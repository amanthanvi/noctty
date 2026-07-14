#requires -Version 7.3

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

function Get-DirectStatementBlockChild {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [System.Management.Automation.Language.StatementBlockAst] $StatementBlock
    )

    if (-not (Test-DirectStatementBlockChild -Node $Node -StatementBlock $StatementBlock)) {
        return $null
    }

    $statement = $Node
    $ancestor = $Node.Parent
    while ($null -ne $ancestor -and $ancestor -isnot [System.Management.Automation.Language.StatementBlockAst]) {
        $statement = $ancestor
        $ancestor = $ancestor.Parent
    }
    if (-not [object]::ReferenceEquals($ancestor, $StatementBlock)) { return $null }
    return $statement
}

function Get-MemberExpressionName {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.MemberExpressionAst] $Node)

    return ([string] $Node.Member.Value).Trim()
}

function Test-DynamicScriptTypeName {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $TypeName)

    $typeName = ((($TypeName -split ',', 2)[0] -replace '\s', '')).ToLowerInvariant()
    return $typeName -in @(
        'scriptblock',
        'system.management.automation.scriptblock',
        'powershell',
        'system.management.automation.powershell',
        'runspace',
        'runspacefactory',
        'system.management.automation.runspaces.runspace',
        'system.management.automation.runspaces.runspacefactory'
    )
}

function Test-DynamicScriptTypeExpression {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)

    return $Node -is [System.Management.Automation.Language.TypeExpressionAst] -and
        (Test-DynamicScriptTypeName -TypeName $Node.TypeName.FullName)
}

function Test-ExecutionContextRoot {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)

    while ($Node -is [System.Management.Automation.Language.ParenExpressionAst] -or
        $Node -is [System.Management.Automation.Language.SubExpressionAst]) {
        $pipeline = if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $Node.Pipeline
        } else {
            $statements = @($Node.SubExpression.Statements)
            if ($Node.SubExpression.Traps.Count -ne 0 -or $statements.Count -ne 1 -or
                $statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
                return $false
            }
            $statements[0]
        }
        $elements = @($pipeline.PipelineElements)
        if ($elements.Count -ne 1 -or $elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
            return $false
        }
        $Node = $elements[0].Expression
    }
    if ($Node -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
    return (($Node.VariablePath.UserPath -split ':')[-1] -eq 'ExecutionContext')
}

function Test-ExecutionContextMemberChain {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [string[]] $Members
    )

    if ($Node -isnot [System.Management.Automation.Language.MemberExpressionAst] -or
        (Get-MemberExpressionName -Node $Node) -ne $Members[-1]) {
        return $false
    }
    if ($Members.Count -eq 1) { return Test-ExecutionContextRoot -Node $Node.Expression }
    return Test-ExecutionContextMemberChain -Node $Node.Expression -Members @($Members[0..($Members.Count - 2)])
}

function Test-CommandResolutionMutationNode {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)

    if ($Node -is [System.Management.Automation.Language.ConvertExpressionAst] -and
        (($Node.Type.TypeName.FullName -replace '\s', '').ToLowerInvariant() -in @('type', 'system.type'))) {
        return $Node.Child -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            (Test-DynamicScriptTypeName -TypeName $Node.Child.Value)
    }
    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $Node.Operator -eq [System.Management.Automation.Language.TokenKind]::As -and
        $Node.Right -is [System.Management.Automation.Language.TypeExpressionAst] -and
        (($Node.Right.TypeName.FullName -replace '\s', '').ToLowerInvariant() -in @('type', 'system.type'))) {
        return $Node.Left -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
            (Test-DynamicScriptTypeName -TypeName $Node.Left.Value)
    }
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        (Test-DynamicScriptTypeName -TypeName $Node.Value)) {
        $isTypeConversion = $Node.Parent -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            (($Node.Parent.Type.TypeName.FullName -replace '\s', '') -in @('type', 'System.Type'))
        $isGetTypeArgument = $Node.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            (Get-MemberExpressionName -Node $Node.Parent) -eq 'GetType' -and
            @($Node.Parent.Arguments | Where-Object { [object]::ReferenceEquals($_, $Node) }).Count -eq 1
        $isAsTypeArgument = $Node.Parent -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $Node.Parent.Operator -eq [System.Management.Automation.Language.TokenKind]::As
        if ($isTypeConversion -or $isGetTypeArgument -or $isAsTypeArgument) { return $true }
    }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst] -and
        (($Node.VariablePath.UserPath -split ':')[-1] -eq 'ExecutionContext')) {
        $ancestor = $Node.Parent
        while ($null -ne $ancestor -and $ancestor -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
            $ancestor = $ancestor.Parent
        }
        if ($ancestor -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $ancestor.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
            (Test-ExecutionContextRoot -Node $ancestor.Right.Expression)) {
            return $true
        }
    }
    if ($Node -is [System.Management.Automation.Language.TypeExpressionAst] -and
        (Test-DynamicScriptTypeExpression -Node $Node) -and
        $Node.Parent -isnot [System.Management.Automation.Language.MemberExpressionAst]) {
        return $true
    }
    if ($Node -is [System.Management.Automation.Language.MemberExpressionAst]) {
        if ($Node.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $true
        }
        $memberName = Get-MemberExpressionName -Node $Node
        if ($Node.Extent.Text -match '(?is)TypeAccelerators.*(?:Add|Remove)\b') { return $true }
        if ($Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $memberName -eq 'GetType' -and $Node.Arguments.Count -ne 0) {
            return $true
        }
        if ((Test-DynamicScriptTypeExpression -Node $Node.Expression) -and
            $memberName -in @('Create', 'CreateRunspace', 'CreatePipeline', 'CreateNestedPipeline', 'GetMethod', 'GetMethods')) {
            return $true
        }
        if ($memberName -eq 'SessionState' -and
            (Test-ExecutionContextRoot -Node $Node.Expression)) {
            return $true
        }
        # Reject access to the InvokeCommand object itself so assigning it to
        # an alias cannot bypass the direct member-chain checks.
        if ($memberName -eq 'InvokeCommand' -and
            ((Test-ExecutionContextRoot -Node $Node.Expression) -or
                (Test-ExecutionContextMemberChain -Node $Node.Expression -Members @('SessionState')))) {
            return $true
        }
        if ($memberName -eq 'InvokeProvider' -and
            ((Test-ExecutionContextRoot -Node $Node.Expression) -or
                (Test-ExecutionContextMemberChain -Node $Node.Expression -Members @('SessionState')))) {
            return $true
        }
    }
    if ($Node -is [System.Management.Automation.Language.CommandAst]) {
        $name = $Node.GetCommandName()
        $leafName = if ($null -eq $name) { '' } else { ($name -split '\\')[-1] }
        return $leafName -in @('Set-Alias', 'sal', 'New-Alias', 'nal', 'Remove-Alias', 'ral', 'Import-Alias', 'ipal', 'Import-Module', 'ipmo', 'Import-PSSession', 'Invoke-Expression', 'iex', 'Get-Variable', 'gv') -or
            $Node.Extent.Text -match '(?i)(?:alias|function|variable):'
    }
    if ($Node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        return $Node.Left.Extent.Text -match '(?i)^\$(?:\{)?(?:global:|script:|local:|private:)?(?:alias|function|variable):'
    }
    return $false
}

function Assert-CommandResolutionContract {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Context,
        [string[]] $ExpectedDotSources = @(),
        [string[]] $ExpectedAmpersandCommands = @()
    )

    $mutators = @($Ast.FindAll({ param($node) Test-CommandResolutionMutationNode -Node $node }, $true))
    if ($mutators.Count -ne 0) { throw "Command resolution mutation is forbidden: $Context" }
    $dotSources = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
    }, $true))
    if ($dotSources.Count -ne $ExpectedDotSources.Count) { throw "Unexpected dot-source count: $Context" }
    for ($i = 0; $i -lt $ExpectedDotSources.Count; $i++) {
        if ($dotSources[$i].Extent.Text.Trim() -ne $ExpectedDotSources[$i]) {
            throw "Unexpected dot-source command: $Context"
        }
    }
    $ampersandCommands = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand
    }, $true))
    if ($ampersandCommands.Count -ne $ExpectedAmpersandCommands.Count) { throw "Unexpected call-operator count: $Context" }
    for ($i = 0; $i -lt $ExpectedAmpersandCommands.Count; $i++) {
        if ($ampersandCommands[$i].Extent.Text.Trim() -ne $ExpectedAmpersandCommands[$i]) {
            throw "Unexpected call-operator command: $Context"
        }
    }
}

function Assert-NoProtectedFunctionDefinitions {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Context
    )

    $protectedNames = @('Get-InteractiveWin11MessageTimeoutMs', 'Assert-InteractiveWin11WindowOwner', 'Invoke-InteractiveWin11PostMessage', 'Invoke-StatefulPostedCommand')
    $definitions = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            (($node.Name -replace '^(?i)(?:global|script|local|private):', '') -in $protectedNames)
    }, $true))
    if ($definitions.Count -ne 0) { throw "Harness must not redefine protected interactive functions: $Context" }
}

$commandResolutionProbes = @(
    [pscustomobject]@{ Reject = $true; Text = '[ScriptBlock]::' + [Environment]::NewLine + '''Create''("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '[ System.Management.Automation.ScriptBlock, System.Management.Automation ]::Create("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '[PowerShell]::Create()' }
    [pscustomobject]@{ Reject = $true; Text = '$ExecutionContext.' + [Environment]::NewLine + 'InvokeCommand.' + [Environment]::NewLine + 'InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '${ExecutionContext}.SessionState.InvokeCommand.''InvokeScript''("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$($ExecutionContext).InvokeCommand.InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$global:ExecutionContext.InvokeCommand.NewScriptBlock("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$ic = $ExecutionContext.InvokeCommand; $ic.InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$ic = ${ExecutionContext}.SessionState.InvokeCommand; $ic.NewScriptBlock("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$ec = Get-Variable ExecutionContext -ValueOnly; $ec.InvokeCommand.InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$(Get-Item variable:ExecutionContext).Value.InvokeCommand.InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$ss = $ExecutionContext.SessionState; $ss.InvokeCommand.InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$member = "Create"; [ScriptBlock]::$member("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$member = "InvokeCommand"; $ExecutionContext.$member.InvokeScript("1+1")' }
    [pscustomobject]@{ Reject = $true; Text = '$ec = $($ExecutionContext)' }
    [pscustomobject]@{ Reject = $true; Text = '$factory = [ScriptBlock]' }
    [pscustomobject]@{ Reject = $true; Text = '[ScriptBlock].GetMethod("Create")' }
    [pscustomobject]@{ Reject = $true; Text = '[PSObject].Assembly.GetType("System.Management.Automation.ScriptBlock")' }
    [pscustomobject]@{ Reject = $true; Text = '[PSObject].Assembly.GetType("System.Management.Automation." + "ScriptBlock")' }
    [pscustomobject]@{ Reject = $true; Text = '$typeName = "System.Management.Automation.ScriptBlock"; [PSObject].Assembly.GetType($typeName)' }
    [pscustomobject]@{ Reject = $true; Text = '$factory = [type]"System.Management.Automation.ScriptBlock"' }
    [pscustomobject]@{ Reject = $true; Text = '$typeName = "System.Management.Automation.ScriptBlock"; $factory = [type]$typeName' }
    [pscustomobject]@{ Reject = $true; Text = '$factory = [type]("System.Management.Automation." + "ScriptBlock")' }
    [pscustomobject]@{ Reject = $true; Text = '$factory = "System.Management.Automation.ScriptBlock" -as [type]' }
    [pscustomobject]@{ Reject = $true; Text = '$typeName = "System.Management.Automation.ScriptBlock"; $factory = $typeName -as [type]' }
    [pscustomobject]@{ Reject = $false; Text = '$factory = "WinghosttyStatefulNative" -as [type]' }
    [pscustomobject]@{ Reject = $true; Text = '[runspacefactory]::CreateRunspace()' }
    [pscustomobject]@{ Reject = $true; Text = '[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()' }
    [pscustomobject]@{ Reject = $false; Text = '[ScriptBlock]::CreateDelegate("x")' }
    [pscustomobject]@{ Reject = $true; Text = '$ExecutionContext.InvokeCommand.InvokeScriptBlock("x")' }
    [pscustomobject]@{ Reject = $false; Text = '$list.Add("[ScriptBlock]::Create")' }
    [pscustomobject]@{ Reject = $false; Text = 'Write-Host "ScriptBlock"' }
    [pscustomobject]@{ Reject = $false; Text = '$list.Add("System.Management.Automation.ScriptBlock")' }
)
foreach ($probe in $commandResolutionProbes) {
    $probeTokens = $null
    $probeErrors = $null
    $probeAst = [System.Management.Automation.Language.Parser]::ParseInput($probe.Text, [ref] $probeTokens, [ref] $probeErrors)
    if ($probeErrors.Count -ne 0) { throw "Command-resolution probe does not parse: $($probe.Text)" }
    $probeRejected = @($probeAst.FindAll({ param($node) Test-CommandResolutionMutationNode -Node $node }, $true)).Count -ne 0
    if ($probeRejected -ne $probe.Reject) { throw "Command-resolution probe contract failed: $($probe.Text)" }
}

$directStatementTokens = $null
$directStatementErrors = $null
$directStatementAst = [System.Management.Automation.Language.Parser]::ParseInput(
    'try { if ($(Invoke-StatefulPostedCommand 1 2 $deadline $process)) { } } finally { }',
    [ref] $directStatementTokens,
    [ref] $directStatementErrors
)
if ($directStatementErrors.Count -ne 0) {
    throw "Direct-statement control-flow probe does not parse: $($directStatementErrors[0].Message)"
}
$directStatementTry = @($directStatementAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $true))[0]
$conditionalPostedCall = @($directStatementAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-StatefulPostedCommand'
}, $true))[0]
if ($null -ne (Get-DirectStatementBlockChild -Node $conditionalPostedCall -StatementBlock $directStatementTry.Body)) {
    throw 'Direct-statement helper accepted a protected call nested in control flow.'
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
$interactiveWin11Lib = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
$cliShellHarness = Join-Path $repoRoot 'test\windows\cli-shell-command.ps1'
$statefulWin11Lib = Join-Path $repoRoot 'test\windows\interactive-win11-stateful-lib.ps1'
$accessibilityHarness = Join-Path $repoRoot 'test\windows\interactive-win11-accessibility.ps1'
$sessionRestoreHarness = Join-Path $repoRoot 'test\windows\interactive-win11-session-restore.ps1'
$paletteThemeHarness = Join-Path $repoRoot 'test\windows\interactive-win11-palette-theme.ps1'
$interactivePrSmoke = Join-Path $repoRoot 'test\windows\interactive-win11-pr-smoke.ps1'
$releaseCopyChecker = Join-Path $repoRoot 'scripts\check-release-copy.ps1'
$releasePreflight = Join-Path $repoRoot 'scripts\release-preflight.ps1'
$windowsPackager = Join-Path $repoRoot 'scripts\package-windows.ps1'
$releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflow -Raw
$readinessWorkflowText = Get-Content -LiteralPath $readinessWorkflow -Raw
$testWorkflowText = Get-Content -LiteralPath $testWorkflow -Raw
$interactiveWin11LibText = Get-Content -LiteralPath $interactiveWin11Lib -Raw
$cliShellHarnessText = Get-Content -LiteralPath $cliShellHarness -Raw
$statefulWin11LibText = Get-Content -LiteralPath $statefulWin11Lib -Raw
$accessibilityHarnessText = Get-Content -LiteralPath $accessibilityHarness -Raw
$sessionRestoreHarnessText = Get-Content -LiteralPath $sessionRestoreHarness -Raw
$paletteThemeHarnessText = Get-Content -LiteralPath $paletteThemeHarness -Raw
$resolutionSourceAsts = foreach ($source in @(
    [pscustomobject]@{ Path = $interactiveWin11Lib; Text = $interactiveWin11LibText },
    [pscustomobject]@{ Path = $statefulWin11Lib; Text = $statefulWin11LibText }
)) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source.Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "PowerShell resolution source does not parse: $($source.Path) ($($errors[0].Message))" }
    [pscustomobject]@{ Path = $source.Path; Ast = $ast }
}
foreach ($source in $resolutionSourceAsts) {
    $expectedAmpersands = if ($source.Path -eq $interactiveWin11Lib) {
        @(
            '& $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList',
            '& cmd /c $devWindowsCmd zig build -Demit-exe=true',
            '& $Condition'
        )
    } else { @() }
    Assert-CommandResolutionContract -Ast $source.Ast -Context $source.Path -ExpectedAmpersandCommands $expectedAmpersands
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
$stopProcessFunctions = @($interactiveWin11LibAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Stop-InteractiveWin11Process'
}, $true))
$stopProcessStatements = if ($stopProcessFunctions.Count -eq 1) {
    @($stopProcessFunctions[0].Body.EndBlock.Statements)
} else { @() }
$stopIdentityTry = if ($stopProcessStatements.Count -eq 10) { $stopProcessStatements[3] } else { $null }
$stopTaskkillTry = if ($stopProcessStatements.Count -eq 10) { $stopProcessStatements[8] } else { $null }
$stopManagedTry = if ($stopProcessStatements.Count -eq 10) { $stopProcessStatements[9] } else { $null }
if ($stopProcessFunctions.Count -ne 1 -or
    -not [object]::ReferenceEquals($stopProcessFunctions[0].Parent, $interactiveWin11LibAst.EndBlock) -or
    $null -ne $stopProcessFunctions[0].Body.BeginBlock -or
    $null -ne $stopProcessFunctions[0].Body.ProcessBlock -or
    $null -ne $stopProcessFunctions[0].Body.DynamicParamBlock -or
    $null -ne $stopProcessFunctions[0].Body.CleanBlock -or
    $null -eq $stopProcessFunctions[0].Body.ParamBlock -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters.Count -ne 2 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Name.VariablePath.UserPath -ne 'Process' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes.Count -ne 2 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes[0].Extent.Text.Trim() -ne '[Parameter(Mandatory)]' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes[1].Extent.Text.Trim() -ne '[System.Diagnostics.Process]' -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Name.VariablePath.UserPath -ne 'RequireLiveRoot' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Attributes.Count -ne 1 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Attributes[0].Extent.Text.Trim() -ne '[switch]' -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].DefaultValue -or
    $stopProcessStatements.Count -ne 10 -or
    $stopProcessStatements[0].Extent.Text.Trim() -ne '$rootProcessId = $Process.Id' -or
    $stopProcessStatements[1].Extent.Text.Trim() -ne '$rootStartedAt = $Process.StartTime' -or
    $stopProcessStatements[2].Extent.Text.Trim() -ne '$rootIsLive = $false' -or
    $stopIdentityTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
    $stopIdentityTry.Body.Statements.Count -ne 2 -or
    $stopIdentityTry.CatchClauses.Count -ne 1 -or
    $null -ne $stopIdentityTry.Finally -or
    $stopIdentityTry.CatchClauses[0].CatchTypes.Count -ne 1 -or
    $stopIdentityTry.CatchClauses[0].CatchTypes[0].TypeName.FullName -ne 'System.InvalidOperationException' -or
    $stopIdentityTry.CatchClauses[0].Body.Statements.Count -ne 0 -or
    $stopIdentityTry.Body.Statements[0].Extent.Text.Trim() -ne '$Process.Refresh()' -or
    $stopIdentityTry.Body.Statements[1].Extent.Text.Trim() -ne '$rootIsLive = -not $Process.HasExited -and $Process.StartTime -eq $rootStartedAt' -or
    $stopProcessStatements[4] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopProcessStatements[4].Clauses.Count -ne 1 -or
    $null -ne $stopProcessStatements[4].ElseClause -or
    $stopProcessStatements[4].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $rootIsLive' -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements.Count -ne 2 -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements[0].Clauses.Count -ne 1 -or
    $null -ne $stopProcessStatements[4].Clauses[0].Item2.Statements[0].ElseClause -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements[0].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $RequireLiveRoot' -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements[0].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements[0].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.ReturnStatementAst] -or
    $stopProcessStatements[4].Clauses[0].Item2.Statements[1] -isnot [System.Management.Automation.Language.ThrowStatementAst] -or
    $stopProcessStatements[5].Extent.Text.Trim() -ne '$taskkillError = $null' -or
    $stopProcessStatements[6].Extent.Text.Trim() -ne '$taskkill = $null' -or
    $stopProcessStatements[7].Extent.Text.Trim() -ne '$taskkillTerminationVerified = $true' -or
    $stopTaskkillTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
    $stopTaskkillTry.Body.Statements.Count -ne 10 -or
    $stopTaskkillTry.CatchClauses.Count -ne 1 -or
    $null -eq $stopTaskkillTry.Finally -or
    $stopTaskkillTry.Body.Statements[0].Extent.Text.Trim() -ne '$taskkillStartInfo = [System.Diagnostics.ProcessStartInfo]::new()' -or
    $stopTaskkillTry.Body.Statements[1].Extent.Text.Trim() -ne '$taskkillStartInfo.FileName = Join-Path $env:SystemRoot ''System32\taskkill.exe''' -or
    $stopTaskkillTry.Body.Statements[2].Extent.Text.Trim() -ne '$taskkillStartInfo.UseShellExecute = $false' -or
    $stopTaskkillTry.Body.Statements[3].Extent.Text.Trim() -ne '$taskkillStartInfo.CreateNoWindow = $true' -or
    $stopTaskkillTry.Body.Statements[4].Extent.Text.Trim() -ne '$taskkillStartInfo.Arguments = "/PID $rootProcessId /T /F"' -or
    $stopTaskkillTry.Body.Statements[5].Extent.Text.Trim() -ne '$taskkill = [System.Diagnostics.Process]::Start($taskkillStartInfo)' -or
    $stopTaskkillTry.Body.Statements[6].Extent.Text.Trim() -ne '$taskkillTerminationVerified = $false' -or
    $stopTaskkillTry.Body.Statements[7].Extent.Text.Trim() -ne '$taskkillTerminationVerified = $taskkill.WaitForExit(10000)' -or
    $stopTaskkillTry.Body.Statements[8] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopTaskkillTry.Body.Statements[8].Clauses.Count -ne 2 -or
    $null -ne $stopTaskkillTry.Body.Statements[8].ElseClause -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $taskkillTerminationVerified' -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements.Count -ne 4 -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[0].Extent.Text.Trim() -ne '$taskkill.Kill()' -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[1].Extent.Text.Trim() -ne '$taskkillTerminationVerified = $taskkill.WaitForExit(5000)' -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[2] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[2].Clauses.Count -ne 1 -or
    $null -ne $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[2].ElseClause -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[2].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $taskkillTerminationVerified' -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[2].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[2].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst] -or
    $stopTaskkillTry.Body.Statements[8].Clauses[0].Item2.Statements[3].Extent.Text.Trim() -ne '$taskkillError = ''taskkill exceeded 10 seconds''' -or
    $stopTaskkillTry.Body.Statements[8].Clauses[1].Item1.Extent.Text.Trim() -ne '$taskkill.ExitCode -ne 0' -or
    $stopTaskkillTry.Body.Statements[8].Clauses[1].Item2.Statements.Count -ne 1 -or
    $stopTaskkillTry.Body.Statements[8].Clauses[1].Item2.Statements[0].Extent.Text.Trim() -ne '$taskkillError = "taskkill exited with code $($taskkill.ExitCode)"' -or
    $stopTaskkillTry.Body.Statements[9] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopTaskkillTry.Body.Statements[9].Clauses.Count -ne 1 -or
    $null -ne $stopTaskkillTry.Body.Statements[9].ElseClause -or
    $stopTaskkillTry.Body.Statements[9].Clauses[0].Item1.Extent.Text.Trim() -ne '$null -eq $taskkillError -and $Process.WaitForExit(5000)' -or
    $stopTaskkillTry.Body.Statements[9].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopTaskkillTry.Body.Statements[9].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.ReturnStatementAst] -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements.Count -ne 2 -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements[0] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements[0].Clauses.Count -ne 1 -or
    $null -ne $stopTaskkillTry.CatchClauses[0].Body.Statements[0].ElseClause -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements[0].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $taskkillTerminationVerified' -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements[0].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements[0].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst] -or
    $stopTaskkillTry.CatchClauses[0].Body.Statements[1].Extent.Text.Trim() -ne '$taskkillError = $_.Exception.Message' -or
    $stopTaskkillTry.Finally.Statements.Count -ne 1 -or
    $stopTaskkillTry.Finally.Statements[0] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopTaskkillTry.Finally.Statements[0].Clauses.Count -ne 1 -or
    $null -ne $stopTaskkillTry.Finally.Statements[0].ElseClause -or
    $stopTaskkillTry.Finally.Statements[0].Clauses[0].Item1.Extent.Text.Trim() -ne '$null -ne $taskkill' -or
    $stopTaskkillTry.Finally.Statements[0].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopTaskkillTry.Finally.Statements[0].Clauses[0].Item2.Statements[0].Extent.Text.Trim() -ne '$taskkill.Dispose()' -or
    $stopManagedTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
    $stopManagedTry.Body.Statements.Count -ne 5 -or
    $stopManagedTry.CatchClauses.Count -ne 1 -or
    $null -ne $stopManagedTry.Finally -or
    $stopManagedTry.Body.Statements[0].Extent.Text.Trim() -ne '$Process.Refresh()' -or
    $stopManagedTry.Body.Statements[1] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopManagedTry.Body.Statements[1].Clauses.Count -ne 1 -or
    $null -ne $stopManagedTry.Body.Statements[1].ElseClause -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item1.Extent.Text.Trim() -ne '$Process.HasExited -or $Process.StartTime -ne $rootStartedAt' -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements.Count -ne 2 -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[0].Clauses.Count -ne 1 -or
    $null -ne $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[0].ElseClause -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[0].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $RequireLiveRoot' -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[0].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[0].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.ReturnStatementAst] -or
    $stopManagedTry.Body.Statements[1].Clauses[0].Item2.Statements[1] -isnot [System.Management.Automation.Language.ThrowStatementAst] -or
    $stopManagedTry.Body.Statements[2].Extent.Text.Trim() -ne '$Process.Kill()' -or
    $stopManagedTry.Body.Statements[3] -isnot [System.Management.Automation.Language.IfStatementAst] -or
    $stopManagedTry.Body.Statements[3].Clauses.Count -ne 1 -or
    $null -ne $stopManagedTry.Body.Statements[3].ElseClause -or
    $stopManagedTry.Body.Statements[3].Clauses[0].Item1.Extent.Text.Trim() -ne '-not $Process.WaitForExit(5000)' -or
    $stopManagedTry.Body.Statements[3].Clauses[0].Item2.Statements.Count -ne 1 -or
    $stopManagedTry.Body.Statements[3].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst] -or
    $stopManagedTry.Body.Statements[4] -isnot [System.Management.Automation.Language.ThrowStatementAst] -or
    $stopManagedTry.CatchClauses[0].Body.Statements.Count -ne 1 -or
    $stopManagedTry.CatchClauses[0].Body.Statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst]) {
    throw 'Interactive process cleanup must remain live, bounded, identity-checked, and fail closed around native tree kill and root-only fallback.'
}
$cliShellTokens = $null
$cliShellErrors = $null
$cliShellAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $cliShellHarnessText,
    [ref]$cliShellTokens,
    [ref]$cliShellErrors
)
$cliShellTimeoutAssignments = @($cliShellAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text.Trim() -eq '$shellLauncherTimeoutSeconds'
}, $true))
$cliShellSwitches = @($cliShellAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.SwitchStatementAst] -and
        $node.Condition.Extent.Text.Trim() -eq '$Shell'
}, $true))
$cliShellPowerShellClauseIndexes = if ($cliShellSwitches.Count -eq 1) {
    @(for ($i = 0; $i -lt $cliShellSwitches[0].Clauses.Count; $i++) {
        if ($cliShellSwitches[0].Clauses[$i].Item1.Extent.Text.Trim() -eq "'powershell'") { $i }
    })
} else { @() }
$cliShellPowerShellClauseIndex = if ($cliShellPowerShellClauseIndexes.Count -eq 1) {
    [int] $cliShellPowerShellClauseIndexes[0]
} else { -1 }
$cliShellStartProcessAssignments = if ($cliShellPowerShellClauseIndex -ge 0) {
    @($cliShellSwitches[0].Clauses[$cliShellPowerShellClauseIndex].Item2.FindAll({
        param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text.Trim() -eq '$process' -and
            $node.Right -is [System.Management.Automation.Language.PipelineAst] -and
            $node.Right.PipelineElements.Count -eq 1 -and
            $node.Right.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
            $node.Right.PipelineElements[0].GetCommandName() -eq 'Start-Process'
    }, $true))
} else { @() }
$cliShellWaitForExitCalls = if ($cliShellPowerShellClauseIndex -ge 0) {
    @($cliShellSwitches[0].Clauses[$cliShellPowerShellClauseIndex].Item2.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Extent.Text.Trim() -eq 'WaitForExit'
    }, $true))
} else { @() }
$cliShellTimeoutIfs = if ($cliShellPowerShellClauseIndex -ge 0) {
    @($cliShellSwitches[0].Clauses[$cliShellPowerShellClauseIndex].Item2.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match '^if \(-not \$process\.WaitForExit\(\$shellLauncherTimeoutSeconds \* 1000\)\)'
    }, $true))
} else { @() }
$cliShellTimeoutStatements = if ($cliShellTimeoutIfs.Count -eq 1) {
    @($cliShellTimeoutIfs[0].Clauses[0].Item2.Statements)
} else { @() }
$cliShellLauncherBlockShared = $cliShellStartProcessAssignments.Count -eq 1 -and
    $cliShellTimeoutIfs.Count -eq 1 -and
    [Object]::ReferenceEquals($cliShellStartProcessAssignments[0].Parent, $cliShellTimeoutIfs[0].Parent)
$cliShellLauncherStatements = if ($cliShellLauncherBlockShared) {
    @($cliShellStartProcessAssignments[0].Parent.Statements)
} else { @() }
$cliShellTopLevelShared = $cliShellTimeoutAssignments.Count -eq 1 -and
    $cliShellSwitches.Count -eq 1 -and
    [Object]::ReferenceEquals($cliShellTimeoutAssignments[0].Parent, $cliShellSwitches[0].Parent) -and
    [Object]::ReferenceEquals($cliShellTimeoutAssignments[0].Parent, $cliShellAst.EndBlock)
$cliShellTopLevelStatements = if ($cliShellTopLevelShared) {
    @($cliShellAst.EndBlock.Statements)
} else { @() }
$cliShellStartProcessIndex = -1
$cliShellTimeoutIndex = -1
$cliShellTimeoutAssignmentIndex = -1
$cliShellSwitchIndex = -1
for ($i = 0; $i -lt $cliShellLauncherStatements.Count; $i++) {
    if ([Object]::ReferenceEquals($cliShellLauncherStatements[$i], $cliShellStartProcessAssignments[0])) {
        $cliShellStartProcessIndex = $i
    }
    if ([Object]::ReferenceEquals($cliShellLauncherStatements[$i], $cliShellTimeoutIfs[0])) {
        $cliShellTimeoutIndex = $i
    }
}
for ($i = 0; $i -lt $cliShellTopLevelStatements.Count; $i++) {
    if ([Object]::ReferenceEquals($cliShellTopLevelStatements[$i], $cliShellTimeoutAssignments[0])) {
        $cliShellTimeoutAssignmentIndex = $i
    }
    if ([Object]::ReferenceEquals($cliShellTopLevelStatements[$i], $cliShellSwitches[0])) {
        $cliShellSwitchIndex = $i
    }
}
if ($cliShellErrors.Count -ne 0 -or
    $cliShellTimeoutAssignments.Count -ne 1 -or
    $cliShellTimeoutAssignments[0].Right.Extent.Text.Trim() -ne '30' -or
    $cliShellSwitches.Count -ne 1 -or
    $cliShellPowerShellClauseIndexes.Count -ne 1 -or
    $cliShellStartProcessAssignments.Count -ne 1 -or
    $cliShellWaitForExitCalls.Count -ne 1 -or
    $cliShellTimeoutIfs.Count -ne 1 -or
    $cliShellTimeoutIfs[0].Clauses.Count -ne 1 -or
    $null -ne $cliShellTimeoutIfs[0].ElseClause -or
    -not $cliShellTopLevelShared -or
    $cliShellTimeoutAssignmentIndex -lt 0 -or
    $cliShellSwitchIndex -ne ($cliShellTimeoutAssignmentIndex + 1) -or
    -not $cliShellLauncherBlockShared -or
    $cliShellStartProcessAssignments[0].Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -or
    $cliShellStartProcessAssignments[0].Parent.Parent -isnot [System.Management.Automation.Language.TryStatementAst] -or
    -not [Object]::ReferenceEquals(
        $cliShellStartProcessAssignments[0].Parent,
        $cliShellStartProcessAssignments[0].Parent.Parent.Body
    ) -or
    $cliShellStartProcessAssignments[0].Parent.Parent.CatchClauses.Count -ne 0 -or
    $null -eq $cliShellStartProcessAssignments[0].Parent.Parent.Finally -or
    $cliShellStartProcessAssignments[0].Parent.Parent.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -or
    $cliShellStartProcessAssignments[0].Parent.Parent.Parent.Parent -isnot [System.Management.Automation.Language.TryStatementAst] -or
    -not [Object]::ReferenceEquals(
        $cliShellStartProcessAssignments[0].Parent.Parent.Parent,
        $cliShellStartProcessAssignments[0].Parent.Parent.Parent.Parent.Body
    ) -or
    $cliShellStartProcessAssignments[0].Parent.Parent.Parent.Parent.CatchClauses.Count -ne 0 -or
    $null -eq $cliShellStartProcessAssignments[0].Parent.Parent.Parent.Parent.Finally -or
    -not [Object]::ReferenceEquals(
        $cliShellStartProcessAssignments[0].Parent.Parent.Parent.Parent.Parent,
        $cliShellSwitches[0].Clauses[$cliShellPowerShellClauseIndex].Item2
    ) -or
    $cliShellStartProcessIndex -lt 0 -or
    $cliShellTimeoutIndex -ne ($cliShellStartProcessIndex + 2) -or
    ($cliShellStartProcessIndex + 1) -ge $cliShellLauncherStatements.Count -or
    ($cliShellTimeoutIndex + 1) -ge $cliShellLauncherStatements.Count -or
    $cliShellLauncherStatements[$cliShellStartProcessIndex + 1].Extent.Text.Trim() -ne '$processHandle = $process.Handle' -or
    $cliShellLauncherStatements[$cliShellTimeoutIndex + 1].Extent.Text.Trim() -ne '$exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle' -or
    $cliShellTimeoutStatements.Count -ne 2 -or
    $cliShellTimeoutStatements[0].Extent.Text.Trim() -ne 'Stop-InteractiveWin11Process -Process $process -RequireLiveRoot' -or
    $cliShellTimeoutStatements[1].Extent.Text.Trim() -ne 'throw "Timed out waiting $shellLauncherTimeoutSeconds seconds for shell launcher process to exit."') {
    throw 'The live PowerShell shell launcher must use one hosted-cold-start timeout and fail explicitly after bounded process-tree cleanup.'
}
$accessibilityTokens = $null
$accessibilityErrors = $null
$accessibilityAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $accessibilityHarnessText,
    [ref]$accessibilityTokens,
    [ref]$accessibilityErrors
)
$accessibilityUIntPtrConversions = @($accessibilityAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ConvertExpressionAst] -and
        $node.Type.TypeName.FullName -eq 'UIntPtr'
}, $true))
if ($accessibilityErrors.Count -ne 0 -or $accessibilityUIntPtrConversions.Count -ne 0) {
    throw 'Accessibility harness must parse and construct nonzero WPARAM values through UIntPtr::new([uint64] ...).'
}
$timeoutFunctions = @($resolutionSourceAsts[0].Ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-InteractiveWin11MessageTimeoutMs'
}, $true))
$timeoutParameters = @($timeoutFunctions[0].Body.ParamBlock.Parameters)
$timeoutStatements = @($timeoutFunctions[0].Body.EndBlock.Statements)
$timeoutTraps = @($timeoutFunctions[0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.TrapStatementAst] }, $true))
if ($timeoutFunctions.Count -ne 1 -or $timeoutParameters.Count -ne 2 -or
    $timeoutParameters[0].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [DateTime] $Deadline' -or
    $timeoutParameters[1].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [string] $Description' -or
    $null -ne $timeoutFunctions[0].Body.DynamicParamBlock -or $null -ne $timeoutFunctions[0].Body.BeginBlock -or
    $null -ne $timeoutFunctions[0].Body.ProcessBlock -or $null -ne $timeoutFunctions[0].Body.CleanBlock -or
    $timeoutTraps.Count -ne 0 -or $timeoutStatements.Count -ne 3 -or
    $timeoutStatements[0].Extent.Text.Trim() -ne '$remainingMs = ($Deadline - [DateTime]::UtcNow).TotalMilliseconds' -or
    $timeoutStatements[1].Extent.Text.Trim() -notmatch '(?s)^if \(\$remainingMs -le 0\) \{\s*throw "Deadline elapsed before sending \$Description\."\s*\}$' -or
    $timeoutStatements[2].Extent.Text.Trim() -ne 'return [uint32][Math]::Min([double][uint32]::MaxValue, [Math]::Ceiling($remainingMs))') {
    throw 'Message timeout helper must preserve its exact direct elapsed-deadline calculation and bounded return.'
}
$postMessageWrapperText = Get-PowerShellBlockText `
    -Content $interactiveWin11LibText `
    -HeaderPattern '^function Invoke-InteractiveWin11PostMessage'
$statefulPostedCommandText = Get-PowerShellBlockText `
    -Content $statefulWin11LibText `
    -HeaderPattern '^function Invoke-StatefulPostedCommand'
$postWrapperTokens = $null
$postWrapperErrors = $null
$postWrapperAst = [System.Management.Automation.Language.Parser]::ParseInput($postMessageWrapperText, [ref]$postWrapperTokens, [ref]$postWrapperErrors)
$postWrapperFunctions = @($postWrapperAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
if ($postWrapperErrors.Count -ne 0 -or $postWrapperFunctions.Count -ne 1 -or
    $postWrapperFunctions[0].Name -ne 'Invoke-InteractiveWin11PostMessage') {
    throw 'Posted-message wrapper contract does not parse to the exact named function.'
}
$postWrapperFunction = $postWrapperFunctions[0]
$postWrapperParameters = @($postWrapperFunction.Body.ParamBlock.Parameters)
$postWrapperStatements = @($postWrapperFunction.Body.EndBlock.Statements)
$postWrapperTraps = @($postWrapperFunction.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.TrapStatementAst] }, $true))
if ($postWrapperParameters.Count -ne 7 -or
    $postWrapperParameters[0].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [IntPtr] $Hwnd' -or
    $postWrapperParameters[1].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [uint32] $Message' -or
    $postWrapperParameters[2].Extent.Text.Trim() -ne '[UIntPtr] $WParam = [UIntPtr]::Zero' -or
    $postWrapperParameters[3].Extent.Text.Trim() -ne '[IntPtr] $LParam = [IntPtr]::Zero' -or
    $postWrapperParameters[4].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [DateTime] $Deadline' -or
    $postWrapperParameters[5].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [string] $Description' -or
    $postWrapperParameters[6].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [System.Diagnostics.Process] $Process' -or
    $null -ne $postWrapperFunction.Body.DynamicParamBlock -or $null -ne $postWrapperFunction.Body.BeginBlock -or
    $null -ne $postWrapperFunction.Body.ProcessBlock -or $null -ne $postWrapperFunction.Body.CleanBlock -or
    $postWrapperTraps.Count -ne 0 -or $postWrapperStatements.Count -ne 6 -or
    $postWrapperStatements[0].Extent.Text.Trim() -ne '$Process.Refresh()' -or
    $postWrapperStatements[1].Extent.Text.Trim() -notmatch '(?s)^if \(\$Process\.HasExited\) \{\s*throw "Refusing to post \$Description because winghostty already exited \(exit code \$\(\$Process\.ExitCode\)\)\."\s*\}$' -or
    $postWrapperStatements[2].Extent.Text.Trim() -ne '[void](Assert-InteractiveWin11WindowOwner -Hwnd $Hwnd -Process $Process -Description $Description -Verb ''post'')' -or
    $postWrapperStatements[3].Extent.Text.Trim() -ne '$lastError = 0' -or
    $postWrapperStatements[4].Extent.Text.Trim() -ne 'if ($Deadline -le [DateTime]::UtcNow) { throw "Timed out waiting for $Description." }' -or
    $postWrapperStatements[5].Extent.Text.Trim() -notmatch '(?s)^if \(-not \[InteractiveWin11MessageNativeV2\]::PostMessageWithError\(\$Hwnd, \$Message, \$WParam, \$LParam, \[ref\] \$lastError\)\) \{\s*\$detail = if \(\$lastError -eq 0\) \{ ''without a Win32 error'' \} else \{ "with Win32 error \$lastError" \}\s*throw "PostMessageW failed for \$Description hwnd=\$Hwnd \$detail\."\s*\}$') {
    throw 'Posted-message wrapper must preserve its exact direct process, ownership, deadline, and native-post sequence.'
}
$statefulPostTokens = $null
$statefulPostErrors = $null
$statefulPostAst = [System.Management.Automation.Language.Parser]::ParseInput($statefulPostedCommandText, [ref]$statefulPostTokens, [ref]$statefulPostErrors)
$statefulPostFunctions = @($statefulPostAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
if ($statefulPostErrors.Count -ne 0 -or $statefulPostFunctions.Count -ne 1 -or
    $statefulPostFunctions[0].Name -ne 'Invoke-StatefulPostedCommand') {
    throw 'Stateful posted-command contract does not parse to the exact named function.'
}
$statefulPostParameters = @($statefulPostFunctions[0].Parameters)
$statefulPostStatements = @($statefulPostFunctions[0].Body.EndBlock.Statements)
$statefulPostTraps = @($statefulPostFunctions[0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.TrapStatementAst] }, $true))
if ($statefulPostParameters.Count -ne 4 -or
    $statefulPostParameters[0].Extent.Text.Trim() -ne '[IntPtr] $Hwnd' -or
    $statefulPostParameters[1].Extent.Text.Trim() -ne '[int] $Id' -or
    $statefulPostParameters[2].Extent.Text.Trim() -ne '[DateTime] $Deadline' -or
    $statefulPostParameters[3].Extent.Text.Trim() -ne '[Parameter(Mandatory)] [System.Diagnostics.Process] $Process' -or
    $null -ne $statefulPostFunctions[0].Body.DynamicParamBlock -or $null -ne $statefulPostFunctions[0].Body.BeginBlock -or
    $null -ne $statefulPostFunctions[0].Body.ProcessBlock -or $null -ne $statefulPostFunctions[0].Body.CleanBlock -or
    $statefulPostTraps.Count -ne 0 -or
    $statefulPostStatements.Count -ne 1 -or
    $statefulPostStatements[0].Extent.Text.Trim() -notmatch '(?s)^Invoke-InteractiveWin11PostMessage\s+`\s*-Hwnd \$Hwnd\s+`\s*-Message 0x0111\s+`\s*-WParam \(\[UIntPtr\]::new\(\[uint64\]\$Id\)\)\s+`\s*-Deadline \$Deadline\s+`\s*-Description "WM_COMMAND id=\$Id"\s+`\s*-Process \$Process$') {
    throw 'Stateful posted-command wrapper must require and forward its exact deadline and process.'
}
$paletteThemeTokens = $null
$paletteThemeErrors = $null
$paletteThemeAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $paletteThemeHarnessText,
    [ref]$paletteThemeTokens,
    [ref]$paletteThemeErrors
)
if ($paletteThemeErrors.Count -ne 0) { throw "Palette theme harness does not parse: $($paletteThemeErrors[0].Message)" }
Assert-CommandResolutionContract -Ast $paletteThemeAst -Context $paletteThemeHarness -ExpectedDotSources @(
    ". (Join-Path `$repoRoot 'scripts\interactive-win11-lib.ps1')",
    ". (Join-Path `$PSScriptRoot 'interactive-win11-stateful-lib.ps1')"
)
Assert-NoProtectedFunctionDefinitions -Ast $paletteThemeAst -Context $paletteThemeHarness
$paletteThemeTraps = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TrapStatementAst]
}, $true))
$paletteThemeFunctions = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
$openThemeQueryFunctions = @($paletteThemeFunctions | Where-Object Name -eq 'Open-ThemeQuery')
$postHighContrastFunctions = @($paletteThemeFunctions | Where-Object Name -eq 'Invoke-PostHighContrastPresentationCanary')
if ($paletteThemeFunctions.Count -ne 2 -or $openThemeQueryFunctions.Count -ne 1 -or $postHighContrastFunctions.Count -ne 1) {
    throw 'Palette theme harness must define only its exact query and post-High-Contrast presentation functions.'
}
$openThemeQueryParameters = @($openThemeQueryFunctions[0].Parameters)
if ($openThemeQueryParameters.Count -ne 4 -or
    $openThemeQueryParameters[0].Extent.Text.Trim() -ne '[IntPtr]$HostHwnd' -or
    $openThemeQueryParameters[1].Extent.Text.Trim() -ne '[string]$Query' -or
    $openThemeQueryParameters[2].Extent.Text.Trim() -ne '[DateTime]$Deadline' -or
    $openThemeQueryParameters[3].Extent.Text.Trim() -ne '$Process') {
    throw 'Palette query opening must preserve its exact non-executable parameter contract.'
}
$openThemeQueryBody = $openThemeQueryFunctions[0].Body
if ($null -ne $openThemeQueryBody.DynamicParamBlock -or $null -ne $openThemeQueryBody.BeginBlock -or
    $null -ne $openThemeQueryBody.ProcessBlock -or
    $null -ne $openThemeQueryBody.CleanBlock -or $paletteThemeTraps.Count -ne 0) {
    throw 'Palette query opening must not use alternate named blocks or traps that can bypass fail-closed deadline errors.'
}
$openThemeQueryStatements = @($openThemeQueryBody.EndBlock.Statements)
if ($openThemeQueryStatements.Count -ne 6 -or
    $openThemeQueryStatements[0].Extent.Text.Trim() -ne 'Invoke-StatefulPostedCommand $HostHwnd 1901 $Deadline $Process' -or
    $openThemeQueryStatements[1].Extent.Text.Trim() -ne '$script:PaletteThemeHost = $HostHwnd' -or
    $openThemeQueryStatements[2].Extent.Text.Trim() -notmatch '(?s)^Wait-InteractiveWin11Until -Deadline \$Deadline -Description ''palette query edit'' -Process \$Process -Condition \{\s*@\(Get-StatefulChildren \$script:PaletteThemeHost \| Where-Object Id -eq 2002\)\.Count -gt 0\s*\}$' -or
    $openThemeQueryStatements[3].Extent.Text.Trim() -ne '$edit = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2002 | Select-Object -First 1' -or
    $openThemeQueryStatements[4].Extent.Text.Trim() -ne 'Set-StatefulEditText $HostHwnd $edit.Hwnd $Query $Deadline $Process' -or
    $openThemeQueryStatements[5].Extent.Text.Trim() -ne 'return $edit.Hwnd') {
    throw 'Palette query opening must preserve its complete fail-closed command, wait, edit, and return sequence.'
}
$postHighContrastParameters = @($postHighContrastFunctions[0].Parameters)
$postHighContrastBody = $postHighContrastFunctions[0].Body
$postHighContrastStatements = @($postHighContrastBody.EndBlock.Statements)
$postHighContrastTraps = @($postHighContrastBody.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TrapStatementAst]
}, $true))
if ($postHighContrastParameters.Count -ne 2 -or
    $postHighContrastParameters[0].Extent.Text.Trim() -ne '[string]$Name' -or
    $postHighContrastParameters[1].Extent.Text.Trim() -ne '[int]$ExpectedRgb' -or
    $null -ne $postHighContrastBody.DynamicParamBlock -or $null -ne $postHighContrastBody.BeginBlock -or
    $null -ne $postHighContrastBody.ProcessBlock -or $null -ne $postHighContrastBody.CleanBlock -or
    $postHighContrastTraps.Count -ne 0 -or $postHighContrastStatements.Count -ne 3 -or
    $postHighContrastStatements[0].Extent.Text.Trim() -ne '$lastError = $null' -or
    $postHighContrastStatements[2].Extent.Text.Trim() -ne 'throw "Post-High-Contrast presentation did not recover after two fresh processes: $($lastError.Exception.Message)"') {
    throw 'Post-High-Contrast presentation must preserve its exact canary parameter contract.'
}
$postHighContrastLoops = @($postHighContrastBody.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst]
}, $true))
if ($postHighContrastLoops.Count -ne 1 -or
    -not [object]::ReferenceEquals($postHighContrastStatements[1], $postHighContrastLoops[0]) -or
    $postHighContrastLoops[0].Variable.VariablePath.UserPath -ne 'attempt' -or
    $postHighContrastLoops[0].Condition.Extent.Text.Trim() -ne '1..2') {
    throw 'Post-High-Contrast presentation must use one exact two-attempt loop.'
}
$postHighContrastLoopStatements = @($postHighContrastLoops[0].Body.Statements)
if ($postHighContrastLoopStatements.Count -ne 2 -or
    $postHighContrastLoopStatements[0].Extent.Text.Trim() -ne '$canary = $null' -or
    $postHighContrastLoopStatements[1] -isnot [System.Management.Automation.Language.TryStatementAst]) {
    throw 'Post-High-Contrast presentation must guard each complete canary lifecycle with one try/catch.'
}
$postHighContrastTry = $postHighContrastLoopStatements[1]
$postHighContrastTryStatements = @($postHighContrastTry.Body.Statements)
if ($postHighContrastTry.CatchClauses.Count -ne 1 -or $null -ne $postHighContrastTry.Finally -or
    $postHighContrastTryStatements.Count -ne 13 -or
    $postHighContrastTryStatements[0].Extent.Text.Trim() -ne '$canary = Start-StatefulApp $layout $exe $repoRoot "$Name-$attempt"' -or
    $postHighContrastTryStatements[1].Extent.Text.Trim() -ne '$runs.Add($canary)' -or
    $postHighContrastTryStatements[2].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
    $postHighContrastTryStatements[3].Extent.Text.Trim() -ne '$canaryHost = Wait-StatefulHost $canary $deadline' -or
    $postHighContrastTryStatements[4].Extent.Text.Trim() -notmatch '(?s)^Wait-InteractiveWin11Until -Deadline \$deadline -Description ''post-High-Contrast canary tab'' -Process \$canary\.Process -Condition \{\s*\(Get-StatefulTabCount \$canaryHost\) -eq 1\s*\}$' -or
    $postHighContrastTryStatements[5].Extent.Text.Trim() -ne '$canarySurface = Wait-StatefulSurface $canaryHost $canary $deadline' -or
    $postHighContrastTryStatements[6].Extent.Text.Trim() -ne 'Show-StatefulHost $canaryHost' -or
    $postHighContrastTryStatements[7].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
    $postHighContrastTryStatements[8].Extent.Text.Trim() -ne '$stablePresentation = [Diagnostics.Stopwatch]::new()' -or
    $postHighContrastTryStatements[9].Extent.Text.Trim() -notmatch '(?s)^Wait-InteractiveWin11Until -Deadline \$deadline -Description ''post-High-Contrast canary framebuffer'' -Process \$canary\.Process -Condition \{\s*if \(\(\(Get-StatefulPixel \$canarySurface\.Hwnd\) -band 0xFFFFFF\) -ne \$ExpectedRgb\) \{\s*\$stablePresentation\.Reset\(\)\s*return \$false\s*\}\s*if \(-not \$stablePresentation\.IsRunning\) \{ \$stablePresentation\.Start\(\) \}\s*return \$stablePresentation\.Elapsed -ge \[TimeSpan\]::FromSeconds\(2\)\s*\}$' -or
    $postHighContrastTryStatements[10].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
    $postHighContrastTryStatements[11].Extent.Text.Trim() -ne 'Close-StatefulHost $canaryHost $canary $deadline' -or
    $postHighContrastTryStatements[12].Extent.Text.Trim() -ne 'return') {
    throw 'Post-High-Contrast presentation must preserve its exact launch, readiness, framebuffer, and close sequence with three fresh deadlines.'
}
$postHighContrastCatchStatements = @($postHighContrastTry.CatchClauses[0].Body.Statements)
if ($postHighContrastCatchStatements.Count -ne 3 -or
    $postHighContrastCatchStatements[0].Extent.Text.Trim() -ne '$lastError = $_' -or
    $postHighContrastCatchStatements[1].Extent.Text.Trim() -notmatch '(?s)^if \(\$null -ne \$canary -and -not \$canary\.Process\.HasExited\) \{\s*try \{ Stop-InteractiveWin11Process -Process \$canary\.Process \}\s*catch \{\s*throw "Post-High-Contrast presentation attempt \$attempt failed: \$\(\$lastError\.Exception\.Message\); process cleanup also failed: \$\(\$_\.Exception\.Message\)"\s*\}\s*\}$' -or
    $postHighContrastCatchStatements[2].Extent.Text.Trim() -ne 'if ($attempt -lt 2) { Write-Warning "Post-High-Contrast presentation attempt $attempt stalled; retrying with a fresh process." }') {
    throw 'Post-High-Contrast presentation must preserve nullable failed-attempt cleanup and bounded retry reporting.'
}
$postHighContrastCalls = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-PostHighContrastPresentationCanary'
}, $true))
$paletteMainTries = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
        $node.Parent -is [System.Management.Automation.Language.NamedBlockAst]
}, $true))
$recoveryCanaryCalls = @($postHighContrastCalls | Where-Object {
    $_.Extent.Text.Trim() -eq "Invoke-PostHighContrastPresentationCanary 'palette-theme-recovery-canary' `$draculaRgb"
})
$restoreCanaryCalls = @($postHighContrastCalls | Where-Object {
    $_.Extent.Text.Trim() -eq "Invoke-PostHighContrastPresentationCanary 'palette-theme-restore-canary' `$themeRgb"
})
$markerRemoveCommands = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Remove-Item -LiteralPath $hcRecoveryPath -Force -ErrorAction Stop'
}, $true))
if ($paletteMainTries.Count -ne 1 -or $postHighContrastCalls.Count -ne 2 -or
    $recoveryCanaryCalls.Count -ne 1 -or $restoreCanaryCalls.Count -ne 1 -or
    $markerRemoveCommands.Count -ne 2) {
    throw 'High Contrast recovery marker removal must follow one successful fresh-process presentation canary.'
}
$recoveryCallStatement = Get-DirectStatementBlockChild -Node $recoveryCanaryCalls[0] -StatementBlock $recoveryCanaryCalls[0].Parent.Parent
$recoveryRemoveCommands = @($markerRemoveCommands | Where-Object {
    [object]::ReferenceEquals($_.Parent.Parent, $recoveryCanaryCalls[0].Parent.Parent)
})
$recoveryBlockStatements = @($recoveryCanaryCalls[0].Parent.Parent.Statements)
if ($null -eq $recoveryCallStatement -or $recoveryRemoveCommands.Count -ne 1 -or
    [Array]::IndexOf($recoveryBlockStatements, $recoveryRemoveCommands[0].Parent) -ne
        ([Array]::IndexOf($recoveryBlockStatements, $recoveryCallStatement) + 1)) {
    throw 'Interrupted High Contrast recovery must delete its marker immediately after a direct successful canary call.'
}
$hcRestoredIfs = @($paletteMainTries[0].Finally.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses.Count -eq 1 -and $_.Clauses[0].Item1.Extent.Text.Trim() -eq '$hcRestored'
})
$hcPresentationReadyIfs = @($paletteMainTries[0].Finally.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Clauses.Count -eq 1 -and $_.Clauses[0].Item1.Extent.Text.Trim() -eq '$hcPresentationReady'
})
$presentationReadyAssignments = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'hcPresentationReady'
}, $true))
$presentationReadyFalse = @($presentationReadyAssignments | Where-Object {
    $_.Right.Extent.Text.Trim() -eq '$false'
})
$presentationReadyTrue = @($presentationReadyAssignments | Where-Object {
    $_.Right.Extent.Text.Trim() -eq '$true'
})
$presentationReadyMutationCommands = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -match '(^|\\)((Set|New|Remove|Clear)-Variable|sv|nv|rv|clv)$' -and
        $node.Extent.Text -match '(?i)hcPresentationReady'
}, $true))
if ($hcRestoredIfs.Count -ne 1 -or $hcPresentationReadyIfs.Count -ne 1 -or
    $presentationReadyAssignments.Count -ne 2 -or $presentationReadyMutationCommands.Count -ne 0 -or
    $presentationReadyFalse.Count -ne 1 -or $presentationReadyTrue.Count -ne 1 -or
    -not [object]::ReferenceEquals($presentationReadyFalse[0], $paletteMainTries[0].Finally.Statements[2]) -or
    $hcRestoredIfs[0].Clauses[0].Item2.Statements.Count -ne 1 -or
    $hcRestoredIfs[0].Clauses[0].Item2.Statements[0] -isnot [System.Management.Automation.Language.TryStatementAst]) {
    throw 'High Contrast cleanup must initialize and gate one exact post-restore presentation proof.'
}
$restoreCanaryTry = $hcRestoredIfs[0].Clauses[0].Item2.Statements[0]
if ($restoreCanaryTry.Body.Statements.Count -ne 2 -or
    -not [object]::ReferenceEquals($restoreCanaryTry.Body.Statements[0], $restoreCanaryCalls[0].Parent) -or
    -not [object]::ReferenceEquals($restoreCanaryTry.Body.Statements[1], $presentationReadyTrue[0]) -or
    $restoreCanaryTry.CatchClauses.Count -ne 1 -or $null -ne $restoreCanaryTry.Finally -or
    $restoreCanaryTry.CatchClauses[0].Body.Statements.Count -ne 1 -or
    $restoreCanaryTry.CatchClauses[0].Body.Statements[0].Extent.Text.Trim() -ne '[void]$cleanupErrors.Add("High Contrast post-restore presentation failed: $($_.Exception.Message)")') {
    throw 'Restored High Contrast state must become presentation-ready only after the direct canary succeeds.'
}
$markerCleanupBody = $hcPresentationReadyIfs[0].Clauses[0].Item2
if ($markerCleanupBody.Statements.Count -ne 1 -or
    $markerCleanupBody.Statements[0] -isnot [System.Management.Automation.Language.TryStatementAst] -or
    $markerCleanupBody.Statements[0].Body.Statements.Count -ne 1 -or
    -not [object]::ReferenceEquals($markerCleanupBody.Statements[0].Body.Statements[0],
        @($markerRemoveCommands | Where-Object { -not [object]::ReferenceEquals($_, $recoveryRemoveCommands[0]) })[0].Parent) -or
    $markerCleanupBody.Statements[0].CatchClauses.Count -ne 1 -or
    $markerCleanupBody.Statements[0].CatchClauses[0].Body.Statements.Count -ne 1 -or
    $markerCleanupBody.Statements[0].CatchClauses[0].Body.Statements[0].Extent.Text.Trim() -ne '[void]$cleanupErrors.Add("High Contrast recovery marker cleanup failed: $($_.Exception.Message)")') {
    throw 'High Contrast recovery marker cleanup must be directly and exclusively gated by successful presentation.'
}
$testCanaryMutationShape = {
    param([string] $Content)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { return $false }
    $functions = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-PostHighContrastPresentationCanary'
    }, $true))
    if ($functions.Count -ne 1) { return $false }
    $loops = @($functions[0].Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst]
    }, $true))
    if ($loops.Count -ne 1 -or $loops[0].Body.Statements.Count -ne 2 -or
        $loops[0].Body.Statements[1] -isnot [System.Management.Automation.Language.TryStatementAst]) {
        return $false
    }
    $statements = @($loops[0].Body.Statements[1].Body.Statements)
    return $statements.Count -eq 13 -and
        $statements[0].Extent.Text.Trim() -eq '$canary = Start-StatefulApp $layout $exe $repoRoot "$Name-$attempt"' -and
        $statements[1].Extent.Text.Trim() -eq '$runs.Add($canary)' -and
        $statements[2].Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -and
        $statements[7].Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -and
        $statements[8].Extent.Text.Trim() -eq '$stablePresentation = [Diagnostics.Stopwatch]::new()' -and
        $statements[10].Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -and
        $statements[11].Extent.Text.Trim() -eq 'Close-StatefulHost $canaryHost $canary $deadline' -and
        $statements[12].Extent.Text.Trim() -eq 'return'
}
$testMarkerMutationShape = {
    param([string] $Content)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { return $false }
    $assignments = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'hcPresentationReady'
    }, $true))
    $trueAssignments = @($assignments | Where-Object { $_.Right.Extent.Text.Trim() -eq '$true' })
    $falseAssignments = @($assignments | Where-Object { $_.Right.Extent.Text.Trim() -eq '$false' })
    $mutationCommands = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -match '(^|\\)((Set|New|Remove|Clear)-Variable|sv|nv|rv|clv)$' -and
            $node.Extent.Text -match '(?i)hcPresentationReady'
    }, $true))
    return $assignments.Count -eq 2 -and $trueAssignments.Count -eq 1 -and
        $falseAssignments.Count -eq 1 -and $mutationCommands.Count -eq 0
}
if (-not (& $testCanaryMutationShape $paletteThemeHarnessText) -or
    -not (& $testMarkerMutationShape $paletteThemeHarnessText)) {
    throw 'High Contrast mutation probes do not recognize the protected production shape.'
}
$deadlineMutationPattern = [regex]::new(
    '(?m)^(\s*Show-StatefulHost \$canaryHost\r?\n)\s*\$deadline = \[DateTime\]::UtcNow\.AddSeconds\(\$TimeoutSeconds\)\r?\n'
)
$missingDeadlineMutation = $deadlineMutationPattern.Replace($paletteThemeHarnessText, '$1', 1)
$earlyReturnPattern = [regex]::new(
    '(?s)(function Invoke-PostHighContrastPresentationCanary.*?foreach \(\$attempt in 1\.\.2\).*?try \{\r?\n)'
)
$earlyReturnMutation = $earlyReturnPattern.Replace($paletteThemeHarnessText, '$1            return' + [Environment]::NewLine, 1)
$failOpenMarkerPattern = [regex]::new(
    '(\[void\]\$cleanupErrors\.Add\("High Contrast post-restore presentation failed: \$\(\$_\.Exception\.Message\)"\))'
)
$failOpenMarkerMutation = $failOpenMarkerPattern.Replace(
    $paletteThemeHarnessText,
    '$hcPresentationReady = $true' + [Environment]::NewLine + '            $1',
    1
)
$moduleMutatorMarkerMutation = $failOpenMarkerPattern.Replace(
    $paletteThemeHarnessText,
    'Microsoft.PowerShell.Utility\Set-Variable hcPresentationReady $true' + [Environment]::NewLine + '            $1',
    1
)
$aliasMutatorMarkerMutation = $failOpenMarkerPattern.Replace(
    $paletteThemeHarnessText,
    'sv hcPresentationReady $true' + [Environment]::NewLine + '            $1',
    1
)
if ($missingDeadlineMutation -eq $paletteThemeHarnessText -or
    $earlyReturnMutation -eq $paletteThemeHarnessText -or
    $failOpenMarkerMutation -eq $paletteThemeHarnessText -or
    $moduleMutatorMarkerMutation -eq $paletteThemeHarnessText -or
    $aliasMutatorMarkerMutation -eq $paletteThemeHarnessText -or
    (& $testCanaryMutationShape $missingDeadlineMutation) -or
    (& $testCanaryMutationShape $earlyReturnMutation) -or
    (& $testMarkerMutationShape $failOpenMarkerMutation) -or
    (& $testMarkerMutationShape $moduleMutatorMarkerMutation) -or
    (& $testMarkerMutationShape $aliasMutatorMarkerMutation)) {
    throw 'High Contrast contract failed to reject a deadline, dead-code, or fail-open marker mutation.'
}
$paletteOpenCalls = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Open-ThemeQuery'
}, $true))
$paletteNormalOpenCalls = @($paletteOpenCalls | Where-Object {
    $_.Extent.Text.Trim() -eq "Open-ThemeQuery `$hostHwnd '0x96f' `$deadline `$run.Process"
})
$paletteHighContrastOpenCalls = @($paletteOpenCalls | Where-Object {
    $_.Extent.Text.Trim() -eq "Open-ThemeQuery `$hcHost 'Dracula' `$deadline `$hcRun.Process"
})
if ($paletteMainTries.Count -ne 1 -or $paletteOpenCalls.Count -ne 3 -or
    $paletteNormalOpenCalls.Count -ne 2 -or $paletteHighContrastOpenCalls.Count -ne 1) {
    throw 'Palette theme harness must preserve its three exact Open-ThemeQuery calls.'
}
foreach ($call in $paletteNormalOpenCalls) {
    if (-not (Test-DirectStatementBlockChild -Node $call -StatementBlock $paletteMainTries[0].Body)) {
        throw 'Normal palette query calls must be direct statements in the main try body.'
    }
}
$paletteHighContrastCallIf = $null
foreach ($candidate in @($paletteThemeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
    foreach ($clause in $candidate.Clauses) {
        if ($clause.Item1.Extent.Text.Trim() -eq '$ExerciseHighContrast' -and
            (Test-DirectStatementBlockChild -Node $paletteHighContrastOpenCalls[0] -StatementBlock $clause.Item2)) {
            if ($null -ne $paletteHighContrastCallIf) { throw 'High Contrast palette query call appears in multiple control-flow blocks.' }
            $paletteHighContrastCallIf = $candidate
        }
    }
}
if ($null -eq $paletteHighContrastCallIf -or
    -not (Test-DirectStatementBlockChild -Node $paletteHighContrastCallIf -StatementBlock $paletteMainTries[0].Body)) {
    throw 'High Contrast palette query call must be direct in its main-try ExerciseHighContrast block.'
}
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
    $_.Extent.Text.Trim() -eq 'Invoke-StatefulPostedCommand $hostHwnd 1904 $deadline $first.Process'
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
    throw 'Session restore tab-seed loop must contain one exact deadline, queued command, count wait, equality barrier, and pump-readiness barrier per iteration.'
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
Assert-CommandResolutionContract -Ast $sessionHarnessAst -Context $sessionRestoreHarness -ExpectedDotSources @(
    ". (Join-Path `$repoRoot 'scripts\interactive-win11-lib.ps1')",
    ". (Join-Path `$PSScriptRoot 'interactive-win11-stateful-lib.ps1')"
)
Assert-NoProtectedFunctionDefinitions -Ast $sessionHarnessAst -Context $sessionRestoreHarness
$sessionTraps = @($sessionHarnessAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.TrapStatementAst] }, $true))
if ($sessionTraps.Count -ne 0) { throw 'Session restore harness must not use traps that swallow validation failures.' }
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
$sessionInitialHostWaits = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text.Trim() -eq '$hostHwnd = Wait-StatefulHost $first $deadline'
}, $true))
$sessionInitialTabWaits = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Wait-InteractiveWin11Until -Deadline $deadline -Description ''initial session-save tab'' -Process $first.Process -Condition { (Get-StatefulTabCount $hostHwnd) -eq 1 }'
}, $true))
$sessionInitialReadyBarriers = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text.Trim() -eq '$null = Invoke-InteractiveWin11Message -Hwnd $hostHwnd -Message 0 -Deadline $deadline -Description ''initial session-save host readiness barrier'' -Process $first.Process'
}, $true))
if ($sessionInitialHostWaits.Count -ne 1 -or $sessionInitialTabWaits.Count -ne 1 -or
    $sessionInitialReadyBarriers.Count -ne 1) {
    throw 'Session restore must contain one exact initial host wait, exact tab-count wait, and nonmutating pump-readiness barrier.'
}
foreach ($node in @($sessionInitialHostWaits[0], $sessionInitialTabWaits[0], $sessionInitialReadyBarriers[0])) {
    if (-not (Test-DirectStatementBlockChild -Node $node -StatementBlock $sessionMainTries[0].Body)) {
        throw 'Session restore initial host, tab-count, and readiness waits must be direct, executable statements in the main try body.'
    }
}
$sessionInitialStatements = @($sessionMainTries[0].Body.Statements)
$sessionInitialWaitIndex = -1
$sessionInitialTabIndex = -1
$sessionInitialReadyIndex = -1
$sessionInitialSeedIndex = -1
for ($i = 0; $i -lt $sessionInitialStatements.Count; $i++) {
    if ([object]::ReferenceEquals($sessionInitialStatements[$i], $sessionInitialHostWaits[0])) { $sessionInitialWaitIndex = $i }
    if ([object]::ReferenceEquals($sessionInitialStatements[$i], $sessionInitialTabWaits[0].Parent)) { $sessionInitialTabIndex = $i }
    if ([object]::ReferenceEquals($sessionInitialStatements[$i], $sessionInitialReadyBarriers[0])) { $sessionInitialReadyIndex = $i }
    if ([object]::ReferenceEquals($sessionInitialStatements[$i], $sessionSeedLoops[0])) { $sessionInitialSeedIndex = $i }
}
if ($sessionInitialTabIndex -ne ($sessionInitialWaitIndex + 1) -or
    $sessionInitialReadyIndex -ne ($sessionInitialTabIndex + 1) -or
    $sessionInitialSeedIndex -ne ($sessionInitialReadyIndex + 1)) {
    throw 'Session restore must prove initial tab creation and host pump readiness on the startup deadline immediately before tab seeding.'
}
$sessionBurstCommands = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Invoke-StatefulPostedCommand $explicitHost 1904 $deadline $explicit.Process'
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
$sessionExplicitTabWaits = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq "Wait-InteractiveWin11Until -Deadline `$deadline -Description 'fresh explicit-command tab' -Process `$explicit.Process -Condition { (Get-StatefulTabCount `$explicitHost) -eq 1 }"
}, $true))
$sessionExplicitHostWaits = @($sessionHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Extent.Text.Trim() -eq '$explicitHost = Wait-StatefulHost $explicit $deadline'
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
if ($sessionExplicitStarts.Count -ne 1 -or $sessionExplicitHostWaits.Count -ne 1 -or
    $sessionExplicitTabWaits.Count -ne 1 -or $sessionBurstCommands.Count -ne 2 -or
    $sessionBurstWaits.Count -ne 1 -or $sessionBurstReady.Count -ne 1 -or
    $sessionExplicitCloses.Count -ne 1 -or $sessionInvariantLoops.Count -ne 1) {
    throw 'Session restore validation must preserve the explicit-process burst phase, its exact-count/pump barriers, and invariant-log rejection.'
}
$sessionBurstDeadlines = @($sessionExactDeadlines | Where-Object {
    (Test-DirectStatementBlockChild -Node $_ -StatementBlock $sessionMainTries[0].Body) -and
    $_.Extent.StartOffset -gt $sessionExplicitTabWaits[0].Extent.EndOffset -and
    $_.Extent.EndOffset -lt $sessionBurstCommands[0].Extent.StartOffset
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
    $sessionExplicitTabWaits[0],
    $sessionBurstDeadlines[0],
    $sessionBurstCommands[0],
    $sessionBurstCommands[1],
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
$sessionSnapshotExitIfs = @($sessionSnapshotFunctions[0].FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match '^if \(\$queryExitCode -ne 0\)'
}, $true))
if ($sessionSnapshotRetryLoops.Count -ne 1 -or $sessionSnapshotWaitIfs.Count -ne 1 -or
    $sessionSnapshotExitIfs.Count -ne 1 -or $sessionSnapshotOutputIfs.Count -ne 1 -or
    -not [object]::ReferenceEquals($sessionSnapshotRetryLoops[0].Parent, $sessionSnapshotFunctions[0].Body.EndBlock) -or
    -not (Test-DirectStatementBlockChild -Node $sessionSnapshotWaitIfs[0] -StatementBlock $sessionSnapshotRetryLoops[0].Body) -or
    -not (Test-DirectStatementBlockChild -Node $sessionSnapshotExitIfs[0] -StatementBlock $sessionSnapshotRetryLoops[0].Body) -or
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
    '$queryHandle = $query.Handle',
    '$remainingMs = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds)'
)
if ($sessionSnapshotLoopStatements.Count -ne 12) {
    throw 'Session restore automation snapshot retry loop is missing causal statements.'
}
for ($i = 0; $i -lt $sessionSnapshotCausalPrefix.Count; $i++) {
    if ($sessionSnapshotLoopStatements[$i].Extent.Text.Trim() -ne $sessionSnapshotCausalPrefix[$i]) {
        throw 'Session restore automation snapshot path, launch, and deadline statements are not in causal order.'
    }
}
if (-not [object]::ReferenceEquals($sessionSnapshotLoopStatements[5], $sessionSnapshotWaitIfs[0]) -or
    $sessionSnapshotLoopStatements[6].Extent.Text.Trim() -ne '$query.Refresh()' -or
    $sessionSnapshotLoopStatements[7].Extent.Text.Trim() -ne '$queryExitCode = Get-InteractiveWin11ProcessExitCode -Process $query -ProcessHandle $queryHandle' -or
    -not [object]::ReferenceEquals($sessionSnapshotLoopStatements[8], $sessionSnapshotExitIfs[0]) -or
    $sessionSnapshotExitIfs[0].Clauses[0].Item2.Statements.Count -ne 3 -or
    $sessionSnapshotExitIfs[0].Clauses[0].Item2.Statements[0].Extent.Text.Trim() -ne '$lastError = if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) { "exit ${queryExitCode}: $(Get-Content $err -Raw)" } else { "exit $queryExitCode" }' -or
    $sessionSnapshotExitIfs[0].Clauses[0].Item2.Statements[1].Extent.Text.Trim() -ne 'Start-Sleep -Milliseconds 250' -or
    $sessionSnapshotExitIfs[0].Clauses[0].Item2.Statements[2].Extent.Text.Trim() -ne 'continue' -or
    -not [object]::ReferenceEquals($sessionSnapshotLoopStatements[9], $sessionSnapshotOutputIfs[0]) -or
    $sessionSnapshotLoopStatements[10].Extent.Text.Trim() -ne '$lastError = if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) { Get-Content $err -Raw } else { ''empty stdout'' }' -or
    $sessionSnapshotLoopStatements[11].Extent.Text.Trim() -ne 'Start-Sleep -Milliseconds 250') {
    throw 'Session restore automation snapshot must wait, refresh, require a zero signed exit code, then parse fresh output.'
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
$sessionSnapshotExitBody = $sessionSnapshotExitIfs[0].Clauses[0].Item2
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
    (([object]::ReferenceEquals($_.Parent, $sessionSnapshotWaitBody) -and
        [object]::ReferenceEquals($_, $sessionSnapshotWaitBody.Statements[-1])) -or
     ([object]::ReferenceEquals($_.Parent, $sessionSnapshotExitBody) -and
        [object]::ReferenceEquals($_, $sessionSnapshotExitBody.Statements[-1])))
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
        if ($i -eq 0 -and (
            $startIndex -le 0 -or
            $sessionMainTryStatements[$startIndex - 1].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
            $sessionInitialWaitIndex -ne ($addIndex + 1))) {
            throw 'Session restore initial launch, evidence registration, and host wait must share one original startup deadline without intervening work.'
        }
        if ($i -eq 1) {
            $explicitHostStatement = Get-DirectStatementBlockChild -Node $sessionExplicitHostWaits[0] -StatementBlock $sessionMainTries[0].Body
            $explicitTabStatement = Get-DirectStatementBlockChild -Node $sessionExplicitTabWaits[0] -StatementBlock $sessionMainTries[0].Body
            $burstDeadlineStatement = Get-DirectStatementBlockChild -Node $sessionBurstDeadlines[0] -StatementBlock $sessionMainTries[0].Body
            $explicitHostIndex = [Array]::IndexOf($sessionMainTryStatements, $explicitHostStatement)
            $explicitTabIndex = [Array]::IndexOf($sessionMainTryStatements, $explicitTabStatement)
            $burstDeadlineIndex = [Array]::IndexOf($sessionMainTryStatements, $burstDeadlineStatement)
            if ($explicitHostIndex -ne ($addIndex + 1) -or $explicitTabIndex -ne ($explicitHostIndex + 1) -or
                $burstDeadlineIndex -ne ($explicitTabIndex + 1)) {
                throw 'Session explicit launch must proceed directly through host/tab readiness into the fresh burst deadline.'
            }
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
    $sessionControlTransfers.Count -ne 4 -or $sessionBootstrapExits.Count -ne 1 -or
    $sessionSnapshotContinues.Count -ne 2 -or $sessionSnapshotReturns.Count -ne 1 -or
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
    $sessionExplicitTabWaits[0].Extent.StartOffset,
    $sessionBurstDeadlines[0].Extent.StartOffset
)
for ($i = 1; $i -lt $sessionBurstOffsets.Count; $i++) {
    if ($sessionBurstOffsets[$i - 1] -ge $sessionBurstOffsets[$i]) {
        throw 'Session restore asynchronous burst operations are not in fail-closed causal order.'
    }
}
$sessionBurstSequenceNodes = @(
    $sessionBurstDeadlines[0],
    $sessionBurstCommands[0],
    $sessionBurstCommands[1],
    $sessionBurstWaits[0],
    $sessionBurstReady[0],
    $sessionCloseDeadlines[0],
    $sessionExplicitCloses[0]
)
$sessionBurstMainStatements = @($sessionMainTries[0].Body.Statements)
$sessionBurstStatementIndices = foreach ($node in $sessionBurstSequenceNodes) {
    $statement = Get-DirectStatementBlockChild -Node $node -StatementBlock $sessionMainTries[0].Body
    if ($null -eq $statement) { throw 'Session restore burst sequence contains a nested operation.' }
    [Array]::IndexOf($sessionBurstMainStatements, $statement)
}
for ($i = 1; $i -lt $sessionBurstStatementIndices.Count; $i++) {
    if ($sessionBurstStatementIndices[$i] -ne ($sessionBurstStatementIndices[$i - 1] + 1)) {
        throw 'Session restore burst deadline, posts, proof barriers, and close must remain adjacent statements.'
    }
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
    -Path $interactivePrSmoke `
    -Pattern "(?ms)if \(\`$harness -eq 'interactive-win11-undo\.ps1'\) \{\s*\`$harnessArgs \+= @\('-TimeoutSeconds', '35'\)\s*\}" `
    -Description 'interactive PR smoke preserves the documented undo harness timeout'
Assert-WorkflowContract `
    -Path $interactivePrSmoke `
    -Pattern "(?ms)for \(\`$attempt = 1; \`$attempt -le 2; \`$attempt\+\+\).*?\`$cacheHydrationMiss = \`$buildText -match 'FileNotFound' -and \`$buildText -match 'zig-global-cache'.*?retrying once with fresh temp cache directories" `
    -Description 'interactive PR smoke retries exactly the transient Zig cache hydration miss'
Assert-WorkflowContract `
    -Path $interactivePrSmoke `
    -Pattern "(?ms)\`$originalErrorActionPreference = \`$ErrorActionPreference\s*try \{\s*\`$ErrorActionPreference = 'Continue'\s*\`$buildOutput = @\(& \(Join-Path \`$repoRoot 'scripts\\dev-windows\.cmd'\) zig build -Demit-exe=true 2>&1\)\s*\`$buildExitCode = \`$LASTEXITCODE\s*\}\s*finally \{\s*\`$ErrorActionPreference = \`$originalErrorActionPreference\s*\}" `
    -Description 'interactive PR smoke captures native build stderr without bypassing exit-code retry logic on PowerShell 7.0'
Assert-WorkflowContract `
    -Path $interactivePrSmoke `
    -Pattern "(?ms)if \(\`$attempt -eq 2 -and \`$env:RUNNER_TEMP\).*?zig-global-cache-pr-smoke-retry-\`$PID.*?zig-local-cache-pr-smoke-retry-\`$PID" `
    -Description 'interactive PR smoke moves the retry to fresh runner-temp Zig cache directories'
Assert-WorkflowContract `
    -Path $interactivePrSmoke `
    -Pattern "(?ms)finally \{\s*\`$env:ZIG_GLOBAL_CACHE_DIR = \`$originalZigGlobalCache\s*\`$env:ZIG_LOCAL_CACHE_DIR = \`$originalZigLocalCache\s*\}" `
    -Description 'interactive PR smoke restores caller-provided Zig cache directories after rebuild retry'
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
    -Pattern 'WINGHOSTTY_EXPECTED_CHECKOUT_SHA' `
    -Description 'interactive provenance can verify an exact PR head checkout instead of only GITHUB_SHA'
Assert-WorkflowContract `
    -Path $runnerProvenanceChecker `
    -Pattern 'commit = \$expectedCommit' `
    -Description 'interactive provenance records the exact expected tested commit'
Assert-WorkflowContract `
    -Path $testWorkflow `
    -Pattern "ref: \\\$\\{\\{ github\\.event_name == 'pull_request' && github\\.event\\.pull_request\\.head\\.sha \\|\\| github\\.sha \\}\\}" `
    -Description 'Test workflow checkouts use the immutable PR head SHA for pull requests'
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot '.github\workflows\windows-arm64.yml') `
    -Pattern "ref: \\\$\\{\\{ github\\.event_name == 'pull_request' && github\\.event\\.pull_request\\.head\\.sha \\|\\| github\\.sha \\}\\}" `
    -Description 'ARM64 workflow checkout uses the immutable PR head SHA for pull requests'
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
Assert-WorkflowContract `
    -Path $windowsPackager `
    -Pattern '(?ms)& zig build .*?\r?\n\s+if \(\$LASTEXITCODE -ne 0\) \{\s*throw "Zig build failed with exit code \$LASTEXITCODE\."' `
    -Description 'Windows packaging fails closed when its native Zig build fails'
Assert-WorkflowContract `
    -Path $windowsPackager `
    -Pattern '(?ms)foreach \(\$runtimeFile in \$runtimeFiles\).*?Assert-PeMachine.*?if \(\$Architecture -eq "x64"\).*?check-windows-x64-baseline\.ps1.*?-Path \$runtimePath' `
    -Description 'Windows packaging checks every x64 runtime PE for baseline compatibility'
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'scripts\check-windows-x64-baseline.ps1') `
    -Pattern '(?ms)Get-Command llvm-objdump\.exe.*?\$objdumpTimeoutMs = 120000.*?\$objdumpKillTimeoutMs = 5000.*?\$streamCopyTimeoutMs = 30000.*?WaitForExit\(\$objdumpTimeoutMs\).*?\$objdumpProcess\.Kill\(\).*?WaitForExit\(\$objdumpKillTimeoutMs\).*?llvm-objdump did not exit after termination.*?WaitAll\(.*?\$streamCopyTimeoutMs.*?llvm-objdump stream cleanup timed out' `
    -Description 'Windows x64 baseline disassembly is time-bounded and kills a timed-out tool'
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

& (Join-Path $root 'Test-WindowsX64Baseline.ps1')

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
