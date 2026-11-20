#requires -Version 7.1
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

The record. The fork's test runner (src/test_runner.zig, which build.zig gives
ghostty-test and both lib-vt test executables) takes `--results=<path>` and
then writes what it ran to that new file, as it decided it: a header with
`builtin.zig_version_string`, the optimize mode and the shard, one line per
test in run order with its index, its result (OK, SKIP or FAIL), whether it
leaked, and its name's bytes in hex, and an `end` line with the run's counts.
The script reads names and results only from that record, never from the
printed lines, which a test's own output can imitate. A record that is
missing, has no `end` line, is out of order or does not add up fails the
capture, and so does one from a shard or one that holds no test. The record's
counts and the exit code alone decide whether the run is green: a logged error,
a leak or a FAIL in the record, or a nonzero exit, makes it not green, and a
runner that panics leaves no `end` line. The runner's stderr is kept as the
run's log; lines in it that look like a panic are counted in the suite record
(`panics=`) for a reader, and decide nothing, since a test can print them.

Three ways to take a list:

* Build mode (-Checkout): the script builds `ghostty-test` itself in that
  checkout (`zig build -Demit-test-exe=true -Demit-exe=false <-BuildOptions>`
  into a prefix under the checkout's .zig-cache, removed however the capture
  stops unless -KeepBuild), so the options it records are the ones that built
  the executable. It records the commit (and refuses a checkout with tracked
  changes, before the build and again after the build and after the run), the
  target the build summary's `compile test ghostty-test <mode> <target>` line
  names, and the compiler and mode the record names (which must equal
  `zig version` and the summary's mode), and runs the executable from the
  checkout. This is how a gate list is taken.
* Declared executables (-TestExe): for executables the script did not build,
  such as the lib-vt test executables (no build step installs them;
  `zig build test-lib-vt -Demit-lib-vt=true` leaves them under
  `.zig-cache\o\<hash>\`). -Revision and -BuildOptions are required and
  recorded as declared; the compiler and mode come from the record.
* Imported runs (-TestLog with -TestResults): a run that already happened
  through `--results`, as its stderr log, its record and its exit code
  (-TestLogExitCode), with the run's own environment record (-TestLogFacts, a
  file `-WriteFacts` wrote beside that run); without one, every environment
  fact is recorded as `unknown`, which no approval condition meets. A log of a
  run without a record, such as CI's `zig build test` (the build runner's
  server mode), cannot be imported.

Run an executable from the checkout that built it (build mode always does): a
test reads the updater's version fixture through a path relative to the build
root (`windows_version_fixture.exe_path`) and fails anywhere else.

Rows are `<suite><TAB><result><TAB><count><TAB><qualified name>`, sorted by
ordinal suite, name and result, between the header and an `# end:` line the
compare checks, as UTF-8 without a BOM with LF line ends. A name is written as
UTF-8 where its bytes are UTF-8, with `\` written `\\`, tab, CR and LF written
`\t`, `\r`, `\n`, and every other control character and every byte that is not
part of a UTF-8 sequence written `\xHH`, so two names are one row only when
their bytes are equal. The list is written whenever the record reads, so
failures stay visible; the script exits 1 when the run is not green or the
record does not read (then no list is written).

Environment facts. Some tests run or skip by the environment, not the code, so
the header records, before the run, the facts they read (`# env:` lines):

  cwd-on-temp-drive      the working directory is on the temporary directory's
                         drive; "image load: windows file path that is not
                         drive-absolute is refused" (graphics_image.zig) skips
                         without it
  temp-makes-8dot3-names the temporary directory's volume gives a long file name
                         an 8.3 alias; "security regression win32 link opener
                         screens the long name behind an 8.3 alias" skips without
  font:<family>          `present` when a font of that family is registered (a
                         value name in the registry's Fonts keys starts with
                         it) or a font file the registry does not name, in the
                         system or per-user font directory, declares it (the
                         family, typographic family or full name of a face in
                         its `name` table holds it); `unknown` when such a file
                         cannot be read; else `absent`. Font discovery
                         (src/font/discovery_windows.zig) scans those
                         directories as well as the registry, and the harfbuzz
                         shaping tests that discover "Arial Unicode MS", "Noto
                         Sans Chakma" or "Noto Serif Tibetan" skip without it
  env:<NAME>             whether an opt-in probe variable is `1`, `unset` or
                         another value (never printed); the ConPTY probes, the
                         link-opener PATHEXT probe and the local-path sweep skip
                         unless theirs is `1`

-EnvironmentOf <list> checks these facts against a baseline list's before the
build or the run, and stops at once if one differs. The compare checks them
again.

  pwsh scripts/capture-test-ran-list.ps1 -Checkout . -BuildOptions none -OutFile ran-list-plain.tsv
  pwsh scripts/capture-test-ran-list.ps1 -Checkout . -BuildOptions '-Dcustom-shaders=true' -OutFile ran-list-ci.tsv
  pwsh scripts/capture-test-ran-list.ps1 -WriteFacts run-facts.txt     (beside a run that is imported later)

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
    # An imported run: its stderr log, its --results record, its exit code.
    [string[]] $TestLog = @(),
    [string[]] $TestResults = @(),
    [int[]] $TestLogExitCode = @(),
    # The environment record of the run that wrote the -TestLog logs.
    [string] $TestLogFacts,
    # One label per input.
    [string[]] $Suite = @(),
    [string] $OutFile,
    # Declared executables and imported runs only; build mode reads it itself.
    [string] $Revision,
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

$script:RanListFormat = '# noctty test ran list v4'
$script:RanListResultsFormat = 'noctty test results v1'
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

# The length of the UTF-8 sequence that starts at $Bytes[$At], or 0 when none
# does (RFC 3629: no overlong forms, no surrogates, nothing above U+10FFFF).
function Get-RanListUtf8Length {
    param([byte[]] $Bytes, [int] $At)
    $b = $Bytes[$At]
    if ($b -lt 0x80) { return 1 }
    $length = 0; $low = 0x80; $high = 0xBF
    if ($b -ge 0xC2 -and $b -le 0xDF) { $length = 2 }
    elseif ($b -eq 0xE0) { $length = 3; $low = 0xA0 }
    elseif ($b -eq 0xED) { $length = 3; $high = 0x9F }
    elseif ($b -ge 0xE1 -and $b -le 0xEF) { $length = 3 }
    elseif ($b -eq 0xF0) { $length = 4; $low = 0x90 }
    elseif ($b -eq 0xF4) { $length = 4; $high = 0x8F }
    elseif ($b -ge 0xF1 -and $b -le 0xF3) { $length = 4 }
    else { return 0 }
    if ($At + $length -gt $Bytes.Length) { return 0 }
    $second = $Bytes[$At + 1]
    if ($second -lt $low -or $second -gt $high) { return 0 }
    for ($k = 2; $k -lt $length; $k++) {
        if ($Bytes[$At + $k] -lt 0x80 -or $Bytes[$At + $k] -gt 0xBF) { return 0 }
    }
    return $length
}

# A name's bytes as a list row holds them (see the description): one line,
# one field, one text per byte string.
function ConvertTo-RanListName {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes)
    $text = [System.Text.StringBuilder]::new()
    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    for ($i = 0; $i -lt $Bytes.Length) {
        $b = $Bytes[$i]
        if ($b -eq 0x5C) { [void] $text.Append('\\'); $i++; continue }
        if ($b -eq 0x09) { [void] $text.Append('\t'); $i++; continue }
        if ($b -eq 0x0D) { [void] $text.Append('\r'); $i++; continue }
        if ($b -eq 0x0A) { [void] $text.Append('\n'); $i++; continue }
        if ($b -lt 0x20 -or $b -eq 0x7F) { [void] $text.Append(('\x{0:x2}' -f $b)); $i++; continue }
        $length = Get-RanListUtf8Length -Bytes $Bytes -At $i
        if ($length -eq 0) { [void] $text.Append(('\x{0:x2}' -f $b)); $i++; continue }
        $char = $strict.GetString($Bytes, $i, $length)
        # C1 controls (U+0080 to U+009F) are control characters too.
        if ($length -eq 2 -and [int][char]$char[0] -le 0x9F) {
            for ($k = 0; $k -lt $length; $k++) { [void] $text.Append(('\x{0:x2}' -f $Bytes[$i + $k])) }
        }
        else { [void] $text.Append($char) }
        $i += $length
    }
    return $text.ToString()
}

# Reads a runner's --results record. Returns its compiler, mode, tests (Index,
# Name as a row writes it, Result, Leaked), its end counts and the reasons it
# cannot stand for a whole run.
function Read-ZigTestResults {
    param([Parameter(Mandatory)] [string] $Path)
    $problems = [Collections.Generic.List[string]]::new()
    $tests = [Collections.Generic.List[object]]::new()
    $record = [pscustomobject]@{ Zig = $null; Mode = $null; Tests = @(); End = $null; Problems = $problems }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $problems.Add("There is no results file '$Path' (the runner did not start, or is not the fork's src/test_runner.zig).")
        return $record
    }
    # Latin-1 maps each byte to one character, so the check below sees every byte.
    $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($Path))
    if ($text -cmatch '[^\n\x20-\x7E]') {
        $problems.Add("'$Path' holds bytes the runner does not write (it writes ASCII lines only).")
        return $record
    }
    if ($text.Length -eq 0 -or -not $text.EndsWith("`n")) {
        $problems.Add("'$Path' does not end in a line end, so the run stopped while it wrote it.")
        return $record
    }
    $lines = $text.Substring(0, $text.Length - 1).Split("`n")
    if ($lines.Count -lt 4 -or $lines[0] -cne $script:RanListResultsFormat -or $lines[1] -cnotmatch '^zig (\S+)$') {
        $problems.Add("'$Path' does not start with the '$($script:RanListResultsFormat)' header.")
        return $record
    }
    $record.Zig = $Matches[1]
    if ($lines[2] -cnotmatch '^mode (\S+)$') { $problems.Add("'$Path' names no mode."); return $record }
    $record.Mode = $Matches[1]
    if ($lines[3] -cnotmatch '^shard ([0-9]+)/([0-9]+)$') { $problems.Add("'$Path' names no shard."); return $record }
    if ($Matches[1] -cne '1' -or $Matches[2] -cne '1') {
        $problems.Add("'$Path' is shard $($Matches[1])/$($Matches[2]) of a run, not a whole run.")
        return $record
    }
    for ($i = 4; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -ne $record.End) { $problems.Add("'$Path' has text after its end line."); break }
        $m = [regex]::Match($line, '^test ([0-9]+) (OK|SKIP|FAIL) ([01]) ((?:[0-9a-f]{2})+)$')
        if ($m.Success) {
            $index = [int]$m.Groups[1].Value
            if ($index -ne $tests.Count + 1) { $problems.Add("'$Path' line $($i + 1) is test $index, not test $($tests.Count + 1)."); break }
            $name = [Convert]::FromHexString($m.Groups[4].Value)
            $tests.Add([pscustomobject]@{ Index = $index; Name = (ConvertTo-RanListName -Bytes $name); Result = $m.Groups[2].Value; Leaked = $m.Groups[3].Value -ceq '1' })
            continue
        }
        $m = [regex]::Match($line, '^end tests=([0-9]+) ok=([0-9]+) skip=([0-9]+) fail=([0-9]+) leaked=([0-9]+) errors-logged=([0-9]+)$')
        if ($m.Success) {
            $record.End = [pscustomobject]@{
                Tests = [int]$m.Groups[1].Value; Ok = [int]$m.Groups[2].Value; Skip = [int]$m.Groups[3].Value
                Fail = [int]$m.Groups[4].Value; Leaked = [int]$m.Groups[5].Value; ErrorsLogged = [int]$m.Groups[6].Value
            }
            continue
        }
        $problems.Add("'$Path' line $($i + 1) is not a test or end line.")
        break
    }
    $record.Tests = $tests.ToArray()
    if ($problems.Count -gt 0) { return $record }
    if ($null -eq $record.End) {
        $problems.Add("'$Path' has no end line, so the run stopped after test $($tests.Count).")
        return $record
    }
    $e = $record.End
    $ok = @($tests | Where-Object Result -ceq 'OK').Count
    $skip = @($tests | Where-Object Result -ceq 'SKIP').Count
    $fail = @($tests | Where-Object Result -ceq 'FAIL').Count
    $leaked = @($tests | Where-Object Leaked).Count
    if ($e.Tests -ne $tests.Count -or $e.Ok -ne $ok -or $e.Skip -ne $skip -or $e.Fail -ne $fail -or $e.Leaked -ne $leaked) {
        $problems.Add("'$Path' does not add up: its end line counts tests=$($e.Tests) ok=$($e.Ok) skip=$($e.Skip) fail=$($e.Fail) leaked=$($e.Leaked), its test lines $($tests.Count), $ok, $skip, $fail and $leaked.")
    }
    return $record
}

# The lines of the runner's stderr that look like a panic. Reported only: a
# test can print such a line, and a runner that panics leaves no `end` line.
function Get-ZigPanicLineCount {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines)
    return @($Lines | Where-Object { $_ -cmatch '^thread [0-9]+ panic: ' -or $_ -cmatch '^panic: ' }).Count
}

# Counts each (suite, name, result); the names are already as a row writes them.
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

# Whether a suite's run is green: it exited 0, and its record counts no
# failure, logged error or leak.
function Test-RanListSuiteGreen {
    param([Parameter(Mandatory)] [object] $Suite)
    return [string]::Equals("$($Suite.Exit)", '0', [StringComparison]::Ordinal) -and [int]$Suite.Fail -eq 0 -and [int]$Suite.ErrorsLogged -eq 0 -and [int]$Suite.Leaked -eq 0
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
    $lines.Add("# columns: suite`tresult`tcount`tqualified name (\\, \t, \r, \n and \xHH escaped)")
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
    return @('cwd-on-temp-drive', 'temp-makes-8dot3-names') + @($script:RanListFonts | ForEach-Object { "font:$_" }) + @($script:RanListProbeVariables | ForEach-Object { "env:$_" })
}

# A dictionary whose keys compare ordinally, in insertion order (PowerShell's
# [ordered] and @{} fold case).
function New-RanListMap {
    return [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
}

# Reads a big-endian integer of $Size bytes at $At, or throws past the end.
function Read-RanListBigEndian {
    param([byte[]] $Bytes, [long] $At, [int] $Size)
    if ($At -lt 0 -or $At + $Size -gt $Bytes.Length) { throw 'past the end of the font file' }
    [long] $v = 0
    for ($k = 0; $k -lt $Size; $k++) { $v = ($v -shl 8) -bor $Bytes[$At + $k] }
    return $v
}

# The family names a font file declares: name IDs 1 (family), 4 (full name)
# and 16 (typographic family) of each face's `name` table, every face of a
# .ttc or .otc collection included. $null when the file cannot be read as an
# OpenType font.
function Get-RanListFontFamilies {
    param([Parameter(Mandatory)] [string] $Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $faces = @([long] 0)
        if ($bytes.Length -ge 12 -and [string]::Equals([System.Text.Encoding]::ASCII.GetString($bytes, 0, 4), 'ttcf', [StringComparison]::Ordinal)) {
            $count = Read-RanListBigEndian $bytes 8 4
            if ($count -lt 1 -or $count -gt 4096) { return $null }
            $faces = @(for ($i = 0; $i -lt $count; $i++) { Read-RanListBigEndian $bytes (12 + 4 * $i) 4 })
        }
        $names = [Collections.Generic.List[string]]::new()
        foreach ($face in $faces) {
            $tables = Read-RanListBigEndian $bytes ($face + 4) 2
            $name = $null
            for ($i = 0; $i -lt $tables; $i++) {
                $record = $face + 12 + 16 * $i
                if ($record + 16 -gt $bytes.Length) { return $null }
                if ([string]::Equals([System.Text.Encoding]::ASCII.GetString($bytes, [int]$record, 4), 'name', [StringComparison]::Ordinal)) {
                    $name = Read-RanListBigEndian $bytes ($record + 8) 4
                }
            }
            if ($null -eq $name) { return $null }
            $entries = Read-RanListBigEndian $bytes ($name + 2) 2
            $strings = $name + (Read-RanListBigEndian $bytes ($name + 4) 2)
            for ($i = 0; $i -lt $entries; $i++) {
                $entry = $name + 6 + 12 * $i
                $platform = Read-RanListBigEndian $bytes $entry 2
                $id = Read-RanListBigEndian $bytes ($entry + 6) 2
                if ($id -ne 1 -and $id -ne 4 -and $id -ne 16) { continue }
                $length = Read-RanListBigEndian $bytes ($entry + 8) 2
                $at = $strings + (Read-RanListBigEndian $bytes ($entry + 10) 2)
                if ($at + $length -gt $bytes.Length) { return $null }
                $encoding = if ($platform -eq 0 -or $platform -eq 3) { [System.Text.Encoding]::BigEndianUnicode } elseif ($platform -eq 1) { [System.Text.Encoding]::Latin1 } else { $null }
                if ($null -ne $encoding) { $names.Add($encoding.GetString($bytes, [int]$at, [int]$length)) }
            }
        }
        return , $names.ToArray()
    }
    catch { return $null }
}

# The font files of the system and per-user font directories that no value of
# the registry's Fonts keys names, as font discovery collects them: files with a
# .ttf, .otf, .ttc or .otc extension directly in each directory.
function Get-RanListUnregisteredFontFiles {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RegisteredPaths, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Directories)
    $registered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $RegisteredPaths) { [void] $registered.Add($p) }
    $files = [Collections.Generic.List[string]]::new()
    foreach ($dir in $Directories) {
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue) {
            if (@('.ttf', '.otf', '.ttc', '.otc') -notcontains $f.Extension.ToLowerInvariant()) { continue }
            if (-not $registered.Contains($f.FullName)) { $files.Add($f.FullName) }
        }
    }
    return , $files.ToArray()
}

# The font facts (see the description) from the registry's value names and the
# family names of the font files it does not name ($null for a file that could
# not be read): present beats unknown, and unknown beats absent.
function Get-RanListFontFacts {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RegisteredNames, [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $UnregisteredFamilies)
    $facts = New-RanListMap
    foreach ($family in $script:RanListFonts) {
        $value = 'absent'
        if (@($RegisteredNames | Where-Object { $_.StartsWith($family, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { $value = 'present' }
        else {
            foreach ($declared in $UnregisteredFamilies) {
                if ($null -eq $declared) { $value = 'unknown'; continue }
                if (@($declared | Where-Object { $_.IndexOf($family, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) { $value = 'present'; break }
            }
        }
        $facts["font:$family"] = $value
    }
    return $facts
}

# The environment facts tests read (see the description), for a run from
# $Directory with this process's environment.
function Get-RanListEnvironment {
    param([Parameter(Mandatory)] [string] $Directory)
    $facts = New-RanListMap
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
    $systemFonts = if ($env:WINDIR) { Join-Path $env:WINDIR 'Fonts' } elseif ($env:SystemRoot) { Join-Path $env:SystemRoot 'Fonts' } else { $null }
    $userFonts = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts' } else { $null }
    $names = [Collections.Generic.List[string]]::new()
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
        $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        foreach ($v in $item.GetValueNames()) {
            $names.Add($v)
            # A value names its file by a path, or by a name in the system font directory.
            $file = "$($item.GetValue($v))"
            if ([string]::IsNullOrWhiteSpace($file)) { continue }
            try { $paths.Add([System.IO.Path]::GetFullPath($(if ([System.IO.Path]::IsPathRooted($file) -or $null -eq $systemFonts) { $file } else { Join-Path $systemFonts $file }))) } catch { }
        }
    }
    $unregistered = [Collections.Generic.List[object]]::new()
    foreach ($file in (Get-RanListUnregisteredFontFiles -RegisteredPaths $paths.ToArray() -Directories @($systemFonts, $userFonts))) {
        $unregistered.Add((Get-RanListFontFamilies -Path $file))
    }
    $fonts = Get-RanListFontFacts -RegisteredNames $names.ToArray() -UnregisteredFamilies $unregistered.ToArray()
    foreach ($key in $fonts.Keys) { $facts[$key] = $fonts[$key] }
    foreach ($name in $script:RanListProbeVariables) {
        $value = [Environment]::GetEnvironmentVariable($name)
        $facts["env:$name"] = $(if ($null -eq $value) { 'unset' } elseif ([string]::Equals($value, '1', [StringComparison]::Ordinal)) { '1' } else { 'other' })
    }
    return $facts
}

# Reads `# env: key=value` (or `key=value`) lines: a run's own environment record.
function Read-RanListFacts {
    param([Parameter(Mandatory)] [string] $Path)
    $facts = New-RanListMap
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
        if ($line -cmatch '^(?:# env: )?([^#=][^=]*)=(.*)$') { $facts[$Matches[1]] = $Matches[2] }
    }
    return $facts
}

# Runs one test executable with `--results=$ResultsPath`, stderr and stdout
# redirected (the runner then prints per-test lines), streaming stderr into
# $LogPath as it arrives, so a run that times out still leaves its log.
# Returns the exit code.
function Invoke-ZigTestExecutable {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ResultsPath,
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $Directory,
        [int] $Minutes = 90
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($Path)
    $psi.ArgumentList.Add("--results=$ResultsPath")
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

# The commit and the tracked changes of a checkout.
function Get-RanListCheckoutState {
    param([Parameter(Mandatory)] [string] $Root)
    $head = (& git -C $Root rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or "$head".Trim() -notmatch '^[0-9a-f]{40}$') { throw "$Root is not a git checkout." }
    $status = @(& git -C $Root status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0) { throw "git status failed in $Root." }
    return [pscustomobject]@{ Head = "$head".Trim(); Status = ($status -join "`n") }
}

# Stops the capture when the checkout's commit or tracked changes are no longer
# the ones the capture started from: the list would name a build it did not run.
function Assert-RanListCheckoutUnchanged {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] [object] $Before, [Parameter(Mandatory)] [string] $When)
    $now = Get-RanListCheckoutState -Root $Root
    if (-not [string]::Equals($now.Head, $Before.Head, [StringComparison]::Ordinal) -or -not [string]::Equals($now.Status, $Before.Status, [StringComparison]::Ordinal)) {
        throw "$Root changed $When (HEAD or tracked files), so the list would not be $($Before.Head)'s; no list written."
    }
}

# Stops the capture when this run's facts differ from a baseline list's.
function Assert-RanListEnvironmentOf {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Facts, [Parameter(Mandatory)] [string] $Baseline)
    $basePath = Resolve-RanListPath $Baseline
    if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) { throw "The baseline '$basePath' does not exist." }
    $baseFacts = New-RanListMap
    foreach ($l in [System.IO.File]::ReadAllLines($basePath)) { if ($l -cmatch '^# env: ([^=]+)=(.*)$') { $baseFacts[$Matches[1]] = $Matches[2] } }
    # Both key sets, ordinally: a key spelled with another case or a control
    # character is a key of its own, missing from the other side.
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in @($Facts.Keys) + @($baseFacts.Keys)) { [void] $keys.Add($k) }
    $differ = @($keys | Where-Object { -not [string]::Equals("$($Facts[$_])", "$($baseFacts[$_])", [StringComparison]::Ordinal) })
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
$root = $null
$before = $null
$builtMode = $null
$rows = [Collections.Generic.List[object]]::new()
$suites = [Collections.Generic.List[object]]::new()
$problems = [Collections.Generic.List[string]]::new()
# Suite labels are compared ordinally everywhere, so two that differ only by
# case would be two suites to one reader and one to another: refuse them.
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$compilers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$modes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
# The finally removes the build prefix however the capture stops (a failed
# build too).
try {
    if (-not [string]::IsNullOrWhiteSpace($Checkout)) {
        # Build mode.
        if ($TestExe.Count -or $TestLog.Count -or $TestResults.Count -or $Revision -or $WorkingDirectory -or $TestLogFacts) {
            throw 'Build mode (-Checkout) reads the revision, compiler and executable itself; do not pass -TestExe, -TestLog, -TestResults, -TestLogFacts, -Revision or -WorkingDirectory with it.'
        }
        if ([string]::IsNullOrWhiteSpace($BuildOptions)) { throw "Pass -BuildOptions: the gate's own options, or 'none'." }
        $root = Resolve-RanListPath $Checkout
        $before = Get-RanListCheckoutState -Root $root
        $Revision = $before.Head
        if ($before.Status.Length -gt 0 -and -not $AllowDirty) { throw "$root has tracked changes, so its build is not $Revision; commit them, or pass -AllowDirty for a control." }
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
        Assert-RanListCheckoutUnchanged -Root $root -Before $before -When 'during the build'
        $compiled = [regex]::Match([System.IO.File]::ReadAllText($buildLog), '(?m)^[ |+\-]*compile test ghostty-test (\S+) (\S+) ')
        if (-not $compiled.Success) { throw "The build summary names no 'compile test ghostty-test <mode> <target>' line; see $buildLog." }
        $versionLog = Join-Path $LogDirectory "$listName.zig-version.log"
        [void] (Invoke-RanListCommand -CommandLine "$zig version" -Directory $root -LogPath $versionLog)
        $versions = @([System.IO.File]::ReadAllLines($versionLog) | Where-Object { $_ -match '^\d+\.\d+\.\d+\S*$' } | Select-Object -Last 1)
        if ($versions.Count -ne 1) { throw "zig version printed no version; see $versionLog." }
        [void] $compilers.Add($versions[0])
        $builtMode = $compiled.Groups[1].Value
        $build['source'] = 'built'
        $build['options'] = $(if ($options.Count) { $options -join ' ' } else { '(none)' })
        $build['target'] = $compiled.Groups[2].Value
        $build['dirty'] = ($before.Status.Length -gt 0).ToString().ToLowerInvariant()
        $WorkingDirectory = $root
        $inputs.Add(@{ Kind = 'exe'; Path = (Join-Path $prefix 'bin\ghostty-test.exe'); Suite = 'ghostty-test' })
    }
    else {
        foreach ($pair in @(@('Revision', $Revision), @('BuildOptions', $BuildOptions))) {
            if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1] -ieq 'unknown') { throw "Declared executables and imported runs need -$($pair[0]) (not empty, not 'unknown')." }
        }
        if ($TestExe.Count -and $TestLog.Count) { throw 'Take declared executables and imported runs as separate lists: their environments come from different places.' }
        if ($TestLog.Count -ne $TestResults.Count -or $TestLog.Count -ne $TestLogExitCode.Count) {
            throw 'Pass one -TestResults and one -TestLogExitCode per -TestLog: the record and the exit code of the run that wrote it.'
        }
        if ($TestLogFacts -and -not $TestLog.Count) { throw '-TestLogFacts is the environment record of the run that wrote -TestLog logs.' }
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = (Get-Location).Path }
        $WorkingDirectory = Resolve-RanListPath $WorkingDirectory
        $all = @($TestExe | ForEach-Object { @{ Kind = 'exe'; Path = (Resolve-RanListPath $_) } })
        for ($i = 0; $i -lt $TestLog.Count; $i++) {
            $all += @{ Kind = 'log'; Path = (Resolve-RanListPath $TestLog[$i]); Results = (Resolve-RanListPath $TestResults[$i]); Exit = $TestLogExitCode[$i] }
        }
        if ($all.Count -eq 0) { throw 'Pass -Checkout, -TestExe or -TestLog.' }
        if ($Suite.Count -ne 0 -and $Suite.Count -ne $all.Count) { throw "Pass one -Suite per input ($($all.Count)), or none." }
        for ($i = 0; $i -lt $all.Count; $i++) {
            $all[$i].Suite = if ($Suite.Count -ne 0) { $Suite[$i] } else { [System.IO.Path]::GetFileNameWithoutExtension($all[$i].Path) }
            $inputs.Add($all[$i])
        }
        if ($TestLog.Count) {
            # An imported run's environment is its own, never this process's.
            $environment = New-RanListMap
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
    }
    $build['filtered'] = ($build['options'] -match '(^|\s)-Dtest-filter(=|\s|$)').ToString().ToLowerInvariant()

    foreach ($item in $inputs) {
        $name = $item.Suite
        # Case-sensitively, as the compare reads it: with case folded, [A-Za-z]
        # also matches the Kelvin sign U+212A.
        if ($name -cnotmatch '^[A-Za-z0-9._-]+$') { throw "Suite name '$name' must be ASCII letters, digits, '.', '_' or '-'." }
        if (-not $seen.Add($name)) { throw "Suite '$name' is given twice (suite names are told apart without regard to case)." }
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) { throw "'$($item.Path)' does not exist." }
        if ($item.Kind -eq 'exe') {
            $logPath = Join-Path $LogDirectory "$listName.$name.log"
            $resultsPath = Join-Path $LogDirectory "$listName.$name.results.txt"
            # The runner creates the record and refuses one that exists, so an
            # earlier capture's cannot stand in for this run's.
            if (Test-Path -LiteralPath $resultsPath) { Remove-Item -LiteralPath $resultsPath }
            Write-Host "Running $name ($($item.Path)) in $WorkingDirectory"
            $exit = Invoke-ZigTestExecutable -Path $item.Path -ResultsPath $resultsPath -LogPath $logPath -Directory $WorkingDirectory -Minutes $TimeoutMinutes
        }
        else {
            $logPath = $item.Path
            $resultsPath = $item.Results
            $exit = $item.Exit
        }
        $record = Read-ZigTestResults -Path $resultsPath
        foreach ($problem in $record.Problems) { $problems.Add("${name}: $problem") }
        $panics = Get-ZigPanicLineCount -Lines ([System.IO.File]::ReadAllLines($logPath, [System.Text.UTF8Encoding]::new($false)))
        if ($record.Problems.Count -gt 0) { continue }
        if ($record.Tests.Count -eq 0) { $problems.Add("${name}: the record holds no test, so the suite ran nothing; no list is taken of an empty suite."); continue }
        [void] $compilers.Add($record.Zig)
        [void] $modes.Add($record.Mode)
        $tests = @($record.Tests)
        $suiteRecord = [pscustomobject]@{
            Name = $name; Tests = $tests.Count; Ok = $record.End.Ok; Skip = $record.End.Skip; Fail = $record.End.Fail
            Exit = $exit; ErrorsLogged = $record.End.ErrorsLogged; Leaked = $record.End.Leaked; Panics = $panics
        }
        $suites.Add($suiteRecord)
        foreach ($row in (Get-RanListRows -SuiteName $name -Tests $tests)) { $rows.Add($row) }
        Write-Host ("{0}: {1} tests, {2} OK, {3} skipped, {4} failed, exit {5}, {6} errors logged, {7} leaked, {8} panics (log {9})" -f $name, $suiteRecord.Tests, $suiteRecord.Ok, $suiteRecord.Skip, $suiteRecord.Fail, $suiteRecord.Exit, $suiteRecord.ErrorsLogged, $suiteRecord.Leaked, $suiteRecord.Panics, $logPath)
    }
    if ($null -ne $root) { Assert-RanListCheckoutUnchanged -Root $root -Before $before -When 'during the run' }
}
finally {
    # The installed executable is about 300 MB; the build cache keeps what a
    # rebuild needs.
    if ($null -ne $prefix -and -not $KeepBuild -and (Test-Path -LiteralPath $prefix)) { Remove-Item -LiteralPath $prefix -Recurse -Force }
}
# One list is one compiler and one mode: the runner's record names them.
if ($compilers.Count -gt 1) { $problems.Add("The compiler differs: 'zig version' and the records name $(@($compilers) -join ', ').") }
if ($modes.Count -gt 1) { $problems.Add("The records name more than one mode: $(@($modes) -join ', ').") }
if ($null -ne $builtMode -and $modes.Count -eq 1 -and -not [string]::Equals(@($modes)[0], $builtMode, [StringComparison]::Ordinal)) { $problems.Add("The build summary's mode is $builtMode, the record's $(@($modes)[0]).") }
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { [Console]::Error.WriteLine("RAN LIST: $problem") }
    [Console]::Error.WriteLine('RAN LIST: no list written.')
    exit 1
}
$build['mode'] = @($modes)[0]
$build['zig'] = @($compilers)[0]
$text = Format-RanList -Rows $rows.ToArray() -Suites $suites.ToArray() -Revision $Revision -Build $build -Environment $environment
[System.IO.File]::WriteAllText($outPath, $text, [System.Text.UTF8Encoding]::new($false))
Write-Host "Wrote $outPath ($($rows.Count) rows)."
$bad = @($suites | Where-Object { -not (Test-RanListSuiteGreen $_) })
if ($bad.Count -gt 0) {
    foreach ($s in $bad) { [Console]::Error.WriteLine("RAN LIST: $($s.Name) is not green ($($s.Fail) failed, exit $($s.Exit), $($s.ErrorsLogged) errors logged, $($s.Leaked) leaked).") }
    exit 1
}
exit 0
