[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Architecture = $null,

    [ValidateSet("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")]
    [string]$Optimize,

    [switch]$RequireInstaller,

    [switch]$RequireSigning
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
    "ghostty-vt.dll"
)

Push-Location $repoRoot
try {
    $buildArgs = @(
        "build",
        "-Demit-exe=true",
        "-Demit-lib-vt=true",
        "-Dtarget=$($archInfo.ZigTarget)",
        "-Dcpu=baseline",
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

    Write-Host "Package phase: $($archInfo.Name)"
    & (Join-Path $repoRoot "scripts/package-windows.ps1") @packageArgs
    if ($LASTEXITCODE -ne 0) {
        throw "package-windows.ps1 failed for $($archInfo.Name) with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
