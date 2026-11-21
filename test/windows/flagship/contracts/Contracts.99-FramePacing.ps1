# Frame pacing under the per-copy rules: test/windows/bench-frame-pacing.ps1 measures bench-windows.ps1's
# frame_time_p95_ms with a fresh portable copy of the receipt-bound measurement build per run, its shell the copy's
# config's cmd.exe, timed from the copy's own render trace; bench-windows.ps1 -Metric frame-pacing delegates to it.
# Pinned here: what the harness may do and that its run-time checks are called (patterns over its code with the
# comments removed, each with a mutation that must fail it); that its shared pieces are #739's
# (hidden-win11-working-set.ps1) and bench-windows.ps1's byte for byte; its pure functions run on synthetic inputs with
# controls (the config, the argv, the visible part's refusal, the record verdict, the interval statistics, the
# workload hash, the marker frame); the trace protocol's constants against the Zig source; and its native layer's
# struct layout and launch-desktop rules (compiled; every launch names an executable that does not exist). No noctty
# is started.
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
        Description = 'the driver evaluates the visible part''s preconditions on its own session right before the launch: a dry run must be refused, a visible run must not be'
        Pattern = '(?s)\$facts = Get-FramePacingSessionFacts \$MinIdleSeconds \$QuietSinceTick\s+\$record\.Composition = \$facts\.Composition\s+\$record\.VisibleRefusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$Visible -and \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}\s+if \(-not \$Visible -and -not \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}.*?\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('if (-not $Visible -and -not $record.VisibleRefusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run whose preconditions fail on the driver''s session starts nothing'
        Pattern = '(?s)\$record\.VisibleRefusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$Visible -and \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}.*?\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('if ($Visible -and $record.VisibleRefusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the visible part''s preconditions are read after the quiet-machine wait, not before it'
        Pattern = '(?s)\$record\.QuietWaitMs = \$quietClock\.ElapsedMilliseconds\s+\}\s+\$record\.TimerResolutionBefore100ns = .*?\$facts = Get-FramePacingSessionFacts \$MinIdleSeconds \$QuietSinceTick'
        Mutation = @('$record.QuietWaitMs = $quietClock.ElapsedMilliseconds', '$record.QuietWaitMs = 0')
    }
    @{
        Description = 'the outer half refuses -Visible off an unlocked, composed, local, idle Default before it creates anything, and keeps the tick it saw idle'
        Pattern = '(?s)\$quietSince = \[long\]-1\s+if \(\$Visible\) \{\s+\$facts = Get-FramePacingSessionFacts \$MinIdleSeconds -1\s+\$refusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$refusal\) \{ throw [^\r\n]+\}\s+\$quietSince = \[long\]\$facts\.LastInputTick\s+\}.*?\[void\]\(New-Item -ItemType Directory -Path \$root\)'
        Mutation = @('if ($refusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run waits for a machine under 30% busy (MEASUREMENT-HARNESS-RERUN-01)'
        Pattern = '(?s)if \(\$Visible\) \{\s+\$quietClock = \[Diagnostics\.Stopwatch\]::StartNew\(\)\s+while \(\(\$record\.BusyPercentBefore -lt 0 -or \$record\.BusyPercentBefore -ge \$script:QuietBusyPercent\) -and \$quietClock\.ElapsedMilliseconds -lt \[long\]\$QuietWaitSeconds \* 1000\) \{'
        Mutation = @('-ge $script:QuietBusyPercent) -and $quietClock', '-ge 100) -and $quietClock')
    }
    @{
        Description = 'only a visible run takes the foreground; a dry run records it as skipped'
        Pattern = '(?s)if \(\$Visible\) \{\s+\$record\.Foreground = \[FramePacingNative\]::Foreground\(\$hostWindow, \$nocttyPid, \$script:ForegroundBoundMs\).*?\} else \{ \$record\.Foreground = ''skipped'' \}'
        Mutation = @("} else { `$record.Foreground = 'skipped' }", "} else { `$record.Foreground = [FramePacingNative]::Foreground(`$hostWindow, `$nocttyPid, `$script:ForegroundBoundMs) }")
    }
    @{
        Description = 'a visible run whose foreground did not take is not measured'
        Pattern = 'if \(-not \[string\]::Equals\(\[string\]\$record\.Foreground, ''ok'', \[StringComparison\]::Ordinal\)\) \{ throw "INCONCLUSIVE: '
        Mutation = @("if (-not [string]::Equals([string]`$record.Foreground, 'ok', [StringComparison]::Ordinal)) { throw `"INCONCLUSIVE: ", "if (`$false) { throw `"INCONCLUSIVE: ")
    }
    @{
        Description = 'the foreground call is bounded: the window must be this copy''s, not hung and answer WM_NULL first, and the calls run on a worker joined within the bound (VISIBLE-PACING-CERT-01 trap 1)'
        Pattern = '(?s)public static string Foreground\(IntPtr hwnd, int pid, int boundMs\) \{\s+if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(IsHungAppWindow\(hwnd\) \|\| !Responsive\(hwnd, \(uint\)boundMs\)\) return "hung";.*?worker\.IsBackground = true;\s+worker\.Start\(\);\s+if \(!worker\.Join\(boundMs\)\) return "timeout";'
        Mutation = @('if (!worker.Join(boundMs)) return "timeout";', 'worker.Join();')
    }
    @{
        Description = 'the foreground call refuses a hung or unresponsive window before any cross-thread call'
        Pattern = '(?s)public static string Foreground\(IntPtr hwnd, int pid, int boundMs\) \{\s+if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(IsHungAppWindow\(hwnd\) \|\| !Responsive\(hwnd, \(uint\)boundMs\)\) return "hung";'
        Mutation = @('if (IsHungAppWindow(hwnd) || !Responsive(hwnd, (uint)boundMs)) return "hung";', '')
    }
    @{
        Description = 'the foreground is unlocked by one zero-motion mouse input, never an Alt tap (PROBE-ALT-TAP-01), and only when SendInput inserted it'
        Pattern = 'var nudge = new Input\[\] \{ new Input \{ type = 0 \} \};\s+nudge\[0\]\.mouse\.flags = 0x0001;[^\r\n]*\s+if \(SendInput\(1, nudge, Marshal\.SizeOf<Input>\(\)\) != 1\) \{ outcome = "unlock-not-inserted"; return; \}'
        Mutation = @('new Input { type = 0 }', 'new Input { type = 1 }')
    }
    @{
        Description = 'a visible run counts only with the foreground, the pane''s focus and the session''s last input unchanged from the arm to the end marker''s swap'
        Pattern = '(?s)\$focusChanges = \[uint64\]\$echoed\.surface_focus_change_count\s+\$inputTick = \[FramePacingNative\]::LastInputTick\(\).*?\$record\.ForegroundHeld = \[FramePacingNative\]::IsForeground\(\$hostWindow\)\s+\$record\.FocusHeld = \[bool\]\$presented\.surface_focused -and \[uint64\]\$presented\.surface_focus_change_count -eq \$focusChanges\s+\$record\.InputDuringRun = \[FramePacingNative\]::LastInputTick\(\) -ne \$inputTick'
        Mutation = @('$record.InputDuringRun = [FramePacingNative]::LastInputTick() -ne $inputTick', '$record.InputDuringRun = $false')
    }
    # --- the copy's launch
    @{
        Description = 'the copy''s argv is exactly the expected list, on the final command line and on the copy''s own command line read back by PID'
        Pattern = '(?s)\$expectedArgv = Get-FramePacingExpectedArgv \$exe "noctty-interactive-\$\(\$layout\.SandboxId\)" \$configPath\s+if \(-not \(Test-WorkingSetArgv \(\[FramePacingNative\]::SplitCommandLine\(\$commandLine\)\) \$expectedArgv\)\) \{ throw .*?\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine, .*?\$launchedLine = \[string\]\(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = \$nocttyPid" -ErrorAction Stop\)\.CommandLine\s+if \(-not \(Test-WorkingSetArgv \(\[FramePacingNative\]::SplitCommandLine\(\$launchedLine\)\) \$expectedArgv\)\) \{ throw '
        Mutation = @('if (-not (Test-WorkingSetArgv ([FramePacingNative]::SplitCommandLine($launchedLine)) $expectedArgv)) { throw', 'if ($false) { throw')
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
        Pattern = '\$env:GHOSTTY_LOG = ''stderr''\s+\$env:NOCTTY_RENDER_TRACE_FILE = \$tracePath\s+\$env:NOCTTY_RENDER_TRACE_LIVE = ''1''\s+\$env:NOCTTY_BENCH_END_MARKER = \$marker\s+\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine, \$work, \$desktopPath, \(Join-Path \$Run ''noctty\.log''\), \$false, \[bool\]\$Visible\)'
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
        Description = 'a visible series'' later runs check the session''s input against the tick the last run saw after its own unlock'
        Pattern = '(?s)\$result = Invoke-FramePacingOuterRun \$build \(Join-Path \$root "run-\$i"\) \$quietSince\s+\$results\.Add\(\$result\)\s+if \(\$Visible -and \$null -ne \$result\.Record -and \$null -ne \$result\.Record\.InputTick\) \{ \$quietSince = \[long\]\$result\.Record\.InputTick \}.*?-QuietSinceTick \{10\}'' -f `\s+[^\r\n]+\$QuietWaitSeconds, \$QuietSince'
        Mutation = @('{ $quietSince = [long]$result.Record.InputTick }', '{ }')
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
        Description = 'frame_time_p95_ms is published only for a visible series whose every run completed; a dry run''s p95 is dry_run_p95_ms'
        Pattern = 'frame_time_p95_ms = \$\(if \(\$Visible -and \$completed\.Count -eq \$Runs\) \{ \$p95 \} else \{ \$null \}\)'
        Mutation = @('if ($Visible -and $completed.Count -eq $Runs) { $p95 }', 'if ($completed.Count -eq $Runs) { $p95 }')
    }
    @{
        Description = 'the pooled samples come only from completed runs'
        Pattern = '\$pooled = \[double\[\]\]@\(\$completed \| ForEach-Object \{ @\(\$_\.Record\.IntervalsMs\) \}'
        Mutation = @('$pooled = [double[]]@($completed | ForEach-Object', '$pooled = [double[]]@($Results | ForEach-Object')
    }
    @{
        Description = 'the exit code says why the series stopped: 3 a tripped guard, 2 an inconclusive visible run, 1 any other failure'
        Pattern = 'switch \(\$last\.Status\) \{ ''guard-tripped'' \{ return 3 \} ''inconclusive'' \{ return 2 \} default \{ return 1 \} \}'
        Mutation = @("'guard-tripped' { return 3 }", "'guard-tripped' { return 1 }")
    }
    @{
        Description = 'completed runs that differ in WorkloadSha256 fail the summary'
        Pattern = 'if \(\$completed\.Count -gt 1 -and \$workloads\.Count -ne 1\) \{ \$summary\.Error = '
        Mutation = @('if ($completed.Count -gt 1 -and $workloads.Count -ne 1) { $summary.Error =', 'if ($false) { $summary.Error =')
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
if (Test-FramePacingInputDiscipline ($framePacingText.Replace('if (SendInput(1, nudge,', 'SendInput(1, keys, 40); if (SendInput(1, nudge,'))) { throw 'The input discipline check accepted a second SendInput.' }

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
        Description = 'bench-windows.ps1 -Metric frame-pacing delegates before its history guard and bootstrap, refuses other targets and parameters, and exits with the harness''s code'
        Pattern = '(?s)\[switch\] \$Visible\s+\)\s+if \(\$Metric -eq ''frame-pacing''\) \{\s+if \(\$Target -ne ''noctty''\) \{ throw [^\r\n]+\}\s+\$pacingParameters = @\(''Metric'', ''Target'', ''Runs'', ''MeasureRepo'', ''RunRoot'', ''Visible''\)\s+\$foreignParameters = @\(\$PSBoundParameters\.Keys \| Where-Object \{ \$pacingParameters -notcontains \$_ \}\)\s+if \(\$foreignParameters\.Count -ne 0\) \{ throw [^\r\n]+\}\s+\$pacingArguments = @\{ MeasureRepo = \$MeasureRepo; RunRoot = \$RunRoot; Runs = \$Runs; Visible = \$Visible \}\s+& \(Join-Path \$PSScriptRoot ''bench-frame-pacing\.ps1''\) @pacingArguments\s+exit \$LASTEXITCODE\s+\}.*?Start-WindowsHarnessHistoryGuard -Harness ''bench-windows\.ps1''.*?Invoke-InteractiveWin11Bootstrap'
        Mutation = @('if ($foreignParameters.Count -ne 0) { throw', 'if ($false) { throw')
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
$framePacingConstantNames = @('Cols', 'Rows', 'GridRows', 'FontFamily', 'FontSize', 'PayloadWorkload', 'PayloadBytes', 'PayloadSeed', 'IntervalCapacity', 'QuietMs', 'EchoQuietMs', 'QuietBusyPercent')
$framePacingConstantLines = foreach ($name in $framePacingConstantNames) {
    $line = [regex]::Match($framePacingText, "(?m)^\`$script:$name = (\d+|'[A-Za-z]+')[ \t]*$").Value.Trim()
    if (-not $line) { throw "The frame-pacing harness has no `$script:$name = <constant> line." }
    $line
}
$framePacingPinned = 'Cols=140 Rows=45 GridRows=43 FontFamily=Consolas FontSize=16 PayloadWorkload=stream PayloadBytes=4194304 PayloadSeed=121 IntervalCapacity=2048 QuietMs=1000 EchoQuietMs=500 QuietBusyPercent=30'
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
        foreach ($name in @('New-FramePacingConfigText', 'Test-FramePacingConfigBytes', 'Get-FramePacingExpectedArgv', 'Test-WorkingSetArgv', 'Get-FramePacingVisibleRefusal', 'Get-FramePacingRecordProblems', 'Get-FramePacingRunStatus', 'Get-FramePacingIntervalStats', 'Get-BenchMedian', 'Get-BenchPercentile', 'Get-FramePacingMarkerTail', 'Get-FramePacingWorkloadSha256', 'Get-BytesSha256')) {
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
            $keybinds = @($lines | Where-Object { $_ -match '^\s*keybind\s*=' })
            if ($keybinds.Count -ne 17 -or -not (Test-FramePacingOrdinal $keybinds[0] 'keybind = clear')) { return $false }
            foreach ($bind in $keybinds[1..16]) { if ($bind -cnotmatch '^keybind = (?:(?:ctrl|alt|shift)\+)*f[56]=text:(?:type stream\.bin|\\r)$') { return $false } }
            return $true
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
        $cases.Add('config (shape: initial-command, no /D, PowerShell, clipboard allowed, copy binding, D3D11, binding before clear; bytes: exact, other run, added line)')

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
        $ok = [pscustomobject]@{ OwnDesktop = 'Default'; InputDesktop = 'Default'; Composition = 1; RemoteSession = $false; IdleMs = 400000; MinIdleMs = 300000; LastInputTick = 77; QuietSinceTick = -1 }
        if ($null -ne (Get-FramePacingVisibleRefusal $ok)) { throw 'The visible check refused an idle, unlocked, composed local Default.' }
        $refusals = @(
            @{ Name = 'a private desktop'; Facts = @{ OwnDesktop = 'noctty-fp-1' } }
            @{ Name = 'a locked session'; Facts = @{ InputDesktop = $null } }
            @{ Name = 'another input desktop'; Facts = @{ InputDesktop = 'Winlogon' } }
            @{ Name = 'no composition'; Facts = @{ Composition = 0 } }
            @{ Name = 'an unreadable composition'; Facts = @{ Composition = -1 } }
            @{ Name = 'a remote session'; Facts = @{ RemoteSession = $true } }
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
        $cases.Add('visible-refusal (idle Default; private, locked, other input desktop, no or unreadable composition, remote, recent or unreadable input, input since the series'' tick; a later run after its own unlock; idle and tick controls)')

        # The record verdict: a complete dry run and a complete visible run count; each broken field is a problem;
        # the visible run's environment problems are only "inconclusive:".
        $intervals = [double[]]@(4.1, 4.2, 4.3)
        $base = @{ Schema = 1; Mode = 'dry-run'; Error = $null; Exit = 0; QuitPosts = 1; GridCols = 140; GridRows = 43; Transport = 'bundled'; Renderer = 'opengl'
            LaunchConfigDefaultFiles = $false; LaunchConfigFile = 'C:\c\config.ghostty'; ConptyDllSHA256 = 'aa'; PrefixConptyDllSHA256 = 'aa'; OpenConsoleSHA256 = 'bb'; PrefixOpenConsoleSHA256 = 'bb'
            PowerShellUnderCopy = 0; EndMarkerPresented = $true; IntervalOverflow = 0; IntervalCount = 3; IntervalsMs = $intervals
            VisibleRefusal = 'this process is not on Default'; Foreground = 'skipped'; Cloaked = $null; ForegroundHeld = $false; FocusHeld = $true; InputDuringRun = $false; BusyPercentBefore = 50.0; RefreshHz = 240 }
        function Join-FramePacingChange([hashtable] $A, [hashtable] $B) { $r = $A.Clone(); foreach ($k in $B.Keys) { $r[$k] = $B[$k] }; return $r }
        function New-FramePacingRecord([hashtable] $Change) { return [pscustomobject](Join-FramePacingChange $base $Change) }
        $visibleOk = @{ Mode = 'visible'; VisibleRefusal = $null; Foreground = 'ok'; Cloaked = 0; ForegroundHeld = $true; FocusHeld = $true; InputDuringRun = $false; BusyPercentBefore = 10.0 }
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
            [IO.File]::WriteAllText($one, (New-FramePacingConfigText 'C:\runs\a\run-1'), $script:Utf8)
            [IO.File]::WriteAllText($two, (New-FramePacingConfigText 'D:\other\b\run-7'), $script:Utf8)
            $h1 = Get-FramePacingWorkloadSha256 'p' $one 'C:\runs\a\run-1'
            $h2 = Get-FramePacingWorkloadSha256 'p' $two 'D:\other\b\run-7'
            if (-not (Test-FramePacingOrdinal $h1 $h2)) { throw 'The workload hash depends on the run''s directory.' }
            if (Test-FramePacingOrdinal $h1 (Get-FramePacingWorkloadSha256 'q' $one 'C:\runs\a\run-1')) { throw 'The workload hash ignores the payload.' }
            $script:FontSize = 17
            try { if (Test-FramePacingOrdinal $h1 (Get-FramePacingWorkloadSha256 'p' $one 'C:\runs\a\run-1')) { throw 'The workload hash ignores a constant.' } } finally { $script:FontSize = 16 }
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
# layout string the harness checks at run time. The controls: a changed field in INPUT's MOUSEINPUT and in
# LASTINPUTINFO, compiled the same way, must give another layout.
$framePacingNative = @($framePacingAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class FramePacingNative' }, $true))
if ($framePacingNative.Count -ne 1) { throw 'The frame-pacing harness must hold one FramePacingNative source.' }
$framePacingLayoutWanted = [regex]::Match($framePacingText, "\`$script:SdkLayout = '([^']+)'").Groups[1].Value
if (-not (Test-FramePacingOrdinal $framePacingLayoutWanted 'Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8 Input=40 mouse@8 MouseInput=32 mouseFlags@12 LastInput=8')) {
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
        if (-not $got.Contains("A child must start on the caller's own desktop")) { throw "Spawn did not refuse another desktop (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::Spawn($missingExe, '"x"', $launchDir, $foreign, $launchLog, $true, $true) }
        if (-not $got.Contains("A child must start on the caller's own desktop")) { throw "A visible Spawn did not refuse another desktop (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, 'WinSta0\Default', [IntPtr]::Zero, $false) }
        if (-not $got.Contains('The driver must start on a private desktop')) { throw "A dry run's LaunchDriver did not refuse Default (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, "WinSta0\$framePacingOwn", [IntPtr]::Zero, $false) }
        if (-not $got.Contains('The driver must start on a private desktop')) { throw "A dry run's LaunchDriver did not refuse the caller's own desktop (got: $got)." }
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, $foreign, [IntPtr]::Zero, $true) }
        if (-not $got.Contains('A visible driver starts only on Default')) { throw "A visible LaunchDriver did not refuse a private desktop (got: $got)." }
        # The controls: a private desktop's name passes a dry run's driver check, and on an unlocked Default the
        # visible driver's and child's checks pass; each then reaches CreateProcess, which fails on the missing
        # executable. On Default a dry run's child is refused there.
        $got = Get-FramePacingLaunchRefusal { $framePacingProbe::LaunchDriver($missingExe, '"x"', $launchDir, $foreign, [IntPtr]::Zero, $false) }
        $wantControl = if ($null -eq $framePacingInput) { 'The driver must start on a private desktop' } else { 'CreateProcess failed' }
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
Write-Host "Frame-pacing harness contract: $framePacingMutations rules, each with a rejected mutation; $framePacingSharedCount shared pieces identical to #739's and bench-windows.ps1's; input discipline (controls: a second foreground, a second SendInput); forbidden forms ($($framePacingForbidden.Count), each caught); trace protocol against consts.zig, render_trace.zig and bench_marker.zig; constants pinned; $($framePacingCases -join '; '); native layout $framePacingLayout (2 controls); desktop assignments (control); $framePacingDesktopCase"
