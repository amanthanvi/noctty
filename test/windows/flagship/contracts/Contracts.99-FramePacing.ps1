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
        Pattern = '(?s)function Invoke-FramePacingOuterRun\(\$build, \[string\] \$Run, \[long\] \$QuietSince, \[string\] \$WatchEvent, \[long\] \$LockNeededMs, \[long\] \$InputMarker\) \{\s+\$stagingClock = \[Diagnostics\.Stopwatch\]::StartNew\(\).*?Where-Object \{ \$_\.Name -notin @\(''noctty\.ico'', ''crash'', ''ghostty''\) \}.*?if \(Test-Path -LiteralPath \(Join-Path \$copy ''noctty\.ico''\)\) \{ throw [^\r\n]+\}\s+if \(-not \(Test-WorkingSetCopy \$copy \$build\)\) \{ throw [^\r\n]+\}\s+\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @('if (-not (Test-WorkingSetCopy $copy $build)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run whose staging and guard setup ran past their bound launches no driver, and the run is inconclusive (Sol on #741)'
        Pattern = '(?s)if \(\$Visible -and \$stagingClock\.ElapsedMilliseconds -gt \$script:StagingBoundMs\) \{ \$notLaunched = "[^\r\n]+" \}\s+if \(\$Visible -and -not \$notLaunched\) \{\s+\$notLaunched = Test-FramePacingInputGate [^\r\n]+\s+\}\s+if \(\$notLaunched\) \{ throw "INCONCLUSIVE: \$notLaunched\." \}\s+\$pi = \[FramePacingNative\]::LaunchDriver\('
        Mutation = @('if ($Visible -and $stagingClock.ElapsedMilliseconds -gt $script:StagingBoundMs) { $notLaunched =', 'if ($false) { $notLaunched =')
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
        Pattern = '(?s)\$facts = Get-FramePacingSessionFacts \$QuietSinceTick \$ForegroundLockNeededMs [^\r\n]+\s+\$record\.Composition = \$facts\.Composition\s+\$record\.NotificationState = \$facts\.NotificationState\s+\$record\.ForegroundLockTimeoutMs = \$facts\.ForegroundLockTimeoutMs\s+\$record\.VisibleRefusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$Visible -and \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}\s+if \(-not \$Visible -and -not \$record\.VisibleRefusal\) \{ throw [^\r\n]+\}.*?Assert-Quiet ''\+version''\s+\$check = \[FramePacingNative\]::Spawn\('
        Mutation = @('if (-not $Visible -and -not $record.VisibleRefusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run whose preconditions fail on the driver''s session launches nothing, not even +version'
        Pattern = '(?s)\$record\.VisibleRefusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$Visible -and \$record\.VisibleRefusal\) \{ throw "INCONCLUSIVE: [^\r\n]+\}.*?\$check = \[FramePacingNative\]::Spawn\('
        Mutation = @('if ($Visible -and $record.VisibleRefusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the visible part''s preconditions are read after the quiet-machine wait, not before it'
        Pattern = '(?s)\$record\.QuietWaitMs = \$quietClock\.ElapsedMilliseconds\s+if [^\r\n]+\}\s+\}\s+\$record\.TimerResolutionBefore100ns = .*?\$facts = Get-FramePacingSessionFacts \$QuietSinceTick \$ForegroundLockNeededMs'
        Mutation = @('$record.QuietWaitMs = $quietClock.ElapsedMilliseconds', '$record.QuietWaitMs = 0')
    }
    @{
        Description = 'a visible run whose quiet wait expired without a reading under 30% launches nothing (Sol and CodeRabbit on #741)'
        Pattern = '(?s)\$record\.QuietWaitMs = \$quietClock\.ElapsedMilliseconds\s+if \(\$record\.BusyPercentBefore -lt 0 -or \$record\.BusyPercentBefore -ge \$script:QuietBusyPercent\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\}.*?Assert-Quiet ''\+version'''
        Mutation = @('{ throw "INCONCLUSIVE: the machine was not under', '{ Log "INCONCLUSIVE: the machine was not under')
    }
    @{
        Description = 'the outer half refuses -Visible off an unlocked, composed, local, idle Default before it creates anything, keeps the tick it saw idle, its idle time and a clock from then, and draws the series'' marker'
        Pattern = '(?s)\$quietSince = \[long\]-1\s+\$watchEvent = \$null\s+\$lockNeeded = \[long\]-1\s+\$inputMarker = \[long\]0\s+\$admissionIdleMs = \[long\]-1\s+\$seriesClock = \[Diagnostics\.Stopwatch\]::StartNew\(\)\s+\$harnessSha256 = Get-FramePacingLoadedHarnessSha256\s+if \(\$Visible\) \{\s+\$facts = Get-FramePacingSessionFacts -1 -1 \$null\s+\$lockNeeded = Get-FramePacingLockNeedMs \$facts\.IdleMs \$facts\.MinIdleMs \$Runs\s+\$facts\.ForegroundLockNeededMs = \$lockNeeded\s+Write-Host [^\r\n]+\s+\$refusal = Get-FramePacingVisibleRefusal \$facts\s+if \(\$refusal\) \{ throw [^\r\n]+\}\s+\$quietSince = \[long\]\$facts\.LastInputTick\s+\$admissionIdleMs = \[long\]\$facts\.IdleMs\s+\$seriesClock\.Restart\(\)\s+\$watchEvent = [^\r\n]+\s+\$inputMarker = New-FramePacingInputMarker\s+\}.*?\[void\]\(New-Item -ItemType Directory -Path \$root\)'
        Mutation = @('if ($refusal) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the series'' marker is random, nonzero (Opus on #741: a zero extra info must never match) and within 31 bits (UNLOCK-HOOK-01: an injected mouse event''s extra info reaches the hook with only its low 32 bits)'
        Pattern = 'function New-FramePacingInputMarker \{\s+\$bytes = \[byte\[\]\]::new\(4\)\s+do \{ \[Security\.Cryptography\.RandomNumberGenerator\]::Fill\(\$bytes\); \$marker = \[long\]\(\[BitConverter\]::ToUInt32\(\$bytes, 0\) -band 0x7FFFFFFF\) \} while \(\$marker -eq 0\)\s+return \$marker\s+\}'
        Mutation = @(' } while ($marker -eq 0)', ' } while ($false)')
    }
    @{
        Description = 'the visible series'' input watch starts before anything is staged, with the series'' marker, refuses the series when the hooks do not install, checks the series'' first run, and is stopped whenever the series may have started it, a refused start included (the lead, Sol and CodeRabbit on #741)'
        Pattern = '(?s)if \(\$Visible\) \{\s+\[FramePacingNative\]::ResetWatchCounts\(\)\s+Start-FramePacingInputWatch \{ param\(\[string\] \$Name\) \[FramePacingNative\]::StartWatch\(\$Name, 5000, \[IntPtr\]\$inputMarker\) \} \$watchEvent\s+\$break = Test-FramePacingInputGate \(New-FramePacingOuterPort\) [^\r\n]+\s+if \(\$break\) \{ throw [^\r\n]+\}\s+\}.*?\[void\]\(New-Item -ItemType Directory -Path \$root\).*?finally \{\s+if \(\$Visible -and -not \[FramePacingNative\]::StopWatch\(\)\) \{ Write-Host [^\r\n]+\}'
        Mutation = @('if ($Visible -and -not [FramePacingNative]::StopWatch()) {', 'if ($false) {')
    }
    @{
        Description = 'a hook that fails to install refuses -Visible, with no fallback to the tick alone'
        Pattern = 'function Start-FramePacingInputWatch\(\[scriptblock\] \$Start, \[string\] \$EventName\) \{\s+if \(-not \(& \$Start \$EventName\)\) \{ throw ''-Visible is refused: [^\r\n]+\}\s+\}'
        Mutation = @('if (-not (& $Start $EventName)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the outer half''s gate runs before the series'' first run'
        Pattern = '(?s)\[FramePacingNative\]::StartWatch\(\$Name, 5000, \[IntPtr\]\$inputMarker\) \} \$watchEvent\s+\$break = Test-FramePacingInputGate \(New-FramePacingOuterPort\) [^\r\n]+\s+if \(\$break\) \{ throw "-Visible is refused: \$break\." \}'
        Mutation = @('if ($break) { throw "-Visible is refused: $break." }', '')
    }
    @{
        Description = 'a visible driver opens the series'' three watches before anything is launched, and starts nothing without them or the marker; every handle is set before the try that closes it (Greptile and CodeRabbit on #741)'
        Pattern = '(?s)\$process = \[IntPtr\]::Zero\s+\$watch = \[IntPtr\]::Zero\s+\$mouseWatch = \[IntPtr\]::Zero\s+\$keyWatch = \[IntPtr\]::Zero\s+try \{.*?\$desktopPath = "WinSta0\\\$DesktopName"\s+if \(\$Visible\) \{\s+if \(\[string\]::IsNullOrEmpty\(\$InputWatchEvent\)\) \{ throw [^\r\n]+\}\s+\$watch = \[FramePacingNative\]::OpenWatch\(\$InputWatchEvent\)\s+if \(\$watch -eq \[IntPtr\]::Zero\) \{ throw [^\r\n]+\}\s+\$mouseWatch = \[FramePacingNative\]::OpenMouseWatch\(\$InputWatchEvent\)\s+\$keyWatch = \[FramePacingNative\]::OpenKeyWatch\(\$InputWatchEvent\)\s+if \(\$mouseWatch -eq \[IntPtr\]::Zero -or \$keyWatch -eq \[IntPtr\]::Zero\) \{ throw [^\r\n]+\}\s+if \(\$InputMarker -eq 0\) \{ throw [^\r\n]+\}\s+\}\s+\$port = New-FramePacingPort \$watch \$mouseWatch \$keyWatch \$InputMarker.*?Assert-Quiet ''\+version'''
        Mutation = @("if (`$watch -eq [IntPtr]::Zero) { throw 'The visible driver cannot open", "if (`$false) { throw 'The visible driver cannot open")
    }
    @{
        Description = 'a visible driver that cannot open the marked-input watches, or has no marker, starts nothing (CodeRabbit, Opus and the lead on #741)'
        Pattern = 'if \(\$mouseWatch -eq \[IntPtr\]::Zero -or \$keyWatch -eq \[IntPtr\]::Zero\) \{ throw ''The visible driver cannot open the series'''' marked-input watches; it starts nothing\.'' \}\s+if \(\$InputMarker -eq 0\) \{ throw '
        Mutation = @('if ($mouseWatch -eq [IntPtr]::Zero -or $keyWatch -eq [IntPtr]::Zero) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the driver''s port hands the native foreground the watch, the mouse watch and the marker, and the native key probe the watch, the key watch and the marker'
        Pattern = '(?s)\$outcome = \[FramePacingNative\]::Foreground\(\$HostWindow, \$OwnerPid, \$BoundMs, \$ExpectedTick, \$this\.Watch, \$this\.MouseWatch, \[IntPtr\]\$this\.Marker, \[ref\]\$unlock\).*?\$outcome = \[FramePacingNative\]::KeyProbe\(\$HostWindow, \$OwnerPid, \$BoundMs, \$ExpectedTick, \$this\.Watch, \$this\.KeyWatch, \[IntPtr\]\$this\.Marker, \[ref\]\$tick\)'
        Mutation = @('$this.MouseWatch, [IntPtr]$this.Marker, [ref]$unlock', '$this.MouseWatch, [IntPtr]::Zero, [ref]$unlock')
    }
    @{
        Description = 'a mouse hook that never saw the harness''s own unlock, or a keyboard hook that never saw its key probe, refuses the run outright, never only inconclusive (CodeRabbit and the lead on #741)'
        Pattern = '(?s)\$script:MouseHookMissed = ''The input watch''''s mouse hook did not see the harness''''s own unlock[^\r\n]+\s+\$script:KeyHookMissed = ''The input watch''''s keyboard hook did not see the harness''''s own key probe[^\r\n]+.*?if \(\[string\]::Equals\(\[string\]\$result\.Outcome, ''unlock-not-seen-by-hook'', \[StringComparison\]::Ordinal\)\) \{ throw \$script:MouseHookMissed \}\s+return \[string\]\$result\.Outcome.*?if \(\[string\]::Equals\(\[string\]\$result\.Outcome, ''key-probe-not-seen-by-hook'', \[StringComparison\]::Ordinal\)\) \{ throw \$script:KeyHookMissed \}\s+return \[string\]\$result\.Outcome'
        Mutation = @("if ([string]::Equals([string]`$result.Outcome, 'key-probe-not-seen-by-hook', [StringComparison]::Ordinal)) { throw", "if (`$false) { throw")
    }
    @{
        Description = 'the keyboard probe runs behind the gate, with the tick the run expects, and its own tick becomes the one the run expects (the lead on #741)'
        Pattern = 'function Invoke-FramePacingKeyProbe\(\$Port, \$Ticks, \[IntPtr\] \$HostWindow, \[int\] \$NocttyPid\) \{\s+Assert-FramePacingInputGate \$Port \$Ticks ''the keyboard probe''\s+\$result = \$Port\.KeyProbe\(\$HostWindow, \$NocttyPid, \$script:ForegroundBoundMs, \[long\]\$Ticks\.Unlock\)\s+if \(\[long\]\$result\.ProbeTick -ge 0\) \{ \$Ticks\.Unlock = \[long\]\$result\.ProbeTick \}'
        Mutation = @("Assert-FramePacingInputGate `$Port `$Ticks 'the keyboard probe'", '')
    }
    @{
        Description = 'the outer half''s gate runs before each visible driver''s launch, and a break, a staging overrun or a job closed on real input is inconclusive when it is the run''s only problem (CodeRabbit, Opus and Sol on #741)'
        Pattern = '(?s)if \(\$Visible -and -not \$notLaunched\) \{\s+\$notLaunched = Test-FramePacingInputGate \(New-FramePacingOuterPort\) [^\r\n]+\s+\}\s+if \(\$notLaunched\) \{ throw "INCONCLUSIVE: \$notLaunched\." \}\s+\$pi = \[FramePacingNative\]::LaunchDriver\(.*?\$stop = if \(\$notLaunched\) \{ [^\r\n]+ \} elseif \(\$inputStopped\) \{ \$inputStopped \} else \{ \$null \}\s+\$stopFailure = Get-FramePacingInputStop \$guardFailures \$outerFailures \$\(if \(\$notLaunched\) \{ \$outerError \} else \{ \$null \}\) \$stop \(Test-FramePacingHookMissed \$driverError\)\s+if \(\$stopFailure\) \{ \$status = ''inconclusive''; \$outerFailures = @\(\$stopFailure\); \$problems = @\(\) \}'
        Mutation = @('if ($notLaunched) { throw "INCONCLUSIVE: $notLaunched." }', '')
    }
    @{
        Description = 'the native key probe and unlock keep the tick their input moved as the harness''s own before the hook''s verdict can return early, so a dead hook is never read as a user''s input (Greptile on #741)'
        Pattern = '(?s)long now = WaitTickMove\(before, 1000\);(?:\s+//[^\r\n]*)*\s+if \(now >= 0 && now != before\) tick = now;\s+bool hookSaw = WaitForSingleObject\(mouse, 1000\) == 0;\s+if \(\(outcome = ProbeSeen\("unlock", before, now, hookSaw\)\) != null\) return;.*?long now = WaitTickMove\(before, 1000\);(?:\s+//[^\r\n]*)*\s+if \(now >= 0 && now != before\) tick = now;\s+bool hookSaw = WaitForSingleObject\(key, 1000\) == 0;\s+if \(\(outcome = ProbeSeen\("key-probe", before, now, hookSaw\)\) != null\) return;'
        Mutation = @('if (now >= 0 && now != before) tick = now;', '')
    }
    @{
        Description = 'a run a hook-miss refusal failed stays failed whatever input stop follows (Greptile on #741)'
        Pattern = '\$stopFailure = Get-FramePacingInputStop \$guardFailures \$outerFailures \$\(if \(\$notLaunched\) \{ \$outerError \} else \{ \$null \}\) \$stop \(Test-FramePacingHookMissed \$driverError\)'
        Mutation = @('$stop (Test-FramePacingHookMissed $driverError)', '$stop $false')
    }
    @{
        Description = 'only the deliberate no-launch refusal may stand beside an input stop: a driver deadline and input during its cleanup stays failed (CodeRabbit on #741)'
        Pattern = 'Get-FramePacingInputStop \$guardFailures \$outerFailures \$\(if \(\$notLaunched\) \{ \$outerError \} else \{ \$null \}\) \$stop'
        Mutation = @('$(if ($notLaunched) { $outerError } else { $null }) $stop', '$outerError $stop')
    }
    @{
        Description = 'a driver''s poll reads the gate once through Assert-FramePacingPollGate, which latches a mismatch and never rereads it (the lead and Sol on #741, round 8)'
        Pattern = 'function Assert-QuietPoll\(\[string\] \$During\) \{\s+if \(-not \$Visible\) \{ return \}\s+Assert-FramePacingPollGate \$port \$record\.InputTicks \$During\s+\}'
        Mutation = @('Assert-FramePacingPollGate $port $record.InputTicks $During', 'Assert-Quiet $During')
    }
    @{
        Description = 'the gate and the native workers latch every input observation into the run''s ticks, and the driver''s record starts unlatched (the lead and Sol on #741, round 8)'
        Pattern = '(?s)if \(\$real\) \{ \$Ticks\.Broken = \$true; return [^\r\n]+\}\s+if \(\$null -eq \$expected -or \[long\]\$expected -lt 0\) \{ \$Ticks\.Broken = \$true; return [^\r\n]+\}\s+if \(\$now -ne \[long\]\$expected\) \{ \$Ticks\.Broken = \$true; return [^\r\n]+\}.*?\$Ticks\.Unlock = \[long\]\$result\.UnlockTick \}\s+if \(\[string\]\$result\.Outcome -match ''\^\(real-\)\?input-''\) \{ \$Ticks\.Broken = \$true \}.*?\$Ticks\.Unlock = \[long\]\$result\.ProbeTick \}\s+if \(\[string\]\$result\.Outcome -match ''\^\(real-\)\?input-''\) \{ \$Ticks\.Broken = \$true \}.*?InputTicks = \[ordered\]@\{ Series = \$QuietSinceTick; Unlock = \$null; Broken = \$false; Checks = '
        Mutation = @('if ($now -ne [long]$expected) { $Ticks.Broken = $true; return', 'if ($now -ne [long]$expected) { return')
    }
    @{
        Description = 'each run carries its own input latch to the series: the outer half''s stop or gate break, or the driver''s latched ticks (the lead and Sol on #741, round 8)'
        Pattern = '\$notLaunched = Test-FramePacingInputGate \(New-FramePacingOuterPort\) \$outerTicks ''the visible driver''''s launch''(?s).*?\$inputSeen = Test-FramePacingRunInput \(\[bool\]\$inputStopped -or \[bool\]\$outerTicks\.Broken\) \$record\s+return \[pscustomobject\]@\{ Run = \$Run; Status = \$status; Failures = [^\r\n]+; Record = \$record; InputSeen = \$inputSeen \}'
        Mutation = @('$inputSeen = Test-FramePacingRunInput ([bool]$inputStopped -or [bool]$outerTicks.Broken) $record', '$inputSeen = $false')
    }
    @{
        Description = 'the series port reads the session''s real tick (Opus on #741, round 8: P13, the baseline returned, as the control)'
        Pattern = '-Name InjectedInputs -Value \{ \[FramePacingNative\]::InjectedInputs\(\) \}\s+Add-Member -InputObject \$port -MemberType ScriptMethod -Name LastInputTick -Value \{ param\(\$Ticks\) \(Read-FramePacingInputTick \$Ticks\)\.Tick \}'
        Mutation = @("-Name InjectedInputs -Value { [FramePacingNative]::InjectedInputs() }`n    Add-Member -InputObject `$port -MemberType ScriptMethod -Name LastInputTick -Value { param(`$Ticks) (Read-FramePacingInputTick `$Ticks).Tick }", "-Name InjectedInputs -Value { [FramePacingNative]::InjectedInputs() }`n    Add-Member -InputObject `$port -MemberType ScriptMethod -Name LastInputTick -Value { param(`$Ticks) `$quietSince }")
    }
    @{
        Description = 'the outer half''s port, which gates each launch, reads the hooks'' count and the session''s real tick (Opus on #741, round 8: P14, the baseline returned, as the control)'
        Pattern = 'function New-FramePacingOuterPort \{\s+\$port = \[pscustomobject\]@\{ Kind = ''outer'' \}\s+Add-Member -InputObject \$port -MemberType ScriptMethod -Name RealInputSeen -Value \{ \[FramePacingNative\]::RealInputs\(\) -gt 0 \}\s+Add-Member -InputObject \$port -MemberType ScriptMethod -Name LastInputTick -Value \{ param\(\$Ticks\) \(Read-FramePacingInputTick \$Ticks\)\.Tick \}'
        Mutation = @("-Name RealInputSeen -Value { [FramePacingNative]::RealInputs() -gt 0 }`n    Add-Member -InputObject `$port -MemberType ScriptMethod -Name LastInputTick -Value { param(`$Ticks) (Read-FramePacingInputTick `$Ticks).Tick }", "-Name RealInputSeen -Value { [FramePacingNative]::RealInputs() -gt 0 }`n    Add-Member -InputObject `$port -MemberType ScriptMethod -Name LastInputTick -Value { param(`$Ticks) `$QuietSince }")
    }
    @{
        Description = 'the driver''s port, which every driver gate and poll reads, reads the series'' real-input event and the session''s real tick (Opus on #741, round 8: P16, the gate''s own expectation returned, as the control)'
        Pattern = '\$port = \[pscustomobject\]@\{ Kind = ''native''; [^\r\n]+\}\s+Add-Member -InputObject \$port -MemberType ScriptMethod -Name RealInputSeen -Value \{ \[FramePacingNative\]::RealInputSignalled\(\$this\.Watch\) \}\s+Add-Member -InputObject \$port -MemberType ScriptMethod -Name LastInputTick -Value \{ param\(\$Ticks\) \(Read-FramePacingInputTick \$Ticks\)\.Tick \}'
        Mutation = @("-Name RealInputSeen -Value { [FramePacingNative]::RealInputSignalled(`$this.Watch) }`n    Add-Member -InputObject `$port -MemberType ScriptMethod -Name LastInputTick -Value { param(`$Ticks) (Read-FramePacingInputTick `$Ticks).Tick }", "-Name RealInputSeen -Value { [FramePacingNative]::RealInputSignalled(`$this.Watch) }`n    Add-Member -InputObject `$port -MemberType ScriptMethod -Name LastInputTick -Value { param(`$Ticks) if (`$null -ne `$Ticks.Unlock) { `$Ticks.Unlock } else { `$Ticks.Series } }")
    }
    @{
        Description = 'the silence check edits the run''s own result, so no field, its input latch among them, is lost (Opus on #741, round 9: a rebuild that drops the copy as the control)'
        Pattern = 'if \(\$silence\) \{ \$result\.Status = Get-FramePacingSilencedStatus \$result\.Status \$silence; \$result\.Failures = @\(@\(\$result\.Failures\) \+ \$silence\.Line\) \}'
        Mutation = @('if ($silence) { $result.Status = Get-FramePacingSilencedStatus $result.Status $silence; $result.Failures = @(@($result.Failures) + $silence.Line) }', 'if ($silence) { $result = [pscustomobject]@{ Run = $result.Run; Status = (Get-FramePacingSilencedStatus $result.Status $silence); Failures = @(@($result.Failures) + $silence.Line); Record = $result.Record } }')
    }
    @{
        Description = 'the supervision loop ends at the deadline check: nothing waits after it before the next supervision wait (Opus on #741, round 9: a 900 ms sleep as the control)'
        Pattern = 'if \(\$state -ne 0x102\) \{ throw ''The wait on the driver failed\.'' \}\s+if \(\$driverClock\.ElapsedMilliseconds -ge \$script:DriverDeadlineMs\) \{ throw ''The driver ran past 30 minutes; the owned job was closed\.'' \}\s+\}\s+\[uint32\]\$code = 0'
        Mutation = @("if (`$driverClock.ElapsedMilliseconds -ge `$script:DriverDeadlineMs) { throw 'The driver ran past 30 minutes; the owned job was closed.' }", "if (`$driverClock.ElapsedMilliseconds -ge `$script:DriverDeadlineMs) { throw 'The driver ran past 30 minutes; the owned job was closed.' }`n            Start-Sleep -Milliseconds 900")
    }
    @{
        Description = 'the clipboard reading is the shared guard''s own samples and verdict, a 0/0 reading unobservable, never held, with no second reading (Opus on #741, round 9; Sol on #744: a resample as the control)'
        Pattern = '(?s)ClipboardSequenceBefore = \$stateGuard\.ClipboardBefore; ClipboardSequenceAfter = \$\(if \(\$null -ne \$stateGuard\.PSObject\.Properties\[''ClipboardAfter''\]\) \{ \$stateGuard\.ClipboardAfter \} else \{ \$null \}\)\s+ClipboardObservable = \$\(if \(\$null -ne \$stateGuard\.PSObject\.Properties\[''ClipboardObservable''\]\) \{ \[bool\]\$stateGuard\.ClipboardObservable \} else \{ \$false \}\).*?Write-Host \(Format-InteractiveWin11ClipboardReading \$guards\.ClipboardSequenceBefore \$guards\.ClipboardSequenceAfter\)'
        Mutation = @('ClipboardSequenceAfter = $(if ($null -ne $stateGuard.PSObject.Properties[''ClipboardAfter'']) { $stateGuard.ClipboardAfter } else { $null })', 'ClipboardSequenceAfter = [HiddenLocal]::GetClipboardSequenceNumber()')
    }
    @{
        Description = 'each driver records the harness hash it ran under, the outer half hashes the harness once at series start, and the summary compares them instead of hashing at summary time (Sol on #741, round 10)'
        Pattern = '(?s)\$record = \[ordered\]@\{\s+Schema = 1; Mode = \$mode; HarnessSha256 = \(Get-FramePacingLoadedHarnessSha256\);.*?\$harnessChanged = \[string\]::IsNullOrEmpty\(\$HarnessSha256\) -or \(Test-FramePacingHarnessChanged \$Results \$HarnessSha256\)'
        Mutation = @('HarnessSha256 = (Get-FramePacingLoadedHarnessSha256);', 'HarnessSha256 = (Get-Sha256 $PSCommandPath);')
    }
    @{
        Description = 'the harness''s identity is the SHA-256 of the script text the process parsed, from its own syntax tree''s root, never the file on disk (Sol on #744: a disk hash as the control)'
        Pattern = 'function Get-FramePacingLoadedHarnessSha256 \{\s+\$ast = \$\{function:Get-FramePacingLoadedHarnessSha256\}\.Ast\s+while \(\$null -ne \$ast\.Parent\) \{ \$ast = \$ast\.Parent \}\s+return Get-BytesSha256 \(\[Text\.Encoding\]::UTF8\.GetBytes\(\$ast\.Extent\.Text\)\)\s+\}'
        Mutation = @('return Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($ast.Extent.Text))', 'return Get-Sha256 $PSCommandPath')
    }
    @{
        Description = 'the polled sleep reads the gate at each 100 ms of it (Opus on #741, round 7: P1, the poll removed, as the control)'
        Pattern = 'function Wait-FramePacingPolled\(\[int\] \$Ms, \[string\] \$During\) \{ for \(\$waited = 0; \$waited -lt \$Ms; \$waited \+= 100\) \{ Start-Sleep -Milliseconds 100; Assert-QuietPoll \$During \} \}'
        Mutation = @('Start-Sleep -Milliseconds 100; Assert-QuietPoll $During } }', 'Start-Sleep -Milliseconds 100 } }')
    }
    @{
        Description = 'the series port reads the hooks'' own count (Opus on #741, round 7: P2, a literal count, as the control)'
        Pattern = 'Add-Member -InputObject \$port -MemberType ScriptMethod -Name RealInputs -Value \{ \[FramePacingNative\]::RealInputs\(\) \}'
        Mutation = @('-Name RealInputs -Value { [FramePacingNative]::RealInputs() }', '-Name RealInputs -Value { [long]0 }')
    }
    @{
        Description = 'the series port stops the real watch (Opus on #741, round 7: P3, a stop that only says it stopped, as the control)'
        Pattern = 'Add-Member -InputObject \$port -MemberType ScriptMethod -Name StopWatch -Value \{ \[FramePacingNative\]::StopWatch\(\) \}'
        Mutation = @('-Name StopWatch -Value { [FramePacingNative]::StopWatch() }', '-Name StopWatch -Value { $true }')
    }
    @{
        Description = 'a series whose verdict is not a pass (exit 0), input and a changed harness among them, writes pacing.json from the allowlist, with the hash the series started with, and then everything else, with no dry_run_p95_ms, to diagnostics.json, whether or not pacing.json was written, a failed diagnostics write a warning (the lead and Sol on #741, rounds 9 and 10, and on #744, rounds 2 to 4)'
        Pattern = '(?s)\$withheld = \$voided -or \$exitCode -ne 0\s+\$diagnosticsFailure = \$null\s+if \(\$withheld\) \{.*?\$allowed = \[ordered\]@\{\s+Schema = 1; Verdict = \$\(if \(\$voided\) \{ ''voided'' \} elseif \(\$exitCode -eq 3\) \{ ''guard-tripped'' \} elseif \(\$exitCode -eq 2\) \{ ''inconclusive'' \} else \{ ''failed'' \}\); ExitCode = \$exitCode\s+Reasons = @\(Get-FramePacingVoidReasons [^\r\n]+\)\s+RealInputsSeen = \$RealInputs; InjectedInputsSeen = \$InjectedInputs; SeriesId = \(Split-Path -Leaf \$Root\)\s+HarnessSha256 = \$HarnessSha256; MeasureHead = \$Build\.Head; ExeSHA256 = \$Build\.ExeSha256\s+\}\s+try \{ \$allowed \| ConvertTo-Json -Depth 3 \| Set-Content -LiteralPath \(Join-Path \$Root ''pacing\.json''\) -Encoding utf8NoBOM \}\s+finally \{\s+(?:#[^\r\n]*\s+)*\$summary\.ExitCode = \$exitCode\s+\$summary\.dry_run_p95_ms = \$null\s+try \{ \$summary \| ConvertTo-Json -Depth 6 \| Set-Content -LiteralPath \(Join-Path \$Root ''diagnostics\.json''\) -Encoding utf8NoBOM -ErrorAction Stop \}\s+catch \{ \$diagnosticsFailure = \$_\.Exception\.Message \}\s+\}\s+\} else \{\s+\$summary \| ConvertTo-Json -Depth 6 \| Set-Content -LiteralPath \(Join-Path \$Root ''pacing\.json''\) -Encoding utf8NoBOM\s+\}'
        Mutation = @('$withheld = $voided -or $exitCode -ne 0', '$withheld = $voided')
    }
    @{
        Description = 'the driver''s session facts read the tick through the run''s ticks, so a moved tick latches the run (the lead and Sol on #741, round 9)'
        Pattern = '\$facts = Get-FramePacingSessionFacts \$QuietSinceTick \$ForegroundLockNeededMs \$\(if \(\$Visible\) \{ \$record\.InputTicks \} else \{ \$null \}\)'
        Mutation = @('$ForegroundLockNeededMs $(if ($Visible) { $record.InputTicks } else { $null })', '$ForegroundLockNeededMs $null')
    }
    @{
        Description = 'the one tick read latches a mismatch or a failed read in the ticks it is given before it returns (the lead and Sol on #741, round 9)'
        Pattern = 'function Read-FramePacingInputTick\(\$Ticks\) \{\s+\$last = \[FramePacingNative\]::LastInputNow\(\)\s+if \(\$null -ne \$Ticks\) \{\s+\$expected = [^\r\n]+\s+if \(\[long\]\$last\[0\] -lt 0 -or \$null -eq \$expected -or \[long\]\$expected -lt 0 -or \[long\]\$last\[0\] -ne \[long\]\$expected\) \{ \$Ticks\.Broken = \$true \}\s+\}'
        Mutation = @('-ne [long]$expected) { $Ticks.Broken = $true }', '-ne [long]$expected) { }')
    }
    @{
        Description = 'nothing but the job-membership check and the environment''s restore comes between the driver''s launch and the first supervision wait (Opus on #741, round 6: G1, a delay before the deadline, as the control)'
        Pattern = 'if \(-not \[FramePacingNative\]::InJobOf\(\$pi\.process, \$job\)\) \{ [^\r\n]+\}\s+foreach \(\$name in \$saved\.Keys\) \{ \[Environment\]::SetEnvironmentVariable\(\$name, \$saved\[\$name\], ''Process''\) \}\s+\$driverClock = \[Diagnostics\.Stopwatch\]::StartNew\(\)\s+while \(\$true\) \{\s+\[long\]\$observed = 0; \[long\]\$closed = 0\s+\$state = \[FramePacingNative\]::SuperviseDriver\('
        Mutation = @('$driverClock = [Diagnostics.Stopwatch]::StartNew()', 'Start-Sleep -Milliseconds 400; $driverClock = [Diagnostics.Stopwatch]::StartNew()')
    }
    @{
        Description = 'the series ends through Complete-FramePacingSeries: the watch stops (unhooks) first, then the final real-input count and the session''s tick are read, then the summary takes exactly what was read (the lead, Sol and Opus on #741, round 6: SUM1, a literal count, as the control)'
        Pattern = '(?s)return Complete-FramePacingSeries \(New-FramePacingSeriesPort\) \$root \$build @\(\$results\.ToArray\(\)\) \$quietSince \$harnessSha256.*?function Complete-FramePacingSeries\(\$Port, \[string\] \$Root, \$Build, \[object\[\]\] \$Results, \[long\] \$Baseline, \[string\] \$HarnessSha256\) \{\s+if \(-not \$Visible\) \{ return Write-FramePacingSummary \$Root \$Build \$Results \$null \$null \$false \$false \$HarnessSha256 \}\s+\$stopped = \[bool\]\$Port\.StopWatch\(\)\s+\$final = Get-FramePacingFinalInput \$stopped \(\[long\]\$Port\.RealInputs\(\)\) \(\[long\]\$Port\.LastInputTick\(\[ordered\]@\{ Series = \$Baseline; Unlock = \$null; Broken = \$false \}\)\) \$Baseline\s+return Write-FramePacingSummary \$Root \$Build \$Results \$final\.RealInputs \$\(if \(\$stopped\) \{ \[long\]\$Port\.InjectedInputs\(\) \} else \{ \$null \}\) \$final\.TickMoved \$final\.TickUnread \$HarnessSha256\s+\}'
        Mutation = @('$final = Get-FramePacingFinalInput $stopped ([long]$Port.RealInputs())', '$final = Get-FramePacingFinalInput $stopped ([long]0)')
    }
    @{
        Description = 'after each visible run the outer half reads the session''s tick against the last tick the harness''s own marked input left, and a moved tick stops the run like hook-seen input (the lead and Sol on #741, round 6)'
        Pattern = 'if \(\$Visible -and -not \$inputStopped -and \$null -ne \$record\) \{\s+\$afterTicks = \[ordered\]@\{ Series = \$\(if \(\$null -ne \$record\.InputTicks -and \$null -ne \$record\.InputTicks\.Unlock\) \{ \[long\]\$record\.InputTicks\.Unlock \} else \{ \$QuietSince \}\); Unlock = \$null; Broken = \$false \}\s+\$afterRun = Read-FramePacingInputTick \$afterTicks\s+\$inputStopped = Get-FramePacingTickStop \$afterRun\.Tick \(\[long\]\$afterTicks\.Series\)\s+\}'
        Mutation = @('$inputStopped = Get-FramePacingTickStop', '$null = Get-FramePacingTickStop')
    }
    @{
        Description = 'the copy''s quit wait reads the gate at each 100 ms (the lead and Sol on #741, round 6)'
        Pattern = 'if \(Wait-FramePacingProcess \$process 60000 ''the copy''''s quit''\) \{ \$record\.Exit = \[FramePacingNative\]::ExitCode\(\$process\) \}'
        Mutation = @("if (Wait-FramePacingProcess `$process 60000 'the copy''s quit')", 'if ([FramePacingNative]::WaitForSingleObject($process, 60000) -eq 0)')
    }
    @{
        Description = 'a render-trace snapshot''s wait for its file reads the gate at each pass (the lead and Sol on #741, round 6)'
        Pattern = 'Assert-QuietPoll ''a render-trace snapshot''\s+Start-Sleep -Milliseconds 5\s+\} while \(\$clock\.ElapsedMilliseconds -lt \$deadline\)'
        Mutation = @("Assert-QuietPoll 'a render-trace snapshot'", '')
    }
    @{
        Description = 'the load readings sample around 100 ms polls of the gate, and the visible quiet wait polls too (the lead and Sol on #741, round 6)'
        Pattern = '(?s)function Measure-FramePacingBusy\(\[string\] \$During\) \{\s+\$before = \[FramePacingNative\]::SystemTimes\(\)\s+Wait-FramePacingPolled 2000 \$During\s+return \[Math\]::Round\(\[FramePacingNative\]::BusyShare\(\$before, \[FramePacingNative\]::SystemTimes\(\)\), 1\)\s+\}.*?\$record\.BusyPercentBefore = Measure-FramePacingBusy ''the load reading''.*?Wait-FramePacingPolled 10000 ''the quiet wait''.*?\$record\.BusyPercentAtArm = Measure-FramePacingBusy ''the load reading before the window''.*?\$record\.BusyPercentAfter = Measure-FramePacingBusy ''the load reading after the window'''
        Mutation = @('Wait-FramePacingPolled 2000 $During', 'Start-Sleep -Milliseconds 2000')
    }
    @{
        Description = 'a visible run whose keyboard probe did not come back ok stops inconclusive before the workload (Opus on #741, round 5: K1, the stop deleted, as the control)'
        Pattern = 'Log "keyboard probe: \$\(\$record\.KeyProbe\)"\s+if \(-not \[string\]::Equals\(\[string\]\$record\.KeyProbe, ''ok'', \[StringComparison\]::Ordinal\)\) \{ throw "INCONCLUSIVE: the keyboard probe was \$\(\$record\.KeyProbe\)\." \}\s+\$settled = Wait-Quiet \$script:QuietMs 30000'
        Mutation = @('if (-not [string]::Equals([string]$record.KeyProbe, ''ok'', [StringComparison]::Ordinal)) { throw "INCONCLUSIVE: the keyboard probe was $($record.KeyProbe)." }', '')
    }
    @{
        Description = 'the end marker''s loop keeps $DrainMs between snapshots and reads the gate at each 100 ms of it (Opus on #741, round 5)'
        Pattern = 'while \(\$null -eq \$presented\) \{\s+for \(\$drained = 0; \$drained -lt \$script:DrainMs; \$drained \+= 100\) \{ Start-Sleep -Milliseconds 100; Assert-QuietPoll ''the end marker''''s swap'' \}\s+if \(-not \[FramePacingNative\]::Alive\(\$process\)\)'
        Mutation = @('Start-Sleep -Milliseconds 100; Assert-QuietPoll ''the end marker''''s swap''', 'Start-Sleep -Milliseconds 100')
    }
    @{
        Description = 'input by the end of the window ends the copy at once, and the gate runs again right before the quit (Opus on #741, round 5)'
        Pattern = '(?s)\$record\.InputDuringRun = \$null -ne \$record\.InputBreak\s+\}\s+Log \("workload: [^\r\n]+\s+if \(\$record\.InputDuringRun\) \{ throw "INCONCLUSIVE: \$\(\$record\.InputBreak\); the copy was ended at once\." \}.*?\$record\.BusyPercentAfter = [^\r\n]+\s+\$record\.TimerResolutionAfter100ns = [^\r\n]+\s+Assert-Quiet ''the quit''\s+foreach \(\$h in Get-Hosts\) \{ if \(\[FramePacingNative\]::PostClose\(\$h, \$nocttyPid\)\)'
        Mutation = @('if ($record.InputDuringRun) { throw "INCONCLUSIVE:', 'if ($false) { throw "INCONCLUSIVE:')
    }
    @{
        Description = 'the outer half reads the run''s record through Read-FramePacingRunRecord, and an unreadable record fails the run only when no real-input stop explains it (Opus on #741, round 5)'
        Pattern = '\$recordPath = Join-Path \$Run ''run\.json''\s+\$read = Read-FramePacingRunRecord \$recordPath\s+\$record = \$read\.Record\s+if \(\$read\.Problem -and -not \$inputStopped\) \{ \$outerFailures \+= \$read\.Problem \}'
        Mutation = @('if ($read.Problem -and -not $inputStopped) { $outerFailures += $read.Problem }', '')
    }
    @{
        Description = 'the outer half supervises the driver through SuperviseDriver, which terminates the run''s job the moment it sees the real-input latch; only comments come before the job''s cleanup, so no grace or wait on the driver precedes the close, and LatchToKillMs runs from the observation until StopOwnedJob has seen no process left and closed the handle (the lead, Sol and Opus on #741, rounds 5 and 6)'
        Pattern = '(?s)while \(\$true\) \{\s+\[long\]\$observed = 0; \[long\]\$closed = 0\s+\$state = \[FramePacingNative\]::SuperviseDriver\(\$pi\.process, \$job, 1000, \[ref\]\$observed, \[ref\]\$closed\)\s+if \(\$state -eq 1 -or \$state -eq 2\) \{\s+if \(\$state -eq 2\) \{ \$cleanup = ''[^''\r\n]+'' \}\s+try \{ \$ownedProcesses = \[HiddenLocal\]::StopOwnedJob\(\$job\); if \(\$state -eq 1 -and \$frequency -gt 0\) \{ \$latchToKillMs = \[Math\]::Round\(\(\[FramePacingNative\]::PerformanceCounter\(\) - \$observed\) \* 1000\.0 / \$frequency, 3\) \} \} catch \{ if \(-not \$cleanup\) \{ \$cleanup = \$_\.Exception\.Message \} \} finally \{ \$job = \[IntPtr\]::Zero \}\s+\[void\]\[HiddenLocal\]::WaitForSingleObject\(\$pi\.process, 5000\)\s+break\s+\}\s+if \(\$state -eq 0\) \{ break \}\s+if \(\$state -ne 0x102\) \{ throw ''The wait on the driver failed\.'' \}'
        Mutation = @('if ($state -eq 1 -or $state -eq 2) {', 'if ($state -eq 2) {')
    }
    @{
        Description = 'after the driver, real input stops the run whatever the driver''s exit says: the supervision''s state and the hooks'' real-input count, read once the job''s cleanup is done (the lead on #741, round 5)'
        Pattern = '(?s)if \(\$desktop -ne \[IntPtr\]::Zero\) \{ \[void\]\[HiddenLocal\]::CloseDesktop\(\$desktop\) \}\s+\}\s+\$inputStopped = Get-FramePacingSupervisionStop \$state \$\(if \(\$Visible\) \{ \[FramePacingNative\]::RealInputs\(\) \} else \{ \[long\]0 \}\)\s+\$sessionAfter = Get-Metadata \$sessionPath.*?OwnedJobCleanup = \$cleanup; DriverExit = \$driverExit; LatchToKillMs = \$latchToKillMs.*?\$stop = if \(\$notLaunched\) \{ [^\r\n]+ \} elseif \(\$inputStopped\) \{ \$inputStopped \} else \{ \$null \}'
        Mutation = @('Get-FramePacingSupervisionStop $state $(if ($Visible) { [FramePacingNative]::RealInputs() } else { [long]0 })', 'Get-FramePacingSupervisionStop $state ([long]0)')
    }
    @{
        Description = 'a visible driver reads the foreground lock again right before the copy''s launch, after +version''s wait, and launches nothing when it would not outlast the series (Sol on #741, round 5)'
        Pattern = '(?s)Wait-FramePacingProcess \$check\.process 60000 ''\+version''.*?if \(\$Visible\) \{\s+\$record\.ForegroundLockTimeoutAtLaunchMs = \[FramePacingNative\]::ForegroundLockTimeout\(\)\s+\$lockShortfall = Get-FramePacingLockShortfall \$record\.ForegroundLockTimeoutAtLaunchMs \$ForegroundLockNeededMs\s+if \(\$lockShortfall\) \{ throw "INCONCLUSIVE: right before the copy''s launch, [^\r\n]+\}\s+\}\s+\$tracePath = Join-Path \$Run ''render-trace\.json'''
        Mutation = @('if ($lockShortfall) { throw "INCONCLUSIVE: right before', 'if ($false) { throw "INCONCLUSIVE: right before')
    }
    @{
        Description = 'a visible run waits for a machine under 30% busy (MEASUREMENT-HARNESS-RERUN-01)'
        Pattern = '(?s)if \(\$Visible\) \{\s+\$quietClock = \[Diagnostics\.Stopwatch\]::StartNew\(\)\s+while \(\(\$record\.BusyPercentBefore -lt 0 -or \$record\.BusyPercentBefore -ge \$script:QuietBusyPercent\) -and \$quietClock\.ElapsedMilliseconds -lt \[long\]\$QuietWaitSeconds \* 1000\) \{'
        Mutation = @('-ge $script:QuietBusyPercent) -and $quietClock', '-ge 100) -and $quietClock')
    }
    @{
        Description = 'only a visible run takes the foreground, through the input gate, then the gate again and the keyboard probe; a dry run records it as skipped and measures the probe''s effect on cmd instead'
        Pattern = '(?s)if \(\$Visible\) \{\s+if \(\$record\.DisplayPowerBefore -ne \$script:DisplayOn\) \{ throw "INCONCLUSIVE: [^\r\n]+\}.*?\$record\.Foreground = Invoke-FramePacingForeground \$port \$record\.InputTicks \$hostWindow \$nocttyPid.*?Assert-Quiet ''the copy in front''\s+\$record\.KeyProbe = Invoke-FramePacingKeyProbe \$port \$record\.InputTicks \$hostWindow \$nocttyPid.*?\} else \{\s+\$record\.Foreground = ''skipped'''
        Mutation = @("Assert-Quiet 'the copy in front'", '')
    }
    @{
        Description = 'the dry run posts the same VK_NONAME to the copy''s pane and requires cmd''s console unchanged, then exactly the console before plus the command F5 typed, both read from the top-left through the cursor (the lead and Greptile on #741)'
        Pattern = '(?s)\$promptBefore = Read-FramePacingConsoleText ''before-probe''\s+Assert-Quiet ''the dry run''''s key probe''\s+\[FramePacingNative\]::PostKey\(\$pane, \$nocttyPid, 0xFC\)\s+\[void\]\(Wait-Quiet \$script:EchoQuietMs 15000\)\s+\$promptAfter = Read-FramePacingConsoleText ''after-probe''\s+\$record\.DryProbePromptUnchanged = Test-FramePacingConsoleTyped \$promptBefore \$promptAfter ''''\s+if \(-not \$record\.DryProbePromptUnchanged\) \{ throw [^\r\n]+\}.*?\$echoed = Wait-Quiet \$script:EchoQuietMs 15000\s+if \(-not \$Visible\) \{\s+\$typed = ''type stream\.bin & echo\.>done\.flag''\s+\$command = Read-FramePacingConsoleText ''after-command''\s+\$record\.DryProbeCommandIntact = Test-FramePacingConsoleTyped \$promptBefore \$command \$typed\s+if \(-not \$record\.DryProbeCommandIntact\) \{ throw '
        Mutation = @('if (-not $record.DryProbePromptUnchanged) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the dry run''s console probe reads every cell from the top-left through the cursor, untrimmed, so a prompt or command that wraps is read whole (Greptile on #741)'
        Pattern = 'int cells = info\.cursor\.y \* info\.size\.x \+ info\.cursor\.x;\s+var text = new StringBuilder\(cells \+ 1\);\s+uint read = 0;\s+if \(cells > 0 && !ReadConsoleOutputCharacterW\(output, text, \(uint\)cells, new Coord \{ x = 0, y = 0 \}, out read\)\) return "read-failed-" \+ Marshal\.GetLastWin32Error\(\);\s+return cells \+ "\\t" \+ text\.ToString\(0, \(int\)read\);'
        Mutation = @('new Coord { x = 0, y = 0 }', 'new Coord { x = 0, y = info.cursor.y }')
    }
    @{
        Description = 'a visible run takes the foreground only with the display on and no screen saver; a copy already in front is allowed only when no window held the foreground before its launch (Opus on #741)'
        Pattern = 'if \(\$record\.DisplayPowerBefore -ne \$script:DisplayOn\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\$record\.ForegroundBeforeUnlock = \[FramePacingNative\]::IsForeground\(\$hostWindow\)\s+if \(\$record\.ForegroundBeforeUnlock\) \{\s+if \(\[string\]::Equals\(\[string\]\$record\.ForegroundBeforeLaunch, ''none'', \[StringComparison\]::Ordinal\)\) \{ \$record\.ForegroundTakenFromNone = \$true \}\s+else \{ throw ''INCONCLUSIVE: [^\r\n]+\}\s+\}\s+\$record\.ScreenSaverBeforeUnlock = \[FramePacingNative\]::ScreenSaverRunning\(\)\s+if \(\$record\.ScreenSaverBeforeUnlock -ne 0\) \{ throw "'
        Mutation = @('if ($record.DisplayPowerBefore -ne $script:DisplayOn) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a visible run reads whether any window held the foreground right before the copy''s launch (Opus on #741)'
        Pattern = 'if \(\$Visible\) \{ \$record\.ForegroundBeforeLaunch = \$\(if \(\[FramePacingNative\]::AnyForeground\(\)\) \{ ''a window'' \} else \{ ''none'' \}\) \}\s+Assert-Quiet ''the copy''''s launch'''
        Mutation = @("else { 'none' }", "else { 'a window' }")
    }
    @{
        Description = 'a screen saver before the unlock stops the run before the foreground (Opus on #741)'
        Pattern = '\$record\.ScreenSaverBeforeUnlock = \[FramePacingNative\]::ScreenSaverRunning\(\)\s+if \(\$record\.ScreenSaverBeforeUnlock -ne 0\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\$record\.Foreground = Invoke-FramePacingForeground'
        Mutation = @('if ($record.ScreenSaverBeforeUnlock -ne 0) { throw', 'if ($false) { throw')
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
        Description = 'the foreground call is bounded: the window must be this copy''s, the watches and the marker must be given, not hung and answer WM_NULL first, and the calls run on a worker joined within the bound (VISIBLE-PACING-CERT-01 trap 1)'
        Pattern = '(?s)public static string Foreground\(IntPtr hwnd, int pid, int boundMs, long expectedTick, IntPtr watch, IntPtr mouseWatch, IntPtr marker, out long unlockTick\) \{\s+unlockTick = -1;\s+if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(watch == IntPtr\.Zero \|\| mouseWatch == IntPtr\.Zero \|\| marker == IntPtr\.Zero\) return "no-input-watch";\s+if \(IsHungAppWindow\(hwnd\) \|\| !Responsive\(hwnd, \(uint\)boundMs\)\) return "hung";.*?worker\.IsBackground = true;\s+worker\.Start\(\);\s+if \(!worker\.Join\(boundMs\)\) \{ cancel\.Set\(\); return "timeout"; \}'
        Mutation = @('if (!worker.Join(boundMs)) { cancel.Set(); return "timeout"; }', 'worker.Join();')
    }
    @{
        Description = 'a timeout cancels the worker''s remaining steps: it reads the cancellation before its input and its foreground call, and stops (CodeRabbit and the lead on #741)'
        Pattern = '(?s)static string Halt\(ManualResetEvent cancel, IntPtr watch, string why\) \{\s+if \(cancel\.WaitOne\(0\)\) return "cancelled";\s+return RealInputSignalled\(watch\) \? why : null;\s+\}'
        Mutation = @('if (cancel.WaitOne(0)) return "cancelled";', '')
    }
    @{
        Description = 'the timeout sets the worker''s cancellation before the caller returns'
        Pattern = 'if \(!worker\.Join\(boundMs\)\) \{ cancel\.Set\(\); return "timeout"; \}'
        Mutation = @('{ cancel.Set(); return "timeout"; }', '{ return "timeout"; }')
    }
    @{
        Description = 'each worker acts on its own duplicates of its watch handles and closes them when it ends, so a caller that gave up on it may close its own (CodeRabbit and Sol on #741)'
        Pattern = '(?s)IntPtr real = DuplicateOwn\(watch\), mouse = DuplicateOwn\(mouseWatch\);\s+if \(real == IntPtr\.Zero \|\| mouse == IntPtr\.Zero\) \{ CloseOwn\(real\); CloseOwn\(mouse\); return "no-input-watch"; \}.*?\} finally \{ CloseOwn\(real\); CloseOwn\(mouse\); \}.*?IntPtr real = DuplicateOwn\(watch\), key = DuplicateOwn\(keyWatch\);\s+if \(real == IntPtr\.Zero \|\| key == IntPtr\.Zero\) \{ CloseOwn\(real\); CloseOwn\(key\); return "no-input-watch"; \}.*?\} finally \{ CloseOwn\(real\); CloseOwn\(key\); \}'
        Mutation = @('} finally { CloseOwn(real); CloseOwn(mouse); }', '} finally { }')
    }
    @{
        Description = 'the native foreground and key probe refuse to run without the series'' watches and marker'
        Pattern = 'if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(watch == IntPtr\.Zero \|\| mouseWatch == IntPtr\.Zero \|\| marker == IntPtr\.Zero\) return "no-input-watch";(?s:.*?)if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(watch == IntPtr\.Zero \|\| keyWatch == IntPtr\.Zero \|\| marker == IntPtr\.Zero\) return "no-input-watch";'
        Mutation = @(' || mouseWatch == IntPtr.Zero || marker == IntPtr.Zero) return "no-input-watch";', ') return "no-input-watch";')
    }
    @{
        Description = 'the foreground call refuses a hung or unresponsive window before any cross-thread call'
        Pattern = '(?s)public static string Foreground\(IntPtr hwnd, int pid, int boundMs, long expectedTick, IntPtr watch, IntPtr mouseWatch, IntPtr marker, out long unlockTick\) \{\s+unlockTick = -1;\s+if \(Owner\(hwnd\) != pid\) return "not-this-copy";\s+if \(watch == IntPtr\.Zero \|\| mouseWatch == IntPtr\.Zero \|\| marker == IntPtr\.Zero\) return "no-input-watch";\s+if \(IsHungAppWindow\(hwnd\) \|\| !Responsive\(hwnd, \(uint\)boundMs\)\) return "hung";'
        Mutation = @('if (IsHungAppWindow(hwnd) || !Responsive(hwnd, (uint)boundMs)) return "hung";', '')
    }
    @{
        Description = 'the foreground is unlocked by one marked absolute mouse move to the cursor''s own pixel, built in one place and aimed before the gate, never an Alt tap (PROBE-ALT-TAP-01) nor a zero-delta move the mouse hook never sees (UNLOCK-HOOK-01), and only when SendInput inserted it'
        Pattern = '(?s)CursorPoint aim;\s+var unlock = UnlockHere\(marker, out aim\);\s+if \(unlock == null\) \{ outcome = "unlock-unaimed"; return; \}\s+long before = LastInputTick\(\);.*?if \(SendInput\(1, unlock, Marshal\.SizeOf<Input>\(\)\) != 1\) \{ outcome = "unlock-not-inserted"; return; \}.*?static Input\[\] UnlockInput\(IntPtr marker, int nx, int ny\) \{\s+var unlock = new Input\[\] \{ new Input \{ type = 0 \} \};\s+unlock\[0\]\.mouse\.dx = nx; unlock\[0\]\.mouse\.dy = ny;\s+unlock\[0\]\.mouse\.flags = 0xC001;[^\r\n]*\s+unlock\[0\]\.mouse\.extra = marker;\s+return unlock;\s+\}.*?static Input\[\] UnlockHere\(IntPtr marker, out CursorPoint aim\) \{\s+aim = new CursorPoint\(\);\s+if \(SetThreadDpiAwarenessContext\(new IntPtr\(-4\)\) == IntPtr\.Zero\) return null;[^\r\n]*\s+if \(!GetCursorPos\(out aim\)\) return null;\s+int left = GetSystemMetrics\(76\), top = GetSystemMetrics\(77\), width = GetSystemMetrics\(78\), height = GetSystemMetrics\(79\);\s+if \(width <= 0 \|\| height <= 0\) return null;\s+return UnlockInput\(marker, Normalize\(aim\.x, left, width\), Normalize\(aim\.y, top, height\)\);\s+\}'
        Mutation = @('new Input { type = 0 }', 'new Input { type = 1 }')
    }
    @{
        Description = 'the keyboard probe is VK_NONAME down and up, marked, built in one place, and only counted when SendInput inserted both (the lead on #741)'
        Pattern = '(?s)if \(SendInput\(2, KeyProbeInput\(marker\), Marshal\.SizeOf<KeyInput>\(\)\) != 2\) \{ outcome = "key-probe-not-inserted"; return; \}.*?static KeyInput\[\] KeyProbeInput\(IntPtr marker\) \{\s+var probe = new KeyInput\[\] \{ new KeyInput \{ type = 1 \}, new KeyInput \{ type = 1 \} \};\s+probe\[0\]\.keybd\.vk = 0xFC; probe\[0\]\.keybd\.extra = marker;\s+probe\[1\]\.keybd\.vk = 0xFC; probe\[1\]\.keybd\.flags = 0x0002; probe\[1\]\.keybd\.extra = marker;\s+return probe;\s+\}'
        Mutation = @('probe[0].keybd.vk = 0xFC;', 'probe[0].keybd.vk = 0x41;')
    }
    @{
        Description = 'the native foreground checks the series'' tick (valid, and the series'') and the input watch on its worker right before its one input, and sends nothing when either moved (Sol, Opus and the lead on #741)'
        Pattern = 'long before = LastInputTick\(\);\s+if \(before < 0 \|\| before != expectedTick\) \{ outcome = "input-before-unlock"; return; \}\s+WaitForSingleObject\(mouse, 0\);[^\r\n]*\s+if \(\(outcome = Halt\(cancel, real, "real-input-before-unlock"\)\) != null\) return;\s+if \(\(outcome = CursorAway\(aim, "unlock-raced"\)\) != null\) return;\s+if \(SendInput\(1, unlock, Marshal\.SizeOf<Input>\(\)\) != 1\)'
        Mutation = @('if (before < 0 || before != expectedTick) { outcome = "input-before-unlock"; return; }', '')
    }
    @{
        Description = 'the cursor is read again between the gate''s last check and the unlock''s SendInput, and the unlock is sent only if it is still on the aimed pixel (Sol and the lead on #746: an absolute move replaces motion)'
        Pattern = 'if \(\(outcome = Halt\(cancel, real, "real-input-before-unlock"\)\) != null\) return;\s+if \(\(outcome = CursorAway\(aim, "unlock-raced"\)\) != null\) return;\s+if \(SendInput\(1, unlock, Marshal\.SizeOf<Input>\(\)\) != 1\)'
        Mutation = @(('                if ((outcome = CursorAway(aim, "unlock-raced")) != null) return;' + "`n"), '')
    }
    @{
        Description = 'after the hook''s sight of the unlock the cursor is read once more, and a cursor off the aimed pixel stops the run before the foreground (Opus on #746)'
        Pattern = 'if \(\(outcome = ProbeSeen\("unlock", before, now, hookSaw\)\) != null\) return;\s+if \(\(outcome = CursorAway\(aim, "unlock-moved-cursor"\)\) != null\) return;\s+if \(LastInputTick\(\) != now\)'
        Mutation = @(('                if ((outcome = CursorAway(aim, "unlock-moved-cursor")) != null) return;' + "`n"), '')
    }
    @{
        Description = 'the cursor check fails closed on a failed read and compares both coordinates, keeping nothing (Sol and Opus on #746)'
        Pattern = 'static string CursorAway\(CursorPoint aim, string why\) \{\s+CursorPoint now;\s+return GetCursorPos\(out now\) && now\.x == aim\.x && now\.y == aim\.y \? null : why;\s+\}'
        Mutation = @('return GetCursorPos(out now) && now.x == aim.x && now.y == aim.y ? null : why;', 'return GetCursorPos(out now) || now.x == aim.x ? null : why;')
    }
    @{
        Description = 'a failed switch to per-monitor DPI awareness aims nothing, so the run fails with unlock-unaimed (Opus on #746)'
        Pattern = 'if \(SetThreadDpiAwarenessContext\(new IntPtr\(-4\)\) == IntPtr\.Zero\) return null;'
        Mutation = @('if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero) return null;', 'SetThreadDpiAwarenessContext(new IntPtr(-4));')
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
        Description = 'the input gate holds immediately before the measured window, after the load reading and the screen-saver reading right before it, each acted on at once (Greptile, CodeRabbit, Sol and Opus on #741)'
        Pattern = '(?s)\$record\.BusyPercentAtArm = Measure-FramePacingBusy ''the load reading before the window''\s+if \(\$Visible -and \(\$record\.BusyPercentAtArm -lt 0 -or \$record\.BusyPercentAtArm -ge \$script:QuietBusyPercent\)\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+if \(\$Visible\) \{\s+\$record\.ScreenSaverAtArm = \[FramePacingNative\]::ScreenSaverRunning\(\)\s+if \(\$record\.ScreenSaverAtArm -ne 0\) \{ throw "INCONCLUSIVE: [^\r\n]+\}\s+\}\s+Assert-Quiet ''the measured window''\s+\$donePath = Join-Path \$work ''done\.flag''.*?TraceMessage\(\$pane, \$nocttyPid, \$script:WmRenderTraceTarget'
        Mutation = @("Assert-Quiet 'the measured window'", '')
    }
    @{
        Description = 'a busy machine right before the window stops a visible run before the window starts (CodeRabbit on #741)'
        Pattern = 'if \(\$Visible -and \(\$record\.BusyPercentAtArm -lt 0 -or \$record\.BusyPercentAtArm -ge \$script:QuietBusyPercent\)\) \{ throw "INCONCLUSIVE: '
        Mutation = @('if ($Visible -and ($record.BusyPercentAtArm -lt 0 -or $record.BusyPercentAtArm -ge $script:QuietBusyPercent)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a screen saver right before the window stops a visible run (Opus on #741)'
        Pattern = 'if \(\$record\.ScreenSaverAtArm -ne 0\) \{ throw "INCONCLUSIVE: '
        Mutation = @('if ($record.ScreenSaverAtArm -ne 0) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the input gate is read again after the end marker''s swap, and a break makes the run inconclusive'
        Pattern = '(?s)if \(\$Visible\) \{\s+\$record\.InputBreak = Test-FramePacingInputGate \$port \$record\.InputTicks ''the end of the measured window''\s+\$record\.InputDuringRun = \$null -ne \$record\.InputBreak\s+\}'
        Mutation = @('$record.InputDuringRun = $null -ne $record.InputBreak', '$record.InputDuringRun = $false')
    }
    @{
        Description = 'the unlock must be seen twice before the foreground: a valid tick that moved, and the mouse hook''s sight of the marked event; then the tick is read again and the watch and cancellation checked, and activation is waited for before "refused" (CodeRabbit, Sol and the lead on #741)'
        Pattern = '(?s)if \(SendInput\(1, unlock, Marshal\.SizeOf<Input>\(\)\) != 1\) \{ outcome = "unlock-not-inserted"; return; \}\s+long now = WaitTickMove\(before, 1000\);(?:\s+//[^\r\n]*)*\s+if \(now >= 0 && now != before\) tick = now;\s+bool hookSaw = WaitForSingleObject\(mouse, 1000\) == 0;\s+if \(\(outcome = ProbeSeen\("unlock", before, now, hookSaw\)\) != null\) return;\s+if \(\(outcome = CursorAway\(aim, "unlock-moved-cursor"\)\) != null\) return;\s+if \(LastInputTick\(\) != now\) \{ outcome = "input-before-foreground"; return; \}\s+if \(\(outcome = Halt\(cancel, real, "real-input-before-foreground"\)\) != null\) return;\s+SetForegroundWindow\(hwnd\);\s+Responsive\(hwnd, 500\);\s+var activation = System\.Diagnostics\.Stopwatch\.StartNew\(\);\s+while \(GetForegroundWindow\(\) != hwnd && activation\.ElapsedMilliseconds < 500\) \{\s+if \(\(outcome = Halt\(cancel, real, "real-input-during-activation"\)\) != null\) return;\s+Thread\.Sleep\(10\);\s+\}\s+outcome = GetForegroundWindow\(\) == hwnd \? "ok" : "refused";'
        Mutation = @('if ((outcome = ProbeSeen("unlock", before, now, hookSaw)) != null) return;', '')
    }
    @{
        Description = 'the tick is read again right before the foreground call (Sol on #741)'
        Pattern = 'if \(LastInputTick\(\) != now\) \{ outcome = "input-before-foreground"; return; \}\s+if \(\(outcome = Halt\(cancel, real, "real-input-before-foreground"\)\) != null\) return;\s+SetForegroundWindow\(hwnd\);'
        Mutation = @('if (LastInputTick() != now) { outcome = "input-before-foreground"; return; }', '')
    }
    @{
        Description = 'the key probe checks the copy is in front, the tick and the watch right before its one input, then needs a valid tick that moved and the keyboard hook''s sight of the marked key (the lead and CodeRabbit on #741)'
        Pattern = '(?s)WaitForSingleObject\(key, 0\);[^\r\n]*\s+if \(GetForegroundWindow\(\) != hwnd\) \{ outcome = "not-in-front"; return; \}\s+long before = LastInputTick\(\);\s+if \(before < 0 \|\| before != expectedTick\) \{ outcome = "input-before-key-probe"; return; \}\s+if \(\(outcome = Halt\(cancel, real, "real-input-before-key-probe"\)\) != null\) return;\s+if \(SendInput\(2, KeyProbeInput\(marker\), Marshal\.SizeOf<KeyInput>\(\)\) != 2\) \{ outcome = "key-probe-not-inserted"; return; \}\s+long now = WaitTickMove\(before, 1000\);(?:\s+//[^\r\n]*)*\s+if \(now >= 0 && now != before\) tick = now;\s+bool hookSaw = WaitForSingleObject\(key, 1000\) == 0;\s+if \(\(outcome = ProbeSeen\("key-probe", before, now, hookSaw\)\) != null\) return;\s+outcome = "ok";'
        Mutation = @('if ((outcome = ProbeSeen("key-probe", before, now, hookSaw)) != null) return;', '')
    }
    @{
        Description = 'the harness''s own input is seen only from two valid, different ticks and the hook of its kind''s sight of it (tabled below)'
        Pattern = 'public static string ProbeSeen\(string what, long before, long now, bool hookSaw\) \{\s+if \(before < 0 \|\| now < 0 \|\| now == before\) return what \+ "-not-observed";\s+if \(!hookSaw\) return what \+ "-not-seen-by-hook";\s+return null;\s+\}'
        Mutation = @('if (!hookSaw) return what + "-not-seen-by-hook";', '')
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
        Pattern = '\$env:GHOSTTY_LOG = ''stderr''\s+\$env:NOCTTY_RENDER_TRACE_FILE = \$tracePath\s+\$env:NOCTTY_RENDER_TRACE_LIVE = ''1''\s+\$env:NOCTTY_BENCH_END_MARKER = \$marker\s+if \(\$Visible\) \{ \$record\.ForegroundBeforeLaunch = [^\r\n]+\}\s+Assert-Quiet ''the copy''''s launch''\s+\$pi = \[FramePacingNative\]::Spawn\(\$exe, \$commandLine, \$work, \$desktopPath, \(Join-Path \$Run ''noctty\.log''\), \$false, \[bool\]\$Visible\)'
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
        Description = 'F5''s command after the gate, its echo presented and quiet, then the trace armed for the end marker (WM_APP + 9 with 0), then the gate and F6''s Enter, with no snapshot between the arm and F6 (CodeRabbit on #741)'
        Pattern = '(?s)Assert-Quiet ''the command key''\s+\[FramePacingNative\]::PostKey\(\$pane, \$nocttyPid, 0x74\)\s+if \(-not \(Wait-For \{ \[uint64\]\(Request-Trace\)\.last_swap_process_output_generation -gt \[uint64\]\$before\.last_swap_process_output_generation \} 15000\)\) \{ throw [^\r\n]+\}\s+\$echoed = Wait-Quiet \$script:EchoQuietMs 15000.*?if \(-not \[FramePacingNative\]::TraceMessage\(\$pane, \$nocttyPid, \$script:WmRenderTraceTarget, 0, \$script:ResponseBoundMs\)\) \{ throw [^\r\n]+\}\s+Assert-Quiet ''the start key''\s+\[FramePacingNative\]::PostKey\(\$pane, \$nocttyPid, 0x75\)'
        Mutation = @("Assert-Quiet 'the start key'", '$armed = Request-Trace')
    }
    @{
        Description = 'the gate runs right before F5 too (Sol, CodeRabbit and the lead on #741)'
        Pattern = 'Assert-Quiet ''the command key''\s+\[FramePacingNative\]::PostKey\(\$pane, \$nocttyPid, 0x74\)'
        Mutation = @("Assert-Quiet 'the command key'", '')
    }
    @{
        Description = 'a workload key is two posts to this copy''s own window and nothing else: no AttachThreadInput, no keyboard-state reset (the lead on #741)'
        Pattern = 'public static void PostKey\(IntPtr h, int pid, int vk\) \{\s+if \(Owner\(h\) != pid\) throw new Exception\("The window is not this copy''s"\);\s+if \(!PostMessageW\(h, 0x100, new IntPtr\(vk\), new IntPtr\(1\)\)\) throw new Exception\("Key-down post failed"\);\s+if \(!PostMessageW\(h, 0x101, new IntPtr\(vk\), new IntPtr\(0xC0000001L\)\)\) throw new Exception\("Key-up post failed"\);\s+\}'
        Mutation = @('if (Owner(h) != pid) throw new Exception("The window is not this copy''s");', '')
    }
    @{
        Description = 'the arm is confirmed after the window, from the snapshot that read it: the target was the end marker (0)'
        Pattern = '\$record\.SnapshotsInWindow = \$snapshotsInWindow\s+if \(-not \$presented\.PSObject\.Properties\[''target_process_output_bytes''\] -or \[uint64\]\$presented\.target_process_output_bytes -ne 0\) \{ throw '
        Mutation = @("if (-not `$presented.PSObject.Properties['target_process_output_bytes'] -or [uint64]`$presented.target_process_output_bytes -ne 0) { throw", 'if ($false) { throw')
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
        Description = 'a visible series'' later runs check the session''s input against the tick the last run''s own unlock and probe left, each launch rechecks the lock against the series'' time so far, and each driver gets the series'' watch, bound and marker (Sol on #741)'
        Pattern = '(?s)\$needNow = Get-FramePacingLockNeedMs \(\$admissionIdleMs \+ \$seriesClock\.ElapsedMilliseconds\) \$facts\.MinIdleMs \(\$Runs - \$i \+ 1\)\s+\$shortfall = Get-FramePacingLockShortfall \(\[FramePacingNative\]::ForegroundLockTimeout\(\)\) \$needNow\s+if \(\$shortfall\) \{\s+\$results\.Add\([^\r\n]+\)\s+Write-Host [^\r\n]+\s+break\s+\}.*?\$result = Invoke-FramePacingOuterRun \$build \(Join-Path \$root "run-\$i"\) \$quietSince \$watchEvent \$needNow \$inputMarker\s+.*?\$results\.Add\(\$result\)\s+if \(\$Visible -and \$null -ne \$result\.Record -and \$null -ne \$result\.Record\.InputTicks -and \$null -ne \$result\.Record\.InputTicks\.Unlock\) \{ \$quietSince = \[long\]\$result\.Record\.InputTicks\.Unlock \}.*?-QuietSinceTick \{9\}'' -f `\s+[^\r\n]+\$QuietWaitSeconds, \$QuietSince\s+if \(\$Visible\) \{ \$line \+= " -Visible -InputWatchEvent \$WatchEvent -ForegroundLockNeededMs \$LockNeededMs -InputMarker \$InputMarker" \}'
        Mutation = @('{ $quietSince = [long]$result.Record.InputTicks.Unlock }', '{ }')
    }
    @{
        Description = 'a launch whose lock would not outlast the remaining runs is not made, and the series stops inconclusive (Sol on #741)'
        Pattern = 'if \(\$shortfall\) \{\s+\$results\.Add\(\[pscustomobject\]@\{ Run = \(Join-Path \$root "run-\$i"\); Status = ''inconclusive''; Failures = @\("inconclusive: \$shortfall; run \$i was not launched"\); Record = \$null \}\)'
        Mutation = @('if ($shortfall) {', 'if ($false) {')
    }
    @{
        Description = 'nothing is sent to the pane inside the measured window: cmd''s done.flag is polled as a file, then one snapshot at a time after the drain (Opus on #741)'
        Pattern = '(?s)\[FramePacingNative\]::PostKey\(\$pane, \$nocttyPid, 0x75\)\s+if \(-not \(Wait-For \{ Test-Path -LiteralPath \$donePath -PathType Leaf \} 120000\)\) \{\s+Assert-Quiet ''the payload''''s timeout''\s+throw [^\r\n]+\s+\}\s+\$doneQpc = .*?while \(\$null -eq \$presented\) \{\s+for \(\$drained = 0; \$drained -lt \$script:DrainMs; \$drained \+= 100\) \{ Start-Sleep -Milliseconds 100; [^\r\n]+ \}\s+.*?try \{ \$s = Request-Trace \} catch \{ Assert-Quiet ''the end marker''''s snapshot''; throw \}\s+if \(\[uint64\]\$s\.first_target_swap_qpc_ticks -gt 0 -and \[uint64\]\$s\.first_target_swap_benchmark_end_marker_generation -gt 0\) \{ \$presented = \$s \}\s+else \{\s+\$snapshotsInWindow\+\+'
        Mutation = @('Test-Path -LiteralPath $donePath -PathType Leaf } 120000))', '[bool](Request-Trace) } 120000))')
    }
    @{
        Description = 'input inside the window makes a visible run inconclusive, never a timeout''s or a failed snapshot''s hard failure: the gate is read at each poll, before each timeout and when a snapshot fails (CodeRabbit on #741)'
        Pattern = '(?s)Assert-QuietPoll ''the end marker''''s swap'' \}\s+if \(-not \[FramePacingNative\]::Alive\(\$process\)\).*?try \{ \$s = Request-Trace \} catch \{ Assert-Quiet ''the end marker''''s snapshot''; throw \}.*?if \(\$clock\.ElapsedMilliseconds -ge \$presentDeadline\) \{ Assert-Quiet ''the end marker''''s timeout''; throw '
        Mutation = @("try { `$s = Request-Trace } catch { Assert-Quiet 'the end marker''s snapshot'; throw }", '$s = Request-Trace')
    }
    @{
        Description = 'every wait of a visible run reads the gate at each poll, against the tick the run expects, and never swallows its throw (Opus on #741)'
        Pattern = '(?s)function Assert-QuietPoll\(\[string\] \$During\) \{\s+if \(-not \$Visible\) \{ return \}\s+Assert-FramePacingPollGate \$port \$record\.InputTicks \$During\s+\}.*?function Wait-For\(\[scriptblock\] \$Predicate, \[int\] \$Ms\) \{\s+\$deadline = \$clock\.ElapsedMilliseconds \+ \$Ms\s+do \{\s+Assert-QuietPoll ''a wait''\s+if \(& \$Predicate\) \{ return \$true \}\s+if \(-not \[FramePacingNative\]::Alive\(\$process\)\) \{ return \$false \}\s+Start-Sleep -Milliseconds 100\s+\} while \(\$clock\.ElapsedMilliseconds -lt \$deadline\)\s+return \[bool\]\(& \$Predicate\)\s+\}.*?function Wait-Quiet\(\[int\] \$QuietMs, \[int\] \$CapMs\) \{.*?Start-Sleep -Milliseconds 100\s+Assert-QuietPoll ''a quiet wait''\s+\$next = Request-Trace'
        Mutation = @("            do {`n                Assert-QuietPoll 'a wait'`n", "            do {`n")
    }
    @{
        Description = 'Wait-For does not swallow the gate''s throw (Opus''s R3 on #741)'
        Pattern = 'do \{\s+Assert-QuietPoll ''a wait''\s+if \(& \$Predicate\) \{ return \$true \}'
        Mutation = @("Assert-QuietPoll 'a wait'`n                if (& `$Predicate) { return `$true }", "if ((& { try { Assert-QuietPoll 'a wait'; & `$Predicate } catch { `$false } })) { return `$true }")
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
        Pattern = '(?s)if \(\$Visible\) \{ \$held = \[FramePacingNative\]::HoldDisplay\(\); if \(-not \$held\) \{ throw [^\r\n]+\} \}.*?finally \{\s+if \(\$Visible -and -not \[FramePacingNative\]::StopWatch\(\)\) \{ Write-Host [^\r\n]+\}\s+if \(\$held\) \{ \[FramePacingNative\]::ReleaseDisplay\(\) \}'
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
        Description = 'frame_time_p95_ms and its median are published only for a visible series with no real input, whose every run completed and whose runs are comparable; real input, an unread count or a tick that left the baseline makes the series inconclusive (the lead on #741, rounds 5 and 6)'
        Pattern = '(?s)\$inputSeen = \$Visible -and \(\$null -eq \$RealInputs -or \[long\]\$RealInputs -ne 0 -or \$TickMoved -or \$inputRuns\.Count -gt 0\)\s+\$harnessChanged = \[string\]::IsNullOrEmpty\(\$HarnessSha256\) -or \(Test-FramePacingHarnessChanged \$Results \$HarnessSha256\)\s+\$voided = \$inputSeen -or \$harnessChanged\s+\$publish = \$Visible -and -not \$voided -and \$completed\.Count -eq \$Runs -and \$series\.Pooled\.Count -gt 0 -and @\(\$series\.MixedEnvironment\)\.Count -eq 0 -and @\(\$series\.MixedBuild\)\.Count -eq 0.*?frame_time_p95_ms = \$\(if \(\$publish\) \{ \$series\.P95 \} else \{ \$null \}\)\s+frame_time_median_ms = \$\(if \(\$publish\) \{ \$series\.Median \} else \{ \$null \}\).*?if \(\$inputSeen\) \{.*?\$inconclusive \+= "input voided the series: [^\r\n]+"\s+\}\s+if \(\$inconclusive\.Count -gt 0\) \{ \$summary\.Inconclusive = \$inconclusive -join ''; '' \}'
        Mutation = @('$publish = $Visible -and -not $voided -and $completed.Count -eq $Runs', '$publish = $Visible -and $completed.Count -eq $Runs')
    }
    @{
        Description = 'the pooled samples come only from completed runs'
        Pattern = '\$series = Get-FramePacingSeries @\(\$completed \| ForEach-Object \{ \$_\.Record \}\)'
        Mutation = @('$series = Get-FramePacingSeries @($completed | ForEach-Object', '$series = Get-FramePacingSeries @($Results | ForEach-Object')
    }
    @{
        Description = 'runs that differ in environment (display mode, DPI, grid) are never pooled: each comparability group is reported alone and the series is inconclusive'
        Pattern = '(?s)\[double\[\]\]\$pooled = @\(if \(\$mixedEnvironment\.Count -eq 0 -and \$mixedBuild\.Count -eq 0\) \{ .*?if \(@\(\$series\.MixedEnvironment\)\.Count -gt 0\) \{ \$inconclusive \+= .*?if \(\$inconclusive\.Count -gt 0\) \{ \$summary\.Inconclusive = \$inconclusive -join ''; '' \}.*?\$exitCode = Get-FramePacingExitCode @\(\$Results \| ForEach-Object \{ \[string\]\$_\.Status \}\) \$summary\.Contains\(''Error''\) \$summary\.Contains\(''Inconclusive''\) \$completed\.Count \$Runs.*?return \$exitCode'
        Mutation = @("`$summary.Contains('Inconclusive') `$completed.Count", "`$false `$completed.Count")
    }
    @{
        Description = 'the exit code''s precedence, highest first: 3 a tripped guard, 1 a failure or a build difference, 2 an inconclusive run or an environment difference, 0 complete (Opus and CodeRabbit on #741; tabled below)'
        Pattern = '(?s)function Get-FramePacingExitCode\(.*?if \(& \$has ''guard-tripped''\) \{ return 3 \}\s+if \(\$BuildDiffers -or \(& \$has ''failed''\)\) \{ return 1 \}\s+if \(\$EnvironmentDiffers -or \(& \$has ''inconclusive''\)\) \{ return 2 \}'
        Mutation = @("if (& `$has 'guard-tripped') { return 3 }", '')
    }
    @{
        Description = 'completed runs that differ in build or workload (WorkloadSha256, the app, renderer, transport, ConPTY digests) fail the summary'
        Pattern = 'if \(@\(\$series\.MixedBuild\)\.Count -gt 0\) \{ \$summary\.Error = '
        Mutation = @('if (@($series.MixedBuild).Count -gt 0) { $summary.Error =', 'if ($false) { $summary.Error =')
    }
)

# The harness's floor is PowerShell 7.2, as #739's (utf8NoBOM, the generic Marshal members); `#requires` is a comment
# token, so this reads the first line.
# The native readers behind the visible run's gates, each pinned with a mutation a careless edit would make (Opus on
# #741): the one input read, the display's power state, the shell's notification state, the display hold, the screen
# saver, the foreground lock, and the input watch (both hooks needed, a manual-reset event only a driver may wait on,
# the injected flags).
$framePacingRules += @(
    @{
        Description = 'the session''s last input and its age come from one GetLastInputInfo read (CodeRabbit on #741)'
        Pattern = 'public static long\[\] LastInputNow\(\) \{\s+var li = new LastInput \{ size = \(uint\)Marshal\.SizeOf<LastInput>\(\) \};\s+if \(!GetLastInputInfo\(ref li\)\) return new long\[\] \{ -1, -1 \};\s+return new long\[\] \{ \(long\)li\.time, \(long\)unchecked\(GetTickCount\(\) - li\.time\) \};\s+\}'
        Mutation = @('return new long[] { (long)li.time, (long)unchecked(GetTickCount() - li.time) };', 'return new long[] { LastInputTick(), (long)unchecked(GetTickCount() - li.time) };')
    }
    @{
        Description = 'the display''s power state is GUID_CONSOLE_DISPLAY_STATE''s value from WM_POWERBROADCAST, read only when it carries one'
        Pattern = '(?s)if \(m == 0x0218 && w\.ToInt64\(\) == 0x8013 && l != IntPtr\.Zero && Marshal\.ReadInt32\(l, 16\) >= 4\) state = Marshal\.ReadInt32\(l, 20\);.*?Guid setting = new Guid\("6FE69556-704A-47A0-8F24-C28D936FDA47"\);'
        Mutation = @('new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47")', 'new Guid("02731015-4510-4526-99E6-E5A17EBD1AEA")')
    }
    @{
        Description = 'an unreadable notification state is -1, never the accepted 5'
        Pattern = 'public static int NotificationState\(\) \{ int s; return SHQueryUserNotificationState\(out s\) == 0 \? s : -1; \}'
        Mutation = @('SHQueryUserNotificationState(out s) == 0 ? s : -1;', 'SHQueryUserNotificationState(out s) == 0 ? s : 5;')
    }
    @{
        Description = 'the display hold asks for the display (ES_DISPLAY_REQUIRED) and the system, continuously'
        Pattern = 'public static bool HoldDisplay\(\) \{ return SetThreadExecutionState\(0x80000000 \| 0x2 \| 0x1\) != 0; \}'
        Mutation = @('SetThreadExecutionState(0x80000000 | 0x2 | 0x1)', 'SetThreadExecutionState(0x80000000 | 0x1)')
    }
    @{
        Description = 'an unreadable screen-saver state is -1, never "none running" (Opus on #741)'
        Pattern = 'public static int ScreenSaverRunning\(\) \{ uint v; return SpiUint\(0x0072, 0, out v, 0\) \? \(v != 0 \? 1 : 0\) : -1; \}'
        Mutation = @('(v != 0 ? 1 : 0) : -1;', '(v != 0 ? 1 : 0) : 0;')
    }
    @{
        Description = 'an unreadable foreground lock is -1, which the visible check refuses (Sol on #741)'
        Pattern = 'public static long ForegroundLockTimeout\(\) \{ uint v; return SpiUint\(0x2000, 0, out v, 0\) \? \(long\)v : -1; \}'
        Mutation = @('? (long)v : -1;', '? (long)v : int.MaxValue;')
    }
    @{
        Description = 'both SPI reads go through SystemParametersInfoW with a UINT out value'
        Pattern = '\[DllImport\("user32\.dll", EntryPoint="SystemParametersInfoW", SetLastError=true\)\] static extern bool SpiUint\(uint action, uint param, out uint value, uint winIni\);'
        Mutation = @('EntryPoint="SystemParametersInfoW"', 'EntryPoint="SystemParametersInfoA"')
    }
    @{
        Description = 'the input watch needs both hooks installed, and installs nothing once cancelled (the lead, Sol and CodeRabbit on #741)'
        Pattern = 'IntPtr kh = IntPtr\.Zero, mh = IntPtr\.Zero;\s+try \{\s+if \(!cancel\.WaitOne\(0\)\) \{\s+IntPtr module = GetModuleHandleW\(IntPtr\.Zero\);\s+kh = SetWindowsHookExW\(13, keyboardProc, module, 0\);\s+mh = SetWindowsHookExW\(14, mouseProc, module, 0\);\s+\}\s+installed = kh != IntPtr\.Zero && mh != IntPtr\.Zero;'
        Mutation = @('installed = kh != IntPtr.Zero && mh != IntPtr.Zero;', 'installed = kh != IntPtr.Zero || mh != IntPtr.Zero;')
    }
    @{
        Description = 'a watch cancelled during startup installs no hook late (Sol and CodeRabbit on #741)'
        Pattern = 'if \(!cancel\.WaitOne\(0\)\) \{\s+IntPtr module = GetModuleHandleW\(IntPtr\.Zero\);\s+kh = SetWindowsHookExW\(13'
        Mutation = @('if (!cancel.WaitOne(0)) {', 'if (true) {')
    }
    @{
        Description = 'the hooks come out on every path of the watch thread, in its finally, and StartWatch is released even when the thread throws (Sol on #741)'
        Pattern = '(?s)ready\.Set\(\);\s+if \(installed && !cancel\.WaitOne\(0\)\) \{ Msg msg; while \(GetMessageW\(out msg, IntPtr\.Zero, 0, 0\) > 0\) \{ \} \}\s+\} finally \{\s+if \(kh != IntPtr\.Zero\) UnhookWindowsHookEx\(kh\);\s+if \(mh != IntPtr\.Zero\) UnhookWindowsHookEx\(mh\);\s+ready\.Set\(\);\s+\}'
        Mutation = @("                if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh);`n                if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh);`n", '')
    }
    @{
        Description = 'StartWatch is false unless the hooks are in place within its bound'
        Pattern = 'if \(!ready\.WaitOne\(ms\) \|\| !installed\) \{ StopWatch\(\); return false; \}'
        Mutation = @('if (!ready.WaitOne(ms) || !installed) {', 'if (!ready.WaitOne(ms)) {')
    }
    @{
        Description = 'StopWatch cancels the watch and closes its events only after its thread has unhooked; a thread that will not end keeps them, and StopWatch says so (CodeRabbit and Sol on #741)'
        Pattern = '(?s)public static bool StopWatch\(\) \{\s+if \(watchThread != null\) \{\s+watchCancel\.Set\(\);\s+uint tid = watchThreadId;\s+if \(tid != 0\) PostThreadMessageW\(tid, 0x0012, IntPtr\.Zero, IntPtr\.Zero\);[^\r\n]*\s+if \(!watchThread\.Join\(2000\)\) return false;\s+watchThread = null; watchThreadId = 0; watchCancel = null;\s+\}\s+if \(watchEvent != IntPtr\.Zero\) \{ CloseHandle\(watchEvent\); watchEvent = IntPtr\.Zero; \}\s+if \(mouseEvent != IntPtr\.Zero\) \{ CloseHandle\(mouseEvent\); mouseEvent = IntPtr\.Zero; \}\s+if \(keyEvent != IntPtr\.Zero\) \{ CloseHandle\(keyEvent\); keyEvent = IntPtr\.Zero; \}\s+inputMarker = IntPtr\.Zero;\s+return true;\s+\}'
        Mutation = @('if (!watchThread.Join(2000)) return false;', 'watchThread.Join(2000);')
    }
    @{
        Description = 'the series'' real-input event is manual-reset and starts clear, so one driver''s read never clears it for the next; its two marked-input events are auto-reset, so each driver''s wait sees a new marked event; a watch needs a marker'
        Pattern = 'if \(watchThread != null \|\| marker == IntPtr\.Zero\) return false;\s+IntPtr real = CreateEventW\(IntPtr\.Zero, true, false, eventName\);\s+if \(real == IntPtr\.Zero\) return false;\s+IntPtr mouse = CreateEventW\(IntPtr\.Zero, false, false, eventName \+ "-mouse"\);\s+IntPtr key = CreateEventW\(IntPtr\.Zero, false, false, eventName \+ "-key"\);'
        Mutation = @('CreateEventW(IntPtr.Zero, true, false, eventName)', 'CreateEventW(IntPtr.Zero, false, false, eventName)')
    }
    @{
        Description = 'the marked-input events are auto-reset (a manual-reset one would show an old marked event as this run''s)'
        Pattern = 'IntPtr mouse = CreateEventW\(IntPtr\.Zero, false, false, eventName \+ "-mouse"\);\s+IntPtr key = CreateEventW\(IntPtr\.Zero, false, false, eventName \+ "-key"\);'
        Mutation = @('CreateEventW(IntPtr.Zero, false, false, eventName + "-mouse")', 'CreateEventW(IntPtr.Zero, true, false, eventName + "-mouse")')
    }
    @{
        Description = 'a driver opens the series'' events for SYNCHRONIZE only: it can wait on them, never set or clear the real-input one'
        Pattern = 'public static IntPtr OpenWatch\(string eventName\) \{ return OpenEventW\(0x00100000, false, eventName\); \}\s+public static IntPtr OpenMouseWatch\(string eventName\) \{ return OpenEventW\(0x00100000, false, eventName \+ "-mouse"\); \}\s+public static IntPtr OpenKeyWatch\(string eventName\) \{ return OpenEventW\(0x00100000, false, eventName \+ "-key"\); \}'
        Mutation = @('OpenEventW(0x00100000, false, eventName)', 'OpenEventW(0x001F0003, false, eventName)')
    }
    @{
        Description = 'a driver reads the watch without waiting, and anything but WAIT_TIMEOUT counts as input: a failed wait, or a zero or closed handle, never reads as quiet (Sol on #741)'
        Pattern = 'public static bool RealInputSignalled\(IntPtr watch\) \{ return watch == IntPtr\.Zero \|\| WaitForSingleObject\(watch, 0\) != 0x102; \}'
        Mutation = @('WaitForSingleObject(watch, 0) != 0x102;', 'WaitForSingleObject(watch, 0) == 0;')
    }
    @{
        Description = 'real input is an event without LLKHF_INJECTED (0x10) or LLMHF_INJECTED (0x01) and only it sets the real-input event; an injected one is counted, and only one carrying the series'' marker sets the marked event of its kind; Classify keeps nothing but counts (Opus, Sol and CodeRabbit on #741)'
        Pattern = 'static void Classify\(bool keyboard, uint flags, IntPtr extra\) \{\s+bool injected = keyboard \? \(flags & 0x10\) != 0 : \(flags & 0x01\) != 0;\s+if \(!injected\) \{ Interlocked\.Increment\(ref realInputs\); if \(watchEvent != IntPtr\.Zero\) SetEvent\(watchEvent\); return; \}\s+Interlocked\.Increment\(ref injectedInputs\);\s+if \(inputMarker == IntPtr\.Zero \|\| extra != inputMarker\) return;\s+if \(keyboard\) \{ Interlocked\.Increment\(ref markedKeys\); if \(keyEvent != IntPtr\.Zero\) SetEvent\(keyEvent\); \}\s+else \{ Interlocked\.Increment\(ref markedMice\); if \(mouseEvent != IntPtr\.Zero\) SetEvent\(mouseEvent\); \}\s+\}'
        Mutation = @('if (inputMarker == IntPtr.Zero || extra != inputMarker) return;', '')
    }
    @{
        Description = 'the keyboard hook reads two words of the event, its flags at 8 and its extra info at 16, never the key code, scan code or time (the lead and Opus on #741)'
        Pattern = 'public static IntPtr KeyboardEvent\(int code, IntPtr wParam, IntPtr lParam\) \{\s+if \(code >= 0\) Classify\(true, \(uint\)Marshal\.ReadInt32\(lParam, 8\), Marshal\.ReadIntPtr\(lParam, 16\)\);\s+return CallNextHookEx\(IntPtr\.Zero, code, wParam, lParam\);\s+\}'
        Mutation = @('Classify(true, (uint)Marshal.ReadInt32(lParam, 8), Marshal.ReadIntPtr(lParam, 16));', 'Classify(true, (uint)Marshal.ReadInt32(lParam, 0), Marshal.ReadIntPtr(lParam, 16));')
    }
    @{
        Description = 'the mouse hook reads two words of the event, its flags at 12 and its extra info at 24, never the position, wheel data or time (the lead and Opus on #741)'
        Pattern = 'public static IntPtr MouseEvent\(int code, IntPtr wParam, IntPtr lParam\) \{\s+if \(code >= 0\) Classify\(false, \(uint\)Marshal\.ReadInt32\(lParam, 12\), Marshal\.ReadIntPtr\(lParam, 24\)\);\s+return CallNextHookEx\(IntPtr\.Zero, code, wParam, lParam\);\s+\}'
        Mutation = @('Classify(false, (uint)Marshal.ReadInt32(lParam, 12), Marshal.ReadIntPtr(lParam, 24));', 'Classify(false, (uint)Marshal.ReadInt32(lParam, 0), Marshal.ReadIntPtr(lParam, 24));')
    }
)

# The PowerShell gates read the hooks (Opus on #741: with either port's RealInputSeen returning $false every gate
# falls back to the tick alone), the series' event names are fresh, the copy's own foreground before the unlock is
# refused, and the outer half checks the hooks' count after each run.
$framePacingRules += @(
    @{
        Description = 'the driver''s port reads the series'' real-input event (Opus''s P7 on #741)'
        Pattern = 'Add-Member -InputObject \$port -MemberType ScriptMethod -Name RealInputSeen -Value \{ \[FramePacingNative\]::RealInputSignalled\(\$this\.Watch\) \}'
        Mutation = @('-Name RealInputSeen -Value { [FramePacingNative]::RealInputSignalled($this.Watch) }', '-Name RealInputSeen -Value { $false }')
    }
    @{
        Description = 'the outer half''s port reads the hooks'' real-input count (Opus''s P8 on #741)'
        Pattern = 'Add-Member -InputObject \$port -MemberType ScriptMethod -Name RealInputSeen -Value \{ \[FramePacingNative\]::RealInputs\(\) -gt 0 \}'
        Mutation = @('-Name RealInputSeen -Value { [FramePacingNative]::RealInputs() -gt 0 }', '-Name RealInputSeen -Value { $false }')
    }
    @{
        Description = 'each series names its events afresh (Opus''s P15 on #741)'
        Pattern = '\$watchEvent = ''Local\\noctty-frame-pacing-input-'' \+ \[guid\]::NewGuid\(\)\.ToString\(''N''\)'
        Mutation = @("'Local\noctty-frame-pacing-input-' + [guid]::NewGuid().ToString('N')", "'Local\noctty-frame-pacing-input'")
    }
    @{
        Description = 'a copy that took the foreground from another window before the harness''s unlock makes the run inconclusive; one that took it when no window held it is recorded (Opus on #741)'
        Pattern = '\$record\.ForegroundBeforeUnlock = \[FramePacingNative\]::IsForeground\(\$hostWindow\)\s+if \(\$record\.ForegroundBeforeUnlock\) \{\s+if \(\[string\]::Equals\(\[string\]\$record\.ForegroundBeforeLaunch, ''none'', \[StringComparison\]::Ordinal\)\) \{ \$record\.ForegroundTakenFromNone = \$true \}\s+else \{ throw ''INCONCLUSIVE: [^\r\n]+\}\s+\}'
        Mutation = @("else { throw 'INCONCLUSIVE: the copy took the foreground", "else { Write-Host 'INCONCLUSIVE: the copy took the foreground")
    }
    @{
        Description = 'the outer half reads the hooks'' marked counts of each kind around each visible run and stops a series whose unlock or key probe the hook of its kind did not count (Opus and CodeRabbit on #741)'
        Pattern = '(?s)\$mouseBefore = if \(\$Visible\) \{ \[FramePacingNative\]::MarkedMouseInputs\(\) \} else \{ \[long\]0 \}\s+\$keyBefore = if \(\$Visible\) \{ \[FramePacingNative\]::MarkedKeyInputs\(\) \} else \{ \[long\]0 \}\s+\$result = Invoke-FramePacingOuterRun [^\r\n]+\s+if \(\$Visible\) \{\s+\$silence = Get-FramePacingHookSilence \$result\.Record \$mouseBefore \(\[FramePacingNative\]::MarkedMouseInputs\(\)\) \$keyBefore \(\[FramePacingNative\]::MarkedKeyInputs\(\)\) \(\[FramePacingNative\]::RealInputs\(\)\)\s+if \(\$silence\) \{ \$result\.Status = Get-FramePacingSilencedStatus \$result\.Status \$silence; \$result\.Failures = @\(@\(\$result\.Failures\) \+ \$silence\.Line\) \}\s+\}\s+\$results\.Add\(\$result\)'
        Mutation = @('if ($silence) { $result.Status =', 'if ($false) { $result.Status =')
    }
    @{
        Description = 'the display''s power state is what its notification said, never a constant (Opus''s N9 on #741)'
        Pattern = 't\.IsBackground = true; t\.Start\(\); t\.Join\(ms \+ 1000\);\s+return state;'
        Mutation = @("t.Join(ms + 1000);`n        return state;", "t.Join(ms + 1000);`n        return 1;")
    }
)

# The foreground lock must outlast the series (Greptile on #741): the admission computes the series' bound before its
# refusal and hands it to each driver, and the driver's deadline is the constant the bound is built from.
$framePacingRules += @(
    @{
        Description = 'the admission computes the series'' lock bound from the idle time it saw and the requested runs before it decides, and says both values'
        Pattern = '\$lockNeeded = Get-FramePacingLockNeedMs \$facts\.IdleMs \$facts\.MinIdleMs \$Runs\s+\$facts\.ForegroundLockNeededMs = \$lockNeeded\s+Write-Host "frame pacing: the foreground lock is [^\r\n]+\s+\$refusal = Get-FramePacingVisibleRefusal \$facts'
        Mutation = @('$facts.ForegroundLockNeededMs = $lockNeeded', '$facts.ForegroundLockNeededMs = 0')
    }
    @{
        Description = 'the driver''s deadline is the constant the run bound is built from'
        Pattern = '\$driverClock = \[Diagnostics\.Stopwatch\]::StartNew\(\)(?s).*?if \(\$driverClock\.ElapsedMilliseconds -ge \$script:DriverDeadlineMs\) \{ throw ''The driver ran past 30 minutes; the owned job was closed\.'' \}'
        Mutation = @('if ($driverClock.ElapsedMilliseconds -ge $script:DriverDeadlineMs) {', 'if ($driverClock.ElapsedMilliseconds -ge 3600000) {')
    }
    @{
        Description = 'the lock bound is the idle time (at least the minimum) plus every run''s longest duration'
        Pattern = 'function Get-FramePacingLockNeedMs\(\[long\] \$IdleMs, \[long\] \$MinIdleMs, \[int\] \$Runs\) \{\s+return \[long\]\[Math\]::Max\(\$IdleMs, \$MinIdleMs\) \+ \[long\]\$Runs \* \[long\]\$script:RunBoundMs\s+\}'
        Mutation = @(' + [long]$Runs * [long]$script:RunBoundMs', ' + [long]$script:RunBoundMs')
    }
)

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

# The foreground is taken in one place only and the keyboard probe sent from one, and the native layer sends two inputs,
# the unlock (an absolute move to the cursor's own pixel, UNLOCK-HOOK-01) and the VK_NONAME probe (the lead on #741), each from its one SendInput declaration: no Alt
# (VK_MENU) and nothing typed through SendInput anywhere in the harness. Controls: a second call, and another input
# added to the source, are both caught.
function Test-FramePacingInputDiscipline([string] $Text) {
    $foregroundCalls = [regex]::Matches($Text, '\[FramePacingNative\]::Foreground\(').Count
    $probeCalls = [regex]::Matches($Text, '\[FramePacingNative\]::KeyProbe\(').Count
    $sendInputs = [regex]::Matches($Text, '\bSendInput\(').Count
    return $foregroundCalls -eq 1 -and $probeCalls -eq 1 -and $sendInputs -eq 4 -and -not $Text.Contains('KEYEVENTF') -and -not $Text.Contains('VK_MENU') -and -not $Text.Contains('SendUnicodeText') -and -not $Text.Contains('SendKeys')
}
if (-not (Test-FramePacingInputDiscipline $framePacingText)) { throw 'The harness must take the foreground in one place and send no input but the one unlock and the key probe.' }
if (Test-FramePacingInputDiscipline ($framePacingText + "`n[FramePacingNative]::Foreground(`$h, 1, 1)")) { throw 'The input discipline check accepted a second foreground call.' }
if (Test-FramePacingInputDiscipline ($framePacingText.Replace('if (SendInput(1, unlock,', 'SendInput(1, keys, 40); if (SendInput(1, unlock,'))) { throw 'The input discipline check accepted a third SendInput.' }
# No other input API at all (Opus on #741: a declared keybd_event with a numeric VK passed the old check): neither
# keybd_event nor mouse_event, no cursor placement, no BlockInput, no key code for Alt. Each appended to the source
# is caught.
$framePacingInputApis = @('keybd_event', 'mouse_event', 'SetCursorPos', 'SetPhysicalCursorPos', 'BlockInput', 'KEYEVENTF', 'VK_MENU', 'SendKeys', 'SendUnicodeText')
function Get-FramePacingInputApis([string] $Text) { return @($framePacingInputApis | Where-Object { $Text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
if (@(Get-FramePacingInputApis $framePacingText).Count -ne 0) { throw "The frame-pacing harness names another input API: $(@(Get-FramePacingInputApis $framePacingText) -join ', ')." }
foreach ($api in $framePacingInputApis) { if (@(Get-FramePacingInputApis ($framePacingText + "`n[DllImport(`"user32.dll`")] static extern void $api();")).Count -ne 1) { throw "The input-API check missed $api." } }
# Every native call that inserts input or moves the foreground has the worker's stop check (the timeout's
# cancellation, then the input watch) as the statement right before it, on its own line, and there are exactly three
# (Opus and CodeRabbit on #741): the unlock's SendInput, the one SetForegroundWindow and the key probe's SendInput.
# Calls are found in the C# source with its comments and string and character literals blanked, with any whitespace
# before the parenthesis (CodeRabbit on #741), and each call is checked, not each line, so a second call on a guarded
# line fails. Nothing attaches to another thread's input, resets key state or raises a window (the lead on #741): no
# AttachThreadInput, SetKeyboardState or BringWindowToTop at all. The controls: Opus's N1 (a SetForegroundWindow before
# the tick check), a second SetForegroundWindow on the guarded line, the check before the foreground dropped, an
# attach added away from any call, a BringWindowToTop added behind its own check, and a spaced `SetForegroundWindow (`
# in IsForeground, outside the pinned worker (CodeRabbit), each caught.
function Get-FramePacingCsCode([string] $Text) {
    $start = $Text.IndexOf('public static class FramePacingNative', [StringComparison]::Ordinal)
    $end = $Text.IndexOf("`n'@", $start, [StringComparison]::Ordinal)
    $chars = $Text.Substring($start, $end - $start).ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $c = $chars[$i]
        if ($c -eq [char]'/' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq [char]'/') {
            while ($i -lt $chars.Length -and $chars[$i] -ne [char]"`n") { $chars[$i] = [char]' '; $i++ }
            continue
        }
        if ($c -eq [char]'/' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq [char]'*') {
            while ($i -lt $chars.Length -and -not ($chars[$i] -eq [char]'*' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq [char]'/')) { if ($chars[$i] -ne [char]"`n") { $chars[$i] = [char]' ' }; $i++ }
            if ($i -lt $chars.Length) { $chars[$i] = [char]' '; $chars[$i + 1] = [char]' '; $i += 2 }
            continue
        }
        if ($c -eq [char]'"' -or $c -eq [char]"'") {
            $quote = $c
            $chars[$i] = [char]' '; $i++
            while ($i -lt $chars.Length -and $chars[$i] -ne $quote) {
                if ($chars[$i] -eq [char]'\' -and $i + 1 -lt $chars.Length) { $chars[$i] = [char]' '; $i++ }
                if ($chars[$i] -ne [char]"`n") { $chars[$i] = [char]' ' }
                $i++
            }
            if ($i -lt $chars.Length) { $chars[$i] = [char]' ' }
            $i++
            continue
        }
        $i++
    }
    return [string]::new($chars)
}
function Get-FramePacingUnguardedCalls([string] $Text) {
    $code = Get-FramePacingCsCode $Text
    $count = 0
    foreach ($call in [regex]::Matches($code, '\b(SendInput|SetForegroundWindow|BringWindowToTop)\s*\(')) {
        $lineStart = $code.LastIndexOf("`n", [Math]::Max(0, $call.Index - 1)) + 1
        $prefix = $code.Substring($lineStart, $call.Index - $lineStart)
        if ($prefix -match 'static extern') { continue }
        $count++
        if ($prefix -notmatch '^\s*(if \()?$') { "not on its own line: $($prefix.Trim())$($call.Value)"; continue }
        $previousEnd = [Math]::Max(0, $lineStart - 1)
        $previousStart = $code.LastIndexOf("`n", [Math]::Max(0, $previousEnd - 1)) + 1
        $previous = $code.Substring($previousStart, $previousEnd - $previousStart).Trim()
        # The unlock's race re-read may sit between the gate and its call (Sol and the lead on #746), and only it.
        if ($previous -match '^if \(\(outcome = CursorAway\(aim, +\)\) != null\) return;$') {
            $previousEnd = [Math]::Max(0, $previousStart - 1)
            $previousStart = $code.LastIndexOf("`n", [Math]::Max(0, $previousEnd - 1)) + 1
            $previous = $code.Substring($previousStart, $previousEnd - $previousStart).Trim()
        }
        if ($previous -notmatch '^if \(\(outcome = Halt\(cancel, real, +\)\) != null\) return;$') { "unguarded: $($call.Value)" }
    }
    if ($count -ne 3) { "$count input or foreground calls, not 3" }
    $raising = [regex]::Matches($code, '\b(AttachThreadInput|SetKeyboardState|BringWindowToTop)\s*\(').Count
    if ($raising -ne 0) { "$raising AttachThreadInput, SetKeyboardState or BringWindowToTop names" }
}
$framePacingUnguarded = @(Get-FramePacingUnguardedCalls $framePacingText)
if ($framePacingUnguarded.Count -ne 0) { throw "The native input and foreground calls are not each behind the worker's stop check: $($framePacingUnguarded -join '; ')." }
foreach ($control in @(
        @{ Name = 'Opus''s N1, a SetForegroundWindow before the tick check'; Old = '                long before = LastInputTick();'; New = "                SetForegroundWindow(hwnd);`n                long before = LastInputTick();" }
        @{ Name = 'a second SetForegroundWindow on the guarded line'; Old = '                SetForegroundWindow(hwnd);'; New = '                SetForegroundWindow(hwnd); SetForegroundWindow(hwnd);' }
        @{ Name = 'the check before the foreground dropped'; Old = "                if ((outcome = Halt(cancel, real, `"real-input-before-foreground`")) != null) return;`n                SetForegroundWindow(hwnd);"; New = '                SetForegroundWindow(hwnd);' }
        @{ Name = 'an attach added away from any call'; Old = '                if (now >= 0 && now != before) tick = now;'; New = "                if (now >= 0 && now != before) tick = now;`n                AttachThreadInput(GetCurrentThreadId(), 0, false);" }
        @{ Name = 'a BringWindowToTop behind its own check'; Old = '                SetForegroundWindow(hwnd);'; New = "                SetForegroundWindow(hwnd);`n                if ((outcome = Halt(cancel, real, `"real-input-before-foreground`")) != null) return;`n                BringWindowToTop(hwnd);" }
        @{ Name = 'a spaced SetForegroundWindow in IsForeground (CodeRabbit)'; Old = 'public static bool IsForeground(IntPtr hwnd) { return GetForegroundWindow() == hwnd; }'; New = 'public static bool IsForeground(IntPtr hwnd) { SetForegroundWindow (hwnd); return GetForegroundWindow() == hwnd; }' }
    )) {
    $mutated = $framePacingText.Replace($control.Old, $control.New)
    if ([string]::Equals($mutated, $framePacingText, [StringComparison]::Ordinal)) { throw "The call-site control changed nothing: $($control.Name)." }
    if (@(Get-FramePacingUnguardedCalls $mutated).Count -eq 0) { throw "The call-site check accepted $($control.Name)." }
}
# The unlock's tick and the probe's are each set once on their worker, from the observed tick (Sol on #741: a late
# re-read must not replace it). The control: a re-read before the outcome.
function Test-FramePacingNativeTick([string] $Text) { return [regex]::Matches($Text, '(?<![\w.$])(?<!long )tick = (?!\$)').Count -eq 2 -and [regex]::Matches($Text, '(?m)^                if \(now >= 0 && now != before\) tick = now;$').Count -eq 2 }
if (-not (Test-FramePacingNativeTick $framePacingText)) { throw 'The native worker must set the unlock''s tick once, from the observed tick.' }
if (Test-FramePacingNativeTick ($framePacingText.Replace('                outcome = GetForegroundWindow() == hwnd ? "ok" : "refused";', "                tick = LastInputTick();`n                outcome = GetForegroundWindow() == hwnd ? `"ok`" : `"refused`";"))) { throw 'The native-tick check accepted a re-read before the outcome.' }
# The hooks see nothing but each event's flags and extra info and keep nothing but the counts (the lead, Sol and Opus
# on #741): exactly two installs, each of a proc assigned once, to KeyboardEvent or MouseEvent, whose bodies the rules
# above pin to those two reads and the next hook; an event's memory is read four times in all, at the two callbacks'
# flags and extra info offsets; no code marshals either hook struct; and the hooks come out twice, in the watch thread's finally. Only the outer half's visible branch starts the
# watch, once; no driver and no dry run does. The controls: a lambda installed in place of a callback, a third
# install, a struct marshalled, and Sol's three mutations (a keyboard field retained, a second StartWatch on the dry
# path, both unhook calls deleted), each caught.
function Get-FramePacingHookReads([string] $Text) {
    if ([regex]::Matches($Text, '\bSetWindowsHookExW\(').Count -ne 3) { 'not exactly the declaration and two installs' }
    foreach ($proc in @(@('keyboardProc', 'KeyboardEvent'), @('mouseProc', 'MouseEvent'))) {
        if ([regex]::Matches($Text, "\b$($proc[0]) = ").Count -ne 1 -or -not $Text.Contains("$($proc[0]) = $($proc[1]);")) { "$($proc[0]) is not $($proc[1]), once" }
    }
    if ([regex]::Matches($Text, 'PtrToStructure<(KbdHook|MouseHook)>').Count -ne 0) { 'a hook struct is marshalled' }
    $reads = @([regex]::Matches($Text, 'Marshal\.\w+\(lParam\b[^)]*\)') | ForEach-Object { $_.Value })
    if (($reads -join ' ') -ne 'Marshal.ReadInt32(lParam, 8) Marshal.ReadIntPtr(lParam, 16) Marshal.ReadInt32(lParam, 12) Marshal.ReadIntPtr(lParam, 24)') { "an event's memory is read beyond each callback's flags and extra info ($($reads -join ', '))" }
    if ([regex]::Matches($Text, '\bUnhookWindowsHookEx\(').Count -ne 3 -or -not ($Text -match '\} finally \{\s+if \(kh != IntPtr\.Zero\) UnhookWindowsHookEx\(kh\);\s+if \(mh != IntPtr\.Zero\) UnhookWindowsHookEx\(mh\);')) { 'the hooks do not come out in the watch thread''s finally' }
    $starts = [regex]::Matches($Text, '\[FramePacingNative\]::StartWatch\(')
    if ($starts.Count -ne 1 -or -not ($Text -match '(?s)if \(\$Visible\) \{\s+\[FramePacingNative\]::ResetWatchCounts\(\)\s+Start-FramePacingInputWatch \{ param\(\[string\] \$Name\) \[FramePacingNative\]::StartWatch\(\$Name, 5000, \[IntPtr\]\$inputMarker\) \} \$watchEvent')) { 'the watch is started other than once, in the outer half''s visible branch' }
}
$framePacingHookReads = @(Get-FramePacingHookReads $framePacingText)
if ($framePacingHookReads.Count -ne 0) { throw "The input watch's hooks may read more than each event's flags: $($framePacingHookReads -join '; ')." }
foreach ($control in @(
        @{ Name = 'a lambda installed in place of the keyboard callback'; Old = 'keyboardProc = KeyboardEvent;'; New = 'keyboardProc = (c, w, l) => CallNextHookEx(IntPtr.Zero, c, w, l);' }
        @{ Name = 'a third install'; Old = '                    mh = SetWindowsHookExW(14, mouseProc, module, 0);'; New = "                    mh = SetWindowsHookExW(14, mouseProc, module, 0);`n                    SetWindowsHookExW(2, keyboardProc, module, 0);" }
        @{ Name = 'a hook struct marshalled'; Old = 'static void Classify(bool keyboard, uint flags, IntPtr extra) {'; New = "static KbdHook last;`n    static void Classify(bool keyboard, uint flags, IntPtr extra) { last = Marshal.PtrToStructure<KbdHook>(IntPtr.Zero);" }
        @{ Name = 'Sol''s retained keyboard field'; Old = '    public static IntPtr KeyboardEvent(int code, IntPtr wParam, IntPtr lParam) {'; New = "    static uint lastKey;`n    static void Retain(IntPtr lParam) { lastKey = (uint)Marshal.ReadInt32(lParam, 0); }`n    public static IntPtr KeyboardEvent(int code, IntPtr wParam, IntPtr lParam) {" }
        @{ Name = 'Sol''s second StartWatch on the dry path'; Old = '        [void](New-Item -ItemType Directory -Path $root)'; New = "        if (-not `$Visible) { [void][FramePacingNative]::StartWatch(`$watchEvent, 5000) }`n        [void](New-Item -ItemType Directory -Path `$root)" }
        @{ Name = 'Sol''s deletion of both unhook calls'; Old = "                if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh);`n                if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh);`n"; New = '' }
    )) {
    $mutated = $framePacingText.Replace($control.Old, $control.New)
    if ([string]::Equals($mutated, $framePacingText, [StringComparison]::Ordinal)) { throw "The hook-read control changed nothing: $($control.Name)." }
    if (@(Get-FramePacingHookReads $mutated).Count -eq 0) { throw "The hook-read check accepted $($control.Name)." }
}
# Every variable a catch or finally in the harness reads is set before its try (Greptile on #741: the driver's
# finally read $watch, first set inside its try, so under StrictMode an early throw lost run.json). The harness's
# parameters, its top-level assignments, the enclosing function's parameters and earlier assignments, automatic
# variables, scoped ones ($script:, $env:) and what the block assigns itself count as set. The control: the driver
# with $watch first set inside its try again.
function Get-FramePacingUnsetCleanupReads([string] $Text) {
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $automatic = @('_', 'PSItem', 'PID', 'LASTEXITCODE', 'true', 'false', 'null', 'this', 'args', 'input', 'Matches', 'PSScriptRoot', 'PSCommandPath', 'ErrorActionPreference')
    $assignedIn = {
        param($Node, [int] $Before)
        $names = [Collections.Generic.List[string]]::new()
        foreach ($found in @($Node.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -or $n -is [Management.Automation.Language.ForEachStatementAst] -or $n -is [Management.Automation.Language.ParameterAst] }, $true))) {
            if ($found.Extent.StartOffset -ge $Before) { continue }
            $targets = if ($found -is [Management.Automation.Language.AssignmentStatementAst]) { @($found.Left) } elseif ($found -is [Management.Automation.Language.ForEachStatementAst]) { @($found.Variable) } else { @($found.Name) }
            foreach ($target in $targets) {
                foreach ($variable in @($target.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true))) {
                    if ($variable.Parent -is [Management.Automation.Language.MemberExpressionAst] -or $variable.Parent -is [Management.Automation.Language.IndexExpressionAst]) { continue }
                    $names.Add($variable.VariablePath.UserPath)
                }
            }
        }
        return , $names
    }
    $topLevel = [Collections.Generic.List[string]]::new()
    if ($null -ne $ast.ParamBlock) { foreach ($parameter in $ast.ParamBlock.Parameters) { $topLevel.Add($parameter.Name.VariablePath.UserPath) } }
    foreach ($statement in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] })) {
        foreach ($variable in @($statement.Left.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true))) { $topLevel.Add($variable.VariablePath.UserPath) }
    }
    foreach ($try in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.TryStatementAst] }, $true))) {
        $owner = $try.Parent
        while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
        $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $topLevel) { [void]$set.Add($name) }
        if ($null -ne $owner) { foreach ($name in (& $assignedIn $owner $try.Extent.StartOffset)) { [void]$set.Add($name) } }
        $blocks = @($try.CatchClauses | ForEach-Object { $_.Body }) + @($try.Finally | Where-Object { $null -ne $_ })
        foreach ($block in $blocks) {
            $own = & $assignedIn $block ([int]::MaxValue)
            foreach ($read in @($block.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true))) {
                $path = $read.VariablePath
                if ($path.IsScript -or $path.IsGlobal -or $path.IsDriveQualified) { continue }
                $name = $path.UserPath
                if ($automatic -contains $name -or $set.Contains($name) -or $own -contains $name) { continue }
                "`$$name, read at line $($read.Extent.StartLineNumber), is not set before its try"
            }
        }
    }
}
$framePacingSourceRaw = Get-Content -LiteralPath $framePacingScript -Raw
$framePacingUnsetReads = @(Get-FramePacingUnsetCleanupReads $framePacingSourceRaw | Select-Object -Unique)
if ($framePacingUnsetReads.Count -ne 0) { throw "A catch or finally in the frame-pacing harness reads a variable its try may not have set: $($framePacingUnsetReads -join '; ')." }
$framePacingLateWatch = $framePacingSourceRaw.Replace("    `$process = [IntPtr]::Zero`n    `$watch = [IntPtr]::Zero`n    `$mouseWatch = [IntPtr]::Zero`n    `$keyWatch = [IntPtr]::Zero`n    try {", "    `$process = [IntPtr]::Zero`n    `$mouseWatch = [IntPtr]::Zero`n    `$keyWatch = [IntPtr]::Zero`n    try {")
if ([string]::Equals($framePacingLateWatch, $framePacingSourceRaw, [StringComparison]::Ordinal)) { throw 'The cleanup-read control changed nothing.' }
if (@(Get-FramePacingUnsetCleanupReads $framePacingLateWatch | Where-Object { $_.StartsWith('$watch,', [StringComparison]::Ordinal) }).Count -eq 0) { throw 'The cleanup-read check accepted the driver''s $watch first set inside its try.' }

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
    'public static bool PostClose(IntPtr h, int pid)', 'public static int[] Children(int parent, string exe)',
    'public static string ConsoleGrid(uint pid)')
foreach ($signature in $framePacingNativeShared) {
    $theirs = Get-FramePacingCsMember $framePacingWorkingSetRaw $signature 'hidden-win11-working-set.ps1'
    $ours = Get-FramePacingCsMember $framePacingRaw $signature 'bench-frame-pacing.ps1'
    if (-not (Test-FramePacingOrdinal $ours $theirs)) { throw "FramePacingNative's '$signature' is not WorkingSetNative's, byte for byte." }
    $framePacingSharedCount++
}

# The hook and foreground code, pinned member for member (Opus and the lead on #741): the callbacks, Classify, the
# watch's start, stop and wait, its openers and read, the foreground and key-probe workers, their stop check, tick wait
# and verdict, the foreground reads, the two inputs, the posted key and the display read, each by the SHA-256 of its
# text. A change to any of them fails here until it has been reviewed and
# the pin updated. With the counts and the gates' bodies above, Opus's mutations are the controls: a callback keeping
# key codes (P1) or writing positions to a file (P2), a callback returning 1, which swallows input system-wide (P3,
# Q7), a second StartWatch in the driver (P5), a StopWatch that posts no WM_QUIT (P6), a hook thread that sleeps
# instead of pumping (P14), either port's RealInputSeen returning $false (P7, P8), and DisplayPower returning 1 (N9).
$framePacingMemberPins = @(
        @{ Signature = 'static void Classify(bool keyboard, uint flags, IntPtr extra)'; Sha256 = 'f91f573b0c0a25af0fda64a08502a82a67c1260ca0fa254b7071d3584427535b' }
        @{ Signature = 'public static IntPtr KeyboardEvent(int code, IntPtr wParam, IntPtr lParam)'; Sha256 = '79b93ded02cf636ed9f4e4c3ef40a7e1d8b96e6f050c005544d92cf29694a10d' }
        @{ Signature = 'public static IntPtr MouseEvent(int code, IntPtr wParam, IntPtr lParam)'; Sha256 = 'cd306b59f0ae8236bbfb734dd50c783c209433e4a8bc8775110c52d35477fba1' }
        @{ Signature = 'public static bool StartWatch(string eventName, int ms, IntPtr marker)'; Sha256 = '9b842cdf095f2ebc9426680364a55387ce1b41b587f0817e1ac866f4d8ed99a0' }
        @{ Signature = 'public static bool StopWatch()'; Sha256 = '6c590b35b80b0f03b2dc5be2b64255a00440fb6c028682b46514c2ec460eaf29' }
        @{ Signature = 'public static int Supervise(IntPtr latch, IntPtr process, IntPtr job, uint ms, out long observed, out long closed)'; Sha256 = '5a20daeca3cebdf16bb7b2a735491cc21fe355499711020b9a3b0b3a2ff68df2' }
        @{ Signature = 'public static int SuperviseDriver(IntPtr process, IntPtr job, uint ms, out long observed, out long closed)'; Sha256 = 'cfefbb2148da9b667465920a7d4881dc06fa69269246807e6ae29b165eb67208' }
        @{ Signature = 'public static IntPtr OpenWatch(string eventName)'; Sha256 = '0373a180689d836df904323b188c9902c36ca0e9ab4707ea0f8804cca959d682' }
        @{ Signature = 'public static IntPtr OpenMouseWatch(string eventName)'; Sha256 = '159b7ce4c47631883241b4759dc41fbe53a4ce168e17e07be1aa13b63e6c34ed' }
        @{ Signature = 'public static IntPtr OpenKeyWatch(string eventName)'; Sha256 = '73d5af8719166d57a9bd0fb47a3045750b85fb82f33d37b69cbbaf5f05c19c15' }
        @{ Signature = 'public static bool RealInputSignalled(IntPtr watch)'; Sha256 = '1921ddf3bf09c7aea7a5b5710f7f16f4006b309ed7b9206a0bb8940c49c065fc' }
        @{ Signature = 'public static string Foreground(IntPtr hwnd, int pid, int boundMs, long expectedTick, IntPtr watch, IntPtr mouseWatch, IntPtr marker, out long unlockTick)'; Sha256 = 'e9553fcd9fd3154255630f4a96bccf94e4bd5bd402edf5e09c86cb175455f162' }
        @{ Signature = 'public static string KeyProbe(IntPtr hwnd, int pid, int boundMs, long expectedTick, IntPtr watch, IntPtr keyWatch, IntPtr marker, out long probeTick)'; Sha256 = 'd54a1c5579311d2b943f36453928d790aca899f364952249faebf760ed515548' }
        @{ Signature = 'static string Halt(ManualResetEvent cancel, IntPtr watch, string why)'; Sha256 = '42855e03813a7961e466546f15dcf67d8d454dd028bff3a74af4ee7aaf6a62b6' }
        @{ Signature = 'static long WaitTickMove(long before, int ms)'; Sha256 = '32ee3d13b32a364382c9b7165f6ce063514f2e25f4ed0074966adcae16476b3c' }
        @{ Signature = 'public static string ProbeSeen(string what, long before, long now, bool hookSaw)'; Sha256 = '3f9f59b1e4ce02d654024eb96be86aabf2ff85ae1df0a9fa462086583da1380c' }
        @{ Signature = 'public static bool IsForeground(IntPtr hwnd)'; Sha256 = '1b0c0e41083dc1ad1ab7b3a6f0f0e6cc7328e4b53b9580b86cb1431fe50d29ec' }
        @{ Signature = 'public static bool AnyForeground()'; Sha256 = '78b4b2029bf02381ef0c9518f62c7f7fc739f903e7f8f8330a407d9fb7680984' }
        @{ Signature = 'static Input[] UnlockInput(IntPtr marker, int nx, int ny)'; Sha256 = '333e7eae95bfba81ad231d91df0f87b305821189d1a9af33a5bb79d8e205ae76' }
        @{ Signature = 'static Input[] UnlockHere(IntPtr marker, out CursorPoint aim)'; Sha256 = 'a534bdaa2b6eb36260638c25af34855a9df72607ad1f414da702960c9c3f4a3d' }
        @{ Signature = 'static string CursorAway(CursorPoint aim, string why)'; Sha256 = '63e229e124aec12dd1e663d8d2660b9f5fb0bb664ad653978090c7dff03e3706' }
        @{ Signature = 'static KeyInput[] KeyProbeInput(IntPtr marker)'; Sha256 = '70a417192acfcb6532d6d12c5f8fbe515e101fee13054cff88f83bfe586eda91' }
        @{ Signature = 'public static void PostKey(IntPtr h, int pid, int vk)'; Sha256 = '9cf7bc2816f4492123db1ed2270c65433a0c337cad627c2f128059d7a190e505' }
        @{ Signature = 'public static int DisplayPower(int ms)'; Sha256 = '2c687c50bea3d35f78d113c2481753582d52c27cddb3cb6a3a760d9f9a18fab7' }
)
function Get-FramePacingHookProblems([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    foreach ($pin in $framePacingMemberPins) {
        $start = $Text.IndexOf($pin.Signature, [StringComparison]::Ordinal)
        if ($start -lt 0) { "no $($pin.Signature)"; continue }
        $member = Get-FramePacingCsMember $Text $pin.Signature 'bench-frame-pacing.ps1'
        $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($member.Replace("`r`n", "`n"))) | ForEach-Object { $_.ToString('x2') }) -join ''
        if (-not [string]::Equals($hash, $pin.Sha256, [StringComparison]::Ordinal)) { "$($pin.Signature) changed (SHA-256 $hash)" }
    }
    foreach ($body in @('-Name RealInputSeen -Value { [FramePacingNative]::RealInputSignalled($this.Watch) }', '-Name RealInputSeen -Value { [FramePacingNative]::RealInputs() -gt 0 }')) {
        if (-not $Text.Contains($body)) { "a port's RealInputSeen is not '$body'" }
    }
    @(Get-FramePacingHookReads $Text)
}
$framePacingHookProblems = @(Get-FramePacingHookProblems $framePacingText)
if ($framePacingHookProblems.Count -ne 0) { throw "The hook and foreground code is not the reviewed code: $($framePacingHookProblems -join '; '). Review the change, then update its pin." }
$framePacingHookControls = @(
    @{ Name = 'P1, a callback keeping key codes'; Old = '        if (code >= 0) Classify(true, (uint)Marshal.ReadInt32(lParam, 8), Marshal.ReadIntPtr(lParam, 16));'; New = '        if (code >= 0) { Keys[(uint)Marshal.ReadInt32(lParam, 12)] = (uint)Marshal.ReadInt32(lParam, 0); Classify(true, (uint)Marshal.ReadInt32(lParam, 8), Marshal.ReadIntPtr(lParam, 16)); }' }
    @{ Name = 'P2, a callback writing positions to a file'; Old = '        if (code >= 0) Classify(false, (uint)Marshal.ReadInt32(lParam, 12), Marshal.ReadIntPtr(lParam, 24));'; New = '        if (code >= 0) { System.IO.File.AppendAllText(System.IO.Path.GetTempFileName(), Marshal.ReadInt32(lParam, 0) + "," + Marshal.ReadInt32(lParam, 4)); Classify(false, (uint)Marshal.ReadInt32(lParam, 12), Marshal.ReadIntPtr(lParam, 24)); }' }
    @{ Name = 'P3, the mouse callback returning 1'; Old = "        if (code >= 0) Classify(false, (uint)Marshal.ReadInt32(lParam, 12), Marshal.ReadIntPtr(lParam, 24));`n        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);"; New = "        if (code >= 0) Classify(false, (uint)Marshal.ReadInt32(lParam, 12), Marshal.ReadIntPtr(lParam, 24));`n        return new IntPtr(1);" }
    @{ Name = 'Q7, the keyboard callback returning 1'; Old = "        if (code >= 0) Classify(true, (uint)Marshal.ReadInt32(lParam, 8), Marshal.ReadIntPtr(lParam, 16));`n        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);"; New = "        if (code >= 0) Classify(true, (uint)Marshal.ReadInt32(lParam, 8), Marshal.ReadIntPtr(lParam, 16));`n        return new IntPtr(1);" }
    @{ Name = 'P5, a second StartWatch in the driver'; Old = '        $port = New-FramePacingPort $watch $mouseWatch $keyWatch $InputMarker'; New = "        `$port = New-FramePacingPort `$watch `$mouseWatch `$keyWatch `$InputMarker`n        [void][FramePacingNative]::StartWatch('Local\fp', 5000, [IntPtr]1)" }
    @{ Name = 'R1, IsForeground returning false (Opus)'; Old = 'public static bool IsForeground(IntPtr hwnd) { return GetForegroundWindow() == hwnd; }'; New = 'public static bool IsForeground(IntPtr hwnd) { return false; }' }
    @{ Name = 'the marker ignored, so another program''s injected event proves a dead hook alive'; Old = 'if (inputMarker == IntPtr.Zero || extra != inputMarker) return;'; New = '' }
    @{ Name = 'P6, a StopWatch that posts no WM_QUIT'; Old = '            if (tid != 0) PostThreadMessageW(tid, 0x0012, IntPtr.Zero, IntPtr.Zero); // WM_QUIT'; New = '' }
    @{ Name = 'P14, a hook thread that sleeps instead of pumping'; Old = '{ Msg msg; while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) { } }'; New = '{ while (!cancel.WaitOne(0)) Thread.Sleep(100); }' }
    @{ Name = 'P7, the driver port''s RealInputSeen returning $false'; Old = '-Name RealInputSeen -Value { [FramePacingNative]::RealInputSignalled($this.Watch) }'; New = '-Name RealInputSeen -Value { $false }' }
    @{ Name = 'P8, the outer port''s RealInputSeen returning $false'; Old = '-Name RealInputSeen -Value { [FramePacingNative]::RealInputs() -gt 0 }'; New = '-Name RealInputSeen -Value { $false }' }
    @{ Name = 'N9, DisplayPower returning 1'; Old = "t.Join(ms + 1000);`n        return state;"; New = "t.Join(ms + 1000);`n        return 1;" }
)
foreach ($control in $framePacingHookControls) {
    $mutated = $framePacingText.Replace($control.Old, $control.New)
    if ([string]::Equals($mutated, $framePacingText, [StringComparison]::Ordinal)) { throw "The hook-pin control changed nothing: $($control.Name)." }
    if (@(Get-FramePacingHookProblems $mutated).Count -eq 0) { throw "The hook pins accepted $($control.Name)." }
}

# Every posted key is right behind a gate, and there are exactly three (Opus's R6 on #741): F5, F6 and the dry run's
# VK_NONAME, whose gate is a no-op off a visible run. The control: an ungated fourth after the post-foreground wait.
function Get-FramePacingUngatedPosts([string] $Text) {
    $lines = @($Text -split "`r?`n")
    $posts = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '\[FramePacingNative\]::PostKey\(') { continue }
        $posts++
        $j = $i - 1
        while ($j -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$j])) { $j-- }
        if ($j -lt 0 -or $lines[$j] -notmatch '^\s*Assert-Quiet ''[^\r\n]+''\s*$') { "ungated: $($lines[$i].Trim())" }
    }
    if ($posts -ne 3) { "$posts posted keys, not 3" }
}
if (@(Get-FramePacingUngatedPosts $framePacingText).Count -ne 0) { throw "A posted key is not right behind a gate: $(@(Get-FramePacingUngatedPosts $framePacingText) -join '; ')." }
$framePacingR6 = $framePacingText.Replace("            `$settled = Wait-Quiet `$script:QuietMs 30000`n        } else {", "            `$settled = Wait-Quiet `$script:QuietMs 30000`n            [FramePacingNative]::PostKey(`$pane, `$nocttyPid, 0x74)`n        } else {")
if ([string]::Equals($framePacingR6, $framePacingText, [StringComparison]::Ordinal)) { throw 'The posted-key control changed nothing.' }
if (@(Get-FramePacingUngatedPosts $framePacingR6).Count -eq 0) { throw 'The posted-key check accepted Opus''s R6, an ungated fourth PostKey.' }

# The keyboard probe is VK_NONAME, and noctty's own test shows what it writes (the lead on #741): the Zig test in
# win32/input.zig feeds it through the key message builder and the encoder and expects no text with Win32 input mode
# off and one character-less record each way with it on.
$framePacingInputZig = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32\input.zig') -Raw
foreach ($want in @('test "win32 VK_NONAME, the frame-pacing keyboard probe, writes no character to the pseudoconsole"', '"\x1b[252;0;0;1;0;1_"', '"\x1b[252;0;0;0;0;1_"', 'keyMessage(case.msg, 0xFC, case.lParam, false, null, false, false)', 'try std.testing.expectEqualStrings("", legacy.buffered());')) {
    if (-not $framePacingInputZig.Contains($want)) { throw "win32/input.zig no longer holds the frame-pacing keyboard probe's test ($want)." }
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
$framePacingConstantNames = @('Cols', 'Rows', 'GridRows', 'FontFamily', 'FontSize', 'PayloadWorkload', 'PayloadBytes', 'PayloadSeed', 'IntervalCapacity', 'QuietMs', 'EchoQuietMs', 'QuietBusyPercent', 'MinIdleSeconds', 'ForegroundBoundMs', 'ResponseBoundMs', 'NotificationsAccepted', 'DisplayOn', 'DrainMs', 'DriverDeadlineMs', 'StagingBoundMs', 'RunBoundMs')
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
$framePacingPinned = 'Cols=140 Rows=45 GridRows=43 FontFamily=Consolas FontSize=16 PayloadWorkload=stream PayloadBytes=4194304 PayloadSeed=121 IntervalCapacity=2048 QuietMs=1000 EchoQuietMs=500 QuietBusyPercent=30 MinIdleSeconds=300 ForegroundBoundMs=5000 ResponseBoundMs=5000 NotificationsAccepted=5 DisplayOn=1 DrainMs=1000 DriverDeadlineMs=1800000 StagingBoundMs=300000 RunBoundMs=2100000'
if (-not (Test-FramePacingOrdinal (Get-FramePacingConstantValues $framePacingText) $framePacingPinned)) { throw "The frame-pacing constants changed: $(Get-FramePacingConstantValues $framePacingText)" }
foreach ($control in @(@('$script:MinIdleSeconds = 300', '$script:MinIdleSeconds = 60'), @('$script:ForegroundBoundMs = 5000', '$script:ForegroundBoundMs = 600000'), @('$script:QuietBusyPercent = 30', '$script:QuietBusyPercent = 100'), @('$script:RunBoundMs = 2100000', '$script:RunBoundMs = 60000'))) {
    $mutated = $framePacingText.Replace($control[0], $control[1])
    if ([string]::Equals($mutated, $framePacingText, [StringComparison]::Ordinal)) { throw "The constants control changed nothing: $($control[1])." }
    if (Test-FramePacingOrdinal (Get-FramePacingConstantValues $mutated) $framePacingPinned) { throw "The constants check accepted $($control[1])." }
}
if ($framePacingText -match '(?i)\[int\]\s*\$MinIdleSeconds') { throw 'The idle time must be the pinned constant, never a parameter.' }
# A run's bound is the driver's deadline plus the staging bound, each enforced (Sol on #741).
$framePacingConstant = { param([string] $Name) [long]([regex]::Match($framePacingText, "(?m)^\`$script:$Name = (\d+)").Groups[1].Value) }
if ((& $framePacingConstant 'RunBoundMs') -ne (& $framePacingConstant 'DriverDeadlineMs') + (& $framePacingConstant 'StagingBoundMs')) { throw 'RunBoundMs must be DriverDeadlineMs plus StagingBoundMs.' }
if (($framePacingText.Replace('[ValidateRange(0, 3600)] [int] $QuietWaitSeconds = 900,', "[ValidateRange(0, 3600)] [int] `$QuietWaitSeconds = 900,`n    [ValidateRange(0, 3600)] [int] `$MinIdleSeconds = 0,")) -notmatch '(?i)\[int\]\s*\$MinIdleSeconds') { throw 'The idle-parameter control changed nothing.' }
$framePacingSaved = @{}
foreach ($name in $framePacingConstantNames + @('Utf8', 'MouseHookMissed', 'KeyHookMissed', 'FramePacingVoidReasons')) {
    $existing = Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
    $framePacingSaved[$name] = [pscustomobject]@{ Existed = $null -ne $existing; Value = $(if ($null -ne $existing) { $existing.Value } else { $null }) }
}
try {
    . ([scriptblock]::Create(($framePacingConstantLines -join "`n")))
    $script:Utf8 = [Text.UTF8Encoding]::new($false)
    # The two hook-miss refusals, by name (Greptile on #741), which the driver throws and the outer half recognizes.
    $framePacingHookLines = @([regex]::Matches($framePacingText, "(?m)^\`$script:(?:MouseHookMissed|KeyHookMissed) = '(?:[^']|'')*'[ \t]*$") | ForEach-Object { $_.Value.Trim() })
    if ($framePacingHookLines.Count -ne 2) { throw 'The frame-pacing harness must name each hook-miss refusal once.' }
    . ([scriptblock]::Create(($framePacingHookLines -join "`n")))
    # The voided series' reason codes (the lead and Sol on #741, round 9), pinned here: a fixed set, no text, no numbers.
    $framePacingReasonLine = @([regex]::Matches($framePacingText, "(?m)^\`$script:FramePacingVoidReasons = @\([^\r\n]+\)[ \t]*$") | ForEach-Object { $_.Value.Trim() })
    if ($framePacingReasonLine.Count -ne 1) { throw 'The frame-pacing harness must name its void reasons once.' }
    . ([scriptblock]::Create($framePacingReasonLine[0]))
    $framePacingReasonsPinned = 'hook-count tick-moved tick-unread watch-not-stopped run-saw-input guard-tripped run-failed run-inconclusive incomplete mixed-build mixed-environment harness-changed'
    if (-not (Test-FramePacingOrdinal ($script:FramePacingVoidReasons -join ' ') $framePacingReasonsPinned) -or @($script:FramePacingVoidReasons | Where-Object { $_ -notmatch '^[a-z]+(-[a-z]+)*$' }).Count -ne 0) { throw "The void reasons changed: $($script:FramePacingVoidReasons -join ' ')." }
    $framePacingVoidedKeys = 'Schema Verdict ExitCode Reasons RealInputsSeen InjectedInputsSeen SeriesId HarnessSha256 MeasureHead ExeSHA256'
    $framePacingActual = ($framePacingConstantNames | ForEach-Object { "$_=$((Get-Variable -Scope Script -Name $_).Value)" }) -join ' '
    if (-not (Test-FramePacingOrdinal $framePacingActual $framePacingPinned)) { throw "The frame-pacing workload's constants changed ($framePacingActual); runs before and after the change are not comparable." }
    $framePacingCases = & {
        # Every extracted function runs under the harness's own StrictMode and error preference (CodeRabbit on #741:
        # a test without them passes code the harness throws on).
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        foreach ($name in @('Add-Line', 'New-FramePacingConfigText', 'Test-FramePacingConfigBytes', 'Get-FramePacingExpectedArgv', 'Test-WorkingSetArgv', 'Get-FramePacingVisibleRefusal', 'Get-FramePacingLockNeedMs', 'Get-FramePacingRecordProblems', 'Get-FramePacingRunStatus', 'Get-FramePacingInputStop', 'Get-FramePacingSupervisionStop', 'Test-FramePacingHookMissed', 'Assert-FramePacingPollGate', 'Test-FramePacingRunInput', 'Get-FramePacingVoidReasons', 'Test-FramePacingHarnessChanged', 'Get-Sha256', 'Get-FramePacingLoadedHarnessSha256', 'Read-FramePacingRunRecord', 'Get-FramePacingTickStop', 'Get-FramePacingFinalInput', 'Complete-FramePacingSeries', 'Get-FramePacingSilencedStatus', 'Get-FramePacingHookSilence', 'Get-FramePacingLockShortfall', 'Invoke-FramePacingKeyProbe', 'Test-FramePacingConsoleTyped', 'Test-FramePacingInputGate', 'Assert-FramePacingInputGate', 'Invoke-FramePacingForeground', 'Start-FramePacingInputWatch', 'Get-FramePacingSeries', 'Write-FramePacingSummary', 'Get-FramePacingExitCode', 'Get-FramePacingIntervalStats', 'Get-BenchMedian', 'Get-BenchPercentile', 'Get-FramePacingMarkerTail', 'Get-FramePacingWorkloadSha256', 'Get-BytesSha256')) {
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
        $ok = [pscustomobject]@{ OwnDesktop = 'Default'; InputDesktop = 'Default'; Composition = 1; RemoteSession = $false; NotificationState = 5; DisplayPower = 1; ScreenSaverRunning = 0; ForegroundLockTimeoutMs = 2147483647; ForegroundLockNeededMs = 10800000; IdleMs = 400000; MinIdleMs = 300000; LastInputTick = 77; QuietSinceTick = -1 }
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
            @{ Name = 'a screen saver (Opus on #741)'; Facts = @{ ScreenSaverRunning = 1 } }
            @{ Name = 'an unreadable screen-saver state'; Facts = @{ ScreenSaverRunning = -1 } }
            @{ Name = 'no foreground lock (Sol on #741)'; Facts = @{ ForegroundLockTimeoutMs = 0 } }
            @{ Name = 'the default 200,000 ms lock with the 300 s idle requirement (Greptile on #741)'; Facts = @{ ForegroundLockTimeoutMs = 200000; ForegroundLockNeededMs = (Get-FramePacingLockNeedMs 300000 300000 1) } }
            @{ Name = 'a lock equal to the series'' bound'; Facts = @{ ForegroundLockTimeoutMs = 10800000 } }
            @{ Name = 'no lock bound'; Facts = @{ ForegroundLockNeededMs = -1 } }
            @{ Name = 'an unreadable foreground lock'; Facts = @{ ForegroundLockTimeoutMs = -1 } }
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
        $above = $ok.PSObject.Copy(); $above.ForegroundLockNeededMs = Get-FramePacingLockNeedMs 300000 300000 5; $above.ForegroundLockTimeoutMs = $above.ForegroundLockNeededMs + 1
        if ($null -ne (Get-FramePacingVisibleRefusal $above)) { throw 'The visible check refused a foreground lock above the series'' bound.' }
        # The bound itself (Greptile on #741): the idle time seen, at least the minimum, plus each run's longest. The
        # control: a bound that ignores the number of runs.
        $needCases = @(@(400000, 300000, 5, (400000 + 5 * 2100000)), @(1000, 300000, 1, (300000 + 2100000)), @(-1, 300000, 50, (300000 + 50 * 2100000)))
        function Get-FramePacingNeedMiss { foreach ($case in $needCases) { $got = Get-FramePacingLockNeedMs $case[0] $case[1] $case[2]; if ($got -ne $case[3]) { return "idle $($case[0]), $($case[2]) runs: $got, not $($case[3])" } }; return $null }
        $needMiss = Get-FramePacingNeedMiss
        if ($needMiss) { throw "The lock bound: $needMiss." }
        $needText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingLockNeedMs' 'bench-frame-pacing.ps1'
        $needControl = $needText.Replace(' + [long]$Runs * [long]$script:RunBoundMs', ' + [long]$script:RunBoundMs')
        if ([string]::Equals($needControl, $needText, [StringComparison]::Ordinal)) { throw 'The lock-bound control changed nothing.' }
        & { . ([scriptblock]::Create($needControl)); if ($null -eq (Get-FramePacingNeedMiss)) { throw 'The lock-bound cases accepted a bound that ignores the runs.' } }
        $refusalText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingVisibleRefusal' 'bench-frame-pacing.ps1'
        $tickControl = $refusalText.Replace('if ($Facts.LastInputTick -ne $Facts.QuietSinceTick)', 'if ($false)')
        if ([string]::Equals($tickControl, $refusalText, [StringComparison]::Ordinal)) { throw 'The tick control changed nothing.' }
        & { . ([scriptblock]::Create($tickControl)); $moved = $ok.PSObject.Copy(); $moved.QuietSinceTick = 76; if ($null -ne (Get-FramePacingVisibleRefusal $moved)) { throw 'The tick control did not accept input since the series'' tick.' } }
        $refusalControl = $refusalText.Replace('if ($Facts.IdleMs -lt 0 -or $Facts.IdleMs -lt $Facts.MinIdleMs)', 'if ($false)')
        if ([string]::Equals($refusalControl, $refusalText, [StringComparison]::Ordinal)) { throw 'The visible-check control changed nothing.' }
        & { . ([scriptblock]::Create($refusalControl)); $recent = $ok.PSObject.Copy(); $recent.IdleMs = 1000; if ($null -ne (Get-FramePacingVisibleRefusal $recent)) { throw 'The visible-check control did not accept recent input.' } }
        $lockControl = $refusalText.Replace('if ($lockShortfall) {', 'if ($false) {')
        if ([string]::Equals($lockControl, $refusalText, [StringComparison]::Ordinal)) { throw 'The foreground-lock control changed nothing.' }
        & { . ([scriptblock]::Create($lockControl)); $unlocked = $ok.PSObject.Copy(); $unlocked.ForegroundLockTimeoutMs = 0; if ($null -ne (Get-FramePacingVisibleRefusal $unlocked)) { throw 'The foreground-lock control did not accept a lock of 0.' } }
        $cases.Add('visible-refusal (idle Default; private, locked, other input desktop, no or unreadable composition, remote, a full-screen app, presentation mode, the display off or dimmed, a screen saver or an unreadable one, a foreground lock of 0 or unreadable, the default 200,000 ms with the 300 s idle requirement, equal to the series'' bound, or with no bound, recent or unreadable input, input since the series'' tick; a later run after its own unlock; a lock above the bound admitted; the bound tabled; idle, tick, foreground-lock and run-blind bound controls)')

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
        $visibleOk = @{ Mode = 'visible'; VisibleRefusal = $null; Foreground = 'ok'; KeyProbe = 'ok'; Cloaked = 0; ForegroundHeld = $true; FocusHeld = $true; InputDuringRun = $false; BusyPercentBefore = 10.0; BusyPercentAtArm = 12.0 }
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
            @{ Name = 'a keyboard probe that timed out (Opus on #741, round 5)'; Change = @{ KeyProbe = 'timeout' } }
            @{ Name = 'a keyboard probe never sent'; Change = @{ KeyProbe = $null } }
        )
        foreach ($case in $softCases) {
            $problems = @(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk $case.Change)))
            if ($problems.Count -eq 0 -or @($problems | Where-Object { -not $_.StartsWith('inconclusive:', [StringComparison]::Ordinal) }).Count -ne 0) { throw "The verdict did not call $($case.Name) inconclusive alone (problems: $($problems -join '; '))." }
        }
        $verdictText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingRecordProblems' 'bench-frame-pacing.ps1'
        $verdictControl = $verdictText.Replace('if ($Record.IntervalOverflow -ne 0) {', 'if ($false) {')
        if ([string]::Equals($verdictControl, $verdictText, [StringComparison]::Ordinal)) { throw 'The verdict control changed nothing.' }
        & { . ([scriptblock]::Create($verdictControl)); if (@(Get-FramePacingRecordProblems (New-FramePacingRecord @{ IntervalOverflow = 1 })).Count -ne 0) { throw 'The verdict control did not accept an overflow.' } }
        $verdictProbeControl = [regex]::Replace($verdictText, '(?m)^\s+if \(-not \[string\]::Equals\(\[string\]\$Record\.KeyProbe, [^\r\n]+\r?\n', '')
        if ([string]::Equals($verdictProbeControl, $verdictText, [StringComparison]::Ordinal)) { throw 'The verdict''s probe control changed nothing.' }
        & { . ([scriptblock]::Create($verdictProbeControl)); if (@(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk @{ KeyProbe = 'timeout' }))).Count -ne 0) { throw 'The verdict''s probe control did not accept a timed-out probe.' } }
        # A dead keyboard hook (Sol on #741, round 9): the driver refused the run with its name and never assigned the
        # probe, which it did send; the verdict carries that failure and no "not sent" line. The control: the probe line
        # without its hook-miss exception.
        $deadHookProblems = @(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk @{ KeyProbe = $null; Error = $script:KeyHookMissed })))
        if (@($deadHookProblems | Where-Object { $_.Contains('keyboard probe was') }).Count -ne 0 -or @($deadHookProblems | Where-Object { $_.Contains($script:KeyHookMissed) }).Count -ne 1) { throw "A dead keyboard hook's verdict: $($deadHookProblems -join '; ')." }
        $verdictDeadControl = $verdictText.Replace(" -and -not [string]::Equals([string]`$Record.Error, `$script:KeyHookMissed, [StringComparison]::Ordinal)) {", ') {')
        if ([string]::Equals($verdictDeadControl, $verdictText, [StringComparison]::Ordinal)) { throw 'The dead-hook verdict control changed nothing.' }
        & { . ([scriptblock]::Create($verdictDeadControl)); if (@(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk @{ KeyProbe = $null; Error = $script:KeyHookMissed })) | Where-Object { $_.Contains('keyboard probe was not sent') }).Count -eq 0) { throw 'The dead-hook verdict control did not bring the line back.' } }
        # After a mouse-hook miss the probe really was not sent (Opus on #741, round 10): that line stays. The control:
        # the exclusion widened to either hook's miss, which drops it.
        $mouseMissProblems = @(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk @{ Foreground = $null; KeyProbe = $null; Error = $script:MouseHookMissed })))
        if (@($mouseMissProblems | Where-Object { $_.Contains('keyboard probe was not sent') }).Count -ne 1) { throw "A mouse-hook miss's verdict lost its true 'not sent' line: $($mouseMissProblems -join '; ')." }
        $verdictMouseControl = $verdictText.Replace(" -and -not [string]::Equals([string]`$Record.Error, `$script:KeyHookMissed, [StringComparison]::Ordinal)) {", " -and -not (Test-FramePacingHookMissed ([string]`$Record.Error))) {")
        if ([string]::Equals($verdictMouseControl, $verdictText, [StringComparison]::Ordinal)) { throw 'The mouse-hook verdict control changed nothing.' }
        & { . ([scriptblock]::Create($verdictMouseControl)); if (@(Get-FramePacingRecordProblems (New-FramePacingRecord (Join-FramePacingChange $visibleOk @{ Foreground = $null; KeyProbe = $null; Error = $script:MouseHookMissed })) | Where-Object { $_.Contains('keyboard probe was not sent') }).Count -ne 0) { throw 'The mouse-hook verdict control did not drop the line.' } }
        $cases.Add("verdict (complete dry run and visible run; $($hardCases.Count) failures; $($softCases.Count) inconclusive alone; a dead keyboard hook with no 'not sent' line, a mouse-hook miss with it; overflow, keyboard-probe, dead-hook and mouse-hook controls)")

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

        # A visible run stopped for the session's sake (CodeRabbit, Sol and Opus on #741): a driver the gate or the
        # staging bound kept from launching, or one whose job was closed on real input, is inconclusive only when that
        # stop was the run's sole problem; with a tripped guard, or an owned-job cleanup that failed beside it, the
        # run's status stands. The control: the outer-failure check removed, which hides the cleanup failure.
        $refusal = 'INCONCLUSIVE: real (non-injected) keyboard or mouse input came before the visible driver''s launch.'
        $inputStopCases = @(
            @{ Want = $null; Args = @(@(), @(), $null, $null) }
            @{ Want = 'inconclusive'; Args = @(@(), @($refusal), $refusal, 'the visible driver was not launched: real input') }
            @{ Want = $null; Args = @(@('clipboard changed'), @($refusal), $refusal, 'the visible driver was not launched: real input') }
            @{ Want = $null; Args = @(@(), @('owned job cleanup: x', $refusal), $refusal, 'the visible driver was not launched: real input') }
            @{ Want = 'inconclusive'; Args = @(@(), @(), $null, 'real input came during the run, and the run''s job was closed') }
            @{ Want = $null; Args = @(@(), @('owned job cleanup: x'), $null, 'real input came during the run, and the run''s job was closed') }
        )
        function Get-FramePacingInputStopMiss {
            foreach ($case in $inputStopCases) {
                $a = $case.Args
                $got = Get-FramePacingInputStop $a[0] $a[1] $a[2] $a[3]
                $kind = if ($null -eq $got) { $null } elseif ($got.StartsWith('inconclusive:', [StringComparison]::Ordinal)) { 'inconclusive' } else { $got }
                if ($kind -ne $case.Want) { return "guards $(@($a[0]).Count), outer '$(@($a[1]) -join '; ')', stop '$($a[3])': $got" }
            }
            if ((Get-FramePacingRunStatus @() @('owned job cleanup: x', $refusal) $null $null @()) -ne 'failed') { return 'a stopped run with a failed cleanup is not failed' }
            return $null
        }
        $inputStopMiss = Get-FramePacingInputStopMiss
        if ($inputStopMiss) { throw "The stopped run's status: $inputStopMiss." }
        $inputStopText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingInputStop' 'bench-frame-pacing.ps1'
        $inputStopControl = $inputStopText.Replace("    if (@(`$OuterFailures | Where-Object { -not [string]::Equals(`$_, `$NoLaunchRefusal, [StringComparison]::Ordinal) }).Count -gt 0) { return `$null }`n", '')
        if ([string]::Equals($inputStopControl, $inputStopText, [StringComparison]::Ordinal)) { throw 'The stopped-run control changed nothing.' }
        & { . ([scriptblock]::Create($inputStopControl)); if ($null -eq (Get-FramePacingInputStopMiss)) { throw 'The stopped-run cases accepted a stop that hides a cleanup failure.' } }
        # A driver deadline with input during its cleanup (CodeRabbit on #741): the deadline is an outer error but not the
        # no-launch refusal, so the run stays failed (exit 1); an input-only stop exits 2; a tripped guard exits 3.
        $deadlineError = 'The driver ran past 30 minutes; the owned job was closed.'
        $inputOnly = Get-FramePacingSupervisionStop 0 1
        if ($null -ne (Get-FramePacingInputStop @() @($deadlineError) $null $inputOnly $false)) { throw 'A driver deadline with input during its cleanup was called inconclusive.' }
        $deadlineStatus = Get-FramePacingRunStatus @() @($deadlineError) $null $null @('no record')
        $inputStatus = if (Get-FramePacingInputStop @() @() $null $inputOnly $false) { 'inconclusive' } else { 'complete' }
        $guardStatus = Get-FramePacingRunStatus @('clipboard changed') @() 0 $null @()
        if ((Get-FramePacingExitCode @($deadlineStatus) $false $false 0 1) -ne 1 -or (Get-FramePacingExitCode @($inputStatus) $false $false 0 1) -ne 2 -or (Get-FramePacingExitCode @($guardStatus) $false $false 0 1) -ne 3) { throw 'A deadline beside input, an input-only stop and a tripped guard do not exit 1, 2 and 3.' }
        $cases.Add("stopped run ($($inputStopCases.Count) cases and a driver deadline beside input, failed; a hidden cleanup failure as the control)")

        # Why the outer half stops a run for real input (the lead on #741, round 5): the latch seen, with the delay from
        # its observation to the job's close; the close failed; or input the hooks counted by the time the driver
        # ended, whatever the driver's exit. Then the chain for a driver that exits cleanly after the latch: its run is
        # inconclusive through Get-FramePacingInputStop, and the series publishes no metric (the summary cases below).
        # The control: a stop that reads the supervision's state alone.
        $supervisionCases = @(
            @{ Args = @(1, 1); Want = 'closed the run''s job when it observed the input (guards.json records the delay)' }
            @{ Args = @(2, 1); Want = 'closing the run''s job failed' }
            @{ Args = @(0, 1); Want = 'the run stops whatever the driver''s exit says' }
            @{ Args = @(-1, 2); Want = 'the run stops whatever the driver''s exit says' }
            @{ Args = @(0, 0); Want = $null }
            @{ Args = @(0x102, 0); Want = $null }
        )
        function Get-FramePacingSupervisionMiss {
            foreach ($case in $supervisionCases) {
                $a = $case.Args
                $got = Get-FramePacingSupervisionStop $a[0] $a[1]
                $ok = if ($null -eq $case.Want) { $null -eq $got } else { $null -ne $got -and $got.Contains($case.Want) }
                if (-not $ok) { return "state $($a[0]), real inputs $($a[1]): $got" }
            }
            $clean = Get-FramePacingRunStatus @() @() 0 $null @()
            $stop = Get-FramePacingSupervisionStop 0 1
            $stopped = Get-FramePacingInputStop @() @() $null $stop
            if (-not [string]::Equals($clean, 'complete', [StringComparison]::Ordinal) -or $null -eq $stopped -or -not $stopped.StartsWith('inconclusive:', [StringComparison]::Ordinal)) { return "a driver that exited cleanly after the latch: status $clean, stop '$stopped'" }
            return $null
        }
        $supervisionMiss = Get-FramePacingSupervisionMiss
        if ($supervisionMiss) { throw "The supervision's stop: $supervisionMiss." }
        $supervisionText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSupervisionStop' 'bench-frame-pacing.ps1'
        $supervisionControl = [regex]::Replace($supervisionText, '(?m)^    if \(\$RealInputs -ne 0\) \{ return [^\r\n]+\r?\n', '')
        if ([string]::Equals($supervisionControl, $supervisionText, [StringComparison]::Ordinal)) { throw 'The supervision-stop control changed nothing.' }
        & { . ([scriptblock]::Create($supervisionControl)); if ($null -eq (Get-FramePacingSupervisionMiss)) { throw 'The supervision cases accepted a stop that ignores input counted after the driver ended.' } }
        if ($framePacingText.Contains('InputStopGraceMs')) { throw 'The harness still has a grace before the outer half closes the run''s job.' }
        $cases.Add("supervision stop ($($supervisionCases.Count) cases and a clean driver exit after the latch, inconclusive; a stop that reads the state alone as the control)")

        # The sticky latch (the lead and Sol on #741, round 8). A poll that reads a moved tick (Sol's 251, the expected
        # 250) stops at once with the break latched in the run's ticks, and never reads again, so a following 250 is
        # not taken as quiet. The control: round 7's poll, which read the gate again and accepted the second 250.
        # Then a run's latch: the outer half's own stop or gate break, or the driver's latched ticks; a record from
        # before the latch, or none, is no input.
        function New-FramePacingTickQueuePort([long[]] $Ticks) {
            $port = [pscustomobject]@{ Kind = 'stand-in'; Queue = [Collections.Generic.Queue[long]]::new([long[]]$Ticks); Reads = 0 }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputSeen -Value { $false }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { $this.Reads++; if ($this.Queue.Count -gt 1) { $this.Queue.Dequeue() } else { $this.Queue.Peek() } }
            return $port
        }
        function Get-FramePacingPollLatchMiss {
            $ticks = [ordered]@{ Series = [long]100; Unlock = [long]250; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
            $port = New-FramePacingTickQueuePort @(251, 250)
            $thrown = $null
            try { Assert-FramePacingPollGate $port $ticks 'a stand-in poll' } catch { $thrown = $_.Exception.Message }
            if ($null -eq $thrown -or -not $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal) -or -not [bool]$ticks.Broken -or $port.Reads -ne 1 -or $ticks.Checks.Count -ne 1) { return "251 then 250: thrown '$thrown', latched $($ticks.Broken), $($port.Reads) reads, $($ticks.Checks.Count) checks" }
            $quietTicks = [ordered]@{ Series = [long]100; Unlock = [long]250; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
            Assert-FramePacingPollGate (New-FramePacingTickQueuePort @(250)) $quietTicks 'a stand-in poll'
            if ([bool]$quietTicks.Broken -or $quietTicks.Checks.Count -ne 0) { return 'a quiet poll latched or recorded a check' }
            return $null
        }
        $pollLatchMiss = Get-FramePacingPollLatchMiss
        if ($pollLatchMiss) { throw "The poll's latch: $pollLatchMiss." }
        & {
            function Assert-FramePacingPollGate($Port, $Ticks, [string] $During) {
                $expected = if ($null -ne $Ticks.Unlock) { $Ticks.Unlock } else { $Ticks.Series }
                if ($Port.RealInputSeen() -or [long]$Port.LastInputTick() -ne [long]$expected) { Assert-FramePacingInputGate $Port $Ticks $During }
            }
            if ($null -eq (Get-FramePacingPollLatchMiss)) { throw 'The poll cases accepted round 7''s poll, which read the gate again and took the returned tick as quiet.' }
        }
        $runInputCases = @(
            @{ Name = 'the outer half''s own stop'; Outer = $true; Record = $null; Want = $true }
            @{ Name = 'a driver that latched a break'; Outer = $false; Record = [pscustomobject]@{ InputTicks = [pscustomobject]@{ Unlock = 250; Broken = $true } }; Want = $true }
            @{ Name = 'a quiet driver'; Outer = $false; Record = [pscustomobject]@{ InputTicks = [pscustomobject]@{ Unlock = 250; Broken = $false } }; Want = $false }
            @{ Name = 'a record from before the latch'; Outer = $false; Record = [pscustomobject]@{ InputTicks = [pscustomobject]@{ Unlock = 250 } }; Want = $false }
            @{ Name = 'no record'; Outer = $false; Record = $null; Want = $false }
        )
        foreach ($case in $runInputCases) {
            if ((Test-FramePacingRunInput $case.Outer $case.Record) -ne $case.Want) { throw "The run's input latch got $($case.Name) wrong." }
        }
        $cases.Add("sticky latch (a poll at 251 then 250 stops on its one read and latches, a quiet poll records nothing; round 7's rereading poll as the control; the run's latch in $($runInputCases.Count) cases)")

        # The one tick read (the lead and Sol on #741, round 9), against a stand-in native read: Sol's session-facts read
        # of 251 against the series' 250 latches the run's ticks; the expected tick does not; a failed read latches; a
        # read without ticks (the admission's) latches nothing. The control: the read without its latch.
        $tickReadText = (Get-FramePacingFunctionText $framePacingAst 'Read-FramePacingInputTick' 'bench-frame-pacing.ps1').Replace('[FramePacingNative]::LastInputNow()', '@([long]$script:fpStandInTick, [long]1000)')
        function Get-FramePacingTickReadMiss([string] $ReadText) {
            return & {
                . ([scriptblock]::Create($ReadText))
                # With an unlock set (Opus on #741, round 10) the read compares against the unlock's tick, not the series'.
                foreach ($case in @(@{ Tick = 251; Series = 250; Unlock = $null; Want = $true }, @{ Tick = 250; Series = 250; Unlock = $null; Want = $false }, @{ Tick = -1; Series = 250; Unlock = $null; Want = $true }, @{ Tick = 251; Series = 100; Unlock = 250; Want = $true }, @{ Tick = 250; Series = 100; Unlock = 250; Want = $false })) {
                    $script:fpStandInTick = $case.Tick
                    $ticks = [ordered]@{ Series = [long]$case.Series; Unlock = $(if ($null -ne $case.Unlock) { [long]$case.Unlock } else { $null }); Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
                    $read = Read-FramePacingInputTick $ticks
                    if ([bool]$ticks.Broken -ne $case.Want -or $read.Tick -ne $case.Tick) { return "a read of $($case.Tick) against series $($case.Series), unlock $($case.Unlock): latched $($ticks.Broken)" }
                }
                $script:fpStandInTick = 251
                if ((Read-FramePacingInputTick $null).Tick -ne 251) { return 'a read without ticks' }
                return $null
            }
        }
        $tickReadMiss = Get-FramePacingTickReadMiss $tickReadText
        if ($tickReadMiss) { throw "The one tick read: $tickReadMiss." }
        if ($null -eq (Get-FramePacingTickReadMiss ($tickReadText.Replace('{ $Ticks.Broken = $true }', '{ }')))) { throw 'The tick-read cases accepted a read that does not latch.' }
        $tickReadIgnoresUnlock = $tickReadText.Replace('$expected = if ($null -ne $Ticks.Unlock) { $Ticks.Unlock } else { $Ticks.Series }', '$expected = $Ticks.Series')
        if ([string]::Equals($tickReadIgnoresUnlock, $tickReadText, [StringComparison]::Ordinal)) { throw 'The tick-read unlock control changed nothing.' }
        if ($null -eq (Get-FramePacingTickReadMiss $tickReadIgnoresUnlock)) { throw 'The tick-read cases accepted a read that ignores the unlock (Opus on #741, round 10).' }
        $cases.Add('one tick read (Sol''s session-facts 251 against 250, the expected tick, a failed read, an unlock''s tick set, the admission''s read without ticks; a read that does not latch and one that ignores the unlock as the controls)')

        # The real Get-FramePacingSessionFacts (Opus on #741, round 10), its native reads replaced by a stand-in class:
        # Sol's session-facts read of 251 against the series' 250 latches the run's ticks, the series' tick does not,
        # and the admission's read without ticks only reads. The control: $Ticks dropped on the function's first line.
        $sessionStandIn = 'FramePacingSessionStandIn' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Add-Type -TypeDefinition @"
public static class $sessionStandIn {
    public static long Tick = 250;
    public static string CurrentDesktopName() { return "Default"; }
    public static string InputDesktopName() { return "Default"; }
    public static int Composition() { return 1; }
    public static bool RemoteSession() { return false; }
    public static int NotificationState() { return 5; }
    public static int DisplayPower(int ms) { return 1; }
    public static int ScreenSaverRunning() { return 0; }
    public static long ForegroundLockTimeout() { return 2147483647; }
    public static long[] LastInputNow() { return new long[] { Tick, 1000 }; }
}
"@
        $sessionReadText = (Get-FramePacingFunctionText $framePacingAst 'Read-FramePacingInputTick' 'bench-frame-pacing.ps1').Replace('[FramePacingNative]::', "[$sessionStandIn]::")
        $sessionFactsText = (Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSessionFacts' 'bench-frame-pacing.ps1').Replace('[FramePacingNative]::', "[$sessionStandIn]::")
        if ($sessionFactsText.Contains('[FramePacingNative]') -or $sessionReadText.Contains('[FramePacingNative]')) { throw 'The session-facts stand-in left a native read in place.' }
        function Get-FramePacingSessionFactsMiss([string] $FactsText) {
            return & {
                . ([scriptblock]::Create($sessionReadText)); . ([scriptblock]::Create($FactsText))
                $class = $sessionStandIn -as [type]
                $class::Tick = 251
                $ticks = [ordered]@{ Series = [long]250; Unlock = $null; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
                $facts = Get-FramePacingSessionFacts 250 -1 $ticks
                if (-not [bool]$ticks.Broken -or $facts.LastInputTick -ne 251) { return "Sol's session-facts read of 251 against 250: latched $($ticks.Broken), tick $($facts.LastInputTick)" }
                $class::Tick = 250
                $quiet = [ordered]@{ Series = [long]250; Unlock = $null; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
                [void](Get-FramePacingSessionFacts 250 -1 $quiet)
                if ([bool]$quiet.Broken) { return 'the series'' own tick latched' }
                $class::Tick = 251
                if ((Get-FramePacingSessionFacts -1 -1 $null).LastInputTick -ne 251) { return 'the admission''s read without ticks' }
                return $null
            }
        }
        $sessionMiss = Get-FramePacingSessionFactsMiss $sessionFactsText
        if ($sessionMiss) { throw "The real session facts: $sessionMiss." }
        $sessionControl = $sessionFactsText.Replace('function Get-FramePacingSessionFacts([long] $QuietSinceTick, [long] $LockNeededMs, $Ticks) {', "function Get-FramePacingSessionFacts([long] `$QuietSinceTick, [long] `$LockNeededMs, `$Ticks) {`n    `$Ticks = `$null")
        if ([string]::Equals($sessionControl, $sessionFactsText, [StringComparison]::Ordinal)) { throw 'The session-facts control changed nothing.' }
        if ($null -eq (Get-FramePacingSessionFactsMiss $sessionControl)) { throw 'The session-facts cases accepted $Ticks dropped on the first line (Opus''s R1 on #741, round 10).' }
        $cases.Add('session facts (the real Get-FramePacingSessionFacts over a stand-in native class: Sol''s 251 against 250 latches, the series'' tick does not, the admission only reads; $Ticks dropped on the first line as the control)')

        # The harness hash (Sol on #741, round 10): a run whose driver recorded another hash, or none, changed the harness;
        # matching hashes and runs with no record did not.
        foreach ($case in @(
                @{ Name = 'matching hashes'; Results = @([pscustomobject]@{ Record = [pscustomobject]@{ HarnessSha256 = 'AA' } }, [pscustomobject]@{ Record = $null }); Want = $false }
                @{ Name = 'another hash'; Results = @([pscustomobject]@{ Record = [pscustomobject]@{ HarnessSha256 = 'aa' } }, [pscustomobject]@{ Record = [pscustomobject]@{ HarnessSha256 = 'bb' } }); Want = $true }
                @{ Name = 'no hash'; Results = @([pscustomobject]@{ Record = [pscustomobject]@{ Mode = 'visible' } }); Want = $true }
            )) {
            if ((Test-FramePacingHarnessChanged $case.Results 'aa') -ne $case.Want) { throw "The harness-change test got $($case.Name) wrong." }
        }
        # Sol's replay (#744): a script that replaces itself after PowerShell loaded it, before it hashes. The loaded
        # text's hash is the outer run's A and a driver started from the file afterwards hashes B, so the series reads a
        # changed harness; hashed from the disk, both read B and a run of A beside drivers of B would publish (the
        # control). Run in child processes on scratch files only.
        $tocDir = Join-Path ([IO.Path]::GetTempPath()) ('fp-toc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($tocDir)
        try {
            $tocDefs = (Get-FramePacingFunctionText $framePacingAst 'Get-BytesSha256' 'bench-frame-pacing.ps1') + "`n" + (Get-FramePacingFunctionText $framePacingAst 'Get-Sha256' 'bench-frame-pacing.ps1') + "`n" + (Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingLoadedHarnessSha256' 'bench-frame-pacing.ps1') + "`n"
            $tocPath = Join-Path $tocDir 'harness.ps1'
            $tocB = $tocDefs + "# variant B`n'loaded=' + (Get-FramePacingLoadedHarnessSha256)`n'disk=' + (Get-Sha256 `$PSCommandPath)`n"
            $tocA = $tocDefs + "# variant A`n[IO.File]::WriteAllText(`$PSCommandPath, [IO.File]::ReadAllText((Join-Path `$PSScriptRoot 'b.txt')))`n'loaded=' + (Get-FramePacingLoadedHarnessSha256)`n'disk=' + (Get-Sha256 `$PSCommandPath)`n"
            [IO.File]::WriteAllText((Join-Path $tocDir 'b.txt'), $tocB)
            [IO.File]::WriteAllText($tocPath, $tocA)
            $pwshExe = (Get-Command pwsh.exe).Source
            $outerOut = @(& $pwshExe -NoProfile -NonInteractive -File $tocPath)
            $driverOut = @(& $pwshExe -NoProfile -NonInteractive -File $tocPath)
            $read = { param([object[]] $Lines, [string] $Kind) (@($Lines | Where-Object { ([string]$_).StartsWith("$Kind=", [StringComparison]::Ordinal) })[0] -split '=', 2)[1] }
            $outerLoaded = & $read $outerOut 'loaded'; $outerDisk = & $read $outerOut 'disk'; $driverLoaded = & $read $driverOut 'loaded'; $driverDisk = & $read $driverOut 'disk'
            if (-not $outerLoaded -or -not $driverLoaded -or [string]::Equals($outerLoaded, $driverLoaded, [StringComparison]::OrdinalIgnoreCase)) { throw "Sol's replay: the loaded hashes of A and B ($outerLoaded, $driverLoaded) do not differ." }
            if (-not (Test-FramePacingHarnessChanged @([pscustomobject]@{ Record = [pscustomobject]@{ HarnessSha256 = $driverLoaded } }) $outerLoaded)) { throw 'Sol''s replay: the loaded hashes did not read as a changed harness.' }
            if (-not [string]::Equals($outerDisk, $driverDisk, [StringComparison]::OrdinalIgnoreCase) -or (Test-FramePacingHarnessChanged @([pscustomobject]@{ Record = [pscustomobject]@{ HarnessSha256 = $driverDisk } }) $outerDisk)) { throw 'Sol''s replay: the disk-hash control did not show the gap, so it shows nothing.' }
        } finally { [IO.Directory]::Delete($tocDir, $true) }
        $summaryHashText = Get-FramePacingFunctionText $framePacingAst 'Write-FramePacingSummary' 'bench-frame-pacing.ps1'
        if ($summaryHashText.Contains('Get-Sha256') -or $summaryHashText.Contains('$PSCommandPath')) { throw 'The summary hashes the harness at summary time.' }
        $cases.Add('harness hash (matching, another, none; the summary hashes nothing at summary time; Sol''s replay of a script replaced after its load: the loaded text reads A then B, the disk control reads B twice; an empty series hash fails closed, the old check as the control)')

        # The dry run's console comparison (Greptile on #741): cmd's console read from the top-left cell through the
        # cursor, as ConsoleTextToCursor reads it, so a prompt that ends at column 130 of a 140-column row and the
        # command that then wraps onto the next row compare whole. The state below is what the console's cells hold:
        # whole rows padded to the width, then the cursor's row up to the cursor. The cases: the command intact on one
        # row and wrapped, the probe leaving the console unchanged, and as controls a stray character before the
        # command, a stray character the probe left, a truncated command, and the old reader's single-row comparison,
        # which refused the wrapped command.
        function New-FramePacingConsoleState([string[]] $Rows, [string] $Cursor) {
            $text = (@($Rows | ForEach-Object { $_.PadRight(140) }) -join '') + $Cursor
            return [pscustomobject]@{ Cells = $text.Length; Text = $text }
        }
        $typed = 'type stream.bin & echo.>done.flag'
        $banner = @('Microsoft Windows [Version 10.0.26300.1]', '(c) Microsoft Corporation. All rights reserved.', '')
        $shortPrompt = 'C:\fp\run-1\work>'
        $longPrompt = 'C:\' + ('x' * 126) + '>'
        if ($longPrompt.Length -ne 130 -or $longPrompt.Length + $typed.Length -le 140) { throw 'The wrapped-command fixture does not wrap.' }
        $consoleCases = @(
            @{ Name = 'the command intact on the prompt''s row'; Before = (New-FramePacingConsoleState $banner $shortPrompt); After = (New-FramePacingConsoleState $banner ($shortPrompt + $typed)); Typed = $typed; Want = $true }
            @{ Name = 'the command intact, wrapped after a prompt ending at column 130'; Before = (New-FramePacingConsoleState $banner $longPrompt); After = (New-FramePacingConsoleState ($banner + ($longPrompt + $typed).Substring(0, 140)) ($longPrompt + $typed).Substring(140)); Typed = $typed; Want = $true }
            @{ Name = 'the probe leaving the console unchanged after a long prompt'; Before = (New-FramePacingConsoleState $banner $longPrompt); After = (New-FramePacingConsoleState $banner $longPrompt); Typed = ''; Want = $true }
            @{ Name = 'a stray character before the command'; Before = (New-FramePacingConsoleState $banner $longPrompt); After = (New-FramePacingConsoleState ($banner + ($longPrompt + 'x' + $typed).Substring(0, 140)) ($longPrompt + 'x' + $typed).Substring(140)); Typed = $typed; Want = $false }
            @{ Name = 'a stray character the probe left'; Before = (New-FramePacingConsoleState $banner $shortPrompt); After = (New-FramePacingConsoleState $banner ($shortPrompt + 'x')); Typed = ''; Want = $false }
            @{ Name = 'a truncated command'; Before = (New-FramePacingConsoleState $banner $longPrompt); After = (New-FramePacingConsoleState $banner ($longPrompt + $typed.Substring(0, 10))); Typed = $typed; Want = $false }
            @{ Name = 'a character the probe replaced in place (Opus on #741, round 5)'; Before = (New-FramePacingConsoleState $banner $shortPrompt); After = (New-FramePacingConsoleState $banner ($shortPrompt.Substring(0, $shortPrompt.Length - 1) + '#')); Typed = ''; Want = $false }
        )
        function Get-FramePacingConsoleMiss {
            foreach ($case in $consoleCases) {
                if ((Test-FramePacingConsoleTyped $case.Before $case.After $case.Typed) -ne $case.Want) { return $case.Name }
            }
            return $null
        }
        $consoleMiss = Get-FramePacingConsoleMiss
        if ($consoleMiss) { throw "The console comparison got $consoleMiss wrong." }
        $consoleText = Get-FramePacingFunctionText $framePacingAst 'Test-FramePacingConsoleTyped' 'bench-frame-pacing.ps1'
        $consoleControl = $consoleText.Replace('$Typed.Length -and [string]::Equals(', '$Typed.Length -or [string]::Equals(')
        if ([string]::Equals($consoleControl, $consoleText, [StringComparison]::Ordinal)) { throw 'The console comparison''s control changed nothing.' }
        & { . ([scriptblock]::Create($consoleControl)); if ($null -eq (Get-FramePacingConsoleMiss)) { throw 'The console cases accepted Opus''s C1, either condition for both.' } }
        # The old reader compared the cursor's row alone: the wrapped command's row holds only the command's tail.
        $oldBefore = $longPrompt; $oldAfter = ($longPrompt + $typed).Substring(140)
        if ([string]::Equals($oldAfter, $oldBefore + $typed, [StringComparison]::Ordinal)) { throw 'The single-row control accepted the wrapped command, so it shows nothing.' }
        $cases.Add("console comparison ($($consoleCases.Count) cases: the command on one row and wrapped after column 130, the probe unchanged, a stray character before the command or left by the probe, a truncated command, a character replaced in place; the old single-row comparison refuses the wrapped command, and Opus's C1 is caught)")

        # The run's record after a kill (Opus on #741, round 5): a missing file reads as none, a file the job's close
        # cut short as none with the reason, a whole one as its record; and a run stopped for real input with no
        # readable record is inconclusive. The control: the old unguarded read, which throws on the cut file.
        $recordDir = Join-Path ([IO.Path]::GetTempPath()) ('fp-record-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory($recordDir)
        try {
            $whole = Join-Path $recordDir 'whole.json'; $cut = Join-Path $recordDir 'cut.json'; $missing = Join-Path $recordDir 'missing.json'
            [IO.File]::WriteAllText($whole, '{ "Schema": 1, "Mode": "visible" }')
            [IO.File]::WriteAllText($cut, '{ "Schema": 1, "Mo')
            $gotWhole = Read-FramePacingRunRecord $whole; $gotCut = Read-FramePacingRunRecord $cut; $gotMissing = Read-FramePacingRunRecord $missing
            if ($null -eq $gotWhole.Record -or $gotWhole.Record.Schema -ne 1 -or $null -ne $gotWhole.Problem) { throw 'A whole run.json did not read as its record.' }
            if ($null -ne $gotCut.Record -or -not $gotCut.Problem -or -not $gotCut.Problem.StartsWith('the run''s record could not be read', [StringComparison]::Ordinal)) { throw 'A cut run.json did not read as none with the reason.' }
            if ($null -ne $gotMissing.Record -or $null -ne $gotMissing.Problem) { throw 'A missing run.json did not read as none.' }
            $stoppedNoRecord = Get-FramePacingInputStop @() @() $null (Get-FramePacingSupervisionStop 1 1)
            if ($null -eq $stoppedNoRecord -or -not $stoppedNoRecord.StartsWith('inconclusive:', [StringComparison]::Ordinal)) { throw 'A run stopped for real input with no readable record is not inconclusive.' }
            $unguarded = $null
            try { $unguarded = Get-Content -LiteralPath $cut -Raw | ConvertFrom-Json; $unguarded = 'read' } catch { $unguarded = 'threw' }
            if (-not (Test-FramePacingOrdinal $unguarded 'threw')) { throw 'The unguarded-read control did not throw on the cut file, so it shows nothing.' }
        } finally { [IO.Directory]::Delete($recordDir, $true) }
        $cases.Add('run record (whole, cut by the close, missing; a stopped run with no record inconclusive; the unguarded read throws on the cut file)')

        # The foreground lock against what the series still needs (Greptile and Sol on #741): Sol's fixture, a finite
        # lock with the idle time already past the bound, refuses; a lock just under the need, or equal to it, refuses;
        # one above it, and this machine's, admit. The control: a lock equal to the need admitted.
        $shortfallCases = @(
            @{ Want = $true; Args = @(2400001, (Get-FramePacingLockNeedMs 2400002 300000 1)) }
            @{ Want = $true; Args = @(((Get-FramePacingLockNeedMs 300000 300000 5) - 1), (Get-FramePacingLockNeedMs 300000 300000 5)) }
            @{ Want = $true; Args = @((Get-FramePacingLockNeedMs 300000 300000 5), (Get-FramePacingLockNeedMs 300000 300000 5)) }
            @{ Want = $false; Args = @(((Get-FramePacingLockNeedMs 300000 300000 5) + 1), (Get-FramePacingLockNeedMs 300000 300000 5)) }
            @{ Want = $false; Args = @(2147483647, (Get-FramePacingLockNeedMs 400000 300000 5)) }
            @{ Want = $true; Args = @(2147483647, -1) }
        )
        function Get-FramePacingShortfallMiss {
            foreach ($case in $shortfallCases) {
                $got = $null -ne (Get-FramePacingLockShortfall $case.Args[0] $case.Args[1])
                if ($got -ne $case.Want) { return "lock $($case.Args[0]), need $($case.Args[1]): shortfall $got" }
            }
            return $null
        }
        $shortfallMiss = Get-FramePacingShortfallMiss
        if ($shortfallMiss) { throw "The lock shortfall: $shortfallMiss." }
        $shortfallText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingLockShortfall' 'bench-frame-pacing.ps1'
        $shortfallControl = $shortfallText.Replace('$LockMs -le $NeedMs', '$LockMs -lt $NeedMs')
        if ([string]::Equals($shortfallControl, $shortfallText, [StringComparison]::Ordinal)) { throw 'The shortfall control changed nothing.' }
        & { . ([scriptblock]::Create($shortfallControl)); if ($null -eq (Get-FramePacingShortfallMiss)) { throw 'The shortfall cases accepted a lock equal to the need.' } }
        $cases.Add("lock shortfall ($($shortfallCases.Count) cases: Sol's fixture, just under, equal, above, this machine's, no need; equal-admitted as the control)")

        # The hooks' silence after a run (Opus and CodeRabbit on #741): a run whose foreground was ok must have moved the
        # mouse hook's marked count, and one whose key probe was ok the keyboard hook's; no record, another outcome, or
        # a count that moved, is not silence. The controls: either kind's check removed.
        # A run whose foreground was taken owes the keyboard probe (Opus on #741, round 5): one that did not come back
        # ok is silence unless real input stopped the run first.
        $both = [pscustomobject]@{ Foreground = 'ok'; KeyProbe = 'ok' }
        $silenceCases = @(
            @{ Want = $false; Args = @($null, 4, 4, 2, 2, 0) }
            @{ Want = $false; Args = @([pscustomobject]@{ Foreground = 'refused' }, 4, 4, 2, 2, 0) }
            @{ Want = $false; Args = @($both, 4, 5, 2, 3, 0) }
            @{ Want = $true; Removed = $true; Args = @($both, 4, 4, 2, 3, 0) }
            @{ Want = $true; Removed = $true; Args = @($both, 4, 5, 2, 2, 0) }
            @{ Want = $true; Removed = $false; Args = @([pscustomobject]@{ Foreground = 'ok' }, 4, 5, 2, 2, 0) }
            @{ Want = $true; Removed = $false; Args = @([pscustomobject]@{ Foreground = 'ok'; KeyProbe = 'timeout' }, 4, 5, 2, 2, 0) }
            @{ Want = $false; Args = @([pscustomobject]@{ Foreground = 'ok'; KeyProbe = 'timeout' }, 4, 5, 2, 2, 1) }
            @{ Want = $false; Args = @([pscustomobject]@{ Foreground = 'ok'; KeyProbe = $null }, 4, 5, 2, 2, 3) }
            @{ Want = $true; Removed = $true; Args = @([pscustomobject]@{ Foreground = 'ok' }, 4, 0, 2, 2, 0) }
        )
        function Get-FramePacingSilenceMiss {
            foreach ($case in $silenceCases) {
                $a = $case.Args
                $silence = Get-FramePacingHookSilence $a[0] $a[1] $a[2] $a[3] $a[4] $a[5]
                $got = $null -ne $silence
                if ($got -ne $case.Want -or ($got -and [bool]$silence.Removed -ne [bool]$case.Removed)) { return "mouse $($a[1]) then $($a[2]), keys $($a[3]) then $($a[4]): silence $got" }
            }
            # The cause named (Opus on #741, round 6): the driver's recorded error goes into an unproven probe's line.
            $named = Get-FramePacingHookSilence ([pscustomobject]@{ Foreground = 'ok'; KeyProbe = $null; Error = 'INCONCLUSIVE: the session''s input tick moved before the keyboard probe' }) 4 5 2 2 0
            if ($null -eq $named -or -not $named.Line.Contains('not sent') -or -not $named.Line.Contains('input tick moved before the keyboard probe')) { return 'an unproven probe''s line does not name the cause the driver recorded' }
            return $null
        }
        $silenceMiss = Get-FramePacingSilenceMiss
        if ($silenceMiss) { throw "The hooks' silence: $silenceMiss." }
        $silenceText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingHookSilence' 'bench-frame-pacing.ps1'
        foreach ($control in @(
                @{ Name = 'the mouse check removed'; Old = 'if ($foregroundTaken -and $MouseAfter -le $MouseBefore) {'; New = 'if ($false) {' }
                @{ Name = 'the keyboard count check removed'; Old = 'if ($probed -and $KeyAfter -le $KeyBefore) {'; New = 'if ($false) {' }
                @{ Name = 'the probe not required once the foreground was taken (Opus on #741, round 5)'; Old = 'if ($foregroundTaken -and -not $probed -and $RealInputs -eq 0) {'; New = 'if ($false) {' }
                @{ Name = 'the probe required even when real input stopped the run'; Old = 'if ($foregroundTaken -and -not $probed -and $RealInputs -eq 0) {'; New = 'if ($foregroundTaken -and -not $probed) {' }
            )) {
            $silenceControl = $silenceText.Replace($control.Old, $control.New)
            if ([string]::Equals($silenceControl, $silenceText, [StringComparison]::Ordinal)) { throw "The silence control changed nothing: $($control.Name)." }
            & { . ([scriptblock]::Create($silenceControl)); if ($null -eq (Get-FramePacingSilenceMiss)) { throw "The silence cases accepted $($control.Name)." } }
        }
        $cases.Add("hooks' silence ($($silenceCases.Count) cases by kind, the keyboard probe owed once the foreground was taken unless real input stopped the run, the cause named; four controls)")

        # The status the silence leaves (Sol and Opus on #741, round 6): a removed hook fails the run; an unproven
        # keyboard hook (a probe refused, or a stop before the probe for input the hooks did not see) leaves an
        # inconclusive run inconclusive and a complete one inconclusive, never failed; a tripped guard stays. The
        # control: round 5's mapping, which failed every silenced run.
        $removed = [pscustomobject]@{ Removed = $true; Line = 'x' }; $unproven = [pscustomobject]@{ Removed = $false; Line = 'inconclusive: x' }
        $silencedCases = @(
            @{ Args = @('inconclusive', $unproven); Want = 'inconclusive' }
            @{ Args = @('complete', $unproven); Want = 'inconclusive' }
            @{ Args = @('failed', $unproven); Want = 'failed' }
            @{ Args = @('inconclusive', $removed); Want = 'failed' }
            @{ Args = @('complete', $removed); Want = 'failed' }
            @{ Args = @('guard-tripped', $removed); Want = 'guard-tripped' }
            @{ Args = @('complete', $null); Want = 'complete' }
        )
        function Get-FramePacingSilencedMiss {
            foreach ($case in $silencedCases) {
                $got = Get-FramePacingSilencedStatus $case.Args[0] $case.Args[1]
                if (-not (Test-FramePacingOrdinal $got $case.Want)) { return "$($case.Args[0]) with $(if ($null -eq $case.Args[1]) { 'no silence' } elseif ($case.Args[1].Removed) { 'a removed hook' } else { 'an unproven hook' }): $got" }
            }
            # Opus's replay (a) and Sol's Low: a tick-only stop before the probe, with the unlock counted, stays inconclusive.
            $tickStopped = Get-FramePacingInputStop @() @() $null (Get-FramePacingTickStop 260 250)
            $silence = Get-FramePacingHookSilence ([pscustomobject]@{ Foreground = 'ok'; KeyProbe = $null; Error = 'INCONCLUSIVE: x' }) 4 5 2 2 0
            if ($null -eq $tickStopped -or -not (Test-FramePacingOrdinal (Get-FramePacingSilencedStatus 'inconclusive' $silence) 'inconclusive')) { return 'a tick-only stop before the probe did not stay inconclusive' }
            return $null
        }
        $silencedMiss = Get-FramePacingSilencedMiss
        if ($silencedMiss) { throw "The silenced status: $silencedMiss." }
        $silencedText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSilencedStatus' 'bench-frame-pacing.ps1'
        $silencedControl = $silencedText.Replace("    if (`$Silence.Removed) { return 'failed' }", "    return 'failed'")
        if ([string]::Equals($silencedControl, $silencedText, [StringComparison]::Ordinal)) { throw 'The silenced-status control changed nothing.' }
        & { . ([scriptblock]::Create($silencedControl)); if ($null -eq (Get-FramePacingSilencedMiss)) { throw 'The silenced-status cases accepted round 5''s mapping, which fails every silenced run.' } }
        $cases.Add("silenced status ($($silencedCases.Count) cases and a tick-only stop before the probe; round 5's mapping as the control)")

        # A keyboard hook that misses the harness's own probe (Greptile on #741), through the outer verdict: a stand-in
        # port whose probe moved the tick (200 to 300) but whose hook did not see it, as the native reports it. The
        # wrapper keeps 300 as the harness's tick and refuses; the outer half then sees the tick where the harness left
        # it, and even with a later tick move (a user's input, unseen by the dead hook) the run stays failed. The
        # control: a stop that ignores the hook failure, which calls the later case inconclusive.
        function Get-FramePacingHookMissMiss {
            $port = [pscustomobject]@{ Kind = 'stand-in' }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputSeen -Value { $false }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { [long]200 }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name KeyProbe -Value { param($HostWindow, $OwnerPid, $BoundMs, $ExpectedTick) [pscustomobject]@{ Outcome = 'key-probe-not-seen-by-hook'; ProbeTick = [long]300 } }
            $ticks = [ordered]@{ Series = [long]100; Unlock = [long]200; Checks = [Collections.Generic.List[object]]::new() }
            $thrown = $null
            try { [void](Invoke-FramePacingKeyProbe $port $ticks ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
            if (-not (Test-FramePacingOrdinal $thrown $script:KeyHookMissed) -or $ticks.Unlock -ne 300) { return "the probe's wrapper: thrown '$thrown', tick $($ticks.Unlock)" }
            $record = [pscustomobject]@{ Foreground = 'ok'; KeyProbe = $null; Error = $thrown; InputTicks = [pscustomobject]@{ Unlock = $ticks.Unlock } }
            foreach ($tickNow in @([long]300, [long]310)) {
                $stop = Get-FramePacingTickStop $tickNow ([long]$record.InputTicks.Unlock)
                $status = Get-FramePacingRunStatus @() @() 1 $thrown @("error: $thrown")
                if (Get-FramePacingInputStop @() @() $null $stop (Test-FramePacingHookMissed $record.Error)) { $status = 'inconclusive' }
                $silence = Get-FramePacingHookSilence $record 4 5 2 2 0
                $status = Get-FramePacingSilencedStatus $status $silence
                if (-not (Test-FramePacingOrdinal $status 'failed')) { return "a dead keyboard hook with the tick at $($tickNow): $status" }
                # No second line calls the failed run inconclusive or the sent probe "not sent" (Opus on #741, round 8).
                if ($null -ne $silence) { return "a dead keyboard hook's run also carries '$($silence.Line)'" }
            }
            if (-not (Test-FramePacingHookMissed $script:MouseHookMissed) -or (Test-FramePacingHookMissed 'INCONCLUSIVE: x')) { return 'the hook-miss test is wrong' }
            return $null
        }
        $hookMissMiss = Get-FramePacingHookMissMiss
        if ($hookMissMiss) { throw "A dead hook through the outer verdict: $hookMissMiss." }
        $hookMissStopText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingInputStop' 'bench-frame-pacing.ps1'
        $hookMissControl = $hookMissStopText.Replace('if (-not $Stop -or $HookMissed -or', 'if (-not $Stop -or')
        if ([string]::Equals($hookMissControl, $hookMissStopText, [StringComparison]::Ordinal)) { throw 'The hook-miss control changed nothing.' }
        & { . ([scriptblock]::Create($hookMissControl)); if ($null -eq (Get-FramePacingHookMissMiss)) { throw 'The dead-hook cases accepted a stop that hides the hook failure.' } }
        $cases.Add('dead hook (a stand-in keyboard hook that misses the probe stays failed, with the tick where the probe left it and after a later move; a stop that hides it as the control)')

        # Input the hooks did not see, from the tick (the lead and Sol on #741, round 6): the expected tick passes;
        # another, or an unreadable one, stops. The series' final reading: the count only when the watch stopped, the
        # tick against the baseline.
        foreach ($case in @(@{ Tick = 250; Expected = 250; Stop = $false }, @{ Tick = 260; Expected = 250; Stop = $true }, @{ Tick = -1; Expected = 250; Stop = $true }, @{ Tick = 240; Expected = 250; Stop = $true })) {
            if (($null -ne (Get-FramePacingTickStop $case.Tick $case.Expected)) -ne $case.Stop) { throw "The tick stop got $($case.Tick) against $($case.Expected) wrong." }
        }
        $finalQuiet = Get-FramePacingFinalInput $true 0 250 250; $finalOpen = Get-FramePacingFinalInput $false 0 250 250; $finalMoved = Get-FramePacingFinalInput $true 0 251 250
        $finalUnread = Get-FramePacingFinalInput $true 0 -1 250
        if ($finalQuiet.RealInputs -ne 0 -or $finalQuiet.TickMoved -or $finalQuiet.TickUnread -or $null -ne $finalOpen.RealInputs -or -not $finalMoved.TickMoved -or $finalMoved.TickUnread -or -not $finalUnread.TickMoved -or -not $finalUnread.TickUnread) { throw 'The series'' final input reading is wrong.' }
        $cases.Add('tick stop (4 cases) and the final reading (quiet, a watch that did not stop, a moved tick)')


        # The driver's early throw (Greptile and CodeRabbit on #741): the real Invoke-FramePacingDriver, under the
        # harness's StrictMode and error preference, against a stand-in native class whose input desktop reads as
        # unreadable (a locked session), so the driver throws at its admission, before it opens the watch or starts
        # anything. It must still write run.json with that error, no exit of a copy, and return 1, in a dry run and a
        # visible one. The control: the driver with $watch first set inside its try, whose finally then throws before
        # the record is written.
        $driverStubName = 'FramePacingDriverStub' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Add-Type -TypeDefinition @"
using System;
public static class $driverStubName {
    public static string Own = "";
    public static int Closed;
    public static string Layout() { return "stub-layout"; }
    public static string CurrentDesktopName() { return Own; }
    public static string InputDesktopName() { return null; }
    public static bool CloseHandle(IntPtr h) { Closed++; return true; }
    public static bool Alive(IntPtr process) { return false; }
    public static void Terminate(IntPtr process, uint code) { }
}
"@
        $driverStub = $driverStubName -as [type]
        $driverText = (Get-FramePacingFunctionText $framePacingAst 'Invoke-FramePacingDriver' 'bench-frame-pacing.ps1').Replace('[FramePacingNative]', "[$driverStubName]")
        function Invoke-FramePacingDriverCase([string] $Text, [bool] $AsVisible, [string] $Own) {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('fp-driver-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($root)
            $hadLayout = $null -ne (Get-Variable -Scope Script -Name SdkLayout -ErrorAction SilentlyContinue)
            $savedLayout = if ($hadLayout) { (Get-Variable -Scope Script -Name SdkLayout).Value } else { $null }
            try {
                $script:SdkLayout = 'stub-layout'
                $driverStub::Own = $Own
                $code = & {
                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'
                    $Run = $root; $Visible = $AsVisible; $DesktopName = $Own; $ExpectedBuildMode = 'ReleaseFast'; $QuietSinceTick = [long]-1; $InputWatchEvent = $null; $ForegroundLockNeededMs = [long]-1; $InputMarker = [long]0
                    function Get-Process { [pscustomobject]@{ PriorityClass = 'Normal' } }
                    . ([scriptblock]::Create($Text))
                    try { @(Invoke-FramePacingDriver)[-1] } catch { "threw: $($_.Exception.Message)" }
                }
                $recordPath = Join-Path $root 'run.json'
                $record = if (Test-Path -LiteralPath $recordPath -PathType Leaf) { Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json } else { $null }
                $logged = (Test-Path -LiteralPath (Join-Path $root 'driver.log') -PathType Leaf) -and (Get-Content -LiteralPath (Join-Path $root 'driver.log') -Raw).Contains('error: The input desktop is unreadable.')
                return [pscustomobject]@{ Code = $code; Record = $record; Logged = $logged }
            } finally {
                if ($hadLayout) { $script:SdkLayout = $savedLayout } else { Remove-Variable -Scope Script -Name SdkLayout -ErrorAction SilentlyContinue }
                [IO.Directory]::Delete($root, $true)
            }
        }
        function Get-FramePacingDriverMiss([string] $Text) {
            foreach ($mode in @(@{ Visible = $false; Own = 'noctty-fp-stub'; Mode = 'dry-run' }, @{ Visible = $true; Own = 'Default'; Mode = 'visible' })) {
                $got = Invoke-FramePacingDriverCase $Text $mode.Visible $mode.Own
                if ($null -eq $got.Record) { return "$($mode.Mode): no run.json ($($got.Code))" }
                if ($got.Code -ne 1 -or $got.Record.Error -ne 'The input desktop is unreadable.' -or $got.Record.Mode -ne $mode.Mode -or $null -ne $got.Record.Exit -or -not $got.Logged) { return "$($mode.Mode): exit $($got.Code), error '$($got.Record.Error)', mode $($got.Record.Mode)" }
            }
            return $null
        }
        $driverMiss = Get-FramePacingDriverMiss $driverText
        if ($driverMiss) { throw "The driver's early throw did not leave its record: $driverMiss." }
        $lateWatchText = $driverText.Replace("    `$process = [IntPtr]::Zero`n    `$watch = [IntPtr]::Zero`n    `$mouseWatch = [IntPtr]::Zero`n    `$keyWatch = [IntPtr]::Zero`n    try {", "    `$process = [IntPtr]::Zero`n    `$mouseWatch = [IntPtr]::Zero`n    `$keyWatch = [IntPtr]::Zero`n    try {")
        if ([string]::Equals($lateWatchText, $driverText, [StringComparison]::Ordinal)) { throw 'The early-throw control changed nothing.' }
        if ($null -eq (Get-FramePacingDriverMiss $lateWatchText)) { throw 'The early-throw case accepted the driver with $watch first set inside its try.' }
        $cases.Add('driver early throw (a locked session at admission, dry and visible, under StrictMode: run.json with the error and exit 1; $watch set inside the try as the control)')

        # The input gate and the foreground, through a stand-in port (Sol's High and Opus's Medium 2 on #741, with the
        # bots' finding): the port's LastInputTick answers from a queue (its last value repeats) and its Foreground
        # counts calls. Quiet: the gate passes and the foreground is called once, and the unlock's tick is then the
        # one expected. Sol's control: input after admission, before the unlock; the gate throws INCONCLUSIVE and the
        # foreground is never called. Input after the unlock, before the window, breaks the next gate. A series with
        # no tick breaks it too. The control on the code: the foreground function without its gate calls the
        # foreground despite the input.
        function New-FramePacingStandInPort([long[]] $Ticks, [long] $UnlockTick) {
            $port = [pscustomobject]@{ Kind = 'stand-in'; Queue = [Collections.Generic.Queue[long]]::new([long[]]$Ticks); ForegroundCalls = 0; UnlockTick = $UnlockTick; Real = $false }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputSeen -Value { [bool]$this.Real }
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
        # Real input with the tick unchanged (the lead on #741: the hook, not the tick, sees a returning user): the gate
        # breaks first, and the foreground is never called.
        $hooked = New-FramePacingStandInPort @(100) 200
        $hooked.Real = $true
        $ticks = New-FramePacingTicks 100
        $thrown = $null
        try { [void](Invoke-FramePacingForeground $hooked $ticks ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
        if (-not $thrown -or -not $thrown.Contains('real (non-injected)') -or $hooked.ForegroundCalls -ne 0 -or -not $ticks.Checks[0].real) { throw "Real input with the tick unchanged did not stop the run before the foreground (calls $($hooked.ForegroundCalls), '$thrown')." }
        $foregroundText = Get-FramePacingFunctionText $framePacingAst 'Invoke-FramePacingForeground' 'bench-frame-pacing.ps1'
        $foregroundControl = $foregroundText.Replace("Assert-FramePacingInputGate `$Port `$Ticks 'the harness''s unlock'", '')
        if ([string]::Equals($foregroundControl, $foregroundText, [StringComparison]::Ordinal)) { throw 'The foreground-gate control changed nothing.' }
        & { . ([scriptblock]::Create($foregroundControl)); $port = New-FramePacingStandInPort @(150) 200; [void](Invoke-FramePacingForeground $port (New-FramePacingTicks 100) ([IntPtr]1) 1); if ($port.ForegroundCalls -ne 1) { throw 'The foreground-gate control did not call the foreground despite the input.' } }
        # The tick the run expects is set in two places only, each from a native worker's own observed tick: the
        # unlock's and then the keyboard probe's (Opus's M8 on #741: a tick read after the window must never become the
        # next run's baseline). The control: a third assignment after the window is caught.
        function Test-FramePacingUnlockAssignments([string] $Text) { return [regex]::Matches($Text, '\.Unlock\s*=(?!=)').Count -eq 2 -and [regex]::Matches($Text, 'if \(\[long\]\$result\.UnlockTick -ge 0\) \{ \$Ticks\.Unlock = \[long\]\$result\.UnlockTick \}').Count -eq 1 -and [regex]::Matches($Text, 'if \(\[long\]\$result\.ProbeTick -ge 0\) \{ \$Ticks\.Unlock = \[long\]\$result\.ProbeTick \}').Count -eq 1 -and [regex]::Matches($Text, '\$quietSince = \[long\]\$result\.Record\.InputTicks\.Unlock').Count -eq 1 }
        if (-not (Test-FramePacingUnlockAssignments $framePacingText)) { throw 'The unlock''s tick must be assigned once, in Invoke-FramePacingForeground, and be the only source of the next run''s tick.' }
        if (Test-FramePacingUnlockAssignments ($framePacingText.Replace('$record.DisplayPowerAfter = [FramePacingNative]::DisplayPower(2000)', "`$record.DisplayPowerAfter = [FramePacingNative]::DisplayPower(2000)`n        `$record.InputTicks.Unlock = [FramePacingNative]::LastInputTick()"))) { throw 'The unlock-assignment check accepted a tick read after the window.' }
        $cases.Add('input gate and foreground (quiet; Sol''s input after admission never reaches the foreground; input after the unlock; no series tick; checks recorded; real input with the tick unchanged; a gateless foreground as the control; the unlock''s tick set once, Opus''s M8 as the control)')

        # The input watch end to end (the lead, Opus, Sol and CodeRabbit on #741), compiled from the harness's own
        # source with its two hook installs replaced by stand-in handles, so nothing is hooked and no real input is
        # read: synthetic events go to the hooks' own callbacks (KeyboardEvent, MouseEvent), whose classification sets
        # the series' events, which the driver's port reads. Our marked unlock and key probe (in their lower-IL forms
        # too) leave the real-input event clear and pass the foreground and the probe; another program's injected mouse
        # event, unmarked or wrongly marked, proves nothing and the run is refused outright, and so is our marked key
        # with the mouse unlock missing (CodeRabbit); a real mouse event or key blocks the next foreground with the tick
        # unchanged; a hook of either kind that stops receiving events refuses the run; a failed install is false,
        # leaves no event and refuses -Visible. The controls, compiled the same way: the keyboard bit read as the
        # mouse's, the real-input event never set, the marker ignored, and the probe accepted without its hook.
        $nativeSource = @($framePacingAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class FramePacingNative' }, $true))[0].Value
        $installs = @('kh = SetWindowsHookExW(13, keyboardProc, module, 0);', 'mh = SetWindowsHookExW(14, mouseProc, module, 0);')
        foreach ($install in $installs) { if (-not $nativeSource.Contains($install)) { throw "The harness's input watch no longer installs '$install'." } }
        function New-FramePacingWatchClass([string] $Source, [string] $Prefix) {
            $class = $Prefix + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Add-Type -TypeDefinition ($Source.Replace('public static class FramePacingNative', "public static class $class"))
            return ($class -as [type])
        }
        $standInSource = $nativeSource.Replace($installs[0], 'kh = new IntPtr(1);').Replace($installs[1], 'mh = new IntPtr(1);')
        $standInWatch = New-FramePacingWatchClass $standInSource 'FramePacingWatchStandIn'
        $failingWatch = New-FramePacingWatchClass ($nativeSource.Replace($installs[0], 'kh = IntPtr.Zero;').Replace($installs[1], 'mh = IntPtr.Zero;')) 'FramePacingWatchFailing'
        $watchMarker = [long]0x5EED1234
        function Send-FramePacingHookEvent([type] $Native, [bool] $Keyboard, [uint32] $Flags, [long] $Extra) {
            # KBDLLHOOKSTRUCT (24 bytes, flags at 8, extra info at 16) or MSLLHOOKSTRUCT (32, at 12 and 24), as pinned.
            $size = if ($Keyboard) { 24 } else { 32 }
            $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
            try {
                for ($i = 0; $i -lt $size; $i++) { [Runtime.InteropServices.Marshal]::WriteByte($buffer, $i, 0) }
                [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $(if ($Keyboard) { 8 } else { 12 }), [int]$Flags)
                [Runtime.InteropServices.Marshal]::WriteInt64($buffer, $(if ($Keyboard) { 16 } else { 24 }), $Extra)
                if ($Keyboard) { [void]$Native::KeyboardEvent(0, [IntPtr]0x100, $buffer) } else { [void]$Native::MouseEvent(0, [IntPtr]0x200, $buffer) }
            } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
        }
        # The watched port reads the stand-in's real-input event through RealInputSignalled and models the native
        # workers' decisions after their inputs: the marked event of each kind's wait and ProbeSeen, from the class.
        function New-FramePacingWatchedPort([type] $Native, [IntPtr] $Watch, [IntPtr] $Mouse, [IntPtr] $Key, [long[]] $Ticks) {
            $port = New-FramePacingStandInPort $Ticks 200
            Add-Member -InputObject $port -NotePropertyName Native -NotePropertyValue $Native
            Add-Member -InputObject $port -NotePropertyName Watch -NotePropertyValue $Watch
            Add-Member -InputObject $port -NotePropertyName Mouse -NotePropertyValue $Mouse
            Add-Member -InputObject $port -NotePropertyName Key -NotePropertyValue $Key
            Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputSeen -Force -Value { $native = $this.Native; [bool]$native::RealInputSignalled($this.Watch) }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name Foreground -Force -Value {
                param($HostWindow, $OwnerPid, $BoundMs, $ExpectedTick)
                $this.ForegroundCalls++
                $native = $this.Native
                $why = $native::ProbeSeen('unlock', 100, 200, ($native::WaitForSingleObject($this.Mouse, 0) -eq 0))
                [pscustomobject]@{ Outcome = $(if ($why) { $why } else { 'ok' }); UnlockTick = 200 }
            }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name KeyProbe -Value {
                param($HostWindow, $OwnerPid, $BoundMs, $ExpectedTick)
                $native = $this.Native
                $why = $native::ProbeSeen('key-probe', 200, 300, ($native::WaitForSingleObject($this.Key, 0) -eq 0))
                [pscustomobject]@{ Outcome = $(if ($why) { $why } else { 'ok' }); ProbeTick = 300 }
            }
            return $port
        }
        # One stand-in watch for a body: started with the marker, its three events opened, all closed and stopped after.
        function Use-FramePacingStandInWatch([type] $StandIn, [scriptblock] $Body) {
            $name = 'Local\fp-contract-watch-' + [guid]::NewGuid().ToString('N')
            $StandIn::ResetWatchCounts()
            if (-not $StandIn::StartWatch($name, 5000, [IntPtr]$watchMarker)) { return 'the stand-in watch did not start' }
            try {
                $handles = [pscustomobject]@{ Watch = $StandIn::OpenWatch($name); Mouse = $StandIn::OpenMouseWatch($name); Key = $StandIn::OpenKeyWatch($name) }
                try {
                    if ($handles.Watch -eq [IntPtr]::Zero -or $handles.Mouse -eq [IntPtr]::Zero -or $handles.Key -eq [IntPtr]::Zero) { return 'a driver could not open the series'' events' }
                    return (& $Body $handles)
                } finally { foreach ($h in @($handles.Watch, $handles.Mouse, $handles.Key)) { if ($h -ne [IntPtr]::Zero) { [void]$StandIn::CloseHandle($h) } } }
            } finally { [void]$StandIn::StopWatch() }
        }
        function Get-FramePacingWatchProblem([type] $StandIn, [type] $Failing) {
            foreach ($real in @(@{ Keyboard = $false; Name = 'a real mouse event' }, @{ Keyboard = $true; Name = 'a real key' })) {
                $problem = Use-FramePacingStandInWatch $StandIn {
                    param($h)
                    foreach ($injected in @(@($false, 0x01), @($false, 0x03), @($true, 0x10), @($true, 0x12))) { Send-FramePacingHookEvent $StandIn $injected[0] $injected[1] $watchMarker }
                    if ($StandIn::RealInputs() -ne 0 -or $StandIn::InjectedInputs() -ne 4 -or $StandIn::MarkedMouseInputs() -ne 2 -or $StandIn::MarkedKeyInputs() -ne 2) { return "our marked input counted wrongly ($($StandIn::RealInputs()) real, $($StandIn::InjectedInputs()) injected, $($StandIn::MarkedMouseInputs()) mouse, $($StandIn::MarkedKeyInputs()) keys)" }
                    $port = New-FramePacingWatchedPort $StandIn $h.Watch $h.Mouse $h.Key @(100, 200, 300)
                    $ticks = New-FramePacingTicks 100
                    if ((Invoke-FramePacingForeground $port $ticks ([IntPtr]1) 1) -ne 'ok' -or $port.ForegroundCalls -ne 1) { return "our marked unlock kept the foreground from being called ($($port.ForegroundCalls) calls)" }
                    if ((Invoke-FramePacingKeyProbe $port $ticks ([IntPtr]1) 1) -ne 'ok' -or $ticks.Unlock -ne 300) { return "our marked key did not pass the key probe (tick $($ticks.Unlock))" }
                    Send-FramePacingHookEvent $StandIn $real.Keyboard 0 0
                    if ($StandIn::RealInputs() -ne 1) { return "$($real.Name) was not counted" }
                    $next = New-FramePacingWatchedPort $StandIn $h.Watch $h.Mouse $h.Key @(100)
                    $thrown = $null
                    try { [void](Invoke-FramePacingForeground $next (New-FramePacingTicks 100) ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
                    if (-not $thrown -or -not $thrown.Contains('real (non-injected)') -or $next.ForegroundCalls -ne 0) { return "$($real.Name) through the callback did not block the next foreground ($($next.ForegroundCalls) calls, '$thrown')" }
                    return $null
                }
                if ($problem) { return $problem }
            }
            # Injected input that is not this unlock proves nothing (Opus, Sol and CodeRabbit on #741).
            foreach ($foreign in @(
                    @{ Keyboard = $false; Flags = 0x01; Extra = 0; Name = 'another program''s unmarked injected mouse event' }
                    @{ Keyboard = $false; Flags = 0x01; Extra = $watchMarker + 1; Name = 'a wrongly marked injected mouse event' }
                    @{ Keyboard = $true; Flags = 0x10; Extra = $watchMarker; Name = 'our marked key with the mouse unlock missing' }
                )) {
                $problem = Use-FramePacingStandInWatch $StandIn {
                    param($h)
                    Send-FramePacingHookEvent $StandIn $foreign.Keyboard $foreign.Flags $foreign.Extra
                    if ($StandIn::RealInputs() -ne 0) { return "$($foreign.Name) counted as real" }
                    $port = New-FramePacingWatchedPort $StandIn $h.Watch $h.Mouse $h.Key @(100, 200)
                    $thrown = $null
                    try { [void](Invoke-FramePacingForeground $port (New-FramePacingTicks 100) ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
                    if (-not $thrown -or $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal) -or -not $thrown.Contains('mouse hook did not see the harness''s own unlock')) { return "$($foreign.Name) proved the mouse hook alive ('$thrown')" }
                    return $null
                }
                if ($problem) { return $problem }
            }
            # A hook of each kind that stops receiving events after install (CodeRabbit and the lead on #741).
            $problem = Use-FramePacingStandInWatch $StandIn {
                param($h)
                Send-FramePacingHookEvent $StandIn $false 0x01 $watchMarker
                $seen = New-FramePacingWatchedPort $StandIn $h.Watch $h.Mouse $h.Key @(100, 200)
                if ((Invoke-FramePacingForeground $seen (New-FramePacingTicks 100) ([IntPtr]1) 1) -ne 'ok') { return 'an unlock the hook saw was not ok' }
                $stale = New-FramePacingWatchedPort $StandIn $h.Watch $h.Mouse $h.Key @(100, 200)
                $thrown = $null
                try { [void](Invoke-FramePacingForeground $stale (New-FramePacingTicks 100) ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
                if (-not $thrown -or $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal) -or -not $thrown.Contains('mouse hook did not see the harness''s own unlock')) { return "a mouse hook that stopped receiving events did not refuse the run ('$thrown')" }
                return $null
            }
            if ($problem) { return $problem }
            $problem = Use-FramePacingStandInWatch $StandIn {
                param($h)
                Send-FramePacingHookEvent $StandIn $false 0x01 $watchMarker
                $port = New-FramePacingWatchedPort $StandIn $h.Watch $h.Mouse $h.Key @(100, 200)
                $ticks = New-FramePacingTicks 100
                if ((Invoke-FramePacingForeground $port $ticks ([IntPtr]1) 1) -ne 'ok') { return 'an unlock the hook saw was not ok' }
                $thrown = $null
                try { [void](Invoke-FramePacingKeyProbe $port $ticks ([IntPtr]1) 1) } catch { $thrown = $_.Exception.Message }
                if (-not $thrown -or $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal) -or -not $thrown.Contains('keyboard hook did not see the harness''s own key probe')) { return "a keyboard hook that never saw the probe did not refuse the run ('$thrown')" }
                return $null
            }
            if ($problem) { return $problem }
            $name = 'Local\fp-contract-watch-' + [guid]::NewGuid().ToString('N')
            if ($Failing::StartWatch($name, 5000, [IntPtr]$watchMarker)) { [void]$Failing::StopWatch(); return 'StartWatch was true with no hook installed' }
            if ($Failing::OpenWatch($name) -ne [IntPtr]::Zero -or $Failing::OpenMouseWatch($name) -ne [IntPtr]::Zero -or $Failing::OpenKeyWatch($name) -ne [IntPtr]::Zero) { return 'a failed watch left an event a driver could open' }
            $thrown = $null
            try { Start-FramePacingInputWatch { param([string] $Name) $Failing::StartWatch($Name, 5000, [IntPtr]$watchMarker) } $name } catch { $thrown = $_.Exception.Message }
            if (-not $thrown -or -not $thrown.StartsWith('-Visible is refused: the low-level input hooks could not be installed', [StringComparison]::Ordinal)) { return "a failed hook install did not refuse -Visible ('$thrown')" }
            return $null
        }
        $watchProblem = Get-FramePacingWatchProblem $standInWatch $failingWatch
        if ($watchProblem) { throw "The input watch: $watchProblem." }
        foreach ($control in @(
                @{ Name = 'the keyboard''s injected bit read as the mouse''s'; Old = 'bool injected = keyboard ? (flags & 0x10) != 0 : (flags & 0x01) != 0;'; New = 'bool injected = keyboard ? (flags & 0x01) != 0 : (flags & 0x01) != 0;' }
                @{ Name = 'the real-input event never set'; Old = 'if (!injected) { Interlocked.Increment(ref realInputs); if (watchEvent != IntPtr.Zero) SetEvent(watchEvent); return; }'; New = 'if (!injected) { Interlocked.Increment(ref realInputs); return; }' }
                @{ Name = 'the marker ignored'; Old = 'if (inputMarker == IntPtr.Zero || extra != inputMarker) return;'; New = '' }
                @{ Name = 'the probe accepted without its hook''s sight of it'; Old = 'if (!hookSaw) return what + "-not-seen-by-hook";'; New = '' }
            )) {
            $controlSource = $standInSource.Replace($control.Old, $control.New)
            if ([string]::Equals($controlSource, $standInSource, [StringComparison]::Ordinal)) { throw "The input-watch control changed nothing: $($control.Name)." }
            if ($null -eq (Get-FramePacingWatchProblem (New-FramePacingWatchClass $controlSource 'FramePacingWatchControl') $failingWatch)) { throw "The input-watch cases accepted $($control.Name)." }
        }
        # ProbeSeen, tabled from the compiled class (CodeRabbit, Sol and the lead on #741): only two valid, different
        # ticks and the hook of its kind's sight of the input pass; a failed read (-1) before or after is never a move.
        $probeCases = @(@('unlock', 100, 200, $true, $null), @('unlock', 100, 100, $true, 'unlock-not-observed'), @('unlock', 100, -1, $true, 'unlock-not-observed'), @('unlock', -1, 200, $true, 'unlock-not-observed'), @('unlock', 100, 200, $false, 'unlock-not-seen-by-hook'), @('key-probe', 200, 300, $false, 'key-probe-not-seen-by-hook'), @('key-probe', 200, 200, $true, 'key-probe-not-observed'), @('key-probe', 200, 300, $true, $null))
        foreach ($case in $probeCases) {
            $got = $standInWatch::ProbeSeen($case[0], $case[1], $case[2], $case[3])
            if ($got -ne $case[4]) { throw "ProbeSeen($($case[0]), $($case[1]), $($case[2]), $($case[3])) is '$got', not '$($case[4])'." }
        }
        $cases.Add("input watch (compiled with stand-in installs: our marked unlock and key, lower-IL forms too, pass; another program's unmarked or wrongly marked injected event, and our key without the unlock, refuse; a real mouse event or key blocks the next foreground; a mouse or keyboard hook that stops receiving events refuses; a failed install refuses -Visible; four compiled controls; ProbeSeen in $($probeCases.Count) cases)")

        # Comparable runs only (Greptile, CodeRabbit, Sol and Opus on #741): runs alike pool; runs at 240 Hz and 60 Hz
        # are reported per mode, never pooled, and so are runs at another DPI or grid; runs at two workloads, builds,
        # renderers, transports or ConPTY digests never pool either. The control: the series pooled regardless of
        # environment mixes the two refresh rates.
        function New-FramePacingRun([hashtable] $Change) {
            $r = @{ HarnessSha256 = 'h'; DisplayMode = '3840x2160@240'; Dpi = 144; GridCols = 140; GridRows = 43; WorkloadSha256 = 'w'; ExeSHA256 = 'e'; Renderer = 'opengl'; Transport = 'bundled'; ConptyDllSHA256 = 'c'; OpenConsoleSHA256 = 'o'; IntervalsMs = [double[]]@(4.1, 4.2, 4.3) }
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
        if ($same.Mixed -or $same.Pooled.Count -ne 5 -or $same.P95 -ne 4.4 -or @($same.Groups).Count -ne 1) { throw "Two runs at one display mode did not pool (pooled $($same.Pooled.Count), p95 $($same.P95))." }
        $mixed = Get-FramePacingSeries @($at240, $at60)
        if (-not $mixed.Mixed -or $mixed.Pooled.Count -ne 0 -or $null -ne $mixed.P95 -or @($mixed.Groups).Count -ne 2) { throw "Runs at 240 Hz and 60 Hz were pooled (pooled $($mixed.Pooled.Count), p95 $($mixed.P95))." }
        $by60 = @($mixed.Groups | Where-Object { Test-FramePacingOrdinal $_.display_mode '3840x2160@60' })
        if ($by60.Count -ne 1 -or $by60[0].p95_ms -ne 16.7 -or $by60[0].intervals -ne 2) { throw 'The 60 Hz runs were not reported on their own.' }
        # A group is every run alike in all nine key fields (Sol, CodeRabbit and Opus on #741): runs that differ in any
        # one of them are two groups, never one group's statistics. The control: groups keyed by the display mode alone.
        $keyChanges = @(@{ DisplayMode = '3840x2160@60' }, @{ Dpi = 96 }, @{ GridRows = 45 }, @{ WorkloadSha256 = 'v' }, @{ ExeSHA256 = 'f' }, @{ Renderer = 'fallback' }, @{ Transport = 'inbox' }, @{ ConptyDllSHA256 = 'd' }, @{ OpenConsoleSHA256 = 'p' })
        function Get-FramePacingGroupMiss {
            foreach ($change in $keyChanges) {
                $split = Get-FramePacingSeries @($at240, (New-FramePacingRun $change))
                if (@($split.Groups).Count -ne 2 -or @($split.Groups | Where-Object { $_.runs -ne 1 -or $_.intervals -ne 3 }).Count -ne 0) { return "runs that differ only in $(@($change.Keys)[0]) shared a group" }
            }
            return $null
        }
        $groupMiss = Get-FramePacingGroupMiss
        if ($groupMiss) { throw "The comparability groups: $groupMiss." }
        $groupControl = (Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSeries' 'bench-frame-pacing.ps1').Replace("`$keyFields = @('DisplayMode', 'Dpi', 'Grid', 'WorkloadSha256', 'ExeSHA256', 'Renderer', 'Transport', 'ConptyDllSHA256', 'OpenConsoleSHA256')", "`$keyFields = @('DisplayMode')")
        if ([string]::Equals($groupControl, (Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSeries' 'bench-frame-pacing.ps1'), [StringComparison]::Ordinal)) { throw 'The group-key control changed nothing.' }
        & { . ([scriptblock]::Create($groupControl)); if ($null -eq (Get-FramePacingGroupMiss)) { throw 'The group cases accepted groups keyed by the display mode alone.' } }
        $twoWorkloads = Get-FramePacingSeries @($at240, (New-FramePacingRun @{ WorkloadSha256 = 'v'; IntervalsMs = [double[]]@(4.0) }))
        if ($twoWorkloads.Pooled.Count -ne 0 -or @($twoWorkloads.MixedBuild) -notcontains 'WorkloadSha256') { throw 'Runs at two workloads were pooled.' }
        $seriesText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingSeries' 'bench-frame-pacing.ps1'
        $seriesControl = $seriesText.Replace('$pooled = @(if ($mixedEnvironment.Count -eq 0 -and $mixedBuild.Count -eq 0) {', '$pooled = @(if ($mixedBuild.Count -eq 0) {')
        if ([string]::Equals($seriesControl, $seriesText, [StringComparison]::Ordinal)) { throw 'The display-mode control changed nothing.' }
        & { . ([scriptblock]::Create($seriesControl)); if ((Get-FramePacingSeries @($at240, $at60)).Pooled.Count -ne 5) { throw 'The display-mode control did not pool the two refresh rates.' } }
        $cases.Add('comparability (runs alike pool; 240 Hz with 60 Hz reported per group; DPI, grid; workload, app, renderer, transport, both ConPTY digests; each of the nine key fields its own group; an environment-blind pool and a display-mode-only key as the controls)')

        # The exit code's precedence, tabled (Opus and CodeRabbit on #741): 3 a tripped guard, over 1 a failure or a
        # build difference, over 2 an inconclusive run or an environment difference, over 0. The control: the failure
        # checked before the guard, so a series with both exits 1.
        $exitCases = @(
            @{ Want = 0; Args = @(@('complete', 'complete'), $false, $false, 2, 2) }
            @{ Want = 2; Args = @(@('complete', 'inconclusive'), $false, $false, 1, 2) }
            @{ Want = 1; Args = @(@('complete', 'failed'), $false, $false, 1, 2) }
            @{ Want = 3; Args = @(@('guard-tripped'), $false, $false, 0, 2) }
            @{ Want = 1; Args = @(@('complete', 'complete'), $true, $false, 2, 2) }
            @{ Want = 2; Args = @(@('complete', 'complete'), $false, $true, 2, 2) }
            @{ Want = 1; Args = @(@('complete', 'complete'), $true, $true, 2, 2) }
            @{ Want = 3; Args = @(@('complete', 'complete', 'guard-tripped'), $true, $false, 2, 3) }
            @{ Want = 3; Args = @(@('complete', 'complete', 'guard-tripped'), $false, $true, 2, 3) }
            @{ Want = 1; Args = @(@('complete', 'complete', 'failed'), $false, $true, 2, 3) }
            @{ Want = 2; Args = @(@('complete', 'complete', 'inconclusive'), $false, $true, 2, 3) }
            @{ Want = 1; Args = @(@('complete'), $false, $false, 1, 2) }
        )
        function Get-FramePacingExitMiss {
            foreach ($case in $exitCases) {
                $a = $case.Args
                $got = Get-FramePacingExitCode $a[0] $a[1] $a[2] $a[3] $a[4]
                if ($got -ne $case.Want) { return "statuses $($a[0] -join ','), build $($a[1]), environment $($a[2]), $($a[3]) of $($a[4]): $got, not $($case.Want)" }
            }
            return $null
        }
        $exitMiss = Get-FramePacingExitMiss
        if ($exitMiss) { throw "The exit code: $exitMiss." }
        $exitText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingExitCode' 'bench-frame-pacing.ps1'
        $exitControl = $exitText.Replace("    if (& `$has 'guard-tripped') { return 3 }`n    if (`$BuildDiffers -or (& `$has 'failed')) { return 1 }", "    if (`$BuildDiffers -or (& `$has 'failed')) { return 1 }`n    if (& `$has 'guard-tripped') { return 3 }")
        if ([string]::Equals($exitControl, $exitText, [StringComparison]::Ordinal)) { throw 'The exit-precedence control changed nothing.' }
        & { . ([scriptblock]::Create($exitControl)); if ($null -eq (Get-FramePacingExitMiss)) { throw 'The exit cases accepted a failure ranked over a tripped guard.' } }
        $cases.Add("exit precedence ($($exitCases.Count) cases: guard over failure and build, failure over inconclusive and environment; the failure ranked over the guard as the control)")

        # The summary's published output, from the real function (Sol and CodeRabbit on #741; Opus's M13 and M17): a dry
        # run publishes only dry_run_p95_ms; a visible series publishes frame_time_p95_ms and its median only when every
        # run completed and the runs are comparable, and otherwise has neither field (a passing dry run has them null)
        # and prints that no measurement was published; mixed display modes exit 2, a mixed workload or build 1, a
        # failed run (the first included) 1, a tripped guard 3, and every case writes pacing.json. The cases run under
        # the harness's own StrictMode (Greptile on #741: an empty pool unwrapped to $null threw on .Count there, before
        # pacing.json, and a test without StrictMode read .Count of $null as 0). Controls: Sol's late assignment of the
        # metric before serialization, the median published without the visible check, the Error exit removed, and the
        # pool's old `if` assignment, are each caught.
        function Invoke-FramePacingSummaryCase([bool] $AsVisible, [int] $RunCount, [object[]] $Results, [string] $SummaryText, [string] $SeriesText, $RealInputs, [bool] $TickMoved, [string] $SeriesSha = 'h', [bool] $LockDiagnostics = $false, [bool] $LockPacing = $false) {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('fp-summary-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($root)
            # Sol's round-3 lock (#744): diagnostics.json held open with no sharing for the whole summary.
            # Sol's round-4 lock: pacing.json held the same way instead.
            $lock = if ($LockDiagnostics) { [IO.File]::Open((Join-Path $root 'diagnostics.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } elseif ($LockPacing) { [IO.File]::Open((Join-Path $root 'pacing.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } else { $null }
            try {
                try {
                    $out = & {
                        Set-StrictMode -Version Latest
                        $Visible = $AsVisible; $Runs = $RunCount
                        if ($SummaryText) { . ([scriptblock]::Create($SummaryText)) }
                        if ($SeriesText) { . ([scriptblock]::Create($SeriesText)) }
                        Write-FramePacingSummary $root ([pscustomobject]@{ Head = 'h'; ExeSha256 = 'e' }) $Results $RealInputs $(if ($AsVisible) { 3 } else { $null }) $TickMoved $false $SeriesSha
                    } 6>&1
                } catch {
                    $thrown = "threw: $($_.Exception.Message)"
                    if ($LockPacing) {
                        $lock.Dispose(); $lock = $null
                        $lockedDiag = Join-Path $root 'diagnostics.json'
                        return [pscustomobject]@{ Code = $thrown; Json = $null; Diag = $(if (Test-Path -LiteralPath $lockedDiag -PathType Leaf) { Get-Content -LiteralPath $lockedDiag -Raw | ConvertFrom-Json } else { $null }); PacingBytes = (Get-Item -LiteralPath (Join-Path $root 'pacing.json')).Length; Console = '' }
                    }
                    return [pscustomobject]@{ Code = $thrown; Json = $null; Console = '' }
                }
                if ($LockPacing) { return [pscustomobject]@{ Code = @($out | Where-Object { $_ -is [int] })[-1]; Json = $null; Diag = $null; PacingBytes = $null; Console = '' } }
                if ($null -ne $lock) {
                    $lock.Dispose(); $lock = $null
                    $lockedJson = Join-Path $root 'pacing.json'
                    $lockedConsole = (@($out | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n")
                    return [pscustomobject]@{ Code = @($out | Where-Object { $_ -is [int] })[-1]; Json = $(if (Test-Path -LiteralPath $lockedJson -PathType Leaf) { Get-Content -LiteralPath $lockedJson -Raw | ConvertFrom-Json } else { $null }); Diag = $null; DiagBytes = (Get-Item -LiteralPath (Join-Path $root 'diagnostics.json')).Length; Console = $lockedConsole }
                }
                $jsonPath = Join-Path $root 'pacing.json'
                if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) { return [pscustomobject]@{ Code = 'no pacing.json'; Json = $null; Console = '' } }
                $console = (@($out | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData }) -join "`n")
                $diagPath = Join-Path $root 'diagnostics.json'
                $diag = if (Test-Path -LiteralPath $diagPath -PathType Leaf) { Get-Content -LiteralPath $diagPath -Raw | ConvertFrom-Json } else { $null }
                return [pscustomobject]@{ Code = @($out | Where-Object { $_ -is [int] })[-1]; Json = (Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json); Diag = $diag; Console = $console }
            } finally { if ($null -ne $lock) { $lock.Dispose() }; [IO.Directory]::Delete($root, $true) }
        }
        function New-FramePacingResult([string] $Status, $Record) { return [pscustomobject]@{ Run = "C:\fp\run-$([guid]::NewGuid().ToString('N').Substring(0, 4))"; Status = $Status; Failures = @(); Record = $Record } }
        $runA = New-FramePacingRun @{}; $runB = New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4) }
        $summaryCases = @(
            @{ Name = 'a complete dry run'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 0; Published = $false; Dry = $true; Console = 'dry run: dry_run_p95_ms' }
            @{ Name = 'a partial visible series'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'inconclusive' $null)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-display-mode series (two refresh rates)'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $at60)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-display-mode dry run'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $at60)); Code = 2; Published = $false; Dry = $false; Console = 'dry run: no timing published' }
            @{ Name = 'a visible series at two workloads'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' (New-FramePacingRun @{ WorkloadSha256 = 'v' }))); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-build series (another app)'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' (New-FramePacingRun @{ ExeSHA256 = 'f' }))); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a failed first run'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a failed first dry run'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'dry run: no timing published' }
            @{ Name = 'a dry run stopped by a failed run after a complete one (Sol on #744, round 2)'; Visible = $false; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'dry run: no timing published' }
            @{ Name = 'a visible series stopped by a failed run'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a visible series stopped by a tripped guard'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'guard-tripped' $null)); Code = 3; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-build series stopped by a tripped guard (Opus on #741)'; Visible = $true; Runs = 3; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' (New-FramePacingRun @{ ExeSHA256 = 'f' })), (New-FramePacingResult 'guard-tripped' $null)); Code = 3; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a mixed-display-mode series stopped by a failed run'; Visible = $true; Runs = 3; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $at60), (New-FramePacingResult 'failed' $null)); Code = 1; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a complete visible series'; Visible = $true; Runs = 2; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 0; Published = $true; Dry = $false; Console = 'frame_time_p95_ms 4.4' }
            @{ Name = 'a complete visible series with real input (the lead on #741, round 5: a driver that exited cleanly after the latch)'; Visible = $true; Runs = 2; Real = 1; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a complete visible series whose input count was not read'; Visible = $true; Runs = 2; Real = $null; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
            @{ Name = 'a complete visible series whose tick left the baseline (the lead and Sol on #741, round 6)'; Visible = $true; Runs = 2; Tick = $true; Results = @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult 'complete' $runB)); Code = 2; Published = $false; Dry = $false; Console = 'no measurement published' }
        )
        function Test-FramePacingSummaryCases([string] $SummaryText, [string] $SeriesText) {
            foreach ($case in $summaryCases) {
                $real = if ($case.ContainsKey('Real')) { $case.Real } elseif ($case.Visible) { [long]0 } else { $null }
                $tick = $case.ContainsKey('Tick') -and [bool]$case.Tick
                $got = Invoke-FramePacingSummaryCase $case.Visible $case.Runs $case.Results $SummaryText $SeriesText $real $tick
                if ($null -eq $got.Json) { return "$($case.Name): $($got.Code)" }
                # Every verdict but a pass (the lead and Sol on #741, round 9, and on #744, round 2): pacing.json is
                # exactly the allowlist, its verdict voided for input, else the exit's, its reasons from the fixed set,
                # its exit the one returned; the wording and every statistic are in diagnostics.json, with no
                # dry_run_p95_ms there either.
                $inputVoided = $case.Visible -and ($null -eq $real -or $real -ne 0 -or $tick)
                if ($got.Code -ne 0) {
                    $keys = @($got.Json.PSObject.Properties | ForEach-Object { $_.Name }) -join ' '
                    if (-not (Test-FramePacingOrdinal $keys $framePacingVoidedKeys)) { return "$($case.Name): exit $($got.Code) pacing.json keys '$keys'" }
                    $verdict = if ($inputVoided) { 'voided' } else { @{ 1 = 'failed'; 2 = 'inconclusive'; 3 = 'guard-tripped' }[[int]$case.Code] }
                    if ($got.Json.Verdict -ne $verdict -or $got.Json.ExitCode -ne $got.Code -or $got.Code -ne $case.Code -or @($got.Json.Reasons | Where-Object { $script:FramePacingVoidReasons -notcontains $_ }).Count -ne 0 -or @($got.Json.Reasons).Count -eq 0 -or $got.Json.RealInputsSeen -ne $real -or ($case.Visible -and $got.Json.InjectedInputsSeen -ne 3) -or (-not $case.Visible -and $null -ne $got.Json.InjectedInputsSeen)) { return "$($case.Name): withheld pacing.json exit $($got.Code), verdict $($got.Json.Verdict), reasons '$(@($got.Json.Reasons) -join ' ')'" }
                    if ($null -eq $got.Diag -or $null -ne $got.Diag.dry_run_p95_ms -or -not $got.Console.Contains($case.Console)) { return "$($case.Name): diagnostics.json missing or with a dry p95, or console '$($got.Console)'" }
                    if ($inputVoided -and (-not $got.Diag.PSObject.Properties['Inconclusive'] -or -not ([string]$got.Diag.Inconclusive).Contains('input voided the series'))) { return "$($case.Name): diagnostics.json does not say what voided it" }
                    continue
                }
                if ($inputVoided) { return "$($case.Name): input did not withhold the series (exit 0)" }
                if ($null -ne $got.Diag) { return "$($case.Name): a passing series wrote diagnostics.json" }
                $published = $null -ne $got.Json.frame_time_p95_ms -or $null -ne $got.Json.frame_time_median_ms
                if ($got.Code -ne $case.Code -or $published -ne $case.Published -or ($null -ne $got.Json.dry_run_p95_ms) -ne $case.Dry -or -not $got.Console.Contains($case.Console)) {
                    return "$($case.Name): exit $($got.Code), published $published, dry $($null -ne $got.Json.dry_run_p95_ms), console '$($got.Console)'"
                }
                if ($case.Published -and ($got.Json.frame_time_p95_ms -ne 4.4 -or $got.Json.frame_time_median_ms -ne 4.2)) { return "$($case.Name): p95 $($got.Json.frame_time_p95_ms), median $($got.Json.frame_time_median_ms)" }
                if (-not $got.Json.PSObject.Properties['Groups'] -or -not $got.Json.PSObject.Properties['RealInputsSeen'] -or $got.Json.PSObject.Properties['ByDisplayMode']) { return "$($case.Name): pacing.json lacks Groups or RealInputsSeen, or still has ByDisplayMode" }
                # The hooks' real-input count is the one the series passed, null in a dry run (CodeRabbit on #741), and
                # any real input makes a visible series inconclusive (the lead on #741, round 5).
                if ($got.Json.RealInputsSeen -ne $real) { return "$($case.Name): RealInputsSeen $($got.Json.RealInputsSeen)" }
                if ($case.Visible -and $null -ne $real -and $real -eq 0 -and -not $tick -and $got.Json.PSObject.Properties['Inconclusive'] -and ([string]$got.Json.Inconclusive).Contains('input voided the series')) { return "$($case.Name): inconclusive for real input with none" }
                if ($case.Visible -and ($null -eq $real -or $real -ne 0 -or $tick) -and -not ($got.Json.PSObject.Properties['Inconclusive'] -and ([string]$got.Json.Inconclusive).Contains('input voided the series'))) { return "$($case.Name): not inconclusive for real input" }
                if (($case.Visible -and $got.Json.InjectedInputsSeen -ne 3) -or (-not $case.Visible -and $null -ne $got.Json.InjectedInputsSeen)) { return "$($case.Name): InjectedInputsSeen $($got.Json.InjectedInputsSeen)" }
            }
            return $null
        }
        $summaryProblem = Test-FramePacingSummaryCases $null
        if ($summaryProblem) { throw "The summary published the wrong thing: $summaryProblem." }
        $summaryText = Get-FramePacingFunctionText $framePacingAst 'Write-FramePacingSummary' 'bench-frame-pacing.ps1'
        foreach ($control in @(
                @{ Name = 'Sol''s late assignment'; Old = "    `$summary | ConvertTo-Json -Depth 6 | Set-Content"; New = "    `$summary.frame_time_p95_ms = `$series.P95`n    `$summary | ConvertTo-Json -Depth 6 | Set-Content" }
                @{ Name = 'Opus''s M13, the median without the visible check'; Old = 'frame_time_median_ms = $(if ($publish) { $series.Median }'; New = 'frame_time_median_ms = $(if ($completed.Count -eq $Runs) { $series.Median }' }
                @{ Name = 'Opus''s M17, the Error exit removed'; Old = "`$summary.Contains('Error') `$summary.Contains('Inconclusive')"; New = "`$false `$summary.Contains('Inconclusive')" }
                @{ Name = 'CodeRabbit''s null input count'; Old = 'RealInputsSeen = $RealInputs'; New = 'RealInputsSeen = $null' }
                @{ Name = 'a null injected count'; Old = 'InjectedInputsSeen = $InjectedInputs'; New = 'InjectedInputsSeen = $null' }
                @{ Name = 'an extra field in a voided pacing.json (the lead and Sol on #741, round 9)'; Old = "{ 'failed' }); ExitCode = `$exitCode"; New = "{ 'failed' }); ExitCode = `$exitCode; Runs = @(`$summary.Runs)" }
                @{ Name = 'the old branch, timing withheld only for input or a changed harness (Sol on #744, round 2)'; Old = '$withheld = $voided -or $exitCode -ne 0'; New = '$withheld = $voided' }
                @{ Name = 'a failed dry run''s dry_run_p95_ms kept in diagnostics.json'; Old = "        `$summary.dry_run_p95_ms = `$null`n"; New = '' }
                @{ Name = 'real input ignored (the lead on #741, round 5)'; Old = '$inputSeen = $Visible -and ($null -eq $RealInputs -or [long]$RealInputs -ne 0 -or $TickMoved -or $inputRuns.Count -gt 0)'; New = '$inputSeen = $false' }
                @{ Name = 'an unread input count read as none'; Old = '($null -eq $RealInputs -or [long]$RealInputs -ne 0 -or $TickMoved -or'; New = '($null -ne $RealInputs -and [long]$RealInputs -ne 0 -or $TickMoved -or' }
                @{ Name = 'a moved tick ignored (the lead and Sol on #741, round 6)'; Old = '[long]$RealInputs -ne 0 -or $TickMoved -or $inputRuns.Count -gt 0)'; New = '[long]$RealInputs -ne 0 -or $inputRuns.Count -gt 0)' }
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
        # Sol on #744, round 3: diagnostics.json locked with no sharing. A failure, an inconclusive series and a
        # tripped guard each keep their exit (1, 2, 3) and their allowlisted pacing.json, the console warns that the
        # details were not written and names no diagnostics path. The controls: round 2's order, diagnostics.json
        # first with no catch (Sol's measured shape, which threw before pacing.json), and the catch removed.
        function Get-FramePacingLockedDiagnosticsMiss([string] $SummaryText) {
            foreach ($locked in @(@{ Status = 'failed'; Code = 1; Verdict = 'failed' }, @{ Status = 'inconclusive'; Code = 2; Verdict = 'inconclusive' }, @{ Status = 'guard-tripped'; Code = 3; Verdict = 'guard-tripped' })) {
                $got = Invoke-FramePacingSummaryCase $true 2 @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult $locked.Status $null)) $SummaryText $null ([long]0) $false 'h' $true
                if ($got.Code -ne $locked.Code) { return "a locked diagnostics.json beside a $($locked.Status) run: exit '$($got.Code)', not $($locked.Code)" }
                $keys = if ($null -ne $got.Json) { @($got.Json.PSObject.Properties | ForEach-Object { $_.Name }) -join ' ' } else { '' }
                if (-not (Test-FramePacingOrdinal $keys $framePacingVoidedKeys) -or $got.Json.Verdict -ne $locked.Verdict -or $got.Json.ExitCode -ne $locked.Code) { return "a locked diagnostics.json beside a $($locked.Status) run: pacing.json keys '$keys'" }
                if (-not $got.Console.Contains('warning: diagnostics.json could not be written') -or $got.Console.Contains('diagnostics=') -or $got.DiagBytes -ne 0) { return "a locked diagnostics.json beside a $($locked.Status) run: console '$($got.Console)', diagnostics bytes $($got.DiagBytes)" }
            }
            return $null
        }
        $lockedMiss = Get-FramePacingLockedDiagnosticsMiss $null
        if ($lockedMiss) { throw "The summary under a locked diagnostics.json: $lockedMiss." }
        $diagnosticsTry = "            `$summary.ExitCode = `$exitCode`n            `$summary.dry_run_p95_ms = `$null`n            try { `$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path `$Root 'diagnostics.json') -Encoding utf8NoBOM -ErrorAction Stop }`n            catch { `$diagnosticsFailure = `$_.Exception.Message }`n"
        $diagnosticsBare = "        `$summary.ExitCode = `$exitCode`n        `$summary.dry_run_p95_ms = `$null`n        `$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path `$Root 'diagnostics.json') -Encoding utf8NoBOM`n"
        $allowedStart = "        `$allowed = [ordered]@{`n"
        $pacingFinally = [regex]::Match($summaryText, "(?s)        try \{ \`$allowed \| ConvertTo-Json -Depth 3 \| Set-Content -LiteralPath \(Join-Path \`$Root 'pacing\.json'\) -Encoding utf8NoBOM \}\n        finally \{\n.*?\n        \}\n")
        $pacingPlain = "        `$allowed | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path `$Root 'pacing.json') -Encoding utf8NoBOM`n"
        if (-not $summaryText.Contains($diagnosticsTry) -or -not $summaryText.Contains($allowedStart) -or -not $pacingFinally.Success -or -not $pacingFinally.Value.Contains($diagnosticsTry)) { throw 'The locked-file controls no longer find the pacing.json and diagnostics.json writes.' }
        # Round 2's order: diagnostics.json first and uncaught, the verdict after it with no finally.
        $diagnosticsFirst = $summaryText.Replace($pacingFinally.Value, $pacingPlain).Replace($allowedStart, $diagnosticsBare + $allowedStart)
        $diagnosticsUncaught = $summaryText.Replace($diagnosticsTry, $diagnosticsBare.Replace("`n        ", "`n            ").Replace("        `$summary.ExitCode", "            `$summary.ExitCode"))
        foreach ($control in @(@{ Name = 'round 2''s order, diagnostics.json first and uncaught'; Text = $diagnosticsFirst }, @{ Name = 'the diagnostics write''s catch removed'; Text = $diagnosticsUncaught })) {
            if ([string]::Equals($control.Text, $summaryText, [StringComparison]::Ordinal)) { throw "The locked-diagnostics control changed nothing: $($control.Name)." }
            if ($null -eq (Get-FramePacingLockedDiagnosticsMiss $control.Text)) { throw "The locked-diagnostics cases accepted $($control.Name)." }
        }
        $cases.Add("summary under a locked diagnostics.json (Sol on #744, round 3: exits 1, 2 and 3 each kept with the allowlisted pacing.json and a console warning; round 2's diagnostics-first order and the catch removed as controls)")
        # Sol on #744, round 4: pacing.json locked with no sharing instead. The pacing.json write's error still ends
        # the summary as before, after diagnostics.json is written with the series' exit (1, 2, 3), the completed
        # run's statistics and no dry_run_p95_ms, in either mode. The control: round 3's order, the diagnostics write
        # after the verdict's with no finally, which lost diagnostics.json.
        function Get-FramePacingLockedPacingMiss([string] $SummaryText) {
            foreach ($locked in @(@{ Status = 'failed'; Code = 1 }, @{ Status = 'inconclusive'; Code = 2 }, @{ Status = 'guard-tripped'; Code = 3 })) {
                foreach ($asVisible in @($true, $false)) {
                    $got = Invoke-FramePacingSummaryCase $asVisible 2 @((New-FramePacingResult 'complete' $runA), (New-FramePacingResult $locked.Status $null)) $SummaryText $null $(if ($asVisible) { [long]0 } else { $null }) $false 'h' $false $true
                    $name = "a locked pacing.json beside a $($locked.Status) run (visible $asVisible)"
                    if (-not ([string]$got.Code).StartsWith('threw:', [StringComparison]::Ordinal) -or -not ([string]$got.Code).Contains('pacing.json')) { return "${name}: '$($got.Code)', not the pacing.json write's error" }
                    if ($null -eq $got.Diag -or $got.Diag.ExitCode -ne $locked.Code -or @($got.Diag.Groups | Where-Object { $null -ne $_.p95_ms }).Count -eq 0 -or $null -ne $got.Diag.dry_run_p95_ms -or $got.PacingBytes -ne 0) { return "${name}: diagnostics.json $(if ($null -eq $got.Diag) { 'missing' } else { "exit $($got.Diag.ExitCode)" }), pacing.json bytes $($got.PacingBytes)" }
                }
            }
            return $null
        }
        $lockedPacingMiss = Get-FramePacingLockedPacingMiss $null
        if ($lockedPacingMiss) { throw "The summary under a locked pacing.json: $lockedPacingMiss." }
        $diagnosticsAfter = $summaryText.Replace($pacingFinally.Value, $pacingPlain + $diagnosticsTry.Replace("`n            ", "`n        ").Replace("            `$summary.ExitCode", "        `$summary.ExitCode"))
        if ([string]::Equals($diagnosticsAfter, $summaryText, [StringComparison]::Ordinal)) { throw 'The locked-pacing control changed nothing.' }
        if ($null -ne (Get-FramePacingLockedDiagnosticsMiss $diagnosticsAfter)) { throw 'The locked-pacing control is not round 3''s working order.' }
        if ($null -eq (Get-FramePacingLockedPacingMiss $diagnosticsAfter)) { throw 'The locked-pacing cases accepted round 3''s order, which loses diagnostics.json.' }
        $cases.Add("summary under a locked pacing.json (Sol on #744, round 4: the write's error still ends the summary, after diagnostics.json keeps exits 1, 2 and 3 and the completed run's statistics, in both modes; round 3's order as the control)")
        $cases.Add("summary output ($($summaryCases.Count) cases under StrictMode, pacing.json, the JSON, the console and the exit; every exit but 0 writes the allowlist with its verdict and no timing, and real input or an unread count publishes nothing; Sol's late assignment, Opus's M13 and M17, real input ignored, an unread count read as none, the old voided-only branch, a failed dry run's p95 kept and the pool's old if assignment as controls)")

        # The series' end (the lead, Sol and Opus on #741, round 6), with Sol's stand-in: a watch whose count moves as
        # the hooks come out (an event delivered during the unhook, the last one the hooks can count) voids the
        # series; a quiet one publishes; a moved tick, or a watch that did not stop, voids it. The control: the old
        # order, the count read before the watch stops, which publishes over the late event.
        function New-FramePacingSeriesStandIn([long] $LateEvents, [long] $Tick, [bool] $Stops) {
            $port = [pscustomobject]@{ Kind = 'stand-in'; Count = [long]0; Late = $LateEvents; Tick = $Tick; Stops = $Stops; Stopped = $false }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name StopWatch -Value { if (-not $this.Stopped) { $this.Count += $this.Late; $this.Stopped = $true }; $this.Stops }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputs -Value { $this.Count }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name InjectedInputs -Value { [long]2 }
            Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { $this.Tick }
            return $port
        }
        # Sol's round-7 table: Published is any timing statistic in pacing.json (the headline p95 and median, each
        # group's p95 and median, each run's p95), so a voided series must write none of them; and its Inconclusive
        # names the observation that voided it. The runs carry a p95 of their own (4.4) so the per-run field shows.
        function Invoke-FramePacingSeriesEnd($Port, [string] $CompleteText, [object[]] $Results, [string] $SeriesSha = 'h', [bool] $Dry = $false) {
            $root = Join-Path ([IO.Path]::GetTempPath()) ('fp-end-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($root)
            try {
                $out = & {
                    Set-StrictMode -Version Latest
                    $Visible = -not $Dry; $Runs = 2
                    if ($CompleteText) { . ([scriptblock]::Create($CompleteText)) }
                    Complete-FramePacingSeries $Port $root ([pscustomobject]@{ Head = 'h'; ExeSha256 = 'e' }) $Results 250 $SeriesSha
                } 6>$null
                $raw = Get-Content -LiteralPath (Join-Path $root 'pacing.json') -Raw
                $json = $raw | ConvertFrom-Json
                $diagPath = Join-Path $root 'diagnostics.json'
                $diag = if (Test-Path -LiteralPath $diagPath -PathType Leaf) { Get-Content -LiteralPath $diagPath -Raw | ConvertFrom-Json } else { $null }
                $why = if ($null -ne $diag -and $diag.PSObject.Properties['Inconclusive']) { [string]$diag.Inconclusive } elseif ($json.PSObject.Properties['Inconclusive']) { [string]$json.Inconclusive } else { '' }
                # Every numeric duration in pacing.json (the lead on #741, round 8), wherever it sits: any field whose
                # name ends in ms, and the stand-in stop's 0.087 ms anywhere in the text.
                $durations = [Collections.Generic.List[object]]::new()
                $walk = { param($Node) if ($Node -is [Management.Automation.PSCustomObject]) { foreach ($property in $Node.PSObject.Properties) { if ($property.Name -match '(?i)ms$' -and $null -ne $property.Value) { $durations.Add($property.Value) }; & $walk $property.Value } } elseif ($Node -is [Array]) { foreach ($item in $Node) { & $walk $item } } }
                & $walk $json
                return [pscustomobject]@{ Code = @($out | Where-Object { $_ -is [int] })[-1]; Published = $durations.Count -gt 0 -or $raw.Contains('0.087') -or $raw.Contains('301234'); Headline = $null -ne $json.PSObject.Properties['frame_time_p95_ms'] -and $null -ne $json.frame_time_p95_ms; Real = $json.RealInputsSeen; Why = $why; Keys = (@($json.PSObject.Properties | ForEach-Object { $_.Name }) -join ' '); Reasons = @($(if ($json.PSObject.Properties['Reasons']) { $json.Reasons } else { @() }))
                    Verdict = $(if ($json.PSObject.Properties['Verdict']) { $json.Verdict } else { $null }); Dry = $(if ($json.PSObject.Properties['dry_run_p95_ms']) { $json.dry_run_p95_ms } else { $null }); HasDiag = $null -ne $diag
                    DiagDry = $(if ($null -ne $diag -and $diag.PSObject.Properties['dry_run_p95_ms']) { $diag.dry_run_p95_ms } else { $null }); DiagTimed = $null -ne $diag -and @($diag.Runs | Where-Object { $null -ne $_.p95_ms }).Count -gt 0 }
            } finally { [IO.Directory]::Delete($root, $true) }
        }
        function Get-FramePacingSeriesEndMiss([string] $CompleteText) {
            $timed = New-FramePacingRun @{ P95Ms = 4.4 }; $timedB = New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4); P95Ms = 4.4 }
            $both = @((New-FramePacingResult 'complete' $timed), (New-FramePacingResult 'complete' $timedB))
            # Runs that carry their own latch: one whose driver's end-of-window gate saw 251 and then exited, one whose
            # poll did (through the real poll gate, which latches), and a hook stop with its delay on the result as
            # round 7's writer would have copied it.
            $latched = [pscustomobject]@{ Run = 'C:\fp\run-1'; Status = 'inconclusive'; Failures = @('error: INCONCLUSIVE: the session had input before the end of the measured window'); Record = $timed; InputSeen = $true }
            $pollTicks = [ordered]@{ Series = [long]100; Unlock = [long]250; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
            try { Assert-FramePacingPollGate (New-FramePacingTickQueuePort @(251, 250)) $pollTicks 'the stand-in quiet wait' } catch { }
            $pollRecord = New-FramePacingRun @{ P95Ms = 4.4; InputTicks = [pscustomobject]@{ Unlock = 250; Broken = [bool]$pollTicks.Broken } }
            $polled = [pscustomobject]@{ Run = 'C:\fp\run-1'; Status = 'inconclusive'; Failures = @('error: INCONCLUSIVE: poll'); Record = $pollRecord; InputSeen = (Test-FramePacingRunInput $false $pollRecord) }
            $stopped = [pscustomobject]@{ Run = 'C:\fp\run-1'; Status = 'inconclusive'; Failures = @("inconclusive: $(Get-FramePacingSupervisionStop 1 1)"); Record = $null; InputSeen = $true; LatchToKillMs = 0.087 }
            # Sol's round-9 cases: a run refused for slow staging, its duration in its failure, beside a hook event; and a
            # driver whose session facts read 251 against the series' 250, through the one tick read, which latched.
            $staged = [pscustomobject]@{ Run = 'C:\fp\run-2'; Status = 'inconclusive'; Failures = @('inconclusive: the visible driver was not launched: the run''s staging and guard setup took 301234 ms, over the 300000 ms the foreground-lock bound allows'); Record = $null; InputSeen = $false }
            $factsTicks = [ordered]@{ Series = [long]250; Unlock = $null; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
            & { $script:fpStandInTick = 251; . ([scriptblock]::Create($tickReadText)); [void](Read-FramePacingInputTick $factsTicks) }
            $factsRecord = New-FramePacingRun @{ P95Ms = 4.4; InputTicks = [pscustomobject]@{ Unlock = $null; Broken = [bool]$factsTicks.Broken } }
            $factsRun = [pscustomobject]@{ Run = 'C:\fp\run-2'; Status = 'inconclusive'; Failures = @('error: INCONCLUSIVE: the visible run is refused: the session had input since the series last saw it idle'); Record = $factsRecord; InputSeen = (Test-FramePacingRunInput $false $factsRecord) }
            $quiet = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText $both
            if ($quiet.Code -ne 0 -or -not $quiet.Headline -or -not $quiet.Published) { return "a quiet series: exit $($quiet.Code), headline $($quiet.Headline)" }
            foreach ($case in @(
                    @{ Name = 'an event as the hooks come out'; Reasons = 'hook-count'; Port = (New-FramePacingSeriesStandIn 1 250 $true); Results = $both; Real = 1; Why = 'hook count 1' }
                    @{ Name = 'a tick that moved after the run'; Reasons = 'tick-moved'; Port = (New-FramePacingSeriesStandIn 0 251 $true); Results = $both; Real = 0; Why = 'tick left the series'' baseline' }
                    @{ Name = 'a tick that could not be read'; Reasons = 'tick-unread'; Port = (New-FramePacingSeriesStandIn 0 -1 $true); Results = $both; Real = 0; Why = 'tick could not be read' }
                    @{ Name = 'a watch that did not stop'; Reasons = 'watch-not-stopped'; Port = (New-FramePacingSeriesStandIn 0 250 $false); Results = $both; Real = $null; Why = 'did not stop, so its count could not be read' }
                    @{ Name = 'tick-only input with the run already inconclusive'; Reasons = 'tick-moved run-inconclusive incomplete'; Port = (New-FramePacingSeriesStandIn 0 251 $true); Results = @((New-FramePacingResult 'inconclusive' $timed)); Real = 0; Why = 'tick left the series'' baseline' }
                    @{ Name = 'a hook count with the tick moved too (one input, maybe)'; Reasons = 'hook-count tick-moved'; Port = (New-FramePacingSeriesStandIn 1 251 $true); Results = $both; Real = 1; Why = 'hook count 1; tick also moved (may be the same input)' }
                    @{ Name = 'Sol''s moved-and-returned tick at the final read (the driver''s gate saw 251, the final read 250)'; Reasons = 'run-saw-input run-inconclusive incomplete'; Port = (New-FramePacingSeriesStandIn 0 250 $true); Results = @($latched, (New-FramePacingResult 'complete' $timedB)); Real = 0; Why = "input seen during $(Split-Path -Leaf $latched.Run)" }
                    @{ Name = 'Sol''s moved-and-returned tick at a poll'; Reasons = 'run-saw-input run-inconclusive incomplete'; Port = (New-FramePacingSeriesStandIn 0 250 $true); Results = @($polled); Real = 0; Why = "input seen during $(Split-Path -Leaf $polled.Run)" }
                    @{ Name = 'a hook stop whose delay is guard telemetry'; Reasons = 'hook-count run-saw-input run-inconclusive incomplete'; Port = (New-FramePacingSeriesStandIn 1 250 $true); Results = @($stopped); Real = 1; Why = 'hook count 1' }
                    @{ Name = 'Sol''s slow staging beside a hook event'; Reasons = 'hook-count run-inconclusive incomplete'; Port = (New-FramePacingSeriesStandIn 1 250 $true); Results = @((New-FramePacingResult 'complete' $timed), $staged); Real = 1; Why = 'hook count 1' }
                    @{ Name = 'Sol''s session-facts read of 251 against 250, the later reads back at 250'; Reasons = 'run-saw-input run-inconclusive incomplete'; Port = (New-FramePacingSeriesStandIn 0 250 $true); Results = @((New-FramePacingResult 'complete' $timed), $factsRun); Real = 0; Why = "input seen during $(Split-Path -Leaf $factsRun.Run)" }
                )) {
                $got = Invoke-FramePacingSeriesEnd $case.Port $CompleteText $case.Results
                if (-not (Test-FramePacingOrdinal $got.Keys $framePacingVoidedKeys) -or @($got.Reasons | Where-Object { $script:FramePacingVoidReasons -notcontains $_ }).Count -ne 0) { return "$($case.Name): voided pacing.json keys '$($got.Keys)', reasons '$($got.Reasons -join ' ')'" }
                # The right reasons, not only members of the set (Opus on #741, round 10).
                if (-not (Test-FramePacingOrdinal ($got.Reasons -join ' ') $case.Reasons)) { return "$($case.Name): reasons '$($got.Reasons -join ' ')', not '$($case.Reasons)'" }
                if ($got.Code -ne 2 -or $got.Published -or $got.Real -ne $case.Real -or -not $got.Why.Contains($case.Why) -or ($case.Why.StartsWith('hook count') -and $got.Why.Contains('no input the hooks counted'))) { return "$($case.Name): exit $($got.Code), a timing statistic written $($got.Published), count $($got.Real), '$($got.Why)'" }
            }
            # A changed harness (Sol on #741, round 10), in a series with no input: matching hashes publish; a run whose driver
            # ran other bytes voids the series as harness-changed, exit 1, with the series' own hash in pacing.json.
            $hashed = New-FramePacingRun @{ P95Ms = 4.4; HarnessSha256 = 'aa' }; $hashedB = New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4); P95Ms = 4.4; HarnessSha256 = 'aa' }
            $sameHarness = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText @((New-FramePacingResult 'complete' $hashed), (New-FramePacingResult 'complete' $hashedB)) 'aa'
            if ($sameHarness.Code -ne 0 -or -not $sameHarness.Headline) { return "matching harness hashes: exit $($sameHarness.Code), headline $($sameHarness.Headline)" }
            $otherHarness = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText @((New-FramePacingResult 'complete' $hashed), (New-FramePacingResult 'complete' (New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4); P95Ms = 4.4; HarnessSha256 = 'bb' }))) 'aa'
            if ($otherHarness.Code -ne 1 -or $otherHarness.Published -or -not (Test-FramePacingOrdinal $otherHarness.Keys $framePacingVoidedKeys) -or -not (Test-FramePacingOrdinal ($otherHarness.Reasons -join ' ') 'harness-changed')) { return "a driver that ran other harness bytes: exit $($otherHarness.Code), keys '$($otherHarness.Keys)', reasons '$($otherHarness.Reasons -join ' ')'" }
            # A dry run with a changed harness (Greptile on #744): no watch, so exactly harness-changed, never a watch reason.
            $dryOther = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText @((New-FramePacingResult 'complete' $hashed), (New-FramePacingResult 'complete' (New-FramePacingRun @{ IntervalsMs = [double[]]@(4.0, 4.4); P95Ms = 4.4; HarnessSha256 = 'bb' }))) 'aa' $true
            if ($dryOther.Code -ne 1 -or $dryOther.Published -or -not (Test-FramePacingOrdinal $dryOther.Keys $framePacingVoidedKeys) -or -not (Test-FramePacingOrdinal ($dryOther.Reasons -join ' ') 'harness-changed')) { return "a dry run with a changed harness: exit $($dryOther.Code), keys '$($dryOther.Keys)', reasons '$($dryOther.Reasons -join ' ')'" }
            # No series hash at all (Opus on #744): fails closed, voided as harness-changed, in either mode.
            foreach ($empty in @($true, $false)) {
                $noHash = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText @((New-FramePacingResult 'complete' $hashed), (New-FramePacingResult 'complete' $hashedB)) '' $empty
                if ($noHash.Code -ne 1 -or $noHash.Published -or -not (Test-FramePacingOrdinal ($noHash.Reasons -join ' ') 'harness-changed')) { return "a series with no hash of its own (dry $empty): exit $($noHash.Code), reasons '$($noHash.Reasons -join ' ')'" }
            }
            $drySame = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText @((New-FramePacingResult 'complete' $hashed), (New-FramePacingResult 'complete' $hashedB)) 'aa' $true
            if ($drySame.Code -ne 0 -or $drySame.Keys -eq $framePacingVoidedKeys -or -not $drySame.Published -or $null -eq $drySame.Dry -or $drySame.HasDiag) { return "a clean dry run with matching hashes: exit $($drySame.Code), keys '$($drySame.Keys)', dry $($drySame.Dry), diagnostics $($drySame.HasDiag)" }
            # Sol's replay (#744, round 2): the first driver completes under A; the second loads changed text whose
            # writer names another file, so the outer half finds no run.json. That run reads as no record (the real
            # Read-FramePacingRunRecord over a scratch run directory holding only runs.json, B's record) and fails
            # (the real Get-FramePacingRunStatus over the real record problems), and the series, in either mode,
            # exits 1 with no timing statistic in pacing.json; the earlier run's timing stays in diagnostics.json. A
            # plain driver failure after a good run is the same.
            $replayDir = Join-Path ([IO.Path]::GetTempPath()) ('fp-r2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($replayDir)
            try {
                [IO.File]::WriteAllText((Join-Path $replayDir 'runs.json'), ((New-FramePacingRun @{ P95Ms = 4.4; HarnessSha256 = 'bb' }) | ConvertTo-Json -Depth 4))
                $missing = Read-FramePacingRunRecord (Join-Path $replayDir 'run.json')
                if ($null -ne $missing.Record) { return "Sol's replay: run.json read as a record" }
                $missingStatus = Get-FramePacingRunStatus @() @() 0 $null @(Get-FramePacingRecordProblems $missing.Record)
                if ($missingStatus -ne 'failed') { return "Sol's replay: a run with no readable record is $missingStatus, not failed" }
            } finally { [IO.Directory]::Delete($replayDir, $true) }
            $noRecord = [pscustomobject]@{ Run = 'C:\fp\run-2'; Status = $missingStatus; Failures = @('no record'); Record = $null; InputSeen = $false }
            $plainFailure = [pscustomobject]@{ Run = 'C:\fp\run-2'; Status = 'failed'; Failures = @('driver exit 1'); Record = $hashedB; InputSeen = $false }
            foreach ($failCase in @(@{ Name = 'Sol''s replay, a changed driver with no readable record'; Result = $noRecord }, @{ Name = 'a plain driver failure after a good run'; Result = $plainFailure })) {
                foreach ($dry in @($true, $false)) {
                    $failed = Invoke-FramePacingSeriesEnd (New-FramePacingSeriesStandIn 0 250 $true) $CompleteText @((New-FramePacingResult 'complete' $hashed), $failCase.Result) 'aa' $dry
                    if ($failed.Code -ne 1 -or $failed.Published -or $failed.Verdict -ne 'failed' -or -not (Test-FramePacingOrdinal $failed.Keys $framePacingVoidedKeys) -or -not (Test-FramePacingOrdinal ($failed.Reasons -join ' ') 'run-failed incomplete') -or -not $failed.HasDiag -or $null -ne $failed.DiagDry -or -not $failed.DiagTimed) { return "$($failCase.Name) (dry $dry): exit $($failed.Code), timing written $($failed.Published), verdict $($failed.Verdict), keys '$($failed.Keys)', reasons '$($failed.Reasons -join ' ')', diagnostics $($failed.HasDiag), its dry p95 $($failed.DiagDry)" }
                }
            }
            return $null
        }
        $seriesEndMiss = Get-FramePacingSeriesEndMiss $null
        if ($seriesEndMiss) { throw "The series' end: $seriesEndMiss." }
        $completeText = Get-FramePacingFunctionText $framePacingAst 'Complete-FramePacingSeries' 'bench-frame-pacing.ps1'
        $completeControl = $completeText.Replace("    `$stopped = [bool]`$Port.StopWatch()`n    `$final = Get-FramePacingFinalInput `$stopped ([long]`$Port.RealInputs())", "    `$count = [long]`$Port.RealInputs()`n    `$stopped = [bool]`$Port.StopWatch()`n    `$final = Get-FramePacingFinalInput `$stopped `$count")
        if ([string]::Equals($completeControl, $completeText, [StringComparison]::Ordinal)) { throw 'The series-end control changed nothing.' }
        if ($null -eq (Get-FramePacingSeriesEndMiss $completeControl)) { throw 'The series-end cases accepted the count read before the watch stops (Sol on #741, round 6).' }
        # The controls: round 8's runs' latches ignored and a tick beside a count claimed as a second source; round 9's
        # extra field in a voided pacing.json (Sol's staging duration rides in with the runs), the full summary written
        # as pacing.json, and a reason that is text.
        $summaryTimingText = Get-FramePacingFunctionText $framePacingAst 'Write-FramePacingSummary' 'bench-frame-pacing.ps1'
        foreach ($control in @(
                @{ Name = 'the runs'' own input latches ignored (the lead and Sol on #741, round 8)'; Old = ' -or $TickMoved -or $inputRuns.Count -gt 0)'; New = ' -or $TickMoved)' }
                @{ Name = 'a tick beside a count claimed as a second source'; Old = "        elseif (`$TickMoved -and `$counted) { `$voids += 'tick also moved (may be the same input)' }`n"; New = '' }
                @{ Name = 'an extra field in a voided pacing.json (the lead and Sol on #741, round 9)'; Old = "{ 'failed' }); ExitCode = `$exitCode"; New = "{ 'failed' }); ExitCode = `$exitCode; Runs = @(`$summary.Runs)" }
                @{ Name = 'the full summary written as a voided pacing.json'; Old = '$allowed | ConvertTo-Json -Depth 3 | Set-Content'; New = '$summary | ConvertTo-Json -Depth 3 | Set-Content' }
                @{ Name = 'Sol''s round-2 shape, timing withheld only for input or a changed harness'; Old = '$withheld = $voided -or $exitCode -ne 0'; New = '$withheld = $voided' }
                @{ Name = 'a failed dry run''s dry_run_p95_ms kept in diagnostics.json'; Old = "        `$summary.dry_run_p95_ms = `$null`n"; New = '' }
            )) {
            $timingControl = $summaryTimingText.Replace($control.Old, $control.New)
            if ([string]::Equals($timingControl, $summaryTimingText, [StringComparison]::Ordinal)) { throw "The timing control changed nothing: $($control.Name)." }
            if ($null -eq (Get-FramePacingSeriesEndMiss $timingControl)) { throw "The series-end cases accepted $($control.Name) (Sol on #741, rounds 8 and 9)." }
        }
        $reasonsText = Get-FramePacingFunctionText $framePacingAst 'Get-FramePacingVoidReasons' 'bench-frame-pacing.ps1'
        # Opus's R3 on #741, round 10: run-saw-input dropped, which leaves an input-voided series naming no input.
        $reasonsDropControl = [regex]::Replace($reasonsText, '(?m)^\s+if \(\$InputRuns -gt 0\) \{ \$reasons\.Add\(''run-saw-input''\) \}\r?\n', '')
        if ([string]::Equals($reasonsDropControl, $reasonsText, [StringComparison]::Ordinal)) { throw 'The run-saw-input control changed nothing.' }
        & { . ([scriptblock]::Create($reasonsDropControl)); if ($null -eq (Get-FramePacingSeriesEndMiss $null)) { throw 'The series-end cases accepted reasons with run-saw-input dropped.' } }
        # Opus on #744: the old check, which an empty series hash turned off.
        $failOpen = $summaryTimingText.Replace('$harnessChanged = [string]::IsNullOrEmpty($HarnessSha256) -or (Test-FramePacingHarnessChanged $Results $HarnessSha256)', '$harnessChanged = -not [string]::IsNullOrEmpty($HarnessSha256) -and (Test-FramePacingHarnessChanged $Results $HarnessSha256)')
        if ([string]::Equals($failOpen, $summaryTimingText, [StringComparison]::Ordinal)) { throw 'The fail-closed control changed nothing.' }
        if ($null -eq (Get-FramePacingSeriesEndMiss $failOpen)) { throw 'The series-end cases accepted an empty series hash turning the harness check off.' }
        # Greptile on #744: the watch reasons ungated, which gives a dry run with a changed harness watch-not-stopped.
        $reasonsUngated = $reasonsText.Replace('    if ($Visible) {', '    if ($true) {')
        if ([string]::Equals($reasonsUngated, $reasonsText, [StringComparison]::Ordinal)) { throw 'The watch-reason gate control changed nothing.' }
        & { . ([scriptblock]::Create($reasonsUngated)); if ($null -eq (Get-FramePacingSeriesEndMiss $null)) { throw 'The series-end cases accepted a dry run''s watch reason.' } }
        $reasonsControl = $reasonsText.Replace("`$reasons.Add('hook-count')", "`$reasons.Add(`"hook count `$RealInputs`")")
        if ([string]::Equals($reasonsControl, $reasonsText, [StringComparison]::Ordinal)) { throw 'The void-reason control changed nothing.' }
        & { . ([scriptblock]::Create($reasonsControl)); if ($null -eq (Get-FramePacingSeriesEndMiss $null)) { throw 'The series-end cases accepted a reason that is text with a number.' } }
        $cases.Add("series end (Sol's stand-ins: quiet publishes, and a clean dry run keeps its full output; Sol's round-2 replay of a changed driver with no readable record, through the real record reader and run status, and a plain driver failure after a good run, each exit 1 in both modes with no timing in pacing.json, verdict failed, and the good run's timing in diagnostics.json alone; an event as the hooks come out, a moved or unread tick, a watch that did not stop, tick-only input after an inconclusive run, a count with the tick moved too, Sol's moved-and-returned tick at the final read and at a poll, a hook stop with its delay, Sol's slow staging beside a hook event and Sol's session-facts read each void the series with pacing.json exactly the allowlist, each case's own reasons and no duration anywhere, and name what voided it; the count read before the unhook, the groups' or the runs' statistics kept, the runs' latches ignored, round 7's latch_to_kill_ms and a second source claimed as the controls)")

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
if (-not (Test-FramePacingOrdinal $framePacingLayoutWanted 'Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8 Input=40 mouse@8 MouseInput=32 mouseFlags@12 mouseExtra@24 KeyInput=40 keybd@8 KeybdInput=24 keybdFlags@4 keybdExtra@16 LastInput=8 SecurityAttributes=24 saDescriptor@8 saInherit@16 ProcessInfo=24 piThread@8 piPid@16 piTid@20 Rect=16 rectRight@8 rectBottom@12 WndClassEx=80 wcProc@8 wcClassName@64 Msg=48 msgWParam@16 msgTime@32 KbdHook=24 kbdFlags@8 kbdExtra@16 MouseHook=32 mouseHookFlags@12 mouseHookExtra@24')) {
    throw 'The frame-pacing harness''s SDK layout string changed.'
}
$framePacingClass = 'FramePacingNativeContract' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($framePacingNative[0].Value.Replace('public static class FramePacingNative', "public static class $framePacingClass"))
$framePacingProbe = $framePacingClass -as [type]
$framePacingLayout = $framePacingProbe::Layout()
if (-not (Test-FramePacingOrdinal $framePacingLayout $framePacingLayoutWanted)) { throw "The frame-pacing native layer's layout is $framePacingLayout, not the SDK's." }
foreach ($control in @(
        @{ Name = 'MOUSEINPUT with its flags before its mouse data'; Old = 'struct MouseInput { public int dx, dy; public uint data, flags, time; public IntPtr extra; }'; New = 'struct MouseInput { public int dx, dy; public uint flags, data, time; public IntPtr extra; }' }
        @{ Name = 'KEYBDINPUT with its key as a DWORD'; Old = 'struct KeybdInput { public ushort vk, scan; public uint flags, time; public IntPtr extra; }'; New = 'struct KeybdInput { public uint vk; public ushort scan; public uint flags, time; public IntPtr extra; }' }
        @{ Name = 'LASTINPUTINFO widened'; Old = 'struct LastInput { public uint size, time; }'; New = 'struct LastInput { public ulong size, time; }' }
        @{ Name = 'SECURITY_ATTRIBUTES with its descriptor narrowed'; Old = 'struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }'; New = 'struct SecurityAttributes { public int length; public int descriptor; public int inherit; }' }
        @{ Name = 'MSG with its wParam narrowed'; Old = 'public uint message; public IntPtr wParam, lParam;'; New = 'public uint message; public int wParam; public IntPtr lParam;' }
        @{ Name = 'KBDLLHOOKSTRUCT with flags before scanCode'; Old = 'struct KbdHook { public uint vk, scan, flags, time;'; New = 'struct KbdHook { public uint vk, flags, scan, time;' }
        @{ Name = 'MSLLHOOKSTRUCT with flags before mouseData'; Old = 'struct MouseHook { public int x, y; public uint data, flags, time;'; New = 'struct MouseHook { public int x, y; public uint flags, data, time;' }
    )) {
    $controlSource = $framePacingNative[0].Value.Replace($control.Old, $control.New)
    if ([string]::Equals($controlSource, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw "The layout control changed nothing: $($control.Name)." }
    $controlClass = 'FramePacingNativeControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Add-Type -TypeDefinition ($controlSource.Replace('public static class FramePacingNative', "public static class $controlClass"))
    if (Test-FramePacingOrdinal (($controlClass -as [type])::Layout()) $framePacingLayoutWanted) { throw "The layout check accepted $($control.Name)." }
}

# The outer half's supervision, compiled (the lead, Sol and Opus on #741, round 5): on the real-input latch it closes
# the run's job itself at once, whatever the driver does, and a latch set by the time the driver ends still reads as
# input. Stand-ins: .NET events for the latch and for the driver (unset: Sol's delayed driver, which never ends), and a
# real, empty run job. The controls: the latch after the driver in the wait (Sol's simultaneous signal read as the
# driver's exit), and a 250 ms grace on the driver before the close (the round-4 code's grace).
function Invoke-FramePacingSupervision([type] $Native, $Latched, [bool] $DriverEnded, [uint32] $Ms) {
    $latch = if ($null -ne $Latched) { [Threading.ManualResetEvent]::new([bool]$Latched) } else { $null }
    $driver = [Threading.ManualResetEvent]::new($DriverEnded)
    $job = $Native::CreateRunJob()
    try {
        [long]$observed = 0; [long]$closed = 0
        $latchHandle = if ($null -ne $latch) { $latch.SafeWaitHandle.DangerousGetHandle() } else { [IntPtr]::Zero }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $state = $Native::Supervise($latchHandle, $driver.SafeWaitHandle.DangerousGetHandle(), $job, $Ms, [ref]$observed, [ref]$closed)
        $wall = $clock.Elapsed.TotalMilliseconds
        $closeMs = if ($state -eq 1) { ($closed - $observed) * 1000.0 / $Native::PerformanceFrequency() } else { $null }
        return [pscustomobject]@{ State = $state; CloseMs = $closeMs; WallMs = $wall }
    } finally { [void]$Native::CloseHandle($job); if ($null -ne $latch) { $latch.Dispose() }; $driver.Dispose() }
}
# No latency is asserted (CodeRabbit on #741: a runner descheduled for 100 ms would fail a correct close). The call must
# terminate the job and return, with a driver that never ends, long before its own 30 s timeout (a 10 s watchdog);
# the delay from the observation to the close is reported, not judged. That termination is the next action after the
# latch wins is checked on the source below.
function Get-FramePacingSupervisionNativeMiss([type] $Native) {
    $delayed = Invoke-FramePacingSupervision $Native $true $false 30000
    if ($delayed.State -ne 1 -or $null -eq $delayed.CloseMs -or $delayed.CloseMs -lt 0 -or $delayed.WallMs -ge 10000) { return "the latch with a driver that never ends: state $($delayed.State), returned after $($delayed.WallMs) ms" }
    $script:framePacingSupervisionCloseMs = $delayed.CloseMs
    $both = Invoke-FramePacingSupervision $Native $true $true 5000
    if ($both.State -ne 1) { return "the latch set when the driver ended: state $($both.State)" }
    $ended = Invoke-FramePacingSupervision $Native $false $true 5000
    if ($ended.State -ne 0) { return "a driver that ended with no latch: state $($ended.State)" }
    $running = Invoke-FramePacingSupervision $Native $false $false 20
    if ($running.State -ne 0x102) { return "no latch and a running driver: state $($running.State)" }
    $dryEnded = Invoke-FramePacingSupervision $Native $null $true 5000
    $dryRunning = Invoke-FramePacingSupervision $Native $null $false 20
    if ($dryEnded.State -ne 0 -or $dryRunning.State -ne 0x102) { return "a dry run's wait (no latch): states $($dryEnded.State) and $($dryRunning.State)" }
    return $null
}
$framePacingSupervisionMiss = Get-FramePacingSupervisionNativeMiss $framePacingProbe
if ($framePacingSupervisionMiss) { throw "The outer half's supervision: $framePacingSupervisionMiss." }
# The structure (CodeRabbit on #741): in Supervise's source, the wait's return is followed by the counter read and then,
# when the latch won, TerminateJobObject, with nothing between. The 250 ms grace is its negative control; the latch
# placed after the driver stays a behavioural control, since its simultaneous case returns the driver's exit.
function Test-FramePacingSuperviseStructure([string] $Source) {
    $member = Get-FramePacingCsMember $Source 'public static int Supervise(IntPtr latch, IntPtr process, IntPtr job, uint ms, out long observed, out long closed)' 'bench-frame-pacing.ps1'
    return [regex]::IsMatch($member, 'uint r = WaitForMultipleObjects\(2, new IntPtr\[\] \{ latch, process \}, false, ms\);\s+QueryPerformanceCounter\(out observed\);\s+if \(r == 0\) \{ bool terminated = TerminateJobObject\(job, 1\); QueryPerformanceCounter\(out closed\); return terminated \? 1 : 2; \}')
}
if (-not (Test-FramePacingSuperviseStructure $framePacingNative[0].Value)) { throw 'Supervise does not terminate the job as its next action after the latch wins.' }
$framePacingGraceSource = $framePacingNative[0].Value.Replace('if (r == 0) { bool terminated = TerminateJobObject(job, 1);', 'if (r == 0) { WaitForSingleObject(process, 250); bool terminated = TerminateJobObject(job, 1);')
if ([string]::Equals($framePacingGraceSource, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The supervision-grace control changed nothing.' }
if (Test-FramePacingSuperviseStructure $framePacingGraceSource) { throw 'The supervision structure check accepted a 250 ms grace before the close.' }
$framePacingLateLatch = $framePacingNative[0].Value.Replace('uint r = WaitForMultipleObjects(2, new IntPtr[] { latch, process }, false, ms);', 'uint r = WaitForMultipleObjects(2, new IntPtr[] { process, latch }, false, ms); r = r == 0 ? 1u : r == 1 ? 0u : r;')
if ([string]::Equals($framePacingLateLatch, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The latch-order control changed nothing.' }
$framePacingLateClass = 'FramePacingSuperviseControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($framePacingLateLatch.Replace('public static class FramePacingNative', "public static class $framePacingLateClass"))
if ($null -eq (Get-FramePacingSupervisionNativeMiss ($framePacingLateClass -as [type]))) { throw 'The supervision cases accepted the latch after the driver in the wait (Sol on #741).' }

# Every wait of the driver reads the gate at each 100 ms (the lead and Sol on #741, round 6): its code has no native
# wait, sleep or load reading longer than 100 ms of its own, only the polled helpers; and those helpers, run against
# this native class with a stand-in gate that reports input on its third read and a process that never ends, stop
# within the wait. The controls: the old quit wait (60 s with no poll) found by the scan, and a process wait without
# its poll, which runs out its time instead.
$framePacingDriverText = Get-FramePacingFunctionText $framePacingAst 'Invoke-FramePacingDriver' 'bench-frame-pacing.ps1'
function Get-FramePacingLongWaits([string] $Text) {
    # Any class's WaitForSingleObject, a Thread.Sleep, a WaitOne and a millisecond Start-Sleep, over 100 ms or with a
    # bound that is not a literal; any Start-Sleep in seconds, named or positional (Opus on #741, round 7).
    foreach ($m in [regex]::Matches($Text, '::WaitForSingleObject\([^,()]+, ([^()]+?)\)|\]::Sleep\(([^()]+?)\)|\.WaitOne\(([^()]*?)\)|Start-Sleep -Milliseconds ([^\s;)}]+)')) {
        $bound = @($m.Groups[1], $m.Groups[2], $m.Groups[3], $m.Groups[4] | Where-Object { $_.Success })[0].Value
        $ms = 0
        if (-not [int]::TryParse($bound, [ref]$ms) -or $ms -gt 100) { $m.Value }
    }
    foreach ($m in [regex]::Matches($Text, 'Start-Sleep -Seconds|Start-Sleep\s+(?!-)|::BusyPercent\(')) { $m.Value }
}
$framePacingLongWaits = @(Get-FramePacingLongWaits $framePacingDriverText)
if ($framePacingLongWaits.Count -ne 0) { throw "The driver waits without reading the gate: $($framePacingLongWaits -join '; ')." }
if (@(Get-FramePacingLongWaits ($framePacingDriverText.Replace("if (Wait-FramePacingProcess `$process 60000 'the copy''s quit')", 'if ([FramePacingNative]::WaitForSingleObject($process, 60000) -eq 0)'))).Count -ne 1) { throw 'The long-wait scan missed the old quit wait.' }
foreach ($control in @(
        @{ Name = 'Opus''s P9, another class''s 60 s wait beside +version''s'; Old = "if (-not (Wait-FramePacingProcess `$check.process 60000 '+version'))"; New = "[void][HiddenLocal]::WaitForSingleObject(`$check.process, 60000)`n            if (-not (Wait-FramePacingProcess `$check.process 60000 '+version'))" }
        @{ Name = 'Opus''s P10, a 3 s Thread.Sleep before the grid probe''s wait'; Old = "if (-not (Wait-FramePacingProcess `$probe.process 60000 'the grid probe'))"; New = "[Threading.Thread]::Sleep(3000)`n            if (-not (Wait-FramePacingProcess `$probe.process 60000 'the grid probe'))" }
        @{ Name = 'a WaitOne with no bound'; Old = "if (-not (Wait-FramePacingProcess `$probe.process 60000 'the grid probe'))"; New = "[void]`$event.WaitOne()`n            if (-not (Wait-FramePacingProcess `$probe.process 60000 'the grid probe'))" }
        @{ Name = 'a positional Start-Sleep in seconds'; Old = "if (-not (Wait-FramePacingProcess `$probe.process 60000 'the grid probe'))"; New = "Start-Sleep 3`n            if (-not (Wait-FramePacingProcess `$probe.process 60000 'the grid probe'))" }
    )) {
    $scanControl = $framePacingDriverText.Replace($control.Old, $control.New)
    if ([string]::Equals($scanControl, $framePacingDriverText, [StringComparison]::Ordinal)) { throw "The long-wait control changed nothing: $($control.Name)." }
    if (@(Get-FramePacingLongWaits $scanControl).Count -ne 1) { throw "The long-wait scan missed $($control.Name)." }
}
$framePacingWaitText = (Get-FramePacingFunctionText $framePacingAst 'Wait-FramePacingProcess' 'bench-frame-pacing.ps1').Replace('[FramePacingNative]::', "[$framePacingClass]::")
function Get-FramePacingPolledWaitMiss([string] $WaitText) {
    return & {
        . ([scriptblock]::Create($WaitText))
        $script:fpPolls = 0
        function Assert-QuietPoll([string] $During) { $script:fpPolls++; if ($script:fpPolls -ge 3) { throw "INCONCLUSIVE: input during $During" } }
        $never = [Threading.ManualResetEvent]::new($false); $ended = [Threading.ManualResetEvent]::new($true)
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew(); $thrown = $null
            try { [void](Wait-FramePacingProcess $never.SafeWaitHandle.DangerousGetHandle() 1500 'a stand-in wait') } catch { $thrown = $_.Exception.Message }
            if ($null -eq $thrown -or -not $thrown.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal) -or $clock.ElapsedMilliseconds -ge 1200) { return "a process that never ends with input on the third poll: thrown '$thrown' after $($clock.ElapsedMilliseconds) ms" }
            $script:fpPolls = 0
            if (-not (Wait-FramePacingProcess $ended.SafeWaitHandle.DangerousGetHandle() 1500 'a stand-in wait') -or $script:fpPolls -ne 0) { return 'a process that had ended did not return at once' }
            return $null
        } finally { $never.Dispose(); $ended.Dispose() }
    }
}
$framePacingPolledMiss = Get-FramePacingPolledWaitMiss $framePacingWaitText
if ($framePacingPolledMiss) { throw "The driver's polled process wait: $framePacingPolledMiss." }
$framePacingWaitControl = $framePacingWaitText.Replace("                Assert-QuietPoll `$During`n", '')
if ([string]::Equals($framePacingWaitControl, $framePacingWaitText, [StringComparison]::Ordinal)) { throw 'The polled-wait control changed nothing.' }
if ($null -eq (Get-FramePacingPolledWaitMiss $framePacingWaitControl)) { throw 'The polled-wait cases accepted a process wait without its poll.' }

# The one tick read (the lead and Sol on #741, round 9): outside Read-FramePacingInputTick, no PowerShell code calls the
# native tick reads, and in the native source GetLastInputInfo is called only by its two wrappers, LastInputTick and
# LastInputNow, which the native workers use for their own bounded checks (whose input outcomes latch). The control: a
# direct read put back in the driver's session facts.
$framePacingTickReadText = Get-FramePacingFunctionText $framePacingAst 'Read-FramePacingInputTick' 'bench-frame-pacing.ps1'
# Not lexical alone (Opus and Sol on #741, round 10): PowerShell code may not name a native tick read at all, called,
# invoked (`.Invoke()`) or as a method group, nor name it as a string (reflection); the native source may declare
# GetLastInputInfo once and name it nowhere but inside LastInputTick and LastInputNow (comments and strings blanked, so
# a third wrapper under any variable name, a delegate or a method group counts), and no string or EntryPoint may name it.
function Get-FramePacingRawTickReads([string] $Text) {
    $powershell = $Text.Replace($framePacingNative[0].Value, '').Replace($framePacingTickReadText, '')
    # The scan checks the plain forms only (Sol and Opus on #744): a method named by a computed value (`.$name(`,
    # `::$name(`), reflection whose name is built up (GetMethod or InvokeMember over a concatenation) and, on the native
    # side, a concatenated EntryPoint or a method that wraps a tick read again all get past it. It guards against an
    # accidental second read, not a deliberate one.
    return @([regex]::Matches($powershell, '::\s*LastInput(?:Tick|Now)\b|GetLastInputInfo|[''"]LastInput(?:Tick|Now)[''"]') | ForEach-Object { $_.Value })
}
function Get-FramePacingNativeTickReadProblems([string] $Text) {
    $code = Get-FramePacingCsCode $Text
    $start = $Text.IndexOf('public static class FramePacingNative', [StringComparison]::Ordinal)
    $raw = $Text.Substring($start, $Text.IndexOf("`n'@", $start, [StringComparison]::Ordinal) - $start)
    $declarations = [regex]::Matches($code, 'extern\s+\w+\s+GetLastInputInfo\s*\(').Count
    if ($declarations -ne 1) { "$declarations GetLastInputInfo declarations" }
    $names = [regex]::Matches($code, '\bGetLastInputInfo\b').Count
    if ($names -ne 3) { "GetLastInputInfo named $names times in the native code, not its declaration and its two wrappers' calls" }
    foreach ($signature in @('public static long LastInputTick()', 'public static long[] LastInputNow()')) {
        $member = Get-FramePacingCsCode ("public static class FramePacingNative {`n" + (Get-FramePacingCsMember $Text $signature 'bench-frame-pacing.ps1') + "`n}`n'@")
        if ([regex]::Matches($member, '\bGetLastInputInfo\s*\(').Count -ne 1) { "$signature does not call GetLastInputInfo exactly once" }
    }
    if ([regex]::IsMatch($raw, '"[^"\r\n]*GetLastInputInfo[^"\r\n]*"')) { 'a string names GetLastInputInfo (an EntryPoint or reflection)' }
    if ([regex]::IsMatch($code, '\b(?:GetProcAddress|GetDelegateForFunctionPointer|NativeLibrary|LoadLibrary)\b')) { 'the native code loads a function by address' }
}
$framePacingRawReads = @(Get-FramePacingRawTickReads $framePacingText)
if ($framePacingRawReads.Count -ne 0) { throw "PowerShell code reads the input tick outside Read-FramePacingInputTick: $($framePacingRawReads -join '; ')." }
$framePacingNativeReadProblems = @(Get-FramePacingNativeTickReadProblems $framePacingText)
if ($framePacingNativeReadProblems.Count -ne 0) { throw "The native tick reads: $($framePacingNativeReadProblems -join '; ')." }
foreach ($control in @(
        @{ Name = 'a direct read in the session facts'; Old = '    $read = Read-FramePacingInputTick $Ticks'; New = '    $read = [pscustomobject]@{ Tick = [FramePacingNative]::LastInputTick(); IdleMs = 0 }' }
        @{ Name = 'Opus''s .Invoke() read in the session facts'; Old = '    $read = Read-FramePacingInputTick $Ticks'; New = '    $read = [pscustomobject]@{ Tick = [FramePacingNative]::LastInputNow.Invoke()[0]; IdleMs = 0 }' }
        @{ Name = 'a reflection read in the session facts'; Old = '    $read = Read-FramePacingInputTick $Ticks'; New = '    $read = [pscustomobject]@{ Tick = [FramePacingNative].GetMethod(''LastInputNow'').Invoke($null, @())[0]; IdleMs = 0 }' }
    )) {
    $rawControl = $framePacingText.Replace($control.Old, $control.New)
    if ([string]::Equals($rawControl, $framePacingText, [StringComparison]::Ordinal)) { throw "The raw-tick-read control changed nothing: $($control.Name)." }
    if (@(Get-FramePacingRawTickReads $rawControl).Count -ne 1) { throw "The raw-tick-read scan missed $($control.Name)." }
}
foreach ($control in @(
        @{ Name = 'Sol''s third wrapper, its struct named sample'; New = "    public static long Sample() { var sample = new LastInput { size = (uint)Marshal.SizeOf<LastInput>() }; return GetLastInputInfo(ref sample) ? (long)sample.time : -1; }`n" }
        @{ Name = 'an EntryPoint alias'; New = "    [DllImport(`"user32.dll`", EntryPoint = `"GetLastInputInfo`")] static extern bool ReadIdle(ref LastInput info);`n" }
        @{ Name = 'a method group'; New = "    static readonly object Reader = (System.Func<int>)(() => { var x = new LastInput(); return GetLastInputInfo(ref x) ? 1 : 0; });`n" }
    )) {
    $nativeControl = $framePacingText.Replace('    public static long[] LastInputNow() {', $control.New + '    public static long[] LastInputNow() {')
    if ([string]::Equals($nativeControl, $framePacingText, [StringComparison]::Ordinal)) { throw "The native-read control changed nothing: $($control.Name)." }
    if (@(Get-FramePacingNativeTickReadProblems $nativeControl).Count -eq 0) { throw "The native-read scan missed $($control.Name)." }
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

# The native foreground without the series' watch, compiled (the lead on #741): with no window (the null window's owner
# is 0) it returns "no-input-watch" before any hung check, input or foreground call. The control: the same source
# without that check goes on to the hung check, which a null window fails, so it too sends nothing.
$framePacingUnlock = [long]0
$framePacingNoWatch = $framePacingProbe::Foreground([IntPtr]::Zero, 0, 1000, 0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$framePacingUnlock)
if (-not (Test-FramePacingOrdinal $framePacingNoWatch 'no-input-watch') -or $framePacingUnlock -ne -1) { throw "The native foreground without a watch returned $framePacingNoWatch (unlock tick $framePacingUnlock), not no-input-watch." }
$framePacingNoProbe = $framePacingProbe::KeyProbe([IntPtr]::Zero, 0, 1000, 0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$framePacingUnlock)
if (-not (Test-FramePacingOrdinal $framePacingNoProbe 'no-input-watch') -or $framePacingUnlock -ne -1) { throw "The native key probe without a watch returned $framePacingNoProbe, not no-input-watch." }
$noWatchControl = $framePacingNative[0].Value.Replace('if (watch == IntPtr.Zero || mouseWatch == IntPtr.Zero || marker == IntPtr.Zero) return "no-input-watch";', '')
if ([string]::Equals($noWatchControl, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The no-watch control changed nothing.' }
$noWatchClass = 'FramePacingNoWatchControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($noWatchControl.Replace('public static class FramePacingNative', "public static class $noWatchClass"))
if (Test-FramePacingOrdinal (($noWatchClass -as [type])::Foreground([IntPtr]::Zero, 0, 1000, 0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$framePacingUnlock)) 'no-input-watch') { throw 'The no-watch control still returned no-input-watch.' }

# The unlock's and the keyboard probe's payloads, read back from the arrays the workers send (Sol's mutation on #741:
# a motion added to the input), with the series' marker in each. The unlock is one marked absolute move at the
# coordinates it is given (UNLOCK-HOOK-01). The controls: the old zero-delta relative move, and the probe's key changed
# to A, give other payloads.
$framePacingMarker = [IntPtr]0x5EED
$framePacingPayloadWanted = 'count=1 type=0 dx=1234 dy=5678 data=0 flags=49153 time=0 extra=24301'
if (-not (Test-FramePacingOrdinal ($framePacingProbe::UnlockPayload($framePacingMarker, 1234, 5678)) $framePacingPayloadWanted)) { throw "The unlock payload is $($framePacingProbe::UnlockPayload($framePacingMarker, 1234, 5678)), not one marked absolute MOUSEEVENTF_MOVE at its coordinates." }
$framePacingProbeWanted = 'count=2 type=1 vk=252 scan=0 flags=0 time=0 extra=24301; type=1 vk=252 scan=0 flags=2 time=0 extra=24301'
if (-not (Test-FramePacingOrdinal ($framePacingProbe::KeyProbePayload($framePacingMarker)) $framePacingProbeWanted)) { throw "The key probe's payload is $($framePacingProbe::KeyProbePayload($framePacingMarker)), not a marked VK_NONAME down and up." }
$probeControl = $framePacingNative[0].Value.Replace('probe[0].keybd.vk = 0xFC;', 'probe[0].keybd.vk = 0x41;')
if ([string]::Equals($probeControl, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The probe-payload control changed nothing.' }
$probeClass = 'FramePacingProbeControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($probeControl.Replace('public static class FramePacingNative', "public static class $probeClass"))
if (Test-FramePacingOrdinal (($probeClass -as [type])::KeyProbePayload($framePacingMarker)) $framePacingProbeWanted) { throw 'The probe-payload check accepted another key.' }
$payloadControl = $framePacingNative[0].Value.Replace("unlock[0].mouse.dx = nx; unlock[0].mouse.dy = ny;`n        unlock[0].mouse.flags = 0xC001;", "unlock[0].mouse.flags = 0x0001;")
if ([string]::Equals($payloadControl, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The unlock-payload control changed nothing.' }
$payloadClass = 'FramePacingPayloadControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($payloadControl.Replace('public static class FramePacingNative', "public static class $payloadClass"))
if (Test-FramePacingOrdinal (($payloadClass -as [type])::UnlockPayload($framePacingMarker, 1234, 5678)) $framePacingPayloadWanted) { throw 'The unlock-payload check accepted the zero-delta relative move.' }
# The unlock's aim (UNLOCK-HOOK-01): Normalize gives each pixel the smallest normalized value that Windows' floor
# mapping, floor(n * size / 65536), sends back to it, on a single display, on a virtual desktop with a negative origin
# and on a 38,400-pixel axis, and 0 at the origin. Nearest rounding is guaranteed to agree only up to 32,768 pixels
# an axis and can fail above it (Sol and Opus on #746: half-up first misses at 32,769; on 38,400, offset 3 normalizes
# to 6, which nearest maps to 4), so it is checked only there. The control: a
# plain floor of pixel * 65536 / size, which misses under floor mapping.
function Get-FramePacingNormalizeMiss([type] $Class) {
    if ($Class::Normalize(-15357, -15360, 38400) -ne 6 -or [Math]::Floor(6 * 38400 / 65536.0) -ne 3 -or [Math]::Round(6 * 38400 / 65536.0) -ne 4) { return "Sol's 38,400-pixel case: offset 3 is $($Class::Normalize(-15357, -15360, 38400))" }
    foreach ($desk in @(@{ Origin = 0; Size = 3840 }, @{ Origin = 0; Size = 2160 }, @{ Origin = -1920; Size = 5760 }, @{ Origin = 0; Size = 1366 }, @{ Origin = -15360; Size = 38400 })) {
        if ($Class::Normalize($desk.Origin, $desk.Origin, $desk.Size) -ne 0) { return "origin of $($desk.Size)" }
        for ($pixel = $desk.Origin; $pixel -lt $desk.Origin + $desk.Size; $pixel += 7) {
            $n = $Class::Normalize($pixel, $desk.Origin, $desk.Size)
            if ($n -lt 0 -or $n -gt 65535) { return "pixel $pixel of $($desk.Size): $n out of range" }
            $floored = $desk.Origin + [Math]::Floor($n * $desk.Size / 65536.0); $rounded = $desk.Origin + [Math]::Round($n * $desk.Size / 65536.0)
            if ($floored -ne $pixel -or ($desk.Size -le 32768 -and $rounded -ne $pixel)) { return "pixel $pixel of $($desk.Size): $n maps to $floored (floor) or $rounded (round)" }
        }
    }
    return $null
}
$normalizeMiss = Get-FramePacingNormalizeMiss $framePacingProbe
if ($normalizeMiss) { throw "The unlock's aim misses: $normalizeMiss." }
$normalizeControl = $framePacingNative[0].Value.Replace('return (int)Math.Ceiling((pixel - origin) * 65536.0 / size);', 'return (int)Math.Floor((pixel - origin) * 65536.0 / size);')
if ([string]::Equals($normalizeControl, $framePacingNative[0].Value, [StringComparison]::Ordinal)) { throw 'The aim control changed nothing.' }
$normalizeClass = 'FramePacingAimControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($normalizeControl.Replace('public static class FramePacingNative', "public static class $normalizeClass"))
if ($null -eq (Get-FramePacingNormalizeMiss ($normalizeClass -as [type]))) { throw 'The aim cases accepted a plain floor.' }
# The marker's width (UNLOCK-HOOK-01): 2,000 markers from the harness's own generator, each nonzero and within 31 bits.
# The control: the old 64-bit generator, whose markers a low-level mouse hook never sees whole.
function Get-FramePacingMarkerMiss([string] $GeneratorText) {
    . ([scriptblock]::Create($GeneratorText))
    for ($i = 0; $i -lt 2000; $i++) { $m = New-FramePacingInputMarker; if ($m -le 0 -or $m -gt 0x7FFFFFFF) { return "marker $m" } }
    return $null
}
$markerText = Get-FramePacingFunctionText $framePacingAst 'New-FramePacingInputMarker' 'bench-frame-pacing.ps1'
$markerMiss = Get-FramePacingMarkerMiss $markerText
if ($markerMiss) { throw "The series' marker is not a nonzero 31-bit value: $markerMiss." }
$markerControl = $markerText.Replace('$bytes = [byte[]]::new(4)', '$bytes = [byte[]]::new(8)').Replace('$marker = [long]([BitConverter]::ToUInt32($bytes, 0) -band 0x7FFFFFFF)', '$marker = [BitConverter]::ToInt64($bytes, 0)')
if ([string]::Equals($markerControl, $markerText, [StringComparison]::Ordinal)) { throw 'The marker-width control changed nothing.' }
if ($null -eq (Get-FramePacingMarkerMiss $markerControl)) { throw 'The marker cases accepted the old 64-bit marker.' }

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
        # The supervision for real (the lead on #741, round 5): a driver that never ends on its own, a busy
        # cmd.exe /D /C for /L loop in a run job on this check's private desktop, and the latch set. The close comes at
        # once and ends it with exit code 1; the job's kill-on-close ends it in the finally if anything here fails.
        $busyJob = $framePacingProbe::CreateRunJob()
        $busyLatch = [Threading.ManualResetEvent]::new($true)
        try {
            $busy = $framePacingProbe::LaunchDriver($cmdExe, ('"{0}" /D /C "for /L %i in (1,0,2) do rem"' -f $cmdExe), $jobDir, "WinSta0\$jobDesktopName", $busyJob, $false)
            try {
                [long]$observed = 0; [long]$closed = 0
                $busyState = $framePacingProbe::Supervise($busyLatch.SafeWaitHandle.DangerousGetHandle(), $busy.process, $busyJob, 30000, [ref]$observed, [ref]$closed)
                $busyEnded = $framePacingProbe::WaitForSingleObject($busy.process, 10000) -eq 0
                $busyExit = if ($busyEnded) { $framePacingProbe::ExitCode($busy.process) } else { $null }
                $busyCloseMs = ($closed - $observed) * 1000.0 / $framePacingProbe::PerformanceFrequency()
                if ($busyState -ne 1 -or -not $busyEnded -or $busyExit -ne 1) { throw "The supervision did not end a busy driver on the latch (state $busyState, ended within 10 s $busyEnded, exit $busyExit)." }
            } finally { [void]$framePacingProbe::CloseHandle($busy.thread); [void]$framePacingProbe::CloseHandle($busy.process) }
        } finally { [void]$framePacingProbe::CloseHandle($busyJob); $busyLatch.Dispose() }
        $framePacingJobCase = "owned-job (a real suspended cmd.exe /D /C exit 0 on a private desktop is a member of its job; without the assignment it is ended before it runs; a busy cmd driver in a run job is ended within a 10 s watchdog, exit 1, when the latch is set, its close $([Math]::Round($busyCloseMs, 3)) ms after the observation here, reported not judged)"
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
    if (-not $repoOut.Contains('frame-pacing:') -or -not $repoOut.Contains($missingRepo)) { throw "bench-windows.ps1 -Metric frame-pacing did not say why the harness refused its measure repo:`n$repoOut" }
    if (Test-Path -LiteralPath $missingRepo) { throw 'The refused frame-pacing run created its run root.' }
    $framePacingBenchCase = 'bench exits (-Runs 51 refused by the wrapper; a refused measure repo exits 1 and names the repo after frame-pacing:)'
} else { $framePacingBenchCase = 'bench exits skipped (no pwsh.exe)' }
Write-Host "Frame-pacing harness contract: $framePacingMutations rules, each with a rejected mutation; $framePacingSharedCount shared pieces identical to #739's and bench-windows.ps1's; input discipline (controls: a second foreground, a third SendInput; $($framePacingInputApis.Count) other input APIs, each caught); every native input and foreground call behind the worker's stop check, found in the comment- and string-free C# with any spacing, with no attach, key-state reset or raise (Opus's N1, a same-line second call, a dropped check, an added attach, an added raise and a spaced call in IsForeground as controls); each worker's tick set once (control); every posted key behind a gate (Opus's R6 as the control); the keyboard probe's encoder test in win32/input.zig; the hooks reading only flags and extra info, unhooked in a finally and started only on the visible path (Sol's three mutations among the controls); $($framePacingMemberPins.Count) hook and foreground members pinned, with both gates' RealInputSeen ($($framePacingHookControls.Count) mutations as controls: Opus's ten, R1 and the marker ignored); forbidden forms ($($framePacingForbidden.Count), each caught); trace protocol against consts.zig, render_trace.zig and bench_marker.zig; constants pinned; $($framePacingCases -join '; '); native layout $framePacingLayout (7 controls); the native foreground without a watch (control); the outer half's supervision (the latch terminates the job as the next action, checked on the source with a 250 ms grace as the control, and returns with a driver that never ends inside a 10 s watchdog, its close $([Math]::Round([double]$script:framePacingSupervisionCloseMs, 3)) ms after the observation here, reported not judged; the latch wins over a driver that ended, with the latch after the driver as the control; a dry run waits on the driver alone); one tick read (no PowerShell code names a native tick read but Read-FramePacingInputTick, called, invoked or by reflection; GetLastInputInfo declared once and named only in its two native wrappers, with no string, EntryPoint or loaded address naming it; a direct, an .Invoke() and a reflection read, a third wrapper, an EntryPoint alias and a method group as the controls); every driver wait polled (a scan for any class's waits, Thread.Sleep, WaitOne, sleeps and load readings over 100 ms, the old quit wait, Opus's P9 and P10, an unbounded WaitOne and a positional sleep as its controls; the process wait stops within the wait on a stand-in gate's input, a wait without its poll as the control); desktop assignments (control); DesktopRefusal ($($framePacingRefusalCases.Count) cases; Opus's M4, M5/M6 and M21 compiled as controls); unlock and key-probe payloads, the unlock's aim on five desktops under floor mapping (nearest, guaranteed only up to 32,768 pixels an axis, checked there; Sol's 38,400-pixel case) and the marker's 31-bit width (UNLOCK-HOOK-01; the zero-delta move, a plain floor and the 64-bit marker among the controls); the cursor read again between the gate and the unlock (unlock-raced) and after the hook's sight of it (unlock-moved-cursor), and a failed DPI switch unaimed (#746); $framePacingJobCase; $framePacingDesktopCase; $framePacingBenchCase"
