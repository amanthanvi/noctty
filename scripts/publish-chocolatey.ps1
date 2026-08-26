#requires -Version 5.1
<#
.SYNOPSIS
  Push the winghostty Chocolatey package (C30).

.DESCRIPTION
  Rewrites chocolatey/winghostty.nuspec + chocolateyinstall.ps1 for the
  given version and installer URL, then choco pack. Submit is skipped
  unless CHOCO_API_KEY is set — same pattern as the WinGet bootstrap
  gate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallerUrl,
    [Parameter(Mandatory = $true)][string]$Sha256,
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$nuspec = Join-Path $repoRoot "chocolatey\winghostty.nuspec"
$install = Join-Path $repoRoot "chocolatey\tools\chocolateyinstall.ps1"
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "dist\chocolatey" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$nuspecText = Get-Content -LiteralPath $nuspec -Raw
$nuspecText = $nuspecText -replace '<version>0\.0\.0</version>', "<version>$Version</version>"
$nuspecOut = Join-Path $OutDir "winghostty.nuspec"
Set-Content -LiteralPath $nuspecOut -Value $nuspecText -Encoding UTF8

$toolsOut = Join-Path $OutDir "tools"
New-Item -ItemType Directory -Path $toolsOut -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot "chocolatey\tools\chocolateyuninstall.ps1") -Destination $toolsOut -Force
$installText = Get-Content -LiteralPath $install -Raw
$installText = $installText.Replace('v0.0.0/winghostty-0.0.0-windows-x64-setup.exe', "v$Version/winghostty-$Version-windows-x64-setup.exe")
$installText = $installText.Replace($InstallerUrl, $InstallerUrl)
$installText = $installText.Replace('0000000000000000000000000000000000000000000000000000000000000000', $Sha256)
if ($InstallerUrl -and $installText -notmatch [regex]::Escape($InstallerUrl)) {
    $installText = $installText -replace "https://github.com/amanthanvi/winghostty/releases/download/v[\d.]+/winghostty-[\d.]+-windows-x64-setup.exe", $InstallerUrl
}
Set-Content -LiteralPath (Join-Path $toolsOut "chocolateyinstall.ps1") -Value $installText -Encoding UTF8

Write-Host "Chocolatey staging written to $OutDir"
if (-not $env:CHOCO_API_KEY) {
    Write-Host "Skipping choco push: CHOCO_API_KEY is not configured."
    return
}
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Skipping choco push: choco is not on PATH."
    return
}
Push-Location $OutDir
try {
    & choco pack winghostty.nuspec
    if ($LASTEXITCODE -ne 0) { throw "choco pack failed" }
    $nupkg = Get-ChildItem -Filter "winghostty.$Version.nupkg" | Select-Object -First 1
    if (-not $nupkg) { throw "nupkg not produced" }
    & choco push $nupkg.FullName --source https://push.chocolatey.org/ --api-key $env:CHOCO_API_KEY
    if ($LASTEXITCODE -ne 0) { throw "choco push failed" }
} finally {
    Pop-Location
}
