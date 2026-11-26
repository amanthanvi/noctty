#requires -Version 7.0
<#
.SYNOPSIS
Fails when a build configure writes the configurer's environment into the build cache.

.DESCRIPTION
ZIG017-RUN-ENV-01 (docs/agents/log/build-release-ci.md): on Zig 0.17 a Run step that sets an environment
variable copies the configurer's whole environment into the step, and the configure process writes the
step, that copy included, into the cached build configuration under `.zig-cache`. Contracts.21 refuses
the calls in the fork's build files; this check covers the rest end to end, the dependencies' own build
scripts included, which configure in the same process.

It sets a variable named NOCTTY_CONFIGURE_SENTINEL to a fixed sentinel value (no secret), configures
the build with each set of options given (`zig build <options> --print-configuration-path`, which
configures and builds nothing), and searches every file under the local cache for the sentinel's
bytes. It prints the names of the files that hold it, never their contents, and exits 1 when any does.

By default it configures two of the three option sets CI's windows-lib-vt job builds with: the
default build and lib-vt (`-Demit-lib-vt=true`). Not covered (council F9): the differential
oracle's set (`oracle -Dvt-api=v140 -Dsimd=true -Doptimize=ReleaseFast -Dcpu=baseline
-Dcustom-shaders=true`, the job's oracle step). The oracle's argument guard
(`test/differential-oracle/build_args.py`) refuses any option outside its allowlist, so a
configure-only `--print-configuration-path` run of that set fails before it writes anything (measured
at 1B.5). A configure only reaches the build-script code its options select, so the oracle's
configure-time code (`src/differential_oracle_build.zig`, which Contracts.21 reads) is checked by
source only.

Run it on a checkout whose local cache holds no configuration from a run without the sentinel (CI's
fresh checkout), or give -CacheDir a fresh directory: a configure the cache already holds is not run
again.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    # Each entry is one configure's options, space-separated.
    [string[]] $Configure = @('', '-Demit-lib-vt=true'),
    [string] $CacheDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sentinel = 'noctty-configure-sentinel-7c1e5b'
$env:NOCTTY_CONFIGURE_SENTINEL = $sentinel
if ($CacheDir) { $env:ZIG_LOCAL_CACHE_DIR = $CacheDir }
$cache = if ($CacheDir) { $CacheDir } else { Join-Path $RepoRoot '.zig-cache' }

Push-Location -LiteralPath $RepoRoot
try {
    foreach ($options in $Configure) {
        $argv = @('build') + @($options -split ' ' | Where-Object { $_ }) + @('--print-configuration-path')
        & zig @argv | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL configure exited $LASTEXITCODE (zig $($argv -join ' '))"
            exit 1
        }
    }
} finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $cache -PathType Container)) {
    Write-Host "FAIL no local cache at $cache after the configure"
    exit 1
}
$needle = [System.Text.Encoding]::UTF8.GetBytes($sentinel)
$files = @(Get-ChildItem -LiteralPath $cache -Recurse -File)
$holding = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt $needle.Length) { continue }
    $text = [System.Text.Encoding]::Latin1.GetString($bytes)
    if ($text.Contains([System.Text.Encoding]::Latin1.GetString($needle), [StringComparison]::Ordinal)) {
        $holding.Add([System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName))
    }
}
if ($holding.Count -gt 0) {
    Write-Host "FAIL the build configuration holds a copy of the environment (ZIG017-RUN-ENV-01) in $($holding.Count) file(s):"
    $holding | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "PASS $($Configure.Count) configure(s); no file of $($files.Count) under the local cache holds the sentinel"
exit 0
