#requires -Version 7.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $root))

function Assert-JsonDocument {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $json = Get-Content -LiteralPath $Path -Raw
    if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
        if (-not ($json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) {
            throw "JSON contract validation failed: $Path"
        }
        return
    }

    try {
        Add-Type -AssemblyName System.Web.Extensions
        $parser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $parser.MaxJsonLength = [int]::MaxValue
        [void]$parser.DeserializeObject($json)
        [void]$parser.DeserializeObject((Get-Content -LiteralPath $SchemaPath -Raw))
    } catch {
        throw "JSON syntax validation failed: $Path ($($_.Exception.Message))"
    }
}

function Assert-PassArtifactsBound {
    param([Parameter(Mandatory)] [string] $Path)

    $result = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($result.status -eq 'pass' -and @($result.artifacts | Where-Object { -not $_.sha256 }).Count -ne 0) {
        throw "Passing verification result has an unbound artifact hash: $Path"
    }
}

function Assert-WorkflowContract {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Description
    )

    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -notmatch $Pattern) {
        throw "Workflow contract missing: $Description ($Path)"
    }
}

function Assert-WorkflowContractAbsent {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Description
    )

    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -match $Pattern) {
        throw "Workflow contract forbidden: $Description ($Path)"
    }
}

function Assert-TextContract {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string] $Context
    )

    if ($Content -notmatch $Pattern) { throw "Contract missing: $Description ($Context)" }
}

function Get-YamlJobText {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Source
    )

    $pattern = '(?ms)^  ' + [regex]::Escape($Name) + ':\s*(?:#.*)?\r?\n.*?(?=^  \S[^\r\n]*:\s*(?:#.*)?$|\z)'
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) { throw "Workflow job not found: $Name ($Source)" }
    $match.Value
}

function Get-YamlStepText {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Source
    )

    $pattern = '(?ms)^      - name:\s+' + [regex]::Escape($Name) + '\s*\r?\n.*?(?=^      -\s+|^    \S[^\r\n]*:\s*(?:#.*)?$|^  \S[^\r\n]*:\s*(?:#.*)?$|\z)'
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) { throw "Workflow step not found: $Name ($Source)" }
    $match.Value
}

function Get-PowerShellBlockText {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $HeaderPattern
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { throw "PowerShell contract source does not parse: $($errors[0].Message)" }
    $blocks = @($ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $node -is [System.Management.Automation.Language.IfStatementAst] -or
            $node -is [System.Management.Automation.Language.ForEachStatementAst]) -and
            $node.Extent.Text -match $HeaderPattern
    }, $true))
    if ($blocks.Count -ne 1) { throw "Expected exactly one PowerShell block for '$HeaderPattern'; found $($blocks.Count)." }
    $blocks[0].Extent.Text
}

function Test-DirectStatementBlockChild {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [System.Management.Automation.Language.StatementBlockAst] $StatementBlock
    )

    $ancestor = $Node.Parent
    while ($null -ne $ancestor -and $ancestor -isnot [System.Management.Automation.Language.StatementBlockAst]) {
        if ($ancestor -isnot [System.Management.Automation.Language.PipelineAst] -and
            $ancestor -isnot [System.Management.Automation.Language.AssignmentStatementAst] -and
            $ancestor -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
            return $false
        }
        $ancestor = $ancestor.Parent
    }
    [object]::ReferenceEquals($ancestor, $StatementBlock)
}

$stepBoundaryProbe = @'
      - name: Target
        run: inside-step
      - uses: example/outside-step@v1
      - name: Other
        run: outside-step
'@
if ((Get-YamlStepText -Content $stepBoundaryProbe -Name 'Target' -Source 'step boundary probe') -match 'outside-step') {
    throw 'Workflow step extraction crossed a step boundary.'
}
$stepTailProbe = "      - name: Target`n        run: inside-step`n    env: # job-level tail`n      VALUE: outside-step"
if ((Get-YamlStepText -Content $stepTailProbe -Name 'Target' -Source 'step tail probe') -match 'outside-step') {
    throw 'Workflow step extraction crossed a job-level key boundary.'
}
$jobBoundaryProbe = "  target:`n    value: inside-job`n  `"other.job`": # annotated`n    value: outside-job"
if ((Get-YamlJobText -Content $jobBoundaryProbe -Name 'target' -Source 'job boundary probe') -match 'outside-job') {
    throw 'Workflow job extraction crossed an annotated job boundary.'
}
$blockBoundaryProbe = @'
if ($RequirePackageManagers) {
    Write-Host "inside { literal"
    # A comment containing } is not a block boundary.
}
Write-Host outside-block
'@
if ((Get-PowerShellBlockText -Content $blockBoundaryProbe -HeaderPattern '^if \(\$RequirePackageManagers\)') -match 'outside-block') {
    throw 'PowerShell AST extraction crossed a block boundary.'
}

$schemaPaths = @(
    'scenario.schema.json'
    'result.schema.json'
    'baseline-manifest.schema.json'
) | ForEach-Object { Join-Path $root $_ }

foreach ($schemaPath in $schemaPaths) {
    Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json | Out-Null
}

$scenarioSchema = Join-Path $root 'scenario.schema.json'
$scenarioIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($scenarioPath in Get-ChildItem -LiteralPath (Join-Path $root 'scenarios') -Filter '*.json') {
    Assert-JsonDocument -Path $scenarioPath.FullName -SchemaPath $scenarioSchema
    $scenario = Get-Content -LiteralPath $scenarioPath.FullName -Raw | ConvertFrom-Json
    if (-not $scenarioIds.Add($scenario.id)) {
        throw "Duplicate flagship scenario id: $($scenario.id)"
    }
}

Assert-JsonDocument `
    -Path (Join-Path $root 'examples\result.json') `
    -SchemaPath (Join-Path $root 'result.schema.json')
$exampleResult = Get-Content -LiteralPath (Join-Path $root 'examples\result.json') -Raw | ConvertFrom-Json
if (-not $exampleResult.example -or -not $exampleResult.scenario_id.StartsWith('example.')) {
    throw 'Example verification result must be explicitly marked and use an example.* scenario id.'
}
Assert-PassArtifactsBound -Path (Join-Path $root 'examples\result.json')
foreach ($resultPath in Get-ChildItem -LiteralPath (Join-Path $root 'artifacts') -Filter result.json -Recurse -ErrorAction SilentlyContinue) {
    Assert-JsonDocument -Path $resultPath.FullName -SchemaPath (Join-Path $root 'result.schema.json')
    Assert-PassArtifactsBound -Path $resultPath.FullName
}
Assert-JsonDocument `
    -Path (Join-Path $root 'examples\baseline-manifest.json') `
    -SchemaPath (Join-Path $root 'baseline-manifest.schema.json')

$releaseWorkflow = Join-Path $repoRoot '.github\workflows\release.yml'
$readinessWorkflow = Join-Path $repoRoot '.github\workflows\release-readiness.yml'
$testWorkflow = Join-Path $repoRoot '.github\workflows\test.yml'
$accessibilityChecker = Join-Path $repoRoot 'scripts\check-accessibility-evidence.ps1'
$runnerProvenanceChecker = Join-Path $repoRoot 'test\windows\assert-interactive-runner.ps1'
$sessionRestoreHarness = Join-Path $repoRoot 'test\windows\interactive-win11-session-restore.ps1'
$releaseCopyChecker = Join-Path $repoRoot 'scripts\check-release-copy.ps1'
$releasePreflight = Join-Path $repoRoot 'scripts\release-preflight.ps1'
$releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflow -Raw
$readinessWorkflowText = Get-Content -LiteralPath $readinessWorkflow -Raw
$testWorkflowText = Get-Content -LiteralPath $testWorkflow -Raw
$sessionRestoreHarnessText = Get-Content -LiteralPath $sessionRestoreHarness -Raw
$sessionRestoreTabSeedLoop = Get-PowerShellBlockText `
    -Content $sessionRestoreHarnessText `
    -HeaderPattern '^foreach \(\$targetTabCount in 2\.\.3\)'
$sessionLoopTokens = $null
$sessionLoopErrors = $null
$sessionLoopAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $sessionRestoreTabSeedLoop,
    [ref]$sessionLoopTokens,
    [ref]$sessionLoopErrors
)
if ($sessionLoopErrors.Count -ne 0) { throw "Session restore tab-seed loop does not parse: $($sessionLoopErrors[0].Message)" }
$sessionLoopNodes = @($sessionLoopAst.FindAll({ param($node) $true }, $true))
$sessionDeadlineNodes = @($sessionLoopNodes | Where-Object {
    $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)'
})
$sessionCommandNodes = @($sessionLoopNodes | Where-Object {
    $_ -is [System.Management.Automation.Language.CommandAst] -and
    $_.Extent.Text.Trim() -eq 'Invoke-StatefulCommand $hostHwnd 1904 $deadline $first.Process'
})
$sessionWaitNodes = @($sessionLoopNodes | Where-Object {
    $_ -is [System.Management.Automation.Language.CommandAst] -and
    $_.Extent.Text.Trim() -match '(?s)^Wait-InteractiveWin11Until -Deadline \$deadline -Description "live tab count \$targetTabCount" -Process \$first\.Process -Condition \{\s*\(Get-StatefulTabCount \$hostHwnd\) -eq \$targetTabCount\s*\}$'
})
$sessionBarrierNodes = @($sessionLoopNodes | Where-Object {
    $_ -is [System.Management.Automation.Language.BinaryExpressionAst] -and
    $_.Extent.Text.Trim() -eq '(Get-StatefulTabCount $hostHwnd) -eq $targetTabCount'
})
$sessionReadyNodes = @($sessionLoopNodes | Where-Object {
    $_ -is [System.Management.Automation.Language.CommandAst] -and
    $_.Extent.Text.Trim() -eq 'Invoke-InteractiveWin11Message -Hwnd $hostHwnd -Message 0 -Deadline $deadline -Description "live tab $targetTabCount readiness barrier" -Process $first.Process'
})
if ($sessionDeadlineNodes.Count -ne 1 -or $sessionCommandNodes.Count -ne 1 -or
    $sessionWaitNodes.Count -ne 1 -or $sessionBarrierNodes.Count -ne 1 -or
    $sessionReadyNodes.Count -ne 1) {
    throw 'Session restore tab-seed loop must contain one exact deadline, send, count wait, equality barrier, and pump-readiness barrier per iteration.'
}
$sessionParsedSeedLoops = @($sessionLoopNodes | Where-Object {
    $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $_.Extent.Text -match '^foreach \(\$targetTabCount in 2\.\.3\)'
})
if ($sessionParsedSeedLoops.Count -ne 1 -or $sessionParsedSeedLoops[0].Body.Statements.Count -ne 4) {
    throw 'Session restore tab-seed contract must parse to one loop containing exactly four executable statements.'
}
foreach ($node in @($sessionDeadlineNodes[0], $sessionCommandNodes[0], $sessionWaitNodes[0], $sessionReadyNodes[0])) {
    if (-not (Test-DirectStatementBlockChild -Node $node -StatementBlock $sessionParsedSeedLoops[0].Body)) {
        throw 'Session restore tab-seed operations must be direct, executable statements in the loop body.'
    }
}
$sessionSeedOffsets = @(
    $sessionDeadlineNodes[0].Extent.StartOffset,
    $sessionCommandNodes[0].Extent.StartOffset,
    $sessionWaitNodes[0].Extent.StartOffset,
    $sessionBarrierNodes[0].Extent.StartOffset,
    $sessionReadyNodes[0].Extent.StartOffset
)
for ($i = 1; $i -lt $sessionSeedOffsets.Count; $i++) {
    if ($sessionSeedOffsets[$i - 1] -ge $sessionSeedOffsets[$i]) {
        throw 'Session restore tab-seed operations are not in fail-closed causal order.'
    }
}
$sessionHarnessTokens = $null
$sessionHarnessErrors = $null
$sessionHarnessAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $sessionRestoreHarnessText,
    [ref]$sessionHarnessTokens,
    [ref]$sessionHarnessErrors
)
if ($sessionHarnessErrors.Count -ne 0) { throw "Session restore harness does not parse: $($sessionHarnessErrors[0].Message)" }
$sessionMainTries = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $node.Parent -is [System.Management.Automation.Language.NamedBlockAst]
}, $true))
$sessionSeedLoops = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Extent.Text -match '^foreach \(\$targetTabCount in 2\.\.3\)'
}, $true))
if ($sessionMainTries.Count -ne 1 -or $sessionSeedLoops.Count -ne 1 -or
    -not (Test-DirectStatementBlockChild -Node $sessionSeedLoops[0] -StatementBlock $sessionMainTries[0].Body)) {
    throw 'Session restore tab seeding must be one direct, executable loop in the main try body.'
}
$sessionBurstCommands = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Invoke-StatefulPostedCommand $explicitHost 1904 $explicit.Process'
}, $true))
$sessionExplicitStarts = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq "Start-StatefulApp `$layout `$exe `$repoRoot 'session-explicit-command' @('-e', 'cmd.exe', '/k')"
}, $true))
$sessionBurstWaits = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq "Wait-InteractiveWin11Until -Deadline `$deadline -Description 'asynchronous burst-created tabs' -Process `$explicit.Process -Condition { (Get-StatefulTabCount `$explicitHost) -eq 3 }"
}, $true))
$sessionBurstReady = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq "Invoke-InteractiveWin11Message -Hwnd `$explicitHost -Message 0 -Deadline `$deadline -Description 'asynchronous tab burst readiness barrier' -Process `$explicit.Process"
}, $true))
$sessionExplicitCloses = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Close-StatefulHost $explicitHost $explicit $deadline'
}, $true))
$sessionExactDeadlines = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)'
}, $true))
$sessionInvariantLoops = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and
        $node.Extent.Text.Trim() -match '(?s)^foreach \(\$run in \$runs\) \{\s*if \(Select-String -LiteralPath \$run\.Stderr -SimpleMatch ''shell/native invariant failed'' -Quiet\) \{\s*throw "Shell/native invariant failure reported by \$\(\$run\.Stderr\)\."\s*\}\s*\}$'
}, $true))
if ($sessionExplicitStarts.Count -ne 1 -or $sessionBurstCommands.Count -ne 2 -or
    $sessionBurstWaits.Count -ne 1 -or $sessionBurstReady.Count -ne 1 -or
    $sessionExplicitCloses.Count -ne 1 -or $sessionInvariantLoops.Count -ne 1) {
    throw 'Session restore validation must preserve the explicit-process burst phase, its exact-count/pump barriers, and invariant-log rejection.'
}
$sessionBurstDeadlines = @($sessionExactDeadlines | Where-Object {
    (Test-DirectStatementBlockChild -Node $_ -StatementBlock $sessionMainTries[0].Body) -and
    $_.Extent.StartOffset -gt $sessionBurstCommands[1].Extent.EndOffset -and
    $_.Extent.EndOffset -lt $sessionBurstWaits[0].Extent.StartOffset
})
$sessionCloseDeadlines = @($sessionExactDeadlines | Where-Object {
    (Test-DirectStatementBlockChild -Node $_ -StatementBlock $sessionMainTries[0].Body) -and
    $_.Extent.StartOffset -gt $sessionBurstReady[0].Extent.EndOffset -and
    $_.Extent.EndOffset -lt $sessionExplicitCloses[0].Extent.StartOffset
})
if ($sessionBurstDeadlines.Count -ne 1 -or $sessionCloseDeadlines.Count -ne 1) {
    throw 'Session restore asynchronous burst and close phases must each receive one fresh exact deadline.'
}
$sessionDirectBurstNodes = @(
    $sessionExplicitStarts[0],
    $sessionBurstCommands[0],
    $sessionBurstCommands[1],
    $sessionBurstDeadlines[0],
    $sessionBurstWaits[0],
    $sessionBurstReady[0],
    $sessionCloseDeadlines[0],
    $sessionExplicitCloses[0]
)
foreach ($node in $sessionDirectBurstNodes) {
    if (-not (Test-DirectStatementBlockChild -Node $node -StatementBlock $sessionMainTries[0].Body)) {
        throw 'Session restore asynchronous burst operations must be direct, executable statements in the main try body.'
    }
}
$sessionInvariantIfs = @($sessionInvariantLoops[0].FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst]
}, $true))
$sessionInvariantThrows = @($sessionInvariantLoops[0].FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ThrowStatementAst] -and
        $node.Extent.Text.Trim() -eq 'throw "Shell/native invariant failure reported by $($run.Stderr)."'
}, $true))
$sessionPassCommands = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.Extent.Text.Trim() -eq 'Write-Host "interactive-win11 session-restore validation: PASS (state=$statePath)"'
}, $true))
if ($sessionPassCommands.Count -ne 1) {
    throw 'Session restore story must contain one exact PASS sentinel.'
}
$sessionBootstrapIfs = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match '^if \(-not \$env:WINGHOSTTY_INTERACTIVE_WIN11_SESSION_RESTORE_BOOTSTRAPPED\)'
}, $true))
if ($sessionBootstrapIfs.Count -ne 1) {
    throw 'Session restore story must contain one exact bootstrap guard.'
}
$sessionSnapshotFunctions = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-SessionAutomationSnapshot' -and
        $node.Extent.Text -match '^function Get-SessionAutomationSnapshot\(\[string\]\$Name, \[DateTime\]\$Deadline\)'
}, $true))
if ($sessionSnapshotFunctions.Count -ne 1) {
    throw 'Session restore story must contain one exact automation snapshot helper.'
}
$sessionSnapshotRetryLoops = @($sessionSnapshotFunctions[0].FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Extent.Text -match '^foreach \(\$attempt in 1\.\.3\)'
}, $true))
$sessionSnapshotWaitIfs = @($sessionSnapshotFunctions[0].FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match '^if \(-not \$query\.WaitForExit\(\$remainingMs\)\)'
}, $true))
$sessionSnapshotOutputIfs = @($sessionSnapshotFunctions[0].FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match '^if \(\(Test-Path \$out\) -and \(Get-Item \$out\)\.Length -gt 0\)'
}, $true))
if ($sessionSnapshotRetryLoops.Count -ne 1 -or $sessionSnapshotWaitIfs.Count -ne 1 -or
    $sessionSnapshotOutputIfs.Count -ne 1 -or
    -not [object]::ReferenceEquals($sessionSnapshotRetryLoops[0].Parent, $sessionSnapshotFunctions[0].Body.EndBlock) -or
    -not (Test-DirectStatementBlockChild -Node $sessionSnapshotWaitIfs[0] -StatementBlock $sessionSnapshotRetryLoops[0].Body) -or
    -not (Test-DirectStatementBlockChild -Node $sessionSnapshotOutputIfs[0] -StatementBlock $sessionSnapshotRetryLoops[0].Body)) {
    throw 'Session restore automation snapshot control flow must remain directly inside one retry loop.'
}
$sessionSnapshotFunctionStatements = @($sessionSnapshotFunctions[0].Body.EndBlock.Statements)
if ($sessionSnapshotFunctionStatements.Count -ne 5 -or
    $sessionSnapshotFunctionStatements[0].Extent.Text.Trim() -ne '$cli = Join-Path (Split-Path -Parent $exe) ''winghostty.com''' -or
    $sessionSnapshotFunctionStatements[1].Extent.Text.Trim() -ne 'if (-not (Test-Path -LiteralPath $cli)) { throw "Missing automation CLI shim: $cli" }' -or
    $sessionSnapshotFunctionStatements[2].Extent.Text.Trim() -ne '$lastError = ''''' -or
    -not [object]::ReferenceEquals($sessionSnapshotFunctionStatements[3], $sessionSnapshotRetryLoops[0]) -or
    $sessionSnapshotFunctionStatements[4].Extent.Text.Trim() -ne 'throw "Session automation query failed after three attempts: $lastError"') {
    throw 'Session restore automation snapshot helper setup, retry, and terminal failure are not in causal order.'
}
$sessionSnapshotLoopStatements = @($sessionSnapshotRetryLoops[0].Body.Statements)
$sessionSnapshotCausalPrefix = @(
    '$out = Join-Path $layout.Logs "$Name-$attempt.json"',
    '$err = Join-Path $layout.Logs "$Name-$attempt.stderr.log"',
    '$query = Start-Process -FilePath $cli -ArgumentList @(''+list-windows'', "--class=$instanceClass") -WorkingDirectory $repoRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru',
    '$remainingMs = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds)'
)
if ($sessionSnapshotLoopStatements.Count -lt 7) {
    throw 'Session restore automation snapshot retry loop is missing causal statements.'
}
for ($i = 0; $i -lt $sessionSnapshotCausalPrefix.Count; $i++) {
    if ($sessionSnapshotLoopStatements[$i].Extent.Text.Trim() -ne $sessionSnapshotCausalPrefix[$i]) {
        throw 'Session restore automation snapshot path, launch, and deadline statements are not in causal order.'
    }
}
if (-not [object]::ReferenceEquals($sessionSnapshotLoopStatements[4], $sessionSnapshotWaitIfs[0]) -or
    $sessionSnapshotLoopStatements[5].Extent.Text.Trim() -ne '$query.Refresh()' -or
    -not [object]::ReferenceEquals($sessionSnapshotLoopStatements[6], $sessionSnapshotOutputIfs[0])) {
    throw 'Session restore automation snapshot must wait, refresh, then inspect fresh output.'
}
$sessionRunsAssignments = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$runs' -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true))
$sessionInstanceClassAssignments = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text.Trim() -eq '$instanceClass = "winghostty-interactive-$($layout.SandboxId)"'
}, $true))
$sessionTopLevelStatements = @($sessionHarnessAst.EndBlock.Statements)
$sessionRunsInitializationIndex = -1
$sessionInstanceClassIndex = -1
$sessionSnapshotFunctionIndex = -1
$sessionMainTryIndex = -1
$sessionInvariantIndex = -1
$sessionPassIndex = -1
for ($i = 0; $i -lt $sessionTopLevelStatements.Count; $i++) {
    if ($sessionRunsAssignments.Count -eq 1 -and [object]::ReferenceEquals($sessionTopLevelStatements[$i], $sessionRunsAssignments[0])) { $sessionRunsInitializationIndex = $i }
    if ($sessionInstanceClassAssignments.Count -eq 1 -and [object]::ReferenceEquals($sessionTopLevelStatements[$i], $sessionInstanceClassAssignments[0])) { $sessionInstanceClassIndex = $i }
    if ([object]::ReferenceEquals($sessionTopLevelStatements[$i], $sessionSnapshotFunctions[0])) { $sessionSnapshotFunctionIndex = $i }
    if ([object]::ReferenceEquals($sessionTopLevelStatements[$i], $sessionMainTries[0])) { $sessionMainTryIndex = $i }
    if ([object]::ReferenceEquals($sessionTopLevelStatements[$i], $sessionInvariantLoops[0])) { $sessionInvariantIndex = $i }
    if ([object]::ReferenceEquals($sessionTopLevelStatements[$i], $sessionPassCommands[0].Parent)) { $sessionPassIndex = $i }
}
$sessionControlTransfers = @($sessionHarnessAst.FindAll({
    param($node)
    ($node -is [System.Management.Automation.Language.ReturnStatementAst] -or
        $node -is [System.Management.Automation.Language.BreakStatementAst] -or
        $node -is [System.Management.Automation.Language.ContinueStatementAst] -or
        $node -is [System.Management.Automation.Language.ExitStatementAst]) -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true))
$sessionFunctionDefinitions = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true))
$sessionRunsInvocations = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -eq '$runs' -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true) | Sort-Object { $_.Extent.StartOffset })
$sessionExpectedRunsInvocations = @(
    '$runs.Add($first)',
    '$runs.Add($explicit)',
    '$runs.Add($second)',
    '$runs.Add($third)'
)
$sessionExpectedStartAssignments = @(
    '$first = Start-StatefulApp $layout $exe $repoRoot ''session-save'' @(''--single-instance=true'')',
    '$explicit = Start-StatefulApp $layout $exe $repoRoot ''session-explicit-command'' @(''-e'', ''cmd.exe'', ''/k'')',
    '$second = Start-StatefulApp $layout $exe $repoRoot ''session-restore'' @(''--single-instance=true'')',
    '$third = Start-StatefulApp $layout $exe $repoRoot ''session-corrupt'''
)
$sessionStartAssignments = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text.Trim() -in $sessionExpectedStartAssignments
}, $true) | Sort-Object { $_.Extent.StartOffset })
$sessionAllStartCommands = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Start-StatefulApp' -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true) | Sort-Object { $_.Extent.StartOffset })
$sessionEapAssignments = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$ErrorActionPreference' -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true))
$sessionForbiddenTermination = @($sessionHarnessAst.FindAll({
    param($node)
    (($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $node.Expression.TypeName.FullName -in @('Environment', 'System.Environment') -and
            $node.Member.Extent.Text -eq 'Exit') -or
        ($node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -match '(^|\\)(Stop-Process|taskkill(?:\.exe)?|Invoke-Expression|iex)$')) -and
        $node.Extent.EndOffset -le $sessionPassCommands[0].Extent.EndOffset
}, $true))
$sessionBootstrapBody = $sessionBootstrapIfs[0].Clauses[0].Item2
$sessionSnapshotWaitBody = $sessionSnapshotWaitIfs[0].Clauses[0].Item2
$sessionSnapshotOutputBody = $sessionSnapshotOutputIfs[0].Clauses[0].Item2
$sessionBootstrapExits = @($sessionControlTransfers | Where-Object {
    $_ -is [System.Management.Automation.Language.ExitStatementAst] -and
    $_.Extent.Text.Trim() -eq 'exit $code' -and
    [object]::ReferenceEquals($_.Parent, $sessionBootstrapBody) -and
    [object]::ReferenceEquals($_, $sessionBootstrapBody.Statements[-1])
})
$sessionSnapshotContinues = @($sessionControlTransfers | Where-Object {
    $_ -is [System.Management.Automation.Language.ContinueStatementAst] -and
    $_.Extent.Text.Trim() -eq 'continue' -and
    [object]::ReferenceEquals($_.Parent, $sessionSnapshotWaitBody) -and
    [object]::ReferenceEquals($_, $sessionSnapshotWaitBody.Statements[-1])
})
$sessionSnapshotReturns = @($sessionControlTransfers | Where-Object {
    $_ -is [System.Management.Automation.Language.ReturnStatementAst] -and
    $_.Extent.Text.Trim() -eq 'return Get-Content $out -Raw | ConvertFrom-Json' -and
    $sessionSnapshotOutputBody.Statements.Count -eq 1 -and
    [object]::ReferenceEquals($_.Parent, $sessionSnapshotOutputBody) -and
    [object]::ReferenceEquals($_, $sessionSnapshotOutputBody.Statements[0])
})
if ($sessionRunsInvocations.Count -eq $sessionExpectedRunsInvocations.Count) {
    for ($i = 0; $i -lt $sessionExpectedRunsInvocations.Count; $i++) {
        if ($sessionRunsInvocations[$i].Extent.Text.Trim() -ne $sessionExpectedRunsInvocations[$i]) {
            throw 'Session restore invariant evidence set was mutated or reordered.'
        }
    }
}
if ($sessionStartAssignments.Count -eq $sessionExpectedStartAssignments.Count -and
    $sessionRunsInvocations.Count -eq $sessionExpectedRunsInvocations.Count -and
    $sessionAllStartCommands.Count -eq $sessionExpectedStartAssignments.Count) {
    $sessionMainTryStatements = @($sessionMainTries[0].Body.Statements)
    for ($i = 0; $i -lt $sessionExpectedStartAssignments.Count; $i++) {
        if ($sessionStartAssignments[$i].Extent.Text.Trim() -ne $sessionExpectedStartAssignments[$i] -or
            -not [object]::ReferenceEquals($sessionAllStartCommands[$i].Parent.Parent, $sessionStartAssignments[$i]) -or
            -not (Test-DirectStatementBlockChild -Node $sessionStartAssignments[$i] -StatementBlock $sessionMainTries[0].Body) -or
            -not (Test-DirectStatementBlockChild -Node $sessionRunsInvocations[$i] -StatementBlock $sessionMainTries[0].Body)) {
            throw 'Session restore process launch and evidence registration must be direct main-story statements.'
        }
        $startIndex = -1
        $addIndex = -1
        for ($statementIndex = 0; $statementIndex -lt $sessionMainTryStatements.Count; $statementIndex++) {
            if ([object]::ReferenceEquals($sessionMainTryStatements[$statementIndex], $sessionStartAssignments[$i])) { $startIndex = $statementIndex }
            if ([object]::ReferenceEquals($sessionMainTryStatements[$statementIndex], $sessionRunsInvocations[$i].Parent.Parent)) { $addIndex = $statementIndex }
        }
        if ($addIndex -ne ($startIndex + 1)) {
            throw 'Session restore must register each launched process immediately for cleanup and invariant scanning.'
        }
    }
}
if ($sessionInvariantIfs.Count -ne 1 -or $sessionInvariantThrows.Count -ne 1 -or
    $sessionFunctionDefinitions.Count -ne 1 -or
    -not [object]::ReferenceEquals($sessionFunctionDefinitions[0], $sessionSnapshotFunctions[0]) -or
    $sessionRunsAssignments.Count -ne 1 -or
    $sessionRunsAssignments[0].Extent.Text.Trim() -ne '$runs = [Collections.Generic.List[object]]::new()' -or
    $sessionInstanceClassAssignments.Count -ne 1 -or
    $sessionRunsInvocations.Count -ne $sessionExpectedRunsInvocations.Count -or
    $sessionStartAssignments.Count -ne $sessionExpectedStartAssignments.Count -or
    $sessionAllStartCommands.Count -ne $sessionExpectedStartAssignments.Count -or
    $sessionEapAssignments.Count -ne 1 -or
    $sessionEapAssignments[0].Extent.Text.Trim() -ne '$ErrorActionPreference = ''Stop''' -or
    -not [object]::ReferenceEquals($sessionEapAssignments[0], $sessionTopLevelStatements[0]) -or
    $sessionForbiddenTermination.Count -ne 0 -or
    $sessionControlTransfers.Count -ne 3 -or $sessionBootstrapExits.Count -ne 1 -or
    $sessionSnapshotContinues.Count -ne 1 -or $sessionSnapshotReturns.Count -ne 1 -or
    $sessionInstanceClassIndex -ne ($sessionRunsInitializationIndex + 1) -or
    $sessionSnapshotFunctionIndex -ne ($sessionInstanceClassIndex + 1) -or
    $sessionMainTryIndex -ne ($sessionSnapshotFunctionIndex + 1) -or
    $sessionInvariantIndex -ne ($sessionMainTryIndex + 1) -or
    $sessionPassIndex -ne ($sessionInvariantIndex + 1) -or
    $sessionPassIndex -ne ($sessionTopLevelStatements.Count - 1) -or
    $sessionInvariantLoops[0].Extent.StartOffset -le $sessionMainTries[0].Extent.EndOffset -or
    $sessionInvariantLoops[0].Extent.EndOffset -ge $sessionPassCommands[0].Extent.StartOffset) {
    throw 'Session restore story must reach invariant rejection after cleanup and before the PASS sentinel without an early control transfer.'
}
$sessionBurstOffsets = @(
    $sessionExplicitStarts[0].Extent.StartOffset,
    $sessionBurstCommands[0].Extent.StartOffset,
    $sessionBurstCommands[1].Extent.StartOffset,
    $sessionBurstDeadlines[0].Extent.StartOffset,
    $sessionBurstWaits[0].Extent.StartOffset,
    $sessionBurstReady[0].Extent.StartOffset,
    $sessionCloseDeadlines[0].Extent.StartOffset,
    $sessionExplicitCloses[0].Extent.StartOffset
)
for ($i = 1; $i -lt $sessionBurstOffsets.Count; $i++) {
    if ($sessionBurstOffsets[$i - 1] -ge $sessionBurstOffsets[$i]) {
        throw 'Session restore asynchronous burst operations are not in fail-closed causal order.'
    }
}
$betweenBurstPosts = $sessionRestoreHarnessText.Substring(
    $sessionBurstCommands[0].Extent.EndOffset,
    $sessionBurstCommands[1].Extent.StartOffset - $sessionBurstCommands[0].Extent.EndOffset
)
if ($betweenBurstPosts -notmatch '^\s*$') {
    throw 'Session restore asynchronous new-tab posts must remain adjacent.'
}
Assert-TextContract `
    -Content (Get-YamlStepText -Content $releaseWorkflowText -Name 'Release preflight' -Source $releaseWorkflow) `
    -Pattern '(?ms)check-release-copy\.ps1 -ExpectedVersion.*?\r?\n\s+if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}' `
    -Description 'release preflight propagates release-copy failures' `
    -Context "$releaseWorkflow :: Release preflight"
Assert-TextContract `
    -Content (Get-YamlStepText -Content $readinessWorkflowText -Name 'Validate release configuration' -Source $readinessWorkflow) `
    -Pattern '(?ms)check-release-copy\.ps1 -ExpectedVersion.*?\r?\n\s+if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}' `
    -Description 'release readiness propagates release-copy failures' `
    -Context "$readinessWorkflow :: Validate release configuration"
Assert-TextContract `
    -Content (Get-YamlStepText -Content $releaseWorkflowText -Name 'Verify published release copy and assets' -Source $releaseWorkflow) `
    -Pattern '(?ms)env:\s+GH_TOKEN: \$\{\{ github\.token \}\}.*?CheckRemoteLatest' `
    -Description 'post-publish remote verification authenticates gh' `
    -Context "$releaseWorkflow :: Verify published release copy and assets"
Assert-TextContract `
    -Content (Get-YamlStepText -Content $testWorkflowText -Name 'Remote release copy checks' -Source $testWorkflow) `
    -Pattern '(?ms)env:\s+GH_TOKEN: \$\{\{ github\.token \}\}.*?CheckRemoteLatest' `
    -Description 'scheduled remote verification authenticates gh' `
    -Context "$testWorkflow :: Remote release copy checks"
Assert-TextContract `
    -Content (Get-YamlStepText `
        -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows' -Source $testWorkflow) `
        -Name 'Setup Zig' `
        -Source "$testWorkflow :: windows") `
    -Pattern '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false' `
    -Description 'hosted Windows tests cannot restore failed Zig build caches' `
    -Context "$testWorkflow :: windows :: Setup Zig"
Assert-TextContract `
    -Content (Get-YamlStepText `
        -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-portable-smoke' -Source $testWorkflow) `
        -Name 'Setup Zig' `
        -Source "$testWorkflow :: windows-portable-smoke") `
    -Pattern '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false' `
    -Description 'portable smoke cannot restore failed Zig build caches' `
    -Context "$testWorkflow :: windows-portable-smoke :: Setup Zig"
Assert-TextContract `
    -Content (Get-YamlStepText `
        -Content (Get-YamlJobText -Content $releaseWorkflowText -Name 'windows-release' -Source $releaseWorkflow) `
        -Name 'Setup Zig' `
        -Source "$releaseWorkflow :: windows-release") `
    -Pattern '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false' `
    -Description 'release builds cannot restore failed Zig build caches' `
    -Context "$releaseWorkflow :: windows-release :: Setup Zig"
Assert-TextContract `
    -Content (Get-YamlStepText `
        -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow) `
        -Name 'Setup Zig' `
        -Source "$testWorkflow :: windows-interactive") `
    -Pattern '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false' `
    -Description 'ephemeral interactive retries cannot restore failed Zig build caches' `
    -Context "$testWorkflow :: windows-interactive :: Setup Zig"
Assert-TextContract `
    -Content (Get-YamlStepText `
        -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow) `
        -Name 'Run interactive Win11 composite' `
        -Source "$testWorkflow :: windows-interactive") `
    -Pattern '(?ms)env:\s+ZIG_GLOBAL_CACHE_DIR: \$\{\{ runner\.temp \}\}\\zig-global-cache\s+ZIG_LOCAL_CACHE_DIR: \$\{\{ runner\.temp \}\}\\zig-local-cache' `
    -Description 'interactive builds use clean per-job Zig caches' `
    -Context "$testWorkflow :: windows-interactive :: Run interactive Win11 composite"
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'scripts\dev-windows.cmd') `
    -Pattern '(?s)if "%ZIG_GLOBAL_CACHE_DIR%"=="" set "ZIG_GLOBAL_CACHE_DIR=.*?if "%ZIG_LOCAL_CACHE_DIR%"=="" set "ZIG_LOCAL_CACHE_DIR=' `
    -Description 'Windows bootstrap preserves caller-provided Zig cache isolation'
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'scripts\dev-windows.ps1') `
    -Pattern '(?s)IsNullOrWhiteSpace\(\$env:ZIG_GLOBAL_CACHE_DIR\).*?IsNullOrWhiteSpace\(\$env:ZIG_LOCAL_CACHE_DIR\)' `
    -Description 'PowerShell Windows bootstrap preserves caller-provided Zig cache isolation'
Assert-TextContract `
    -Content (Get-YamlStepText -Content $testWorkflowText -Name 'Upload interactive evidence' -Source $testWorkflow) `
    -Pattern '(?ms)include-hidden-files: true.*?github\.workspace.*?\.sandbox/win11/\*\*/logs/\*\*' `
    -Description 'interactive evidence upload includes the actual hidden sandbox log tree' `
    -Context "$testWorkflow :: Upload interactive evidence"
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\[DateTimeOffset\]::TryParse\(' `
    -Description 'accessibility evidence timestamp is semantically validated'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\$provenance\.runner_name -ne \$result\.environment\.runner_name' `
    -Description 'runner provenance is bound to the interactive result'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\$provenance\.runner_name -ne \$interactiveJob\[0\]\.runner_name' `
    -Description 'runner provenance is bound to the GitHub job'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\$provenanceRunAttempt -ne \[int\]\$run\.run_attempt' `
    -Description 'runner provenance is bound to the GitHub run attempt'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\[string\]\$provenance\.user -match .*SYSTEM' `
    -Description 'service-account runner provenance is rejected'
Assert-WorkflowContract `
    -Path $runnerProvenanceChecker `
    -Pattern "(?m)^\`$minimumRunnerVersion = \[version\]'2\.327\.1'\s*$" `
    -Description 'interactive evidence enforces the upload-artifact runner floor'
Assert-WorkflowContractAbsent `
    -Path $runnerProvenanceChecker `
    -Pattern '(?m)^\s*\[version\]\s+\$MinimumRunnerVersion\b' `
    -Description 'interactive runner floor cannot be lowered by a parameter'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern "(?m)^\s*\`$minimumRunnerVersion = \[version\]'2\.327\.1'\s*$" `
    -Description 'accessibility evidence pins the upload-artifact runner floor'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '(?m)^#requires -Version 7\.1\s*$' `
    -Description 'accessibility evidence requires PowerShell 7.1 or newer'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\$provenance = Get-Content -LiteralPath \$provenancePaths\[0\]\.FullName -Raw \| ConvertFrom-Json -NoEnumerate' `
    -Description 'accessibility evidence preserves the JSON root kind'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\$provenance\.GetType\(\) -ne \[System\.Management\.Automation\.PSCustomObject\]' `
    -Description 'accessibility evidence requires runner provenance to be a JSON object'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern "schema_version -ne 'winghostty\.interactive-runner-provenance\.v1'" `
    -Description 'accessibility evidence rejects unsupported runner provenance schemas'
Assert-WorkflowContract `
    -Path $runnerProvenanceChecker `
    -Pattern '\$runnerVersion -lt \$minimumRunnerVersion' `
    -Description 'interactive evidence rejects outdated runners'
Assert-WorkflowContract `
    -Path $accessibilityChecker `
    -Pattern '\$provenanceRunnerVersion -lt \$minimumRunnerVersion' `
    -Description 'accessibility evidence rejects outdated interactive runners'
$objectRoot = ConvertFrom-Json -InputObject '{"value":1}' -NoEnumerate
$arrayRoot = ConvertFrom-Json -InputObject '[{"value":1}]' -NoEnumerate
if ($objectRoot.GetType() -ne [System.Management.Automation.PSCustomObject] -or
    $arrayRoot.GetType() -eq [System.Management.Automation.PSCustomObject]) {
    throw 'PowerShell JSON root-kind preservation does not satisfy the evidence contract.'
}
Assert-WorkflowContract `
    -Path $releaseCopyChecker `
    -Pattern '\$global:LASTEXITCODE\s*=\s*0\s*$' `
    -Description 'release-copy success explicitly clears native exit state'
Assert-WorkflowContract `
    -Path $releasePreflight `
    -Pattern '\$minimumValidityDays -lt 180(?!\d)' `
    -Description 'signer-validity overrides cannot lower the 180-day floor'
Assert-TextContract `
    -Content (Get-PowerShellBlockText -Content (Get-Content -LiteralPath $releasePreflight -Raw) -HeaderPattern '^function\s+Assert-WingetArchitectureCoverage(?=\s|\{)') `
    -Pattern '(?ms)Assert-WingetArchitectureCoverage.*?Architecture:.*?arm64,x64' `
    -Description 'stable preflight requires public WinGet x64 and arm64 bootstrap' `
    -Context "$releasePreflight :: Assert-WingetArchitectureCoverage"
Assert-TextContract `
    -Content (Get-PowerShellBlockText -Content (Get-Content -LiteralPath $releasePreflight -Raw) -HeaderPattern '^if \(\$RequirePackageManagers\)') `
    -Pattern '(?ms)Assert-WingetArchitectureCoverage\s+`\r?\n\s+-ManifestPath' `
    -Description 'package-manager preflight invokes the WinGet architecture gate' `
    -Context "$releasePreflight :: RequirePackageManagers"

foreach ($baselinePath in Get-ChildItem -LiteralPath (Join-Path $root 'baselines') -Filter '*.json') {
    Assert-JsonDocument `
        -Path $baselinePath.FullName `
        -SchemaPath (Join-Path $root 'baseline-manifest.schema.json')
    $baseline = Get-Content -LiteralPath $baselinePath.FullName -Raw | ConvertFrom-Json
    & git -C $repoRoot cat-file -e "$($baseline.git_commit)^{commit}" 2>$null
    $baselineCommitAvailable = $LASTEXITCODE -eq 0
    if (-not $baselineCommitAvailable) {
        Write-Warning "Skipping frozen baseline git diff because commit is unavailable in this checkout: $($baseline.git_commit)"
    }
    foreach ($artifact in $baseline.artifacts) {
        $artifactPath = Join-Path $repoRoot $artifact.path
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Frozen baseline artifact is missing: $($artifact.path)"
        }
        if ($baselineCommitAvailable) {
            & git -C $repoRoot diff --quiet $baseline.git_commit -- $artifact.path
            if ($LASTEXITCODE -ne 0) {
                throw "Frozen baseline artifact drifted from $($baseline.git_commit): $($artifact.path)"
            }
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $artifact.sha256) {
            throw "Frozen baseline hash mismatch: $($artifact.path)"
        }
    }
}

Write-Host "flagship verification contracts: PASS ($($scenarioIds.Count) scenarios)"
exit 0
