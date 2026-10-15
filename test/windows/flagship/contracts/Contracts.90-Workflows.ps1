Invoke-ContractTable -Contracts @(
    @{
        File = (Join-Path $repoRoot '.github\dependabot.yml')
        Pattern = '(?m)package-ecosystem:\s*"npm"'
        Kind = 'WorkflowAbsent'
        Description = 'the dependency-free static site has no stale npm dependency updater'
    }
    @{
        File = $testWorkflow
        Content = {
            $testWorkflowText
        }
        Pattern = '(?ms)^on:\s+push:\s+branches: \[main\]\s+pull_request: \{\}'
        Kind = 'Text'
        Description = 'push CI is main-only while pull-request CI remains enabled'
    }
    @{
        File = "$testWorkflow :: windows site checks"
        Content = {
            (Get-YamlJobText -Content $testWorkflowText -Name 'windows' -Source $testWorkflow)
        }
        Pattern = '(?ms)- name: Deterministic site asset check.*?node scripts/build-site-assets\.mjs --check.*?if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}.*?- name: Site unit tests.*?node --test "site/tests/\*\*/\*\.test\.mjs".*?if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}'
        Kind = 'Text'
        Description = 'dependency-free site asset and recursively discovered unit-test gates run in fail-closed order'
    }
    @{
        File = "$testWorkflow :: Remote release copy checks"
        Content = {
            (Get-YamlStepBlock -Content $testWorkflowText -Name 'Remote release copy checks' -Source $testWorkflow)
        }
        Pattern = '(?ms)env:\s+GH_TOKEN: \$\{\{ github\.token \}\}.*?CheckRemoteLatest'
        Kind = 'Text'
        Description = 'scheduled remote verification authenticates gh'
    }
    @{
        File = "$testWorkflow :: windows :: Setup Zig"
        Content = {
            (Get-YamlStepBlock `
                    -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows' -Source $testWorkflow) `
                    -Name 'Setup Zig' `
                    -Source "$testWorkflow :: windows")
        }
        Pattern = '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false'
        Kind = 'Text'
        Description = 'hosted Windows tests cannot restore failed Zig build caches'
    }
    @{
        File = "$testWorkflow :: windows-portable-smoke :: Setup Zig"
        Content = {
            (Get-YamlStepBlock `
                    -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-portable-smoke' -Source $testWorkflow) `
                    -Name 'Setup Zig' `
                    -Source "$testWorkflow :: windows-portable-smoke")
        }
        Pattern = '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false'
        Kind = 'Text'
        Description = 'portable smoke cannot restore failed Zig build caches'
    }
    @{
        File = "$releaseWorkflow :: windows-release :: Setup Zig"
        Content = {
            (Get-YamlStepBlock `
                    -Content (Get-YamlJobText -Content $releaseWorkflowText -Name 'windows-release' -Source $releaseWorkflow) `
                    -Name 'Setup Zig' `
                    -Source "$releaseWorkflow :: windows-release")
        }
        Pattern = '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false'
        Kind = 'Text'
        Description = 'release builds cannot restore failed Zig build caches'
    }
    @{
        File = "$testWorkflow :: windows-interactive :: Setup Zig"
        Content = {
            (Get-YamlStepBlock `
                    -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow) `
                    -Name 'Setup Zig' `
                    -Source "$testWorkflow :: windows-interactive")
        }
        Pattern = '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false'
        Kind = 'Text'
        Description = 'ephemeral interactive retries cannot restore failed Zig build caches'
    }
    @{
        File = "$testWorkflow :: windows-interactive"
        Content = {
            (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow)
        }
        Pattern = '(?m)^\s*timeout-minutes:\s+60\s*$'
        Kind = 'Text'
        Description = 'full interactive validation has enough job budget for the accessibility soak'
    }
)
if (Test-Path -LiteralPath (Join-Path $repoRoot '.github\workflows\clean-artifacts.yml')) {
    throw 'The archived artifact-cleanup workflow must remain deleted; upload retention owns cleanup.'
}
$prettierIgnoreText = Get-Content -LiteralPath (Join-Path $repoRoot '.prettierignore') -Raw
$typosConfigText = Get-Content -LiteralPath (Join-Path $repoRoot 'typos.toml') -Raw
if ($prettierIgnoreText -match '\*\*/\*\.xcassets/' -or
    $typosConfigText -match '(?m)^\[type\.po\]$') {
    throw 'Removed macOS asset-catalog and gettext ignore rules must not return.'
}
$releaseWindowsJob = Get-YamlJobText `
    -Content $releaseWorkflowText `
    -Name 'windows-release' `
    -Source $releaseWorkflow
if ($releaseWindowsJob -match 'FORCE_JAVASCRIPT_ACTIONS_TO_NODE24') {
    throw 'The x64 release job must not carry the ARM64 JavaScript action runtime workaround.'
}
$windowsArmWorkflow = Join-Path $repoRoot '.github\workflows\windows-arm64.yml'
$windowsArmWorkflowText = Get-Content -LiteralPath $windowsArmWorkflow -Raw
$windowsHostedJob = Get-YamlJobText -Content $testWorkflowText -Name 'windows' -Source $testWorkflow
foreach ($shellCase in @(
        @{ Name = 'PowerShell shell integration tests (PowerShell 7)'; Shell = 'pwsh'; Script = 'powershell-shell-integration' },
        @{ Name = 'PowerShell shell integration tests (Windows PowerShell 5.1)'; Shell = 'powershell'; Script = 'powershell-shell-integration' },
        @{ Name = 'Bash shell integration tests (Git Bash)'; Shell = 'pwsh'; Script = 'bash-shell-integration' }
    )) {
    $step = Get-YamlStepBlock -Content $windowsHostedJob -Name $shellCase.Name -Source $testWorkflow
    # Step fields sit at eight spaces; the lines of a `run: |` body sit deeper,
    # so a script name in a comment or string there does not count.
    if ($step -notmatch ('(?m)^ {8}shell: ' + $shellCase.Shell + '\s*$') -or
        $step -notmatch ('(?m)^ {8}run: \./test/windows/' + $shellCase.Script + '\.ps1\s*$')) {
        throw "Missing behavioural shell-integration coverage: $($shellCase.Name)"
    }
}
$hintsStep = Get-YamlStepBlock -Content $windowsHostedJob -Name 'Interactive hints contract checks' -Source $testWorkflow
if ($hintsStep -notmatch 'run: ./test/windows/Test-InteractiveWin11HintsContracts\.ps1') {
    throw 'Hosted CI must run the hints contracts.'
}
$libVtJob = Get-YamlJobText -Content $testWorkflowText -Name 'windows-lib-vt' -Source $testWorkflow
$libVtStep = Get-YamlStepBlock -Content $libVtJob -Name 'Run libghostty-vt and C API tests' -Source $testWorkflow
if ($libVtStep -notmatch 'run: zig build test-lib-vt -Demit-lib-vt=true --summary all') {
    throw 'CI must run the separate libghostty-vt graph and report its test count.'
}
# Required coverage must execute and propagate failures at both YAML levels.
# The experimental ConPTY job is intentionally excluded from this contract.
function Test-MandatoryWorkflowCoverage {
    param(
        [Parameter(Mandatory)] [string] $JobText,
        [Parameter(Mandatory)] [string[]] $StepNames
    )

    if ($JobText -match '(?m)^    [''"]?(?:if|continue-on-error)[''"]?[ \t]*:') { return $false }
    foreach ($name in $StepNames) {
        $step = Get-YamlStepBlock -Content $JobText -Name $name -Source 'required coverage'
        if ($step -match '(?m)^        [''"]?(?:if|continue-on-error)[''"]?[ \t]*:') { return $false }
    }
    return $true
}
$coverageMutationCount = 0
foreach ($coverage in @(
        @{ Job = $windowsHostedJob; Steps = @(
                'PowerShell shell integration tests (PowerShell 7)',
                'PowerShell shell integration tests (Windows PowerShell 5.1)',
                'Bash shell integration tests (Git Bash)',
                'Cmd and Clink integration tests (portable)',
                'Interactive hints contract checks'
            ) },
        @{ Job = $libVtJob; Steps = @('Run libghostty-vt and C API tests') }
    )) {
    if (-not (Test-MandatoryWorkflowCoverage -JobText $coverage.Job -StepNames $coverage.Steps)) {
        throw 'Required shell, hints, and library coverage must be unconditional and fail closed.'
    }
    foreach ($setting in @(
            'if: false', 'continue-on-error: true',
            "'if': false", "'continue-on-error': true",
            '"if": false', '"continue-on-error": true',
            'if : false', 'continue-on-error : true'
        )) {
        $mutations = @($coverage.Job.Replace('    steps:', "    $setting`n    steps:"))
        foreach ($name in $coverage.Steps) {
            $mutations += $coverage.Job.Replace("      - name: $name", "      - name: $name`n        $setting")
        }
        foreach ($mutation in $mutations) {
            if (Test-MandatoryWorkflowCoverage -JobText $mutation -StepNames $coverage.Steps) {
                throw "Required coverage accepted a disabled or ignored mutation: $setting"
            }
            $coverageMutationCount++
        }
    }
}
Write-Host "Required workflow coverage: $coverageMutationCount/$coverageMutationCount disabling mutations rejected"
$conptyJob = Get-YamlJobText -Content $testWorkflowText -Name 'windows-conpty-probes' -Source $testWorkflow
$conptyStep = Get-YamlStepBlock -Content $conptyJob -Name 'Run opt-in ConPTY transport and key input probes' -Source $testWorkflow
if ($conptyJob -notmatch '(?m)^    continue-on-error: true\s*$' -or
    $conptyJob -notmatch '(?m)^    timeout-minutes: 20\s*$' -or
    $conptyStep -notmatch '(?m)^        timeout-minutes: 15\s*$' -or
    $conptyStep -notmatch '-Dtest-filter=ConPTY --summary all') {
    throw 'Experimental ConPTY coverage must be optional, bounded, and retain the child dispatch test.'
}
foreach ($probeVariable in @('NOCTTY_RUN_CONPTY_TRANSPORT_TEST', 'NOCTTY_CONPTY_TRANSPORT_PROBE', 'NOCTTY_CONPTY_KEY_INPUT_PROBE')) {
    if ($conptyStep -notmatch ($probeVariable + ": '1'")) { throw "Missing scoped probe variable: $probeVariable" }
    if ($windowsHostedJob -match $probeVariable) { throw 'ConPTY probe variables must stay out of the required Windows job.' }
}
$armTestStep = Get-YamlStepBlock -Content $windowsArmWorkflowText -Name 'Run ARM64 Zig tests' -Source $windowsArmWorkflow
$armBuildStep = Get-YamlStepBlock -Content $windowsArmWorkflowText -Name 'Build and package ARM64 binaries' -Source $windowsArmWorkflow
if ($armTestStep -notmatch '-Dcustom-shaders=true.*?--summary all' -or
    $armBuildStep -notmatch '-Optimize ReleaseFast') {
    throw 'ARM64 CI must test shaders and compile the release optimization mode.'
}
$releaseTests = Get-YamlStepBlock -Content $releaseWindowsJob -Name 'Run full test suite' -Source $releaseWorkflow
if ($releaseTests -notmatch '-Dcustom-shaders=true --summary all') {
    throw 'Release tests must use shipped shader support and report the test count.'
}
if ($releaseWindowsJob -notmatch 'choco install innosetup --version=6\.7\.1 --no-progress -y') {
    throw 'The installer compiler version must remain pinned.'
}
Invoke-ContractTable -Contracts @(
    @{
        File = $windowsArmWorkflow
        Content = {
            $windowsArmWorkflowText
        }
        Pattern = 'FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: "true"'
        Kind = 'Text'
        Description = 'the JavaScript action runtime workaround remains scoped to Windows ARM64'
    }
)
$interactiveRunStep = Get-YamlStepBlock `
    -Content (Get-YamlJobText -Content $testWorkflowText -Name 'windows-interactive' -Source $testWorkflow) `
    -Name 'Run interactive Win11 composite' `
    -Source "$testWorkflow :: windows-interactive"
Invoke-ContractTable -Contracts @(
    @{
        File = "$testWorkflow :: windows-interactive :: Run interactive Win11 composite"
        Content = {
            $interactiveRunStep
        }
        Pattern = '(?ms)env:\s+ZIG_GLOBAL_CACHE_DIR: \$\{\{ runner\.temp \}\}\\zig-global-cache\s+ZIG_LOCAL_CACHE_DIR: \$\{\{ runner\.temp \}\}\\zig-local-cache'
        Kind = 'Text'
        Description = 'interactive builds use clean per-job Zig caches'
    }
)
$interactiveRunScript = Get-YamlLiteralRunScript `
    -Content $interactiveRunStep `
    -Source "$testWorkflow :: windows-interactive :: Run interactive Win11 composite"
$expectedInteractiveRunScript = @'
$ErrorActionPreference = 'Stop'
$quick = '${{ github.event_name }}' -eq 'pull_request'
if ($quick) {
  ./test/windows/interactive-win11-pr-smoke.ps1 -Rebuild -ResetState
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-shaders.ps1 -Rebuild -ResetState
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-shader-pacing.ps1 -ResetState
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  ./test/windows/flagship/Invoke-InteractiveWin11.ps1 -Rebuild -ResetState -IncludeForegroundHarness
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-shaders.ps1 -Rebuild -ResetState
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  ./test/windows/interactive-win11-shader-pacing.ps1 -ResetState
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
Invoke-ContractTable -Contracts @(
    @{
        File = $shaderHarness
        Pattern = 'zig build -Demit-exe=true -Dcustom-shaders=true'
        Kind = 'Workflow'
        Description = 'shader harness rebuilds the executable with custom shader support'
    }
    @{
        File = $shaderHarness
        Pattern = "(?s)custom shaders: enabled.*?R -ge 220.*?G -le 40.*?B -ge 220"
        Kind = 'Workflow'
        Description = 'shader harness verifies both the compiled capability and visible magenta output'
    }
    @{
        File = $shaderHarness
        Pattern = '(?ms)Show-StatefulHost \$hostHwnd\r?\n\s+\$graphics\.CopyFromScreen.*?Show-StatefulHost \$hostHwnd\r?\n\s+\$argb = Get-StatefulPixel'
        Kind = 'Workflow'
        Description = 'shader harness refocuses the host immediately before both screen-pixel captures'
    }
    @{
        File = "$testWorkflow :: Verify default source-build shader mode"
        Content = {
            (Get-YamlStepBlock -Content $testWorkflowText -Name 'Verify default source-build shader mode' -Source $testWorkflow)
        }
        Pattern = '(?ms)noctty\.com \+version.*?Build Config.*?custom shaders: disabled'
        Kind = 'Text'
        Description = 'default source build executes the CLI and reports custom shaders disabled'
    }
    @{
        File = (Join-Path $repoRoot 'scripts\dev-windows.cmd')
        Pattern = '(?s)if "%ZIG_GLOBAL_CACHE_DIR%"=="" set "ZIG_GLOBAL_CACHE_DIR=.*?if "%ZIG_LOCAL_CACHE_DIR%"=="" set "ZIG_LOCAL_CACHE_DIR='
        Kind = 'Workflow'
        Description = 'Windows bootstrap preserves caller-provided Zig cache isolation'
    }
    @{
        File = (Join-Path $repoRoot 'scripts\dev-windows.ps1')
        Pattern = '(?s)IsNullOrWhiteSpace\(\$env:ZIG_GLOBAL_CACHE_DIR\).*?IsNullOrWhiteSpace\(\$env:ZIG_LOCAL_CACHE_DIR\)'
        Kind = 'Workflow'
        Description = 'PowerShell Windows bootstrap preserves caller-provided Zig cache isolation'
    }
    @{
        File = "$testWorkflow :: Upload interactive evidence"
        Content = {
            (Get-YamlStepBlock -Content $testWorkflowText -Name 'Upload interactive evidence' -Source $testWorkflow)
        }
        Pattern = '(?ms)include-hidden-files: true.*?github\.workspace.*?\.sandbox/win11/\*\*/logs/\*\*'
        Kind = 'Text'
        Description = 'interactive evidence upload includes the actual hidden sandbox log tree'
    }
    @{
        File = $interactivePrSmoke
        Pattern = "(?ms)if \(\`$harness -eq 'interactive-win11-undo\.ps1'\) \{\s*\`$harnessArgs \+= @\('-TimeoutSeconds', '35'\)\s*\}"
        Kind = 'Workflow'
        Description = 'interactive PR smoke preserves the documented undo harness timeout'
    }
    @{
        File = $interactivePrSmoke
        Pattern = "(?ms)for \(\`$attempt = 1; \`$attempt -le 2; \`$attempt\+\+\).*?\`$cacheHydrationMiss = \`$buildText -match 'FileNotFound' -and \`$buildText -match 'zig-global-cache'.*?retrying once with fresh temp cache directories"
        Kind = 'Workflow'
        Description = 'interactive PR smoke retries exactly the transient Zig cache hydration miss'
    }
    @{
        File = $interactivePrSmoke
        Pattern = "(?ms)\`$originalErrorActionPreference = \`$ErrorActionPreference\s*try \{\s*\`$ErrorActionPreference = 'Continue'\s*\`$buildOutput = @\(& \(Join-Path \`$repoRoot 'scripts\\dev-windows\.cmd'\) zig build -Demit-exe=true 2>&1\)\s*\`$buildExitCode = \`$LASTEXITCODE\s*\}\s*finally \{\s*\`$ErrorActionPreference = \`$originalErrorActionPreference\s*\}"
        Kind = 'Workflow'
        Description = 'interactive PR smoke captures native build stderr without bypassing exit-code retry logic on PowerShell 7.0'
    }
)
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
Invoke-ContractTable -Contracts @(
    @{
        File = (Join-Path $repoRoot 'src\renderer\Thread.zig')
        Pattern = '(?s)fn armCursorTimerIfDead\(.*?cursor_c\.state\(\) != \.dead.*?cursor_h\.run\('
        Kind = 'Workflow'
        Description = 'cursor blink completion is rearmed only after libxev releases it'
    }
    @{
        File = (Join-Path $repoRoot 'src\renderer\Thread.zig')
        Pattern = '(?i)cursor_c_cancel|cursor_h\.(?:cancel|reset)\s*\('
        Kind = 'WorkflowAbsent'
        Description = 'cursor blink never cancels or resets an IOCP-owned completion'
    }
    @{
        File = $interactivePrSmoke
        Pattern = "(?ms)if \(\`$attempt -eq 2 -and \`$env:RUNNER_TEMP\).*?zig-global-cache-pr-smoke-retry-\`$PID.*?zig-local-cache-pr-smoke-retry-\`$PID"
        Kind = 'Workflow'
        Description = 'interactive PR smoke moves the retry to fresh runner-temp Zig cache directories'
    }
    @{
        File = $interactivePrSmoke
        Pattern = "(?ms)finally \{\s*\`$env:ZIG_GLOBAL_CACHE_DIR = \`$originalZigGlobalCache\s*\`$env:ZIG_LOCAL_CACHE_DIR = \`$originalZigLocalCache\s*\}"
        Kind = 'Workflow'
        Description = 'interactive PR smoke restores caller-provided Zig cache directories after rebuild retry'
    }
    @{
        File = $accessibilityHarness
        Pattern = '\[Math\]::Max\(90, \(\$TimeoutSeconds \* 3\) \+ \$IdleSoakSeconds \+ 60\)'
        Kind = 'Workflow'
        Description = 'accessibility harness budgets all three timeout-bearing launch phases plus idle soak'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\[DateTimeOffset\]::TryParse\('
        Kind = 'Workflow'
        Description = 'accessibility evidence timestamp is semantically validated'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\$provenance\.runner_name -ne \$result\.environment\.runner_name'
        Kind = 'Workflow'
        Description = 'runner provenance is bound to the interactive result'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\$provenance\.runner_name -ne \$interactiveJob\[0\]\.runner_name'
        Kind = 'Workflow'
        Description = 'runner provenance is bound to the GitHub job'
    }
    @{
        File = $accessibilityChecker
        Pattern = '(?ms)gh run download \$runId.*?--repo \$repository.*?\$provenance\.repository -ne \$repository'
        Kind = 'Workflow'
        Description = 'accessibility artifact download and provenance validation use the configured repository'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\$provenanceRunAttempt -ne \[int\]\$run\.run_attempt'
        Kind = 'Workflow'
        Description = 'runner provenance is bound to the GitHub run attempt'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\[string\]\$provenance\.user -match .*SYSTEM'
        Kind = 'Workflow'
        Description = 'service-account runner provenance is rejected'
    }
    @{
        File = $runnerProvenanceChecker
        Pattern = "(?m)^\`$minimumRunnerVersion = \[version\]'2\.327\.1'\s*$"
        Kind = 'Workflow'
        Description = 'interactive evidence enforces the upload-artifact runner floor'
    }
    @{
        File = $runnerProvenanceChecker
        Pattern = '(?m)^\s*\[version\]\s+\$MinimumRunnerVersion\b'
        Kind = 'WorkflowAbsent'
        Description = 'interactive runner floor cannot be lowered by a parameter'
    }
    @{
        File = $accessibilityChecker
        Pattern = "(?m)^\s*\`$minimumRunnerVersion = \[version\]'2\.327\.1'\s*$"
        Kind = 'Workflow'
        Description = 'accessibility evidence pins the upload-artifact runner floor'
    }
    @{
        File = $accessibilityChecker
        Pattern = '(?m)^#requires -Version 7\.1\s*$'
        Kind = 'Workflow'
        Description = 'accessibility evidence requires PowerShell 7.1 or newer'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\$provenance = Get-Content -LiteralPath \$provenancePaths\[0\]\.FullName -Raw \| ConvertFrom-Json -NoEnumerate'
        Kind = 'Workflow'
        Description = 'accessibility evidence preserves the JSON root kind'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\$provenance\.GetType\(\) -ne \[System\.Management\.Automation\.PSCustomObject\]'
        Kind = 'Workflow'
        Description = 'accessibility evidence requires runner provenance to be a JSON object'
    }
    @{
        File = $accessibilityChecker
        Pattern = "schema_version -ne 'noctty\.interactive-runner-provenance\.v1'"
        Kind = 'Workflow'
        Description = 'accessibility evidence rejects unsupported runner provenance schemas'
    }
    @{
        File = $runnerProvenanceChecker
        Pattern = 'NOCTTY_EXPECTED_CHECKOUT_SHA'
        Kind = 'Workflow'
        Description = 'interactive provenance can verify an exact PR head checkout instead of only GITHUB_SHA'
    }
    @{
        File = $runnerProvenanceChecker
        Pattern = 'commit = \$expectedCommit'
        Kind = 'Workflow'
        Description = 'interactive provenance records the exact expected tested commit'
    }
    @{
        File = $testWorkflow
        Pattern = 'ref: \$\{\{ github\.event_name == ''pull_request'' && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        Kind = 'Workflow'
        Description = 'Test workflow checkouts use the immutable PR head SHA for pull requests'
    }
    @{
        File = $testWorkflow
        Pattern = '(?ms)^permissions:\s+contents: read\s+concurrency:'
        Kind = 'Workflow'
        Description = 'Test workflow grants its GitHub token read-only repository contents access'
    }
    @{
        File = $testWorkflow
        Pattern = '(?ms)- name: Setup Node\.js\s+uses: actions/setup-node@2028fbc5c25fe9cf00d9f06a71cc4710d4507903.*?node-version: 22.*?- name: Deterministic site asset check.*?node scripts/build-site-assets\.mjs --check.*?if \(\$LASTEXITCODE -ne 0\).*?- name: Site unit tests.*?node --test "site/tests/\*\*/\*\.test\.mjs".*?if \(\$LASTEXITCODE -ne 0\)'
        Kind = 'Workflow'
        Description = 'site checks use a pinned supported Node version and retain fail-closed command guards'
    }
    @{
        File = (Join-Path $repoRoot '.github\workflows\windows-arm64.yml')
        Pattern = 'ref: \$\{\{ github\.event_name == ''pull_request'' && github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}'
        Kind = 'Workflow'
        Description = 'ARM64 workflow checkout uses the immutable PR head SHA for pull requests'
    }
    @{
        File = (Join-Path $repoRoot '.github\workflows\windows-arm64.yml')
        Pattern = '(?ms)Run ARM64 CLI smoke.*?Build Config.*?custom shaders: enabled.*?Run packaged ARM64 CLI smoke.*?Build Config.*?custom shaders: enabled'
        Kind = 'Workflow'
        Description = 'native and packaged ARM64 CLI smokes retain version output and shader capability coverage'
    }
    @{
        File = $runnerProvenanceChecker
        Pattern = '\$runnerVersion -lt \$minimumRunnerVersion'
        Kind = 'Workflow'
        Description = 'interactive evidence rejects outdated runners'
    }
    @{
        File = $accessibilityChecker
        Pattern = '\$provenanceRunnerVersion -lt \$minimumRunnerVersion'
        Kind = 'Workflow'
        Description = 'accessibility evidence rejects outdated interactive runners'
    }
)
$objectRoot = ConvertFrom-Json -InputObject '{"value":1}' -NoEnumerate
$arrayRoot = ConvertFrom-Json -InputObject '[{"value":1}]' -NoEnumerate
if ($objectRoot.GetType() -ne [System.Management.Automation.PSCustomObject] -or
    $arrayRoot.GetType() -eq [System.Management.Automation.PSCustomObject]) {
    throw 'PowerShell JSON root-kind preservation does not satisfy the evidence contract.'
}
