$keyInputHarnessTokens = $null
$keyInputHarnessErrors = $null
$keyInputHarnessAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $keyInputHarnessText,
    [ref]$keyInputHarnessTokens,
    [ref]$keyInputHarnessErrors
)
if ($keyInputHarnessErrors.Count -ne 0) {
    throw "Key-input harness does not parse: $($keyInputHarnessErrors[0].Message)"
}
$interactiveValidatorTokens = $null
$interactiveValidatorErrors = $null
$interactiveValidatorAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $interactiveValidatorText,
    [ref]$interactiveValidatorTokens,
    [ref]$interactiveValidatorErrors
)
if ($interactiveValidatorErrors.Count -ne 0) {
    throw "Interactive validator does not parse: $($interactiveValidatorErrors[0].Message)"
}

$keyInputParameterNames = @($keyInputHarnessAst.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
if ($keyInputParameterNames -contains 'Route') {
    throw 'Key-input harness must always target the surface directly; Route is not a valid public option.'
}
$keyInputKeyParameters = @($keyInputHarnessAst.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -eq 'Key'
})
$keyInputKeyValidateSets = if ($keyInputKeyParameters.Count -eq 1) {
    @($keyInputKeyParameters[0].Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.AttributeAst] -and
            $_.TypeName.FullName -eq 'ValidateSet'
    })
} else {
    @()
}
$keyInputKeyValues = if ($keyInputKeyValidateSets.Count -eq 1) {
    @($keyInputKeyValidateSets[0].PositionalArguments | ForEach-Object {
        if ($_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw 'Key-input Key ValidateSet values must be static strings.'
        }
        $_.Value
    })
} else {
    @()
}
$requiredKeyInputValues = @(
    'a',
    'space',
    'unicode-bmp',
    'unicode-supplementary',
    'unicode-burst',
    'unicode-cr',
    'unicode-lf',
    'unicode-tab',
    'unicode-backspace',
    'unicode-escape'
)
# Exact cardinality is the public input matrix: removing or duplicating a key
# changes the accepted CLI and the artifact namespace.
if ($keyInputKeyValues.Count -ne $requiredKeyInputValues.Count -or
    @(Compare-Object -ReferenceObject $requiredKeyInputValues -DifferenceObject $keyInputKeyValues -SyncWindow 0 -CaseSensitive).Count -ne 0 -or
    @($keyInputKeyValues | Sort-Object -Unique).Count -ne $keyInputKeyValues.Count) {
    throw 'Key-input harness must expose the exact ten-key input ValidateSet.'
}
if (@($keyInputKeyValues | Where-Object { $_ -match '(?i)alt|numpad' }).Count -ne 0) {
    throw 'Key-input harness cannot expose Alt+numpad input synthesis.'
}

$slugFunctions = @(Get-NamedFunctionDefinitions -Ast $keyInputHarnessAst -Name 'Get-KeyInputScenarioSlug')
# Single ownership is deliberate: every harness and artifact path must share one
# slug implementation.
if ($slugFunctions.Count -ne 1) {
    throw 'Key-input harness must own exactly one scenario-slug function.'
}
try {
    . ([scriptblock]::Create($slugFunctions[0].Extent.Text))
    $slugFixtures = @(
        foreach ($keyValue in $keyInputKeyValues) {
            Get-KeyInputScenarioSlug -Key $keyValue
        }
    )
    if (@($slugFixtures | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0 -or
        $slugFixtures.Count -ne 10 -or
        @($slugFixtures | Sort-Object -Unique).Count -ne $slugFixtures.Count) {
        throw 'The ten-key set must produce exactly ten unique artifact slugs.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-KeyInputScenarioSlug -ErrorAction SilentlyContinue
}

# Execute the target's artifact expressions. AST discovery is semantic (external
# command and observable suffix), so private assignment names may change freely.
$sandboxCalls = @(Get-NamedCommands -Ast $keyInputHarnessAst -Name 'Initialize-InteractiveWin11Sandbox')
if ($sandboxCalls.Count -ne 1) {
    throw 'Key-input harness must initialize exactly one isolated sandbox.'
}
$artifactSuffixes = @('-stdout.log', '-stderr.log', '-result.json')
$artifactJoinCalls = @(Get-NamedCommands -Ast $keyInputHarnessAst -Name 'Join-Path' | Where-Object {
    $children = @($_.CommandElements | Where-Object {
        $childExpression = $_
        $childExpression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            @($artifactSuffixes | Where-Object { $childExpression.Value.EndsWith($_) }).Count -eq 1
    })
    $children.Count -eq 1
})
if ($artifactJoinCalls.Count -ne $artifactSuffixes.Count) {
    throw 'Key-input harness must emit stdout, stderr, and result artifact paths.'
}
$artifactPrefixVariableNames = @($artifactJoinCalls | ForEach-Object {
    $child = @($_.CommandElements | Where-Object {
        $childExpression = $_
        $childExpression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            @($artifactSuffixes | Where-Object { $childExpression.Value.EndsWith($_) }).Count -eq 1
    })[0]
    @($child.NestedExpressions | ForEach-Object { Get-VariableExpressionName -Node $_ })
} | Sort-Object -Unique)
if ($artifactPrefixVariableNames.Count -ne 1) {
    throw 'Key-input artifact names must share one executed prefix value.'
}
$artifactPrefixAssignments = @($keyInputHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        (Get-VariableExpressionName -Node $node.Left) -eq $artifactPrefixVariableNames[0]
}, $true))
if ($artifactPrefixAssignments.Count -ne 1 -or
    $artifactPrefixAssignments[0].Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
    $artifactPrefixAssignments[0].Right.Expression -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
    throw 'Key-input artifact prefix must be one executable string expression.'
}
$scenarioVariableNames = @($artifactPrefixAssignments[0].Right.Expression.NestedExpressions | ForEach-Object {
    Get-VariableExpressionName -Node $_
} | Sort-Object -Unique)
if ($scenarioVariableNames.Count -ne 1) {
    throw 'Key-input artifact prefix must consume one scenario slug.'
}
$sandboxAssignment = $sandboxCalls[0].Parent
while ($null -ne $sandboxAssignment -and $sandboxAssignment -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
    $sandboxAssignment = $sandboxAssignment.Parent
}
if ($null -eq $sandboxAssignment) {
    throw 'Key-input sandbox call must participate in executable setup.'
}
$sandboxResultVariableName = Get-VariableExpressionName -Node $sandboxAssignment.Left
$sandboxMemberAssignments = @($keyInputHarnessAst.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { return $false }
    $members = @($node.Right.FindAll({
        param($child)
        $child -is [System.Management.Automation.Language.MemberExpressionAst] -and
            (Get-VariableExpressionName -Node $child.Expression) -eq $sandboxResultVariableName
    }, $true))
    $members.Count -gt 0
}, $true))
$artifactSetupSource = @(
    $artifactPrefixAssignments[0].Extent.Text
    $sandboxAssignment.Extent.Text
    $sandboxMemberAssignments | ForEach-Object { $_.Extent.Text }
    $artifactJoinCalls | ForEach-Object { $_.Extent.Text }
) -join [Environment]::NewLine
$artifactSandboxCalls = 0
$artifactSandboxName = $null
function Initialize-InteractiveWin11Sandbox {
    param($RepoRoot, $SandboxName, [switch]$ResetState, [switch]$IncludeResourcesDir)
    $script:artifactSandboxCalls++
    $script:artifactSandboxName = $SandboxName
    [ordered]@{
        RepoRoot = $RepoRoot
        Layout = [ordered]@{ Logs = 'C:\probe\logs'; Temp = 'C:\probe\temp' }
    }
}
$keyInputPriorRepoRoot = $repoRoot
$keyInputPriorResetState = $ResetState
try {
    Set-Variable -Name $scenarioVariableNames[0] -Value 'behavior-probe'
    $repoRoot = 'C:\probe\repo'
    $ResetState = $false
    $artifactPaths = @(& ([scriptblock]::Create($artifactSetupSource)))
    $normalizedArtifactPaths = @($artifactPaths | ForEach-Object {
        [System.IO.Path]::GetFullPath([string]$_)
    })
    $expectedArtifactPaths = @(
        [System.IO.Path]::GetFullPath((Join-Path 'C:\probe\logs' 'interactive-win11-key-input-behavior-probe-stdout.log')),
        [System.IO.Path]::GetFullPath((Join-Path 'C:\probe\logs' 'interactive-win11-key-input-behavior-probe-stderr.log')),
        [System.IO.Path]::GetFullPath((Join-Path 'C:\probe\temp' 'interactive-win11-key-input-behavior-probe-result.json'))
    )
    if ($artifactSandboxCalls -ne 1 -or
        $artifactSandboxName -cne 'key-input-behavior-probe' -or
        $artifactPaths.Count -ne 3 -or
        (Compare-Object $expectedArtifactPaths $normalizedArtifactPaths -SyncWindow 0 -CaseSensitive)) {
        throw 'Executed key-input setup must place stdout/stderr under layout Logs and result JSON under layout Temp using the scenario slug.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Initialize-InteractiveWin11Sandbox -ErrorAction SilentlyContinue
    Remove-Variable -Name $scenarioVariableNames[0] -ErrorAction SilentlyContinue
    $repoRoot = $keyInputPriorRepoRoot
    $ResetState = $keyInputPriorResetState
}

# Execute the composite declarations against a recording runner. Nine is the
# intended release matrix (classic-a plus eight Unicode/control paths); space is
# intentionally standalone-only.
$keyInputCompositeCalls = @(Get-NamedCommands -Ast $interactiveValidatorAst -Name 'Invoke-HarnessWithPassSentinel' | Where-Object {
    $scriptName = Get-CommandParameterArgument -Command $_ -Name 'ScriptName'
    $scriptName -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $scriptName.Value -eq 'interactive-win11-key-input.ps1'
})
$compositeRecords = [Collections.Generic.List[object]]::new()
function Invoke-HarnessWithPassSentinel {
    param($ScriptName, $TimeoutSeconds, [string[]]$AdditionalArguments = @(), $ScenarioSlug)
    [void]$script:compositeRecords.Add([pscustomobject]@{
        ScriptName = $ScriptName
        TimeoutSeconds = $TimeoutSeconds
        AdditionalArguments = @($AdditionalArguments)
        ScenarioSlug = $ScenarioSlug
    })
}
try {
    & ([scriptblock]::Create(($keyInputCompositeCalls | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine))
}
finally {
    Remove-Item -LiteralPath Function:\Invoke-HarnessWithPassSentinel -ErrorAction SilentlyContinue
}
$coveredKeyScenarios = @($compositeRecords | ForEach-Object {
    $index = [array]::IndexOf($_.AdditionalArguments, '-Key')
    if ($index -lt 0) { 'a' } else { $_.AdditionalArguments[$index + 1] }
})
$expectedKeyScenarios = @(
    'a',
    'unicode-bmp',
    'unicode-supplementary',
    'unicode-burst',
    'unicode-cr',
    'unicode-lf',
    'unicode-tab',
    'unicode-backspace',
    'unicode-escape'
)
if ($compositeRecords.Count -ne 9 -or
    @($compositeRecords.ScenarioSlug | Sort-Object -Unique).Count -ne 9 -or
    (Compare-Object $expectedKeyScenarios $coveredKeyScenarios -SyncWindow 0 -CaseSensitive)) {
    throw 'Executed composite validator must isolate every key-input scenario except space.'
}

$getHarnessArgumentsFunctions = @(Get-NamedFunctionDefinitions -Ast $interactiveValidatorAst -Name 'Get-HarnessArguments')
$startHarnessFunctions = @(Get-NamedFunctionDefinitions -Ast $interactiveValidatorAst -Name 'Start-Harness')
$invokeHarnessFunctions = @(Get-NamedFunctionDefinitions -Ast $interactiveValidatorAst -Name 'Invoke-HarnessWithPassSentinel')
# These are genuine ownership counts: the validator has one implementation for
# argument construction, launch, and pass-sentinel adjudication.
if ($getHarnessArgumentsFunctions.Count -ne 1 -or
    $startHarnessFunctions.Count -ne 1 -or
    $invokeHarnessFunctions.Count -ne 1) {
    throw 'Interactive validator must own one implementation of each harness stage.'
}
if (-not ('InteractiveWin11HarnessRun' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Diagnostics;
public class InteractiveWin11HarnessRun {
    public string Script { get; }
    public Process Process { get; }
    public string Stdout { get; }
    public string Stderr { get; }
    public int TimeoutSeconds { get; }
    public InteractiveWin11HarnessRun(string script, Process process, string stdout, string stderr, int timeoutSeconds) {
        Script = script; Process = process; Stdout = stdout; Stderr = stderr; TimeoutSeconds = timeoutSeconds;
    }
}
'@
}
$validatorStartCalls = [Collections.Generic.List[object]]::new()
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, [switch]$PassThru)
    [void]$script:validatorStartCalls.Add([pscustomobject]@{
        FilePath = $FilePath
        ArgumentList = @($ArgumentList)
        WorkingDirectory = $WorkingDirectory
        Stdout = $RedirectStandardOutput
        Stderr = $RedirectStandardError
    })
    [System.Diagnostics.Process]::GetCurrentProcess()
}
$keyInputPriorSuiteLogDir = $suiteLogDir
$keyInputPriorRepoRoot = $repoRoot
$keyInputPriorResetState = $ResetState
$keyInputValidatorScriptRoot = Split-Path -Parent $keyInputHarness
try {
    $getHarnessArgumentsSource = $getHarnessArgumentsFunctions[0].Extent.Text.Replace(
        '$PSScriptRoot',
        '$script:keyInputValidatorScriptRoot'
    )
    . ([scriptblock]::Create($getHarnessArgumentsSource))
    . ([scriptblock]::Create($startHarnessFunctions[0].Extent.Text))
    $suiteLogDir = 'C:\probe\suite-logs'
    $ResetState = $true
    $run = Start-Harness -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 23 `
        -AdditionalArguments @('-Key', 'unicode-bmp') -ScenarioSlug 'bmp'
    if ($validatorStartCalls.Count -ne 1 -or
        [System.IO.Path]::GetFullPath($run.Stdout) -cne
            [System.IO.Path]::GetFullPath((Join-Path $suiteLogDir 'interactive-win11-key-input-bmp.stdout.log')) -or
        [System.IO.Path]::GetFullPath($run.Stderr) -cne
            [System.IO.Path]::GetFullPath((Join-Path $suiteLogDir 'interactive-win11-key-input-bmp.stderr.log')) -or
        $validatorStartCalls[0].ArgumentList -cnotcontains 'unicode-bmp' -or
        $validatorStartCalls[0].ArgumentList -cnotcontains '-ResetState') {
        throw 'Executed Start-Harness must keep composite stdout/stderr under the suite log directory and forward scenario/reset arguments.'
    }
}
finally {
    foreach ($name in @('Start-Process', 'Start-Harness', 'Get-HarnessArguments')) {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
    $suiteLogDir = $keyInputPriorSuiteLogDir
    $repoRoot = $keyInputPriorRepoRoot
    $ResetState = $keyInputPriorResetState
}

$passSentinelStartCalls = [Collections.Generic.List[object]]::new()
$passSentinelLogCalls = 0
$passSentinelSummaryCalls = 0
$passSentinelStopCalls = 0
$passSentinelWaitCalls = [Collections.Generic.List[int]]::new()
$script:passSentinelWaitResult = $true
$script:passSentinelSummary = 'PASS'
$processProbe = [pscustomobject]@{ ExitCode = 0 }
$processProbe | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param($Milliseconds)
    $script:passSentinelWaitCalls.Add($Milliseconds)
    $script:passSentinelWaitResult
}
function Start-Harness {
    param($ScriptName, $TimeoutSeconds, $AdditionalArguments, $ScenarioSlug)
    [void]$script:passSentinelStartCalls.Add([pscustomobject]@{
        ScriptName = $ScriptName; TimeoutSeconds = $TimeoutSeconds
        AdditionalArguments = @($AdditionalArguments); ScenarioSlug = $ScenarioSlug
    })
    [pscustomobject]@{ Script = $ScenarioSlug; Process = $script:processProbe; Stdout = 'out'; Stderr = 'err' }
}
function Get-HarnessLog { param($Path) $script:passSentinelLogCalls++; 'log' }
function Get-HarnessSummary {
    param($Path)
    $script:passSentinelSummaryCalls++
    $script:passSentinelSummary
}
function Stop-InteractiveWin11Process {
    param($Process, [switch] $RequireLiveRoot)
    $script:passSentinelStopCalls++
    $script:passSentinelStoppedProcess = $Process
    $script:passSentinelStopRequiredLiveRoot = $RequireLiveRoot.IsPresent
}
try {
    . ([scriptblock]::Create($invokeHarnessFunctions[0].Extent.Text))
    Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 17 `
        -AdditionalArguments @('-Key', 'unicode-lf') -ScenarioSlug 'control-lf'

    $script:passSentinelSummary = 'missing sentinel'
    $missingPassMessage = ''
    try {
        Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 17 -ScenarioSlug 'missing-pass'
    }
    catch { $missingPassMessage = $_.Exception.Message }

    $script:passSentinelSummary = 'PASS'
    $processProbe.ExitCode = 23
    $nonzeroMessage = ''
    try {
        Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 17 -ScenarioSlug 'nonzero'
    }
    catch { $nonzeroMessage = $_.Exception.Message }

    $processProbe.ExitCode = 0
    $script:passSentinelWaitResult = $false
    $timeoutMessage = ''
    try {
        Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 17 -ScenarioSlug 'timeout'
    }
    catch { $timeoutMessage = $_.Exception.Message }

    # A harness that runs several scenarios sequentially applies -TimeoutSeconds
    # to each one, so the outer kill deadline has to be stated separately or a
    # run in which no scenario was late still gets killed. The override must
    # replace the budget outright, not add to the per-scenario default.
    $budgetMessage = ''
    try {
        Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 17 `
            -WaitTimeoutSeconds 115 -ScenarioSlug 'budget'
    }
    catch { $budgetMessage = $_.Exception.Message }

    if ($passSentinelStartCalls.Count -ne 5 -or
        $passSentinelStartCalls[0].ScenarioSlug -cne 'control-lf' -or
        $passSentinelStartCalls[0].AdditionalArguments -cnotcontains 'unicode-lf' -or
        $passSentinelLogCalls -ne 10 -or
        $passSentinelSummaryCalls -ne 3 -or
        $passSentinelWaitCalls.Count -ne 5 -or
        @($passSentinelWaitCalls[0..3] | Where-Object { $_ -ne 22000 }).Count -ne 0 -or
        $passSentinelWaitCalls[4] -ne 115000 -or
        $passSentinelStartCalls[4].TimeoutSeconds -ne 17 -or
        $missingPassMessage -notlike '*did not report PASS*' -or
        $nonzeroMessage -notlike '*exited with code 23*' -or
        $timeoutMessage -notlike '*timed out after 17s*' -or
        $budgetMessage -notlike '*timed out after 115s total budget (per-scenario deadline 17s)*' -or
        $script:passSentinelStopCalls -ne 2 -or
        -not [object]::ReferenceEquals($script:passSentinelStoppedProcess, $processProbe) -or
        -not $script:passSentinelStopRequiredLiveRoot) {
        throw 'Pass-sentinel runner must reject missing PASS, nonzero exit, and timeout; timeout must stop the exact live root.'
    }
}
finally {
    foreach ($name in @(
        'Invoke-HarnessWithPassSentinel', 'Start-Harness', 'Get-HarnessLog',
        'Get-HarnessSummary', 'Stop-InteractiveWin11Process'
    )) {
        Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Scope Script -Name passSentinelWaitResult, passSentinelSummary, passSentinelStoppedProcess, passSentinelStopRequiredLiveRoot -ErrorAction SilentlyContinue
}
