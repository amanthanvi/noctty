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
    [pscustomobject]@{ Reject = $false; Text = '$ec = Get-Variable ExecutionContext -ValueOnly; $ec.InvokeCommand.InvokeScript("1+1")' }
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
    [pscustomobject]@{ Reject = $false; Text = '$factory = "NocttyStatefulNative" -as [type]' }
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

$strictOnlyCommandProbes = @(
    'Get-Variable value',
    'gv value',
    'Set-Variable value 1',
    'sv value 1',
    'set value 1',
    'New-Variable value 1',
    'nv value 1',
    'Remove-Variable value',
    'rv value',
    'Clear-Variable value',
    'clv value',
    '. ./scripts/replace-release-evidence.ps1',
    '& Write-Output harmless'
)
$strictOnlyCommandProbes += @(
    @(
        'GetType',
        'GetMethod', 'GetMethods',
        'GetConstructor', 'GetConstructors',
        'GetField', 'GetFields',
        'GetProperty', 'GetProperties',
        'GetMember', 'GetMembers',
        'Invoke', 'InvokeMember', 'DynamicInvoke',
        'CreateDelegate', 'CreateInstance',
        'MakeGenericMethod', 'MakeGenericType'
    ) | ForEach-Object { '$value.' + $_ + '()' }
)
$strictOnlyCommandProbes += @(
    @(
        'powershell',
        'System.Management.Automation.PowerShell',
        'runspace',
        'runspacefactory',
        'initialsessionstate',
        'System.Management.Automation.Runspaces.Runspace',
        'System.Management.Automation.Runspaces.RunspaceFactory',
        'System.Management.Automation.Runspaces.InitialSessionState',
        'Microsoft.CSharp.CSharpCodeProvider',
        'Reflection.Assembly',
        'System.Reflection.Emit.AssemblyBuilder'
    ) | ForEach-Object {
        "'$_'"
        "[$_]::Name"
    }
)
$strictOnlyCommandProbes += @(
    @(
        'DefaultRunspace',
        'SessionStateProxy',
        'SetVariable',
        'GetVariable',
        'RemoveVariable'
    ) | ForEach-Object { '$value.' + $_ }
)
$strictOnlyCommandProbes += @(
    'Tee-Object -Variable value',
    'tee -Variable value',
    'Write-Output x -OutVariable value',
    'Write-Output x -ov value',
    'Write-Output x -OutV value',
    'Write-Output x -PipelineV value',
    'Write-Output x -ev value',
    'Write-Output x -wv value',
    'Write-Output x -iv value',
    'Write-Output x | ForEach-Object -MemberName ToString',
    'Write-Output x | % -M ToString',
    'gm -InputObject value',
    'Add-Type -TypeDefinition ''public class StrictProbe {}''',
    'Microsoft.PowerShell.Utility\Add-Type -TypeDefinition ''public class StrictProbe {}'''
)
$strictOnlyCommandProbes += @(
    @(
        'PSObject',
        'Properties',
        'CompileAssemblyFromSource',
        'DefineDynamicAssembly',
        'Load'
    ) | ForEach-Object { '$value.' + $_ }
)
$strictOnlyCommandProbes += @(
    '$PSCmdlet',
    '$Host',
    '$MyInvocation',
    '$value.SessionState',
    '$value.PSVariable'
)
foreach ($probeText in $strictOnlyCommandProbes) {
    $probeTokens = $null
    $probeErrors = $null
    $probeAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $probeText,
        [ref]$probeTokens,
        [ref]$probeErrors
    )
    if ($probeErrors.Count -ne 0) {
        throw "Strict command probe does not parse: $probeText"
    }
    $generalRejections = @($probeAst.FindAll({
        param($node)
        Test-ForbiddenScriptMutationNode -Node $node
    }, $true))
    $strictRejections = @($probeAst.FindAll({
        param($node)
        Test-ForbiddenScriptMutationNode `
            -Node $node `
            -StrictReleaseContract
    }, $true))
    if ($generalRejections.Count -ne 0 -or
        $strictRejections.Count -ne 1) {
        throw "Strict command mode contract failed: $probeText"
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
if ((Get-YamlStepBlock -Content $stepBoundaryProbe -Name 'Target' -Source 'step boundary probe') -match 'outside-step') {
    throw 'Workflow step extraction crossed a step boundary.'
}
$duplicateStepProbe = @'
      - name: Target
        run: first
      - name: Target
        run: second
'@
$duplicateStepRejected = $false
try {
    Get-YamlStepBlock `
        -Content $duplicateStepProbe `
        -Name 'Target' `
        -Source 'duplicate step probe' |
        Out-Null
}
catch {
    $duplicateStepRejected = $true
}
if (-not $duplicateStepRejected) {
    throw 'Workflow step extraction accepted an ambiguous duplicate name.'
}
$stepTailProbe = "      - name: Target`n        run: inside-step`n    env: # job-level tail`n      VALUE: outside-step"
if ((Get-YamlStepBlock -Content $stepTailProbe -Name 'Target' -Source 'step tail probe') -match 'outside-step') {
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
$script:FlagshipScenarioIds = $scenarioIds

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
$siteDeployWorkflow = Join-Path $repoRoot '.github\workflows\deploy-site.yml'
$siteAssetBuilder = Join-Path $repoRoot 'scripts\build-site-assets.mjs'
$sitePayloadBuilder = Join-Path $repoRoot 'scripts\build-site-payload.ps1'
$siteHeaderContract = Join-Path $repoRoot 'scripts\get-site-header-contract.ps1'
$siteDeploymentHeadGate = Join-Path $repoRoot 'scripts\require-site-deployment-head.ps1'
$cloudflarePagesVerifier = Join-Path $repoRoot 'scripts\verify-cloudflare-pages.ps1'
$siteHeaders = Join-Path $repoRoot 'site\_headers'
$siteReadme = Join-Path $repoRoot 'site\README.md'
$site404 = Join-Path $repoRoot 'site\404.html'
$siteIndex = Join-Path $repoRoot 'site\index.html'
$siteGitattributes = Join-Path $repoRoot '.gitattributes'
$accessibilityChecker = Join-Path $repoRoot 'scripts\check-accessibility-evidence.ps1'
$runnerProvenanceChecker = Join-Path $repoRoot 'test\windows\assert-interactive-runner.ps1'
$interactiveWin11Lib = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
$interactiveWin11WindowLib = Join-Path $repoRoot 'scripts\interactive-win11-window-lib.ps1'
$cliShellHarness = Join-Path $repoRoot 'test\windows\cli-shell-command.ps1'
$statefulWin11Lib = Join-Path $repoRoot 'test\windows\interactive-win11-stateful-lib.ps1'
$accessibilityHarness = Join-Path $repoRoot 'test\windows\interactive-win11-accessibility.ps1'
$imeCandidateHarness = Join-Path $repoRoot 'test\windows\interactive-win11-ime-candidate.ps1'
$sessionRestoreHarness = Join-Path $repoRoot 'test\windows\interactive-win11-session-restore.ps1'
$paletteThemeHarness = Join-Path $repoRoot 'test\windows\interactive-win11-palette-theme.ps1'
$newTabHarness = Join-Path $repoRoot 'test\windows\interactive-win11-new-tab.ps1'
$undoHarness = Join-Path $repoRoot 'test\windows\interactive-win11-undo.ps1'
$resizeHarness = Join-Path $repoRoot 'test\windows\interactive-win11-resize.ps1'
$keyInputHarness = Join-Path $repoRoot 'test\windows\interactive-win11-key-input.ps1'
$shellCommandLiveHarness = Join-Path $repoRoot 'test\windows\interactive-win11-shell-command-live.ps1'
$interactiveValidator = Join-Path $repoRoot 'test\windows\interactive-win11-validate.ps1'
$shaderHarness = Join-Path $repoRoot 'test\windows\interactive-win11-shaders.ps1'
$win32Runtime = Join-Path $repoRoot 'src\apprt\win32.zig'
$win32RuntimeModuleDirectory = Join-Path $repoRoot 'src\apprt\win32'
$win32RuntimeBaselineModuleNames = @(
    'chrome_layout.zig'
    'consts.zig'
    'gdi.zig'
    'gl_startup.zig'
    'input.zig'
    'labels.zig'
    'render_trace.zig'
    'sys.zig'
)
if (-not (Test-Path -LiteralPath $win32RuntimeModuleDirectory -PathType Container)) {
    throw "Required Win32 runtime module directory is missing: $win32RuntimeModuleDirectory"
}
$win32RuntimeModuleFiles = @(
    Get-ChildItem -LiteralPath $win32RuntimeModuleDirectory -Filter '*.zig' -File |
        Sort-Object Name |
        ForEach-Object FullName
)
if ($win32RuntimeModuleFiles.Count -eq 0) {
    throw "No Win32 runtime modules were found: $win32RuntimeModuleDirectory"
}
$win32RuntimeModuleNames = @($win32RuntimeModuleFiles | ForEach-Object {
    Split-Path -Leaf $_
})
$missingWin32RuntimeModuleNames = @($win32RuntimeBaselineModuleNames | Where-Object {
    $_ -cnotin $win32RuntimeModuleNames
})
if ($missingWin32RuntimeModuleNames.Count -ne 0) {
    throw "Required Win32 runtime modules are missing: $($missingWin32RuntimeModuleNames -join ', ')"
}
$win32RuntimeFiles = @($win32Runtime) + $win32RuntimeModuleFiles
$win32Settings = Join-Path $repoRoot 'src\apprt\win32_settings.zig'
$win32Theme = Join-Path $repoRoot 'src\apprt\win32_theme.zig'
$win32UiaWidgets = Join-Path $repoRoot 'src\apprt\win32_uia\widgets.zig'
$terminalOutputCapture = Join-Path $repoRoot 'src\termio\semantic_output_capture.zig'
$terminalStreamHandler = Join-Path $repoRoot 'src\termio\stream_handler.zig'
$terminalSemanticOutput = Join-Path $repoRoot 'src\terminal\semantic_output.zig'
$termioRuntime = Join-Path $repoRoot 'src\termio\Termio.zig'
$surfaceRuntime = Join-Path $repoRoot 'src\apprt\surface.zig'
$terminalAccessibility = Join-Path $repoRoot 'src\apprt\win32_terminal_accessibility.zig'
$interactivePrSmoke = Join-Path $repoRoot 'test\windows\interactive-win11-pr-smoke.ps1'
$releaseCopyChecker = Join-Path $repoRoot 'scripts\check-release-copy.ps1'
$releasePreflight = Join-Path $repoRoot 'scripts\release-preflight.ps1'
$publishedReleaseVerifier = Join-Path $repoRoot 'scripts\verify-published-release.ps1'
$windowsPackager = Join-Path $repoRoot 'scripts\package-windows.ps1'
$windowsBuildCapabilities = Join-Path $repoRoot 'scripts\windows-build-capabilities.ps1'
$signingTrust = Join-Path $repoRoot 'scripts\signing-trust.ps1'
$signingTrustTest = Join-Path $repoRoot 'scripts\test-signing-trust.ps1'
$releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflow -Raw
$readinessWorkflowText = Get-Content -LiteralPath $readinessWorkflow -Raw
$testWorkflowText = Get-Content -LiteralPath $testWorkflow -Raw
$siteDeployWorkflowText = Get-Content -LiteralPath $siteDeployWorkflow -Raw
$siteAssetBuilderText = Get-Content -LiteralPath $siteAssetBuilder -Raw
$sitePayloadBuilderText = Get-Content -LiteralPath $sitePayloadBuilder -Raw
$cloudflarePagesVerifierText = Get-Content -LiteralPath $cloudflarePagesVerifier -Raw
$siteHeadersText = Get-Content -LiteralPath $siteHeaders -Raw
$siteReadmeText = Get-Content -LiteralPath $siteReadme -Raw
$site404Text = Get-Content -LiteralPath $site404 -Raw
$siteIndexText = Get-Content -LiteralPath $siteIndex -Raw
$siteGitattributesText = Get-Content -LiteralPath $siteGitattributes -Raw
$interactiveWin11LibText = Get-Content -LiteralPath $interactiveWin11Lib -Raw
if (-not (Test-Path -LiteralPath $interactiveWin11WindowLib -PathType Leaf)) {
    throw "Required interactive Win11 window library is missing: $interactiveWin11WindowLib"
}
$interactiveWin11WindowLibText = Get-Content -LiteralPath $interactiveWin11WindowLib -Raw
$cliShellHarnessText = Get-Content -LiteralPath $cliShellHarness -Raw
$statefulWin11LibText = Get-Content -LiteralPath $statefulWin11Lib -Raw
$accessibilityHarnessText = Get-Content -LiteralPath $accessibilityHarness -Raw
$imeCandidateHarnessText = Get-Content -LiteralPath $imeCandidateHarness -Raw
$publishedReleaseVerifierText = Get-Content -LiteralPath $publishedReleaseVerifier -Raw
$windowsPackagerText = Get-Content -LiteralPath $windowsPackager -Raw
$signingTrustText = Get-Content -LiteralPath $signingTrust -Raw
$signingTrustTestText = Get-Content -LiteralPath $signingTrustTest -Raw
$win32RuntimeText = Get-Content -LiteralPath $win32Runtime -Raw
$win32RuntimeTexts = @($win32RuntimeFiles | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
        throw "Required Win32 runtime source is missing: $_"
    }
    Get-Content -LiteralPath $_ -Raw
})
$win32RuntimeAllText = $win32RuntimeTexts -join "`n"
$win32SettingsText = Get-Content -LiteralPath $win32Settings -Raw
$win32ThemeText = Get-Content -LiteralPath $win32Theme -Raw
$win32UiaWidgetsText = Get-Content -LiteralPath $win32UiaWidgets -Raw
$terminalOutputCaptureText = Get-Content -LiteralPath $terminalOutputCapture -Raw
$terminalStreamHandlerText = Get-Content -LiteralPath $terminalStreamHandler -Raw
$terminalSemanticOutputText = Get-Content -LiteralPath $terminalSemanticOutput -Raw
$termioRuntimeText = Get-Content -LiteralPath $termioRuntime -Raw
$surfaceRuntimeText = Get-Content -LiteralPath $surfaceRuntime -Raw
$terminalAccessibilityText = Get-Content -LiteralPath $terminalAccessibility -Raw
$sessionRestoreHarnessText = Get-Content -LiteralPath $sessionRestoreHarness -Raw
$paletteThemeHarnessText = Get-Content -LiteralPath $paletteThemeHarness -Raw
$newTabHarnessText = Get-Content -LiteralPath $newTabHarness -Raw
$undoHarnessText = Get-Content -LiteralPath $undoHarness -Raw
$keyInputHarnessText = Get-Content -LiteralPath $keyInputHarness -Raw
$shellCommandLiveHarnessText = Get-Content -LiteralPath $shellCommandLiveHarness -Raw
$interactiveValidatorText = Get-Content -LiteralPath $interactiveValidator -Raw
