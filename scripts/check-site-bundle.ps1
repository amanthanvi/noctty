[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

& node (Join-Path $PSScriptRoot 'build-site-bundle.mjs')
if ($LASTEXITCODE -ne 0) {
    throw "Site bundle build failed with exit code $LASTEXITCODE."
}

& git -C $repoRoot diff --exit-code -- site/bundle.js
if ($LASTEXITCODE -ne 0) {
    throw 'site/bundle.js is stale. Run npm --prefix site run build and commit the generated bundle.'
}

Write-Host 'Deterministic site bundle check passed.' -ForegroundColor Green
