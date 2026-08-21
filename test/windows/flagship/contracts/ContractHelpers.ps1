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

function Assert-ZigTestsDiscoveredAndRun {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [hashtable] $Sources,
        [Parameter(Mandatory)] [string[]] $ExpectedNames,
        [Parameter(Mandatory)] [string] $Filter
    )

    $declarations = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Sources.GetEnumerator()) {
        foreach ($match in [regex]::Matches(
            $entry.Value,
            '(?m)^test "(?<name>[^"\r\n]+)" \{$'
        )) {
            [void]$declarations.Add([pscustomobject]@{
                Path = $entry.Key
                Name = $match.Groups['name'].Value
            })
        }
    }
    foreach ($expectedName in $ExpectedNames) {
        $declMatches = @($declarations | Where-Object { $_.Name -ceq $expectedName })
        if ($declMatches.Count -ne 1) {
            throw "Expected exactly one Zig test declaration '$expectedName'; found $($declMatches.Count)."
        }
    }

    Invoke-ZigFixture `
        -RepoRoot $RepoRoot `
        -Filter $Filter
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

function Get-YamlStepBlock {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Source
    )

    $pattern = '(?ms)^      - name:[ \t]+' + [regex]::Escape($Name) + '[ \t]*\r?\n.*?(?=^      -[ \t]+|^    \S[^\r\n]*:\s*(?:#.*)?$|^  \S[^\r\n]*:\s*(?:#.*)?$|\z)'
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one workflow step '$Name'; found $($matches.Count): $Source"
    }
    $matches[0].Value
}

function Assert-DeferredZigFixtureExecution {
    param(
        [Parameter(Mandatory)] [string] $WorkflowText,
        [Parameter(Mandatory)] [string] $Source
    )

    $windowsJob = Get-YamlJobText `
        -Content $WorkflowText `
        -Name 'windows' `
        -Source $Source
    $flagshipStep = Get-YamlStepBlock `
        -Content $windowsJob `
        -Name 'Flagship verification contract checks' `
        -Source "$Source :: windows"
    $setupStep = Get-YamlStepBlock `
        -Content $windowsJob `
        -Name 'Setup Zig' `
        -Source "$Source :: windows"
    $fullSuiteStep = Get-YamlStepBlock `
        -Content $windowsJob `
        -Name 'Full Zig test suite' `
        -Source "$Source :: windows"
    $conditionalStepPattern = '(?m)^        (?:if|continue-on-error):'
    $flagshipIndex = $windowsJob.IndexOf($flagshipStep, [StringComparison]::Ordinal)
    $setupIndex = $windowsJob.IndexOf($setupStep, [StringComparison]::Ordinal)
    $fullSuiteIndex = $windowsJob.IndexOf($fullSuiteStep, [StringComparison]::Ordinal)

    if ($flagshipStep -notmatch
            '(?m)^        run: \./test/windows/flagship/Test-VerificationContracts\.ps1\s*$' -or
        $setupStep -notmatch
            '(?m)^        uses: mlugg/setup-zig@[^\s]+(?:\s+#.*)?\s*$' -or
        $setupStep -match $conditionalStepPattern -or
        $fullSuiteStep -notmatch
            '(?m)^        run: zig build test -Demit-test-exe=true\s*$' -or
        $fullSuiteStep -match $conditionalStepPattern -or
        $flagshipIndex -lt 0 -or
        $setupIndex -le $flagshipIndex -or
        $fullSuiteIndex -le $setupIndex) {
        throw 'The early flagship contract must defer unavailable fixture execution to the same Windows job''s mandatory Setup Zig and full Zig test suite.'
    }
}

function Test-FlagshipZigFixtureExecutionEnabled {
    return $env:GITHUB_ACTIONS -ne 'true'
}

function Invoke-ZigFixture {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Filter
    )

    if (-not (Test-FlagshipZigFixtureExecutionEnabled)) {
        Write-Host "ZIG-FIXTURE-EXECUTION-SKIPPED [$Filter]: deferred to mandatory full Zig suite in the same Windows job."
        return
    }
    $filterArgument = "-Dtest-filter=$Filter"
    $zigExitCode = 1
    Push-Location $RepoRoot
    try {
        & (Join-Path $RepoRoot 'scripts\dev-windows.cmd') `
            zig build test $filterArgument
        $zigExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($zigExitCode -ne 0) {
        throw "Zig semantic fixture '$Filter' failed with exit code $zigExitCode."
    }
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

function ConvertTo-CanonicalText {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    (($Text -replace "`r`n", "`n") -replace "`r", "`n").
        TrimEnd([char[]]"`n")
}

function Get-CanonicalTextSha256 {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $normalized = ConvertTo-CanonicalText -Text $Text
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
        return (([BitConverter]::ToString($sha256.ComputeHash($bytes))) -replace
            '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-YamlStepEnvelopeDigest {
    param(
        [Parameter(Mandatory)] [string] $StepText,
        [Parameter(Mandatory)] [string] $ExpectedSha256
    )

    (Get-CanonicalTextSha256 -Text $StepText) -ceq $ExpectedSha256
}

function Get-NamedVariableAssignments {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Name
    )

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is
                [System.Management.Automation.Language.VariableExpressionAst] -and
            (($node.Left.VariablePath.UserPath -split ':')[-1]) -ceq $Name
    }, $true))
}

function Test-ExactVariableUseSet {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast[]] $ExpectedContainers
    )

    $actualUses = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (($node.VariablePath.UserPath -split ':')[-1]) -ceq $Name
    }, $true))
    $expectedUses = @(
        foreach ($container in $ExpectedContainers) {
            $container.FindAll({
                param($node)
                $node -is
                    [System.Management.Automation.Language.VariableExpressionAst] -and
                    (($node.VariablePath.UserPath -split ':')[-1]) -ceq $Name
            }, $true)
        }
    )
    if ($actualUses.Count -ne $expectedUses.Count) { return $false }
    foreach ($expected in $expectedUses) {
        if (@($actualUses | Where-Object {
            [object]::ReferenceEquals($_, $expected)
        }).Count -ne 1) {
            return $false
        }
    }
    return $true
}

function Test-NamedReleasePreflightSplat {
    param(
        [Parameter(Mandatory)] [string] $ScriptText,
        [Parameter(Mandatory)] [hashtable] $ExpectedExpressions,
        [Parameter(Mandatory)] [string] $ExpectedScriptSha256
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $ScriptText,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { return $false }
    if (@($ast.FindAll({
        param($node)
        Test-ForbiddenScriptMutationNode `
            -Node $node `
            -StrictReleaseContract
    }, $true)).Count -ne 0) {
        return $false
    }
    if (@($ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
            return $false
        }
        $name = $node.GetCommandName()
        return $null -ne $name -and
            ($name -split '\\')[-1] -in @(
                'New-Item', 'ni',
                'Get-ChildItem', 'dir', 'gci', 'ls',
                'Get-Content', 'cat', 'gc', 'type'
            )
    }, $true)).Count -ne 0) {
        return $false
    }

    $commands = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            (($node.GetCommandName() -replace '\\', '/') -eq
                './scripts/release-preflight.ps1')
    }, $true))
    if ($commands.Count -ne 1 -or $commands[0].CommandElements.Count -ne 2) {
        return $false
    }
    $splat = $commands[0].CommandElements[1]
    if ($splat -isnot
            [System.Management.Automation.Language.VariableExpressionAst] -or
        -not $splat.Splatted) {
        return $false
    }
    $splatName = ($splat.VariablePath.UserPath -split ':')[-1]

    $assignments = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is
                [System.Management.Automation.Language.VariableExpressionAst] -and
            (($node.Left.VariablePath.UserPath -split ':')[-1]) -eq $splatName
    }, $true))
    if ($assignments.Count -ne 1 -or
        $assignments[0].Right -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $assignments[0].Right.Expression -isnot
            [System.Management.Automation.Language.HashtableAst]) {
        return $false
    }

    $actualExpressions = @{}
    foreach ($pair in $assignments[0].Right.Expression.KeyValuePairs) {
        if ($pair.Item1 -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
        $key = [string]$pair.Item1.Value
        if ($actualExpressions.ContainsKey($key)) { return $false }
        $actualExpressions[$key] = $pair.Item2.Extent.Text.Trim()
    }
    if ($actualExpressions.Count -ne $ExpectedExpressions.Count) {
        return $false
    }
    foreach ($key in $ExpectedExpressions.Keys) {
        if (-not $actualExpressions.ContainsKey($key) -or
            $actualExpressions[$key] -cne $ExpectedExpressions[$key]) {
            return $false
        }
    }

    $variableUses = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (($node.VariablePath.UserPath -split ':')[-1]) -eq $splatName
    }, $true))
    $assignmentUses = @($variableUses | Where-Object {
        [object]::ReferenceEquals($_, $assignments[0].Left)
    })
    $invocationUses = @($variableUses | Where-Object {
        [object]::ReferenceEquals($_, $splat)
    })
    $allSplats = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Splatted
    }, $true))
    return $variableUses.Count -eq 2 -and
        $assignmentUses.Count -eq 1 -and
        $invocationUses.Count -eq 1 -and
        $allSplats.Count -eq 1 -and
        [object]::ReferenceEquals($allSplats[0], $splat) -and
        (Get-CanonicalTextSha256 -Text $ScriptText) -ceq
            $ExpectedScriptSha256
}

function Assert-NamedReleasePreflightSplat {
    param(
        [Parameter(Mandatory)] [string] $StepText,
        [Parameter(Mandatory)] [hashtable] $ExpectedExpressions,
        [Parameter(Mandatory)] [string] $ExpectedScriptSha256,
        [Parameter(Mandatory)] [string] $Context
    )

    $scriptText = Get-YamlLiteralRunScript `
        -Content $StepText `
        -Source $Context
    if (-not (Test-NamedReleasePreflightSplat `
        -ScriptText $scriptText `
        -ExpectedExpressions $ExpectedExpressions `
        -ExpectedScriptSha256 $ExpectedScriptSha256)) {
        throw "Release preflight workflow must use one immutable exact named splat: $Context"
    }
}

function Test-ReleaseInteractiveResultSelectionContract {
    param([Parameter(Mandatory)] [string] $ScriptText)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput(
        $ScriptText,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { return $false }

    $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
        'winghostty-release-selection-' + [Guid]::NewGuid().ToString('N')
    )
    $priorRunnerTemp = $env:RUNNER_TEMP
    $priorRepository = $env:GH_REPOSITORY
    $priorLastExitCode = $global:LASTEXITCODE
    $script:releaseSelectionRunJson = $null
    $script:releaseSelectionGitCalls = 0
    $script:releaseSelectionGhCalls = 0
    $script:releaseSelectionDownloadCalls = 0
    $script:releaseSelectionHostCalls = 0

    function git {
        $script:releaseSelectionGitCalls++
        $global:LASTEXITCODE = 0
        'abc123'
    }
    function gh {
        $script:releaseSelectionGhCalls++
        $global:LASTEXITCODE = 0
        if ($args.Count -ge 2 -and $args[0] -eq 'run' -and $args[1] -eq 'list') {
            return $script:releaseSelectionRunJson
        }
        if ($args.Count -ge 1 -and $args[0] -eq 'api') {
            return (@{
                jobs = @(
                    @{
                        name = 'Windows 11 Interactive Composite'
                        conclusion = 'success'
                    }
                )
            } | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($args.Count -ge 2 -and $args[0] -eq 'run' -and $args[1] -eq 'download') {
            $script:releaseSelectionDownloadCalls++
            return
        }
        throw "Unexpected gh probe arguments: $($args -join ' ')"
    }
    function Write-Host {
        $script:releaseSelectionHostCalls++
    }

    function Write-SelectionResultFixture {
        param(
            [Parameter(Mandatory)] [string] $Directory,
            [Parameter(Mandatory)] [string] $ScenarioId,
            [Parameter(Mandatory)] [string] $Status
        )
        [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
        $payloadPath = Join-Path $Directory 'payload.bin'
        [System.IO.File]::WriteAllBytes($payloadPath, [byte[]](1, 3, 5, 7))
        $payloadHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $result = [ordered]@{
            scenario_id = $ScenarioId
            status = $Status
            implementation_commit = 'abc123'
            workflow_run_id = '123'
            artifacts = @(
                [ordered]@{
                    path = 'payload.bin'
                    sha256 = $payloadHash
                }
            )
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $Directory 'result.json'),
            ($result | ConvertTo-Json -Depth 8 -Compress)
        )
    }

    function Invoke-SelectionFixture {
        param([Parameter(Mandatory)] [bool] $DuplicateComposite)
        $artifactRoot = Join-Path $probeRoot 'flagship-release-evidence-123'
        if ([System.IO.Directory]::Exists($artifactRoot)) {
            [System.IO.Directory]::Delete($artifactRoot, $true)
        }
        [System.IO.Directory]::CreateDirectory($artifactRoot) | Out-Null
        Write-SelectionResultFixture -Directory (Join-Path $artifactRoot 'valid') -ScenarioId 'windows.interactive-win11.composite' -Status 'pass'
        if ($DuplicateComposite) {
            Write-SelectionResultFixture -Directory (Join-Path $artifactRoot 'duplicate') -ScenarioId 'windows.interactive-win11.composite' -Status 'pass'
        } else {
            Write-SelectionResultFixture -Directory (Join-Path $artifactRoot 'unrelated') -ScenarioId 'windows.interactive-win11.other' -Status 'fail'
            $malformedDirectory = Join-Path $artifactRoot 'malformed'
            [System.IO.Directory]::CreateDirectory($malformedDirectory) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $malformedDirectory 'result.json'), '{')
        }
        $script:releaseSelectionRunJson = @(
            @{
                databaseId = 123
                headSha = 'abc123'
                conclusion = 'success'
                status = 'completed'
            }
        ) | ConvertTo-Json -Depth 4 -Compress
        $script:releaseSelectionGitCalls = 0
        $script:releaseSelectionGhCalls = 0
        $script:releaseSelectionDownloadCalls = 0
        $script:releaseSelectionHostCalls = 0
        $message = $null
        try {
            & ([scriptblock]::Create($ScriptText))
        }
        catch {
            $message = $_.Exception.Message
        }
        return [pscustomobject]@{
            Message = $message
            GitCalls = $script:releaseSelectionGitCalls
            GhCalls = $script:releaseSelectionGhCalls
            DownloadCalls = $script:releaseSelectionDownloadCalls
            HostCalls = $script:releaseSelectionHostCalls
        }
    }

    try {
        [System.IO.Directory]::CreateDirectory($probeRoot) | Out-Null
        $env:RUNNER_TEMP = $probeRoot
        $env:GH_REPOSITORY = 'amanthanvi/winghostty'
        $single = Invoke-SelectionFixture -DuplicateComposite $false
        $duplicate = Invoke-SelectionFixture -DuplicateComposite $true
        return $null -eq $single.Message -and
            $single.GitCalls -eq 1 -and
            $single.GhCalls -ge 3 -and
            $single.DownloadCalls -eq 1 -and
            $single.HostCalls -eq 1 -and
            $duplicate.Message -like 'Release SHA abc123 has no successful interactive Win11 Test run*' -and
            $duplicate.GitCalls -eq 1 -and
            $duplicate.GhCalls -ge 3 -and
            $duplicate.DownloadCalls -eq 1 -and
            $duplicate.HostCalls -eq 0
    }
    finally {
        $env:RUNNER_TEMP = $priorRunnerTemp
        $env:GH_REPOSITORY = $priorRepository
        $global:LASTEXITCODE = $priorLastExitCode
        if ([System.IO.Directory]::Exists($probeRoot)) {
            [System.IO.Directory]::Delete($probeRoot, $true)
        }
        Remove-Variable -Scope Script -Name releaseSelectionRunJson, releaseSelectionGitCalls, releaseSelectionGhCalls, releaseSelectionDownloadCalls, releaseSelectionHostCalls -ErrorAction SilentlyContinue
    }
}

function Get-LogicalAndLeaves {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)

    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $Node.Operator -eq [System.Management.Automation.Language.TokenKind]::And) {
        Get-LogicalAndLeaves -Node $Node.Left
        Get-LogicalAndLeaves -Node $Node.Right
        return
    }
    return ,$Node
}

function Get-SinglePipelineExpression {
    param([System.Management.Automation.Language.Ast] $Node)

    if ($Node -isnot [System.Management.Automation.Language.PipelineAst] -or
        $Node.PipelineElements.Count -ne 1 -or
        $Node.PipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst]) {
        return $null
    }
    return $Node.PipelineElements[0].Expression
}

function Test-ExactExpressionSet {
    param(
        [System.Management.Automation.Language.Ast] $Root,
        [Parameter(Mandatory)] [string[]] $Expected
    )

    if ($null -eq $Root) { return $false }
    $actual = @(
        Get-LogicalAndLeaves -Node $Root |
            ForEach-Object { ($_.Extent.Text -replace '\s+', ' ').Trim() }
    )
    return $actual.Count -eq $Expected.Count -and
        @($Expected | Where-Object { $actual -cnotcontains $_ }).Count -eq 0
}

function Test-CommandArgumentPair {
    param(
        [Parameter(Mandatory)] [string[]] $Elements,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )

    $matchCount = 0
    for ($index = 0; $index -lt ($Elements.Count - 1); $index++) {
        if ($Elements[$index] -ceq $Name -and
            $Elements[$index + 1] -ceq $Value) {
            $matchCount++
        }
    }
    return $matchCount -eq 1 -and
        @($Elements | Where-Object { $_ -ceq $Name }).Count -eq 1
}

function Test-ReleaseInteractiveSuccessPredicates {
    param(
        [Parameter(Mandatory)] [string] $ScriptText,
        [Parameter(Mandatory)] [string] $ExpectedScriptSha256
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $ScriptText,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { return $false }
    if (@($ast.FindAll({
        param($node)
        Test-ForbiddenScriptMutationNode -Node $node -StrictReleaseContract
    }, $true)).Count -ne 0) {
        return $false
    }
    if (@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Splatted
    }, $true)).Count -ne 0) {
        return $false
    }

    # This body is a deliberate reviewed-source snapshot. The canonical SHA is
    # the invariant; duplicating every local, statement count, and source order
    # as AST shape added no coverage and made harmless refactors fail twice.
    return (Get-CanonicalTextSha256 -Text $ScriptText) -ceq
        $ExpectedScriptSha256
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

function Test-DirectNamedBlockChild {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [System.Management.Automation.Language.NamedBlockAst] $NamedBlock
    )

    $ancestor = $Node.Parent
    while ($null -ne $ancestor -and
        $ancestor -isnot [System.Management.Automation.Language.NamedBlockAst]) {
        if ($ancestor -isnot [System.Management.Automation.Language.PipelineAst] -and
            $ancestor -isnot
                [System.Management.Automation.Language.AssignmentStatementAst] -and
            $ancestor -isnot
                [System.Management.Automation.Language.CommandExpressionAst]) {
            return $false
        }
        $ancestor = $ancestor.Parent
    }
    [object]::ReferenceEquals($ancestor, $NamedBlock)
}

function Get-MemberExpressionName {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.MemberExpressionAst] $Node)

    return ([string] $Node.Member.Value).Trim()
}

function Get-NamedFunctionDefinitions {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Name
    )

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
    }, $true))
}

function Get-NamedCommands {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Name
    )

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq $Name
    }, $true))
}

function Get-NamedMemberExpressions {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Name,
        [switch] $InvocationOnly
    )

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
            (-not $InvocationOnly -or
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
            (Get-MemberExpressionName -Node $node) -eq $Name
    }, $true))
}

function Get-ExpressionRootVariableName {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)

    while ($Node -is [System.Management.Automation.Language.MemberExpressionAst] -or
        $Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        if ($Node -is [System.Management.Automation.Language.MemberExpressionAst]) {
            $Node = $Node.Expression
        } else {
            $pipelineElements = @($Node.Pipeline.PipelineElements)
            if ($pipelineElements.Count -ne 1 -or
                $pipelineElements[0] -isnot
                    [System.Management.Automation.Language.CommandExpressionAst]) {
                return ''
            }
            $Node = $pipelineElements[0].Expression
        }
    }
    if ($Node -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
        return ''
    }
    return ($Node.VariablePath.UserPath -split ':')[-1]
}

function Test-CommandHasStringArgument {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.CommandAst] $Command,
        [Parameter(Mandatory)] [string] $Value
    )

    return @($Command.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value -eq $Value
    }, $true)).Count -gt 0
}

function Get-CommandParameterArgument {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.CommandAst] $Command,
        [Parameter(Mandatory)] [string] $Name
    )

    $elements = @($Command.CommandElements)
    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst] -or
            $element.ParameterName -ne $Name) {
            continue
        }
        if ($null -ne $element.Argument) { return $element.Argument }
        if (($index + 1) -lt $elements.Count -and
            $elements[$index + 1] -isnot
                [System.Management.Automation.Language.CommandParameterAst]) {
            return $elements[$index + 1]
        }
        return $null
    }
    return $null
}

function Get-ContainingStatementBlock {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)

    while ($null -ne $Node -and
        $Node -isnot [System.Management.Automation.Language.StatementBlockAst]) {
        $Node = $Node.Parent
    }
    return $Node
}

function Get-VariableExpressionName {
    param([System.Management.Automation.Language.Ast] $Node)

    if ($Node -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
        return ''
    }
    return ($Node.VariablePath.UserPath -split ':')[-1]
}

function Test-StaticMemberReference {
    param(
        [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [string] $TypeName,
        [Parameter(Mandatory)] [string] $MemberName
    )

    return $Node -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $Node.Static -and
        (Get-MemberExpressionName -Node $Node) -eq $MemberName -and
        $Node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $Node.Expression.TypeName.FullName -eq $TypeName
}

function Test-DirectJoinPathNameExpression {
    param(
        [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [string] $ParentVariable,
        [AllowEmptyString()] [string] $ParentMember = '',
        [Parameter(Mandatory)] [string] $ChildVariable,
        [Parameter(Mandatory)] [string] $ChildSuffix,
        [Parameter(Mandatory)] [ValidateSet('Expandable', 'Format')] [string] $Style
    )

    if ($Node -isnot [System.Management.Automation.Language.PipelineAst] -or
        $Node.PipelineElements.Count -ne 1 -or
        $Node.PipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandAst]) {
        return $false
    }
    $command = $Node.PipelineElements[0]
    $elements = @($command.CommandElements)
    if ($command.GetCommandName() -ne 'Join-Path' -or $elements.Count -ne 3) {
        return $false
    }
    $parent = $elements[1]
    if ([string]::IsNullOrEmpty($ParentMember)) {
        if ((Get-VariableExpressionName -Node $parent) -ne $ParentVariable) {
            return $false
        }
    } elseif ($parent -isnot
            [System.Management.Automation.Language.MemberExpressionAst] -or
        (Get-ExpressionRootVariableName -Node $parent) -ne $ParentVariable -or
        (Get-MemberExpressionName -Node $parent) -ne $ParentMember) {
        return $false
    }

    $child = $elements[2]
    if ($Style -eq 'Expandable') {
        return $child -is
                [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            $child.Value -ceq ('$' + $ChildVariable + $ChildSuffix) -and
            $child.NestedExpressions.Count -eq 1 -and
            (Get-VariableExpressionName -Node $child.NestedExpressions[0]) -eq
                $ChildVariable
    }
    if ($child -isnot [System.Management.Automation.Language.ParenExpressionAst] -or
        $child.Pipeline.PipelineElements.Count -ne 1 -or
        $child.Pipeline.PipelineElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst]) {
        return $false
    }
    $format = $child.Pipeline.PipelineElements[0].Expression
    return $format -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $format.Operator -eq [System.Management.Automation.Language.TokenKind]::Format -and
        $format.Left -is
            [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $format.Left.Value -ceq ('{0}' + $ChildSuffix) -and
        (Get-VariableExpressionName -Node $format.Right) -eq $ChildVariable
}

function Test-InjectiveHarnessRunNameExpression {
    param([System.Management.Automation.Language.Ast] $Node)

    if ($Node -isnot [System.Management.Automation.Language.IfStatementAst] -or
        $Node.Clauses.Count -ne 1 -or $null -eq $Node.ElseClause) {
        return $false
    }
    $conditionElements = @($Node.Clauses[0].Item1.PipelineElements)
    $thenStatements = @($Node.Clauses[0].Item2.Statements)
    $elseStatements = @($Node.ElseClause.Statements)
    if ($conditionElements.Count -ne 1 -or
        $conditionElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $thenStatements.Count -ne 1 -or $elseStatements.Count -ne 1) {
        return $false
    }
    $condition = $conditionElements[0].Expression
    if ($condition -isnot
            [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
        -not $condition.Static -or
        $condition.Expression -isnot
            [System.Management.Automation.Language.TypeExpressionAst] -or
        $condition.Expression.TypeName.FullName -ne 'string' -or
        (Get-MemberExpressionName -Node $condition) -ne 'IsNullOrWhiteSpace' -or
        $condition.Arguments.Count -ne 1 -or
        (Get-VariableExpressionName -Node $condition.Arguments[0]) -ne
            'ScenarioSlug') {
        return $false
    }
    $thenElements = @($thenStatements[0].PipelineElements)
    $elseElements = @($elseStatements[0].PipelineElements)
    if ($thenElements.Count -ne 1 -or $elseElements.Count -ne 1 -or
        $thenElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        $elseElements[0] -isnot
            [System.Management.Automation.Language.CommandExpressionAst] -or
        (Get-VariableExpressionName -Node $thenElements[0].Expression) -ne
            'ScriptName') {
        return $false
    }
    $format = $elseElements[0].Expression
    if ($format -isnot [System.Management.Automation.Language.BinaryExpressionAst] -or
        $format.Operator -ne [System.Management.Automation.Language.TokenKind]::Format -or
        $format.Left -isnot
            [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $format.Left.Value -cne '{0}-{1}' -or
        $format.Right -isnot [System.Management.Automation.Language.ArrayLiteralAst] -or
        $format.Right.Elements.Count -ne 2) {
        return $false
    }
    $scriptName = $format.Right.Elements[0]
    return $scriptName -is
            [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $scriptName.Static -and
        $scriptName.Expression -is
            [System.Management.Automation.Language.TypeExpressionAst] -and
        $scriptName.Expression.TypeName.FullName -eq 'System.IO.Path' -and
        (Get-MemberExpressionName -Node $scriptName) -eq
            'GetFileNameWithoutExtension' -and
        $scriptName.Arguments.Count -eq 1 -and
        (Get-VariableExpressionName -Node $scriptName.Arguments[0]) -eq
            'ScriptName' -and
        (Get-VariableExpressionName -Node $format.Right.Elements[1]) -eq
            'ScenarioSlug'
}

function Test-TextChangedHandlerOperation {
    param(
        [System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)] [ValidateSet('Add', 'Remove')] [string] $Operation
    )

    if ($Node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
        -not $Node.Static -or
        $Node.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or
        $Node.Expression.TypeName.FullName -ne
            'System.Windows.Automation.Automation' -or
        (Get-MemberExpressionName -Node $Node) -ne
            "${Operation}AutomationEventHandler") {
        return $false
    }
    $arguments = @($Node.Arguments)
    $expectedCount = if ($Operation -eq 'Add') { 4 } else { 3 }
    if ($arguments.Count -ne $expectedCount -or
        -not (Test-StaticMemberReference `
            -Node $arguments[0] `
            -TypeName 'System.Windows.Automation.TextPattern' `
            -MemberName 'TextChangedEvent') -or
        (Get-VariableExpressionName -Node $arguments[1]) -eq '' -or
        (Get-VariableExpressionName -Node $arguments[-1]) -eq '') {
        return $false
    }
    if ($Operation -eq 'Add' -and
        -not (Test-StaticMemberReference `
            -Node $arguments[2] `
            -TypeName 'System.Windows.Automation.TreeScope' `
            -MemberName 'Element')) {
        return $false
    }
    return $true
}

function Assert-NoUnreachableStatements {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Ast,
        [Parameter(Mandatory)] [string] $Context
    )

    $terminatorTypes = @(
        [System.Management.Automation.Language.ReturnStatementAst],
        [System.Management.Automation.Language.ThrowStatementAst],
        [System.Management.Automation.Language.ExitStatementAst],
        [System.Management.Automation.Language.BreakStatementAst],
        [System.Management.Automation.Language.ContinueStatementAst]
    )
    foreach ($block in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StatementBlockAst]
    }, $true))) {
        $statements = @($block.Statements)
        for ($index = 0; $index -lt ($statements.Count - 1); $index++) {
            $statementType = $statements[$index].GetType()
            if ($terminatorTypes -contains $statementType) {
                throw "Unreachable statement after $($statementType.Name): $Context"
            }
        }
    }
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

function Test-StrictReleaseForbiddenTypeName {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $TypeName)

    $typeName = ((($TypeName -split ',', 2)[0] -replace '\s', '')).ToLowerInvariant()
    return $typeName -in @(
        'powershell',
        'system.management.automation.powershell',
        'runspace',
        'runspacefactory',
        'initialsessionstate',
        'system.management.automation.runspaces.runspace',
        'system.management.automation.runspaces.runspacefactory',
        'system.management.automation.runspaces.initialsessionstate',
        'microsoft.csharp.csharpcodeprovider',
        'system.codedom.compiler.codedomprovider',
        'system.codedom.compiler.compilerparameters',
        'microsoft.codeanalysis.compilation',
        'microsoft.codeanalysis.csharp.csharpcompilation',
        'assembly',
        'reflection.assembly',
        'system.reflection.assembly',
        'system.reflection.emit.assemblybuilder',
        'system.reflection.emit.modulebuilder',
        'system.reflection.emit.typebuilder',
        'system.reflection.emit.methodbuilder',
        'system.reflection.emit.dynamicmethod'
    )
}

function Test-StrictReleaseForbiddenParameterName {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $ParameterName)

    if ($ParameterName.Length -eq 0) { return $false }
    if ($ParameterName -in @('ov', 'pv', 'ev', 'wv', 'iv')) {
        return $true
    }
    foreach ($canonicalName in @(
        'OutVariable',
        'PipelineVariable',
        'ErrorVariable',
        'WarningVariable',
        'InformationVariable',
        'MemberName'
    )) {
        if ($canonicalName.StartsWith(
            $ParameterName,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }
    }
    return $false
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

function Test-ForbiddenScriptMutationNode {
    param(
        [Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node,
        [switch] $StrictReleaseContract
    )

    if ($StrictReleaseContract -and
        $Node -is [System.Management.Automation.Language.CommandParameterAst] -and
        (Test-StrictReleaseForbiddenParameterName `
            -ParameterName $Node.ParameterName)) {
        return $true
    }
    if ($StrictReleaseContract -and
        $Node -is [System.Management.Automation.Language.TypeExpressionAst] -and
        (Test-StrictReleaseForbiddenTypeName -TypeName $Node.TypeName.FullName)) {
        return $true
    }
    if ($StrictReleaseContract -and
        $Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        (Test-StrictReleaseForbiddenTypeName -TypeName $Node.Value)) {
        return $true
    }
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
    if ($StrictReleaseContract -and
        $Node -is [System.Management.Automation.Language.VariableExpressionAst] -and
        (($Node.VariablePath.UserPath -split ':')[-1]) -in @(
            'ExecutionContext', 'PSCmdlet', 'Host', 'MyInvocation'
        )) {
        return $true
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
        if ($StrictReleaseContract -and
            $memberName -in @(
                'DefaultRunspace', 'SessionStateProxy',
                'SetVariable', 'GetVariable', 'RemoveVariable',
                'SessionState', 'PSVariable',
                'PSObject', 'PSBase', 'PSAdapted',
                'Members', 'Methods', 'Properties',
                'CompileAssemblyFromSource',
                'CompileAssemblyFromFile',
                'CompileAssemblyFromDom',
                'CreateCompiler', 'CreateProvider',
                'DefineDynamicAssembly', 'DefineDynamicModule',
                'DefineType', 'DefineMethod',
                'CreateType', 'CreateTypeInfo',
                'BakeByteArray', 'Emit',
                'Load', 'LoadFile', 'LoadFrom', 'UnsafeLoadFrom', 'LoadModule'
            )) {
            return $true
        }
        if ($StrictReleaseContract -and
            $Node -is
                [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $memberName -in @(
                'GetType',
                'GetMethod', 'GetMethods',
                'GetConstructor', 'GetConstructors',
                'GetField', 'GetFields',
                'GetProperty', 'GetProperties',
                'GetMember', 'GetMembers',
                'Invoke', 'InvokeMember', 'DynamicInvoke',
                'CreateDelegate', 'CreateInstance',
                'MakeGenericMethod', 'MakeGenericType'
            )) {
            return $true
        }
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
        if ($StrictReleaseContract -and
            $Node.InvocationOperator -in @(
                [System.Management.Automation.Language.TokenKind]::Ampersand,
                [System.Management.Automation.Language.TokenKind]::Dot
            )) {
            return $true
        }
        $leafName = if ($null -eq $name) { '' } else { ($name -split '\\')[-1] }
        return $leafName -in @('Set-Alias', 'sal', 'New-Alias', 'nal', 'Remove-Alias', 'ral', 'Import-Alias', 'ipal', 'Import-Module', 'ipmo', 'Import-PSSession', 'Add-PSSnapin', 'asnp', 'Remove-PSSnapin', 'rsnp', 'Invoke-Expression', 'iex') -or
            ($StrictReleaseContract -and
                $leafName -in @(
                    'Get-Command', 'gcm',
                    'Add-Type',
                    'Tee-Object', 'tee',
                    'Get-Member', 'gm',
                    'Get-Variable', 'gv',
                    'Set-Variable', 'sv', 'set',
                    'New-Variable', 'nv',
                    'Remove-Variable', 'rv',
                    'Clear-Variable', 'clv',
                    'Set-Item', 'si', 'Clear-Item', 'cli',
                    'Remove-Item', 'del', 'erase', 'rd', 'ri', 'rm', 'rmdir',
                    'Copy-Item', 'copy', 'cp', 'cpi',
                    'Move-Item', 'mi', 'move', 'mv',
                    'Rename-Item', 'ren', 'rni', 'Get-Item', 'gi',
                    'Set-ItemProperty', 'sp',
                    'New-ItemProperty',
                    'Clear-ItemProperty', 'clp',
                    'Remove-ItemProperty', 'rp',
                    'Copy-ItemProperty', 'cpp',
                    'Move-ItemProperty', 'mp',
                    'Rename-ItemProperty', 'rnp',
                    'Get-ItemProperty', 'gp',
                    'Get-ItemPropertyValue', 'gpv',
                    'Set-Content', 'sc', 'Add-Content', 'ac',
                    'Clear-Content', 'clc'
                )) -or
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

    $mutators = @($Ast.FindAll({ param($node) Test-ForbiddenScriptMutationNode -Node $node }, $true))
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

function Initialize-ContractFailureCollection {
    $script:ContractFailures = [Collections.Generic.List[object]]::new()
}

function Add-ContractFailure {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string] $SourceFragment,
        [string] $Detail
    )

    $script:ContractFailures.Add([pscustomobject]@{
        Description = $Description
        SourceFragment = $SourceFragment
        Detail = $Detail
    })
}

function Invoke-ContractTable {
    param([Parameter(Mandatory)] [object[]] $Contracts)

    foreach ($contract in $Contracts) {
        try {
            switch ($contract.Kind) {
                'Text' {
                    $content = if ($contract.Content -is [scriptblock]) {
                        [string](& $contract.Content)
                    }
                    else {
                        [string]$contract.Content
                    }
                    Assert-TextContract `
                        -Content $content `
                        -Pattern $contract.Pattern `
                        -Description $contract.Description `
                        -Context $contract.File
                }
                'Workflow' {
                    Assert-WorkflowContract `
                        -Path $contract.File `
                        -Pattern $contract.Pattern `
                        -Description $contract.Description
                }
                'WorkflowAbsent' {
                    Assert-WorkflowContractAbsent `
                        -Path $contract.File `
                        -Pattern $contract.Pattern `
                        -Description $contract.Description
                }
                default {
                    throw "Unknown contract kind: $($contract.Kind)"
                }
            }
        }
        catch {
            Add-ContractFailure `
                -Description ([string]$contract.Description) `
                -SourceFragment $script:CurrentContractFragment `
                -Detail $_.Exception.Message
        }
    }
}
