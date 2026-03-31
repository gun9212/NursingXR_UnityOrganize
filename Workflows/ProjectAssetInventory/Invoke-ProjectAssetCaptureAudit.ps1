[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$OutputLabel,
    [int]$DuplicateThreshold = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    $_ | Format-List * -Force
    if ($_.InvocationInfo) {
        $_.InvocationInfo | Format-List * -Force
    }
    exit 1
}


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

function Escape-CsvValue {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ''
    }

    return '"' + $Value.Replace('"', '""') + '"'
}

function Write-IssueCsv {
    param(
        [string]$Path,
        [object[]]$Records
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('project_name,source_path,project_path,capture_path,issue_type,reason,duplicate_count,file_size,foreground_ratio,laplacian_variance,min_margin_ratio,bbox_fill_ratio,asset_kind,top_root,relative_folder,file_name,extension') | Out-Null

    foreach ($record in @($Records)) {
        $fields = @(
            $record.project_name,
            $record.source_path,
            $record.project_path,
            $record.capture_path,
            $record.issue_type,
            $record.reason,
            $record.duplicate_count,
            $record.file_size,
            $record.foreground_ratio,
            $record.laplacian_variance,
            $record.min_margin_ratio,
            $record.bbox_fill_ratio,
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

function Get-ManualReviewBucket {
    param([string]$IssueType)

    $normalizedIssueType = ([string]$IssueType).Trim().ToLowerInvariant()
    switch ($normalizedIssueType) {
        'capture_failed' { return 'manual_capture_required' }
        'blank_or_tiny_subject' { return 'manual_capture_required' }
        'missing_success_output' { return 'manual_review_required' }
        'placeholder_duplicate' { return 'manual_review_required' }
        'composition_retry' { return 'manual_review_required' }
        default { return 'manual_review_required' }
    }
}

function Write-ManualReviewPaths {
    param(
        [string]$Path,
        [string]$OutputRoot,
        [object[]]$Records
    )

    $sortedRecords = @($Records | Sort-Object @{ Expression = { Get-ManualReviewBucket -IssueType $_.issue_type } }, issue_type, capture_path)
    $builder = New-Object System.Text.StringBuilder

    if (@($sortedRecords).Count -eq 0) {
        [void]$builder.AppendLine('=== manual_review_required (0) ===')
        [void]$builder.AppendLine('[none]')
        [void]$builder.AppendLine('No remaining manual review or manual capture paths.')
        Write-Utf8File -Path $Path -Content $builder.ToString()
        return
    }

    foreach ($bucketGroup in ($sortedRecords | Group-Object { Get-ManualReviewBucket -IssueType $_.issue_type })) {
        [void]$builder.AppendLine(('=== {0} ({1}) ===' -f $bucketGroup.Name, @($bucketGroup.Group).Count))
        foreach ($issueTypeGroup in ($bucketGroup.Group | Group-Object issue_type | Sort-Object Name)) {
            [void]$builder.AppendLine(('[' + [string]$issueTypeGroup.Name + ']'))
            foreach ($record in @($issueTypeGroup.Group | Sort-Object capture_path, project_name, source_path)) {
                $absoluteCapturePath = [System.IO.Path]::GetFullPath((Join-Path $OutputRoot ([string]$record.capture_path -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
                $reason = [string]$record.reason
                if ([string]::IsNullOrWhiteSpace($reason)) {
                    [void]$builder.AppendLine($absoluteCapturePath)
                }
                else {
                    [void]$builder.AppendLine(($absoluteCapturePath + ' | reason=' + $reason))
                }
            }

            [void]$builder.AppendLine()
        }
    }

    Write-Utf8File -Path $Path -Content $builder.ToString().TrimEnd() + [Environment]::NewLine
}

function New-SummaryCounts {
    param(
        [object[]]$Records,
        [string]$PropertyName
    )

    return @(
        $Records |
            Group-Object -Property $PropertyName |
            Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
            ForEach-Object {
                [PSCustomObject]@{
                    name = [string]$_.Name
                    count = [int]$_.Count
                }
            }
    )
}

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @"
using System;
using System.Drawing;
public static class CaptureAuditMetrics
{
    public static string Analyze(string path)
    {
        using (var src = new Bitmap(path))
        using (var bmp = new Bitmap(128, 128))
        using (var g = Graphics.FromImage(bmp))
        {
            g.DrawImage(src, 0, 0, 128, 128);

            var c1 = bmp.GetPixel(0, 0);
            var c2 = bmp.GetPixel(127, 0);
            var c3 = bmp.GetPixel(0, 127);
            var c4 = bmp.GetPixel(127, 127);
            double br = (c1.R + c2.R + c3.R + c4.R) / 4.0;
            double bg = (c1.G + c2.G + c3.G + c4.G) / 4.0;
            double bb = (c1.B + c2.B + c3.B + c4.B) / 4.0;

            double[,] gray = new double[128, 128];
            int foregroundCount = 0;
            int minX = 128;
            int minY = 128;
            int maxX = -1;
            int maxY = -1;
            for (int y = 0; y < 128; y++)
            {
                for (int x = 0; x < 128; x++)
                {
                    var color = bmp.GetPixel(x, y);
                    gray[x, y] = color.R * 0.299 + color.G * 0.587 + color.B * 0.114;

                    double dr = color.R - br;
                    double dg = color.G - bg;
                    double db = color.B - bb;
                    double distance = Math.Sqrt(dr * dr + dg * dg + db * db);
                    if (distance > 18.0)
                    {
                        foregroundCount++;
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            double lapSum = 0;
            double lapSq = 0;
            for (int y = 1; y < 127; y++)
            {
                for (int x = 1; x < 127; x++)
                {
                    double value = -gray[x - 1, y] - gray[x + 1, y] - gray[x, y - 1] - gray[x, y + 1] + 4 * gray[x, y];
                    lapSum += value;
                    lapSq += value * value;
                }
            }

            int lapCount = 126 * 126;
            double lapMean = lapSum / lapCount;
            double lapVar = (lapSq / lapCount) - (lapMean * lapMean);
            double foregroundRatio = foregroundCount / 16384.0;
            double minMarginRatio = 0.0;
            double bboxFillRatio = 0.0;
            if (foregroundCount > 0 && maxX >= minX && maxY >= minY)
            {
                double marginLeft = minX / 128.0;
                double marginTop = minY / 128.0;
                double marginRight = (127 - maxX) / 128.0;
                double marginBottom = (127 - maxY) / 128.0;
                minMarginRatio = Math.Min(Math.Min(marginLeft, marginTop), Math.Min(marginRight, marginBottom));
                bboxFillRatio = ((maxX - minX + 1.0) * (maxY - minY + 1.0)) / 16384.0;
            }
            return string.Format("{0:F6}|{1:F2}|{2:F6}|{3:F6}", foregroundRatio, lapVar, minMarginRatio, bboxFillRatio);
        }
    }
}
"@
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $workflowRoot = Split-Path -Parent $PSScriptRoot
    $WorkspaceRoot = Split-Path -Parent $workflowRoot
}

$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$OutputRoot = Join-Path $WorkspaceRoot $OutputLabel
$rootCaptureInventoryPath = Join-Path $OutputRoot 'capture_inventory.csv'

if (-not (Test-Path -LiteralPath $rootCaptureInventoryPath -PathType Leaf)) {
    throw 'Root capture inventory was not found: ' + $rootCaptureInventoryPath
}

$successRows = @(
    Import-Csv -LiteralPath $rootCaptureInventoryPath |
        Where-Object { $_.capture_status -eq 'success' }
)
$nonSuccessRows = @(
    Import-Csv -LiteralPath $rootCaptureInventoryPath |
        Where-Object { $_.capture_status -ne 'success' }
)

$metrics = New-Object System.Collections.Generic.List[object]
foreach ($row in $successRows) {
    $absoluteCapturePath = Join-Path $OutputRoot $row.capture_path
    if (-not (Test-Path -LiteralPath $absoluteCapturePath -PathType Leaf)) {
        continue
    }

    $hash = (Get-FileHash -LiteralPath $absoluteCapturePath -Algorithm SHA256).Hash
    $metricParts = [CaptureAuditMetrics]::Analyze($absoluteCapturePath) -split '\|'
    $metrics.Add([PSCustomObject]@{
        project_name = $row.project_name
        source_path = $row.source_path
        project_path = $row.project_path
        capture_path = $row.capture_path
        asset_kind = $row.asset_kind
        top_root = $row.top_root
        relative_folder = $row.relative_folder
        file_name = $row.file_name
        extension = $row.extension
        hash = $hash
        file_size = (Get-Item -LiteralPath $absoluteCapturePath).Length
        foreground_ratio = [double]$metricParts[0]
        laplacian_variance = [double]$metricParts[1]
        min_margin_ratio = [double]$metricParts[2]
        bbox_fill_ratio = [double]$metricParts[3]
    }) | Out-Null
}

$duplicateCountMap = @{}
foreach ($group in ($metrics | Group-Object hash)) {
    $duplicateCountMap[$group.Name] = $group.Count
}

$issueRecords = New-Object System.Collections.Generic.List[object]
foreach ($row in $successRows) {
    $absoluteCapturePath = Join-Path $OutputRoot $row.capture_path
    if (Test-Path -LiteralPath $absoluteCapturePath -PathType Leaf) {
        continue
    }

    $issueRecords.Add([PSCustomObject]@{
        project_name = $row.project_name
        source_path = $row.source_path
        project_path = $row.project_path
        capture_path = $row.capture_path
        issue_type = 'missing_success_output'
        reason = 'capture_inventory.csv marks success but the PNG file is missing on disk.'
        duplicate_count = 0
        file_size = ''
        foreground_ratio = ''
        laplacian_variance = ''
        min_margin_ratio = ''
        bbox_fill_ratio = ''
        asset_kind = $row.asset_kind
        top_root = $row.top_root
        relative_folder = $row.relative_folder
        file_name = $row.file_name
        extension = $row.extension
    }) | Out-Null
}

foreach ($metric in $metrics) {
    $duplicateCount = [int]$duplicateCountMap[$metric.hash]
    $issueType = ''
    $reason = ''
    $isFlatTiny = $duplicateCount -eq 1 -and $metric.foreground_ratio -le 0.01 -and $metric.laplacian_variance -lt 1.0
    $isSharpButSeverelyTiny = $duplicateCount -eq 1 -and (
        $metric.foreground_ratio -le 0.0015 -or
        $metric.bbox_fill_ratio -le 0.0025
    )
    if ($duplicateCount -ge $DuplicateThreshold) {
        $issueType = 'placeholder_duplicate'
        $reason = 'Identical PNG reused across many different assets; likely generic AssetPreview or mini thumbnail.'
    }
    elseif ($isFlatTiny -or $isSharpButSeverelyTiny) {
        $issueType = 'blank_or_tiny_subject'
        $reason = 'Rendered subject occupies too few pixels to read clearly, even if some edges remain sharp; camera framing or renderer/material visibility is likely wrong.'
    }
    elseif ($duplicateCount -eq 1 -and $metric.foreground_ratio -ge 0.02 -and ($metric.min_margin_ratio -le 0.015 -or $metric.bbox_fill_ratio -ge 0.88)) {
        $issueType = 'composition_retry'
        $reason = 'Upper-diagonal framing still clips or overfills the visible subject; rerun with alternate composition before manual review.'
    }
    if ([string]::IsNullOrWhiteSpace($issueType)) {
        continue
    }

    $issueRecords.Add([PSCustomObject]@{
        project_name = $metric.project_name
        source_path = $metric.source_path
        project_path = $metric.project_path
        capture_path = $metric.capture_path
        issue_type = $issueType
        reason = $reason
        duplicate_count = $duplicateCount
        file_size = $metric.file_size
        foreground_ratio = ('{0:F6}' -f $metric.foreground_ratio)
        laplacian_variance = ('{0:F2}' -f $metric.laplacian_variance)
        min_margin_ratio = ('{0:F6}' -f $metric.min_margin_ratio)
        bbox_fill_ratio = ('{0:F6}' -f $metric.bbox_fill_ratio)
        asset_kind = $metric.asset_kind
        top_root = $metric.top_root
        relative_folder = $metric.relative_folder
        file_name = $metric.file_name
        extension = $metric.extension
    }) | Out-Null
}

$sortedIssueRecords = @($issueRecords | Sort-Object project_name, issue_type, source_path)
$rootIssuePath = Join-Path $OutputRoot 'capture_quality_issues.csv'
Write-IssueCsv -Path $rootIssuePath -Records $sortedIssueRecords
$manualReviewRecords = New-Object System.Collections.Generic.List[object]
foreach ($issueRecord in $sortedIssueRecords) {
    $manualReviewRecords.Add($issueRecord) | Out-Null
}

foreach ($row in $nonSuccessRows) {
    $manualReviewRecords.Add([PSCustomObject]@{
            project_name = $row.project_name
            source_path = $row.source_path
            project_path = $row.project_path
            capture_path = $row.capture_path
            issue_type = 'capture_failed'
            reason = if ([string]::IsNullOrWhiteSpace([string]$row.error)) { 'Capture did not complete successfully.' } else { [string]$row.error }
            duplicate_count = ''
            file_size = ''
            foreground_ratio = ''
            laplacian_variance = ''
            min_margin_ratio = ''
            bbox_fill_ratio = ''
            asset_kind = $row.asset_kind
            top_root = $row.top_root
            relative_folder = $row.relative_folder
            file_name = $row.file_name
            extension = $row.extension
        }) | Out-Null
}

$manualReviewRecordsArray = @($manualReviewRecords.ToArray())
Write-ManualReviewPaths -Path (Join-Path $OutputRoot 'capture_manual_review_paths.txt') -OutputRoot $OutputRoot -Records $manualReviewRecordsArray

foreach ($projectGroup in ($sortedIssueRecords | Group-Object project_name)) {
    $projectDocsRoot = Join-Path (Join-Path $OutputRoot $projectGroup.Name) '_docs'
    if (-not (Test-Path -LiteralPath $projectDocsRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $projectDocsRoot -Force | Out-Null
    }

    Write-IssueCsv -Path (Join-Path $projectDocsRoot 'capture_quality_issues.csv') -Records @($projectGroup.Group | Sort-Object issue_type, source_path)
}

$totalAnalyzed = $metrics.Count
$totalIssues = @($sortedIssueRecords).Count
$issueTypeSummary = @(New-SummaryCounts -Records $sortedIssueRecords -PropertyName 'issue_type')
$projectSummary = @(New-SummaryCounts -Records $sortedIssueRecords -PropertyName 'project_name')

$summary = New-Object PSObject
$summary | Add-Member -NotePropertyName generatedAt -NotePropertyValue ([DateTimeOffset]::Now.ToString('O'))
$summary | Add-Member -NotePropertyName workspaceRoot -NotePropertyValue $WorkspaceRoot
$summary | Add-Member -NotePropertyName outputRoot -NotePropertyValue (Normalize-Path -Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $OutputRoot))
$summary | Add-Member -NotePropertyName totalAnalyzed -NotePropertyValue $totalAnalyzed
$summary | Add-Member -NotePropertyName totalIssues -NotePropertyValue $totalIssues
$summary | Add-Member -NotePropertyName issueTypes -NotePropertyValue $issueTypeSummary
$summary | Add-Member -NotePropertyName projects -NotePropertyValue $projectSummary


Write-Utf8File -Path (Join-Path $OutputRoot 'capture_quality_summary.json') -Content ($summary | ConvertTo-Json -Depth 5)

$rootIssueRelativePath = Normalize-Path -Path (Get-RelativePathCompat -BasePath $WorkspaceRoot -TargetPath $rootIssuePath)
Write-Output ("Audited capture quality: {0} images, {1} issues -> {2}" -f $totalAnalyzed, $totalIssues, $rootIssueRelativePath)

