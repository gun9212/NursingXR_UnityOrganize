[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$OutputLabel,
    [string]$ConfigPath
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
        New-Item -ItemType Directory -Path $directory | Out-Null
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
        foreach ($childDirectory in $currentDirectory.EnumerateDirectories()) {
            if (Should-SkipDiscoveryDirectory -Directory $childDirectory -OutputLabel $OutputLabel) {
                continue
            }

            if (Test-UnityProjectRoot -Path $childDirectory.FullName) {
                $projects.Add([PSCustomObject]@{
                    Name = $childDirectory.Name
                    FullPath = $childDirectory.FullName
                    RelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $RootPath -TargetPath $childDirectory.FullName)
                })
                continue
            }

            $stack.Push($childDirectory)
        }
    }

    return $projects | Sort-Object RelativePath, Name
}

function Get-ProjectOverrides {
    param([string[]]$Paths)

    $map = @{}
    foreach ($Path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            continue
        }

        $rawConfig = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($rawConfig)) {
            continue
        }

        $json = $rawConfig | ConvertFrom-Json
        if ($null -eq $json -or $null -eq $json.projects) {
            continue
        }

        foreach ($projectProperty in $json.projects.PSObject.Properties) {
            $relativePathKey = Normalize-Path $projectProperty.Name
            $exclude = @()
            $outputName = ''
            $excludeProperty = $projectProperty.Value.PSObject.Properties['exclude']
            $outputNameProperty = $projectProperty.Value.PSObject.Properties['output_name']

            if ($null -ne $excludeProperty -and $null -ne $excludeProperty.Value) {
                $exclude = @($excludeProperty.Value | ForEach-Object { Normalize-Path $_ })
            }

            if ($null -ne $outputNameProperty -and $null -ne $outputNameProperty.Value) {
                $outputName = [string]$outputNameProperty.Value
            }

            $map[$relativePathKey] = [PSCustomObject]@{
                Exclude = $exclude
                OutputName = $outputName
            }
        }
    }

    return $map
}

function Test-IsExcludedSourcePath {
    param(
        [string]$SourcePath,
        [string[]]$ExcludePrefixes
    )

    $normalizedSourcePath = Normalize-Path $SourcePath
    foreach ($prefix in $ExcludePrefixes) {
        $normalizedPrefix = Normalize-Path $prefix
        if ([string]::IsNullOrWhiteSpace($normalizedPrefix)) {
            continue
        }

        if ($normalizedSourcePath.Equals($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($normalizedSourcePath.StartsWith($normalizedPrefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-AssetKindFromExtension {
    param([string]$Extension)

    switch ($Extension.ToLowerInvariant()) {
        '.fbx' { return 'fbx' }
        '.obj' { return 'obj' }
        '.prefab' { return 'prefab' }
        default { return $Extension.TrimStart('.').ToLowerInvariant() }
    }
}

function Get-InventoryRecords {
    param(
        [string]$ProjectRoot,
        [string]$ProjectName,
        [string[]]$ExcludePrefixes
    )

    $assetsRoot = Join-Path $ProjectRoot 'Assets'
    $records = New-Object System.Collections.Generic.List[object]
    $supportedExtensions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in @('.fbx', '.obj', '.prefab')) {
        [void]$supportedExtensions.Add($extension)
    }

    foreach ($filePath in [System.IO.Directory]::EnumerateFiles($assetsRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $extension = [System.IO.Path]::GetExtension($filePath)
        if (-not $supportedExtensions.Contains($extension)) {
            continue
        }

        $sourcePath = Normalize-Path (Get-RelativePathCompat -BasePath $ProjectRoot -TargetPath $filePath)
        if (-not $sourcePath.StartsWith('Assets/', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if (Test-IsExcludedSourcePath -SourcePath $sourcePath -ExcludePrefixes $ExcludePrefixes) {
            continue
        }

        $pathRelativeToAssets = $sourcePath.Substring('Assets/'.Length)
        $segments = $pathRelativeToAssets.Split('/')
        $topRoot = '_root'
        $relativeFolder = ''
        if ($segments.Length -gt 1) {
            $topRoot = $segments[0]
            if ($segments.Length -gt 2) {
                $relativeFolder = [string]::Join('/', $segments[1..($segments.Length - 2)])
            }
        }

        $records.Add([PSCustomObject]@{
            project_name = $ProjectName
            source_path = $sourcePath
            project_path = (Normalize-Path (Join-Path $ProjectName $sourcePath))
            absolute_path = [System.IO.Path]::GetFullPath($filePath)
            asset_kind = Get-AssetKindFromExtension -Extension $extension
            top_root = $topRoot
            relative_folder = $relativeFolder
            file_name = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
            extension = $extension.ToLowerInvariant()
        })
    }

    return $records | Sort-Object source_path, project_path
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

function Build-InlineCounts {
    param([object[]]$SummaryCounts)

    return (($SummaryCounts | ForEach-Object { '{0} {1}' -f $_.name, $_.count }) -join ', ')
}

function Write-InventoryCsv {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('project_name,source_path,project_path,absolute_path,asset_kind,top_root,relative_folder,file_name,extension') | Out-Null

    foreach ($record in $Records) {
        $fields = @(
            $record.project_name,
            $record.source_path,
            $record.project_path,
            $record.absolute_path,
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

function Write-SearchablePaths {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $content = (($Records | ForEach-Object { $_.absolute_path }) -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8File -Path $Path -Content $content
}

function Write-WorkspaceSearchablePaths {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $sortedRecords = @($Records | Sort-Object project_path, source_path)
    Write-SearchablePaths -Path $Path -Records $sortedRecords
}

function Write-SummaryJson {
    param(
        [string]$Path,
        [string]$WorkspaceRoot,
        [string]$WorkflowRelativePath,
        [string]$ProjectName,
        [string]$UnityProjectRelativePath,
        [string]$OutputRelativePath,
        [string[]]$ExcludePrefixes,
        [object[]]$Records
    )

    $assetKinds = New-SummaryCounts -Records $Records -PropertyName 'asset_kind'
    $topRoots = New-SummaryCounts -Records $Records -PropertyName 'top_root' -ByCountDescending
    $summary = [PSCustomObject]@{
        generatedAt = [DateTimeOffset]::Now.ToString('O')
        workspaceRoot = $WorkspaceRoot
        workflowRoot = $WorkflowRelativePath
        projectName = $ProjectName
        unityProjectPath = $UnityProjectRelativePath
        sourcePath = 'Assets'
        sourceScope = (Normalize-Path (Join-Path $ProjectName 'Assets'))
        outputPath = $OutputRelativePath
        excludePrefixes = @($ExcludePrefixes)
        totalCount = @($Records).Count
        assetKinds = @($assetKinds)
        topRoots = @($topRoots)
    }

    Write-Utf8File -Path $Path -Content ($summary | ConvertTo-Json -Depth 6)
}

function Write-ProjectIndex {
    param(
        [string]$Path,
        [string]$ProjectName,
        [string]$UnityProjectRelativePath,
        [string]$OutputRelativePath,
        [string]$WorkflowRelativePath,
        [string[]]$ExcludePrefixes,
        [object[]]$Records
    )

    $assetKinds = New-SummaryCounts -Records $Records -PropertyName 'asset_kind'
    $topRoots = New-SummaryCounts -Records $Records -PropertyName 'top_root' -ByCountDescending
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# Project Asset Inventory')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('- Generated At: `' + [DateTimeOffset]::Now.ToString('O') + '`')
    [void]$builder.AppendLine('- Project Name: `' + $ProjectName + '`')
    [void]$builder.AppendLine('- Unity Project Path: `' + $UnityProjectRelativePath + '`')
    [void]$builder.AppendLine('- Source Scope: `' + (Normalize-Path (Join-Path $ProjectName 'Assets')) + '`')
    [void]$builder.AppendLine('- Output Path: `' + $OutputRelativePath + '`')
    [void]$builder.AppendLine('- Workflow Root: `' + $WorkflowRelativePath + '`')
    [void]$builder.AppendLine('- Total Assets: `' + @($Records).Count + '`')
    [void]$builder.AppendLine('- Asset Kinds: `' + (Build-InlineCounts -SummaryCounts $assetKinds) + '`')
    [void]$builder.AppendLine('- Exclude Prefixes: `' + (($ExcludePrefixes | Sort-Object) -join ', ') + '`')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Output Files')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('- [project_inventory.csv](project_inventory.csv)')
    [void]$builder.AppendLine('- [project_inventory_paths.txt](project_inventory_paths.txt)')
    [void]$builder.AppendLine('- [scan_summary.json](scan_summary.json)')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Search')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('- Use project_inventory_paths.txt for single-file Ctrl+F path search with absolute filesystem paths.')
    [void]$builder.AppendLine('- Use project_inventory.csv when you also need asset kind, top-level root metadata, or absolute filesystem paths.')
    [void]$builder.AppendLine()
    [void]$builder.AppendLine('## Top Roots')
    [void]$builder.AppendLine()
    foreach ($topRoot in $topRoots) {
        [void]$builder.AppendLine('- ' + $topRoot.name + ': `' + $topRoot.count + '`')
    }

    Write-Utf8File -Path $Path -Content $builder.ToString()
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $workflowRoot = Split-Path -Parent $PSScriptRoot
    $WorkspaceRoot = Split-Path -Parent $workflowRoot
}

if ([string]::IsNullOrWhiteSpace($OutputLabel)) {
    $OutputLabel = Get-Date -Format 'yyyyMMdd'
}

$configPaths = Resolve-ConfigPaths -ExplicitPath $ConfigPath -ScriptRoot $PSScriptRoot
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$WorkflowRelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $PSScriptRoot)
$OutputRoot = Join-Path $WorkspaceRoot $OutputLabel
$projectOverrides = Get-ProjectOverrides -Paths $configPaths
$projects = @(Get-DiscoveredUnityProjects -RootPath $WorkspaceRoot -OutputLabel $OutputLabel)

if (@($projects).Count -eq 0) {
    Write-Warning ('No Unity projects were discovered under ' + $WorkspaceRoot)
    return
}

$resolvedProjects = @()
$outputNameMap = @{}
foreach ($project in $projects) {
    $override = $projectOverrides[$project.RelativePath]
    $outputName = $project.Name
    $excludePrefixes = @()
    if ($null -ne $override) {
        if (-not [string]::IsNullOrWhiteSpace($override.OutputName)) {
            $outputName = [string]$override.OutputName
        }
        if ($null -ne $override.Exclude) {
            $excludePrefixes = @($override.Exclude)
        }
    }

    if ($outputNameMap.ContainsKey($outputName)) {
        throw 'Duplicate output_name detected: ' + $outputName
    }

    $outputNameMap[$outputName] = $project.RelativePath
    $resolvedProjects += [PSCustomObject]@{
        ProjectName = $outputName
        FullPath = $project.FullPath
        RelativePath = $project.RelativePath
        ExcludePrefixes = $excludePrefixes
    }
}

$allRecords = New-Object System.Collections.Generic.List[object]
foreach ($project in $resolvedProjects) {
    $records = @(Get-InventoryRecords -ProjectRoot $project.FullPath -ProjectName $project.ProjectName -ExcludePrefixes $project.ExcludePrefixes)
    foreach ($record in $records) {
        $allRecords.Add($record) | Out-Null
    }
    $projectOutputRoot = Join-Path $OutputRoot $project.ProjectName
    $docsRoot = Join-Path $projectOutputRoot '_docs'
    if (-not (Test-Path -LiteralPath $docsRoot)) {
        New-Item -ItemType Directory -Path $docsRoot -Force | Out-Null
    }

    $outputRelativePath = Normalize-Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $projectOutputRoot)
    Write-InventoryCsv -Path (Join-Path $docsRoot 'project_inventory.csv') -Records $records
    Write-SearchablePaths -Path (Join-Path $docsRoot 'project_inventory_paths.txt') -Records $records
    Write-SummaryJson -Path (Join-Path $docsRoot 'scan_summary.json') -WorkspaceRoot $WorkspaceRoot -WorkflowRelativePath $WorkflowRelativePath -ProjectName $project.ProjectName -UnityProjectRelativePath $project.RelativePath -OutputRelativePath $outputRelativePath -ExcludePrefixes $project.ExcludePrefixes -Records $records
    Write-ProjectIndex -Path (Join-Path $docsRoot 'project_index.md') -ProjectName $project.ProjectName -UnityProjectRelativePath $project.RelativePath -OutputRelativePath $outputRelativePath -WorkflowRelativePath $WorkflowRelativePath -ExcludePrefixes $project.ExcludePrefixes -Records $records

    Write-Output ('Generated ' + $project.ProjectName + ': ' + $records.Count + ' assets -> ' + $outputRelativePath)
}

$workspaceRecords = @($allRecords | Sort-Object project_path, source_path)
Write-InventoryCsv -Path (Join-Path $OutputRoot 'project_inventory.csv') -Records $workspaceRecords
Write-WorkspaceSearchablePaths -Path (Join-Path $OutputRoot 'project_inventory_paths.txt') -Records $workspaceRecords
