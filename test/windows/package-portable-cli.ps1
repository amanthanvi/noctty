param(
    [string] $Version = '0.0.1',
    [string] $Architecture = $null,
    [switch] $SkipPackage
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\windows-architecture.ps1')
$Architecture = (Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })).Name
$packageScript = Join-Path $repoRoot 'scripts\package-windows.ps1'
$shellHarness = Join-Path $repoRoot 'test\windows\cli-shell-command.ps1'
$detachedHarness = Join-Path $repoRoot 'test\windows\cli-detached-action.ps1'

$stageBase = Join-Path $repoRoot ("dist\artifacts\winghostty-{0}-windows-{1}" -f $Version, $Architecture)
$portableRoot = Join-Path $stageBase 'winghostty'
$portableExe = Join-Path $portableRoot 'winghostty.exe'
$portableCommand = Join-Path $portableRoot 'winghostty.com'
$portableResources = Join-Path $portableRoot 'share\ghostty'

if (-not $SkipPackage) {
    & $packageScript -Version $Version -Architecture $Architecture
}

foreach ($path in @($portableRoot, $portableExe, $portableCommand, $portableResources)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing packaged portable artifact path: $path"
    }
}

& $shellHarness `
    -Shell cmd `
    -BinDir $portableRoot `
    -Arguments @('+help') `
    -ExpectedText 'Usage: winghostty [+action] [options]'

& $shellHarness `
    -Shell powershell `
    -BinDir $portableRoot `
    -Arguments @('+version') `
    -ExpectedText 'Build Config'

& $shellHarness `
    -Shell cmd `
    -BinDir $portableRoot `
    -Arguments @('+boo', '--help') `
    -ExpectedText 'The `boo` command is used to display the project animation in the terminal.'

& $shellHarness `
    -Shell powershell `
    -BinDir $portableRoot `
    -Arguments @('+list-keybinds') `
    -ExpectedText 'keybind = ctrl+shift+,=reload_config'

& $shellHarness `
    -Shell cmd `
    -BinDir $portableRoot `
    -Arguments @('+list-colors') `
    -ExpectedText 'alice blue = #f0f8ff'

& $shellHarness `
    -Shell powershell `
    -BinDir $portableRoot `
    -Arguments @('+list-themes') `
    -ExpectedText '0x96f (resources)'

& $detachedHarness `
    -ExePath $portableExe `
    -Action '+boo' `
    -ResourcesDir $portableResources

Write-Host "portable package CLI validation: PASS (root=$portableRoot)"
