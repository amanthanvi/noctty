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
  font:<family>          `present` when a name in a font file that font
                         discovery (src/font/discovery_windows.zig) reads holds
                         it: a .ttf, .otf, .ttc or .otc file in the system or
                         per-user font directory, or one a value of the
                         registry's Fonts keys names. Every face's family,
                         style, full, typographic and WWS names (name IDs 1, 2,
                         4, 16, 17, 21 and 22) on every platform count, and
                         each family joined to each style: more names than
                         discovery matches on, so a wrong `present` only makes
                         a skip need review. `unknown` when such a file, or
                         such a name, cannot be read or decoded; else
                         `absent`. The harfbuzz shaping tests that discover
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
# Get-RanListNameDecoder's decoders, made on first use.
$script:RanListNameDecoders = $null
# The sfnt version tags FreeType's TrueType driver opens (tt_face_init) that
# the probe trusts: 00010000, `true`, A5 `kbd` and A5 `lst`. Not 00020000, which
# tt_face_init also takes: its bytes `00 02` open a bare FNT version 0x200 file,
# so FreeType's winfnt driver can name such a face when the TrueType driver
# refuses it (council round 6 on #731, Opus L2).
$script:RanListTrueTypeTags = @(0x00010000L, 0x74727565L, 0xA56B6264L, 0xA56C7374L)
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
    $lines.Add('# build: ' + (@($Build.get_Keys() | ForEach-Object { "$_=$($Build[$_])" }) -join "`t"))
    $envKeys = [string[]] @($Environment.get_Keys())
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

# A strict decoder for a name record's platform and encoding, or $null for one
# the probe does not decode. Platform 0 (Unicode), any encoding, and platform 3
# (Windows) encodings 0 (symbol), 1 (BMP) and 10 (full repertoire) are
# UTF-16BE; platform 1 (Macintosh) encoding 0 is MacRoman; platform 2 (ISO)
# encodings 0, 1 and 2 are ASCII, UTF-16BE and ISO 8859-1. Each decoder throws
# on bytes it cannot decode.
function Get-RanListNameDecoder {
    param([long] $Platform, [long] $Encoding)
    if ($null -eq $script:RanListNameDecoders) {
        $utf16 = [System.Text.UnicodeEncoding]::new($true, $false, $true)
        $decoders = @{ 'utf16' = $utf16; 'latin1' = [System.Text.Encoding]::Latin1 }
        $decoders['ascii'] = [System.Text.Encoding]::GetEncoding('us-ascii', [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
        # MacRoman is code page 10000, which needs .NET's code-page provider.
        try { $decoders['macroman'] = [System.Text.Encoding]::GetEncoding(10000, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback) } catch { $decoders['macroman'] = $null }
        $script:RanListNameDecoders = $decoders
    }
    $kind = if ($Platform -eq 0) { 'utf16' }
    elseif ($Platform -eq 1 -and $Encoding -eq 0) { 'macroman' }
    elseif ($Platform -eq 2 -and $Encoding -eq 0) { 'ascii' }
    elseif ($Platform -eq 2 -and $Encoding -eq 1) { 'utf16' }
    elseif ($Platform -eq 2 -and $Encoding -eq 2) { 'latin1' }
    elseif ($Platform -eq 3 -and ($Encoding -eq 0 -or $Encoding -eq 1 -or $Encoding -eq 10)) { 'utf16' }
    else { $null }
    if ($null -eq $kind) { return $null }
    return $script:RanListNameDecoders[$kind]
}

# Adds the names of one `name` table at $Name, $TableLength bytes long, to
# $Names (see Get-RanListFontNames). Returns whether all of it could be read and
# decoded; throws past the end of the file.
function Add-RanListNameTable {
    param([byte[]] $Bytes, [long] $Name, [long] $TableLength, [Collections.Generic.HashSet[string]] $Names)
    if ($TableLength -lt 6 -or $Name + $TableLength -gt $Bytes.Length) { return $false }
    # Formats 0 and 1 share the record array; format 1 adds language tags after it.
    $format = Read-RanListBigEndian $Bytes $Name 2
    if ($format -ne 0 -and $format -ne 1) { return $false }
    $entries = Read-RanListBigEndian $Bytes ($Name + 2) 2
    $storage = Read-RanListBigEndian $Bytes ($Name + 4) 2
    $recordsEnd = 6 + 12 * $entries
    if ($recordsEnd -gt $TableLength -or $storage -gt $TableLength) { return $false }
    $complete = $true
    if ($format -eq 1) {
        # The language tags and every string they point at must lie inside the table.
        $tags = if ($recordsEnd + 2 -le $TableLength) { Read-RanListBigEndian $Bytes ($Name + $recordsEnd) 2 } else { $null }
        if ($null -eq $tags -or $recordsEnd + 2 + 4 * $tags -gt $TableLength) { $complete = $false }
        else {
            for ($j = 0; $j -lt $tags; $j++) {
                $tagRecord = $Name + $recordsEnd + 2 + 4 * $j
                $tagLength = Read-RanListBigEndian $Bytes $tagRecord 2
                $tagOffset = Read-RanListBigEndian $Bytes ($tagRecord + 2) 2
                if ($storage + $tagOffset + $tagLength -gt $TableLength) { $complete = $false }
            }
        }
    }
    # Each ID's distinct strings: most languages and platforms repeat one name.
    $byId = [Collections.Generic.Dictionary[int, Collections.Generic.HashSet[string]]]::new()
    foreach ($id in 1, 2, 4, 16, 17, 21, 22) { $byId[$id] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
    for ($i = 0; $i -lt $entries; $i++) {
        $entry = $Name + 6 + 12 * $i
        $platform = Read-RanListBigEndian $Bytes $entry 2
        $encoding = Read-RanListBigEndian $Bytes ($entry + 2) 2
        $id = [int] (Read-RanListBigEndian $Bytes ($entry + 6) 2)
        $length = Read-RanListBigEndian $Bytes ($entry + 8) 2
        $offset = Read-RanListBigEndian $Bytes ($entry + 10) 2
        # A string past the table, whichever its ID, leaves the table unread in part.
        if ($storage + $offset + $length -gt $TableLength) { $complete = $false; continue }
        if (-not $byId.ContainsKey($id)) { continue }
        $at = [int]($Name + $storage + $offset)
        $decoder = Get-RanListNameDecoder $platform $encoding
        if ($null -eq $decoder) { $complete = $false }
        else {
            try { [void] $byId[$id].Add($decoder.GetString($Bytes, $at, [int]$length)) }
            catch { $complete = $false }
        }
        # FreeType reads every ISO (platform 2) record as UTF-16BE, whatever its
        # encoding says (tt_face_get_name in sfobjs.c), and drops an odd last byte.
        if ($platform -eq 2) { [void] $byId[$id].Add([System.Text.Encoding]::BigEndianUnicode.GetString($Bytes, $at, [int]($length - $length % 2))) }
    }
    # FreeType cuts a name at its first NUL (tt_name_ascii_from_utf16 and
    # _other); the cut name joins too, and the whole one is kept.
    foreach ($id in @($byId.get_Keys())) {
        foreach ($s in @($byId[$id])) {
            $nul = $s.IndexOf([char]0)
            if ($nul -ge 0) { [void] $byId[$id].Add($s.Substring(0, $nul)) }
        }
    }
    foreach ($id in $byId.get_Keys()) { $Names.UnionWith($byId[$id]) }
    foreach ($familyId in 1, 16, 21) {
        foreach ($styleId in 2, 17, 22) {
            foreach ($family in $byId[$familyId]) { foreach ($style in $byId[$styleId]) { [void] $Names.Add("$family $style") } }
        }
    }
    return $complete
}

# Whether a file's opening bytes pass the header tests FreeType's Mac loader
# applies when its TrueType driver refuses a face (load_mac_face in ftobjs.c):
# IsMacBinary's on the first 128 bytes, or FT_Raccess_Get_HeaderInfo's on a
# resource-fork header at the start. Such a file can be named from a font in
# its fork, which the probe does not read, so it is not wholly read. Only the
# headers are tested; the forks are not parsed.
function Test-RanListMacContainer {
    param([byte[]] $Bytes)
    if ($Bytes.Length -ge 128) {
        $h = $Bytes
        $nameLength = [int] $h[1]
        if ($h[0] -eq 0 -and $h[74] -eq 0 -and $h[82] -eq 0 -and $nameLength -ge 1 -and $nameLength -le 33 -and $h[63] -eq 0 -and $h[2 + $nameLength] -eq 0 -and $h[0x53] -le 0x7F) { return $true }
    }
    if ($Bytes.Length -ge 16 -and $Bytes[0] -lt 0x80 -and $Bytes[4] -lt 0x80 -and $Bytes[8] -lt 0x80 -and $Bytes[12] -lt 0x80) {
        $dataAt = Read-RanListBigEndian $Bytes 0 4
        $mapAt = Read-RanListBigEndian $Bytes 4 4
        $dataLength = Read-RanListBigEndian $Bytes 8 4
        $mapLength = Read-RanListBigEndian $Bytes 12 4
        $apart = if ($dataAt -lt $mapAt) { $dataAt -le $mapAt - $dataLength } else { $mapAt -le $dataAt - $mapLength }
        if ($mapAt -ne 0 -and $apart -and $dataAt + $dataLength -le $Bytes.Length -and $mapAt + $mapLength -le $Bytes.Length) { return $true }
    }
    return $false
}

# Adds one face's names to $Names (see Get-RanListFontNames): those of every
# directory entry tagged `name`, since FreeType keeps the first and a later one
# could be any. Returns whether every part of them could be read and decoded,
# and whether they are the names FreeType takes the face's family from; throws
# past the end of the file.
function Add-RanListFaceNames {
    param([byte[]] $Bytes, [long] $Face, [Collections.Generic.HashSet[string]] $Names)
    $version = Read-RanListBigEndian $Bytes $Face 4
    $tables = Read-RanListBigEndian $Bytes ($Face + 4) 2
    $nameTables = [Collections.Generic.List[object]]::new()
    $heads = 0
    $headsUsable = $true
    $headsWhole = $true
    for ($i = 0; $i -lt $tables; $i++) {
        $record = $Face + 12 + 16 * $i
        if ($record + 16 -gt $Bytes.Length) { return $false }
        $tag = [System.Text.Encoding]::ASCII.GetString($Bytes, [int]$record, 4)
        $tableOffset = Read-RanListBigEndian $Bytes ($record + 8) 4
        $tableLength = Read-RanListBigEndian $Bytes ($record + 12) 4
        # FreeType treats a table of no length, or one past the end of the file, as missing.
        $usable = $tableLength -gt 0 -and $tableOffset + $tableLength -le $Bytes.Length
        if ([string]::Equals($tag, 'head', [StringComparison]::Ordinal)) {
            $heads++
            if (-not $usable) { $headsUsable = $false }
            # check_table_dir refuses a TrueType face whose `head` (or `bhed`) is
            # under 0x36 bytes; a short `bhed` is the Mac loader's way in, which
            # Test-RanListMacContainer covers by the file's shape.
            if ($tableLength -lt 0x36 -or $tableOffset + $tableLength -gt $Bytes.Length) { $headsWhole = $false }
        }
        if ([string]::Equals($tag, 'name', [StringComparison]::Ordinal)) { $nameTables.Add(@($tableOffset, $tableLength)) }
    }
    if ($nameTables.Count -eq 0) { return $false }
    $complete = $true
    # Only a face FreeType reads as a plain sfnt is wholly read: a CFF font
    # (`OTTO`) with a usable `head` table, since without one cff_face_init loads
    # no sfnt names and takes the family from the CFF data; or a TrueType face
    # ($script:RanListTrueTypeTags: 00010000, `true`, or the Apple tags A5 `kbd`
    # and A5 `lst`) with a `head` of at least 0x36 bytes inside the file. Any other face (`typ1`, which FreeType opens as Type 1 or CID from its
    # own table; a WOFF file, which FreeType decompresses first; a Mac resource
    # fork; an unknown tag) takes its family from data the probe does not read.
    if ($version -eq 0x4F54544FL) { if ($heads -eq 0 -or -not $headsUsable) { $complete = $false } }
    elseif ($script:RanListTrueTypeTags -contains $version) { if ($heads -eq 0 -or -not $headsWhole) { $complete = $false } }
    else { $complete = $false }
    foreach ($table in $nameTables) {
        $read = try { Add-RanListNameTable -Bytes $Bytes -Name $table[0] -TableLength $table[1] -Names $Names } catch { $false }
        if (-not $read) { $complete = $false }
    }
    return $complete
}

# The names a font file declares, for the font facts: every record with name ID
# 1, 2, 4, 16, 17, 21 or 22 (family, style, full name, typographic family and
# style, WWS family and style) in the `name` table of every face, a .ttc or .otc
# collection's included, on every platform Get-RanListNameDecoder decodes; and
# each family (1, 16, 21) joined to each style (2, 17, 22) with a space, as
# noctty's full name joins FreeType's family and style (`buildFullName` in
# src/font/discovery_windows.zig). These are more names than discovery matches
# on, on purpose: it no longer mirrors which of them FreeType picks. Complete is
# false when part of them cannot be read or decoded: a file or face that is not
# an OpenType font, a `name` table of a format other than 0 or 1, one whose
# records, language tags or strings pass its declared length or that runs past
# the end of the file, or a record of those IDs in an encoding the probe does
# not decode or with bytes its encoding refuses; and a face whose family
# FreeType takes from elsewhere: one with no `name` table, or a CFF font
# (`OTTO`) without a usable `head` table (none, one of no length, or one past
# the end of the file), whose family comes from its CFF data (as does a bare
# CFF file's, which reads as no OpenType font); any face FreeType does not
# read as a plain sfnt (see Add-RanListFaceNames); and a file shaped like a Mac
# container (see Test-RanListMacContainer). Where FreeType reads a name
# otherwise than its label says, the probe reads it both ways: an ISO record
# also as UTF-16BE, and every name also cut at its first NUL, before joins;
# and it reads every `name` table a face's directory lists. Names holds what
# could be read.
function Get-RanListFontNames {
    param([Parameter(Mandatory)] [string] $Path)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $complete = $true
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if (Test-RanListMacContainer -Bytes $bytes) { $complete = $false }
        $faces = @([long] 0)
        if ($bytes.Length -ge 12 -and [string]::Equals([System.Text.Encoding]::ASCII.GetString($bytes, 0, 4), 'ttcf', [StringComparison]::Ordinal)) {
            $count = Read-RanListBigEndian $bytes 8 4
            if ($count -lt 1 -or $count -gt 4096) { throw 'not a font collection' }
            $faces = @(for ($i = 0; $i -lt $count; $i++) { Read-RanListBigEndian $bytes (12 + 4 * $i) 4 })
        }
        foreach ($face in $faces) {
            $faceComplete = try { Add-RanListFaceNames -Bytes $bytes -Face $face -Names $names } catch { $false }
            if (-not $faceComplete) { $complete = $false }
        }
    }
    catch { $complete = $false }
    return [pscustomobject]@{ Names = [string[]] @($names); Complete = $complete }
}

# The font files discovery reads (scanAll in src/font/discovery_windows.zig),
# each once, compared ordinally: every file with a .ttf, .otf, .ttc or .otc
# extension directly in each directory, hidden ones included
# (collectDirFontPaths), and every such file a registry path names
# (collectRegistryFontPaths), inside those directories or not. A path that
# names no file is skipped: discovery cannot open it either.
function Get-RanListFontFiles {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Directories, [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $RegistryPaths)
    $supported = @('.ttf', '.otf', '.ttc', '.otc')
    # Ordinal. Discovery drops a spelling that differs from an earlier one only
    # in case (addUniquePath), but the probe compares paths after GetFullPath
    # resolves them, and a `.\` segment can leave two spellings discovery keeps
    # apart that, resolved, differ only in case; on a case-sensitive directory
    # they name two files (council round 7 on #731, Sol M). Reading both is a
    # harmless over-read.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $files = [Collections.Generic.List[string]]::new()
    foreach ($dir in $Directories) {
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue) {
            if ($supported -notcontains $f.Extension.ToLowerInvariant()) { continue }
            if ($seen.Add($f.FullName)) { $files.Add($f.FullName) }
        }
    }
    foreach ($p in $RegistryPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $full = try { [System.IO.Path]::GetFullPath($p) } catch { $null }
        if ($null -eq $full -or $supported -notcontains [System.IO.Path]::GetExtension($full).ToLowerInvariant()) { continue }
        if (-not [System.IO.File]::Exists($full)) { continue }
        if ($seen.Add($full)) { $files.Add($full) }
    }
    return , $files.ToArray()
}

# The font facts (see the description) from the names of the font files
# discovery reads (Get-RanListFontNames' results): `present` when a name of any
# file holds the family, compared ordinally without case; else `unknown` when a
# file's names are not Complete; else `absent`. An over-approximation: a
# `present` discovery would not find only makes a skip need an approval that
# applies, which fails closed, while a wrong `absent` could let an approval
# cover a test that lost a font it had.
function Get-RanListFontFacts {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [object[]] $Fonts)
    $facts = New-RanListMap
    foreach ($family in $script:RanListFonts) {
        $value = 'absent'
        foreach ($font in $Fonts) {
            if ($null -eq $font) { $value = 'unknown'; continue }
            $holds = $false
            foreach ($n in $font.Names) { if ($n.IndexOf($family, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $holds = $true; break } }
            if ($holds) { $value = 'present'; break }
            if (-not $font.Complete) { $value = 'unknown' }
        }
        $facts["font:$family"] = $value
    }
    return $facts
}

# The font directories discovery scans (systemFontsDir and userFontsDir in
# src/font/discovery_windows.zig): %WINDIR%\Fonts, else %SystemRoot%\Fonts, else
# C:\Windows\Fonts; and %LOCALAPPDATA%\Microsoft\Windows\Fonts when LOCALAPPDATA
# is set, joined as discovery joins them ("{s}\\Fonts"). The system directory
# comes first. A variable set to an empty value is set, as
# std.process.getEnvVarOwned returns it, so its directory is `\Fonts` or
# `\Microsoft\Windows\Fonts` on the current drive; only $null means unset.
function Get-RanListFontDirectories {
    param(
        $WinDir = [Environment]::GetEnvironmentVariable('WINDIR'),
        $SystemRoot = [Environment]::GetEnvironmentVariable('SystemRoot'),
        $LocalAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    )
    $base = if ($null -ne $WinDir) { $WinDir } elseif ($null -ne $SystemRoot) { $SystemRoot } else { 'C:\Windows' }
    $dirs = [Collections.Generic.List[string]]::new()
    $dirs.Add("$base\Fonts")
    if ($null -ne $LocalAppData) { $dirs.Add("$LocalAppData\Microsoft\Windows\Fonts") }
    return , $dirs.ToArray()
}

# Whether a font path, in the form discovery hands it to FreeType, leaves the
# probe unable to tell which file FreeType opens (council round 6 on #731):
# one holding `/`, through which FreeType's resource-fork guessers reach a
# sibling (raccess_make_file_name in ftrfork.c puts its prefix after the last
# `/`); one not starting with a drive letter and `:`, for which they put the
# prefix before the whole path and so reach a file relative to the test's
# working directory; or one holding a non-ASCII character, since FreeType opens
# the UTF-8 bytes discovery passes with CreateFileA, which under an ANSI code
# page can open a differently spelled file. Also one holding a `:` after its
# drive: a value like `Q:foo.ttf`, which Zig joins to the system directory as
# `<dir>\Q:foo.ttf` (a stream of a file named `Q`) while .NET reads it as
# `Q:\foo.ttf` (council round 7 on #731, Opus L2).
function Test-RanListUnsafeFontPath {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    # -cmatch: with case folded, [^\x00-\x7F] does not match U+212A or U+0130,
    # whose case partners are ASCII (council round 7 on #731, Opus L1).
    return $Path.Contains('/') -or $Path -cnotmatch '\A[A-Za-z]:' -or $Path.IndexOf(':', 2) -ge 0 -or $Path -cmatch '[^\x00-\x7F]'
}

# Whether discovery's resolveRegistryFontPath takes a value as it is: Zig's
# std.fs.path.isAbsoluteWindows, true for a leading `/` or `\`, or a drive
# letter, `:` and a separator. Any other value is joined to the system font
# directory.
function Test-RanListZigAbsolute {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    if ($Path.Length -ge 1 -and ($Path[0] -eq [char]'/' -or $Path[0] -eq [char]'\')) { return $true }
    return $Path.Length -ge 3 -and $Path[1] -eq [char]':' -and ($Path[2] -eq [char]'/' -or $Path[2] -eq [char]'\')
}

# Where discovery looks for font files, for a test that runs in $Directory:
# Directories, the font directories; RegistryPaths, the file each Fonts value
# names; and Unsafe, whether a directory or a value, in the form discovery
# hands FreeType, fails Test-RanListUnsafeFontPath. Discovery opens its paths
# in the test process, whose working directory is $Directory, so each path is
# resolved against it (a path rooted on no drive, `\Fonts`, or a relative one),
# not against PowerShell's location or this process's directory.
function Get-RanListFontSources {
    param([Parameter(Mandatory)] [string] $Directory)
    $base = [System.IO.Path]::GetFullPath($Directory)
    $supported = @('.ttf', '.otf', '.ttc', '.otc')
    $unsafe = $false
    $rawDirs = Get-RanListFontDirectories
    foreach ($d in $rawDirs) { if (Test-RanListUnsafeFontPath -Path $d) { $unsafe = $true } }
    $fontDirs = @(foreach ($d in $rawDirs) { [System.IO.Path]::GetFullPath($d, $base) })
    $systemFonts = $fontDirs[0]
    # The file each Fonts value names, as collectRegistryFontPaths resolves it:
    # the value's data (expanded, trimmed of spaces and tabs), a path, or a name
    # in the system font directory. Value names are not read; discovery does not
    # read them.
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($key in 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
        $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
        if ($null -eq $item) { continue }
        foreach ($v in $item.GetValueNames()) {
            # Discovery takes the data up to its first NUL (std.mem.sliceTo); .NET
            # keeps what follows. Both are tried; a path holding a NUL is skipped.
            $data = "$($item.GetValue($v))"
            $tried = [Collections.Generic.List[string]]::new()
            $nul = $data.IndexOf([char]0)
            if ($nul -ge 0) { $tried.Add($data.Substring(0, $nul)) }
            $tried.Add($data)
            # The path discovery forms from the value, for the path rule.
            $value = $tried[0].Trim(' ', "`t")
            if ($value.Length -gt 0 -and $supported -contains [System.IO.Path]::GetExtension($value).ToLowerInvariant()) {
                $formed = if (Test-RanListZigAbsolute -Path $value) { $value } else { "$($rawDirs[0])\$value" }
                if (Test-RanListUnsafeFontPath -Path $formed) { $unsafe = $true }
            }
            foreach ($raw in $tried) {
                $file = $raw.Trim(' ', "`t")
                if ($file.Length -eq 0) { continue }
                $joined = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { [System.IO.Path]::Join($systemFonts, $file) }
                try { $paths.Add([System.IO.Path]::GetFullPath($joined, $base)) } catch { }
            }
        }
    }
    return [pscustomobject]@{ Directories = [string[]] $fontDirs; RegistryPaths = $paths.ToArray(); Unsafe = $unsafe }
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
    $sources = Get-RanListFontSources -Directory $Directory
    $fonts = [Collections.Generic.List[object]]::new()
    $unsafe = $sources.Unsafe
    foreach ($file in (Get-RanListFontFiles -Directories $sources.Directories -RegistryPaths $sources.RegistryPaths)) {
        # A directory entry's name is part of the path discovery forms; the
        # registry's names were tested in Get-RanListFontSources.
        if ([System.IO.Path]::GetFileName($file) -cmatch '[^\x00-\x7F]') { $unsafe = $true }
        $fonts.Add((Get-RanListFontNames -Path $file))
    }
    # A path the rule refuses can lead FreeType to a file the probe does not read.
    if ($unsafe) { $fonts.Add([pscustomobject]@{ Names = [string[]] @(); Complete = $false }) }
    $fontFacts = Get-RanListFontFacts -Fonts $fonts.ToArray()
    foreach ($key in $fontFacts.get_Keys()) { $facts[$key] = $fontFacts[$key] }
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
    # get_Keys(): a fact named Keys, Values or Count shadows that member of a dictionary.
    foreach ($k in @($Facts.get_Keys()) + @($baseFacts.get_Keys())) { [void] $keys.Add($k) }
    # A key only one side holds differs, even when the other side's value is
    # empty: a missing key and an empty value both read as ''.
    $differ = @($keys | Where-Object { $Facts.Contains($_) -ne $baseFacts.Contains($_) -or -not [string]::Equals("$($Facts[$_])", "$($baseFacts[$_])", [StringComparison]::Ordinal) })
    if ($differ.Count -gt 0) {
        foreach ($key in $differ) {
            $here = if ($Facts.Contains($key)) { "'$($Facts[$key])'" } else { 'missing' }
            $there = if ($baseFacts.Contains($key)) { "'$($baseFacts[$key])'" } else { 'missing' }
            [Console]::Error.WriteLine("RAN LIST: environment fact $key is $here here and $there in the baseline.")
        }
        [Console]::Error.WriteLine('RAN LIST: this run would not be like for like with its baseline; nothing was built or run.')
        exit 1
    }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($WriteFacts)) {
    $dir = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { (Get-Location).Path } else { Resolve-RanListPath $WorkingDirectory }
    $facts = Get-RanListEnvironment -Directory $dir
    $text = (@($facts.get_Keys() | ForEach-Object { "# env: $_=$($facts[$_])" }) -join "`n") + "`n"
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
        # \A and \z: `$` would also match before a trailing LF.
        if ($name -cnotmatch '\A[A-Za-z0-9._-]+\z') { throw "Suite name '$name' must be ASCII letters, digits, '.', '_' or '-'." }
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
