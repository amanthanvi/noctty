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
if ($readme -notmatch 'noctty\s+(?<version>\d+\.\d+\.\d+)\]\(https://github\.com/amanthanvi/noctty/releases/tag/v\k<version>\)') {
    throw 'Could not determine the current release version from README.md.'
}
$previous = $Matches.version

foreach ($relative in @(
    'README.md',
    'docs/getting-started.md',
    'site/index.html',
    'site/version.js',
    'site/terminal.js'
)) {
    $path = Join-Path $repoRoot $relative
    $text = [System.IO.File]::ReadAllText($path).Replace($previous, $Version)
    if ($relative -eq 'README.md') {
        $text = [regex]::Replace($text, 'published \d{4}-\d{2}-\d{2}\.', "published $PublishedDate.", 1)
    }
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

if (-not $SkipSiteBuild) {
    & node (Join-Path $repoRoot 'scripts/build-site-assets.mjs')
    if ($LASTEXITCODE -ne 0) { throw "Site asset refresh failed with exit code $LASTEXITCODE." }
}

& (Join-Path $PSScriptRoot 'check-release-copy.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Generated release copy failed local consistency checks.' }
Write-Host "Release copy updated: $previous -> $Version ($PublishedDate)." -ForegroundColor Green
