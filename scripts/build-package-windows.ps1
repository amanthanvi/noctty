[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Architecture = $null,

    [ValidateSet("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")]
    [string]$Optimize,

    [switch]$RequireInstaller,

    [switch]$RequireSigning,

    [switch]$RequireConPty,

    [switch]$RequireSymbols
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "windows-architecture.ps1")
. (Join-Path $PSScriptRoot "windows-build-capabilities.ps1")

$archInfo = Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })
$repoRoot = Get-RepoRoot
$zigOutBin = Join-Path $repoRoot "zig-out/bin"
$buildCapabilitiesPath = Join-Path $zigOutBin "noctty-build-capabilities.json"
# Paths under zig-out\bin, as in scripts/package-windows.ps1.
$runtimeFiles = @(
    "noctty.com",
    "noctty.exe",
    # Nothing under the retired name ghostty-vt.dll: v1.4.100 dropped the
    # placeholder the portable ZIP carried there, and zig-out\bin\ghostty-vt.dll,
    # the -Demit-lib-vt=true library, never ships
    # (portable_zip_carries_legacy_entries in src/update/portable_apply.zig).
    "noctty-terminal-handoff-proxy.dll"
)

Push-Location $repoRoot
try {
    if ([string]::IsNullOrWhiteSpace($Optimize)) {
        Write-Warning "-Optimize was omitted; packaging a Debug build. Pass -Optimize ReleaseFast for release parity."
    }
    $buildArgs = @(
        "build",
        "-Demit-exe=true",
        "-Dtarget=$($archInfo.ZigTarget)",
        "-Dcpu=baseline",
        "-Dstrip=false",
        "-Dcustom-shaders=true",
        "-Dversion-string=$Version"
    )
    if (-not [string]::IsNullOrWhiteSpace($Optimize)) {
        $buildArgs += "-Doptimize=$Optimize"
    }

    Write-Host "Build phase: $($archInfo.Name) ($($archInfo.ZigTarget))"
    Remove-Item -LiteralPath $buildCapabilitiesPath -Force -ErrorAction SilentlyContinue
    & zig @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed for $($archInfo.Name) with exit code $LASTEXITCODE."
    }
    Write-WindowsBuildCapabilitiesManifest `
        -Path $buildCapabilitiesPath `
        -BinPath $zigOutBin `
        -Version $Version `
        -Architecture $archInfo.Name `
        -RuntimeFiles $runtimeFiles

    $packageArgs = @{
        Version = $Version
        Architecture = $archInfo.Name
        SkipBuild = $true
    }
    if ($RequireInstaller) {
        $packageArgs.RequireInstaller = $true
    }
    if ($RequireSigning) {
        $packageArgs.RequireSigning = $true
    }
    if ($RequireConPty) {
        $packageArgs.RequireConPty = $true
    }
    if ($RequireSymbols) {
        $packageArgs.RequireSymbols = $true
    }

    Write-Host "Package phase: $($archInfo.Name)"
    & (Join-Path $repoRoot "scripts/package-windows.ps1") @packageArgs
    if ($LASTEXITCODE -ne 0) {
        throw "package-windows.ps1 failed for $($archInfo.Name) with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
