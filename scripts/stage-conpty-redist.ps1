[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $true)]
    [string]$CacheRoot
)

# Stages the pinned bundled ConPTY pair for `zig build`
# (src/build/ConptyRedist.zig) with the same Install-ConPtyRedist that release
# packaging uses. Exits 3 when the package could not be downloaded, which the
# build tolerates; every other failure, a hash or PE mismatch included, is
# fatal.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot "windows-architecture.ps1")
. (Join-Path $PSScriptRoot "conpty-redist.ps1")

$staged = Install-ConPtyRedist `
    -PinPath (Join-Path $PSScriptRoot "..\dist\windows\conpty-redist.json") `
    -Architecture $Architecture `
    -Destination $Destination `
    -CacheRoot $CacheRoot
if (-not $staged) {
    exit 3
}
