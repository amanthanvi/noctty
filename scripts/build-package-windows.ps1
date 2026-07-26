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
. (Join-Path $PSScriptRoot "windows-architecture.ps1")

$archInfo = Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

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
    & zig @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed for $($archInfo.Name) with exit code $LASTEXITCODE."
    }

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
