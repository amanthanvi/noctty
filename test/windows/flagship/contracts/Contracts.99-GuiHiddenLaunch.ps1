# The hidden-desktop GUI suite's launch, build rule and runner (interactive offload PR 1; design §4.1, §4.2).
# What runs here needs no desktop: the desktop decision, the launcher's per-launch check, staging, the shell verdict
# and the runner's process verdict run on synthetic inputs, and each with a control that must be refused. The
# workflow, the GUI selection and the real-input module's contract are Contracts.99-GuiHiddenSelection.ps1's.
$guiLibPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
$guiRunnerPath = Join-Path $repoRoot 'test\windows\gui-hidden-runner.ps1'
$guiPlanPath = Join-Path $repoRoot 'test\windows\gui-hidden-plan.json'
$guiMeasurementsPath = Join-Path $repoRoot 'test\windows\flagship\measurements\gui-measurements.json'
$guiStatefulPath = Join-Path $repoRoot 'test\windows\interactive-win11-stateful-lib.ps1'

function Get-GuiContractAst([string] $Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Path does not parse: $($errors[0].Message)" }
    return $ast
}
function Get-GuiContractFunctionText($Ast, [string] $Name) {
    $found = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true))
    if ($found.Count -ne 1) { throw "Expected one function $Name, found $($found.Count)." }
    return $found[0].Extent.Text
}
function Test-GuiContractInsideHostedSwitch($Node, [switch] $ElseBranch) {
    # True when `Node` sits in the then-branch of an `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP)`, or, with -ElseBranch, in
    # the else-branch of one with no other clause.
    $cursor = $Node.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.IfStatementAst] -and ($cursor.Clauses.Count -eq 1 -or -not $ElseBranch) -and
            [string]::Equals($cursor.Clauses[0].Item1.Extent.Text, '$env:NOCTTY_GUI_HIDDEN_DESKTOP', [StringComparison]::Ordinal)) {
            $branch = if ($ElseBranch) { $cursor.ElseClause } else { $cursor.Clauses[0].Item2 }
            if ($null -ne $branch -and $Node.Extent.StartOffset -ge $branch.Extent.StartOffset -and $Node.Extent.EndOffset -le $branch.Extent.EndOffset) { return $true }
        }
        $cursor = $cursor.Parent
    }
    return $false
}
$guiLibAst = Get-GuiContractAst $guiLibPath
# Pins a mirror of SDK structs (AGENTS.md "Win32 FFI"; Greptile on #740): `Type`'s Layout() must equal the literal its
# source file assigns to `LiteralName`, and the same source with two fields of one struct swapped, compiled under
# another class name, must not.
function Assert-GuiContractLayout($FileAst, [string] $Source, [string] $ClassName, [string] $LiteralName, [string] $SwapFrom, [string] $SwapTo) {
    $assignment = @($FileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $LiteralName }, $true))
    if ($assignment.Count -ne 1) { throw "Expected one $LiteralName." }
    $pinned = [scriptblock]::Create('return ' + $assignment[0].Right.Extent.Text).Invoke()[0]
    $actual = ($ClassName -as [type])::Layout()
    if (-not [string]::Equals($actual, $pinned, [StringComparison]::Ordinal)) { throw "$ClassName's structs are $actual, not the pinned SDK layout." }
    $swapped = $Source.Replace($SwapFrom, $SwapTo)
    if ([string]::Equals($swapped, $Source, [StringComparison]::Ordinal)) { throw "The $ClassName layout control changed nothing." }
    # Every class in the source gets the same new suffix, so the control compiles beside the real types.
    $suffix = 'Swapped' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $controlClass = $ClassName + $suffix
    $swapped = [regex]::Replace($swapped, 'public static class (\w+)', ('public static class $1' + $suffix))
    Add-Type -TypeDefinition $swapped
    if ([string]::Equals(($controlClass -as [type])::Layout(), $pinned, [StringComparison]::Ordinal)) { throw "The $ClassName layout check accepted two swapped fields." }
}
$guiMeasureLibAst = Get-GuiContractAst (Join-Path $repoRoot 'scripts\interactive-win11-measure-lib.ps1')
foreach ($name in @('Get-InteractiveWin11CanonicalPath', 'Test-InteractiveWin11SamePath')) {
    . ([scriptblock]::Create((Get-GuiContractFunctionText $guiMeasureLibAst $name)))
}
$guiRunnerAst = Get-GuiContractAst $guiRunnerPath

# ---- (1) lib's hosted block: compiled and run only inside `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP)`, at the library's
# top level (design §2.1 check 3: nothing new runs on the default route), after the launch-policy selector's refusal.
$guiTopStatements = @($guiLibAst.EndBlock.Statements)
$guiHostedBlocks = @($guiTopStatements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses.Count -eq 1 -and $null -eq $_.ElseClause -and
        [string]::Equals($_.Clauses[0].Item1.Extent.Text, '$env:NOCTTY_GUI_HIDDEN_DESKTOP', [StringComparison]::Ordinal)
})
if ($guiHostedBlocks.Count -ne 1) { throw 'The library must hold exactly one top-level if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) block.' }
$guiHostedBlock = $guiHostedBlocks[0]
$guiHostedAddTypes = @(Get-NamedCommands -Ast $guiHostedBlock -Name 'Add-Type')
$guiHostedAsserts = @($guiHostedBlock.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $n.Expression.TypeName.FullName -ceq 'InteractiveWin11HostedDesktop' -and (Get-MemberExpressionName -Node $n) -ceq 'Assert' }, $true))
$guiHostedExitReceipts = @(Get-NamedCommands -Ast $guiHostedBlock -Name 'Register-EngineEvent')
if ($guiHostedAddTypes.Count -ne 1 -or $guiHostedAsserts.Count -ne 1 -or $guiHostedExitReceipts.Count -ne 1) {
    throw 'The hosted block must compile the desktop check once, assert it once and register the leaf receipt once.'
}
foreach ($statement in $guiTopStatements) {
    if ([object]::ReferenceEquals($statement, $guiHostedBlock) -or $statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
    if ($statement.Extent.Text -match 'InteractiveWin11Hosted(Desktop|Launch)') { throw 'No top-level library statement outside the hosted block may touch the hosted types.' }
}
$guiPolicyRefusals = @($guiTopStatements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        [string]::Equals($_.Clauses[0].Item1.Extent.Text, '$env:NOCTTY_GUI_LAUNCH_POLICY', [StringComparison]::Ordinal) -and
        $_.Clauses[0].Item2.Extent.Text -match '\bthrow\b'
})
if ($guiPolicyRefusals.Count -ne 1 -or [Array]::IndexOf($guiTopStatements, $guiPolicyRefusals[0]) -gt [Array]::IndexOf($guiTopStatements, $guiHostedBlock)) {
    throw 'The library must refuse any NOCTTY_GUI_LAUNCH_POLICY value before its hosted block.'
}

# ---- (2) the desktop decision, compiled from the library's own text, table-tested.
if (-not ('InteractiveWin11HostedDesktop' -as [type])) {
    $guiTypeDefinition = Get-CommandParameterArgument -Command $guiHostedAddTypes[0] -Name 'TypeDefinition'
    if ($guiTypeDefinition -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { throw 'The hosted types must be one literal Add-Type.' }
    Add-Type -TypeDefinition $guiTypeDefinition.Value
}
$guiHostedSource = (Get-CommandParameterArgument -Command $guiHostedAddTypes[0] -Name 'TypeDefinition').Value
Assert-GuiContractLayout $guiLibAst $guiHostedSource 'InteractiveWin11HostedLaunch' '$script:InteractiveWin11HostedLaunchLayout' 'public uint volumeSerial, sizeHigh, sizeLow,' 'public uint volumeSerial, sizeLow, sizeHigh,'
$guiExpected = 'WinSta0\noctty-gh-' + ('a' * 32)
$guiOwn = 'noctty-gh-' + ('a' * 32)
foreach ($case in @(
        @{ Name = 'the runner''s desktop'; Station = 'WinSta0'; Desktop = $guiOwn; Input = 'Default'; Expected = $guiExpected; Admitted = $true }
        @{ Name = 'another window station'; Station = 'Service-0x0-3e7$'; Desktop = $guiOwn; Input = 'Default'; Expected = $guiExpected; Admitted = $false }
        @{ Name = 'another run''s private desktop'; Station = 'WinSta0'; Desktop = 'noctty-gh-' + ('b' * 32); Input = 'Default'; Expected = $guiExpected; Admitted = $false }
        @{ Name = 'Default'; Station = 'WinSta0'; Desktop = 'Default'; Input = 'Default'; Expected = $guiExpected; Admitted = $false }
        @{ Name = 'an unreadable thread desktop'; Station = 'WinSta0'; Desktop = ''; Input = 'Default'; Expected = $guiExpected; Admitted = $false }
        @{ Name = 'an unreadable input desktop (a locked workstation)'; Station = 'WinSta0'; Desktop = $guiOwn; Input = ''; Expected = $guiExpected; Admitted = $false }
        @{ Name = 'the input desktop itself, any case'; Station = 'WinSta0'; Desktop = $guiOwn; Input = $guiOwn.ToUpperInvariant(); Expected = $guiExpected; Admitted = $false }
        @{ Name = 'an expected name that is not a runner''s'; Station = 'WinSta0'; Desktop = 'Default'; Input = 'Winlogon'; Expected = 'WinSta0\Default'; Admitted = $false }
        @{ Name = 'an expected identity without a station'; Station = 'WinSta0'; Desktop = $guiOwn; Input = 'Default'; Expected = $guiOwn; Admitted = $false }
        @{ Name = 'no expected identity'; Station = 'WinSta0'; Desktop = $guiOwn; Input = 'Default'; Expected = ''; Admitted = $false }
    )) {
    $reason = [InteractiveWin11HostedDesktop]::Decide($case.Station, $case.Desktop, $case.Input, $case.Expected)
    if (($null -eq $reason) -ne $case.Admitted) { throw "The hosted desktop decision answered '$reason' for $($case.Name)." }
}
if ([InteractiveWin11HostedDesktop]::Decide('WinSta0', $guiOwn, '', $guiExpected) -notmatch 'locked') { throw 'An unreadable input desktop must be named as a possibly locked workstation.' }

# ---- (3) the launcher's per-launch check and its staged identity, on a synthetic staged copy.
$guiScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-gui-hidden-contract-' + [guid]::NewGuid().ToString('N'))
$guiSavedEnvironment = @{}
foreach ($name in @('NOCTTY_GUI_HIDDEN_DESKTOP', 'NOCTTY_GUI_HIDDEN_EXE', 'NOCTTY_GUI_HIDDEN_RUN', 'NOCTTY_INTERACTIVE_MEASURE_AUMID')) {
    $guiSavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $guiCopy = Join-Path $guiScratch 'copy'
    [void](New-Item -ItemType Directory -Path $guiCopy)
    $guiApp = Join-Path $guiCopy 'noctty.exe'; $guiCli = Join-Path $guiCopy 'noctty.com'
    [IO.File]::WriteAllText($guiApp, 'app ' + [guid]::NewGuid()); [IO.File]::WriteAllText($guiCli, 'cli ' + [guid]::NewGuid())
    [IO.File]::WriteAllText((Join-Path $guiCopy 'noctty.portable'), '')
    $guiHashOf = { param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $guiToken = [guid]::NewGuid().ToString('N')
    $guiStage = { param([string] $Exe, [string] $Cli, [string] $Token = $guiToken)
        [IO.File]::WriteAllText((Join-Path $guiScratch 'staged.json'), ([ordered]@{ exeSha256 = $Exe; cliSha256 = $Cli; runToken = $Token } | ConvertTo-Json)) }
    & $guiStage (& $guiHashOf $guiApp) (& $guiHashOf $guiCli)
    $env:NOCTTY_GUI_HIDDEN_DESKTOP = $guiExpected
    $env:NOCTTY_GUI_HIDDEN_EXE = $guiApp
    $env:NOCTTY_GUI_HIDDEN_RUN = $guiScratch
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
    foreach ($name in @('Initialize-InteractiveWin11HostedIdentity', 'Get-InteractiveWin11HostedLaunchRefusal', 'ConvertTo-InteractiveWin11HostedCommandLine',
            'Get-InteractiveWin11HostedArgumentRefusal', 'Get-InteractiveWin11HostedRunToken', 'Get-InteractiveWin11NormalizedPath',
            'Get-InteractiveWin11WorktreeId', 'Get-InteractiveWin11SandboxName', 'Get-InteractiveWin11SandboxLayout')) {
        . ([scriptblock]::Create((Get-GuiContractFunctionText $guiLibAst $name)))
    }
    $script:InteractiveWin11HostedIdentity = Initialize-InteractiveWin11HostedIdentity
    $script:InteractiveWin11HostedRunToken = Get-InteractiveWin11HostedRunToken
    $guiAppArgs = @('--single-instance=false', "--class=noctty-interactive-x-$guiToken")
    if (Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList $guiAppArgs) { throw 'The launcher refused the genuine staged app.' }
    if (Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiCli -ArgumentList @('+version')) { throw 'The launcher refused the genuine staged CLI.' }
    # The existence check before any launch checks the file alone (the first local run of round 1 refused every leaf there).
    if (Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -FileOnly) { throw 'The existence check refused the genuine staged app.' }
    if (-not (Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp)) { throw 'The launch check admitted an app launch with no arguments.' }
    $guiRefusals = [ordered]@{}
    $guiRefusals['another binary'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath (Join-Path $guiScratch 'staged.json') -ArgumentList $guiAppArgs
    # H1 on #740: an app launch without an explicit single-instance policy, a class without this run's token, and an
    # IPC action without a class are each refused before anything starts.
    $guiRefusals['an app launch without --single-instance=false'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList @("--class=noctty-interactive-x-$guiToken")
    $guiRefusals['a class without the run token'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList @('--single-instance=false', '--class=noctty-interactive-x')
    $guiRefusals['another run''s class'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList @('--single-instance=false', "--class=noctty-interactive-x-$([guid]::NewGuid().ToString('N'))")
    $guiRefusals['an IPC action without a class'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiCli -ArgumentList @('+list-windows')
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $null
    $guiRefusals['measurement mode unset'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList $guiAppArgs
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
    Remove-Item -LiteralPath (Join-Path $guiCopy 'noctty.portable')
    $guiRefusals['no portable marker'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList $guiAppArgs
    [IO.File]::WriteAllText((Join-Path $guiCopy 'noctty.portable'), '')
    [IO.File]::WriteAllText((Join-Path $guiCopy 'noctty.ico'), 'icon')
    $guiRefusals['noctty.ico beside it'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList $guiAppArgs
    Remove-Item -LiteralPath (Join-Path $guiCopy 'noctty.ico')
    Start-Sleep -Milliseconds 20
    [IO.File]::WriteAllText($guiApp, 'replaced ' + [guid]::NewGuid())
    $guiRefusals['the app replaced after staging'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp -ArgumentList $guiAppArgs
    foreach ($entry in $guiRefusals.GetEnumerator()) { if (-not $entry.Value) { throw "The launcher admitted $($entry.Key)." } }
    # H1 on #740: two runs of one leaf from one checkout share neither a sandbox nor a class. Each run's token gives
    # a sandbox under its own run directory and an id ending in the token; one run's class fails the other's rule.
    $guiLayouts = foreach ($token in @($guiToken, [guid]::NewGuid().ToString('N'))) {
        & $guiStage (& $guiHashOf $guiApp) (& $guiHashOf $guiCli) $token
        [pscustomobject]@{ Token = $token; Layout = (Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName 'smoke') }
    }
    foreach ($entry in $guiLayouts) {
        if (-not (Test-InteractiveWin11SamePath $entry.Layout.SandboxRoot (Join-Path $guiScratch "sandbox-$($entry.Token)")) -or
            -not $entry.Layout.SandboxId.EndsWith("-$($entry.Token)", [StringComparison]::Ordinal)) {
            throw 'A hosted sandbox must sit under its run directory, named and suffixed by its run token.'
        }
    }
    if ([string]::Equals($guiLayouts[0].Layout.SandboxRoot, $guiLayouts[1].Layout.SandboxRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($guiLayouts[0].Layout.SandboxId, $guiLayouts[1].Layout.SandboxId, [StringComparison]::Ordinal)) {
        throw 'Two runs shared a hosted sandbox or class.'
    }
    $guiOtherClass = @('--single-instance=true', "--class=noctty-interactive-$($guiLayouts[1].Layout.SandboxId)")
    if ((Get-InteractiveWin11HostedArgumentRefusal -Arguments $guiOtherClass -Token $guiLayouts[1].Token) -or
        -not (Get-InteractiveWin11HostedArgumentRefusal -Arguments $guiOtherClass -Token $guiLayouts[0].Token)) {
        throw 'A run''s class must pass its own run''s rule and fail another''s.'
    }
    $guiLeafText = Get-GuiContractFunctionText $guiRunnerAst 'Invoke-GuiHiddenLeaf'
    if (-not $guiLeafText.Contains('$token = [guid]::NewGuid().ToString(''N'')') -or -not $guiLeafText.Contains('runToken = $token')) {
        throw 'The runner must draw a fresh run token for every leaf it runs and stage it.'
    }
    & $guiStage (& $guiHashOf $guiApp) (& $guiHashOf $guiCli)
    # The staged identity refuses a CLI that is not the receipt's, with the app unchanged.
    [IO.File]::WriteAllText($guiApp, 'app2 ' + [guid]::NewGuid())
    & $guiStage (& $guiHashOf $guiApp) ('0' * 64)
    $guiIdentityRefused = $false
    try { [void](Initialize-InteractiveWin11HostedIdentity) } catch { $guiIdentityRefused = $true }
    if (-not $guiIdentityRefused) { throw 'The staged identity accepted a CLI that is not the receipt''s.' }

    # ---- (4) the launcher starts nothing it refuses, and keeps nothing whose command line it cannot read back as its
    # own: the native half swapped for a recording stand-in (the "process" it returns is this one, never resumed).
    if (-not ('GuiHiddenContractLaunch' -as [type])) {
        Add-Type -TypeDefinition @'
public static class GuiHiddenContractLaunch {
    public struct Pi { public System.IntPtr process, thread; public int pid, tid; }
    public static int Starts, Terminates, Resumes;
    public static string[] NextArgv;
    public static string RecordPath;
    public static bool RecordedBeforeResume;
    public static Pi Start(string app, string command, string cwd, string desktop, string stdout, string stderr) {
        Starts++; return new Pi { pid = System.Diagnostics.Process.GetCurrentProcess().Id };
    }
    public static string[] Argv(System.IntPtr process) { return NextArgv; }
    public static long CreationTime(System.IntPtr process) { return 1; }
    public static uint ResumeThread(System.IntPtr thread) {
        Resumes++;
        RecordedBeforeResume = RecordPath != null && System.IO.File.Exists(RecordPath) && System.IO.File.ReadAllText(RecordPath).Length > 0;
        return 0;
    }
    public static bool TerminateProcess(System.IntPtr process, uint code) { Terminates++; return true; }
    public static bool CloseHandle(System.IntPtr handle) { return true; }
    public static void Assert(string expected) { }
}
'@
    }
    $guiStartText = (Get-GuiContractFunctionText $guiLibAst 'Start-InteractiveWin11HostedProcess').
        Replace('[InteractiveWin11HostedLaunch]::', '[GuiHiddenContractLaunch]::').
        Replace('[InteractiveWin11HostedDesktop]::Assert(', '[GuiHiddenContractLaunch]::Assert(')
    if ($guiStartText.Contains('[InteractiveWin11HostedLaunch]::') -or -not $guiStartText.Contains('[GuiHiddenContractLaunch]::Start(') -or
        -not $guiStartText.Contains('[GuiHiddenContractLaunch]::Argv(')) { throw 'The launcher stand-in lost its anchor.' }
    . ([scriptblock]::Create($guiStartText))
    & $guiStage (& $guiHashOf $guiApp) (& $guiHashOf $guiCli)
    $script:InteractiveWin11HostedIdentity = Initialize-InteractiveWin11HostedIdentity
    $guiPidRecord = Join-Path $guiScratch 'launcher-pids.txt'
    [GuiHiddenContractLaunch]::RecordPath = $guiPidRecord
    foreach ($refused in @(
            @{ Name = 'another binary'; File = (Join-Path $guiScratch 'staged.json'); Arguments = $guiAppArgs }
            @{ Name = '--command in argv'; File = $guiApp; Arguments = @($guiAppArgs) + @('--command=cmd.exe') }
            @{ Name = 'a quoted argument'; File = $guiApp; Arguments = @($guiAppArgs) + @('a"b') }
            @{ Name = 'an app launch without --single-instance'; File = $guiApp; Arguments = @("--class=noctty-interactive-x-$guiToken") }
        )) {
        [GuiHiddenContractLaunch]::Starts = 0
        $threw = $false
        try { [void](Start-InteractiveWin11HostedProcess -FilePath $refused.File -ArgumentList $refused.Arguments -WorkingDirectory $guiScratch) } catch { $threw = $true }
        if (-not $threw -or [GuiHiddenContractLaunch]::Starts -ne 0) { throw "The launcher reached its native start for $($refused.Name)." }
    }
    # A started process whose command line reads back otherwise than the launcher built it is ended, never recorded.
    foreach ($readBack in @(
            @{ Name = 'an extra argument'; Argv = @($guiApp) + @($guiAppArgs) + @('--single-instance=true') }
            @{ Name = 'another class'; Argv = @($guiApp, '--single-instance=false', '--class=noctty-interactive-x') }
            @{ Name = 'an unreadable command line'; Argv = $null }
        )) {
        [GuiHiddenContractLaunch]::Starts = 0; [GuiHiddenContractLaunch]::Terminates = 0; [GuiHiddenContractLaunch]::Resumes = 0
        [GuiHiddenContractLaunch]::NextArgv = $readBack.Argv
        $threw = $false
        try { [void](Start-InteractiveWin11HostedProcess -FilePath $guiApp -ArgumentList $guiAppArgs -WorkingDirectory $guiScratch) } catch { $threw = $true }
        if (-not $threw -or [GuiHiddenContractLaunch]::Terminates -ne 1 -or [GuiHiddenContractLaunch]::Resumes -ne 0 -or (Test-Path -LiteralPath $guiPidRecord)) {
            throw "The launcher ran or kept a process whose command line read back with $($readBack.Name)."
        }
    }
    [GuiHiddenContractLaunch]::Starts = 0; [GuiHiddenContractLaunch]::Terminates = 0; [GuiHiddenContractLaunch]::Resumes = 0
    [GuiHiddenContractLaunch]::NextArgv = @($guiApp) + @($guiAppArgs)
    $guiStarted = Start-InteractiveWin11HostedProcess -FilePath $guiApp -ArgumentList $guiAppArgs -WorkingDirectory $guiScratch
    if ([GuiHiddenContractLaunch]::Starts -ne 1 -or [GuiHiddenContractLaunch]::Terminates -ne 0 -or [GuiHiddenContractLaunch]::Resumes -ne 1 -or
        -not [GuiHiddenContractLaunch]::RecordedBeforeResume -or $null -eq $guiStarted -or @([IO.File]::ReadAllLines($guiPidRecord)).Count -ne 1) {
        throw 'The launcher stand-in never saw the admitted start, resumed only after its PID record (the control''s positive half).'
    }
    # An 8.3 spelling of the staged app is the same file (#740's first hosted run: TEMP is C:\Users\RUNNER~1\... there).
    $guiShortCopy = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($guiCopy).ShortPath
    if ([string]::Equals($guiShortCopy, $guiCopy, [StringComparison]::OrdinalIgnoreCase)) { Write-Host 'Contracts.99-GuiHiddenLaunch short-name control: SKIPPED (this volume keeps no 8.3 names)' }
    elseif (Get-InteractiveWin11HostedLaunchRefusal -FilePath (Join-Path $guiShortCopy 'noctty.exe') -FileOnly) { throw 'The launcher refused the staged app spelled with an 8.3 name.' }
}
finally {
    foreach ($entry in $guiSavedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    $script:InteractiveWin11HostedIdentity = $null
    Remove-Item -LiteralPath $guiScratch -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- (5) staging: only the receipt's app and CLI become a copy; no icon, no PDB, the marker and the policy config.
if (-not ('GuiHiddenRunnerNative' -as [type])) {
    $guiRunnerAddType = @(Get-NamedCommands -Ast $guiRunnerAst -Name 'Add-Type')
    if ($guiRunnerAddType.Count -ne 1) { throw 'The runner must define its native surface through one Add-Type.' }
    $guiRunnerType = Get-CommandParameterArgument -Command $guiRunnerAddType[0] -Name 'TypeDefinition'
    if ($guiRunnerType -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { throw 'The runner''s native surface must be one literal Add-Type.' }
    Add-Type -TypeDefinition $guiRunnerType.Value
}
$guiRunnerSource = (Get-CommandParameterArgument -Command @(Get-NamedCommands -Ast $guiRunnerAst -Name 'Add-Type')[0] -Name 'TypeDefinition').Value
Assert-GuiContractLayout $guiRunnerAst $guiRunnerSource 'GuiHiddenRunnerNative' '$script:GuiHiddenNativeLayout' 'public uint volumeSerial, sizeHigh, sizeLow,' 'public uint volumeSerial, sizeLow, sizeHigh,'
foreach ($name in @('Get-GuiHiddenHash', 'Get-GuiHiddenBaseConfig', 'New-GuiHiddenCopy', 'Get-GuiHiddenProcessVerdict', 'ConvertTo-GuiHiddenRecordValue',
        'Write-GuiHiddenRecord', 'Get-GuiHiddenReparsePointCount', 'Test-GuiHiddenLeafReceipt', 'Get-GuiHiddenConfigPolicy')) {
    . ([scriptblock]::Create((Get-GuiContractFunctionText $guiRunnerAst $name)))
}
foreach ($name in @('Get-InteractiveWin11HostedPolicyConfig', 'Get-InteractiveWin11HostedArgumentRefusal')) {
    . ([scriptblock]::Create((Get-GuiContractFunctionText $guiLibAst $name)))
}
# The runner's list of the files it hashes, from its own text.
$guiBuildFilesAssignment = @($guiRunnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:GuiHiddenBuildFiles' }, $true))
if ($guiBuildFilesAssignment.Count -ne 1) { throw 'The runner must list the files it hashes once.' }
. ([scriptblock]::Create($guiBuildFilesAssignment[0].Extent.Text))
if (@($script:GuiHiddenBuildFiles.Name) -join ',' -cne 'noctty.exe,noctty.com,conpty.dll,OpenConsole.exe') { throw 'The runner must hash the app, the CLI and the ConPTY pair.' }
$guiScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-gui-hidden-stage-' + [guid]::NewGuid().ToString('N'))
try {
    $guiBin = Join-Path $guiScratch 'prefix\bin'
    [void](New-Item -ItemType Directory -Path $guiBin, (Join-Path $guiScratch 'prefix\share\ghostty'))
    foreach ($file in @('noctty.exe', 'noctty.com', 'noctty.ico', 'noctty.pdb', 'conpty.dll', 'OpenConsole.exe')) { [IO.File]::WriteAllText((Join-Path $guiBin $file), "$file " + [guid]::NewGuid()) }
    $guiBuild = [ordered]@{}
    foreach ($file in $script:GuiHiddenBuildFiles) { $guiBuild[$file.Key] = Get-GuiHiddenHash (Join-Path $guiBin $file.Name) }
    $guiGood = Join-Path $guiScratch 'good'
    New-GuiHiddenCopy -Bin $guiBin -Copy $guiGood -Build $guiBuild
    $guiCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $guiConfig = @([IO.File]::ReadAllLines((Join-Path $guiGood 'config.ghostty')))
    if (-not [IO.File]::Exists((Join-Path $guiGood 'noctty.portable')) -or [IO.File]::Exists((Join-Path $guiGood 'noctty.ico')) -or
        [IO.File]::Exists((Join-Path $guiGood 'noctty.pdb')) -or -not [IO.Directory]::Exists((Join-Path $guiGood 'share\ghostty')) -or
        @($guiConfig | Where-Object { [string]::Equals($_, "command = direct:$guiCmd /D", [StringComparison]::Ordinal) }).Count -ne 1 -or
        @($guiConfig | Where-Object { [string]::Equals($_, 'window-save-state = never', [StringComparison]::Ordinal) }).Count -ne 1) {
        throw 'A staged copy must carry the marker, the share tree and the policy config, and no icon or PDB.'
    }
    foreach ($bad in @(
            @{ Name = 'an ordinary build (the app is not the receipt''s)'; Key = 'exeSha256' }
            @{ Name = 'a substituted CLI with the app unchanged'; Key = 'cliSha256' }
            @{ Name = 'a substituted conpty.dll (Sol H2 on #740)'; Key = 'conptyDllSha256' }
            @{ Name = 'a substituted OpenConsole.exe'; Key = 'openConsoleSha256' }
        )) {
        $build = [ordered]@{}; foreach ($key in $guiBuild.Keys) { $build[$key] = $guiBuild[$key] }
        $build[$bad.Key] = '1' * 64
        $threw = $false
        try { New-GuiHiddenCopy -Bin $guiBin -Copy (Join-Path $guiScratch ([guid]::NewGuid().ToString('N'))) -Build $build } catch { $threw = $true }
        if (-not $threw) { throw "Staging accepted $($bad.Name)." }
    }
    foreach ($missing in @('noctty.com', 'OpenConsole.exe')) {
        $bin = Join-Path $guiScratch "bin-without-$missing\bin"
        [void](New-Item -ItemType Directory -Path $bin, (Join-Path (Split-Path -Parent $bin) 'share\ghostty'))
        Get-ChildItem -LiteralPath $guiBin -File | Where-Object { $_.Name -cne $missing } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $bin }
        $threw = $false
        try { New-GuiHiddenCopy -Bin $bin -Copy (Join-Path $guiScratch "copy-without-$missing") -Build $guiBuild } catch { $threw = $true }
        if (-not $threw) { throw "Staging accepted a generation without its $missing." }
    }

    # ---- (6) reparse points: one junction under a root is counted, none is not.
    $guiPlain = Join-Path $guiScratch 'plain'
    [void](New-Item -ItemType Directory -Path (Join-Path $guiPlain 'a\b'))
    if ((Get-GuiHiddenReparsePointCount @($guiPlain)) -ne 0) { throw 'The reparse scan counted a plain tree.' }
    # The junction points outside the scanned root, at a directory holding a sentinel: the scan counts the junction
    # and never lists anything through it.
    $guiOutside = Join-Path $guiScratch 'outside'
    [void](New-Item -ItemType Directory -Path $guiOutside)
    [IO.File]::WriteAllText((Join-Path $guiOutside 'sentinel.txt'), 'never read')
    [void](New-Item -ItemType Junction -Path (Join-Path $guiPlain 'a\link') -Target $guiOutside)
    $guiVisited = [System.Collections.Generic.List[string]]::new()
    if ((Get-GuiHiddenReparsePointCount @($guiPlain) $guiVisited) -ne 1) { throw 'The reparse scan missed a junction (the AutoRun symptom).' }
    if (@($guiVisited | Where-Object { $_.EndsWith('sentinel.txt', [StringComparison]::OrdinalIgnoreCase) }).Count -ne 0) {
        throw 'The reparse scan followed a junction to its target.'
    }

    # ---- (7) the record writer: a path, a command line or an odd key never reaches the file.
    $guiRecordPath = Join-Path $guiScratch 'record.json'
    $guiRejected = Write-GuiHiddenRecord ([ordered]@{ leaf = 'smoke'; path = 'C:\Users\someone\x'; line = '"cmd.exe" /D'; 'bad_key' = 1; ok = 3 }) $guiRecordPath
    $guiRecordText = [IO.File]::ReadAllText($guiRecordPath)
    if ($guiRejected -ne 3 -or $guiRecordText.Contains('someone') -or $guiRecordText.Contains('cmd.exe') -or $guiRecordText.Contains('bad_key')) {
        throw 'The runner''s record writer let a path, a command line or an odd key through.'
    }
    # A record with a rejected value is written failed, so the receipt and the result agree (CodeRabbit on #740).
    [void](Write-GuiHiddenRecord ([ordered]@{ leaf = 'smoke'; passed = $true; path = 'C:\x' }) $guiRecordPath)
    if ((Get-Content -LiteralPath $guiRecordPath -Raw | ConvertFrom-Json).passed -ne $false) { throw 'The record writer wrote a passing record that held a rejected value.' }
    [void](Write-GuiHiddenRecord ([ordered]@{ leaf = 'smoke'; passed = $true }) $guiRecordPath)
    if ((Get-Content -LiteralPath $guiRecordPath -Raw | ConvertFrom-Json).passed -ne $true) { throw 'The record writer failed a clean passing record.' }

    # ---- (7b) the result's status: only exit 0 over the whole plan passes; a subset is skip; a runner failure is
    # error (CodeRabbit on #740). And the runner itself, started with a non-empty -Out or an unusable -MeasureRepo,
    # exits 2 without leaving a pass: nothing in a non-empty -Out, an error result in a new one.
    . ([scriptblock]::Create((Get-GuiContractFunctionText $guiRunnerAst 'Get-GuiHiddenResultStatus')))
    . ([scriptblock]::Create((Get-GuiContractFunctionText $guiRunnerAst 'Get-GuiHiddenGuardState')))
    foreach ($case in @(
            @{ Exit = 0; Subset = $false; All = $true; Guards = $true; Status = 'pass'; Leaves = 'pass' }
            @{ Exit = 0; Subset = $true; All = $true; Guards = $true; Status = 'skip'; Leaves = 'skip' }
            @{ Exit = 0; Subset = $false; All = $false; Guards = $true; Status = 'fail'; Leaves = 'fail' }
            @{ Exit = 1; Subset = $false; All = $false; Guards = $true; Status = 'fail'; Leaves = 'fail' }
            @{ Exit = 2; Subset = $false; All = $true; Guards = $true; Status = 'error'; Leaves = 'pass' }
            @{ Exit = 2; Subset = $false; All = $false; Guards = $true; Status = 'error'; Leaves = 'fail' }
            @{ Exit = 3; Subset = $false; All = $true; Guards = $true; Status = 'error'; Leaves = 'pass' }
            # Greptile on #740: a guard that never ran is never a pass, nor a skip.
            @{ Exit = 0; Subset = $false; All = $true; Guards = $false; Status = 'error'; Leaves = 'pass' }
            @{ Exit = 0; Subset = $true; All = $true; Guards = $false; Status = 'error'; Leaves = 'skip' }
        )) {
        $judged = Get-GuiHiddenResultStatus $case.Exit $case.Subset $case.All $case.Guards
        if ($judged.Status -cne $case.Status -or $judged.Leaves -cne $case.Leaves) { throw "The result status misjudged exit $($case.Exit), subset $($case.Subset), all passed $($case.All), guards held $($case.Guards)." }
    }
    foreach ($case in @(
            @{ Started = $true; Held = $true; State = 'held' }
            @{ Started = $true; Held = $false; State = 'tripped' }
            @{ Started = $true; Held = $null; State = 'not-run' }
            @{ Started = $false; Held = $null; State = 'not-run' }
            @{ Started = $false; Held = $true; State = 'not-run' }
        )) {
        if ((Get-GuiHiddenGuardState $case.Started $case.Held) -cne $case.State) { throw "The guard state misjudged started $($case.Started), held $($case.Held)." }
    }
    # The runner says the guards are held only when all three are `held`: no started-only or default `$true`.
    $guiRunnerText = [IO.File]::ReadAllText($guiRunnerPath)
    if (-not $guiRunnerText.Contains('$runRecord.stateGuardsHeld = @($runRecord.guards.Values | Where-Object { $_ -cne ''held'' }).Count -eq 0') -or
        [regex]::Matches($guiRunnerText, '\$runRecord\.stateGuardsHeld = ').Count -ne 2 -or -not $guiRunnerText.Contains('$runRecord.stateGuardsHeld = $false')) {
        throw 'The runner must hold the guards only when all three are held, false until then.'
    }
    $guiChild = (Get-Process -Id $PID).Path
    # The children below are expected to exit 2; a session that promotes native exit codes must not stop here first.
    $PSNativeCommandUseErrorActionPreference = $false
    $guiFullOut = Join-Path $guiScratch 'out-full'
    [void](New-Item -ItemType Directory -Path $guiFullOut)
    [IO.File]::WriteAllText((Join-Path $guiFullOut 'earlier.json'), '{}')
    & $guiChild -NoProfile -NonInteractive -File $guiRunnerPath -MeasureRepo $repoRoot -Work (Join-Path $guiScratch 'work-full') -Out $guiFullOut *> $null
    if ($LASTEXITCODE -ne 2 -or @(Get-ChildItem -LiteralPath $guiFullOut -Force).Count -ne 1 -or (Test-Path -LiteralPath (Join-Path $guiScratch 'work-full'))) {
        throw 'The runner must refuse a non-empty -Out with exit 2 and write nothing.'
    }
    $guiNewOut = Join-Path $guiScratch 'out-new'
    & $guiChild -NoProfile -NonInteractive -File $guiRunnerPath -MeasureRepo (Join-Path $guiScratch 'no-such-repo') -Work (Join-Path $guiScratch 'work-new') -Out $guiNewOut *> $null
    $guiErrorResult = $(if (Test-Path -LiteralPath (Join-Path $guiNewOut 'result.json')) { Get-Content -LiteralPath (Join-Path $guiNewOut 'result.json') -Raw | ConvertFrom-Json } else { $null })
    $guiErrorRun = $(if (Test-Path -LiteralPath (Join-Path $guiNewOut 'receipts\run.json')) { Get-Content -LiteralPath (Join-Path $guiNewOut 'receipts\run.json') -Raw | ConvertFrom-Json } else { $null })
    if ($LASTEXITCODE -ne 2 -or $null -eq $guiErrorResult -or $guiErrorResult.status -cne 'error' -or
        @($guiErrorResult.assertions | Where-Object { $_.status -ceq 'pass' -and $_.id -cin @('leaves-pass', 'state-guards') }).Count -ne 0 -or
        $null -eq $guiErrorRun -or $guiErrorRun.stateGuardsHeld -ne $false -or
        (@($guiErrorRun.guards.state, $guiErrorRun.guards.history, $guiErrorRun.guards.startup) -join ',') -cne 'not-run,not-run,not-run') {
        throw 'A runner validation failure must exit 2 with an error result, no passing leaves-pass or state-guards, and its guards not-run.'
    }
    $guiPublishOut = Join-Path $guiScratch 'out-publish'
    & $guiChild -NoProfile -NonInteractive -File $guiRunnerPath -PublishError helper-self-test -Out $guiPublishOut *> $null
    $guiPublished = $(if (Test-Path -LiteralPath (Join-Path $guiPublishOut 'result.json')) { Get-Content -LiteralPath (Join-Path $guiPublishOut 'result.json') -Raw | ConvertFrom-Json } else { $null })
    if ($LASTEXITCODE -ne 2 -or $null -eq $guiPublished -or $guiPublished.status -cne 'error' -or [string]$guiPublished.failure.message -cne 'exit 2 (helper-self-test)') {
        throw '-PublishError must exit 2 with an error result naming its kind.'
    }
    & $guiChild -NoProfile -NonInteractive -File $guiRunnerPath -PublishError 'Bad Kind' -Out (Join-Path $guiScratch 'out-badkind') *> $null
    if ($LASTEXITCODE -ne 2 -or (Test-Path -LiteralPath (Join-Path $guiScratch 'out-badkind'))) { throw '-PublishError must refuse a kind outside its shape before it writes.' }
    $guiAsciiOut = Join-Path $guiScratch 'out-ascii'
    & $guiChild -NoProfile -NonInteractive -File $guiRunnerPath -MeasureRepo $repoRoot -Work (Join-Path $guiScratch ('work-caf' + [char]0xE9)) -Out $guiAsciiOut *> $null
    if ($LASTEXITCODE -ne 2 -or (Test-Path -LiteralPath (Join-Path $guiScratch ('work-caf' + [char]0xE9)))) { throw 'The runner must refuse a non-ASCII -Work before it creates it.' }
    $guiImage = [IO.Path]::GetFullPath($guiRunnerPath)
    $guiShortDir = (New-Object -ComObject Scripting.FileSystemObject).GetFolder((Split-Path -Parent $guiImage)).ShortPath
    if (-not [GuiHiddenRunnerNative]::SameImage((Join-Path $guiShortDir (Split-Path -Leaf $guiImage)), $guiImage, [GuiHiddenRunnerNative]::FileId($guiImage))) { throw 'SameImage refused one file spelled two ways.' }
    if ([GuiHiddenRunnerNative]::SameImage($guiLibPath, $guiImage, [GuiHiddenRunnerNative]::FileId($guiImage))) { throw 'SameImage accepted another file.' }
}
finally { Remove-Item -LiteralPath $guiScratch -Recurse -Force -ErrorAction SilentlyContinue }

# ---- (8) the shell verdict: System32's cmd.exe with /D among the switches before /C, /R or /K (cmd runs /R as /C).
$guiSystemCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
foreach ($case in @(
        @{ Line = "`"$guiSystemCmd`" /D"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd /D"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd /d /c H:\x\payload.cmd"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd /D /K type seed.txt"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /C echo /D"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /K /D"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /R /D x"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /r /D x"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /D /R echo"; Read = 1; System = $true; Off = $true }
        @{ Line = 'cmd.exe /D'; Read = 1; System = $false; Off = $true }
        @{ Line = "$guiSystemCmd /D" + [char]27; Read = 0; System = $false; Off = $false }
        @{ Line = ''; Read = 0; System = $false; Off = $false }
    )) {
    $system = $false; $off = $false
    $read = [GuiHiddenRunnerNative]::CmdVerdict($case.Line, $guiSystemCmd, [ref]$system, [ref]$off)
    if ($read -ne $case.Read -or $system -ne $case.System -or $off -ne $case.Off) { throw "The shell verdict misjudged a command line (case $($case.Read)/$($case.System)/$($case.Off))." }
}

# ---- (9) the runner's process verdict, on synthetic joiners. The leaf is pid 100; its run token is $guiVerdictToken.
$guiVerdictToken = [guid]::NewGuid().ToString('N')
$guiGui = @('noctty.exe', '--single-instance=false', "--class=noctty-interactive-x-$guiVerdictToken", '-e', 'cmd')
$guiIpc = @('noctty.com', '+list-windows', "--class=noctty-automation-x-$guiVerdictToken")
$guiRow = { param($Id, $Image, $Parent, $Creation, [bool] $IsCmd = $false, [bool] $Read = $false, [bool] $System = $false, [bool] $Off = $false, [bool] $OpenFailed = $false, [string[]] $Argv = $null, [bool] $InCopy = $true)
    $isNoctty = $Image -ieq 'noctty.exe' -or $Image -ieq 'noctty.com'
    [pscustomobject]@{ Pid = $Id; Image = $Image; Parent = $Parent; Creation = $Creation; IsCmd = $IsCmd; CmdRead = $Read; CmdSystem = $System; CmdImageSystem = $System
        CmdAutoRunOff = $Off; OpenFailed = $OpenFailed; Unpinned = $false; IsNoctty = $isNoctty; InCopy = ($isNoctty -and $InCopy); Argv = $(if ($isNoctty) { $Argv } else { $null }) } }
$guiGoodRows = @(
    (& $guiRow 100 'pwsh.exe' 1 10)
    (& $guiRow 200 'noctty.exe' 100 20 -Argv $guiGui)
    (& $guiRow 300 'OpenConsole.exe' 200 30)
    (& $guiRow 400 'cmd.exe' 200 40 $true $true $true $true)
    (& $guiRow 500 'noctty.com' 400 50 -Argv @('noctty', '+help'))
    (& $guiRow 600 'noctty.com' 100 60 -Argv $guiIpc)
    (& $guiRow 700 'noctty.exe' 600 70 -Argv $guiIpc)
    (& $guiRow 710 'noctty.exe' 500 71 -Argv @('noctty', '+help'))
    (& $guiRow 450 'powershell.exe' 200 45)
    (& $guiRow 550 'noctty.com' 450 55 -Argv @('noctty', '+version'))
    (& $guiRow 560 'noctty.exe' 550 56 -Argv @('noctty', '+version'))
)
$guiLauncher = @{ 200 = [long]20; 600 = [long]60 }
$guiVerdict = { param($Rows, [int] $Total, [int] $Shells) Get-GuiHiddenProcessVerdict $Rows $guiLauncher $Total $Shells $guiVerdictToken 100 }
if (-not (& $guiVerdict $guiGoodRows 11 1).passed) { throw 'The process verdict failed a clean leaf (a launched app, the terminal shells'' CLIs, a launched CLI, and the noctty.exe each CLI forwards).' }
$guiWith = { param([object[]] $Extra) @($guiGoodRows) + @($Extra) }
$guiReplace = { param([int] $Id, $Row) @($guiGoodRows | ForEach-Object { if ($_.Pid -eq $Id) { $Row } else { $_ } }) }
foreach ($bad in @(
        @{ Name = 'a cmd without /D'; Rows = (& $guiReplace 400 (& $guiRow 400 'cmd.exe' 200 40 $true $true $true $false)); Total = 11; Shells = 1 }
        @{ Name = 'an unread cmd'; Rows = (& $guiReplace 400 (& $guiRow 400 'cmd.exe' 200 40 $true $false $false $false)); Total = 11; Shells = 1 }
        @{ Name = 'a cmd outside System32 (image or command line)'; Rows = (& $guiReplace 400 (& $guiRow 400 'cmd.exe' 200 40 $true $true $false $true)); Total = 11; Shells = 1 }
        @{ Name = 'fewer shells than declared'; Rows = $guiGoodRows; Total = 11; Shells = 2 }
        @{ Name = 'a joiner the reader never took'; Rows = $guiGoodRows; Total = 12; Shells = 1 }
        @{ Name = 'a joiner that could not be opened'; Rows = (& $guiWith @((& $guiRow 800 $null 0 0 $false $false $false $false $true))); Total = 12; Shells = 1 }
        @{ Name = 'a joiner opened and pinned whose image could not be read'; Rows = (& $guiWith @((& $guiRow 810 $null 100 81))); Total = 12; Shells = 1 }
        @{ Name = 'a noctty the leaf started itself'; Rows = (& $guiWith @((& $guiRow 900 'noctty.exe' 100 90 -Argv $guiGui))); Total = 12; Shells = 1 }
        @{ Name = 'a noctty with a reused launcher PID'; Rows = (& $guiReplace 200 (& $guiRow 200 'noctty.exe' 100 21 -Argv $guiGui)); Total = 11; Shells = 1 }
        @{ Name = 'a noctty forwarded by a noctty the leaf started itself'; Rows = (& $guiWith @((& $guiRow 900 'noctty.com' 100 90 -Argv $guiIpc), (& $guiRow 910 'noctty.exe' 900 91 -Argv $guiIpc))); Total = 13; Shells = 1 }
        @{ Name = 'a noctty whose parent PID was reused after it started'; Rows = (& $guiWith @((& $guiRow 920 'noctty.com' 400 39 -Argv @('noctty', '+help')))); Total = 12; Shells = 1 }
        # Opus M1 on #740: a shell the leaf itself started is not a shell inside the terminal.
        @{ Name = 'leaf -> powershell -> noctty.exe'; Rows = (& $guiWith @((& $guiRow 1000 'powershell.exe' 100 100), (& $guiRow 1010 'noctty.exe' 1000 101 -Argv $guiGui))); Total = 13; Shells = 1 }
        @{ Name = 'leaf -> pwsh -> noctty.exe'; Rows = (& $guiWith @((& $guiRow 1020 'pwsh.exe' 100 102), (& $guiRow 1030 'noctty.exe' 1020 103 -Argv $guiGui))); Total = 13; Shells = 1 }
        @{ Name = 'leaf -> System32 cmd /D -> noctty.exe'; Rows = (& $guiWith @((& $guiRow 1040 'cmd.exe' 100 104 $true $true $true $true), (& $guiRow 1050 'noctty.exe' 1040 105 -Argv $guiGui))); Total = 13; Shells = 1 }
        @{ Name = 'leaf -> powershell -> noctty.com'; Rows = (& $guiWith @((& $guiRow 1000 'powershell.exe' 100 100), (& $guiRow 1060 'noctty.com' 1000 106 -Argv @('noctty', '+help')))); Total = 13; Shells = 1 }
        @{ Name = 'leaf -> System32 cmd /D -> noctty.com'; Rows = (& $guiWith @((& $guiRow 1040 'cmd.exe' 100 104 $true $true $true $true), (& $guiRow 1070 'noctty.com' 1040 107 -Argv @('noctty', '+help')))); Total = 13; Shells = 2 }
        # H2 on #740: only the staged CLI may descend from a terminal shell, and only from the copy.
        @{ Name = 'a noctty.exe straight from a terminal shell'; Rows = (& $guiWith @((& $guiRow 1080 'noctty.exe' 400 108 -Argv $guiGui))); Total = 12; Shells = 1 }
        @{ Name = 'a terminal shell''s noctty.com outside the copy'; Rows = (& $guiReplace 500 (& $guiRow 500 'noctty.com' 400 50 -Argv @('noctty', '+help') -InCopy $false)); Total = 11; Shells = 1 }
        @{ Name = 'a launched noctty.exe outside the copy'; Rows = (& $guiReplace 200 (& $guiRow 200 'noctty.exe' 100 20 -Argv $guiGui -InCopy $false)); Total = 11; Shells = 1 }
        @{ Name = 'a noctty whose command line was not read'; Rows = (& $guiReplace 700 (& $guiRow 700 'noctty.exe' 600 70)); Total = 11; Shells = 1 }
        # H1 on #740: every noctty in the job keeps the argument rule.
        @{ Name = 'a launched app with another run''s class'; Rows = (& $guiReplace 200 (& $guiRow 200 'noctty.exe' 100 20 -Argv @('noctty.exe', '--single-instance=false', '--class=noctty-interactive-x'))); Total = 11; Shells = 1 }
        @{ Name = 'a launched app without --single-instance'; Rows = (& $guiReplace 200 (& $guiRow 200 'noctty.exe' 100 20 -Argv @('noctty.exe', "--class=noctty-interactive-x-$guiVerdictToken"))); Total = 11; Shells = 1 }
        @{ Name = 'an IPC action without a class'; Rows = (& $guiReplace 700 (& $guiRow 700 'noctty.exe' 600 70 -Argv @('noctty.com', '+new-window'))); Total = 11; Shells = 1 }
    )) {
    if ((& $guiVerdict $bad.Rows $bad.Total $bad.Shells).passed) { throw "The process verdict passed $($bad.Name)." }
}

# ---- (9b) the leaf receipt, judged strictly: a missing, null or mistyped field is invalid, never cast (Sol and
# CodeRabbit on #740).
$guiScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-gui-hidden-receipt-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $guiScratch)
    $guiReceipt = { param([string] $Text) $path = Join-Path $guiScratch ([guid]::NewGuid().ToString('N') + '.json'); [IO.File]::WriteAllText($path, $Text); Test-GuiHiddenLeafReceipt $path }
    $guiValid = & $guiReceipt '{"schemaVersion":1,"realInputLoaded":false,"psEdition":"Core","psVersion":"7.6"}'
    if (-not $guiValid.valid -or $guiValid.realInputLoaded -ne $false) { throw 'A complete receipt saying the module never loaded was refused.' }
    $guiLoaded = & $guiReceipt '{"schemaVersion":1,"realInputLoaded":true,"psEdition":"Desktop","psVersion":"5.1"}'
    if (-not $guiLoaded.valid -or $guiLoaded.realInputLoaded -ne $true) { throw 'A complete receipt saying the module loaded was misread.' }
    foreach ($bad in @(
            @{ Name = 'an empty object'; Text = '{}' }
            @{ Name = 'no realInputLoaded'; Text = '{"schemaVersion":1,"psEdition":"Core","psVersion":"7.6"}' }
            @{ Name = 'a null realInputLoaded'; Text = '{"schemaVersion":1,"realInputLoaded":null,"psEdition":"Core","psVersion":"7.6"}' }
            @{ Name = 'a string realInputLoaded'; Text = '{"schemaVersion":1,"realInputLoaded":"false","psEdition":"Core","psVersion":"7.6"}' }
            @{ Name = 'a number realInputLoaded'; Text = '{"schemaVersion":1,"realInputLoaded":0,"psEdition":"Core","psVersion":"7.6"}' }
            @{ Name = 'another schema'; Text = '{"schemaVersion":2,"realInputLoaded":false,"psEdition":"Core","psVersion":"7.6"}' }
            @{ Name = 'no psVersion'; Text = '{"schemaVersion":1,"realInputLoaded":false,"psEdition":"Core"}' }
            @{ Name = 'an array'; Text = '[]' }
            @{ Name = 'a one-element array holding a valid receipt'; Text = '[{"schemaVersion":1,"realInputLoaded":false,"psEdition":"Core","psVersion":"7.6"}]' }
            @{ Name = 'unparsable text'; Text = '{"schemaVersion":1,' }
        )) {
        if ((& $guiReceipt $bad.Text).valid) { throw "The receipt judge accepted $($bad.Name)." }
    }
    if ((Test-GuiHiddenLeafReceipt (Join-Path $guiScratch 'absent.json')).present) { throw 'The receipt judge saw a receipt that is not there.' }

    # ---- (9c) the launch policy is read back from the copy's config: a later line wins, and an override, a governed
    # key or an include fails it (Opus L5 on #740).
    $guiPolicyFile = Join-Path $guiScratch 'config.ghostty'
    $guiBase = @(Get-InteractiveWin11HostedPolicyConfig) + @('window-save-state = never')
    [IO.File]::WriteAllLines($guiPolicyFile, [string[]]$guiBase)
    $guiPolicy = Get-GuiHiddenConfigPolicy $guiPolicyFile
    if (-not $guiPolicy.held -or $guiPolicy.clipboardRead -cne 'deny' -or $guiPolicy.shellKind -cne 'config-direct-system32-cmd') { throw 'The policy read-back refused the policy''s own config.' }
    foreach ($bad in @(
            @{ Name = 'a later clipboard-read = allow'; Lines = @($guiBase) + @('clipboard-read = allow') }
            @{ Name = 'a later shell'; Lines = @($guiBase) + @('command = cmd.exe') }
            @{ Name = 'a class line'; Lines = @('class = noctty-x') + @($guiBase) }
            @{ Name = 'a single-instance line'; Lines = @('single-instance = true') + @($guiBase) }
            @{ Name = 'an include'; Lines = @($guiBase) + @('config-file = other.ghostty') }
            @{ Name = 'no policy at all'; Lines = @('confirm-close-surface = false') }
        )) {
        [IO.File]::WriteAllLines($guiPolicyFile, [string[]]$bad.Lines)
        if ((Get-GuiHiddenConfigPolicy $guiPolicyFile).held) { throw "The policy read-back held with $($bad.Name)." }
    }
}
finally { Remove-Item -LiteralPath $guiScratch -Recurse -Force -ErrorAction SilentlyContinue }

# ---- (9d) the argument rule, table-tested (H1 on #740).
$guiRuleToken = [guid]::NewGuid().ToString('N')
foreach ($case in @(
        @{ Args = @('--single-instance=false', "--class=noctty-x-$guiRuleToken"); Ok = $true }
        @{ Args = @('--single-instance=true', "--class=noctty-x-$guiRuleToken"); Ok = $true }
        @{ Args = @('--single-instance=true', '--single-instance=false', "--class=noctty-x-$guiRuleToken", '-e', 'cmd', '--class=anything'); Ok = $true }
        @{ Args = @('+version'); Ok = $true }
        @{ Args = @('+vt-probe'); Ok = $true }
        @{ Args = @('+list-windows', "--class=noctty-x-$guiRuleToken"); Ok = $true }
        @{ Args = @("--class=noctty-x-$guiRuleToken"); Ok = $false }
        @{ Args = @('--single-instance=detect', "--class=noctty-x-$guiRuleToken"); Ok = $false }
        @{ Args = @('--single-instance=false'); Ok = $false }
        @{ Args = @('--single-instance=false', '--class=noctty-x'); Ok = $false }
        @{ Args = @('--single-instance=false', "--class=noctty-x-$guiRuleToken", '--class=noctty-y'); Ok = $false }
        @{ Args = @('+version', '--class=noctty-x'); Ok = $false }
        @{ Args = @('+list-windows'); Ok = $false }
        @{ Args = @('+new-window', '+help', "--class=noctty-x-$guiRuleToken"); Ok = $false }
        @{ Args = @('--single-instance=false', "--class=noctty-x-$guiRuleToken", '--config-file=x'); Ok = $false }
        @{ Args = @('--single-instance=false', "--class=noctty-x-$guiRuleToken", '--gtk-single-instance=true'); Ok = $false }
        @{ Args = @('--single-instance=false', '--class', "noctty-x-$guiRuleToken"); Ok = $false }
    )) {
    $refusal = Get-InteractiveWin11HostedArgumentRefusal -Arguments $case.Args -Token $guiRuleToken
    if (($null -eq $refusal) -ne $case.Ok) { throw "The argument rule misjudged: $($case.Args -join ' ')" }
}
if (-not (Get-InteractiveWin11HostedArgumentRefusal -Arguments @('+version') -Token '')) { throw 'The argument rule admitted a launch without a run token.' }

# ---- (9e) the run-time check (design §4.3), its three controls, each in a child pwsh with nothing else loaded:
# lib's own receipt block writes realInputLoaded true after the module's type loads (on a clean exit and on a throw)
# and false without it; and with NOCTTY_GUI_HIDDEN_DESKTOP set the module refuses to load, so a hosted call to its
# type finds no type (Opus L3 on #740).
$guiReceiptAssignment = @($guiLibAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$interactiveWin11HostedReceiptPath' }, $true))
$guiReceiptRegistration = @(Get-NamedCommands -Ast $guiLibAst -Name 'Register-EngineEvent')
if ($guiReceiptAssignment.Count -ne 1 -or $guiReceiptRegistration.Count -ne 1) { throw 'lib must write the leaf receipt from one PowerShell.Exiting registration.' }
$guiChildPwsh = (Get-Process -Id $PID).Path
$PSNativeCommandUseErrorActionPreference = $false
$guiScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-gui-hidden-runtime-' + [guid]::NewGuid().ToString('N'))
$guiSavedRun = $env:NOCTTY_GUI_HIDDEN_RUN
$guiSavedDesktop = $env:NOCTTY_GUI_HIDDEN_DESKTOP
try {
    [void](New-Item -ItemType Directory -Path $guiScratch)
    foreach ($case in @(
            @{ Name = 'clean exit, module absent'; Load = $false; End = 'exit 0'; Loaded = $false }
            @{ Name = 'clean exit, module loaded'; Load = $true; End = 'exit 0'; Loaded = $true }
            @{ Name = 'a throw, module loaded'; Load = $true; End = 'throw ''leaf failed'''; Loaded = $true }
        )) {
        $run = Join-Path $guiScratch ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $run)
        $script = Join-Path $run 'leaf.ps1'
        $load = $(if ($case.Load) { "Add-Type -TypeDefinition 'public static class InteractiveWin11RealInput { }'" } else { '' })
        [IO.File]::WriteAllText($script, ($guiReceiptAssignment[0].Extent.Text, $guiReceiptRegistration[0].Extent.Text, $load, $case.End -join "`n"))
        $env:NOCTTY_GUI_HIDDEN_RUN = $run
        & $guiChildPwsh -NoProfile -NonInteractive -File $script *> $null
        $judged = Test-GuiHiddenLeafReceipt (Join-Path $run 'leaf-receipt.json')
        if (-not $judged.valid -or $judged.realInputLoaded -ne $case.Loaded) { throw "lib's receipt block misreported the module ($($case.Name))." }
    }
    $env:NOCTTY_GUI_HIDDEN_RUN = $guiSavedRun
    $env:NOCTTY_GUI_HIDDEN_DESKTOP = 'WinSta0\noctty-gh-' + ('0' * 32)
    $probe = Join-Path $guiScratch 'module-probe.ps1'
    $module = Join-Path $repoRoot 'scripts\interactive-win11-realinput.ps1'
    [IO.File]::WriteAllText($probe, @"
`$refused = `$false
try { . '$($module.Replace("'", "''"))' } catch { `$refused = `$true }
`$typeAbsent = `$null -eq ('InteractiveWin11RealInput' -as [type])
`$callFailed = `$false
try { [void][InteractiveWin11RealInput]::ForceForeground([IntPtr]::Zero) } catch { `$callFailed = `$true }
if (`$refused -and `$typeAbsent -and `$callFailed) { exit 0 } else { exit 1 }
"@)
    & $guiChildPwsh -NoProfile -NonInteractive -File $probe *> $null
    if ($LASTEXITCODE -ne 0) { throw 'With NOCTTY_GUI_HIDDEN_DESKTOP set, the real-input module must refuse to load and a call to its type must fail.' }
}
finally {
    $env:NOCTTY_GUI_HIDDEN_RUN = $guiSavedRun
    $env:NOCTTY_GUI_HIDDEN_DESKTOP = $guiSavedDesktop
    Remove-Item -LiteralPath $guiScratch -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- (9f) the measurement record's hosted destinations name their workflow, receipt variant and gate, every one has
# an owner, and Q0's owners are exactly the plan's leaves (design §5.1; Opus L8 on #740).
$guiDestinationProblems = {
    param($Measurements, [string[]] $LeafIds)
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($measurement in @($Measurements.measurements)) {
        foreach ($obligation in @($measurement.governs)) {
            foreach ($destination in @($obligation.destinations)) {
                if ([string]$destination.kind -clike 'hosted*') {
                    foreach ($field in @('workflow', 'receipt', 'gate')) {
                        if ([string]::IsNullOrWhiteSpace([string]$destination.$field)) { $problems.Add("$($measurement.id) $field") }
                    }
                }
                if ([string]$destination.kind -cne 'disposition' -and @($destination.owner | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) { $problems.Add("$($measurement.id) owner") }
                if ([string]$measurement.id -ceq 'Q0' -and [string]$destination.kind -ceq 'hosted' -and
                    ($destination.owner -isnot [array] -or @($destination.owner).Count -ne $LeafIds.Count -or
                     @(for ($i = 0; $i -lt $LeafIds.Count; $i++) { if ([string]$destination.owner[$i] -cne $LeafIds[$i]) { $i } }).Count -ne 0 -or
                     [string]$destination.workflow -cne 'gui-hidden.yml')) { $problems.Add('Q0 owners') }
            }
        }
    }
    return , $problems.ToArray()
}
$guiPlanLeafIds = @((Get-Content -LiteralPath $guiPlanPath -Raw | ConvertFrom-Json).leaves | ForEach-Object { [string]$_.id })
$guiMeasurementText = Get-Content -LiteralPath $guiMeasurementsPath -Raw
$guiDestinationFound = & $guiDestinationProblems ($guiMeasurementText | ConvertFrom-Json) $guiPlanLeafIds
if ($guiDestinationFound.Count -ne 0) { throw "gui-measurements.json's destinations are underspecified: $($guiDestinationFound -join '; ')." }
foreach ($mutation in @(
        @{ Name = 'a hosted destination without its workflow'; Edit = { param($m) $m.measurements[0].governs[0].destinations[0].workflow = $null } }
        @{ Name = 'a provisional destination without its receipt variant'; Edit = { param($m) $m.measurements[1].governs[0].destinations[0].receipt = '' } }
        @{ Name = 'a destination without an owner'; Edit = { param($m) $m.measurements[2].governs[0].destinations[0].owner = $null } }
        @{ Name = 'Q0 owned by the plan file, not its leaves'; Edit = { param($m) $m.measurements[0].governs[0].destinations[0].owner = 'test/windows/gui-hidden-plan.json' } }
        @{ Name = 'Q0 owned by one comma-joined string'; Edit = { param($m) $m.measurements[0].governs[0].destinations[0].owner = 'vt-probe,smoke,shell-command,cli-automation,undo,session-restore' } }
    )) {
    $mutated = $guiMeasurementText | ConvertFrom-Json
    & $mutation.Edit $mutated
    $found = & $guiDestinationProblems $mutated $guiPlanLeafIds
    if ($found.Count -eq 0) { throw "The destination check accepted $($mutation.Name)." }
}

# ---- (10) every hosted leaf loads lib before the first write, launch or bootstrap it runs; and no launch that can
# start the copy or its CLI runs on a hosted path, in the leaves or in the library functions they reach (design §4.1).
# Order is read from what runs: a write inside a helper runs where the file calls the helper, not where it is defined,
# and a helper's own statements keep their order; only a load every hosted run reaches counts, one the hosted path can
# skip (in the switch's else, any other branch, a loop, a try) protects nothing (CodeRabbit on #740). A command is
# named as PowerShell calls it, a module qualifier dropped. A launch is found through the syntax tree, not by variable
# name (Opus on #740):
# Start-Process, [Diagnostics.Process]::Start, a ProcessStartInfo, or a `&`, `.` or bare call whose callee the
# walker's resolver (scripts/ci-script-closure.ps1) cannot prove to be some other program. Each must sit in the else
# of an `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP)` whose then-branch uses the hosted launcher (that switch, not the
# nearest `if`: CodeRabbit on #740), or after a hosted tripwire that throws before it (a function's first
# `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw }`, or vt-probe's `if ($Runtime -and $env:NOCTTY_GUI_HIDDEN_DESKTOP)
# { throw }` before its `if ($Runtime)`). A Process start whose FileName is a known program other than noctty and a
# shell (lib's System32 taskkill) is not one; nor is the hosted launcher's own [InteractiveWin11HostedLaunch]::Start.
$guiPlan = Get-Content -LiteralPath $guiPlanPath -Raw | ConvertFrom-Json
$guiLibraryFiles = @('scripts\interactive-win11-lib.ps1', 'scripts\interactive-win11-window-lib.ps1', 'scripts\interactive-win11-state-guard.ps1',
    'scripts\windows-harness-history.ps1', 'test\windows\hidden-win11-local-lib.ps1', 'test\windows\interactive-win11-stateful-lib.ps1') |
    ForEach-Object { Join-Path $repoRoot $_ }
$guiLeafFiles = @($guiPlan.leaves | ForEach-Object { Join-Path $repoRoot ([string]$_.script) })
$guiFirstUseNames = @('Invoke-InteractiveWin11HarnessMain', 'Invoke-InteractiveWin11Bootstrap', 'Initialize-InteractiveWin11Sandbox', 'Start-Process', 'Set-Content', 'New-Item', 'Out-File')

function Get-GuiLaunchFunctionOf($Node) {
    # The innermost function definition around a node, or $null at the script's own level.
    for ($walk = $Node.Parent; $null -ne $walk; $walk = $walk.Parent) {
        if ($walk -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $walk }
    }
    return $null
}

function Get-GuiLaunchCommandName($Command) {
    # The cmdlet or function a command calls, lower-case, with a module qualifier dropped
    # (Microsoft.PowerShell.Management\Set-Content is Set-Content): scripts/ci-script-closure.ps1's rule.
    $first = $Command.CommandElements[0]
    if ($first -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
    if ($first.Value -match '\A[A-Za-z][\w.]*\\(?<name>[A-Za-z]+-[A-Za-z]\w*)\z') { return $Matches['name'].ToLowerInvariant() }
    return $first.Value.ToLowerInvariant()
}

function Get-GuiLaunchChains($Ast, $Node, [hashtable] $Memo) {
    # Every way a node runs in the file's own flow: each a list of nodes, the calls that reach it outermost first and
    # the node last (Nodes). Outside any function, the node alone; in a function, each chain that reaches a call of
    # that function, then the node; none when nothing calls it. A write inside a helper runs where the file calls the
    # helper, not where it is defined (CodeRabbit on #740).
    $function = Get-GuiLaunchFunctionOf $Node
    if ($null -eq $function) { return , @([pscustomobject]@{ Nodes = [object[]]@($Node) }) }
    $key = $function.Extent.StartOffset
    if (-not $Memo.ContainsKey($key)) {
        # A recursive call adds no chain while its own are being found.
        $Memo[$key] = @()
        $calls = [System.Collections.Generic.List[object]]::new()
        $name = $function.Name.ToLowerInvariant()
        foreach ($call in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]::Equals($n.GetCommandName(), $name, [StringComparison]::OrdinalIgnoreCase) }.GetNewClosure(), $true))) {
            foreach ($chain in (Get-GuiLaunchChains $Ast $call $Memo)) { $calls.Add($chain) }
        }
        $Memo[$key] = $calls.ToArray()
    }
    return , @(foreach ($chain in $Memo[$key]) { [pscustomobject]@{ Nodes = [object[]](@($chain.Nodes) + @($Node)) } })
}

function Test-GuiLaunchRunsFirst($Node, $Target) {
    # True when $Node has run whenever its scope reaches $Target on the hosted path (a hosted run sets
    # NOCTTY_GUI_HIDDEN_DESKTOP); with $Target $null, whenever its scope (the script, or the function around it) runs
    # to its end. Walking up from $Node, each container must pass control through to it: a pipeline, an assignment, the
    # then-branch of an `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP)`, or the body of a try with no catch (a throw there ends
    # the run, so what follows in the body ran after $Node). It succeeds at the first statement list that also holds
    # $Target after $Node; without a $Target, at its scope's own top level, when no `return` of its function comes
    # before it. Any other branch (the else of that switch included), a loop, a switch, a try with a catch, or a
    # scriptblock may skip $Node (CodeRabbit on #740); a try's finally runs after a throw in its body, so $Node does not
    # protect it.
    $end = $Node.Extent.EndOffset
    for ($walk = $Node.Parent; $null -ne $walk; $walk = $walk.Parent) {
        if ($walk -is [System.Management.Automation.Language.PipelineAst] -or $walk -is [System.Management.Automation.Language.CommandExpressionAst] -or
            $walk -is [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        if ($walk -isnot [System.Management.Automation.Language.NamedBlockAst] -and $walk -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $false }
        if ($null -ne $Target -and $Target.Extent.StartOffset -ge $end -and $Target.Extent.EndOffset -le $walk.Extent.EndOffset) { return $true }
        $holder = $walk.Parent
        if ($walk -is [System.Management.Automation.Language.StatementBlockAst]) {
            if ($holder -is [System.Management.Automation.Language.IfStatementAst] -and [object]::ReferenceEquals($holder.Clauses[0].Item2, $walk) -and
                [string]::Equals($holder.Clauses[0].Item1.Extent.Text, '$env:NOCTTY_GUI_HIDDEN_DESKTOP', [StringComparison]::Ordinal)) { $walk = $holder; continue }
            if ($holder -is [System.Management.Automation.Language.TryStatementAst] -and [object]::ReferenceEquals($holder.Body, $walk) -and $holder.CatchClauses.Count -eq 0) {
                if ($null -ne $Target -and $Target.Extent.StartOffset -ge $holder.Extent.StartOffset -and $Target.Extent.EndOffset -le $holder.Extent.EndOffset) { return $false }
                $walk = $holder
                continue
            }
            return $false
        }
        # The top level of a scope: the script's, a function's, or a scriptblock's (which may run at any time).
        if ($null -ne $Target) { return $false }
        $owner = $holder.Parent
        if ($null -eq $owner) { return $true }
        if ($owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
        $returns = @($owner.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Extent.StartOffset -lt $end }, $true) | Where-Object {
            $scope = $_.Parent
            while ($scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $scope -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $scope = $scope.Parent }
            [object]::ReferenceEquals($scope, $owner)
        })
        return $returns.Count -eq 0
    }
    return $false
}

function Test-GuiLaunchRunsBefore($Load, $Use) {
    # True when the load chain runs before the use chain on every hosted run that reaches the use. Past the calls the
    # two share, they part at one step each in the same scope: the load's step must run before the use's there
    # (Test-GuiLaunchRunsFirst), and each later step of the load, inside the helpers it calls, must run whenever its
    # helper runs. Inside one helper the statements keep their own order (CodeRabbit on #740: a load and a write in
    # one helper shared the call's offset, and a strict comparison refused the load first).
    $loadNodes = $Load.Nodes
    $useNodes = $Use.Nodes
    $j = 0
    while ($j -lt $loadNodes.Count - 1 -and $j -lt $useNodes.Count - 1 -and [object]::ReferenceEquals($loadNodes[$j], $useNodes[$j])) { $j++ }
    if ([object]::ReferenceEquals($loadNodes[$j], $useNodes[$j])) { return $false }
    if (-not [object]::ReferenceEquals((Get-GuiLaunchFunctionOf $loadNodes[$j]), (Get-GuiLaunchFunctionOf $useNodes[$j]))) { return $false }
    if (-not (Test-GuiLaunchRunsFirst $loadNodes[$j] $useNodes[$j])) { return $false }
    for ($k = $j + 1; $k -lt $loadNodes.Count; $k++) { if (-not (Test-GuiLaunchRunsFirst $loadNodes[$k] $null)) { return $false } }
    return $true
}

function Test-GuiLaunchLibFirst($Ast, [string] $RepoPath) {
    # True when the file loads the interactive library before every write, launch or bootstrap it can run, on the
    # hosted path. A load counts only when the walker's resolver proves its target is scripts/interactive-win11-lib.ps1
    # (a `$libPath` naming some other file does not), and only where Test-GuiLaunchRunsBefore says it runs first: a
    # load the hosted path can skip, such as one in the switch's else, protects nothing (CodeRabbit on #740).
    . (Join-Path $repoRoot 'scripts\ci-script-closure.ps1')
    $context = New-CiScriptContext -RepoRoot $repoRoot -RepoPath $RepoPath -Ast $Ast
    $memo = @{}
    $loads = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true))) {
        $value = Resolve-CiScriptValue $node.CommandElements[0] $context
        $target = $(if ($value.Kind -eq 'path') { ConvertTo-CiScriptTargetPath -RepoRoot $repoRoot -Value $value.Value })
        if (-not [string]::Equals($target, 'scripts/interactive-win11-lib.ps1', [StringComparison]::Ordinal)) { continue }
        foreach ($chain in (Get-GuiLaunchChains $Ast $node $memo)) { $loads.Add($chain) }
    }
    if ($loads.Count -eq 0) { return $false }
    $useNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($guiFirstUseNames | ForEach-Object { $_.ToLowerInvariant() }), [StringComparer]::Ordinal)
    foreach ($node in @($Ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.CommandAst] -and $useNames.Contains([string](Get-GuiLaunchCommandName $n))) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and (Get-MemberExpressionName -Node $n) -match '\AWrite(AllText|AllLines|AllBytes)\z') }, $true))) {
        foreach ($use in (Get-GuiLaunchChains $Ast $node $memo)) {
            if (@($loads | Where-Object { Test-GuiLaunchRunsBefore $_ $use }).Count -eq 0) { return $false }
        }
    }
    return $true
}

function Get-GuiLaunchHostedSwitch($Node) {
    # The `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP)` with no other clause whose else-branch holds the node: the one that
    # accepted it, however many `if`s sit between; $null when there is none.
    for ($cursor = $Node.Parent; $null -ne $cursor; $cursor = $cursor.Parent) {
        if ($cursor -is [System.Management.Automation.Language.IfStatementAst] -and $cursor.Clauses.Count -eq 1 -and $null -ne $cursor.ElseClause -and
            [string]::Equals($cursor.Clauses[0].Item1.Extent.Text, '$env:NOCTTY_GUI_HIDDEN_DESKTOP', [StringComparison]::Ordinal) -and
            $Node.Extent.StartOffset -ge $cursor.ElseClause.Extent.StartOffset -and $Node.Extent.EndOffset -le $cursor.ElseClause.Extent.EndOffset) { return $cursor }
    }
    return $null
}

function Test-GuiLaunchTripwired($Node) {
    # True when a hosted refusal runs before the node: an `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw }`, or for a
    # node inside `if (<C>) { ... }`, an `if (<C> -and $env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw }`, that ends before the
    # node in a statement list that also holds it.
    $conditions = [System.Collections.Generic.List[string]]::new()
    $conditions.Add('$env:NOCTTY_GUI_HIDDEN_DESKTOP')
    for ($walk = $Node.Parent; $null -ne $walk; $walk = $walk.Parent) {
        if ($walk -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $walk.Clauses) {
                if ($Node.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $Node.Extent.EndOffset -le $clause.Item2.Extent.EndOffset) {
                    $conditions.Add($clause.Item1.Extent.Text + ' -and $env:NOCTTY_GUI_HIDDEN_DESKTOP')
                }
            }
        }
        if ($walk -is [System.Management.Automation.Language.NamedBlockAst] -or $walk -is [System.Management.Automation.Language.StatementBlockAst]) {
            foreach ($statement in $walk.Statements) {
                if ($statement.Extent.EndOffset -gt $Node.Extent.StartOffset) { break }
                if ($statement -is [System.Management.Automation.Language.IfStatementAst] -and $statement.Clauses.Count -eq 1 -and $null -eq $statement.ElseClause -and
                    @($statement.Clauses[0].Item2.Statements).Count -eq 1 -and @($statement.Clauses[0].Item2.Statements)[0] -is [System.Management.Automation.Language.ThrowStatementAst] -and
                    @($conditions | Where-Object { [string]::Equals($_, $statement.Clauses[0].Item1.Extent.Text, [StringComparison]::Ordinal) }).Count -gt 0) { return $true }
            }
        }
        if ($walk -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
    }
    return $false
}

function Get-GuiLaunchProblems {
    # The launches in one parsed file that can start the copy or its CLI on a hosted path: one line each.
    param([Parameter(Mandatory)] $Ast, [Parameter(Mandatory)] [string] $RepoPath)
    . (Join-Path $repoRoot 'scripts\ci-script-closure.ps1')
    $context = New-CiScriptContext -RepoRoot $repoRoot -RepoPath $RepoPath -Ast $Ast
    $found = [System.Collections.Generic.List[string]]::new()
    # Whether a resolved value can be the copy, its CLI, or a program that starts them (a shell).
    $canHold = {
        param($Value)
        if ($Value.Kind -eq 'scriptblock') { return $false }
        if ($Value.Kind -eq 'path' -and (Test-CiScriptTargetKind $Value.Value) -in @('script', 'batch')) { return $false }
        if ($Value.Kind -notin @('path', 'native') -or -not $Value.Value) { return $true }
        $leaf = ($Value.Value -split '[\\/]')[-1].ToLowerInvariant()
        if ($leaf -match '\A(noctty|cmd|powershell|pwsh)(\.exe|\.com)?\z' -or $leaf -match '(?i)\Aget-[a-z0-9-]*(exepath|clipath)\z') { return $true }
        if ($Value.Kind -eq 'path' -and (Test-CiScriptTargetKind $Value.Value) -ne 'native' -and $Value.Value -match '[\\/]') { return $true }
        return $false
    }
    # A Process start's program, from its start info's FileName assignments when it is a variable.
    $fileNameOf = {
        param($Node)
        if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $name = $Node.VariablePath.UserPath
            $values = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    $n.Left.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.Expression.VariablePath.UserPath -ieq $name -and
                    $n.Left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Left.Member.Value -ieq 'FileName' }.GetNewClosure(), $true) |
                ForEach-Object { Resolve-CiScriptValue $_.Right $context })
            if ($values.Count -eq 0) { return @{ Kind = 'unresolved'; Value = $null } }
            return Merge-CiScriptValues $values
        }
        return Resolve-CiScriptValue $Node $context
    }
    $sites = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -or $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $name = Get-GuiLaunchCommandName $node
            $first = $node.CommandElements[0]
            if (@('start-process', 'saps', 'start').Contains([string]$name)) { $sites.Add($node); continue }
            if ([string]::Equals($name, 'new-object', [StringComparison]::Ordinal) -and $node.Extent.Text -match '(?i)\bDiagnostics\.ProcessStartInfo\b') {
                $assigned = $node.Parent.Parent
                $target = $(if ($assigned -is [System.Management.Automation.Language.AssignmentStatementAst] -and $assigned.Left -is [System.Management.Automation.Language.VariableExpressionAst]) { $assigned.Left })
                if ($null -eq $target -or (& $canHold (& $fileNameOf $target))) { $sites.Add($node) }
                continue
            }
            $invoked = $node.InvocationOperator -in @([System.Management.Automation.Language.TokenKind]::Ampersand, [System.Management.Automation.Language.TokenKind]::Dot)
            $bare = $first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $first.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::BareWord -and
                ($first.Value -match '[\\/]' -or (Test-CiScriptTargetKind $first.Value) -ne 'other') -and $first.Value -notmatch '\A[A-Za-z][\w.]*\\[A-Za-z]+-[A-Za-z]\w*\z'
            $shell = $first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $first.Value -match '(?i)\A(cmd|powershell|pwsh)(\.exe)?\z'
            if (-not $invoked -and -not $bare -and -not $shell) { continue }
            if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            if (& $canHold (Resolve-CiScriptValue $first $context)) { $sites.Add($node) }
            continue
        }
        # [Diagnostics.Process]::Start(...) and [Diagnostics.ProcessStartInfo]::new(...)
        if (-not $node.Static -or $node.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { continue }
        $type = $node.Expression.TypeName.FullName
        $method = Get-MemberExpressionName -Node $node
        if ($type -match '(?i)\A(System\.)?Diagnostics\.Process\z' -and $method -ieq 'Start') {
            $argument = @($node.Arguments)[0]
            if ($null -eq $argument -or (& $canHold (& $fileNameOf $argument))) { $sites.Add($node) }
        } elseif ($type -match '(?i)\A(System\.)?Diagnostics\.ProcessStartInfo\z' -and $method -ieq 'new') {
            $assigned = $node.Parent.Parent
            $target = $(if ($assigned -is [System.Management.Automation.Language.AssignmentStatementAst] -and $assigned.Left -is [System.Management.Automation.Language.VariableExpressionAst]) { $assigned.Left })
            if ($null -eq $target -or (& $canHold (& $fileNameOf $target))) { $sites.Add($node) }
        }
    }
    foreach ($site in $sites) {
        $switch = Get-GuiLaunchHostedSwitch $site
        if ($switch) {
            # A call of the hosted launcher in the hosted branch's own code: a comment or a string that names it starts
            # nothing, nor does a scriptblock or function the branch only defines (CodeRabbit on #740).
            $branch = $switch.Clauses[0].Item2
            $launchers = @($branch.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    @('start-interactivewin11hostedprocess', 'invoke-interactivewin11hostedprocess').Contains([string](Get-GuiLaunchCommandName $n)) }, $true) | Where-Object {
                    $inner = $_.Parent
                    while (-not [object]::ReferenceEquals($inner, $branch) -and $inner -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                        $inner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $inner = $inner.Parent }
                    [object]::ReferenceEquals($inner, $branch)
                })
            if ($launchers.Count -eq 0) {
                $found.Add("${RepoPath}: the hosted branch of the switch around line $($site.Extent.StartLineNumber) does not call the hosted launcher.")
            }
            continue
        }
        if (Test-GuiLaunchTripwired $site) { continue }
        $found.Add("${RepoPath}: line $($site.Extent.StartLineNumber) can start the copy or its CLI outside the else of an if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) switch and after no hosted tripwire.")
    }
    return , $found.ToArray()
}

foreach ($file in @($guiLeafFiles) + @($guiLibraryFiles)) {
    $ast = Get-GuiContractAst $file
    $guiLaunchRepoPath = [IO.Path]::GetRelativePath($repoRoot, $file).Replace('\', '/')
    if ($guiLeafFiles -contains $file -and -not (Test-GuiLaunchLibFirst $ast $guiLaunchRepoPath)) {
        throw "$file writes, launches or bootstraps before the interactive library (and its desktop check) loads, or never loads it."
    }
    $launchProblems = Get-GuiLaunchProblems -Ast $ast -RepoPath $guiLaunchRepoPath
    if ($launchProblems.Count -ne 0) { throw ($launchProblems -join ' ') }
}
# Controls, on synthetic files (each read as test/windows/order-fixture.ps1). The order check: a helper that writes
# runs where it is called; a load counts only where every hosted run reaches it; a helper keeps its own order.
$guiOrderLib = ". (Join-Path `$PSScriptRoot '..\..\scripts\interactive-win11-lib.ps1')"
$guiOrderHelper = "function Write-Seed { Set-Content -LiteralPath `$seed -Value 1 }"
$guiOrderWrite = "Set-Content -LiteralPath `$seed -Value 1"
foreach ($case in @(
        @{ Name = 'a helper called only after the load'; Accept = $true; Text = "$guiOrderHelper`n$guiOrderLib`nWrite-Seed" }
        @{ Name = 'a helper called before the load'; Accept = $false; Text = "$guiOrderHelper`nWrite-Seed`n$guiOrderLib" }
        @{ Name = 'a helper called from a helper called before the load'; Accept = $false; Text = "$guiOrderHelper`nfunction Initialize-Run { Write-Seed }`nInitialize-Run`n$guiOrderLib" }
        @{ Name = 'a write before the load'; Accept = $false; Text = "$guiOrderWrite`n$guiOrderLib" }
        @{ Name = 'a helper never called'; Accept = $true; Text = "$guiOrderHelper`n$guiOrderLib" }
        @{ Name = 'a load only in the switch''s else, then a write'; Accept = $false; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { `$hosted = 1 } else { $guiOrderLib }`n$guiOrderWrite" }
        @{ Name = 'a load in the switch''s hosted branch, then a write'; Accept = $true; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { $guiOrderLib } else { `$legacy = 1 }`n$guiOrderWrite" }
        @{ Name = 'a load under another condition, then a write'; Accept = $false; Text = "if (`$Fast) { $guiOrderLib }`n$guiOrderWrite" }
        @{ Name = 'a load in a try with a catch, then a write'; Accept = $false; Text = "try { $guiOrderLib } catch { }`n$guiOrderWrite" }
        @{ Name = 'a load, then a write, in one try with a catch'; Accept = $true; Text = "try { $guiOrderLib; $guiOrderWrite } catch { }" }
        @{ Name = 'a load, then a write, in a try with only a finally (the leaves'' wrapper)'; Accept = $true; Text = "try {`n$guiOrderLib`n$guiOrderWrite`n} finally { `$done = 1 }" }
        @{ Name = 'a write in the finally of the try that loads'; Accept = $false; Text = "try {`n$guiOrderLib`n} finally { $guiOrderWrite }" }
        @{ Name = 'a $libPath that names another script'; Accept = $false; Text = "`$libPath = Join-Path `$PSScriptRoot 'other-lib.ps1'`n. `$libPath`n$guiOrderWrite" }
        @{ Name = 'a loading helper called only in the switch''s else'; Accept = $false; Text = "function Initialize-Run { $guiOrderLib }`nif (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { `$hosted = 1 } else { Initialize-Run }`n$guiOrderWrite" }
        @{ Name = 'a loading helper whose early return can skip the load'; Accept = $false; Text = "function Initialize-Run { if (`$Skip) { return }; $guiOrderLib }`nInitialize-Run`n$guiOrderWrite" }
        @{ Name = 'a loading helper called first'; Accept = $true; Text = "function Initialize-Run { $guiOrderLib }`nInitialize-Run`n$guiOrderWrite" }
        @{ Name = 'one helper that loads, then writes'; Accept = $true; Text = "function Initialize-Run { $guiOrderLib; $guiOrderWrite }`nInitialize-Run" }
        @{ Name = 'one helper that writes, then loads'; Accept = $false; Text = "function Initialize-Run { $guiOrderWrite; $guiOrderLib }`nInitialize-Run" }
        @{ Name = 'one helper that loads then writes, first called under a condition'; Accept = $true; Text = "function Initialize-Run { $guiOrderLib; $guiOrderWrite }`nif (`$Early) { Initialize-Run }`nInitialize-Run" }
        @{ Name = 'a module-qualified write before the load'; Accept = $false; Text = "Microsoft.PowerShell.Management\$guiOrderWrite`n$guiOrderLib" }
    )) {
    $orderAst = [System.Management.Automation.Language.Parser]::ParseInput($case.Text, [ref]$null, [ref]$null)
    if ((Test-GuiLaunchLibFirst $orderAst 'test/windows/order-fixture.ps1') -ne $case.Accept) { throw "The load-order check misjudged $($case.Name) (expected accept=$($case.Accept))." }
}
# The launch ban: each control in a hosted path must be refused; each legitimate shape must pass.
$guiHostedLaunch = 'Start-InteractiveWin11HostedProcess -FilePath $exe -ArgumentList $a'
foreach ($case in @(
        @{ Name = 'a legacy launch in the else'; Accept = $true; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { $guiHostedLaunch } else { Start-Process -FilePath `$exe -ArgumentList `$a -PassThru }" }
        @{ Name = 'a legacy launch under a nested condition in the else'; Accept = $true; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { $guiHostedLaunch } else { if (`$Wait) { Start-Process -FilePath `$exe -Wait } else { Start-Process -FilePath `$exe } }" }
        @{ Name = 'an else whose hosted branch skips the launcher'; Accept = $false; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { `$p = 1 } else { if (`$Wait) { Start-Process -FilePath `$exe -Wait } }" }
        @{ Name = 'a hosted branch that names the launcher only in a comment'; Accept = $false; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) {`n    # $guiHostedLaunch`n    `$p = 1`n} else { Start-Process -FilePath `$exe }" }
        @{ Name = 'a hosted branch that names the launcher only in a string'; Accept = $false; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { Write-Host 'Start-InteractiveWin11HostedProcess' } else { Start-Process -FilePath `$exe }" }
        @{ Name = 'a hosted branch that only defines a scriptblock calling the launcher'; Accept = $false; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { `$later = { $guiHostedLaunch } } else { Start-Process -FilePath `$exe }" }
        @{ Name = 'a hosted branch that calls Invoke-InteractiveWin11HostedProcess'; Accept = $true; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { `$run = Invoke-InteractiveWin11HostedProcess -FilePath `$cli -ArgumentList `$a } else { `$run = Start-Process -FilePath `$cli -PassThru }" }
        @{ Name = 'a module-qualified Start-Process'; Accept = $false; Text = '$p = Microsoft.PowerShell.Management\Start-Process -FilePath $exe -PassThru' }
        @{ Name = 'a bare Start-Process'; Accept = $false; Text = '$p = Start-Process -FilePath $exe -PassThru' }
        @{ Name = '& $server from the exe path, in the hosted branch'; Accept = $false; Text = "`$server = Get-InteractiveWin11ExePath -RepoRoot `$r`nif (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { & `$server --x; $guiHostedLaunch } else { Start-Process -FilePath `$server }" }
        @{ Name = '& (Get-InteractiveWin11ExePath) in the hosted branch'; Accept = $false; Text = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { & (Get-InteractiveWin11ExePath -RepoRoot `$r) --x; $guiHostedLaunch } else { }" }
        @{ Name = 'the hosted exe variable called'; Accept = $false; Text = '& $env:NOCTTY_GUI_HIDDEN_EXE +version' }
        @{ Name = 'a CLI joined to the copy''s directory'; Accept = $false; Text = "`$cli = Join-Path `$dir 'noctty.com'`n& `$cli +list-windows" }
        @{ Name = 'Process.Start of the exe'; Accept = $false; Text = '$p = [System.Diagnostics.Process]::Start($exe, "--x")' }
        @{ Name = 'a ProcessStartInfo for the exe'; Accept = $false; Text = "`$psi = [Diagnostics.ProcessStartInfo]::new()`n`$psi.FileName = `$exe`n`$p = [Diagnostics.Process]::Start(`$psi)" }
        @{ Name = 'a shell that can start anything'; Accept = $false; Text = 'powershell.exe -NoProfile -Command "& $exe"' }
        @{ Name = 'System32 taskkill through a ProcessStartInfo'; Accept = $true; Text = "`$psi = [System.Diagnostics.ProcessStartInfo]::new()`n`$psi.FileName = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'`n`$t = [System.Diagnostics.Process]::Start(`$psi)" }
        @{ Name = 'a build behind a function''s hosted tripwire'; Accept = $true; Text = "function Invoke-Build { if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw 'never in hosted mode' }; & cmd /c `$devWindowsCmd zig build }" }
        @{ Name = 'vt-probe''s refused -Runtime children'; Accept = $true; Text = "if (`$Runtime -and `$env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw 'no -Runtime in hosted mode' }`nif (`$Runtime) { & powershell.exe @scriptArgs }" }
        @{ Name = 'a tripwire after the launch'; Accept = $false; Text = "function Invoke-Build { & cmd /c `$devWindowsCmd zig build; if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw 'too late' } }" }
        @{ Name = 'a callback, git and a script'; Accept = $true; Text = "`$check = { 1 }`n& `$check`n& git status`n& (Get-Command git.exe).Source log`n. (Join-Path `$PSScriptRoot 'helper.ps1')" }
    )) {
    $launchAst = [System.Management.Automation.Language.Parser]::ParseInput($case.Text, [ref]$null, [ref]$null)
    $launchProblems = Get-GuiLaunchProblems -Ast $launchAst -RepoPath 'test/windows/launch-fixture.ps1'
    if (($launchProblems.Count -eq 0) -ne $case.Accept) { throw "The launch ban misjudged $($case.Name) (expected accept=$($case.Accept)): $($launchProblems -join ' ')" }
}
# The hosted-switch helper the session check below uses still refuses a bare Start-Process.
$guiControlAst = [System.Management.Automation.Language.Parser]::ParseInput("`$p = Start-Process -FilePath `$exe -PassThru", [ref]$null, [ref]$null)
$guiControlLaunch = @(Get-NamedCommands -Ast $guiControlAst -Name 'Start-Process')[0]
if (Test-GuiContractInsideHostedSwitch $guiControlLaunch -ElseBranch) { throw 'The hosted-switch check accepted a bare Start-Process.' }

# vt-probe refuses -Runtime in hosted mode before it builds the runtime children's arguments (the legacy-only edge).
$guiVtProbe = Get-GuiContractAst (Join-Path $repoRoot 'test\windows\vt-probe-win32-conformance.ps1')
$guiRuntimeRefusal = @($guiVtProbe.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
    [string]::Equals($n.Clauses[0].Item1.Extent.Text, '$Runtime -and $env:NOCTTY_GUI_HIDDEN_DESKTOP', [StringComparison]::Ordinal) -and
    $n.Clauses[0].Item2.Extent.Text -match '\bthrow\b' }, $true))
$guiRuntimeChildren = @($guiVtProbe.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
    [string]::Equals($n.Clauses[0].Item1.Extent.Text, '$Runtime', [StringComparison]::Ordinal) -and
    $n.Clauses[0].Item2.Extent.Text.Contains('$runtimeHarnesses') }, $true))
if ($guiRuntimeRefusal.Count -ne 1 -or $guiRuntimeChildren.Count -ne 1 -or $guiRuntimeRefusal[0].Extent.StartOffset -gt $guiRuntimeChildren[0].Extent.StartOffset) {
    throw 'vt-probe must refuse -Runtime in hosted mode before it builds the runtime children.'
}

# ---- (11) session-restore's hosted comparison is of bytes: a case-only change escapes the old string comparison.
$guiScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-gui-hidden-case-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllText($guiScratch, '{"windows":[{"title":"abc"}]}')
    $guiBeforeText = Get-Content $guiScratch -Raw
    $guiBeforeHash = (Get-FileHash -LiteralPath $guiScratch -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($guiScratch, '{"windows":[{"title":"ABC"}]}')
    if ((Get-Content $guiScratch -Raw) -ne $guiBeforeText) { throw 'The case-only control is broken: -ne saw the change it should miss.' }
    if ([string]::Equals((Get-FileHash -LiteralPath $guiScratch -Algorithm SHA256).Hash, $guiBeforeHash, [StringComparison]::Ordinal)) { throw 'The byte comparison missed a case-only change.' }
}
finally { Remove-Item -LiteralPath $guiScratch -ErrorAction SilentlyContinue }
$guiSessionRestore = Get-GuiContractAst (Join-Path $repoRoot 'test\windows\interactive-win11-session-restore.ps1')
$guiHashCompare = @($guiSessionRestore.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
    $n.Clauses[0].Item1.Extent.Text.Contains('Get-FileHash -LiteralPath $statePath -Algorithm SHA256') -and
    $n.Clauses[0].Item1.Extent.Text.Contains('[StringComparison]::Ordinal') -and $n.Clauses[0].Item2.Extent.Text -match 'throw' }, $true) | Where-Object { Test-GuiContractInsideHostedSwitch $_ })
if ($guiHashCompare.Count -ne 1) { throw 'session-restore must compare the saved file''s bytes in hosted mode.' }

# ---- (12) the measurement record: Q0 and P1-P5 from #738's final hosted run, each with at least one obligation and
# each obligation with a non-empty destination set (CodeRabbit on #740: an empty or missing `governs` ran the
# destination checks zero times and passed).
function Get-GuiMeasurementProblems($Record) {
    $found = [System.Collections.Generic.List[string]]::new()
    $ids = @($Record.measurements | ForEach-Object { [string]$_.id })
    if ($Record.schemaVersion -ne 1 -or ($ids -join ',') -cne 'Q0,P1,P2,P3,P4,P5') { $found.Add('gui-measurements.json must hold Q0 and P1-P5, once each, in order.') }
    foreach ($measurement in @($Record.measurements)) {
        if ([string]$measurement.outcome -cnotin @('pass', 'fail', 'inconclusive') -or $measurement.runId -ne 44835461408 -or $measurement.attempt -ne 1 -or $measurement.pr -ne 738) {
            $found.Add("gui-measurements.json's $($measurement.id) must cite #738's final hosted run 44835461408, attempt 1, with a known outcome.")
        }
        $governs = $measurement.governs
        if ($null -eq $governs -or @($governs).Count -lt 1 -or @($governs | Where-Object { $null -eq $_ }).Count -ne 0) {
            $found.Add("gui-measurements.json's $($measurement.id) governs no obligation.")
            continue
        }
        foreach ($obligation in @($governs)) {
            if (@($obligation.destinations | Where-Object { $null -ne $_ }).Count -lt 1) { $found.Add("gui-measurements.json's $($measurement.id) leaves an obligation with no destination.") }
            foreach ($destination in @($obligation.destinations | Where-Object { $null -ne $_ })) {
                if ([string]$destination.kind -cnotin @('hosted', 'hosted:test-tools', 'hosted:product-identity', 'hosted:provisional', 'parity', 'visible', 'bench', 'unit', 'disposition')) {
                    $found.Add("gui-measurements.json's $($measurement.id) names an unknown destination kind.")
                }
                if ([string]$destination.kind -ceq 'disposition' -and [string]::IsNullOrWhiteSpace([string]$destination.reason)) {
                    $found.Add("gui-measurements.json's $($measurement.id) has a disposition without its reason.")
                }
            }
        }
    }
    return , $found.ToArray()
}
$guiMeasurementsText = Get-Content -LiteralPath $guiMeasurementsPath -Raw
$guiMeasurementProblems = Get-GuiMeasurementProblems ($guiMeasurementsText | ConvertFrom-Json)
if ($guiMeasurementProblems.Count -ne 0) { throw ($guiMeasurementProblems -join ' ') }
foreach ($control in @(
        @{ Name = 'P5 governing an empty list'; Change = { param($r) ($r.measurements | Where-Object { $_.id -ceq 'P5' }).governs = @() } }
        @{ Name = 'P5 with no governs'; Change = { param($r) ($r.measurements | Where-Object { $_.id -ceq 'P5' }).PSObject.Properties.Remove('governs') } }
        @{ Name = 'an obligation with no destination'; Change = { param($r) @(($r.measurements | Where-Object { $_.id -ceq 'P5' }).governs)[0].destinations = @() } }
    )) {
    $mutated = $guiMeasurementsText | ConvertFrom-Json
    & $control.Change $mutated
    $controlProblems = Get-GuiMeasurementProblems $mutated
    if ($controlProblems.Count -eq 0) { throw "The measurement record check accepted $($control.Name)." }
}
