[CmdletBinding()]
param(
    [string]$Remote = 'upstream',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$upstreamRef = "$Remote/$Branch"

$head = & git -C $repoRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'git rev-parse failed for HEAD' }
$head = "$head".Trim()

# A fresh clone has only `origin`, so this is the expected first-run state.
# Say what to do about it instead of failing deep inside a git plumbing call.
& git -C $repoRoot rev-parse --verify --quiet "$upstreamRef^{commit}" > $null
if ($LASTEXITCODE -ne 0) {
    & git -C $repoRoot remote get-url $Remote > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        $remoteUrl = if ($Remote -eq 'upstream') { 'https://github.com/ghostty-org/ghostty.git' } else { '<url>' }
        Write-Host "No local ref '$upstreamRef' and no remote '$Remote'. This script never fetches; create the read-only remote and refresh it first:" -ForegroundColor Yellow
        Write-Host "  git remote add $Remote $remoteUrl"
        Write-Host "  git remote set-url --push $Remote DISABLED"
    } else {
        Write-Host "No local ref '$upstreamRef'. This script never fetches; refresh remote '$Remote' first:" -ForegroundColor Yellow
    }
    Write-Host "  git fetch $Remote"
    Write-Host "Then confirm '$upstreamRef' exists with: git rev-parse --verify $upstreamRef"
    exit 1
}

$base = & git -C $repoRoot merge-base $head $upstreamRef
if ($LASTEXITCODE -ne 0) { throw "git merge-base failed for $upstreamRef" }
$base = "$base".Trim()

$baseDate = & git -C $repoRoot show -s --format='%cs' $base
if ($LASTEXITCODE -ne 0) { throw 'git show failed for the merge base' }
$baseDate = "$baseDate".Trim()

$countText = & git -C $repoRoot rev-list --left-right --count "$head...$upstreamRef"
if ($LASTEXITCODE -ne 0) { throw "git rev-list failed for $upstreamRef" }
$counts = "$countText".Trim() -split '\s+'

$metadataText = @(
    & git -C $repoRoot show "${head}:dist/windows/release-metadata.json"
) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'git show failed for release-metadata.json' }
$metadata = $metadataText | ConvertFrom-Json

$forkPaths = @(& git -C $repoRoot diff --name-only "$base..$head")
if ($LASTEXITCODE -ne 0) { throw 'git diff failed for fork paths' }
$upstreamPaths = @(& git -C $repoRoot diff --name-only "$base..$upstreamRef")
if ($LASTEXITCODE -ne 0) { throw 'git diff failed for upstream paths' }
$forkDeleted = @(& git -C $repoRoot diff --diff-filter=D --name-only "$base..$head")
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

Write-Output "Analyzed head: $head"
Write-Output "Merge base: $base ($baseDate)"
Write-Output "Ahead/behind: $($counts[0]) / $($counts[1])"
Write-Output "Recorded upstreamBaseVersion: $($metadata.upstreamBaseVersion)"
Write-Output "Live overlap ($($liveOverlap.Count)):"
$liveOverlap
