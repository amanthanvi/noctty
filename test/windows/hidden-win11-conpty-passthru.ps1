#requires -Version 7.1
<#
QR-64, the prompt-time resets: do the mode resets the shell integrations send
at the prompt reach noctty through the bundled ConPTY? noctty's recovery after
a TUI that exits with Kitty keyboard flags, modifyOtherKeys or Kitty paste
events set (the 2026-10-11 keyboard-recovery and the 2026-11-27
PASTE-EVENTS-RESET-01 entries in docs/agents/log/shell-integration.md) works
only if the console host passes those sequences on: a host that knows a
sequence can keep it, and one that does not can drop it or move it.

No noctty runs. conpty-passthru-probe.c makes the pseudo console itself, the
way noctty's Windows pty does (src/pty.zig: the bundled conpty.dll's
CreatePseudoConsole, with glyph width flags 0x0 for noctty's default
`grapheme-width-method = unicode` and 0x10 for `legacy`), on a private desktop
of its own (WinSta0\noctty-passthru-<32 hex>, every process started there by
name), once per case; its client turns VT processing on and writes the case
between printable markers (`<P0>`, the case's bytes, `</P0>`), and the probe
keeps every byte the host writes to the pseudo console's output pipe, which is
what noctty reads. A case passes when the bytes between the markers are
exactly the case's bytes. The baseline, a run whose case has no bytes, must
come back with nothing between its markers. The in-box conhost is measured
too, for information only (noctty uses it only when the bundled pair cannot
load, and it changes with Windows); for each sequence of a case the harness
reports where a host put it: between the markers, before them, after them,
or nowhere (dropped).

The cases: each reset any integration sends, alone; each integration's prompt
string as it ships, read from the sources at run time (the run stops with exit
2 when a source no longer has the form read here):
src/shell-integration/powershell/integration.ps1's prompt wrapper (OSC 133;A)
and host reader fallback (OSC 133;P), the Clink prefix in
src/shell-integration/cmd/noctty-shell-integration.lua, and cmd's PROMPT prefix
without Clink (`cmd_prompt_prefix` in src/termio/shell_integration.zig, as cmd
expands it); then `CSI ?5522h` (what a TUI sets), bracketed paste `CSI ?2004h`
and `CSI ?2004l`, and `CSI ?9999h`, a mode no host knows. The aid is 4242 and
the directory C:\Windows (integration.ps1 sends the shell's PID, cmd its `$P`
and Clink `os.getcwd()`).

When the ConPTY pin (dist/windows/conpty-redist.json) moves, build (which
stages the new pair), run hidden-win11-conpty-width.ps1 and
hidden-win11-conpty-passthru.ps1 on it, and ship the pair only when both pass
(docs/agents/log/conpty.md, 2026-11-27 CONPTY-PASSTHRU-01).

The negative control: -ControlCase <n> makes the client write `CSI ?9998h` in
place of case n's bytes, on every host, while the comparison still expects the
case's bytes, and the run must report that case dropped and exit 1.

Nothing here touches the clipboard, the foreground, PowerShell history or
noctty's state. The one side effect is the helper compile: it calls
scripts\dev-windows.cmd, whose `for /f` children are cmd.exe without /D and
run the user's cmd AutoRun (conpty.md, 2026-11-18 REPLY-PATH-01, item (6)).

Exit codes: 0 every case and the baseline came back through the bundled pair
exactly as written, between their markers, with both flags; 1 one did not (a
sequence dropped, moved out of the markers, or other bytes between them); 2
the setup or the probe failed (the pair is not the pinned one, a source no
longer has the form read here, the probe did not run on its private desktop,
the host was not the expected one, the host's output holds no markers).
#>
[CmdletBinding()]
param(
    # The folder with the staged bundled pair (conpty.dll and OpenConsole.exe), as `zig build` stages it.
    [string] $Bin,
    # A new directory for the helper, the cases and the measurements. Default: .sandbox\conpty-passthru\<time>.
    [string] $Run,
    # The architecture of the pair, for its pinned hashes.
    [ValidateSet('x64', 'arm64')]
    [string] $Architecture = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }),
    # The negative control: the number of one case (as the run lists them) whose bytes the client replaces.
    [ValidateRange(-1, 63)]
    [int] $ControlCase = -1,
    # Compile the probe and stop.
    [switch] $CompileOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Bin) { $Bin = Join-Path $repoRoot 'zig-out\bin' }
if (-not $Run) { $Run = Join-Path $repoRoot ('.sandbox\conpty-passthru\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }

function Stop-Setup([string] $Message) {
    Write-Host "SETUP FAILED: $Message"
    exit 2
}

# Terminal bytes compare ordinally: -eq, -ceq and -in ignore an ESC or a BEL
# under pwsh 7's ICU (tooling.md, 2026-11-18 PWSH-CEQ-ICU).
function Test-Same([string] $A, [string] $B) { [string]::Equals($A, $B, [StringComparison]::Ordinal) }

$esc = [string][char]0x1b
$bel = [string][char]0x07
$aid = '4242'
$cwd = 'C:\Windows'
$controlBytes = "$esc[?9998h"

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

# --- Escape sequences --------------------------------------------------------
# CSI (parameters, intermediates, final), OSC (to BEL or ST), and other ESC
# sequences. The rest of a host's output is text.
$sequencePattern = [regex]'\e\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]|\e\][^\a\e]*(?:\a|\e\\)|\e[\x20-\x2F]*[\x30-\x7E]'
function Get-Sequences([string] $Text) {
    , @(foreach ($m in $sequencePattern.Matches($Text)) { [pscustomobject]@{ Text = $m.Value; Index = $m.Index; End = $m.Index + $m.Length } })
}
function Show-Bytes([string] $Text) {
    $shown = [regex]::Replace($Text, '\e\][012];[^\a\e]*(?:\a|\e\\)', '<title>')
    $shown = $shown.Replace($esc, 'ESC').Replace($bel, 'BEL')
    return [regex]::Replace($shown, '[\x00-\x1F\x7F-\xFF]', { param($m) '<{0:X2}>' -f [int][char]$m.Value })
}

# --- The cases, read from what ships ----------------------------------------
function Get-Source([string] $Relative) {
    $path = Join-Path $repoRoot $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Setup "$Relative is missing." }
    return [IO.File]::ReadAllText($path)
}

# integration.ps1: each `__ghostty_write_osc "..."` that holds a CSI.
$ps1 = Get-Source 'src\shell-integration\powershell\integration.ps1'
$ps1Writes = @([regex]::Matches($ps1, '__ghostty_write_osc "([^"]*\$\{Global:__ghostty_esc\}\[[^"]*)"') | ForEach-Object { $_.Groups[1].Value })
function ConvertFrom-Ps1String([string] $Text) {
    $out = $Text.Replace('${Global:__ghostty_esc}', $esc).Replace('${Global:__ghostty_bel}', $bel).Replace('${Global:__ghostty_aid}', $aid)
    if ($out.Contains('$') -or $out.Contains('`')) { Stop-Setup "an integration.ps1 prompt string interpolates something this harness does not read: $Text" }
    return $out
}
$ps1Prompt = @($ps1Writes | Where-Object { $_.Contains('}]133;A;') })
$ps1Reader = @($ps1Writes | Where-Object { $_.Contains('}]133;P;') })
if ($ps1Writes.Count -ne 2 -or $ps1Prompt.Count -ne 1 -or $ps1Reader.Count -ne 1) {
    Stop-Setup "integration.ps1 writes $($ps1Writes.Count) strings with a CSI; this harness reads two, the prompt wrapper's (133;A) and the reader fallback's (133;P). Update the cases."
}

# The Clink prefix: `local prefix = <concatenation>` right before `prompt = prefix ..`.
$lua = Get-Source 'src\shell-integration\cmd\noctty-shell-integration.lua'
$luaPrefix = @([regex]::Matches($lua, '(?s)local prefix = (.*?)\r?\n\s*prompt = prefix \.\.'))
if ($luaPrefix.Count -ne 1) { Stop-Setup "noctty-shell-integration.lua has $($luaPrefix.Count) Clink prompt prefixes of the form this harness reads. Update the cases." }
function ConvertFrom-LuaConcat([string] $Expr) {
    $token = [regex]'\G\s*(?:"(?<lit>[^"\\]*)"|(?<name>ESC|BEL|os\.getcwd\(\)))\s*(?<sep>\.\.|\z)'
    $sb = [Text.StringBuilder]::new()
    $at = 0
    while ($true) {
        $m = $token.Match($Expr, $at)
        if (-not $m.Success) { Stop-Setup "the Clink prompt prefix is not a concatenation of plain strings, ESC, BEL and os.getcwd(). Update the cases." }
        if ($m.Groups['lit'].Success) { [void]$sb.Append($m.Groups['lit'].Value) }
        elseif (Test-Same $m.Groups['name'].Value 'ESC') { [void]$sb.Append($esc) }
        elseif (Test-Same $m.Groups['name'].Value 'BEL') { [void]$sb.Append($bel) }
        else { [void]$sb.Append($cwd) }
        if ($m.Groups['sep'].Length -eq 0) { break }
        $at = $m.Index + $m.Length
    }
    return $sb.ToString()
}

# cmd's PROMPT prefix: `cmd_prompt_prefix`, a concatenation of literals and consts, as cmd expands it.
$zig = Get-Source 'src\termio\shell_integration.zig'
function Resolve-ZigConst([string] $Name, [int] $Depth) {
    if ($Depth -gt 8) { Stop-Setup "shell_integration.zig's const $Name nests too deep." }
    $decl = @([regex]::Matches($zig, "(?m)^const $([regex]::Escape($Name)) = "))
    if ($decl.Count -ne 1) { Stop-Setup "shell_integration.zig declares const $Name $($decl.Count) times. Update the cases." }
    $token = [regex]'\G\s*(?:"(?<lit>(?:[^"\\\n]|\\.)*)"|(?<name>[A-Za-z_]\w*))\s*(?<sep>\+\+|;)'
    $sb = [Text.StringBuilder]::new()
    $at = $decl[0].Index + $decl[0].Length
    while ($true) {
        $m = $token.Match($zig, $at)
        if (-not $m.Success) { Stop-Setup "shell_integration.zig's const $Name is not a concatenation of string literals and consts. Update the cases." }
        if ($m.Groups['lit'].Success) {
            # Only `\\` (one backslash) is read here; another escape stops the run.
            $lit = $m.Groups['lit'].Value.Replace('\\', [string][char]0)
            if ($lit.Contains('\')) { Stop-Setup "shell_integration.zig's const $Name has an escape this harness does not read." }
            [void]$sb.Append($lit.Replace([string][char]0, '\'))
        }
        else { [void]$sb.Append((Resolve-ZigConst $m.Groups['name'].Value ($Depth + 1))) }
        $at = $m.Index + $m.Length
        if (Test-Same $m.Groups['sep'].Value ';') { break }
    }
    return $sb.ToString()
}
function ConvertFrom-CmdPrompt([string] $Text) {
    $sb = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -ne [char]'$') { [void]$sb.Append($Text[$i]); continue }
        if ($i + 1 -ge $Text.Length) { Stop-Setup 'cmd_prompt_prefix ends in a lone $.' }
        $i++
        $code = [char]::ToUpperInvariant($Text[$i])
        if ($code -eq [char]'E') { [void]$sb.Append($esc) }
        elseif ($code -eq [char]'P') { [void]$sb.Append($cwd) }
        elseif ($code -eq [char]'$') { [void]$sb.Append('$') }
        else { Stop-Setup "cmd_prompt_prefix uses the PROMPT code `$$code, which this harness does not expand. Update the cases." }
    }
    return $sb.ToString()
}

$shipped = @(
    [pscustomobject]@{ Name = 'integration.ps1 prompt wrapper (OSC 133;A)'; Bytes = ConvertFrom-Ps1String $ps1Prompt[0] }
    [pscustomobject]@{ Name = 'integration.ps1 reader fallback (OSC 133;P)'; Bytes = ConvertFrom-Ps1String $ps1Reader[0] }
    [pscustomobject]@{ Name = 'Clink prompt prefix (noctty-shell-integration.lua)'; Bytes = ConvertFrom-LuaConcat $luaPrefix[0].Groups[1].Value }
    [pscustomobject]@{ Name = 'cmd PROMPT prefix (cmd_prompt_prefix)'; Bytes = ConvertFrom-CmdPrompt (Resolve-ZigConst 'cmd_prompt_prefix' 0) }
)
# Each reset any of them sends, alone, in the order they first send them.
$resets = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($s in $shipped) {
    foreach ($seq in (Get-Sequences $s.Bytes)) {
        if ($seq.Text.StartsWith("$esc[", [StringComparison]::Ordinal) -and $seen.Add($seq.Text)) { $resets.Add($seq.Text) }
    }
}
if ($resets.Count -eq 0) { Stop-Setup 'the shipped prompt strings hold no CSI.' }
$cases = [Collections.Generic.List[object]]::new()
foreach ($r in $resets) { $cases.Add([pscustomobject]@{ Name = (Show-Bytes $r); Bytes = $r }) }
foreach ($s in $shipped) { $cases.Add($s) }
foreach ($extra in @("$esc[?5522h", "$esc[?2004h", "$esc[?2004l", "$esc[?9999h")) { $cases.Add([pscustomobject]@{ Name = (Show-Bytes $extra); Bytes = $extra }) }
foreach ($c in $cases) {
    if ($c.Bytes -cmatch '[^\x00-\x7F]') { Stop-Setup "case '$($c.Name)' is not ASCII; the client writes bytes in the console's code page." }
    if (-not (Test-Same (-join @((Get-Sequences $c.Bytes) | ForEach-Object Text)) $c.Bytes)) { Stop-Setup "case '$($c.Name)' holds text between its sequences; this harness reads sequences only." }
}
if ($ControlCase -ge $cases.Count) { Stop-Setup "-ControlCase $ControlCase is not a case (0 to $($cases.Count - 1))." }
Write-Host "Cases: $($cases.Count): the $($resets.Count) resets alone, the $($shipped.Count) shipped prompt strings, and 4 more."
for ($n = 0; $n -lt $cases.Count; $n++) {
    if (-not (Test-Same $cases[$n].Name (Show-Bytes $cases[$n].Bytes))) { Write-Host ('  {0,-3} {1}: {2}' -f $n, $cases[$n].Name, (Show-Bytes $cases[$n].Bytes)) }
}

# --- The probe -----------------------------------------------------------------
if (Test-Path -LiteralPath $Run) { Stop-Setup '-Run must be a new directory.' }
[void](New-Item -ItemType Directory -Path $Run)
$Run = (Resolve-Path -LiteralPath $Run).ProviderPath
$probe = Join-Path $Run 'conpty-passthru-probe.exe'
$compile = Join-Path $Run 'compile.cmd'
@(
    '@echo off'
    ('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" user32.lib > "{4}" 2>&1' -f
        (Join-Path $repoRoot 'scripts\dev-windows.cmd'), (Join-Path $PSScriptRoot 'conpty-passthru-probe.c'), $probe,
        (Join-Path $Run 'conpty-passthru-probe.obj'), (Join-Path $Run 'compile.log'))
    'exit /b %errorlevel%'
) | Set-Content -LiteralPath $compile -Encoding ascii
# Wait for cmd.exe itself: `Start-Process -Wait` also waits for every descendant, and the
# compile leaves one running for minutes after cl has finished (conpty.md, 2026-11-26 CONPTY-WIDTH-18, trap (3)).
$compileStart = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), "/d /c `"`"$compile`"`"")
$compileStart.UseShellExecute = $false
$compileStart.WorkingDirectory = $Run
$compileProcess = [Diagnostics.Process]::Start($compileStart)
if (-not $compileProcess.WaitForExit(300000)) { Stop-Setup 'the probe compile ran for five minutes.' }
if ($compileProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $probe)) { Stop-Setup "the probe did not compile ($($compileProcess.ExitCode)); see compile.log in the run directory." }
if ($CompileOnly) { Write-Host 'conpty-passthru-probe.c compiled; nothing run.'; exit 0 }

# One run per case and host, each on a private desktop of its own, so whatever a host writes
# in a run is the case's or the host's own (the baseline shows the host's own).
function Invoke-PassthruProbe([string] $Name, [string] $Source, [string] $Flags, [string] $Written) {
    $casesFile = Join-Path $Run "$Name.cases"
    $hex = if ($Written.Length -eq 0) { '-' } else { [Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($Written)) }
    [IO.File]::WriteAllText($casesFile, "$hex`n", [Text.Encoding]::ASCII)
    $out = Join-Path $Run "$Name.out"
    $desktop = 'noctty-passthru-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    & $probe launch $desktop $Source $Flags $casesFile $out
    $code = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath "$out.host")) { Stop-Setup "probe $Name exited $code and recorded no host." }
    $hostInfo = @{}
    foreach ($line in [IO.File]::ReadAllLines("$out.host")) { $k, $v = $line.Split("`t", 2); $hostInfo[$k] = $v }
    $writerInfo = @{}
    if (Test-Path -LiteralPath $out) { foreach ($line in [IO.File]::ReadAllLines($out)) { $k, $v = $line.Split("`t", 2); $writerInfo[$k] = $v } }
    $rawBytes = if (Test-Path -LiteralPath "$out.raw") { [IO.File]::ReadAllBytes("$out.raw") } else { [byte[]]@() }
    $expected = if ($Source -eq 'inbox') { 'conhost.exe' } else { 'OpenConsole.exe' }
    $problems = @(
        if ($code -ne 0) { "exit $code" }
        if ($hostInfo.probe_desktop_private -ne '1') { 'the probe was not on its private desktop' }
        if ($hostInfo.host_exe -ne $expected) { "the console host was $($hostInfo.host_exe), not $expected" }
        if ($hostInfo.host_image_matches -ne '1') { 'the console host is not the one in -Bin' }
        if ([int]$hostInfo.console_windows_private -lt 1) { 'no console window on the private desktop' }
        if ($hostInfo.console_windows_default -ne '0') { 'a console window on the Default desktop' }
        if ($hostInfo.writer_exit -ne '0' -or $hostInfo.writer_timed_out -ne '0') { "the writer exited $($hostInfo.writer_exit)" }
        if ($hostInfo.drain_finished -ne '1' -or $hostInfo.raw_write_failed -ne '0') { 'the host output was not kept whole' }
        if ([string]$rawBytes.Length -ne $hostInfo.host_output_bytes) { "the probe kept $($rawBytes.Length) of $($hostInfo.host_output_bytes) bytes" }
        if ($writerInfo['writer_desktop_private'] -ne '1') { 'the writer was not on the private desktop' }
        if ($writerInfo['cases'] -ne '1') { 'the writer did not write its one case' }
    )
    if ($problems.Count -ne 0) { Stop-Setup "probe ${Name}: $($problems -join '; ')." }
    return [Text.Encoding]::Latin1.GetString($rawBytes)
}

# Where the host put each sequence of the case, against the markers' place in its text.
function Measure-Case([string] $Raw, [string] $Name, [string] $Bytes) {
    $seqs = Get-Sequences $Raw
    $plain = [Text.StringBuilder]::new()
    $map = [Collections.Generic.List[int]]::new()
    $at = 0
    foreach ($s in @($seqs) + @([pscustomobject]@{ Index = $Raw.Length; End = $Raw.Length })) {
        for ($i = $at; $i -lt $s.Index; $i++) { [void]$plain.Append($Raw[$i]); $map.Add($i) }
        $at = $s.End
    }
    $text = $plain.ToString()
    $open = $text.IndexOf('<P0>', [StringComparison]::Ordinal)
    $close = if ($open -ge 0) { $text.IndexOf('</P0>', $open + 4, [StringComparison]::Ordinal) } else { -1 }
    if ($open -lt 0 -or $close -lt 0) { Stop-Setup "probe ${Name}: the host's output holds no <P0> ... </P0>." }
    $openStart = $map[$open]; $openEnd = $map[$open + 3] + 1
    $closeStart = $map[$close]; $closeEnd = $map[$close + 4] + 1
    $inside = $Raw.Substring($openEnd, $closeStart - $openEnd)
    $parts = foreach ($want in (Get-Sequences $Bytes)) { $want.Text }
    $used = [Collections.Generic.HashSet[int]]::new()
    $last = -1
    $placed = foreach ($want in @($parts)) {
        $hit = $null
        foreach ($s in $seqs) { if ($s.Index -gt $last -and -not $used.Contains($s.Index) -and (Test-Same $s.Text $want)) { $hit = $s; break } }
        if (-not $hit) { foreach ($s in $seqs) { if (-not $used.Contains($s.Index) -and (Test-Same $s.Text $want)) { $hit = $s; break } } }
        $where = if (-not $hit) { 'dropped' }
            elseif ($hit.End -le $openStart) { 'before the markers' }
            elseif ($hit.Index -ge $openEnd -and $hit.End -le $closeStart) { 'between the markers' }
            elseif ($hit.Index -ge $closeEnd) { 'after the markers' }
            else { 'inside a marker' }
        if ($hit) { [void]$used.Add($hit.Index); $last = $hit.Index }
        [pscustomobject]@{ Sequence = $want; Where = $where }
    }
    $placed = @($placed)
    $dropped = @($placed | Where-Object Where -eq 'dropped').Count
    $label = if (Test-Same $inside $Bytes) { 'in place' }
        elseif ($placed.Count -ne 0 -and $dropped -eq $placed.Count) { 'dropped' }
        elseif ($dropped -ne 0) { 'partly dropped' }
        elseif (@($placed | Where-Object Where -ne 'between the markers').Count -ne 0) { 'moved' }
        else { 'other bytes between the markers' }
    return [pscustomobject]@{ Label = $label; Placed = $placed; Inside = $inside; Sequences = @($seqs | ForEach-Object Text) }
}

$configs = @(
    [pscustomobject]@{ Key = 'bundled-0x0'; Title = 'bundled 0x0'; Source = $pair; Flags = '0'; Verdict = $true }
    [pscustomobject]@{ Key = 'bundled-0x10'; Title = 'bundled 0x10'; Source = $pair; Flags = '10'; Verdict = $true }
    [pscustomobject]@{ Key = 'inbox-0x0'; Title = 'in-box'; Source = 'inbox'; Flags = '0'; Verdict = $false }
)
$results = [Collections.Generic.List[object]]::new()
foreach ($config in $configs) {
    Write-Host "Running $($config.Title): the baseline and $($cases.Count) cases, one private desktop each."
    $raw = Invoke-PassthruProbe "$($config.Key)-baseline" $config.Source $config.Flags ''
    $m = Measure-Case $raw "$($config.Key)-baseline" ''
    $results.Add([pscustomobject]@{ Config = $config; Case = -1; Name = 'baseline (no bytes)'; Bytes = ''; M = $m; Baseline = $m.Sequences })
    $baseline = [Collections.Generic.HashSet[string]]::new([string[]]@($m.Sequences), [StringComparer]::Ordinal)
    for ($n = 0; $n -lt $cases.Count; $n++) {
        $written = if ($n -eq $ControlCase) { $controlBytes } else { $cases[$n].Bytes }
        $key = '{0}-c{1:D2}' -f $config.Key, $n
        $raw = Invoke-PassthruProbe $key $config.Source $config.Flags $written
        $m = Measure-Case $raw $key $cases[$n].Bytes
        foreach ($p in $m.Placed) { if ($p.Where -ne 'dropped' -and $baseline.Contains($p.Sequence)) { $p.Where += ' (the baseline has it too)' } }
        $results.Add([pscustomobject]@{ Config = $config; Case = $n; Name = $cases[$n].Name; Bytes = $cases[$n].Bytes; M = $m })
    }
}
Write-Host "Probes: $($results.Count) runs, each on its own private desktop; the bundled runs on the OpenConsole.exe in -Bin, the in-box runs on conhost.exe."

# --- The report -------------------------------------------------------------------
$report = Join-Path $Run 'results.tsv'
[IO.File]::WriteAllLines($report, [string[]](@("config`tcase`tname`tlabel`tsequence`twhere") + @(foreach ($r in $results) {
    if ($r.M.Placed.Count -eq 0) { "$($r.Config.Key)`t$($r.Case)`t$($r.Name)`t$($r.M.Label)`t-`t-" }
    foreach ($p in $r.M.Placed) { "$($r.Config.Key)`t$($r.Case)`t$($r.Name)`t$($r.M.Label)`t$(Show-Bytes $p.Sequence)`t$($p.Where)" }
})))

$width = [Math]::Max(20, (@($results | ForEach-Object { $_.Name.Length }) | Measure-Object -Maximum).Maximum + 4)
Write-Host (('{0,-' + ($width + 4) + '}{1,-14}{2,-14}{3}') -f 'case', 'bundled 0x0', 'bundled 0x10', 'in-box (information)')
foreach ($n in @(-1) + @(0..($cases.Count - 1))) {
    $row = @($results | Where-Object Case -eq $n)
    $label = { param($key) ($row | Where-Object { $_.Config.Key -eq $key }).M.Label }
    $caseName = if ($n -lt 0) { '-   ' + $row[0].Name } else { ('{0,-4}' -f $n) + $row[0].Name }
    Write-Host (('{0,-' + ($width + 4) + '}{1,-14}{2,-14}{3}') -f $caseName, (& $label 'bundled-0x0'), (& $label 'bundled-0x10'), (& $label 'inbox-0x0'))
}
foreach ($r in $results) {
    if (Test-Same $r.M.Label 'in place') { continue }
    $tag = if ($r.Config.Verdict) { 'NOT IN PLACE' } else { 'In-box (information only)' }
    $caseName = if ($r.Case -lt 0) { $r.Name } else { "case $($r.Case), $($r.Name)" }
    $where = @($r.M.Placed | ForEach-Object { "$(Show-Bytes $_.Sequence) $($_.Where)" }) -join '; '
    Write-Host "${tag}: $($r.Config.Title), ${caseName}: $($r.M.Label): $where; between the markers: [$(Show-Bytes $r.M.Inside)]"
}
foreach ($config in $configs) {
    $b = @($results | Where-Object { $_.Config.Key -eq $config.Key -and $_.Case -eq -1 })[0]
    $own = @($b.Baseline)
    $hits = @(foreach ($c in $cases) { foreach ($s in (Get-Sequences $c.Bytes)) { if (@($own | Where-Object { Test-Same $_ $s.Text }).Count -ne 0) { Show-Bytes $s.Text } } })
    $line = if ($hits.Count -eq 0) { 'none of the cases'' sequences' } else { "these of the cases' sequences: $(($hits | Select-Object -Unique) -join ', ')" }
    Write-Host "Baseline, $($config.Title): the host wrote $($own.Count) sequences of its own and $line."
}
if ($ControlCase -ge 0) { Write-Host "Control: the client wrote $(Show-Bytes $controlBytes) in place of case ${ControlCase}'s bytes ($($cases[$ControlCase].Name))." }

Write-Host "Results: $report"
$failed = @($results | Where-Object { $_.Config.Verdict -and -not (Test-Same $_.M.Label 'in place') })
if ($failed.Count -ne 0) {
    Write-Host "RESULT: FAIL ($($failed.Count) bundled runs not in place)"
    exit 1
}
Write-Host 'RESULT: PASS'
exit 0
