# The working-set workloads (PLAN.md §3.5): test/windows/hidden-win11-working-set.ps1 runs one portable copy on a
# private desktop through one fixed workload and samples its memory. Pinned here: what the harness may do (patterns
# over its code with the comments removed, each with a mutation that must fail it), its settle rule (run on
# synthetic samples, with a control), how many blocks each workload writes, and its native layer's struct layout
# (compiled and checked against the SDK's x64 sizes). No noctty is started.
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
        Pattern = '(?s)StartupUnchanged = \$before\.Startup -ceq \$after\.Startup.*?JumpListUnchanged = .*?HistoryUnchanged = .*?if \(-not \$guards\.StartupUnchanged\).*?if \(-not \$guards\.JumpListUnchanged\).*?if \(\$historyFailure\).*?throw \(''working-set harness: '''
        Mutation = @('if (-not $guards.JumpListUnchanged) {', 'if ($false -and -not $guards.JumpListUnchanged) {')
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
        Pattern = '(?s)if \(\$record\.CyclesMissed -gt 0\) \{ \$record\.Error = .*?if \(\$Workload -eq ''session-capture'' -and \$record\.SessionSaves -ne 10\) \{ \$record\.Error = .*?if \(\$Workload -eq ''uia-walk'' -and -not \$record\.Uia\.walk_complete\) \{ \$record\.Error = .*?if \(\$record\.Exit -ne 0\) \{ \$record\.Error = .*?return \$\(if \(\$record\.Error\) \{ 1 \} else \{ 0 \}\)'
        Mutation = @('if ($record.CyclesMissed -gt 0) {', 'if ($false) {')
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

# The settle rule and the block counts, taken from the harness's AST and run: a flat series settles, a drift of
# 1% in private bytes or 2% in working set over the last ten samples does not, nor do fewer than ten samples. The
# control (the 0.5% private-bytes tolerance widened to 5%) must accept the 1% drift.
$workingSetAst = [Management.Automation.Language.Parser]::ParseFile($workingSetScript, [ref]$null, [ref]$null)
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
    $script:RowPageBytes = 1120; $script:BlockLines = 25000
    . ([scriptblock]::Create($blocksText))
    $want = [ordered]@{ 'fixed' = 1; 'scrollback-default' = 4; 'uia-walk' = 4; 'session-capture' = 4; 'tab-churn' = 0 }
    foreach ($name in $want.Keys) { if ((Get-WorkloadBlocks $name 1073741824) -ne $want[$name]) { throw "Get-WorkloadBlocks changed for $name." } }
    # 1.25 times what 1 GiB holds at 1,120 bytes a row, in blocks of 25,000 lines: 48.
    if ((Get-WorkloadBlocks 'scrollback-max' 1073741824) -ne 48) { throw 'scrollback-max must write 1.25 times what -ScrollbackMaxBytes holds.' }
}

# The native layer: the harness's Add-Type source, compiled here under another class name, must give the SDK's x64
# layout string the harness checks at run time (psapi.h PROCESS_MEMORY_COUNTERS_EX2, processthreadsapi.h
# STARTUPINFOW and STARTUPINFOEXW, winnt.h JOBOBJECT_EXTENDED_LIMIT_INFORMATION).
$nativeSource = @($workingSetAst.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'public static class WorkingSetNative' }, $true))
if ($nativeSource.Count -ne 1) { throw 'The working-set harness must hold one WorkingSetNative source.' }
$layoutWanted = [regex]::Match($workingSetText, "\`$script:SdkLayout = '([^']+)'").Groups[1].Value
if ($layoutWanted -cne 'MemoryCounters=96 workingSet@16 privateUsage@72 sharedCommit@88 Startup=104 desktop@16 flags@60 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16') {
    throw 'The working-set harness''s SDK layout string changed.'
}
$contractClass = 'WorkingSetNativeContract' + [guid]::NewGuid().ToString('N').Substring(0, 8)
Add-Type -TypeDefinition ($nativeSource[0].Value.Replace('public static class WorkingSetNative', "public static class $contractClass"))
$layoutActual = ($contractClass -as [type])::Layout()
if ($layoutActual -cne $layoutWanted) { throw "The working-set native layer's layout is $layoutActual, not the SDK's." }

Write-Host "Working-set harness contract: $workingSetMutations rules, each with a rejected mutation; settle and block cases; native layout $layoutActual"
