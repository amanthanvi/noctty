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

function Get-YamlLiteralRunScript {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Source
    )

    $match = [regex]::Match($Content, '(?ms)^        run:[ \t]*\|[ \t]*\r?\n(?<body>.*)\z')
    if (-not $match.Success) { throw "Literal workflow run block not found: $Source" }
    $scriptLines = @(
        foreach ($line in ($match.Groups['body'].Value -split '\r?\n')) {
            if ($line.Length -eq 0) { ''; continue }
            if (-not $line.StartsWith('          ', [StringComparison]::Ordinal)) {
                throw "Literal workflow run block has unexpected indentation: $Source"
            }
            $line.Substring(10)
        }
    )
    ($scriptLines -join "`n").TrimEnd([char[]]"`n")
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
        return $leafName -in @('Set-Alias', 'sal', 'New-Alias', 'nal', 'Remove-Alias', 'ral', 'Import-Alias', 'ipal', 'Import-Module', 'ipmo', 'Import-PSSession', 'Add-PSSnapin', 'asnp', 'Remove-PSSnapin', 'rsnp', 'Invoke-Expression', 'iex', 'Get-Variable', 'gv') -or
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
        [Parameter(Mandatory)] [System.Management.Automation.Language.Token[]] $Tokens,
        [Parameter(Mandatory)] [string] $Context,
        [string[]] $ExpectedDotSources = @(),
        [string[]] $ExpectedAmpersandCommands = @()
    )

    $mutators = @($Ast.FindAll({ param($node) Test-CommandResolutionMutationNode -Node $node }, $true))
    if ($mutators.Count -ne 0) { throw "Command resolution mutation is forbidden: $Context" }
    if (Test-CommandLoadingRequirement -Ast $Ast -Tokens $Tokens) {
        throw "Command-loading #requires directive is forbidden: $Context"
    }
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

function Test-CommandLoadingRequirement {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [System.Management.Automation.Language.Token[]] $Tokens
    )

    if ($null -ne $Ast.ScriptRequirements -and
        @($Ast.ScriptRequirements.RequiredModules).Count -ne 0) {
        return $true
    }

    return @($Tokens | Where-Object {
        $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and
            $_.Text -match '(?i)^#requires\b[^\r\n]*[ \t]-(?:M(?:o(?:d(?:u(?:l(?:e(?:s)?)?)?)?)?)?|P(?:S(?:S(?:n(?:a(?:p(?:i(?:n)?)?)?)?)?)?)?)(?::|[ \t]|$)'
    }).Count -ne 0
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
    [pscustomobject]@{ Reject = $true; Text = 'Invoke-Expression ''Write-Host bypass''' }
    [pscustomobject]@{ Reject = $true; Text = 'iex ''Write-Host bypass''' }
    [pscustomobject]@{ Reject = $true; Text = 'Add-PSSnapin Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = 'asnp Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -PSSnapin Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -PSSnapin:Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -P Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -PS Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -PSSn Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#ReQuIrEs -Version 5.1 -PsSnApIn Example.SnapIn' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -Modules Example.Module' }
    [pscustomobject]@{ Reject = $true; Text = '#requires -M Example.Module' }
    [pscustomobject]@{ Reject = $false; Text = '#requires -Version 5.1' }
    [pscustomobject]@{ Reject = $false; Text = '#requires -PSEdition Desktop' }
    [pscustomobject]@{ Reject = $false; Text = 'Write-Host ''#requires -PSSnapin Example.SnapIn''' }
    [pscustomobject]@{ Reject = $false; Text = ("@'" + [Environment]::NewLine + '#requires -Modules Example.Module' + [Environment]::NewLine + "'@") }
)
foreach ($probe in $commandResolutionProbes) {
    $probeTokens = $null
    $probeErrors = $null
    $probeAst = [System.Management.Automation.Language.Parser]::ParseInput($probe.Text, [ref] $probeTokens, [ref] $probeErrors)
    if ($probeErrors.Count -ne 0) { throw "Command-resolution probe does not parse: $($probe.Text)" }
    $probeRejected = $false
    $probeFailure = $null
    try {
        Assert-CommandResolutionContract -Ast $probeAst -Tokens $probeTokens -Context "probe: $($probe.Text)"
    } catch {
        $probeRejected = $true
        $probeFailure = $_.Exception.Message
    }
    if ($probeRejected -ne $probe.Reject) {
        throw "Command-resolution probe contract failed: $($probe.Text) (contract result: $probeFailure)"
    }
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
$newTabHarness = Join-Path $repoRoot 'test\windows\interactive-win11-new-tab.ps1'
$undoHarness = Join-Path $repoRoot 'test\windows\interactive-win11-undo.ps1'
$resizeHarness = Join-Path $repoRoot 'test\windows\interactive-win11-resize.ps1'
$win32Runtime = Join-Path $repoRoot 'src\apprt\win32.zig'
$win32Settings = Join-Path $repoRoot 'src\apprt\win32_settings.zig'
$win32UiaWidgets = Join-Path $repoRoot 'src\apprt\win32_uia\widgets.zig'
$interactivePrSmoke = Join-Path $repoRoot 'test\windows\interactive-win11-pr-smoke.ps1'
$releaseCopyChecker = Join-Path $repoRoot 'scripts\check-release-copy.ps1'
$releasePreflight = Join-Path $repoRoot 'scripts\release-preflight.ps1'
$publishedReleaseVerifier = Join-Path $repoRoot 'scripts\verify-published-release.ps1'
$windowsPackager = Join-Path $repoRoot 'scripts\package-windows.ps1'
$releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflow -Raw
$readinessWorkflowText = Get-Content -LiteralPath $readinessWorkflow -Raw
$testWorkflowText = Get-Content -LiteralPath $testWorkflow -Raw
$interactiveWin11LibText = Get-Content -LiteralPath $interactiveWin11Lib -Raw
$cliShellHarnessText = Get-Content -LiteralPath $cliShellHarness -Raw
$statefulWin11LibText = Get-Content -LiteralPath $statefulWin11Lib -Raw
$accessibilityHarnessText = Get-Content -LiteralPath $accessibilityHarness -Raw
$publishedReleaseVerifierText = Get-Content -LiteralPath $publishedReleaseVerifier -Raw
$win32RuntimeText = Get-Content -LiteralPath $win32Runtime -Raw
$win32SettingsText = Get-Content -LiteralPath $win32Settings -Raw
$win32UiaWidgetsText = Get-Content -LiteralPath $win32UiaWidgets -Raw
$sessionRestoreHarnessText = Get-Content -LiteralPath $sessionRestoreHarness -Raw
$paletteThemeHarnessText = Get-Content -LiteralPath $paletteThemeHarness -Raw
$accessibilityHarnessTokens = $null
$accessibilityHarnessErrors = $null
$accessibilityHarnessAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $accessibilityHarnessText,
    [ref]$accessibilityHarnessTokens,
    [ref]$accessibilityHarnessErrors
)
if ($accessibilityHarnessErrors.Count -ne 0) {
    throw "Accessibility harness does not parse: $($accessibilityHarnessErrors[0].Message)"
}
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
    $expectedAmpersands = if ($source.Path -eq $interactiveWin11Lib) {
        @(
            '& $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $LauncherPath @ArgumentList',
            '& cmd /c $devWindowsCmd zig build -Demit-exe=true',
            '& $Condition'
        )
    } else { @() }
    Assert-CommandResolutionContract -Ast $source.Ast -Tokens $source.Tokens -Context $source.Path -ExpectedAmpersandCommands $expectedAmpersands
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
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes.Count -ne 2 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes[0].Extent.Text.Trim() -ne '[Parameter(Mandatory)]' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].Attributes[1].Extent.Text.Trim() -ne '[System.Diagnostics.Process]' -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[0].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Name.VariablePath.UserPath -ne 'RequireLiveRoot' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Attributes.Count -ne 1 -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].Attributes[0].Extent.Text.Trim() -ne '[switch]' -or
    $null -ne $stopProcessFunctions[0].Body.ParamBlock.Parameters[1].DefaultValue -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[2].Name.VariablePath.UserPath -ne 'Contained' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[2].Attributes[0].Extent.Text.Trim() -ne '[switch]' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[3].Name.VariablePath.UserPath -ne 'AllowAlreadyExited' -or
    $stopProcessFunctions[0].Body.ParamBlock.Parameters[3].Attributes[0].Extent.Text.Trim() -ne '[switch]') {
    throw 'Interactive process cleanup must expose explicit contained, live-root, and already-exited contracts.'
}
$snapshotCimCommands = @($processTreeSnapshotFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-CimInstance'
    }, $true))
$verificationCimCommands = @($processTreeExitedFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-CimInstance'
    }, $true))
$snapshotCalls = @($stopProcessFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-InteractiveWin11ProcessTreeSnapshot'
    }, $true))
$rootStopCalls = @($stopProcessFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Stop-InteractiveWin11RootHandle'
    }, $true))
$waitCalls = @($stopProcessFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Wait-InteractiveWin11ProcessTreeSnapshotExited'
    }, $true))
$stopProcessText = $stopProcessFunctions[0].Extent.Text
$rootTerminateCalls = @($stopRootHandleFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Extent.Text -eq '[InteractiveWin11ProcessNative]::TerminateProcess($RootProcessHandle, 1)'
    }, $true))
$rootWaitCalls = @($stopRootHandleFunctions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Extent.Text -eq '[InteractiveWin11ProcessNative]::WaitForSingleObject($RootProcessHandle, 15000)'
    }, $true))
if ($snapshotCimCommands.Count -ne 1 -or
    $verificationCimCommands.Count -ne 1 -or
    $snapshotCimCommands[0].Extent.Text -notmatch '(?s)-ClassName\s+Win32_Process\s+-OperationTimeoutSec\s+5\s+-ErrorAction\s+Stop' -or
    $verificationCimCommands[0].Extent.Text -notmatch '(?s)-ClassName\s+Win32_Process.*?-OperationTimeoutSec\s+\$OperationTimeoutSec.*?-ErrorAction\s+Stop' -or
    $snapshotCimCommands[0].Extent.Text -match '(?i)-Filter\b' -or
    $verificationCimCommands[0].Extent.Text -match '(?i)-Filter\b' -or
    @($processTreeSnapshotFunctions[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CatchClauseAst] }, $true)).Count -ne 0 -or
    @($processTreeExitedFunctions[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CatchClauseAst] }, $true)).Count -ne 0 -or
    $snapshotCalls.Count -ne 1 -or
    $rootStopCalls.Count -ne 1 -or
    $waitCalls.Count -ne 1 -or
    $snapshotCalls[0].Extent.StartOffset -ge $rootStopCalls[0].Extent.StartOffset -or
    $rootStopCalls[0].Extent.StartOffset -ge $waitCalls[0].Extent.StartOffset -or
    $rootTerminateCalls.Count -ne 1 -or
    $rootWaitCalls.Count -ne 1 -or
    $stopProcessText -notmatch '(?s)if \(-not \$Contained\).*?taskkill\.exe.*?WaitForExit\(10000\).*?Kill\(\).*?WaitForExit\(5000\)' -or
    $stopProcessText -notmatch '(?s)\$taskkillCleanupError.*?if \(\$null -ne \$taskkillCleanupError\)\s*\{\s*throw' -or
    $stopProcessText -notmatch '(?s)if \(\$Contained -and \$null -ne \$snapshotError\).*?return' -or
    $stopProcessText -notmatch '(?s)\$lifecycleModeCount.*?if \(\$lifecycleModeCount -gt 1\).*?mutually exclusive' -or
    $stopProcessText -notmatch '(?s)if \(\$null -ne \$verificationError\).*?if \(\$Contained\).*?return.*?throw' -or
    $waitProcessTreeExitedFunctions[0].Extent.Text -notmatch '(?s)\$deadline\s*=\s*\[DateTime\]::UtcNow\.AddSeconds\(\$TimeoutSeconds\).*?while \(\[DateTime\]::UtcNow -lt \$deadline\)') {
    throw 'Interactive cleanup must use bounded uncontained tree kill, contained Job cleanup, native root termination, and deadline-bound verification.'
}

. ([scriptblock]::Create($processTreeSnapshotFunctions[0].Extent.Text))
. ([scriptblock]::Create($processTreeExitedFunctions[0].Extent.Text))
$script:verificationCimProcesses = @()
$script:verificationCimFailure = $null
function script:Get-CimInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClassName,
        [string] $Filter,
        [uint32] $OperationTimeoutSec
    )

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
    try { [void](Get-InteractiveWin11ProcessTreeSnapshot -RootProcessId 100 -RootStartedAt $rootCreated) } catch { $missingRootRejected = $true }
    if (-not $missingRootRejected) {
        throw 'Interactive process snapshot accepted a missing root identity.'
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
}
finally {
    Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name verificationCimProcesses, verificationCimFailure -ErrorAction SilentlyContinue
}

. ([scriptblock]::Create($stopProcessFunctions[0].Extent.Text))
$script:cleanupSnapshotFailure = $false
$script:cleanupVerificationFailure = $false
$script:cleanupVerificationExited = $true
function script:Get-InteractiveWin11ProcessTreeSnapshot {
    param([int] $RootProcessId, [datetime] $RootStartedAt)
    if ($script:cleanupSnapshotFailure) { throw 'simulated snapshot failure' }
    @([pscustomobject]@{ ProcessId = $RootProcessId; CreationDate = $RootStartedAt })
}
function script:Stop-InteractiveWin11RootHandle {
    param(
        [System.Diagnostics.Process] $Process,
        [IntPtr] $RootProcessHandle,
        [datetime] $RootStartedAt
    )
    $Process.Kill()
    if (-not $Process.WaitForExit(5000)) { throw 'mock root process did not exit' }
}
function script:Wait-InteractiveWin11ProcessTreeSnapshotExited {
    param([object[]] $Snapshot)
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
    if (-not $process.HasExited) {
        throw 'Contained cleanup did not terminate the root before accepting unavailable verification.'
    }
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
    Remove-Variable -Scope Script -Name cleanupSnapshotFailure, cleanupVerificationFailure, cleanupVerificationExited -ErrorAction SilentlyContinue
}

$containmentFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11ContainmentArguments'
    }, $true))
$launchArgumentFunctions = @($interactiveWin11LibAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InteractiveWin11LaunchArguments'
    }, $true))
if ($containmentFunctions.Count -ne 1 -or
    $launchArgumentFunctions.Count -ne 1 -or
    $containmentFunctions[0].Extent.Text -notmatch [regex]::Escape("'--linux-cgroup=always'") -or
    $containmentFunctions[0].Extent.Text -notmatch [regex]::Escape("'--linux-cgroup-hard-fail=true'") -or
    $containmentFunctions[0].Extent.Text -notmatch [regex]::Escape("'--windows-job-object-kill-on-close=true'") -or
    $launchArgumentFunctions[0].Extent.Text -notmatch '\bGet-InteractiveWin11ContainmentArguments\b') {
    throw 'Interactive Win11 launches must opt into hard-fail kill-on-close Job Object containment.'
}
$interactiveLibraryTest = Get-Content -LiteralPath (Join-Path $repoRoot 'test\windows\interactive-win11.ps1') -Raw
if ($interactiveLibraryTest -notmatch [regex]::Escape("Assert-Equal `$launchArgs.Count 5 'launch args should include containment and isolation overrides'") -or
    $interactiveLibraryTest -notmatch [regex]::Escape("Assert-True (`$launchArgs -contains '--linux-cgroup=always')") -or
    $interactiveLibraryTest -notmatch [regex]::Escape("Assert-True (`$launchArgs -contains '--linux-cgroup-hard-fail=true')") -or
    $interactiveLibraryTest -notmatch [regex]::Escape("Assert-True (`$launchArgs -contains '--windows-job-object-kill-on-close=true')")) {
    throw 'Interactive helper tests must assert all containment and isolation launch arguments.'
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
$cleanupScriptFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'test\windows') -Filter '*.ps1' -File -Recurse |
        Where-Object { $_.FullName -ne $PSCommandPath }
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
        # The composite validator is a byte-for-byte frozen baseline artifact.
        # Mode omission uses Stop-InteractiveWin11Process's fail-closed live-root
        # default; every mutable caller must state exactly one lifecycle mode.
        $frozenValidatorDefault = $file.Name -eq 'interactive-win11-validate.ps1' -and $modeCount -eq 0
        if ((-not $frozenValidatorDefault -and $modeCount -ne 1) -or
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

Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('throw "Interactive Win11 root process $RootProcessId was absent from the process-table snapshot."')) `
    -Description 'interactive cleanup fails closed if root is absent from process snapshot' `
    -Context $interactiveWin11Lib
Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('throw ''Interactive Win11 process-tree verification requires a non-empty snapshot.''')) `
    -Description 'interactive cleanup rejects vacuous empty-snapshot verification' `
    -Context $interactiveWin11Lib
Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('$capturedStartedAtById[$parentProcessId]')) `
    -Description 'interactive cleanup fails closed on identity-matched descendants created after snapshot' `
    -Context $interactiveWin11Lib
Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('$terminationRequested = [InteractiveWin11ProcessNative]::TerminateProcess($RootProcessHandle, 1)')) `
    -Description 'interactive cleanup terminates only the captured root handle' `
    -Context $interactiveWin11Lib
Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('throw "Failed to verify cleanup of interactive Win11 process tree $rootProcessId')) `
    -Description 'interactive cleanup still fails closed on unverified process tree' `
    -Context $interactiveWin11Lib
Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);')) `
    -Description 'native root fallback termination declaration' `
    -Context $interactiveWin11Lib
Assert-TextContract `
    -Content $interactiveWin11LibText `
    -Pattern ([regex]::Escape('public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);')) `
    -Description 'native root termination wait declaration' `
    -Context $interactiveWin11Lib
$expectedCliShellHarnessText = @'
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cmd', 'powershell')]
    [string] $Shell,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedText,

    [int] $ExpectedExitCode = 0,

    [string] $BinDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

function Format-CmdArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.Length -eq 0) {
        return '""'
    }

    $escaped = $Argument.Replace('%', '%%').Replace('"', '""')
    if ($escaped -match '[\s"&|<>()^!]') {
        return '"' + $escaped + '"'
    }

    return $escaped
}

function Format-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Argument
    )

    return "'" + $Argument.Replace("'", "''") + "'"
}

$binDir = [System.IO.Path]::GetFullPath($(if ($BinDir) { $BinDir } else { Join-Path $repoRoot 'zig-out\bin' }))
$guiExe = Join-Path $binDir 'winghostty.exe'
$commandExe = Join-Path $binDir 'winghostty.com'
$cmdExe = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$powershellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

foreach ($requiredExecutable in @($guiExe, $commandExe, $cmdExe, $powershellExe)) {
    if (-not (Test-Path -LiteralPath $requiredExecutable -PathType Leaf)) {
        throw "Missing required executable: $requiredExecutable. Run `zig build -Demit-exe=true` if the winghostty binaries are absent."
    }
}

$envPath = "$binDir;$env:PATH"
$argsDisplay = [string]::Join(' ', $Arguments)
$shellLauncherTimeoutSeconds = 30

switch ($Shell) {
    'cmd' {
        $resolved = & $cmdExe /d /c "set ""PATH=$envPath""&& where winghostty"
        if ($LASTEXITCODE -ne 0) {
            throw "cmd could not resolve winghostty from PATH."
        }
        $resolvedPath = [System.IO.Path]::GetFullPath(($resolved | Select-Object -First 1))
        if (-not [string]::Equals($resolvedPath, $commandExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "cmd resolved winghostty to the wrong artifact: $resolvedPath"
        }

        $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stdout.txt")
        $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stderr.txt")
        $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + ".cmd")
        try {
            $cmdArgs = [string]::Join(' ', ($Arguments | ForEach-Object { Format-CmdArgument $_ }))
            $cmdCommand = if ([string]::IsNullOrEmpty($cmdArgs)) { 'winghostty' } else { "winghostty $cmdArgs" }
            @(
                '@echo off'
                "set `"PATH=$envPath`""
                $cmdCommand
            ) | Set-Content -LiteralPath $payloadPath -Encoding ASCII

            $process = Start-Process `
                -FilePath $cmdExe `
                -ArgumentList "/d /c `"$payloadPath`"" `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -WindowStyle Hidden `
                -PassThru
            $processHandle = $process.Handle
            if (-not $process.WaitForExit($shellLauncherTimeoutSeconds * 1000)) {
                Stop-InteractiveWin11Process -Process $process -RequireLiveRoot
                throw "Timed out waiting $shellLauncherTimeoutSeconds seconds for shell launcher process to exit."
            }

            $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
            $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
                Get-Content -LiteralPath $stdoutPath -Raw
            } else {
                ''
            }
            $stderrText = if (Test-Path -LiteralPath $stderrPath) {
                Get-Content -LiteralPath $stderrPath -Raw
            } else {
                ''
            }
            $output = $stdoutText + $stderrText
        }
        finally {
            Remove-Item -LiteralPath $stdoutPath, $stderrPath, $payloadPath -ErrorAction SilentlyContinue
        }
    }

    'powershell' {
        $oldPath = $env:PATH
        $env:PATH = $envPath
        try {
            $resolved = & $powershellExe -NoProfile -Command "(Get-Command winghostty).Source"
            if ($LASTEXITCODE -ne 0) {
                throw "PowerShell could not resolve winghostty from PATH."
            }
            $resolvedPath = [System.IO.Path]::GetFullPath($resolved)
            if (-not [string]::Equals($resolvedPath, $commandExe, [StringComparison]::OrdinalIgnoreCase)) {
                throw "PowerShell resolved winghostty to the wrong artifact: $resolvedPath"
            }

            $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stdout.txt")
            $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stderr.txt")
            $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + ".ps1")
            try {
                $env:PATH = $envPath
                $argLiterals = [string]::Join(', ', ($Arguments | ForEach-Object { Format-PowerShellLiteral $_ }))
                @(
                    '$argsList = @(' + $argLiterals + ')'
                    '$output = & winghostty @argsList | Out-String'
                    '$exitCode = $LASTEXITCODE'
                    '[Console]::Out.Write($output)'
                    'exit $exitCode'
                ) | Set-Content -LiteralPath $payloadPath -Encoding UTF8

                $process = Start-Process `
                    -FilePath $powershellExe `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $payloadPath) `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError $stderrPath `
                    -WindowStyle Hidden `
                    -PassThru
                $processHandle = $process.Handle
                if (-not $process.WaitForExit($shellLauncherTimeoutSeconds * 1000)) {
                    Stop-InteractiveWin11Process -Process $process -RequireLiveRoot
                    throw "Timed out waiting $shellLauncherTimeoutSeconds seconds for shell launcher process to exit."
                }

                $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
                $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
                    Get-Content -LiteralPath $stdoutPath -Raw
                } else {
                    ''
                }
                $stderrText = if (Test-Path -LiteralPath $stderrPath) {
                    Get-Content -LiteralPath $stderrPath -Raw
                } else {
                    ''
                }
                $output = $stdoutText + $stderrText
            }
            finally {
                Remove-Item -LiteralPath $stdoutPath, $stderrPath, $payloadPath -ErrorAction SilentlyContinue
            }
        }
        finally {
            $env:PATH = $oldPath
        }
    }
}

if ($exitCode -ne $ExpectedExitCode) {
    throw "$Shell shell launcher should exit with code $ExpectedExitCode, got $exitCode."
}

$outputText = if ($output -is [string]) { $output } else { ($output | Out-String) }
if (-not $outputText.Contains($ExpectedText)) {
    throw "$Shell shell launcher output did not contain expected text '$ExpectedText'."
}

Write-Host "shell launcher validation: PASS (shell=$Shell, args=$argsDisplay)"
'@
if ((($cliShellHarnessText -replace "\r\n?", "`n") -replace '\n+\z', '') -cne
    (($expectedCliShellHarnessText -replace "\r\n?", "`n") -replace '\n+\z', '')) {
    throw 'CLI shell harness must match its complete reviewed source snapshot.'
}
$cliShellTokens = $null
$cliShellErrors = $null
$cliShellAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $cliShellHarnessText,
    [ref]$cliShellTokens,
    [ref]$cliShellErrors
)
if ($cliShellErrors.Count -ne 0) { throw 'CLI shell harness must parse without errors.' }
Assert-CommandResolutionContract -Ast $cliShellAst -Tokens $cliShellTokens -Context $cliShellHarness -ExpectedDotSources @(
    ". (Join-Path `$repoRoot 'scripts\interactive-win11-lib.ps1')"
) -ExpectedAmpersandCommands @(
    '& $cmdExe /d /c "set ""PATH=$envPath""&& where winghostty"'
    '& $powershellExe -NoProfile -Command "(Get-Command winghostty).Source"'
)
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
$textRangeEndpointReferences = [regex]::Matches(
    $accessibilityHarnessText,
    '\[System\.Windows\.Automation\.Text\.TextPatternRangeEndpoint\]::(?:Start|End)'
)
if ($textRangeEndpointReferences.Count -ne 4 -or
    $accessibilityHarnessText -match '\[System\.Windows\.Automation\.TextPatternRangeEndpoint\]') {
    throw 'Accessibility caret assertions must use the installed UIAutomation Text.TextPatternRangeEndpoint type.'
}
if ($accessibilityHarnessText -match 'VkKeyScanW|SendAsciiText' -or
    $accessibilityHarnessText -notmatch 'private const uint KEYEVENTF_UNICODE = 0x0004;' -or
    ([regex]::Matches($accessibilityHarnessText, 'inputs\.Add\(Key\(0, value, KEYEVENTF_UNICODE(?: \| KEYEVENTF_KEYUP)?\)\);')).Count -ne 2) {
    throw 'Accessibility text injection must use layout-independent KEYEVENTF_UNICODE key down/up pairs.'
}
$queryOnlyTextPatternContract = [regex]::Match(
    $accessibilityHarnessText,
    '(?s)\$queryOnlyPreviousRange = \$textPattern\.DocumentRange.*?RemoveAutomationEventHandler\(.*?TextPattern\]::TextChangedEvent.*?Send-AccessibilityOutputMarker .*?-TextPattern \$textPattern .*?-Marker \$queryOnlyMarker.*?\$script:queryOnlyTextProbe = \$textPattern\.DocumentRange\.GetText\(-1\).*?\$queryOnlyPreviousRange\.GetText\(-1\)\.Contains\(\$queryOnlyMarker\).*?AddAutomationEventHandler\(.*?TextPattern\]::TextChangedEvent'
)
if (-not $queryOnlyTextPatternContract.Success) {
    throw 'Accessibility query-only contract must remove this client handler, request fresh ranges through the retained TextPattern, preserve the prior immutable range, and restore the handler.'
}
if ($win32RuntimeText -notmatch 'WM_WINHOSTTY_UIA_QUERY_REFRESH = WM_APP \+ 6' -or
    $win32RuntimeText -notmatch 'SendMessageTimeoutW\(\s*hwnd\.\?,\s*WM_WINHOSTTY_UIA_QUERY_REFRESH,\s*1,' -or
    $win32RuntimeText -notmatch 'refreshTerminalUiaTextWithMode\(wParam != 0\)' -or
    $win32RuntimeText -notmatch 'if \(!force and !terminalUiaRefreshDue' -or
    $win32RuntimeText -notmatch 'query_refresh_post_pending\.cmpxchgStrong\(false, true' -or
    $win32RuntimeText -notmatch 'PostMessageW\(hwnd\.\?, WM_WINHOSTTY_UIA_QUERY_REFRESH' -or
    $win32RuntimeText -notmatch 'refresh_snapshot = clients_listening_for_events or query_recently_active') {
    throw 'Terminal UIA polling must use a coalesced query-driven UI-thread refresh and stop snapshots when clients are idle.'
}
if ($accessibilityHarnessText -notmatch 'Send-AccessibilityBlindOutputMarker' -or
    $accessibilityHarnessText -notmatch 'Start-Sleep -Milliseconds 1200' -or
    $accessibilityHarnessText -notmatch '\$coldQueryFirstText = \$textPattern\.DocumentRange\.GetText\(-1\)' -or
    $accessibilityHarnessText -notmatch 'cold_query_first_document_range_fresh') {
    throw 'Accessibility evidence must prove the first TextPattern range after a cold query is fresh without pre-querying.'
}
$stressBoundaryContract = [regex]::Match(
    $accessibilityHarnessText,
    '(?s)\$stressFirstMarker = "\$\{stressPrefix\}_1".*?\$stressFinalMarker = "\$\{stressPrefix\}_150".*?for /L %i in \(1,1,\$stressLineCount\) do @echo \$\{stressPrefix\}_%i.*?\$stressCommand\.Contains\(\$stressFirstMarker\).*?\$stressCommand\.Contains\(\$stressFinalMarker\)'
)
if (-not $stressBoundaryContract.Success -or $accessibilityHarnessText -match 'echo \$stressFirstMarker') {
    throw 'Accessibility sustained-output boundaries must be generated only by command execution, never echoed literally in the typed command.'
}
if ($accessibilityHarnessText -notmatch '\$settingsElement\.Current\.Name -ne ''winghostty settings''' -or
    $accessibilityHarnessText -notmatch '\$settingsExpectedControls = \[ordered\]@\{' -or
    $accessibilityHarnessText -notmatch 'settingsControlOverlapComparisons' -or
    $accessibilityHarnessText -notmatch 'settingsContainmentChecks' -or
    $accessibilityHarnessText -notmatch '\$settingsLayoutControls = @\(\$sectionButtons\) \+ @\(\$interactiveSettingsControls\)' -or
    $accessibilityHarnessText -notmatch 'Automation\]::Compare\(\s*\$settingsSharedSectionContainer' -or
    $accessibilityHarnessText -notmatch '\$containerSelection\.Current\.GetSelection\(\)') {
    throw 'Accessibility settings evidence must assert root identity, named roles, shared selection semantics, peer overlap, and client containment.'
}
if ($accessibilityHarnessText -match '(?m)^\s*\$matches\s*=' -or
    $accessibilityHarnessText -notmatch '\$controlMatches = @\(\$interactiveSettingsControls \| Where-Object' -or
    $accessibilityHarnessText -notmatch '\$controlMatches\.Count -ne 1') {
    throw 'Accessibility settings evidence must not overwrite the automatic $matches variable.'
}
if ($win32SettingsText -notmatch 'const settings_header_control_count = 3;' -or
    $win32SettingsText -notmatch 'const settings_clipped_control_count = settings_control_count - settings_header_control_count;' -or
    $win32SettingsText -notmatch 'for \(0\.\.settings_clipped_control_count\) \|index\|' -or
    $win32SettingsText -match 'for \(0\.\.27\) \|index\|') {
    throw 'Settings viewport clipping must derive its content-control bound from the fixed header-control count.'
}
if ($accessibilityHarnessText -notmatch '\$script:palette = \$palette' -or
    $accessibilityHarnessText -notmatch '\$script:paletteUnavailableItems = @\(\$script:palette\.FindAll' -or
    $accessibilityHarnessText -notmatch '\$script:palette = @\(\$root\.FindAll' -or
    $accessibilityHarnessText -notmatch '(?s)if \(\$null -eq \$script:palette\) \{\s*\$script:palette = @\(\$root\.FindAll.*?if \(\$null -eq \$script:palette\) \{.*?\$script:paletteUnavailableItems = @\(\).*?\$queryStillFocused.*?NotificationCount -gt 0.*?return \$true.*?\$script:paletteUnavailableItems = @\(\$script:palette\.FindAll' -or
    $accessibilityHarnessText -notmatch '\$script:paletteUnavailableFocused\.Current\.ControlType -eq \[System\.Windows\.Automation\.ControlType\]::Edit' -or
    $accessibilityHarnessText -notmatch '\$script:paletteUnavailableFocused\.Current\.Name -eq ''Command palette query''' -or
    $accessibilityHarnessText -notmatch '\$script:paletteUnavailableFocused\.Current\.HasKeyboardFocus' -or
    $accessibilityHarnessText -notmatch '(?s)\$script:paletteUnavailableItems = @\(\$script:palette\.FindAll.*?\$script:paletteUnavailableFocused = \[System\.Windows\.Automation\.AutomationElement\]::FocusedElement.*?\$queryStillFocused = \$null -ne \$script:paletteUnavailableFocused -and\s*\$script:paletteUnavailableFocused\.Current\.ProcessId -eq \$process\.Id -and\s*\$script:paletteUnavailableFocused\.Current\.ControlType -eq \[System\.Windows\.Automation\.ControlType\]::Edit -and\s*\$script:paletteUnavailableFocused\.Current\.Name -eq ''Command palette query'' -and\s*\$script:paletteUnavailableFocused\.Current\.HasKeyboardFocus.*?return \$script:paletteUnavailableItems\.Count -eq 0 -and\s*\$queryStillFocused -and' -or
    $accessibilityHarnessText -notmatch '-not \[WinghosttyAccessibilityNative\]::IsWindowVisible\(\$paletteNativeHwnd\)' -or
    $accessibilityHarnessText -notmatch "-Description 'command palette native List recovery after zero matches'" -or
    $accessibilityHarnessText -notmatch '\$paletteRecoveredSelectionPattern\.Current\.GetSelection\(\)' -or
    $accessibilityHarnessText -notmatch '\$script:paletteRecoveredFocus\.Current\.HasKeyboardFocus' -or
    $accessibilityHarnessText -notmatch '\$script:paletteRecoveryLastTransient' -or
    $accessibilityHarnessText -notmatch '(?s)command palette native List recovery after zero matches.*?Test-AccessibilityTransientHResult -HResult \$_.*?\$transientHresult -eq 0x80040201.*?\$script:paletteRecovered = \$null' -or
    $accessibilityHarnessText -notmatch 'function Get-AccessibilityExceptionHResults' -or
    $accessibilityHarnessText -notmatch '\$results = \[System\.Collections\.Generic\.List\[int\]\]::new\(\)' -or
    $accessibilityHarnessText -notmatch '\$cursor = \$cursor\.InnerException' -or
    $accessibilityHarnessText -notmatch 'function Test-AccessibilityTransientHResult' -or
    $accessibilityHarnessText -notmatch 'foreach \(\$knownTransient in @\(\[int\]0x80010001, \[int\]0x8001010A, \[int\]0x80040201\)\)' -or
    $accessibilityHarnessText -notmatch 'Test-AccessibilityTransientHResult -HResult 0' -or
    $accessibilityHarnessText -notmatch '\$hresults = @\(Get-AccessibilityExceptionHResults -Exception \$_\.Exception\)' -or
    $accessibilityHarnessText -notmatch 'Test-AccessibilityTransientHResult -HResult \$_' -or
    $accessibilityHarnessText -notmatch '\$null -eq \$transientHresult' -or
    $accessibilityHarnessText -notmatch '\$transientHresult -eq 0x80010001 -or \$transientHresult -eq 0x8001010A' -or
    $accessibilityHarnessText -notmatch '\$transientHresult -eq 0x80040201' -or
    $accessibilityHarnessText -notmatch '(?s)if \(\$transientHresult -eq 0x80040201\) \{\s*\$script:palette = \$null\s*return \$false' -or
    $accessibilityHarnessText -match '0x80131501') {
    throw 'Accessibility palette recovery must unwrap exception chains, use script-scoped reacquisition, and retry only known UIA transient HRESULTs.'
}
$accessibilityHresultFunctions = @($accessibilityHarnessAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Get-AccessibilityExceptionHResults', 'Test-AccessibilityTransientHResult')
}, $true))
if ($accessibilityHresultFunctions.Count -ne 2) {
    throw 'Accessibility harness must define exactly one exception-chain helper and one transient-HRESULT classifier.'
}
foreach ($function in $accessibilityHresultFunctions) {
    Invoke-Expression $function.Extent.Text
}
foreach ($knownHresult in @([int]0x80010001, [int]0x8001010A, [int]0x80040201)) {
    $knownException = [Runtime.InteropServices.COMException]::new('known transient', $knownHresult)
    $directChain = @(Get-AccessibilityExceptionHResults -Exception $knownException)
    $wrappedChain = @(Get-AccessibilityExceptionHResults -Exception ([Exception]::new('wrapper', $knownException)))
    if ($directChain.Count -ne 1 -or $directChain[0] -ne $knownHresult -or
        $wrappedChain.Count -ne 2 -or $wrappedChain[-1] -ne $knownHresult -or
        -not (Test-AccessibilityTransientHResult -HResult $directChain[0]) -or
        -not (Test-AccessibilityTransientHResult -HResult $wrappedChain[-1])) {
        throw ('Accessibility transient HRESULT semantics failed for 0x{0:X8}.' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($knownHresult), 0))
    }
}
if (Test-AccessibilityTransientHResult -HResult ([int]0x80131501)) {
    throw 'Accessibility transient HRESULT classifier must reject the generic .NET wrapper result 0x80131501.'
}
if ($accessibilityHarnessText -notmatch 'ExpectedFocusedHwnd' -or
    $accessibilityHarnessText -notmatch 'sustained output command'' -ExpectedFocusedHwnd \$leftPane\.Hwnd' -or
    $accessibilityHarnessText -notmatch 'failed to remove terminal TextChanged handler') {
    throw 'Accessibility input ownership and UIA cleanup must remain exact and fail closed.'
}
if ($accessibilityHarnessText -notmatch '\$idleTerminalHostHwnd = \$process\.MainWindowHandle' -or
    $accessibilityHarnessText -notmatch 'ForceForeground\(\$idleTerminalHostHwnd\)' -or
    $accessibilityHarnessText -notmatch 'GetForegroundWindow\(\) -eq \$idleTerminalHostHwnd' -or
    $accessibilityHarnessText -notmatch 'FocusedWindowFor\(\$idleTerminalHostHwnd\) -eq \$leftPane\.Hwnd' -or
    $accessibilityHarnessText -match '(?s)settings-open idle soak.*?ForceForeground\(\$process\.MainWindowHandle\)') {
    throw 'Accessibility settings idle-soak focus checks must retain the terminal host HWND before Process.Refresh can recache the independent Settings window.'
}
$settingsSectionProviderContract = [regex]::Match(
    $win32UiaWidgetsText,
    '(?ms)^pub const SettingsSectionProvider = struct \{(?<body>.*?)^\};\s*$'
)
if (-not $settingsSectionProviderContract.Success -or
    $settingsSectionProviderContract.Groups['body'].Value -match 'SendMessageW|SetFocus' -or
    $settingsSectionProviderContract.Groups['body'].Value -notmatch 'container\.selected_index\.load\(\.acquire\)' -or
    $settingsSectionProviderContract.Groups['body'].Value -notmatch 'PostMessageW\(self\.hwnd, BM_CLICK') {
    throw 'Settings section UIA callbacks must use atomic selection state and asynchronously marshal clicks to the UI thread.'
}
if ($win32UiaWidgetsText -match 'UiaRaiseAutomationEvent\(' -or
    ([regex]::Matches($win32UiaWidgetsText, 'events\.raiseSelectionItemSelected\(')).Count -ne 2 -or
    $win32UiaWidgetsText -notmatch 'events\.raiseSelectionItemSelected\(&row\.base\)' -or
    $win32UiaWidgetsText -notmatch 'events\.raiseSelectionItemSelected\(&self\.base\)') {
    throw 'Widget selection-item events must route through the shared UIA event helper.'
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
Assert-TextContract `
    -Content $paletteThemeHarnessText `
    -Pattern ([regex]::Escape('[int]$TimeoutSeconds = 60')) `
    -Description 'palette High Contrast transition budget remains Debug-build tolerant' `
    -Context $paletteThemeHarness
Assert-CommandResolutionContract -Ast $paletteThemeAst -Tokens $paletteThemeTokens -Context $paletteThemeHarness -ExpectedDotSources @(
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
if ($postHighContrastLoopStatements.Count -ne 3 -or
    $postHighContrastLoopStatements[0].Extent.Text.Trim() -ne '$canary = $null' -or
    $postHighContrastLoopStatements[1].Extent.Text.Trim() -ne '$presentationProven = $false' -or
    $postHighContrastLoopStatements[2] -isnot [System.Management.Automation.Language.TryStatementAst]) {
    throw 'Post-High-Contrast presentation must guard each complete canary lifecycle with one try/catch.'
}
$postHighContrastTry = $postHighContrastLoopStatements[2]
$postHighContrastTryStatements = @($postHighContrastTry.Body.Statements)
if ($postHighContrastTry.CatchClauses.Count -ne 1 -or $null -ne $postHighContrastTry.Finally -or
    $postHighContrastTryStatements.Count -ne 14 -or
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
    $postHighContrastTryStatements[10].Extent.Text.Trim() -ne '$presentationProven = $true' -or
    $postHighContrastTryStatements[11].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
    $postHighContrastTryStatements[12].Extent.Text.Trim() -ne 'Close-StatefulHost $canaryHost $canary $deadline' -or
    $postHighContrastTryStatements[13].Extent.Text.Trim() -ne 'return') {
    throw 'Post-High-Contrast presentation must preserve its exact launch, readiness, framebuffer, and close sequence with three fresh deadlines.'
}
$postHighContrastCatchStatements = @($postHighContrastTry.CatchClauses[0].Body.Statements)
if ($postHighContrastCatchStatements.Count -ne 4 -or
    $postHighContrastCatchStatements[0].Extent.Text.Trim() -ne '$lastError = $_' -or
    $postHighContrastCatchStatements[1].Extent.Text.Trim() -notmatch '(?s)^if \(\$null -ne \$canary -and -not \$canary\.Process\.HasExited\) \{\s*try \{ Stop-InteractiveWin11Process -Process \$canary\.Process -Contained \}\s*catch \{\s*throw "Post-High-Contrast presentation attempt \$attempt failed: \$\(\$lastError\.Exception\.Message\); process cleanup also failed: \$\(\$_\.Exception\.Message\)"\s*\}\s*\}$' -or
    $postHighContrastCatchStatements[2].Extent.Text.Trim() -ne 'if ($presentationProven) { return }' -or
    $postHighContrastCatchStatements[3].Extent.Text.Trim() -ne 'if ($attempt -lt 2) { Write-Warning "Post-High-Contrast presentation attempt $attempt stalled; retrying with a fresh process." }') {
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
    if ($loops.Count -ne 1 -or $loops[0].Body.Statements.Count -ne 3 -or
        $loops[0].Body.Statements[1].Extent.Text.Trim() -ne '$presentationProven = $false' -or
        $loops[0].Body.Statements[2] -isnot [System.Management.Automation.Language.TryStatementAst]) {
        return $false
    }
    $statements = @($loops[0].Body.Statements[2].Body.Statements)
    return $statements.Count -eq 14 -and
        $statements[0].Extent.Text.Trim() -eq '$canary = Start-StatefulApp $layout $exe $repoRoot "$Name-$attempt"' -and
        $statements[1].Extent.Text.Trim() -eq '$runs.Add($canary)' -and
        $statements[2].Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -and
        $statements[7].Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -and
        $statements[8].Extent.Text.Trim() -eq '$stablePresentation = [Diagnostics.Stopwatch]::new()' -and
        $statements[10].Extent.Text.Trim() -eq '$presentationProven = $true' -and
        $statements[11].Extent.Text.Trim() -eq '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -and
        $statements[12].Extent.Text.Trim() -eq 'Close-StatefulHost $canaryHost $canary $deadline' -and
        $statements[13].Extent.Text.Trim() -eq 'return'
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
$highContrastClause = @($paletteHighContrastCallIf.Clauses | Where-Object {
    $_.Item1.Extent.Text.Trim() -eq '$ExerciseHighContrast' -and
        (Test-DirectStatementBlockChild -Node $paletteHighContrastOpenCalls[0] -StatementBlock $_.Item2)
})[0]
$highContrastOpenStatement = Get-DirectStatementBlockChild `
    -Node $paletteHighContrastOpenCalls[0] `
    -StatementBlock $highContrastClause.Item2
$highContrastOpenIndex = [Array]::IndexOf($highContrastClause.Item2.Statements, $highContrastOpenStatement)
if ($highContrastOpenIndex -lt 1 -or $highContrastOpenIndex -ge ($highContrastClause.Item2.Statements.Count - 1) -or
    $highContrastClause.Item2.Statements[$highContrastOpenIndex - 1].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
    $highContrastClause.Item2.Statements[$highContrastOpenIndex + 1].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)') {
    throw 'High Contrast palette opening and suppression checks must each receive a fresh deadline.'
}
$highContrastStabilityWaits = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Wait-InteractiveWin11Until' -and
        $node.Extent.Text -match "-Description '(?:stable High Contrast framebuffer|suppressed High Contrast theme preview)'"
}, $true))
if ($highContrastStabilityWaits.Count -ne 2 -or
    @($highContrastStabilityWaits | Where-Object {
        $_.Extent.Text -match [regex]::Escape('[TimeSpan]::FromSeconds(2)')
    }).Count -ne 2 -or
    @($highContrastStabilityWaits | Where-Object {
        $_.Extent.Text -match [regex]::Escape('$hcPresentation.Stable.Restart()')
    }).Count -ne 1 -or
    @($highContrastStabilityWaits | Where-Object {
        $_.Extent.Text -match [regex]::Escape("throw 'Theme preview changed terminal colors while High Contrast was active.'") -and
            $_.Extent.Text -match [regex]::Escape('$suppressedPreviewStable.Reset()') -and
            $_.Extent.Text -match [regex]::Escape('$previewPixel -band 0xFFFFFF) -eq $draculaRgb')
    }).Count -ne 1) {
    throw 'High Contrast theme preview must reject Dracula immediately and prove the original framebuffer stable for two seconds.'
}
$highContrastCloseCalls = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Close-StatefulHost $hcHost $hcRun $deadline'
}, $true))
$highContrastDismissCalls = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text.Trim() -eq 'Invoke-StatefulButton $hcHost 2004 $deadline $hcRun.Process'
}, $true))
$highContrastDismissWaits = @($paletteThemeAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Wait-InteractiveWin11Until' -and
        $node.Extent.Text -match "-Description 'High Contrast palette dismissal'" -and
        $node.Extent.Text -match 'Where-Object Id -eq 2002\)\.Count -eq 0'
}, $true))
if ($highContrastCloseCalls.Count -ne 1 -or $highContrastDismissCalls.Count -ne 1 -or
    $highContrastDismissWaits.Count -ne 1 -or
    -not (Test-DirectStatementBlockChild -Node $highContrastDismissCalls[0] -StatementBlock $highContrastClause.Item2) -or
    -not (Test-DirectStatementBlockChild -Node $highContrastDismissWaits[0] -StatementBlock $highContrastClause.Item2) -or
    $highContrastCloseCalls[0].Parent.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -or
    $highContrastCloseCalls[0].Parent.Parent.Parent -isnot [System.Management.Automation.Language.TryStatementAst] -or
    $highContrastCloseCalls[0].Parent.Parent.Statements.Count -ne 2 -or
    $highContrastCloseCalls[0].Parent.Parent.Statements[0].Extent.Text.Trim() -ne '$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)' -or
    $highContrastCloseCalls[0].Parent.Parent.Parent.CatchClauses.Count -ne 1 -or
    $highContrastCloseCalls[0].Parent.Parent.Parent.CatchClauses[0].Body.Extent.Text -notmatch
        '(?s)Stop-InteractiveWin11Process -Process \$hcRun\.Process -Contained.*?Write-Warning') {
    throw 'High Contrast palette dismissal must stay strict; only host-close timeout may become a warning after contained termination.'
}
if ($paletteThemeHarnessText -notmatch 'Invoke-StatefulButton \$hostHwnd 2004 \$deadline \$run\.Process' -or
    $paletteThemeHarnessText -match 'Invoke-Stateful(?:Posted)?Command \$\w+ 2004' -or
    $paletteThemeHarnessText -notmatch "-Description 'theme palette dismissal after preview'" -or
    $paletteThemeHarnessText -notmatch '\$themeListRect\.Top -lt \$themeSurfaceRect\.Top' -or
    $paletteThemeHarnessText -notmatch '(?s)Dracula preview rollback.*?\$deadline = \[DateTime\]::UtcNow\.AddSeconds\(\$TimeoutSeconds\)\s*\$edit = Open-ThemeQuery' -or
    $paletteThemeHarnessText -notmatch 'Dismissal changed persisted theme instead of reverting preview') {
    throw 'Palette theme validation must prove rich-result geometry and click the real Close button before framebuffer/config rollback.'
}
if ($win32RuntimeText -notmatch 'const list_y = overlay_y \+ self\.scaled\(host_overlay_height\);' -or
    $win32RuntimeText -notmatch 'paletteListTransition\(' -or
    $win32RuntimeText -notmatch 'if \(transition\.exposes_content\) \{\s*self\.invalidateVisibleSurfaceChildPaint\(true, false\);' -or
    $win32RuntimeText -notmatch 'const was_palette = self\.overlay_mode == \.command_palette;' -or
    $win32RuntimeText -notmatch 'if \(was_confirm or was_palette\)' -or
    $win32RuntimeText -notmatch 'palette_catalog_retained_config' -or
    $win32RuntimeText -notmatch 'palette_catalog_config_source' -or
    $win32RuntimeText -notmatch '(?s)other != self and other\.overlay_mode == \.command_palette.*?other\.hideOverlay\(\);' -or
    $win32RuntimeText -notmatch '(?s)\.config_change =>.*?if \(host\.overlay_mode == \.command_palette\) host\.hideOverlay\(\);.*?self\.config\.deinit\(\);\s*self\.config = config;' -or
    $win32RuntimeText -notmatch 'self\.refreshPalettePresentation\(\);' -or
    $win32RuntimeText -notmatch 'Make the window taller to show and activate palette results\.' -or
    $win32RuntimeText -notmatch 'DT_LEFT \| DT_VCENTER \| DT_SINGLELINE \| DT_NOPREFIX \| DT_END_ELLIPSIS') {
    throw 'Palette list layout must sit below feedback and repaint exposed terminal content on shrink, hide, and dismissal.'
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
Assert-CommandResolutionContract -Ast $sessionHarnessAst -Tokens $sessionHarnessTokens -Context $sessionRestoreHarness -ExpectedDotSources @(
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
    -Pattern '(?ms)env:\s+GH_TOKEN: \$\{\{ github\.token \}\}.*?CheckRemoteLatest.*?if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}.*?verify-published-release\.ps1 -Version \$env:RELEASE_VERSION.*?if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}' `
    -Description 'post-publish remote verification authenticates gh and fails closed on copy and byte/signature checks' `
    -Context "$releaseWorkflow :: Verify published release copy and assets"
Assert-TextContract `
    -Content (Get-YamlStepText -Content $releaseWorkflowText -Name 'Publish GitHub Release' -Source $releaseWorkflow) `
    -Pattern '(?ms)GH_REPO: \$\{\{ github\.repository \}\}.*?gh release view \$tag --repo \$env:GH_REPO.*?gh release create \$tag --repo \$env:GH_REPO.*?if \(\$LASTEXITCODE -ne 0\).*?gh release edit \$tag --repo \$env:GH_REPO.*?if \(\$LASTEXITCODE -ne 0\).*?gh release upload \$tag --repo \$env:GH_REPO.*?if \(\$LASTEXITCODE -ne 0\)' `
    -Description 'GitHub release commands pin the fork and mutations fail closed' `
    -Context "$releaseWorkflow :: Publish GitHub Release"
foreach ($contract in @(
    @{ Pattern = '\$expectedNames\.Count -ne 8'; Description = 'published verifier requires the exact eight-asset set' },
    @{ Pattern = '(?s)\$missing = .*?\$unexpected = .*?\$missing\.Count -gt 0 -or \$unexpected\.Count -gt 0.*?asset set mismatch'; Description = 'published verifier rejects missing and unexpected assets' },
    @{ Pattern = '(?s)\$digest -notmatch.*?\$actualHash -ne \$digest\.Substring\(7\)\.ToLowerInvariant\(\).*?digest mismatch'; Description = 'published verifier compares downloaded bytes with GitHub SHA-256 digests' },
    @{ Pattern = 'SequenceEqual'; Description = 'published verifier preserves byte-identical legacy x64 checksum alias' },
    @{ Pattern = '(?s)\$checksums\.Count -ne \$expectedChecksumNames\.Count.*?\$checksums\.Contains\(\$_\).*?\$checksums\[\$name\] -ne \$actualHash'; Description = 'published verifier enforces exact checksum names, count, and hashes' },
    @{ Pattern = '(?s)\$signatureEvidence\.Add\(\(Assert-PublishedSignature.*?Setup \$architecture.*?foreach \(\$relativePath.*?\$signatureEvidence\.Add\(\(Assert-PublishedSignature.*?\$signatureEvidence\.Count -ne 8'; Description = 'published verifier validates exactly eight downloaded Authenticode signatures' },
    @{ Pattern = '(?s)Get-CertificateSpkiSha256.*?\$AllowedPins -notcontains \$pin.*?\$thumbprints\.Count -ne 1 -or \$pins\.Count -ne 1'; Description = 'published verifier binds every downloaded signer to one updater SPKI' },
    @{ Pattern = "winghostty/winghostty\.com'.*?winghostty/winghostty\.exe'.*?winghostty/ghostty-vt\.dll'"; Description = 'published verifier checks every packaged runtime PE for both architectures' }
    @{ Pattern = '(?s)finally \{.*?\$createdTempDirectory.*?\$DownloadDirectory\.StartsWith\(\$tempRoot.*?for \(\$attempt = 1; \$attempt -le 3; \$attempt\+\+\).*?Remove-Item .*?-ErrorAction Stop.*?Write-Warning'; Description = 'published verifier guards, retries, and reports temporary cleanup' }
)) {
    Assert-TextContract `
        -Content $publishedReleaseVerifierText `
        -Pattern $contract.Pattern `
        -Description $contract.Description `
        -Context $publishedReleaseVerifier
}
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
    -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow) `
    -Pattern '(?m)^\s*timeout-minutes:\s+60\s*$' `
    -Description 'full interactive validation has enough job budget for the accessibility soak' `
    -Context "$testWorkflow :: windows-interactive"
$interactiveRunStep = Get-YamlStepText `
    -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow) `
    -Name 'Run interactive Win11 composite' `
    -Source "$testWorkflow :: windows-interactive"
Assert-TextContract `
    -Content $interactiveRunStep `
    -Pattern '(?ms)env:\s+ZIG_GLOBAL_CACHE_DIR: \$\{\{ runner\.temp \}\}\\zig-global-cache\s+ZIG_LOCAL_CACHE_DIR: \$\{\{ runner\.temp \}\}\\zig-local-cache' `
    -Description 'interactive builds use clean per-job Zig caches' `
    -Context "$testWorkflow :: windows-interactive :: Run interactive Win11 composite"
$interactiveRunScript = Get-YamlLiteralRunScript `
    -Content $interactiveRunStep `
    -Source "$testWorkflow :: windows-interactive :: Run interactive Win11 composite"
$expectedInteractiveRunScript = @'
$ErrorActionPreference = 'Stop'
$quick = '${{ github.event_name }}' -eq 'pull_request'
if ($quick) {
  ./test/windows/interactive-win11-pr-smoke.ps1 -Rebuild -ResetState
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  ./test/windows/flagship/Invoke-InteractiveWin11.ps1 -Rebuild -ResetState -IncludeForegroundHarness
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-accessibility.ps1 -ResetState -TimeoutSeconds 120 -IdleSoakSeconds 600
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-palette-theme.ps1 -ResetState -ExerciseHighContrast
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-session-restore.ps1 -ResetState
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
'@
$expectedInteractiveRunScript = ($expectedInteractiveRunScript -replace '\r\n?', "`n").TrimEnd([char[]]"`n")
if ($interactiveRunScript -cne $expectedInteractiveRunScript) {
    throw 'Interactive workflow run script drifted from its exact fail-closed source snapshot.'
}
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
foreach ($paletteActionHarness in @($newTabHarness, $undoHarness, $resizeHarness)) {
    $tokens = $null
    $errors = $null
    $paletteActionAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $paletteActionHarness,
        [ref] $tokens,
        [ref] $errors
    )
    if ($errors.Count -ne 0) {
        throw "Palette action harness does not parse: $paletteActionHarness ($($errors[0].Message))"
    }
    $paletteActionFunctions = @($paletteActionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-CommandPaletteAction'
    }, $true))
    if ($paletteActionFunctions.Count -ne 1) {
        throw "Palette action harness must define exactly one Invoke-CommandPaletteAction helper: $paletteActionHarness"
    }
    $paletteActionBody = $paletteActionFunctions[0].Body
    $paletteSubmitCalls = @($paletteActionBody.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-InteractiveWin11Message' -and
            $node.Extent.Text -match '-Hwnd\s+\$edit\.Hwnd' -and
            $node.Extent.Text -match '-Message\s+(?:\$wmChar|0x0102)' -and
            $node.Extent.Text -match '-WParam\s+\(\[UIntPtr\]\(\[uint64\](?:\$vkReturn|0x0D)\)\)' -and
            $node.Extent.Text -match '-Description\s+[''\"]palette WM_CHAR Enter[''\"]'
    }, $true))
    if ($paletteSubmitCalls.Count -ne 1) {
        throw "Palette action helper must submit exactly once through WM_CHAR Enter on its edit HWND: $paletteActionHarness"
    }
    if ($paletteActionBody.Extent.Text -match '(?i)paletteConfirmCommandId|\b2003\b') {
        throw "Palette action helper cannot reference the hidden accept-button command ID: $paletteActionHarness"
    }
}
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'src\renderer\Thread.zig') `
    -Pattern '(?s)fn armCursorTimerIfDead\(.*?cursor_c\.state\(\) != \.dead.*?cursor_h\.run\(' `
    -Description 'cursor blink completion is rearmed only after libxev releases it'
Assert-WorkflowContractAbsent `
    -Path (Join-Path $repoRoot 'src\renderer\Thread.zig') `
    -Pattern '(?i)cursor_c_cancel|cursor_h\.(?:cancel|reset)\s*\(' `
    -Description 'cursor blink never cancels or resets an IOCP-owned completion'
Assert-WorkflowContract `
    -Path $interactivePrSmoke `
    -Pattern "(?ms)if \(\`$attempt -eq 2 -and \`$env:RUNNER_TEMP\).*?zig-global-cache-pr-smoke-retry-\`$PID.*?zig-local-cache-pr-smoke-retry-\`$PID" `
    -Description 'interactive PR smoke moves the retry to fresh runner-temp Zig cache directories'
Assert-WorkflowContract `
    -Path $interactivePrSmoke `
    -Pattern "(?ms)finally \{\s*\`$env:ZIG_GLOBAL_CACHE_DIR = \`$originalZigGlobalCache\s*\`$env:ZIG_LOCAL_CACHE_DIR = \`$originalZigLocalCache\s*\}" `
    -Description 'interactive PR smoke restores caller-provided Zig cache directories after rebuild retry'
Assert-WorkflowContract `
    -Path $accessibilityHarness `
    -Pattern '\[Math\]::Max\(90, \(\$TimeoutSeconds \* 3\) \+ \$IdleSoakSeconds \+ 60\)' `
    -Description 'accessibility harness budgets all three timeout-bearing launch phases plus idle soak'
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
