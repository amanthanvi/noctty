#requires -Version 7.0
<#
.SYNOPSIS
Builds the libghostty-vt examples on Windows (test.yml's windows-examples job).

.DESCRIPTION
Modelled on upstream Ghostty's `build-examples-cmake-windows` job, which builds
each CMake example with Visual Studio's generator. This one also builds every
Zig example, which upstream builds only on Linux:

- every `example/<name>/build.zig.zon`: `zig build -Dtarget=native-native-msvc`
  in that folder (a path dependency on this tree). The fork builds for MSVC,
  and Zig 0.17.1's default `native` target on Windows is windows-gnu, where
  the pure Zig examples' C++ dependencies fail to compile (`<cstring>` not
  found, MinGW header errors); upstream v1.4.0's own zig-vt example fails
  the same way there (measured);
- every `example/<name>/CMakeLists.txt` but `c-vt-cmake-cross`: `cmake -B
  build -DFETCHCONTENT_SOURCE_DIR_NOCTTY=<this tree>` and `cmake --build
  build`. The cross example needs a single-config generator (Makefiles or
  Ninja) for `zig cc`; Visual Studio's always uses MSVC (upstream excludes it
  for the same reason).

The Zig examples share one local cache (`ZIG_LOCAL_CACHE_DIR`, under the
root's `.zig-cache` unless already set), so the library compiles once for all of
them. Every example is built, the failures are listed at the end, and the
script exits 1 when any failed or when it found no example of either kind.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    # Build only the examples whose folder name matches (a local check).
    [string] $Filter = '*'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$exampleRoot = Join-Path $RepoRoot 'example'
$cmakeExcluded = @('c-vt-cmake-cross')

if (-not $env:ZIG_LOCAL_CACHE_DIR) {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $RepoRoot '.zig-cache\examples'
}

$zigExamples = @(Get-ChildItem -LiteralPath $exampleRoot -Directory |
        Where-Object { $_.Name -like $Filter -and (Test-Path -LiteralPath (Join-Path $_.FullName 'build.zig.zon')) } |
        Sort-Object Name)
$cmakeExamples = @(Get-ChildItem -LiteralPath $exampleRoot -Directory |
        Where-Object { $_.Name -like $Filter -and $_.Name -notin $cmakeExcluded -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'CMakeLists.txt')) } |
        Sort-Object Name)
if ($Filter -eq '*' -and ($zigExamples.Count -eq 0 -or $cmakeExamples.Count -eq 0)) {
    Write-Host "FAIL found $($zigExamples.Count) Zig and $($cmakeExamples.Count) CMake examples under $exampleRoot"
    exit 1
}

$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-ExampleCommand {
    param(
        [Parameter(Mandatory)] [string] $Example,
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    Push-Location -LiteralPath $Directory
    try {
        # To the host: a function's pipeline output would be its result.
        & $Command @Arguments | Out-Host
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        Write-Host "::error::$Example`: $Command $($Arguments[0]) exited $code"
        return $false
    }
    return $true
}

foreach ($example in $zigExamples) {
    Write-Host "::group::$($example.Name) (zig build)"
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = Invoke-ExampleCommand -Example $example.Name -Directory $example.FullName -Command 'zig' -Arguments @('build', '-Dtarget=native-native-msvc', '--summary', 'none')
    Write-Host "$($example.Name): $(if ($ok) { 'built' } else { 'FAILED' }) in $([int]$timer.Elapsed.TotalSeconds)s"
    Write-Host '::endgroup::'
    if (-not $ok) { $failures.Add("$($example.Name) (zig build)") }
}

foreach ($example in $cmakeExamples) {
    Write-Host "::group::$($example.Name) (cmake)"
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = (Invoke-ExampleCommand -Example $example.Name -Directory $example.FullName -Command 'cmake' -Arguments @('-B', 'build', "-DFETCHCONTENT_SOURCE_DIR_NOCTTY=$RepoRoot")) -and
        (Invoke-ExampleCommand -Example $example.Name -Directory $example.FullName -Command 'cmake' -Arguments @('--build', 'build'))
    Write-Host "$($example.Name): $(if ($ok) { 'built' } else { 'FAILED' }) in $([int]$timer.Elapsed.TotalSeconds)s"
    Write-Host '::endgroup::'
    if (-not $ok) { $failures.Add("$($example.Name) (cmake)") }
}

$total = $zigExamples.Count + $cmakeExamples.Count
if ($failures.Count -gt 0) {
    Write-Host "RESULT FAIL $($failures.Count) of $total examples failed:"
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "RESULT PASS $total examples built ($($zigExamples.Count) Zig, $($cmakeExamples.Count) CMake; excluded: $($cmakeExcluded -join ', '))"
exit 0
