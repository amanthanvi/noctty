#requires -Version 7.0
<#
.SYNOPSIS
Writes the list of Zig tests that actually ran: one sorted, diffable row per
suite, result and fully qualified test name, with its multiplicity, under a
header that records the build, the compiler and the environment the run had.

.DESCRIPTION
A source-name inventory cannot see a test that is still in a file but no longer
reachable from a test root (src/terminal/main.zig is the only import of
resize_replay.zig's replay tests: drop it and every name stays while none of
them runs). The ran list records execution instead.
scripts/compare-test-ran-list.ps1 checks a later list against it.

Two ways to take a list:

* Build mode (-Checkout): the script builds `ghostty-test` itself in that
  checkout (`zig build -Demit-test-exe=true -Demit-exe=false <-BuildOptions>`
  into a prefix under the checkout's .zig-cache), so the options it records are
  the ones that built the executable. It records the commit (and refuses a
  checkout with tracked changes), the mode and target the build summary's
  `compile test ghostty-test <mode> <target>` line names, and `zig version`,
  and runs the executable from the checkout. This is how a gate list is taken.
* Declared mode (-TestExe or -TestLog): for an executable or a log the script
  did not build, such as the lib-vt test executables (no build step installs
  them; `zig build test-lib-vt -Demit-lib-vt=true` leaves them under
  `.zig-cache\o\<hash>\`) or CI's ghostty-test.log. -Revision, -BuildOptions
  and -ZigVersion are then required and recorded as declared. A -TestLog needs
  -TestLogExitCode, the exit code of the run that wrote it.

Run the executable from the checkout that built it (build mode always does): a
test reads the updater's version fixture through a path relative to the build
root (`windows_version_fixture.exe_path`) and fails anywhere else.

The runner's terminal mode prints `N/M <qualified name>...` as a test starts,
then whatever the test prints, then `OK`, `SKIP` or `FAIL (<error>)` (on the
header line for a quiet test), and after the last test a closing line and its
trailers: `N errors were logged.`, `N tests leaked memory.` (src/test_runner.zig;
Zig 0.15.2's and 0.17.1's stock runners print the same lines). The parser
follows only that structure:

* a header is a line `<k>/<M> ` with k the next index and M the announced
  total; a header-shaped line out of sequence fails the log;
* a test's result is its block's one result-shaped line (or the header line's
  `...OK|SKIP|FAIL (x)` ending). A block with two, as when a test prints a
  bare `OK` or `SKIP` before its result, or with none, fails the log: a test's
  own output cannot change a result;
* a quiet test's name may hold `...`; a test whose output starts on the header
  line and holds `...` cannot be told from its name, and fails the log;
* the closing line's counts must match the blocks, and a panic line, an error
  or leak trailer, or a nonzero exit makes the run not green.

Rows are `<suite><TAB><result><TAB><count><TAB><qualified name>`, sorted by
ordinal suite, name and result, between the header and an `# end:` line the
compare checks, as UTF-8 without a BOM with LF line ends. The list is written
whenever the log parses, so failures stay visible; the script exits 1 when the
run is not green or the log does not parse (then no list is written).

Environment facts. Some tests run or skip by the environment, not the code, so
the header records, before the run, the facts they read (`# env:` lines):

  cwd-on-temp-drive      the working directory is on the temporary directory's
                         drive; "image load: windows file path that is not
                         drive-absolute is refused" (graphics_image.zig) skips
                         without it
  temp-makes-8dot3-names the temporary directory's volume gives a long file name
                         an 8.3 alias; "security regression win32 link opener
                         screens the long name behind an 8.3 alias" skips without
  store-alias            a wt.exe or winget.exe Store alias exists under
                         %LOCALAPPDATA%\Microsoft\WindowsApps; "shell discovery
                         accepts a real installed Store execution alias" skips
                         without one
  font:<family>          a font of that family is registered (the registry's
                         Fonts keys); the harfbuzz shaping tests that discover
                         "Arial Unicode MS", "Noto Sans Chakma" or "Noto Serif
                         Tibetan" skip without it
  env:<NAME>             whether an opt-in probe variable is `1`, `unset` or
                         another value (never printed); the ConPTY probes, the
                         link-opener PATHEXT probe and the local-path sweep skip
                         unless theirs is `1`

-EnvironmentOf <list> checks these facts against a baseline list's before the
run, and fails at once if one differs. The compare checks them again.

  pwsh scripts/capture-test-ran-list.ps1 -Checkout . -BuildOptions none -OutFile ran-list-plain.tsv
  pwsh scripts/capture-test-ran-list.ps1 -Checkout . -BuildOptions '-Dcustom-shaders=true' -OutFile ran-list-ci.tsv

Pass several executables from PowerShell (`-TestExe a.exe, b.exe`): `pwsh -File`
hands a comma-separated argument to the script as one path.
#>
[CmdletBinding()]
param(
    # Build mode: the checkout to build ghostty-test in and run it from.
    [string] $Checkout,
    # The zig build options, space separated (build mode: passed to zig build,
    # after -Demit-test-exe=true -Demit-exe=false; declared mode: recorded).
    [string] $BuildOptions,
    [string[]] $TestExe = @(),
    [string[]] $TestLog = @(),
    [int[]] $TestLogExitCode = @(),
    # One label per input, -TestExe inputs first, then -TestLog inputs.
    [string[]] $Suite = @(),
    [string] $OutFile,
    # Declared mode only; build mode reads them from the checkout.
    [string] $Revision,
    [string] $ZigVersion,
    [string] $LogDirectory,
    # Declared mode: the checkout that built the executables (see above).
    [string] $WorkingDirectory,
    # A baseline list whose environment facts this run must have.
    [string] $EnvironmentOf,
    [int] $TimeoutMinutes = 90,
    # Build mode: take a list of a checkout with tracked changes (a control).
    [switch] $AllowDirty,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

$script:RanListFormat = '# noctty test ran list v2'
$script:RanListResult = '^(OK|SKIP|FAIL(?: \([^)]*\))?)\s*$'
$script:RanListFonts = @('Arial Unicode MS', 'Noto Sans Chakma', 'Noto Serif Tibetan')
$script:RanListProbeVariables = @(
    'NOCTTY_CONPTY_KEY_INPUT_PROBE',
    'NOCTTY_CONPTY_TRANSPORT_PROBE',
    'NOCTTY_RUN_CONPTY_TRANSPORT_TEST',
    'NOCTTY_RUN_LINK_PATHEXT_PROBE',
    'NOCTTY_RUN_LOCAL_PATH_SWEEP'
)

# A path as PowerShell's location resolves it (.NET's current directory does
# not follow Set-Location), whether or not it exists yet.
function Resolve-RanListPath {
    param([Parameter(Mandatory)] [string] $Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# Parses the runner's terminal-mode lines. Returns the tests (Index, Name,
# Result), the closing counts and trailers, and the reasons the log cannot
# stand for a whole run.
function ConvertFrom-ZigRunnerLog {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines)

    $problems = [Collections.Generic.List[string]]::new()
    $blocks = [Collections.Generic.List[object]]::new()
    $current = $null
    $total = 0
    $summary = $null
    $trailers = @{ ErrorsLogged = 0; Leaked = 0 }
    $panics = 0
    $after = 0
    foreach ($line in $Lines) {
        if ($line -match '^thread \d+ panic: ' -or $line -match '^panic: ') { $panics++ }
        if ($null -ne $summary) {
            if ($line -match '^(\d+) errors were logged\.$') { $trailers.ErrorsLogged = [int]$Matches[1]; continue }
            if ($line -match '^(\d+) tests leaked memory\.$') { $trailers.Leaked = [int]$Matches[1]; continue }
            if ($line -match '^(\d+) fuzz tests found\.$') { continue }
            if ($line.Trim().Length -gt 0) { $after++ }
            continue
        }
        $header = [regex]::Match($line, '^(\d+)/(\d+) (.*)$')
        if ($header.Success -and $header.Groups[3].Value.Contains('...')) {
            $index = [int]$header.Groups[1].Value
            $count = [int]$header.Groups[2].Value
            if ($index -eq $blocks.Count + 1 -and ($total -eq 0 -or $count -eq $total)) {
                $total = $count
                $current = [pscustomobject]@{ Index = $index; Rest = $header.Groups[3].Value; Lines = [Collections.Generic.List[string]]::new() }
                $blocks.Add($current)
                continue
            }
            $problems.Add("A line looks like the runner's header for test $index of $count out of sequence (expected test $($blocks.Count + 1)); a test's output cannot be told from the runner's.")
            if ($null -ne $current) { $current.Lines.Add($line) }
            continue
        }
        $closed = [regex]::Match($line, '^(\d+) passed; (\d+) skipped; (\d+) failed\.$')
        $allPassed = [regex]::Match($line, '^All (\d+) tests passed\.$')
        if ($closed.Success -or $allPassed.Success) {
            $summary = if ($closed.Success) {
                @{ Passed = [int]$closed.Groups[1].Value; Skipped = [int]$closed.Groups[2].Value; Failed = [int]$closed.Groups[3].Value }
            }
            else { @{ Passed = [int]$allPassed.Groups[1].Value; Skipped = 0; Failed = 0 } }
            continue
        }
        if ($null -ne $current) { $current.Lines.Add($line) }
    }

    $tests = [Collections.Generic.List[object]]::new()
    foreach ($block in $blocks) {
        $quiet = [regex]::Match($block.Rest, '^(.+)\.\.\.(OK|SKIP|FAIL(?: \([^)]*\))?)\s*$')
        $results = @($block.Lines | Where-Object { $_ -match $script:RanListResult })
        $found = $results.Count + [int]$quiet.Success
        if ($found -eq 0) { $problems.Add("Test $($block.Index) has no result."); continue }
        if ($found -gt 1) {
            $problems.Add("Test $($block.Index)'s block holds $found result-shaped lines (OK, SKIP or FAIL (...)): its output cannot be told from its result.")
            continue
        }
        if ($quiet.Success) {
            $name = $quiet.Groups[1].Value
            $result = $quiet.Groups[2].Value
        }
        else {
            $result = ([regex]::Match($results[0], $script:RanListResult)).Groups[1].Value
            # 0: every part (a negative count splits from the right in PowerShell 7).
            $parts = $block.Rest -split '\.\.\.', 0
            if ($parts.Count -ne 2) {
                $problems.Add("Test $($block.Index): its name, or the output that starts on its header line, holds '...', so the name cannot be told from the output.")
                continue
            }
            $name = $parts[0]
        }
        if ($name.Length -eq 0 -or $name.Contains("`t")) { $problems.Add("Test $($block.Index) has an empty name or one with a tab."); continue }
        $tests.Add([pscustomobject]@{ Index = $block.Index; Name = $name; Result = ($result -replace ' \(.*\)$', '') })
    }

    if ($blocks.Count -eq 0) { $problems.Add('The log holds no per-test lines (run the test executable directly, stderr not a terminal).') }
    elseif ($null -eq $summary) { $problems.Add("The log has no closing line, so the run did not finish ($($blocks.Count) of $total tests reported).") }
    else {
        if ($blocks.Count -ne $total -or ($summary.Passed + $summary.Skipped + $summary.Failed) -ne $total) {
            $problems.Add("The log is inconsistent: $($blocks.Count) tests reported, $total announced, the closing line counts $($summary.Passed + $summary.Skipped + $summary.Failed).")
        }
        foreach ($status in @(@('OK', 'Passed'), @('SKIP', 'Skipped'), @('FAIL', 'Failed'))) {
            $actual = @($tests | Where-Object Result -ceq $status[0]).Count
            if ($actual -ne $summary[$status[1]]) { $problems.Add("Parsed $actual $($status[1].ToLowerInvariant()) tests but the closing line says $($summary[$status[1]]).") }
        }
        if ($after -gt 0) { $problems.Add("$after lines follow the closing line that are not the runner's trailers.") }
    }
    return [pscustomobject]@{
        Tests = $tests.ToArray(); Problems = $problems.ToArray()
        ErrorsLogged = $trailers.ErrorsLogged; Leaked = $trailers.Leaked; Panics = $panics
    }
}

# Counts each (suite, name, result).
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

# Whether a suite's run is green: it exited 0 and printed no failure, panic,
# logged error or leak.
function Test-RanListSuiteGreen {
    param([Parameter(Mandatory)] [object] $Suite)
    return "$($Suite.Exit)" -eq '0' -and [int]$Suite.Fail -eq 0 -and [int]$Suite.ErrorsLogged -eq 0 -and [int]$Suite.Leaked -eq 0 -and [int]$Suite.Panics -eq 0
}

# The list's text. $Build and $Environment are ordered key/value maps; $Suites
# holds one record per suite.
function Format-RanList {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [Parameter(Mandatory)] [object[]] $Suites,
        [Parameter(Mandatory)] [string] $Revision,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Build,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Environment
    )
    # Ordinal order of (suite, name, result): NUL sorts below every character
    # either can hold. Only the string keys are sorted (PowerShell hands a .NET
    # sort a copy of an object array, so a keys-and-items sort would leave the
    # rows where they were).
    $byKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) { $byKey.Add("$($row.Suite)`0$($row.Name)`0$($row.Result)", $row) }
    $keys = [string[]] @($byKey.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($script:RanListFormat)
    $lines.Add("# revision: $Revision")
    $lines.Add('# build: ' + (@($Build.Keys | ForEach-Object { "$_=$($Build[$_])" }) -join "`t"))
    $envKeys = [string[]] @($Environment.Keys)
    [Array]::Sort($envKeys, [StringComparer]::Ordinal)
    foreach ($key in $envKeys) { $lines.Add("# env: $key=$($Environment[$key])") }
    foreach ($s in $Suites) {
        $lines.Add("# suite: $($s.Name) tests=$($s.Tests) ok=$($s.Ok) skip=$($s.Skip) fail=$($s.Fail) exit=$($s.Exit) errors-logged=$($s.ErrorsLogged) leaked=$($s.Leaked) panics=$($s.Panics)")
    }
    $lines.Add("# columns: suite`tresult`tcount`tqualified name")
    $total = 0
    foreach ($key in $keys) {
        $row = $byKey[$key]
        $lines.Add("$($row.Suite)`t$($row.Result)`t$($row.Count)`t$($row.Name)")
        $total += $row.Count
    }
    $lines.Add("# end: rows=$($keys.Count) tests=$total")
    return ($lines -join "`n") + "`n"
}

# The environment facts tests read (see the description), for a run from
# $Directory with this process's environment.
function Get-RanListEnvironment {
    param([Parameter(Mandatory)] [string] $Directory)
    $facts = [ordered]@{}
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $facts['cwd-on-temp-drive'] = ([System.IO.Path]::GetPathRoot($Directory).TrimEnd('\') -ieq [System.IO.Path]::GetPathRoot($temp).TrimEnd('\')).ToString().ToLowerInvariant()
    $probe = Join-Path $temp ('noctty-ran-list-8dot3-probe-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [System.IO.File]::WriteAllText($probe, '')
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = [System.IO.Path]::GetFileName($fso.GetFile($probe).ShortPath)
        $facts['temp-makes-8dot3-names'] = ($short -ine [System.IO.Path]::GetFileName($probe)).ToString().ToLowerInvariant()
    }
    catch { $facts['temp-makes-8dot3-names'] = 'unknown' }
    finally { if (Test-Path -LiteralPath $probe) { [System.IO.File]::Delete($probe) } }
    $apps = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps' } else { $null }
    $alias = $null -ne $apps -and (@('wt.exe', 'winget.exe') | Where-Object { Test-Path -LiteralPath (Join-Path $apps $_) }).Count -gt 0
    $facts['store-alias'] = $(if ($alias) { 'present' } else { 'absent' })
    $registered = [Collections.Generic.List[string]]::new()
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
        $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -ne $item) { foreach ($v in $item.GetValueNames()) { $registered.Add($v) } }
    }
    foreach ($family in $script:RanListFonts) {
        $has = @($registered | Where-Object { $_.StartsWith($family, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        $facts["font:$family"] = $(if ($has) { 'present' } else { 'absent' })
    }
    foreach ($name in $script:RanListProbeVariables) {
        $value = [Environment]::GetEnvironmentVariable($name)
        $facts["env:$name"] = $(if ($null -eq $value) { 'unset' } elseif ($value -ceq '1') { '1' } else { 'other' })
    }
    return $facts
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
        # A child the test started can inherit stderr and keep it open after
        # the executable exits; do not wait for it forever.
        if (-not $copy.Wait([TimeSpan]::FromSeconds(60)) -or -not $stdout.Wait([TimeSpan]::FromSeconds(60))) {
            throw "$Path exited, but its output stayed open for 60 s (a process it started holds it); its log so far is $LogPath."
        }
        return $process.ExitCode
    }
    finally {
        $log.Dispose()
    }
}

# Runs a command line through cmd.exe in $Directory, its output to $LogPath.
# Returns the exit code.
function Invoke-RanListCommand {
    param([Parameter(Mandatory)] [string] $CommandLine, [Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] [string] $LogPath)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $psi.ArgumentList.Add('/d')
    $psi.ArgumentList.Add('/c')
    $psi.ArgumentList.Add($CommandLine)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.WorkingDirectory = $Directory
    $process = [System.Diagnostics.Process]::Start($psi)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [System.IO.File]::WriteAllText($LogPath, $out.Result + $err.Result, [System.Text.UTF8Encoding]::new($false))
    return $process.ExitCode
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutFile)) { throw 'Pass -OutFile.' }
$outPath = Resolve-RanListPath $OutFile
$LogDirectory = if ([string]::IsNullOrWhiteSpace($LogDirectory)) { Split-Path -Parent $outPath } else { Resolve-RanListPath $LogDirectory }
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$listName = [System.IO.Path]::GetFileNameWithoutExtension($outPath)
$build = [ordered]@{}
$inputs = [Collections.Generic.List[object]]::new()

if (-not [string]::IsNullOrWhiteSpace($Checkout)) {
    # Build mode.
    if ($TestExe.Count -or $TestLog.Count -or $Revision -or $ZigVersion -or $WorkingDirectory) {
        throw 'Build mode (-Checkout) reads the revision, compiler and executable itself; do not pass -TestExe, -TestLog, -Revision, -ZigVersion or -WorkingDirectory with it.'
    }
    if ([string]::IsNullOrWhiteSpace($BuildOptions)) { throw "Pass -BuildOptions: the gate's own options, or 'none'." }
    $root = Resolve-RanListPath $Checkout
    $Revision = (& git -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $Revision -notmatch '^[0-9a-f]{40}$') { throw "$root is not a git checkout." }
    $dirty = @(& git -C $root status --porcelain --untracked-files=no)
    if ($dirty.Count -gt 0 -and -not $AllowDirty) { throw "$root has tracked changes, so its build is not $Revision; commit them, or pass -AllowDirty for a control." }
    $options = @($BuildOptions -split '\s+' | Where-Object { $_ -and $_ -cne 'none' })
    # Relative to the checkout, so the command line needs no quotes (cmd /c
    # would pass them on to zig, which reads them as part of the path).
    $prefixRelative = '.zig-cache\ran-list-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $prefix = Join-Path $root $prefixRelative
    $zig = if (Test-Path -LiteralPath (Join-Path $root 'scripts\dev-windows.cmd')) { 'scripts\dev-windows.cmd zig' } else { 'zig' }
    $buildLog = Join-Path $LogDirectory "$listName.build.log"
    $line = "$zig build -Demit-test-exe=true -Demit-exe=false $($options -join ' ') --prefix $prefixRelative --summary all"
    Write-Host "Building ghostty-test in $root"
    if ((Invoke-RanListCommand -CommandLine $line -Directory $root -LogPath $buildLog) -ne 0) { throw "The build failed; see $buildLog." }
    $compiled = [regex]::Match([System.IO.File]::ReadAllText($buildLog), '(?m)^[ |+\-]*compile test ghostty-test (\S+) (\S+) ')
    if (-not $compiled.Success) { throw "The build summary names no 'compile test ghostty-test <mode> <target>' line; see $buildLog." }
    $versionLog = Join-Path $LogDirectory "$listName.zig-version.log"
    [void] (Invoke-RanListCommand -CommandLine "$zig version" -Directory $root -LogPath $versionLog)
    $versions = @([System.IO.File]::ReadAllLines($versionLog) | Where-Object { $_ -match '^\d+\.\d+\.\d+\S*$' } | Select-Object -Last 1)
    if ($versions.Count -ne 1) { throw "zig version printed no version; see $versionLog." }
    $build['source'] = 'built'
    $build['options'] = $(if ($options.Count) { $options -join ' ' } else { '(none)' })
    $build['mode'] = $compiled.Groups[1].Value
    $build['target'] = $compiled.Groups[2].Value
    $build['zig'] = $versions[0]
    $build['dirty'] = ($dirty.Count -gt 0).ToString().ToLowerInvariant()
    $WorkingDirectory = $root
    $inputs.Add(@{ Kind = 'exe'; Path = (Join-Path $prefix 'bin\ghostty-test.exe'); Suite = 'ghostty-test' })
}
else {
    # Declared mode.
    foreach ($pair in @(@('Revision', $Revision), @('BuildOptions', $BuildOptions), @('ZigVersion', $ZigVersion))) {
        if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1] -ieq 'unknown') { throw "Declared mode needs -$($pair[0]) (not empty, not 'unknown')." }
    }
    if ($TestLog.Count -ne $TestLogExitCode.Count) { throw 'Pass one -TestLogExitCode per -TestLog: the exit code of the run that wrote it.' }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
    $WorkingDirectory = Resolve-RanListPath $WorkingDirectory
    $all = @($TestExe | ForEach-Object { @{ Kind = 'exe'; Path = (Resolve-RanListPath $_) } })
    for ($i = 0; $i -lt $TestLog.Count; $i++) { $all += @{ Kind = 'log'; Path = (Resolve-RanListPath $TestLog[$i]); Exit = $TestLogExitCode[$i] } }
    if ($all.Count -eq 0) { throw 'Pass -Checkout, -TestExe or -TestLog.' }
    if ($Suite.Count -ne 0 -and $Suite.Count -ne $all.Count) { throw "Pass one -Suite per input ($($all.Count)), or none." }
    for ($i = 0; $i -lt $all.Count; $i++) {
        $all[$i].Suite = if ($Suite.Count -ne 0) { $Suite[$i] } else { [System.IO.Path]::GetFileNameWithoutExtension($all[$i].Path) }
        $inputs.Add($all[$i])
    }
    $build['source'] = 'declared'
    $declared = @($BuildOptions -split '\s+' | Where-Object { $_ -and $_ -cne 'none' })
    $build['options'] = $(if ($declared.Count) { $declared -join ' ' } else { '(none)' })
    $build['zig'] = $ZigVersion
}
$build['filtered'] = ($build['options'] -match '(^|\s)-Dtest-filter(=|\s|$)').ToString().ToLowerInvariant()

$environment = Get-RanListEnvironment -Directory $WorkingDirectory
if (-not [string]::IsNullOrWhiteSpace($EnvironmentOf)) {
    $basePath = Resolve-RanListPath $EnvironmentOf
    if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) { throw "The baseline '$basePath' does not exist." }
    $baseFacts = @{}
    foreach ($l in [System.IO.File]::ReadAllLines($basePath)) { if ($l -match '^# env: ([^=]+)=(.*)$') { $baseFacts[$Matches[1]] = $Matches[2] } }
    $differ = @(@($environment.Keys) + @($baseFacts.Keys) | Sort-Object -Unique | Where-Object { "$($environment[$_])" -cne "$($baseFacts[$_])" })
    if ($differ.Count -gt 0) {
        foreach ($key in $differ) { [Console]::Error.WriteLine("RAN LIST: environment fact $key is '$($environment[$key])' here and '$($baseFacts[$key])' in the baseline.") }
        [Console]::Error.WriteLine('RAN LIST: this run would not be like for like with its baseline; nothing was run.')
        exit 1
    }
}

$rows = [Collections.Generic.List[object]]::new()
$suites = [Collections.Generic.List[object]]::new()
$problems = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in $inputs) {
    $name = $item.Suite
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "Suite name '$name' must be letters, digits, '.', '_' or '-'." }
    if (-not $seen.Add($name)) { throw "Suite '$name' is given twice." }
    if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) { throw "'$($item.Path)' does not exist." }
    if ($item.Kind -eq 'exe') {
        $logPath = Join-Path $LogDirectory "$listName.$name.log"
        Write-Host "Running $name ($($item.Path)) in $WorkingDirectory"
        $exit = Invoke-ZigTestExecutable -Path $item.Path -LogPath $logPath -Directory $WorkingDirectory -Minutes $TimeoutMinutes
    }
    else {
        $logPath = $item.Path
        $exit = $item.Exit
    }
    $parsed = ConvertFrom-ZigRunnerLog -Lines ([System.IO.File]::ReadAllLines($logPath, [System.Text.UTF8Encoding]::new($false)))
    foreach ($problem in $parsed.Problems) { $problems.Add("${name}: $problem") }
    $tests = @($parsed.Tests)
    $record = [pscustomobject]@{
        Name = $name; Tests = $tests.Count
        Ok = @($tests | Where-Object Result -ceq 'OK').Count
        Skip = @($tests | Where-Object Result -ceq 'SKIP').Count
        Fail = @($tests | Where-Object Result -ceq 'FAIL').Count
        Exit = $exit; ErrorsLogged = $parsed.ErrorsLogged; Leaked = $parsed.Leaked; Panics = $parsed.Panics
    }
    $suites.Add($record)
    foreach ($row in (Get-RanListRows -SuiteName $name -Tests $tests)) { $rows.Add($row) }
    Write-Host ("{0}: {1} tests, {2} OK, {3} skipped, {4} failed, exit {5}, {6} errors logged, {7} leaked, {8} panics (log {9})" -f $name, $record.Tests, $record.Ok, $record.Skip, $record.Fail, $record.Exit, $record.ErrorsLogged, $record.Leaked, $record.Panics, $logPath)
}
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { [Console]::Error.WriteLine("RAN LIST: $problem") }
    [Console]::Error.WriteLine('RAN LIST: no list written.')
    exit 1
}
$text = Format-RanList -Rows $rows.ToArray() -Suites $suites.ToArray() -Revision $Revision -Build $build -Environment $environment
[System.IO.File]::WriteAllText($outPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $outPath ($($rows.Count) rows)."
$bad = @($suites | Where-Object { -not (Test-RanListSuiteGreen $_) })
if ($bad.Count -gt 0) {
    foreach ($s in $bad) { [Console]::Error.WriteLine("RAN LIST: $($s.Name) is not green ($($s.Fail) failed, exit $($s.Exit), $($s.ErrorsLogged) errors logged, $($s.Leaked) leaked, $($s.Panics) panics).") }
    exit 1
}
exit 0
