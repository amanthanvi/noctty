$sessionTokens = $null
$sessionErrors = $null
$sessionAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $sessionRestoreHarnessText,
    [ref]$sessionTokens,
    [ref]$sessionErrors
)
if ($sessionErrors.Count -ne 0) {
    throw "Session restore harness does not parse: $($sessionErrors[0].Message)"
}
if (@($sessionAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.TrapStatementAst]
        }, $true)).Count -ne 0) {
    throw 'Session restore harness must not swallow validation failures with traps.'
}
$sessionForbiddenMutations = @($sessionAst.FindAll({
    param($node)
    if (Test-ForbiddenScriptMutationNode -Node $node) { return $true }
    if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
        return $false
    }
    $commandName = $node.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) { return $false }
    return (($commandName -split '\\')[-1]) -match
        '^(?i)(?:Stop-Process|taskkill(?:\.exe)?)$'
}, $true))
if ($sessionForbiddenMutations.Count -ne 0) {
    throw 'Session restore cleanup must not use command-resolution mutation or shared-runner process killing by name.'
}

$sessionBootstrapCalls = @(
    Get-NamedCommands `
        -Ast $sessionAst.EndBlock `
        -Name 'Invoke-InteractiveWin11HarnessMain'
)
# Exact-one is the bootstrap ownership invariant, not an incidental call count.
if ($sessionBootstrapCalls.Count -ne 1 -or
    -not (Test-CommandHasStringArgument `
        -Command $sessionBootstrapCalls[0] `
        -Value 'NOCTTY_INTERACTIVE_WIN11_SESSION_RESTORE_BOOTSTRAPPED')) {
    throw 'Session restore must invoke the shared bootstrap gate once with its stable sentinel.'
}

$sessionSnapshotFunctions = @(
    Get-NamedFunctionDefinitions `
        -Ast $sessionAst `
        -Name 'Get-SessionAutomationSnapshot'
)
# Exact-one is a real single-source-of-truth invariant: every automation query
# must share the same retry, deadline, cleanup, and JSON parsing behavior.
if ($sessionSnapshotFunctions.Count -ne 1 -or
    -not [object]::ReferenceEquals($sessionSnapshotFunctions[0].Parent, $sessionAst.EndBlock)) {
    throw 'Session restore must own one top-level automation snapshot helper.'
}
Assert-NoUnreachableStatements `
    -Ast $sessionSnapshotFunctions[0].Body `
    -Context 'Get-SessionAutomationSnapshot'

. ([scriptblock]::Create($sessionSnapshotFunctions[0].Extent.Text))
$sessionProbeDirectory = Join-Path (
    [IO.Path]::GetTempPath()
) ('noctty-session-contract-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($sessionProbeDirectory) | Out-Null
$exe = Join-Path $sessionProbeDirectory 'noctty.exe'
$sessionProbeCli = Join-Path $sessionProbeDirectory 'noctty.com'
[IO.File]::WriteAllText($sessionProbeCli, 'contract shim')
$sessionOriginalRepoRoot = $repoRoot
$layout = [pscustomobject]@{ Logs = $sessionProbeDirectory }
$instanceClass = 'noctty-interactive-contract'
$repoRoot = 'contract-repo-root'
$script:SESSION_RESTORE_RETRY_MS = 17
$script:sessionSnapshotProbeMode = 'success-on-third'
$script:sessionSnapshotStartCalls = 0
$script:sessionSnapshotStopCalls = 0
$script:sessionSnapshotSleepCalls = 0
$script:sessionSnapshotExitCodeCalls = 0
$script:sessionSnapshotLog = [Collections.Generic.List[string]]::new()

function script:Start-Process {
    [CmdletBinding()]
    param(
        [string] $FilePath,
        [object[]] $ArgumentList,
        [string] $WorkingDirectory,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError,
        [switch] $PassThru
    )

    $script:sessionSnapshotStartCalls++
    $attempt = $script:sessionSnapshotStartCalls
    $script:sessionSnapshotLog.Add("start:$attempt")
    if ($FilePath -ne $sessionProbeCli -or
        ($ArgumentList -join '|') -ne '+list-windows|--class=noctty-interactive-contract' -or
        $WorkingDirectory -ne $repoRoot -or
        -not $PassThru) {
        throw 'Session snapshot mock received the wrong automation query arguments.'
    }

    if ($script:sessionSnapshotProbeMode -eq 'success-on-third') {
        if ($attempt -eq 2) {
            [IO.File]::WriteAllText($RedirectStandardError, 'retryable query failure')
        }
        elseif ($attempt -eq 3) {
            [IO.File]::WriteAllText(
                $RedirectStandardOutput,
                '{"windows":[{"active_tab_id":"tab-2","tabs":[{"tab_id":"tab-1"},{"tab_id":"tab-2","active":true},{"tab_id":"tab-3"}]}]}'
            )
        }
    }

    $query = [pscustomobject]@{
        Attempt = $attempt
        Handle = [IntPtr]$attempt
        WaitResult = $script:sessionSnapshotProbeMode -ne 'success-on-third' -or $attempt -ne 1
    }
    $query | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param([int] $Milliseconds)
        $script:sessionSnapshotLog.Add("wait:$($this.Attempt):$Milliseconds")
        if ($Milliseconds -le 0) {
            throw 'Session snapshot helper supplied an exhausted deadline to WaitForExit.'
        }
        return $this.WaitResult
    }
    $query | Add-Member -MemberType ScriptMethod -Name Refresh -Value {
        $script:sessionSnapshotLog.Add("refresh:$($this.Attempt)")
    }
    return $query
}

function script:Stop-InteractiveWin11Process {
    param($Process, [switch] $RequireLiveRoot)
    $script:sessionSnapshotStopCalls++
    $script:sessionSnapshotLog.Add("stop:$($Process.Attempt):$($RequireLiveRoot.IsPresent)")
}

function script:Get-InteractiveWin11ProcessExitCode {
    param($Process, [IntPtr] $ProcessHandle)
    $script:sessionSnapshotExitCodeCalls++
    $script:sessionSnapshotLog.Add("exit:$($Process.Attempt):$($ProcessHandle.ToInt64())")
    if ($script:sessionSnapshotProbeMode -eq 'success-on-third' -and $Process.Attempt -eq 2) {
        return 9
    }
    return 0
}

function script:Start-Sleep {
    param([int] $Milliseconds)
    $script:sessionSnapshotSleepCalls++
    $script:sessionSnapshotLog.Add("sleep:$Milliseconds")
    if ($Milliseconds -ne 17) {
        throw "Session snapshot retry used $Milliseconds ms instead of its configured cadence."
    }
}

try {
    $sessionSnapshot = Get-SessionAutomationSnapshot `
        -Name 'contract-success' `
        -Deadline ([DateTime]::UtcNow.AddSeconds(5))
    $expectedSuccessOrder = @(
        'start:1',
        'stop:1:True',
        'start:2',
        'exit:2:2',
        'sleep:17',
        'start:3',
        'exit:3:3'
    )
    $successLog = @($script:sessionSnapshotLog)
    $cursor = -1
    foreach ($expectedEvent in $expectedSuccessOrder) {
        $next = [Array]::IndexOf($successLog, $expectedEvent, $cursor + 1)
        if ($next -lt 0) {
            throw "Session snapshot behavior missed ordered event '$expectedEvent': $($successLog -join ', ')"
        }
        $cursor = $next
    }
    if ($sessionSnapshot.windows.Count -ne 1 -or
        $sessionSnapshot.windows[0].tabs.Count -ne 3 -or
        $script:sessionSnapshotStartCalls -ne 3 -or
        $script:sessionSnapshotStopCalls -ne 1 -or
        $script:sessionSnapshotSleepCalls -ne 1 -or
        $script:sessionSnapshotExitCodeCalls -ne 2) {
        throw 'Session snapshot behavior did not time out, stop, retry, parse, and return the third query exactly once.'
    }

    $startCallsBeforeFailure = $script:sessionSnapshotStartCalls
    $sleepCallsBeforeFailure = $script:sessionSnapshotSleepCalls
    $script:sessionSnapshotProbeMode = 'empty-output'
    $sessionFailureMessage = ''
    try {
        [void](Get-SessionAutomationSnapshot `
            -Name 'contract-failure' `
            -Deadline ([DateTime]::UtcNow.AddSeconds(5)))
    }
    catch {
        $sessionFailureMessage = $_.Exception.Message
    }
    if ($sessionFailureMessage -notlike 'Session automation query failed after three attempts:*' -or
        ($script:sessionSnapshotStartCalls - $startCallsBeforeFailure) -ne 3 -or
        ($script:sessionSnapshotSleepCalls - $sleepCallsBeforeFailure) -ne 3) {
        throw 'Session snapshot terminal-failure behavior did not exhaust three invoked retries with its observable error prefix.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Stop-InteractiveWin11Process -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-InteractiveWin11ProcessExitCode -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\Get-SessionAutomationSnapshot -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name SESSION_RESTORE_RETRY_MS, sessionSnapshotProbeMode, sessionSnapshotStartCalls, sessionSnapshotStopCalls, sessionSnapshotSleepCalls, sessionSnapshotExitCodeCalls, sessionSnapshotLog -ErrorAction SilentlyContinue
    $repoRoot = $sessionOriginalRepoRoot
    if ([IO.Directory]::Exists($sessionProbeDirectory)) {
        [IO.Directory]::Delete($sessionProbeDirectory, $true)
    }
}

# The end-to-end harness itself observes every causal boundary (tab counts,
# readiness barriers, immutable saved bytes, restored active tab, quarantine,
# and clean process exit). Statement position adds no independent invariant, so
# all former ordering/offset and private-local-name pins are intentionally gone.
$sessionRunNames = @(
    'session-save',
    'session-explicit-command',
    'session-restore',
    'session-corrupt'
)
$sessionStartCalls = @(
    Get-NamedCommands `
        -Ast $sessionAst.EndBlock `
        -Name 'Start-StatefulApp'
)
$sessionStartAssignments = @($sessionAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        @(Get-NamedCommands -Ast $node.Right -Name 'Start-StatefulApp').Count -eq 1
}, $true))
if ($sessionStartAssignments.Count -ne $sessionStartCalls.Count) {
    throw 'Every session restore Start-StatefulApp call must assign its successful run before registration.'
}
foreach ($startAssignment in $sessionStartAssignments) {
    $runVariableName = Get-VariableExpressionName -Node $startAssignment.Left
    $statementBlock = Get-ContainingStatementBlock -Node $startAssignment
    $assignmentStatement = Get-DirectStatementBlockChild `
        -Node $startAssignment `
        -StatementBlock $statementBlock
    $registrationCalls = @($statementBlock.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            (Get-MemberExpressionName -Node $node) -eq 'Add' -and
            (Get-ExpressionRootVariableName -Node $node.Expression) -eq 'runs' -and
            $node.Arguments.Count -eq 1 -and
            (Get-VariableExpressionName -Node $node.Arguments[0]) -eq $runVariableName -and
            (Test-DirectStatementBlockChild -Node $node -StatementBlock $statementBlock)
    }, $true))
    $registrationStatement = if ($registrationCalls.Count -eq 1) {
        Get-DirectStatementBlockChild `
            -Node $registrationCalls[0] `
            -StatementBlock $statementBlock
    } else {
        $null
    }
    $blockStatements = @($statementBlock.Statements)
    $assignmentIndex = [Array]::IndexOf($blockStatements, $assignmentStatement)
    $registrationIndex = [Array]::IndexOf($blockStatements, $registrationStatement)
    if ([string]::IsNullOrWhiteSpace($runVariableName) -or
        $registrationCalls.Count -ne 1 -or
        $assignmentIndex -lt 0 -or
        $registrationIndex -ne ($assignmentIndex + 1)) {
        throw "Successful session run '$runVariableName' must be registered immediately in `$runs for fail-closed cleanup."
    }
}
foreach ($runName in $sessionRunNames) {
    # Exact-one per named run is the scenario matrix itself: save, explicit
    # no-restore, restore, and corrupt-state quarantine.
    $matchingRunCalls = @($sessionStartCalls | Where-Object {
        Test-CommandHasStringArgument -Command $_ -Value $runName
    })
    if ($matchingRunCalls.Count -ne 1) {
        throw "Session restore story must execute exactly one '$runName' run."
    }
}
if (@($sessionStartCalls | Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'session-explicit-command'
        } | Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value '-e'
        } | Where-Object {
            Test-CommandHasStringArgument -Command $_ -Value 'cmd.exe'
        }).Count -ne 1) {
    throw 'Session restore explicit-command run must exercise the no-restore -e path.'
}

$sessionDiagnosticStrings = @(
    $sessionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true) | ForEach-Object { $_.Value }
)
$requiredSessionDiagnostics = @(
    'initial session-save host readiness barrier',
    'asynchronous tab burst readiness barrier',
    'session-state file',
    'restored tabs',
    'corrupt state quarantine',
    'fresh tab after corrupt state'
)
if (@($requiredSessionDiagnostics | Where-Object {
            $sessionDiagnosticStrings -notcontains $_
        }).Count -ne 0) {
    throw 'Session restore story is missing an observable causal-boundary diagnostic.'
}

$sessionPassCommands = @(
    Get-NamedCommands `
        -Ast $sessionAst.EndBlock `
        -Name 'Write-Host' |
        Where-Object {
            $_.CommandElements.Count -ge 2 -and
                $_.CommandElements[1] -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                $_.CommandElements[1].Value.StartsWith(
                    'interactive-win11 session-restore validation: PASS',
                    [StringComparison]::Ordinal
                )
        }
)
$sessionInvariantLoops = @($sessionAst.EndBlock.Statements | Where-Object {
    if ($_ -isnot [System.Management.Automation.Language.ForEachStatementAst] -or
        (Get-VariableExpressionName -Node $_.Variable) -ne 'run' -or
        $_.Condition.Extent.Text.Trim() -cne '$runs') {
        return $false
    }
    $selectCalls = @(Get-NamedCommands -Ast $_.Body -Name 'Select-String')
    if ($selectCalls.Count -ne 1 -or
        -not (Test-CommandHasStringArgument `
            -Command $selectCalls[0] `
            -Value 'shell/native invariant failed')) {
        return $false
    }
    $literalPath = Get-CommandParameterArgument `
        -Command $selectCalls[0] `
        -Name 'LiteralPath'
    $switchNames = @($selectCalls[0].CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst]
    } | ForEach-Object { $_.ParameterName })
    $throws = @($_.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ThrowStatementAst] -and
            $node.Extent.Text -match 'Shell/native invariant failure reported'
    }, $true))
    return $literalPath -is [System.Management.Automation.Language.MemberExpressionAst] -and
        (Get-ExpressionRootVariableName -Node $literalPath) -eq 'run' -and
        (Get-MemberExpressionName -Node $literalPath) -eq 'Stderr' -and
        $switchNames -contains 'SimpleMatch' -and
        $switchNames -contains 'Quiet' -and
        $throws.Count -eq 1
})
$passStatement = if ($sessionPassCommands.Count -eq 1) {
    $sessionPassCommands[0].Parent
} else {
    $null
}
$topLevelStatements = @($sessionAst.EndBlock.Statements)
$invariantIndex = if ($sessionInvariantLoops.Count -eq 1) {
    [Array]::IndexOf($topLevelStatements, $sessionInvariantLoops[0])
} else {
    -1
}
$passIndex = [Array]::IndexOf($topLevelStatements, $passStatement)
if ($sessionPassCommands.Count -ne 1 -or
    $sessionInvariantLoops.Count -ne 1 -or
    $invariantIndex -lt 0 -or
    $passIndex -le $invariantIndex) {
    throw 'Session restore must reject the shell/native invariant stderr marker before emitting its stable PASS diagnostic.'
}
