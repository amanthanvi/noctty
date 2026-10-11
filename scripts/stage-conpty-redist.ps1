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
# packaging uses. Exits 3 when the package could not be fetched, which the
# build tolerates; every other failure, a hash or PE mismatch included, is
# fatal.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.IO.Compression.FileSystem
. (Join-Path $PSScriptRoot "windows-architecture.ps1")
. (Join-Path $PSScriptRoot "conpty-redist.ps1")

# Builds in several worktrees share the Zig global cache, and two first-time
# downloads would race to move the package into it. A mutex that an elevated
# build created can refuse a normal one; that build then runs unserialized,
# and the race costs at most a rebuild.
try {
    $mutex = [System.Threading.Mutex]::new($false, "Local\noctty-stage-conpty-redist")
}
catch [System.UnauthorizedAccessException] {
    $mutex = $null
}
$owned = $false
try {
    if ($mutex) {
        try {
            $owned = $mutex.WaitOne([TimeSpan]::FromMinutes(2))
        }
        catch [System.Threading.AbandonedMutexException] {
            # A build was killed mid-stage; the mutex is ours and the helper
            # re-verifies everything it finds.
            $owned = $true
        }
        if (-not $owned) {
            Write-Warning "Another build has been staging the bundled ConPTY for two minutes."
            exit 3
        }
    }
    $staged = Install-ConPtyRedist `
        -PinPath (Join-Path $PSScriptRoot "..\dist\windows\conpty-redist.json") `
        -Architecture $Architecture `
        -Destination $Destination `
        -CacheRoot $CacheRoot
}
finally {
    if ($owned) {
        $mutex.ReleaseMutex()
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}
if (-not $staged) {
    exit 3
}
