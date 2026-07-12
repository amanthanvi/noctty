[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$common = @{
    ResetState = $ResetState
}

if ($Rebuild) {
    & (Join-Path $repoRoot 'scripts\dev-windows.cmd') zig build -Demit-exe=true
    if ($LASTEXITCODE -ne 0) { throw "PR smoke build failed with exit code $LASTEXITCODE." }
}

foreach ($harness in @(
    'interactive-win11-smoke.ps1',
    'interactive-win11-key-input.ps1',
    'interactive-win11-new-tab.ps1',
    'interactive-win11-resize.ps1',
    'interactive-win11-undo.ps1',
    'interactive-win11-accessibility.ps1',
    'interactive-win11-palette-theme.ps1',
    'interactive-win11-session-restore.ps1'
)) {
    & (Join-Path $PSScriptRoot $harness) @common
    if ($LASTEXITCODE -ne 0) { throw "$harness failed with exit code $LASTEXITCODE." }
}

Write-Host 'interactive Win11 PR smoke: PASS' -ForegroundColor Green
