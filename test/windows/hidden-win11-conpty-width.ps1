#requires -Version 7.1
<#
PLAN.md 7.7, the Unicode 18 width rule: does noctty give each code point the
width the bundled ConPTY gives it? Where they differ, the cursor drifts a
column after each such character, since ConPTY draws from its own buffer.

No noctty runs. conpty-width-probe.c makes the pseudo console itself, the way
noctty's Windows pty does (src/pty.zig: the bundled conpty.dll's
CreatePseudoConsole, with glyph width flags 0x0 for noctty's default
`grapheme-width-method = unicode` and 0x10 for `legacy`), on a private desktop
of its own (WinSta0\noctty-width-<32 hex>, every process started there by
name), and its client writes each code point alone at column 0 and reads
OpenConsole's own buffer cursor with GetConsoleScreenBufferInfo, with VT
processing on and off. A cursor-position report cannot do this: the bundled
pair forwards CSI 6n and noctty answers it from its own cursor. noctty's width
is read from the table it compiles in, src/unicode/generated_props.zig. The
in-box conhost is measured too, for information only (noctty uses it only
when the bundled pair cannot load, and it changes with Windows).

The code points are the rows of the probe's table,
src/unicode/testdata/conpty_width.tsv: controls (widths every table agrees on,
among them already-wide neighbours of the new ranges in the same planes,
which show the probe reads 2 there) and the 990 that Unicode 18 moved from
Neutral to Wide. The test "unicode: widths match the bundled ConPTY's measured
widths" (src/unicode/main.zig) asserts noctty's width for every row; the pins
that make them agree are in src/build/uucode_config.zig (conpty_width_pins).

When the ConPTY pin (dist/windows/conpty-redist.json) moves: build (which
stages the new pair), run this, and if the measured widths changed, run it
with -WriteTable, fix the pins until the test passes, and run this again.

The negative control: -ControlCodePoint <hex> changes only noctty's width for
that one code point (1 <-> 2) before the comparison, and the run must report
that one disagreement and exit 1.

Nothing here touches the clipboard, the foreground, PowerShell history or
noctty's state. The one side effect is the helper compile: it calls
scripts\dev-windows.cmd, whose `for /f` children are cmd.exe without /D and
run the user's cmd AutoRun (conpty.md, 2026-11-18 REPLY-PATH-01, item (6)).

Exit codes: 0 every row agrees and the measurement matches the table; 1 a
disagreement, a row the four bundled configurations measure differently, a
control row off, or a measurement that differs from the table; 2 the setup or
the probe failed (the pair is not the pinned one, the probe did not run on its
private desktop, the host was not the expected one).
#>
[CmdletBinding()]
param(
    # The folder with the staged bundled pair (conpty.dll and OpenConsole.exe), as `zig build` stages it.
    [string] $Bin,
    # A new directory for the helper, the measurements and the comparison. Default: .sandbox\conpty-width\<time>.
    [string] $Run,
    # The probe's table: the code points to measure and the widths last measured.
    [string] $Table,
    # The architecture of the pair, for its pinned hashes.
    [ValidateSet('x64', 'arm64')]
    [string] $Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    # The negative control: one code point (hex) whose noctty width the comparison flips.
    [string] $ControlCodePoint,
    # Write the measured widths into -Table instead of failing when they changed.
    [switch] $WriteTable,
    # Compile the probe and stop.
    [switch] $CompileOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Bin) { $Bin = Join-Path $repoRoot 'zig-out\bin' }
if (-not $Table) { $Table = Join-Path $repoRoot 'src\unicode\testdata\conpty_width.tsv' }
if (-not $Run) { $Run = Join-Path $repoRoot ('.sandbox\conpty-width\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$props = Join-Path $repoRoot 'src\unicode\generated_props.zig'

function Stop-Setup([string] $Message) {
    Write-Host "SETUP FAILED: $Message"
    exit 2
}

# --- The pinned pair -------------------------------------------------------
$pin = Get-Content -LiteralPath (Join-Path $repoRoot 'dist\windows\conpty-redist.json') -Raw | ConvertFrom-Json
$pinArch = $pin.architectures.$Architecture
$pair = (Resolve-Path -LiteralPath $Bin -ErrorAction SilentlyContinue)
if (-not $pair) { Stop-Setup "no folder at -Bin; build (it stages the pair) or stage it with scripts\stage-conpty-redist.ps1." }
$pair = $pair.ProviderPath.TrimEnd('\')
foreach ($file in @(@{ Name = 'conpty.dll'; Sha = $pinArch.conptyDll.sha256 }, @{ Name = 'OpenConsole.exe'; Sha = $pinArch.openConsoleExe.sha256 })) {
    $path = Join-Path $pair $file.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Setup "$($file.Name) is not in -Bin." }
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -cne $file.Sha) { Stop-Setup "$($file.Name) in -Bin is not the pinned $($pin.version) $Architecture file." }
}
Write-Host "Bundled pair: the pinned $($pin.packageId) $($pin.version) ($Architecture), both SHA-256 verified."

# --- The table ---------------------------------------------------------------
$rows = [Collections.Generic.List[object]]::new()
foreach ($line in [IO.File]::ReadAllLines($Table)) {
    if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
    $cols = $line.Split("`t")
    if ($cols.Count -ne 3 -or $cols[2] -notin @('control', 'unicode18')) { Stop-Setup "a table row is not <hex><TAB><width><TAB>control|unicode18: '$line'." }
    $rows.Add([pscustomobject]@{ Cp = [Convert]::ToInt32($cols[0], 16); Hex = $cols[0]; Table = [int]$cols[1]; Kind = $cols[2] })
}
$unicode18Rows = @($rows | Where-Object Kind -eq 'unicode18')
if ($unicode18Rows.Count -ne 990) { Stop-Setup "the table has $($unicode18Rows.Count) unicode18 rows, not PLAN.md 7.7's 990." }

# --- noctty's widths, from the table it compiles in --------------------------
function Read-NocttyWidth([string] $Path) {
    $text = [IO.File]::ReadAllText($Path)
    $stages = @{}
    foreach ($name in 'stage1', 'stage2') {
        $m = [regex]::Match($text, "pub const ${name}: \[(\d+)\]u16 = \.\{(.*?)\};", 'Singleline')
        if (-not $m.Success) { Stop-Setup "generated_props.zig has no $name." }
        $values = [int[]]@($m.Groups[2].Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($values.Count -ne [int]$m.Groups[1].Value) { Stop-Setup "generated_props.zig's $name has $($values.Count) entries." }
        $stages[$name] = $values
    }
    $m = [regex]::Match($text, 'pub const stage3: \[(\d+)\]Elem = \.\{(.*)\};\s*\};\s*\}\s*$', 'Singleline')
    if (-not $m.Success) { Stop-Setup 'generated_props.zig has no stage3.' }
    $widths = [int[]]@([regex]::Matches($m.Groups[2].Value, '\.width = (\d+),') | ForEach-Object { $_.Groups[1].Value })
    if ($widths.Count -ne [int]$m.Groups[1].Value) { Stop-Setup "generated_props.zig's stage3 has $($widths.Count) widths." }
    $s1 = $stages.stage1; $s2 = $stages.stage2
    $width = { param([int] $cp) $widths[$s2[$s1[$cp -shr 8] + ($cp -band 0xFF)]] }.GetNewClosure()
    # The reading must give what codepointWidth's own test asserts before anything is read from it.
    foreach ($anchor in @(@(0x41, 1), @(0x4E00, 2), @(0x1F600, 2), @(0x301, 0), @(0x200D, 0))) {
        if ((& $width $anchor[0]) -ne $anchor[1]) { Stop-Setup ('generated_props.zig reads U+{0:X4} as {1}, not {2}.' -f $anchor[0], (& $width $anchor[0]), $anchor[1]) }
    }
    return $width
}
$nocttyWidth = Read-NocttyWidth $props
$control = $null
if ($ControlCodePoint) {
    $control = [Convert]::ToInt32($ControlCodePoint, 16)
    if (-not ($rows | Where-Object Cp -eq $control)) { Stop-Setup "-ControlCodePoint $ControlCodePoint is not a row of the table." }
}

# --- The probe -----------------------------------------------------------------
if (Test-Path -LiteralPath $Run) { Stop-Setup '-Run must be a new directory.' }
[void](New-Item -ItemType Directory -Path $Run)
$Run = (Resolve-Path -LiteralPath $Run).ProviderPath
$probe = Join-Path $Run 'conpty-width-probe.exe'
$compile = Join-Path $Run 'compile.cmd'
@(
    '@echo off'
    ('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" user32.lib > "{4}" 2>&1' -f
        (Join-Path $repoRoot 'scripts\dev-windows.cmd'), (Join-Path $PSScriptRoot 'conpty-width-probe.c'), $probe,
        (Join-Path $Run 'conpty-width-probe.obj'), (Join-Path $Run 'compile.log'))
    'exit /b %errorlevel%'
) | Set-Content -LiteralPath $compile -Encoding ascii
# Wait for cmd.exe itself: `Start-Process -Wait` also waits for every descendant, and the
# compile leaves one running for minutes after cl has finished (measured: the run hung there).
$compileStart = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), "/d /c `"`"$compile`"`"")
$compileStart.UseShellExecute = $false
$compileStart.WorkingDirectory = $Run
$compileProcess = [Diagnostics.Process]::Start($compileStart)
if (-not $compileProcess.WaitForExit(300000)) { Stop-Setup 'the probe compile ran for five minutes.' }
if ($compileProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $probe)) { Stop-Setup "the probe did not compile ($($compileProcess.ExitCode)); see compile.log in the run directory." }
if ($CompileOnly) { Write-Host 'conpty-width-probe.c compiled; nothing run.'; exit 0 }

$cpsFile = Join-Path $Run 'cps.txt'
[IO.File]::WriteAllLines($cpsFile, [string[]]@($rows | ForEach-Object Hex))

function Invoke-WidthProbe([string] $Name, [string] $Source, [string] $Flags) {
    $out = Join-Path $Run "$Name.tsv"
    $desktop = 'noctty-width-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    & $probe launch $desktop $Source $Flags $cpsFile $out
    $code = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath "$out.host")) { Stop-Setup "probe $Name exited $code and recorded no host." }
    $hostInfo = @{}
    foreach ($line in [IO.File]::ReadAllLines("$out.host")) { $k, $v = $line.Split("`t", 2); $hostInfo[$k] = $v }
    $expected = if ($Source -eq 'inbox') { 'conhost.exe' } else { 'OpenConsole.exe' }
    $problems = @(
        if ($code -ne 0) { "exit $code" }
        if ($hostInfo.probe_desktop_private -ne '1') { 'the probe was not on its private desktop' }
        if ($hostInfo.host_exe -ne $expected) { "the console host was $($hostInfo.host_exe), not $expected" }
        if ($hostInfo.host_image_matches -ne '1') { 'the console host is not the one in -Bin' }
        if ([int]$hostInfo.console_windows_private -lt 1) { 'no console window on the private desktop' }
        if ($hostInfo.console_windows_default -ne '0') { 'a console window on the Default desktop' }
        if ($hostInfo.writer_exit -ne '0' -or $hostInfo.writer_timed_out -ne '0') { "the writer exited $($hostInfo.writer_exit)" }
    )
    if ($problems.Count -ne 0) { Stop-Setup "probe ${Name}: $($problems -join '; ')." }
    $measured = @{}
    $writerPrivate = $false
    foreach ($line in [IO.File]::ReadAllLines($out)) {
        $p = $line.Split("`t")
        if ($p[0] -eq 'writer_desktop_private') { $writerPrivate = $p[1] -eq '1'; continue }
        if ($p.Count -ne 5) { continue }
        $advance = [int]$p[2]
        # The cells must say what the cursor says: a wide cell is a leading and a trailing half.
        $cells = if ($advance -eq 2) { $p[3] -eq 'L' -and $p[4] -eq 'T' } elseif ($advance -eq 1) { $p[3] -eq '-' } else { $false }
        if (-not $cells) { Stop-Setup "probe ${Name}: U+$($p[0]) ($($p[1])) moved the cursor $advance with cells $($p[3]) $($p[4])." }
        $measured["$([Convert]::ToInt32($p[0], 16))/$($p[1])"] = $advance
    }
    if (-not $writerPrivate) { Stop-Setup "probe ${Name}: the writer was not on the private desktop." }
    if ($measured.Count -ne 2 * $rows.Count) { Stop-Setup "probe ${Name}: $($measured.Count) measurements for $($rows.Count) code points in two modes." }
    return $measured
}

$bundled = [ordered]@{
    'bundled 0x0' = Invoke-WidthProbe 'bundled-0x0' $pair '0'
    'bundled 0x10' = Invoke-WidthProbe 'bundled-0x10' $pair '10'
}
$inbox = Invoke-WidthProbe 'inbox-0x0' 'inbox' '0'
Write-Host 'Probes: each ran on its own private desktop; the bundled runs on the OpenConsole.exe in -Bin, the in-box run on conhost.exe.'

# --- The comparison --------------------------------------------------------------
$results = foreach ($row in $rows) {
    $widths = @(foreach ($config in $bundled.Keys) { foreach ($mode in 'vt', 'legacy') { $bundled[$config]["$($row.Cp)/$mode"] } })
    $conpty = $widths[0]
    $noctty = & $nocttyWidth $row.Cp
    if ($null -ne $control -and $row.Cp -eq $control) { $noctty = 3 - $noctty }
    [pscustomobject]@{
        Hex = $row.Hex; Cp = $row.Cp; Kind = $row.Kind; Table = $row.Table
        Conpty = $conpty; Consistent = @($widths | Sort-Object -Unique).Count -eq 1
        Noctty = $noctty; Inbox = $inbox["$($row.Cp)/vt"]; InboxConsistent = $inbox["$($row.Cp)/vt"] -eq $inbox["$($row.Cp)/legacy"]
    }
}
$report = Join-Path $Run 'comparison.tsv'
[IO.File]::WriteAllLines($report, [string[]](@("cp`tkind`tconpty`tnoctty`ttable`tinbox`tverdict") + @($results | ForEach-Object {
    "$($_.Hex)`t$($_.Kind)`t$($_.Conpty)`t$($_.Noctty)`t$($_.Table)`t$($_.Inbox)`t$(if ($_.Conpty -eq $_.Noctty) { 'agree' } else { 'disagree' })"
})))

$inconsistent = @($results | Where-Object { -not $_.Consistent })
$disagree = @($results | Where-Object { $_.Consistent -and $_.Conpty -ne $_.Noctty })
$changed = @($results | Where-Object { $_.Consistent -and $_.Conpty -ne $_.Table })
foreach ($kind in 'control', 'unicode18') {
    $of = @($results | Where-Object Kind -eq $kind)
    $emoji = @($of | Where-Object { $_.Cp -ge 0x1F000 -and $_.Cp -le 0x1FFFF })
    $line = '{0} ({1}): agree {2}, disagree {3}' -f $kind, $of.Count, @($of | Where-Object { $_.Conpty -eq $_.Noctty }).Count, @($of | Where-Object { $_.Conpty -ne $_.Noctty }).Count
    if ($kind -eq 'unicode18') { $line += '; the emoji blocks ({0}): agree {1}' -f $emoji.Count, @($emoji | Where-Object { $_.Conpty -eq $_.Noctty }).Count }
    Write-Host $line
}
$inboxAgree = @($results | Where-Object { $_.InboxConsistent -and $_.Inbox -eq $_.Noctty }).Count
Write-Host "In-box conhost (information only): agrees with noctty on $inboxAgree of $($results.Count)."
foreach ($r in $inconsistent) { Write-Host ('INCONSISTENT: U+{0}: the four bundled configurations measured different widths.' -f $r.Hex) }
foreach ($r in $disagree) { Write-Host ('DISAGREE: U+{0} ({1}): the bundled ConPTY gives {2}, noctty {3}.' -f $r.Hex, $r.Kind, $r.Conpty, $r.Noctty) }
if ($null -ne $control) { Write-Host ('Control: noctty''s width for U+{0:X4} was flipped before the comparison.' -f $control) }

if ($WriteTable -and $inconsistent.Count -eq 0) {
    $header = @(
        "# The width the bundled ConPTY gives each code point, measured in its own screen buffer"
        "# by test/windows/hidden-win11-conpty-width.ps1 (PLAN.md 7.7, the Unicode 18 width rule)."
        "# conpty.dll and OpenConsole.exe $($pin.version) ($Architecture); glyph width flags 0x0 and"
        "# 0x10, VT processing on and off, all four the same. The test `"unicode: widths match the"
        "# bundled ConPTY's measured widths`" (src/unicode/main.zig) asserts noctty's width for"
        "# every row. Columns: code point (hex), the bundled ConPTY's width, kind (control: a"
        "# width every table agrees on; unicode18: Neutral while unassigned in Unicode 17, Wide"
        "# in Unicode 18)."
    )
    $body = @($results | ForEach-Object { "$($_.Hex)`t$($_.Conpty)`t$($_.Kind)" })
    [IO.File]::WriteAllText($Table, ((@($header) + $body) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote the measured widths to the table ($($body.Count) rows)."
    $changed = @()
}
elseif ($changed.Count -ne 0) {
    Write-Host "CHANGED: the bundled ConPTY measured $($changed.Count) rows differently from the table (first: U+$($changed[0].Hex), $($changed[0].Table) -> $($changed[0].Conpty)); rerun with -WriteTable, then fix the pins."
}
$controlRowsOff = @($results | Where-Object { -not $WriteTable -and $_.Kind -eq 'control' -and $_.Conpty -ne $_.Table })
if ($controlRowsOff.Count -ne 0) { Write-Host "CONTROL ROW OFF: the probe measured a control row other than its table width (U+$($controlRowsOff[0].Hex))." }

Write-Host "Comparison: $report"
if ($inconsistent.Count -ne 0 -or $disagree.Count -ne 0 -or $changed.Count -ne 0 -or $controlRowsOff.Count -ne 0) {
    Write-Host 'RESULT: FAIL'
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
