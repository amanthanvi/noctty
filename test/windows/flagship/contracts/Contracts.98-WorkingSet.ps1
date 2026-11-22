# The working-set workloads (PLAN.md §3.5): test/windows/hidden-win11-working-set.ps1 runs one portable copy of the
# receipt-bound measurement build on a private desktop through one fixed workload and samples its memory. Pinned here:
# what the harness may do and that its run-time checks are called (patterns over its code with the comments removed,
# each with a mutation that must fail it, the council's round-1 mutations among them), the workload itself (its
# constants), its pure functions run on synthetic inputs with controls (the settle rule, the block counts, the
# required stages, the record verdict and the workload hash), its build admission (a repository with only a plain
# zig-out build is refused), the shared state guard's paths, and its native layer's struct layout (compiled and
# checked against the SDK's x64 sizes). No noctty is started.
$workingSetScript = Join-Path $repoRoot 'test\windows\hidden-win11-working-set.ps1'
# Ordinal string equality for every comparison of config, argv, path, receipt and hash text here (Sol and Opus,
# round 5): -ceq and -cne are culture-aware and skip a soft hyphen.
function Test-WorkingSetOrdinal([string] $A, [string] $B) { return [string]::Equals($A, $B, [StringComparison]::Ordinal) }
$workingSetStateGuard = Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1'

function Get-WorkingSetCodeText([string] $Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "The working-set harness does not parse: $Path" }
    $builder = [Text.StringBuilder]::new($text)
    foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        [void]$builder.Remove($token.Extent.StartOffset, $token.Extent.EndOffset - $token.Extent.StartOffset)
    }
    return $builder.ToString()
}
$workingSetText = Get-WorkingSetCodeText $workingSetScript
$workingSetGuardText = Get-WorkingSetCodeText $workingSetStateGuard

$workingSetRules = @(
    # --- build admission and what the driver may launch
    @{
        Description = 'the outer half admits only the receipt-bound measurement build, before it creates anything, and checks the copied app and CLI bytes against the receipt'
        Pattern = '(?s)function Invoke-WorkingSetOuter \{\s+if \(-not \$Workload\) \{ throw ''Pass -Workload\.'' \}\s+Assert-WorkingSetWorkloadName \$Workload\s+\$build = Get-WorkingSetMeasureBuild \$MeasureRepo.*?if \(-not \(Test-WorkingSetCopy \$copy \$build\)\) \{ throw .*?\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @('if (-not (Test-WorkingSetCopy $copy $build)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'admission is Assert-InteractiveWin11MeasureBuild on the generation, then the prefix''s noctty.exe and noctty.com against the receipt''s hashes'
        Pattern = '(?s)function Get-WorkingSetMeasureBuild\(\[string\] \$Repo\) \{.*?\$exe = Get-InteractiveWin11MeasureExePath -RepoRoot \$Repo.*?\$receiptBytes = Read-WorkingSetPlainFile \$layout\.Receipt\s+Assert-InteractiveWin11MeasureBuild -RepoRoot \$Repo -ExePath \$exe.*?if \(-not \[string\]::Equals\(\(Get-Sha256 \$exe\), \[string\]\$receipt\.ExeSHA256, \[StringComparison\]::Ordinal\) -or -not \[string\]::Equals\(\(Get-Sha256 \$cli\), \[string\]\$receipt\.CliSHA256, \[StringComparison\]::Ordinal\)\) \{\s+throw'
        Mutation = @('Assert-InteractiveWin11MeasureBuild -RepoRoot $Repo -ExePath $exe', '')
    }
    @{
        Description = 'the driver is given the staged copy, never the build itself (council round 1, Opus mutation 01)'
        Pattern = '(?s)\$line = ''"\{0\}" -NoProfile -NonInteractive -File "\{1\}" -Driver -MeasureRepo "\{2\}" -Bin "\{3\}" -Run "\{4\}"[^\r\n]*'' -f `\s+\$pwsh, \$PSCommandPath, \$build\.Repo, \$copy, \$Run,'
        Mutation = @('$build.Repo, $copy, $Run,', '$build.Repo, $source, $Run,')
    }
    @{
        Description = 'the driver re-proves its isolation before it starts anything: a private desktop that is neither Default nor the input desktop, a job, and LOCALAPPDATA, APPDATA, TEMP and TMP inside the run'
        Pattern = '(?s)\$own = \[WorkingSetNative\]::CurrentDesktopName\(\)\s+\$inputDesktop = \[WorkingSetNative\]::InputDesktopName\(\).*?if \(\[string\]::Equals\(\$own, ''Default'', \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw .*?if \(\$null -eq \$inputDesktop\) \{ throw .*?if \(\[string\]::Equals\(\$own, \$inputDesktop, \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw .*?if \(-not \[WorkingSetNative\]::InJob\(\)\) \{ throw .*?foreach \(\$name in @\(''LOCALAPPDATA'', ''APPDATA'', ''TEMP'', ''TMP''\)\) \{.*?StartsWith\(\$runPrefix, \[StringComparison\]::OrdinalIgnoreCase\)\) \{\s+throw .*?\$check = \[WorkingSetNative\]::Spawn\(\$exe, \(''"\{0\}" \+version'''
        Mutation = @("if (-not [WorkingSetNative]::InJob()) { throw 'The driver is in no job.' }", '')
    }
    @{
        Description = 'the driver launches only the staged copy: the run''s own copy directory, the portable marker, no noctty.ico, the harness''s config, and the receipt''s bytes'
        Pattern = '(?s)if \(-not \[string\]::Equals\(\[IO\.Path\]::GetFullPath\(\$Bin\)\.TrimEnd\(''\\''\), \(Join-Path \$runPrefix ''copy''\), \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw .*?noctty\.portable.*?noctty\.ico.*?foreach \(\$wanted in @\(''keybind = clear'', ''clipboard-read = deny'', ''clipboard-write = deny'', ''copy-on-select = false'', ''auto-update = off''\)\) \{.*?\$build = Get-WorkingSetMeasureBuild \$MeasureRepo\s+if \(-not \(Test-WorkingSetCopy \$Bin \$build\)\) \{ throw .*?\$check = \[WorkingSetNative\]::Spawn\('
        Mutation = @("(Join-Path `$runPrefix 'copy')", "(Join-Path `$runPrefix 'elsewhere')")
    }
    @{
        Description = 'the build mode is checked through +version (and against the receipt) before the launch, and a mismatch launches nothing'
        Pattern = '(?s)''"\{0\}" \+version''.*?if \(-not \[string\]::Equals\(\[string\]\$record\.BuildMode, \$ExpectedBuildMode, \[StringComparison\]::Ordinal\) -or -not \[string\]::Equals\(\[string\]\$build\.Optimize, \$ExpectedBuildMode, \[StringComparison\]::Ordinal\)\) \{[^\r\n]*return 3 \}.*?\[WorkingSetNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('not launched"; return 3 }', 'not launched" }')
    }
    # --- the copy's isolation
    @{
        Description = 'the shell is the config''s command, System32''s cmd.exe run directly with /D; the command line carries none; the clipboard is denied on the command line'
        Pattern = '(?s)"command = direct:\$cmdPath /D".*?\$launchArguments = @\(Get-InteractiveWin11LaunchArguments -Layout \$layout -UseConfiguredCommand\) \+ @\(\s*"--window-save-state=\$saveState", ''--clipboard-read=deny'', ''--clipboard-write=deny'',.*?if \(@\(\$launchArguments \| Where-Object \{ \$_ -like ''--command=\*'' -or \$_ -eq ''-e'' \}\)\.Count -ne 0\) \{ throw'
        Mutation = @("'--clipboard-read=deny', '--clipboard-write=deny',", "'--clipboard-read=deny',")
    }
    @{
        Description = 'the driver refuses a config whose command is not exactly System32''s cmd.exe with /D'
        Pattern = '(?s)\$cmdPath = Join-Path \(\[Environment\]::GetFolderPath\(''System''\)\) ''cmd\.exe''\s+if \(\$configCommands\.Count -ne 1 -or -not \[string\]::Equals\(\$configCommands\[0\], "command = direct:\$cmdPath /D", \[StringComparison\]::Ordinal\)\) \{ throw'
        Mutation = @('"command = direct:$cmdPath /D", [StringComparison]::Ordinal)) { throw', '"command = direct:$cmdPath", [StringComparison]::Ordinal)) { throw')
    }
    @{
        Description = 'only the session-capture workload saves session state; every other runs with --window-save-state=never'
        Pattern = '\$saveState = if \(\$Workload -eq ''session-capture''\) \{ ''always'' \} else \{ ''never'' \}'
        Mutation = @("{ 'always' } else { 'never' }", "{ 'always' } else { 'default' }")
    }
    @{
        Description = 'the copy carries no noctty.ico (so it cannot create a missing AppUserModelId key) and no crash tree'
        Pattern = '(?s)Get-ChildItem -LiteralPath \$source -Force \| Where-Object \{ \$_\.Name -notin @\(''noctty\.ico'', ''crash'', ''ghostty''\) \}.*?if \(Test-Path -LiteralPath \(Join-Path \$copy ''noctty\.ico''\)\) \{ throw'
        Mutation = @("Where-Object { `$_.Name -notin @('noctty.ico', 'crash', 'ghostty') }", "Where-Object { `$_.Name -notin @('crash', 'ghostty') }")
    }
    @{
        Description = 'the copy is portable: the noctty.portable marker sits beside its exe'
        Pattern = '\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @("'noctty.portable'", "'portable.marker'")
    }
    @{
        Description = 'the driver starts on a new private desktop inside the owned job; LOCALAPPDATA, APPDATA, TEMP and TMP point into the run until LaunchDriver has run, and nothing restores the real ones before it (council round 1, Opus mutation 02)'
        Pattern = '(?s)\$desktopName = ''noctty-ws-'' \+ \[guid\]::NewGuid\(\).*?\$job = \[WorkingSetNative\]::CreateRunJob\(\)\s+\$env:LOCALAPPDATA = Join-Path \$Run ''localappdata''; \$env:APPDATA = Join-Path \$Run ''appdata''\s+\$env:TEMP = Join-Path \$Run ''temp''; \$env:TMP = \$env:TEMP\s+\$pwsh = \(Get-Command pwsh\.exe\)\.Source\s+\$line = ''[^\r\n]+'' -f `\r?\n[^\r\n]+\r?\n\s+\$pi = \[WorkingSetNative\]::LaunchDriver\(\$pwsh, \$line, \$Run, "WinSta0\\\$desktopName", \$job\)\s+foreach \(\$name in \$saved\.Keys\)'
        Mutation = @('$pi = [WorkingSetNative]::LaunchDriver(', "foreach (`$name in `$saved.Keys) { [Environment]::SetEnvironmentVariable(`$name, `$saved[`$name], 'Process') }`n        `$pi = [WorkingSetNative]::LaunchDriver(")
    }
    @{
        Description = 'the outer half refuses a run whose recorded LOCALAPPDATA, APPDATA, TEMP or TMP was not inside the run, or was a real one'
        Pattern = '(?s)foreach \(\$name in @\(''LOCALAPPDATA'', ''APPDATA'', ''TEMP'', ''TMP''\)\) \{\s+\$dir = \[string\]\$record\.EffectiveDirs\.\$name\s+if \(-not \$dir -or -not .*?StartsWith\(\$Run\.TrimEnd\(''\\''\) \+ ''\\'', \[StringComparison\]::OrdinalIgnoreCase\) -or @\(\$realDirs \| Where-Object \{ \[string\]::Equals\(\$_, \$dir\.TrimEnd\(''\\''\), \[StringComparison\]::OrdinalIgnoreCase\) \}\)\.Count -gt 0\) \{\s+\$failed \+= '
        Mutation = @(' -or @($realDirs | Where-Object { [string]::Equals($_, $dir.TrimEnd(''\''), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0', '')
    }
    @{
        Description = 'the driver is created suspended, with no console window and no priority flag (normal priority, never BELOW_NORMAL 0x4000), and assigned to the job before it runs'
        Pattern = '(?s)public static ProcessInfo LaunchDriver\(.*?CreateProcessW\(app, new StringBuilder\(command\), IntPtr\.Zero, IntPtr\.Zero, false, 0x08000004, .*?AssignProcessToJobObject\(job, pi\.process\) \|\| ResumeThread\(pi\.thread\)'
        Mutation = @('false, 0x08000004, IntPtr.Zero', 'false, 0x08004004, IntPtr.Zero')
    }
    @{
        Description = 'the driver itself measures at normal priority'
        Pattern = '\(Get-Process -Id \$PID\)\.PriorityClass = ''Normal'''
        Mutation = @("PriorityClass = 'Normal'", "PriorityClass = 'BelowNormal'")
    }
    @{
        Description = 'the copy runs at normal priority: its creation flags carry NORMAL_PRIORITY_CLASS, and a copy at any other priority fails the run'
        Pattern = '(?s)CreateProcessW\(app, new StringBuilder\(command\), IntPtr\.Zero, IntPtr\.Zero, true, 0x00080000 \| 0x20 \| \(noWindow \? 0x08000000u : 0u\), .*?if \(-not \[string\]::Equals\(\[string\]\$record\.NocttyPriority, ''Normal'', \[StringComparison\]::Ordinal\)\) \{ throw'
        Mutation = @('true, 0x00080000 | 0x20 | (noWindow', 'true, 0x00080000 | 0x4000 | (noWindow')
    }
    @{
        Description = 'no launch asks for BELOW_NORMAL_PRIORITY_CLASS or CREATE_DEFAULT_ERROR_MODE (which would drop the inherited SEM_NOGPFAULTERRORBOX)'
        Pattern = '(?s)\A(?!.*(?:0x04000000|0x00004000|0x4000[^0-9a-fA-F]))'
        Mutation = @('true, 0x00080000 | 0x20 | (noWindow', 'true, 0x00080000 | 0x04000000 | 0x20 | (noWindow')
    }
    @{
        Description = 'the run''s job kills its processes when closed and ends one on an unhandled exception, so a crash cannot wait in WER''s dialog, and SEM_NOGPFAULTERRORBOX is set before the copy is created (SOAK-01 trap 5)'
        Pattern = '(?s)public static IntPtr CreateRunJob\(\) \{.*?limits\.basic\.flags = 0x2000 \| 0x400;.*?\[WorkingSetNative\]::SetErrorMode\(\[WorkingSetNative\]::GetErrorMode\(\) -bor 2\).*?\[WorkingSetNative\]::Spawn\(\$exe, \$commandLine.*?\$job = \[WorkingSetNative\]::CreateRunJob\(\)'
        Mutation = @('limits.basic.flags = 0x2000 | 0x400;', 'limits.basic.flags = 0x2000;')
    }
    @{
        Description = 'only one run at a time in the session, and the mutex is released and disposed however the run ends (copies run together differ by tens of MiB, SOAK-01 trap 6)'
        Pattern = '(?s)\$mutex = \[Threading\.Mutex\]::new\(\$false, ''Local\\noctty-hidden-win11-working-set''\)\s+\$owned = \$false\s+try \{\s+try \{ \$owned = \$mutex\.WaitOne\(0\) \}.*?if \(-not \$owned\) \{ throw .*?\} finally \{\s+if \(\$owned\) \{ \$mutex\.ReleaseMutex\(\) \}\s+\$mutex\.Dispose\(\)'
        Mutation = @('if ($owned) { $mutex.ReleaseMutex() }', '')
    }
    @{
        Description = 'a relative -Run is taken from PowerShell''s location (CodeRabbit on #739)'
        Pattern = '\$Run = \[IO\.Path\]::GetFullPath\(\[IO\.Path\]::Combine\(\(Get-Location -PSProvider FileSystem\)\.ProviderPath, \$Run\)\)'
        Mutation = @('[IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $Run)', '$Run')
    }
    # --- the guards and the verdict
    @{
        Description = 'the real startup ledger, product jump list and clipboard sequence go through the shared state guard, called with its own paths (no seam), and its failure fails the run (council round 1, Opus mutation 06)'
        Pattern = '(?s)\$stateGuard = Start-InteractiveWin11StateGuard -Harness ''hidden-win11-working-set'' -ReceiptDirectory \$Run\r?\n.*?try \{ Assert-InteractiveWin11StateGuard -Guard \$stateGuard \} catch \{ \$stateFailure = \$_\.Exception\.Message \}.*?if \(\$stateFailure\) \{ \$failed \+= \$stateFailure \}'
        Mutation = @("-ReceiptDirectory `$Run`n", "-ReceiptDirectory `$Run -LocalAppDataRoot (Join-Path `$Run 'localappdata')`n")
    }
    @{
        Description = 'the PowerShell history guard runs and its failure fails the run (council round 1, Opus mutation 05)'
        Pattern = '(?s)\$historyGuard = Start-WindowsHarnessHistoryGuard -Harness ''hidden-win11-working-set\.ps1''.*?try \{ Assert-WindowsHarnessHistoryGuard -Guard \$historyGuard \} catch \{ \$historyFailure = \$_\.Exception\.Message \}.*?if \(\$historyFailure\) \{ \$failed \+= \$historyFailure \}'
        Mutation = @('try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure = $_.Exception.Message }', '')
    }
    @{
        Description = 'the real session-state.json is guarded by size and time (session-capture saves session state)'
        Pattern = '(?s)\$sessionPath = Join-Path \$realLocal ''noctty\\session-state\.json''\s+\$sessionBefore = Get-Metadata \$sessionPath.*?\$sessionAfter = Get-Metadata \$sessionPath.*?SessionUnchanged = \[string\]::Equals\(\$sessionBefore, \$sessionAfter, \[StringComparison\]::Ordinal\).*?if \(-not \$guards\.SessionUnchanged\) \{ \$failed \+= '
        Mutation = @("`$sessionPath = Join-Path `$realLocal 'noctty\session-state.json'", "`$sessionPath = Join-Path `$Run 'session-state.json'")
    }
    @{
        Description = 'the clipboard sequence numbers recorded before and after each run are the shared guard''s own samples, never a second reading (Sol on #744: a resample as the control)'
        Pattern = '(?s)ClipboardSequenceBefore = \$stateGuard\.ClipboardBefore; ClipboardSequenceAfter = \$\(if \(\$null -ne \$stateGuard\.PSObject\.Properties\[''ClipboardAfter''\]\) \{ \$stateGuard\.ClipboardAfter \} else \{ \$null \}\)'
        Mutation = @('ClipboardSequenceAfter = $(if ($null -ne $stateGuard.PSObject.Properties[''ClipboardAfter'']) { $stateGuard.ClipboardAfter } else { $null })', 'ClipboardSequenceAfter = [HiddenLocal]::GetClipboardSequenceNumber()')
    }
    @{
        Description = 'a clipboard sequence of 0 before and after is recorded and reported as unobservable from the shared guard''s own verdict, never as held, and does not fail the run (the lead on #741''s follow-up; Sol on #744)'
        Pattern = '(?s)ClipboardObservable = \$\(if \(\$null -ne \$stateGuard\.PSObject\.Properties\[''ClipboardObservable''\]\) \{ \[bool\]\$stateGuard\.ClipboardObservable \} else \{ \$false \}\).*?\$guards \| ConvertTo-Json -Depth 4 \| Set-Content -LiteralPath \(Join-Path \$Run ''guards\.json''\).*?Write-Host \(Format-InteractiveWin11ClipboardReading \$guards\.ClipboardSequenceBefore \$guards\.ClipboardSequenceAfter\)'
        Mutation = @('ClipboardObservable = $(if ($null -ne $stateGuard.PSObject.Properties[''ClipboardObservable'']) { [bool]$stateGuard.ClipboardObservable } else { $false })', 'ClipboardObservable = $true')
    }
    @{
        Description = 'a failed driver fails the run (council round 1, Opus mutation 03)'
        Pattern = '(?s)if \(\$driverExit -eq 3\) \{ \$failed \+= [^\r\n]+\}\s+elseif \(\$null -ne \$driverExit -and \$driverExit -ne 0\) \{ \$failed \+= '
        Mutation = @('elseif ($null -ne $driverExit -and $driverExit -ne 0) { $failed += ', 'elseif ($false) { $failed += ')
    }
    @{
        Description = 'the driver exits with its own verdict (council round 1, Opus mutation 04)'
        Pattern = '(?s)if \(\$Driver\) \{\s+\$code = Invoke-WorkingSetDriver \| Select-Object -Last 1\s+exit \$code\s+\}'
        Mutation = @('exit $code', 'exit 0')
    }
    @{
        Description = 'the outer half checks the record itself and says complete only when every guard, the driver and the record passed'
        Pattern = '(?s)\$failed \+= @\(Get-WorkingSetRecordProblems \$record \| ForEach-Object \{ "record: \$_" \}\).*?if \(\$failed\.Count -gt 0\) \{ throw \(''working-set harness: '' \+ \(\$failed -join ''; ''\)\) \}\s+Write-Host "working-set harness: \$Workload complete: \$Run"\s+\}'
        Mutation = @('$failed += @(Get-WorkingSetRecordProblems $record | ForEach-Object { "record: $_" })', '')
    }
    @{
        Description = 'the driver''s verdict includes the record check'
        Pattern = '(?s)\$problems = @\(Get-WorkingSetRecordProblems \(\[pscustomobject\]\$record\)\)\s+if \(\$problems\.Count -gt 0 -and -not \$record\.Error\) \{ \$record\.Error = \$problems -join ''; '' \}\s+return \$\(if \(\$record\.Error\) \{ 1 \} else \{ 0 \}\)'
        Mutation = @('if ($problems.Count -gt 0 -and -not $record.Error)', 'if ($false)')
    }
    # --- what the harness may not do
    @{
        Description = 'nothing in the harness uses real input, the foreground, the clipboard, Start-Process or a recursive delete'
        Pattern = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|BringWindowToTop|OpenClipboard|SetClipboardData|GetClipboardData|EmptyClipboard|Set-Clipboard|Get-Clipboard|Windows\.Forms\.Clipboard|Windows\.Clipboard|Start-Process|Invoke-Item|Remove-Item\b[^\r\n;|]*\s-r\w*\b|Directory\]::Delete\(|\.Delete\(\s*\$true\s*\)))'
        Mutation = @('[WorkingSetNative]::Key($base, $nocttyPid, 0x74)', "[WorkingSetNative]::Key(`$base, `$nocttyPid, 0x74); [System.Windows.Forms.Clipboard]::SetText('x')")
    }
    @{
        Description = 'nor an abbreviated recursive delete (council round 1, Opus mutation 10)'
        Pattern = '(?s)\A(?!.*Remove-Item\b[^\r\n;|]*\s-r\w*\b)'
        Mutation = @("[IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), '')", "Remove-Item -LiteralPath `$copy -r -Force")
    }
    @{
        Description = 'nor a recursive directory delete through .NET'
        Pattern = '(?s)\A(?!.*Directory\]::Delete\()'
        Mutation = @("[IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), '')", "[IO.Directory]::Delete(`$copy, `$true)")
    }
    @{
        Description = 'a posted key goes only to a window this copy owns'
        Pattern = '(?s)public static void Key\(IntPtr h, int pid, int vk\) \{\s*int owner; uint tid = GetWindowThreadProcessId\(h, out owner\);[^\r\n]*\s*if \(tid == 0 \|\| owner != pid\) throw'
        Mutation = @('if (tid == 0 || owner != pid) throw', 'if (tid == 0) throw')
    }
    @{
        Description = 'the config clears every default binding, binds nothing that copies or pastes, and denies OSC 52 and updates'
        Pattern = '(?s)\$bindings = \[ordered\]@\{(?:(?!copy|paste)[^}])*\}.*?''auto-update = off''.*?''clipboard-read = deny''.*?''clipboard-write = deny''.*?''copy-on-select = false''.*?''keybind = clear''\s*foreach \(\$key in \$bindings\.Keys\) \{ foreach \(\$chord in \$chords\) \{ "keybind = \$chord\$key=\$\(\$bindings\[\$key\]\)" \} \}\s*\)\s+return \(\$lines -join "`n"\) \+ "`n"'
        Mutation = @("f7 = 'close_tab' }", "f7 = 'close_tab'; f9 = 'copy_to_clipboard' }")
    }
    @{
        Description = 'each key is bound under every Shift, Ctrl and Alt chord, so a modifier the user holds cannot turn a posted key into an unbound one'
        Pattern = '\$chords = @\('''', ''shift\+'', ''ctrl\+'', ''alt\+'', ''ctrl\+shift\+'', ''alt\+shift\+'', ''ctrl\+alt\+'', ''ctrl\+alt\+shift\+''\)'
        Mutation = @(", 'ctrl+alt+shift+')", ')')
    }
    # --- the workload and its proofs
    @{
        Description = 'the workload''s constants are the ones Phase 0a measured (a change is a new workload, and changes WorkloadSha256)'
        Pattern = '(?s)\$script:BlockLines = 25000\s+\$script:RowPageBytes = 1120\s+\$script:Cols = 140\s+\$script:Rows = 45\s+\$script:GridRows = 43\s+\$script:FixedCycles = 20\s+\$script:ChurnCycles = 50\s+\$script:SessionCheckpoints = 10\s+\$script:PruneSeconds = 7\s+\$script:SettleSamples = 10\s+\$script:SampleMs = 500\s+\$script:SettleCapMs = 90000\s'
        Mutation = @('$script:FixedCycles = 20', '$script:FixedCycles = 19')
    }
    @{
        Description = 'a run expects the grid the config gave on the measurement machine, 43 rows (measured on the 0a build and the PR head), not the configured 45'
        Pattern = '(?m)^\$script:GridRows = 43[ \t]*$'
        Mutation = @('$script:GridRows = 43', '$script:GridRows = 45')
    }
    @{
        Description = 'every workload uses those constants: the cycle counts, the prune wait and the checkpoints'
        Pattern = '(?s)for \(\$i = 0; \$i -lt \$script:FixedCycles; \$i\+\+\) \{ \[void\]\(Invoke-TabCycle\) \}\s+Wait-Pruned\s+Add-Stage ''after''.*?for \(\$i = 0; \$i -lt \$script:ChurnCycles; \$i\+\+\) \{ \[void\]\(Invoke-TabCycle\) \}\s+Wait-Pruned\s+Add-Stage ''after''.*?for \(\$i = 0; \$i -lt \$script:SessionCheckpoints; \$i\+\+\) \{'
        Mutation = @('for ($i = 0; $i -lt $script:ChurnCycles; $i++)', 'for ($i = 0; $i -lt 5; $i++)')
    }
    @{
        Description = 'the output block is generated from the constants alone: 25,000 deterministic lines, every seventh in an SGR colour'
        Pattern = '(?s)function New-BlockText \{.*?for \(\$i = 0; \$i -lt \$script:BlockLines; \$i\+\+\) \{\s+\$text = ''ws line \{0:D6\} the quick brown fox jumps over the lazy dog 0123456789 abcdefghij'' -f \$i\s+if \(\$i % 7 -eq 0\)'
        Mutation = @("if (`$i % 7 -eq 0)", "if (`$i % 8 -eq 0)")
    }
    @{
        Description = 'a stage samples at the fixed cadence until Test-Settled or the cap, and records whether its last sample is the base pane alone'
        Pattern = '(?s)function Add-Stage\(\[string\] \$Name\) \{.*?\$samples\.Add\(\(Read-Sample\)\)\s+if \(Test-Settled \$samples\.ToArray\(\)\) \{ break \}\s+Start-Sleep -Milliseconds \$script:SampleMs\s+\} while \(\$clock\.ElapsedMilliseconds - \$started -lt \$script:SettleCapMs\)\s+\$settled = Test-Settled \$samples\.ToArray\(\)\s+if \(-not \$settled\) \{ \$script:wsUnsettled \+= @\(\$Name\) \}.*?base_pane_only = \$last\.base_pane_only'
        Mutation = @('if (-not $settled) { $script:wsUnsettled += @($Name) }', '')
    }
    @{
        Description = 'a sample''s pane set is compared with the base pane, and its sum field is named for what it is (PrivateUsage + SharedCommitUsage)'
        Pattern = '(?s)base_pane_only = \(\$panes\.Count -eq 1 -and \$panes\[0\] -eq \$script:wsBase\).*?private_plus_shared_commit = \$v\[2\]'
        Mutation = @('$panes.Count -eq 1 -and $panes[0] -eq $script:wsBase', '$panes.Count -ge 1')
    }
    @{
        Description = 'each workload branch ends with its after stage (council round 1, Sol: a removed after stage)'
        Pattern = '(?s)\A(?:(?!Add-Stage ''after'').)*(?:Add-Stage ''after''(?:(?!Add-Stage ''after'').)*){5}\z'
        Mutation = @("                }`n                Add-Stage 'after'`n            }`n            'uia-walk' {", "                }`n            }`n            'uia-walk' {")
    }
    @{
        Description = 'after the last close the copy must be back to its base pane alone (bounded), not just 7 s older (SOAK-01 trap 2)'
        Pattern = '(?s)function Wait-Pruned \{\s+Start-Sleep -Seconds \$script:PruneSeconds\s+if \(-not \(Wait-For \{ \$panes = @\(Get-AllSurfaces \$false\); \$panes\.Count -eq 1 -and \$panes\[0\] -eq \$base \} 30000\)\) \{ throw'
        Mutation = @('$panes.Count -eq 1 -and $panes[0] -eq $base } 30000', '$true } 30000')
    }
    @{
        Description = 'the grid is read from the base pane''s pseudoconsole before start, and a grid other than the constants fails the run'
        Pattern = '(?s)\$probe = \[WorkingSetNative\]::Spawn\(\$pwsh, \(''"\{0\}" -NoProfile -NonInteractive -File "\{1\}" -Run "\{2\}" -GridProbePid \{3\}'' -f \$pwsh, \$PSCommandPath, \$Run, \$shells\[0\]\), \$Run, \$desktopPath,.*?if \(\$record\.GridCols -ne \$script:Cols -or \$record\.GridRows -ne \$script:GridRows\) \{ throw [^\r\n]+\}\s+Add-Stage ''start'''
        Mutation = @('if ($record.GridCols -ne $script:Cols -or $record.GridRows -ne $script:GridRows) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a block counts only when the acknowledgement file reaches its own number and the window title shows the pane parsed through its end'
        Pattern = '(?s)\[IO\.File\]::WriteAllText\(\(Join-Path \$work ''next-block\.txt''\), "\$Index`r`n"\)\s+\[WorkingSetNative\]::Key\(\$base, \$nocttyPid, 0x74\)\s+if \(-not \(Wait-For \{ \(Get-FloodCount\) -ge \$Index \} 600000\)\) \{ throw [^\r\n]+\}\s+if \(-not \(Wait-For \{ \[WorkingSetNative\]::Title\(\$hostWindow\)\.Contains\("ws-block-\$Index"\) \} 60000\)\) \{ throw'
        Mutation = @('[WorkingSetNative]::Title($hostWindow).Contains("ws-block-$Index")', '$true')
    }
    @{
        Description = 'the flood batch file sets the title after the block and acknowledges last, reading the block number without a child cmd'
        Pattern = '(?s)''@type "%~dp0block\.txt" \|\| exit /b 1''\s+''@set /p n=<"%~dp0next-block\.txt"''\s+''@title ws-block-%n%''\s+''@echo block>>"%~dp0flood-count\.txt"'''
        Mutation = @("'@title ws-block-%n%'", "'@rem'")
    }
    @{
        Description = 'a session checkpoint counts only with a new base-pane snapshot holding the fixture, read from the copy''s own session file (council round 1)'
        Pattern = '(?s)\$sessionFile = Join-Path \$Bin ''session-state\.json''.*?if \(\$null -ne \$s -and \$s\.At -gt \$previous -and \$s\.At -gt \$closeAt -and \$s\.Lines -eq \$expectedLines -and \$s\.Fixture -ge \$expectedLines - 10\) \{'
        Mutation = @('$s.At -gt $previous -and ', '')
    }
    @{
        Description = 'the driver''s verdict reads the record with its lists as plain arrays (Greptile on #739)'
        Pattern = '(?s)foreach \(\$name in @\(''Stages'', ''SessionSnapshots''\)\) \{\s+if \(\$record\[\$name\] -is \[Collections\.Generic\.List\[object\]\]\) \{ \$record\[\$name\] = \[object\[\]\]\$record\[\$name\]\.ToArray\(\) \}.*?ConvertTo-RecordArrays\s+\$problems = @\(Get-WorkingSetRecordProblems'
        Mutation = @("ConvertTo-RecordArrays`n        `$problems = @(Get-WorkingSetRecordProblems", "`$problems = @(Get-WorkingSetRecordProblems")
    }
    @{
        Description = 'the record is written with its lists as plain arrays, on the error path too'
        Pattern = '(?s)\} finally \{\s+if \(\$process -ne \[IntPtr\]::Zero\) \{ \[void\]\[WorkingSetNative\]::CloseHandle\(\$process\) \}\s+ConvertTo-RecordArrays\s+\$record \| ConvertTo-Json -Depth 8'
        Mutation = @("ConvertTo-RecordArrays`n        `$record | ConvertTo-Json -Depth 8", "`$record | ConvertTo-Json -Depth 8")
    }
    @{
        Description = 'a session checkpoint counts only a snapshot taken after its own close (CodeRabbit on #739)'
        Pattern = '(?s)\$closeAt = \[uint64\]\$script:wsCloseAt.*?if \(\$null -ne \$s -and \$s\.At -gt \$previous -and \$s\.At -gt \$closeAt -and '
        Mutation = @('$s.At -gt $closeAt -and ', '')
    }
    @{
        Description = 'the close''s time is taken right before the close key, on the clock the snapshot uses'
        Pattern = '(?s)\$script:wsCloseAt = \[DateTimeOffset\]::UtcNow\.ToUnixTimeMilliseconds\(\)\s+\[WorkingSetNative\]::Key\(\$new, \$nocttyPid, 0x76\)'
        Mutation = @('$script:wsCloseAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()', '$script:wsCloseAt = 0')
    }
    @{
        Description = 'a -Run inside -MeasureRepo that git does not ignore is refused before the run directory is created (CodeRabbit on #739)'
        Pattern = '(?s)function Invoke-WorkingSetOuterRun\(.*?Assert-WorkingSetRunPlacement \$Run \$build\.Repo\s+.*?\[void\]\(New-Item -ItemType Directory -Path \$Run\)'
        Mutation = @('Assert-WorkingSetRunPlacement $Run $build.Repo', '$null')
    }
    @{
        Description = 'the UIA walk is complete only when it ended, the document holds the last block''s last line, and it counted the whole document (council round 1; Sol, round 2)'
        Pattern = '(?s)\$expectedLines = Get-ExpectedUiaLines.*?walk_complete = \(\$ended -and \$holdsFixture -and \$lines -eq \$expectedLines\)'
        Mutation = @('$ended -and $holdsFixture -and $lines -eq $expectedLines', '$ended')
    }
    @{
        Description = 'the UIA client takes the pane from this copy''s own window handle'
        Pattern = '\$element = \[System\.Windows\.Automation\.AutomationElement\]::FromHandle\(\$base\)'
        Mutation = @('FromHandle($base)', 'RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)')
    }
    @{
        Description = 'each run records the workload''s hash over the workload, its limit, its blocks, the block, the flood batch file and the config'
        Pattern = '(?s)\$record\.BlocksPlanned = Get-WorkloadBlocks \$Workload \$record\.LaunchScrollbackLimit\s+\$record\.WorkloadSha256 = Get-WorkloadSha256 \$Workload \$record\.LaunchScrollbackLimit \$record\.BlocksPlanned \$record\.BlockSha256 \$record\.FloodSha256 \(Join-Path \$Bin ''config\.ghostty''\) \$Run'
        Mutation = @('$record.BlockSha256 $record.FloodSha256', '$record.BlockSha256 ''0''')
    }
    # --- round 2 (Sol M1-M3, Opus's Medium and Lows)
    @{
        Description = 'the product''s payload constants the checks derive from (win32_session_state.zig, win32_uia/text.zig, the config''s line cap)'
        Pattern = '(?s)\$script:SessionBudgetBytes = 524288\s+\$script:SessionOverheadBytes = 96\s+\$script:SessionLineCap = 10000\s+\$script:UiaHistoryCells = 40000\s+\$script:UiaHistoryMaxRows = 500\s'
        Mutation = @('$script:SessionOverheadBytes = 96', '$script:SessionOverheadBytes = 0')
    }
    @{
        Description = 'a session checkpoint counts only a snapshot of exactly the lines its budget gives, so a halved slice from the formatter''s retry does not (Sol, round 2)'
        Pattern = '(?s)\$expectedLines = Get-ExpectedSessionLines.*?\$s\.Lines -eq \$expectedLines -and \$s\.Fixture -ge \$expectedLines - 10\) \{.*?lines = \$script:wsSnapshot\.Lines; fixture_lines = \$script:wsSnapshot\.Fixture \}'
        Mutation = @('$s.Lines -eq $expectedLines -and ', '$s.Lines -le 10000 -and ')
    }
    @{
        Description = 'the driver refuses a staged config that is not byte for byte the generator''s for the run, before its first launch (Sol, round 2)'
        Pattern = '(?s)if \(-not \(Test-WorkingSetConfigBytes \(Join-Path \$Bin ''config\.ghostty''\) \$Workload \$Run\)\) \{ throw [^\r\n]+\}.*?\$check = \[WorkingSetNative\]::Spawn\('
        Mutation = @('if (-not (Test-WorkingSetConfigBytes', 'if ($false -and -not (Test-WorkingSetConfigBytes')
    }
    @{
        Description = 'the outer half writes exactly the generator''s config'
        Pattern = '\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''config\.ghostty''\), \(New-WorkingSetConfigText \$Workload \$Run\), \$script:Utf8\)'
        Mutation = @('(New-WorkingSetConfigText $Workload $Run), $script:Utf8)', '((New-WorkingSetConfigText $Workload $Run) + "initial-command = x"), $script:Utf8)')
    }
    @{
        Description = 'the outer half refuses an inherited NOCTTY_CONPTY before it creates anything (Sol, round 2)'
        Pattern = '(?s)\$source = \$build\.Bin\s+if \(\$null -ne \[Environment\]::GetEnvironmentVariable\(''NOCTTY_CONPTY''\)\) \{ throw ''NOCTTY_CONPTY is set in this environment[^\r\n]+\}.*?\[void\]\(New-Item -ItemType Directory -Path \$Run\)'
        Mutation = @("if (`$null -ne [Environment]::GetEnvironmentVariable('NOCTTY_CONPTY')) { throw 'NOCTTY_CONPTY is set in this environment", "if (`$false) { throw 'NOCTTY_CONPTY is set in this environment")
    }
    @{
        Description = 'the driver refuses NOCTTY_CONPTY before its first launch'
        Pattern = '(?s)if \(\$null -ne \[Environment\]::GetEnvironmentVariable\(''NOCTTY_CONPTY''\)\) \{ throw ''NOCTTY_CONPTY is set; the copy would not run on the bundled ConPTY\.'' \}.*?\$check = \[WorkingSetNative\]::Spawn\('
        Mutation = @("if (`$null -ne [Environment]::GetEnvironmentVariable('NOCTTY_CONPTY')) { throw 'NOCTTY_CONPTY is set; the copy", "if (`$false) { throw 'NOCTTY_CONPTY is set; the copy")
    }
    @{
        Description = 'the copy''s conpty.dll and OpenConsole.exe must be the build''s, byte for byte, before the first launch, and both digests are recorded'
        Pattern = '(?s)foreach \(\$file in @\(@\(''conpty\.dll'', ''ConptyDllSHA256''\), @\(''OpenConsole\.exe'', ''OpenConsoleSHA256''\)\)\) \{.*?\$record\[''Prefix'' \+ \$file\[1\]\] = Get-Sha256 \$built\s+if \(-not \[string\]::Equals\(\[string\]\$record\[\$file\[1\]\], \[string\]\$record\[''Prefix'' \+ \$file\[1\]\], \[StringComparison\]::Ordinal\)\) \{ throw .*?\$check = \[WorkingSetNative\]::Spawn\('
        Mutation = @("if (-not [string]::Equals([string]`$record[`$file[1]], [string]`$record['Prefix' + `$file[1]], [StringComparison]::Ordinal)) { throw", "if (`$false) { throw")
    }
    @{
        Description = 'the record keeps the transport the copy''s own log names: bundled from the copy''s conpty.dll, or the in-box conhost'
        Pattern = '(?s)\$nocttyLog = Read-SharedText \(Join-Path \$Run ''noctty\.log''\)\s+\$record\.Transport = if \(\$nocttyLog\.Contains\(''using the in-box conhost''\)\) \{ ''inbox'' \} elseif \(\$nocttyLog\.IndexOf\(''using bundled ConPTY: '' \+ \(Join-Path \$Bin ''conpty\.dll''\), \[StringComparison\]::OrdinalIgnoreCase\) -ge 0\) \{ ''bundled'' \} else \{ ''unknown'' \}'
        Mutation = @("if (`$nocttyLog.Contains('using the in-box conhost')) { 'inbox' } elseif", "if (`$false) { 'inbox' } elseif")
    }
    @{
        Description = 'the record keeps the CLI''s and the admitted receipt''s digests (Sol, round 2)'
        Pattern = '(?s)ReceiptSha256 = Get-BytesSha256 \$receiptBytes \}.*?\$record\.CliSHA256 = Get-Sha256 \(Join-Path \$Bin ''noctty\.com''\)\s+\$record\.ReceiptSHA256 = \$build\.ReceiptSha256'
        Mutation = @('$record.ReceiptSHA256 = $build.ReceiptSha256', '$record.ReceiptSHA256 = $null')
    }
    @{
        Description = 'every driver launch names the driver''s own private desktop (Opus, round 2: m03, Default for $desktopPath)'
        Pattern = '\$desktopPath = "WinSta0\\\$DesktopName"'
        Mutation = @('$desktopPath = "WinSta0\$DesktopName"', '$desktopPath = ''WinSta0\Default''')
    }
    @{
        Description = 'the +version check and the copy are each launched on $desktopPath (Opus, round 2: m01, Default in the copy''s own launch)'
        Pattern = '(?s)\[WorkingSetNative\]::Spawn\(\$exe, \(''"\{0\}" \+version'' -f \$exe\), \$work, \$desktopPath, .*?\[WorkingSetNative\]::Spawn\(\$exe, \$commandLine, \$work, \$desktopPath, '
        Mutation = @('[WorkingSetNative]::Spawn($exe, $commandLine, $work, $desktopPath,', '[WorkingSetNative]::Spawn($exe, $commandLine, $work, ''WinSta0\Default'',')
    }
    @{
        Description = 'the native Spawn refuses any desktop but the caller''s own, read through GetThreadDesktop and UOI_NAME (Opus, round 2)'
        Pattern = '(?s)public static ProcessInfo Spawn\(.*?string own = "WinSta0\\\\" \+ CurrentDesktopName\(\);\s+if \(!string\.Equals\(desktop, own, StringComparison\.OrdinalIgnoreCase\)\) throw new Exception\("A child must start on the caller''s own desktop"\);.*?CreateProcessW\('
        Mutation = @('if (!string.Equals(desktop, own, StringComparison.OrdinalIgnoreCase)) throw new Exception("A child must start on the caller''s own desktop");', '')
    }
    @{
        Description = 'the native LaunchDriver refuses the caller''s own desktop, Default and the input desktop'
        Pattern = '(?s)public static ProcessInfo LaunchDriver\(.*?if \(input == null \|\| string\.Equals\(desktop, "WinSta0\\\\" \+ CurrentDesktopName\(\), StringComparison\.OrdinalIgnoreCase\) \|\| string\.Equals\(desktop, "WinSta0\\\\Default", StringComparison\.OrdinalIgnoreCase\) \|\| string\.Equals\(desktop, "WinSta0\\\\" \+ input, StringComparison\.OrdinalIgnoreCase\)\)\s+throw new Exception\("The driver must start on a private desktop[^"]*"\);.*?CreateProcessW\('
        Mutation = @('string.Equals(desktop, "WinSta0\\" + CurrentDesktopName(), StringComparison.OrdinalIgnoreCase) || ', '')
    }
    @{
        Description = 'the copy''s --scrollback-limit is read back from its launch arguments and must be the workload''s (Opus, round 2: m06, 10,000,000 under 1 GiB)'
        Pattern = '(?s)"--scrollback-limit=\$\(\$record\.ScrollbackLimitBytes\)"\).*?\$commandLine = .*?\$expectedArgv = Get-WorkingSetExpectedArgv \$exe "noctty-interactive-\$\(\$layout\.SandboxId\)" \$saveState \(Join-Path \$Bin ''config\.ghostty''\) \$record\.ScrollbackLimitBytes\s+if \(-not \(Test-WorkingSetArgv \(\[WorkingSetNative\]::SplitCommandLine\(\$commandLine\)\) \$expectedArgv\)\) \{ throw [^\r\n]+\}\s+\$planned = Get-WorkingSetLaunchValues \$expectedArgv\s+\$record\.LaunchScrollbackLimit = \[long\]@\(\$planned\.ScrollbackLimits\)\[0\]'
        Mutation = @('"--scrollback-limit=$($record.ScrollbackLimitBytes)")', '"--scrollback-limit=10000000")')
    }
    @{
        Description = 'the outer half refuses a record whose workload, launch limit or planned blocks are not the ones it asked for'
        Pattern = '(?s)if \(-not \[string\]::Equals\(\[string\]\$record\.Workload, \$Workload, \[StringComparison\]::Ordinal\)\) \{ \$failed \+= [^\r\n]+\}\s+if \(\$record\.ScrollbackLimitBytes -ne \$wantLimit -or \$record\.LaunchScrollbackLimit -ne \$wantLimit\) \{ \$failed \+= [^\r\n]+\}\s+if \(\$record\.BlocksPlanned -ne \(Get-WorkloadBlocks \$Workload \$wantLimit\)\) \{ \$failed \+= '
        Mutation = @('if (-not [string]::Equals([string]$record.Workload, $Workload, [StringComparison]::Ordinal)) { $failed += "record: workload $($record.Workload), not $Workload" }', '')
    }
    @{
        Description = 'the driver is given the outer half''s own workload (Opus, round 2: m07)'
        Pattern = '\$build\.Repo, \$copy, \$Run, \$Workload, \$ExpectedBuildMode, '
        Mutation = @('$Run, $Workload, $ExpectedBuildMode,', '$Run, ''fixed'', $ExpectedBuildMode,')
    }
    @{
        Description = 'nor [Diagnostics.Process]::Start, which names no desktop (Opus, round 2: m13)'
        Pattern = '(?s)\A(?!.*Process\]::Start\()'
        Mutation = @("[IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), '')", "[IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), ''); [Diagnostics.Process]::Start(`$exe)")
    }
    @{
        Description = 'the driver''s noctty.ico refusal itself, not the text of its message (Opus, round 2: m05)'
        Pattern = '-or \(Test-Path -LiteralPath \(Join-Path \$Bin ''noctty\.ico''\)\)\) \{ throw ''The copy is not a portable copy without noctty\.ico\.'' \}'
        Mutation = @(" -or (Test-Path -LiteralPath (Join-Path `$Bin 'noctty.ico'))", '')
    }
    @{
        Description = 'the receipt is read once: its fields and its digest come from the same bytes (CodeRabbit on #739)'
        Pattern = '(?s)\$lock = \[IO\.File\]::Open\(\(Join-Path \$layout\.Root ''build\.lock''\), \[IO\.FileMode\]::OpenOrCreate, \[IO\.FileAccess\]::Read, \[IO\.FileShare\]::Read\)\s+try \{\s+if \(-not \(\[IO\.Path\]::GetFullPath\(\$layout\.Receipt\)\)\.StartsWith\(\$layout\.Repo\.TrimEnd\(''\\''\) \+ ''\\'', \[StringComparison\]::OrdinalIgnoreCase\)\) \{ throw [^\r\n]+\}\s+Assert-InteractiveWin11MeasurePlainPath \$layout\.Receipt\s+\$receiptBytes = Read-WorkingSetPlainFile \$layout\.Receipt\s+Assert-InteractiveWin11MeasureBuild -RepoRoot \$Repo -ExePath \$exe\s+\$receiptAfter = Read-WorkingSetPlainFile \$layout\.Receipt\s+\} finally \{ \$lock\.Dispose\(\) \}.*?\$receipt = \[Text\.Encoding\]::UTF8\.GetString\(\$receiptBytes\)[^\r\n]*\| ConvertFrom-Json.*?ReceiptSha256 = Get-BytesSha256 \$receiptBytes \}'
        Mutation = @('ReceiptSha256 = Get-BytesSha256 $receiptBytes }', 'ReceiptSha256 = Get-Sha256 (Get-InteractiveWin11MeasureLayout $Repo).Receipt }')
    }
    @{
        Description = 'F5 types a relative .\flood.cmd, never the run''s path, so cmd never parses the path (CodeRabbit on #739)'
        Pattern = '\$floodText = ''\.\\\\flood\.cmd\\r'''
        Mutation = @("`$floodText = '.\\flood.cmd\r'", "`$floodText = '\`"' + (Join-Path `$work 'flood.cmd').Replace('\', '\\') + '\`"\r'")
    }
    @{
        Description = 'the copy is launched with --config-default-files=false and --config-file naming the generated config, both read back from its launch arguments (Sol, round 3)'
        Pattern = '(?s)''--config-default-files=false'', "--config-file=\$\(Join-Path \$Bin ''config\.ghostty''\)",.*?Test-WorkingSetArgv \(\[WorkingSetNative\]::SplitCommandLine\(\$commandLine\)\) \$expectedArgv.*?\$record\.LaunchConfigFile = @\(\$planned\.ConfigFiles\)\[0\]'
        Mutation = @("'--config-default-files=false', `"--config-file=", "`"--config-file=")
    }
    @{
        Description = 'the driver refuses a staged copy holding a legacy config file the default search would read, before its first launch (Sol, round 3)'
        Pattern = '(?s)\$stray = @\(Get-WorkingSetStrayConfigs \$Bin\); if \(\$stray\.Count -gt 0\) \{ throw .*?\$check = \[WorkingSetNative\]::Spawn\('
        Mutation = @('if ($stray.Count -gt 0) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the driver reads every command line of the config in any spelling, initial-command included'
        Pattern = '\$configCommands = @\(\[IO\.File\]::ReadAllLines\(\(Join-Path \$Bin ''config\.ghostty''\)\) \| Where-Object \{ \$_ -match ''\^\\s\*\(initial-\)\?command\\s\*='' \}\)'
        Mutation = @("`$_ -match '^\s*(initial-)?command\s*='", "`$_ -like 'command =*'")
    }
    @{
        Description = 'after the launch, the copy''s real command line (by PID, as #738 reads one) must carry the same limit and config, or the run stops (Opus, round 3)'
        Pattern = '(?s)\$pi = \[WorkingSetNative\]::Spawn\(\$exe, \$commandLine, .*?\$launchedLine = \[string\]\(Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = \$nocttyPid" -ErrorAction Stop\)\.CommandLine\s+if \(-not \(Test-WorkingSetArgv \(\[WorkingSetNative\]::SplitCommandLine\(\$launchedLine\)\) \$expectedArgv\)\) \{ throw'
        Mutation = @('if (-not (Test-WorkingSetArgv ([WorkingSetNative]::SplitCommandLine($launchedLine))', 'if ($false -and -not (Test-WorkingSetArgv ([WorkingSetNative]::SplitCommandLine($launchedLine))')
    }
    @{
        Description = 'nothing appends to the launch arguments after they are built (Opus, round 3: m06b, a second --scrollback-limit)'
        Pattern = '(?s)\A(?!.*\$launchArguments\s*\+=)'
        Mutation = @('$commandLine = (''"{0}" '' -f $exe)', '$launchArguments += ''--scrollback-limit=10000000''; $commandLine = (''"{0}" '' -f $exe)')
    }
    @{
        Description = 'the ConPTY pair check compares the copy with the build, not with itself (Opus, round 3: t6)'
        Pattern = '\$staged = Join-Path \$Bin \$file\[0\]; \$built = Join-Path \$build\.Bin \$file\[0\]'
        Mutation = @('$built = Join-Path $build.Bin $file[0]', '$built = $staged')
    }
    @{
        Description = 'the record check requires a checkpoint''s fixture lines too, not only its length (Opus, round 3: p3)'
        Pattern = 'if \(\[int\]\$pair\.lines -ne \$expectedLines -or \[int\]\$pair\.fixture_lines -lt \$expectedLines - 10\)'
        Mutation = @(' -or [int]$pair.fixture_lines -lt $expectedLines - 10', '')
    }
    @{
        Description = 'nor the [Diagnostics.Process] type at all, whose instance Start names no desktop either (Opus, round 3: m13b)'
        Pattern = '(?s)\A(?!.*(?:Diagnostics\.Process\]|New-Object\s+(?:System\.)?Diagnostics\.Process\b))'
        Mutation = @("[IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), '')", "`$p = [Diagnostics.Process]::new(); [void]`$p.Start(); [IO.File]::WriteAllText((Join-Path `$copy 'noctty.portable'), '')")
    }
    @{
        Description = 'the admitted receipt must still be the receipt on disk once the admission has passed, or the run refuses (Sol, round 4)'
        Pattern = 'if \(-not \[string\]::Equals\(\[Convert\]::ToBase64String\(\$receiptBytes\), \[Convert\]::ToBase64String\(\$receiptAfter\), \[StringComparison\]::Ordinal\)\) \{ throw ''The measurement receipt changed during admission\.'' \}'
        Mutation = @('if (-not [string]::Equals([Convert]::ToBase64String($receiptBytes), [Convert]::ToBase64String($receiptAfter), [StringComparison]::Ordinal)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the final command line must split into exactly the expected argument list before the launch (Sol, round 4)'
        Pattern = 'if \(-not \(Test-WorkingSetArgv \(\[WorkingSetNative\]::SplitCommandLine\(\$commandLine\)\) \$expectedArgv\)\) \{ throw'
        Mutation = @('if (-not (Test-WorkingSetArgv ([WorkingSetNative]::SplitCommandLine($commandLine)) $expectedArgv)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'the outer half refuses a record whose launch config file is not the copy''s own generated one (Opus, round 4: n3)'
        Pattern = 'if \(-not \[string\]::Equals\(\[string\]\$record\.LaunchConfigFile, \(Join-Path \$copy ''config\.ghostty''\), \[StringComparison\]::OrdinalIgnoreCase\)\) \{ \$failed \+= '
        Mutation = @('if (-not [string]::Equals([string]$record.LaunchConfigFile, (Join-Path $copy ''config.ghostty''), [StringComparison]::OrdinalIgnoreCase)) { $failed += ', 'if ($false) { $failed += ')
    }
    @{
        Description = 'the final command line and the expected argument list are each assigned exactly once (Opus, round 5: a5b, an append plus a rebuilt list)'
        Pattern = '(?s)\A(?=.*?\$commandLine\b\s*=(?!=))(?=.*?\$expectedArgv\b\s*=(?!=))(?!(?:.*?\$commandLine\b\s*[-+*/]?=(?!=)){2})(?!(?:.*?\$expectedArgv\b\s*[-+*/]?=(?!=)){2})'
        Mutation = @('[void][WorkingSetNative]::SetErrorMode(', '$commandLine += '' --initial-command=x''; $expectedArgv = [string[]][WorkingSetNative]::SplitCommandLine($commandLine); [void][WorkingSetNative]::SetErrorMode(')
    }
    @{
        Description = 'the no-follow read checks BY_HANDLE_FILE_INFORMATION''s size and every field offset against the SDK''s before it reads (Greptile on #739)'
        Pattern = 'if \(-not \[string\]::Equals\(\[WorkingSetPlainRead\]::Layout\(\), \$wantLayout, \[StringComparison\]::Ordinal\)\) \{ throw [^\r\n]+\}\s+return \[WorkingSetPlainRead\]::Read\(\$Path\)'
        Mutation = @('if (-not [string]::Equals([WorkingSetPlainRead]::Layout(), $wantLayout, [StringComparison]::Ordinal)) { throw', 'if ($false) { throw')
    }
    # --- the native layer
    @{
        Description = 'the mirrored structs are checked against the SDK''s x64 sizes and offsets before anything runs (AGENTS.md "Win32 FFI")'
        Pattern = '(?s)if \(-not \[string\]::Equals\(\[WorkingSetNative\]::Layout\(\), \$script:SdkLayout, \[StringComparison\]::Ordinal\)\) \{ throw'
        Mutation = @('if (-not [string]::Equals([WorkingSetNative]::Layout(), $script:SdkLayout, [StringComparison]::Ordinal)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a count whose query failed is published as unavailable (-1, then null), never 0'
        Pattern = '(?s)long handleCount = GetProcessHandleCount\(process, out handles\) \? \(long\)handles : -1;.*?Marshal\.SetLastPInvokeError\(0\);\s+uint v = GetGuiResources\(process, kind\);\s+return v == 0 && Marshal\.GetLastPInvokeError\(\) != 0 \? -1 : \(long\)v;.*?handles = \$\(if \(\$v\[4\] -lt 0\) \{ \$null \} else \{ \$v\[4\] \}\)'
        Mutation = @('? (long)handles : -1;', '? (long)handles : 0;')
    }
)
# The harness's floor is PowerShell 7.2 (.NET 6): its native layer calls Marshal.SetLastPInvokeError and
# GetLastPInvokeError, which older .NET lacks (Greptile on #739). `#requires` is a comment token, which the rules'
# comment-stripped text leaves out, so this reads the file's first line.
$workingSetFirstLine = Get-Content -LiteralPath $workingSetScript -TotalCount 1
if (-not (Test-WorkingSetOrdinal $workingSetFirstLine '#requires -Version 7.2')) { throw "The working-set harness must require PowerShell 7.2 (.NET 6) for its native layer, not '$workingSetFirstLine'." }
if (-not $workingSetText.Contains('Marshal.SetLastPInvokeError')) { throw 'The 7.2 floor is for Marshal.SetLastPInvokeError; update this check if the native layer no longer calls it.' }
$workingSetMutations = 0
foreach ($rule in $workingSetRules) {
    Assert-TextContract -Content $workingSetText -Pattern $rule.Pattern -Description $rule.Description -Context $workingSetScript
    $mutated = $workingSetText.Replace($rule.Mutation[0], $rule.Mutation[1])
    if ([string]::Equals($mutated, $workingSetText, [StringComparison]::Ordinal)) { throw "Working-set contract mutation changed nothing: $($rule.Description)" }
    if ($mutated -match $rule.Pattern) { throw "Working-set contract accepted a mutation: $($rule.Description)" }
    $workingSetMutations++
}

# Every launch names its desktop: the native source assigns the startup desktop exactly twice, each from the caller's
# `desktop` argument, and both launches refuse an empty one. The control is council round 1's (Sol): a second
# assignment that overwrites the value with null right before CreateProcessW.
$nativeSourceText = [regex]::Match($workingSetText, "(?s)@'\r?\n(using System;.*?public static class WorkingSetNative.*?)\r?\n'@").Groups[1].Value
if (-not $nativeSourceText) { throw 'The working-set harness must hold one WorkingSetNative source.' }
function Test-WorkingSetDesktopAssignments([string] $Source) {
    $assignments = @([regex]::Matches($Source, '(?<![\w])(?:si\.info\.)?desktop\s*=(?!=)\s*[^,;}\r\n]+') | ForEach-Object { $_.Value -replace '\s+', ' ' })
    $guards = [regex]::Matches($Source, 'if \(string\.IsNullOrEmpty\(desktop\)\) throw new Exception\("A launch must name its desktop"\);').Count
    return $assignments.Count -eq 2 -and $assignments[0] -ceq 'desktop = desktop' -and $assignments[1] -ceq 'si.info.desktop = desktop' -and $guards -eq 2
}
if (-not (Test-WorkingSetDesktopAssignments $nativeSourceText)) { throw 'Every launch must take its startup desktop from its caller, once, and refuse an empty one.' }
if (Test-WorkingSetDesktopAssignments ($nativeSourceText.Replace('si.attributes = list;', "si.attributes = list;`n            si.info.desktop = null;"))) {
    throw 'The desktop check accepted an assignment that overwrites the startup desktop with null.'
}

# The shared state guard holds the paths the harness no longer restates: the real startup ledger and the product jump
# list by its exact name, both compared after the run. The control is council round 1's (Opus mutation 07): the jump
# list's name changed.
function Test-WorkingSetStateGuardPaths([string] $Text) {
    return $Text -match '(?s)Startup = Join-Path \$LocalAppDataRoot ''noctty\\startup-attempts\.json''\s+ProductJumpList = Join-Path \$destinations ''c2214d6ebc43ff3f\.customDestinations-ms''.*?foreach \(\$name in @\(''Startup'', ''ProductJumpList''\)\) \{'
}
if (-not (Test-WorkingSetStateGuardPaths $workingSetGuardText)) { throw 'scripts/interactive-win11-state-guard.ps1 must guard the real startup ledger and the product jump list by their exact paths.' }
if (Test-WorkingSetStateGuardPaths ($workingSetGuardText.Replace('c2214d6ebc43ff3f.customDestinations-ms', '0000000000000000.customDestinations-ms'))) {
    throw 'The state-guard path check accepted another jump list name.'
}

# The pure functions, taken from the harness's AST and run with the harness's own constants (evaluated from its
# `$script:` assignments; the runner's script scope is restored afterwards, values and existence both).
$workingSetAst = [Management.Automation.Language.Parser]::ParseFile($workingSetScript, [ref]$null, [ref]$null)
function Get-WorkingSetFunction([string] $Name) {
    $found = @($workingSetAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $false))
    if ($found.Count -ne 1) { throw "The working-set harness must define $Name once." }
    return $found[0].Extent.Text
}
$constantNames = @('BlockLines', 'RowPageBytes', 'Cols', 'Rows', 'GridRows', 'FixedCycles', 'ChurnCycles', 'SessionCheckpoints', 'PruneSeconds', 'SettleSamples', 'SampleMs', 'SettleCapMs', 'SessionBudgetBytes', 'SessionOverheadBytes', 'SessionLineCap', 'UiaHistoryCells', 'UiaHistoryMaxRows')
$constantLines = foreach ($name in $constantNames) {
    $line = [regex]::Match($workingSetText, "(?m)^\`$script:$name = \d+[ \t]*$").Value.Trim()
    if (-not $line) { throw "The working-set harness has no `$script:$name = <number> line." }
    $line
}
$savedScriptVars = @{}
foreach ($name in $constantNames + @('Utf8')) {
    $existing = Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
    $savedScriptVars[$name] = [pscustomobject]@{ Existed = $null -ne $existing; Value = $(if ($null -ne $existing) { $existing.Value } else { $null }) }
}
try {
. ([scriptblock]::Create(($constantLines -join "`n")))
$script:Utf8 = [Text.UTF8Encoding]::new($false)

# The settle rule: a flat series settles, a drift of 1% in private bytes or 2% in working set over the last ten
# samples does not, nor do fewer than ten samples. The control (the 0.5% private-bytes tolerance widened to 5%) must
# accept the 1% drift.
$settledText = Get-WorkingSetFunction 'Test-Settled'
function New-WorkingSetSamples([double] $PrivateDrift, [double] $WorkingDrift, [int] $Count = 12) {
    return @(for ($i = 0; $i -lt $Count; $i++) {
            $t = if ($i -ge $Count - 10) { ($i - ($Count - 10)) / 9.0 } else { 0 }
            [pscustomobject]@{ private_bytes = 100000000 * (1 + $PrivateDrift * $t); working_set = 200000000 * (1 + $WorkingDrift * $t) }
        })
}
& {
    . ([scriptblock]::Create($settledText))
    if (-not (Test-Settled (New-WorkingSetSamples 0 0))) { throw 'Test-Settled must accept a flat series.' }
    if (-not (Test-Settled (New-WorkingSetSamples 0.004 0.009))) { throw 'Test-Settled must accept drift inside its tolerances.' }
    if (Test-Settled (New-WorkingSetSamples 0.01 0)) { throw 'Test-Settled accepted a 1% private-bytes drift.' }
    if (Test-Settled (New-WorkingSetSamples 0 0.02)) { throw 'Test-Settled accepted a 2% working-set drift.' }
    if (Test-Settled (New-WorkingSetSamples 0 0 9)) { throw 'Test-Settled accepted fewer than ten samples.' }
}
$settledControl = $settledText.Replace('{ 0.005 }', '{ 0.05 }')
if ([string]::Equals($settledControl, $settledText, [StringComparison]::Ordinal)) { throw 'The settle control changed nothing.' }
$controlAccepted = & { . ([scriptblock]::Create($settledControl)); Test-Settled (New-WorkingSetSamples 0.01 0) }
if (-not $controlAccepted) { throw 'The settle cases did not catch a widened private-bytes tolerance.' }

# The block counts and the required stages.
$blocksText = Get-WorkingSetFunction 'Get-WorkloadBlocks'
$stagesText = Get-WorkingSetFunction 'Get-WorkloadStages'
& {
    . ([scriptblock]::Create($blocksText))
    . ([scriptblock]::Create($stagesText))
    $want = [ordered]@{ 'fixed' = 1; 'scrollback-default' = 4; 'uia-walk' = 4; 'session-capture' = 4; 'tab-churn' = 0 }
    foreach ($name in $want.Keys) { if ((Get-WorkloadBlocks $name 1073741824) -ne $want[$name]) { throw "Get-WorkloadBlocks changed for $name." } }
    # 1.25 times what 1 GiB holds at 1,120 bytes a row, in blocks of 25,000 lines: 48.
    if ((Get-WorkloadBlocks 'scrollback-max' 1073741824) -ne 48) { throw 'scrollback-max must write 1.25 times what -ScrollbackMaxBytes holds.' }
    if (-not (Test-WorkingSetOrdinal (@(Get-WorkloadStages 'scrollback-max' 48) -join ',') 'start,block-8,block-16,block-24,block-32,block-40,block-48,after')) { throw 'scrollback-max''s stages changed.' }
    if (-not (Test-WorkingSetOrdinal (@(Get-WorkloadStages 'scrollback-default' 4) -join ',') 'start,block-1,block-2,block-3,block-4,after')) { throw 'scrollback-default''s stages changed.' }
    foreach ($name in 'fixed', 'tab-churn') { if (-not (Test-WorkingSetOrdinal (@(Get-WorkloadStages $name 0) -join ',') 'start,after')) { throw "$name's stages changed." } }
    foreach ($name in 'uia-walk', 'session-capture') { if (-not (Test-WorkingSetOrdinal (@(Get-WorkloadStages $name 4) -join ',') 'start,filled,after')) { throw "$name's stages changed." } }
}

# The record verdict: a complete synthetic record of each workload passes; each control (council round 1: a removed
# after stage, an unsettled stage, a stage off the base pane, the wrong grid, no close that took, a non-zero exit, a
# missed block, a short session or an incomplete UIA walk) must give a problem.
$problemsText = Get-WorkingSetFunction 'Get-WorkingSetRecordProblems'
& {
    . ([scriptblock]::Create($blocksText))
    . ([scriptblock]::Create($stagesText))
    . ([scriptblock]::Create($problemsText))
    . ([scriptblock]::Create((Get-WorkingSetFunction 'Get-ExpectedSessionLines')))
    . ([scriptblock]::Create((Get-WorkingSetFunction 'Get-ExpectedUiaLines')))
    # The formulas give what every run measured: 3,717 session lines at 140 columns and a 329-line walk at 140 x 43.
    if ((Get-ExpectedSessionLines) -ne 3717) { throw "Get-ExpectedSessionLines gives $(Get-ExpectedSessionLines), not the 3,717 measured." }
    if ((Get-ExpectedUiaLines) -ne 329) { throw "Get-ExpectedUiaLines gives $(Get-ExpectedUiaLines), not the 329 measured." }
    function New-WorkingSetRecord([string] $Name) {
        $limit = if ($Name -eq 'scrollback-max') { 1073741824 } else { 10000000 }
        $blocks = Get-WorkloadBlocks $Name $limit
        $cycles = switch ($Name) { 'fixed' { 20 } 'tab-churn' { 50 } 'session-capture' { 10 } default { 0 } }
        $stages = @(Get-WorkloadStages $Name $blocks | ForEach-Object { [pscustomobject]@{ name = $_; settled = -not $_.StartsWith('block-'); base_pane_only = $true } })
        return [pscustomobject]@{
            Schema = 2; Workload = $Name; Error = $null; Exit = 0; QuitPosts = 1; GridCols = 140; GridRows = 43
            ScrollbackLimitBytes = $limit; Blocks = $blocks; BlocksPlanned = $blocks; Cycles = $cycles; CyclesMissed = 0
            SessionSaves = $(if ($Name -eq 'session-capture') { 10 } else { 0 })
            SessionSnapshots = @(if ($Name -eq 'session-capture') { foreach ($k in 1..10) { [pscustomobject]@{ close_at_unix_ms = [uint64](1000 * $k); snapshot_at_unix_ms = [uint64](1000 * $k + 900); lines = 3717; fixture_lines = 3715 } } })
            Uia = $(if ($Name -eq 'uia-walk') { [pscustomobject]@{ walk_complete = $true; walk_ended = $true; holds_last_line = $true; walked_lines = 329 } } else { $null })
            LaunchConfigDefaultFiles = $false; LaunchConfigFile = 'C:\run\copy\config.ghostty'
            Transport = 'bundled'; ConptyDllSHA256 = 'aa'; PrefixConptyDllSHA256 = 'aa'; OpenConsoleSHA256 = 'bb'; PrefixOpenConsoleSHA256 = 'bb'
            Stages = $stages
        }
    }
    foreach ($name in 'fixed', 'scrollback-default', 'scrollback-max', 'uia-walk', 'session-capture', 'tab-churn') {
        $problems = @(Get-WorkingSetRecordProblems (New-WorkingSetRecord $name))
        if ($problems.Count -ne 0) { throw "A complete $name record gave problems: $($problems -join '; ')" }
    }
    $controls = @(
        @{ Name = 'a removed after stage'; Workload = 'scrollback-default'; Change = { param($r) $r.Stages = @($r.Stages | Where-Object { $_.name -ne 'after' }) } }
        @{ Name = 'an unsettled after stage'; Workload = 'fixed'; Change = { param($r) $r.Stages[-1].settled = $false } }
        @{ Name = 'a stage off the base pane'; Workload = 'tab-churn'; Change = { param($r) $r.Stages[-1].base_pane_only = $false } }
        @{ Name = 'the wrong grid'; Workload = 'uia-walk'; Change = { param($r) $r.GridRows = 30 } }
        @{ Name = 'the configured 45 rows'; Workload = 'fixed'; Change = { param($r) $r.GridRows = 45 } }
        @{ Name = 'no close that took'; Workload = 'fixed'; Change = { param($r) $r.QuitPosts = 0 } }
        @{ Name = 'a non-zero exit'; Workload = 'fixed'; Change = { param($r) $r.Exit = 1 } }
        @{ Name = 'a missed block'; Workload = 'scrollback-max'; Change = { param($r) $r.Blocks = 47 } }
        @{ Name = 'a planned block count off the limit'; Workload = 'scrollback-max'; Change = { param($r) $r.Blocks = 20; $r.BlocksPlanned = 20 } }
        @{ Name = 'a missed cycle'; Workload = 'tab-churn'; Change = { param($r) $r.Cycles = 49; $r.CyclesMissed = 1 } }
        @{ Name = 'a short session'; Workload = 'session-capture'; Change = { param($r) $r.SessionSaves = 9 } }
        @{ Name = 'a session snapshot from before its close'; Workload = 'session-capture'; Change = { param($r) $r.SessionSnapshots[4].snapshot_at_unix_ms = $r.SessionSnapshots[4].close_at_unix_ms - 10 } }
        @{ Name = 'a session snapshot no newer than the one before'; Workload = 'session-capture'; Change = { param($r) $r.SessionSnapshots[4].snapshot_at_unix_ms = $r.SessionSnapshots[3].snapshot_at_unix_ms } }
        @{ Name = 'a counted snapshot without its times'; Workload = 'session-capture'; Change = { param($r) $r.SessionSnapshots = @($r.SessionSnapshots | Select-Object -First 9) } }
        @{ Name = 'a halved session capture, 1,858 lines (Sol, round 2: the formatter''s retry)'; Workload = 'session-capture'; Change = { param($r) $r.SessionSnapshots[6].lines = 1858; $r.SessionSnapshots[6].fixture_lines = 1856 } }
        @{ Name = 'a checkpoint of the right length that is not the fixture (Opus, round 3)'; Workload = 'session-capture'; Change = { param($r) $r.SessionSnapshots[2].fixture_lines = 100 } }
        @{ Name = 'a UIA document of the history rows alone, 285 lines (Sol, round 2)'; Workload = 'uia-walk'; Change = { param($r) $r.Uia.walked_lines = 285 } }
        @{ Name = 'a UIA walk that never ended'; Workload = 'uia-walk'; Change = { param($r) $r.Uia.walk_ended = $false } }
        @{ Name = 'the in-box conhost'; Workload = 'fixed'; Change = { param($r) $r.Transport = 'inbox' } }
        @{ Name = 'default config files left on (Sol, round 3)'; Workload = 'uia-walk'; Change = { param($r) $r.LaunchConfigDefaultFiles = $true } }
        @{ Name = 'no generated config named'; Workload = 'fixed'; Change = { param($r) $r.LaunchConfigFile = $null } }
        @{ Name = 'a transport the log did not name'; Workload = 'tab-churn'; Change = { param($r) $r.Transport = $null } }
        @{ Name = 'a conpty.dll not the build''s'; Workload = 'scrollback-default'; Change = { param($r) $r.ConptyDllSHA256 = 'ab' } }
        @{ Name = 'no OpenConsole.exe digest'; Workload = 'fixed'; Change = { param($r) $r.OpenConsoleSHA256 = $null; $r.PrefixOpenConsoleSHA256 = $null } }
        @{ Name = 'an incomplete UIA walk'; Workload = 'uia-walk'; Change = { param($r) $r.Uia.walk_complete = $false } }
        @{ Name = 'an older schema'; Workload = 'fixed'; Change = { param($r) $r.Schema = 1 } }
    )
    foreach ($control in $controls) {
        $record = New-WorkingSetRecord $control.Workload
        & $control.Change $record
        if (@(Get-WorkingSetRecordProblems $record).Count -eq 0) { throw "The record verdict accepted $($control.Name)." }
    }
}

# The workload hash: the same inputs give the same hash, the run's own directory (in working-directory and, escaped,
# in the flood binding) does not count, and a changed workload, scrollback limit, planned block count, constant, block,
# flood batch file or config line does (Greptile, CodeRabbit and both council seats on #739).
$hashText = Get-WorkingSetFunction 'Get-WorkloadSha256'
$hashDir = Join-Path ([IO.Path]::GetTempPath()) ('ws-contract-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($hashDir)
try {
    $configA = Join-Path $hashDir 'a.ghostty'; $configB = Join-Path $hashDir 'b.ghostty'; $configC = Join-Path $hashDir 'c.ghostty'
    [IO.File]::WriteAllLines($configA, [string[]]@('window-width = 140', 'working-directory = C:\run-a\work', 'keybind = f5=text:\"C:\\run-a\\work\\flood.cmd\"\r'))
    [IO.File]::WriteAllLines($configB, [string[]]@('window-width = 140', 'working-directory = D:\other\run-b\work', 'keybind = f5=text:\"D:\\other\\run-b\\work\\flood.cmd\"\r'))
    [IO.File]::WriteAllLines($configC, [string[]]@('window-width = 141', 'working-directory = C:\run-a\work', 'keybind = f5=text:\"C:\\run-a\\work\\flood.cmd\"\r'))
    & {
        . ([scriptblock]::Create($hashText))
        $a = Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a'
        if ($a -notmatch '\A[0-9a-f]{64}\z') { throw 'Get-WorkloadSha256 must give a SHA-256.' }
        if (-not (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configB 'D:\other\run-b\'))) { throw 'The workload hash must not depend on the run''s directory.' }
        if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configB 'D:\other')) { throw 'The workload hash took out more than the run''s directory.' }
        if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'tab-churn' 10000000 1 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the workload.' }
        if (Test-WorkingSetOrdinal (Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' 'ff' $configA 'C:\run-a') (Get-WorkloadSha256 'scrollback-max' 2147483647 96 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the scrollback limit.' }
        if (Test-WorkingSetOrdinal (Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' 'ff' $configA 'C:\run-a') (Get-WorkloadSha256 'scrollback-max' 1073741824 47 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the planned blocks.' }
        if (Test-WorkingSetOrdinal (Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' 'ff' $configA 'C:\run-a') (Get-WorkloadSha256 'scrollback-max' 2147483647 48 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the scrollback limit at the same block count.' }
        if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'ab' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the block.' }
        if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'fe' $configA 'C:\run-a')) { throw 'The workload hash ignored the flood batch file.' }
        if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configC 'C:\run-a')) { throw 'The workload hash ignored a config line.' }
        $script:FixedCycles++
        try { if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored a constant.' } } finally { $script:FixedCycles-- }
        $script:GridRows++
        try { if (Test-WorkingSetOrdinal $a (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the expected grid.' } } finally { $script:GridRows-- }
    }
    # The control: a hash that takes out the plain directory but not its escaped form in the flood binding (the form
    # a real config holds) must fail the run-directory case.
    $hashControl = $hashText.Replace(".Replace(`$root.Replace('\', '\\'), '<run>')", '')
    if ([string]::Equals($hashControl, $hashText, [StringComparison]::Ordinal)) { throw 'The workload hash control changed nothing.' }
    $controlCaught = & {
        . ([scriptblock]::Create($hashControl))
        -not (Test-WorkingSetOrdinal (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a') (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configB 'D:\other\run-b'))
    }
    if (-not $controlCaught) { throw 'The run-directory case did not catch a hash that keeps the escaped directory.' }

    # Build admission, through the harness's own Get-WorkingSetMeasureBuild and the real measure library, with only
    # its git boundary replaced (as test/windows/interactive-win11-measure-contract.ps1 does), so HEAD resolves and each
    # case reaches the admission check (council round 1, Sol H1; CodeRabbit on #739):
    #   - a fixture generation with a matching receipt is admitted, and its receipt's head and hashes come back;
    #   - the same generation with its prefix noctty.exe changed is refused by the receipt check, by name;
    #   - a checkout whose only build is a plain zig-out\bin has no generation, and is refused for that, by name.
    $admissionText = Get-WorkingSetFunction 'Get-WorkingSetMeasureBuild'
    & {
        . (Join-Path $repoRoot 'scripts\interactive-win11-measure-lib.ps1')
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        function Get-Sha256([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
        . ([scriptblock]::Create($admissionText))
        . ([scriptblock]::Create((Get-WorkingSetFunction 'Get-BytesSha256')))
        . ([scriptblock]::Create((Get-WorkingSetFunction 'Read-WorkingSetPlainFile')))
        $wsFixtureHead = '1234567890123456789012345678901234567890'
        $wsFixtureOriginal = [Text.Encoding]::UTF8.GetBytes(("const std = @import(`"std`");`n" +
                "const aumid_wide = std.unicode.utf8ToUtf16LeStringLiteral(`"io.github.amanthanvi.noctty`");`n" +
                "pub const aumid_utf8 = `"io.github.amanthanvi.noctty`";`n" +
                "pub fn registerAumidDisplayName(alloc: std.mem.Allocator, portable: bool) void {`n    _ = alloc;`n    _ = portable;`n}`n"))
        $wsFixtureNotifier = [Text.Encoding]::UTF8.GetBytes('const aumid_utf16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");' + "`n" + 'win32_toast_winrt.WinrtToast.init(core_app.alloc, aumid_utf16)' + "`n")
        $archiveStream = [IO.MemoryStream]::new()
        $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($name in 'src/apprt/win32_aumid.zig', 'src/apprt/win32/app.zig') {
            $entryStream = $zip.CreateEntry($name).Open()
            $content = if ($name -eq 'src/apprt/win32/app.zig') { $wsFixtureNotifier } else { $wsFixtureOriginal }
            try { $entryStream.Write($content, 0, $content.Length) } finally { $entryStream.Dispose() }
        }
        $zip.Dispose()
        $wsFixtureArchive = $archiveStream.ToArray()
        $archiveStream.Dispose()
        # The git boundary: this fixture's HEAD, a clean checkout, its two identity sources and its archive.
        function Invoke-InteractiveWin11MeasureGit {
            param([string] $RepoRoot, [string[]] $Arguments)
            switch ($Arguments[0]) {
                'rev-parse' { return ,[Text.Encoding]::UTF8.GetBytes($wsFixtureHead) }
                'status' { return ,[byte[]]@() }
                'show' { if ($Arguments[1].EndsWith(':src/apprt/win32/app.zig')) { return ,$wsFixtureNotifier }; return ,$wsFixtureOriginal }
                'archive' { return ,$wsFixtureArchive }
                default { throw 'Unexpected fixture git operation.' }
            }
        }
        function New-WorkingSetFixtureCheckout([string] $Root) {
            [void][IO.Directory]::CreateDirectory((Join-Path $Root 'src\apprt\win32'))
            [IO.File]::WriteAllBytes((Join-Path $Root 'src\apprt\win32_aumid.zig'), $wsFixtureOriginal)
            [IO.File]::WriteAllBytes((Join-Path $Root 'src\apprt\win32\app.zig'), $wsFixtureNotifier)
        }
        # A generation the way Invoke-InteractiveWin11MeasureBuild leaves one, with synthetic app and CLI bytes.
        $measureRepo = Join-Path $hashDir 'measure-repo'
        New-WorkingSetFixtureCheckout $measureRepo
        $layout = Get-InteractiveWin11MeasureLayout $measureRepo -Head $wsFixtureHead
        [void][IO.Directory]::CreateDirectory($layout.Root)
        [IO.File]::WriteAllBytes($layout.Archive, $wsFixtureArchive)
        [IO.Compression.ZipFile]::ExtractToDirectory($layout.Archive, $layout.Source)
        $patched = Get-InteractiveWin11MeasurePatchedBytes $wsFixtureOriginal
        [IO.File]::WriteAllBytes((Join-Path $layout.Source 'src\apprt\win32_aumid.zig'), $patched)
        $sourceReceipt = [ordered]@{
            Schema = 2; Head = $wsFixtureHead; Patch = 'aumid-isolate-product-toast-v2'; NotifierAumid = 'io.github.amanthanvi.noctty'
            ArchiveSHA256 = Get-InteractiveWin11MeasureHash $wsFixtureArchive
            OriginalAumidSHA256 = Get-InteractiveWin11MeasureHash $wsFixtureOriginal; PatchedAumidSHA256 = Get-InteractiveWin11MeasureHash $patched
            OriginalNotifierSHA256 = Get-InteractiveWin11MeasureHash $wsFixtureNotifier; MeasuredNotifierSHA256 = Get-InteractiveWin11MeasureHash $wsFixtureNotifier
        }
        [IO.File]::WriteAllText($layout.SourceReceipt, ($sourceReceipt | ConvertTo-Json))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $layout.Exe))
        [IO.File]::WriteAllText($layout.Exe, 'synthetic measurement app')
        [IO.File]::WriteAllText($layout.Cli, 'synthetic measurement CLI')
        $receipt = [ordered]@{
            Schema = 3; State = 'complete'; Head = $wsFixtureHead; RepoRoot = $layout.Repo
            BuildArguments = (Get-InteractiveWin11MeasureBuildArguments 'ReleaseFast') -join ' '
            Aumid = 'io.github.amanthanvi.noctty.measure'; Patch = $sourceReceipt.Patch; NotifierAumid = $sourceReceipt.NotifierAumid
            ArchiveSHA256 = $sourceReceipt.ArchiveSHA256; OriginalAumidSHA256 = $sourceReceipt.OriginalAumidSHA256
            PatchedAumidSHA256 = $sourceReceipt.PatchedAumidSHA256; OriginalNotifierSHA256 = $sourceReceipt.OriginalNotifierSHA256
            MeasuredNotifierSHA256 = $sourceReceipt.MeasuredNotifierSHA256
            SourceReceiptSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.SourceReceipt))
            Optimize = 'ReleaseFast'; ExePath = $layout.Exe; ExeSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.Exe))
            CliPath = $layout.Cli; CliSHA256 = Get-InteractiveWin11MeasureHash ([IO.File]::ReadAllBytes($layout.Cli))
        }
        [IO.File]::WriteAllText($layout.Receipt, ($receipt | ConvertTo-Json))

        $admitted = Get-WorkingSetMeasureBuild $measureRepo
        if (-not (Test-WorkingSetOrdinal $admitted.Head $wsFixtureHead) -or -not (Test-WorkingSetOrdinal $admitted.ExeSha256 $receipt.ExeSHA256) -or -not (Test-WorkingSetOrdinal $admitted.CliSha256 $receipt.CliSHA256) -or
            -not (Test-WorkingSetOrdinal $admitted.Optimize 'ReleaseFast') -or -not (Test-WorkingSetOrdinal $admitted.ReceiptSha256 (Get-Sha256 $layout.Receipt)) -or -not [string]::Equals($admitted.Bin, (Split-Path -Parent $layout.Exe), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The harness did not admit a measurement generation with a matching receipt, or returned another build.'
        }

        # Sol's round-4 case: the receipt is replaced after the library's admission passed. The harness refuses (or
        # would name the admitted receipt); the control, the harness as it was (fields read after the admission),
        # names the replacement.
        $admittedReceiptJson = [IO.File]::ReadAllText($layout.Receipt)
        $replacementJson = $admittedReceiptJson.Replace($wsFixtureHead, ('f' * 40))
        $realAssert = ${function:Assert-InteractiveWin11MeasureBuild}
        function Assert-InteractiveWin11MeasureBuild { param($RepoRoot, $ExePath) & $realAssert -RepoRoot $RepoRoot -ExePath $ExePath; [IO.File]::WriteAllText($layout.Receipt, $replacementJson) }
        $swapped = $null; $swapError = $null
        try { $swapped = Get-WorkingSetMeasureBuild $measureRepo } catch { $swapError = $_.Exception.Message }
        if ($null -ne $swapped -and -not (Test-WorkingSetOrdinal $swapped.Head $wsFixtureHead)) { throw 'A receipt replaced after admission reached the harness''s build record.' }
        if ($null -eq $swapped -and -not (Test-WorkingSetOrdinal $swapError 'The measurement receipt changed during admission.')) { throw "A receipt replaced after admission was refused for another reason (got: $swapError)." }
        [IO.File]::WriteAllText($layout.Receipt, $admittedReceiptJson)
        $oldAdmission = $admissionText.Replace('$receipt = [Text.Encoding]::UTF8.GetString($receiptBytes)', '$receipt = [Text.Encoding]::UTF8.GetString($receiptAfter)').Replace(
            'if (-not [string]::Equals([Convert]::ToBase64String($receiptBytes), [Convert]::ToBase64String($receiptAfter), [StringComparison]::Ordinal)) { throw', 'if ($false) { throw')
        if ([string]::Equals($oldAdmission, $admissionText, [StringComparison]::Ordinal)) { throw 'The receipt-swap control changed nothing.' }
        $oldSwapped = & { . ([scriptblock]::Create($oldAdmission)); Get-WorkingSetMeasureBuild $measureRepo }
        if (-not (Test-WorkingSetOrdinal $oldSwapped.Head ('f' * 40))) { throw 'The receipt-swap control did not take the replacement, so the case shows nothing.' }
        [IO.File]::WriteAllText($layout.Receipt, $admittedReceiptJson)
        Set-Item -Path function:Assert-InteractiveWin11MeasureBuild -Value $realAssert

        # Sol's round-5 case: build.json a file symlink to a valid receipt whose target is held open exclusively. The
        # harness refuses at the path check, with the library's own message, before anything opens it (an open of the
        # target would fail on the exclusive hold instead), and the no-follow read refuses the link itself. The
        # control, round 4's order (read the receipt, then check its path), opens the target and fails on the hold.
        $linkTarget = Join-Path $hashDir 'receipt-target.json'
        [IO.File]::WriteAllText($linkTarget, $admittedReceiptJson)
        [IO.File]::Delete($layout.Receipt)
        $script:wsReceiptLinkCase = 'receipt link (refused at the path check before any read; the no-follow read refuses the link; control; BY_HANDLE_FILE_INFORMATION''s 13 offsets, with a swapped-field control)'
        try { [void](New-Item -ItemType SymbolicLink -Path $layout.Receipt -Target $linkTarget -ErrorAction Stop) } catch { $script:wsReceiptLinkCase = 'receipt link skipped (no symlink privilege here)' }
        if (Test-Path -LiteralPath $layout.Receipt) {
            $hold = [IO.File]::Open($linkTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
            try {
                $linkError = $null
                try { [void](Get-WorkingSetMeasureBuild $measureRepo) } catch { $linkError = $_.Exception.Message }
                if (-not (Test-WorkingSetOrdinal $linkError 'Measurement paths must not contain reparse points.')) { throw "A symlinked build.json was not refused at the path check before any read (got: $linkError)." }
                $handleError = $null
                try { [void](Read-WorkingSetPlainFile $layout.Receipt) } catch { $handleError = $_.Exception.Message }
                if ($null -eq $handleError -or -not $handleError.Contains('The opened file is a reparse point.')) { throw "The no-follow read did not refuse the symlinked build.json itself (got: $handleError)." }
                $oldOrder = $admissionText.Replace("        Assert-InteractiveWin11MeasurePlainPath `$layout.Receipt`n", '').Replace('$receiptBytes = Read-WorkingSetPlainFile $layout.Receipt', '$receiptBytes = [IO.File]::ReadAllBytes($layout.Receipt)')
                if ([string]::Equals($oldOrder, $admissionText, [StringComparison]::Ordinal)) { throw 'The receipt-link control changed nothing.' }
                $oldError = $null
                try { & { . ([scriptblock]::Create($oldOrder)); [void](Get-WorkingSetMeasureBuild $measureRepo) } } catch { $oldError = $_.Exception.Message }
                if (Test-WorkingSetOrdinal $oldError 'Measurement paths must not contain reparse points.') { throw 'The receipt-link control was refused at the path check anyway, so the case shows nothing.' }
            } finally { $hold.Dispose() }
            [IO.File]::Delete($layout.Receipt)
        }
        [IO.File]::WriteAllText($layout.Receipt, $admittedReceiptJson)
        # The no-follow read's struct is the SDK's (fileapi.h BY_HANDLE_FILE_INFORMATION on x64, no pshpack, FILETIME
        # as two DWORDs): its size and every field's offset, and the harness's run-time literal is this one (Greptile on
        # #739). The control, the same source with two fields swapped, compiled under another name, must give another
        # layout.
        $plainLayoutWanted = 'ByHandle=52 attributes@0 createdLow@4 createdHigh@8 accessedLow@12 accessedHigh@16 writtenLow@20 writtenHigh@24 volume@28 sizeHigh@32 sizeLow@36 links@40 indexHigh@44 indexLow@48'
        if (-not (Test-WorkingSetOrdinal ([WorkingSetPlainRead]::Layout()) $plainLayoutWanted)) { throw "BY_HANDLE_FILE_INFORMATION's mirror is $([WorkingSetPlainRead]::Layout()), not the SDK's." }
        $plainReadText = Get-WorkingSetFunction 'Read-WorkingSetPlainFile'
        if (-not $plainReadText.Contains("`$wantLayout = '$plainLayoutWanted'")) { throw 'The harness''s run-time BY_HANDLE_FILE_INFORMATION layout is not the pinned one.' }
        $plainSource = [regex]::Match($plainReadText, "(?s)@'\r?\n(.*?)\r?\n'@").Groups[1].Value
        $plainControl = $plainSource.Replace('public uint volume, sizeHigh, sizeLow,', 'public uint volume, sizeLow, sizeHigh,')
        if ([string]::Equals($plainControl, $plainSource, [StringComparison]::Ordinal)) { throw 'The BY_HANDLE_FILE_INFORMATION control changed nothing.' }
        $plainControlClass = 'WorkingSetPlainReadControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Add-Type -TypeDefinition ($plainControl.Replace('public static class WorkingSetPlainRead', "public static class $plainControlClass"))
        if (Test-WorkingSetOrdinal (($plainControlClass -as [type])::Layout()) $plainLayoutWanted) { throw 'The BY_HANDLE_FILE_INFORMATION layout check accepted two swapped fields.' }

        [IO.File]::WriteAllText($layout.Exe, 'another app')
        $tampered = $null
        try { [void](Get-WorkingSetMeasureBuild $measureRepo) } catch { $tampered = $_.Exception.Message }
        if (-not (Test-WorkingSetOrdinal $tampered 'Measurement build receipt does not match HEAD, source patch, or executable.')) {
            throw "A changed measurement app was not refused by the receipt check (got: $tampered)."
        }

        $plainRepo = Join-Path $hashDir 'plain-repo'
        New-WorkingSetFixtureCheckout $plainRepo
        [void][IO.Directory]::CreateDirectory((Join-Path $plainRepo 'zig-out\bin'))
        foreach ($file in 'noctty.exe', 'noctty.com') { [IO.File]::WriteAllBytes((Join-Path $plainRepo "zig-out\bin\$file"), [byte[]](0x4d, 0x5a)) }
        $plain = $null
        try { [void](Get-WorkingSetMeasureBuild $plainRepo) } catch { $plain = $_.Exception.Message }
        $plainGeneration = (Get-InteractiveWin11MeasureLayout $plainRepo -Head $wsFixtureHead).Root
        if ($null -eq $plain -or -not $plain.Contains($plainGeneration)) {
            throw "A checkout with only a plain zig-out build was not refused for its missing measurement generation (got: $plain)."
        }
    }
} finally { [IO.Directory]::Delete($hashDir, $true) }

# The run's placement, against a real git checkout (CodeRabbit on #739): a -Run inside it that git does not ignore is
# refused, by message; one git ignores and one outside the checkout pass. The control, a check that never asks git,
# must accept the first, so the case is shown to catch it.
$placementText = Get-WorkingSetFunction 'Assert-WorkingSetRunPlacement'
$placementDir = Join-Path ([IO.Path]::GetTempPath()) ('ws-placement-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($placementDir)
try {
    $placementRepo = Join-Path $placementDir 'repo'
    [void][IO.Directory]::CreateDirectory($placementRepo)
    & git -C $placementRepo init -q 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'git init failed for the run-placement fixture.' }
    [IO.File]::WriteAllText((Join-Path $placementRepo '.gitignore'), "/ws-ignored-runs/`n")
    $unignoredRun = Join-Path $placementRepo 'ws-placement-runs\ws-1'
    $refusal = '-Run is inside -MeasureRepo and git does not ignore it; choose a -Run outside the checkout or in a directory git ignores.'
    & {
        . ([scriptblock]::Create($placementText))
        $got = $null
        try { Assert-WorkingSetRunPlacement $unignoredRun $placementRepo } catch { $got = $_.Exception.Message }
        if (-not (Test-WorkingSetOrdinal $got $refusal)) { throw "A -Run inside the checkout that git does not ignore was not refused (got: $got)." }
        Assert-WorkingSetRunPlacement (Join-Path $placementRepo 'ws-ignored-runs\ws-1') $placementRepo
        Assert-WorkingSetRunPlacement (Join-Path $placementDir 'outside\ws-1') $placementRepo
    }
    $placementControl = $placementText.Replace('if ($LASTEXITCODE -ne 0) { throw', 'if ($false) { throw')
    if ([string]::Equals($placementControl, $placementText, [StringComparison]::Ordinal)) { throw 'The run-placement control changed nothing.' }
    $controlAccepted = & {
        . ([scriptblock]::Create($placementControl))
        try { Assert-WorkingSetRunPlacement $unignoredRun $placementRepo; $true } catch { $false }
    }
    if (-not $controlAccepted) { throw 'The run-placement control refused the run anyway, so the case shows nothing.' }
} finally { [IO.Directory]::Delete($placementDir, $true) }

# The staged config, byte for byte (Sol, round 2): the generator's own output passes; with an initial-command, a second
# command in the no-space spelling, or its keybind = clear dropped, it fails. The control, a check that compares
# nothing, must accept the initial-command one.
$configDir = Join-Path ([IO.Path]::GetTempPath()) ('ws-config-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($configDir)
try {
    $configRun = Join-Path $configDir 'run-1'
    $generatorText = Get-WorkingSetFunction 'New-WorkingSetConfigText'
    $configCheckText = Get-WorkingSetFunction 'Test-WorkingSetConfigBytes'
    $configCases = & {
        . ([scriptblock]::Create($generatorText))
        . ([scriptblock]::Create($configCheckText))
        $generated = New-WorkingSetConfigText 'session-capture' $configRun
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $cases = [ordered]@{
            exact = $generated
            initialCommand = $generated + "initial-command = direct:$cmdPath /D /C exit`n"
            secondCommand = $generated + "command=direct:$cmdPath /D /K echo`n"
            noClear = $generated.Replace("keybind = clear`n", '')
        }
        $verdicts = [ordered]@{}
        foreach ($name in $cases.Keys) {
            $path = Join-Path $configDir "$name.ghostty"
            [IO.File]::WriteAllText($path, $cases[$name], $script:Utf8)
            $verdicts[$name] = Test-WorkingSetConfigBytes $path 'session-capture' $configRun
        }
        $verdicts.otherRun = Test-WorkingSetConfigBytes (Join-Path $configDir 'exact.ghostty') 'session-capture' (Join-Path $configDir 'run-2')
        $verdicts
    }
    if (-not $configCases.exact) { throw 'The generator''s own config failed its byte check.' }
    foreach ($name in 'initialCommand', 'secondCommand', 'noClear', 'otherRun') { if ($configCases[$name]) { throw "The config byte check accepted a staged config with $name." } }
    $configControl = $configCheckText.Replace('return [string]::Equals($staged, $expected, [StringComparison]::Ordinal)', 'return $true')
    if ([string]::Equals($configControl, $configCheckText, [StringComparison]::Ordinal)) { throw 'The config control changed nothing.' }
    $configControlAccepted = & {
        . ([scriptblock]::Create($generatorText))
        . ([scriptblock]::Create($configControl))
        Test-WorkingSetConfigBytes (Join-Path $configDir 'initialCommand.ghostty') 'session-capture' $configRun
    }
    if (-not $configControlAccepted) { throw 'The config control refused the initial-command config anyway, so the case shows nothing.' }

    # A run path cmd would expand or reinterpret (%USERNAME%, &, ^) is handled literally (CodeRabbit on #739): it
    # appears only as the working-directory value, and no keybind (F5's typed text among them) carries any of it. The
    # control, the earlier binding that typed the quoted path, must fail.
    function Test-WorkingSetRunPathLiteral([string] $Generator, [string] $Run) {
        $text = & { . ([scriptblock]::Create($Generator)); New-WorkingSetConfigText 'fixed' $Run }
        $lines = @($text -split "`n" | Where-Object { $_ })
        $carrying = @($lines | Where-Object { $_.Contains('%USERNAME%') -or $_.Contains('a&b^c') })
        return $carrying.Count -eq 1 -and (Test-WorkingSetOrdinal $carrying[0] "working-directory = $(Join-Path $Run 'work')")
    }
    $metaRun = Join-Path $configDir 'a&b^c\%USERNAME%\run-1'
    if (-not (Test-WorkingSetRunPathLiteral $generatorText $metaRun)) { throw 'A run path with %USERNAME%, & and ^ reached a command line in the config.' }
    $pathControl = $generatorText.Replace("`$floodText = '.\\flood.cmd\r'", "`$floodText = '\`"' + (Join-Path `$work 'flood.cmd').Replace('\', '\\') + '\`"\r'")
    if ([string]::Equals($pathControl, $generatorText, [StringComparison]::Ordinal)) { throw 'The run-path control changed nothing.' }
    if (Test-WorkingSetRunPathLiteral $pathControl $metaRun) { throw 'The run-path case accepted the binding that types the path.' }

    # The generator's first-pane command, pinned here independently of the generator (Sol, round 3): its config sets
    # exactly one command, System32's cmd.exe run directly with /D, and no initial-command, in any spelling. The
    # control, a generator that adds an initial-command, must fail.
    $allWorkloads = @('fixed', 'scrollback-default', 'scrollback-max', 'uia-walk', 'session-capture', 'tab-churn')
    function Test-WorkingSetGeneratedCommand([string] $Generator) {
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        foreach ($workload in $allWorkloads) {
            $text = & { . ([scriptblock]::Create($Generator)); New-WorkingSetConfigText $workload $configRun }
            $commands = @($text -split "`n" | Where-Object { $_ -match '^\s*(initial-)?command\s*=' })
            if ($commands.Count -ne 1 -or -not (Test-WorkingSetOrdinal $commands[0] "command = direct:$cmdPath /D")) { return $false }
        }
        return $true
    }
    if (-not (Test-WorkingSetGeneratedCommand $generatorText)) { throw 'The generated config does not set exactly System32''s cmd.exe with /D, or it sets an initial-command.' }
    $commandControl = $generatorText.Replace("        'keybind = clear'`n", "        'initial-command = direct:C:\Windows\System32\cmd.exe /D /C exit'`n        'keybind = clear'`n")
    if ([string]::Equals($commandControl, $generatorText, [StringComparison]::Ordinal)) { throw 'The generated-command control changed nothing.' }
    if (Test-WorkingSetGeneratedCommand $commandControl) { throw 'The generated-command check accepted a generator that adds an initial-command.' }
    $commandControlOne = $generatorText.Replace("        'keybind = clear'`n", "        if (`$Workload -eq 'uia-walk') { 'initial-command = direct:C:\Windows\System32\cmd.exe /D /C exit' }`n        'keybind = clear'`n")
    if (Test-WorkingSetGeneratedCommand $commandControlOne) { throw 'The generated-command check accepted a uia-walk-only initial-command (Opus n2).' }

    # The generator's whole output for a fixed run, against a config built here independently (Opus, round 3): any
    # changed line fails. The controls are Opus's generator mutations, an initial-command /K echo and renderer = d3d11.
    function Get-WorkingSetExpectedConfig([string] $Workload, [string] $Run) {
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $lines = [Collections.Generic.List[string]]@(
            "command = direct:$cmdPath /D", 'auto-update = off', 'confirm-close-surface = false', 'desktop-notifications = false',
            'clipboard-read = deny', 'clipboard-write = deny', 'copy-on-select = false', 'window-width = 140', 'window-height = 45',
            "window-save-state-scrollback = $(if ($Workload -eq 'session-capture') { 10000 } else { 0 })",
            "working-directory = $(Join-Path $Run 'work')", 'keybind = clear')
        foreach ($binding in @('f2=new_tab', 'f5=text:.\\flood.cmd\r', 'f6=close_surface', 'f7=close_tab')) {
            foreach ($chord in @('', 'shift+', 'ctrl+', 'alt+', 'ctrl+shift+', 'alt+shift+', 'ctrl+alt+', 'ctrl+alt+shift+')) { $lines.Add("keybind = $chord$binding") }
        }
        return ($lines -join "`n") + "`n"
    }
    function Test-WorkingSetGeneratorOutput([string] $Generator) {
        foreach ($workload in $allWorkloads) {
            $got = & { . ([scriptblock]::Create($Generator)); New-WorkingSetConfigText $workload $configRun }
            if (-not (Test-WorkingSetOrdinal $got (Get-WorkingSetExpectedConfig $workload $configRun))) { return $false }
        }
        return $true
    }
    if (-not (Test-WorkingSetGeneratorOutput $generatorText)) { throw 'The config generator''s output is not the pinned config.' }
    foreach ($mutant in @(
            @{ Name = 'an initial-command /K echo line (Opus c1)'; Text = $generatorText.Replace("        'keybind = clear'`n", "        `"initial-command = direct:`$cmdPath /K echo`"`n        'keybind = clear'`n") }
            @{ Name = 'renderer = d3d11 (Opus c2)'; Text = $generatorText.Replace("        'keybind = clear'`n", "        'renderer = d3d11'`n        'keybind = clear'`n") }
            @{ Name = 'a tab-churn-only renderer = d3d11 (Opus n1)'; Text = $generatorText.Replace("        'keybind = clear'`n", "        if (`$Workload -eq 'tab-churn') { 'renderer = d3d11' }`n        'keybind = clear'`n") }
            @{ Name = 'a soft hyphen in tab-churn''s auto-update value (Sol, round 5)'; Text = $generatorText.Replace("        'auto-update = off'`n", "        `$(if (`$Workload -eq 'tab-churn') { `"auto-update = o`$([char]0x00AD)ff`" } else { 'auto-update = off' })`n") }
            @{ Name = 'a soft hyphen in desktop-notifications (Opus g1)'; Text = $generatorText.Replace("        'desktop-notifications = false'`n", "        `"desktop-notificati`$([char]0x00AD)ons = false`"`n") }
        )) {
        if ([string]::Equals($mutant.Text, $generatorText, [StringComparison]::Ordinal)) { throw "The generator control changed nothing: $($mutant.Name)." }
        if (Test-WorkingSetGeneratorOutput $mutant.Text) { throw "The pinned config accepted a generator with $($mutant.Name)." }
    }

    # The copy's exact argv (Sol, round 4): the expected list is pinned here as a literal, and an argv passes only when
    # it is exactly that list. An extra CLI initial-command (Sol's case), a malformed --config-default-files value
    # (fa<soft hyphen>lse, Sol's case), a second limit (Opus's m06b), the arguments reordered, or the config file
    # missing all fail. The control, the earlier containment check (each wanted argument present), must accept the
    # extra initial-command.
    $argvText = (Get-WorkingSetFunction 'Get-WorkingSetExpectedArgv') + "`n" + (Get-WorkingSetFunction 'Test-WorkingSetArgv')
    $configPath = Join-Path $configDir 'copy\config.ghostty'
    $argvCases = & {
        . ([scriptblock]::Create($argvText))
        $expected = Get-WorkingSetExpectedArgv 'C:\c\noctty.exe' 'noctty-interactive-x' 'never' $configPath 1073741824
        $literal = [string[]]@('C:\c\noctty.exe', '--linux-cgroup=always', '--linux-cgroup-hard-fail=true', '--windows-job-object-kill-on-close=true',
            '--single-instance=false', '--class=noctty-interactive-x', '--window-save-state=never', '--clipboard-read=deny', '--clipboard-write=deny',
            '--config-default-files=false', "--config-file=$configPath", '--scrollback-limit=1073741824')
        $softHyphen = [string][char]0x00AD
        [ordered]@{
            pinned = Test-WorkingSetArgv $expected $literal
            exact = Test-WorkingSetArgv $literal $expected
            extraInitialCommand = Test-WorkingSetArgv ([string[]]($literal[0..10] + '--initial-command=direct:C:\Windows\System32\cmd.exe /D /C exit' + $literal[11])) $expected
            malformedDefaultFiles = Test-WorkingSetArgv ([string[]]($literal[0..8] + "--config-default-files=fa$($softHyphen)lse" + $literal[10..11])) $expected
            secondLimit = Test-WorkingSetArgv ([string[]]($literal + '--scrollback-limit=10000000')) $expected
            reordered = Test-WorkingSetArgv ([string[]]($literal[0..9] + $literal[11] + $literal[10])) $expected
            noConfigFile = Test-WorkingSetArgv ([string[]]($literal[0..9] + $literal[11])) $expected
        }
    }
    if (-not $argvCases.pinned) { throw 'Get-WorkingSetExpectedArgv is not the pinned argument list.' }
    if (-not $argvCases.exact) { throw 'The exact-argv check refused the expected list.' }
    foreach ($name in 'extraInitialCommand', 'malformedDefaultFiles', 'secondLimit', 'reordered', 'noConfigFile') { if ($argvCases[$name]) { throw "The exact-argv check accepted an argv with $name." } }
    $containment = 'function Test-WorkingSetArgv([string[]] $Actual, [string[]] $Expected) { foreach ($wanted in $Expected) { if ($Actual -notcontains $wanted) { return $false } }; return $true }'
    $argvControlAccepted = & {
        . ([scriptblock]::Create((Get-WorkingSetFunction 'Get-WorkingSetExpectedArgv')))
        . ([scriptblock]::Create($containment))
        $expected = Get-WorkingSetExpectedArgv 'C:\c\noctty.exe' 'noctty-interactive-x' 'never' $configPath 1073741824
        Test-WorkingSetArgv ([string[]]($expected[0..10] + '--initial-command=direct:C:\Windows\System32\cmd.exe /D /C exit' + $expected[11])) $expected
    }
    if (-not $argvControlAccepted) { throw 'The containment control refused the extra initial-command anyway, so the case shows nothing.' }
    # The helper's arguments are the ones the expected list assumes (scripts/interactive-win11-lib.ps1).
    $launchLib = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1') -Raw
    foreach ($argument in '''--linux-cgroup=always''', '''--linux-cgroup-hard-fail=true''', '''--windows-job-object-kill-on-close=true''', '''--single-instance=false''', '"--class=noctty-interactive-$($Layout.SandboxId)"') {
        if (-not $launchLib.Contains($argument)) { throw "The launch helper no longer emits $argument, which the expected argv assumes." }
    }

    # Sol's round-3 case: an untouched config.ghostty beside a legacy ghostty/config that sets an initial-command must
    # not pass; nor a pre-rename winghostty/config.ghostty; a copy with only its generated config does. The results
    # are compared as joined strings (an empty result fails). The controls run these same assertions on mutated
    # functions and must fail them: Opus's s1 (the copy path pointed elsewhere) and s2 (the result indexed past its
    # end), and n9 (the list cut to ghostty\config).
    $strayText = Get-WorkingSetFunction 'Get-WorkingSetStrayConfigs'
    $strayCopy = Join-Path $configDir 'copy'
    [void][IO.Directory]::CreateDirectory((Join-Path $strayCopy 'ghostty'))
    [void][IO.Directory]::CreateDirectory((Join-Path $strayCopy 'winghostty'))
    [IO.File]::Copy((Join-Path $configDir 'exact.ghostty'), (Join-Path $strayCopy 'config.ghostty'))
    function Get-WorkingSetStrayProblems([string] $FunctionText) {
        $legacyFile = Join-Path $strayCopy 'ghostty\config'
        $renamedFile = Join-Path $strayCopy 'winghostty\config.ghostty'
        $override = "initial-command = direct:C:\Windows\System32\cmd.exe /D /C exit`n"
        $found = & {
            . ([scriptblock]::Create($FunctionText))
            $result = [ordered]@{ clean = (@(Get-WorkingSetStrayConfigs $strayCopy) -join ',') }
            [IO.File]::WriteAllText($legacyFile, $override)
            $result.legacy = @(Get-WorkingSetStrayConfigs $strayCopy) -join ','
            [IO.File]::Delete($legacyFile)
            [IO.File]::WriteAllText($renamedFile, $override)
            $result.renamed = @(Get-WorkingSetStrayConfigs $strayCopy) -join ','
            [IO.File]::Delete($renamedFile)
            $result
        }
        $problems = @()
        if (-not (Test-WorkingSetOrdinal $found.clean '')) { $problems += "clean copy refused ($($found.clean))" }
        if (-not (Test-WorkingSetOrdinal $found.legacy 'ghostty\config')) { $problems += "legacy ghostty/config gave '$($found.legacy)'" }
        if (-not (Test-WorkingSetOrdinal $found.renamed 'winghostty\config.ghostty')) { $problems += "winghostty/config.ghostty gave '$($found.renamed)'" }
        return $problems
    }
    $strayProblems = @(Get-WorkingSetStrayProblems $strayText)
    if ($strayProblems.Count -ne 0) { throw "The stray-config case failed: $($strayProblems -join '; ')." }
    $strayList = "@(@('ghostty\config', 'winghostty\config.ghostty') | Where-Object { Test-Path -LiteralPath (Join-Path `$Copy `$_) })"
    foreach ($mutant in @(
            @{ Name = 'the copy path pointed elsewhere (Opus s1)'; Text = $strayText.Replace("function Get-WorkingSetStrayConfigs([string] `$Copy) {", "function Get-WorkingSetStrayConfigs([string] `$Copy) {`n    `$Copy = Join-Path `$Copy 'nothing'") }
            @{ Name = 'the result indexed past its end (Opus s2)'; Text = $strayText.Replace("return $strayList", "return @($strayList[99..100])") }
            @{ Name = 'the list cut to ghostty\config (Opus n9)'; Text = $strayText.Replace("@('ghostty\config', 'winghostty\config.ghostty')", "@('ghostty\config')") }
        )) {
        if ([string]::Equals($mutant.Text, $strayText, [StringComparison]::Ordinal)) { throw "The stray-config control changed nothing: $($mutant.Name)." }
        if (@(Get-WorkingSetStrayProblems $mutant.Text).Count -eq 0) { throw "The stray-config case passed a function with $($mutant.Name)." }
    }
    # Leave the copy with the legacy file, as before, for nothing after this reads it.
    [IO.File]::WriteAllText((Join-Path $strayCopy 'ghostty\config'), "initial-command = direct:C:\Windows\System32\cmd.exe /D /C exit`n")
    # The list is the product's: file_load.zig's legacy paths, rooted at the portable root.
    $fileLoadZig = Get-Content -LiteralPath (Join-Path $repoRoot 'src\config\file_load.zig') -Raw
    if (-not $fileLoadZig.Contains('.subdir = "ghostty/config"') -or -not $fileLoadZig.Contains('.subdir = "winghostty/config.ghostty"')) { throw 'The stray-config list is not file_load.zig''s legacy paths.' }
} finally { [IO.Directory]::Delete($configDir, $true) }

# What the payload checks and the transport check read from the product: the session budget and overhead, the UIA
# history budget, and the two startup markers in src/pty.zig.
$sessionStateZig = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32_session_state.zig') -Raw
$uiaTextZig = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32_uia\text.zig') -Raw
$ptyZig = Get-Content -LiteralPath (Join-Path $repoRoot 'src\pty.zig') -Raw
if (-not $sessionStateZig.Contains('pub const max_total_scrollback_bytes: usize = 512 * 1024;') -or $script:SessionBudgetBytes -ne 512 * 1024) { throw 'The session budget is not the product''s max_total_scrollback_bytes.' }
if (-not $sessionStateZig.Contains("pub const scrollback_snapshot_storage_overhead: usize = $($script:SessionOverheadBytes);")) { throw 'The session overhead is not the product''s scrollback_snapshot_storage_overhead.' }
if (-not $uiaTextZig.Contains("pub const accessible_history_max_rows: usize = $($script:UiaHistoryMaxRows);")) { throw 'The UIA row cap is not the product''s accessible_history_max_rows.' }
if (-not $uiaTextZig.Contains('pub const accessible_history_target_cells: usize = 40_000;') -or $script:UiaHistoryCells -ne 40000) { throw 'The UIA cell budget is not the product''s accessible_history_target_cells.' }
if (-not $ptyZig.Contains('log.info("using bundled ConPTY: {s}"') -or -not $ptyZig.Contains('"using the in-box conhost')) { throw 'The transport markers are not the ones src/pty.zig logs.' }

} finally {
    foreach ($name in $savedScriptVars.Keys) {
        if ($savedScriptVars[$name].Existed) { Set-Variable -Scope Script -Name $name -Value $savedScriptVars[$name].Value }
        else { Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue }
    }
}

# The native layer: the harness's Add-Type source, compiled here under another class name, must give the SDK's x64
# layout string the harness checks at run time (psapi.h PROCESS_MEMORY_COUNTERS_EX2, processthreadsapi.h
# STARTUPINFOW and STARTUPINFOEXW, winnt.h JOBOBJECT_EXTENDED_LIMIT_INFORMATION, tlhelp32.h PROCESSENTRY32W,
# consoleapi2.h CONSOLE_SCREEN_BUFFER_INFO with COORD and SMALL_RECT). The controls (Greptile on #739): a changed field
# in each of the last two mirrors, compiled the same way, must give another layout.
$nativeSource = @($workingSetAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class WorkingSetNative' }, $true))
if ($nativeSource.Count -ne 1) { throw 'The working-set harness must hold one WorkingSetNative source.' }
$layoutWanted = [regex]::Match($workingSetText, "\`$script:SdkLayout = '([^']+)'").Groups[1].Value
if (-not (Test-WorkingSetOrdinal $layoutWanted 'MemoryCounters=96 peakWorkingSet@8 workingSet@16 privateUsage@72 sharedCommit@88 Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8')) {
    throw 'The working-set harness''s SDK layout string changed.'
}
$contractClass = 'WorkingSetNativeContract' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($nativeSource[0].Value.Replace('public static class WorkingSetNative', "public static class $contractClass"))
$layoutActual = ($contractClass -as [type])::Layout()
if (-not (Test-WorkingSetOrdinal $layoutActual $layoutWanted)) { throw "The working-set native layer's layout is $layoutActual, not the SDK's." }
$layoutControls = @(
    @{ Name = 'PROCESSENTRY32W with its heap id narrowed'; Old = 'public uint size, usage, processId; public IntPtr heapId;'; New = 'public uint size, usage, processId; public uint heapId;' }
    @{ Name = 'CONSOLE_SCREEN_BUFFER_INFO with its attributes widened'; Old = 'public Coord size, cursor; public ushort attributes;'; New = 'public Coord size, cursor; public uint attributes;' }
)
foreach ($control in $layoutControls) {
    $controlSource = $nativeSource[0].Value.Replace($control.Old, $control.New)
    if ([string]::Equals($controlSource, $nativeSource[0].Value, [StringComparison]::Ordinal)) { throw "The layout control changed nothing: $($control.Name)." }
    $controlClass = 'WorkingSetNativeControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Add-Type -TypeDefinition ($controlSource.Replace('public static class WorkingSetNative', "public static class $controlClass"))
    if (Test-WorkingSetOrdinal (($controlClass -as [type])::Layout()) $layoutWanted) { throw "The layout check accepted $($control.Name)." }
}

# The split the launch read-back uses (CommandLineToArgvW, compiled): a quoted argument with spaces comes back whole.
$splitProbe = @(($contractClass -as [type])::SplitCommandLine('"C:\a b\noctty.exe" --scrollback-limit=10000000 "--config-file=C:\a b\copy\config.ghostty" --config-default-files=false'))
if ($splitProbe.Count -ne 4 -or $splitProbe[0] -cne 'C:\a b\noctty.exe' -or $splitProbe[2] -cne '--config-file=C:\a b\copy\config.ghostty' -or $splitProbe[3] -cne '--config-default-files=false') {
    throw "SplitCommandLine did not split a command line as CommandLineToArgvW does (got $($splitProbe -join ' | '))."
}

# The launch desktop at run time (Opus, round 2): the compiled native layer refuses a child on any desktop but the
# caller's own and on Default or the input desktop, and the driver on the caller's own desktop, Default or the input
# desktop. Every call names an executable that does not exist, so a missing refusal fails with CreateProcess and
# still starts nothing. Where this process has no readable desktop (a service session), the case is skipped.
$desktopProbe = $contractClass -as [type]
$ownDesktop = $null
try { $ownDesktop = $desktopProbe::CurrentDesktopName() } catch { $ownDesktop = $null }
if ($null -ne $ownDesktop) {
    $launchDir = Join-Path ([IO.Path]::GetTempPath()) ('ws-launch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($launchDir)
    try {
        $missingExe = Join-Path $launchDir 'missing.exe'
        $launchLog = Join-Path $launchDir 'launch.log'
        function Get-LaunchRefusal([scriptblock] $Call) { try { & $Call; return 'launched' } catch { return $_.Exception.Message } }
        $foreign = 'WinSta0\ws-contract-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $got = Get-LaunchRefusal { $desktopProbe::Spawn($missingExe, '"x"', $launchDir, $foreign, $launchLog, $true) }
        if (-not $got.Contains("A child must start on the caller's own desktop")) { throw "Spawn did not refuse another desktop (got: $got)." }
        $got = Get-LaunchRefusal { $desktopProbe::Spawn($missingExe, '"x"', $launchDir, 'WinSta0\Default', $launchLog, $true) }
        if (-not ($got.Contains("A child must start on the caller's own desktop") -or $got.Contains('A child must not start on Default or the input desktop'))) { throw "Spawn did not refuse Default (got: $got)." }
        $got = Get-LaunchRefusal { $desktopProbe::LaunchDriver($missingExe, '"x"', $launchDir, 'WinSta0\Default', [IntPtr]::Zero) }
        if (-not $got.Contains('The driver must start on a private desktop')) { throw "LaunchDriver did not refuse Default (got: $got)." }
        $got = Get-LaunchRefusal { $desktopProbe::LaunchDriver($missingExe, '"x"', $launchDir, "WinSta0\$ownDesktop", [IntPtr]::Zero) }
        if (-not $got.Contains('The driver must start on a private desktop')) { throw "LaunchDriver did not refuse the caller's own desktop (got: $got)." }
        # The control: a private desktop's name passes the check and reaches CreateProcess, which fails on the
        # missing executable (when the input desktop cannot be read, LaunchDriver refuses that too).
        $got = Get-LaunchRefusal { $desktopProbe::LaunchDriver($missingExe, '"x"', $launchDir, $foreign, [IntPtr]::Zero) }
        $wantControl = if ($null -eq $desktopProbe::InputDesktopName()) { 'The driver must start on a private desktop' } else { 'CreateProcess failed' }
        if (-not $got.Contains($wantControl)) { throw "LaunchDriver's desktop check refused a private desktop, or launched (got: $got)." }
    } finally { [IO.Directory]::Delete($launchDir, $true) }
    $desktopCase = 'launch-desktop (Spawn: foreign, Default; LaunchDriver: Default, own; control: private)'
} else { $desktopCase = 'launch-desktop skipped (no readable desktop)' }
Write-Host "Working-set harness contract: $workingSetMutations rules, each with a rejected mutation; desktop, state-guard, settle, block, stage, verdict, workload-hash, admission (admitted, tampered, plain), run-placement (unignored, ignored, outside), config-bytes (exact, initial-command, second command, no clear, other run, a %USERNAME% run path), generated-command over all six workloads (Opus n2 among its controls), generator-output over all six workloads (Opus c1, c2, n1, g1 and Sol's soft hyphens), exact argv (pinned, exact, Sol's extra initial-command and malformed value, second limit, reordered, no config file; containment control), receipt swap (Sol's; control), $($script:wsReceiptLinkCase), command-line split, stray-config (Sol's legacy ghostty/config, winghostty, clean; Opus s1, s2, n9 controls) and $desktopCase cases; native layout $layoutActual"
