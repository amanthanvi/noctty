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

# Builds in several worktrees share the Zig global cache, and two first-time
# downloads would race to move the package into it.
$mutex = [System.Threading.Mutex]::new($false, "Local\noctty-stage-conpty-redist")
try {
    try {
        [void]$mutex.WaitOne()
    }
    catch [System.Threading.AbandonedMutexException] {
        # A build was killed mid-stage; the mutex is ours and the helper
        # re-verifies everything it finds.
    }
    try {
        $staged = Install-ConPtyRedist `
            -PinPath (Join-Path $PSScriptRoot "..\dist\windows\conpty-redist.json") `
            -Architecture $Architecture `
            -Destination $Destination `
            -CacheRoot $CacheRoot
    }
    finally {
        $mutex.ReleaseMutex()
    }
}
finally {
    $mutex.Dispose()
}
if (-not $staged) {
    exit 3
}
