# Frame pacing under the per-copy rules: test/windows/bench-frame-pacing.ps1 measures bench-windows.ps1's
# frame_time_p95_ms with a fresh portable copy of the receipt-bound measurement build per run, its shell the copy's
# config's cmd.exe, timed from the copy's own render trace; bench-windows.ps1 -Metric frame-pacing delegates to it.
# Pinned here: what the harness may do and that its run-time checks are called (patterns over its code with the
# comments removed, each with a mutation that must fail it); that its shared pieces are #739's
# (hidden-win11-working-set.ps1) and bench-windows.ps1's byte for byte; its pure functions run on synthetic inputs with
# controls (the config, the argv, the visible part's refusal, the record verdict, the interval statistics, the
# workload hash, the marker frame); its run-time gates driven through behaviour, not text (the input gate and the
# foreground through a stand-in port, the summary's published output, the unlock payload, DesktopRefusal, the owned
# job, bench-windows.ps1's exit codes); the trace protocol's constants against the Zig source; and its native layer's
# struct layout and launch-desktop rules (compiled). No noctty is started: the launch cases name an executable that
# does not exist, and the owned-job case runs System32's cmd.exe /D /C exit 0 on a private desktop of its own.
$framePacingScript = Join-Path $repoRoot 'test\windows\bench-frame-pacing.ps1'
$framePacingBenchScript = Join-Path $repoRoot 'test\windows\bench-windows.ps1'
$framePacingWorkingSetScript = Join-Path $repoRoot 'test\windows\hidden-win11-working-set.ps1'
# Ordinal string equality for every comparison of config, argv, path and source text here.
function Test-FramePacingOrdinal([string] $A, [string] $B) { return [string]::Equals($A, $B, [StringComparison]::Ordinal) }

function Get-FramePacingCodeText([string] $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "A frame-pacing source does not parse: $Path" }
    $builder = [Text.StringBuilder]::new($text)
    foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    return $builder.ToString()
}
$framePacingText = Get-FramePacingCodeText $framePacingScript
$framePacingBenchText = Get-FramePacingCodeText $framePacingBenchScript

$framePacingRules = @(
    # --- admission, the copy and what the driver may launch
    @{
        Description = 'the outer half admits only the receipt-bound measurement build and refuses an inherited NOCTTY_ or GHOSTTY_ variable before it creates anything'
        Pattern = '(?s)function Invoke-FramePacingOuter \{\s+\$build = Get-WorkingSetMeasureBuild \$MeasureRepo\s+\$inherited = @\(\[Environment\]::GetEnvironmentVariables\(''Process''\)\.Keys [^\r\n]+\s+if \(\$inherited\.Count -ne 0\) \{ throw .*?\[void\]\(New-Item -ItemType Directory -Path \$root\)'
        Mutation = @('if ($inherited.Count -ne 0) { throw "This environment', 'if ($inherited.Count -lt 0) { throw "This environment')
    }
    @{
        Description = 'each run copies the build without noctty.ico, checks the copied app and CLI against the receipt, then marks it portable'
        Pattern = '(?s)function Invoke-FramePacingOuterRun\(\$build, \[string\] \$Run, \[long\] \$QuietSince\) \{.*?Where-Object \{ \$_\.Name -notin @\(''noctty\.ico'', ''crash'', ''ghostty''\) \}.*?if \(Test-Path -LiteralPath \(Join-Path \$copy ''noctty\.ico''\)\) \{ throw [^\r\n]+\}\s+if \(-not \(Test-WorkingSetCopy \$copy \$build\)\) \{ throw [^\r\n]+\}\s+\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @('if (-not (Test-WorkingSetCopy $copy $build)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the copy leaves noctty.ico behind'
        Pattern = 'Where-Object \{ \$_\.Name -notin @\(''noctty\.ico'', ''crash'', ''ghostty''\) \}'
        Mutation = @("@('noctty.ico', 'crash', 'ghostty')", "@('crash', 'ghostty')")
    }
    @{
        Description = 'the driver is given the staged copy, never the build itself'
        Pattern = '(?s)\$line = ''"\{0\}" -NoProfile -NonInteractive -File "\{1\}" -Driver -MeasureRepo "\{2\}" -Bin "\{3\}" -Run "\{4\}"[^\r\n]*'' -f `\s+\$pwsh, \$PSCommandPath, \$build\.Repo, \$copy, \$Run,'
        Mutation = @('$build.Repo, $copy, $Run,', '$build.Repo, $source, $Run,')
    }
    @{
        Description = 'the driver starts with LOCALAPPDATA, APPDATA, TEMP and TMP inside the run, in the owned job, on the run''s desktop'
        Pattern = '(?s)\$job = \[FramePacingNative\]::CreateRunJob\(\)\s+\$env:LOCALAPPDATA = Join-Path \$Run ''localappdata''; \$env:APPDATA = Join-Path \$Run ''appdata''\s+\$env:TEMP = Join-Path \$Run ''temp''; \$env:TMP = \$env:TEMP\s+.*?\$pi = \[FramePacingNative\]::LaunchDriver\(\$pwsh, \$line, \$Run, "WinSta0\\\$desktopName", \$job, \[bool\]\$Visible\)'
        Mutation = @("`$env:TEMP = Join-Path `$Run 'temp'", "`$env:TEMP = `$saved['TEMP']")
    }
    @{
        Description = 'the driver re-proves its isolation before it starts anything: its desktop (a dry run''s private one, neither Default nor the input desktop; a visible run''s Default while it is the input desktop), a job, and the four directories inside the run'
        Pattern = '(?s)\$own = \[FramePacingNative\]::CurrentDesktopName\(\)\s+\$inputDesktop = \[FramePacingNative\]::InputDesktopName\(\)\s+if \(-not \[string\]::Equals\(\$own, \$DesktopName, \[StringComparison\]::Ordinal\)\) \{ throw [^\r\n]+\}\s+if \(\$null -eq \$inputDesktop\) \{ throw [^\r\n]+\}\s+if \(\$Visible\) \{\s+if \(-not \[string\]::Equals\(\$own, ''Default'', \[StringComparison\]::OrdinalIgnoreCase\) -or -not \[string\]::Equals\(\$inputDesktop, ''Default'', \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw [^\r\n]+\}\s+\} else \{\s+if \(-not \$own\.StartsWith\(''noctty-fp-'', \[StringComparison\]::Ordinal\)\) \{ throw [^\r\n]+\}\s+if \(\[string\]::Equals\(\$own, ''Default'', \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw [^\r\n]+\}\s+if \(\[string\]::Equals\(\$own, \$inputDesktop, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw [^\r\n]+\}\s+\}\s+if \(-not \[FramePacingNative\]::InJob\(\)\) \{ throw [^\r\n]+\}.*?foreach \(\$name in @\(''LOCALAPPDATA'', ''APPDATA'', ''TEMP'', ''TMP''\)\) \{.*?StartsWith\(\$runPrefix, \[StringComparison\]::OrdinalIgnoreCase\)\) \{\s+throw '
        Mutation = @("if (-not [FramePacingNative]::InJob()) { throw 'The driver is in no job.' }", '')
    }
    @{
        Description = 'a dry run''s driver refuses the input desktop'
        Pattern = '(?s)\} else \{\s+if \(-not \$own\.StartsWith\(''noctty-fp-'', \[StringComparison\]::Ordinal\)\) \{ throw [^\r\n]+\}\s+if \(\[string\]::Equals\(\$own, ''Default'', \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw [^\r\n]+\}\s+if \(\[string\]::Equals\(\$own, \$inputDesktop, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw '
        Mutation = @("if ([string]::Equals(`$own, `$inputDesktop, [StringComparison]::OrdinalIgnoreCase)) { throw 'The driver is on the input desktop.' }", '')
    }
    @{
        Description = 'the driver refuses any inherited NOCTTY_ or GHOSTTY_ variable (NOCTTY_CONPTY among them), so the copy''s only ones are the four it sets'
        Pattern = '\$inherited = @\(\[Environment\]::GetEnvironmentVariables\(''Process''\)\.Keys \| Where-Object \{ \(\[string\]\$_\)\.StartsWith\(''NOCTTY_'', \[StringComparison\]::OrdinalIgnoreCase\) -or \(\[string\]\$_\)\.StartsWith\(''GHOSTTY_'', \[StringComparison\]::OrdinalIgnoreCase\) \}\)\s+if \(\$inherited\.Count -ne 0\) \{ throw "The driver inherited'
        Mutation = @('if ($inherited.Count -ne 0) { throw "The driver inherited', 'if ($inherited.Count -lt 0) { throw "The driver inherited')
    }
    @{
        Description = 'the driver launches only the staged copy: the run''s copy directory, the portable marker, no noctty.ico, the config byte for byte, the receipt''s bytes'
        Pattern = '(?s)if \(-not \[string\]::Equals\(\[IO\.Path\]::GetFullPath\(\$Bin\)\.TrimEnd\(''\\''\), \(Join-Path \$runPrefix ''copy''\), \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw .*?noctty\.portable.*?noctty\.ico.*?if \(-not \(Test-FramePacingConfigBytes \$configPath \$Run\)\) \{ throw .*?\$build = Get-WorkingSetMeasureBuild \$MeasureRepo\s+if \(-not \(Test-WorkingSetCopy \$Bin \$build\)\) \{ throw '
        Mutation = @('if (-not (Test-FramePacingConfigBytes $configPath $Run)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the copy''s config sets exactly one command, System32''s cmd.exe with /D, and no initial-command'
        Pattern = '\$configCommands = @\(\[IO\.File\]::ReadAllLines\(\$configPath\) \| Where-Object \{ \$_ -match ''\^\\s\*\(initial-\)\?command\\s\*='' \}\)\s+\$cmdPath = Join-Path \(\[Environment\]::GetFolderPath\(''System''\)\) ''cmd\.exe''\s+if \(\$configCommands\.Count -ne 1 -or -not \[string\]::Equals\(\$configCommands\[0\], "command = direct:\$cmdPath /D", \[StringComparison\]::Ordinal\)\) \{ throw'
        Mutation = @('if ($configCommands.Count -ne 1 -or', 'if ($configCommands.Count -lt 1 -or')
    }
    @{
        Description = 'a staged copy holding a legacy config is refused'
        Pattern = '\$stray = @\(Get-WorkingSetStrayConfigs \$Bin\); if \(\$stray\.Count -gt 0\) \{ throw '
        Mutation = @('if ($stray.Count -gt 0) { throw', 'if ($stray.Count -lt 0) { throw')
    }
    @{
        Description = 'the copy''s conpty.dll and OpenConsole.exe are the build''s, byte for byte'
        Pattern = '(?s)foreach \(\$file in @\(@\(''conpty\.dll'', ''ConptyDllSHA256''\), @\(''OpenConsole\.exe'', ''OpenConsoleSHA256''\)\)\) \{.*?if \(-not \[string\]::Equals\(\[string\]\$record\[\$file\[1\]\], \[string\]\$record\[''Prefix'' \+ \$file\[1\]\], \[StringComparison\]::Ordinal\)\) \{ throw '
        Mutation = @("@('OpenConsole.exe', 'OpenConsoleSHA256')", "@('conpty.dll', 'OpenConsoleSHA256')")
    }
    @{
        Description = 'the driver re-proves the payload: the generator''s bytes for the constants with this run''s fresh marker, byte for byte'
        Pattern = '(?s)\$marker = \[IO\.File\]::ReadAllText\(\(Join-Path \$work ''marker\.txt''\)\)\s+if \(\$marker -notmatch ''\\ANB\[0-9a-f\]\{16\}\\z''\) \{ throw .*?Write-FramePacingPayload \$checkPath \$marker\s+if \(-not \[string\]::Equals\(\(Get-Sha256 \$checkPath\), \(Get-Sha256 \$streamPath\), \[StringComparison\]::Ordinal\)\) \{ throw '
        Mutation = @('if (-not [string]::Equals((Get-Sha256 $checkPath), (Get-Sha256 $streamPath), [StringComparison]::Ordinal)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the build mode is checked through +version and against the receipt before the launch, and a mismatch launches nothing'
        Pattern = '(?s)''"\{0\}" \+version''.*?if \(-not \[string\]::Equals\(\[string\]\$record\.BuildMode, \$ExpectedBuildMode, \[StringComparison\]::Ordinal\) -or -not \[string\]::Equals\(\[string\]\$build\.Optimize, \$ExpectedBuildMode, \[StringComparison\]::Ordinal\)\) \{[^\r\n]*return 3 \}.*?\[FramePacingNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('not launched"; return 3 }', 'not launched" }')
    }
    # --- the visible part
    @{
        Description = 'the driver evaluates the visible part''s preconditions on its own session before any launch: a dry run must be refused, a visible run must not be'
        Pattern = '(?s)\$facts = Get-FramePacingSessionFacts \$QuietSinceTick\s+\$record\.Composition = \$facts\.Composition\s+\$record\.NotificationState = \$facts\.NotificationState\s+\$record\.VisibleRefusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$Visible -and \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}\s+if \(-not \$Visible -and -not \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}.*?Assert-Quiet ''\+version''\s+\$check = \[FramePacingNative\]::Spawn\('
        Mutation = @('if (-not $Visible -and -not $record.VisibleRefusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run whose preconditions fail on the driver''s session launches nothing, not even +version'
        Pattern = '(?s)\$record\.VisibleRefusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$Visible -and \$record\.VisibleRefusal\) \{ throw "INCONCLUSIVE: [^\r\n]+\}.*?\$check = \[FramePacingNative\]::Spawn\('
        Mutation = @('if ($Visible -and $record.VisibleRefusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the visible part''s preconditions are read after the quiet-machine wait, not before it'
        Pattern = '(?s)\$record\.QuietWaitMs = \$quietClock\.ElapsedMilliseconds\s+if [^\r\n]+\}\s+\}\s+\$record\.TimerResolutionBefore100ns = .*?\$facts = Get-FramePacingSessionFacts \$QuietSinceTick'
        Mutation = @('$record.QuietWaitMs = $quietClock.ElapsedMilliseconds', '$record.QuietWaitMs = 0')
    }
    @{
        Description = 'a visible run whose quiet wait expired without a reading under 30% launches nothing (Sol and CodeRabbit on #741)'
        Pattern = '(?s)\$record\.QuietWaitMs = \$quietClock\.ElapsedMilliseconds\s+if \(\$record\.BusyPercentBefore -lt 0 -or \$record\.BusyPercentBefore -ge \$script:QuietBusyPercent\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\}.*?Assert-Quiet ''\+version'''
        Mutation = @('{ throw "INCONCLUSIVE: the machine was not under', '{ Log "INCONCLUSIVE: the machine was not under')
    }
    @{
        Description = 'the outer half refuses -Visible off an unlocked, composed, local, idle Default before it creates anything, and keeps the tick it saw idle'
        Pattern = '(?s)\$quietSince = \[long\]-1\s+if \(\$Visible\) \{\s+\$facts = Get-FramePacingSessionFacts -1\s+\$refusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$refusal\) \{ throw [^\r\n]+\}\s+\$quietSince = \[long\]\$facts\.LastInputTick\s+\}.*?\[void\]\(New-Item -ItemType Directory -Path \$root\)'
        Mutation = @('if ($refusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run waits for a machine under 30% busy (MEASUREMENT-HARNESS-RERUN-01)'
        Pattern = '(?s)if \(\$Visible\) \{\s+\$quietClock = \[Diagnostics\.Stopwatch\]::StartNew\(\)\s+while \(\(\$record\.BusyPercentBefore -lt 0 -or \$record\.BusyPercentBefore -ge \$script:QuietBusyPercent\) -and \$quietClock\.ElapsedMilliseconds -lt \[long\]\$QuietWaitSeconds \* 1000\) \{'
        Mutation = @('-ge $script:QuietBusyPercent) -and $quietClock', '-ge 100) -and $quietClock')
    }
    @{
        Description = 'only a visible run takes the foreground, through the input gate; a dry run records it as skipped'
        Pattern = '(?s)if \(\$Visible\) \{\s+if \(\$record\.DisplayPowerBefore -ne \$script:DisplayOn\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\$record\.Foreground = Invoke-FramePacingForeground \$port \$record\.InputTicks \$hostWindow \$nocttyPid.*?\} else \{ \$record\.Foreground = ''skipped'' \}'
        Mutation = @("} else { `$record.Foreground = 'skipped' }", "} else { `$record.Foreground = Invoke-FramePacingForeground `$port `$record.InputTicks `$hostWindow `$nocttyPid }")
    }
    @{
        Description = 'a visible run takes the foreground only with the display on (Opus on #741)'
        Pattern = 'if \(\$record\.DisplayPowerBefore -ne \$script:DisplayOn\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\$record\.Foreground = Invoke-FramePacingForeground'
        Mutation = @('if ($record.DisplayPowerBefore -ne $script:DisplayOn) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a minimized window is not a foreground (Opus on #741)'
        Pattern = 'if \(\[FramePacingNative\]::IsIconic\(\$hostWindow\)\) \{ \$record\.Foreground = ''minimized'' \}'
        Mutation = @("if ([FramePacingNative]::IsIconic(`$hostWindow)) { `$record.Foreground = 'minimized' }", '')
    }
    @{
        Description = 'a visible run whose foreground did not take is not measured'
        Pattern = 'if \(-not \[string\]::Equals\(\[string\]\$record\.Foreground, ''ok'', \[StringComparison\]::Ordinal\)\) \{ throw "INCONCLUSIVE: '
        Mutation = @("if (-not [string]::Equals([string]`$record.Foreground, 'ok', [StringComparison]::Ordinal)) { throw `"INCONCLUSIVE: ", "if (`$false) { throw `"INCONCLUSIVE: ")
    }
    @{
        Description = 'the foreground call is bounded: the window must be this copy''s, not hung and answer WM_NULL first, and the calls run on a worker joined within the bound (VISIBLE-PACING-CERT-01 trap 1)'
        Pattern = '(?s)public static string Foreground\(IntPtr hwnd, int pid, int boundMs, long expectedTick, out long unlockTick\) \{\s+unlockTick = -1;\s+if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(IsHungAppWindow\(hwnd\) \|\| !Responsive\(hwnd, \(uint\)boundMs\)\) return "hung";.*?worker\.IsBackground = true;\s+worker\.Start\(\);\s+if \(!worker\.Join\(boundMs\)\) return "timeout";'
        Mutation = @('if (!worker.Join(boundMs)) return "timeout";', 'worker.Join();')
    }
    @{
        Description = 'the foreground call refuses a hung or unresponsive window before any cross-thread call'
        Pattern = '(?s)public static string Foreground\(IntPtr hwnd, int pid, int boundMs, long expectedTick, out long unlockTick\) \{\s+unlockTick = -1;\s+if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(IsHungAppWindow\(hwnd\) \|\| !Responsive\(hwnd, \(uint\)boundMs\)\) return "hung";'
        Mutation = @('if (IsHungAppWindow(hwnd) || !Responsive(hwnd, (uint)boundMs)) return "hung";', '')
    }
    @{
        Description = 'the foreground is unlocked by one zero-motion mouse input built in one place, never an Alt tap (PROBE-ALT-TAP-01), and only when SendInput inserted it'
        Pattern = '(?s)if \(SendInput\(1, UnlockInput\(\), Marshal\.SizeOf<Input>\(\)\) != 1\) \{ outcome = "unlock-not-inserted"; return; \}.*?static Input\[\] UnlockInput\(\) \{\s+var unlock = new Input\[\] \{ new Input \{ type = 0 \} \};\s+unlock\[0\]\.mouse\.flags = 0x0001;[^\r\n]*\s+return unlock;\s+\}'
        Mutation = @('new Input { type = 0 }', 'new Input { type = 1 }')
    }
    @{
        Description = 'the native foreground checks the series'' tick again on its worker right before its one input, and sends nothing when it moved (Sol and Opus on #741)'
        Pattern = 'long before = LastInputTick\(\);\s+if \(before != expectedTick\) \{ outcome = "input-before-unlock"; return; \}\s+if \(SendInput\(1, UnlockInput\(\), Marshal\.SizeOf<Input>\(\)\) != 1\)'
        Mutation = @('if (before != expectedTick) { outcome = "input-before-unlock"; return; }', '')
    }
    @{
        Description = 'a visible run counts only with the foreground and the pane''s focus unchanged from the arm to the end marker''s swap'
        Pattern = '(?s)\$focusChanges = \[uint64\]\$echoed\.surface_focus_change_count.*?\$record\.ForegroundHeld = \[FramePacingNative\]::IsForeground\(\$hostWindow\)\s+\$record\.FocusHeld = \[bool\]\$presented\.surface_focused -and \[uint64\]\$presented\.surface_focus_change_count -eq \$focusChanges'
        Mutation = @('-and [uint64]$presented.surface_focus_change_count -eq $focusChanges', '')
    }
    @{
        Description = 'the input gate runs right before each launch on Default (+version, the copy, the grid probe), against the series'' tick or the unlock''s (Sol''s High on #741): the copy'
        Pattern = '(?s)function Assert-Quiet\(\[string\] \$Before\) \{ if \(\$Visible\) \{ Assert-FramePacingInputGate \$port \$record\.InputTicks \$Before \} \}.*?Assert-Quiet ''\+version''\s+\$check = \[FramePacingNative\]::Spawn\(.*?Assert-Quiet ''the copy''''s launch''\s+\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine.*?Assert-Quiet ''the grid probe''\s+\$probe = \[FramePacingNative\]::Spawn\('
        Mutation = @("Assert-Quiet 'the copy''s launch'", '')
    }
    @{
        Description = 'the input gate runs right before each launch on Default: the grid probe'
        Pattern = '(?s)function Assert-Quiet\(\[string\] \$Before\) \{ if \(\$Visible\) \{ Assert-FramePacingInputGate \$port \$record\.InputTicks \$Before \} \}.*?Assert-Quiet ''\+version''\s+\$check = \[FramePacingNative\]::Spawn\(.*?Assert-Quiet ''the copy''''s launch''\s+\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine.*?Assert-Quiet ''the grid probe''\s+\$probe = \[FramePacingNative\]::Spawn\('
        Mutation = @("Assert-Quiet 'the grid probe'", '')
    }
    @{
        Description = 'the input gate runs right before each launch on Default: +version'
        Pattern = '(?s)function Assert-Quiet\(\[string\] \$Before\) \{ if \(\$Visible\) \{ Assert-FramePacingInputGate \$port \$record\.InputTicks \$Before \} \}.*?Assert-Quiet ''\+version''\s+\$check = \[FramePacingNative\]::Spawn\(.*?Assert-Quiet ''the copy''''s launch''\s+\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine.*?Assert-Quiet ''the grid probe''\s+\$probe = \[FramePacingNative\]::Spawn\('
        Mutation = @("Assert-Quiet '+version'", '')
    }
    @{
        Description = 'the gate applies to a visible run only and reads the run''s own ticks'
        Pattern = 'function Assert-Quiet\(\[string\] \$Before\) \{ if \(\$Visible\) \{ Assert-FramePacingInputGate \$port \$record\.InputTicks \$Before \} \}'
        Mutation = @('if ($Visible) { Assert-FramePacingInputGate', 'if ($false) { Assert-FramePacingInputGate')
    }
    @{
        Description = 'the input gate holds immediately before the measured window, after the load reading right before it (Greptile, CodeRabbit, Sol and Opus on #741)'
        Pattern = '(?s)\$record\.BusyPercentAtArm = \[Math\]::Round\(\[FramePacingNative\]::BusyPercent\(2000\), 1\)\s+Assert-Quiet ''the measured window''\s+\$donePath = Join-Path \$work ''done\.flag''.*?TraceMessage\(\$pane, \$nocttyPid, \$script:WmRenderTraceTarget'
        Mutation = @("Assert-Quiet 'the measured window'", '')
    }
    @{
        Description = 'the input gate is read again after the end marker''s swap, and a break makes the run inconclusive'
        Pattern = '(?s)if \(\$Visible\) \{\s+\$record\.InputBreak = Test-FramePacingInputGate \$port \$record\.InputTicks ''the end of the measured window''\s+\$record\.InputDuringRun = \$null -ne \$record\.InputBreak\s+\}'
        Mutation = @('$record.InputDuringRun = $null -ne $record.InputBreak', '$record.InputDuringRun = $false')
    }
    @{
        Description = 'the unlock''s tick is the one the unlock itself left: read after SendInput, waited for while it is still the tick before, and taken on the worker before any foreground call'
        Pattern = '(?s)long before = LastInputTick\(\);\s+if \(before != expectedTick\) \{[^\r\n]+\}\s+if \(SendInput\(1, UnlockInput\(\), Marshal\.SizeOf<Input>\(\)\) != 1\) \{ outcome = "unlock-not-inserted"; return; \}\s+var waited = System\.Diagnostics\.Stopwatch\.StartNew\(\);\s+long now = LastInputTick\(\);\s+while \(now == before && waited\.ElapsedMilliseconds < 1000\) \{ Thread\.Sleep\(5\); now = LastInputTick\(\); \}\s+tick = now;\s+SetForegroundWindow\(hwnd\);.*?if \(!worker\.Join\(boundMs\)\) return "timeout";\s+unlockTick = tick;'
        Mutation = @('unlockTick = tick;', 'unlockTick = LastInputTick();')
    }
    @{
        Description = 'each run reads its window''s display mode at the start and again after the window, and a change is inconclusive (Greptile on #741)'
        Pattern = '(?s)\$record\.DisplayMode = ''\{0\}x\{1\}@\{2\}'' -f \$monitorMode\[0\], \$monitorMode\[1\], \$monitorMode\[2\].*?\$modeAfter = \[FramePacingNative\]::MonitorMode\(\$hostWindow\)\s+\$record\.DisplayModeAfter = ''\{0\}x\{1\}@\{2\}'' -f \$modeAfter\[0\], \$modeAfter\[1\], \$modeAfter\[2\]'
        Mutation = @("`$record.DisplayModeAfter = '{0}x{1}@{2}' -f `$modeAfter[0], `$modeAfter[1], `$modeAfter[2]", '$record.DisplayModeAfter = $record.DisplayMode')
    }
    # --- the copy's launch
    @{
        Description = 'the copy''s argv is exactly the expected list, on the final command line and on the copy''s own command line read back by PID'
        Pattern = '(?s)\$expectedArgv = Get-FramePacingExpectedArgv \$exe "noctty-interactive-\$\(\$layout\.SandboxId\)" \$configPath\s+if \(-not \(Test-WorkingSetArgv \(\[FramePacingNative\]::SplitCommandLine\(\$commandLine\)\) \$expectedArgv\)\) \{ throw .*?\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine, .*?\$launched = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = \$nocttyPid" -ErrorAction Stop\s+\$launchedLine = \[string\]\$launched\.CommandLine\s+if \(-not \(Test-WorkingSetArgv \(\[FramePacingNative\]::SplitCommandLine\(\$launchedLine\)\) \$expectedArgv\)\) \{ throw '
        Mutation = @('if (-not (Test-WorkingSetArgv ([FramePacingNative]::SplitCommandLine($launchedLine)) $expectedArgv)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'what runs is the run''s own copy: the executable''s path derived from the run is checked before any launch (Sol''s uncopied-build mutation on #741)'
        Pattern = '(?s)\$copyExe = Join-Path \(\$runPrefix \+ ''copy''\) ''noctty\.exe''\s+\$exe = Join-Path \$Bin ''noctty\.exe''\s+if \(-not \[string\]::Equals\(\[IO\.Path\]::GetFullPath\(\$exe\), \$copyExe, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw .*?if \(-not \[string\]::Equals\(\[string\]\$launched\.ExecutablePath, \$copyExe, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw '
        Mutation = @("`$exe = Join-Path `$Bin 'noctty.exe'", "`$exe = Join-Path `$build.Bin 'noctty.exe'")
    }
    @{
        Description = 'what runs is the run''s own copy: the launched image is read back by PID'
        Pattern = '(?s)\$copyExe = Join-Path \(\$runPrefix \+ ''copy''\) ''noctty\.exe''.*?if \(-not \[string\]::Equals\(\[string\]\$launched\.ExecutablePath, \$copyExe, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw '
        Mutation = @('if (-not [string]::Equals([string]$launched.ExecutablePath, $copyExe, [StringComparison]::OrdinalIgnoreCase)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the final command line is checked against the expected list before the launch'
        Pattern = '(?s)if \(-not \(Test-WorkingSetArgv \(\[FramePacingNative\]::SplitCommandLine\(\$commandLine\)\) \$expectedArgv\)\) \{ throw .*?\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine, '
        Mutation = @('if (-not (Test-WorkingSetArgv ([FramePacingNative]::SplitCommandLine($commandLine)) $expectedArgv)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the launch helper is asked for no shell (-UseConfiguredCommand), and the harness adds only its own isolation, the clipboard denial and the generated config'
        Pattern = '\$launchArguments = @\(Get-InteractiveWin11LaunchArguments -Layout \$layout -UseConfiguredCommand\) \+ @\(\s+''--window-save-state=never'', ''--clipboard-read=deny'', ''--clipboard-write=deny'',\s+''--config-default-files=false'', "--config-file=\$configPath"\)'
        Mutation = @('-UseConfiguredCommand) + @(', ') + @(')
    }
    @{
        Description = 'the command line must not set the shell'
        Pattern = 'if \(@\(\$launchArguments \| Where-Object \{ \$_ -like ''--command=\*'' -or \$_ -eq ''-e'' \}\)\.Count -ne 0\) \{ throw '
        Mutation = @("if (@(`$launchArguments | Where-Object { `$_ -like '--command=*' -or `$_ -eq '-e' }).Count -ne 0) { throw", "if (`$false) { throw")
    }
    @{
        Description = 'the copy''s environment adds only the log, the live render trace into the run and the run''s end marker, set right before its launch'
        Pattern = '\$env:GHOSTTY_LOG = ''stderr''\s+\$env:NOCTTY_RENDER_TRACE_FILE = \$tracePath\s+\$env:NOCTTY_RENDER_TRACE_LIVE = ''1''\s+\$env:NOCTTY_BENCH_END_MARKER = \$marker\s+Assert-Quiet ''the copy''''s launch''\s+\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine, \$work, \$desktopPath, \(Join-Path \$Run ''noctty\.log''\), \$false, \[bool\]\$Visible\)'
        Mutation = @("`$env:NOCTTY_RENDER_TRACE_LIVE = '1'", "`$env:NOCTTY_RENDER_TRACE_LIVE = '0'")
    }
    @{
        Description = 'the copy runs at normal priority'
        Pattern = 'if \(-not \[string\]::Equals\(\[string\]\$record\.NocttyPriority, ''Normal'', \[StringComparison\]::Ordinal\)\) \{ throw '
        Mutation = @("if (-not [string]::Equals([string]`$record.NocttyPriority, 'Normal'", "if (`$false -and [string]::Equals([string]`$record.NocttyPriority, 'Normal'")
    }
    @{
        Description = 'the grid is read before the workload and must be the pinned one'
        Pattern = '(?s)\$record\.GridCols = \[int\]\$grid\.Groups\[1\]\.Value; \$record\.GridRows = \[int\]\$grid\.Groups\[2\]\.Value\s+if \(\$record\.GridCols -ne \$script:Cols -or \$record\.GridRows -ne \$script:GridRows\) \{ throw .*?\$settled = Wait-Quiet'
        Mutation = @(' -or $record.GridRows -ne $script:GridRows) { throw', ') { throw')
    }
    # --- the workload and its trace
    @{
        Description = 'F5''s command, its echo presented and quiet, then the trace armed for the end marker (WM_APP + 9 with 0) and checked armed, then F6''s Enter'
        Pattern = '(?s)\[FramePacingNative\]::Key\(\$pane, \$nocttyPid, 0x74\)\s+if \(-not \(Wait-For \{ \[uint64\]\(Request-Trace\)\.last_swap_process_output_generation -gt \[uint64\]\$before\.last_swap_process_output_generation \} 15000\)\) \{ throw [^\r\n]+\}\s+\$echoed = Wait-Quiet \$script:EchoQuietMs 15000.*?if \(-not \[FramePacingNative\]::TraceMessage\(\$pane, \$nocttyPid, \$script:WmRenderTraceTarget, 0, \$script:ResponseBoundMs\)\) \{ throw [^\r\n]+\}\s+\$armed = Request-Trace\s+if \(-not \$armed\.target_active -or \[uint64\]\$armed\.target_process_output_bytes -ne 0 -or \[uint64\]\$armed\.first_target_swap_qpc_ticks -ne 0\) \{ throw [^\r\n]+\}\s+\[FramePacingNative\]::Key\(\$pane, \$nocttyPid, 0x75\)'
        Mutation = @('if (-not $armed.target_active -or', 'if ($false -and')
    }
    @{
        Description = 'the arm targets the end marker (0), not a byte count'
        Pattern = '\[FramePacingNative\]::TraceMessage\(\$pane, \$nocttyPid, \$script:WmRenderTraceTarget, 0, \$script:ResponseBoundMs\)'
        Mutation = @('$script:WmRenderTraceTarget, 0, $script:ResponseBoundMs', '$script:WmRenderTraceTarget, 1, $script:ResponseBoundMs')
    }
    @{
        Description = 'the window ends at the first swap that presented the end marker'
        Pattern = '\[uint64\]\$s\.first_target_swap_qpc_ticks -gt 0 -and \[uint64\]\$s\.first_target_swap_benchmark_end_marker_generation -gt 0'
        Mutation = @(' -and [uint64]$s.first_target_swap_benchmark_end_marker_generation -gt 0', '')
    }
    @{
        Description = 'the samples are the trace''s own intervals over its own QPC frequency, with its overflow count'
        Pattern = '\$record\.IntervalOverflow = \[uint64\]\$presented\.target_swap_interval_overflow_count\s+\$stats = Get-FramePacingIntervalStats @\(\$presented\.target_swap_interval_qpc_ticks\) \(\[double\]\$presented\.qpc_frequency\)'
        Mutation = @('([double]$presented.qpc_frequency)', '(1000.0)')
    }
    @{
        Description = 'the workload starts from a pane that presented a frame and went quiet'
        Pattern = '\$settled = Wait-Quiet \$script:QuietMs 30000\s+if \(\[uint64\]\$settled\.swap_buffers_count -lt 1\) \{ throw '
        Mutation = @('if ([uint64]$settled.swap_buffers_count -lt 1) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'no PowerShell runs under the copy: the copy''s children and its shell''s, for both PowerShells'
        Pattern = 'foreach \(\$parent in @\(\$nocttyPid\) \+ @\(\$shells\)\) \{ foreach \(\$name in @\(''powershell\.exe'', ''pwsh\.exe''\)\) \{ \$record\.PowerShellUnderCopy \+= @\(\[FramePacingNative\]::Children\(\$parent, \$name\)\)\.Count \} \}'
        Mutation = @("@('powershell.exe', 'pwsh.exe')", "@('powershell.exe')")
    }
    @{
        Description = 'the transport is the bundled ConPTY from the copy''s own conpty.dll, read from its log'
        Pattern = '\$record\.Transport = if \(\$nocttyLog\.Contains\(''using the in-box conhost''\)\) \{ ''inbox'' \} elseif \(\$nocttyLog\.IndexOf\(''using bundled ConPTY: '' \+ \(Join-Path \$Bin ''conpty\.dll''\), \[StringComparison\]::OrdinalIgnoreCase\) -ge 0\) \{ ''bundled'' \} else \{ ''unknown'' \}'
        Mutation = @("{ 'inbox' }", "{ 'bundled' }")
    }
    @{
        Description = 'a renderer fallback (a startup failure or any Direct3D 11 line) is not OpenGL'
        Pattern = '\$record\.Renderer = if \(\$nocttyLog\.Contains\(''startup failed''\) -or \$nocttyLog\.Contains\(''Direct3D 11''\) -or \$nocttyLog\.Contains\(''D3D11''\)\) \{ ''fallback'' \} else \{ ''opengl'' \}'
        Mutation = @("{ 'fallback' }", "{ 'opengl' }")
    }
    @{
        Description = 'the driver applies the record verdict before it reports success'
        Pattern = '(?s)\$problems = @\(Get-FramePacingRecordProblems \(\[pscustomobject\]\$record\)\)\s+if \(\$problems\.Count -gt 0 -and -not \$record\.Error\) \{\s+\$soft = .*?\$record\.Error = [^\r\n]+\s+\}\s+if \(-not \$record\.Error\) \{ return 0 \}'
        Mutation = @('if ($problems.Count -gt 0 -and -not $record.Error) {', 'if ($false) {')
    }
    @{
        Description = 'a visible series'' later runs check the session''s input against the tick the last run''s own unlock left'
        Pattern = '(?s)\$result = Invoke-FramePacingOuterRun \$build \(Join-Path \$root "run-\$i"\) \$quietSince\s+\$results\.Add\(\$result\)\s+if \(\$Visible -and \$null -ne \$result\.Record -and \$null -ne \$result\.Record\.InputTicks -and \$null -ne \$result\.Record\.InputTicks\.Unlock\) \{ \$quietSince = \[long\]\$result\.Record\.InputTicks\.Unlock \}.*?-QuietSinceTick \{9\}'' -f `\s+[^\r\n]+\$QuietWaitSeconds, \$QuietSince'
        Mutation = @('{ $quietSince = [long]$result.Record.InputTicks.Unlock }', '{ }')
    }
    @{
        Description = 'nothing is sent to the pane inside the measured window: cmd''s done.flag is polled as a file, then one snapshot at a time after the drain (Opus on #741)'
        Pattern = '(?s)\[FramePacingNative\]::Key\(\$pane, \$nocttyPid, 0x75\)\s+if \(-not \(Wait-For \{ Test-Path -LiteralPath \$donePath -PathType Leaf \} 120000\)\) \{ throw [^\r\n]+\}\s+\$doneQpc = .*?while \(\$null -eq \$presented\) \{\s+Start-Sleep -Milliseconds \$script:DrainMs\s+.*?\$s = Request-Trace\s+if \(\[uint64\]\$s\.first_target_swap_qpc_ticks -gt 0 -and \[uint64\]\$s\.first_target_swap_benchmark_end_marker_generation -gt 0\) \{ \$presented = \$s \}\s+else \{\s+\$snapshotsInWindow\+\+'
        Mutation = @('if (-not (Wait-For { Test-Path -LiteralPath $donePath -PathType Leaf } 120000))', 'if (-not (Wait-For { [bool](Request-Trace) } 120000))')
    }
    @{
        Description = 'a snapshot that still shows the target armed is counted as inside the window, and the count is recorded'
        Pattern = '(?s)else \{\s+\$snapshotsInWindow\+\+.*?\$record\.SnapshotsInWindow = \$snapshotsInWindow'
        Mutation = @('$snapshotsInWindow++', '')
    }
    @{
        Description = 'the producer''s end is cmd''s own done.flag, which must not exist before the window'
        Pattern = 'if \(Test-Path -LiteralPath \$donePath\) \{ throw '
        Mutation = @('if (Test-Path -LiteralPath $donePath) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the outer half checks the driver runs in the run''s own job right after the launch (Sol on #741)'
        Pattern = '\$pi = \[FramePacingNative\]::LaunchDriver\(\$pwsh, \$line, \$Run, "WinSta0\\\$desktopName", \$job, \[bool\]\$Visible\)\s+if \(-not \[FramePacingNative\]::InJobOf\(\$pi\.process, \$job\)\) \{ \[FramePacingNative\]::Terminate\(\$pi\.process, 1\); throw [^\r\n]+\}'
        Mutation = @('if (-not [FramePacingNative]::InJobOf($pi.process, $job)) {', 'if ($false) {')
    }
    @{
        Description = 'LaunchDriver resumes the driver only once it is a member of the run''s own job (the contract''s owned-job case runs it)'
        Pattern = 'if \(!AssignProcessToJobObject\(job, pi\.process\) \|\| !InJobOf\(pi\.process, job\) \|\| ResumeThread\(pi\.thread\) == 0xFFFFFFFF\) \{'
        Mutation = @('|| !InJobOf(pi.process, job) ||', '||')
    }
    @{
        Description = 'both launches take their desktop''s admission from DesktopRefusal with the live names (tabled below)'
        Pattern = '(?s)string refusal = DesktopRefusal\(desktop, "WinSta0\\\\" \+ CurrentDesktopName\(\), InputDesktopName\(\), visible, true\);\s+if \(refusal != null\) throw new Exception\(refusal\);.*?string refusal = DesktopRefusal\(desktop, "WinSta0\\\\" \+ CurrentDesktopName\(\), InputDesktopName\(\), visible, false\);\s+if \(refusal != null\) throw new Exception\(refusal\);'
        Mutation = @('visible, false);', 'visible, true);')
    }
    @{
        Description = 'a visible series holds the display on and releases it at the end (Opus on #741)'
        Pattern = '(?s)if \(\$Visible\) \{ \$held = \[FramePacingNative\]::HoldDisplay\(\); if \(-not \$held\) \{ throw [^\r\n]+\} \}.*?finally \{\s+if \(\$held\) \{ \[FramePacingNative\]::ReleaseDisplay\(\) \}'
        Mutation = @('if ($held) { [FramePacingNative]::ReleaseDisplay() }', '')
    }
    @{
        Description = 'a staging failure is a failed run before any launch, and the series still writes its summary (CodeRabbit on #741)'
        Pattern = '(?s)try \{\s+\[void\]\(New-Item -ItemType Directory -Path \$Run\).*?\} catch \{\s+return \[pscustomobject\]@\{ Run = \$Run; Status = ''failed''; Failures = @\("staging failed before any launch: [^\r\n]+\}\s+\}\s+\$realLocal ='
        Mutation = @("Status = 'failed'; Failures = @(`"staging failed", "Status = 'complete'; Failures = @(`"staging failed")
    }
    @{
        Description = 'the driver exits 2 only for an INCONCLUSIVE error, and every problem must be the environment''s for its verdict to say so'
        Pattern = '(?s)\$soft = @\(\$problems \| Where-Object \{ \$_\.StartsWith\(''inconclusive:'', \[StringComparison\]::Ordinal\) \}\)\s+\$record\.Error = \$\(if \(\$soft\.Count -eq \$problems\.Count\) \{ ''INCONCLUSIVE: '' \} else \{ '''' \}\) \+ \(\$problems -join ''; ''\)\s+\}\s+if \(-not \$record\.Error\) \{ return 0 \}\s+return \$\(if \(\$record\.Error\.StartsWith\(''INCONCLUSIVE:'', \[StringComparison\]::Ordinal\)\) \{ 2 \} else \{ 1 \}\)'
        Mutation = @('if ($soft.Count -eq $problems.Count) {', 'if ($soft.Count -gt 0) {')
    }
    # --- the guards, the series and the summary
    @{
        Description = 'each run keeps the shared state guard, the history guard and the real session file''s metadata, and a changed one is a tripped guard'
        Pattern = '(?s)\$sessionBefore = Get-Metadata \$sessionPath\s+\$stateGuard = Start-InteractiveWin11StateGuard -Harness ''bench-frame-pacing'' -ReceiptDirectory \$Run\s+\$historyGuard = Start-WindowsHarnessHistoryGuard -Harness ''bench-frame-pacing\.ps1''.*?try \{ Assert-InteractiveWin11StateGuard -Guard \$stateGuard \} catch \{ \$stateFailure = \$_\.Exception\.Message \}.*?try \{ Assert-WindowsHarnessHistoryGuard -Guard \$historyGuard \} catch \{ \$historyFailure = \$_\.Exception\.Message \}.*?if \(\$stateFailure\) \{ \$guardFailures \+= \$stateFailure \}\s+if \(-not \$guards\.SessionUnchanged\) \{ \$guardFailures \+= [^\r\n]+\}\s+if \(\$historyFailure\) \{ \$guardFailures \+= \$historyFailure \}.*?\$status = Get-FramePacingRunStatus @\(\$guardFailures\) @\(\$outerFailures\) \$driverExit \$driverError @\(\$problems\)'
        Mutation = @("if (-not `$guards.SessionUnchanged) { `$guardFailures += 'the real session-state.json changed' }", '')
    }
    @{
        Description = 'the history guard''s verdict reaches the run''s status'
        Pattern = '(?s)try \{ Assert-WindowsHarnessHistoryGuard -Guard \$historyGuard \} catch \{ \$historyFailure = \$_\.Exception\.Message \}.*?if \(\$historyFailure\) \{ \$guardFailures \+= \$historyFailure \}'
        Mutation = @('if ($historyFailure) { $guardFailures += $historyFailure }', '')
    }
    @{
        Description = 'the outer half checks the record''s mode and where the copy ran from (each directory inside the run, none a real one)'
        Pattern = '(?s)if \(-not \[string\]::Equals\(\[string\]\$record\.Mode, \$wantMode, \[StringComparison\]::Ordinal\)\) \{ \$outerFailures \+= .*?foreach \(\$name in @\(''LOCALAPPDATA'', ''APPDATA'', ''TEMP'', ''TMP''\)\) \{\s+\$dir = \[string\]\$record\.EffectiveDirs\.\$name\s+if \(-not \$dir -or .*?@\(\$realDirs \| Where-Object '
        Mutation = @('$dir = [string]$record.EffectiveDirs.$name', '$dir = Join-Path $Run $name')
    }
    @{
        Description = 'the series runs one harness at a time in the session'
        Pattern = '(?s)\$mutex = \[Threading\.Mutex\]::new\(\$false, ''Local\\noctty-bench-frame-pacing''\).*?if \(-not \$owned\) \{ throw '
        Mutation = @('if (-not $owned) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the run root is new, outside the build, and not an unignored directory of the measure repo'
        Pattern = '(?s)if \(Test-Path -LiteralPath \$root\) \{ throw [^\r\n]+\}\s+if \(\(\$root \+ ''\\''\)\.StartsWith\(\$build\.Bin\.TrimEnd\(''\\''\) \+ ''\\'', \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw [^\r\n]+\}\s+Assert-WorkingSetRunPlacement \$root \$build\.Repo'
        Mutation = @('Assert-WorkingSetRunPlacement $root $build.Repo', '')
    }
    @{
        Description = 'the series stops at the first run that did not complete'
        Pattern = 'if \(-not \[string\]::Equals\(\$result\.Status, ''complete'', \[StringComparison\]::Ordinal\)\) \{ break \}'
        Mutation = @("'complete', [StringComparison]::Ordinal)) { break }", "'complete', [StringComparison]::Ordinal)) { }")
    }
    @{
        Description = 'frame_time_p95_ms and its median are published only for a visible series whose every run completed and whose runs are comparable'
        Pattern = '(?s)\$publish = \$Visible -and \$completed\.Count -eq \$Runs -and \$series\.Pooled\.Count -gt 0 -and @\(\$series\.MixedEnvironment\)\.Count -eq 0 -and @\(\$series\.MixedBuild\)\.Count -eq 0.*?frame_time_p95_ms = \$\(if \(\$publish\) \{ \$series\.P95 \} else \{ \$null \}\)\s+frame_time_median_ms = \$\(if \(\$publish\) \{ \$series\.Median \} else \{ \$null \}\)'
        Mutation = @('$publish = $Visible -and $completed.Count -eq $Runs', '$publish = $completed.Count -eq $Runs')
    }
    @{
        Description = 'the pooled samples come only from completed runs'
        Pattern = '\$series = Get-FramePacingSeries @\(\$completed \| ForEach-Object \{ \$_\.Record \}\)'
        Mutation = @('$series = Get-FramePacingSeries @($completed | ForEach-Object', '$series = Get-FramePacingSeries @($Results | ForEach-Object')
    }
    @{
        Description = 'runs that differ in environment (display mode, DPI, grid) are never pooled: each mode is reported alone and the series is inconclusive, exit 2'
        Pattern = '(?s)\[double\[\]\]\$pooled = @\(if \(\$mixedEnvironment\.Count -eq 0 -and \$mixedBuild\.Count -eq 0\) \{ .*?if \(@\(\$series\.MixedEnvironment\)\.Count -gt 0\) \{ \$summary\.Inconclusive = .*?if \(\$summary\.Contains\(''Inconclusive''\)\) \{ return 2 \}'
        Mutation = @("if (`$summary.Contains('Inconclusive')) { return 2 }", '')
    }
    @{
        Description = 'the exit code says why the series stopped: 3 a tripped guard, 2 an inconclusive visible run, 1 any other failure'
        Pattern = 'switch \(\$last\.Status\) \{ ''guard-tripped'' \{ return 3 \} ''inconclusive'' \{ return 2 \} default \{ return 1 \} \}'
        Mutation = @("'guard-tripped' { return 3 }", "'guard-tripped' { return 1 }")
    }
    @{
        Description = 'completed runs that differ in build or workload (WorkloadSha256, the app, renderer, transport, ConPTY digests) fail the summary'
        Pattern = 'if \(@\(\$series\.MixedBuild\)\.Count -gt 0\) \{ \$summary\.Error = '
        Mutation = @('if (@($series.MixedBuild).Count -gt 0) { $summary.Error =', 'if ($false) { $summary.Error =')
    }
)

# The harness's floor is PowerShell 7.2, as #739's (utf8NoBOM, the generic Marshal members); `#requires` is a comment
# token, so this reads the first line.
$framePacingFirstLine = Get-Content -LiteralPath $framePacingScript -TotalCount 1
if (-not (Test-FramePacingOrdinal $framePacingFirstLine '#requires -Version 7.2')) { throw "The frame-pacing harness must require PowerShell 7.2, not '$framePacingFirstLine'." }
$framePacingMutations = 0
foreach ($rule in $framePacingRules) {
    Assert-TextContract -Content $framePacingText -Pattern $rule.Pattern -Description $rule.Description -Context $framePacingScript
    $mutated = $framePacingText.Replace($rule.Mutation[0], $rule.Mutation[1])
    if ([string]::Equals($mutated, $framePacingText, [StringComparison]::Ordinal)) { throw "Frame-pacing contract mutation changed nothing: $($rule.Description)" }
    if ($mutated -match $rule.Pattern) { throw "Frame-pacing contract accepted a mutation: $($rule.Description)" }
    $framePacingMutations++
}

# The foreground is taken in one place only, and the native layer sends one input, the zero-motion unlock: no
# keyboard SendInput, no Alt (VK_MENU) and nothing typed through SendInput anywhere in the harness. Controls: a second
# call, and a keyboard input added to the source, are both caught.
function Test-FramePacingInputDiscipline([string] $Text) {
    $foregroundCalls = [regex]::Matches($Text, '\[FramePacingNative\]::Foreground\(').Count
    $sendInputs = [regex]::Matches($Text, '\bSendInput\(').Count
    return $foregroundCalls -eq 1 -and $sendInputs -eq 2 -and -not $Text.Contains('KEYEVENTF') -and -not $Text.Contains('VK_MENU') -and -not $Text.Contains('SendUnicodeText') -and -not $Text.Contains('SendKeys')
}
if (-not (Test-FramePacingInputDiscipline $framePacingText)) { throw 'The harness must take the foreground in one place and send no input but the one zero-motion unlock.' }
if (Test-FramePacingInputDiscipline ($framePacingText + "`n[FramePacingNative]::Foreground(`$h, 1, 1)")) { throw 'The input discipline check accepted a second foreground call.' }
if (Test-FramePacingInputDiscipline ($framePacingText.Replace('if (SendInput(1, UnlockInput(),', 'SendInput(1, keys, 40); if (SendInput(1, UnlockInput(),'))) { throw 'The input discipline check accepted a second SendInput.' }
# No other input API at all (Opus on #741: a declared keybd_event with a numeric VK passed the old check): neither
# keybd_event nor mouse_event, no cursor placement, no BlockInput, no key code for Alt. Each appended to the source
# is caught.
$framePacingInputApis = @('keybd_event', 'mouse_event', 'SetCursorPos', 'SetPhysicalCursorPos', 'BlockInput', 'KEYEVENTF', 'VK_MENU', 'SendKeys', 'SendUnicodeText')
function Get-FramePacingInputApis([string] $Text) { return @($framePacingInputApis | Where-Object { $Text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
if (@(Get-FramePacingInputApis $framePacingText).Count -ne 0) { throw "The frame-pacing harness names another input API: $(@(Get-FramePacingInputApis $framePacingText) -join ', ')." }
foreach ($api in $framePacingInputApis) { if (@(Get-FramePacingInputApis ($framePacingText + "`n[DllImport(`"user32.dll`")] static extern void $api();")).Count -ne 1) { throw "The input-API check missed $api." } }

# What the harness may not do (#739's list and the bench's fixture paths): start a process through Start-Process or
# Process.Start, touch the clipboard, stop a process by name, build, or start a PowerShell fixture in the copy. The
# control: each forbidden form appended to the text is caught.
$framePacingForbidden = @('Start-Process', 'Diagnostics.Process]::Start', '[Diagnostics.Process]::new', 'Set-Clipboard', 'Get-Clipboard', 'Clipboard]::', 'Stop-Process', 'Get-Process -Name', 'Invoke-InteractiveWin11Build', 'ExecutionPolicy', "'-e'," , 'powershell.exe -')
function Get-FramePacingForbidden([string] $Text) { return @($framePacingForbidden | Where-Object { $Text.Contains($_) }) }
$framePacingFound = @(Get-FramePacingForbidden $framePacingText)
if ($framePacingFound.Count -ne 0) { throw "The frame-pacing harness uses a forbidden form: $($framePacingFound -join ', ')." }
foreach ($form in $framePacingForbidden) {
    if (@(Get-FramePacingForbidden ($framePacingText + "`n$form")).Count -ne 1) { throw "The forbidden-form check missed '$form'." }
}

# The shared pieces are the hardened ones, byte for byte: #739's functions (hidden-win11-working-set.ps1) and
# bench-windows.ps1's statistics and payload generator. A change to either copy alone fails here. Controls: one changed
# character in a copy is a difference.
$framePacingAst = [Management.Automation.Language.Parser]::ParseFile($framePacingScript, [ref]$null, [ref]$null)
$framePacingWorkingSetAst = [Management.Automation.Language.Parser]::ParseFile($framePacingWorkingSetScript, [ref]$null, [ref]$null)
$framePacingBenchAst = [Management.Automation.Language.Parser]::ParseFile($framePacingBenchScript, [ref]$null, [ref]$null)
function Get-FramePacingFunctionText($Ast, [string] $Name, [string] $Source) {
    $found = @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { throw "$Source must define $Name once (found $($found.Count))." }
    return $found[0].Extent.Text
}
$framePacingShared = @(
    @{ Ast = $framePacingWorkingSetAst; Source = 'hidden-win11-working-set.ps1'; Names = @('Add-Line', 'Get-Metadata', 'Get-Sha256', 'Read-WorkingSetPlainFile', 'Get-BytesSha256', 'Get-WorkingSetMeasureBuild', 'Test-WorkingSetCopy', 'Assert-WorkingSetRunPlacement', 'Get-WorkingSetStrayConfigs', 'Test-WorkingSetArgv', 'Read-SharedText') }
    @{ Ast = $framePacingBenchAst; Source = 'bench-windows.ps1'; Names = @('Get-BenchMedian', 'Get-BenchPercentile') }
)
$framePacingSharedCount = 0
foreach ($group in $framePacingShared) {
    foreach ($name in $group.Names) {
        $theirs = Get-FramePacingFunctionText $group.Ast $name $group.Source
        $ours = Get-FramePacingFunctionText $framePacingAst $name 'bench-frame-pacing.ps1'
        if (-not (Test-FramePacingOrdinal $ours $theirs)) { throw "bench-frame-pacing.ps1's $name is not $($group.Source)'s, byte for byte." }
        if (Test-FramePacingOrdinal ($ours.Substring(0, $ours.Length - 1) + ' }') $theirs) { throw "The identity check accepted a changed $name." }
        $framePacingSharedCount++
    }
}
# A C# member's text from its signature through its closing brace (braces balanced, as these members' are).
function Get-FramePacingCsMember([string] $Text, [string] $Signature, [string] $Source) {
    $start = $Text.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "$Source has no '$Signature'." }
    if ($Text.IndexOf($Signature, $start + 1, [StringComparison]::Ordinal) -ge 0) { throw "$Source has '$Signature' twice." }
    $depth = 0
    for ($i = $Text.IndexOf('{', $start); $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '{') { $depth++ }
        elseif ($Text[$i] -eq '}') { $depth--; if ($depth -eq 0) { return $Text.Substring($start, $i - $start + 1) } }
    }
    throw "$Source's '$Signature' is unbalanced."
}
$framePacingBenchRaw = Get-Content -LiteralPath $framePacingBenchScript -Raw
$framePacingRaw = Get-Content -LiteralPath $framePacingScript -Raw
$framePacingWorkingSetRaw = Get-Content -LiteralPath $framePacingWorkingSetScript -Raw
foreach ($signature in @('private static uint Next(ref uint state)', 'public static void WritePayload(string path, long length, uint seed, string workload, int rows, int cols)')) {
    $theirs = Get-FramePacingCsMember $framePacingBenchRaw $signature 'bench-windows.ps1'
    $ours = Get-FramePacingCsMember $framePacingRaw $signature 'bench-frame-pacing.ps1'
    if (-not (Test-FramePacingOrdinal $ours $theirs)) { throw "bench-frame-pacing.ps1's payload generator ($signature) is not bench-windows.ps1's, byte for byte." }
    if ($ours.Contains('33 + random % 94') -and (Test-FramePacingOrdinal ($ours.Replace('33 + random % 94', '32 + random % 95')) $theirs)) { throw 'The generator identity check accepted a changed generator.' }
    $framePacingSharedCount++
}
# The native members #739 hardened (the job, the desktop names, the argv split, the posted key, the process walk,
# the grid probe, the window queries), compared member by member with WorkingSetNative's.
$framePacingNativeShared = @('static string NameOf(IntPtr desktop)', 'public static string CurrentDesktopName()', 'public static string[] SplitCommandLine(string commandLine)',
    'public static string InputDesktopName()', 'public static IntPtr CreateRunJob()', 'public static bool InJob()', 'public static bool Alive(IntPtr process)',
    'public static long ExitCode(IntPtr process)', 'public static IntPtr[] Hosts(int pid)', 'public static IntPtr[] Surfaces(IntPtr host, bool visibleOnly)',
    'public static int Owner(IntPtr h)', 'public static long[] ClientAndDpi(IntPtr h)', 'public static bool Responsive(IntPtr h, uint ms)',
    'public static bool PostClose(IntPtr h, int pid)', 'public static void Key(IntPtr h, int pid, int vk)', 'public static int[] Children(int parent, string exe)',
    'public static string ConsoleGrid(uint pid)')
foreach ($signature in $framePacingNativeShared) {
    $theirs = Get-FramePacingCsMember $framePacingWorkingSetRaw $signature 'hidden-win11-working-set.ps1'
    $ours = Get-FramePacingCsMember $framePacingRaw $signature 'bench-frame-pacing.ps1'
    if (-not (Test-FramePacingOrdinal $ours $theirs)) { throw "FramePacingNative's '$signature' is not WorkingSetNative's, byte for byte." }
    $framePacingSharedCount++
}

# The trace protocol against the Zig source: the two control messages (win32/consts.zig) and the interval capacity
# (render_trace.zig), which an overflow check is only right against.
$framePacingConsts = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32\consts.zig') -Raw
$framePacingTraceZig = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32\render_trace.zig') -Raw
if ($framePacingConsts -notmatch 'pub const WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT = WM_APP \+ 8;' -or $framePacingConsts -notmatch 'pub const WM_WINHOSTTY_RENDER_TRACE_TARGET = WM_APP \+ 9;' -or $framePacingConsts -notmatch '(?m)^const WM_APP = 0x8000;') {
    throw 'win32/consts.zig no longer gives the render trace''s messages as WM_APP (0x8000) + 8 and + 9.'
}
if ($framePacingText -notmatch '\$script:WmRenderTraceSnapshot = \[uint32\]\(0x8000 \+ 8\)' -or $framePacingText -notmatch '\$script:WmRenderTraceTarget = \[uint32\]\(0x8000 \+ 9\)') { throw 'The harness''s render-trace message IDs are not WM_APP + 8 and + 9.' }
$framePacingCapacity = [regex]::Match($framePacingTraceZig, 'const target_swap_interval_capacity: usize = (\d+);').Groups[1].Value
if (-not $framePacingCapacity -or $framePacingText -notmatch "(?m)^\`$script:IntervalCapacity = $framePacingCapacity\s*$") { throw "The harness's interval capacity is not render_trace.zig's ($framePacingCapacity)." }
if ($framePacingTraceZig -notmatch '"NOCTTY_RENDER_TRACE_FILE"' -or $framePacingTraceZig -notmatch '"NOCTTY_RENDER_TRACE_LIVE"') { throw 'render_trace.zig no longer reads NOCTTY_RENDER_TRACE_FILE and NOCTTY_RENDER_TRACE_LIVE.' }
if ((Get-Content -LiteralPath (Join-Path $repoRoot 'src\termio\bench_marker.zig') -Raw) -notmatch '"NOCTTY_BENCH_END_MARKER"') { throw 'bench_marker.zig no longer reads NOCTTY_BENCH_END_MARKER.' }

# bench-windows.ps1's delegation: -Metric frame-pacing runs bench-frame-pacing.ps1 before anything of the bench
# starts (its history guard, bootstrap, build and fixtures), forwards only -Runs, -MeasureRepo, -RunRoot and -Visible,
# refuses any other parameter and another target, and exits with the harness's code; the frame-pacing parameters are
# refused for every other metric.
$framePacingBenchRules = @(
    @{
        Description = 'bench-windows.ps1 -Metric frame-pacing delegates before its history guard and bootstrap, refuses other targets and parameters, and exits with the harness''s code, never an earlier one'
        Pattern = '(?s)\[switch\] \$Visible\s+\)\s+if \(\$Metric -eq ''frame-pacing''\) \{\s+if \(\$Target -ne ''noctty''\) \{ throw [^\r\n]+\}\s+\$pacingParameters = @\(''Metric'', ''Target'', ''Runs'', ''MeasureRepo'', ''RunRoot'', ''Visible''\)\s+\$foreignParameters = @\(\$PSBoundParameters\.Keys \| Where-Object \{ \$pacingParameters -notcontains \$_ \}\)\s+if \(\$foreignParameters\.Count -ne 0\) \{ throw [^\r\n]+\}\s+if \(\$Runs -gt 50\) \{ throw [^\r\n]+\}\s+\$pacingArguments = @\{ MeasureRepo = \$MeasureRepo; RunRoot = \$RunRoot; Runs = \$Runs; Visible = \$Visible \}\s+\$global:LASTEXITCODE = -1\s+try \{ & \(Join-Path \$PSScriptRoot ''bench-frame-pacing\.ps1''\) @pacingArguments -ErrorAction Stop \}\s+catch \{ [^\r\n]+exit 1 \}\s+if \(\$LASTEXITCODE -lt 0\) \{ exit 1 \}\s+exit \$LASTEXITCODE\s+\}.*?Start-WindowsHarnessHistoryGuard -Harness ''bench-windows\.ps1''.*?Invoke-InteractiveWin11Bootstrap'
        Mutation = @('if ($foreignParameters.Count -ne 0) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'bench-windows.ps1 -Metric frame-pacing refuses more than the harness''s 50 runs itself (CodeRabbit on #741)'
        Pattern = 'if \(\$Runs -gt 50\) \{ throw ''-Metric frame-pacing takes -Runs 1 to 50\.'' \}'
        Mutation = @('if ($Runs -gt 50) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a harness that never ran exits 1 through bench-windows.ps1, never with an earlier command''s code (CodeRabbit on #741)'
        Pattern = '\$global:LASTEXITCODE = -1\s+try \{ & \(Join-Path \$PSScriptRoot ''bench-frame-pacing\.ps1''\) @pacingArguments -ErrorAction Stop \}\s+catch \{ [^\r\n]+exit 1 \}\s+if \(\$LASTEXITCODE -lt 0\) \{ exit 1 \}'
        Mutation = @('if ($LASTEXITCODE -lt 0) { exit 1 }', '')
    }
    @{
        Description = 'bench-windows.ps1 refuses the frame-pacing parameters for every other metric'
        Pattern = 'if \(-not \[string\]::IsNullOrEmpty\(\$MeasureRepo\) -or -not \[string\]::IsNullOrEmpty\(\$RunRoot\) -or \$Visible\) \{\s+throw '
        Mutation = @(' -or $Visible) {', ') {')
    }
    @{
        Description = 'frame-pacing is a -Metric value of its own, not part of -Metric all'
        Pattern = "\[ValidateSet\('all', 'throughput', 'cold-start', 'memory', 'idle', 'conpty-rtt', 'key-to-pixel-proxy', 'frame-pacing'\)\]"
        Mutation = @(", 'frame-pacing')]", ')]')
    }
)
foreach ($rule in $framePacingBenchRules) {
    Assert-TextContract -Content $framePacingBenchText -Pattern $rule.Pattern -Description $rule.Description -Context $framePacingBenchScript
    $mutated = $framePacingBenchText.Replace($rule.Mutation[0], $rule.Mutation[1])
    if ([string]::Equals($mutated, $framePacingBenchText, [StringComparison]::Ordinal)) { throw "Frame-pacing contract mutation changed nothing: $($rule.Description)" }
    if ($mutated -match $rule.Pattern) { throw "Frame-pacing contract accepted a mutation: $($rule.Description)" }
    $framePacingMutations++
}
# Test-BenchMetricRequested's 'all' must not reach frame-pacing: the delegation exits first, and nothing else names it.
if ([regex]::Matches($framePacingBenchText, "'frame-pacing'").Count -ne 2) { throw 'bench-windows.ps1 must name frame-pacing only in its ValidateSet and its delegation.' }

# The pure functions, run in a child scope with the harness's constants (evaluated from its `$script:` assignment
# lines; the runner's script scope is restored afterwards, values and existence both).
# The visible run's gates are constants among them (Opus on #741): 300 s with no input, a 5 s foreground bound, a 5 s
# response bound, notifications accepted (5) and the display on (1), and the 1 s drain before the window's one
# snapshot. Opus's mutations are the controls: the idle time cut to 60 s and the bound raised to ten minutes are
# caught, and no parameter may lower the idle time.
$framePacingConstantNames = @('Cols', 'Rows', 'GridRows', 'FontFamily', 'FontSize', 'PayloadWorkload', 'PayloadBytes', 'PayloadSeed', 'IntervalCapacity', 'QuietMs', 'EchoQuietMs', 'QuietBusyPercent', 'MinIdleSeconds', 'ForegroundBoundMs', 'ResponseBoundMs', 'NotificationsAccepted', 'DisplayOn', 'DrainMs')
function Get-FramePacingConstantLines([string] $Text) {
    foreach ($name in $framePacingConstantNames) {
        $found = @([regex]::Matches($Text, "(?m)^\`$script:$name = (\d+|'[A-Za-z]+')[ \t]*$"))
        if ($found.Count -ne 1) { throw "The frame-pacing harness must assign `$script:$name a constant exactly once." }
        $found[0].Value.Trim()
    }
}
function Get-FramePacingConstantValues([string] $Text) {
    return (@(Get-FramePacingConstantLines $Text) | ForEach-Object { $_ -replace '^\$script:(\w+) = ''?([^'']*)''?$', '$1=$2' }) -join ' '
}
$framePacingConstantLines = @(Get-FramePacingConstantLines $framePacingText)
$framePacingPinned = 'Cols=140 Rows=45 GridRows=43 FontFamily=Consolas FontSize=16 PayloadWorkload=stream PayloadBytes=4194304 PayloadSeed=121 IntervalCapacity=2048 QuietMs=1000 EchoQuietMs=500 QuietBusyPercent=30 MinIdleSeconds=300 ForegroundBoundMs=5000 ResponseBoundMs=5000 NotificationsAccepted=5 DisplayOn=1 DrainMs=1000'
if (-not (Test-FramePacingOrdinal (Get-FramePacingConstantValues $framePacingText) $framePacingPinned)) { throw "The frame-pacing constants changed: $(Get-FramePacingConstantValues $framePacingText)" }
foreach ($control in @(@('$script:MinIdleSeconds = 300', '$script:MinIdleSeconds = 60'), @('$script:ForegroundBoundMs = 5000', '$script:ForegroundBoundMs = 600000'), @('$script:QuietBusyPercent = 30', '$script:QuietBusyPercent = 100'))) {
    $mutated = $framePacingText.Replace($control[0], $control[1])
    if ([string]::Equals($mutated, $framePacingText, [StringComparison]::Ordinal)) { throw "The constants control changed nothing: $($control[1])." }
    if (Test-FramePacingOrdinal (Get-FramePacingConstantValues $mutated) $framePacingPinned) { throw "The constants check accepted $($control[1])." }
}
if ($framePacingText -match '(?i)\[int\]\s*\$MinIdleSeconds') { throw 'The idle time must be the pinned constant, never a parameter.' }
if (($framePacingText.Replace('[ValidateRange(0, 3600)] [int] $QuietWaitSeconds = 900,', "[ValidateRange(0, 3600)] [int] `$QuietWaitSeconds = 900,`n    [ValidateRange(0, 3600)] [int] `$MinIdleSeconds = 0,")) -notmatch '(?i)\[int\]\s*\$MinIdleSeconds') { throw 'The idle-parameter control changed nothing.' }
$framePacingSaved = @{}
foreach ($name in $framePacingConstantNames + @('Utf8')) {
    $existing = Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
    $framePacingSaved[$name] = [pscustomobject]@{ Existed = $null -ne $existing; Value = $(if ($null -ne $existing) { $existing.Value } else { $null }) }
}
try {
    . ([scriptblock]::Create(($framePacingConstantLines -join "`n")))
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    $framePacingActual = ($framePacingConstantNames | ForEach-Object { "$_=$((Get-Variable -Scope Script -Name $_).Value)" }) -join ' '
    if (-not (Test-FramePacingOrdinal $framePacingActual $framePacingPinned)) { throw "The frame-pacing workload's constants changed ($framePacingActual); runs before and after the change are not comparable." }
    $framePacingCases = & {
        foreach ($name in @('New-FramePacingConfigText', 'Test-FramePacingConfigBytes', 'Get-FramePacingExpectedArgv', 'Test-WorkingSetArgv', 'Get-FramePacingVisibleRefusal', 'Get-FramePacingRecordProblems', 'Get-FramePacingRunStatus', 'Test-FramePacingInputGate', 'Assert-FramePacingInputGate', 'Invoke-FramePacingForeground', 'Get-FramePacingSeries', 'Write-FramePacingSummary', 'Get-FramePacingIntervalStats', 'Get-BenchMedian', 'Get-BenchPercentile', 'Get-FramePacingMarkerTail', 'Get-FramePacingWorkloadSha256', 'Get-BytesSha256')) {
            . ([scriptblock]::Create((Get-FramePacingFunctionText $framePacingAst $name 'bench-frame-pacing.ps1')))
        }
        $cases = [Collections.Generic.List[string]]::new()

        # The config: exactly the harness's lines. One command, System32's cmd.exe with /D; no initial-command; the
        # clipboard denied and copy-on-select off; OpenGL; every default binding cleared first; only F5 and F6, each
        # a text action; no PowerShell anywhere. The controls are configs a careless edit would produce.
        $cmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        function Test-FramePacingConfigShape([string] $Text, [string] $Run) {
            $lines = @($Text -split "`n" | Where-Object { $_ -ne '' })
            $commands = @($lines | Where-Object { $_ -match '^\s*command\s*=' })
            if ($commands.Count -ne 1 -or -not (Test-FramePacingOrdinal $commands[0] "command = direct:$cmd /D")) { return $false }
            if (@($lines | Where-Object { $_ -match '^\s*initial-command\s*=' }).Count -ne 0) { return $false }
            foreach ($want in @('auto-update = off', 'clipboard-read = deny', 'clipboard-write = deny', 'copy-on-select = false', 'renderer = opengl', 'cursor-style-blink = false', "working-directory = $(Join-Path $Run 'work')")) {
                if (@($lines | Where-Object { Test-FramePacingOrdinal $_ $want }).Count -ne 1) { return $false }
            }
            if (@($lines | Where-Object { $_ -match '(?i)powershell|pwsh' }).Count -ne 0) { return $false }
            # Every default binding cleared first, then exactly F5's and F6's text under each of the eight modifier
            # chords, in order, each once (CodeRabbit on #741: a swap or a repeat must fail).
            $keybinds = @($lines | Where-Object { $_ -match '^\s*keybind\s*=' })
            $chords = @('', 'shift+', 'ctrl+', 'alt+', 'ctrl+shift+', 'alt+shift+', 'ctrl+alt+', 'ctrl+alt+shift+')
            $want = @('keybind = clear') + @(foreach ($pair in @(@('f5', 'text:type stream.bin & echo.>done.flag'), @('f6', 'text:\r'))) { foreach ($chord in $chords) { "keybind = $chord$($pair[0])=$($pair[1])" } })
            return Test-FramePacingOrdinal ($keybinds -join "`n") ($want -join "`n")
        }
        $run = 'C:\fp contract\run-1'
        $config = New-FramePacingConfigText $run
        if (-not (Test-FramePacingConfigShape $config $run)) { throw "The generated config is not the harness's shape:`n$config" }
        $controls = @(
            @{ Name = 'an initial-command line'; Text = $config + "initial-command = direct:$cmd /D /K echo`n" }
            @{ Name = 'cmd without /D'; Text = $config.Replace("command = direct:$cmd /D", "command = direct:$cmd") }
            @{ Name = 'a PowerShell shell'; Text = $config.Replace("command = direct:$cmd /D", 'command = pwsh.exe -NoProfile') }
            @{ Name = 'the clipboard allowed'; Text = $config.Replace('clipboard-read = deny', 'clipboard-read = allow') }
            @{ Name = 'a copy binding'; Text = $config + "keybind = f7=copy_to_clipboard`n" }
            @{ Name = 'Direct3D 11'; Text = $config.Replace('renderer = opengl', 'renderer = d3d11') }
            @{ Name = 'a binding before the clear'; Text = $config.Replace('keybind = clear', "keybind = f8=new_tab`nkeybind = clear") }
            @{ Name = 'F5''s and F6''s actions swapped'; Text = $config.Replace('f5=text:type stream.bin & echo.>done.flag', 'f5=TMP').Replace('f6=text:\r', 'f6=text:type stream.bin & echo.>done.flag').Replace('f5=TMP', 'f5=text:\r') }
            @{ Name = 'a repeated binding in place of a chord'; Text = $config.Replace('keybind = alt+f6=text:\r', 'keybind = f6=text:\r') }
            @{ Name = 'no producer end file'; Text = $config.Replace(' & echo.>done.flag', '') }
        )
        foreach ($control in $controls) {
            if ([string]::Equals($control.Text, $config, [StringComparison]::Ordinal)) { throw "The config control changed nothing: $($control.Name)." }
            if (Test-FramePacingConfigShape $control.Text $run) { throw "The config check accepted $($control.Name)." }
        }
        $staged = Join-Path ([IO.Path]::GetTempPath()) ('fp-config-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ghostty')
        try {
            [IO.File]::WriteAllText($staged, $config, $script:Utf8)
            if (-not (Test-FramePacingConfigBytes $staged $run)) { throw 'The config bytes check refused the harness''s own config.' }
            if (Test-FramePacingConfigBytes $staged 'C:\fp contract\run-2') { throw 'The config bytes check accepted another run''s config.' }
            [IO.File]::WriteAllText($staged, $config.Replace('clipboard-write = deny', "clipboard-write = deny`ncopy-on-select = true"), $script:Utf8)
            if (Test-FramePacingConfigBytes $staged $run) { throw 'The config bytes check accepted an added line.' }
        } finally { Remove-Item -LiteralPath $staged -ErrorAction SilentlyContinue }
        $cases.Add('config (shape: initial-command, no /D, PowerShell, clipboard allowed, copy binding, D3D11, binding before clear, F5/F6 swapped, a repeated binding, no done.flag; bytes: exact, other run, added line)')

        # The argv: the pinned list, exactly; an added shell, an -e command, a reordered pair and a missing config
        # file are refused.
        $argv = @(Get-FramePacingExpectedArgv 'C:\c\noctty.exe' 'noctty-interactive-x' 'C:\c\config.ghostty')
        $pinned = @('C:\c\noctty.exe', '--linux-cgroup=always', '--linux-cgroup-hard-fail=true', '--windows-job-object-kill-on-close=true', '--single-instance=false', '--class=noctty-interactive-x', '--window-save-state=never', '--clipboard-read=deny', '--clipboard-write=deny', '--config-default-files=false', '--config-file=C:\c\config.ghostty')
        if (-not (Test-FramePacingOrdinal ($argv -join "`n") ($pinned -join "`n"))) { throw "The expected argv changed: $($argv -join ' ')" }
        if (-not (Test-WorkingSetArgv $pinned $argv)) { throw 'The argv check refused the expected list.' }
        foreach ($bad in @(@($pinned + '--command=cmd.exe'), @($pinned + @('-e', 'cmd.exe')), @($pinned[0..5] + $pinned[7] + $pinned[6] + $pinned[8..10]), @($pinned[0..9]))) {
            if (Test-WorkingSetArgv $bad $argv) { throw "The argv check accepted $($bad -join ' ')." }
        }
        $cases.Add('argv (pinned, exact; added --command, -e, reordered, no config file)')

        # The visible part's refusal: only Default, the input desktop, composed, local and idle passes.
        $ok = [pscustomobject]@{ OwnDesktop = 'Default'; InputDesktop = 'Default'; Composition = 1; RemoteSession = $false; NotificationState = 5; DisplayPower = 1; IdleMs = 400000; MinIdleMs = 300000; LastInputTick = 77; QuietSinceTick = -1 }
        if ($null -ne (Get-FramePacingVisibleRefusal $ok)) { throw 'The visible check refused an idle, unlocked, composed local Default.' }
        $refusals = @(
            @{ Name = 'a private desktop'; Facts = @{ OwnDesktop = 'noctty-fp-1' } }
            @{ Name = 'a locked session'; Facts = @{ InputDesktop = $null } }
            @{ Name = 'another input desktop'; Facts = @{ InputDesktop = 'Winlogon' } }
            @{ Name = 'no composition'; Facts = @{ Composition = 0 } }
            @{ Name = 'an unreadable composition'; Facts = @{ Composition = -1 } }
            @{ Name = 'a remote session'; Facts = @{ RemoteSession = $true } }
            @{ Name = 'a full-screen app'; Facts = @{ NotificationState = 2 } }
            @{ Name = 'presentation mode'; Facts = @{ NotificationState = 4 } }
            @{ Name = 'an unreadable notification state'; Facts = @{ NotificationState = -1 } }
            @{ Name = 'the display off'; Facts = @{ DisplayPower = 0 } }
            @{ Name = 'the display dimmed'; Facts = @{ DisplayPower = 2 } }
            @{ Name = 'an unreadable display state'; Facts = @{ DisplayPower = -1 } }
            @{ Name = 'recent input'; Facts = @{ IdleMs = 299999 } }
            @{ Name = 'an unreadable idle time'; Facts = @{ IdleMs = -1 } }
            @{ Name = 'input since the series'' tick'; Facts = @{ QuietSinceTick = 76; IdleMs = 400000 } }
        )
        foreach ($case in $refusals) {
            $facts = $ok.PSObject.Copy()
            foreach ($key in $case.Facts.Keys) { $facts.$key = $case.Facts[$key] }
            if ($null -eq (Get-FramePacingVisibleRefusal $facts)) { throw "The visible check accepted $($case.Name)." }
        }
        # A later run of a visible series: the harness's own unlock made the idle time short, and the tick it saw then
        # is still the session's last input, so the run may go on.
        $later = $ok.PSObject.Copy(); $later.IdleMs = 2000; $later.QuietSinceTick = 77
        if ($null -ne (Get-FramePacingVisibleRefusal $later)) { throw 'The visible check refused a later run whose only input since the series'' tick was its own unlock.' }
        $refusalText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingVisibleRefusal' 'bench-frame-pacing.ps1'
        $tickControl = $refusalText.Replace('if ($Facts.LastInputTick -ne $Facts.QuietSinceTick)', 'if ($false)')
        if ([string]::Equals($tickControl, $refusalText, [StringComparison]::Ordinal)) { throw 'The tick control changed nothing.' }
        & { . ([scriptblock]::Create($tickControl)); $moved = $ok.PSObject.Copy(); $moved.QuietSinceTick = 76; if ($null -ne (Get-FramePacingVisibleRefusal $moved)) { throw 'The tick control did not accept input since the series'' tick.' } }
        $refusalControl = $refusalText.Replace('if ($Facts.IdleMs -lt 0 -or $Facts.IdleMs -lt $Facts.MinIdleMs)', 'if ($false)')
        if ([string]::Equals($refusalControl, $refusalText, [StringComparison]::Ordinal)) { throw 'The visible-check control changed nothing.' }
        & { . ([scriptblock]::Create($refusalControl)); $recent = $ok.PSObject.Copy(); $recent.IdleMs = 1000; if ($null -ne (Get-FramePacingVisibleRefusal $recent)) { throw 'The visible-check control did not accept recent input.' } }
        $cases.Add('visible-refusal (idle Default; private, locked, other input desktop, no or unreadable composition, remote, a full-screen app, presentation mode, the display off or dimmed, recent or unreadable input, input since the series'' tick; a later run after its own unlock; idle and tick controls)')

        # The record verdict: a complete dry run and a complete visible run count; each broken field is a problem;
        # the visible run's environment problems are only "inconclusive:".
        $intervals = [double[]]@(4.1, 4.2, 4.3)
        $base = @{ Schema = 1; Mode = 'dry-run'; Error = $null; Exit = 0; QuitPosts = 1; GridCols = 140; GridRows = 43; Transport = 'bundled'; Renderer = 'opengl'
            LaunchConfigDefaultFiles = $false; LaunchConfigFile = 'C:\c\config.ghostty'; ConptyDllSHA256 = 'aa'; PrefixConptyDllSHA256 = 'aa'; OpenConsoleSHA256 = 'bb'; PrefixOpenConsoleSHA256 = 'bb'
            PowerShellUnderCopy = 0; EndMarkerPresented = $true; IntervalOverflow = 0; IntervalCount = 3; IntervalsMs = $intervals
            VisibleRefusal = 'this process is not on Default'; Foreground = 'skipped'; Cloaked = $null; ForegroundHeld = $false; FocusHeld = $true; InputDuringRun = $null; BusyPercentBefore = 50.0; RefreshHz = 240
            DisplayMode = '3840x2160@240'; DisplayModeAfter = '3840x2160@240'; SnapshotsInWindow = 0; BusyPercentAtArm = 50.0; DisplayPowerBefore = 1; DisplayPowerAfter = 1 }
        function Join-FramePacingChange([hashtable] $A, [hashtable] $B) { $r = $A.Clone(); foreach ($k in $B.Keys) { $r[$k] = $B[$k] }; return $r }
        function New-FramePacingRecord([hashtable] $Change) { return [pscustomobject](Join-FramePacingChange $base $Change) }
        $visibleOk = @{ Mode = 'visible'; VisibleRefusal = $null; Foreground = 'ok'; Cloaked = 0; ForegroundHeld = $true; FocusHeld = $true; InputDuringRun = $false; BusyPercentBefore = 10.0; BusyPercentAtArm = 12.0 }
        if (@(Get-FramePacingRecordProblems (New-FramePacingRecord @{})).Count -ne 0) { throw "A complete dry run has problems: $(@(Get-FramePacingRecordProblems (New-FramePacingRecord @{})) -join '; ')" }
        if (@(Get-FramePacingRecordProblems (New-FramePacingRecord $visibleOk)).Count -ne 0) { throw "A complete visible run has problems: $(@(Get-FramePacingRecordProblems (New-FramePacingRecord $visibleOk)) -join '; ')" }
        $hardCases = @(
            @{ Name = 'an overflow'; Change = @{ IntervalOverflow = 1 } }
            @{ Name = 'one interval'; Change = @{ IntervalCount = 1; IntervalsMs = [double[]]@(4.1) } }
            @{ Name = 'a count that is not the list'; Change = @{ IntervalCount = 4 } }
            @{ Name = 'a zero interval'; Change = @{ IntervalsMs = [double[]]@(4.1, 0, 4.3) } }
            @{ Name = 'the in-box conhost'; Change = @{ Transport = 'inbox' } }
            @{ Name = 'a renderer fallback'; Change = @{ Renderer = 'fallback' } }
            @{ Name = 'PowerShell under the copy'; Change = @{ PowerShellUnderCopy = 1 } }
            @{ Name = 'no end marker'; Change = @{ EndMarkerPresented = $false } }
            @{ Name = 'another grid'; Change = @{ GridRows = 45 } }
            @{ Name = 'another ConPTY host'; Change = @{ OpenConsoleSHA256 = 'cc' } }
            @{ Name = 'default config files'; Change = @{ LaunchConfigDefaultFiles = $true } }
            @{ Name = 'a dry run that passed the visible checks'; Change = @{ VisibleRefusal = $null } }
            @{ Name = 'a dry run that took the foreground'; Change = @{ Foreground = 'ok' } }
            @{ Name = 'an unknown mode'; Change = @{ Mode = 'Visible' } }
            @{ Name = 'a visible run with no refresh rate'; Change = (Join-FramePacingChange $visibleOk @{ RefreshHz = 0 }) }
            @{ Name = 'no display mode'; Change = @{ DisplayMode = '0x0@0'; DisplayModeAfter = '0x0@0' } }
        )
        foreach ($case in $hardCases) {
            $problems = @(Get-FramePacingRecordProblems (New-FramePacingRecord $case.Change))
            if (@($problems | Where-Object { -not $_.StartsWith('inconclusive:', [StringComparison]::Ordinal) }).Count -eq 0) { throw "The verdict accepted $($case.Name) (problems: $($problems -join '; '))." }
        }
        $softCases = @(
            @{ Name = 'a lost foreground'; Change = @{ ForegroundHeld = $false } }
            @{ Name = 'a focus change'; Change = @{ FocusHeld = $false } }
            @{ Name = 'input during the run'; Change = @{ InputDuringRun = $true } }
            @{ Name = 'a busy machine'; Change = @{ BusyPercentBefore = 30.0 } }
            @{ Name = 'a cloaked window'; Change = @{ Cloaked = 2 } }
            @{ Name = 'a refused foreground'; Change = @{ Foreground = 'timeout' } }
            @{ Name = 'a refused visible run'; Change = @{ VisibleRefusal = 'the session is remote' } }
            @{ Name = 'a display mode that changed during the run'; Change = @{ DisplayModeAfter = '3840x2160@60' } }
            @{ Name = 'a snapshot request inside the window (Opus on #741)'; Change = @{ SnapshotsInWindow = 1 } }
            @{ Name = 'no snapshot count'; Change = @{ SnapshotsInWindow = $null } }
            @{ Name = 'a busy machine right before the window'; Change = @{ BusyPercentAtArm = 45.0 } }
            @{ Name = 'an unverifiable load right before the window'; Change = @{ BusyPercentAtArm = -1.0 } }
            @{ Name = 'the display off after the window'; Change = @{ DisplayPowerAfter = 0 } }
        )
        foreach ($case in $softCases) {
            $problems = @(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk $case.Change)))
            if ($problems.Count -eq 0 -or @($problems | Where-Object { -not $_.StartsWith('inconclusive:', [StringComparison]::Ordinal) }).Count -ne 0) { throw "The verdict did not call $($case.Name) inconclusive alone (problems: $($problems -join '; '))." }
        }
        $verdictText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingRecordProblems' 'bench-frame-pacing.ps1'
        $verdictControl = $verdictText.Replace('if ($Record.IntervalOverflow -ne 0) {', 'if ($false) {')
        if ([string]::Equals($verdictControl, $verdictText, [StringComparison]::Ordinal)) { throw 'The verdict control changed nothing.' }
        & { . ([scriptblock]::Create($verdictControl)); if (@(Get-FramePacingRecordProblems (New-FramePacingRecord @{ IntervalOverflow = 1 })).Count -ne 0) { throw 'The verdict control did not accept an overflow.' } }
        $cases.Add("verdict (complete dry run and visible run; $($hardCases.Count) failures; $($softCases.Count) inconclusive alone; overflow control)")

        # The run's status: a guard first; the outer half's failures; an INCONCLUSIVE driver (exit 2) whatever its
        # record lacks; any other exit or a hard problem fails; problems that are all the environment's are
        # inconclusive. The control drops the guard-first rule, which turns a tripped guard during an inconclusive
        # run into "inconclusive".
        $statusCases = @(
            @{ Want = 'complete'; Args = @(@(), @(), 0, $null, @()) }
            @{ Want = 'guard-tripped'; Args = @(@('clipboard changed'), @(), 0, $null, @()) }
            @{ Want = 'guard-tripped'; Args = @(@('clipboard changed'), @(), 2, 'INCONCLUSIVE: the foreground was timeout.', @('no close post took')) }
            @{ Want = 'failed'; Args = @(@(), @('owned job cleanup: x'), 0, $null, @()) }
            @{ Want = 'inconclusive'; Args = @(@(), @(), 2, 'INCONCLUSIVE: the foreground was timeout.', @('no close post took', 'grid x')) }
            @{ Want = 'failed'; Args = @(@(), @(), 2, 'the copy did not answer', @()) }
            @{ Want = 'failed'; Args = @(@(), @(), 1, 'INCONCLUSIVE: the foreground was timeout.', @()) }
            @{ Want = 'failed'; Args = @(@(), @(), $null, $null, @()) }
            @{ Want = 'failed'; Args = @(@(), @(), 0, $null, @('transport inbox')) }
            @{ Want = 'failed'; Args = @(@(), @(), 0, $null, @('inconclusive: the session had input during the workload', 'transport inbox')) }
            @{ Want = 'inconclusive'; Args = @(@(), @(), 0, $null, @('inconclusive: the session had input during the workload')) }
        )
        foreach ($case in $statusCases) {
            $a = $case.Args
            $got = Get-FramePacingRunStatus $a[0] $a[1] $a[2] $a[3] $a[4]
            if (-not (Test-FramePacingOrdinal $got $case.Want)) { throw "The run status of exit $($a[2]), error '$($a[3])', guards $($a[0].Count), outer $($a[1].Count), problems '$($a[4] -join '; ')' is $got, not $($case.Want)." }
        }
        $statusText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingRunStatus' 'bench-frame-pacing.ps1'
        $statusControl = $statusText.Replace("if (@(`$GuardFailures).Count -gt 0) { return 'guard-tripped' }", '')
        if ([string]::Equals($statusControl, $statusText, [StringComparison]::Ordinal)) { throw 'The run-status control changed nothing.' }
        & { . ([scriptblock]::Create($statusControl)); if ((Get-FramePacingRunStatus @('clipboard changed') @() 2 'INCONCLUSIVE: x' @()) -ne 'inconclusive') { throw 'The run-status control did not hide the tripped guard.' } }
        $cases.Add("run status ($($statusCases.Count) cases; guard-first control)")

        # The input gate and the foreground, through a stand-in port (Sol's High and Opus's Medium 2 on #741, with the
        # bots' finding): the port's LastInputTick answers from a queue (its last value repeats) and its Foreground
        # counts calls. Quiet: the gate passes and the foreground is called once, and the unlock's tick is then the
        # one expected. Sol's control: input after admission, before the unlock; the gate throws INCONCLUSIVE and the
        # foreground is never called. Input after the unlock, before the window, breaks the next gate. A series with
        # no tick breaks it too. The control on the code: the foreground function without its gate calls the
        # foreground despite the input.
        function New-FramePacingStandInPort([long[]] $Ticks, [long] $UnlockTick) {
            $port = [pscustomobject]@{ Kind = 'stand-in'; Queue = [Collections.Generic.Queue[long]]::new([long[]]$Ticks); ForegroundCalls = 0; UnlockTick = $UnlockTick }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { if ($this.Queue.Count -gt 1) { $this.Queue.Dequeue() } else { $this.Queue.Peek() } }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name Foreground -Value { param($HostWindow, $OwnerPid, $BoundMs, $ExpectedTick) $this.ForegroundCalls++; [pscustomobject]@{ Outcome = 'ok'; UnlockTick = $this.UnlockTick } }
            return $port
        }
        function New-FramePacingTicks([long] $Series) { return [ordered]@{ Series = $Series; Unlock = $null; Checks = [Collections.Generic.List[object]]::new() } }
        $quiet = New-FramePacingStandInPort @(100, 200) 200
        $ticks = New-FramePacingTicks 100
        $outcome = Invoke-FramePacingForeground $quiet $ticks ([IntPtr]1) 1
        if ($outcome -ne 'ok' -or $quiet.ForegroundCalls -ne 1 -or $ticks.Unlock -ne 200) { throw "A quiet session did not get one foreground call and the unlock's tick (calls $($quiet.ForegroundCalls), unlock $($ticks.Unlock))." }
        if ($null -ne (Test-FramePacingInputGate $quiet $ticks 'the measured window')) { throw 'The gate broke on the unlock''s own tick.' }
        $returned = New-FramePacingStandInPort @(150) 200
        $ticks = New-FramePacingTicks 100
        $thrown = $null
        try { [void](Invoke-FramePacingForeground $returned $ticks ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
        if (-not $thrown -or -not $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal) -or $returned.ForegroundCalls -ne 0) { throw "Input after admission did not stop the run before the foreground (calls $($returned.ForegroundCalls), '$thrown')." }
        $afterUnlock = New-FramePacingStandInPort @(100, 250) 200
        $ticks = New-FramePacingTicks 100
        [void](Invoke-FramePacingForeground $afterUnlock $ticks ([IntPtr]1) 1)
        $thrown = $null
        try { Assert-FramePacingInputGate $afterUnlock $ticks 'the measured window' } catch { $thrown = $_.Exception.Message }
        if (-not $thrown -or -not $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal)) { throw 'Input after the unlock, before the window, did not break the gate.' }
        if ($null -eq (Test-FramePacingInputGate (New-FramePacingStandInPort @(5) 0) (New-FramePacingTicks -1) 'the copy''s launch')) { throw 'The gate passed a series with no tick.' }
        if (@($ticks.Checks).Count -lt 2) { throw 'The gate does not record its checks.' }
        $foregroundText = Get-FramePacingFunctionText $framePacingAst 'Invoke-FramePacingForeground' 'bench-frame-pacing.ps1'
        $foregroundControl = $foregroundText.Replace("Assert-FramePacingInputGate `$Port `$Ticks 'the harness''s unlock'", '')
        if ([string]::Equals($foregroundControl, $foregroundText, [StringComparison]::Ordinal)) { throw 'The foreground-gate control changed nothing.' }
        & { . ([scriptblock]::Create($foregroundControl)); $port = New-FramePacingStandInPort @(150) 200; [void](Invoke-FramePacingForeground $port (New-FramePacingTicks 100) ([IntPtr]1) 1); if ($port.ForegroundCalls -ne 1) { throw 'The foreground-gate control did not call the foreground despite the input.' } }
        # The unlock's tick is set in one place only (Opus's M8 on #741: a tick read after the window must never become
        # the next run's baseline). The control: a second assignment after the window is caught.
        function Test-FramePacingUnlockAssignments([string] $Text) { return [regex]::Matches($Text, '\.Unlock\s*=(?!=)').Count -eq 1 -and [regex]::Matches($Text, '\$quietSince = \[long\]\$result\.Record\.InputTicks\.Unlock').Count -eq 1 }
        if (-not (Test-FramePacingUnlockAssignments $framePacingText)) { throw 'The unlock''s tick must be assigned once, in Invoke-FramePacingForeground, and be the only source of the next run''s tick.' }
        if (Test-FramePacingUnlockAssignments ($framePacingText.Replace('$record.DisplayPowerAfter = [FramePacingNative]::DisplayPower(2000)', "`$record.DisplayPowerAfter = [FramePacingNative]::DisplayPower(2000)`n        `$record.InputTicks.Unlock = [FramePacingNative]::LastInputTick()"))) { throw 'The unlock-assignment check accepted a tick read after the window.' }
        $cases.Add('input gate and foreground (quiet; Sol''s input after admission never reaches the foreground; input after the unlock; no series tick; checks recorded; a gateless foreground as the control; the unlock''s tick set once, Opus''s M8 as the control)')

        # Comparable runs only (Greptile, CodeRabbit, Sol and Opus on #741): runs alike pool; runs at 240 Hz and 60 Hz
        # are reported per mode, never pooled, and so are runs at another DPI or grid; runs at two workloads, builds,
        # renderers, transports or ConPTY digests never pool either. The control: the series pooled regardless of
        # environment mixes the two refresh rates.
        function New-FramePacingRun([hashtable] $Change) {
            $r = @{ DisplayMode = '3840x2160@240'; Dpi = 144; GridCols = 140; GridRows = 43; WorkloadSha256 = 'w'; ExeSHA256 = 'e'; Renderer = 'opengl'; Transport = 'bundled'; ConptyDllSHA256 = 'c'; OpenConsoleSHA256 = 'o'; IntervalsMs = [double[]]@(4.1, 4.2, 4.3) }
            foreach ($k in $Change.Keys) { $r[$k] = $Change[$k] }
            # The fields every real run.json carries that the summary reads (StrictMode refuses a missing one).
            if (-not $r.ContainsKey('IntervalCount')) { $r.IntervalCount = @($r.IntervalsMs).Count }
            if (-not $r.ContainsKey('P95Ms')) { $r.P95Ms = $null }
            return [pscustomobject]$r
        }
        $at240 = New-FramePacingRun @{}
        $at240b = New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4) }
        $at60 = New-FramePacingRun @{ DisplayMode = '3840x2160@60'; IntervalsMs = [double[]]@(16.6, 16.7) }
        foreach ($case in @(@{ Field = 'Dpi'; Change = @{ Dpi = 96 } }, @{ Field = 'Grid'; Change = @{ GridRows = 45 } })) {
            $env = Get-FramePacingSeries @($at240, (New-FramePacingRun $case.Change))
            if ($env.Pooled.Count -ne 0 -or @($env.MixedEnvironment) -notcontains $case.Field) { throw "Runs that differ in $($case.Field) were pooled." }
        }
        foreach ($case in @(@{ Field = 'ExeSHA256'; Change = @{ ExeSHA256 = 'f' } }, @{ Field = 'Renderer'; Change = @{ Renderer = 'fallback' } }, @{ Field = 'Transport'; Change = @{ Transport = 'inbox' } }, @{ Field = 'ConptyDllSHA256'; Change = @{ ConptyDllSHA256 = 'd' } }, @{ Field = 'OpenConsoleSHA256'; Change = @{ OpenConsoleSHA256 = 'p' } })) {
            $build = Get-FramePacingSeries @($at240, (New-FramePacingRun $case.Change))
            if ($build.Pooled.Count -ne 0 -or @($build.MixedBuild) -notcontains $case.Field) { throw "Runs that differ in $($case.Field) were pooled." }
        }
        $same = Get-FramePacingSeries @($at240, $at240b)
        if ($same.Mixed -or $same.Pooled.Count -ne 5 -or $same.P95 -ne 4.4 -or @($same.ByMode).Count -ne 1) { throw "Two runs at one display mode did not pool (pooled $($same.Pooled.Count), p95 $($same.P95))." }
        $mixed = Get-FramePacingSeries @($at240, $at60)
        if (-not $mixed.Mixed -or $mixed.Pooled.Count -ne 0 -or $null -ne $mixed.P95 -or @($mixed.ByMode).Count -ne 2) { throw "Runs at 240 Hz and 60 Hz were pooled (pooled $($mixed.Pooled.Count), p95 $($mixed.P95))." }
        $by60 = @($mixed.ByMode | Where-Object { Test-FramePacingOrdinal $_.display_mode '3840x2160@60' })
        if ($by60.Count -ne 1 -or $by60[0].p95_ms -ne 16.7 -or $by60[0].intervals -ne 2) { throw 'The 60 Hz runs were not reported on their own.' }
        $twoWorkloads = Get-FramePacingSeries @($at240, (New-FramePacingRun @{ WorkloadSha256 = 'v'; IntervalsMs = [double[]]@(4.0) }))
        if ($twoWorkloads.Pooled.Count -ne 0 -or @($twoWorkloads.MixedBuild) -notcontains 'WorkloadSha256') { throw 'Runs at two workloads were pooled.' }
        $seriesText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSeries' 'bench-frame-pacing.ps1'
        $seriesControl = $seriesText.Replace('$pooled = @(if ($mixedEnvironment.Count -eq 0 -and $mixedBuild.Count -eq 0) {', '$pooled = @(if ($mixedBuild.Count -eq 0) {')
        if ([string]::Equals($seriesControl, $seriesText, [StringComparison]::Ordinal)) { throw 'The display-mode control changed nothing.' }
        & { . ([scriptblock]::Create($seriesControl)); if ((Get-FramePacingSeries @($at240, $at60)).Pooled.Count -ne 5) { throw 'The display-mode control did not pool the two refresh rates.' } }
        $cases.Add('comparability (runs alike pool; 240 Hz with 60 Hz reported per mode; DPI, grid; workload, app, renderer, transport, both ConPTY digests; an environment-blind pool as the control)')

        # The summary's published output, from the real function (Sol and CodeRabbit on #741; Opus's M13 and M17): a
        # dry run publishes only dry_run_p95_ms; a visible series publishes frame_time_p95_ms and its median only when
        # every run completed and the runs are comparable, and otherwise writes null and prints that no measurement was
        # published; mixed display modes exit 2, a mixed workload or build 1, a failed run (the first included) 1, a
        # tripped guard 3, and every case writes pacing.json. The cases run under the harness's own StrictMode (Greptile
        # on #741: an empty pool unwrapped to $null threw on .Count there, before pacing.json, and a test without
        # StrictMode read .Count of $null as 0). Controls: Sol's late assignment of the metric before serialization, the
        # median published without the visible check, the Error exit removed, and the pool's old `if` assignment, are
        # each caught.
        function Invoke-FramePacingSummaryCase([bool] $AsVisible, [int] $RunCount, [object[]] $Results, [string] $SummaryText, [string] $SeriesText) {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('fp-summary-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($root)
            try {
                try {
                    $out = & {
                        Set-StrictMode -Version Latest
                        $Visible = $AsVisible; $Runs = $RunCount
                        if ($SummaryText) { . ([scriptblock]::Create($SummaryText)) }
                        if ($SeriesText) { . ([scriptblock]::Create($SeriesText)) }
                        Write-FramePacingSummary $root ([pscustomobject]@{ Head = 'h'; ExeSha256 = 'e' }) $Results
                    } 6>&1
                } catch { return [pscustomobject]@{ Code = "threw: $($_.Exception.Message)"; Json = $null; Console = '' } }
                $jsonPath = Join-Path $root 'pacing.json'
                if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { return [pscustomobject]@{ Code = 'no pacing.json'; Json = $null; Console = '' } }
                $console = (@($out | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n")
                return [pscustomobject]@{ Code = @($out | Where-Object { $_ -is [int] })[-1]; Json = (Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json); Console = $console }
            } finally { [IO.Directory]::Delete($root, $true) }
        }
        function New-FramePacingResult([string] $Status, $Record) { return [pscustomobject]@{ Run = "C:\fp\run-$([guid]::NewGuid().ToString('N').Substring(0, 4))"; Status = $Status; Failures = @(); Record = $Record } }
        $runA = New-FramePacingRun @{}; $runB = New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4) }
        $summaryCases = @(
            @{ Name = 'a complete dry run'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 0; Published = $false; Dry = $true; Console = 'dry run: dry_run_p95_ms' }
            @{ Name = 'a partial visible series'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'inconclusive' $null)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-display-mode series (two refresh rates)'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $at60)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-display-mode dry run'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $at60)); Code = 2; Published = $false; Dry = $false; Console = 'dry run: no pooled intervals' }
            @{ Name = 'a visible series at two workloads'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' (New-FramePacingRun @{ WorkloadSha256 = 'v' }))); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-build series (another app)'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' (New-FramePacingRun @{ ExeSHA256 = 'f' }))); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a failed first run'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a failed first dry run'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'dry run: no pooled intervals' }
            @{ Name = 'a visible series stopped by a failed run'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a visible series stopped by a tripped guard'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'guard-tripped' $null)); Code = 3; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a complete visible series'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 0; Published = $true; Dry = $false; Console = 'frame_time_p95_ms 4.4' }
        )
        function Test-FramePacingSummaryCases([string] $SummaryText, [string] $SeriesText) {
            foreach ($case in $summaryCases) {
                $got = Invoke-FramePacingSummaryCase $case.Visible $case.Runs $case.Results $SummaryText $SeriesText
                if ($null -eq $got.Json) { return "$($case.Name): $($got.Code)" }
                $published = $null -ne $got.Json.frame_time_p95_ms -or $null -ne $got.Json.frame_time_median_ms
                if ($got.Code -ne $case.Code -or $published -ne $case.Published -or ($null -ne $got.Json.dry_run_p95_ms) -ne $case.Dry -or -not $got.Console.Contains($case.Console)) {
                    return "$($case.Name): exit $($got.Code), published $published, dry $($null -ne $got.Json.dry_run_p95_ms), console '$($got.Console)'"
                }
                if ($case.Published -and ($got.Json.frame_time_p95_ms -ne 4.4 -or $got.Json.frame_time_median_ms -ne 4.2)) { return "$($case.Name): p95 $($got.Json.frame_time_p95_ms), median $($got.Json.frame_time_median_ms)" }
            }
            return $null
        }
        $summaryProblem = Test-FramePacingSummaryCases $null
        if ($summaryProblem) { throw "The summary published the wrong thing: $summaryProblem." }
        $summaryText = Get-FramePacingFunctionText $framePacingAst 'Write-FramePacingSummary' 'bench-frame-pacing.ps1'
        foreach ($control in @(
                @{ Name = 'Sol''s late assignment'; Old = "    `$summary | ConvertTo-Json -Depth 6 | Set-Content"; New = "    `$summary.frame_time_p95_ms = `$series.P95`n    `$summary | ConvertTo-Json -Depth 6 | Set-Content" }
                @{ Name = 'Opus''s M13, the median without the visible check'; Old = 'frame_time_median_ms = $(if ($publish) { $series.Median }'; New = 'frame_time_median_ms = $(if ($completed.Count -eq $Runs) { $series.Median }' }
                @{ Name = 'Opus''s M17, the Error exit removed'; Old = "    if (`$summary.Contains('Error')) { return 1 }"; New = '' }
            )) {
            $controlText = $summaryText.Replace($control.Old, $control.New)
            if ([string]::Equals($controlText, $summaryText, [StringComparison]::Ordinal)) { throw "The summary control changed nothing: $($control.Name)." }
            if ($null -eq (Test-FramePacingSummaryCases $controlText)) { throw "The summary cases accepted $($control.Name)." }
        }
        $seriesOld = '    $pooled = if ($mixedEnvironment.Count -eq 0 -and $mixedBuild.Count -eq 0) { [double[]]@($Records | ForEach-Object { @($_.IntervalsMs) } | ForEach-Object { [double]$_ }) } else { [double[]]@() }'
        $seriesNew = '    [double[]]$pooled = @(if ($mixedEnvironment.Count -eq 0 -and $mixedBuild.Count -eq 0) { $Records | ForEach-Object { @($_.IntervalsMs) } | ForEach-Object { [double]$_ } })'
        $seriesFunctionText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSeries' 'bench-frame-pacing.ps1'
        $seriesUnwrap = $seriesFunctionText.Replace($seriesNew, $seriesOld)
        if ([string]::Equals($seriesUnwrap, $seriesFunctionText, [StringComparison]::Ordinal)) { throw 'The pool-unwrap control changed nothing.' }
        if ($null -eq (Test-FramePacingSummaryCases $null $seriesUnwrap)) { throw 'The summary cases accepted the pool''s old if assignment, which unwraps an empty pool to $null.' }
        $cases.Add("summary output ($($summaryCases.Count) cases under StrictMode, pacing.json, the JSON, the console and the exit; Sol's late assignment, Opus's M13 and M17, and the pool's old if assignment as controls)")

        # The statistics: QPC ticks over the trace's frequency in ms; nearest-rank p95 and the median.
        $stats = Get-FramePacingIntervalStats @(10000, 20000, 30000) 10000000.0
        if (-not (Test-FramePacingOrdinal (($stats.Ms | ForEach-Object { $_.ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ',') '1,2,3') -or $stats.P95 -ne 3 -or $stats.Median -ne 2 -or $stats.Count -ne 3 -or $stats.Sum -ne 6) { throw "The interval statistics are wrong for 1, 2, 3 ms (p95 $($stats.P95), median $($stats.Median))." }
        $twenty = Get-FramePacingIntervalStats @(1..20 | ForEach-Object { $_ * 10000 }) 10000000.0
        if ($twenty.P95 -ne 19 -or $twenty.Median -ne 10.5) { throw "Nearest-rank p95 of 1..20 ms must be 19 and the median 10.5 (got $($twenty.P95), $($twenty.Median))." }
        if ((Get-FramePacingIntervalStats @() 10000000.0).Count -ne 0) { throw 'No ticks must give no intervals.' }
        $cases.Add('statistics (1,2,3 ms; 1..20 ms nearest rank; empty)')

        # The marker frame is bench-windows.ps1's (SGR reset, CUP 1;1, EL 2, then the token), and the bench's stream
        # producer still writes that frame.
        $tail = Get-FramePacingMarkerTail 'NB0123456789abcdef'
        if (-not (Test-FramePacingOrdinal ([BitConverter]::ToString($tail)) ([BitConverter]::ToString([Text.Encoding]::ASCII.GetBytes("$([char]27)[0m$([char]27)[1;1H$([char]27)[2KNB0123456789abcdef"))))) { throw 'The marker frame is not SGR reset, CUP 1;1, EL 2 and the token.' }
        if (-not $framePacingBenchText.Contains("`$markerFrame = if (`$marker.Length -gt 0) { [Text.Encoding]::ASCII.GetBytes(([char]27) + '[0m' + ([char]27) + '[1;1H' + ([char]27) + '[2K') }")) { throw 'bench-windows.ps1''s stream producer no longer writes the marker frame this harness copies.' }
        $cases.Add('marker frame (bytes; the bench producer''s)')

        # The workload hash: the run's directory does not change it; a constant or the payload does.
        $hashDir = Join-Path ([IO.Path]::GetTempPath()) ('fp-hash-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($hashDir)
        try {
            $one = Join-Path $hashDir 'one.ghostty'; $two = Join-Path $hashDir 'two.ghostty'
            # Two run directories under the temporary one, on whatever drive it is (CodeRabbit and Opus on #741: a
            # D:\ path throws on a machine without that drive).
            $runA = Join-Path $hashDir 'runs\a\run-1'; $runB = Join-Path $hashDir 'other\b\run-7'
            [IO.File]::WriteAllText($one, (New-FramePacingConfigText $runA), $script:Utf8)
            [IO.File]::WriteAllText($two, (New-FramePacingConfigText $runB), $script:Utf8)
            $h1 = Get-FramePacingWorkloadSha256 'p' $one $runA
            $h2 = Get-FramePacingWorkloadSha256 'p' $two $runB
            if (-not (Test-FramePacingOrdinal $h1 $h2)) { throw 'The workload hash depends on the run''s directory.' }
            if (Test-FramePacingOrdinal $h1 (Get-FramePacingWorkloadSha256 'q' $one $runA)) { throw 'The workload hash ignores the payload.' }
            $script:FontSize = 17
            try { if (Test-FramePacingOrdinal $h1 (Get-FramePacingWorkloadSha256 'p' $one $runA)) { throw 'The workload hash ignores a constant.' } } finally { $script:FontSize = 16 }
        } finally { [IO.Directory]::Delete($hashDir, $true) }
        $cases.Add('workload hash (run directory; payload; constant)')
        $cases.ToArray()
    }
} finally {
    foreach ($name in $framePacingSaved.Keys) {
        if ($framePacingSaved[$name].Existed) { Set-Variable -Scope Script -Name $name -Value $framePacingSaved[$name].Value }
        else { Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue }
    }
}

# The native layer: the harness's Add-Type source, compiled here under another class name, must give the SDK's x64
# layout string the harness checks at run time. The controls: a changed field in INPUT's MOUSEINPUT, LASTINPUTINFO,
# SECURITY_ATTRIBUTES and MSG, compiled the same way, must give another layout.
$framePacingNative = @($framePacingAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class FramePacingNative' }, $true))
if ($framePacingNative.Count -ne 1) { throw 'The frame-pacing harness must hold one FramePacingNative source.' }
$framePacingLayoutWanted = [regex]::Match($framePacingText, "\`$script:SdkLayout = '([^']+)'").Groups[1].Value
if (-not (Test-FramePacingOrdinal $framePacingLayoutWanted 'Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8 Input=40 mouse@8 MouseInput=32 mouseFlags@12 LastInput=8 SecurityAttributes=24 saDescriptor@8 saInherit@16 ProcessInfo=24 piThread@8 piPid@16 piTid@20 Rect=16 rectRight@8 rectBottom@12 WndClassEx=80 wcProc@8 wcClassName@64 Msg=48 msgWParam@16 msgTime@32')) {
    throw 'The frame-pacing harness''s SDK layout string changed.'
}
$framePacingClass = 'FramePacingNativeContract' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($framePacingNative[0].Value.Replace('public static class FramePacingNative', "public static class $framePacingClass"))
$framePacingProbe = $framePacingClass -as [type]
$framePacingLayout = $framePacingProbe::Layout()
if (-not (Test-FramePacingOrdinal $framePacingLayout $framePacingLayoutWanted)) { throw "The frame-pacing native layer's layout is $framePacingLayout, not the SDK's." }
foreach ($control in @(
        @{ Name = 'MOUSEINPUT with its extra info narrowed'; Old = 'public uint data, flags, time; public IntPtr extra; }'; New = 'public uint data, flags, time; public uint extra; }' }
        @{ Name = 'LASTINPUTINFO widened'; Old = 'struct LastInput { public uint size, time; }'; New = 'struct LastInput { public ulong size, time; }' }
        @{ Name = 'SECURITY_ATTRIBUTES with its descriptor narrowed'; Old = 'struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }'; New = 'struct SecurityAttributes { public int length; public int descriptor; public int inherit; }' }
        @{ Name = 'MSG with its wParam narrowed'; Old = 'public uint message; public IntPtr wParam, lParam;'; New = 'public uint message; public int wParam; public IntPtr lParam;' }
    )) {
    $controlSource = $framePacingNative[0].Value.Replace($control.Old, $control.New)
    if ([string]::Equals($controlSource, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw "The layout control changed nothing: $($control.Name)." }
    $controlClass = 'FramePacingNativeControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Add-Type -TypeDefinition ($controlSource.Replace('public static class FramePacingNative', "public static class $controlClass"))
    if (Test-FramePacingOrdinal (($controlClass -as [type])::Layout()) $framePacingLayoutWanted) { throw "The layout check accepted $($control.Name)." }
}

# Every launch names its desktop: the native source assigns the startup desktop exactly twice, each from the caller's
# `desktop` argument, and both launches refuse an empty one (#739's check). The control: a second assignment that
# overwrites the value with null right before CreateProcessW.
$framePacingNativeText = $framePacingNative[0].Value
function Test-FramePacingDesktopAssignments([string] $Source) {
    $assignments = @([regex]::Matches($Source, '(?<![\w])(?:si\.info\.)?desktop\s*=(?!=)\s*[^,;}\r\n]+') | ForEach-Object { $_.Value -replace '\s+', ' ' })
    $guards = [regex]::Matches($Source, 'if \(string\.IsNullOrEmpty\(desktop\)\) throw new Exception\("A launch must name its desktop"\);').Count
    return $assignments.Count -eq 2 -and (Test-FramePacingOrdinal $assignments[0] 'desktop = desktop') -and (Test-FramePacingOrdinal $assignments[1] 'si.info.desktop = desktop') -and $guards -eq 2
}
if (-not (Test-FramePacingDesktopAssignments $framePacingNativeText)) { throw 'Every frame-pacing launch must take its startup desktop from its caller, once, and refuse an empty one.' }
if (Test-FramePacingDesktopAssignments ($framePacingNativeText.Replace('si.attributes = list;', "si.attributes = list;`n            si.info.desktop = null;"))) { throw 'The desktop check accepted an assignment that overwrites the startup desktop with null.' }

# DesktopRefusal, tabled (Opus's M4, M5, M6 and M21 on #741): every combination a launch can meet, from the compiled
# class. The controls are those four mutations, each compiled under another name: a visible driver not from Default,
# a visible launch while Default is not the input desktop (driver and child), and a dry run's driver onto the input
# desktop, each accepted by the mutant and refused here. An unreadable input desktop goes in as [NullString]::Value:
# PowerShell passes a plain $null to a string parameter as an empty string.
$framePacingRefusalCases = @(
    @{ Name = 'a dry driver onto a private desktop'; Args = @('WinSta0\fp-1', 'WinSta0\Default', 'Default', $false, $true); Refused = $false }
    @{ Name = 'a dry driver onto the caller''s own desktop'; Args = @('WinSta0\Default', 'WinSta0\Default', 'Default', $false, $true); Refused = $true }
    @{ Name = 'a dry driver onto Default from a private desktop'; Args = @('WinSta0\Default', 'WinSta0\fp-0', 'Default', $false, $true); Refused = $true }
    @{ Name = 'a dry driver onto another input desktop (M21)'; Args = @('WinSta0\Other', 'WinSta0\Default', 'Other', $false, $true); Refused = $true }
    @{ Name = 'a dry driver with the input desktop unreadable'; Args = @('WinSta0\fp-1', 'WinSta0\Default', [NullString]::Value, $false, $true); Refused = $true }
    @{ Name = 'a dry child onto its own private desktop'; Args = @('WinSta0\fp-1', 'WinSta0\fp-1', 'Default', $false, $false); Refused = $false }
    @{ Name = 'a dry child onto another desktop'; Args = @('WinSta0\fp-2', 'WinSta0\fp-1', 'Default', $false, $false); Refused = $true }
    @{ Name = 'a dry child onto Default, its own'; Args = @('WinSta0\Default', 'WinSta0\Default', 'Default', $false, $false); Refused = $true }
    @{ Name = 'a dry child onto its own desktop while it is the input desktop'; Args = @('WinSta0\fp-1', 'WinSta0\fp-1', 'fp-1', $false, $false); Refused = $true }
    @{ Name = 'a visible driver onto Default from Default, the input desktop'; Args = @('WinSta0\Default', 'WinSta0\Default', 'Default', $true, $true); Refused = $false }
    @{ Name = 'a visible driver onto a private desktop'; Args = @('WinSta0\fp-1', 'WinSta0\Default', 'Default', $true, $true); Refused = $true }
    @{ Name = 'a visible driver from a private desktop (M4)'; Args = @('WinSta0\Default', 'WinSta0\fp-1', 'Default', $true, $true); Refused = $true }
    @{ Name = 'a visible driver while the session is locked (M5)'; Args = @('WinSta0\Default', 'WinSta0\Default', 'Winlogon', $true, $true); Refused = $true }
    @{ Name = 'a visible driver with the input desktop unreadable'; Args = @('WinSta0\Default', 'WinSta0\Default', [NullString]::Value, $true, $true); Refused = $true }
    @{ Name = 'a visible child onto Default, the input desktop'; Args = @('WinSta0\Default', 'WinSta0\Default', 'Default', $true, $false); Refused = $false }
    @{ Name = 'a visible child while the session is locked (M6)'; Args = @('WinSta0\Default', 'WinSta0\Default', 'Winlogon', $true, $false); Refused = $true }
    @{ Name = 'a visible child onto a private desktop'; Args = @('WinSta0\fp-1', 'WinSta0\fp-1', 'Default', $true, $false); Refused = $true }
    @{ Name = 'a launch naming no desktop'; Args = @('', 'WinSta0\Default', 'Default', $false, $false); Refused = $true }
)
function Get-FramePacingRefusalMiss([type] $Native) {
    foreach ($case in $framePacingRefusalCases) {
        $a = $case.Args
        $refused = $null -ne $Native::DesktopRefusal($a[0], $a[1], $a[2], $a[3], $a[4])
        if ($refused -ne $case.Refused) { return $case.Name }
    }
    return $null
}
$framePacingRefusalMiss = Get-FramePacingRefusalMiss $framePacingProbe
if ($framePacingRefusalMiss) { throw "DesktopRefusal got $framePacingRefusalMiss wrong." }
foreach ($control in @(
        @{ Name = 'M4, a visible driver not from Default'; Old = 'if (!Same(target, def) || !Same(own, def) || !Same(inp, def))'; New = 'if (!Same(target, def) || !Same(inp, def))' }
        @{ Name = 'M5 and M6, Default not the input desktop'; Old = 'if (!Same(target, def) || !Same(own, def) || !Same(inp, def))'; New = 'if (!Same(target, def) || !Same(own, def))' }
        @{ Name = 'M21, a dry driver onto the input desktop'; Old = 'Same(target, own) || Same(target, def) || Same(target, inp) ?'; New = 'Same(target, own) || Same(target, def) ?' }
    )) {
    $controlSource = $framePacingNative[0].Value.Replace($control.Old, $control.New)
    if ([string]::Equals($controlSource, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw "The DesktopRefusal control changed nothing: $($control.Name)." }
    $controlClass = 'FramePacingRefusalControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Add-Type -TypeDefinition ($controlSource.Replace('public static class FramePacingNative', "public static class $controlClass"))
    if ($null -eq (Get-FramePacingRefusalMiss ($controlClass -as [type]))) { throw "The DesktopRefusal table accepted $($control.Name)." }
}

# The unlock payload, read back from the array the foreground sends (Sol's mutation on #741: a motion added to the
# zero-motion input). The control: the same source with dx = 20 added gives another payload.
$framePacingPayloadWanted = 'count=1 type=0 dx=0 dy=0 data=0 flags=1 time=0 extra=0'
if (-not (Test-FramePacingOrdinal ($framePacingProbe::UnlockPayload()) $framePacingPayloadWanted)) { throw "The unlock payload is $($framePacingProbe::UnlockPayload()), not one zero-motion MOUSEEVENTF_MOVE." }
$payloadControl = $framePacingNative[0].Value.Replace('unlock[0].mouse.flags = 0x0001; // MOUSEEVENTF_MOVE, dx = dy = 0', 'unlock[0].mouse.flags = 0x0001; unlock[0].mouse.dx = 20;')
if ([string]::Equals($payloadControl, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The unlock-payload control changed nothing.' }
$payloadClass = 'FramePacingPayloadControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($payloadControl.Replace('public static class FramePacingNative', "public static class $payloadClass"))
if (Test-FramePacingOrdinal (($payloadClass -as [type])::UnlockPayload()) $framePacingPayloadWanted) { throw 'The unlock-payload check accepted a motion.' }

# The owned job, run for real (Sol's mutation on #741: the driver resumed without its job): LaunchDriver starts
# System32's cmd.exe /D /C exit 0, suspended, on a private desktop of this check's own, and it must come back a member
# of the job it was given. The control: the same source without the assignment ends the process before it runs and
# throws. Skipped where no private desktop can be made or the input desktop is unreadable here.
if (-not ('FramePacingContractDesktop' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FramePacingContractDesktop {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr security);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
}
'@
}
$framePacingJobCase = 'owned-job skipped (no private desktop or no readable input desktop)'
$jobDesktopName = 'fp-contract-job-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$jobDesktop = [FramePacingContractDesktop]::CreateDesktopW($jobDesktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
if ($jobDesktop -ne [IntPtr]::Zero -and $null -ne $framePacingProbe::InputDesktopName()) {
    $jobDir = Join-Path ([IO.Path]::GetTempPath()) ('fp-job-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($jobDir)
    $cmdExe = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    try {
        function Invoke-FramePacingJobCase([type] $Native) {
            $job = $Native::CreateRunJob()
            try {
                $pi = $Native::LaunchDriver($cmdExe, ('"{0}" /D /C exit 0' -f $cmdExe), $jobDir, "WinSta0\$jobDesktopName", $job, $false)
                try {
                    $member = $Native::InJobOf($pi.process, $job)
                    [void]$Native::WaitForSingleObject($pi.process, 10000)
                    return $(if ($member) { 'member' } else { 'not a member' })
                } finally { [void]$Native::CloseHandle($pi.thread); [void]$Native::CloseHandle($pi.process) }
            } catch { return "refused: $($_.Exception.Message)" }
            finally { [void]$Native::CloseHandle($job) }
        }
        $got = Invoke-FramePacingJobCase $framePacingProbe
        if (-not (Test-FramePacingOrdinal $got 'member')) { throw "LaunchDriver's driver was not a member of the run's own job ($got)." }
        $jobControl = $framePacingNative[0].Value.Replace('if (!AssignProcessToJobObject(job, pi.process) || !InJobOf(pi.process, job) ||', 'if (!InJobOf(pi.process, job) ||')
        if ([string]::Equals($jobControl, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The owned-job control changed nothing.' }
        $jobClass = 'FramePacingJobControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Add-Type -TypeDefinition ($jobControl.Replace('public static class FramePacingNative', "public static class $jobClass"))
        $got = Invoke-FramePacingJobCase ($jobClass -as [type])
        if (-not $got.Contains("The driver is not in the run's own job")) { throw "LaunchDriver without the assignment was not refused before the driver ran ($got)." }
        $framePacingJobCase = 'owned-job (a real suspended cmd.exe /D /C exit 0 on a private desktop is a member of its job; without the assignment it is ended before it runs)'
    } finally {
        [IO.Directory]::Delete($jobDir, $true)
        [void][FramePacingContractDesktop]::CloseDesktop($jobDesktop)
    }
} elseif ($jobDesktop -ne [IntPtr]::Zero) { [void][FramePacingContractDesktop]::CloseDesktop($jobDesktop) }

# The launch desktops at run time, compiled: a dry run's child only on the caller's own desktop and never Default or
# the input desktop, its driver never on the caller's own desktop, Default or the input desktop; a visible run's child
# and driver only on Default while it is the input desktop and the caller's. Every call names an executable that does
# not exist, so a missing refusal fails with CreateProcess and still starts nothing. Where this process has no
# readable desktop (a service session), the cases are skipped.
$framePacingOwn = $null
try { $framePacingOwn = $framePacingProbe::CurrentDesktopName() } catch { $framePacingOwn = $null }
if ($null -ne $framePacingOwn) {
    $framePacingInput = $framePacingProbe::InputDesktopName()
    $framePacingOnDefault = [string]::Equals($framePacingOwn, 'Default', [StringComparison]::OrdinalIgnoreCase) -and $null -ne $framePacingInput -and [string]::Equals($framePacingInput, 'Default', [StringComparison]::OrdinalIgnoreCase)
    $launchDir = Join-Path ([IO.Path]::GetTempPath()) ('fp-launch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($launchDir)
    try {
        $missingExe = Join-Path $launchDir 'missing.exe'
        $launchLog = Join-Path $launchDir 'launch.log'
        function Get-FramePacingLaunchRefusal([scriptblock] $Call) { try { & $Call; return 'launched' } catch { return $_.Exception.Message } }
        $foreign = 'WinSta0\fp-contract-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::Spawn($missingExe, '"x"', $launchDir, $foreign, $launchLog, $true, $false) }
        if (-not ($got.Contains("A child must start on the caller's own desktop") -or $got.Contains('The input desktop is unreadable'))) { throw "Spawn did not refuse another desktop (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::Spawn($missingExe, '"x"', $launchDir, $foreign, $launchLog, $true, $true) }
        if (-not ($got.Contains('A visible child starts only on Default') -or $got.Contains('The input desktop is unreadable'))) { throw "A visible Spawn did not refuse another desktop (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, 'WinSta0\Default', [IntPtr]::Zero, $false) }
        if (-not ($got.Contains('The driver must start on a private desktop') -or $got.Contains('The input desktop is unreadable'))) { throw "A dry run's LaunchDriver did not refuse Default (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, "WinSta0\$framePacingOwn", [IntPtr]::Zero, $false) }
        if (-not ($got.Contains('The driver must start on a private desktop') -or $got.Contains('The input desktop is unreadable'))) { throw "A dry run's LaunchDriver did not refuse the caller's own desktop (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, $foreign, [IntPtr]::Zero, $true) }
        if (-not ($got.Contains('A visible driver starts only on Default') -or $got.Contains('The input desktop is unreadable'))) { throw "A visible LaunchDriver did not refuse a private desktop (got: $got)." }
        # The controls: a private desktop's name passes a dry run's driver check, and on an unlocked Default the
        # visible driver's and child's checks pass; each then reaches CreateProcess, which fails on the missing
        # executable. On Default a dry run's child is refused there.
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, $foreign, [IntPtr]::Zero, $false) }
        $wantControl = if ($null -eq $framePacingInput) { 'The input desktop is unreadable' } else { 'CreateProcess failed' }
        if (-not $got.Contains($wantControl)) { throw "A dry run's LaunchDriver check refused a private desktop, or launched (got: $got)." }
        if ($framePacingOnDefault) {
            $got = Get-FramePacingLaunchRefusal { $framePacingProbe::Spawn($missingExe, '"x"', $launchDir, 'WinSta0\Default', $launchLog, $true, $false) }
            if (-not $got.Contains('A child must not start on Default or the input desktop')) { throw "A dry run's Spawn did not refuse Default (got: $got)." }
            $got = Get-FramePacingLaunchRefusal { $framePacingProbe::Spawn($missingExe, '"x"', $launchDir, 'WinSta0\Default', $launchLog, $true, $true) }
            if (-not $got.Contains('CreateProcess failed')) { throw "A visible Spawn's check refused Default, or launched (got: $got)." }
            $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, 'WinSta0\Default', [IntPtr]::Zero, $true) }
            if (-not $got.Contains('CreateProcess failed')) { throw "A visible LaunchDriver's check refused Default, or launched (got: $got)." }
            $framePacingDesktopCase = 'launch-desktop (dry: Spawn foreign and Default, LaunchDriver Default and own; visible: Spawn foreign, LaunchDriver private; controls: dry driver private, visible Spawn and driver on Default)'
        } else {
            $framePacingDesktopCase = 'launch-desktop (dry: Spawn foreign, LaunchDriver Default and own; visible: Spawn foreign, LaunchDriver private; control: dry driver private; the Default cases skipped off an unlocked Default)'
        }
    } finally { [IO.Directory]::Delete($launchDir, $true) }
} else { $framePacingDesktopCase = 'launch-desktop skipped (no readable desktop)' }
# bench-windows.ps1's frame-pacing exits, run in a child pwsh (CodeRabbit on #741): -Runs 51 is refused by the
# wrapper itself, and a harness that throws (a measure repo that does not exist) exits 1 through it, never 0. Neither
# reaches a launch: the first stops before the harness, the second at its admission.
$framePacingPwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if ($framePacingPwsh) {
    $missingRepo = Join-Path ([IO.Path]::GetTempPath()) ('fp-no-repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $runsOut = & $framePacingPwsh -NoProfile -NonInteractive -File $framePacingBenchScript -Metric frame-pacing -Runs 51 -MeasureRepo $missingRepo -RunRoot (Join-Path $missingRepo 'runs') 2>&1 | Out-String
    $runsExit = $LASTEXITCODE
    if ($runsExit -eq 0 -or -not $runsOut.Contains('-Runs 1 to 50')) { throw "bench-windows.ps1 -Metric frame-pacing -Runs 51 exited $runsExit without the run limit's refusal." }
    $repoOut = & $framePacingPwsh -NoProfile -NonInteractive -File $framePacingBenchScript -Metric frame-pacing -Runs 1 -MeasureRepo $missingRepo -RunRoot (Join-Path $missingRepo 'runs') 2>&1 | Out-String
    $repoExit = $LASTEXITCODE
    if ($repoExit -ne 1) { throw "bench-windows.ps1 -Metric frame-pacing exited $repoExit, not 1, when the harness refused its measure repo." }
    if (Test-Path -LiteralPath $missingRepo) { throw 'The refused frame-pacing run created its run root.' }
    $framePacingBenchCase = 'bench exits (-Runs 51 refused by the wrapper; a refused measure repo exits 1)'
} else { $framePacingBenchCase = 'bench exits skipped (no pwsh.exe)' }
Write-Host "Frame-pacing harness contract: $framePacingMutations rules, each with a rejected mutation; $framePacingSharedCount shared pieces identical to #739's and bench-windows.ps1's; input discipline (controls: a second foreground, a second SendInput; $($framePacingInputApis.Count) other input APIs, each caught); forbidden forms ($($framePacingForbidden.Count), each caught); trace protocol against consts.zig, render_trace.zig and bench_marker.zig; constants pinned; $($framePacingCases -join '; '); native layout $framePacingLayout (4 controls); desktop assignments (control); DesktopRefusal ($($framePacingRefusalCases.Count) cases; Opus's M4, M5/M6 and M21 compiled as controls); unlock payload (control); $framePacingJobCase; $framePacingDesktopCase; $framePacingBenchCase"
