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

Three ways to take a list:

* Build mode (-Checkout): the script builds `ghostty-test` itself in that
  checkout (`zig build -Demit-test-exe=true -Demit-exe=false <-BuildOptions>`
  into a prefix under the checkout's .zig-cache, deleted after the run unless
  -KeepBuild), so the options it records are the ones that built the
  executable. It records the commit (and refuses a checkout with tracked
  changes), the mode and target the build summary's
  `compile test ghostty-test <mode> <target>` line names, and `zig version`,
  and runs the executable from the checkout. This is how a gate list is taken.
* Declared executables (-TestExe): for executables the script did not build,
  such as the lib-vt test executables (no build step installs them;
  `zig build test-lib-vt -Demit-lib-vt=true` leaves them under
  `.zig-cache\o\<hash>\`). -Revision, -BuildOptions and -ZigVersion are
  required and recorded as declared.
* Imported logs (-TestLog): for a log a run already wrote, such as CI's
  ghostty-test.log. It needs the same declarations, -TestLogExitCode (the exit
  code of the run that wrote it) and the run's own environment record
  (-TestLogFacts, a file `-WriteFacts` wrote beside that run); without one,
  every environment fact is recorded as `unknown`, and the compare then
  refuses an approval that needs a fact.

Run an executable from the checkout that built it (build mode always does): a
test reads the updater's version fixture through a path relative to the build
root (`windows_version_fixture.exe_path`) and fails anywhere else.

Names. For an executable, the script first asks it for its tests' names in
the runner's server mode (`--listen=-`, `query_test_metadata`, the protocol the
build runner uses; Zig 0.15.2 and 0.17.1 frame it alike), so a name holding
`...` or a newline is read exactly. Then it runs the executable in terminal
mode, which prints `<k>/<M> <name>...` as test k starts, then whatever the test
prints, then `OK`, `SKIP` or `FAIL (<error>)` (on the header line for a quiet
test), and after the last test a closing line and its trailers:
`N errors were logged.`, `N tests leaked memory.` (src/test_runner.zig). The
parser follows only that structure:

* test k's block starts at the line that begins with exactly
  `<k>/<M> <name k>...`, in index order, and runs to the next one or to the
  closing line;
* a block's result is its one result-shaped line (or a header line that ends
  in one). A block with two, as when a test prints a bare `OK` or `SKIP`
  before its result, or with none, as when a test's output without a newline
  runs into its result, fails the log: a test's own output cannot change a
  result or a name;
* an imported log has no names to check against, so a header line that holds
  `...` more than once, or any other line that holds `...` (which could be the
  rest of a name that holds a newline), fails it;
* the closing line's counts must match the blocks, and a panic line, an error
  or leak trailer, or a nonzero exit makes the run not green.

Rows are `<suite><TAB><result><TAB><count><TAB><qualified name>`, the name with
`\` written `\\` and a tab, CR or LF written `\t`, `\r`, `\n`, sorted by ordinal
suite, name and result, between the header and an `# end:` line the compare
checks, as UTF-8 without a BOM with LF line ends. The list is written whenever
the log parses, so failures stay visible; the script exits 1 when the run is
not green or the log does not parse (then no list is written).

Environment facts. Some tests run or skip by the environment, not the code, so
the header records, before the run, the facts they read (`# env:` lines):

  cwd-on-temp-drive      the working directory is on the temporary directory's
                         drive; "image load: windows file path that is not
                         drive-absolute is refused" (graphics_image.zig) skips
                         without it
  temp-makes-8dot3-names the temporary directory's volume gives a long file name
                         an 8.3 alias; "security regression win32 link opener
                         screens the long name behind an 8.3 alias" skips without
  store-alias            `usable` when %LOCALAPPDATA%\Microsoft\WindowsApps holds
                         a wt.exe or winget.exe App Execution Alias (reparse tag
                         APPEXECLINK) whose target exists; "shell discovery
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
build or the run, and stops at once if one differs. The compare checks them
again.

  pwsh scripts/capture-test-ran-list.ps1 -Checkout . -BuildOptions none -OutFile ran-list-plain.tsv
  pwsh scripts/capture-test-ran-list.ps1 -Checkout . -BuildOptions '-Dcustom-shaders=true' -OutFile ran-list-ci.tsv
  pwsh scripts/capture-test-ran-list.ps1 -WriteFacts run-facts.txt     (beside a run whose log is imported later)

Pass several executables from PowerShell (`-TestExe a.exe, b.exe`): `pwsh -File`
hands a comma-separated argument to the script as one path.
#>
[CmdletBinding()]
param(
    # Build mode: the checkout to build ghostty-test in and run it from.
    [string] $Checkout,
    # The zig build options, space separated (build mode: passed to zig build,
    # after -Demit-test-exe=true -Demit-exe=false; otherwise recorded).
    [string] $BuildOptions,
    [string[]] $TestExe = @(),
    [string[]] $TestLog = @(),
    [int[]] $TestLogExitCode = @(),
    # The environment record of the run that wrote the -TestLog logs.
    [string] $TestLogFacts,
    # One label per input.
    [string[]] $Suite = @(),
    [string] $OutFile,
    # Declared executables and imported logs only; build mode reads them itself.
    [string] $Revision,
    [string] $ZigVersion,
    [string] $LogDirectory,
    # Declared executables: the checkout that built them (see above).
    [string] $WorkingDirectory,
    # A baseline list whose environment facts this run must have.
    [string] $EnvironmentOf,
    # Write this environment's facts to a file and run nothing.
    [string] $WriteFacts,
    [int] $TimeoutMinutes = 90,
    # Build mode: take a list of a checkout with tracked changes (a control;
    # the compare refuses the list unless it is told the same).
    [switch] $AllowDirty,
    # Build mode: keep the installed executable after the run.
    [switch] $KeepBuild,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

$script:RanListFormat = '# noctty test ran list v3'
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

# A name as a list row holds it: one line, one field.
function ConvertTo-RanListName {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Name)
    return $Name.Replace('\', '\\').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
}

# Reads exactly $Count bytes, or throws after $Seconds.
function Read-RanListBytes {
    param([System.IO.Stream] $Stream, [int] $Count, [int] $Seconds)
    $buffer = [byte[]]::new($Count)
    $done = 0
    while ($done -lt $Count) {
        $read = $Stream.ReadAsync($buffer, $done, $Count - $done)
        if (-not $read.Wait([TimeSpan]::FromSeconds($Seconds))) { throw "The test executable sent nothing for $Seconds s." }
        if ($read.Result -eq 0) { throw 'The test executable closed its output before it sent its test names.' }
        $done += $read.Result
    }
    return , $buffer
}

# The executable's test names, in index order, from the runner's server mode:
# the client sends query_test_metadata (tag 4, no body) and the server answers
# test_metadata (tag 3): string_bytes_len and tests_len (u32 each), the names'
# offsets into string_bytes, the expected panic messages' offsets, then the
# NUL-terminated strings (std/zig/Server.zig, std/zig/Client.zig).
function Get-ZigTestNames {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Directory, [int] $Seconds = 60)
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Path)
    $psi.ArgumentList.Add('--listen=-')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Directory
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $err = $process.StandardError.ReadToEndAsync()
        $in = $process.StandardInput.BaseStream
        $out = $process.StandardOutput.BaseStream
        $query = [byte[]]::new(8)
        [BitConverter]::GetBytes([uint32]4).CopyTo($query, 0)
        $in.Write($query, 0, 8)
        $in.Flush()
        $names = $null
        for ($messages = 0; $null -eq $names; $messages++) {
            if ($messages -gt 16) { throw 'The test executable sent no test metadata.' }
            $header = Read-RanListBytes -Stream $out -Count 8 -Seconds $Seconds
            $tag = [BitConverter]::ToUInt32($header, 0)
            $length = [BitConverter]::ToUInt32($header, 4)
            $body = if ($length -gt 0) { Read-RanListBytes -Stream $out -Count ([int]$length) -Seconds $Seconds } else { [byte[]]::new(0) }
            if ($tag -ne 3) { continue }
            $stringsLength = [BitConverter]::ToUInt32($body, 0)
            $tests = [BitConverter]::ToUInt32($body, 4)
            $strings = 8 + 8 * $tests
            if ($body.Length -ne $strings + $stringsLength) { throw "The test metadata is $($body.Length) bytes, not $($strings + $stringsLength)." }
            $list = [Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $tests; $i++) {
                $start = $strings + [BitConverter]::ToUInt32($body, 8 + 4 * $i)
                $end = [Array]::IndexOf($body, [byte]0, $start)
                if ($end -lt 0) { throw "Test $($i + 1)'s name has no terminator." }
                $list.Add([System.Text.Encoding]::UTF8.GetString($body, $start, $end - $start))
            }
            $names = $list.ToArray()
        }
        [void] $in.WriteAsync([byte[]]::new(8), 0, 8).Wait([TimeSpan]::FromSeconds(5))
        $in.Close()
        if (-not $process.WaitForExit($Seconds * 1000)) { throw 'The test executable did not exit after the names query.' }
        [void] $err.Wait([TimeSpan]::FromSeconds(5))
        return , $names
    }
    finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

# Parses the runner's terminal-mode lines. With -Names (the executable's own),
# each block is found by its exact header; without them (an imported log) the
# header is the next index and the name runs to the first `...`, which only an
# unambiguous log allows. Returns the tests (Index, Name, Result), the trailers
# and the reasons the log cannot stand for a whole run.
function ConvertFrom-ZigRunnerLog {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines,
        [AllowNull()] [string[]] $Names = $null
    )
    $problems = [Collections.Generic.List[string]]::new()
    $text = $Lines -join "`n"
    $closing = '(?m)^(?:All (\d+) tests passed\.|(\d+) passed; (\d+) skipped; (\d+) failed\.)$'
    $blocks = [Collections.Generic.List[object]]::new()
    $closeAt = -1
    $summary = $null
    $total = 0

    if ($null -ne $Names) {
        $total = $Names.Count
        $from = 0
        for ($k = 1; $k -le $total; $k++) {
            $prefix = "$k/$total $($Names[$k - 1])..."
            $at = -1
            for ($i = $text.IndexOf($prefix, $from, [StringComparison]::Ordinal); $i -ge 0; $i = $text.IndexOf($prefix, $i + 1, [StringComparison]::Ordinal)) {
                if ($i -eq 0 -or $text[$i - 1] -eq "`n") { $at = $i; break }
            }
            if ($at -lt 0) { $problems.Add("Test $k's header ('$k/$total ' and its name) is not in the log, in order."); break }
            if ($blocks.Count -gt 0) { $blocks[$blocks.Count - 1].End = $at - 1 }
            $blocks.Add([pscustomobject]@{ Index = $k; Name = $Names[$k - 1]; Start = $at + $prefix.Length; End = $text.Length })
            $from = $at + $prefix.Length
        }
        $tail = if ($blocks.Count -gt 0) { $blocks[$blocks.Count - 1].Start } else { 0 }
        $found = [regex]::Matches($text.Substring($tail), $closing)
        if ($found.Count -gt 0) {
            $last = $found[$found.Count - 1]
            $closeAt = $tail + $last.Index
            if ($blocks.Count -gt 0) { $blocks[$blocks.Count - 1].End = $closeAt - 1 }
            $summary = $last
        }
        foreach ($b in $blocks) { $b | Add-Member -NotePropertyName Pieces -NotePropertyValue @($text.Substring($b.Start, [Math]::Max(0, $b.End - $b.Start)) -split "`n") }
    }
    else {
        $lineList = @($text -split "`n")
        $offset = 0
        $current = $null
        foreach ($line in $lineList) {
            $here = $offset
            $offset += $line.Length + 1
            if ($closeAt -ge 0) { continue }
            if ($line -match $closing) { $closeAt = $here; $summary = [regex]::Match($line, $closing); continue }
            $header = [regex]::Match($line, '^(\d+)/(\d+) (.*)$')
            if ($header.Success -and $header.Groups[3].Value.Contains('...')) {
                $index = [int]$header.Groups[1].Value
                $count = [int]$header.Groups[2].Value
                if ($index -eq $blocks.Count + 1 -and ($total -eq 0 -or $count -eq $total)) {
                    $total = $count
                    $rest = $header.Groups[3].Value
                    $parts = $rest -split '\.\.\.', 0
                    if ($parts.Count -ne 2) {
                        $problems.Add("Test ${index}: its header line holds '...' more than once, so an imported log cannot tell its name from its output (capture from the executable, which serves its names).")
                    }
                    $current = [pscustomobject]@{ Index = $index; Name = $parts[0]; Pieces = [Collections.Generic.List[string]]::new() }
                    $current.Pieces.Add($parts[$parts.Count - 1])
                    $blocks.Add($current)
                    continue
                }
                $problems.Add("A line looks like the runner's header for test $index of $count out of sequence (expected test $($blocks.Count + 1)); a test's output cannot be told from the runner's.")
            }
            if ($null -ne $current) {
                if ($line.Contains('...')) {
                    $problems.Add("Test $($current.Index): a line after its header holds '...', which could be the rest of a test name that holds a newline; an imported log cannot tell (capture from the executable).")
                }
                $current.Pieces.Add($line)
            }
        }
        if ($closeAt -lt 0) { $closeAt = -1 }
    }

    $tests = [Collections.Generic.List[object]]::new()
    foreach ($block in $blocks) {
        $results = @($block.Pieces | Where-Object { $_ -match $script:RanListResult })
        if ($results.Count -eq 0) {
            $problems.Add("Test $($block.Index) has no result line (a test's output that does not end in a newline runs into it).")
            continue
        }
        if ($results.Count -gt 1) {
            $problems.Add("Test $($block.Index)'s block holds $($results.Count) result-shaped lines (OK, SKIP or FAIL (...)): its output cannot be told from its result.")
            continue
        }
        if ($block.Name.Length -eq 0) { $problems.Add("Test $($block.Index) has an empty name."); continue }
        $result = ([regex]::Match($results[0], $script:RanListResult)).Groups[1].Value -replace ' \(.*\)$', ''
        $tests.Add([pscustomobject]@{ Index = $block.Index; Name = $block.Name; Result = $result })
    }

    $trailers = @{ ErrorsLogged = 0; Leaked = 0 }
    $after = 0
    if ($closeAt -ge 0) {
        $afterLines = @($text.Substring($closeAt) -split "`n" | Select-Object -Skip 1)
        foreach ($line in $afterLines) {
            if ($line -match '^(\d+) errors were logged\.$') { $trailers.ErrorsLogged = [int]$Matches[1]; continue }
            if ($line -match '^(\d+) tests leaked memory\.$') { $trailers.Leaked = [int]$Matches[1]; continue }
            if ($line -match '^(\d+) fuzz tests found\.$') { continue }
            if ($line.Trim().Length -gt 0) { $after++ }
        }
    }
    $panics = @($Lines | Where-Object { $_ -match '^thread \d+ panic: ' -or $_ -match '^panic: ' }).Count

    if ($blocks.Count -eq 0 -and $total -eq 0) { $problems.Add('The log holds no per-test lines (run the test executable directly, stderr not a terminal).') }
    elseif ($null -eq $summary) { $problems.Add("The log has no closing line, so the run did not finish ($($blocks.Count) of $total tests reported).") }
    else {
        $passed = if ($summary.Groups[1].Success) { [int]$summary.Groups[1].Value } else { [int]$summary.Groups[2].Value }
        $skipped = if ($summary.Groups[1].Success) { 0 } else { [int]$summary.Groups[3].Value }
        $failedCount = if ($summary.Groups[1].Success) { 0 } else { [int]$summary.Groups[4].Value }
        if ($blocks.Count -ne $total -or ($passed + $skipped + $failedCount) -ne $total) {
            $problems.Add("The log is inconsistent: $($blocks.Count) tests reported, $total announced, the closing line counts $($passed + $skipped + $failedCount).")
        }
        foreach ($status in @(@('OK', $passed, 'passed'), @('SKIP', $skipped, 'skipped'), @('FAIL', $failedCount, 'failed'))) {
            $actual = @($tests | Where-Object Result -ceq $status[0]).Count
            if ($actual -ne $status[1]) { $problems.Add("Parsed $actual $($status[2]) tests but the closing line says $($status[1]).") }
        }
        if ($after -gt 0) { $problems.Add("$after lines follow the closing line that are not the runner's trailers.") }
    }
    return [pscustomobject]@{
        Tests = $tests.ToArray(); Problems = $problems.ToArray()
        ErrorsLogged = $trailers.ErrorsLogged; Leaked = $trailers.Leaked; Panics = $panics
    }
}

# Counts each (suite, name, result), the name written as a row holds it.
function Get-RanListRows {
    param([Parameter(Mandatory)] [string] $SuiteName, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Tests)
    $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($test in $Tests) {
        $key = "$(ConvertTo-RanListName $test.Name)`t$($test.Result)"
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
    $lines.Add("# columns: suite`tresult`tcount`tqualified name (\\, \t, \r, \n escaped)")
    $total = 0
    foreach ($key in $keys) {
        $row = $byKey[$key]
        $lines.Add("$($row.Suite)`t$($row.Result)`t$($row.Count)`t$($row.Name)")
        $total += $row.Count
    }
    $lines.Add("# end: rows=$($keys.Count) tests=$total")
    return ($lines -join "`n") + "`n"
}

# The keys of the environment facts (see the description).
function Get-RanListFactKeys {
    return @('cwd-on-temp-drive', 'temp-makes-8dot3-names', 'store-alias') + @($script:RanListFonts | ForEach-Object { "font:$_" }) + @($script:RanListProbeVariables | ForEach-Object { "env:$_" })
}

# Whether $Path is an App Execution Alias whose target exists: the reparse
# tag is IO_REPARSE_TAG_APPEXECLINK, and the third string of its data names
# the target, as `shell discovery accepts a real installed Store execution
# alias` (src/config/windows_shell.zig) requires.
function Test-RanListExecutionAlias {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not ('RanListReparse' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RanListReparse {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle device, uint code, IntPtr inBuffer, uint inSize, byte[] outBuffer, uint outSize, out uint returned, IntPtr overlapped);
    public static string AppExecLinkTarget(string path) {
        // FILE_READ_ATTRIBUTES, share all, OPEN_EXISTING, OPEN_REPARSE_POINT | BACKUP_SEMANTICS.
        using (var h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x00200000 | 0x02000000, IntPtr.Zero)) {
            if (h.IsInvalid) return null;
            var buffer = new byte[16 * 1024];
            uint returned;
            // FSCTL_GET_REPARSE_POINT.
            if (!DeviceIoControl(h, 0x000900A8, IntPtr.Zero, 0, buffer, (uint)buffer.Length, out returned, IntPtr.Zero)) return null;
            if (returned < 12 || BitConverter.ToUInt32(buffer, 0) != 0x8000001B) return null;
            // Tag, data length, reserved, version; then NUL-terminated UTF-16 strings.
            var strings = System.Text.Encoding.Unicode.GetString(buffer, 12, (int)returned - 12).Split('\0');
            return strings.Length > 2 ? strings[2] : null;
        }
    }
}
'@
    }
    $target = [RanListReparse]::AppExecLinkTarget($Path)
    return -not [string]::IsNullOrEmpty($target) -and [System.IO.File]::Exists($target)
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
    $usable = $null -ne $apps -and @(@('wt.exe', 'winget.exe') | Where-Object { Test-RanListExecutionAlias (Join-Path $apps $_) }).Count -gt 0
    $facts['store-alias'] = $(if ($usable) { 'usable' } else { 'absent' })
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

# Reads `# env: key=value` (or `key=value`) lines: a run's own environment record.
function Read-RanListFacts {
    param([Parameter(Mandatory)] [string] $Path)
    $facts = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
        if ($line -match '^(?:# env: )?([^#=][^=]*)=(.*)$') { $facts[$Matches[1]] = $Matches[2] }
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

# Stops the capture when this run's facts differ from a baseline list's.
function Assert-RanListEnvironmentOf {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Facts, [Parameter(Mandatory)] [string] $Baseline)
    $basePath = Resolve-RanListPath $Baseline
    if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) { throw "The baseline '$basePath' does not exist." }
    $baseFacts = @{}
    foreach ($l in [System.IO.File]::ReadAllLines($basePath)) { if ($l -match '^# env: ([^=]+)=(.*)$') { $baseFacts[$Matches[1]] = $Matches[2] } }
    $differ = @(@($Facts.Keys) + @($baseFacts.Keys) | Sort-Object -Unique | Where-Object { "$($Facts[$_])" -cne "$($baseFacts[$_])" })
    if ($differ.Count -gt 0) {
        foreach ($key in $differ) { [Console]::Error.WriteLine("RAN LIST: environment fact $key is '$($Facts[$key])' here and '$($baseFacts[$key])' in the baseline.") }
        [Console]::Error.WriteLine('RAN LIST: this run would not be like for like with its baseline; nothing was built or run.')
        exit 1
    }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($WriteFacts)) {
    $dir = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { (Get-Location).Path } else { Resolve-RanListPath $WorkingDirectory }
    $facts = Get-RanListEnvironment -Directory $dir
    $text = (@($facts.Keys | ForEach-Object { "# env: $_=$($facts[$_])" }) -join "`n") + "`n"
    [System.IO.File]::WriteAllText((Resolve-RanListPath $WriteFacts), $text, [System.Text.UTF8Encoding]::new($false))
    exit 0
}
if ([string]::IsNullOrWhiteSpace($OutFile)) { throw 'Pass -OutFile.' }
$outPath = Resolve-RanListPath $OutFile
$LogDirectory = if ([string]::IsNullOrWhiteSpace($LogDirectory)) { Split-Path -Parent $outPath } else { Resolve-RanListPath $LogDirectory }
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$listName = [System.IO.Path]::GetFileNameWithoutExtension($outPath)
$build = [ordered]@{}
$inputs = [Collections.Generic.List[object]]::new()
$prefix = $null
$rows = [Collections.Generic.List[object]]::new()
$suites = [Collections.Generic.List[object]]::new()
$problems = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
# The finally removes the build prefix however the capture stops (a failed
# build too).
try {
    if (-not [string]::IsNullOrWhiteSpace($Checkout)) {
        # Build mode.
        if ($TestExe.Count -or $TestLog.Count -or $Revision -or $ZigVersion -or $WorkingDirectory -or $TestLogFacts) {
            throw 'Build mode (-Checkout) reads the revision, compiler and executable itself; do not pass -TestExe, -TestLog, -TestLogFacts, -Revision, -ZigVersion or -WorkingDirectory with it.'
        }
        if ([string]::IsNullOrWhiteSpace($BuildOptions)) { throw "Pass -BuildOptions: the gate's own options, or 'none'." }
        $root = Resolve-RanListPath $Checkout
        $Revision = (& git -C $root rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $Revision -notmatch '^[0-9a-f]{40}$') { throw "$root is not a git checkout." }
        $dirty = @(& git -C $root status --porcelain --untracked-files=no)
        if ($dirty.Count -gt 0 -and -not $AllowDirty) { throw "$root has tracked changes, so its build is not $Revision; commit them, or pass -AllowDirty for a control." }
        $environment = Get-RanListEnvironment -Directory $root
        if (-not [string]::IsNullOrWhiteSpace($EnvironmentOf)) { Assert-RanListEnvironmentOf -Facts $environment -Baseline $EnvironmentOf }
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
        foreach ($pair in @(@('Revision', $Revision), @('BuildOptions', $BuildOptions), @('ZigVersion', $ZigVersion))) {
            if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1] -ieq 'unknown') { throw "Declared executables and imported logs need -$($pair[0]) (not empty, not 'unknown')." }
        }
        if ($TestExe.Count -and $TestLog.Count) { throw 'Take declared executables and imported logs as separate lists: their environments come from different places.' }
        if ($TestLog.Count -ne $TestLogExitCode.Count) { throw 'Pass one -TestLogExitCode per -TestLog: the exit code of the run that wrote it.' }
        if ($TestLogFacts -and -not $TestLog.Count) { throw '-TestLogFacts is the environment record of the run that wrote -TestLog logs.' }
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
        if ($TestLog.Count) {
            # An imported log's environment is its run's, never this process's.
            $environment = [ordered]@{}
            if ($TestLogFacts) {
                $recorded = Read-RanListFacts -Path (Resolve-RanListPath $TestLogFacts)
                foreach ($key in (Get-RanListFactKeys)) { $environment[$key] = $(if ($recorded.Contains($key)) { $recorded[$key] } else { 'unknown' }) }
            }
            else { foreach ($key in (Get-RanListFactKeys)) { $environment[$key] = 'unknown' } }
        }
        else { $environment = Get-RanListEnvironment -Directory $WorkingDirectory }
        if (-not [string]::IsNullOrWhiteSpace($EnvironmentOf)) { Assert-RanListEnvironmentOf -Facts $environment -Baseline $EnvironmentOf }
        $build['source'] = $(if ($TestLog.Count) { 'imported' } else { 'declared' })
        $declared = @($BuildOptions -split '\s+' | Where-Object { $_ -and $_ -cne 'none' })
        $build['options'] = $(if ($declared.Count) { $declared -join ' ' } else { '(none)' })
        $build['zig'] = $ZigVersion
    }
    $build['filtered'] = ($build['options'] -match '(^|\s)-Dtest-filter(=|\s|$)').ToString().ToLowerInvariant()

    foreach ($item in $inputs) {
        $name = $item.Suite
        if ($name -notmatch '^[A-Za-z0-9._-]+$') { throw "Suite name '$name' must be letters, digits, '.', '_' or '-'." }
        if (-not $seen.Add($name)) { throw "Suite '$name' is given twice." }
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) { throw "'$($item.Path)' does not exist." }
        $names = $null
        if ($item.Kind -eq 'exe') {
            $names = Get-ZigTestNames -Path $item.Path -Directory $WorkingDirectory
            $logPath = Join-Path $LogDirectory "$listName.$name.log"
            Write-Host "Running $name ($($item.Path), $($names.Count) tests) in $WorkingDirectory"
            $exit = Invoke-ZigTestExecutable -Path $item.Path -LogPath $logPath -Directory $WorkingDirectory -Minutes $TimeoutMinutes
        }
        else {
            $logPath = $item.Path
            $exit = $item.Exit
        }
        $parsed = ConvertFrom-ZigRunnerLog -Lines ([System.IO.File]::ReadAllLines($logPath, [System.Text.UTF8Encoding]::new($false))) -Names $names
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
}
finally {
    # The installed executable is about 300 MB; the build cache keeps what a
    # rebuild needs.
    if ($null -ne $prefix -and -not $KeepBuild -and (Test-Path -LiteralPath $prefix)) { Remove-Item -LiteralPath $prefix -Recurse -Force }
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
