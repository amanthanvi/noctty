# The soak (PLAN.md §3.5): test/windows/interactive-win11-soak.ps1 runs one portable copy on a private
# desktop for hours and records a run directory; ci/soak_judge.py judges it, and ci/test_soak_judge.py,
# which CI's checks job runs on a pinned Python, holds the judge's controls. Pinned here: what the harness
# may do (patterns over its code with the comments removed, each with a mutation that must fail it), its
# native layer (compiled and run against this process: the struct size, the error mode it reads, the
# handle the negative control injects), that the launch helper's class has the shape the judge accepts,
# and the CI step. No noctty is started.
$soakScript = Join-Path $repoRoot 'test\windows\interactive-win11-soak.ps1'
$soakJudge = Join-Path $repoRoot 'ci\soak_judge.py'
$soakLib = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
$soakWorkflow = Join-Path $repoRoot '.github\workflows\test.yml'

function Get-SoakCodeText([string] $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "The soak harness does not parse: $Path" }
    $builder = [Text.StringBuilder]::new($text)
    foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    return $builder.ToString()
}
$soakText = Get-SoakCodeText $soakScript

# Each rule: the pattern the harness's code must match, and a mutation (old text, new text) of the code
# that a correct rule must reject; the mutation must change the text.
$soakRules = @(
    @{
        Description = 'the copy starts with the launch helper''s isolation (its containment, its own class, --single-instance=false), --window-save-state=never and the clipboard denied on the command line'
        Pattern = '(?s)Get-InteractiveWin11SandboxLayout -RepoRoot \$repoRoot -SandboxName \$SandboxName.*?\$launchArguments = @\(Get-InteractiveWin11LaunchArguments -Layout \$layout -UseConfiguredCommand\) \+ @\(\s*"--command=direct:\$cmdPath /D", ''--window-save-state=never'', ''--clipboard-read=deny'', ''--clipboard-write=deny''\).*?\$commandLine = \(''"\{0\}" '' -f \$exe\) \+ \(@\(\$launchArguments \|'
        Mutation = @("'--clipboard-read=deny', '--clipboard-write=deny'", "'--clipboard-read=deny'")
    }
    @{
        Description = 'every pane runs System32''s cmd.exe directly with /D, so no cmd AutoRun runs (a bare --command=cmd.exe goes through Exec''s outer cmd /c)'
        Pattern = '(?s)\$cmdPath = Join-Path \(\[Environment\]::GetFolderPath\(''System''\)\) ''cmd\.exe''.*?"--command=direct:\$cmdPath /D".*?if \(@\(\$launchArguments \| Where-Object \{ \$_ -like ''--command=\*'' \}\)\.Count -ne 1\) \{ throw'
        Mutation = @('"--command=direct:$cmdPath /D"', '"--command=cmd.exe"')
    }
    @{
        Description = 'the copy carries no noctty.ico (so it cannot create a missing AppUserModelId key) and no crash tree of an earlier run'
        Pattern = '(?s)Get-ChildItem -LiteralPath \$Bin -Force \| Where-Object \{ \$_\.Name -notin @\(''noctty\.ico'', ''crash'', ''ghostty''\) \}.*?if \(Test-Path -LiteralPath \(Join-Path \$copy ''noctty\.ico''\)\) \{ throw'
        Mutation = @("Where-Object { `$_.Name -notin @('noctty.ico', 'crash', 'ghostty') }", "Where-Object { `$_.Name -notin @('noctty.ico') }")
    }
    @{
        Description = 'a flood counts only when the acknowledgement file reaches its own number, written only after its output, by an ASCII batch file that takes its paths from its own location (CodeRabbit, rounds 1 and 3)'
        Pattern = '(?s)\$script:soakFloodsAsked\+\+\s*\$want = \$script:soakFloodsAsked.*?Wait-For \{ \(Get-FloodCount\) -ge \$want \} 30000.*?''@type "%~dp0flood\.txt" && echo flood>>"%~dp0flood-count\.txt"'''
        Mutation = @('(Get-FloodCount) -ge $want', '(Get-FloodCount) -gt $count')
    }
    @{
        Description = 'the baseline is the original base pane, never a substitute (CodeRabbit, round 1)'
        Pattern = '(?s)function Test-AtBaseline \{\s*\$panes = @\(Get-AllSurfaces \$false\)\s*return \$panes\.Count -eq 1 -and \$panes\[0\] -eq \$script:soakBase'
        Mutation = @(' -and $panes[0] -eq $script:soakBase', '')
    }
    @{
        Description = 'the clipboard sequence number is recorded before and after each run'
        Pattern = '(?s)\$before = \[ordered\]@\{[^\r\n]*Clipboard = \[HiddenLocal\]::GetClipboardSequenceNumber\(\) \}.*?\$after = \[ordered\]@\{[^\r\n]*Clipboard = \[HiddenLocal\]::GetClipboardSequenceNumber\(\) \}.*?ClipboardSequenceBefore = \$before\.Clipboard; ClipboardSequenceAfter = \$after\.Clipboard'
        Mutation = @('ClipboardSequenceAfter = $after.Clipboard', 'ClipboardSequenceAfter = $before.Clipboard')
    }
    @{
        Description = 'the build mode is checked through +version before the launch, and a mismatch launches nothing'
        Pattern = '(?s)''"\{0\}" \+version''.*?build mode.*?if \(\$harness\.BuildMode -cne \$ExpectedBuildMode\) \{.*?return 3.*?\[SoakNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('return 3', '')
    }
    @{
        Description = 'SEM_NOGPFAULTERRORBOX is set before the copy is created, so the copy inherits it'
        Pattern = '(?s)\[SoakNative\]::SetErrorMode\(\[SoakNative\]::GetErrorMode\(\) -bor 2\).*?\[SoakNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('GetErrorMode() -bor 2', 'GetErrorMode() -bor 0')
    }
    @{
        Description = 'the soak job kills its processes when closed and ends one on an unhandled exception, so a crash cannot wait in WER''s dialog whatever the copy''s error mode becomes'
        Pattern = '(?s)public static IntPtr CreateSoakJob\(\) \{.*?limits\.basic\.flags = 0x2000 \| 0x400;.*?SetInformationJobObject\(job, 9, ref limits'
        Mutation = @('limits.basic.flags = 0x2000 | 0x400;', 'limits.basic.flags = 0x2000;')
    }
    @{
        Description = 'the wer row says suppressed only with the job''s limit in force and SEM_NOGPFAULTERRORBOX at the copy''s launch'
        Pattern = '(?s)\$harness\.JobLimitFlags = \[SoakNative\]::JobLimitFlags\(\[IntPtr\]::Zero\).*?\$jobDies = \(\$harness\.JobLimitFlags -band 0x2400\) -eq 0x2400.*?\$suppressed = \$jobDies -and \$harness\.HardErrorModes\.Count -gt 0 -and \(\$harness\.HardErrorModes\[0\] -band 2\) -ne 0'
        Mutation = @('$suppressed = $jobDies -and ', '$suppressed = ')
    }
    @{
        Description = 'no launch asks for the default error mode (CREATE_DEFAULT_ERROR_MODE would drop the inherited one)'
        Pattern = '(?s)\A(?!.*0x04000000)'
        Mutation = @('0x00080000 | priority', '0x00080000 | 0x04000000 | priority')
    }
    @{
        Description = 'the driver refuses to run off its private desktop, and every process it starts names that desktop'
        Pattern = '(?s)if \(\[SoakNative\]::CurrentDesktopName\(\) -cne \$DesktopName\) \{ throw .*?\$desktopPath = "WinSta0\\\$DesktopName".*?Spawn\(\$exe, \(''"\{0\}" \+version'' -f \$exe\), \$work, \$desktopPath,.*?Spawn\(\$exe, \$commandLine, \$work, \$desktopPath,'
        Mutation = @('$desktopPath = "WinSta0\$DesktopName"', '$desktopPath = "WinSta0\Default"')
    }
    @{
        Description = 'the driver starts on a new private desktop inside the owned job, with LOCALAPPDATA and APPDATA redirected into the run'
        Pattern = '(?s)\$desktopName = ''noctty-soak-'' \+ \[guid\]::NewGuid\(\).*?\$job = \[SoakNative\]::CreateSoakJob\(\).*?\$env:LOCALAPPDATA = Join-Path \$Run ''localappdata''; \$env:APPDATA = Join-Path \$Run ''appdata''.*?\[HiddenLocal\]::Launch\(\$pwsh, \$line, \$Run, "WinSta0\\\$desktopName", \$job\)'
        Mutation = @("`$env:LOCALAPPDATA = Join-Path `$Run 'localappdata'; ", '')
    }
    @{
        Description = 'the copy is portable: the noctty.portable marker sits beside its exe'
        Pattern = '\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @("'noctty.portable'", "'portable.marker'")
    }
    @{
        Description = 'the exit code comes only from GetExitCodeProcess on the held handle: no Process object, no PID lookup'
        Pattern = '(?s)\A(?!.*(?:\.ExitCode\b|Get-Process\b|GetProcessById|WaitForExit|\.HasExited))'
        Mutation = @('-ExitCode { [SoakNative]::ExitCode($process) }', '-ExitCode { (Get-Process -Id $nocttyPid).ExitCode }')
    }
    @{
        Description = 'nothing in the harness uses real input, the foreground, the clipboard, Start-Process or a recursive delete'
        Pattern = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|BringWindowToTop|OpenClipboard|SetClipboardData|GetClipboardData|Set-Clipboard|Get-Clipboard|Start-Process|Invoke-Item|Remove-Item\b[^\r\n;|]*\s-Recurse\b))'
        Mutation = @('[SoakNative]::Key($From, $Vk)', '[SoakNative]::Key($From, $Vk); Set-Clipboard -Value x')
    }
    @{
        Description = 'nor a recursive delete with -Recurse after its path'
        Pattern = '(?s)\A(?!.*Remove-Item\b[^\r\n;|]*\s-Recurse\b)'
        Mutation = @("[IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), '')", "Remove-Item -LiteralPath `$copy -Recurse")
    }
    @{
        Description = 'the soak config clears every default binding, binds nothing that copies or pastes, and denies OSC 52 and updates'
        Pattern = '(?s)\$bindings = \[ordered\]@\{(?:(?!copy|paste)[^}])*\}.*?''auto-update = off''.*?''clipboard-read = deny''.*?''clipboard-write = deny''.*?''copy-on-select = false''.*?''keybind = clear''\s*foreach \(\$key in \$bindings\.Keys\) \{ foreach \(\$chord in \$chords\) \{ "keybind = \$chord\$key=\$\(\$bindings\[\$key\]\)" \} \}\s*\) \| Set-Content'
        Mutation = @("f8 = 'clear_screen'", "f8 = 'clear_screen'; f9 = 'copy_to_clipboard'")
    }
    @{
        Description = 'each churn key is bound under every Shift, Ctrl and Alt chord, so a modifier the user holds cannot turn a posted key into an unbound one'
        Pattern = '\$chords = @\('''', ''shift\+'', ''ctrl\+'', ''alt\+'', ''ctrl\+shift\+'', ''alt\+shift\+'', ''ctrl\+alt\+'', ''ctrl\+alt\+shift\+''\)'
        Mutation = @(", 'ctrl+alt+shift+')", ')')
    }
    @{
        Description = 'the kill control ends the process with exit code 3 after the minute''s sample'
        Pattern = '(?s)Add-Line \$timingTsv .*?if \(\$KillAtMinute -eq \$minute -and \[SoakNative\]::Alive\(\$process\)\) \{\s*\[SoakNative\]::Terminate\(\$process, 3\)'
        Mutation = @('[SoakNative]::Terminate($process, 3)', '[SoakNative]::Terminate($process, 0)')
    }
    @{
        Description = 'the negative control duplicates a handle into the soaked process each minute, before its sample'
        Pattern = '(?s)if \(\$InjectHandleEachMinute -and \[SoakNative\]::Alive\(\$process\)\) \{\s*if \(\[SoakNative\]::Inject\(\$process\)\).*?while \(\$clock\.ElapsedMilliseconds -lt \$due\)'
        Mutation = @('[SoakNative]::Inject($process)', '[SoakNative]::Inject([IntPtr]::Zero)')
    }
    @{
        Description = 'no control is written where the judge reads it: a control is judged blind'
        Pattern = '(?s)\A(?!.*Add-Line \$(?:runTsv|samplesTsv|metricsTsv|threadsTsv|timingTsv)[^\r\n]*(?:KillAtMinute|Inject|Hang))'
        Mutation = @('Add-Line $runTsv "planned`t$Minutes"', 'Add-Line $runTsv "planned`t$Minutes`t$HangAtMinute"')
    }
    @{
        Description = 'a resize asks the copy''s own thread (SWP_ASYNCWINDOWPOS) and waits a bounded time, so a hung copy cannot hold the driver past a sample (round 1''s Opus H1)'
        Pattern = '(?s)public static bool Resize\(IntPtr h, int width, int height, int ms\) \{\s*if \(!SetWindowPos\(h, IntPtr\.Zero, 0, 0, width, height, 0x0002 \| 0x0004 \| 0x0010 \| 0x4000\)\).*?while \(clock\.ElapsedMilliseconds < ms\);.*?\[SoakNative\]::Resize\(\$hostWindow, \$size\[0\], \$size\[1\], \$script:ResponseBoundMs\)'
        Mutation = @('0x0002 | 0x0004 | 0x0010 | 0x4000', '0x0002 | 0x0004 | 0x0010')
    }
    @{
        Description = 'the churn asks the copy to answer before the minute and before each step, so a hung copy costs it seconds, not the minute'
        Pattern = '(?s)function Test-Answers\(\[IntPtr\] \$Window\) \{\s*return \$Window -ne \[IntPtr\]::Zero -and \[SoakNative\]::Responsive\(\$Window, \$script:ResponseBoundMs\).*?if \(-not \(Test-Answers \$hostWindow\)\) \{ Log "minute \$\{Minute\}: the copy does not answer; no churn"; \$r\.Missed\+\+; return \$r \}.*?if \(-not \(Test-Answers \$hostWindow\)\) \{ & \$skip \$Step ''the copy does not answer''; return \$false \}'
        Mutation = @("if (-not (Test-Answers `$hostWindow)) { & `$skip `$Step 'the copy does not answer'; return `$false }", '')
    }
    @{
        Description = 'a step that cannot run (past its deadline, after a missed step, the copy not answering) counts as missed (round 1''s Opus L6)'
        Pattern = '(?s)\$skip = \{\s*param\(\[string\] \$Step, \[string\] \$Why\)\s*\$r\.Missed\+\+\s*Log "minute \$Minute \$Step step skipped: \$Why".*?if \(\$From -eq \[IntPtr\]::Zero\) \{ & \$skip \$Step ''the step before it missed''; return \$false \}\s*if \(\$clock\.ElapsedMilliseconds -ge \$OpenUntilMs\) \{ & \$skip \$Step ''past its deadline''; return \$false \}'
        Mutation = @("param([string] `$Step, [string] `$Why)`n                `$r.Missed++", "param([string] `$Step, [string] `$Why)")
    }
    @{
        Description = 'the hang control suspends only the soaked copy''s UI thread, resumes it from a timer, and runs after the first resize or 10 s before the sample'
        Pattern = '(?s)public static uint SuspendFor\(IntPtr h, int pid, int ms\) \{.*?if \(tid == 0 \|\| owner != pid\) throw.*?if \(GetProcessIdOfThread\(t\) != \(uint\)pid\).*?resumer = new System\.Threading\.Timer\(_ => \{ ResumeThread\(t\); CloseHandle\(t\); \}.*?if \(\$i -eq 0 -and \$HangAtMinute -eq \$Minute -and \$HangAt -eq ''resize''\) \{ Start-Hang \$hostWindow \}.*?if \(\$HangAtMinute -eq \$minute -and \$HangAt -eq ''sample'' -and \[SoakNative\]::Alive\(\$process\)\) \{\s*while \(\$clock\.ElapsedMilliseconds -lt \$due - 10000\)'
        Mutation = @('if (GetProcessIdOfThread(t) != (uint)pid)', 'if (false)')
    }
    @{
        Description = 'a resize hang on an idle minute (the first or a tenth, which run no churn) is refused before the launch (Greptile, round 2)'
        Pattern = '(?s)if \(\$minute -ge 2 -and \$minute % 10 -ne 0 -and .*?if \(\$HangAt -eq ''resize'' -and \$HangAtMinute -gt 0 -and \(\$HangAtMinute -eq 1 -or \$HangAtMinute % 10 -eq 0\)\) \{\s*throw'
        Mutation = @('$HangAtMinute -eq 1 -or $HangAtMinute % 10 -eq 0', '$HangAtMinute % 10 -eq 0')
    }
    @{
        Description = 'a hang must be seen by its minute''s own sample: a -HangSeconds too short to reach it is refused before the launch, and a sample that did not see the copy fail to answer is a control miss (CodeRabbit and Sol, round 2)'
        Pattern = '(?s)if \(\$HangAtMinute -eq \$minute -and \$null -ne \$harness\.HungAtMs -and \$answeredNow -ne \$false\) \{\s*\$harness\.ControlMisses\.Add\(.*?\$hangLead = if \(\$HangAt -eq ''sample''\) \{ 10 \} else \{ 90 \}\s*\$hangNeeds = \$hangLead \+ \[int\]\(\$script:ResponseBoundMs / 1000\) \+ 5\s*if \(\$HangAtMinute -gt 0 -and \$HangSeconds -lt \$hangNeeds\) \{\s*throw'
        Mutation = @('$HangSeconds -lt $hangNeeds', '$HangSeconds -lt 1')
    }
    @{
        Description = 'the hang''s sample check reads that sample''s own answer'
        Pattern = '(?s)foreach \(\$h in \$mine\) \{ if \(-not \[SoakNative\]::Responsive\(\$h\.Hwnd, \$script:ResponseBoundMs\)\) \{ \$answered = \$false \} \}\s*\$probeEnd = \$clock\.ElapsedMilliseconds\s*\$answeredNow = \$answered\s.*?-and \$answeredNow -ne \$false\) \{'
        Mutation = @('$answeredNow = $answered', '$answeredNow = $true')
    }
    @{
        Description = 'each minute''s probe is timed where it runs: its start before the liveness check, its end after the last WM_NULL answer, both written to timing.tsv (Sol, round 2: a timestamp taken before the probe hid a 15 s delay)'
        Pattern = '(?s)while \(\$clock\.ElapsedMilliseconds -lt \$due\) \{[^\r\n]*\}\s*\$harness\.Churn \+= \$load\.Churn; \$harness\.Missed \+= \$load\.Missed\s*\$probeStart = \$clock\.ElapsedMilliseconds\s*\$answeredNow = \$null\s*if \(-not \[SoakNative\]::Alive\(\$process\)\) \{\s*\$probeEnd = \$clock\.ElapsedMilliseconds.*?\$answer = if \(\[SoakNative\]::Responsive\(\$other\.Hwnd, \$script:ResponseBoundMs\)\) \{ ''yes'' \} else \{ ''no'' \}\s*\$probeEnd = \$clock\.ElapsedMilliseconds.*?\$answered = \$false \} \}\s*\$probeEnd = \$clock\.ElapsedMilliseconds.*?Add-Line \$timingTsv "\$minute`t\$probeStart`t\$probeEnd`t\$workMs"'
        Mutation = @("`$probeStart = `$clock.ElapsedMilliseconds", "`$probeStart = `$due")
    }
    @{
        Description = 'a control asked for that did not take effect (no hang, no kill with exit code 3, no injection) fails the harness, since the judge never sees a control (Greptile, round 2)'
        Pattern = '(?s)if \(\$HangAtMinute -gt 0 -and \$null -eq \$harness\.HungAtMs\) \{ \$harness\.ControlMisses\.Add\(.*?if \(\$KillAtMinute -gt 0 -and \$null -eq \$harness\.Killed\) \{ \$harness\.ControlMisses\.Add\(.*?if \(\$InjectHandleEachMinute -and \$harness\.Injected -eq 0\) \{ \$harness\.ControlMisses\.Add\(.*?if \(\$harness\.ControlMisses\.Count -gt 0\) \{\s*Log [^\r\n]*\s*return 4\s*\}.*?elseif \(\$driverExit -eq 4\) \{ \$failed \+= '
        Mutation = @('$null -eq $harness.HungAtMs', '$false')
    }
    @{
        Description = 'the driver ends through Invoke-SoakQuit, and a WM_CLOSE goes only to a window the soaked process still owns, so a post that took means the copy was there to be asked (council round 3, Sol)'
        Pattern = '(?s)public static bool PostClose\(IntPtr h, int pid\) \{\s*int owner; GetWindowThreadProcessId\(h, out owner\);\s*return owner == pid && PostMessageW\(h, 0x10, IntPtr\.Zero, IntPtr\.Zero\);.*?\$quit = Invoke-SoakQuit -Alive \{ \[SoakNative\]::Alive\(\$process\) \}.*?-Post \{ param\(\$Window\) \[SoakNative\]::PostClose\(\$Window, \$nocttyPid\) \}.*?\$end = \$quit\.End'
        Mutation = @('return owner == pid && PostMessageW', 'return PostMessageW')
    }
    @{
        Description = 'the mirrored structs are checked against the SDK''s x64 sizes and offsets before anything runs (AGENTS.md "Win32 FFI", round 1''s Opus L4)'
        Pattern = '(?s)if \(\[SoakNative\]::Layout\(\) -cne \$script:SdkLayout\) \{ throw'
        Mutation = @('if ([SoakNative]::Layout() -cne $script:SdkLayout) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a driver that overran its bound or a launch that failed still leaves the crash collection and the guards to run (round 1''s Opus L2)'
        Pattern = '(?s)\} catch \{\s*\$outerError = \$_\.Exception\.Message\s*\} finally \{.*?Copy-CrashEvidence .*?Assert-WindowsHarnessHistoryGuard .*?if \(\$outerError\) \{ \$failed \+= \$outerError \}'
        Mutation = @('if ($outerError) { $failed += $outerError }', '')
    }
    @{
        Description = 'a LocalDumps dump counts only when written after the launch, since its name carries only the PID (round 1''s Opus L5)'
        Pattern = '\(Test-Path -LiteralPath \$dump\) -and \(Get-Item -LiteralPath \$dump\)\.LastWriteTimeUtc -ge \$launchUtc\)'
        Mutation = @(' -and (Get-Item -LiteralPath $dump).LastWriteTimeUtc -ge $launchUtc', '')
    }
    @{
        Description = 'the real startup ledger, jump list and PowerShell history are checked after the run, and a change fails it'
        Pattern = '(?s)StartupUnchanged = \$before\.Startup -ceq \$after\.Startup.*?JumpListUnchanged = .*?HistoryUnchanged = .*?if \(-not \$guards\.StartupUnchanged\).*?if \(-not \$guards\.JumpListUnchanged\).*?if \(\$historyFailure\).*?throw \(''soak harness: '''
        Mutation = @('if (-not $guards.StartupUnchanged) {', 'if ($false -and -not $guards.StartupUnchanged) {')
    }
    @{
        Description = 'a WER scan that cannot rule a report out leaves a file in crash\, which the judge counts'
        Pattern = '(?s)if \(\$problems\.Count -gt 0\) \{.*?WriteAllLines\(\(Join-Path \$Destination ''wer-scan-incomplete\.txt''\)'
        Mutation = @("'wer-scan-incomplete.txt'", "'..\wer-scan-incomplete.txt'")
    }
)
$soakMutations = 0
foreach ($rule in $soakRules) {
    Assert-TextContract -Content $soakText -Pattern $rule.Pattern -Description $rule.Description -Context $soakScript
    $mutated = $soakText.Replace($rule.Mutation[0], $rule.Mutation[1])
    if ([string]::Equals($mutated, $soakText, [StringComparison]::Ordinal)) { throw "Soak contract mutation changed nothing: $($rule.Description)" }
    if ($mutated -match $rule.Pattern) { throw "Soak contract accepted a mutation: $($rule.Description)" }
    $soakMutations++
}

# Each run.tsv row kind is written exactly once (the judge fails a duplicate), and the samples come from
# the held handle's PID and creation time.
foreach ($kind in @('launch', 'mode', 'class', 'exe', 'planned', 'wer', 'end')) {
    $writes = [regex]::Matches($soakText, 'Add-Line \$runTsv \(?"' + $kind + '`t').Count
    if ($writes -ne 1) { throw "The soak harness writes the run.tsv $kind row $writes times; the judge needs it once." }
}
if ($soakText -notmatch '(?s)\$start = \[SoakNative\]::CreationTime\(\$process\).*?Add-Line \$runTsv "launch`t\$nocttyPid`t\$start".*?Add-Line \$samplesTsv \("\$minute`t\$nocttyPid`t\$start`t"') {
    throw 'The soak harness must take the launch row and each sample from the held handle.'
}

# The shortest run the judge accepts is the repository thresholds' warm-up plus window; the minimum the harness
# prints after a run, its usage and the judge's usage all give that number (CodeRabbit, round 3: the printed hint
# still said 90 after the window moved to 60). The control: a stale hint fails the same check.
$soakThresholdRows = @(Get-Content -LiteralPath (Join-Path $repoRoot 'ci\soak-thresholds.tsv') | Where-Object { $_ -match '^(warmup|window)\t\d+\s*$' })
if ($soakThresholdRows.Count -ne 2) { throw 'ci/soak-thresholds.tsv needs one warmup and one window row.' }
$soakMinimum = ($soakThresholdRows | ForEach-Object { [int](($_ -split "`t")[1]) } | Measure-Object -Sum).Sum
function Test-SoakMinimumNamed([string] $Harness, [string] $Judge, [int] $Minimum) {
    return $Harness.Contains("($Minimum at least; 480 at release coverage)") -and
        $Harness.Contains("--min-minutes $Minimum for Phase 0a's runs") -and $Judge.Contains("use it with --min-minutes $Minimum.")
}
$soakRawText = Get-Content -LiteralPath $soakScript -Raw
$soakJudgeRaw = Get-Content -LiteralPath $soakJudge -Raw
if (-not (Test-SoakMinimumNamed $soakRawText $soakJudgeRaw $soakMinimum)) {
    throw "The soak harness's printed minimum, its usage and the judge's usage must each give $soakMinimum (warm-up plus window)."
}
if (Test-SoakMinimumNamed ($soakRawText.Replace("($soakMinimum at least;", '(90 at least;')) $soakJudgeRaw $soakMinimum) {
    throw 'The soak minimum check accepted a stale printed hint.'
}

# The hang minimum before the launch covers the measured worst case (council round 3, Opus L2): on ReleaseFast a
# resize hang's probe came 70.5 s after the hang began (r5-hang-resize), up to 5 s more on a minute that floods the
# base pane, and the probe's own WM_NULL waits 5 s; a sample hang starts 10 s before the probe. The lines are taken
# from the harness and evaluated; the control, the old 60 s lead, fails the same check.
$hangLines = [regex]::Match($soakText, '(?m)^\s*\$hangLead = .*\r?\n\s*\$hangNeeds = .*$').Value
if (-not $hangLines) { throw 'The soak harness has no $hangLead and $hangNeeds lines.' }
function Get-SoakHangNeeds([string] $Lines, [string] $Mode) {
    $script:ResponseBoundMs = 5000
    $HangAt = $Mode
    . ([scriptblock]::Create($Lines))
    return $hangNeeds
}
function Test-SoakHangMinimum([string] $Lines) {
    return (Get-SoakHangNeeds $Lines 'resize') -ge [Math]::Ceiling(70.5 + 5 + 5) -and (Get-SoakHangNeeds $Lines 'sample') -ge 10 + 5 + 5
}
if (-not (Test-SoakHangMinimum $hangLines)) { throw "The resize hang's minimum is below the measured 70.5 s to its probe, plus the base pane's flood and the probe's bound." }
if (Test-SoakHangMinimum ($hangLines.Replace('{ 90 }', '{ 60 }'))) { throw 'The hang minimum check accepted the old 60 s resize lead.' }

# The quit's end row (council round 3, Sol: a copy that left on its own between the last liveness check and the
# posts read as a clean quit). The harness's Invoke-SoakQuit, taken from its AST, runs with test doubles: `quit`
# only when a post took and the exit followed; no window, or a post that failed, then an exit is `unasked`.
$soakAst = [Management.Automation.Language.Parser]::ParseFile($soakScript, [ref]$null, [ref]$null)
$quitAst = @($soakAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SoakQuit' }, $false))
if ($quitAst.Count -ne 1) { throw 'The soak harness must define Invoke-SoakQuit once.' }
# End rows hold a tab, and pwsh 7.6's -ceq ignores control characters (PWSH-CEQ-ICU), so rows compare ordinally.
function Test-SoakQuitRow([string] $Got, [string] $Want) { return [string]::Equals($Got, $Want, [StringComparison]::Ordinal) }
if (Test-SoakQuitRow "quit`t0" 'quit0') { throw 'The quit row check ignores the tab in an end row.' }
$quitCases = @(
    @{ Name = 'no window to post to, then the handle signals with 0'; Alive = $true; Windows = @(); Posts = @(); Waits = $true; Want = "unasked`t0" }
    @{ Name = 'the window vanished, the post failed, then the handle signals with 0'; Alive = $true; Windows = @(7); Posts = @($false); Waits = $true; Want = "unasked`t0" }
    @{ Name = 'a post took, then the copy ended with 0'; Alive = $true; Windows = @(7); Posts = @($true); Waits = $true; Want = "quit`t0" }
    @{ Name = 'one of two posts took'; Alive = $true; Windows = @(7, 8); Posts = @($false, $true); Waits = $true; Want = "quit`t0" }
    @{ Name = 'the copy had ended before the quit'; Alive = $false; Windows = @(7); Posts = @($true); Waits = $true; Want = "early`t0" }
    @{ Name = 'a post took and the bound ran out'; Alive = $true; Windows = @(7); Posts = @($true); Waits = $false; Want = "stuck`t-" }
)
& {
    . ([scriptblock]::Create($quitAst[0].Extent.Text))
    foreach ($case in $quitCases) {
        $script:quitPostIndex = 0; $script:quitStopped = $false
        $result = Invoke-SoakQuit -Alive { $case.Alive } -Windows { $case.Windows } `
            -Post { param($Window) $taken = $case.Posts[$script:quitPostIndex]; $script:quitPostIndex++; $taken } `
            -Wait { $case.Waits } -ExitCode { 0 } -Stop { $script:quitStopped = $true }
        if (-not (Test-SoakQuitRow $result.End $case.Want)) { throw "Invoke-SoakQuit gave '$($result.End -replace "`t", ' ')' for $($case.Name); want '$($case.Want -replace "`t", ' ')'." }
        if (($case.Want -like 'stuck*') -ne $script:quitStopped) { throw "Invoke-SoakQuit's stop ran wrongly for $($case.Name)." }
    }
}
$quitControl = $quitAst[0].Extent.Text.Replace("if (`$quitPosts -gt 0) { 'quit' } else { 'unasked' }", "'quit'")
if ([string]::Equals($quitControl, $quitAst[0].Extent.Text, [StringComparison]::Ordinal)) { throw 'The quit control changed nothing.' }
$controlCaught = & {
    . ([scriptblock]::Create($quitControl))
    -not (Test-SoakQuitRow (Invoke-SoakQuit -Alive { $true } -Windows { @() } -Post { $false } -Wait { $true } -ExitCode { 0 } -Stop { }).End "unasked`t0")
}
if (-not $controlCaught) { throw 'The quit test doubles did not catch a quit recorded with no post.' }

# The class the launch helper composes for a soak sandbox has the shape the judge accepts, and two sandbox
# names give two classes. The helper's functions are taken from the library and run in a child scope.
$judgeText = Get-Content -LiteralPath $soakJudge -Raw
$classPattern = [regex]::Match($judgeText, '(?m)^CLASS_RE = r"(?<re>[^"]+)"').Groups['re'].Value
if (-not $classPattern) { throw 'ci/soak_judge.py has no CLASS_RE.' }
$libAst = [Management.Automation.Language.Parser]::ParseFile($soakLib, [ref]$null, [ref]$null)
$helperNames = @('Get-InteractiveWin11NormalizedPath', 'Get-InteractiveWin11WorktreeId', 'Get-InteractiveWin11SandboxName',
    'Get-InteractiveWin11SandboxLayout', 'Get-InteractiveWin11ContainmentArguments', 'Get-InteractiveWin11LaunchArguments')
$helperText = ($helperNames | ForEach-Object {
        $name = $_
        $found = @($libAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false))
        if ($found.Count -ne 1) { throw "scripts/interactive-win11-lib.ps1 must define $name once." }
        $found[0].Extent.Text
    }) -join "`n"
$classes = & {
    . ([scriptblock]::Create($helperText))
    foreach ($sandbox in @('soak-fast', 'soak-safe')) {
        $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName $sandbox
        @(Get-InteractiveWin11LaunchArguments -Layout $layout | Where-Object { $_ -like '--class=*' } | ForEach-Object { $_.Substring(8) })
    }
}
if (@($classes).Count -ne 2 -or $classes[0] -ceq $classes[1]) { throw 'Two soak sandboxes must give two classes.' }
foreach ($class in $classes) {
    if ($class -cnotmatch ('\A(?:' + $classPattern + ')\z')) { throw "The launch helper's class '$class' fails the judge's CLASS_RE." }
}
if ('noctty-interactive-soak' -cmatch ('\A(?:' + $classPattern + ')\z')) { throw 'The judge''s CLASS_RE accepts a class with no worktree hash.' }

# The harness's native layer, compiled under another name and run against this process only.
$nativeSource = [regex]::Match((Get-Content -LiteralPath $soakScript -Raw), "(?s)Add-Type @'\r?\n(?<cs>.*?public static class SoakNative.*?)\r?\n'@").Groups['cs'].Value
if (-not $nativeSource) { throw 'The soak harness''s native layer was not found.' }
$nativeName = 'SoakNativeContract' + [guid]::NewGuid().ToString('N')
Add-Type -TypeDefinition ($nativeSource.Replace('public static class SoakNative', "public static class $nativeName"))
$native = $nativeName -as [type]
$self = [IntPtr]::new(-1)   # GetCurrentProcess's pseudo handle
if ($native::MemoryCountersSize -ne 96) { throw "PROCESS_MEMORY_COUNTERS_EX2 mirrors as $($native::MemoryCountersSize) bytes, not 96 (psapi.h, x64)." }
if ($native::JobLimitsSize -ne 144) { throw "JOBOBJECT_EXTENDED_LIMIT_INFORMATION mirrors as $($native::JobLimitsSize) bytes, not 144 (winnt.h, x64)." }
$soakJob = $native::CreateSoakJob()   # no process is ever assigned to it
try {
    if ($native::JobLimitFlags($soakJob) -ne 0x2400) { throw 'The soak job does not carry KILL_ON_JOB_CLOSE and DIE_ON_UNHANDLED_EXCEPTION, read back.' }
} finally { [void]$native::CloseHandle($soakJob) }
$memory = $native::Memory($self)
if ($memory.Count -ne 3 -or $memory[0] -le 0 -or $memory[1] -le 0 -or $memory[2] -lt $memory[0]) { throw 'The soak memory sample is not private bytes, working set and commit charge.' }
$created = [DateTime]::FromFileTimeUtc($native::CreationTime($self))
if ([Math]::Abs(($created - [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime()).TotalSeconds) -gt 1) { throw 'The soak creation time does not match this process''s start.' }
$savedMode = $native::GetErrorMode()
try {
    [void]$native::SetErrorMode($savedMode -bor 2)
    if (($native::HardErrorMode($self) -band 2) -eq 0) { throw 'The process error mode the soak reads does not show SEM_NOGPFAULTERRORBOX after SetErrorMode.' }
    [void]$native::SetErrorMode($savedMode -band (-bnot 2))
    if (($native::HardErrorMode($self) -band 2) -ne 0) { throw 'The process error mode the soak reads shows SEM_NOGPFAULTERRORBOX after it was cleared.' }
} finally { [void]$native::SetErrorMode($savedMode) }
$injected = $false
# The first call creates the event it duplicates, in this process: that one is not measured, so the handle the
# count must gain is the duplicate's alone.
if (-not $native::Inject($self)) { throw 'The negative control''s DuplicateHandle failed.' }
for ($attempt = 0; $attempt -lt 3 -and -not $injected; $attempt++) {
    $handlesBefore = $native::HandleCount($self)
    if (-not $native::Inject($self)) { throw 'The negative control''s DuplicateHandle failed.' }
    $injected = $native::HandleCount($self) -eq $handlesBefore + 1
}
if (-not $injected) { throw 'The negative control''s injection did not add one handle to its target.' }
$threadRows = @($native::Threads($self, $PID))
if ($threadRows.Count -lt 1 -or @($threadRows | Where-Object { $_ -cnotmatch '\A\d+\t(?:[^\t]+\+0x[0-9a-f]+|0x[0-9a-f]+|\?)\t[^\t]*\z' }).Count -ne 0) {
    throw 'The soak thread rows are not tid, start address and name.'
}
# Every call of the native layer from the script passes as many arguments as the C# method takes: PowerShell
# finds a wrong count only when the call runs (round 2's first short runs failed that way at the first resize).
$nativeArity = @{}
foreach ($m in [regex]::Matches($nativeSource, 'public static (?:extern )?[\w\[\]<>.]+ (?<name>\w+)\((?<params>[^)]*)\)')) {
    $nativeArity[$m.Groups['name'].Value] = if ($m.Groups['params'].Value.Trim()) { @($m.Groups['params'].Value -split ',').Count } else { 0 }
}
function Get-SoakNativeCallProblems([string] $Text) {
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($call in [regex]::Matches($Text, '\[SoakNative\]::(?<name>\w+)\(')) {
        $name = $call.Groups['name'].Value
        $depth = 1; $i = $call.Index + $call.Length; $commas = 0; $any = $false
        while ($i -lt $Text.Length -and $depth -gt 0) {
            $ch = $Text[$i]
            if ($ch -eq '(' -or $ch -eq '[' -or $ch -eq '{') { $depth++ } elseif ($ch -eq ')' -or $ch -eq ']' -or $ch -eq '}') { $depth-- }
            elseif ($ch -eq ',' -and $depth -eq 1) { $commas++ }
            if ($depth -gt 0 -and -not [char]::IsWhiteSpace($ch)) { $any = $true }
            $i++
        }
        $count = if ($any) { $commas + 1 } else { 0 }
        if (-not $nativeArity.ContainsKey($name)) { $problems.Add("$name is not a public method") }
        elseif ($nativeArity[$name] -ne $count) { $problems.Add("$name takes $($nativeArity[$name]) arguments, called with $count") }
    }
    return , $problems
}
$scriptOnly = $soakText.Replace($nativeSource, '')
$callProblems = Get-SoakNativeCallProblems $scriptOnly
if ($callProblems.Count -ne 0) { throw "The soak harness calls its native layer wrongly: $($callProblems -join '; ')" }
$badCall = $scriptOnly.Replace('$baseWidth, $baseHeight, $script:ResponseBoundMs)', '$baseWidth, $baseHeight)')
if ([string]::Equals($badCall, $scriptOnly, [StringComparison]::Ordinal) -or (Get-SoakNativeCallProblems $badCall).Count -ne 1) { throw 'The native-call check accepted a resize called without its bound.' }
# The SDK's x64 layout (psapi.h, winnt.h, tlhelp32.h, processthreadsapi.h, winbase.h), written out here a
# second time so the harness's own copy cannot drift with its structs.
$sdkLayout = 'MemoryCounters=96 workingSet@16 privateUsage@72 sharedCommit@88 JobLimits=144 limitFlags@16 ' +
    'ThreadEntry=28 threadId@8 ownerProcessId@12 ProcessEntry=568 processId@8 parentProcessId@32 ModuleInfo=24 ' +
    'sizeOfImage@8 Startup=104 desktop@16 flags@60 output@88 error@96 StartupEx=112 attributes@104'
if ($native::Layout() -cne $sdkLayout) { throw "The soak's mirrored structs are not the SDK's x64 layout: $($native::Layout())" }
if ($soakText -notmatch [regex]::Escape("'" + $sdkLayout.Substring(0, 70))) { throw 'The harness''s SdkLayout is not the contract''s.' }

# Round 1's Opus H1, as a probe: a window whose thread stops pumping. The harness's resize must come back
# within its bound; a copy of it without SWP_ASYNCWINDOWPOS must wait for the thread (the hazard).
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class SoakStalledWindow {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    static ManualResetEvent release;
    // A hidden, never-shown popup on a (MTA, so non-pumping) thread that stops pumping from its creation: it
    // waits for Go(), then holds `holdMs` more and ends. The caller starts its clock before Go(), so a blocking
    // resize measures the whole hold however the caller is scheduled (CodeRabbit, round 2).
    public static IntPtr Start(int holdMs) {
        IntPtr window = IntPtr.Zero; var made = new ManualResetEvent(false); var go = new ManualResetEvent(false);
        release = go;
        var t = new Thread(() => {
            window = CreateWindowExW(0x08000080, "STATIC", "", 0x80000000, 0, 0, 100, 100, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            made.Set();
            go.WaitOne();
            Thread.Sleep(holdMs);
            DestroyWindow(window);
        });
        t.IsBackground = true; t.Start(); made.WaitOne();
        return window;
    }
    public static void Go() { release.Set(); }
}
'@
$blockingName = 'SoakNativeBlocking' + [guid]::NewGuid().ToString('N')
Add-Type -TypeDefinition ($nativeSource.Replace('public static class SoakNative', "public static class $blockingName").Replace(
        '0x0002 | 0x0004 | 0x0010 | 0x4000', '0x0002 | 0x0004 | 0x0010'))
foreach ($case in @(@{ Type = $native; Async = $true }, @{ Type = ($blockingName -as [type]); Async = $false })) {
    $stalled = [SoakStalledWindow]::Start(3000)
    if ($stalled -eq [IntPtr]::Zero) { throw 'The stalled-window probe made no window.' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    [SoakStalledWindow]::Go()
    [void]$case.Type::Resize($stalled, 321, 123, 500)
    $elapsed = $timer.ElapsedMilliseconds
    if ($case.Async -and $elapsed -gt 2000) { throw "The soak's resize waited $elapsed ms for a thread that stopped pumping." }
    if (-not $case.Async -and $elapsed -lt 2500) { throw "The blocking-resize control returned in $elapsed ms; the probe does not stall." }
    Start-Sleep -Milliseconds 3200   # the probe thread ends and destroys its window
}

# CI runs the judge's controls on a pinned interpreter, unconditionally (PLAN.md §6.5: setup-python at a
# commit SHA, Python 3.13, each tool with -I). The interpreter is the checks job's one Python setup, the step the
# migration lints share (Contracts.90 pins its text); a second setup-python in the job would give the tools two
# interpreters (PR #727, rebased over #721).
$soakChecks = Get-YamlJobText -Content (Get-Content -LiteralPath $soakWorkflow -Raw) -Name 'checks' -Source $soakWorkflow
$setupStep = Get-YamlStepBlock -Content $soakChecks -Name 'Setup Python' -Source $soakWorkflow
$testStep = Get-YamlStepBlock -Content $soakChecks -Name 'Soak judge tests' -Source $soakWorkflow
if ($setupStep -notmatch '(?m)^        uses: actions/setup-python@[0-9a-f]{40} # v\S+\s*$' -or
    $setupStep -notmatch '(?m)^          python-version: [''"]3\.13[''"]\s*$') {
    throw 'The soak judge''s interpreter must be actions/setup-python pinned to a commit SHA with Python 3.13.'
}
if ([regex]::Matches($soakChecks, '(?m)^\s+uses: actions/setup-python@').Count -ne 1) {
    throw 'The checks job must set up Python once, so the soak judge and the lints share one pinned interpreter.'
}
if ($testStep -notmatch '(?m)^        run: python -I ci/test_soak_judge\.py\s*$') { throw 'CI must run the soak judge''s tests with python -I.' }
foreach ($step in @($setupStep, $testStep)) {
    if ($step -match '(?m)^        [''"]?(?:if|continue-on-error)[''"]?[ \t]*:') { throw 'The soak judge steps must be unconditional and fail closed.' }
}
if ($soakChecks.IndexOf('- name: Setup Python' + "`n", [StringComparison]::Ordinal) -lt 0 -and $soakChecks.IndexOf('- name: Setup Python' + "`r`n", [StringComparison]::Ordinal) -lt 0) {
    throw 'The checks job has no step named exactly Setup Python.'
}
if ($soakChecks.IndexOf($setupStep, [StringComparison]::Ordinal) -gt $soakChecks.IndexOf($testStep, [StringComparison]::Ordinal)) {
    throw 'The soak judge''s interpreter must be set up before its tests run.'
}
Write-Host "Soak contracts: $($soakRules.Count) rules, $soakMutations/$soakMutations mutations rejected"
