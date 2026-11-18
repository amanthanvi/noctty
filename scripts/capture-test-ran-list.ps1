#requires -Version 7.0
<#
.SYNOPSIS
Writes the list of Zig tests that actually ran: one sorted, diffable row per
suite, result and fully qualified test name, with its multiplicity.

.DESCRIPTION
A source-name inventory cannot see a test that is still in a file but no longer
reachable from a test root (src/terminal/main.zig is the only import of
resize_replay.zig's replay tests: drop it and every name stays while none of
them runs). The ran list records execution instead. scripts/compare-test-ran-list.ps1
checks a later list against it.

A Zig test executable run directly (no --listen) with stderr not a terminal
prints `N/M <qualified name>...` as a test starts and `OK`, `SKIP` or
`FAIL (<error>)` when it ends: on the same line for a quiet test, on a line of
its own after whatever the test logged (src/test_runner.zig, the stock runner's
terminal mode; Zig 0.15.2 and 0.17.1 print the same lines). It ends with
`All N tests passed.` or `N passed; N skipped; N failed.`. A log that stops
before that line, or whose counts disagree with the tests it lists, is refused,
so a crash or a timeout cannot shrink a list.

Each input is a suite, named by -Suite (default: the file name without its
extension). Run an executable with -TestExe, which keeps its runner lines as
<list name>.<suite>.log in -LogDirectory (default: beside -OutFile), or read
a log a run already wrote with -TestLog (CI's ghostty-test.log). The
executable runs in -WorkingDirectory (default: the current directory), which
must be the checkout that built it, as CI runs it from the checkout root: a
test reads the version fixture through a path the build gave relative to
that root (`windows_version_fixture.exe_path`) and fails with
InstallerVersionInfoUnavailable anywhere else, and a test skips unless the
directory is on the temporary directory's drive.

Rows are `<suite><TAB><result><TAB><count><TAB><qualified name>`, sorted by
ordinal suite, name and result, between a header (revision, build options,
per-suite totals, exit codes) and an `# end:` line the compare checks, written
as UTF-8 without a BOM with LF line ends. The list is written whatever the
results, so failures stay visible, and the script exits 1 when a test failed,
an executable exited nonzero (a leak or a logged error) or a log is refused
(then no list is written).

The `zig build test` step does not install the test executable: install it
first, for example
  zig build -Demit-test-exe=true -Demit-exe=false [the options the suite runs with]
which leaves zig-out\bin\ghostty-test.exe. The lib-vt test executables
(ghostty-vt-test, ghostty-vt-c-test) are not installed by any step; pass the
ones `zig build test-lib-vt -Demit-lib-vt=true` built in its cache.

  pwsh scripts/capture-test-ran-list.ps1 -TestExe zig-out\bin\ghostty-test.exe `
      -Revision (git rev-parse HEAD) -BuildOptions '-Demit-test-exe=true' -OutFile ran-list.tsv

Pass several executables from PowerShell (`-TestExe a.exe, b.exe`): `pwsh -File`
hands a comma-separated argument to the script as one path.
#>
[CmdletBinding()]
param(
    [string[]] $TestExe = @(),
    [string[]] $TestLog = @(),
    # One label per input, -TestExe inputs first, then -TestLog inputs.
    [string[]] $Suite = @(),
    [string] $OutFile,
    [string] $Revision = 'unknown',
    # The `zig build` options the executables were built with; the compare
    # refuses to compare lists whose options differ.
    [string] $BuildOptions = 'unknown',
    [string] $LogDirectory,
    # The checkout that built the executables (see above).
    [string] $WorkingDirectory = (Get-Location).Path,
    [int] $TimeoutMinutes = 90,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

$script:RanListFormat = '# noctty test ran list v1'

# Parses the runner's terminal-mode lines. Returns the tests (Index, Name,
# Result) and the reasons the log cannot stand for a whole run.
function ConvertFrom-ZigRunnerLog {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines)

    $announced = 0
    $summary = $null
    $tests = [Collections.Generic.List[object]]::new()
    $pending = $null
    $problems = [Collections.Generic.List[string]]::new()
    $resultPattern = '^(OK|SKIP|FAIL)(?: \([^)]+\))?\s*$'
    foreach ($line in $Lines) {
        if ($null -ne $pending -and $line -match $resultPattern) {
            $tests.Add([pscustomobject]@{ Index = $pending.Index; Name = $pending.Name; Result = $Matches[1] })
            $pending = $null
            continue
        }
        $header = [regex]::Match($line, '^(\d+)/(\d+) (.*?)\.\.\.(.*)$')
        if ($header.Success) {
            if ($null -ne $summary) { $problems.Add('A per-test header follows the closing line.') }
            if ($null -ne $pending) { $problems.Add("Test $($pending.Index) ($($pending.Name)) has no result before the next header.") }
            $index = [int]$header.Groups[1].Value
            if ($index -ne $tests.Count + 1 + [int]($null -ne $pending)) { $problems.Add("Per-test indexes are not sequential at $index.") }
            $count = [int]$header.Groups[2].Value
            if ($announced -ne 0 -and $count -ne $announced) { $problems.Add('Per-test announced totals changed within the run.') }
            if ($announced -eq 0) { $announced = $count }
            $name = $header.Groups[3].Value
            if ($name.Length -eq 0 -or $name.Contains("`t")) { $problems.Add("Test $index has an empty name or one with a tab.") }
            $pending = [pscustomobject]@{ Index = $index; Name = $name }
            if ($header.Groups[4].Value -match $resultPattern) {
                $tests.Add([pscustomobject]@{ Index = $index; Name = $name; Result = $Matches[1] })
                $pending = $null
            }
            continue
        }
        $total = [regex]::Match($line, '^(\d+) passed; (\d+) skipped; (\d+) failed\.$')
        $allPassed = [regex]::Match($line, '^All (\d+) tests passed\.$')
        if ($total.Success -or $allPassed.Success) {
            if ($null -ne $summary) { $problems.Add('The log has more than one closing line.') }
            if ($null -ne $pending) { $problems.Add("Test $($pending.Index) ($($pending.Name)) has no result before the closing line.") }
            $summary = if ($total.Success) {
                @{ Passed = [int]$total.Groups[1].Value; Skipped = [int]$total.Groups[2].Value; Failed = [int]$total.Groups[3].Value }
            }
            else { @{ Passed = [int]$allPassed.Groups[1].Value; Skipped = 0; Failed = 0 } }
        }
    }
    if ($tests.Count -eq 0) { $problems.Add('The log holds no per-test lines (run the test executable directly, stderr not a terminal).') }
    elseif ($null -eq $summary) { $problems.Add("The log has no closing line, so the run did not finish ($($tests.Count) of $announced tests reported).") }
    elseif ($tests.Count -ne $announced -or ($summary.Passed + $summary.Skipped + $summary.Failed) -ne $announced) {
        $problems.Add("The log is inconsistent: $($tests.Count) tests parsed, $announced announced, the closing line counts $($summary.Passed + $summary.Skipped + $summary.Failed).")
    }
    if ($null -ne $summary) {
        foreach ($status in @(@('OK', 'Passed'), @('SKIP', 'Skipped'), @('FAIL', 'Failed'))) {
            $actual = @($tests | Where-Object Result -ceq $status[0]).Count
            if ($actual -ne $summary[$status[1]]) { $problems.Add("Parsed $actual $($status[1].ToLowerInvariant()) tests but the closing line says $($summary[$status[1]]).") }
        }
    }
    return [pscustomobject]@{ Tests = $tests.ToArray(); Problems = $problems.ToArray() }
}

# Counts each (suite, name, result) and sorts the rows ordinally.
function Get-RanListRows {
    param([Parameter(Mandatory)] [string] $SuiteName, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Tests)
    $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($test in $Tests) {
        $key = "$($test.Name)`t$($test.Result)"
        $counts[$key] = 1 + $(if ($counts.ContainsKey($key)) { $counts[$key] } else { 0 })
    }
    $rows = foreach ($key in $counts.Keys) {
        $name, $result = $key -split "`t", 2
        [pscustomobject]@{ Suite = $SuiteName; Result = $result; Count = $counts[$key]; Name = $name }
    }
    return @($rows)
}

# The list's text: header, sorted rows, end line. $Suites holds one record per
# suite (Name, Tests, Ok, Skip, Fail, Exit).
function Format-RanList {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [object[]] $Suites,
        [string] $Revision = 'unknown',
        [string] $BuildOptions = 'unknown'
    )
    # Ordinal order of (suite, name, result): NUL sorts below every character
    # either can hold. Only the string keys are sorted (PowerShell hands a
    # .NET sort a copy of an object array, so a keys-and-items sort would
    # leave the rows where they were).
    $byKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) { $byKey.Add("$($row.Suite)`0$($row.Name)`0$($row.Result)", $row) }
    $keys = [string[]] @($byKey.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $sorted = @($keys | ForEach-Object { $byKey[$_] })
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($script:RanListFormat)
    $lines.Add("# revision: $Revision")
    $lines.Add("# build: $BuildOptions")
    foreach ($s in $Suites) {
        $lines.Add("# suite: $($s.Name) tests=$($s.Tests) ok=$($s.Ok) skip=$($s.Skip) fail=$($s.Fail) exit=$($s.Exit)")
    }
    $lines.Add("# columns: suite`tresult`tcount`tqualified name")
    $total = 0
    foreach ($row in $sorted) {
        $lines.Add("$($row.Suite)`t$($row.Result)`t$($row.Count)`t$($row.Name)")
        $total += $row.Count
    }
    $lines.Add("# end: rows=$($sorted.Count) tests=$total")
    return ($lines -join "`n") + "`n"
}

# Runs one test executable with stderr and stdout redirected (the runner then
# prints per-test lines), streaming stderr into $LogPath as it arrives, so a run
# that times out still leaves its log. Returns the exit code.
function Invoke-ZigTestExecutable {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $Directory,
        [int] $Minutes = 90
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Path)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.WorkingDirectory = $Directory
    $log = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 1)
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $copy = $process.StandardError.BaseStream.CopyToAsync($log)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit($Minutes * 60 * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$Path did not finish within $Minutes minutes; its log so far is $LogPath."
        }
        $copy.Wait()
        [void] $stdout.Result
        return $process.ExitCode
    }
    finally {
        $log.Dispose()
    }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutFile)) { throw 'Pass -OutFile.' }
$inputs = @($TestExe | ForEach-Object { @{ Kind = 'exe'; Path = $_ } }) + @($TestLog | ForEach-Object { @{ Kind = 'log'; Path = $_ } })
if ($inputs.Count -eq 0) { throw 'Pass -TestExe or -TestLog.' }
if ($Suite.Count -ne 0 -and $Suite.Count -ne $inputs.Count) { throw "Pass one -Suite per input ($($inputs.Count)), or none." }
$outPath = [System.IO.Path]::GetFullPath($OutFile)
if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Split-Path -Parent $outPath }
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$rows = [Collections.Generic.List[object]]::new()
$suites = [Collections.Generic.List[object]]::new()
$problems = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
for ($i = 0; $i -lt $inputs.Count; $i++) {
    $item = $inputs[$i]
    $path = (Resolve-Path -LiteralPath $item.Path).Path
    $name = if ($Suite.Count -ne 0) { $Suite[$i] } else { [System.IO.Path]::GetFileNameWithoutExtension($path) }
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "Suite name '$name' must be letters, digits, '.', '_' or '-'." }
    if (-not $seen.Add($name)) { throw "Suite '$name' is given twice." }
    $exit = 'n/a'
    $logPath = $path
    if ($item.Kind -eq 'exe') {
        $logPath = Join-Path (Resolve-Path -LiteralPath $LogDirectory).Path "$([System.IO.Path]::GetFileNameWithoutExtension($outPath)).$name.log"
        Write-Host "Running $name ($path)"
        $exit = Invoke-ZigTestExecutable -Path $path -LogPath $logPath -Directory $WorkingDirectory -Minutes $TimeoutMinutes
    }
    $parsed = ConvertFrom-ZigRunnerLog -Lines ([System.IO.File]::ReadAllLines($logPath, [System.Text.UTF8Encoding]::new($false)))
    foreach ($problem in $parsed.Problems) { $problems.Add("${name}: $problem") }
    $tests = @($parsed.Tests)
    $ok = @($tests | Where-Object Result -ceq 'OK').Count
    $skip = @($tests | Where-Object Result -ceq 'SKIP').Count
    $fail = @($tests | Where-Object Result -ceq 'FAIL').Count
    $suites.Add([pscustomobject]@{ Name = $name; Tests = $tests.Count; Ok = $ok; Skip = $skip; Fail = $fail; Exit = $exit })
    foreach ($row in (Get-RanListRows -SuiteName $name -Tests $tests)) { $rows.Add($row) }
    Write-Host ("{0}: {1} tests, {2} OK, {3} skipped, {4} failed, exit {5} (log {6})" -f $name, $tests.Count, $ok, $skip, $fail, $exit, $logPath)
}
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { [Console]::Error.WriteLine("RAN LIST: $problem") }
    [Console]::Error.WriteLine('RAN LIST: no list written.')
    exit 1
}
$text = Format-RanList -Rows $rows.ToArray() -Suites $suites.ToArray() -Revision $Revision -BuildOptions $BuildOptions
[System.IO.File]::WriteAllText($outPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $outPath ($($rows.Count) rows)."
$bad = @($suites | Where-Object { $_.Fail -gt 0 -or ($_.Exit -ne 'n/a' -and $_.Exit -ne 0) })
if ($bad.Count -gt 0) {
    foreach ($s in $bad) { [Console]::Error.WriteLine("RAN LIST: $($s.Name) is not green ($($s.Fail) failed, exit $($s.Exit)).") }
    exit 1
}
