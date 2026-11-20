# The working-set workloads (PLAN.md §3.5): test/windows/hidden-win11-working-set.ps1 runs one portable copy on a
# private desktop through one fixed workload and samples its memory. Pinned here: what the harness may do (patterns
# over its code with the comments removed, each with a mutation that must fail it), the workload itself (its
# constants, so a Phase 0a baseline and a later run measure the same thing), its settle rule and its workload hash
# (run on synthetic inputs, with controls), how many blocks each workload writes (from the harness's own constants),
# and its native layer's struct layout (compiled and checked against the SDK's x64 sizes). No noctty is started.
$workingSetScript = Join-Path $repoRoot 'test\windows\hidden-win11-working-set.ps1'

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

$workingSetRules = @(
    @{
        Description = 'the copy starts with the launch helper''s isolation (its own class, --single-instance=false), System32''s cmd.exe run directly with /D, and the clipboard denied on the command line'
        Pattern = '(?s)\$cmdPath = Join-Path \(\[Environment\]::GetFolderPath\(''System''\)\) ''cmd\.exe''\s*\$launchArguments = @\(Get-InteractiveWin11LaunchArguments -Layout \$layout -UseConfiguredCommand\) \+ @\(\s*"--command=direct:\$cmdPath /D", "--window-save-state=\$saveState", ''--clipboard-read=deny'', ''--clipboard-write=deny'','
        Mutation = @("'--clipboard-read=deny', '--clipboard-write=deny',", "'--clipboard-read=deny',")
    }
    @{
        Description = 'only the session-capture workload saves session state; every other runs with --window-save-state=never'
        Pattern = '\$saveState = if \(\$Workload -eq ''session-capture''\) \{ ''always'' \} else \{ ''never'' \}'
        Mutation = @("{ 'always' } else { 'never' }", "{ 'always' } else { 'default' }")
    }
    @{
        Description = 'the copy carries no noctty.ico (so it cannot create a missing AppUserModelId key) and no crash tree'
        Pattern = '(?s)Get-ChildItem -LiteralPath \$Bin -Force \| Where-Object \{ \$_\.Name -notin @\(''noctty\.ico'', ''crash'', ''ghostty''\) \}.*?if \(Test-Path -LiteralPath \(Join-Path \$copy ''noctty\.ico''\)\) \{ throw'
        Mutation = @("Where-Object { `$_.Name -notin @('noctty.ico', 'crash', 'ghostty') }", "Where-Object { `$_.Name -notin @('crash', 'ghostty') }")
    }
    @{
        Description = 'the copy is portable: the noctty.portable marker sits beside its exe'
        Pattern = '\[IO\.File\]::WriteAllText\(\(Join-Path \$copy ''noctty\.portable''\), ''''\)'
        Mutation = @("'noctty.portable'", "'portable.marker'")
    }
    @{
        Description = 'the build mode is checked through +version before the launch, and a mismatch launches nothing'
        Pattern = '(?s)''"\{0\}" \+version''.*?if \(\$record\.BuildMode -cne \$ExpectedBuildMode\) \{[^\r\n]*return 3 \}.*?\[WorkingSetNative\]::Spawn\(\$exe, \$commandLine'
        Mutation = @('not launched"; return 3 }', 'not launched" }')
    }
    @{
        Description = 'the driver refuses to run off its private desktop, and every process it starts names that desktop'
        Pattern = '(?s)if \(\[WorkingSetNative\]::CurrentDesktopName\(\) -cne \$DesktopName\) \{ throw .*?\$desktopPath = "WinSta0\\\$DesktopName".*?Spawn\(\$exe, \(''"\{0\}" \+version'' -f \$exe\), \$work, \$desktopPath,.*?Spawn\(\$exe, \$commandLine, \$work, \$desktopPath,'
        Mutation = @('$desktopPath = "WinSta0\$DesktopName"', '$desktopPath = "WinSta0\Default"')
    }
    @{
        Description = 'the driver starts on a new private desktop inside the owned job, with LOCALAPPDATA and APPDATA redirected into the run'
        Pattern = '(?s)\$desktopName = ''noctty-ws-'' \+ \[guid\]::NewGuid\(\).*?\$job = \[WorkingSetNative\]::CreateRunJob\(\).*?\$env:LOCALAPPDATA = Join-Path \$Run ''localappdata''; \$env:APPDATA = Join-Path \$Run ''appdata''.*?\[WorkingSetNative\]::LaunchDriver\(\$pwsh, \$line, \$Run, "WinSta0\\\$desktopName", \$job\)'
        Mutation = @("`$env:LOCALAPPDATA = Join-Path `$Run 'localappdata'; ", '')
    }
    @{
        Description = 'the driver is created suspended, with no console window and no priority flag (normal priority, never BELOW_NORMAL 0x4000), and assigned to the job before it runs'
        Pattern = '(?s)public static ProcessInfo LaunchDriver\(.*?CreateProcessW\(app, new StringBuilder\(command\), IntPtr\.Zero, IntPtr\.Zero, false, 0x08000004, .*?AssignProcessToJobObject\(job, pi\.process\) \|\| ResumeThread\(pi\.thread\)'
        Mutation = @('false, 0x08000004, IntPtr.Zero', 'false, 0x08004004, IntPtr.Zero')
    }
    @{
        Description = 'the run''s job kills its processes when closed and ends one on an unhandled exception, so a crash cannot wait in WER''s dialog, and SEM_NOGPFAULTERRORBOX is set before the copy is created (SOAK-01 trap 5)'
        Pattern = '(?s)public static IntPtr CreateRunJob\(\) \{.*?limits\.basic\.flags = 0x2000 \| 0x400;.*?\[WorkingSetNative\]::SetErrorMode\(\[WorkingSetNative\]::GetErrorMode\(\) -bor 2\).*?\[WorkingSetNative\]::Spawn\(\$exe, \$commandLine.*?\$job = \[WorkingSetNative\]::CreateRunJob\(\)'
        Mutation = @('limits.basic.flags = 0x2000 | 0x400;', 'limits.basic.flags = 0x2000;')
    }
    @{
        Description = 'the driver itself measures at normal priority'
        Pattern = '\[Diagnostics\.Process\]::GetCurrentProcess\(\)\.PriorityClass = ''Normal'''
        Mutation = @("PriorityClass = 'Normal'", "PriorityClass = 'BelowNormal'")
    }
    @{
        Description = 'the clipboard sequence number is recorded before and after each run'
        Pattern = '(?s)\$before = \[ordered\]@\{[^\r\n]*Clipboard = \[HiddenLocal\]::GetClipboardSequenceNumber\(\) \}.*?\$after = \[ordered\]@\{[^\r\n]*Clipboard = \[HiddenLocal\]::GetClipboardSequenceNumber\(\) \}.*?ClipboardSequenceBefore = \$before\.Clipboard; ClipboardSequenceAfter = \$after\.Clipboard'
        Mutation = @('ClipboardSequenceAfter = $after.Clipboard', 'ClipboardSequenceAfter = $before.Clipboard')
    }
    @{
        Description = 'the real startup ledger, jump list and PowerShell history are checked after the run, and a change fails it'
        Pattern = '(?s)StartupUnchanged = \$before\.Startup -ceq \$after\.Startup\s+SessionUnchanged = \$before\.Session -ceq \$after\.Session\s+JumpListUnchanged = \$before\.JumpList -ceq \$after\.JumpList\s+HistoryUnchanged = \$null -eq \$historyFailure\s.*?if \(-not \$guards\.StartupUnchanged\).*?if \(-not \$guards\.SessionUnchanged\).*?if \(-not \$guards\.JumpListUnchanged\).*?if \(\$historyFailure\).*?throw \(''working-set harness: '''
        Mutation = @('JumpListUnchanged = $before.JumpList -ceq $after.JumpList', 'JumpListUnchanged = $true')
    }
    @{
        Description = 'the real session-state.json is guarded by size and time, like the startup ledger (session-capture saves session state)'
        Pattern = '(?s)\$sessionPath = Join-Path \$realLocal ''noctty\\session-state\.json''.*?\$before = \[ordered\]@\{[^\r\n]*Session = Get-Metadata \$sessionPath;.*?\$after = \[ordered\]@\{[^\r\n]*Session = Get-Metadata \$sessionPath;'
        Mutation = @("`$sessionPath = Join-Path `$realLocal 'noctty\session-state.json'", "`$sessionPath = Join-Path `$Run 'session-state.json'")
    }
    @{
        Description = 'nothing in the harness uses real input, the foreground, the clipboard, Start-Process or a recursive delete'
        Pattern = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|BringWindowToTop|OpenClipboard|SetClipboardData|GetClipboardData|Set-Clipboard|Get-Clipboard|Start-Process|Invoke-Item|Remove-Item\b[^\r\n;|]*\s-Recurse\b))'
        Mutation = @('[WorkingSetNative]::Key($base, $nocttyPid, 0x74)', '[WorkingSetNative]::Key($base, $nocttyPid, 0x74); Set-Clipboard -Value x')
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
    @{
        Description = 'a block counts only when the acknowledgement file reaches its own number, written by the batch file after its output'
        Pattern = '(?s)if \(-not \(Wait-For \{ \(Get-FloodCount\) -ge \$Index \} 600000\)\) \{ throw.*?''@type "%~dp0block\.txt" && echo block>>"%~dp0flood-count\.txt"'''
        Mutation = @('(Get-FloodCount) -ge $Index', '(Get-FloodCount) -ge 0')
    }
    @{
        Description = 'the UIA client takes the pane from this copy''s own window handle'
        Pattern = '\$element = \[System\.Windows\.Automation\.AutomationElement\]::FromHandle\(\$base\)'
        Mutation = @('FromHandle($base)', 'RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)')
    }
    @{
        Description = 'a missed cycle, a missing session write, an incomplete walk or an unclean exit fails the run'
        Pattern = '(?s)if \(\$record\.CyclesMissed -gt 0\) \{ \$record\.Error = .*?if \(\$Workload -eq ''session-capture'' -and \$record\.SessionSaves -ne \$script:SessionCheckpoints\) \{ \$record\.Error = .*?if \(\$Workload -eq ''uia-walk'' -and -not \$record\.Uia\.walk_complete\) \{ \$record\.Error = .*?if \(\$record\.Exit -ne 0\) \{ \$record\.Error = .*?return \$\(if \(\$record\.Error\) \{ 1 \} else \{ 0 \}\)'
        Mutation = @('if ($record.CyclesMissed -gt 0) {', 'if ($false) {')
    }
    @{
        Description = 'the workload''s constants are the ones Phase 0a measured (a change is a new baseline, and changes WorkloadSha256)'
        Pattern = '(?s)\$script:BlockLines = 25000\s+\$script:RowPageBytes = 1120\s+\$script:Cols = 140\s+\$script:Rows = 45\s+\$script:FixedCycles = 20\s+\$script:ChurnCycles = 50\s+\$script:SessionCheckpoints = 10\s+\$script:PruneSeconds = 7\s+\$script:SettleSamples = 10\s+\$script:SampleMs = 500\s+\$script:SettleCapMs = 90000\s'
        Mutation = @('$script:FixedCycles = 20', '$script:FixedCycles = 19')
    }
    @{
        Description = 'every workload uses those constants: the cycle counts, the prune wait and the checkpoints'
        Pattern = '(?s)for \(\$i = 0; \$i -lt \$script:FixedCycles; \$i\+\+\) \{ Invoke-TabCycle \}\s+Wait-Pruned\s+Add-Stage ''after''.*?for \(\$i = 0; \$i -lt \$script:ChurnCycles; \$i\+\+\) \{ Invoke-TabCycle \}\s+Wait-Pruned\s+Add-Stage ''after''.*?for \(\$i = 0; \$i -lt \$script:SessionCheckpoints; \$i\+\+\) \{'
        Mutation = @('for ($i = 0; $i -lt $script:ChurnCycles; $i++)', 'for ($i = 0; $i -lt 5; $i++)')
    }
    @{
        Description = 'the output block is generated from the constants alone: 25,000 deterministic lines, every seventh in an SGR colour'
        Pattern = '(?s)function New-BlockText \{.*?for \(\$i = 0; \$i -lt \$script:BlockLines; \$i\+\+\) \{\s+\$text = ''ws line \{0:D6\} the quick brown fox jumps over the lazy dog 0123456789 abcdefghij'' -f \$i\s+if \(\$i % 7 -eq 0\)'
        Mutation = @("if (`$i % 7 -eq 0)", "if (`$i % 8 -eq 0)")
    }
    @{
        Description = 'a stage samples at the fixed cadence until Test-Settled or the cap, and a stage that never settled fails the run'
        Pattern = '(?s)function Add-Stage\(\[string\] \$Name\) \{.*?\$samples\.Add\(\(Read-Sample\)\)\s+if \(Test-Settled \$samples\.ToArray\(\)\) \{ break \}\s+Start-Sleep -Milliseconds \$script:SampleMs\s+\} while \(\$clock\.ElapsedMilliseconds - \$started -lt \$script:SettleCapMs\)\s+\$settled = Test-Settled \$samples\.ToArray\(\)\s+if \(-not \$settled\) \{ \$script:wsUnsettled \+= @\(\$Name\) \}.*?if \(\$script:wsUnsettled\.Count -gt 0\) \{ \$record\.Error = '
        Mutation = @('if (-not $settled) { $script:wsUnsettled += @($Name) }', '')
    }
    @{
        Description = 'after the last close the copy must be back to its one pane (bounded), not just 7 s older (SOAK-01 trap 2)'
        Pattern = '(?s)function Wait-Pruned \{\s+Start-Sleep -Seconds \$script:PruneSeconds\s+if \(-not \(Wait-For \{ @\(Get-AllSurfaces \$false\)\.Count -eq 1 \} 30000\)\) \{ throw'
        Mutation = @('@(Get-AllSurfaces $false).Count -eq 1 } 30000', '$true } 30000')
    }
    @{
        Description = 'the copy runs at normal priority: its creation flags carry NORMAL_PRIORITY_CLASS, and a copy at any other priority fails the run'
        Pattern = '(?s)CreateProcessW\(app, new StringBuilder\(command\), IntPtr\.Zero, IntPtr\.Zero, true, 0x00080000 \| 0x20, .*?if \(\$record\.NocttyPriority -cne ''Normal''\) \{ throw'
        Mutation = @('true, 0x00080000 | 0x20, IntPtr.Zero', 'true, 0x00080000 | 0x4000, IntPtr.Zero')
    }
    @{
        Description = 'no launch asks for BELOW_NORMAL_PRIORITY_CLASS or CREATE_DEFAULT_ERROR_MODE (which would drop the inherited SEM_NOGPFAULTERRORBOX)'
        Pattern = '(?s)\A(?!.*(?:0x04000000|0x00004000|0x4000[^0-9a-fA-F]))'
        Mutation = @('true, 0x00080000 | 0x20, IntPtr.Zero', 'true, 0x00080000 | 0x04000000 | 0x20, IntPtr.Zero')
    }
    @{
        Description = 'both native launches name their desktop in STARTUPINFO (a null lpDesktop puts the child on the user''s desktop)'
        Pattern = '(?s)public static ProcessInfo LaunchDriver\(string app, string command, string cwd, string desktop, IntPtr job\) \{\s+var si = new Startup \{ cb = Marshal\.SizeOf<Startup>\(\), desktop = desktop,.*?public static ProcessInfo Spawn\(string app, string command, string cwd, string desktop, string logPath\) \{.*?si\.info\.desktop = desktop;'
        Mutation = @('si.info.desktop = desktop;', 'si.info.desktop = null;')
    }
    @{
        Description = 'only one run at a time in the session (copies run together differ by tens of MiB, SOAK-01 trap 6)'
        Pattern = '(?s)\$script:wsMutex = \[Threading\.Mutex\]::new\(\$false, ''Local\\noctty-hidden-win11-working-set''\)\s+if \(-not \$script:wsMutex\.WaitOne\(0\)\) \{ throw'
        Mutation = @('if (-not $script:wsMutex.WaitOne(0)) { throw', 'if ($false) { throw')
    }
    @{
        Description = 'a -Bin that holds a used portable copy''s state is refused (its session would be restored, its startup ledger read)'
        Pattern = '(?s)\$used = @\(''session-state\.json'', ''startup-attempts\.json'', ''noctty\.portable'', ''config\.ghostty'', ''shell-integration'' \| Where-Object \{ Test-Path -LiteralPath \(Join-Path \$Bin \$_\) \}\)\s+if \(\$used\.Count -gt 0\) \{ throw'
        Mutation = @("'session-state.json', 'startup-attempts.json', ", '')
    }
    @{
        Description = 'each run records the workload''s hash, so a comparison can refuse runs of another workload'
        Pattern = '(?s)\$record\.BlockSha256 = \(Get-FileHash -LiteralPath \(Join-Path \$work ''block\.txt''\) -Algorithm SHA256\)\.Hash\.ToLowerInvariant\(\).*?\$record\.BlocksPlanned = Get-WorkloadBlocks \$Workload \$ScrollbackMaxBytes\s+\$record\.WorkloadSha256 = Get-WorkloadSha256 \$Workload \$record\.ScrollbackLimitBytes \$record\.BlocksPlanned \$record\.BlockSha256 \(Join-Path \$Bin ''config\.ghostty''\) \$Run'
        Mutation = @('Get-WorkloadSha256 $Workload $record.ScrollbackLimitBytes $record.BlocksPlanned', 'Get-WorkloadSha256 ''fixed'' 10000000 1')
    }
    @{
        Description = 'the mirrored structs are checked against the SDK''s x64 sizes and offsets before anything runs (AGENTS.md "Win32 FFI")'
        Pattern = '(?s)if \(\[WorkingSetNative\]::Layout\(\) -cne \$script:SdkLayout\) \{ throw'
        Mutation = @('if ([WorkingSetNative]::Layout() -cne $script:SdkLayout) { throw', 'if ($false) { throw')
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

# The settle rule, the block counts and the workload hash, taken from the harness's AST and run with the harness's
# own constants (evaluated from its `$script:` assignments; the runner's script scope is restored afterwards): a flat
# series settles, a drift of 1% in private bytes or 2% in working set over the last ten samples does not, nor do fewer
# than ten samples. The control (the 0.5% private-bytes tolerance widened to 5%) must accept the 1% drift.
$workingSetAst = [Management.Automation.Language.Parser]::ParseFile($workingSetScript, [ref]$null, [ref]$null)
$constantNames = @('BlockLines', 'RowPageBytes', 'Cols', 'Rows', 'FixedCycles', 'ChurnCycles', 'SessionCheckpoints', 'PruneSeconds', 'SettleSamples', 'SampleMs', 'SettleCapMs')
$constantLines = foreach ($name in $constantNames) {
    $line = [regex]::Match($workingSetText, "(?m)^\`$script:$name = \d+[ \t]*$").Value.Trim()
    if (-not $line) { throw "The working-set harness has no `$script:$name = <number> line." }
    $line
}
$savedScriptVars = @{}
foreach ($name in $constantNames + @('Utf8')) { $savedScriptVars[$name] = Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue }
try {
. ([scriptblock]::Create(($constantLines -join "`n")))
$script:Utf8 = [Text.UTF8Encoding]::new($false)
function Get-WorkingSetFunction([string] $Name) {
    $found = @($workingSetAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $false))
    if ($found.Count -ne 1) { throw "The working-set harness must define $Name once." }
    return $found[0].Extent.Text
}
$settledText = Get-WorkingSetFunction 'Test-Settled'
$blocksText = Get-WorkingSetFunction 'Get-WorkloadBlocks'
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
& {
    . ([scriptblock]::Create($blocksText))
    $want = [ordered]@{ 'fixed' = 1; 'scrollback-default' = 4; 'uia-walk' = 4; 'session-capture' = 4; 'tab-churn' = 0 }
    foreach ($name in $want.Keys) { if ((Get-WorkloadBlocks $name 1073741824) -ne $want[$name]) { throw "Get-WorkloadBlocks changed for $name." } }
    # 1.25 times what 1 GiB holds at 1,120 bytes a row, in blocks of 25,000 lines: 48.
    if ((Get-WorkloadBlocks 'scrollback-max' 1073741824) -ne 48) { throw 'scrollback-max must write 1.25 times what -ScrollbackMaxBytes holds.' }
}
# The workload hash: the same inputs give the same hash, the run's own directory (in working-directory and, escaped,
# in the flood binding) does not count, and a changed workload, scrollback limit, planned block count, constant, block
# or config line does (Greptile on #739: workloads that share a config must not share a hash).
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
        $a = Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configA 'C:\run-a'
        if ($a -notmatch '\A[0-9a-f]{64}\z') { throw 'Get-WorkloadSha256 must give a SHA-256.' }
        if ($a -cne (Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configB 'D:\other\run-b\')) { throw 'The workload hash must not depend on the run''s directory.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configB 'D:\other')) { throw 'The workload hash took out more than the run''s directory.' }
        if ($a -ceq (Get-WorkloadSha256 'tab-churn' 10000000 1 'aa' $configA 'C:\run-a')) { throw 'The workload hash ignored the workload.' }
        if ((Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' $configA 'C:\run-a') -ceq (Get-WorkloadSha256 'scrollback-max' 2147483647 96 'aa' $configA 'C:\run-a')) { throw 'The workload hash ignored the scrollback limit.' }
        if ((Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' $configA 'C:\run-a') -ceq (Get-WorkloadSha256 'scrollback-max' 1073741824 47 'aa' $configA 'C:\run-a')) { throw 'The workload hash ignored the planned blocks.' }
        if ((Get-WorkloadSha256 'scrollback-max' 1073741824 48 'aa' $configA 'C:\run-a') -ceq (Get-WorkloadSha256 'scrollback-max' 2147483647 48 'aa' $configA 'C:\run-a')) { throw 'The workload hash ignored the scrollback limit at the same block count.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'ab' $configA 'C:\run-a')) { throw 'The workload hash ignored the block.' }
        if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configC 'C:\run-a')) { throw 'The workload hash ignored a config line.' }
        $script:FixedCycles++
        try { if ($a -ceq (Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configA 'C:\run-a')) { throw 'The workload hash ignored a constant.' } } finally { $script:FixedCycles-- }
    }
    # The control: a hash that takes out the plain directory but not its escaped form in the flood binding (the form
    # a real config holds) must fail the run-directory case.
    $hashControl = $hashText.Replace(".Replace(`$root.Replace('\', '\\'), '<run>')", '')
    if ([string]::Equals($hashControl, $hashText, [StringComparison]::Ordinal)) { throw 'The workload hash control changed nothing.' }
    $controlCaught = & {
        . ([scriptblock]::Create($hashControl))
        (Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configA 'C:\run-a') -cne (Get-WorkloadSha256 'fixed' 10000000 1 'aa' $configB 'D:\other\run-b')
    }
    if (-not $controlCaught) { throw 'The run-directory case did not catch a hash that keeps the escaped directory.' }
} finally { [IO.Directory]::Delete($hashDir, $true) }
} finally {
    foreach ($name in $savedScriptVars.Keys) {
        if ($savedScriptVars[$name]) { Set-Variable -Scope Script -Name $name -Value $savedScriptVars[$name].Value }
        else { Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue }
    }
}

# The native layer: the harness's Add-Type source, compiled here under another class name, must give the SDK's x64
# layout string the harness checks at run time (psapi.h PROCESS_MEMORY_COUNTERS_EX2, processthreadsapi.h
# STARTUPINFOW and STARTUPINFOEXW, winnt.h JOBOBJECT_EXTENDED_LIMIT_INFORMATION).
$nativeSource = @($workingSetAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class WorkingSetNative' }, $true))
if ($nativeSource.Count -ne 1) { throw 'The working-set harness must hold one WorkingSetNative source.' }
$layoutWanted = [regex]::Match($workingSetText, "\`$script:SdkLayout = '([^']+)'").Groups[1].Value
if ($layoutWanted -cne 'MemoryCounters=96 peakWorkingSet@8 workingSet@16 privateUsage@72 sharedCommit@88 Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16') {
    throw 'The working-set harness''s SDK layout string changed.'
}
$contractClass = 'WorkingSetNativeContract' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($nativeSource[0].Value.Replace('public static class WorkingSetNative', "public static class $contractClass"))
$layoutActual = ($contractClass -as [type])::Layout()
if ($layoutActual -cne $layoutWanted) { throw "The working-set native layer's layout is $layoutActual, not the SDK's." }

Write-Host "Working-set harness contract: $workingSetMutations rules, each with a rejected mutation; settle, block and workload-hash cases; native layout $layoutActual"
