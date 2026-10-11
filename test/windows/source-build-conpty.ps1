[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",

    [string]$BinPath = "zig-out\bin"
)

# Checks that `zig build` staged the pinned bundled ConPTY pair beside
# noctty.exe (src/build/ConptyRedist.zig), with the release helper's own hash
# and PE checks. On a native build it also checks that noctty selects it.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot "scripts\windows-architecture.ps1")
. (Join-Path $repoRoot "scripts\conpty-redist.ps1")

$pin = Get-Content -LiteralPath (Join-Path $repoRoot "dist\windows\conpty-redist.json") -Raw | ConvertFrom-Json
$architecturePin = $pin.architectures.PSObject.Properties[$Architecture].Value
$bin = if ([System.IO.Path]::IsPathRooted($BinPath)) { $BinPath } else { Join-Path $repoRoot $BinPath }

foreach ($file in @(
    @{ Name = "conpty.dll"; Sha256 = $architecturePin.conptyDll.sha256 },
    @{ Name = "OpenConsole.exe"; Sha256 = $architecturePin.openConsoleExe.sha256 }
)) {
    $path = Join-Path $bin $file.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "zig build did not stage $path."
    }
    Assert-ConPtySha256 -Path $path -Expected $file.Sha256 -Label $path
    Assert-PeMachine -PathToCheck $path -ExpectedArchitecture $Architecture
}

if ($Architecture -eq (Get-DefaultWindowsPackageArchitecture)) {
    $versionText = & (Join-Path $bin "noctty.com") +version | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "noctty.com +version failed with exit code $LASTEXITCODE."
    }
    if ($versionText -notmatch "ConPTY\s*: bundled \(") {
        throw "The source build did not select the bundled ConPTY:`n$versionText"
    }
}

Write-Host "Source build staged the pinned $Architecture ConPTY pair in $bin."
