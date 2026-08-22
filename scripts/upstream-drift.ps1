[CmdletBinding()]
param(
    [string]$Remote = 'upstream',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$upstreamRef = "$Remote/$Branch"

$base = & git -C $repoRoot merge-base HEAD $upstreamRef
if ($LASTEXITCODE -ne 0) { throw "git merge-base failed for $upstreamRef" }
$base = "$base".Trim()

$baseDate = & git -C $repoRoot show -s --format='%cs' $base
if ($LASTEXITCODE -ne 0) { throw 'git show failed for the merge base' }
$baseDate = "$baseDate".Trim()

$countText = & git -C $repoRoot rev-list --left-right --count "HEAD...$upstreamRef"
if ($LASTEXITCODE -ne 0) { throw "git rev-list failed for $upstreamRef" }
$counts = "$countText".Trim() -split '\s+'

$metadataPath = Join-Path $repoRoot 'dist\windows\release-metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

$forkPaths = @(& git -C $repoRoot diff --name-only "$base..HEAD")
if ($LASTEXITCODE -ne 0) { throw 'git diff failed for fork paths' }
$upstreamPaths = @(& git -C $repoRoot diff --name-only "$base..$upstreamRef")
if ($LASTEXITCODE -ne 0) { throw 'git diff failed for upstream paths' }
$forkDeleted = @(& git -C $repoRoot diff --diff-filter=D --name-only "$base..HEAD")
if ($LASTEXITCODE -ne 0) { throw 'git diff failed for fork deletions' }

$upstreamSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
$deletedSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($path in $upstreamPaths) { [void]$upstreamSet.Add($path) }
foreach ($path in $forkDeleted) { [void]$deletedSet.Add($path) }

$liveOverlap = @(
    $forkPaths |
        Where-Object { $upstreamSet.Contains($_) -and -not $deletedSet.Contains($_) } |
        Sort-Object -Unique
)

Write-Output "Merge base: $base ($baseDate)"
Write-Output "Ahead/behind: $($counts[0]) / $($counts[1])"
Write-Output "Recorded upstreamBaseVersion: $($metadata.upstreamBaseVersion)"
Write-Output "Live overlap ($($liveOverlap.Count)):"
$liveOverlap
