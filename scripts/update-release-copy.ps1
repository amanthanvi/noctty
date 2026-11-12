[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string] $PublishedDate,

    [switch] $SkipSiteBuild
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$repoRoot = Get-RepoRoot
$readmePath = Join-Path $repoRoot 'README.md'
$readme = [System.IO.File]::ReadAllText($readmePath)
if ($readme -notmatch 'koreterm\s+(?<version>\d+\.\d+\.\d+)\]\(https://github\.com/amanthanvi/koreterm/releases/tag/v\k<version>\)') {
    throw 'Could not determine the current release version from README.md.'
}
$previous = $Matches.version

foreach ($relative in @(
    'README.md',
    'docs/getting-started.md',
    'site/index.html',
    'site/version.js'
)) {
    $path = Join-Path $repoRoot $relative
    $text = [System.IO.File]::ReadAllText($path).Replace($previous, $Version)
    if ($relative -eq 'README.md') {
        $text = [regex]::Replace($text, 'published \d{4}-\d{2}-\d{2}\.', "published $PublishedDate.", 1)
    }
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

# The trust page also names older versions on purpose (the verifier floor v1.3.124,
# the legacy v1.3.123 path), so only its two latest-release elements are rewritten.
$trustPath = Join-Path $repoRoot 'site/why-koreterm.html'
$trust = [System.IO.File]::ReadAllText($trustPath)
$trust = [regex]::Replace($trust, '(id="nc-version">v)\d+\.\d+\.\d+', "`${1}$Version", 1)
$trust = [regex]::Replace($trust, '(id="nc-version-summary">Version )\d+\.\d+\.\d+', "`${1}$Version", 1)
[System.IO.File]::WriteAllText($trustPath, $trust, [System.Text.UTF8Encoding]::new($false))

if (-not $SkipSiteBuild) {
    & node (Join-Path $repoRoot 'scripts/build-site-assets.mjs')
    if ($LASTEXITCODE -ne 0) { throw "Site asset refresh failed with exit code $LASTEXITCODE." }
}

& (Join-Path $PSScriptRoot 'check-release-copy.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Generated release copy failed local consistency checks.' }
Write-Host "Release copy updated: $previous -> $Version ($PublishedDate)." -ForegroundColor Green
