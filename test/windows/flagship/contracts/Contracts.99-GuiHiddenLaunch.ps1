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
        if (-not [string]::Equals($entry.Layout.SandboxRoot, (Join-Path $guiScratch "sandbox-$($entry.Token)"), [StringComparison]::OrdinalIgnoreCase) -or
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
    public static int Starts, Terminates;
    public static string[] NextArgv;
    public static Pi Start(string app, string command, string cwd, string desktop, string stdout, string stderr) {
        Starts++; return new Pi { pid = System.Diagnostics.Process.GetCurrentProcess().Id };
    }
    public static string[] Argv(System.IntPtr process) { return NextArgv; }
    public static long CreationTime(System.IntPtr process) { return 1; }
    public static uint ResumeThread(System.IntPtr thread) { return 0; }
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
        [GuiHiddenContractLaunch]::Starts = 0; [GuiHiddenContractLaunch]::Terminates = 0
        [GuiHiddenContractLaunch]::NextArgv = $readBack.Argv
        $threw = $false
        try { [void](Start-InteractiveWin11HostedProcess -FilePath $guiApp -ArgumentList $guiAppArgs -WorkingDirectory $guiScratch) } catch { $threw = $true }
        if (-not $threw -or [GuiHiddenContractLaunch]::Terminates -ne 1 -or (Test-Path -LiteralPath $guiPidRecord)) { throw "The launcher kept a process whose command line read back with $($readBack.Name)." }
    }
    [GuiHiddenContractLaunch]::Starts = 0; [GuiHiddenContractLaunch]::Terminates = 0
    [GuiHiddenContractLaunch]::NextArgv = @($guiApp) + @($guiAppArgs)
    $guiStarted = Start-InteractiveWin11HostedProcess -FilePath $guiApp -ArgumentList $guiAppArgs -WorkingDirectory $guiScratch
    if ([GuiHiddenContractLaunch]::Starts -ne 1 -or [GuiHiddenContractLaunch]::Terminates -ne 0 -or $null -eq $guiStarted -or
        @([IO.File]::ReadAllLines($guiPidRecord)).Count -ne 1) { throw 'The launcher stand-in never saw the admitted start and its record (the control''s positive half).' }
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
    foreach ($case in @(
            @{ Exit = 0; Subset = $false; All = $true; Status = 'pass'; Leaves = 'pass' }
            @{ Exit = 0; Subset = $true; All = $true; Status = 'skip'; Leaves = 'skip' }
            @{ Exit = 0; Subset = $false; All = $false; Status = 'fail'; Leaves = 'fail' }
            @{ Exit = 1; Subset = $false; All = $false; Status = 'fail'; Leaves = 'fail' }
            @{ Exit = 2; Subset = $false; All = $true; Status = 'error'; Leaves = 'pass' }
            @{ Exit = 2; Subset = $false; All = $false; Status = 'error'; Leaves = 'fail' }
            @{ Exit = 3; Subset = $false; All = $true; Status = 'error'; Leaves = 'pass' }
        )) {
        $judged = Get-GuiHiddenResultStatus $case.Exit $case.Subset $case.All
        if ($judged.Status -cne $case.Status -or $judged.Leaves -cne $case.Leaves) { throw "The result status misjudged exit $($case.Exit), subset $($case.Subset), all passed $($case.All)." }
    }
    $guiChild = (Get-Process -Id $PID).Path
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
    if ($LASTEXITCODE -ne 2 -or $null -eq $guiErrorResult -or $guiErrorResult.status -cne 'error' -or
        @($guiErrorResult.assertions | Where-Object { $_.status -ceq 'pass' -and $_.id -ceq 'leaves-pass' }).Count -ne 0) {
        throw 'A runner validation failure must exit 2 with an error result and no passing leaves-pass.'
    }
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
                    ((@($destination.owner) -join ',') -cne ($LeafIds -join ',') -or [string]$destination.workflow -cne 'gui-hidden.yml')) { $problems.Add('Q0 owners') }
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
    )) {
    $mutated = $guiMeasurementText | ConvertFrom-Json
    & $mutation.Edit $mutated
    $found = & $guiDestinationProblems $mutated $guiPlanLeafIds
    if ($found.Count -eq 0) { throw "The destination check accepted $($mutation.Name)." }
}

# ---- (10) every hosted leaf and the stateful library: lib loads before the first write, launch or bootstrap, and every
# Start-Process or `& $cli` sits in the else of an `if ($env:NOCTTY_GUI_HIDDEN_DESKTOP)` whose then-branch uses the
# hosted launcher (design §4.1).
$guiPlan = Get-Content -LiteralPath $guiPlanPath -Raw | ConvertFrom-Json
$guiHostedFiles = @($guiPlan.leaves | ForEach-Object { Join-Path $repoRoot ([string]$_.script) }) + @($guiStatefulPath)
$guiFirstUseNames = @('Invoke-InteractiveWin11HarnessMain', 'Invoke-InteractiveWin11Bootstrap', 'Initialize-InteractiveWin11Sandbox', 'Start-Process', 'Set-Content', 'New-Item', 'Out-File')
foreach ($file in $guiHostedFiles) {
    $ast = Get-GuiContractAst $file
    $text = $ast.Extent.Text
    if (-not [string]::Equals($file, $guiStatefulPath, [StringComparison]::OrdinalIgnoreCase)) {
        $libLoads = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
            ($n.Extent.Text -match 'interactive-win11-lib\.ps1' -or $n.Extent.Text -match '\$libPath') }, $true))
        if ($libLoads.Count -lt 1) { throw "$file must dot-source the interactive library." }
        $firstUse = @($ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $guiFirstUseNames) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and (Get-MemberExpressionName -Node $n) -match '\AWrite(AllText|AllLines|AllBytes)\z') }, $true) |
            Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
        if ($firstUse.Count -eq 1 -and $firstUse[0].Extent.StartOffset -lt $libLoads[0].Extent.StartOffset) {
            throw "$file writes, launches or bootstraps before the interactive library (and its desktop check) loads."
        }
    }
    $launches = @($ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Start-Process') -or
        ($n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
            $n.CommandElements.Count -gt 0 -and $n.CommandElements[0].Extent.Text -match '\A\$(cli|exe|exePath)\z') -or
        ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -match 'Diagnostics\.Process\]\z' -and (Get-MemberExpressionName -Node $n) -ceq 'Start') }, $true))
    foreach ($launch in $launches) {
        if (-not (Test-GuiContractInsideHostedSwitch $launch -ElseBranch)) {
            throw "$file starts a process outside the else of an if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) switch (line $($launch.Extent.StartLineNumber))."
        }
        $cursor = $launch.Parent
        while ($cursor -isnot [System.Management.Automation.Language.IfStatementAst]) { $cursor = $cursor.Parent }
        if ($cursor.Clauses[0].Item2.Extent.Text -notmatch '\b(Start|Invoke)-InteractiveWin11HostedProcess\b') {
            throw "$file's hosted branch beside line $($launch.Extent.StartLineNumber) does not use the hosted launcher."
        }
    }
}
# The control: a Start-Process outside any hosted switch must be caught.
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

# ---- (12) the measurement record: Q0 and P1-P5 from #738's final hosted run, each with a non-empty destination set.
$guiMeasurements = Get-Content -LiteralPath $guiMeasurementsPath -Raw | ConvertFrom-Json
$guiIds = @($guiMeasurements.measurements | ForEach-Object { [string]$_.id })
if ($guiMeasurements.schemaVersion -ne 1 -or ($guiIds -join ',') -cne 'Q0,P1,P2,P3,P4,P5') { throw 'gui-measurements.json must hold Q0 and P1-P5, once each, in order.' }
foreach ($measurement in $guiMeasurements.measurements) {
    if ([string]$measurement.outcome -cnotin @('pass', 'fail', 'inconclusive') -or $measurement.runId -ne 44835461408 -or $measurement.attempt -ne 1 -or $measurement.pr -ne 738) {
        throw "gui-measurements.json's $($measurement.id) must cite #738's final hosted run 44835461408, attempt 1, with a known outcome."
    }
    foreach ($obligation in @($measurement.governs)) {
        if (@($obligation.destinations).Count -lt 1) { throw "gui-measurements.json's $($measurement.id) leaves an obligation with no destination." }
        foreach ($destination in @($obligation.destinations)) {
            if ([string]$destination.kind -cnotin @('hosted', 'hosted:test-tools', 'hosted:product-identity', 'hosted:provisional', 'parity', 'visible', 'bench', 'unit', 'disposition')) {
                throw "gui-measurements.json's $($measurement.id) names an unknown destination kind."
            }
            if ([string]$destination.kind -ceq 'disposition' -and [string]::IsNullOrWhiteSpace([string]$destination.reason)) {
                throw "gui-measurements.json's $($measurement.id) has a disposition without its reason."
            }
        }
    }
}
