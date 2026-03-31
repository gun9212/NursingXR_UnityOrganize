[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$OutputLabel,
    [string]$ConfigPath,
    [string[]]$Projects,
    [int]$CaptureSize = 1024,
    [switch]$PrepareDirectoriesOnly,
    [string]$QualityIssueCsvPath,
    [string[]]$QualityIssueTypes = @('placeholder_duplicate', 'blank_or_tiny_subject', 'composition_retry')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Path {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return ($Path -replace '\\', '/').TrimEnd('/')
}

function Get-DirectoryUri {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fullPath += [System.IO.Path]::DirectorySeparatorChar
    }

    return New-Object System.Uri($fullPath)
}

function Get-RelativePathCompat {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = Get-DirectoryUri -Path $BasePath
    $targetUri = New-Object System.Uri([System.IO.Path]::GetFullPath($TargetPath))
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString())
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}
function Resolve-ConfigPaths {
    param(
        [string]$ExplicitPath,
        [string]$ScriptRoot
    )

    $resolvedPaths = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        foreach ($entry in ($ExplicitPath -split '[,;]')) {
            $trimmedEntry = $entry.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmedEntry)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $trimmedEntry -PathType Leaf)) {
                throw 'Config path was not found: ' + $trimmedEntry
            }

            $resolvedPaths.Add([System.IO.Path]::GetFullPath($trimmedEntry)) | Out-Null
        }

        return @($resolvedPaths | Select-Object -Unique)
    }

    foreach ($candidateName in @('projects.json', 'projects.local.json')) {
        $candidatePath = Join-Path $ScriptRoot $candidateName
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $resolvedPaths.Add([System.IO.Path]::GetFullPath($candidatePath)) | Out-Null
        }
    }

    return @($resolvedPaths | Select-Object -Unique)
}


function Escape-CsvValue {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ''
    }

    return '"' + $Value.Replace('"', '""') + '"'
}

function Test-UnityProjectRoot {
    param([string]$Path)

    return (Test-Path -LiteralPath (Join-Path $Path 'Assets') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Path 'Packages') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Path 'ProjectSettings') -PathType Container)
}

function Test-HiddenOrSystemDirectory {
    param([System.IO.DirectoryInfo]$Directory)

    return (($Directory.Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0) -or
        (($Directory.Attributes -band [System.IO.FileAttributes]::System) -ne 0)
}

function Should-SkipDiscoveryDirectory {
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string]$OutputLabel
    )

    if (Test-HiddenOrSystemDirectory -Directory $Directory) {
        return $true
    }

    if ($Directory.Name -eq 'Workflows') {
        return $true
    }

    if ($Directory.Name -eq $OutputLabel) {
        return $true
    }

    if ($Directory.Name -match '^\d{6}$') {
        return $true
    }

    return $false
}

function Get-DiscoveredUnityProjects {
    param(
        [string]$RootPath,
        [string]$OutputLabel
    )

    $projects = New-Object System.Collections.Generic.List[object]
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $rootDirectory = Get-Item -LiteralPath $RootPath
    $stack.Push($rootDirectory)

    while ($stack.Count -gt 0) {
        $currentDirectory = $stack.Pop()
        foreach ($childDirectory in @(Get-ChildItem -LiteralPath $currentDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Should-SkipDiscoveryDirectory -Directory $childDirectory -OutputLabel $OutputLabel) {
                continue
            }

            if (Test-UnityProjectRoot -Path $childDirectory.FullName) {
                $projects.Add([PSCustomObject]@{
                    Name = $childDirectory.Name
                    FullPath = $childDirectory.FullName
                    RelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $RootPath -TargetPath $childDirectory.FullName)
                }) | Out-Null
                continue
            }

            $stack.Push($childDirectory)
        }
    }

    $sortedProjects = @($projects | Sort-Object RelativePath, Name)
    return $sortedProjects
}
function Get-WorkflowConfig {
    param([string[]]$Paths)

    $projectMap = @{}
    $editorSearchRoots = New-Object System.Collections.Generic.List[string]

    foreach ($Path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            continue
        }

        $rawConfig = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($rawConfig)) {
            continue
        }

        $json = $rawConfig | ConvertFrom-Json
        if ($null -eq $json) {
            continue
        }

        $editorRootsProperty = $json.PSObject.Properties['editor_search_roots']
        if ($null -ne $editorRootsProperty -and $null -ne $editorRootsProperty.Value) {
            foreach ($editorRoot in @($editorRootsProperty.Value)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$editorRoot)) {
                    $editorSearchRoots.Add([string]$editorRoot) | Out-Null
                }
            }
        }

        $projectsProperty = $json.PSObject.Properties['projects']
        if ($null -eq $projectsProperty -or $null -eq $projectsProperty.Value) {
            continue
        }

        foreach ($projectProperty in $projectsProperty.Value.PSObject.Properties) {
            $relativePathKey = Normalize-Path $projectProperty.Name
            $existing = if ($projectMap.ContainsKey($relativePathKey)) {
                $projectMap[$relativePathKey]
            } else {
                [PSCustomObject]@{
                    Exclude = @()
                    OutputName = ''
                    UnityEditorPath = ''
                    CaptureEnabled = $true
                }
            }

            $exclude = @($existing.Exclude)
            $outputName = [string]$existing.OutputName
            $unityEditorPath = [string]$existing.UnityEditorPath
            $captureEnabled = [bool]$existing.CaptureEnabled

            $excludeProperty = $projectProperty.Value.PSObject.Properties['exclude']
            $outputNameProperty = $projectProperty.Value.PSObject.Properties['output_name']
            $unityEditorPathProperty = $projectProperty.Value.PSObject.Properties['unity_editor_path']
            $captureEnabledProperty = $projectProperty.Value.PSObject.Properties['capture_enabled']

            if ($null -ne $excludeProperty -and $null -ne $excludeProperty.Value) {
                $exclude = @($excludeProperty.Value | ForEach-Object { Normalize-Path $_ })
            }

            if ($null -ne $outputNameProperty -and $null -ne $outputNameProperty.Value) {
                $outputName = [string]$outputNameProperty.Value
            }

            if ($null -ne $unityEditorPathProperty -and $null -ne $unityEditorPathProperty.Value) {
                $unityEditorPath = [string]$unityEditorPathProperty.Value
            }

            if ($null -ne $captureEnabledProperty -and $null -ne $captureEnabledProperty.Value) {
                $captureEnabled = [bool]$captureEnabledProperty.Value
            }

            $projectMap[$relativePathKey] = [PSCustomObject]@{
                Exclude = $exclude
                OutputName = $outputName
                UnityEditorPath = $unityEditorPath
                CaptureEnabled = $captureEnabled
            }
        }
    }

    return [PSCustomObject]@{
        EditorSearchRoots = @($editorSearchRoots | Select-Object -Unique)
        Projects = $projectMap
    }
}

function Get-RequestedProjectSelections {
    param([string[]]$RequestedProjects)

    $normalizedSelections = New-Object System.Collections.Generic.List[string]
    foreach ($requestedProject in @($RequestedProjects)) {
        if ([string]::IsNullOrWhiteSpace($requestedProject)) {
            continue
        }

        foreach ($selection in ($requestedProject -split '[,;]')) {
            $trimmed = $selection.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            $normalizedSelections.Add($trimmed) | Out-Null
        }
    }

    return @($normalizedSelections | Select-Object -Unique)
}

function Parse-UnityVersionInfo {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $match = [System.Text.RegularExpressions.Regex]::Match(
        $Version.Trim(),
        '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<release>[abfcp])(?<build>\d+)$')
    if (-not $match.Success) {
        return $null
    }

    return [PSCustomObject]@{
        Raw = $Version.Trim()
        Major = [int]$match.Groups['major'].Value
        Minor = [int]$match.Groups['minor'].Value
        Patch = [int]$match.Groups['patch'].Value
        Release = $match.Groups['release'].Value
        Build = [int]$match.Groups['build'].Value
    }
}

function Resolve-UnityEditorExecutable {
    param(
        [string]$RequestedVersion,
        [string]$OverridePath,
        [string[]]$SearchRoots
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $trimmedOverridePath = $OverridePath.Trim()
        if (Test-Path -LiteralPath $trimmedOverridePath -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($trimmedOverridePath)
        }

        $overrideExe = Join-Path $trimmedOverridePath 'Editor\Unity.exe'
        if (Test-Path -LiteralPath $overrideExe -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($overrideExe)
        }

        throw 'Configured unity_editor_path was not found: ' + $OverridePath
    }

    $candidateSearchRoots = New-Object System.Collections.Generic.List[string]
    $candidateRecords = New-Object System.Collections.Generic.List[object]
    $defaultSearchRoots = New-Object System.Collections.Generic.List[string]
    foreach ($configuredRoot in @($SearchRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
            $defaultSearchRoots.Add([string]$configuredRoot) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_EDITOR_SEARCH_ROOTS)) {
        foreach ($envRoot in ($env:UNITY_EDITOR_SEARCH_ROOTS -split ';') ) {
            $trimmedEnvRoot = $envRoot.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmedEnvRoot)) {
                $defaultSearchRoots.Add($trimmedEnvRoot) | Out-Null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_EDITOR_ROOT)) {
        $defaultSearchRoots.Add($env:UNITY_EDITOR_ROOT.Trim()) | Out-Null
    }

    $defaultSearchRoots.Add('C:\Program Files\Unity\Hub\Editor') | Out-Null

    foreach ($searchRoot in ($defaultSearchRoots | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($searchRoot)) {
            continue
        }

        $candidateSearchRoots.Add([System.IO.Path]::GetFullPath($searchRoot)) | Out-Null
    }
    foreach ($searchRoot in ($candidateSearchRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
            continue
        }

        foreach ($directory in (Get-ChildItem -LiteralPath $searchRoot -Directory -ErrorAction SilentlyContinue)) {
            $versionInfo = Parse-UnityVersionInfo -Version $directory.Name
            if ($null -eq $versionInfo) {
                continue
            }

            $editorExe = Join-Path $directory.FullName 'Editor\Unity.exe'
            if (-not (Test-Path -LiteralPath $editorExe -PathType Leaf)) {
                continue
            }

            $candidateRecords.Add([PSCustomObject]@{
                VersionInfo = $versionInfo
                Executable = $editorExe
            }) | Out-Null
        }
    }

    if ($candidateRecords.Count -eq 0) {
        return $null
    }

    foreach ($candidateRecord in $candidateRecords) {
        if ($candidateRecord.VersionInfo.Raw -eq $RequestedVersion) {
            return $candidateRecord.Executable
        }
    }

    $requestedVersionInfo = Parse-UnityVersionInfo -Version $RequestedVersion
    if ($null -eq $requestedVersionInfo) {
        return $null
    }

    $streamMatches = @($candidateRecords | Where-Object {
            $_.VersionInfo.Major -eq $requestedVersionInfo.Major -and
            $_.VersionInfo.Minor -eq $requestedVersionInfo.Minor
        } | Sort-Object `
            @{ Expression = { $_.VersionInfo.Patch }; Descending = $true }, `
            @{ Expression = { $_.VersionInfo.Build }; Descending = $true }, `
            @{ Expression = { $_.VersionInfo.Raw }; Descending = $false })
    if ($streamMatches.Count -gt 0) {
        return $streamMatches[0].Executable
    }

    return $null
}

function Get-UnityProjectVersion {
    param([string]$ProjectRoot)

    $projectVersionPath = Join-Path $ProjectRoot 'ProjectSettings\ProjectVersion.txt'
    if (-not (Test-Path -LiteralPath $projectVersionPath -PathType Leaf)) {
        return ''
    }

    foreach ($line in Get-Content -LiteralPath $projectVersionPath) {
        if ($line -match '^m_EditorVersion:\s*(.+)$') {
            return $Matches[1].Trim()
        }
    }

    return ''
}

function Get-CaptureRelativePath {
    param(
        [string]$ProjectName,
        [string]$SourcePath
    )

    $normalizedSourcePath = Normalize-Path $SourcePath
    $segments = $normalizedSourcePath.Split('/')
    $directorySegments = if ($segments.Length -gt 1) { @($segments[0..($segments.Length - 2)]) } else { @() }
    $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($normalizedSourcePath)
    $extensionSuffix = [System.IO.Path]::GetExtension($normalizedSourcePath).TrimStart('.').ToLowerInvariant()
    $captureFileName = $fileNameWithoutExtension + '_' + $extensionSuffix + '.png'
    $directoryPath = if (@($directorySegments).Count -gt 0) { [string]::Join('/', @($directorySegments)) } else { '' }
    $projectRelativePath = if ([string]::IsNullOrWhiteSpace($directoryPath)) {
        $captureFileName
    }
    else {
        $directoryPath + '/' + $captureFileName
    }

    return Normalize-Path (Join-Path $ProjectName $projectRelativePath)
}

function Get-AbsoluteOutputPath {
    param(
        [string]$OutputRoot,
        [string]$RelativeOutputPath
    )

    return [System.IO.Path]::GetFullPath((Join-Path $OutputRoot ($RelativeOutputPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
}

function Write-CaptureInventoryCsv {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('project_name,source_path,project_path,capture_path,capture_status,error,asset_kind,top_root,relative_folder,file_name,extension') | Out-Null

    foreach ($record in @($Records)) {
        $fields = @(
            $record.project_name,
            $record.source_path,
            $record.project_path,
            $record.capture_path,
            $record.capture_status,
            $record.error,
            $record.asset_kind,
            $record.top_root,
            $record.relative_folder,
            $record.file_name,
            $record.extension
        ) | ForEach-Object { Escape-CsvValue $_ }

        $lines.Add(($fields -join ',')) | Out-Null
    }

    Write-Utf8File -Path $Path -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function New-SummaryCounts {
    param(
        [object[]]$Records,
        [string]$PropertyName,
        [switch]$ByCountDescending
    )

    $groups = $Records | Group-Object -Property $PropertyName
    if ($ByCountDescending) {
        $groups = $groups | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false }
    }
    else {
        $groups = $groups | Sort-Object Name
    }

    return @($groups | ForEach-Object {
        [PSCustomObject]@{
            name = $_.Name
            count = $_.Count
        }
    })
}

function Write-CaptureSummaryJson {
    param(
        [string]$Path,
        [string]$WorkspaceRoot,
        [string]$WorkflowRelativePath,
        [string]$ProjectName,
        [string]$UnityProjectRelativePath,
        [string]$OutputRelativePath,
        [string]$UnityVersion,
        [string]$UnityEditorPath,
        [int]$CaptureSize,
        [int]$BatchExitCode,
        [object[]]$Records
    )

    $statusCounts = New-SummaryCounts -Records $Records -PropertyName 'capture_status' -ByCountDescending
    $assetKinds = New-SummaryCounts -Records $Records -PropertyName 'asset_kind'
    $topRoots = New-SummaryCounts -Records $Records -PropertyName 'top_root' -ByCountDescending

    $summary = [PSCustomObject]@{
        generatedAt = [DateTimeOffset]::Now.ToString('O')
        workspaceRoot = $WorkspaceRoot
        workflowRoot = $WorkflowRelativePath
        projectName = $ProjectName
        unityProjectPath = $UnityProjectRelativePath
        requestedUnityVersion = $UnityVersion
        unityEditorPath = $UnityEditorPath
        sourcePath = 'Assets'
        captureRoot = (Normalize-Path (Join-Path $ProjectName 'Assets'))
        outputPath = $OutputRelativePath
        captureSize = $CaptureSize
        batchExitCode = $BatchExitCode
        totalCount = @($Records).Count
        statuses = @($statusCounts)
        assetKinds = @($assetKinds)
        topRoots = @($topRoots)
    }

    Write-Utf8File -Path $Path -Content ($summary | ConvertTo-Json -Depth 6)
}

function Remove-NonSuccessCaptureFiles {
    param(
        [string]$OutputRoot,
        [object[]]$Records
    )

    foreach ($record in @($Records | Where-Object { $_.capture_status -ne 'success' })) {
        if ([string]::IsNullOrWhiteSpace($record.capture_path)) {
            continue
        }

        $absoluteCapturePath = Get-AbsoluteOutputPath -OutputRoot $OutputRoot -RelativeOutputPath $record.capture_path
        if (Test-Path -LiteralPath $absoluteCapturePath -PathType Leaf) {
            Remove-Item -LiteralPath $absoluteCapturePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-CaptureRequest {
    param(
        [string]$ProjectName,
        [string]$OutputRoot,
        [int]$CaptureSize,
        [object[]]$InventoryRows,
        [hashtable]$ForceRecaptureCapturePaths
    )

    return [PSCustomObject]@{
        captureSize = $CaptureSize
        entries = @($InventoryRows | ForEach-Object {
            $captureRelativePath = Get-CaptureRelativePath -ProjectName $ProjectName -SourcePath $_.source_path
            $forceRecapture = $false
            $issueType = ''
            $previewDistanceScaleOverride = 0.0
            if ($null -ne $ForceRecaptureCapturePaths) {
                $forceRecapture = $ForceRecaptureCapturePaths.ContainsKey($captureRelativePath)
                if ($forceRecapture) {
                    $issueType = [string]$ForceRecaptureCapturePaths[$captureRelativePath]
                    $previewDistanceScaleOverride = Get-PreviewDistanceScaleOverride -SourcePath $_.source_path -IssueType $issueType
                }
            }

            [PSCustomObject]@{
                projectName = $ProjectName
                sourcePath = $_.source_path
                projectPath = $_.project_path
                capturePath = $captureRelativePath
                outputPath = (Get-AbsoluteOutputPath -OutputRoot $OutputRoot -RelativeOutputPath $captureRelativePath)
                assetKind = $_.asset_kind
                topRoot = $_.top_root
                relativeFolder = $_.relative_folder
                fileName = $_.file_name
                extension = $_.extension
                issueType = $issueType
                previewDistanceScale = $previewDistanceScaleOverride
                forceRecapture = $forceRecapture
            }
        })
    }
}

function Get-PreviewDistanceScaleOverride {
    param(
        [string]$SourcePath,
        [string]$IssueType
    )

    $normalizedSourcePath = Normalize-Path $SourcePath
    $normalizedIssueType = [string]$IssueType
    if (-not [string]::Equals($normalizedIssueType, 'blank_or_tiny_subject', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 0.0
    }

    switch ($normalizedSourcePath) {
        'Assets/ART/free/tooth paste/Tooth+brush+lowpoly.fbx' { return 0.16 }
        'Assets/ksim/ART/buy/pen/ball_pen.fbx' { return 0.14 }
        'Assets/ksim/ART/Asset/Blue Dot Studios/Hospital/Prefabs/Tree_A.prefab' { return 0.08 }
        default { return 0.12 }
    }
}
function Get-QualityIssueSelectionMap {
    param(
        [string]$CsvPath,
        [string[]]$AllowedIssueTypes
    )

    $selectionMap = @{}
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        return $selectionMap
    }

    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw 'Quality issue CSV was not found: ' + $CsvPath
    }

    $normalizedIssueTypes = @($AllowedIssueTypes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
    if (@($normalizedIssueTypes).Count -eq 0) {
        throw 'At least one quality issue type must be provided when QualityIssueCsvPath is used.'
    }

    $importedIssueRows = @(Import-Csv -LiteralPath $CsvPath)
    if (@($importedIssueRows).Count -eq 0) {
        return $selectionMap
    }

    $issueColumnNames = @($importedIssueRows[0].PSObject.Properties.Name)
    $requiredIssueColumns = @('project_name', 'capture_path', 'issue_type')
    $missingIssueColumns = @($requiredIssueColumns | Where-Object { $issueColumnNames -notcontains $_ })
    if (@($missingIssueColumns).Count -gt 0) {
        throw ('Quality issue CSV is missing required columns: ' + (($missingIssueColumns | Sort-Object) -join ', ') + '. Path=' + $CsvPath)
    }

    $issueRows = @($importedIssueRows | Where-Object { $normalizedIssueTypes -contains ([string]$_.issue_type) })
    foreach ($issueRow in $issueRows) {
        $projectName = [string]$issueRow.project_name
        $capturePath = Normalize-Path ([string]$issueRow.capture_path)
        if ([string]::IsNullOrWhiteSpace($projectName) -or [string]::IsNullOrWhiteSpace($capturePath)) {
            continue
        }

        if (-not $selectionMap.ContainsKey($projectName)) {
            $selectionMap[$projectName] = @{}
        }

        $selectionMap[$projectName][$capturePath] = [string]$issueRow.issue_type
    }

    return $selectionMap
}

function Remove-CaptureOutputsForRequest {
    param([object]$CaptureRequest)

    foreach ($entry in @($CaptureRequest.entries | Where-Object { $_.forceRecapture })) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.outputPath)) {
            continue
        }

        if (Test-Path -LiteralPath $entry.outputPath -PathType Leaf) {
            Remove-Item -LiteralPath $entry.outputPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-CaptureDirectories {
    param([object]$CaptureRequest)

    foreach ($entry in @($CaptureRequest.entries)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.outputPath)) {
            continue
        }

        $outputDirectory = Split-Path -Parent $entry.outputPath
        if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
    }
}

function Merge-CaptureRecords {
    param(
        [object[]]$ExistingRecords,
        [object[]]$UpdatedRecords
    )

    $recordMap = @{}
    foreach ($record in @($ExistingRecords) + @($UpdatedRecords)) {
        if ($null -eq $record) {
            continue
        }

        $key = ([string]$record.project_name) + '|' + ([string]$record.source_path) + '|' + ([string]$record.capture_path)
        $recordMap[$key] = $record
    }

    return @($recordMap.Values | Sort-Object project_name, source_path)
}

function New-SkippedCaptureResults {
    param(
        [string]$ProjectName,
        [object[]]$InventoryRows,
        [string]$Status,
        [string]$ErrorMessage
    )

    return @($InventoryRows | ForEach-Object {
        [PSCustomObject]@{
            project_name = $ProjectName
            source_path = $_.source_path
            project_path = $_.project_path
            capture_path = (Get-CaptureRelativePath -ProjectName $ProjectName -SourcePath $_.source_path)
            capture_status = $Status
            error = $ErrorMessage
            asset_kind = $_.asset_kind
            top_root = $_.top_root
            relative_folder = $_.relative_folder
            file_name = $_.file_name
            extension = $_.extension
        }
    })
}

function New-CaptureRecordFromInventoryRow {
    param(
        [string]$ProjectName,
        [object]$InventoryRow,
        [string]$CapturePath,
        [string]$Status,
        [string]$ErrorMessage
    )

    return [PSCustomObject]@{
        project_name = $ProjectName
        source_path = $InventoryRow.source_path
        project_path = $InventoryRow.project_path
        capture_path = $CapturePath
        capture_status = $Status
        error = $ErrorMessage
        asset_kind = $InventoryRow.asset_kind
        top_root = $InventoryRow.top_root
        relative_folder = $InventoryRow.relative_folder
        file_name = $InventoryRow.file_name
        extension = $InventoryRow.extension
    }
}

function Wait-ForStableFile {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds = 15000,
        [int]$PollMilliseconds = 250
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLength = -1L
    $stableReads = 0

    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $currentLength = (Get-Item -LiteralPath $Path).Length
            if ($currentLength -gt 0 -and $currentLength -eq $lastLength) {
                $stableReads += 1
                if ($stableReads -ge 2) {
                    return $true
                }
            }
            else {
                $lastLength = $currentLength
                $stableReads = 0
            }
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }

    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function New-CaptureResultsFromDiskState {
    param(
        [string]$ProjectName,
        [string]$OutputRoot,
        [object[]]$InventoryRows,
        [string]$FailureMessage
    )

    return @($InventoryRows | ForEach-Object {
        $capturePath = Get-CaptureRelativePath -ProjectName $ProjectName -SourcePath $_.source_path
        $absoluteCapturePath = Get-AbsoluteOutputPath -OutputRoot $OutputRoot -RelativeOutputPath $capturePath
        if (Test-Path -LiteralPath $absoluteCapturePath -PathType Leaf) {
            New-CaptureRecordFromInventoryRow -ProjectName $ProjectName -InventoryRow $_ -CapturePath $capturePath -Status 'success' -ErrorMessage ''
        }
        else {
            New-CaptureRecordFromInventoryRow -ProjectName $ProjectName -InventoryRow $_ -CapturePath $capturePath -Status 'failed' -ErrorMessage $FailureMessage
        }
    })
}

function Complete-RunCaptureRecords {
    param(
        [string]$ProjectName,
        [string]$OutputRoot,
        [object[]]$InventoryRows,
        [object[]]$ImportedRecords,
        [string]$FallbackFailureMessage
    )

    $importedRecordMap = @{}
    foreach ($record in @($ImportedRecords)) {
        if ($null -eq $record) {
            continue
        }

        $capturePathKey = Normalize-Path ([string]$record.capture_path)
        if ([string]::IsNullOrWhiteSpace($capturePathKey)) {
            continue
        }

        $importedRecordMap[$capturePathKey] = $record
    }

    return @($InventoryRows | ForEach-Object {
        $capturePath = Get-CaptureRelativePath -ProjectName $ProjectName -SourcePath $_.source_path
        $capturePathKey = Normalize-Path $capturePath
        if ($importedRecordMap.ContainsKey($capturePathKey)) {
            $importedRecordMap[$capturePathKey]
        }
        else {
            $absoluteCapturePath = Get-AbsoluteOutputPath -OutputRoot $OutputRoot -RelativeOutputPath $capturePath
            if (Test-Path -LiteralPath $absoluteCapturePath -PathType Leaf) {
                New-CaptureRecordFromInventoryRow -ProjectName $ProjectName -InventoryRow $_ -CapturePath $capturePath -Status 'success' -ErrorMessage ''
            }
            else {
                New-CaptureRecordFromInventoryRow -ProjectName $ProjectName -InventoryRow $_ -CapturePath $capturePath -Status 'failed' -ErrorMessage $FallbackFailureMessage
            }
        }
    })
}

function Get-ReconciledProjectCaptureBase {
    param(
        [string]$ProjectName,
        [string]$OutputRoot,
        [object[]]$ProjectInventoryRows,
        [object[]]$ExistingCaptureRecords
    )

    $existingRecordMap = @{}
    foreach ($record in @($ExistingCaptureRecords)) {
        if ($null -eq $record) {
            continue
        }

        $capturePathKey = Normalize-Path ([string]$record.capture_path)
        if ([string]::IsNullOrWhiteSpace($capturePathKey)) {
            continue
        }

        $existingRecordMap[$capturePathKey] = $record
    }

    return @($ProjectInventoryRows | ForEach-Object {
        $capturePath = Get-CaptureRelativePath -ProjectName $ProjectName -SourcePath $_.source_path
        $capturePathKey = Normalize-Path $capturePath
        if ($existingRecordMap.ContainsKey($capturePathKey)) {
            $existingRecordMap[$capturePathKey]
        }
        else {
            $absoluteCapturePath = Get-AbsoluteOutputPath -OutputRoot $OutputRoot -RelativeOutputPath $capturePath
            if (Test-Path -LiteralPath $absoluteCapturePath -PathType Leaf) {
                New-CaptureRecordFromInventoryRow -ProjectName $ProjectName -InventoryRow $_ -CapturePath $capturePath -Status 'success' -ErrorMessage ''
            }
            else {
                New-CaptureRecordFromInventoryRow -ProjectName $ProjectName -InventoryRow $_ -CapturePath $capturePath -Status 'failed' -ErrorMessage 'Capture state reconstructed from inventory and disk because canonical capture_inventory.csv was incomplete.'
            }
        }
    })
}

function Ensure-CaptureToolInjection {
    param(
        [string]$ProjectRoot,
        [string]$CaptureToolsEditorRoot
    )

    $editorRoot = Join-Path $ProjectRoot 'Assets\Editor'
    $editorRootCreated = $false
    if (-not (Test-Path -LiteralPath $editorRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $editorRoot -Force | Out-Null
        $editorRootCreated = $true
    }

    $toolLinkPath = Join-Path $editorRoot '__UnityWorkflowCaptureTools'
    $expectedToolFile = Join-Path $toolLinkPath 'ProjectAssetCaptureBatch.cs'
    $sourceToolFile = Join-Path $CaptureToolsEditorRoot 'ProjectAssetCaptureBatch.cs'
    if (-not (Test-Path -LiteralPath $sourceToolFile -PathType Leaf)) {
        throw 'Capture tool source file was not found: ' + $sourceToolFile
    }

    if (Test-Path -LiteralPath $toolLinkPath) {
        $existingItem = Get-Item -LiteralPath $toolLinkPath -Force
        $isReparsePoint = ($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isReparsePoint -and (Test-Path -LiteralPath $expectedToolFile -PathType Leaf)) {
            return [PSCustomObject]@{
                EditorRoot = $editorRoot
                EditorRootCreated = $editorRootCreated
                ToolLinkPath = $toolLinkPath
                InjectionMode = 'junction'
            }
        }

        if ($isReparsePoint) {
            [System.IO.Directory]::Delete($toolLinkPath)
        }
        else {
            Remove-Item -LiteralPath $toolLinkPath -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    try {
        New-Item -ItemType Junction -Path $toolLinkPath -Target $CaptureToolsEditorRoot | Out-Null
    }
    catch {
    }

    if (-not (Test-Path -LiteralPath $expectedToolFile -PathType Leaf)) {
        if (Test-Path -LiteralPath $toolLinkPath) {
            $currentItem = Get-Item -LiteralPath $toolLinkPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $currentItem -and (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                [System.IO.Directory]::Delete($toolLinkPath)
            }
            else {
                Remove-Item -LiteralPath $toolLinkPath -Force -Recurse -ErrorAction SilentlyContinue
            }
        }

        New-Item -ItemType Directory -Path $toolLinkPath -Force | Out-Null
        foreach ($sourceItem in @(Get-ChildItem -LiteralPath $CaptureToolsEditorRoot -Force -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $sourceItem.FullName -Destination (Join-Path $toolLinkPath $sourceItem.Name) -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $expectedToolFile -PathType Leaf)) {
        throw 'Capture tool injection did not expose ProjectAssetCaptureBatch.cs: ' + $expectedToolFile
    }

    $injectionMode = 'directory_copy'
    $finalItem = Get-Item -LiteralPath $toolLinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $finalItem -and (($finalItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        $injectionMode = 'junction'
    }

    return [PSCustomObject]@{
        EditorRoot = $editorRoot
        EditorRootCreated = $editorRootCreated
        ToolLinkPath = $toolLinkPath
        InjectionMode = $injectionMode
    }
}

function Remove-CaptureToolInjection {
    param([object]$InjectionState)

    if ($null -eq $InjectionState) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($InjectionState.ToolLinkPath) -and (Test-Path -LiteralPath $InjectionState.ToolLinkPath)) {
        $toolLinkItem = Get-Item -LiteralPath $InjectionState.ToolLinkPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $toolLinkItem -and (($toolLinkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            [System.IO.Directory]::Delete($InjectionState.ToolLinkPath)
        }
        else {
            Remove-Item -LiteralPath $InjectionState.ToolLinkPath -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    $toolLinkMetaPath = $InjectionState.ToolLinkPath + '.meta'
    if (Test-Path -LiteralPath $toolLinkMetaPath -PathType Leaf) {
        Remove-Item -LiteralPath $toolLinkMetaPath -Force -ErrorAction SilentlyContinue
    }

    if ($InjectionState.EditorRootCreated -and -not [string]::IsNullOrWhiteSpace($InjectionState.EditorRoot)) {
        $remainingItems = @(Get-ChildItem -LiteralPath $InjectionState.EditorRoot -Force -ErrorAction SilentlyContinue)
        if (@($remainingItems).Count -eq 0) {
            Remove-Item -LiteralPath $InjectionState.EditorRoot -Force -ErrorAction SilentlyContinue
            $editorMetaPath = $InjectionState.EditorRoot + '.meta'
            if (Test-Path -LiteralPath $editorMetaPath -PathType Leaf) {
                Remove-Item -LiteralPath $editorMetaPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-UnityProjectProcessInfo {
    param([string]$ProjectRoot)

    $normalizedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $unityProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'Unity.exe'" -ErrorAction SilentlyContinue)
    return @(
        $unityProcesses | Where-Object {
            $commandLine = [string]$_.CommandLine
            -not [string]::IsNullOrWhiteSpace($commandLine) -and $commandLine.IndexOf($normalizedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        }
    )
}

function Clear-StaleUnityProjectLock {
    param([string]$ProjectRoot)

    $lockFilePath = Join-Path $ProjectRoot 'Temp\UnityLockfile'
    if (-not (Test-Path -LiteralPath $lockFilePath -PathType Leaf)) {
        return
    }

    $sameProjectProcesses = @(Get-UnityProjectProcessInfo -ProjectRoot $ProjectRoot)
    if (@($sameProjectProcesses).Count -gt 0) {
        $processSummary = (@($sameProjectProcesses | ForEach-Object { $_.ProcessId.ToString() }) -join ', ')
        throw ('Unity project is already open by another process. ProjectRoot=' + $ProjectRoot + '; PIDs=' + $processSummary)
    }

    Remove-Item -LiteralPath $lockFilePath -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 750
    if (Test-Path -LiteralPath $lockFilePath -PathType Leaf) {
        throw ('Stale UnityLockfile could not be removed. Path=' + $lockFilePath)
    }
}

function Invoke-UnityCaptureBatchPreflight {
    param([string]$ProjectRoot, [string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw ('Capture manifest was not found before Unity launch. Path=' + $ManifestPath)
    }

    $sameProjectProcesses = @(Get-UnityProjectProcessInfo -ProjectRoot $ProjectRoot)
    if (@($sameProjectProcesses).Count -gt 0) {
        $processSummary = (@($sameProjectProcesses | ForEach-Object { $_.ProcessId.ToString() }) -join ', ')
        throw ('Unity project is already open by another process. ProjectRoot=' + $ProjectRoot + '; PIDs=' + $processSummary)
    }

    Clear-StaleUnityProjectLock -ProjectRoot $ProjectRoot
}

function Invoke-UnityCaptureBatch {
    param(
        [string]$UnityEditorPath,
        [string]$ProjectRoot,
        [string]$ManifestPath,
        [string]$ResultPath,
        [string]$LogPath,
        [int]$CaptureSize
    )

    $argumentList = @(
        '-batchmode'
        '-quit'
        '-projectPath'
        ('"' + $ProjectRoot + '"'),
        '-logFile'
        ('"' + $LogPath + '"'),
        '-executeMethod'
        'ProjectAssetCaptureBatch.RunBatchCapture'
        '-captureManifest'
        ('"' + $ManifestPath + '"'),
        '-captureResult'
        ('"' + $ResultPath + '"'),
        '-captureSize'
        $CaptureSize.ToString()
    )

    Invoke-UnityCaptureBatchPreflight -ProjectRoot $ProjectRoot -ManifestPath $ManifestPath
    $process = Start-Process -FilePath $UnityEditorPath -ArgumentList $argumentList -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $workflowRoot = Split-Path -Parent $PSScriptRoot
    $WorkspaceRoot = Split-Path -Parent $workflowRoot
}

if ([string]::IsNullOrWhiteSpace($OutputLabel)) {
    $OutputLabel = Get-Date -Format 'yyyyMMdd'
}

$configPaths = Resolve-ConfigPaths -ExplicitPath $ConfigPath -ScriptRoot $PSScriptRoot
$CaptureSize = [Math]::Min([Math]::Max($CaptureSize, 128), 2048)
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$WorkflowRelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $PSScriptRoot)
$OutputRoot = Join-Path $WorkspaceRoot $OutputLabel
$CaptureToolsEditorRoot = Join-Path $PSScriptRoot 'UnityCaptureTools\Editor'
$qualityIssueSelectionMap = Get-QualityIssueSelectionMap -CsvPath $QualityIssueCsvPath -AllowedIssueTypes $QualityIssueTypes
$rootInventoryPath = Join-Path $OutputRoot 'project_inventory.csv'
$rootInventoryRows = if (Test-Path -LiteralPath $rootInventoryPath -PathType Leaf) { @(Import-Csv -Path $rootInventoryPath) } else { @() }
if ($PrepareDirectoriesOnly) {
    if (-not (Test-Path -LiteralPath $rootInventoryPath -PathType Leaf)) {
        throw 'Root inventory manifest was not found: ' + $rootInventoryPath
    }
    if (@($rootInventoryRows).Count -eq 0) {
        throw 'Root inventory manifest was empty: ' + $rootInventoryPath
    }


    $preparedProjectCounts = @{}
    foreach ($row in $rootInventoryRows) {
        if ($null -eq $row) {
            continue
        }

        $projectName = if ($row.PSObject.Properties['project_name'] -ne $null) { [string]$row.project_name } else { '' }
        $sourcePath = if ($row.PSObject.Properties['source_path'] -ne $null) { [string]$row.source_path } else { '' }
        if ([string]::IsNullOrWhiteSpace($projectName) -or [string]::IsNullOrWhiteSpace($sourcePath)) {
            continue
        }

        $captureRelativePath = Get-CaptureRelativePath -ProjectName $projectName -SourcePath $sourcePath
        $absoluteOutputPath = Get-AbsoluteOutputPath -OutputRoot $OutputRoot -RelativeOutputPath $captureRelativePath
        $targetDirectory = Split-Path -Parent $absoluteOutputPath
        if (-not [string]::IsNullOrWhiteSpace($targetDirectory) -and -not (Test-Path -LiteralPath $targetDirectory)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }

        if (-not $preparedProjectCounts.ContainsKey($projectName)) {
            $preparedProjectCounts[$projectName] = 0
        }

        $preparedProjectCounts[$projectName] += 1
    }

    foreach ($projectName in @($preparedProjectCounts.Keys | Sort-Object)) {
        $projectAssetsRoot = Normalize-Path (Join-Path (Join-Path $OutputLabel $projectName) 'Assets')
        Write-Output ('Prepared capture directories for ' + $projectName + ': ' + $preparedProjectCounts[$projectName] + ' assets -> ' + $projectAssetsRoot)
    }

    return
}

$workflowConfig = Get-WorkflowConfig -Paths $configPaths
$projectOverrides = $workflowConfig.Projects
$workspaceProjectCandidates = @(
    Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        ($_.FullName -notlike (Join-Path $WorkspaceRoot 'Workflows*')) -and
        ($_.FullName -notlike (Join-Path $WorkspaceRoot ($OutputLabel + '*'))) -and
        ($_.Name -notmatch '^\d{6}$') -and
        (Test-UnityProjectRoot -Path $_.FullName)
    } | Sort-Object @{ Expression = { $_.FullName.Length } }, FullName
)

$workspaceProjects = @()
foreach ($candidateProject in $workspaceProjectCandidates) {
    $candidateFullPath = [System.IO.Path]::GetFullPath($candidateProject.FullName)
    $isNestedProject = $false
    foreach ($selectedProject in $workspaceProjects) {
        $selectedFullPath = [System.IO.Path]::GetFullPath([string]$selectedProject.FullPath).TrimEnd('\', '/') + '\'
        if ($candidateFullPath.StartsWith($selectedFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isNestedProject = $true
            break
        }
    }

    if ($isNestedProject) {
        continue
    }

    $workspaceProjects += [PSCustomObject]@{
        Name = $candidateProject.Name
        FullPath = $candidateProject.FullName
        RelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $candidateProject.FullName)
    }
}

if (@($workspaceProjects).Count -eq 0) {
    throw 'No Unity projects were discovered under ' + $WorkspaceRoot
}

$resolvedProjects = @()
$outputNameMap = @{}
foreach ($project in $workspaceProjects) {
    $projectRelativePath = Normalize-Path ([string]$project.RelativePath)
    $projectName = [string]$project.Name
    $override = $projectOverrides[$projectRelativePath]
    $outputName = $projectName
    $unityEditorPath = ''
    $captureEnabled = $true

    if ($null -ne $override) {
        if (-not [string]::IsNullOrWhiteSpace($override.OutputName)) {
            $outputName = [string]$override.OutputName
        }

        if (-not [string]::IsNullOrWhiteSpace($override.UnityEditorPath)) {
            $unityEditorPath = [string]$override.UnityEditorPath
        }

        if ($null -ne $override.CaptureEnabled) {
            $captureEnabled = [bool]$override.CaptureEnabled
        }
    }

    if ($outputNameMap.ContainsKey($outputName)) {
        throw 'Duplicate output_name detected: ' + $outputName
    }

    $outputNameMap[$outputName] = $projectRelativePath
    $resolvedProjects += [PSCustomObject]@{
        ProjectName = $outputName
        FullPath = $project.FullPath
        RelativePath = $projectRelativePath
        UnityEditorPath = $unityEditorPath
        CaptureEnabled = $captureEnabled
    }
}

$requestedProjects = Get-RequestedProjectSelections -RequestedProjects $Projects
if (@($requestedProjects).Count -gt 0) {
    $selectedProjects = @()
    foreach ($requestedProject in $requestedProjects) {
        $normalizedRequestedProject = Normalize-Path $requestedProject
        $matchedProject = $resolvedProjects | Where-Object {
            $_.ProjectName.Equals($requestedProject, [System.StringComparison]::OrdinalIgnoreCase) -or
            (($_.PSObject.Properties['RelativePath'] -ne $null) -and $_.RelativePath.Equals($normalizedRequestedProject, [System.StringComparison]::OrdinalIgnoreCase))
        } | Select-Object -First 1

        if ($null -eq $matchedProject) {
            throw 'Requested project was not discovered: ' + $requestedProject
        }

        $selectedProjects += $matchedProject
    }

    $resolvedProjects = @($selectedProjects | Group-Object ProjectName | ForEach-Object { $_.Group[0] } | Sort-Object ProjectName)
}

$allCaptureRecords = New-Object System.Collections.Generic.List[object]
foreach ($project in $resolvedProjects) {
    $projectOutputRoot = Join-Path $OutputRoot $project.ProjectName
    $docsRoot = Join-Path $projectOutputRoot '_docs'
    if (-not (Test-Path -LiteralPath $docsRoot)) {
        New-Item -ItemType Directory -Path $docsRoot -Force | Out-Null
    }

    $captureInventoryPath = Join-Path $docsRoot 'capture_inventory.csv'
    $captureSummaryPath = Join-Path $docsRoot 'capture_summary.json'
    $batchLogPath = Join-Path $docsRoot 'capture_batch.log'
    $existingCaptureRecords = if (Test-Path -LiteralPath $captureInventoryPath -PathType Leaf) { @($(Import-Csv -Path $captureInventoryPath)) } else { @() }
    $projectInventoryPath = Join-Path $docsRoot 'project_inventory.csv'
    if (Test-Path -LiteralPath $projectInventoryPath -PathType Leaf) {
        $projectInventoryRows = @(Import-Csv -Path $projectInventoryPath)
    }
    elseif (@($rootInventoryRows).Count -gt 0) {
        $projectInventoryRows = @($rootInventoryRows | Where-Object { $_.project_name -eq $project.ProjectName })
    }
    else {
        throw 'Project inventory was not found. Run the inventory workflow first: ' + $projectInventoryPath
    }
    if (@($projectInventoryRows).Count -eq 0) {
        throw 'Project inventory rows were not found for project: ' + $project.ProjectName
    }
    $fullProjectBase = @(Get-ReconciledProjectCaptureBase -ProjectName $project.ProjectName -OutputRoot $OutputRoot -ProjectInventoryRows $projectInventoryRows -ExistingCaptureRecords $existingCaptureRecords)
    $inventoryRows = $projectInventoryRows
    $forceRecaptureCapturePaths = $null
    if ($qualityIssueSelectionMap.ContainsKey($project.ProjectName)) {
        $forceRecaptureCapturePaths = $qualityIssueSelectionMap[$project.ProjectName]
        $inventoryRows = @(
            $inventoryRows | Where-Object {
                $capturePath = Get-CaptureRelativePath -ProjectName $project.ProjectName -SourcePath $_.source_path
                $forceRecaptureCapturePaths.ContainsKey($capturePath)
            }
        )
    }

    if (@($inventoryRows).Count -eq 0) {
        foreach ($existingRecord in $fullProjectBase) {
            $allCaptureRecords.Add($existingRecord) | Out-Null
        }
        continue
    }

    $captureRequest = New-CaptureRequest -ProjectName $project.ProjectName -OutputRoot $OutputRoot -CaptureSize $CaptureSize -InventoryRows $inventoryRows -ForceRecaptureCapturePaths $forceRecaptureCapturePaths
    $outputRelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $projectOutputRoot)

    if ($PrepareDirectoriesOnly) {
        Ensure-CaptureDirectories -CaptureRequest $captureRequest
        Write-Output ('Prepared capture directories for ' + $project.ProjectName + ': ' + @($inventoryRows).Count + ' assets -> ' + $outputRelativePath)
        continue
    }

    if (-not $project.CaptureEnabled) {
        $skippedResults = @(New-SkippedCaptureResults -ProjectName $project.ProjectName -InventoryRows $inventoryRows -Status 'skipped' -ErrorMessage 'Capture disabled by workflow config.')
        if (@($existingCaptureRecords).Count -gt 0) {
            $skippedResults = @(Merge-CaptureRecords -ExistingRecords $fullProjectBase -UpdatedRecords $skippedResults)
        }
        Write-CaptureInventoryCsv -Path $captureInventoryPath -Records $skippedResults
        Write-CaptureSummaryJson -Path $captureSummaryPath -WorkspaceRoot $WorkspaceRoot -WorkflowRelativePath $WorkflowRelativePath -ProjectName $project.ProjectName -UnityProjectRelativePath $project.RelativePath -OutputRelativePath $outputRelativePath -UnityVersion '' -UnityEditorPath '' -CaptureSize $CaptureSize -BatchExitCode 0 -Records $skippedResults
        foreach ($record in $skippedResults) {
            $allCaptureRecords.Add($record) | Out-Null
        }
        continue
    }

    $requestedUnityVersion = Get-UnityProjectVersion -ProjectRoot $project.FullPath
    $unityEditorPath = Resolve-UnityEditorExecutable -RequestedVersion $requestedUnityVersion -OverridePath $project.UnityEditorPath -SearchRoots $workflowConfig.EditorSearchRoots
    if ([string]::IsNullOrWhiteSpace($unityEditorPath)) {
        $skippedResults = @(New-SkippedCaptureResults -ProjectName $project.ProjectName -InventoryRows $inventoryRows -Status 'skipped' -ErrorMessage ('No Unity editor was found for version ' + $requestedUnityVersion + '.'))
        if (@($existingCaptureRecords).Count -gt 0) {
            $skippedResults = @(Merge-CaptureRecords -ExistingRecords $fullProjectBase -UpdatedRecords $skippedResults)
        }
        Write-CaptureInventoryCsv -Path $captureInventoryPath -Records $skippedResults
        Write-CaptureSummaryJson -Path $captureSummaryPath -WorkspaceRoot $WorkspaceRoot -WorkflowRelativePath $WorkflowRelativePath -ProjectName $project.ProjectName -UnityProjectRelativePath $project.RelativePath -OutputRelativePath $outputRelativePath -UnityVersion $requestedUnityVersion -UnityEditorPath '' -CaptureSize $CaptureSize -BatchExitCode -1 -Records $skippedResults
        foreach ($record in $skippedResults) {
            $allCaptureRecords.Add($record) | Out-Null
        }
        continue
    }

    $manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) ('UnityWorkflowCapture_' + $project.ProjectName + '_' + $OutputLabel + '.json')
    $tempResultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('UnityWorkflowCaptureResult_' + $project.ProjectName + '_' + $OutputLabel + '.csv')
    if (Test-Path -LiteralPath $captureInventoryPath -PathType Leaf) {
        Remove-Item -LiteralPath $captureInventoryPath -Force
    }
    if (Test-Path -LiteralPath $tempResultPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempResultPath -Force
    }
    Write-Utf8File -Path $manifestPath -Content ($captureRequest | ConvertTo-Json -Depth 6)

    $injectionState = $null
    $batchExitCode = -1
    try {
        $injectionState = Ensure-CaptureToolInjection -ProjectRoot $project.FullPath -CaptureToolsEditorRoot $CaptureToolsEditorRoot
        $batchExitCode = Invoke-UnityCaptureBatch -UnityEditorPath $unityEditorPath -ProjectRoot $project.FullPath -ManifestPath $manifestPath -ResultPath $tempResultPath -LogPath $batchLogPath -CaptureSize $CaptureSize
    }
    finally {
        Remove-CaptureToolInjection -InjectionState $injectionState
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        }
    }

    $resultFileReady = Wait-ForStableFile -Path $tempResultPath
    $fallbackFailureMessage = 'Unity capture batch did not produce a complete capture_inventory.csv. ExitCode=' + $batchExitCode
    if ($resultFileReady) {
        $importedRunCaptureRecords = @(Import-Csv -Path $tempResultPath)
        $runCaptureRecords = @(Complete-RunCaptureRecords -ProjectName $project.ProjectName -OutputRoot $OutputRoot -InventoryRows $inventoryRows -ImportedRecords $importedRunCaptureRecords -FallbackFailureMessage $fallbackFailureMessage)
    }
    else {
        $runCaptureRecords = @(New-CaptureResultsFromDiskState -ProjectName $project.ProjectName -OutputRoot $OutputRoot -InventoryRows $inventoryRows -FailureMessage $fallbackFailureMessage)
    }

    $captureRecords = @(Merge-CaptureRecords -ExistingRecords $fullProjectBase -UpdatedRecords $runCaptureRecords)
    Write-CaptureInventoryCsv -Path $captureInventoryPath -Records $captureRecords
    if (Test-Path -LiteralPath $tempResultPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempResultPath -Force -ErrorAction SilentlyContinue
    }
    Remove-NonSuccessCaptureFiles -OutputRoot $OutputRoot -Records $captureRecords
    Write-CaptureSummaryJson -Path $captureSummaryPath -WorkspaceRoot $WorkspaceRoot -WorkflowRelativePath $WorkflowRelativePath -ProjectName $project.ProjectName -UnityProjectRelativePath $project.RelativePath -OutputRelativePath $outputRelativePath -UnityVersion $requestedUnityVersion -UnityEditorPath $unityEditorPath -CaptureSize $CaptureSize -BatchExitCode $batchExitCode -Records $captureRecords

    foreach ($captureRecord in $captureRecords) {
        $allCaptureRecords.Add($captureRecord) | Out-Null
    }

    Write-Output ('Captured ' + $project.ProjectName + ': ' + @($captureRecords).Count + ' assets -> ' + $outputRelativePath)
}
$workspaceCaptureRecords = @($allCaptureRecords | Sort-Object project_name, source_path)
Write-CaptureInventoryCsv -Path (Join-Path $OutputRoot 'capture_inventory.csv') -Records $workspaceCaptureRecords
