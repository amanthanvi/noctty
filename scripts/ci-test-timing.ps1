#requires -Version 5.1
<#
.SYNOPSIS
Per-test timing of the Zig test executable, for the job summary (report only).

.DESCRIPTION
The test runner (src/test_runner.zig, a copy of Zig's stock one) prints no
durations under `zig build test`. Run by
hand (no --listen) with stderr not a terminal, it prints `N/M <qualified name>...`
as a test starts and `OK`, `SKIP` or `FAIL (<error>)` when it ends: on the same
line for a quiet test, on a line of its own after whatever the test logged.
This runs the executable that `-Demit-test-exe=true` installs, timestamps each
line as it arrives, and gives a test the time from the previous test's end to
its own end. The slowest go to the job summary and to
<OutputDirectory>\test-timing.json, and the runner's lines, untimed, to
<OutputDirectory>\ghostty-test.log, which scripts/check-test-skips.ps1 reads.

The first 70 or so entries are the unnamed reference tests every filter keeps;
they cost nothing.
#>
[CmdletBinding()]
param(
    [string] $TestExe,
    [int] $Top = 25,
    [string] $OutputDirectory = 'test-timing',
    # Dot-source for the parser only.
    [switch] $LibraryOnly
)

# Turns timestamped runner lines into one record per test. Each element of
# $Lines is @{ Seconds = <arrival>; Text = <line> }. A test that logs keeps its
# header line open until its own `OK`/`SKIP`/`FAIL (...)` line, so a logging test
# is not cut short and its neighbour is not charged for the rest of it.
function ConvertFrom-ZigTestLines {
    param([Parameter(Mandatory)] [object[]] $Lines)

    $tests = [System.Collections.Generic.List[object]]::new()
    $open = $null
    $lastEnd = 0.0
    $lastSeen = 0.0
    $resultPattern = '^(OK|SKIP|FAIL \(.*\))$'
    # Records a test that ended at $End, charged the time since $lastEnd.
    function Add-ZigTestRecord($Name, [double] $End, $Result) {
        $tests.Add([pscustomobject]@{ Name = $Name; Seconds = [math]::Round($End - $lastEnd, 3); Result = $Result })
    }
    foreach ($line in $Lines) {
        $text = [string] $line.Text
        $seconds = [double] $line.Seconds
        $lastSeen = $seconds
        $result = $null
        if ($text -match '^(\d+)/(\d+) (.+?)\.\.\.(.*)$') {
            if ($null -ne $open) {
                # The previous test never printed its end (it crashed or the log
                # was cut): close it where the next one starts.
                Add-ZigTestRecord $open $seconds 'incomplete'
                $lastEnd = $seconds
            }
            $open = $Matches[3]
            $rest = $Matches[4]
            if ($rest -match $resultPattern) { $result = $rest }
        }
        elseif ($null -ne $open -and $text -match $resultPattern) {
            $result = $text
        }
        if ($null -ne $result) {
            Add-ZigTestRecord $open $seconds $result
            $lastEnd = $seconds
            $open = $null
        }
    }
    if ($null -ne $open) {
        # The log ended inside a test: charge it the time up to the last line.
        Add-ZigTestRecord $open $lastSeen 'incomplete'
    }
    return $tests.ToArray()
}

if ($LibraryOnly) { return }

if ([string]::IsNullOrWhiteSpace($TestExe)) { throw 'Pass -TestExe.' }
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $TestExe).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
$psi.UseShellExecute = $false
$psi.RedirectStandardError = $true
$psi.RedirectStandardOutput = $true
$psi.WorkingDirectory = (Get-Location).Path
# Each line reaches the log as it arrives, so a run the step's timeout kills
# still leaves the log up to the test that hung (it then fails the skip budget
# as cut off, and the upload carries it).
$log = [System.IO.StreamWriter]::new((Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'ghostty-test.log'), $false, [System.Text.UTF8Encoding]::new($false))
$log.AutoFlush = $true
try {
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lines = [System.Collections.Generic.List[object]]::new()
    while ($null -ne ($line = $process.StandardError.ReadLine())) {
        $lines.Add(@{ Seconds = $clock.Elapsed.TotalSeconds; Text = $line })
        $log.WriteLine($line)
    }
    $process.WaitForExit()
    [void] $stdoutTask.Result
    $total = $clock.Elapsed.TotalSeconds
}
finally {
    $log.Dispose()
}

$tests = @(ConvertFrom-ZigTestLines -Lines $lines.ToArray())
$slowest = @($tests | Sort-Object Seconds -Descending | Select-Object -First $Top)
$over = @($tests | Where-Object { $_.Seconds -ge 1 })
[ordered]@{
    exit_code = $process.ExitCode
    tests = $tests.Count
    total_seconds = [math]::Round($total, 1)
    tests_over_one_second = $over.Count
    slowest = $slowest
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'test-timing.json') -Encoding utf8

$summary = @(
    '### Zig test timing (report only)'
    ''
    ('{0} tests in {1:N0} s; {2} took a second or more, together {3:N0} s.' -f $tests.Count, $total, $over.Count, ($over | Measure-Object Seconds -Sum).Sum)
    ''
    '| Seconds | Test |'
    '| ---: | --- |'
) + ($slowest | ForEach-Object { '| {0:N2} | `{1}` |' -f $_.Seconds, $_.Name })
$summary | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8 }
if ($process.ExitCode -ne 0) { throw "The test executable exited with code $($process.ExitCode)." }
