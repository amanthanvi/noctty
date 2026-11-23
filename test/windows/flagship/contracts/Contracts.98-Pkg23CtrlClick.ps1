# PKG-23's Ctrl+click harness: test/windows/hidden-win11-pkg23-ctrl-click.ps1 starts a portable copy of the Debug
# measurement build on a private desktop, Ctrl+clicks row 0 while cmd streams numbered URLs, and counts the opens the
# Debug open-URL trace seam records. Pinned here, with no noctty started: its checker's controls (the harness's own
# -ControlOnly run), that those controls refuse a checker which would pass a missing or partial record (the checker run
# in a fresh runspace with each mutation), what the harness may do (patterns over its code with the comments removed,
# each with a mutation that must fail it), and the seam it relies on: the Win32 opener records the URL and returns
# before ShellExecuteW, and each record holds one open.
$pkg23Script = Join-Path $repoRoot 'test\windows\hidden-win11-pkg23-ctrl-click.ps1'
$pkg23Raw = Get-Content -LiteralPath $pkg23Script -Raw
$pkg23Text = Remove-PowerShellComments $pkg23Raw
$pkg23Fragment = $script:CurrentContractFragment

function Add-Pkg23Failure([string] $Description, [string] $Detail) {
    Add-ContractFailure -Description $Description -SourceFragment $pkg23Fragment -Detail $Detail
}

# The text with the first occurrence of `$Old` replaced, or $null when `$Old` is not there.
function Get-Pkg23Mutated([string] $Text, [string] $Old, [string] $New) {
    $at = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($at -lt 0) { return $null }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

# A rule holds when its pattern matches the text and does not match the text with its mutation.
function Assert-Pkg23Rules([string] $Text, [object[]] $Rules, [string] $Label) {
    foreach ($rule in $Rules) {
        if ($Text -notmatch $rule.Pattern) { Add-Pkg23Failure "${Label}: $($rule.Description)" 'The pattern does not match.'; continue }
        $mutated = Get-Pkg23Mutated $Text $rule.Mutation[0] $rule.Mutation[1]
        if ($null -eq $mutated -or $mutated -ceq $Text) { Add-Pkg23Failure "${Label}: $($rule.Description)" 'The mutation changes nothing.'; continue }
        if ($mutated -match $rule.Pattern) { Add-Pkg23Failure "${Label}: $($rule.Description)" 'The rule accepts its mutation.' }
    }
}

# --- 1. The harness's own checker controls.
$pkg23Output = @(& pwsh -NoProfile -NonInteractive -File $pkg23Script -ControlOnly 2>&1 | ForEach-Object { [string]$_ })
$pkg23Exit = $LASTEXITCODE
$pkg23Line = [regex]::Match(($pkg23Output -join "`n"), '\APKG-23 checker controls: PASS \((\d+) controls\)\z')
if ($pkg23Exit -ne 0 -or -not $pkg23Line.Success -or [int]$pkg23Line.Groups[1].Value -lt 25) {
    Add-Pkg23Failure 'the PKG-23 harness''s checker controls pass, all 25 of them' "exit $pkg23Exit"
}

# --- 2. The controls refuse a checker that passes a missing or partial record.
$pkg23Ast = [Management.Automation.Language.Parser]::ParseInput($pkg23Raw, [ref]$null, [ref]$null)
$pkg23CheckerNames = @('Get-Pkg23RecordStatus', 'Get-Pkg23Verdict', 'Get-Pkg23DryVerdict', 'ConvertTo-Pkg23Bytes', 'Get-Pkg23StreamRecord', 'Invoke-Pkg23CheckerControls')
$pkg23Checker = [Text.StringBuilder]::new()
foreach ($statement in $pkg23Ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -like '$script:Pkg23*') {
        [void]$pkg23Checker.AppendLine($statement.Extent.Text)
    }
}
foreach ($name in $pkg23CheckerNames) {
    $definition = $pkg23Ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $false)
    if (-not $definition) { Add-Pkg23Failure "the PKG-23 checker defines $name" 'Missing.'; continue }
    [void]$pkg23Checker.AppendLine($definition.Extent.Text)
}
$pkg23CheckerText = $pkg23Checker.ToString()
$pkg23RunControls = {
    param([string] $Code)
    . ([scriptblock]::Create($Code))
    try { [void](Invoke-Pkg23CheckerControls); 'accepted' } catch { 'refused' }
}
$pkg23CheckerMutations = @(
    @{ Name = 'the original checker'; Old = $null; New = $null; Expect = 'accepted' }
    @{ Name = 'a missing record is not counted against the run'; Old = '$counts.whole -eq $Clicks -and'; New = '$counts.whole -eq ($Clicks - $counts.missing) -and'; Expect = 'refused' }
    @{ Name = 'a missing record reads as whole'; Old = "if (`$null -eq `$Bytes) { return 'missing' }"; New = "if (`$null -eq `$Bytes) { return 'whole' }"; Expect = 'refused' }
    @{ Name = 'a record without its line end gets one'; Old = '-not $text.EndsWith("`r`n", [StringComparison]::Ordinal)) { return ''partial'' }'; New = '$false) { return ''partial'' }; if (-not $text.EndsWith("`r`n", [StringComparison]::Ordinal)) { $text += "`r`n" }'; Expect = 'refused' }
    @{ Name = 'a second line in a record is allowed'; Old = '$line.Length -eq 0 -or $line.IndexOfAny([char[]]@([char]13, [char]10)) -ge 0'; New = '$line.Length -eq 0'; Expect = 'refused' }
    @{ Name = 'the stream pattern is not anchored'; Old = "'\Ahttps://pkg23\.invalid/(1[0-9]{7})/\1\z'"; New = "'https://pkg23\.invalid/(1[0-9]{7})/\1'"; Expect = 'refused' }
    @{ Name = 'a URL no longer checks its own number'; Old = "/(1[0-9]{7})/\1\z'"; New = "/(1[0-9]{7})/1[0-9]{7}\z'"; Expect = 'refused' }
    @{ Name = 'an open the driver saw for no click is ignored'; Old = '.Count + $LiveExtras'; New = '.Count'; Expect = 'refused' }
    @{ Name = 'an extra record is ignored'; Old = '$extra -eq 0 -and'; New = ''; Expect = 'refused' }
    @{ Name = 'a stalled stream passes'; Old = ' -and $ordered -and $moved)'; New = ' -and $ordered)'; Expect = 'refused' }
    @{ Name = 'the dry click ignores the job'; Old = '$quiet = $JobProcessesAfter -eq $JobProcessesBefore -and'; New = '$quiet = $true -or'; Expect = 'refused' }
    @{ Name = 'a dry click that recorded nothing passes'; Old = "`$status -eq 'whole' -and `$quiet"; New = "`$status -ne 'torn' -and `$quiet"; Expect = 'refused' }
    @{ Name = 'the dry click ignores the job counter''s launch control'; Old = ' -and $quiet -and $counted)'; New = ' -and $quiet)'; Expect = 'refused' }
    @{ Name = 'the dry click ignores the build mode'; Old = "[string]::Equals(`$BuildMode, 'Debug', [StringComparison]::Ordinal) -and "; New = ''; Expect = 'refused' }
)
foreach ($mutation in $pkg23CheckerMutations) {
    $code = $pkg23CheckerText
    if ($null -ne $mutation.Old) {
        $code = Get-Pkg23Mutated $pkg23CheckerText $mutation.Old $mutation.New
        if ($null -eq $code) { Add-Pkg23Failure "checker mutation '$($mutation.Name)'" 'Its target is not in the checker.'; continue }
    }
    try {
        $outcome = @(Invoke-ContractScriptWithDeadline -Script $pkg23RunControls -Arguments @($code) -HangMessage "The PKG-23 checker controls hung on '$($mutation.Name)'.")
        if ($outcome.Count -ne 1 -or $outcome[0] -cne $mutation.Expect) {
            Add-Pkg23Failure "the PKG-23 checker controls are $($mutation.Expect) for '$($mutation.Name)'" "got '$($outcome -join ',')'"
        }
    } catch { Add-Pkg23Failure "checker mutation '$($mutation.Name)'" $_.Exception.Message }
}

# --- 3. What the harness may do.
$pkg23Rules = @(
    @{
        Description = 'it uses no real input, foreground or desktop switch, clipboard, shell open, process start of its own, or recursive delete'
        Pattern = '(?s)\A(?!.*(?:SendInput|keybd_event|mouse_event|SetForegroundWindow|SetActiveWindow|BringWindowToTop|SwitchDesktop|Set-Clipboard|Get-Clipboard|SetClipboardData|OpenClipboard|shell32|Start-Process|Diagnostics\.Process\]::Start|Invoke-Item|Register-Default|Remove-Item\s+-Recurse))'
        Mutation = @('[Pkg23Native]::CtrlClick($Pane, $script:parkX, $script:parkY, $X, $Y)', '[Pkg23Native]::CtrlClick($Pane, $script:parkX, $script:parkY, $X, $Y); Start-Process notepad')
    }
    @{
        Description = 'a -Run that already exists launches nothing, so the results the outer half reads are this run''s'
        Pattern = '(?s)if \(-not \$Driver\) \{\s+if \(-not \$MeasureRepo -or -not \$Run\) \{ throw [^\r\n]*\}\s+if \(Test-Path -LiteralPath \$Run\) \{ Write-Host [^\r\n]*; exit 1 \}'
        Mutation = @('if (Test-Path -LiteralPath $Run) {', 'if ($false) {')
    }
    @{
        Description = 'the outer half runs the checker controls, then admits only the receipt-bound measurement build, before the driver'
        Pattern = '(?s)if \(-not \$Driver\) \{.*?\$controls = Invoke-Pkg23CheckerControls\s.*?Assert-InteractiveWin11MeasureBuild -RepoRoot \$MeasureRepo -ExePath \$exe.*?Invoke-LocalHiddenDriver -Script'
        Mutation = @('$controls = Invoke-Pkg23CheckerControls', '$controls = 0')
    }
    @{
        Description = 'a measurement build that is not Debug (no trace seam) launches nothing and exits 4'
        Pattern = '(?s)\[string\]::Equals\(\[string\]\$receipt\.Optimize, ''Debug'', \[StringComparison\]::Ordinal\)\) \{[^}]*?exit 4\s*\}.*?Invoke-LocalHiddenDriver -Script'
        Mutation = @("nothing was launched.'`n        exit 4", "nothing was launched.'")
    }
    @{
        Description = 'before the driver, the outer half checks the seam in the source the measurement build was made from, and a problem exits 4'
        Pattern = '(?s)\$layout = Get-InteractiveWin11MeasureLayout -RepoRoot \$MeasureRepo.*?\$seamProblems = Get-Pkg23SeamProblems \(\[IO\.File\]::ReadAllText\(\(Join-Path \$layout\.Source ''src\\apprt\\win32\\app\.zig''\)\)\) `\s+\(\[IO\.File\]::ReadAllText\(\(Join-Path \$layout\.Source ''src\\apprt\\win32\.zig''\)\)\)\s+if \(\$seamProblems\.Count -ne 0\) \{[^}]*?exit 4\s*\}.*?Invoke-LocalHiddenDriver -Script'
        Mutation = @('if ($seamProblems.Count -ne 0) {', 'if ($false) {')
    }
    @{
        Description = 'the copy is the measurement AUMID''s: the variable is set before the launch'
        Pattern = '(?s)\$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = ''1''.*?\[HiddenLocal\]::Spawn\(\$exe, \$line'
        Mutation = @("`$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'", "`$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '0'")
    }
    @{
        Description = 'a copy that died or stopped answering at the dry click stops the run before the stream'
        Pattern = '(?s)\$alive = Test-Pkg23Running\s+\$responds = \$alive -and \[Pkg23Native\]::Responds\(\$hostWindow\).*?if \(-not \(\$alive -and \$responds\)\) \{ \$R\.Stage = ''dry-product-failure''; return \}.*?PostSurfaceKey\(\$pane'
        Mutation = @("`$R.Stage = 'dry-product-failure'; return }", "`$R.Stage = 'dry-product-failure' }")
    }
    @{
        Description = 'the driver runs on its own private desktop with the clipboard guarded and a copy without noctty.ico'
        Pattern = 'Invoke-LocalHiddenDriver -Script \$PSCommandPath -Bin \(Split-Path -Parent \$exe\) -Run \$Run -DesktopPrefix \$desktopPrefix `\s+-TimeoutSeconds \$DriverTimeoutSeconds -Label ''PKG-23 driver'' -PassDesktopName -GuardClipboard -OmitIcon'
        Mutation = @('-PassDesktopName -GuardClipboard -OmitIcon', '-PassDesktopName -OmitIcon')
    }
    @{
        Description = 'the outer half exits 3 when a new jump-list file or a reparse point appears'
        Pattern = '(?s)\$newJump = @\(Get-Pkg23NewJumpListFiles \$jumpBefore \$since\)\.Count\s+\$reparse = Get-Pkg23ReparsePointCount \$Run.*?-or \$newJump -ne 0 -or \$reparse -ne 0\) \{[^}]*?exit 3'
        Mutation = @(' -or $reparse -ne 0) {', ') {')
    }
    @{
        Description = 'the driver admits only the fresh portable copy on its named desktop before anything else'
        Pattern = '(?s)\A(?:(?!\[HiddenLocal\]::Spawn).)*?\nAssert-LocalHiddenFixture \$Bin \$Run \$DesktopName \$desktopPrefix\n'
        Mutation = @("`nAssert-LocalHiddenFixture `$Bin `$Run `$DesktopName `$desktopPrefix`n", "`n")
    }
    @{
        Description = 'the copy runs System32''s cmd.exe directly with /D (no AutoRun), no shell integration, its own class, single-instance off'
        Pattern = '(?s)\$classToken = \[guid\]::NewGuid\(\)\.ToString\(''N''\).*?"command = direct:\$cmd /D /C pkg23-stream-\$Name\.cmd", "working-directory = \$Bin", ''shell-integration = none'',\s+''single-instance = false'', "class = noctty-test-pkg23-\$classToken"'
        Mutation = @('"command = direct:$cmd /D /C pkg23-stream-$Name.cmd"', '"command = cmd.exe /C pkg23-stream-$Name.cmd"')
    }
    @{
        Description = 'the copy denies the clipboard, copies nothing on select, checks no update, and keeps no scrollback'
        Pattern = '''copy-on-select = false'', ''clipboard-read = deny'', ''clipboard-write = deny'',\s+''auto-update = off'', ''desktop-notifications = false'', ''keybind = clear'', ''scrollback-limit = 0'','
        Mutation = @("'scrollback-limit = 0'", "'scrollback-limit = 10000000'")
    }
    @{
        Description = 'every URL in the harness names the reserved pkg23.invalid host'
        Pattern = '(?s)\A(?!.*https?://(?!pkg23\\?\.inv))'
        Mutation = @('do echo https://pkg23.invalid/%%i', 'do echo https://example.com/%%i')
    }
    @{
        Description = 'the copy''s build mode comes from its own +version, and a build that is not Debug stops before the launch'
        Pattern = '(?s)function Invoke-Pkg23Driver \{\s+\$results\.Stage = ''build-mode''\s+\$buildMode = Get-Pkg23BuildMode\s+\$results\.BuildMode = \$buildMode\s+if \(-not \[string\]::Equals\(\$buildMode, ''Debug'', \[StringComparison\]::Ordinal\)\) \{ \$results\.Stage = ''dry-failed''; return \}\s+foreach \(\$name in \$setNames\)'
        Mutation = @('$buildMode = Get-Pkg23BuildMode', '$buildMode = ''Debug''')
    }
    @{
        Description = 'the trace variable names a file inside the run and is set before the only launch, which carries no command, config file or -e'
        Pattern = '(?s)\$work = Join-Path \$Run ''pkg23''.*?\$tracePath = Join-Path \$traceDir ''open-url\.txt''.*?\$env:NOCTTY_WIN32_OPEN_URL_TRACE_FILE = \$tracePath\s+\$line = ''"\{0\}" --single-instance=false --window-save-state=never'' -f \$exe\s+\$launchBefore = \[Pkg23Native\]::JobTotalProcesses\(\)\s+\$script:noctty = \[HiddenLocal\]::Spawn\(\$exe, \$line'
        Mutation = @("--single-instance=false --window-save-state=never' -f `$exe", "--single-instance=false' -f `$exe")
    }
    @{
        Description = 'one dry click is checked before the stream starts, and a failed one returns before the stream''s key'
        Pattern = '(?s)Send-Pkg23Click \$pane \$x \$y\s+\$dry = Wait-Pkg23Record 5000.*?\$R\.DryClick = Get-Pkg23DryVerdict \$dry\.Bytes \$BuildMode \$before \$after \$newNames \$launchProcesses.*?if \(-not \$R\.DryClick\.Passed\) \{ \$R\.Stage = ''dry-failed''; return \}.*?PostSurfaceKey\(\$pane'
        Mutation = @("if (-not `$R.DryClick.Passed) { `$R.Stage = 'dry-failed'; return }", "if (-not `$R.DryClick.Passed) { `$R.Stage = 'dry-failed' }")
    }
    @{
        Description = 'each click''s record is archived, the trace cleared, and a second open counted before the next click, and the run looks for one after the last'
        Pattern = '(?s)for \(\$i = 1; \$i -le \$Clicks; \$i\+\+\) \{.*?Send-Pkg23Click \$pane \$x \$y\s+\$record = Wait-Pkg23Record 3000\s+if \(\$null -ne \$record\.Bytes\) \{ \[IO\.File\]::WriteAllBytes\(.*?\}\s+Clear-Pkg23Trace\s+if \(Test-Pkg23TraceAppears 150\) \{ \$R\.ExtraOpens\+\+; Clear-Pkg23Trace \}\s+\}.*?if \(Test-Pkg23TraceAppears 1000\) \{ \$R\.ExtraOpens\+\+; Clear-Pkg23Trace \}.*?Get-Pkg23Verdict \$records \$Clicks \(\$R\.ExtraOpens \+ \$R\.LateRecordsDiscarded\)'
        Mutation = @('if (Test-Pkg23TraceAppears 150) { $R.ExtraOpens++; Clear-Pkg23Trace }', '')
    }
    @{
        Description = 'a click is a posted move to the park cell, then a move, press and release, all carrying MK_CONTROL, after the target thread''s key state is cleared'
        Pattern = '(?s)\A(?=.*\[Pkg23Native\]::ClearKeys\(\$Pane\)\s+\[Pkg23Native\]::CtrlClick\(\$Pane, \$script:parkX, \$script:parkY, \$X, \$Y\))(?=.*!PostMessageW\(h, 0x200, new IntPtr\(0x8\), park\) \|\|\s+!PostMessageW\(h, 0x200, new IntPtr\(0x8\), l\) \|\| !PostMessageW\(h, 0x201, new IntPtr\(0x9\), l\) \|\|\s+!PostMessageW\(h, 0x202, new IntPtr\(0x8\), l\))'
        Mutation = @('0x201, new IntPtr(0x9)', '0x201, new IntPtr(0x1)')
    }
    @{
        Description = 'every click is on row 0 at its set''s column (set A column 0, as the October probe clicked; set B column 3, inside the URL), each a single click'
        Pattern = '(?s)\A(?=.*\$y = \[int\]\(\$pad \+ \$cellHeight / 2\)\s+\$x = \[int\]\(\$pad \+ \(\$Spec\.Column \+ 0\.5\) \* \$cellWidth\)\s+\$script:parkX = \[int\]\(\$pad \+ 70\.5 \* \$cellWidth\)\s+\$script:parkY = \[int\]\(\$pad \+ 2\.5 \* \$cellHeight\))(?=.*''scrollback-limit = 0'', ''click-repeat-interval = 1'',)(?=.*\bA = \[ordered\]@\{ AltScreen = \$false; Column = 0 \})'
        Mutation = @('A = [ordered]@{ AltScreen = $false; Column = 0 }', 'A = [ordered]@{ AltScreen = $false; Column = 3 }')
    }
    @{
        Description = 'set B clicks column 3 on the alternate screen: its stream enters it (DECSET 1049) and homes the cursor before the dry URL'
        Pattern = '(?s)\bB = \[ordered\]@\{ AltScreen = \$true; Column = 3 \}.*?\$stream = @\(''@echo off''\)\s+if \(\$Spec\.AltScreen\) \{ \$stream \+= \(''<nul set /p "='' \+ \[char\]27 \+ ''\[\?1049h'' \+ \[char\]27 \+ ''\[H"''\) \}\s+\$stream \+= @\(\s+"echo \$\(\$script:Pkg23DryUrl\)"'
        Mutation = @("'[?1049h'", "'[?1047h'")
    }
    @{
        Description = 'set B is column 3, not column 0'
        Pattern = '\bB = \[ordered\]@\{ AltScreen = \$true; Column = 3 \}'
        Mutation = @('B = [ordered]@{ AltScreen = $true; Column = 3 }', 'B = [ordered]@{ AltScreen = $true; Column = 0 }')
    }
    @{
        Description = 'the sets are counted separately: each its own launch, records directory and verdict, and a run takes both by default'
        Pattern = '(?s)\[ValidateSet\(''A'', ''B'', ''AB''\)\] \[string\] \$Sets = ''AB''.*?\$recordsDir = Join-Path \$work "\$Name\\records".*?\$R\.Verdict = \$verdict.*?\$results\.Set\[\$name\] = \$R\s+\$results\.Stage = "set \$name"\s+try \{ Invoke-Pkg23Set \$name \$setSpecs\[\$name\] \$buildMode \$R \} finally \{ Close-Pkg23Copy \}'
        Mutation = @('$recordsDir = Join-Path $work "$Name\records"', '$recordsDir = Join-Path $work "records"')
    }
    @{
        Description = 'a run takes both sets unless told otherwise'
        Pattern = '\[ValidateSet\(''A'', ''B'', ''AB''\)\] \[string\] \$Sets = ''AB'''
        Mutation = @("[string] `$Sets = 'AB'", "[string] `$Sets = 'A'")
    }
    @{
        Description = 'the guards'' values are written into the run before the trip exit: the clipboard sequence and each history candidate''s index, size and ticks, before and after, no path or content'
        Pattern = '(?s)\$historyBefore = @\(\$historyPaths \| ForEach-Object \{ Get-WindowsHarnessHistoryMetadata \$_ \}\)\s+\$clipboardBefore = \[HiddenLocal\]::GetClipboardSequenceNumber\(\).*?Invoke-LocalHiddenDriver.*?\$historyAfter = @\(\$historyPaths \| ForEach-Object \{ Get-WindowsHarnessHistoryMetadata \$_ \}\)\s+\$clipboardAfter = \[HiddenLocal\]::GetClipboardSequenceNumber\(\).*?ClipboardSequence = \[ordered\]@\{ Before = \$clipboardBefore; After = \$clipboardAfter.*?History = @\(for \(\$i = 0; \$i -lt \$historyPaths\.Count; \$i\+\+\) \{\s+\[ordered\]@\{ Index = \$i; Before = \$historyBefore\[\$i\]; After = \$historyAfter\[\$i\];.*?\| Set-Content -LiteralPath \(Join-Path \$Run ''pkg23-guards\.json''\)\s+if \(-not \$guards\.StartupUnchanged'
        Mutation = @('History = @(for ($i = 0;', 'Hist = @(for ($i = 0;')
    }
    @{
        Description = 'a click goes only to the owned pane of the copy on the private desktop'
        Pattern = 'if \(\[Pkg23Native\]::Owner\(\$Pane\) -ne \$script:noctty\.pid -or \[Pkg23Native\]::ClassOf\(\$Pane\) -cne ''noctty\.win32'' -or\s+\[HiddenLocal\]::WindowDesktop\(\$Pane\) -cne \$DesktopName\) \{ throw'
        Mutation = @("[Pkg23Native]::ClassOf(`$Pane) -cne 'noctty.win32' -or", '')
    }
)
Assert-Pkg23Rules $pkg23Text $pkg23Rules 'hidden-win11-pkg23-ctrl-click.ps1'

# --- 4. The seam the harness reads, through the harness's own check (Get-Pkg23SeamProblems, which its outer half runs
# on the measurement build's source before any launch): this checkout's opener holds every rule, and each mutation of
# it, a way the dry click could reach the shell or the per-click record could break, is reported.
$pkg23AppText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\apprt\win32\app.zig'))
$pkg23Win32Text = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\apprt\win32.zig'))
$pkg23SeamDefinition = $pkg23Ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-Pkg23SeamProblems' }, $false)
if (-not $pkg23SeamDefinition) { Add-Pkg23Failure 'the PKG-23 harness defines Get-Pkg23SeamProblems' 'Missing.' }
else {
    $pkg23RunSeam = {
        param([string] $Code, [string] $App, [string] $Win32)
        . ([scriptblock]::Create($Code))
        $found = Get-Pkg23SeamProblems $App $Win32
        $found.Count
    }
    $pkg23SeamMutations = @(
        @{ Name = 'this checkout'; File = $null; Old = $null; New = $null }
        @{ Name = 'the opener goes on to the shell after the trace'; File = 'app'; Old = 'try recordOpenUrlForTest(self.core_app.alloc, target)) return;'; New = 'try recordOpenUrlForTest(self.core_app.alloc, target)) {}' }
        @{ Name = 'the trace is not Debug-only but never runs'; File = 'app'; Old = 'if (builtin.mode == .Debug and'; New = 'if (builtin.mode == .ReleaseFast and' }
        @{ Name = 'a queued target goes straight to the shell'; File = 'app'; Old = 'target, dispatchOpenTarget),'; New = 'target, shellExecuteOpenTarget),' }
        @{ Name = 'a second caller reaches the shell'; File = 'app'; Old = 'try self.deferShellRequest(.{ .target = owned });'; New = 'try self.deferShellRequest(.{ .target = owned }); if (false) try shellExecuteOpenTarget(self, owned);' }
        @{ Name = 'a link open is not queued'; File = 'app'; Old = 'orelse return self.app.deferOpenTarget(checked);'; New = 'orelse return self.app.dispatchOpenTarget(checked);' }
        @{ Name = 'the trace variable is renamed'; File = 'win32'; Old = '"NOCTTY_WIN32_OPEN_URL_TRACE_FILE",'; New = '"NOCTTY_OPEN_URL_TRACE",' }
        @{ Name = 'the trace appends'; File = 'win32'; Old = 'createFileAbsolute(path, .{ .truncate = true })'; New = 'createFileAbsolute(path, .{ .truncate = false })' }
        @{ Name = 'the trace reports no record'; File = 'win32'; Old = "try writeOpenUrlTrace(file, url);`n    return true;"; New = "try writeOpenUrlTrace(file, url);`n    return false;" }
        @{ Name = 'a record has no line end'; File = 'win32'; Old = 'print("{s}\r\n", .{url})'; New = 'print("{s}", .{url})' }
    )
    foreach ($mutation in $pkg23SeamMutations) {
        $app = $pkg23AppText
        $win32 = $pkg23Win32Text
        if ($mutation.File -eq 'app') { $app = Get-Pkg23Mutated ($pkg23AppText -replace "`r`n", "`n") $mutation.Old $mutation.New }
        elseif ($mutation.File -eq 'win32') { $win32 = Get-Pkg23Mutated ($pkg23Win32Text -replace "`r`n", "`n") $mutation.Old $mutation.New }
        if ($null -eq $app -or $null -eq $win32) { Add-Pkg23Failure "seam mutation '$($mutation.Name)'" 'Its target is not in the source.'; continue }
        try {
            $count = @(Invoke-ContractScriptWithDeadline -Script $pkg23RunSeam -Arguments @($pkg23SeamDefinition.Extent.Text, $app, $win32) -HangMessage "The PKG-23 seam check hung on '$($mutation.Name)'.")
            $expectClean = $null -eq $mutation.File
            if ($count.Count -ne 1 -or (($count[0] -eq 0) -ne $expectClean)) {
                Add-Pkg23Failure "the PKG-23 seam check $(if ($expectClean) { 'passes' } else { 'reports' }) '$($mutation.Name)'" "problems: $($count -join ',')"
            }
        } catch { Add-Pkg23Failure "seam mutation '$($mutation.Name)'" $_.Exception.Message }
    }
}
