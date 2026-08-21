[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$repoRoot = Get-RepoRoot

& node (Join-Path $PSScriptRoot 'build-site-bundle.mjs') --check
if ($LASTEXITCODE -ne 0) {
    throw "Deterministic site bundle check failed with exit code $LASTEXITCODE. Run npm --prefix site run build."
}

Write-Host 'Deterministic site bundle and SHA-256 cache-key check passed.' -ForegroundColor Green
