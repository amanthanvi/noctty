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
$redirectedHarness = Join-Path $repoRoot 'test\windows\cli-redirected-text-action.ps1'
$detachedHarness = Join-Path $repoRoot 'test\windows\cli-detached-action.ps1'

$stageBase = Join-Path $repoRoot ("dist\artifacts\koreterm-{0}-windows-{1}" -f $Version, $Architecture)
$portableRoot = Join-Path $stageBase 'koreterm'
$portableExe = Join-Path $portableRoot 'koreterm.exe'
$portableCommand = Join-Path $portableRoot 'koreterm.com'
$portableResources = Join-Path $portableRoot 'share\ghostty'

if (-not $SkipPackage) {
    & $packageScript -Version $Version -Architecture $Architecture
}

foreach ($path in @($portableRoot, $portableExe, $portableCommand, $portableResources)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing packaged portable artifact path: $path"
    }
}

# The portable ZIP's ghostty-vt.dll is the placeholder, not libghostty-vt: it
# fails to load with ERROR_DLL_INIT_FAILED, exports nothing and says what it
# is in its version resource.
. (Join-Path $repoRoot 'scripts\ghostty-vt-stub.ps1')
$dllSmoke = Join-Path $stageBase 'test_dll_init.exe'
& zig cc (Join-Path $PSScriptRoot 'test_dll_init.c') -lshell32 -lversion -o $dllSmoke
if ($LASTEXITCODE -ne 0) { throw "Packaged DLL smoke compilation failed: $LASTEXITCODE" }
& $dllSmoke (Join-Path $portableRoot 'ghostty-vt.dll') $GhosttyVtStubDescription
if ($LASTEXITCODE -ne 0) { throw "Packaged DLL smoke failed: $LASTEXITCODE" }

& $shellHarness `
    -Shell cmd `
    -BinDir $portableRoot `
    -Arguments @('+help') `
    -ExpectedText 'Usage: koreterm [+action] [options]'

& $shellHarness `
    -Shell powershell `
    -BinDir $portableRoot `
    -Arguments @('+version') `
    -ExpectedText 'Build Config'

& $shellHarness `
    -Shell cmd `
    -BinDir $portableRoot `
    -Arguments @('+version') `
    -ExpectedText '- channel:'

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

& $redirectedHarness `
    -ExePath $portableExe `
    -Action '+help' `
    -ExpectedText 'Usage: koreterm [+action] [options]'

& $detachedHarness `
    -ExePath $portableExe `
    -Action '+version' `
    -ResourcesDir $portableResources

Write-Host "portable package CLI validation: PASS (root=$portableRoot)"
