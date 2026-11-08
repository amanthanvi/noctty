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
$runtimeFiles = @(
    "noctty.com",
    "noctty.exe",
    # Transitional: noctty does not use ghostty-vt.dll (libghostty-vt 0.1.0)
    # and Setup no longer installs it, but the portable updater of 1.3.136
    # and older refuses a portable ZIP without it. Drop it (and
    # -Demit-lib-vt=true) only together with
    # portable_zip_carries_legacy_entries in src/update/portable_apply.zig.
    "ghostty-vt.dll",
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
        "-Demit-lib-vt=true",
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
