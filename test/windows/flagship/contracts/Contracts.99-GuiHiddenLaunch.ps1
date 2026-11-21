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
    $guiStaged = @{ exeSha256 = (& $guiHashOf $guiApp); cliSha256 = (& $guiHashOf $guiCli) }
    [IO.File]::WriteAllText((Join-Path $guiScratch 'staged.json'), ($guiStaged | ConvertTo-Json))
    $env:NOCTTY_GUI_HIDDEN_DESKTOP = $guiExpected
    $env:NOCTTY_GUI_HIDDEN_EXE = $guiApp
    $env:NOCTTY_GUI_HIDDEN_RUN = $guiScratch
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
    foreach ($name in @('Initialize-InteractiveWin11HostedIdentity', 'Get-InteractiveWin11HostedLaunchRefusal', 'ConvertTo-InteractiveWin11HostedCommandLine')) {
        . ([scriptblock]::Create((Get-GuiContractFunctionText $guiLibAst $name)))
    }
    $script:InteractiveWin11HostedIdentity = Initialize-InteractiveWin11HostedIdentity
    if (Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp) { throw 'The launcher refused the genuine staged app.' }
    if (Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiCli) { throw 'The launcher refused the genuine staged CLI.' }
    $guiRefusals = [ordered]@{}
    $guiRefusals['another binary'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath (Join-Path $guiScratch 'staged.json')
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $null
    $guiRefusals['measurement mode unset'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
    Remove-Item -LiteralPath (Join-Path $guiCopy 'noctty.portable')
    $guiRefusals['no portable marker'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp
    [IO.File]::WriteAllText((Join-Path $guiCopy 'noctty.portable'), '')
    [IO.File]::WriteAllText((Join-Path $guiCopy 'noctty.ico'), 'icon')
    $guiRefusals['noctty.ico beside it'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp
    Remove-Item -LiteralPath (Join-Path $guiCopy 'noctty.ico')
    Start-Sleep -Milliseconds 20
    [IO.File]::WriteAllText($guiApp, 'replaced ' + [guid]::NewGuid())
    $guiRefusals['the app replaced after staging'] = Get-InteractiveWin11HostedLaunchRefusal -FilePath $guiApp
    foreach ($entry in $guiRefusals.GetEnumerator()) { if (-not $entry.Value) { throw "The launcher admitted $($entry.Key)." } }
    # The staged identity refuses a CLI that is not the receipt's, with the app unchanged.
    [IO.File]::WriteAllText($guiApp, 'app2 ' + [guid]::NewGuid())
    [IO.File]::WriteAllText((Join-Path $guiScratch 'staged.json'), (@{ exeSha256 = (& $guiHashOf $guiApp); cliSha256 = ('0' * 64) } | ConvertTo-Json))
    $guiIdentityRefused = $false
    try { [void](Initialize-InteractiveWin11HostedIdentity) } catch { $guiIdentityRefused = $true }
    if (-not $guiIdentityRefused) { throw 'The staged identity accepted a CLI that is not the receipt''s.' }

    # ---- (4) the launcher starts nothing it refuses: the native start swapped for a recording stand-in.
    if (-not ('GuiHiddenContractLaunch' -as [type])) {
        Add-Type -TypeDefinition @'
public static class GuiHiddenContractLaunch {
    public static int Starts;
    public static object Start(string app, string command, string cwd, string desktop, string stdout, string stderr) { Starts++; throw new System.Exception("stand-in start"); }
    public static void Assert(string expected) { }
}
'@
    }
    $guiStartText = (Get-GuiContractFunctionText $guiLibAst 'Start-InteractiveWin11HostedProcess').
        Replace('[InteractiveWin11HostedLaunch]::Start(', '[GuiHiddenContractLaunch]::Start(').
        Replace('[InteractiveWin11HostedDesktop]::Assert(', '[GuiHiddenContractLaunch]::Assert(')
    if ($guiStartText.Contains('[InteractiveWin11HostedLaunch]::Start(') -or -not $guiStartText.Contains('[GuiHiddenContractLaunch]::Start(')) { throw 'The launcher stand-in lost its anchor.' }
    . ([scriptblock]::Create($guiStartText))
    [IO.File]::WriteAllText((Join-Path $guiScratch 'staged.json'), (@{ exeSha256 = (& $guiHashOf $guiApp); cliSha256 = (& $guiHashOf $guiCli) } | ConvertTo-Json))
    $script:InteractiveWin11HostedIdentity = Initialize-InteractiveWin11HostedIdentity
    foreach ($refused in @(
            @{ Name = 'another binary'; File = (Join-Path $guiScratch 'staged.json'); Arguments = @() }
            @{ Name = '--command in argv'; File = $guiApp; Arguments = @('--command=cmd.exe') }
            @{ Name = 'a quoted argument'; File = $guiApp; Arguments = @('a"b') }
        )) {
        [GuiHiddenContractLaunch]::Starts = 0
        $threw = $false
        try { [void](Start-InteractiveWin11HostedProcess -FilePath $refused.File -ArgumentList $refused.Arguments -WorkingDirectory $guiScratch) } catch { $threw = $true }
        if (-not $threw -or [GuiHiddenContractLaunch]::Starts -ne 0) { throw "The launcher reached its native start for $($refused.Name)." }
    }
    [GuiHiddenContractLaunch]::Starts = 0
    try { [void](Start-InteractiveWin11HostedProcess -FilePath $guiApp -ArgumentList @('--class=x') -WorkingDirectory $guiScratch) } catch { }
    if ([GuiHiddenContractLaunch]::Starts -ne 1) { throw 'The launcher stand-in never saw the admitted start (the control''s positive half).' }
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
foreach ($name in @('Get-GuiHiddenHash', 'Get-GuiHiddenBaseConfig', 'New-GuiHiddenCopy', 'Get-GuiHiddenProcessVerdict', 'ConvertTo-GuiHiddenRecordValue', 'Write-GuiHiddenRecord', 'Get-GuiHiddenReparsePointCount')) {
    . ([scriptblock]::Create((Get-GuiContractFunctionText $guiRunnerAst $name)))
}
. ([scriptblock]::Create((Get-GuiContractFunctionText $guiLibAst 'Get-InteractiveWin11HostedPolicyConfig')))
$guiScratch = Join-Path ([IO.Path]::GetTempPath()) ('noctty-gui-hidden-stage-' + [guid]::NewGuid().ToString('N'))
try {
    $guiBin = Join-Path $guiScratch 'prefix\bin'
    [void](New-Item -ItemType Directory -Path $guiBin, (Join-Path $guiScratch 'prefix\share\ghostty'))
    foreach ($file in @('noctty.exe', 'noctty.com', 'noctty.ico', 'noctty.pdb', 'conpty.dll', 'OpenConsole.exe')) { [IO.File]::WriteAllText((Join-Path $guiBin $file), "$file " + [guid]::NewGuid()) }
    $guiExeHash = Get-GuiHiddenHash (Join-Path $guiBin 'noctty.exe'); $guiCliHash = Get-GuiHiddenHash (Join-Path $guiBin 'noctty.com')
    $guiGood = Join-Path $guiScratch 'good'
    New-GuiHiddenCopy -Bin $guiBin -Copy $guiGood -ExeSha256 $guiExeHash -CliSha256 $guiCliHash
    $guiCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $guiConfig = @([IO.File]::ReadAllLines((Join-Path $guiGood 'config.ghostty')))
    if (-not [IO.File]::Exists((Join-Path $guiGood 'noctty.portable')) -or [IO.File]::Exists((Join-Path $guiGood 'noctty.ico')) -or
        [IO.File]::Exists((Join-Path $guiGood 'noctty.pdb')) -or -not [IO.Directory]::Exists((Join-Path $guiGood 'share\ghostty')) -or
        @($guiConfig | Where-Object { [string]::Equals($_, "command = direct:$guiCmd /D", [StringComparison]::Ordinal) }).Count -ne 1 -or
        @($guiConfig | Where-Object { [string]::Equals($_, 'window-save-state = never', [StringComparison]::Ordinal) }).Count -ne 1) {
        throw 'A staged copy must carry the marker, the share tree and the policy config, and no icon or PDB.'
    }
    foreach ($bad in @(
            @{ Name = 'an ordinary build (the app is not the receipt''s)'; Exe = ('1' * 64); Cli = $guiCliHash }
            @{ Name = 'a substituted CLI with the app unchanged'; Exe = $guiExeHash; Cli = ('2' * 64) }
        )) {
        $threw = $false
        try { New-GuiHiddenCopy -Bin $guiBin -Copy (Join-Path $guiScratch ([guid]::NewGuid().ToString('N'))) -ExeSha256 $bad.Exe -CliSha256 $bad.Cli } catch { $threw = $true }
        if (-not $threw) { throw "Staging accepted $($bad.Name)." }
    }
    Remove-Item -LiteralPath (Join-Path $guiBin 'noctty.com')
    $threw = $false
    try { New-GuiHiddenCopy -Bin $guiBin -Copy (Join-Path $guiScratch 'nocli') -ExeSha256 $guiExeHash -CliSha256 $guiCliHash } catch { $threw = $true }
    if (-not $threw) { throw 'Staging accepted a generation without its CLI.' }

    # ---- (6) reparse points: one junction under a root is counted, none is not.
    $guiPlain = Join-Path $guiScratch 'plain'
    [void](New-Item -ItemType Directory -Path (Join-Path $guiPlain 'a\b'))
    if ((Get-GuiHiddenReparsePointCount @($guiPlain)) -ne 0) { throw 'The reparse scan counted a plain tree.' }
    [void](New-Item -ItemType Junction -Path (Join-Path $guiPlain 'a\link') -Target (Join-Path $guiPlain 'a\b'))
    if ((Get-GuiHiddenReparsePointCount @($guiPlain)) -ne 1) { throw 'The reparse scan missed a junction (the AutoRun symptom).' }

    # ---- (7) the record writer: a path, a command line or an odd key never reaches the file.
    $guiRecordPath = Join-Path $guiScratch 'record.json'
    $guiRejected = Write-GuiHiddenRecord ([ordered]@{ leaf = 'smoke'; path = 'C:\Users\someone\x'; line = '"cmd.exe" /D'; 'bad_key' = 1; ok = 3 }) $guiRecordPath
    $guiRecordText = [IO.File]::ReadAllText($guiRecordPath)
    if ($guiRejected -ne 3 -or $guiRecordText.Contains('someone') -or $guiRecordText.Contains('cmd.exe') -or $guiRecordText.Contains('bad_key')) {
        throw 'The runner''s record writer let a path, a command line or an odd key through.'
    }
}
finally { Remove-Item -LiteralPath $guiScratch -Recurse -Force -ErrorAction SilentlyContinue }

# ---- (8) the shell verdict: System32's cmd.exe with /D among the switches before /C or /K.
$guiSystemCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
foreach ($case in @(
        @{ Line = "`"$guiSystemCmd`" /D"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd /D"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd /d /c H:\x\payload.cmd"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd /D /K type seed.txt"; Read = 1; System = $true; Off = $true }
        @{ Line = "$guiSystemCmd"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /C echo /D"; Read = 1; System = $true; Off = $false }
        @{ Line = "$guiSystemCmd /K /D"; Read = 1; System = $true; Off = $false }
        @{ Line = 'cmd.exe /D'; Read = 1; System = $false; Off = $true }
        @{ Line = "$guiSystemCmd /D" + [char]27; Read = 0; System = $false; Off = $false }
        @{ Line = ''; Read = 0; System = $false; Off = $false }
    )) {
    $system = $false; $off = $false
    $read = [GuiHiddenRunnerNative]::CmdVerdict($case.Line, $guiSystemCmd, [ref]$system, [ref]$off)
    if ($read -ne $case.Read -or $system -ne $case.System -or $off -ne $case.Off) { throw "The shell verdict misjudged a command line (case $($case.Read)/$($case.System)/$($case.Off))." }
}

# ---- (9) the runner's process verdict, on synthetic joiners.
$script:LeafPid = 100
$guiRow = { param($Id, $Image, $Parent, $Creation, [bool] $IsCmd = $false, [bool] $Read = $false, [bool] $System = $false, [bool] $Off = $false, [bool] $OpenFailed = $false)
    [pscustomobject]@{ Pid = $Id; Image = $Image; Parent = $Parent; Creation = $Creation; IsCmd = $IsCmd; CmdRead = $Read; CmdSystem = $System; CmdAutoRunOff = $Off; OpenFailed = $OpenFailed; Unpinned = $false } }
$guiGoodRows = @(
    (& $guiRow 100 'pwsh.exe' 1 10)
    (& $guiRow 200 'noctty.exe' 100 20)
    (& $guiRow 300 'OpenConsole.exe' 200 30)
    (& $guiRow 400 'cmd.exe' 200 40 $true $true $true $true)
    (& $guiRow 500 'noctty.com' 400 50)
    (& $guiRow 600 'noctty.com' 100 60)
    (& $guiRow 700 'noctty.exe' 600 70)
    (& $guiRow 710 'noctty.exe' 500 71)
)
$guiLauncher = @{ 200 = [long]20; 600 = [long]60 }
if (-not (Get-GuiHiddenProcessVerdict $guiGoodRows $guiLauncher 8 1).passed) { throw 'The process verdict failed a clean leaf (a launched app, a shell''s CLI and the noctty.exe each CLI forwards).' }
foreach ($bad in @(
        @{ Name = 'a cmd without /D'; Rows = @($guiGoodRows[0..2]) + @((& $guiRow 400 'cmd.exe' 200 40 $true $true $true $false)) + @($guiGoodRows[4..7]); Total = 8; Shells = 1 }
        @{ Name = 'an unread cmd'; Rows = @($guiGoodRows[0..2]) + @((& $guiRow 400 'cmd.exe' 200 40 $true $false $false $false)) + @($guiGoodRows[4..7]); Total = 8; Shells = 1 }
        @{ Name = 'a cmd outside System32'; Rows = @($guiGoodRows[0..2]) + @((& $guiRow 400 'cmd.exe' 200 40 $true $true $false $true)) + @($guiGoodRows[4..7]); Total = 8; Shells = 1 }
        @{ Name = 'fewer shells than declared'; Rows = $guiGoodRows; Total = 8; Shells = 2 }
        @{ Name = 'a joiner the reader never took'; Rows = $guiGoodRows; Total = 9; Shells = 1 }
        @{ Name = 'a joiner that could not be opened'; Rows = @($guiGoodRows) + @((& $guiRow 800 $null 0 0 $false $false $false $false $true)); Total = 9; Shells = 1 }
        @{ Name = 'a noctty the leaf started itself'; Rows = @($guiGoodRows) + @((& $guiRow 900 'noctty.exe' 100 90)); Total = 9; Shells = 1 }
        @{ Name = 'a noctty with a reused launcher PID'; Rows = @($guiGoodRows[0]) + @((& $guiRow 200 'noctty.exe' 100 21)) + @($guiGoodRows[2..7]); Total = 8; Shells = 1 }
        @{ Name = 'a noctty forwarded by a noctty the leaf started itself'; Rows = @($guiGoodRows) + @((& $guiRow 900 'noctty.com' 100 90)) + @((& $guiRow 910 'noctty.exe' 900 91)); Total = 10; Shells = 1 }
        @{ Name = 'a noctty whose parent PID was reused after it started'; Rows = @($guiGoodRows) + @((& $guiRow 920 'noctty.exe' 400 39)); Total = 9; Shells = 1 }
    )) {
    if ((Get-GuiHiddenProcessVerdict $bad.Rows $guiLauncher $bad.Total $bad.Shells).passed) { throw "The process verdict passed $($bad.Name)." }
}
$script:LeafPid = 0

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
