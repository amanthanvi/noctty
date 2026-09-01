$publishedReleaseVerifierTokens = $null
$publishedReleaseVerifierErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $publishedReleaseVerifierText,
    [ref]$publishedReleaseVerifierTokens,
    [ref]$publishedReleaseVerifierErrors
)
if ($publishedReleaseVerifierErrors.Count -ne 0) {
    throw "Published release verifier does not parse: $($publishedReleaseVerifierErrors[0].Message)"
}

$windowLibTokens = $null
$windowLibErrors = $null
$windowLibAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $interactiveWin11WindowLibText,
    [ref]$windowLibTokens,
    [ref]$windowLibErrors
)
if ($windowLibErrors.Count -ne 0) {
    throw "Interactive Win11 window library does not parse: $($windowLibErrors[0].Message)"
}
$windowLibAddTypes = @(Get-NamedCommands -Ast $windowLibAst -Name 'Add-Type')
$windowLibTypeDefinition = if ($windowLibAddTypes.Count -eq 1) {
    Get-CommandParameterArgument -Command $windowLibAddTypes[0] -Name 'TypeDefinition'
} else {
    $null
}
if ($windowLibTypeDefinition -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
    throw 'Interactive Win11 window library must define its native surface through one literal Add-Type command.'
}
$windowLibCSharp = $windowLibTypeDefinition.Value
$windowNativeClassDefinitions = [regex]::Matches(
    $windowLibCSharp,
    '(?m)^\s*public\s+static\s+class\s+InteractiveWin11WindowNative\s*\{'
)
$forceForegroundDefinitions = [regex]::Matches(
    $windowLibCSharp,
    '(?m)^\s*public\s+static\s+bool\s+ForceForeground\s*\(\s*IntPtr\s+hWnd,\s*bool\s+altTap,\s*bool\s+useSendInputForAltTap\s*\)'
)
if ($windowNativeClassDefinitions.Count -ne 1 -or
    $forceForegroundDefinitions.Count -ne 1) {
    throw 'Interactive Win11 window library must own exactly one native class and one three-argument ForceForeground method.'
}
$forceForegroundOpenBrace = $windowLibCSharp.IndexOf(
    '{',
    $forceForegroundDefinitions[0].Index + $forceForegroundDefinitions[0].Length
)
$forceForegroundEnd = -1
$forceForegroundDepth = 0
if ($forceForegroundOpenBrace -ge 0) {
    for ($index = $forceForegroundOpenBrace; $index -lt $windowLibCSharp.Length; $index++) {
        if ($windowLibCSharp[$index] -eq '{') {
            $forceForegroundDepth++
        } elseif ($windowLibCSharp[$index] -eq '}') {
            $forceForegroundDepth--
            if ($forceForegroundDepth -eq 0) {
                $forceForegroundEnd = $index
                break
            }
        }
    }
}
if ($forceForegroundEnd -lt 0) {
    throw 'ForceForeground must have one balanced method body.'
}
$forceForegroundMethod = $windowLibCSharp.Substring(
    $forceForegroundDefinitions[0].Index,
    $forceForegroundEnd - $forceForegroundDefinitions[0].Index + 1
)
$altTapStrategies = [regex]::Matches(
    $forceForegroundMethod,
    '(?s)if\s*\(\s*altTap\s*\)\s*\{\s*if\s*\(\s*useSendInputForAltTap\s*\)\s*\{(?<sendInput>.*?)\}\s*else\s*\{(?<keybdEvent>.*?)\}\s*\}'
)
$attachInputCalls = [regex]::Matches(
    $forceForegroundMethod,
    'AttachThreadInput\s*\([^;]+,\s*(?<attach>true|false)\s*\)'
)
$attachTrueCalls = @($attachInputCalls | Where-Object { $_.Groups['attach'].Value -ceq 'true' })
$attachFalseCalls = @($attachInputCalls | Where-Object { $_.Groups['attach'].Value -ceq 'false' })
$forceForegroundReturns = [regex]::Matches(
    $forceForegroundMethod,
    '\breturn\b[^;]*;'
)
$forceForegroundHasExactReturn = $forceForegroundReturns.Count -eq 1 -and
    $forceForegroundReturns[0].Value -cmatch
        '^return\s+GetForegroundWindow\s*\(\s*\)\s*==\s*hWnd\s*;$'
if ($altTapStrategies.Count -ne 1 -or
    $altTapStrategies[0].Groups['sendInput'].Value -notmatch '\bSubmitInputs\s*\(' -or
    $altTapStrategies[0].Groups['keybdEvent'].Value -notmatch '\bkeybd_event\s*\(' -or
    $attachTrueCalls.Count -ne 2 -or
    $attachFalseCalls.Count -ne 2 -or
    -not $forceForegroundHasExactReturn -or
    $forceForegroundMethod -notmatch '(?s)\btry\s*\{.*?\bSetForegroundWindow\s*\(\s*hWnd\s*\).*?return\s+GetForegroundWindow\s*\(\s*\)\s*==\s*hWnd\s*;.*?\bfinally\s*\{') {
    throw 'ForceForeground must preserve SendInput and keybd_event Alt-tap strategies plus the paired AttachThreadInput handshake.'
}

$windowLibConsumerSources = @(
    [pscustomobject]@{ Path = $accessibilityHarness; Text = $accessibilityHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $imeCandidateHarness; Text = $imeCandidateHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $keyInputHarness; Text = $keyInputHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $newTabHarness; Text = $newTabHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $shellCommandLiveHarness; Text = $shellCommandLiveHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $statefulWin11Lib; Text = $statefulWin11LibText; DotSource = ". (Join-Path (Split-Path -Parent (Split-Path -Parent `$PSScriptRoot)) 'scripts\interactive-win11-window-lib.ps1')" },
    [pscustomobject]@{ Path = $undoHarness; Text = $undoHarnessText; DotSource = ". (Join-Path `$repoRoot 'scripts\interactive-win11-window-lib.ps1')" }
)
$windowLibConsumerAsts = foreach ($source in $windowLibConsumerSources) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $source.Text,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) {
        throw "Interactive window-library consumer does not parse: $($source.Path) ($($errors[0].Message))"
    }
    $matchingDotSources = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
            $node.Extent.Text.Trim() -ceq $source.DotSource
    }, $true))
    if ($matchingDotSources.Count -ne 1) {
        throw "Interactive harness must dot-source the shared window library exactly once: $($source.Path)"
    }
    [pscustomobject]@{ Path = $source.Path; Ast = $ast }
}

$forceForegroundCallContracts = @(
    [pscustomobject]@{ Path = $accessibilityHarness; Count = 19; AltTap = 'true'; SendInputAltTap = 'true' },
    [pscustomobject]@{ Path = $keyInputHarness; Count = 5; AltTap = 'false'; SendInputAltTap = 'false' },
    [pscustomobject]@{ Path = $shellCommandLiveHarness; Count = 2; AltTap = 'true'; SendInputAltTap = 'false' }
)
foreach ($contract in $forceForegroundCallContracts) {
    $sourceAst = @($windowLibConsumerAsts | Where-Object { $_.Path -eq $contract.Path })[0].Ast
    $calls = @(Get-NamedMemberExpressions -Ast $sourceAst -Name 'ForceForeground' -InvocationOnly)
    $invalidCalls = @($calls | Where-Object {
        $_.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or
        $_.Expression.TypeName.FullName -cne 'InteractiveWin11WindowNative' -or
        $_.Arguments.Count -ne 3 -or
        $_.Arguments[1] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $_.Arguments[1].VariablePath.UserPath -cne $contract.AltTap -or
        $_.Arguments[2] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $_.Arguments[2].VariablePath.UserPath -cne $contract.SendInputAltTap
    })
    if ($calls.Count -ne $contract.Count -or $invalidCalls.Count -ne 0) {
        throw "ForceForeground strategy arguments changed: $($contract.Path) (expected $($contract.Count) calls with `$$($contract.AltTap), `$$($contract.SendInputAltTap))."
    }
}

$windowNativeShadowDefinitions = @(
    foreach ($searchRoot in @(
        (Join-Path $repoRoot 'test\windows'),
        (Join-Path $repoRoot 'scripts')
    )) {
        foreach ($sourceFile in Get-ChildItem -LiteralPath $searchRoot -File -Recurse) {
            if ([string]::Equals(
                    $sourceFile.FullName,
                    $interactiveWin11WindowLib,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                continue
            }
            try {
                $sourceText = Get-Content -LiteralPath $sourceFile.FullName -Raw -ErrorAction Stop
            }
            catch {
                throw "InteractiveWin11WindowNative shadow scan could not read $($sourceFile.FullName): $($_.Exception.Message)"
            }
            $definitionCount = [regex]::Matches(
                $sourceText,
                '(?ims)^\s*(?:(?:public|internal|private|protected|static|sealed|abstract|partial|new|unsafe|readonly|ref)\s+|\[[^\]]+\]\s*)*(?:class|struct)\s+InteractiveWin11WindowNative\b'
            ).Count
            if ($definitionCount -gt 0) {
                [pscustomobject]@{ Path = $sourceFile.FullName; Count = $definitionCount }
            }
        }
    }
)
if ($windowNativeShadowDefinitions.Count -ne 0) {
    throw "InteractiveWin11WindowNative must not be shadowed outside the shared window library: $($windowNativeShadowDefinitions.Path -join ', ')"
}

$resolutionSourceAsts = foreach ($source in @(
    [pscustomobject]@{ Path = $interactiveWin11Lib; Text = $interactiveWin11LibText },
    [pscustomobject]@{ Path = $statefulWin11Lib; Text = $statefulWin11LibText }
)) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source.Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "PowerShell resolution source does not parse: $($source.Path) ($($errors[0].Message))" }
    [pscustomobject]@{ Path = $source.Path; Ast = $ast; Tokens = $tokens }
}
foreach ($source in $resolutionSourceAsts) {
    $expectedDotSources = if ($source.Path -eq $statefulWin11Lib) {
        @(". (Join-Path (Split-Path -Parent (Split-Path -Parent `$PSScriptRoot)) 'scripts\interactive-win11-window-lib.ps1')")
    } else { @() }
    $expectedAmpersands = if ($source.Path -eq $interactiveWin11Lib) {
        @(
            '& $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList',
            '& cmd /c $devWindowsCmd zig build -Demit-exe=true @optimizeArguments',
            '& $Condition',
            '& $Condition'
        )
    } else { @() }
    Assert-CommandResolutionContract -Ast $source.Ast -Tokens $source.Tokens -Context $source.Path -ExpectedDotSources $expectedDotSources -ExpectedAmpersandCommands $expectedAmpersands
    $definitions = @($source.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($name in @('Get-InteractiveWin11MessageTimeoutMs', 'Assert-InteractiveWin11WindowOwner', 'Invoke-InteractiveWin11PostMessage', 'Invoke-StatefulPostedCommand')) {
        $expected = if ($source.Path -eq $interactiveWin11Lib) {
            if ($name -eq 'Invoke-StatefulPostedCommand') { 0 } else { 1 }
        } else {
            if ($name -eq 'Invoke-StatefulPostedCommand') { 1 } else { 0 }
        }
        if (@($definitions | Where-Object { ($_.Name -replace '^(?i)(?:global|script|local|private):', '') -eq $name }).Count -ne $expected) {
            throw "Interactive library has the wrong ownership count for protected function $name`: $($source.Path)"
        }
    }
}
$interactiveWin11LibAst = @($resolutionSourceAsts | Where-Object { $_.Path -eq $interactiveWin11Lib })[0].Ast
$waitUntilFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Wait-InteractiveWin11Until'
}, $true))
if ($waitUntilFunctions.Count -ne 1) {
    throw 'Interactive harness library must own exactly one Wait-InteractiveWin11Until function.'
}
. ([scriptblock]::Create($waitUntilFunctions[0].Extent.Text))
$waitUntilCurrentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
try {
    & {
        $Process = 'caller-process-sentinel'
        Wait-InteractiveWin11Until `
            -Condition { $Process -ceq 'caller-process-sentinel' } `
            -Description 'caller Process binding contract' `
            -Deadline ([DateTime]::UtcNow.AddSeconds(1)) `
            -PollMilliseconds 1 `
            -ConditionFirst `
            -TimeoutMessage 'Wait-InteractiveWin11Until shadowed the caller Process variable.'
    }
    Wait-InteractiveWin11Until `
        -Condition { $true } `
        -Description 'Process alias binding contract' `
        -Deadline ([DateTime]::UtcNow.AddSeconds(1)) `
        -Process $waitUntilCurrentProcess `
        -ConditionFirst
}
finally {
    $waitUntilCurrentProcess.Dispose()
    Remove-Item -LiteralPath Function:\Wait-InteractiveWin11Until -ErrorAction SilentlyContinue
}
$harnessMainFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-InteractiveWin11HarnessMain'
}, $true))
if ($harnessMainFunctions.Count -ne 1 -or
    -not [object]::ReferenceEquals($harnessMainFunctions[0].Parent, $interactiveWin11LibAst.EndBlock)) {
    throw 'Interactive harness main helper must remain one top-level definition.'
}
# Exact-one is the invariant here: callers must resolve one shared top-level
# bootstrap gate. Its private statement layout is deliberately not pinned.
$harnessMainSource = $harnessMainFunctions[0].Extent.Text
$harnessMainProbeEnvironment =
    'NOCTTY_HARNESS_MAIN_CONTRACT_' + [Guid]::NewGuid().ToString('N')
$harnessMainProbePrevious = [Environment]::GetEnvironmentVariable(
    $harnessMainProbeEnvironment,
    [EnvironmentVariableTarget]::Process
)
try {
    [Environment]::SetEnvironmentVariable(
        $harnessMainProbeEnvironment,
        'already-bootstrapped',
        [EnvironmentVariableTarget]::Process
    )
    $sentinelProbe = @"
$harnessMainSource
function Invoke-InteractiveWin11Bootstrap { throw 'bootstrap mock must not run' }
Invoke-InteractiveWin11HarnessMain -RepoRoot 'repo-probe' -LauncherPath 'launcher-probe' -EnvironmentVariable '$harnessMainProbeEnvironment' -ArgumentList @('one', 'two')
Write-Output 'HARNESS-MAIN-RETURNED'
"@
    $sentinelOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -Command $sentinelProbe 2>&1)
    $sentinelExitCode = $LASTEXITCODE
    if ($sentinelExitCode -ne 0 -or
        $sentinelOutput -notcontains 'HARNESS-MAIN-RETURNED' -or
        $sentinelOutput -match 'bootstrap mock') {
        throw 'Interactive harness main did not return without bootstrapping when its process sentinel was set.'
    }

    [Environment]::SetEnvironmentVariable(
        $harnessMainProbeEnvironment,
        $null,
        [EnvironmentVariableTarget]::Process
    )
    $bootstrapProbe = @"
$harnessMainSource
function Invoke-InteractiveWin11Bootstrap {
    param(
        [string] `$RepoRoot,
        [string] `$LauncherPath,
        [string] `$EnvironmentVariable,
        [string[]] `$ArgumentList,
        [System.Management.Automation.PSReference] `$ExitCode
    )
    Write-Output ('BOOTSTRAP-CALLED|' + `$RepoRoot + '|' + `$LauncherPath + '|' + `$EnvironmentVariable + '|' + (`$ArgumentList -join ','))
    `$ExitCode.Value = 37
}
Invoke-InteractiveWin11HarnessMain -RepoRoot 'repo-probe' -LauncherPath 'launcher-probe' -EnvironmentVariable '$harnessMainProbeEnvironment' -ArgumentList @('one', 'two')
Write-Output 'UNREACHABLE-AFTER-HARNESS-MAIN'
"@
    $bootstrapOutput = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -Command $bootstrapProbe 2>&1)
    $bootstrapExitCode = $LASTEXITCODE
    $bootstrapCalls = @($bootstrapOutput | Where-Object {
        $_ -eq "BOOTSTRAP-CALLED|repo-probe|launcher-probe|$harnessMainProbeEnvironment|one,two"
    })
    if ($bootstrapCalls.Count -ne 1 -or
        $bootstrapExitCode -ne 37 -or
        $bootstrapOutput -contains 'UNREACHABLE-AFTER-HARNESS-MAIN') {
        throw 'Interactive harness main did not invoke its bootstrap mock once, forward arguments, and propagate exit code 37.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        $harnessMainProbeEnvironment,
        $harnessMainProbePrevious,
        [EnvironmentVariableTarget]::Process
    )
}
$stopProcessFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Stop-InteractiveWin11Process'
}, $true))
$processTreeSnapshotFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11ProcessTreeSnapshot'
    }, $true))
$processTreeExitedFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-InteractiveWin11ProcessTreeSnapshotExited'
    }, $true))
$waitProcessTreeExitedFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-InteractiveWin11ProcessTreeSnapshotExited'
    }, $true))
$stopRootHandleFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-InteractiveWin11RootHandle'
    }, $true))
# Exact-one top-level definitions are genuine ownership invariants: cleanup
# callers must all resolve the same lifecycle implementation.
$stopProcessMandatoryAttributes = @(
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes |
        Where-Object {
            $_ -is [System.Management.Automation.Language.AttributeAst] -and
                $_.TypeName.Name -eq 'Parameter' -and
                $_.NamedArguments.ArgumentName -contains 'Mandatory'
        }
)
if ($stopProcessFunctions.Count -ne 1 -or
    $processTreeSnapshotFunctions.Count -ne 1 -or
    $processTreeExitedFunctions.Count -ne 1 -or
    $waitProcessTreeExitedFunctions.Count -ne 1 -or
    $stopRootHandleFunctions.Count -ne 1 -or
    -not [object]::ReferenceEquals($stopProcessFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($processTreeSnapshotFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($processTreeExitedFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($waitProcessTreeExitedFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    -not [object]::ReferenceEquals($stopRootHandleFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TrapStatementAst]
    }, $true)).Count -ne 0 -or
    $null -ne $stopProcessFunctions[0].Body.BeginBlock -or
    $null -ne $stopProcessFunctions[0].Body.ProcessBlock -or
    $null -ne $stopProcessFunctions[0].Body.DynamicParamBlock -or
    $null -ne $stopProcessFunctions[0].Body.CleanBlock -or
    $null -eq $stopProcessFunctions[0].Body.ParamBlock -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters.Count -ne 4 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Name.VariablePath.UserPath -ne 'Process' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].StaticType -ne [System.Diagnostics.Process] -or
    $stopProcessMandatoryAttributes.Count -ne 1 -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Name.VariablePath.UserPath -ne 'RequireLiveRoot' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].StaticType -ne [switch] -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[2].Name.VariablePath.UserPath -ne 'Contained' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[2].StaticType -ne [switch] -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[3].Name.VariablePath.UserPath -ne 'AllowAlreadyExited' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[3].StaticType -ne [switch]) {
    throw 'Interactive process cleanup must expose explicit contained, live-root, and already-exited contracts.'
}
$rootTerminateCalls = @(
    Get-NamedMemberExpressions `
        -Ast $stopRootHandleFunctions[0].Body `
        -Name 'TerminateProcess' `
        -InvocationOnly
)
$rootWaitCalls = @(
    Get-NamedMemberExpressions `
        -Ast $stopRootHandleFunctions[0].Body `
        -Name 'WaitForSingleObject' `
        -InvocationOnly
)
if ($rootTerminateCalls.Count -ne 1 -or
    $rootTerminateCalls[0].Arguments.Count -ne 2 -or
    (Get-VariableExpressionName -Node $rootTerminateCalls[0].Arguments[0]) -ne
        'RootProcessHandle' -or
    $rootTerminateCalls[0].Arguments[1].Extent.Text.Trim() -cne '1' -or
    $rootWaitCalls.Count -ne 1 -or
    $rootWaitCalls[0].Arguments.Count -ne 2 -or
    (Get-VariableExpressionName -Node $rootWaitCalls[0].Arguments[0]) -ne
        'RootProcessHandle' -or
    $rootWaitCalls[0].Arguments[1].Extent.Text.Trim() -cne '15000') {
    throw 'Root fallback must terminate and wait on the captured process HANDLE with exit code 1 and a 15000 ms budget.'
}
if ($waitProcessTreeExitedFunctions[0].Body.Extent.Text -notmatch
        '(?s)\$deadline\s*=\s*\[DateTime\]::UtcNow\.AddSeconds\(\$TimeoutSeconds\).*?do\s*\{.*?Test-InteractiveWin11ProcessTreeSnapshotExited.*?-OperationTimeoutSec\s+\$operationTimeoutSec.*?Start-Sleep\s+-Milliseconds.*?\}\s*while\s*\(\[DateTime\]::UtcNow\s+-lt\s+\$deadline\)') {
    throw 'Process-tree verification must poll with per-query bounds until one explicit deadline.'
}

$uncontainedKillBranches = @($stopProcessFunctions[0].Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        $node.Clauses[0].Item1.Extent.Text.Trim() -ceq '-not $Contained'
}, $true))
$taskkillArgumentAssignments = if ($uncontainedKillBranches.Count -eq 1) {
    @($uncontainedKillBranches[0].Clauses[0].Item2.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
            (Get-ExpressionRootVariableName -Node $node.Left) -eq
                'taskkillStartInfo' -and
            (Get-MemberExpressionName -Node $node.Left) -eq 'Arguments'
    }, $true))
} else {
    @()
}
$taskkillWaitCalls = if ($uncontainedKillBranches.Count -eq 1) {
    @(Get-NamedMemberExpressions `
        -Ast $uncontainedKillBranches[0].Clauses[0].Item2 `
        -Name 'WaitForExit' `
        -InvocationOnly)
} else {
    @()
}
$taskkillWaitBudgets = @($taskkillWaitCalls | ForEach-Object {
    if ($_.Arguments.Count -eq 1) { $_.Arguments[0].Extent.Text.Trim() }
})
$taskkillCleanupRethrows = @($stopProcessFunctions[0].Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        $node.Clauses[0].Item1.Extent.Text -match
            '\$null\s+-ne\s+\$taskkillCleanupError' -and
        @($node.Clauses[0].Item2.FindAll({
            param($child)
            $child -is [System.Management.Automation.Language.ThrowStatementAst] -and
                $child.Extent.Text -match 'Failed to reap taskkill'
        }, $true)).Count -eq 1
}, $true))
if ($uncontainedKillBranches.Count -ne 1 -or
    $taskkillArgumentAssignments.Count -ne 1 -or
    $taskkillArgumentAssignments[0].Right.Extent.Text -notmatch
        '/PID\s+\$rootProcessId\s+/T\s+/F' -or
    $taskkillWaitCalls.Count -ne 2 -or
    $taskkillWaitBudgets -notcontains '10000' -or
    $taskkillWaitBudgets -notcontains '5000' -or
    $taskkillCleanupRethrows.Count -ne 1) {
    throw 'Uncontained cleanup must taskkill the captured PID tree with /T /F, bound taskkill/reap waits to 10000/5000 ms, and rethrow cleanup failure.'
}

# The executed probes below cover query bounds, snapshot-before-stop behavior,
# identity matching, fail-closed verification, contained fallback, and mutually
# exclusive lifecycle modes.

. ([scriptblock]::Create($processTreeSnapshotFunctions[0].Extent.Text))
. ([scriptblock]::Create($processTreeExitedFunctions[0].Extent.Text))
$script:verificationCimProcesses = @()
$script:verificationCimFailure = $null
$script:verificationCimCalls = 0
function script:Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClassName,
        [string] $Filter,
        [uint32] $OperationTimeoutSec
    )

    $script:verificationCimCalls++
    if ($ClassName -ne 'Win32_Process' -or
        $PSBoundParameters.ContainsKey('Filter') -or
        $OperationTimeoutSec -lt 1 -or
        $OperationTimeoutSec -gt 5) {
        throw 'Verification mock requires one bounded, unfiltered Win32_Process query.'
    }
    if ($null -ne $script:verificationCimFailure) {
        throw $script:verificationCimFailure
    }
    $script:verificationCimProcesses
}

try {
    $rootCreated = [datetime]'2026-07-14T15:00:00Z'
    $childCreated = $rootCreated.AddSeconds(1)
    $grandchildCreated = $rootCreated.AddSeconds(2)
    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; CreationDate = $rootCreated },
        [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; CreationDate = $childCreated },
        [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; CreationDate = $grandchildCreated },
        [pscustomobject]@{ ProcessId = 103; ParentProcessId = 100; CreationDate = $rootCreated.AddMinutes(-1) },
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 4; CreationDate = $rootCreated }
    )
    $snapshot = @(Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated)
    if ((@($snapshot.ProcessId | Sort-Object) -join ',') -ne '100,101,102') {
        throw 'Interactive process snapshot did not close over the full descendant tree.'
    }
    if (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot) {
        throw 'Interactive process verification accepted captured identities that were still live.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; CreationDate = $rootCreated.AddMinutes(1) },
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 4; CreationDate = $rootCreated }
    )
    if (-not (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot)) {
        throw 'Interactive process verification confused a reused PID with a captured identity.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 201; ParentProcessId = 100; CreationDate = $rootCreated.AddMinutes(2) }
    )
    if (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot) {
        throw 'Interactive process verification missed a child created after the snapshot.'
    }
    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 201; ParentProcessId = 100; CreationDate = $rootCreated.AddMinutes(-1) }
    )
    if (-not (Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot)) {
        throw 'Interactive process verification confused a stale child from a reused parent PID with a live descendant.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 4; CreationDate = $rootCreated }
    )
    $missingRootRejected = $false
    $missingRootMessage = ''
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch {
        $missingRootRejected = $true
        $missingRootMessage = $_.Exception.Message
    }
    if (-not $missingRootRejected -or
        $missingRootMessage -notlike 'Interactive Win11 root process 100 was absent*') {
        throw 'Interactive process snapshot accepted a missing root identity.'
    }

    $emptySnapshotRejected = $false
    $emptySnapshotMessage = ''
    try { [void](Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot @()) } catch {
        $emptySnapshotRejected = $true
        $emptySnapshotMessage = $_.Exception.Message
    }
    if (-not $emptySnapshotRejected -or
        [string]::IsNullOrWhiteSpace($emptySnapshotMessage)) {
        throw 'Interactive process verification accepted a vacuous empty snapshot.'
    }

    $script:verificationCimProcesses = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 4; CreationDate = $rootCreated.AddMinutes(1) }
    )
    $reusedRootRejected = $false
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch { $reusedRootRejected = $true }
    if (-not $reusedRootRejected) {
        throw 'Interactive process snapshot accepted a reused root PID.'
    }

    $script:verificationCimFailure = 'simulated CIM failure'
    $snapshotFailureRejected = $false
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch { $snapshotFailureRejected = $true }
    $verificationFailureRejected = $false
    try { [void](Test-InteractiveWin11ProcessTreeSnapshotExited -Snapshot $snapshot) } catch { $verificationFailureRejected = $true }
    if (-not $snapshotFailureRejected -or -not $verificationFailureRejected) {
        throw 'Interactive process cleanup treated a CIM failure as proof of exit.'
    }
    if ($script:verificationCimCalls -lt 8) {
        throw 'Interactive process-tree behavior probes did not invoke the bounded CIM mock.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name verificationCimProcesses, verificationCimFailure, verificationCimCalls -ErrorAction SilentlyContinue
}

. ([scriptblock]::Create($stopProcessFunctions[0].Extent.Text))
$script:cleanupSnapshotFailure = $false
$script:cleanupVerificationFailure = $false
$script:cleanupVerificationExited = $true
$script:cleanupSnapshotCalls = 0
$script:cleanupRootStopCalls = 0
$script:cleanupVerificationCalls = 0
$script:cleanupLog = [Collections.Generic.List[string]]::new()
function script:Get-InteractiveWin11ProcessTreeSnapshot {
    param([int] $RootProcessId, [datetime] $RootStartedAt)
    $script:cleanupSnapshotCalls++
    $script:cleanupLog.Add('snapshot')
    if ($script:cleanupSnapshotFailure) { throw 'simulated snapshot failure' }
    @([pscustomobject]@{ ProcessId = $RootProcessId; CreationDate = $RootStartedAt })
}
function script:Stop-InteractiveWin11RootHandle {
    param(
        [System.Diagnostics.Process] $Process,
        [IntPtr] $RootProcessHandle,
        [datetime] $RootStartedAt
    )
    $script:cleanupRootStopCalls++
    $script:cleanupLog.Add('stop')
    $Process.Kill()
    if (-not $Process.WaitForExit(5000)) { throw 'mock root process did not exit' }
}
function script:Wait-InteractiveWin11ProcessTreeSnapshotExited {
    param([object[]] $Snapshot)
    $script:cleanupVerificationCalls++
    $script:cleanupLog.Add('verify')
    if ($script:cleanupVerificationFailure) { throw 'simulated verification query failure' }
    $script:cleanupVerificationExited
}
function script:Start-CleanupContractProcess {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-Command')
    $startInfo.ArgumentList.Add('Start-Sleep -Seconds 30')
    [System.Diagnostics.Process]::Start($startInfo)
}
try {
    $process = Start-CleanupContractProcess
    $script:cleanupVerificationFailure = $true
    Stop-InteractiveWin11Process -Process $process -Contained
    if (-not $process.HasExited -or
        ($script:cleanupLog -join '|') -cne 'snapshot|stop|verify') {
        throw 'Contained cleanup must snapshot, stop the captured root handle, then verify descendants in that order.'
    }
    $script:cleanupLog.Clear()
    $process.Dispose()
    $process = $null

    $process = Start-CleanupContractProcess
    $script:cleanupVerificationFailure = $false
    $script:cleanupVerificationExited = $false
    $liveDescendantRejected = $false
    try { Stop-InteractiveWin11Process -Process $process -Contained } catch { $liveDescendantRejected = $true }
    if (-not $liveDescendantRejected -or -not $process.HasExited) {
        throw 'Contained cleanup accepted a successful verification query that reported live descendants.'
    }
    $process.Dispose()
    $process = $null

    $process = Start-CleanupContractProcess
    $script:cleanupSnapshotFailure = $true
    $script:cleanupVerificationExited = $true
    Stop-InteractiveWin11Process -Process $process -Contained
    if (-not $process.HasExited) {
        throw 'Contained cleanup did not terminate the root after initial snapshot failure.'
    }
    $process.Dispose()
    $process = $null

    $process = Start-CleanupContractProcess
    $script:cleanupSnapshotFailure = $true
    Stop-InteractiveWin11Process -Process $process -AllowAlreadyExited
    if (-not $process.HasExited) {
        throw 'Already-exited cleanup did not terminate the root after a snapshot race.'
    }
    $process.Dispose()
    $process = $null

    $conflictingModesRejected = $false
    try {
        Stop-InteractiveWin11Process `
            -Process ([System.Diagnostics.Process]::GetCurrentProcess()) `
            -Contained `
            -RequireLiveRoot
    }
    catch { $conflictingModesRejected = $true }
    if (-not $conflictingModesRejected) {
        throw 'Interactive cleanup accepted conflicting lifecycle modes.'
    }
    if ($script:cleanupSnapshotCalls -lt 1 -or
        $script:cleanupRootStopCalls -lt 1 -or
        $script:cleanupVerificationCalls -lt 1) {
        throw 'Interactive cleanup behavior probes did not invoke every lifecycle mock.'
    }
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11ProcessTreeSnapshot -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Stop-InteractiveWin11RootHandle -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Wait-InteractiveWin11ProcessTreeSnapshotExited -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Start-CleanupContractProcess -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Stop-InteractiveWin11Process -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name cleanupSnapshotFailure, cleanupVerificationFailure, cleanupVerificationExited, cleanupSnapshotCalls, cleanupRootStopCalls, cleanupVerificationCalls, cleanupLog -ErrorAction SilentlyContinue
}

$containmentFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11ContainmentArguments'
    }, $true))
$launchArgumentFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11LaunchArguments'
    }, $true))
# Exact-one is a single-source-of-truth invariant for launch policy ownership.
if ($containmentFunctions.Count -ne 1 -or
    $launchArgumentFunctions.Count -ne 1) {
    throw 'Interactive Win11 launch policy must have one containment owner and one launch composer.'
}
. ([scriptblock]::Create($containmentFunctions[0].Extent.Text))
. ([scriptblock]::Create($launchArgumentFunctions[0].Extent.Text))
try {
    $containmentArguments = @(Get-InteractiveWin11ContainmentArguments)
    if (($containmentArguments -join '|') -ne
        '--linux-cgroup=always|--linux-cgroup-hard-fail=true|--windows-job-object-kill-on-close=true') {
        throw 'Interactive containment behavior did not return the three required hard-fail arguments.'
    }

    $script:containmentForwardCalls = 0
    function script:Get-InteractiveWin11ContainmentArguments {
        $script:containmentForwardCalls++
        '--contract-containment-probe'
    }
    $launchArguments = @(
        Get-InteractiveWin11LaunchArguments -Layout ([ordered]@{ SandboxId = 'contract-sandbox' })
    )
    if ($script:containmentForwardCalls -ne 1 -or
        ($launchArguments -join '|') -ne
            '--contract-containment-probe|--single-instance=false|--class=noctty-interactive-contract-sandbox') {
        throw 'Interactive launch composition did not invoke containment policy once and append isolation arguments.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11ContainmentArguments -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11LaunchArguments -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name containmentForwardCalls -ErrorAction SilentlyContinue
}
$interactiveHarnessFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test\windows') -Filter 'interactive-win11-*.ps1' -File
)
$launchContainmentViolations = [Collections.Generic.List[string]]::new()
$forbiddenConfigOverrides = [Collections.Generic.List[string]]::new()
foreach ($file in @($interactiveHarnessFiles) + @(Get-Item -LiteralPath $interactiveWin11Lib)) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($content, '[''"]--single-instance=false[''"]')) {
        $prefixStart = [math]::Max(0, $match.Index - 512)
        $prefix = $content.Substring($prefixStart, $match.Index - $prefixStart)
        if ($prefix -notmatch '\bGet-InteractiveWin11(?:Launch|Containment)Arguments\b') {
            [void]$launchContainmentViolations.Add("$($file.Name):$($match.Index)")
        }
    }
    if ($file.FullName -ne $interactiveWin11Lib -and
        $content -match '(?im)^\s*(?:linux-cgroup|linux-cgroup-hard-fail|windows-job-object-kill-on-close)\s*=') {
        [void]$forbiddenConfigOverrides.Add($file.Name)
    }
}
if ($launchContainmentViolations.Count -ne 0) {
    throw "Interactive launch arguments bypass Job Object containment: $($launchContainmentViolations -join ', ')"
}
if ($forbiddenConfigOverrides.Count -ne 0) {
    throw "Interactive harness config overrides CLI containment: $($forbiddenConfigOverrides -join ', ')"
}

$cleanupContractViolations = [Collections.Generic.List[string]]::new()
$verificationContractsRunner = Join-Path $root 'Test-VerificationContracts.ps1'
$verificationContractsDirectory = Join-Path $root 'contracts'
$cleanupScriptFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test\windows') -Filter '*.ps1' -File -Recurse |
        Where-Object {
            $_.FullName -ne $verificationContractsRunner -and
                -not $_.FullName.StartsWith(
                    $verificationContractsDirectory + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )
        }
)
foreach ($file in $cleanupScriptFiles) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell parser errors while checking cleanup contract: $($file.FullName)"
    }
    foreach ($command in @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Stop-InteractiveWin11Process'
            }, $true))) {
        $text = $command.Extent.Text
        $modeCount = @(
            $text -match '(?i)(?:^|\s)-Contained(?:\s|$)'
            $text -match '(?i)(?:^|\s)-RequireLiveRoot(?:\s|$)'
            $text -match '(?i)(?:^|\s)-AllowAlreadyExited(?:\s|$)'
        ).Where({ $_ }).Count
        if ($modeCount -ne 1 -or
            ($text -match '(?i)(?:^|\s)-AllowAlreadyExited(?:\s|$)' -and $file.Name -ne 'vt-probe-win32-conformance.ps1')) {
            [void]$cleanupContractViolations.Add("$($file.Name):$($command.Extent.StartLineNumber): $text")
        }
    }
}
if ($cleanupContractViolations.Count -ne 0) {
    throw "Interactive cleanup calls lack exactly one explicit lifecycle contract:`n$($cleanupContractViolations -join "`n")"
}
$jobObjectSource = Get-Content -LiteralPath (Join-Path $repoRoot 'src\apprt\win32_job_object.zig') -Raw
$commandSource = Get-Content -LiteralPath (Join-Path $repoRoot 'src\Command.zig') -Raw
if ($jobObjectSource -notmatch 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE' -or
    $jobObjectSource -notmatch 'kill_on_close' -or
    $commandSource -notmatch '(?s)CREATE_SUSPENDED.*?AssignProcessToJobObject.*?ResumeThread') {
    throw 'Windows child containment must assign the suspended process to a kill-on-close Job Object before resume.'
}

# Native entry-point signatures are genuine FFI structure; private cleanup
# names and error strings are covered by the executed lifecycle probes above.
Invoke-ContractTable -Contracts @(
    @{
        File = $interactiveWin11Lib
        Content = {
            $interactiveWin11LibText
        }
        Pattern = ([regex]::Escape('public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);'))
        Kind = 'Text'
        Description = 'native root fallback termination declaration'
    }
    @{
        File = $interactiveWin11Lib
        Content = {
            $interactiveWin11LibText
        }
        Pattern = ([regex]::Escape('public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);'))
        Kind = 'Text'
        Description = 'native root termination wait declaration'
    }
)
