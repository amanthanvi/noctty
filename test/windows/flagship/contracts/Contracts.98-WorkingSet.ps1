# The working-set workloads (PLAN.md §3.5): test/windows/hidden-win11-working-set.ps1 runs one portable copy of the
# receipt-bound measurement build on a private desktop through one fixed workload and samples its memory. Pinned here:
# what the harness may do and that its run-time checks are called (patterns over its code with the comments removed,
# each with a mutation that must fail it, the council's round-1 mutations among them), the workload itself (its
# constants), its pure functions run on synthetic inputs with controls (the settle rule, the block counts, the
# required stages, the record verdict and the workload hash), its build admission (a repository with only a plain
# zig-out build is refused), the shared state guard's paths, and its native layer's struct layout (compiled and
# checked against the SDK's x64 sizes). No noctty is started.
$workingSetScript = Join-Path $repoRoot 'test\windows\hidden-win11-working-set.ps1'
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
        Pattern = '(?s)function Invoke-WorkingSetOuter \{\s+if \(-not \$Workload\) \{ throw ''Pass -Workload\.'' \}\s+\$build = Get-WorkingSetMeasureBuild \$MeasureRepo.*?if \(-not \(Test-WorkingSetCopy \$copy \$build\)\) \{ throw .*?\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @('if (-not (Test-WorkingSetCopy $copy $build)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'admission is Assert-InteractiveWin11MeasureBuild on the generation, then the prefix''s noctty.exe and noctty.com against the receipt''s hashes'
        Pattern = '(?s)function Get-WorkingSetMeasureBuild\(\[string\] \$Repo\) \{.*?\$exe = Get-InteractiveWin11MeasureExePath -RepoRoot \$Repo\s+Assert-InteractiveWin11MeasureBuild -RepoRoot \$Repo -ExePath \$exe.*?if \(\(Get-Sha256 \$exe\) -cne \[string\]\$receipt\.ExeSHA256 -or \(Get-Sha256 \$cli\) -cne \[string\]\$receipt\.CliSHA256\) \{\s+throw'
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
        Pattern = '(?s)''"\{0\}" \+version''.*?if \(\$record\.BuildMode -cne \$ExpectedBuildMode -or \$build\.Optimize -cne \$ExpectedBuildMode\) \{[^\r\n]*return 3 \}.*?\[WorkingSetNative\]::Spawn\(\$exe, \$commandLine'
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
        Pattern = '(?s)\$cmdPath = Join-Path \(\[Environment\]::GetFolderPath\(''System''\)\) ''cmd\.exe''\s+if \(\$configCommands\.Count -ne 1 -or \$configCommands\[0\] -cne "command = direct:\$cmdPath /D"\) \{ throw'
        Mutation = @('"command = direct:$cmdPath /D") { throw', '"command = direct:$cmdPath") { throw')
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
        Pattern = '(?s)foreach \(\$name in @\(''LOCALAPPDATA'', ''APPDATA'', ''TEMP'', ''TMP''\)\) \{\s+\$dir = \[string\]\$record\.EffectiveDirs\.\$name\s+if \(-not \$dir -or -not .*?StartsWith\(\$Run\.TrimEnd\(''\\''\) \+ ''\\'', \[StringComparison\]::OrdinalIgnoreCase\) -or \(\$realDirs -contains \$dir\.TrimEnd\(''\\''\)\)\) \{\s+\$failed \+= '
        Mutation = @(' -or ($realDirs -contains $dir.TrimEnd(''\''))', '')
    }
    @{
        Description = 'the driver is created suspended, with no console window and no priority flag (normal priority, never BELOW_NORMAL 0x4000), and assigned to the job before it runs'
        Pattern = '(?s)public static ProcessInfo LaunchDriver\(.*?CreateProcessW\(app, new StringBuilder\(command\), IntPtr\.Zero, IntPtr\.Zero, false, 0x08000004, .*?AssignProcessToJobObject\(job, pi\.process\) \|\| ResumeThread\(pi\.thread\)'
        Mutation = @('false, 0x08000004, IntPtr.Zero', 'false, 0x08004004, IntPtr.Zero')
    }
    @{
        Description = 'the driver itself measures at normal priority'
        Pattern = '\[Diagnostics\.Process\]::GetCurrentProcess\(\)\.PriorityClass = ''Normal'''
        Mutation = @("PriorityClass = 'Normal'", "PriorityClass = 'BelowNormal'")
    }
    @{
        Description = 'the copy runs at normal priority: its creation flags carry NORMAL_PRIORITY_CLASS, and a copy at any other priority fails the run'
        Pattern = '(?s)CreateProcessW\(app, new StringBuilder\(command\), IntPtr\.Zero, IntPtr\.Zero, true, 0x00080000 \| 0x20 \| \(noWindow \? 0x08000000u : 0u\), .*?if \(\$record\.NocttyPriority -cne ''Normal''\) \{ throw'
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
        Pattern = '(?s)\$sessionPath = Join-Path \$realLocal ''noctty\\session-state\.json''\s+\$sessionBefore = Get-Metadata \$sessionPath.*?\$sessionAfter = Get-Metadata \$sessionPath.*?SessionUnchanged = \$sessionBefore -ceq \$sessionAfter.*?if \(-not \$guards\.SessionUnchanged\) \{ \$failed \+= '
        Mutation = @("`$sessionPath = Join-Path `$realLocal 'noctty\session-state.json'", "`$sessionPath = Join-Path `$Run 'session-state.json'")
    }
    @{
        Description = 'the clipboard sequence number is recorded before and after each run'
        Pattern = '(?s)ClipboardSequenceBefore = \$stateGuard\.ClipboardBefore; ClipboardSequenceAfter = \[HiddenLocal\]::GetClipboardSequenceNumber\(\)'
        Mutation = @('ClipboardSequenceAfter = [HiddenLocal]::GetClipboardSequenceNumber()', 'ClipboardSequenceAfter = $stateGuard.ClipboardBefore')
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
        Pattern = '(?s)\$bindings = \[ordered\]@\{(?:(?!copy|paste)[^}])*\}.*?''auto-update = off''.*?''clipboard-read = deny''.*?''clipboard-write = deny''.*?''copy-on-select = false''.*?''keybind = clear''\s*foreach \(\$key in \$bindings\.Keys\) \{ foreach \(\$chord in \$chords\) \{ "keybind = \$chord\$key=\$\(\$bindings\[\$key\]\)" \} \}\s*\) \| Set-Content'
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
        Pattern = '(?s)\$sessionFile = Join-Path \$Bin ''session-state\.json''.*?if \(\$null -ne \$s -and \$s\.At -gt \$previous -and \$s\.Fixture -ge 1000 -and \$s\.Lines -le 10000\) \{'
        Mutation = @('$s.At -gt $previous -and ', '')
    }
    @{
        Description = 'the UIA walk is complete only when it ended, the document holds the last block''s last line, and it covered the history rows (council round 1)'
        Pattern = '(?s)walk_complete = \(\$ended -and \$holdsFixture -and \$lines -ge \$historyRows\)'
        Mutation = @('$ended -and $holdsFixture -and $lines -ge $historyRows', '$ended')
    }
    @{
        Description = 'the UIA client takes the pane from this copy''s own window handle'
        Pattern = '\$element = \[System\.Windows\.Automation\.AutomationElement\]::FromHandle\(\$base\)'
        Mutation = @('FromHandle($base)', 'RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)')
    }
    @{
        Description = 'each run records the workload''s hash over the workload, its limit, its blocks, the block, the flood batch file and the config'
        Pattern = '(?s)\$record\.BlocksPlanned = Get-WorkloadBlocks \$Workload \$ScrollbackMaxBytes\s+\$record\.WorkloadSha256 = Get-WorkloadSha256 \$Workload \$record\.ScrollbackLimitBytes \$record\.BlocksPlanned \$record\.BlockSha256 \$record\.FloodSha256 \(Join-Path \$Bin ''config\.ghostty''\) \$Run'
        Mutation = @('$record.BlockSha256 $record.FloodSha256', '$record.BlockSha256 ''0''')
    }
    # --- the native layer
    @{
        Description = 'the mirrored structs are checked against the SDK''s x64 sizes and offsets before anything runs (AGENTS.md "Win32 FFI")'
        Pattern = '(?s)if \(\[WorkingSetNative\]::Layout\(\) -cne \$script:SdkLayout\) \{ throw'
        Mutation = @('if ([WorkingSetNative]::Layout() -cne $script:SdkLayout) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a count whose query failed is published as unavailable (-1, then null), never 0'
        Pattern = '(?s)long handleCount = GetProcessHandleCount\(process, out handles\) \? \(long\)handles : -1;.*?Marshal\.SetLastPInvokeError\(0\);\s+uint v = GetGuiResources\(process, kind\);\s+return v == 0 && Marshal\.GetLastPInvokeError\(\) != 0 \? -1 : \(long\)v;.*?handles = \$\(if \(\$v\[4\] -lt 0\) \{ \$null \} else \{ \$v\[4\] \}\)'
        Mutation = @('? (long)handles : -1;', '? (long)handles : 0;')
    }
)
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
$constantNames = @('BlockLines', 'RowPageBytes', 'Cols', 'Rows', 'GridRows', 'FixedCycles', 'ChurnCycles', 'SessionCheckpoints', 'PruneSeconds', 'SettleSamples', 'SampleMs', 'SettleCapMs')
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
    if ((@(Get-WorkloadStages 'scrollback-max' 48) -join ',') -cne 'start,block-8,block-16,block-24,block-32,block-40,block-48,after') { throw 'scrollback-max''s stages changed.' }
    if ((@(Get-WorkloadStages 'scrollback-default' 4) -join ',') -cne 'start,block-1,block-2,block-3,block-4,after') { throw 'scrollback-default''s stages changed.' }
    foreach ($name in 'fixed', 'tab-churn') { if ((@(Get-WorkloadStages $name 0) -join ',') -cne 'start,after') { throw "$name's stages changed." } }
    foreach ($name in 'uia-walk', 'session-capture') { if ((@(Get-WorkloadStages $name 4) -join ',') -cne 'start,filled,after') { throw "$name's stages changed." } }
}

# The record verdict: a complete synthetic record of each workload passes; each control (council round 1: a removed
# after stage, an unsettled stage, a stage off the base pane, the wrong grid, no close that took, a non-zero exit, a
# missed block, a short session or an incomplete UIA walk) must give a problem.
$problemsText = Get-WorkingSetFunction 'Get-WorkingSetRecordProblems'
& {
    . ([scriptblock]::Create($blocksText))
    . ([scriptblock]::Create($stagesText))
    . ([scriptblock]::Create($problemsText))
    function New-WorkingSetRecord([string] $Name) {
        $limit = if ($Name -eq 'scrollback-max') { 1073741824 } else { 10000000 }
        $blocks = Get-WorkloadBlocks $Name $limit
        $cycles = switch ($Name) { 'fixed' { 20 } 'tab-churn' { 50 } 'session-capture' { 10 } default { 0 } }
        $stages = @(Get-WorkloadStages $Name $blocks | ForEach-Object { [pscustomobject]@{ name = $_; settled = -not $_.StartsWith('block-'); base_pane_only = $true } })
        return [pscustomobject]@{
            Schema = 2; Workload = $Name; Error = $null; Exit = 0; QuitPosts = 1; GridCols = 140; GridRows = 43
            ScrollbackLimitBytes = $limit; Blocks = $blocks; BlocksPlanned = $blocks; Cycles = $cycles; CyclesMissed = 0
            SessionSaves = $(if ($Name -eq 'session-capture') { 10 } else { 0 })
            Uia = $(if ($Name -eq 'uia-walk') { [pscustomobject]@{ walk_complete = $true } } else { $null })
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
        if ($a -cne (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configB 'D:\other\run-b\')) { throw 'The workload hash must not depend on the run''s directory.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configB 'D:\other')) { throw 'The workload hash took out more than the run''s directory.' }
        if ($a -ceq (Get-WorkloadSha256 'tab-churn' 10000000 1 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the workload.' }
        if ((Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' 'ff' $configA 'C:\run-a') -ceq (Get-WorkloadSha256 'scrollback-max' 2147483647 96 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the scrollback limit.' }
        if ((Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' 'ff' $configA 'C:\run-a') -ceq (Get-WorkloadSha256 'scrollback-max' 1073741824 47 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the planned blocks.' }
        if ((Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' 'ff' $configA 'C:\run-a') -ceq (Get-WorkloadSha256 'scrollback-max' 2147483647 48 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the scrollback limit at the same block count.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'ab' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the block.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'fe' $configA 'C:\run-a')) { throw 'The workload hash ignored the flood batch file.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configC 'C:\run-a')) { throw 'The workload hash ignored a config line.' }
        $script:FixedCycles++
        try { if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored a constant.' } } finally { $script:FixedCycles-- }
        $script:GridRows++
        try { if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a')) { throw 'The workload hash ignored the expected grid.' } } finally { $script:GridRows-- }
    }
    # The control: a hash that takes out the plain directory but not its escaped form in the flood binding (the form
    # a real config holds) must fail the run-directory case.
    $hashControl = $hashText.Replace(".Replace(`$root.Replace('\', '\\'), '<run>')", '')
    if ([string]::Equals($hashControl, $hashText, [StringComparison]::Ordinal)) { throw 'The workload hash control changed nothing.' }
    $controlCaught = & {
        . ([scriptblock]::Create($hashControl))
        (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configA 'C:\run-a') -cne (Get-WorkloadSha256 'fixed' 10000000 1 'aa' 'ff' $configB 'D:\other\run-b')
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
        if ($admitted.Head -cne $wsFixtureHead -or $admitted.ExeSha256 -cne $receipt.ExeSHA256 -or $admitted.CliSha256 -cne $receipt.CliSHA256 -or
            $admitted.Optimize -cne 'ReleaseFast' -or -not [string]::Equals($admitted.Bin, (Split-Path -Parent $layout.Exe), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The harness did not admit a measurement generation with a matching receipt, or returned another build.'
        }

        [IO.File]::WriteAllText($layout.Exe, 'another app')
        $tampered = $null
        try { [void](Get-WorkingSetMeasureBuild $measureRepo) } catch { $tampered = $_.Exception.Message }
        if ($tampered -cne 'Measurement build receipt does not match HEAD, source patch, or executable.') {
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
if ($layoutWanted -cne 'MemoryCounters=96 peakWorkingSet@8 workingSet@16 privateUsage@72 sharedCommit@88 Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8') {
    throw 'The working-set harness''s SDK layout string changed.'
}
$contractClass = 'WorkingSetNativeContract' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($nativeSource[0].Value.Replace('public static class WorkingSetNative', "public static class $contractClass"))
$layoutActual = ($contractClass -as [type])::Layout()
if ($layoutActual -cne $layoutWanted) { throw "The working-set native layer's layout is $layoutActual, not the SDK's." }
$layoutControls = @(
    @{ Name = 'PROCESSENTRY32W with its heap id narrowed'; Old = 'public uint size, usage, processId; public IntPtr heapId;'; New = 'public uint size, usage, processId; public uint heapId;' }
    @{ Name = 'CONSOLE_SCREEN_BUFFER_INFO with its attributes widened'; Old = 'public Coord size, cursor; public ushort attributes;'; New = 'public Coord size, cursor; public uint attributes;' }
)
foreach ($control in $layoutControls) {
    $controlSource = $nativeSource[0].Value.Replace($control.Old, $control.New)
    if ([string]::Equals($controlSource, $nativeSource[0].Value, [StringComparison]::Ordinal)) { throw "The layout control changed nothing: $($control.Name)." }
    $controlClass = 'WorkingSetNativeControl' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Add-Type -TypeDefinition ($controlSource.Replace('public static class WorkingSetNative', "public static class $controlClass"))
    if (($controlClass -as [type])::Layout() -ceq $layoutWanted) { throw "The layout check accepted $($control.Name)." }
}

Write-Host "Working-set harness contract: $workingSetMutations rules, each with a rejected mutation; desktop, state-guard, settle, block, stage, verdict, workload-hash and admission (admitted, tampered, plain) cases; native layout $layoutActual"
