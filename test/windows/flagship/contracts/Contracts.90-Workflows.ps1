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
        File = "$testWorkflow :: checks site checks"
        Content = {
            (Get-YamlJobText -Content $testWorkflowText -Name 'checks' -Source $testWorkflow)
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
$checksJob = Get-YamlJobText -Content $testWorkflowText -Name 'checks' -Source $testWorkflow
# Pin the interpreter, isolated invocation, event inputs and the one Phase 0b
# switch. Compare whole steps so extra arguments cannot override enforcement.
function Test-MigrationLintSteps {
    param([Parameter(Mandatory)] [string] $JobText)
    $python = Get-YamlStepBlock -Content $JobText -Name 'Setup Python' -Source 'migration lints'
    $controls = Get-YamlStepBlock -Content $JobText -Name 'Migration lint controls' -Source 'migration lints'
    $lints = Get-YamlStepBlock -Content $JobText -Name 'Migration diff lints' -Source 'migration lints'
    if ($JobText.IndexOf($python) -ge $JobText.IndexOf($controls) -or
        $JobText.IndexOf($controls) -ge $JobText.IndexOf($lints)) { return $false }
    $activeLines = @($python -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }) -join "`n"
    $expectedPython = @'
      - name: Setup Python
        uses: actions/setup-python@83679a892e2d95755f2dac6acb0bfd1e9ac5d548 # v6.1.0
        with:
          python-version: "3.13"
'@
    if ($activeLines -cne $expectedPython.TrimEnd()) { return $false }
    $activeLines = @($controls -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }) -join "`n"
    $expectedControls = @'
      - name: Migration lint controls
        shell: pwsh
        run: python -I ci/test_lints.py
'@
    if ($activeLines -cne $expectedControls.TrimEnd()) { return $false }
    $activeLines = @($lints -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' }) -join "`n"
    $expectedLints = @'
      - name: Migration diff lints
        shell: pwsh
        env:
          LINT_EVENT: ${{ github.event_name }}
          LINT_BASE: ${{ github.event.pull_request.base.sha }}
          LINT_HEAD: ${{ github.event.pull_request.head.sha || github.sha }}
          LINT_BEFORE: ${{ github.event.before }}
        run: python -I ci/run_lints.py --win32-mode report
'@
    # A separate activation PR just before Phase 0b flips this one token.
    return $activeLines -ceq $expectedLints.TrimEnd() -or
        $activeLines -ceq $expectedLints.Replace('--win32-mode report', '--win32-mode enforce').TrimEnd()
}
if (-not (Test-MigrationLintSteps -JobText $checksJob)) {
    throw 'Migration lints must pin Python 3.13, use isolated mode and exact event inputs, and retain the Phase 0b switch.'
}
function Assert-MigrationLintMutations {
    param([Parameter(Mandatory)] [string] $JobText)
    $selectedMode = [regex]::Match($JobText, '--win32-mode (report|enforce)').Groups[1].Value
    if (-not $selectedMode) { throw 'Migration lint mode was not found.' }
    $pythonStep = Get-YamlStepBlock -Content $JobText -Name 'Setup Python' -Source 'migration lint controls'
    $lintStep = Get-YamlStepBlock -Content $JobText -Name 'Migration diff lints' -Source 'migration lint controls'
    $mutations = @(
        $JobText.Replace('python -I ci/test_lints.py', 'python ci/test_lints.py'),
        $JobText.Replace('python -I ci/run_lints.py', 'python ci/run_lints.py'),
        $JobText.Replace('python-version: "3.13"', 'python-version: "3.14"'),
        $JobText.Replace('actions/setup-python@83679a892e2d95755f2dac6acb0bfd1e9ac5d548', 'actions/setup-python@v6'),
        $JobText.Replace('LINT_BASE: ${{ github.event.pull_request.base.sha }}', 'LINT_BASE: ${{ github.sha }}'),
        $JobText.Replace('LINT_HEAD: ${{ github.event.pull_request.head.sha || github.sha }}', 'LINT_HEAD: main'),
        $JobText.Replace('LINT_BEFORE: ${{ github.event.before }}', 'LINT_BEFORE: main'),
        $JobText.Replace("--win32-mode $selectedMode", "--win32-mode $selectedMode --win32-mode $selectedMode"),
        $JobText.Replace($pythonStep, '').Replace($lintStep, $lintStep + $pythonStep)
    )
    foreach ($mutation in $mutations) {
        if ($mutation -ceq $JobText -or (Test-MigrationLintSteps -JobText $mutation)) {
            throw 'Migration lint workflow accepted a weakening mutation.'
        }
    }
    return $mutations.Count
}
$lintMutationCount = 0
foreach ($migrationMode in @('report', 'enforce')) {
    $migrationVariant = [regex]::Replace($checksJob, '--win32-mode (report|enforce)', "--win32-mode $migrationMode")
    if (-not (Test-MigrationLintSteps -JobText $migrationVariant)) { throw 'Migration lint switch position failed its contract.' }
    $lintMutationCount += Assert-MigrationLintMutations -JobText $migrationVariant
}
Write-Host "Migration lint workflow: $lintMutationCount/$lintMutationCount weakening mutations rejected (report and enforce)"
foreach ($controlCase in @(
        @{ Name = 'Harness provenance and state controls (PowerShell 7)'; Shell = 'pwsh' },
        @{ Name = 'Harness provenance and state controls (Windows PowerShell 5.1)'; Shell = 'powershell' }
    )) {
    $step = Get-YamlStepBlock -Content $checksJob -Name $controlCase.Name -Source $testWorkflow
    if ($step -notmatch ('(?m)^ {8}shell: ' + $controlCase.Shell + '\s*$') -or
        $step -notmatch '(?m)^ {8}run: \|\r?\n {10}\./test/windows/interactive-win11-measure-contract\.ps1\r?\n {10}\./test/windows/interactive-win11-state-guard-contract\.ps1\s*$') {
        throw "Missing executable provenance and state controls: $($controlCase.Name)"
    }
}
foreach ($shellCase in @(
        @{ Name = 'PowerShell shell integration tests (PowerShell 7)'; Shell = 'pwsh'; Script = 'powershell-shell-integration' },
        @{ Name = 'PowerShell shell integration tests (Windows PowerShell 5.1)'; Shell = 'powershell'; Script = 'powershell-shell-integration' },
        @{ Name = 'Bash shell integration tests (Git Bash)'; Shell = 'pwsh'; Script = 'bash-shell-integration' }
    )) {
    $step = Get-YamlStepBlock -Content $checksJob -Name $shellCase.Name -Source $testWorkflow
    # Step fields sit at eight spaces; the lines of a `run: |` body sit deeper,
    # so a script name in a comment or string there does not count.
    if ($step -notmatch ('(?m)^ {8}shell: ' + $shellCase.Shell + '\s*$') -or
        $step -notmatch ('(?m)^ {8}run: \./test/windows/' + $shellCase.Script + '\.ps1\s*$')) {
        throw "Missing behavioural shell-integration coverage: $($shellCase.Name)"
    }
}
$hintsStep = Get-YamlStepBlock -Content $checksJob -Name 'Interactive hints contract checks' -Source $testWorkflow
if ($hintsStep -notmatch 'run: ./test/windows/Test-InteractiveWin11HintsContracts\.ps1') {
    throw 'Hosted CI must run the hints contracts.'
}
$pathFilterStep = Get-YamlStepBlock -Content $checksJob -Name 'CI script tests (path filter, gate, reports)' -Source $testWorkflow
if ($pathFilterStep -notmatch '(?m)^        run: \./test/windows/ci-scripts\.ps1\s*$') {
    throw 'The checks job must run the CI script tests.'
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
        @{ Job = $checksJob; Steps = @(
                'Flagship verification contract checks',
                'Setup Python',
                'Migration lint controls',
                'Migration diff lints',
                'PowerShell shell integration tests (PowerShell 7)',
                'PowerShell shell integration tests (Windows PowerShell 5.1)',
                'Harness provenance and state controls (PowerShell 7)',
                'Harness provenance and state controls (Windows PowerShell 5.1)',
                'Bash shell integration tests (Git Bash)',
                'Cmd and Clink integration tests (portable)',
                'Interactive hints contract checks',
                'CI script tests (path filter, gate, reports)'
            ) }
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
    if ($conptyStep -notmatch ($probeVariable + ': (?<quote>[''"])1\k<quote>')) { throw "Missing scoped probe variable: $probeVariable" }
    if ($testWorkflowText.Replace($conptyJob, '') -match $probeVariable) { throw 'ConPTY probe variables must stay out of the required Windows jobs.' }
}

# The compiled jobs are filtered by path. A filter may skip a job, never weaken
# it: the only job-level condition is the changes flag, nothing may ignore a
# failure, and its mandatory steps stay unconditional. The gate then requires
# exactly the jobs that carry a flag.
function Test-FilteredJobCoverage {
    param(
        [Parameter(Mandatory)] [string] $JobText,
        [Parameter(Mandatory)] [string] $Flag,
        [Parameter(Mandatory)] [string[]] $StepNames
    )

    if ($JobText -notmatch '(?m)^    needs: changes\s*$') { return $false }
    if ($JobText -notmatch ("(?m)^    if: needs\.changes\.outputs\.$Flag == 'true'\s*$")) { return $false }
    if ($JobText -match '(?m)^    [''"]?continue-on-error[''"]?[ \t]*:') { return $false }
    foreach ($name in $StepNames) {
        $step = Get-YamlStepBlock -Content $JobText -Name $name -Source 'filtered job coverage'
        if ($step -match '(?m)^        [''"]?(?:if|continue-on-error)[''"]?[ \t]*:') { return $false }
    }
    return $true
}
$filteredJobs = @(
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'tests'; Flag = 'tests'; Steps = @('Zig formatting', 'Full Zig test suite', 'Native Win32 compositor tests') }
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'bench'; Flag = 'bench'; Steps = @('Headless benchmark regression gates') }
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'build'; Flag = 'build'; Steps = @('Build executable', 'Verify default source-build shader mode', 'Verify source build stages the pinned ConPTY', 'Build without D3D11 beta') }
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'renderer-smoke'; Flag = 'renderer_smoke'; Steps = @('Build D3D11 lifecycle smoke tools', 'Hidden-desktop x64 WARP lifecycle smoke') }
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'cross-arm64'; Flag = 'cross_arm64'; Steps = @('Build ARM64 executable', 'Verify ARM64 source build stages the pinned ConPTY') }
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'windows-lib-vt'; Flag = 'lib_vt'; Steps = @('Run libghostty-vt and C API tests') }
    @{ Workflow = $testWorkflow; Text = $testWorkflowText; Job = 'windows-portable-smoke'; Flag = 'portable_smoke'; Steps = @('Run portable package CLI smoke') }
    @{ Workflow = $windowsArmWorkflow; Text = $windowsArmWorkflowText; Job = 'arm64-tests'; Flag = 'arm64_tests'; Steps = @('Verify native ARM64 runner', 'Run ARM64 Zig tests') }
    @{ Workflow = $windowsArmWorkflow; Text = $windowsArmWorkflowText; Job = 'arm64-build'; Flag = 'arm64_build'; Steps = @('Verify native ARM64 runner', 'Build and package ARM64 binaries', 'Run ARM64 CLI smoke', 'Build ARM64 D3D11 smoke tools', 'Hidden-desktop ARM64 WARP lifecycle smoke', 'Run packaged ARM64 CLI smoke') }
)
$filteredMutationCount = 0
foreach ($filtered in $filteredJobs) {
    $jobText = Get-YamlJobText -Content $filtered.Text -Name $filtered.Job -Source $filtered.Workflow
    if (-not (Test-FilteredJobCoverage -JobText $jobText -Flag $filtered.Flag -StepNames $filtered.Steps)) {
        throw "Filtered job '$($filtered.Job)' must carry exactly its changes flag '$($filtered.Flag)' and keep its mandatory steps unconditional and fail closed ($($filtered.Workflow))."
    }
    $mutations = @(
        $jobText.Replace("    if: needs.changes.outputs.$($filtered.Flag) == 'true'", '    if: true')
        $jobText.Replace("    if: needs.changes.outputs.$($filtered.Flag) == 'true'", "    if: needs.changes.outputs.$($filtered.Flag) != 'false'")
        $jobText.Replace('    needs: changes', '    needs: []')
        $jobText.Replace('    steps:', "    continue-on-error: true`n    steps:")
    )
    foreach ($name in $filtered.Steps) {
        foreach ($setting in @('if: false', 'continue-on-error: true')) {
            $mutations += $jobText.Replace("      - name: $name", "      - name: $name`n        $setting")
        }
    }
    foreach ($mutation in $mutations) {
        if (Test-FilteredJobCoverage -JobText $mutation -Flag $filtered.Flag -StepNames $filtered.Steps) {
            throw "Filtered job '$($filtered.Job)' accepted a weakened mutation."
        }
        $filteredMutationCount++
    }
}
Write-Host "Filtered job coverage: $filteredMutationCount/$filteredMutationCount weakening mutations rejected"

# Every Zig job restores only verified dependency packages, never build output
# (a failed or cancelled job can save incomplete generated files).
foreach ($zigJob in @(
        @{ Workflow = $testWorkflow; Text = $testWorkflowText; Jobs = @('tests', 'bench', 'build', 'renderer-smoke', 'cross-arm64', 'windows-lib-vt', 'windows-conpty-probes', 'windows-portable-smoke', 'bench-trend') }
        @{ Workflow = $windowsArmWorkflow; Text = $windowsArmWorkflowText; Jobs = @('arm64-tests', 'arm64-build') }
    )) {
    foreach ($jobName in $zigJob.Jobs) {
        $jobText = Get-YamlJobText -Content $zigJob.Text -Name $jobName -Source $zigJob.Workflow
        $setup = Get-YamlStepBlock -Content $jobText -Name 'Setup Zig' -Source "$($zigJob.Workflow) :: $jobName"
        if ($setup -notmatch '(?ms)with:\s+version: 0\.15\.2\s+.*?use-cache: false') {
            throw "$($zigJob.Workflow) job '$jobName': Zig builds must not restore failed Zig build caches."
        }
        $cache = Get-YamlStepBlock -Content $jobText -Name 'Cache Zig dependency packages' -Source "$($zigJob.Workflow) :: $jobName"
        if ($cache -notmatch '(?m)^ {10}path: \$\{\{ github\.workspace \}\}\\\.zig-global-cache/p\s*$') {
            throw "$($zigJob.Workflow) job '$jobName': only the verified dependency package directory may be cached."
        }
    }
}

# The gate's own steps decide whether a skipped or failed job fails the run, so
# neither may be conditional or ignore failure, and the validating step must
# read the needs context it was given.
function Test-GateJobShape {
    param([Parameter(Mandatory)] [string] $JobText)

    if ($JobText -match '(?m)^        [''"]?(?:if|continue-on-error)[''"]?[ \t]*:') { return $false }
    $step = Get-YamlStepBlock -Content $JobText -Name 'Every needed job succeeded and every skipped job was not needed' -Source 'gate job'
    return ($step -match '(?m)^          NEEDS_JSON: \$\{\{ toJSON\(needs\) \}\}\s*$') -and
        ($step -match '(?m)^        run: \./scripts/ci-gate\.ps1 -NeedsJson \$env:NEEDS_JSON -Expect \S+\s*$') -and
        ($step -match '(?m)^        shell: pwsh\s*$')
}

# The path filter, its outputs and the gates agree. The flags the workflows
# read are the ones Get-CiJobFlags prints, the changes job exposes each of them,
# and each gate requires exactly the jobs that carry one.
$knownFlags = & {
    . (Join-Path $repoRoot 'scripts\ci-changed-paths.ps1') -LibraryOnly
    @((Get-CiJobFlags -Selection (New-CiSelection $true)).Keys)
}
foreach ($gated in @(
        @{ Workflow = $testWorkflow; Text = $testWorkflowText; Gate = 'windows'; GateName = 'Windows Build And Tests'
            # The one filtered job the required gate leaves out: the
            # experimental probes, which may fail (continue-on-error).
            Own = @('windows-conpty-probes') }
        @{ Workflow = $windowsArmWorkflow; Text = $windowsArmWorkflowText; Gate = 'native-arm64'; GateName = 'Native Windows ARM64 Tests'; Own = @() }
    )) {
    $changesJob = Get-YamlJobText -Content $gated.Text -Name 'changes' -Source $gated.Workflow
    if ($changesJob -notmatch '(?m)^\s+run: \./scripts/ci-changed-paths\.ps1 -EventName \$env:EVENT_NAME -BaseSha \$env:BASE_SHA -HeadSha \$env:HEAD_SHA\s*$' -or
        $changesJob -notmatch '(?m)^\s+fetch-depth: 0\s*$' -or
        $changesJob -notmatch '(?m)^    runs-on: ubuntu-') {
        throw "$($gated.Workflow): the changes job must run the path filter on a full-history checkout."
    }
    $outputNames = @([regex]::Matches($changesJob, '(?m)^      (\w+): \$\{\{ steps\.filter\.outputs\.(\w+) \}\}\s*$') | ForEach-Object {
            if ($_.Groups[1].Value -cne $_.Groups[2].Value) { throw "$($gated.Workflow): changes output '$($_.Groups[1].Value)' reads '$($_.Groups[2].Value)'." }
            $_.Groups[1].Value
        })
    foreach ($output in $outputNames) {
        if ($output -cnotin $knownFlags) { throw "$($gated.Workflow): changes output '$output' is not a flag of scripts/ci-changed-paths.ps1." }
    }
    $gateJob = Get-YamlJobText -Content $gated.Text -Name $gated.Gate -Source $gated.Workflow
    # always(): the `main: CI gates` ruleset requires the gate, and under
    # !cancelled() a cancelled run skips it, which a required check reads as
    # passing.
    if ($gateJob -notmatch ("(?m)^    name: " + [regex]::Escape($gated.GateName) + "\s*$") -or
        $gateJob -notmatch '(?m)^    if: \$\{\{ always\(\) \}\}\s*$' -or
        $gateJob -notmatch '(?m)^    runs-on: ubuntu-' -or
        $gateJob -match '(?m)^    continue-on-error:') {
        throw "$($gated.Workflow): the gate job '$($gated.Gate)' must keep the name '$($gated.GateName)', run always (a cancelled run included) and never ignore failure."
    }
    if (-not (Test-GateJobShape -JobText $gateJob)) {
        throw "$($gated.Workflow): the gate job '$($gated.Gate)' must run scripts/ci-gate.ps1 on toJSON(needs) in an unconditional step that cannot ignore failure."
    }
    $gateMutations = @(
        $gateJob.Replace('      - name: Every needed job', "      - name: Every needed job`n        continue-on-error: true")
        $gateJob.Replace('      - name: Every needed job', "      - name: Every needed job`n        if: false")
        $gateJob.Replace('      - name: Checkout the gate script', "      - name: Checkout the gate script`n        continue-on-error: true")
        $gateJob.Replace('NEEDS_JSON: ${{ toJSON(needs) }}', "NEEDS_JSON: '{}'")
        $gateJob.Replace('-NeedsJson $env:NEEDS_JSON', '-NeedsJson ''{}''')
        $gateJob.Replace('./scripts/ci-gate.ps1', './scripts/ci-gate-disabled.ps1')
    )
    foreach ($gateMutation in $gateMutations) {
        if (Test-GateJobShape -JobText $gateMutation) { throw "$($gated.Workflow): the gate job accepted a weakened mutation." }
    }
    $expectMatch = [regex]::Match($gateJob, '(?m)-Expect (?<list>\S+)\s*$')
    if (-not $expectMatch.Success) { throw "$($gated.Workflow): the gate job has no -Expect list." }
    $expected = @{}
    foreach ($entry in ($expectMatch.Groups['list'].Value -split ',')) {
        $job, $flag = $entry -split ':', 2
        $expected[$job] = $flag
    }
    $needsMatch = [regex]::Match($gateJob, '(?m)^    needs:\s*\[(?<list>[^\]]*)\]\s*$')
    $needed = @($needsMatch.Groups['list'].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $neededText = ($needed | Sort-Object) -join ','
    $expectedText = ((@('changes') + @($expected.Keys)) | Sort-Object) -join ','
    if ($neededText -cne $expectedText) {
        throw "$($gated.Workflow): the gate's needs [$($needed -join ', ')] must be changes plus the jobs in -Expect [$(@($expected.Keys) -join ', ')]."
    }
    # Every job in the workflow that waits for the changes job is either gated
    # or named as having a check of its own.
    foreach ($jobMatch in [regex]::Matches($gated.Text, '(?m)^  (?<id>[\w-]+):\s*$')) {
        $id = $jobMatch.Groups['id'].Value
        $text = Get-YamlJobText -Content $gated.Text -Name $id -Source $gated.Workflow
        $flagMatch = [regex]::Match($text, "(?m)^    if: needs\.changes\.outputs\.(\w+) == 'true'\s*$")
        if (-not $flagMatch.Success) { continue }
        if ($flagMatch.Groups[1].Value -cnotin $knownFlags) { throw "$($gated.Workflow) job '$id' reads the unknown flag '$($flagMatch.Groups[1].Value)'." }
        if ($id -in $gated.Own) { continue }
        if (-not $expected.ContainsKey($id) -or $expected[$id] -cne $flagMatch.Groups[1].Value) {
            throw "$($gated.Workflow) job '$id' is filtered by '$($flagMatch.Groups[1].Value)' but the gate does not require it with that flag."
        }
    }
    foreach ($job in $expected.Keys) {
        if ($expected[$job] -ceq 'always') { continue }
        if ($expected[$job] -cnotin $knownFlags) { throw "$($gated.Workflow): the gate expects '$job' under the unknown flag '$($expected[$job])'." }
    }
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
# The job's whole run is the driver, which puts every launch on the composite's
# measure-AUMID build inside one state guard (STANDALONE-LEAF-AUMID-01).
if ($interactiveRunStep -notmatch '(?m)^ {8}shell: pwsh\s*$' -or
    $interactiveRunStep -notmatch '(?m)^ {8}run: \./test/windows/interactive-win11-job\.ps1\s*$' -or
    $interactiveRunStep -match '(?m)^ {8}run: \|') {
    throw 'The interactive job must run the composite and every leaf through test/windows/interactive-win11-job.ps1.'
}
$interactiveJobDriver = Join-Path $repoRoot 'test\windows\interactive-win11-job.ps1'
$interactiveJobTokens = $null
$interactiveJobErrors = $null
$interactiveJobAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $interactiveJobDriver, [ref]$interactiveJobTokens, [ref]$interactiveJobErrors)
if ($interactiveJobErrors.Count -ne 0) { throw "Interactive job driver does not parse: $($interactiveJobErrors[0].Message)" }
[void](Get-HistoryGuardedScriptBody -Ast $interactiveJobAst -Harness 'interactive-win11-job.ps1')
$interactiveJobPlanDefinitions = @($interactiveJobAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-InteractiveWin11JobPlan'
}, $true))
if ($interactiveJobPlanDefinitions.Count -ne 1) { throw 'The interactive job driver must own one Get-InteractiveWin11JobPlan.' }
$interactiveJobPlan = & ([scriptblock]::Create($interactiveJobPlanDefinitions[0].Extent.Text + "`nGet-InteractiveWin11JobPlan"))
$interactiveJobPlanText = @($interactiveJobPlan | ForEach-Object {
    $step = $_
    (@($step.Script) + @($step.Arguments.Keys | Sort-Object | ForEach-Object {
        if ($step.Arguments[$_] -is [bool]) { "-$_" } else { "-$_ $($step.Arguments[$_])" }
    })) -join ' '
}) -join "`n"
$expectedInteractiveJobPlan = @'
test\windows\flagship\Invoke-InteractiveWin11.ps1 -DeferCommandFinish -IncludeForegroundHarness -Rebuild -ResetState
test\windows\interactive-win11-shaders.ps1 -ResetState
test\windows\interactive-win11-shader-pacing.ps1 -ResetState
test\windows\interactive-win11-accessibility.ps1 -IdleSoakSeconds 600 -ResetState -TimeoutSeconds 120
test\windows\interactive-win11-palette-theme.ps1 -ExerciseHighContrast -ResetState
test\windows\interactive-win11-session-restore.ps1 -ResetState
test\windows\interactive-win11-command-finish.ps1 -ResetState -TimeoutSeconds 12
'@
if ($interactiveJobPlanText -cne ($expectedInteractiveJobPlan -replace '\r\n?', "`n").TrimEnd([char[]]"`n")) {
    throw "Interactive job plan drifted from its exact fail-closed snapshot:`n$interactiveJobPlanText"
}
# EVIDENCE-TOAST-FOREGROUND. A toast shows on the visible desktop whatever desktop
# noctty runs on, and its banner can cover a leaf's screen pixels or hold the
# foreground a leaf needs. In the evidence job the command-finish leaf is the
# only step that raises one on purpose, so the composite defers it and the job
# runs it last; every other step's noctty is kept from raising one. Checked
# here: the order, the composite's deferral, the accessibility leaf's two
# Settings-saving processes (by the notification settings noctty ends up with),
# and an inventory of toast sources over every script the job runs, each with
# mutation controls.
$toastLeaf = 'test\windows\interactive-win11-command-finish.ps1'
$toastLeafSteps = @($interactiveJobPlan | Where-Object { $_.Script -ceq $toastLeaf })
if ($toastLeafSteps.Count -ne 1 -or -not [object]::ReferenceEquals($interactiveJobPlan[-1], $toastLeafSteps[0]) -or
    $interactiveJobPlan[0].Arguments.DeferCommandFinish -ne $true) {
    throw 'The interactive job must run the command-finish leaf once, as its last step, and its composite must defer that leaf.'
}
$validateHarness = Join-Path $repoRoot 'test\windows\interactive-win11-validate.ps1'
$flagshipInteractive = Join-Path $repoRoot 'test\windows\flagship\Invoke-InteractiveWin11.ps1'
# Parses a script's text; -Tokens also returns its tokens. Parses are kept by
# text, since the checks and their controls read the same scripts many times.
$toastParses = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$parseToastScript = {
    param([string] $Text, [string] $Name, [switch] $Tokens)
    $parsed = $null
    if (-not $toastParses.TryGetValue($Text, [ref]$parsed)) {
        $parsedTokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$parsedTokens, [ref]$errors)
        if ($errors.Count -ne 0) { throw "$Name does not parse: $($errors[0].Message)" }
        $parsed = [pscustomobject]@{ Ast = $ast; Tokens = $parsedTokens }
        $toastParses[$Text] = $parsed
    }
    if ($Tokens) { $parsed } else { $parsed.Ast }
}
# A command's value for one named parameter (the element after it), or $null.
$getNamedArgument = {
    param([System.Management.Automation.Language.CommandAst] $Command, [string] $Parameter)
    $elements = $Command.CommandElements
    for ($index = 0; $index + 1 -lt $elements.Count; $index++) {
        if ($elements[$index] -is [System.Management.Automation.Language.CommandParameterAst] -and
            $elements[$index].ParameterName -eq $Parameter -and $null -eq $elements[$index].Argument) {
            return $elements[$index + 1]
        }
    }
    $null
}
# The composite's leaves, by the -ScriptName literal of each launch.
$getLeafLaunches = {
    param([System.Management.Automation.Language.Ast] $Ast)
    # The runner functions' own inner calls (`-ScriptName $ScriptName`) are not launches.
    @($Ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst] -or
            $node.GetCommandName() -notin @('Invoke-Harness', 'Invoke-HarnessWithPassSentinel', 'Start-Harness')) { return $false }
        for ($at = $node.Parent; $null -ne $at; $at = $at.Parent) {
            if ($at -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
        }
        $true
    }, $true) | ForEach-Object {
        $value = & $getNamedArgument $_ 'ScriptName'
        [pscustomobject]@{
            Command = $_
            Script = if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $value.Value } else { $null }
        }
    })
}
$isWithin = {
    param($Node, $Ancestor)
    for ($at = $Node; $null -ne $at; $at = $at.Parent) { if ([object]::ReferenceEquals($at, $Ancestor)) { return $true } }
    $false
}
# The composite starts the command-finish leaf once, as the one statement of an
# if whose one clause is `-not $DeferCommandFinish`, and the progress leaf as a
# pipeline of its own, each a direct statement of the `@( ... )` that
# `$parallelRuns` is assigned (so no loop, `if` or block around either can
# keep it from running); it declares the switch and only reads it, each read the
# whole condition of an if (no assignment, increment, [ref], variable cmdlet or
# `$PSBoundParameters` can change it); and it names the leaf's script once, so no
# Start-Process, `&` or `-File` of it can run beside that launch.
$testCompositeDeferral = {
    param([string] $Text)
    $parsed = & $parseToastScript $Text 'interactive-win11-validate.ps1' -Tokens
    $Ast = $parsed.Ast
    $parameters = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'DeferCommandFinish' })
    if ($parameters.Count -ne 1 -or $parameters[0].StaticType -ne [switch]) { return $false }
    $launches = @(& $getLeafLaunches $Ast)
    if (@($launches | Where-Object { $null -eq $_.Script }).Count -ne 0) { return $false }
    $toast = @($launches | Where-Object { $_.Script -ceq 'interactive-win11-command-finish.ps1' })
    $progress = @($launches | Where-Object { $_.Script -ceq 'interactive-win11-progress.ps1' })
    if ($toast.Count -ne 1 -or $progress.Count -ne 1 -or $toast[0].Command.GetCommandName() -cne 'Start-Harness') { return $false }
    $parallel = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '[InteractiveWin11HarnessRun[]] $parallelRuns'
    }, $true))
    if ($parallel.Count -ne 1) { return $false }
    $runs = $parallel[0].Right
    if ($runs -is [System.Management.Automation.Language.PipelineAst] -and $runs.PipelineElements.Count -eq 1) { $runs = $runs.PipelineElements[0] }
    if ($runs -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $runs.Expression -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { return $false }
    $runStatements = @($runs.Expression.SubExpression.Statements)
    $isRunStatement = { param($Statement) @($runStatements | Where-Object { [object]::ReferenceEquals($_, $Statement) }).Count -eq 1 }
    $progressPipeline = $progress[0].Command.Parent
    if ($progressPipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $progressPipeline.PipelineElements.Count -ne 1 -or
        $progressPipeline.Background -or -not (& $isRunStatement $progressPipeline)) { return $false }
    $toastPipeline = $toast[0].Command.Parent
    $toastBlock = $toastPipeline.Parent
    $toastIf = $toastBlock.Parent
    if ($toastPipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $toastPipeline.PipelineElements.Count -ne 1 -or $toastPipeline.Background -or
        $toastBlock -isnot [System.Management.Automation.Language.StatementBlockAst] -or $toastBlock.Statements.Count -ne 1 -or
        $toastIf -isnot [System.Management.Automation.Language.IfStatementAst] -or -not (& $isRunStatement $toastIf) -or
        $toastIf.Clauses.Count -ne 1 -or $null -ne $toastIf.ElseClause -or
        -not [string]::Equals($toastIf.Clauses[0].Item1.Extent.Text, '-not $DeferCommandFinish', [StringComparison]::Ordinal) -or
        -not [object]::ReferenceEquals($toastIf.Clauses[0].Item2, $toastBlock)) { return $false }
    $isIfCondition = {
        param($Pipeline)
        $Pipeline -is [System.Management.Automation.Language.PipelineAst] -and $Pipeline.Parent -is [System.Management.Automation.Language.IfStatementAst] -and
            @($Pipeline.Parent.Clauses | Where-Object { [object]::ReferenceEquals($_.Item1, $Pipeline) }).Count -eq 1
    }
    foreach ($use in @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -match '^(?i)((global|local|script|private|variable):)?DeferCommandFinish$'
            }, $true))) {
        if ($use.Parent -is [System.Management.Automation.Language.ParameterAst]) { continue }
        $read = $use.Parent
        if ($read -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            $read.TokenKind -in @([System.Management.Automation.Language.TokenKind]::Not, [System.Management.Automation.Language.TokenKind]::Exclaim)) { $read = $read.Parent }
        if ($read -isnot [System.Management.Automation.Language.CommandExpressionAst] -or -not (& $isIfCondition $read.Parent)) { return $false }
    }
    if (@($Ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match '(?i)DeferCommandFinish') -or
                ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -ieq 'PSBoundParameters')
            }, $true)).Count -ne 0) { return $false }
    $named = @($parsed.Tokens | Where-Object {
        $_ -is [System.Management.Automation.Language.StringToken] -and $_.Value -match '(?i)command-finish[^\\/]*\.ps1'
    })
    $named.Count -eq 1
}
$validateText = Get-Content -LiteralPath $validateHarness -Raw
if (-not (& $testCompositeDeferral $validateText)) {
    throw 'interactive-win11-validate.ps1 must start the command-finish leaf once, in $parallelRuns, only under if (-not $DeferCommandFinish), name its script nowhere else, declare that switch and only read it, and start the progress leaf unconditionally.'
}
$deferGuardText = "    if (-not `$DeferCommandFinish) { Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12 }"
$parallelRunsText = '[InteractiveWin11HarnessRun[]] $parallelRuns = @('
foreach ($toastControl in @(
        @{ Name = 'the guard removed'; From = $deferGuardText; To = "    Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12" },
        @{ Name = 'the guard inverted'; From = $deferGuardText; To = "    if (`$DeferCommandFinish) { Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12 }" },
        @{ Name = 'an else that starts it'; From = $deferGuardText; To = "$deferGuardText else { Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12 }" },
        @{ Name = 'a second launch after the parallel runs'; From = '$maxTimeoutSeconds = '; To = "Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12`n`$maxTimeoutSeconds = " },
        @{ Name = 'the progress leaf guarded too'; From = "    Start-Harness -ScriptName 'interactive-win11-progress.ps1' -TimeoutSeconds 20"; To = "    if (-not `$DeferCommandFinish) { Start-Harness -ScriptName 'interactive-win11-progress.ps1' -TimeoutSeconds 20 }" },
        @{ Name = 'the progress leaf inside while ($false) (CodeRabbit)'; From = "    Start-Harness -ScriptName 'interactive-win11-progress.ps1' -TimeoutSeconds 20"; To = "    while (`$false) { Start-Harness -ScriptName 'interactive-win11-progress.ps1' -TimeoutSeconds 20 }" },
        @{ Name = 'the command-finish launch inside a loop in its guard'; From = $deferGuardText; To = "    if (-not `$DeferCommandFinish) { foreach (`$once in @()) { Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12 } }" },
        @{ Name = 'the switch undeclared'; From = '    [switch] $DeferCommandFinish'; To = '    [string] $DeferCommandFinish' },
        @{ Name = 'the switch cleared before the parallel runs'; From = $parallelRunsText; To = "`$DeferCommandFinish = `$false`n$parallelRunsText" },
        @{ Name = 'the switch cleared in script scope'; From = $parallelRunsText; To = "[bool]`$script:DeferCommandFinish = `$false`n$parallelRunsText" },
        @{ Name = 'the switch cleared by Set-Variable'; From = $parallelRunsText; To = "Set-Variable -Name DeferCommandFinish -Value `$false`n$parallelRunsText" },
        @{ Name = 'the switch read through PSBoundParameters'; From = $parallelRunsText; To = "`$null = `$PSBoundParameters.Remove('Rebuild')`n$parallelRunsText" },
        @{ Name = 'the switch passed on'; From = $parallelRunsText; To = "Write-Host `$DeferCommandFinish`n$parallelRunsText" },
        @{ Name = 'a direct Start-Process of the leaf'; From = '$maxTimeoutSeconds = '; To = "Start-Process -FilePath 'powershell.exe' -ArgumentList @('-File', (Join-Path `$PSScriptRoot 'interactive-win11-command-finish.ps1'))`n`$maxTimeoutSeconds = " },
        @{ Name = 'the leaf run with &'; From = '$maxTimeoutSeconds = '; To = "& (Join-Path `$PSScriptRoot 'interactive-win11-command-finish.ps1')`n`$maxTimeoutSeconds = " }
    )) {
    if (([regex]::Matches($validateText, [regex]::Escape($toastControl.From))).Count -ne 1) {
        throw "Composite deferral control '$($toastControl.Name)' lost its anchor."
    }
    if (& $testCompositeDeferral $validateText.Replace($toastControl.From, $toastControl.To)) {
        throw "The composite deferral check accepted $($toastControl.Name)."
    }
}
# The wrapper declares -DeferCommandFinish and passes it on: in one block,
# `$arguments = @(...)`, the only plain assignment of `$arguments`, comes first,
# then `if ($DeferCommandFinish) { $arguments += '-DeferCommandFinish' }`, then,
# as the very next statement, so nothing can write `$arguments` between them,
# the one `powershell.exe` call, which splats `@arguments`. The switch is only
# read, as the composite's is: the name appears as its declaration and as that
# if's whole condition and nowhere else, no string names it but the one
# literal `-DeferCommandFinish` token the append adds, and the wrapper uses
# neither `$PSBoundParameters` nor a variable cmdlet (Sol M, round 7: a
# `$DeferCommandFinish = $false` before the append passed).
$testWrapperForwarding = {
    param([string] $Text)
    $ast = & $parseToastScript $Text 'Invoke-InteractiveWin11.ps1'
    $same = { param([string] $Left, [string] $Right) [string]::Equals($Left, $Right, [StringComparison]::Ordinal) }
    $parameters = @($ast.ParamBlock.Parameters | Where-Object { & $same $_.Name.VariablePath.UserPath 'DeferCommandFinish' })
    if ($parameters.Count -ne 1 -or $parameters[0].StaticType -ne [switch]) { return $false }
    $appends = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and
                (& $same $node.Extent.Text "if (`$DeferCommandFinish) { `$arguments += '-DeferCommandFinish' }") }, $true))
    $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
                [string]::Equals($node.GetCommandName(), 'powershell.exe', [StringComparison]::OrdinalIgnoreCase) }, $true))
    $builds = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals($node.Left.VariablePath.UserPath, 'arguments', [StringComparison]::OrdinalIgnoreCase) }, $true))
    if ($appends.Count -ne 1 -or $calls.Count -ne 1 -or $builds.Count -ne 1 -or $calls[0].Parent -isnot [System.Management.Automation.Language.PipelineAst]) { return $false }
    $switchUses = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath -match '^(?i)((global|local|script|private|variable|using):)?DeferCommandFinish$' }, $true))
    if ($switchUses.Count -ne 2) { return $false }
    foreach ($use in $switchUses) {
        if ($use.Parent -is [System.Management.Automation.Language.ParameterAst]) { continue }
        if (-not (& $same $use.VariablePath.UserPath 'DeferCommandFinish') -or $use.Parent -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
            -not [object]::ReferenceEquals($use.Parent.Parent, $appends[0].Clauses[0].Item1)) { return $false }
    }
    $switchNames = @($ast.FindAll({ param($node) ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                $node.Value.IndexOf('DeferCommandFinish', [StringComparison]::OrdinalIgnoreCase) -ge 0 }, $true))
    if ($switchNames.Count -ne 1 -or -not (& $same $switchNames[0].Value '-DeferCommandFinish') -or
        $switchNames[0].Extent.StartOffset -lt $appends[0].Extent.StartOffset -or $switchNames[0].Extent.EndOffset -gt $appends[0].Extent.EndOffset) { return $false }
    if (@($ast.FindAll({ param($node) ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.VariablePath.UserPath -match '^(?i)((global|local|script|private|variable):)?PSBoundParameters$') -or
                    ($node -is [System.Management.Automation.Language.CommandAst] -and $null -ne $node.GetCommandName() -and
                        $node.GetCommandName().Substring($node.GetCommandName().LastIndexOf([char]'\') + 1) -in @('Set-Variable', 'New-Variable', 'Clear-Variable', 'Remove-Variable', 'sv', 'set', 'nv', 'clv', 'rv')) }, $true)).Count -ne 0) { return $false }
    $splats = @($calls[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
    if ($splats.Count -ne 1 -or -not (& $same $splats[0].VariablePath.UserPath 'arguments')) { return $false }
    $statements = @($appends[0].Parent.Statements)
    $at = { param($Statement) for ($i = 0; $i -lt $statements.Count; $i++) { if ([object]::ReferenceEquals($statements[$i], $Statement)) { return $i } }; -1 }
    $buildAt = & $at $builds[0]
    $appendAt = & $at $appends[0]
    $callAt = & $at $calls[0].Parent
    $buildAt -ge 0 -and $buildAt -lt $appendAt -and $appendAt -ge 0 -and $appendAt + 1 -eq $callAt
}
$flagshipInteractiveText = Get-Content -LiteralPath $flagshipInteractive -Raw
if (-not (& $testWrapperForwarding $flagshipInteractiveText)) {
    throw 'Invoke-InteractiveWin11.ps1 must declare -DeferCommandFinish and append it to the arguments its powershell.exe call splats, before that call.'
}
$wrapperAppend = "    if (`$DeferCommandFinish) { `$arguments += '-DeferCommandFinish' }`n"
$wrapperCall = "    & powershell.exe @arguments *> `$rawTranscriptPath`n"
foreach ($toastControl in @(
        @{ Name = 'the append after the call (CodeRabbit)'; From = $wrapperAppend; To = ''; Then = @(, @($wrapperCall, "$wrapperCall$wrapperAppend")) },
        @{ Name = 'the arguments built again between the append and the call'; From = $wrapperCall; To = "    `$arguments = @('-NoLogo')`n$wrapperCall" },
        @{ Name = 'a typed write that drops the switch before the call (CodeRabbit)'; From = $wrapperCall; To = "    [string[]] `$arguments = `$arguments | Where-Object { `$_ -ne '-DeferCommandFinish' }`n$wrapperCall" },
        @{ Name = 'the call splatting another array'; From = $wrapperCall; To = "    & powershell.exe @otherArguments *> `$rawTranscriptPath`n" },
        @{ Name = 'the append to another array'; From = $wrapperAppend; To = "    if (`$DeferCommandFinish) { `$otherArguments += '-DeferCommandFinish' }`n" },
        @{ Name = 'the switch undeclared'; From = '    [switch] $DeferCommandFinish'; To = '    [string] $DeferCommandFinish' },
        @{ Name = 'the switch cleared before the append (Sol M, round 7)'; From = $wrapperAppend; To = "    `$DeferCommandFinish = `$false`n$wrapperAppend" },
        @{ Name = 'the switch cleared in script scope'; From = $wrapperAppend; To = "    [bool]`$script:DeferCommandFinish = `$false`n$wrapperAppend" },
        @{ Name = 'the switch cleared by Set-Variable on a built name'; From = $wrapperAppend; To = "    Microsoft.PowerShell.Utility\Set-Variable -Name ('Defer' + 'CommandFinish') -Value `$false`n$wrapperAppend" },
        @{ Name = 'the switch read through PSBoundParameters'; From = $wrapperAppend; To = "    `$null = `$PSBoundParameters.Remove('Rebuild')`n$wrapperAppend" },
        @{ Name = 'the switch passed on another way'; From = $wrapperAppend; To = "$wrapperAppend    Write-Host `$DeferCommandFinish`n" },
        @{ Name = 'the token appended twice'; From = $wrapperAppend; To = "$wrapperAppend    `$extraToken = '-DeferCommandFinish'`n" }
    )) {
    $wrapperMutated = $flagshipInteractiveText
    foreach ($wrapperEdit in @(, @($toastControl.From, $toastControl.To)) + @(if ($toastControl.ContainsKey('Then')) { $toastControl.Then })) {
        if (([regex]::Matches($wrapperMutated, [regex]::Escape($wrapperEdit[0]))).Count -ne 1) { throw "Wrapper forwarding control '$($toastControl.Name)' lost its anchor." }
        $wrapperMutated = $wrapperMutated.Replace($wrapperEdit[0], $wrapperEdit[1])
    }
    if (& $testWrapperForwarding $wrapperMutated) { throw "The wrapper forwarding check accepted $($toastControl.Name)." }
}

# OSC 9 is a desktop notification unless osc9.zig parses it as something else.
# Exempt are only the two forms the job's leaves send and the parser proves are
# no notification: progress, `9;4;` and a state its switch takes (`9;4;5` and a
# bare `9;4;` are notifications), and a working directory, `9;9;`. Every other
# OSC 9, ConEmu's included, is a source. The states come from the parser's
# source, and every parser test's input, as text and as bytes, must be flagged
# if and only if that test expects a notification, for the exempt kinds.
$osc9Parser = Join-Path $repoRoot 'src\terminal\osc\parsers\osc9.zig'
$osc9Text = Get-Content -LiteralPath $osc9Parser -Raw
$progressBranch = [regex]::Match($osc9Text, "(?s)// OSC 9;4 progress report\s*'4' => \{\s*if \(data\.len < 2\) break :conemu;\s*if \(data\[1\] != ';'\) break :conemu;\s*if \(data\.len < 3\) break :conemu;\s*switch \(data\[2\]\) \{(?<cases>.*?)\n\s*else => break :conemu,")
$cwdBranch = [regex]::Match($osc9Text, "(?s)// OSC 9;9 current working directory\s*'9' => \{\s*if \(data\.len < 2\) break :conemu;\s*if \(data\[1\] != ';'\) break :conemu;")
$progressStates = @(if ($progressBranch.Success) {
        [regex]::Matches($progressBranch.Groups['cases'].Value, "(?m)^\s*'(?<state>[0-9])' => \{") | ForEach-Object { $_.Groups['state'].Value }
    })
if (-not $progressBranch.Success -or -not $cwdBranch.Success -or $progressStates.Count -eq 0 -or
    ($progressStates -join '') -cne (($progressStates | Sort-Object -Unique) -join '')) {
    throw 'osc9.zig no longer has the OSC 9;4 progress and 9;9 working-directory branches the toast-source inventory reads; derive its exemptions again.'
}
$progressStateClass = '[' + ($progressStates -join '') + ']'
# A byte as a PowerShell number: hex (`0x5d`, any case, leading zeros) or
# decimal (`93`, leading zeros), with any type suffix (`93uy`, `0x5dL`); a run
# of them, comma-separated as a byte array literal writes them.
$byteOf = { param([int] $Value) '(?:0x0*{0:x2}|0*{1})(?:[a-z]{{1,2}})?\b' -f $Value, $Value }
$bytesOf = { param([string] $Characters) '\b' + ((@($Characters.ToCharArray()) | ForEach-Object { & $byteOf ([int]$_) }) -join '\s*,\s*') }
$progressStateBytes = '(?:' + (($progressStates | ForEach-Object { & $byteOf ([int][char]$_) }) -join '|') + ')'
$osc9TextSource = '\]9;(?!4;' + $progressStateClass + '|9;)'
$osc9ByteSource = '(?i)' + (& $bytesOf ']9;') + '(?!\s*,\s*' + (& $bytesOf '4;') + '\s*,\s*' + $progressStateBytes + ')(?!\s*,\s*' + (& $bytesOf '9;') + ')'

# Every script the job runs: the workflow job's two scripts and each .ps1 a
# script names in a string, as found, so the shared libraries the leaves load
# (scripts\interactive-win11-lib.ps1 and the rest) are read too. Only the
# command-finish leaf may hold a toast source; only the accessibility leaf may
# save Settings, from the processes pinned below.
$toastSources = [ordered]@{
    'a notify-on-command-finish setting' = 'notify-on-command-finish'
    'desktop-notifications = true' = '(?i)desktop-notifications\s*=\s*true'
    'an OSC 9 notification (text)' = $osc9TextSource
    'an OSC 777 notification (text)' = '\]777;'
    'an OSC 99 notification (text)' = '\]99;'
    'an OSC 7501 program status (text)' = '\]7501;'
    'an OSC 9 notification (bytes)' = $osc9ByteSource
    'an OSC 777 notification (bytes)' = '(?i)' + (& $bytesOf ']777')
    'an OSC 99 notification (bytes)' = '(?i)' + (& $bytesOf ']99;')
    'an OSC 7501 program status (bytes)' = '(?i)' + (& $bytesOf ']7501')
    'a reload_config action' = '[''"]reload_config[''"]'
    # A copy raises the clipboard-copy notice (`Surface.copySelectionToClipboards`,
    # `copy_last_command_output`), which `desktop-notifications` does not gate.
    # `copy-on-select = false` turns copying off (the hidden-desktop launch policy).
    'a clipboard copy' = '(?i)\bcopy_to_clipboard\b|\bcopy_last_command_output\b|\bcopy-or-paste\b|\bcopy-on-select\b(?!\s*=\s*false\b)|\bright-click-action\b'
}
$settingsSaves = [ordered]@{
    'a Settings Save and close' = "-ActionName\s+'Save and close'"
    'a Settings Save invoke' = '\.Save\.TryGetCurrentPattern\('
}
$accessibilityLeaf = 'test\windows\interactive-win11-accessibility.ps1'
$findToastSources = {
    param([string] $File, [string] $Text)
    foreach ($toastSource in $toastSources.GetEnumerator()) {
        if ($File -cne $toastLeaf -and [regex]::IsMatch($Text, $toastSource.Value)) { "$File holds $($toastSource.Key)" }
    }
    foreach ($toastSave in $settingsSaves.GetEnumerator()) {
        if ($File -cne $accessibilityLeaf -and [regex]::IsMatch($Text, $toastSave.Value)) { "$File holds $($toastSave.Key)" }
    }
}
# The scripts reachable from the workflow job's two, each read with $Read (a
# repository-relative path to its text, or $null when there is no such file):
# a string naming a .ps1 that exists, beside the naming script, at the
# repository root, in test\windows or in scripts, is read too; one that starts
# `$PSScriptRoot\` (or `${PSScriptRoot}`) is looked for beside the naming
# script only, one that starts `$repoRoot\` at the root only. A string naming a
# .ps1 found nowhere fails the inventory, unless it is one of the payloads a
# leaf writes at run time ($toastGeneratedScripts), whose text is the leaf's.
$toastGeneratedScripts = @(
    'test\windows\interactive-win11-accessibility.ps1|cold-output-$token.ps1',
    'test\windows\interactive-win11-accessibility.ps1|inactive-output-$inactiveToken.ps1',
    'test\windows\interactive-win11-command-finish.ps1|interactive-win11-command-finish-payload.ps1',
    'test\windows\interactive-win11-configured-size.ps1|interactive-win11-configured-size-payload.ps1',
    'test\windows\interactive-win11-ime-candidate.ps1|interactive-win11-ime-candidate-payload.ps1',
    'test\windows\interactive-win11-key-input.ps1|$artifactPrefix-payload.ps1',
    'test\windows\interactive-win11-progress.ps1|interactive-win11-progress-payload.ps1',
    'test\windows\interactive-win11-resize.ps1|interactive-win11-resize-payload.ps1',
    'test\windows\interactive-win11-shaders.ps1|interactive-win11-shaders-payload.ps1'
)
$toastGeneratedSet = [Collections.Generic.HashSet[string]]::new([string[]]$toastGeneratedScripts, [StringComparer]::Ordinal)
$readJobFiles = {
    param([scriptblock] $Read)
    $texts = @{}
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($root in @('test\windows\interactive-win11-job.ps1', 'test\windows\assert-interactive-runner.ps1')) { $queue.Enqueue($root) }
    while ($queue.Count -ne 0) {
        $file = $queue.Dequeue()
        if ($texts.ContainsKey($file)) { continue }
        $text = & $Read $file
        if ($null -eq $text) { throw "An interactive job file is missing: $file" }
        $texts[$file] = $text
        $directory = Split-Path -Parent $file
        $parsedFile = & $parseToastScript $text $file -Tokens
        # A literal child of `Join-Path $repoRoot` or `Join-Path $PSScriptRoot`
        # resolves against that base alone, as PowerShell resolves it.
        $joinBases = @{}
        foreach ($join in $parsedFile.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $null -ne $node.GetCommandName() -and
                    [string]::Equals($node.GetCommandName().Substring($node.GetCommandName().LastIndexOf([char]'\') + 1), 'Join-Path', [StringComparison]::OrdinalIgnoreCase) }, $true)) {
            # `Join-Path $base 'x.ps1'`, by its module or not, or with -Path and -ChildPath.
            $elements = @($join.CommandElements)
            $joinBase = & $getNamedArgument $join 'Path'
            $joinChild = & $getNamedArgument $join 'ChildPath'
            if ($null -eq $joinBase -and $null -eq $joinChild -and $elements.Count -eq 3) { $joinBase = $elements[1]; $joinChild = $elements[2] }
            if ($joinBase -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
                $joinChild -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            if ([string]::Equals($joinBase.VariablePath.UserPath, 'repoRoot', [StringComparison]::OrdinalIgnoreCase)) { $joinBases[$joinChild.Extent.StartOffset] = '' }
            elseif ([string]::Equals($joinBase.VariablePath.UserPath, 'PSScriptRoot', [StringComparison]::OrdinalIgnoreCase)) { $joinBases[$joinChild.Extent.StartOffset] = $directory }
        }
        foreach ($token in $parsedFile.Tokens) {
            if ($token -isnot [System.Management.Automation.Language.StringToken] -or $token.Value -notmatch '\.ps1$') { continue }
            $name = $token.Value
            $bases = if ($joinBases.ContainsKey($token.Extent.StartOffset)) { @($joinBases[$token.Extent.StartOffset]) } else { @($directory, '', 'test\windows', 'scripts') }
            $rooted = [regex]::Match($name, '^(?i)\$(?:\{(?<root>PSScriptRoot|repoRoot)\}|(?<root>PSScriptRoot|repoRoot))[\\/]')
            if ($rooted.Success) {
                $name = $name.Substring($rooted.Length)
                $bases = if ([string]::Equals($rooted.Groups['root'].Value, 'PSScriptRoot', [StringComparison]::OrdinalIgnoreCase)) { @($directory) } else { @('') }
            }
            # Any other name is read against every base it resolves against,
            # not only the first.
            $found = $false
            foreach ($base in $bases) {
                $relative = if ($base) { Join-Path $base $name } else { $name }
                $candidate = [IO.Path]::GetRelativePath($repoRoot, [IO.Path]::GetFullPath((Join-Path $repoRoot $relative)))
                if ($null -ne (& $Read $candidate)) { $queue.Enqueue($candidate); $found = $true }
            }
            if (-not $found -and -not $toastGeneratedSet.Contains("$file|$($token.Value)")) {
                throw "$file names $($token.Value), which the toast-source inventory cannot find; name it from `$PSScriptRoot or `$repoRoot, or list it as a payload the leaf writes."
            }
        }
    }
    $texts
}
$readRepositoryFile = {
    param([string] $File)
    $path = Join-Path $repoRoot $File
    if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) } else { $null }
}
$jobFileTexts = & $readJobFiles $readRepositoryFile
$jobFiles = @($jobFileTexts.Keys | Sort-Object)
# The list holds at least what the plan and the composite launch, and the
# shared scripts they load.
$toastExpectedFiles = [Collections.Generic.List[string]]::new()
foreach ($toastStep in $interactiveJobPlan) { $toastExpectedFiles.Add($toastStep.Script) }
foreach ($toastLaunch in @(& $getLeafLaunches (& $parseToastScript $validateText 'interactive-win11-validate.ps1'))) {
    $toastExpectedFiles.Add("test\windows\$($toastLaunch.Script)")
}
foreach ($toastCovered in @('test\windows\interactive-win11-validate.ps1', 'test\windows\interactive-win11-stateful-lib.ps1',
        'scripts\interactive-win11-lib.ps1', 'scripts\interactive-win11-window-lib.ps1', 'scripts\interactive-win11-measure-lib.ps1',
        'scripts\interactive-win11-state-guard.ps1', 'scripts\windows-harness-history.ps1')) { $toastExpectedFiles.Add($toastCovered) }
$toastMissing = @($toastExpectedFiles | Where-Object { $jobFiles -cnotcontains $_ } | Sort-Object -Unique)
if ($toastMissing.Count -ne 0) { throw "The interactive job file list lost $($toastMissing -join ', ')." }
$toastSourceProblems = @(foreach ($toastFile in $jobFiles) { & $findToastSources $toastFile $jobFileTexts[$toastFile] })
if ($toastSourceProblems.Count -ne 0) {
    throw "Only the command-finish leaf may raise a toast in the interactive job: $($toastSourceProblems -join '; ')."
}
# Who may run the command-finish leaf, whose toast sources the inventory
# exempts by file: the plan's last step, the composite's guarded launch
# (checked above), and vt-probe-win32-conformance.ps1's `-Runtime` branch,
# which no job script takes: the composite launches that leaf only as
# `Invoke-Harness -ScriptName 'vt-probe-win32-conformance.ps1' -TimeoutSeconds
# 10 -PassResetState` and names `Runtime` nowhere, and no other job script names
# it. No other job script names the leaf's script, so no earlier step can run it.
# Each script's strings that name the leaf or the vt-probe leaf, by text.
$toastNamings = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$testToastLeafNamers = {
    param([hashtable] $Texts)
    $namers = [ordered]@{}
    $probeNamers = [ordered]@{}
    foreach ($entry in @($Texts.GetEnumerator() | Sort-Object Key)) {
        $parsed = & $parseToastScript $entry.Value $entry.Key -Tokens
        $naming = $null
        if (-not $toastNamings.TryGetValue($entry.Value, [ref]$naming)) {
            $naming = [pscustomobject]@{ Leaf = [Collections.Generic.List[object]]::new(); Probe = 0 }
            foreach ($token in $parsed.Tokens) {
                if ($token -isnot [System.Management.Automation.Language.StringToken]) { continue }
                # A string that ends in the leaf's file name, as a path or a bare name.
                if ($token.Value -match '(?i)(^|[\\/])interactive-win11-command-finish\.ps1$') { $naming.Leaf.Add($token) }
                if ($token.Value -match '(?i)vt-probe-win32-conformance') { $naming.Probe++ }
            }
            $toastNamings[$entry.Value] = $naming
        }
        if ($naming.Leaf.Count -ne 0 -and -not [string]::Equals($entry.Key, $toastLeaf, [StringComparison]::Ordinal)) { $namers[$entry.Key] = $naming.Leaf.ToArray() }
        if ($naming.Probe -ne 0 -and -not [string]::Equals($entry.Key, 'test\windows\vt-probe-win32-conformance.ps1', [StringComparison]::Ordinal)) { $probeNamers[$entry.Key] = $parsed }
    }
    if (-not [string]::Equals(($namers.Keys -join ','), 'test\windows\interactive-win11-job.ps1,test\windows\interactive-win11-validate.ps1,test\windows\vt-probe-win32-conformance.ps1', [StringComparison]::Ordinal)) { return $false }
    if (@($namers.Values | Where-Object { @($_).Count -ne 1 }).Count -ne 0) { return $false }
    # The vt-probe leaf names it only inside `if ($Runtime)`.
    $probeAst = & $parseToastScript $Texts['test\windows\vt-probe-win32-conformance.ps1'] 'vt-probe-win32-conformance.ps1'
    $probeName = @($namers['test\windows\vt-probe-win32-conformance.ps1'])[0]
    $runtimeIfs = @($probeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses.Count -eq 1 -and $null -eq $node.ElseClause -and
                [string]::Equals($node.Clauses[0].Item1.Extent.Text, '$Runtime', [StringComparison]::Ordinal) -and
                $probeName.Extent.StartOffset -ge $node.Clauses[0].Item2.Extent.StartOffset -and $probeName.Extent.EndOffset -le $node.Clauses[0].Item2.Extent.EndOffset }, $true))
    if ($runtimeIfs.Count -ne 1) { return $false }
    # `-Runtime` is a switch with no default, and nothing writes it, so the
    # branch runs only when a caller passes it.
    $runtimeParameters = @($probeAst.ParamBlock.Parameters | Where-Object { [string]::Equals($_.Name.VariablePath.UserPath, 'Runtime', [StringComparison]::OrdinalIgnoreCase) })
    if ($runtimeParameters.Count -ne 1 -or $runtimeParameters[0].StaticType -ne [switch] -or $null -ne $runtimeParameters[0].DefaultValue) { return $false }
    if (@($probeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    @($node.Left.FindAll({ param($inner) $inner -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                $inner.VariablePath.UserPath -match '^(?i)((global|local|script|private|variable):)?Runtime$' }, $true)).Count -ne 0 }, $true)).Count -ne 0) { return $false }
    # Only the composite launches it, once, with no -Runtime, and names Runtime nowhere.
    if (-not [string]::Equals(($probeNamers.Keys -join ','), 'test\windows\interactive-win11-validate.ps1', [StringComparison]::Ordinal)) { return $false }
    $validate = $probeNamers['test\windows\interactive-win11-validate.ps1']
    $probeLaunches = @($validate.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
                @($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -match '(?i)vt-probe-win32-conformance' }).Count -ne 0 }, $true))
    if ($probeLaunches.Count -ne 1 -or -not [string]::Equals($probeLaunches[0].Extent.Text, "Invoke-Harness -ScriptName 'vt-probe-win32-conformance.ps1' -TimeoutSeconds 10 -PassResetState", [StringComparison]::Ordinal)) { return $false }
    if (@($validate.Tokens | Where-Object { $_.Text -match '(?i)Runtime' -and $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment }).Count -ne 0) { return $false }
    $true
}
if (-not (& $testToastLeafNamers $jobFileTexts)) {
    throw 'Only the job plan, the composite''s guarded launch and vt-probe-win32-conformance.ps1''s -Runtime branch (which no job script takes) may name the command-finish leaf.'
}
foreach ($toastControl in @(
        @{ Name = 'an earlier leaf that runs the command-finish leaf (CodeRabbit)'; File = 'test\windows\interactive-win11-shaders.ps1'; Append = "& (Join-Path `$PSScriptRoot 'interactive-win11-command-finish.ps1')" },
        @{ Name = 'the job driver naming it twice'; File = 'test\windows\interactive-win11-job.ps1'; Append = "`$extra = 'test\windows\interactive-win11-command-finish.ps1'" },
        @{ Name = 'vt-probe naming it outside its -Runtime branch'; File = 'test\windows\vt-probe-win32-conformance.ps1'; Append = "& powershell.exe -File (Join-Path `$PSScriptRoot 'interactive-win11-command-finish.ps1')"; Replace = "        @{ Script = 'interactive-win11-command-finish.ps1'; Timeout = 12 },`n" },
        @{ Name = 'the composite passing -Runtime'; File = 'test\windows\interactive-win11-validate.ps1'; From = "Invoke-Harness -ScriptName 'vt-probe-win32-conformance.ps1' -TimeoutSeconds 10 -PassResetState"; To = "Start-Harness -ScriptName 'vt-probe-win32-conformance.ps1' -TimeoutSeconds 10 -AdditionalArguments @('-Runtime')" },
        @{ Name = 'another job script launching vt-probe'; File = 'test\windows\interactive-win11-stateful-lib.ps1'; Append = "function Invoke-Probe { & (Join-Path `$PSScriptRoot 'vt-probe-win32-conformance.ps1') -Runtime }" },
        @{ Name = 'vt-probe''s -Runtime on by default (CodeRabbit)'; File = 'test\windows\vt-probe-win32-conformance.ps1'; From = '    [switch] $Runtime,'; To = '    [switch] $Runtime = $true,' },
        @{ Name = 'vt-probe setting -Runtime itself'; File = 'test\windows\vt-probe-win32-conformance.ps1'; From = '$mode = if ($Runtime)'; To = "`$Runtime = `$true`n`$mode = if (`$Runtime)" }
    )) {
    $toastNamerTexts = $jobFileTexts.Clone()
    if ($toastControl.ContainsKey('Append')) { $toastNamerTexts[$toastControl.File] += "`n$($toastControl.Append)" }
    if ($toastControl.ContainsKey('Replace')) {
        if (([regex]::Matches($toastNamerTexts[$toastControl.File], [regex]::Escape($toastControl.Replace))).Count -ne 1) { throw "Leaf-namer control '$($toastControl.Name)' lost its anchor." }
        $toastNamerTexts[$toastControl.File] = $toastNamerTexts[$toastControl.File].Replace($toastControl.Replace, '')
    }
    if ($toastControl.ContainsKey('From')) {
        if (([regex]::Matches($toastNamerTexts[$toastControl.File], [regex]::Escape($toastControl.From))).Count -ne 1) { throw "Leaf-namer control '$($toastControl.Name)' lost its anchor." }
        $toastNamerTexts[$toastControl.File] = $toastNamerTexts[$toastControl.File].Replace($toastControl.From, $toastControl.To)
    }
    if (& $testToastLeafNamers $toastNamerTexts) { throw "The command-finish leaf check accepted $($toastControl.Name)." }
}
# The patterns see the sources they were written for: the toast leaf's own
# config, and both Settings saves.
if (-not [regex]::IsMatch($jobFileTexts[$toastLeaf], $toastSources['a notify-on-command-finish setting']) -or
    -not [regex]::IsMatch($jobFileTexts[$toastLeaf], $toastSources['desktop-notifications = true']) -or
    @($settingsSaves.Values | Where-Object { -not [regex]::IsMatch($jobFileTexts[$accessibilityLeaf], $_) }).Count -ne 0) {
    throw 'The toast-source inventory no longer matches the sources it was written for.'
}
$nonToastLeaf = 'test\windows\interactive-win11-shaders.ps1'
# What a non-toast leaf would hold with this text in it; the leaf itself holds
# no source (checked above), so the text is read alone.
$isToastSourceIn = {
    param([string] $Text)
    @(& $findToastSources $nonToastLeaf $Text).Count -ne 0
}
$asOscText = { param([string] $Body) '"' + [char]0x60 + 'e]' + $Body + [char]0x60 + 'a"' }
$asOscBytes = { param([string] $Body) '[byte[]](0x1b,0x5d,' + ((@($Body.ToCharArray()) | ForEach-Object { '0x{0:x2}' -f [int]$_ }) -join ',') + ',0x07)' }
$asOscDecimal = { param([string] $Body) '[byte[]](27, 93, ' + ((@($Body.ToCharArray()) | ForEach-Object { [string][int]$_ }) -join ', ') + ', 7)' }
# The parser's own tests, by the command each expects.
$osc9Cases = @(foreach ($testBlock in ($osc9Text -split '(?=\ntest ")')) {
        $testName = [regex]::Match($testBlock, '^\ntest "(?<name>[^"]*)" \{')
        $testInputs = [regex]::Matches($testBlock, 'const input = "(?<input>[^"\\]*)";')
        $testTag = [regex]::Match($testBlock, 'try testing\.expect\(cmd == \.(?<tag>[a-z_]+)\);')
        if ($testName.Success -and $testInputs.Count -eq 1 -and $testTag.Success) {
            [pscustomobject]@{ Name = $testName.Groups['name'].Value; Input = $testInputs[0].Groups['input'].Value; Tag = $testTag.Groups['tag'].Value }
        }
    })
$osc9Notifications = @($osc9Cases | Where-Object { $_.Tag -ceq 'show_desktop_notification' })
$osc9Exempt = @($osc9Cases | Where-Object { $_.Tag -cin @('conemu_progress_report', 'report_pwd') })
foreach ($osc9Required in @('9;4', '9;4;', '9;4;5', '9;4;5a', '9;9')) {
    if (@($osc9Notifications | Where-Object { $_.Input -ceq $osc9Required }).Count -ne 1) { throw "osc9.zig's tests no longer show '$osc9Required' as a notification; read them again." }
}
if ($osc9Cases.Count -lt 50 -or @($osc9Exempt | Where-Object { $_.Tag -ceq 'conemu_progress_report' }).Count -lt 10 -or
    @($osc9Exempt | Where-Object { $_.Tag -ceq 'report_pwd' }).Count -lt 1) {
    throw "The toast-source inventory read only $($osc9Cases.Count) of osc9.zig's test cases."
}
foreach ($osc9Case in $osc9Cases) {
    $osc9Expected = $osc9Case.Tag -ceq 'show_desktop_notification'
    foreach ($osc9Form in @((& $asOscText $osc9Case.Input), (& $asOscBytes $osc9Case.Input), (& $asOscDecimal $osc9Case.Input))) {
        $osc9Flagged = & $isToastSourceIn $osc9Form
        if (($osc9Expected -and -not $osc9Flagged) -or ($osc9Case.Tag -cin @('conemu_progress_report', 'report_pwd') -and $osc9Flagged)) {
            throw "The toast-source inventory disagrees with osc9.zig's test '$($osc9Case.Name)' on $osc9Form (flagged: $osc9Flagged, the parser: $($osc9Case.Tag))."
        }
    }
}
foreach ($toastControl in @(
        @{ Name = 'notify-on-command-finish = always'; Text = "'notify-on-command-finish = always'" },
        @{ Name = 'notify-on-command-finish = never'; Text = "'notify-on-command-finish = never'" },
        @{ Name = 'desktop-notifications = true'; Text = "'desktop-notifications = true'" },
        @{ Name = 'an OSC 9 notification as text'; Text = '"`e]9;hello`a"' },
        @{ Name = 'an OSC 9;4 with no state as text'; Text = '"`e]9;4;`a"' },
        @{ Name = 'an OSC 9;4 with state 5 as text'; Text = '"`e]9;4;5`a"' },
        @{ Name = 'an OSC 777 notification as text'; Text = '"`e]777;notify;t;b`a"' },
        @{ Name = 'an OSC 99 notification as text'; Text = '"`e]99;;hi`a"' },
        @{ Name = 'an OSC 7501 report as text'; Text = '"`e]7501;state=blocked`a"' },
        @{ Name = 'an OSC 9 notification as bytes'; Text = '[byte[]](0x1b,0x5d,0x39,0x3b,0x68,0x07)' },
        @{ Name = 'an OSC 9;4 with no state as bytes'; Text = '[byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x07)' },
        @{ Name = 'an OSC 9;4 with state 5 as bytes'; Text = '[byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x35,0x07)' },
        @{ Name = 'an empty OSC 9 ending the bytes'; Text = '[byte[]](0x1b,0x5d,0x39,0x3b)' },
        @{ Name = 'an OSC 777 notification as bytes'; Text = '[byte[]](0x1b, 0x5d, 0x37, 0x37, 0x37, 0x3b)' },
        @{ Name = 'an OSC 99 notification as bytes'; Text = '[byte[]](0x1b,0x5D,0x39,0x39,0x3b)' },
        @{ Name = 'an OSC 7501 report as bytes'; Text = '[byte[]](0x1b,0x5d,0x37,0x35,0x30,0x31,0x3b)' },
        @{ Name = 'an OSC 9 notification as decimal bytes (CodeRabbit)'; Text = '[byte[]](27,93,57,59,72,7)' },
        @{ Name = 'an OSC 9 notification as suffixed decimal bytes'; Text = '[byte[]](27uy, 93uy, 57uy, 59uy, 72uy, 7uy)' },
        @{ Name = 'an OSC 9 notification as hex with leading zeros'; Text = '[byte[]](0x1B,0x05D,0x039,0x03B,0x48,0x07)' },
        @{ Name = 'an OSC 777 notification as decimal bytes'; Text = '[byte[]](27,93,55,55,55,59)' },
        @{ Name = 'an OSC 9;4 with state 5 as decimal bytes'; Text = '[byte[]](27,93,57,59,52,59,53,7)' },
        @{ Name = 'a reload_config action'; Text = "Invoke-Action 'reload_config'" },
        @{ Name = 'a copy_to_clipboard binding'; Text = "'keybind = ctrl+shift+c=copy_to_clipboard'" },
        @{ Name = 'a copy-on-select setting'; Text = "'copy-on-select = clipboard'" },
        @{ Name = 'a Settings Save and close'; Text = "Invoke-AccessibilitySettingsCloseAction -ActionName 'Save and close'" },
        @{ Name = 'a Settings Save invoke'; Text = '$probe.Save.TryGetCurrentPattern($pattern, [ref]$invoke)' }
    )) {
    if (-not (& $isToastSourceIn $toastControl.Text)) { throw "The toast-source inventory missed $($toastControl.Name) in a non-toast leaf." }
}
# What the progress leaf sends, and a working directory, raise no toast.
foreach ($toastAllowed in @('[byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x31,0x3b,0x35,0x30,0x07)', '[byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x30,0x3b,0x07)',
        '[byte[]](27, 93, 57, 59, 52, 59, 49, 59, 53, 48, 7)', '[byte[]](27,93,57,59,57,59)',
        '[byte[]](0x1b,0x5d,0x39,0x3b,0x39,0x3b)', '"`e]9;4;1;50`a"', '"`e]9;4;3`a"', '"`e]9;9;C:\x`a"')) {
    if (& $isToastSourceIn $toastAllowed) { throw "The toast-source inventory flagged $toastAllowed, which osc9.zig parses as progress or a working directory." }
}
# A source in the shared launch library is found, and so is one in a script
# that only another job script names.
if (@(& $findToastSources 'scripts\interactive-win11-lib.ps1' ($jobFileTexts['scripts\interactive-win11-lib.ps1'] + "`n'--notify-on-command-finish=always'")).Count -ne 1) {
    throw 'The toast-source inventory missed a source in the shared launch library.'
}
$toastExtraLibrary = 'scripts\interactive-win11-extra-control-lib.ps1'
$toastDiscovered = & $readJobFiles {
    param([string] $File)
    if ($File -ceq $toastExtraLibrary) { return "`$null = [byte[]](0x1b,0x5d,0x37,0x37,0x37,0x3b)" }
    $text = & $readRepositoryFile $File
    if ($File -ceq $nonToastLeaf) { $text += "`n. (Join-Path `$repoRoot '$toastExtraLibrary')" }
    $text
}
if (-not $toastDiscovered.ContainsKey($toastExtraLibrary) -or
    @(& $findToastSources $toastExtraLibrary $toastDiscovered[$toastExtraLibrary]).Count -ne 1) {
    throw 'The toast-source inventory must read a script that only another job script names.'
}
# The same through `$PSScriptRoot` (CodeRabbit), for a helper beside the leaf.
$toastSiblingHelper = 'test\windows\interactive-win11-extra-control-helper.ps1'
$toastSiblingDiscovered = & $readJobFiles {
    param([string] $File)
    if ($File -ceq $toastSiblingHelper) { return "`$null = '--notify-on-command-finish=always'" }
    $text = & $readRepositoryFile $File
    if ($File -ceq $nonToastLeaf) { $text += "`n. `"`$PSScriptRoot\interactive-win11-extra-control-helper.ps1`"" }
    $text
}
if (-not $toastSiblingDiscovered.ContainsKey($toastSiblingHelper) -or
    @(& $findToastSources $toastSiblingHelper $toastSiblingDiscovered[$toastSiblingHelper]).Count -ne 1) {
    throw 'The toast-source inventory must read a script a job script names from $PSScriptRoot.'
}
# `Join-Path $repoRoot` names the root script even with a quiet one of that
# name beside the leaf: the root one is read and its source found, the
# sibling is not read (CodeRabbit; Sol's round-6 Low).
$toastRootHelper = 'interactive-win11-extra-root-helper.ps1'
# The same by its module and with -Path and -ChildPath (Sol Low, round 7).
foreach ($toastJoin in @("Join-Path `$repoRoot '$toastRootHelper'", "Microsoft.PowerShell.Management\Join-Path `$repoRoot '$toastRootHelper'",
        "Join-Path -Path `$repoRoot -ChildPath '$toastRootHelper'")) {
    $toastBothDiscovered = & $readJobFiles {
        param([string] $File)
        if ($File -ceq $toastRootHelper) { return "`$null = '--notify-on-command-finish=always'" }
        if ($File -ceq "test\windows\$toastRootHelper") { return "`$null = 'quiet'" }
        $text = & $readRepositoryFile $File
        if ($File -ceq $nonToastLeaf) { $text += "`n. ($toastJoin)" }
        $text
    }
    if (-not $toastBothDiscovered.ContainsKey($toastRootHelper) -or $toastBothDiscovered.ContainsKey("test\windows\$toastRootHelper") -or
        @(& $findToastSources $toastRootHelper $toastBothDiscovered[$toastRootHelper]).Count -ne 1) {
        throw "The toast-source inventory must read the script $toastJoin names, not a sibling of that name."
    }
}
# And a script it cannot find fails it.
$toastUnfound = $null
try {
    $null = & $readJobFiles {
        param([string] $File)
        $text = & $readRepositoryFile $File
        if ($File -ceq $nonToastLeaf) { $text += "`n. `"`$env:TEMP\toast-helper.ps1`"" }
        $text
    }
}
catch { $toastUnfound = $_.Exception.Message }
if ($null -eq $toastUnfound -or -not $toastUnfound.Contains('which the toast-source inventory cannot find')) {
    throw 'The toast-source inventory must fail on a script a job script names that it cannot find.'
}

# The accessibility leaf's two Settings saves, in three layers.
# (A) Pins. The leaf's regions between `# pin-begin: <name>` and `# pin-end:
#     <name>` lines are pinned below by the SHA-256 of their text with LF line
#     ends ($saveLeafPins): `save-functions` (the reading, the run-time and
#     sandbox checks, the launcher), `save-sandbox` (the sandbox and the
#     environment both saves run in), `save-flow` (both launches, their checks
#     and both saves) and `failure-path` (the main catch through the final
#     throw). An edit there fails this contract until its pin is updated in
#     the same change, so a reviewer sees it. Each region must hold the
#     statements it guards, found in the leaf's syntax tree.
# (B) Run-time checks, in the leaf. Right after each saving launch, before its
#     probe opens, `Assert-AccessibilitySaveLaunchQuiet` reads that process's
#     own command line, by its id, never printing it, and stops the leaf
#     unless `Get-AccessibilitySaveLaunchVerdict` finds every notification
#     off. Before the first launch, before each save and before the verifier
#     starts, `Assert-AccessibilitySaveSandboxQuiet` finds no default config
#     file but the one the saves write, and no include in it, in the
#     directory the saving environment names. Both read byte for byte: they
#     compare ordinally (PowerShell's `-eq` family ignores some characters,
#     PWSH-CEQ-ICU) and refuse any argument character outside printable ASCII.
#     Run below on synthetic command lines and files, under PowerShell 7 and
#     Windows PowerShell 5.1, and against a stand-in process lookup; the Zig
#     test "a command line's notification flags are read byte for byte"
#     (Config.zig) is their reference for what noctty reads.
# (C) The static grammar names what changed. It refuses every form it does not
#     list; it evaluates no PowerShell, so a name built at run time is the
#     run-time checks' to catch. Its rules, (1) to (7):
# (1) Saves. Exactly one close-prompt action named 'Save and close', every
#     action name single-quoted: a `Get-AccessibilitySettingsCloseActionInvoke`
#     on `-SettingsProbe $saveProbe`, written once to `$saveCloseInvoke`, read
#     once, and pressed as `$saveCloseInvoke.Invoke()`, the statement right
#     after the 'before the probe saves' check; exactly one
#     `.Save.TryGetCurrentPattern(`, on `$verifyScrollback.Save`, and exactly
#     one `$restoreInvoke.Invoke()`, the statement right after the 'before the
#     verifier saves' check.
# (2) Probes and processes. `$saveProbe = Open-AccessibilitySettingsProbe
#     -Process $saveProbeProcess ...`, `$saveVerifyProbe = ... -Process
#     $saveVerifyProcess ...`, `$verifyScrollback = Get-AccessibilityScrollbackProbe
#     -SettingsProbe $saveVerifyProbe ...`; `$saveProbeProcess` and
#     `$saveVerifyProcess` are each assigned from one
#     `Start-AccessibilityProcessWithEnvironment` call, the leaf's only two, each
#     with `-EnvironmentVariables $settingsProbeEnvironment`, which is
#     `Get-InteractiveWin11Environment -Layout $settingsPersistenceLayout`.
# (3) Launch arguments. Each launch's `-ArgumentList` is a variable assigned
#     `$name = @( ... )`, each element one statement of one of these forms:
#     `Get-InteractiveWin11ContainmentArguments` with no argument; a
#     single-quoted string; `"--class=$name"`, where `$name =
#     "<letters, digits, hyphens>$([Guid]::NewGuid().ToString('N'))"`; or
#     `$settingsSaveNotificationArguments`, assigned `@('...', '...')` or
#     `'...', '...'` of single-quoted strings. The containment function is
#     defined once, in scripts\interactive-win11-lib.ps1 and in no other job
#     script, as `return @( <single-quoted strings, one per line> )`.
# (4) Every variable named in (2) and (3) is written exactly once, by that
#     plain `$name =`, and otherwise only read: no scoped spelling, no other
#     assignment of any operator, no index, member, `[ref]`, loop or parameter
#     of that name, no string naming it (so no `-OutVariable [+]name`,
#     `-PipelineVariable name` or `Set-Variable -Name name`), and no job script
#     but the leaf names it at all. The three arrays are read only where (3)
#     puts them, and `$settingsProbeEnvironment` only by the two launches and
#     the four sandbox checks, so no alias, method call or parameter can reach
#     them. The leaf's five save functions are each defined once, by that name
#     and no scoped one, and in no other job script. The leaf uses no variable
#     or alias cmdlet, no `Invoke-Expression`, no common variable parameter,
#     no `$ExecutionContext` and no background pipeline (`... &`), and every
#     token of its code outside comments is printable ASCII. No job script
#     uses a variable or alias cmdlet, `Import-Alias` or `Invoke-Expression`
#     (by any module-qualified name too, such as
#     `Microsoft.PowerShell.Utility\Set-Variable`); a `function:`, `variable:`
#     or `alias:` drive, as a variable or a path; a `data` section;
#     `[scriptblock]::Create` or a cast to `[scriptblock]`; `SessionState`,
#     `SessionStateProxy`, `InvokeCommand` or `InvokeProvider`; `$PSCmdlet`; or
#     `&` or `.` on a name built by an expression (a variable, a member, a
#     literal, a script block or `(Join-Path ...)` are the targets allowed).
# (5) Order. The statements of (1), (2), (3) and (7) and the four sandbox
#     checks are direct statements of the one block that holds both launches,
#     none a background pipeline, in this order: the flags before each launch
#     array, each class name and launch array before its launch, each launch
#     before its run-time check, each check before its probe opens; the first
#     sandbox check before the first launch, one after the probe opens and
#     before its save, one after the first process stops and before the
#     second launch, and one after the verifier's probe opens and before its
#     save.
# (6) The arguments those forms give: every element is printable ASCII with
#     no space, quote or backtick (`Start-Process -ArgumentList` joins the
#     elements with spaces and quotes nothing), none is `--config-file` (an
#     include is read after the command line, `Config.load`, and wins), and
#     the notification settings they leave are all off, read by the leaf's own
#     `Get-AccessibilityNotificationSettings`.
# (7) The block that holds the launches is the leaf's normal-mode branch, a
#     direct statement of the leaf's main `try`, whose only `catch` is
#     `$runFailure = $_`; after the try, `$failureMessages.Add(...)` of that
#     error is a direct statement of `if ($null -ne $runFailure)`, and the
#     final throw follows. So a failed check stops the leaf before its save
#     and fails it.
# A save then shows its banner and, with `config-reload` off and that banner
# shown, `settingsNotifySuccessThunk` returns before the toast (settings.md
# PROFILES-4 trap 7).
$saveOrdinal = [StringComparer]::Ordinal
$saveFolded = [StringComparer]::OrdinalIgnoreCase
$saveSame = { param([string] $Left, [string] $Right) [string]::Equals($Left, $Right, [StringComparison]::Ordinal) }
$saveSet = { param([string[]] $Values) , [Collections.Generic.HashSet[string]]::new($Values, $saveFolded) }
$saveAstAll = [Func[System.Management.Automation.Language.Ast, bool]] [System.Management.Automation.LanguagePrimitives]::IsTrue
$saveLinqOfType = [System.Linq.Enumerable].GetMethod('OfType')
$saveLinqToArray = [System.Linq.Enumerable].GetMethod('ToArray')
$saveNodesOfType = {
    param($All, [type] $Type)
    $typed = $saveLinqOfType.MakeGenericMethod($Type).Invoke($null, [object[]]@(, $All))
    , $saveLinqToArray.MakeGenericMethod($Type).Invoke($null, [object[]]@(, $typed))
}
# A name without a scope or drive prefix PowerShell reads as the same name
# (written out in the index's loops, which run once per node).
$saveScopes = [Collections.Generic.HashSet[string]]::new([string[]]@('global', 'local', 'script', 'private', 'variable', 'using', 'env'), [StringComparer]::OrdinalIgnoreCase)
$saveBareName = {
    param([string] $Name)
    if ($Name.StartsWith('+', [StringComparison]::Ordinal)) { $Name = $Name.Substring(1) }
    $colon = $Name.IndexOf([char]':')
    if ($colon -gt 0 -and $saveScopes.Contains($Name.Substring(0, $colon))) { $Name.Substring($colon + 1) } else { $Name }
}
# A command's name without a module qualifier (`Microsoft.PowerShell.Utility\Set-Variable`).
$saveCommandName = {
    param($Command)
    $name = $Command.GetCommandName()
    if ($null -eq $name) { return $null }
    $slash = $name.LastIndexOf([char]'\')
    if ($slash -ge 0) { $name.Substring($slash + 1) } else { $name }
}
# One parse and one walk of a script, kept by its text: every check below
# reads the nodes it needs from here, by kind and by name.
$saveIndexes = [Collections.Generic.Dictionary[string, object]]::new($saveOrdinal)
$saveIndexOf = {
    param([string] $Text, [string] $Name)
    $found = $null
    if ($saveIndexes.TryGetValue($Text, [ref]$found)) { return $found }
    $parsed = & $parseToastScript $Text $Name -Tokens
    $all = $saveLinqToArray.MakeGenericMethod([System.Management.Automation.Language.Ast]).Invoke($null, [object[]]@(, $parsed.Ast.FindAll($saveAstAll, $true)))
    $variables = & $saveNodesOfType $all ([System.Management.Automation.Language.VariableExpressionAst])
    $variablesByName = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new($saveFolded)
    foreach ($variable in $variables) {
        $bare = $variable.VariablePath.UserPath
        $colon = $bare.IndexOf([char]':')
        if ($colon -gt 0 -and $saveScopes.Contains($bare.Substring(0, $colon))) { $bare = $bare.Substring($colon + 1) }
        $list = $null
        if (-not $variablesByName.TryGetValue($bare, [ref]$list)) { $list = [Collections.Generic.List[object]]::new(); $variablesByName[$bare] = $list }
        $list.Add($variable)
    }
    $strings = [object[]](& $saveNodesOfType $all ([System.Management.Automation.Language.StringConstantExpressionAst])) +
        [object[]](& $saveNodesOfType $all ([System.Management.Automation.Language.ExpandableStringExpressionAst]))
    $stringNames = [Collections.Generic.HashSet[string]]::new($saveFolded)
    foreach ($string in $strings) {
        $bare = $string.Value
        if ($bare.StartsWith('+', [StringComparison]::Ordinal)) { $bare = $bare.Substring(1) }
        $colon = $bare.IndexOf([char]':')
        if ($colon -gt 0 -and $saveScopes.Contains($bare.Substring(0, $colon))) { $bare = $bare.Substring($colon + 1) }
        [void]$stringNames.Add($bare)
    }
    $commands = & $saveNodesOfType $all ([System.Management.Automation.Language.CommandAst])
    $commandsByName = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new($saveFolded)
    foreach ($command in $commands) {
        $commandName = $command.GetCommandName()
        if ($null -eq $commandName) { continue }
        $slash = $commandName.LastIndexOf([char]'\')
        if ($slash -ge 0) { $commandName = $commandName.Substring($slash + 1) }
        $list = $null
        if (-not $commandsByName.TryGetValue($commandName, [ref]$list)) { $list = [Collections.Generic.List[object]]::new(); $commandsByName[$commandName] = $list }
        $list.Add($command)
    }
    # Every token but comments, for the printable-ASCII rule: a character
    # class with no case folding compares code units exactly.
    $outsideAscii = '[^\t\n\r\x20-\x7E]'
    $codeOutsideAscii = $false
    if ([regex]::IsMatch($Text, $outsideAscii)) {
        $code = [Text.StringBuilder]::new()
        foreach ($token in $parsed.Tokens) { if ($token.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { [void]$code.Append($token.Text).Append("`n") } }
        $codeOutsideAscii = [regex]::IsMatch($code.ToString(), $outsideAscii)
    }
    $index = [pscustomobject]@{
        Text = $Text
        CodeOutsideAscii = $codeOutsideAscii
        Ast = $parsed.Ast
        Tokens = $parsed.Tokens
        All = $all
        Variables = $variables
        VariablesByName = $variablesByName
        Strings = $strings
        StringNames = $stringNames
        Commands = $commands
        CommandsByName = $commandsByName
        Functions = & $saveNodesOfType $all ([System.Management.Automation.Language.FunctionDefinitionAst])
        Pipelines = & $saveNodesOfType $all ([System.Management.Automation.Language.PipelineAst])
        InvokeMembers = & $saveNodesOfType $all ([System.Management.Automation.Language.InvokeMemberExpressionAst])
        Members = & $saveNodesOfType $all ([System.Management.Automation.Language.MemberExpressionAst])
        Converts = & $saveNodesOfType $all ([System.Management.Automation.Language.ConvertExpressionAst])
        TypeExpressions = & $saveNodesOfType $all ([System.Management.Automation.Language.TypeExpressionAst])
        DataSections = & $saveNodesOfType $all ([System.Management.Automation.Language.DataStatementAst])
        CommandParameters = & $saveNodesOfType $all ([System.Management.Automation.Language.CommandParameterAst])
    }
    $saveIndexes[$Text] = $index
    $index
}
$saveCommandsNamed = {
    param($Index, [string] $Name)
    $list = $null
    if ($Index.CommandsByName.TryGetValue($Name, [ref]$list)) { $list.ToArray() }
}
$saveIndexOfFile = { param([string] $File) & $saveIndexOf $jobFileTexts[$File] (Split-Path -Leaf $File) }
$saveLeafIndex = & $saveIndexOfFile $accessibilityLeaf
$saveFunctionNames = @('Get-AccessibilityNotificationSettings', 'Get-AccessibilitySaveLaunchVerdict', 'Assert-AccessibilitySaveLaunchQuiet',
    'Assert-AccessibilitySaveSandboxQuiet', 'Start-AccessibilityProcessWithEnvironment', 'Get-AccessibilitySettingsCloseActionInvoke')
# The cmdlets the pinned regions call. No job script may define a function of
# one of these names, which would run in its place (Opus L1, round 6), and a
# region may call nothing else but a function the job scripts define;
# `Start-Process` and `Join-Path` are called there by their module.
$saveRegionCmdlets = [Collections.Generic.HashSet[string]]::new([string[]]@('ConvertTo-Json', 'ForEach-Object', 'Get-CimInstance', 'Get-Content',
        'Get-Process', 'Get-WinEvent', 'Join-Path', 'Measure-Object', 'Out-Null', 'Select-Object', 'Set-Content', 'Start-Process', 'Start-Sleep',
        'Test-Path', 'Where-Object'), [StringComparer]::OrdinalIgnoreCase)
$saveQualifiedCmdlets = @{ 'Start-Process' = 'Microsoft.PowerShell.Management\Start-Process'; 'Join-Path' = 'Microsoft.PowerShell.Management\Join-Path' }
# The functions the whole leaf defines, which its regions may call (the
# controls run on the leaf with the others cut).
$saveLeafFunctionNames = [Collections.Generic.HashSet[string]]::new([string[]]@($saveLeafIndex.Functions | ForEach-Object { & $saveBareName $_.Name }), [StringComparer]::OrdinalIgnoreCase)
$saveRuntimeFunctions = [ordered]@{}
foreach ($saveRuntimeName in $saveFunctionNames) {
    $saveRuntimeFound = @($saveLeafIndex.Functions | Where-Object { & $saveSame $_.Name $saveRuntimeName })
    if ($saveRuntimeFound.Count -ne 1) { throw "interactive-win11-accessibility.ps1 must define $saveRuntimeName once." }
    $saveRuntimeFunctions[$saveRuntimeName] = $saveRuntimeFound[0]
}
foreach ($saveRuntimeFunction in @($saveRuntimeFunctions.Values)[0..3]) {
    if (@($saveRuntimeFunction.FindAll($saveAstAll, $true) | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandAst] -and
                    "$(& $saveCommandName $_)" -match '^(?i)(Write-|Out-|Tee-Object|Add-Content|Set-Content|Export-|echo$|tee$)'
            }).Count -ne 0) {
        throw "$($saveRuntimeFunction.Name) must not print or write anything, the command line least of all."
    }
}
# The leaf's own reading, defined here from its source: the static check, the
# tables below and the run-time check share it.
$saveReadingText = $saveRuntimeFunctions['Get-AccessibilityNotificationSettings'].Extent.Text + "`n" + $saveRuntimeFunctions['Get-AccessibilitySaveLaunchVerdict'].Extent.Text
. ([scriptblock]::Create($saveReadingText))
$getEffectiveNotifications = {
    param([string[]] $Arguments)
    Get-AccessibilityNotificationSettings -Arguments $Arguments
}
$saveSoftHyphen = [string][char]0x00AD
$saveControl = [string][char]0x0001
$toastQuietPair = @('--app-notifications=false', '--desktop-notifications=false')
# What noctty reads, as `desktop clipboard-copy config-reload`. The rows marked
# Zig are those the Zig test reads the same way.
$saveSettingsRows = @(
    @{ Name = 'no arguments'; Arguments = @(); Expected = 'True True True' },
    @{ Name = 'the quiet pair (Zig)'; Arguments = $toastQuietPair; Expected = 'False False False' },
    @{ Name = 'an override after it'; Arguments = $toastQuietPair + @('--app-notifications=true'); Expected = 'False True True' },
    @{ Name = 'an override before it'; Arguments = @('--app-notifications=true', '--desktop-notifications=true') + $toastQuietPair; Expected = 'False False False' },
    @{ Name = 'a later list from the defaults'; Arguments = @('--app-notifications=false', '--app-notifications=no-clipboard-copy'); Expected = 'True False True' },
    @{ Name = 'a bare desktop flag'; Arguments = $toastQuietPair + @('--desktop-notifications'); Expected = 'True False False' },
    @{ Name = 'desktop as 1'; Arguments = $toastQuietPair + @('--desktop-notifications=1'); Expected = 'True False False' },
    @{ Name = 'desktop as F'; Arguments = @('--desktop-notifications=F'); Expected = 'False True True' },
    @{ Name = 'an unparsed desktop value'; Arguments = $toastQuietPair + @('--desktop-notifications=yes'); Expected = 'False False False' },
    @{ Name = 'an empty desktop value after it'; Arguments = $toastQuietPair + @('--desktop-notifications='); Expected = 'True False False' },
    @{ Name = 'an empty app value after it'; Arguments = $toastQuietPair + @('--app-notifications='); Expected = 'False True True' },
    @{ Name = 'empty values before it'; Arguments = @('--app-notifications=', '--desktop-notifications=') + $toastQuietPair; Expected = 'False False False' },
    @{ Name = 'a bare app flag'; Arguments = $toastQuietPair + @('--app-notifications'); Expected = 'False False False' },
    @{ Name = 'an unparsed app list'; Arguments = $toastQuietPair + @('--app-notifications=no-config-reload,bogus'); Expected = 'False False False' },
    @{ Name = 'an app list in another case'; Arguments = $toastQuietPair + @('--app-notifications=NO-CONFIG-RELOAD'); Expected = 'False False False' },
    @{ Name = 'a spaced app list'; Arguments = @('--app-notifications= no-config-reload , no-clipboard-copy'); Expected = 'True False False' },
    @{ Name = 'an override after -e (Zig)'; Arguments = $toastQuietPair + @('-e', 'cmd.exe', '--app-notifications=true'); Expected = 'False False False' },
    @{ Name = 'an override after -toastactivated'; Arguments = $toastQuietPair + @('-toastactivated', '--app-notifications=true'); Expected = 'False False False' },
    @{ Name = 'an override after -EMBEDDING'; Arguments = $toastQuietPair + @('-EMBEDDING', '--app-notifications=true'); Expected = 'False False False' },
    @{ Name = 'a key in another case'; Arguments = $toastQuietPair + @('--App-Notifications=true'); Expected = 'False False False' },
    # PWSH-CEQ-ICU: the characters PowerShell's comparisons ignore are bytes to noctty.
    @{ Name = 'a soft hyphen inside false (Zig)'; Arguments = @("--app-notifications=fa${saveSoftHyphen}lse", '--desktop-notifications=false'); Expected = 'False True True' },
    @{ Name = 'a control character inside false (Zig)'; Arguments = @("--app-notifications=fa${saveControl}lse", '--desktop-notifications=false'); Expected = 'False True True' },
    @{ Name = 'a soft hyphen inside -e (Zig)'; Arguments = $toastQuietPair + @("-${saveSoftHyphen}e", '--app-notifications=true'); Expected = 'False True True' },
    @{ Name = 'a control character inside -e'; Arguments = $toastQuietPair + @("-${saveControl}e", '--app-notifications=true'); Expected = 'False True True' },
    @{ Name = 'a soft hyphen inside a key'; Arguments = $toastQuietPair + @("--app-noti${saveSoftHyphen}fications=true"); Expected = 'False False False' },
    @{ Name = 'a zero-width space inside true'; Arguments = $toastQuietPair + @("--app-notifications=tr$([char]0x200B)ue"); Expected = 'False False False' },
    @{ Name = 'a dotless i inside -Embedding'; Arguments = $toastQuietPair + @("-Embedd$([char]0x0131)ng", '--app-notifications=true'); Expected = 'False True True' },
    @{ Name = 'a Kelvin sign inside a list'; Arguments = $toastQuietPair + @("--app-notifications=no-clipboard-copy,no-config-reload$([char]0x212A)"); Expected = 'False False False' }
)
$saveLaunchLine = '"C:\Program Files\noctty\noctty.exe" --linux-cgroup=always --linux-cgroup-hard-fail=true --windows-job-object-kill-on-close=true --single-instance=false --class=noctty-accessibility-settings-save-0123 --command=cmd.exe'
$saveQuietLine = "$saveLaunchLine --app-notifications=false --desktop-notifications=false"
$saveVerdictRows = @(
    @{ Name = 'the clean case (Zig)'; Line = $saveQuietLine; Expected = 'quiet' },
    @{ Name = 'an unquoted program name'; Line = 'C:\noctty\noctty.exe --app-notifications=false --desktop-notifications=false'; Expected = 'quiet' },
    @{ Name = 'runs of spaces'; Line = 'noctty.exe   --app-notifications=false    --desktop-notifications=false  '; Expected = 'quiet' },
    @{ Name = 'a leading space (an empty program name)'; Line = ' --desktop-notifications=true --app-notifications=false --desktop-notifications=false'; Expected = 'quiet' },
    @{ Name = 'a quoted name with more after it'; Line = '"C:\noctty\noctty.exe"x --app-notifications=false --desktop-notifications=false'; Expected = 'quiet' },
    @{ Name = 'a program name outside ASCII'; Line = "`"C:\n$([char]0x00F6)ctty\noctty.exe`" --app-notifications=false --desktop-notifications=false"; Expected = 'quiet' },
    @{ Name = 'an override before the flags'; Line = "$saveLaunchLine --app-notifications=true --app-notifications=false --desktop-notifications=false"; Expected = 'quiet' },
    @{ Name = 'an override after the flags'; Line = "$saveQuietLine --app-notifications=true"; Expected = 'it leaves the clipboard-copy notice, config-reload notifications on' },
    @{ Name = 'an empty desktop value after the flags'; Line = "$saveQuietLine --desktop-notifications="; Expected = 'it leaves desktop-notifications on' },
    @{ Name = 'an empty app value after the flags'; Line = "$saveQuietLine --app-notifications="; Expected = 'it leaves the clipboard-copy notice, config-reload notifications on' },
    @{ Name = 'a --config-file'; Line = "$saveQuietLine --config-file=C:\x\notify.conf"; Expected = 'it names a --config-file' },
    @{ Name = 'a bare --config-file before the flags'; Line = "$saveLaunchLine --config-file --app-notifications=false --desktop-notifications=false"; Expected = 'it names a --config-file' },
    @{ Name = 'a quote after the program name'; Line = "$saveLaunchLine --title=`"a b`" --app-notifications=false --desktop-notifications=false"; Expected = 'its arguments hold a quote' },
    @{ Name = '-e before the flags'; Line = "$saveLaunchLine -e cmd.exe --app-notifications=false --desktop-notifications=false"; Expected = 'it leaves desktop-notifications, the clipboard-copy notice, config-reload notifications on' },
    @{ Name = 'no flags'; Line = $saveLaunchLine; Expected = 'it leaves desktop-notifications, the clipboard-copy notice, config-reload notifications on' },
    @{ Name = 'an empty command line'; Line = ''; Expected = 'its command line could not be read' },
    @{ Name = 'no command line'; Line = $null; Expected = 'its command line could not be read' },
    @{ Name = 'an unclosed program name'; Line = '"noctty.exe --app-notifications=false --desktop-notifications=false'; Expected = 'its program name is not closed' },
    @{ Name = 'a quote inside an unquoted program name (Zig)'; Line = 'C:\x"y --app-notifications=false --desktop-notifications=false'; Expected = 'its program name is not closed' },
    @{ Name = 'a NUL in the program name'; Line = "noctty$([char]0).exe --app-notifications=false --desktop-notifications=false"; Expected = 'its command line holds a NUL' },
    # PWSH-CEQ-ICU, Opus's round-5 cases among them.
    @{ Name = 'a tab between arguments'; Line = "$saveLaunchLine --app-notifications=false`t--desktop-notifications=false"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'a soft hyphen inside false (Zig)'; Line = "$saveLaunchLine --app-notifications=fa${saveSoftHyphen}lse --desktop-notifications=false"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'a soft hyphen inside a list'; Line = "$saveLaunchLine --app-notifications=no-clipboard-copy,no-config-relo${saveSoftHyphen}ad --desktop-notifications=false"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'a soft hyphen inside -e, then an override (Zig)'; Line = "$saveQuietLine -${saveSoftHyphen}e --app-notifications=true"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'a control character inside false (Zig)'; Line = "$saveLaunchLine --app-notifications=fa${saveControl}lse --desktop-notifications=false"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'a control character inside -e, then an override'; Line = "$saveQuietLine -${saveControl}e --app-notifications=true"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'a NUL after the flags'; Line = "$saveQuietLine$([char]0) --app-notifications=true"; Expected = 'its arguments hold a character outside printable ASCII' },
    @{ Name = 'DEL inside false'; Line = "$saveLaunchLine --app-notifications=fa$([char]0x7F)lse --desktop-notifications=false"; Expected = 'its arguments hold a character outside printable ASCII' }
)
$saveTableFailures = [Collections.Generic.List[string]]::new()
foreach ($toastCase in $saveSettingsRows) {
    $toastEffective = & $getEffectiveNotifications ([string[]]$toastCase.Arguments)
    $toastActual = "$($toastEffective.Desktop) $($toastEffective.ClipboardCopy) $($toastEffective.ConfigReload)"
    if (-not (& $saveSame $toastActual $toastCase.Expected)) { $saveTableFailures.Add("the reading of $($toastCase.Name) is '$toastActual'; noctty reads '$($toastCase.Expected)'") }
}
foreach ($toastCase in $saveVerdictRows) {
    $toastVerdict = Get-AccessibilitySaveLaunchVerdict -CommandLine $toastCase.Line
    if (-not (& $saveSame $toastVerdict $toastCase.Expected)) { $saveTableFailures.Add("the run-time verdict on $($toastCase.Name) is '$toastVerdict', not '$($toastCase.Expected)'") }
}
if ($saveTableFailures.Count -ne 0) { throw "Under PowerShell $($PSVersionTable.PSVersion): $($saveTableFailures -join '; ')." }
# The same tables under Windows PowerShell 5.1, whose comparisons ignore other
# characters than 7's: the composite starts its leaves with powershell.exe.
$saveDesktopPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
if (-not [IO.File]::Exists($saveDesktopPowerShell)) { throw "Windows PowerShell 5.1 is missing: $saveDesktopPowerShell." }
$saveEngineRows = @(
    foreach ($toastCase in $saveSettingsRows) { [ordered]@{ Kind = 'settings'; Arguments = @($toastCase.Arguments); Expected = $toastCase.Expected } }
    foreach ($toastCase in $saveVerdictRows) { [ordered]@{ Kind = 'verdict'; Line = $toastCase.Line; Expected = $toastCase.Expected } }
)
$saveEngineScript = $saveReadingText + "`n" + @'
# 5.1 writes a JSON array as one object; foreach takes it apart.
$rows = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($args[0])) | ConvertFrom-Json
$index = 0
foreach ($row in $rows) {
    if ([string]::Equals($row.Kind, 'settings', [StringComparison]::Ordinal)) {
        $s = Get-AccessibilityNotificationSettings -Arguments ([string[]]@($row.Arguments))
        $actual = "$($s.Desktop) $($s.ClipboardCopy) $($s.ConfigReload)"
    } else {
        $actual = Get-AccessibilitySaveLaunchVerdict -CommandLine $row.Line
    }
    if (-not [string]::Equals($actual, $row.Expected, [StringComparison]::Ordinal)) { "row $index`: '$actual', not '$($row.Expected)'" }
    $index++
}
"rows=$index"
'@
$saveEnginePath = Join-Path ([IO.Path]::GetTempPath()) ("noctty-contract-quiet-$([Guid]::NewGuid().ToString('N')).ps1")
try {
    [IO.File]::WriteAllText($saveEnginePath, $saveEngineScript, [Text.UTF8Encoding]::new($true))
    $saveEnginePayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $saveEngineRows -Depth 4 -Compress)))
    $saveEngineOutput = @(& $saveDesktopPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $saveEnginePath $saveEnginePayload 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or $saveEngineOutput.Count -ne 1 -or -not (& $saveSame $saveEngineOutput[0] "rows=$($saveEngineRows.Count)")) {
        throw "Under Windows PowerShell 5.1 the leaf's reading disagrees: $($saveEngineOutput -join '; ')."
    }
}
finally {
    if ([IO.File]::Exists($saveEnginePath)) { [IO.File]::Delete($saveEnginePath) }
}

# The run-time check itself, with the process lookup swapped for a stand-in:
# it reads the process it is given, by its id, writes nothing to any stream on
# any row (a quiet launch or one it stops), throws unless the launch is quiet,
# and never puts the command line in its error.
$saveAssertText = $saveRuntimeFunctions['Assert-AccessibilitySaveLaunchQuiet'].Extent.Text
$saveCimCall = 'CimCmdlets\Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction Stop'
if ([regex]::Matches($saveAssertText, [regex]::Escape($saveCimCall)).Count -ne 1 -or
    [regex]::Matches($saveAssertText, 'CimCmdlets\\Get-CimInstance').Count -ne 1) {
    throw 'Assert-AccessibilitySaveLaunchQuiet must read the command line of the process it is given, by its id, once.'
}
function script:Get-ToastContractCimInstance {
    param([string] $ClassName, [string] $Filter, $ErrorAction)
    $script:toastCimRead = "$ClassName|$Filter"
    if ($script:toastCimThrows) { throw 'the process has gone' }
    [pscustomobject]@{ CommandLine = $script:toastCimLine }
}
. ([scriptblock]::Create($saveAssertText.Replace('CimCmdlets\Get-CimInstance', 'Get-ToastContractCimInstance')))
try {
    $toastSelf = [System.Diagnostics.Process]::GetCurrentProcess()
    $toastMarker = 'w9marker' + [Guid]::NewGuid().ToString('N')
    foreach ($toastCase in @(
            @{ Name = 'a quiet launch'; Line = "$saveLaunchLine --title=$toastMarker --app-notifications=false --desktop-notifications=false"; Throws = $false; Fails = $false },
            @{ Name = 'an override'; Line = "$saveLaunchLine --title=$toastMarker --app-notifications=false --desktop-notifications=false --app-notifications=true"; Throws = $false; Fails = $true },
            @{ Name = 'an empty value'; Line = "$saveLaunchLine --title=$toastMarker --app-notifications=false --desktop-notifications=false --desktop-notifications="; Throws = $false; Fails = $true },
            @{ Name = 'a --config-file'; Line = "$saveLaunchLine --title=$toastMarker --config-file=$toastMarker --app-notifications=false --desktop-notifications=false"; Throws = $false; Fails = $true },
            @{ Name = 'a soft hyphen'; Line = "$saveLaunchLine --title=$toastMarker --app-notifications=fa${saveSoftHyphen}lse --desktop-notifications=false"; Throws = $false; Fails = $true },
            @{ Name = 'no command line'; Line = $null; Throws = $false; Fails = $true },
            @{ Name = 'a lookup that fails'; Line = $saveQuietLine; Throws = $true; Fails = $true }
        )) {
        $script:toastCimLine = $toastCase.Line
        $script:toastCimThrows = $toastCase.Throws
        $script:toastCimRead = $null
        $toastError = $null
        # Collected as it streams, so output written before a throw is seen too.
        $toastOutput = [Collections.Generic.List[object]]::new()
        try { Assert-AccessibilitySaveLaunchQuiet -Process $toastSelf -Description 'contract probe' 6>&1 5>&1 4>&1 3>&1 2>&1 | ForEach-Object { $toastOutput.Add($_) } }
        catch { $toastError = $_.Exception.Message }
        if (-not (& $saveSame $script:toastCimRead "Win32_Process|ProcessId = $($toastSelf.Id)")) {
            throw "Assert-AccessibilitySaveLaunchQuiet on $($toastCase.Name) read '$($script:toastCimRead)', not the process it was given."
        }
        if ($toastOutput.Count -ne 0) { throw "Assert-AccessibilitySaveLaunchQuiet wrote output on $($toastCase.Name)." }
        if ($toastCase.Fails -ne ($null -ne $toastError)) {
            throw "Assert-AccessibilitySaveLaunchQuiet $(if ($toastCase.Fails) { 'let through' } else { 'stopped' }) $($toastCase.Name)."
        }
        if ($null -ne $toastError -and ($toastError.Contains($toastMarker) -or $toastError.Contains('noctty.exe') -or
                -not $toastError.StartsWith('The contract probe did not start with every notification off: ', [StringComparison]::Ordinal))) {
            throw "Assert-AccessibilitySaveLaunchQuiet's error on $($toastCase.Name) is not the bare verdict."
        }
    }
}
finally {
    Remove-Item -LiteralPath Function:\Assert-AccessibilitySaveLaunchQuiet, Function:\Get-ToastContractCimInstance -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name toastCimLine, toastCimThrows, toastCimRead -ErrorAction SilentlyContinue
}

# The sandbox check, on files in scratch directories under a non-ASCII path:
# the template noctty writes at its first start (src\config\config-template,
# rendered as writeConfigTemplate renders it, with that path in a comment)
# passes once the sandbox may hold it; so does any byte in a comment or a
# value. Any other default file, an include in any spelling noctty could read
# as one (and the CR-split lines this check reads besides), a UTF-16 file, an
# environment that points elsewhere, or a save with its terminal window
# closed stops it. It writes nothing on any of them.
. ([scriptblock]::Create($saveRuntimeFunctions['Assert-AccessibilitySaveSandboxQuiet'].Extent.Text))
$saveSandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("noctty-contract-sandbox-$([Guid]::NewGuid().ToString('N'))")
try {
    $saveAscii = [Text.Encoding]::ASCII
    $saveUtf8 = [Text.UTF8Encoding]::new($false)
    $saveUnicodeDirectory = 'Jos' + [char]0x00E9
    $saveTemplateText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\config\config-template'))
    if (-not $saveTemplateText.Contains('{[path]s}')) { throw 'src\config\config-template no longer writes its path; render it again here.' }
    foreach ($toastCase in @(
            @{ Name = 'an empty sandbox before the first launch'; Files = @{}; Empty = $true; Fails = $false },
            @{ Name = 'the rendered template before the first launch'; Files = @{ 'noctty\config.ghostty' = 'template' }; Empty = $true; Fails = $true },
            @{ Name = 'the rendered template under a non-ASCII path before a save (Greptile, CodeRabbit)'; Files = @{ 'noctty\config.ghostty' = 'template' }; Empty = $false; Fails = $false },
            @{ Name = 'a saved file'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes("scrollback-limit = 10001`r`nwindow-theme = dark`n# config-file = notify.conf`n") }; Empty = $false; Fails = $false },
            @{ Name = 'a soft hyphen in a value'; Files = @{ 'noctty\config.ghostty' = $saveUtf8.GetBytes("font-family = a$([char]0x00AD)b`n") }; Empty = $false; Fails = $false },
            @{ Name = 'a soft hyphen inside the key (noctty reads no include)'; Files = @{ 'noctty\config.ghostty' = $saveUtf8.GetBytes("config-$([char]0x00AD)file = notify.conf`n") }; Empty = $false; Fails = $false },
            @{ Name = 'a form feed before the key (noctty trims only spaces and tabs)'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes("`fconfig-file = notify.conf`n") }; Empty = $false; Fails = $false },
            @{ Name = 'a legacy ghostty\config'; Files = @{ 'ghostty\config' = $saveAscii.GetBytes("`n") }; Empty = $false; Fails = $true },
            @{ Name = 'a pre-rename winghostty config'; Files = @{ 'winghostty\config.ghostty' = $saveAscii.GetBytes("`n") }; Empty = $false; Fails = $true },
            @{ Name = 'an include'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes("scrollback-limit = 1`nconfig-file = notify.conf`n") }; Empty = $false; Fails = $true },
            @{ Name = 'an include with no spaces, last'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes("scrollback-limit = 1`r`nconfig-file=notify.conf") }; Empty = $false; Fails = $true },
            @{ Name = 'an include with no value'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes("config-file`n") }; Empty = $false; Fails = $true },
            @{ Name = 'an include after a bare CR'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes("scrollback-limit = 1`rconfig-file=notify.conf") }; Empty = $false; Fails = $true },
            @{ Name = 'an indented include in another case'; Files = @{ 'noctty\config.ghostty' = $saveAscii.GetBytes(" `tCONFIG-FILE = notify.conf`n") }; Empty = $false; Fails = $true },
            @{ Name = 'an include after a UTF-8 byte order mark'; Files = @{ 'noctty\config.ghostty' = [byte[]](@(0xEF, 0xBB, 0xBF) + $saveAscii.GetBytes("config-file = notify.conf`n")) }; Empty = $false; Fails = $true },
            @{ Name = 'a UTF-16 file'; Files = @{ 'noctty\config.ghostty' = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("scrollback-limit = 1`n")) }; Empty = $false; Fails = $true },
            @{ Name = 'no XDG_CONFIG_HOME'; Files = @{}; Empty = $true; Fails = $true; NoHome = $true },
            @{ Name = 'another saved file than the environment reads'; Files = @{}; Empty = $true; Fails = $true; Elsewhere = $true },
            @{ Name = 'a save with its terminal window open'; Files = @{ 'noctty\config.ghostty' = 'template' }; Empty = $false; Fails = $false; HostOpen = $true },
            @{ Name = 'a build folder with no portable marker'; Files = @{ 'bin\noctty.exe' = $saveAscii.GetBytes('MZ') }; Empty = $true; Fails = $false; Exe = 'bin\noctty.exe' },
            @{ Name = 'noctty.portable beside the exe (Opus L2, round 6)'; Files = @{ 'bin\noctty.exe' = $saveAscii.GetBytes('MZ'); 'bin\noctty.portable' = $saveAscii.GetBytes("`n") }; Empty = $true; Fails = $true; Exe = 'bin\noctty.exe' },
            @{ Name = 'portable.txt beside the exe'; Files = @{ 'bin\noctty.exe' = $saveAscii.GetBytes('MZ'); 'bin\portable.txt' = $saveAscii.GetBytes("`n") }; Empty = $true; Fails = $true; Exe = 'bin\noctty.exe' },
            @{ Name = 'config.ghostty beside the exe'; Files = @{ 'bin\noctty.exe' = $saveAscii.GetBytes('MZ'); 'bin\config.ghostty' = $saveAscii.GetBytes("`n") }; Empty = $true; Fails = $true; Exe = 'bin\noctty.exe' },
            @{ Name = 'a save with its terminal window closed (CodeRabbit)'; Files = @{ 'noctty\config.ghostty' = 'template' }; Empty = $false; Fails = $true; HostOpen = $false }
        )) {
        $saveCaseRoot = Join-Path $saveSandboxRoot "$([Guid]::NewGuid().ToString('N'))\$saveUnicodeDirectory"
        foreach ($saveFile in $toastCase.Files.GetEnumerator()) {
            $saveFilePath = Join-Path $saveCaseRoot $saveFile.Key
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $saveFilePath))
            $saveBytes = if ($saveFile.Value -is [string]) { $saveUtf8.GetBytes($saveTemplateText.Replace('{[path]s}', $saveFilePath)) } else { [byte[]]$saveFile.Value }
            [IO.File]::WriteAllBytes($saveFilePath, $saveBytes)
        }
        [void][IO.Directory]::CreateDirectory($saveCaseRoot)
        $saveEnvironment = [ordered]@{ LOCALAPPDATA = $saveCaseRoot }
        if (-not $toastCase.ContainsKey('NoHome')) { $saveEnvironment['XDG_CONFIG_HOME'] = $saveCaseRoot }
        $saveSavedPath = if ($toastCase.ContainsKey('Elsewhere')) { Join-Path $saveSandboxRoot 'elsewhere\noctty\config.ghostty' } else { Join-Path $saveCaseRoot 'noctty\config.ghostty' }
        $saveArguments = @{ Environment = $saveEnvironment; SavedConfigPath = $saveSavedPath; When = 'in the contract'; Empty = [bool]$toastCase.Empty }
        if ($toastCase.ContainsKey('HostOpen')) { $saveArguments['HostOpen'] = $toastCase.HostOpen }
        if ($toastCase.ContainsKey('Exe')) { $saveArguments['ExecutablePath'] = Join-Path $saveCaseRoot $toastCase.Exe }
        $toastError = $null
        $toastOutput = [Collections.Generic.List[object]]::new()
        try { Assert-AccessibilitySaveSandboxQuiet @saveArguments 6>&1 5>&1 4>&1 3>&1 2>&1 | ForEach-Object { $toastOutput.Add($_) } }
        catch { $toastError = $_.Exception.Message }
        if ($toastCase.Fails -ne ($null -ne $toastError)) {
            throw "Assert-AccessibilitySaveSandboxQuiet $(if ($toastCase.Fails) { 'let through' } else { 'stopped' }) $($toastCase.Name)$(if ($toastError) { ": $toastError" })."
        }
        if ($toastOutput.Count -ne 0) { throw "Assert-AccessibilitySaveSandboxQuiet wrote output on $($toastCase.Name)." }
        if ($null -ne $toastError -and $toastError.Contains('notify.conf')) { throw "Assert-AccessibilitySaveSandboxQuiet quoted the file on $($toastCase.Name)." }
    }
}
finally {
    Remove-Item -LiteralPath Function:\Assert-AccessibilitySaveSandboxQuiet -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($saveSandboxRoot)) { [IO.Directory]::Delete($saveSandboxRoot, $true) }
}
# The launcher refuses an environment that names one variable twice, in two
# cases (an ordinal dictionary, as a changed library could return), before it
# sets anything or starts a process (Opus L1, round 6). The FilePath does not
# exist, so nothing could start even past the check.
. ([scriptblock]::Create($saveRuntimeFunctions['Start-AccessibilityProcessWithEnvironment'].Extent.Text))
try {
    $saveDuplicate = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $saveDuplicate['XDG_CONFIG_HOME'] = 'A'
    $saveDuplicate['Xdg_Config_Home'] = 'B'
    $saveMissing = Join-Path $repoRoot 'zig-out\no-such-dir\no-such-noctty.exe'
    $saveBefore = [System.Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', [System.EnvironmentVariableTarget]::Process)
    $toastError = $null
    try { $null = Start-AccessibilityProcessWithEnvironment -FilePath $saveMissing -ArgumentList @('x') -WorkingDirectory $repoRoot -EnvironmentVariables $saveDuplicate -RedirectStandardOutput $saveMissing -RedirectStandardError $saveMissing }
    catch { $toastError = $_.Exception.Message }
    if ($null -eq $toastError -or -not $toastError.StartsWith('The launch environment names ', [StringComparison]::Ordinal) -or
        -not [string]::Equals([System.Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', [System.EnvironmentVariableTarget]::Process), $saveBefore, [StringComparison]::Ordinal)) {
        throw 'Start-AccessibilityProcessWithEnvironment must refuse an environment that names one variable twice, in two cases, before it sets any.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Start-AccessibilityProcessWithEnvironment -ErrorAction SilentlyContinue
}

# (A) The pins, by SHA-256 of each region's text with LF line ends. An edit in
# a region must update its pin here, in the same change.
$saveLeafPins = [ordered]@{
    'save-functions' = '93DD4F853D407C2240DC8C936942AF1B006CDB0E23BF256A07B6AAFE29BC47BC'
    'save-sandbox' = '56CDC68B224423E2D1883BF14793EF52FC92FD43C9CE81D3DAD01DACFC26820C'
    'save-flow' = '05DFB5066F2C3613BE18E0594D6AED3E9E5E1A578245B5FF8EE7E092ACC2B010'
    'failure-path' = '2C488B0A4E92E3C4846520BE1F40C5D6FF7BA9B83BC7F175D588723D2DF859DE'
}
# Each region of a text: from its begin marker's line to its end marker's line,
# as offsets into that text, or a problem.
$saveRegionsOf = {
    param([string] $Text)
    $regions = [ordered]@{}
    $problems = [Collections.Generic.List[string]]::new()
    $begins = @([regex]::Matches($Text, '(?m)^[ \t]*# pin-begin: (?<name>[a-z-]+)[ \t]*\r?$'))
    $ends = @([regex]::Matches($Text, '(?m)^[ \t]*# pin-end: (?<name>[a-z-]+)[ \t]*(\r?\n|$)'))
    $beginNames = @($begins | ForEach-Object { $_.Groups['name'].Value })
    $endNames = @($ends | ForEach-Object { $_.Groups['name'].Value })
    $pinned = @($saveLeafPins.Keys)
    if (-not (& $saveSame ($beginNames -join ',') ($pinned -join ',')) -or -not (& $saveSame ($endNames -join ',') ($pinned -join ','))) {
        $problems.Add("the pinned regions begin '$($beginNames -join ',')' and end '$($endNames -join ',')' where '$($pinned -join ',')' are pinned")
    }
    for ($at = 0; $at -lt [Math]::Min($begins.Count, $ends.Count); $at++) {
        if (-not (& $saveSame $beginNames[$at] $endNames[$at]) -or $ends[$at].Index -lt $begins[$at].Index -or
            ($at + 1 -lt $begins.Count -and $begins[$at + 1].Index -lt $ends[$at].Index)) {
            $problems.Add("pinned region $($beginNames[$at]) does not end before the next begins")
            continue
        }
        $regions[$beginNames[$at]] = [pscustomobject]@{ Start = $begins[$at].Index; End = $ends[$at].Index + $ends[$at].Length }
    }
    [pscustomobject]@{ Regions = $regions; Problems = $problems }
}
$getSavePinProblems = {
    param([string] $Text)
    $lf = $Text.Replace("`r`n", "`n")
    $found = & $saveRegionsOf $lf
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($problem in $found.Problems) { $problems.Add($problem) }
    foreach ($name in $saveLeafPins.Keys) {
        $hash = 'missing'
        if ($found.Regions.Contains($name)) {
            $region = $found.Regions[$name]
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lf.Substring($region.Start, $region.End - $region.Start))))
        }
        if (-not (& $saveSame $hash $saveLeafPins[$name])) {
            $problems.Add("pinned region $name changed (SHA-256 $hash); review it and update its pin in Contracts.90-Workflows.ps1")
        }
    }
    $problems.ToArray()
}
$saveChangedRegions = {
    param([string] $Text)
    @(& $getSavePinProblems $Text | ForEach-Object { if ($_ -match '^pinned region (?<name>[a-z-]+) changed') { $Matches['name'] } else { 'markers' } } | Sort-Object -Unique) -join ','
}
$saveLeafPinProblems = @(& $getSavePinProblems $jobFileTexts[$accessibilityLeaf])
if ($saveLeafPinProblems.Count -ne 0) { throw "interactive-win11-accessibility.ps1: $($saveLeafPinProblems -join '; ')." }

$saveGrammarNames = @('settingsSaveNotificationArguments', 'saveProbeArguments', 'saveVerifyArguments', 'saveProbeClass', 'saveVerifyClass',
    'saveProbeProcess', 'saveVerifyProcess', 'saveProbe', 'saveVerifyProbe', 'verifyScrollback')
$saveGrammarSet = & $saveSet $saveGrammarNames
$saveVariableCmdlets = & $saveSet @('Set-Variable', 'New-Variable', 'Get-Variable', 'Remove-Variable', 'Clear-Variable', 'Set-Alias', 'New-Alias',
    'Invoke-Expression', 'Import-Alias', 'sv', 'set', 'nv', 'gv', 'rv', 'clv', 'sal', 'nal', 'iex', 'ipal')
$saveVariableParameters = @('OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'PipelineVariable')
$saveVariableAbbreviations = & $saveSet @('ov', 'ev', 'wv', 'iv', 'pv')
$saveDefinedSet = & $saveSet ($saveFunctionNames + @('Get-InteractiveWin11ContainmentArguments'))
$saveGuidPart = '$([Guid]::NewGuid().ToString(''N''))'
$isSingleQuoted = {
    param($Node)
    $Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $Node.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuoted
}
# A pipeline of exactly one element, not in the background, and no
# redirection; that element, or $null.
$soleElement = {
    param($Pipeline)
    if ($Pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $Pipeline.PipelineElements.Count -ne 1 -or $Pipeline.Background) { return $null }
    $element = $Pipeline.PipelineElements[0]
    if ($element.Redirections.Count -ne 0) { return $null }
    $element
}
# Forms through which a script could write a variable, define a function or
# alias, or run a command, by a name the source does not spell (item (4)).
$saveDynamicMembers = & $saveSet @('SessionState', 'SessionStateProxy', 'InvokeCommand', 'InvokeProvider')
$saveDynamicDrives = & $saveSet @('function', 'variable', 'alias')
$saveDynamicForms = {
    param($Index)
    $found = [Collections.Generic.List[object]]::new()
    foreach ($node in $Index.Variables) {
        if ($saveDynamicDrives.Contains("$($node.VariablePath.DriveName)") -or $saveFolded.Equals($node.VariablePath.UserPath, 'PSCmdlet')) { $found.Add($node) }
    }
    foreach ($node in $Index.Strings) { if ($node.Value -match '^(?i)\s*(function|variable|alias):') { $found.Add($node) } }
    foreach ($node in $Index.DataSections) { $found.Add($node) }
    foreach ($node in $Index.TypeExpressions) { if ($node.TypeName.FullName -match '^(?i)(System\.Management\.Automation\.)?scriptblock$') { $found.Add($node) } }
    foreach ($node in $Index.Converts) {
        if ($node.Type.TypeName.FullName -match '^(?i)(System\.Management\.Automation\.)?scriptblock$' -and
            $node.Child -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $found.Add($node) }
    }
    foreach ($node in $Index.Members) { if ($saveDynamicMembers.Contains($node.Member.Extent.Text)) { $found.Add($node) } }
    foreach ($node in $Index.Commands) {
        if ($node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Unknown) { continue }
        $target = $node.CommandElements[0]
        if ($target -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $target -is [System.Management.Automation.Language.VariableExpressionAst] -or
            $target -is [System.Management.Automation.Language.MemberExpressionAst] -or
            $target -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
        if ($target -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $inner = & $soleElement $target.Pipeline
            if ($inner -is [System.Management.Automation.Language.CommandAst] -and $saveFolded.Equals((& $saveCommandName $inner), 'Join-Path')) { continue }
        }
        $found.Add($node)
    }
    , $found.ToArray()
}
# `@( <statements> )` as a list of sole elements, or $null.
$arrayStatements = {
    param($Expression)
    if ($Expression -isnot [System.Management.Automation.Language.ArrayExpressionAst] -or $Expression.SubExpression.Traps.Count -ne 0) { return $null }
    $elements = [Collections.Generic.List[object]]::new()
    foreach ($statement in $Expression.SubExpression.Statements) {
        $element = & $soleElement $statement
        if ($null -eq $element) { return $null }
        $elements.Add($element)
    }
    , $elements.ToArray()
}
# Single-quoted strings: one, or an array literal of them; $null otherwise.
$singleQuotedList = {
    param($Expression)
    $items = if ($Expression -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($Expression.Elements) } else { @($Expression) }
    foreach ($item in $items) { if (-not (& $isSingleQuoted $item)) { return $null } }
    , [string[]]@($items | ForEach-Object { $_.Value })
}
# Is `$Node` inside the left side of an assignment, or written another way?
$isWritten = {
    param($Node)
    for ($at = $Node; $null -ne $at.Parent; $at = $at.Parent) {
        $parent = $at.Parent
        if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($parent.Left, $at)) { return $true }
        if ($parent -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            $parent.TokenKind -in @([System.Management.Automation.Language.TokenKind]::PlusPlus, [System.Management.Automation.Language.TokenKind]::MinusMinus,
                [System.Management.Automation.Language.TokenKind]::PostfixPlusPlus, [System.Management.Automation.Language.TokenKind]::PostfixMinusMinus)) { return $true }
        if ($parent -is [System.Management.Automation.Language.ConvertExpressionAst] -and $saveFolded.Equals($parent.Type.TypeName.FullName, 'ref')) { return $true }
        if ($parent -is [System.Management.Automation.Language.ForEachStatementAst] -and [object]::ReferenceEquals($parent.Variable, $at)) { return $true }
        if ($parent -is [System.Management.Automation.Language.ParameterAst]) { return $true }
        if ($parent -is [System.Management.Automation.Language.StatementAst] -or $parent -is [System.Management.Automation.Language.CommandAst]) { return $false }
    }
    $false
}
# The uses of a name in a script, any spelling PowerShell reads as it.
$saveUsesOf = {
    param($Index, [string] $Name)
    $list = $null
    if ($Index.VariablesByName.TryGetValue($Name, [ref]$list)) { , $list.ToArray() } else { , @() }
}
# The one plain `$name = ...` of a grammar variable, or $null when the name is
# spelled, written or named in any other way, in the leaf or another job script.
$soleWrite = {
    param($Index, [string] $Name, $Others)
    $plain = $null
    foreach ($use in (& $saveUsesOf $Index $Name)) {
        if (-not $saveFolded.Equals($use.VariablePath.UserPath, $Name)) { return $null }
        if (-not (& $isWritten $use)) { continue }
        $parent = $use.Parent
        if ($null -ne $plain -or $parent -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
            -not [object]::ReferenceEquals($parent.Left, $use) -or $parent.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { return $null }
        $plain = $parent
    }
    if ($Index.StringNames.Contains($Name)) { return $null }
    $named = $false
    if (-not $Others.Names.TryGetValue($Name, [ref]$named)) { $named = $Others.Joined.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0; $Others.Names[$Name] = $named }
    if ($named) { return $null }
    $plain
}
# What the grammar asks of the other job scripts, read once per text.
$saveOtherFacts = [Collections.Generic.Dictionary[string, object]]::new($saveOrdinal)
$summarizeOtherScripts = {
    param([hashtable] $Texts)
    $variableCmdlet = $false
    $definesSaved = $false
    $dynamicForms = $false
    $shadowsCmdlet = $false
    $defaultParameters = $false
    $functionNames = [Collections.Generic.HashSet[string]]::new($saveFolded)
    foreach ($other in $Texts.GetEnumerator()) {
        $key = $other.Key + [char]0 + $other.Value
        $facts = $null
        if (-not $saveOtherFacts.TryGetValue($key, [ref]$facts)) {
            $otherIndex = & $saveIndexOf $other.Value $other.Key
            $facts = [pscustomobject]@{
                VariableCmdlet = @($otherIndex.CommandsByName.Keys | Where-Object { $saveVariableCmdlets.Contains($_) }).Count -ne 0
                DefinesSaved = @($otherIndex.Functions | Where-Object {
                        $saveDefinedSet.Contains((& $saveBareName $_.Name)) -and
                            -not ((& $saveSame $other.Key 'scripts\interactive-win11-lib.ps1') -and (& $saveSame $_.Name 'Get-InteractiveWin11ContainmentArguments'))
                    }).Count -ne 0
                DynamicForms = (& $saveDynamicForms $otherIndex).Count -ne 0
                ShadowsCmdlet = @($otherIndex.Functions | Where-Object { $saveRegionCmdlets.Contains((& $saveBareName $_.Name)) }).Count -ne 0
                DefaultParameters = (& $saveUsesOf $otherIndex 'PSDefaultParameterValues').Count -ne 0
                FunctionNames = [string[]]@($otherIndex.Functions | ForEach-Object { & $saveBareName $_.Name })
            }
            $saveOtherFacts[$key] = $facts
        }
        if ($facts.VariableCmdlet) { $variableCmdlet = $true }
        if ($facts.DefinesSaved) { $definesSaved = $true }
        if ($facts.DynamicForms) { $dynamicForms = $true }
        if ($facts.ShadowsCmdlet) { $shadowsCmdlet = $true }
        if ($facts.DefaultParameters) { $defaultParameters = $true }
        foreach ($functionName in $facts.FunctionNames) { [void]$functionNames.Add($functionName) }
    }
    [pscustomobject]@{
        VariableCmdlet = $variableCmdlet; DefinesSaved = $definesSaved; DynamicForms = $dynamicForms; Joined = (@($Texts.Values) -join "`n")
        ShadowsCmdlet = $shadowsCmdlet; DefaultParameters = $defaultParameters; FunctionNames = $functionNames
        Names = [Collections.Generic.Dictionary[string, bool]]::new($saveFolded)
    }
}
# The arguments one launch gives noctty, or $null when any part is outside the
# grammar.
$readLaunchArguments = {
    param($Index, [string] $ArgumentsName, [string] $LibraryText, $Others)
    $write = & $soleWrite $Index $ArgumentsName $Others
    if ($null -eq $write) { return $null }
    $right = & $soleElement $write.Right
    if ($right -isnot [System.Management.Automation.Language.CommandExpressionAst] -and $write.Right -is [System.Management.Automation.Language.CommandExpressionAst]) { $right = $write.Right }
    if ($right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or $right.Redirections.Count -ne 0) { return $null }
    $elements = & $arrayStatements $right.Expression
    if ($null -eq $elements) { return $null }
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($element in $elements) {
        if ($element -is [System.Management.Automation.Language.CommandAst]) {
            if (-not (& $saveSame $element.GetCommandName() 'Get-InteractiveWin11ContainmentArguments') -or $element.CommandElements.Count -ne 1) { return $null }
            $library = & $saveIndexOf $LibraryText 'interactive-win11-lib.ps1'
            $definitions = @($library.Functions | Where-Object { $saveFolded.Equals((& $saveBareName $_.Name), 'Get-InteractiveWin11ContainmentArguments') })
            if ($definitions.Count -ne 1 -or -not (& $saveSame $definitions[0].Name 'Get-InteractiveWin11ContainmentArguments') -or
                $null -ne $definitions[0].Parameters -or $null -ne $definitions[0].Body.ParamBlock -or
                $null -ne $definitions[0].Body.BeginBlock -or $null -ne $definitions[0].Body.ProcessBlock -or $null -ne $definitions[0].Body.DynamicParamBlock -or
                $definitions[0].Body.EndBlock.Traps.Count -ne 0 -or $definitions[0].Body.EndBlock.Statements.Count -ne 1 -or
                $definitions[0].Body.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.ReturnStatementAst]) { return $null }
            $returned = & $soleElement $definitions[0].Body.EndBlock.Statements[0].Pipeline
            if ($returned -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
            $items = & $arrayStatements $returned.Expression
            if ($null -eq $items) { return $null }
            foreach ($item in $items) {
                if ($item -isnot [System.Management.Automation.Language.CommandExpressionAst] -or -not (& $isSingleQuoted $item.Expression)) { return $null }
                $resolved.Add($item.Expression.Value)
            }
            continue
        }
        if ($element -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
        $expression = $element.Expression
        if (& $isSingleQuoted $expression) { $resolved.Add($expression.Value); continue }
        if ($expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
            $expression.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::DoubleQuoted -and
            $expression.Value -cmatch '^--class=\$(?<name>[A-Za-z]+)$' -and $expression.NestedExpressions.Count -eq 1 -and
            $expression.NestedExpressions[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (& $saveSame $expression.NestedExpressions[0].VariablePath.UserPath $Matches['name']) -and $saveGrammarSet.Contains($Matches['name'])) {
            $classWrite = & $soleWrite $Index $Matches['name'] $Others
            if ($null -eq $classWrite -or $classWrite.Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
                $classWrite.Right.Redirections.Count -ne 0) { return $null }
            $class = $classWrite.Right.Expression
            if ($class -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                $class.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::DoubleQuoted -or
                $class.NestedExpressions.Count -ne 1 -or $class.NestedExpressions[0] -isnot [System.Management.Automation.Language.SubExpressionAst] -or
                -not (& $saveSame $class.NestedExpressions[0].Extent.Text $saveGuidPart) -or
                $class.Value -cnotmatch ('^(?<prefix>[A-Za-z0-9-]+)' + [regex]::Escape($saveGuidPart) + '$')) { return $null }
            $resolved.Add('--class=' + $Matches['prefix'] + ('0' * 32))
            continue
        }
        if ($expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            (& $saveSame $expression.VariablePath.UserPath 'settingsSaveNotificationArguments')) {
            $flagsWrite = & $soleWrite $Index 'settingsSaveNotificationArguments' $Others
            if ($null -eq $flagsWrite -or $flagsWrite.Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
                $flagsWrite.Right.Redirections.Count -ne 0) { return $null }
            $flags = $flagsWrite.Right.Expression
            if ($flags -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                $inner = & $arrayStatements $flags
                if ($null -eq $inner -or $inner.Count -ne 1 -or $inner[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
                $flags = $inner[0].Expression
            }
            $values = & $singleQuotedList $flags
            if ($null -eq $values) { return $null }
            foreach ($value in $values) { $resolved.Add($value) }
            continue
        }
        return $null
    }
    , [string[]]$resolved
}
# An argument the grammar lets through: printable ASCII, no space, no quote,
# no backtick.
$isPlainArgument = {
    param([string] $Value)
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 0x21 -or $code -gt 0x7E -or $code -eq 0x22 -or $code -eq 0x27 -or $code -eq 0x60) { return $false }
    }
    $true
}
$saveSandboxCalls = [ordered]@{
    FirstLaunchCheck = 'Assert-AccessibilitySaveSandboxQuiet -Environment $settingsProbeEnvironment -SavedConfigPath $sandboxConfigPath -When ''before the first launch'' -Empty -ExecutablePath $exe'
    ProbeSaveCheck = 'Assert-AccessibilitySaveSandboxQuiet -Environment $settingsProbeEnvironment -SavedConfigPath $sandboxConfigPath -When ''before the probe saves'' -HostOpen ([NocttyAccessibilityNative]::IsWindow($saveProbeHost))'
    VerifyStartCheck = 'Assert-AccessibilitySaveSandboxQuiet -Environment $settingsProbeEnvironment -SavedConfigPath $sandboxConfigPath -When ''before the verifier starts'' -ExecutablePath $exe'
    VerifySaveCheck = 'Assert-AccessibilitySaveSandboxQuiet -Environment $settingsProbeEnvironment -SavedConfigPath $sandboxConfigPath -When ''before the verifier saves'' -HostOpen ([NocttyAccessibilityNative]::IsWindow($saveVerifyHost))'
}
$testQuietSettingsSaves = {
    param([string] $Text, [string] $LibraryText, $Others)
    $index = & $saveIndexOf $Text 'interactive-win11-accessibility.ps1'
    # (4), the leaf-wide part.
    if ($index.CodeOutsideAscii) { return $false }
    foreach ($commandName in $index.CommandsByName.Keys) { if ($saveVariableCmdlets.Contains($commandName)) { return $false } }
    foreach ($parameter in $index.CommandParameters) {
        if ($saveVariableAbbreviations.Contains($parameter.ParameterName)) { return $false }
        foreach ($variableParameter in $saveVariableParameters) {
            $stem = $variableParameter.Length - 'ariable'.Length
            if ($parameter.ParameterName.Length -ge $stem -and $variableParameter.StartsWith($parameter.ParameterName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    if ((& $saveUsesOf $index 'ExecutionContext').Count -ne 0) { return $false }
    foreach ($pipeline in $index.Pipelines) { if ($pipeline.Background) { return $false } }
    if ($Others.VariableCmdlet -or $Others.DefinesSaved -or $Others.DynamicForms -or $Others.ShadowsCmdlet -or $Others.DefaultParameters) { return $false }
    # Opus L1, round 6: no default parameter values, and no function named,
    # in any scope, after a cmdlet the regions call. A function whose name
    # itself carries the module qualifier a region calls the cmdlet by
    # (`function Microsoft.PowerShell.Management\Start-Process`) still runs
    # for that call: the residual the README states.
    if ((& $saveUsesOf $index 'PSDefaultParameterValues').Count -ne 0) { return $false }
    foreach ($function in $index.Functions) { if ($saveRegionCmdlets.Contains((& $saveBareName $function.Name))) { return $false } }
    if ((& $saveDynamicForms $index).Count -ne 0) { return $false }
    foreach ($definedName in $saveDefinedSet) {
        $definitions = @($index.Functions | Where-Object { $saveFolded.Equals((& $saveBareName $_.Name), $definedName) })
        $wanted = if ($saveFolded.Equals($definedName, 'Get-InteractiveWin11ContainmentArguments')) { 0 } else { 1 }
        if ($definitions.Count -ne $wanted -or @($definitions | Where-Object { -not (& $saveSame $_.Name $definedName) }).Count -ne 0) { return $false }
    }
    # (2) and (3): the two launches and what each is given.
    $starts = @(& $saveCommandsNamed $index 'Start-AccessibilityProcessWithEnvironment')
    if ($starts.Count -ne 2) { return $false }
    $launched = @{}
    foreach ($process in @('saveProbeProcess', 'saveVerifyProcess')) {
        $write = & $soleWrite $index $process $Others
        if ($null -eq $write) { return $false }
        $start = & $soleElement $write.Right
        if ($start -isnot [System.Management.Automation.Language.CommandAst] -or -not (& $saveSame $start.GetCommandName() 'Start-AccessibilityProcessWithEnvironment')) { return $false }
        $argumentList = & $getNamedArgument $start 'ArgumentList'
        if ($argumentList -isnot [System.Management.Automation.Language.VariableExpressionAst] -or -not $saveGrammarSet.Contains($argumentList.VariablePath.UserPath)) { return $false }
        $resolvedArguments = & $readLaunchArguments $index $argumentList.VariablePath.UserPath $LibraryText $Others
        if ($null -eq $resolvedArguments) { return $false }
        # (6).
        foreach ($resolvedArgument in $resolvedArguments) { if (-not (& $isPlainArgument $resolvedArgument)) { return $false } }
        $effective = & $getEffectiveNotifications $resolvedArguments
        if ($effective.ConfigFile -or $effective.Desktop -or $effective.ClipboardCopy -or $effective.ConfigReload) { return $false }
        $launched[$process] = $start
    }
    if (@($starts | Where-Object { $s = $_; @($launched.Values | Where-Object { [object]::ReferenceEquals($_, $s) }).Count -eq 1 }).Count -ne 2) { return $false }
    foreach ($tie in @(
            @{ Name = 'saveProbe'; Command = 'Open-AccessibilitySettingsProbe'; Parameter = 'Process'; Source = 'saveProbeProcess' },
            @{ Name = 'saveVerifyProbe'; Command = 'Open-AccessibilitySettingsProbe'; Parameter = 'Process'; Source = 'saveVerifyProcess' },
            @{ Name = 'verifyScrollback'; Command = 'Get-AccessibilityScrollbackProbe'; Parameter = 'SettingsProbe'; Source = 'saveVerifyProbe' })) {
        $write = & $soleWrite $index $tie.Name $Others
        if ($null -eq $write) { return $false }
        $call = & $soleElement $write.Right
        if ($call -isnot [System.Management.Automation.Language.CommandAst] -or -not (& $saveSame $call.GetCommandName() $tie.Command)) { return $false }
        $source = & $getNamedArgument $call $tie.Parameter
        if ($source -isnot [System.Management.Automation.Language.VariableExpressionAst] -or -not (& $saveSame $source.VariablePath.UserPath $tie.Source)) { return $false }
    }
    # (1): the saves, on those probes. The probe's is the InvokePattern of the
    # close prompt's "Save and close" button, taken once by the pinned helper
    # into `$saveCloseInvoke` and invoked once, in save-flow.
    $saveCloses = [Collections.Generic.List[object]]::new()
    foreach ($close in @(@(& $saveCommandsNamed $index 'Invoke-AccessibilitySettingsCloseAction') + @(& $saveCommandsNamed $index 'Get-AccessibilitySettingsCloseActionInvoke'))) {
        $action = & $getNamedArgument $close 'ActionName'
        if (-not (& $isSingleQuoted $action)) { return $false }
        if (& $saveSame $action.Value 'Save and close') { $saveCloses.Add($close) }
    }
    if ($saveCloses.Count -ne 1 -or -not (& $saveSame $saveCloses[0].GetCommandName() 'Get-AccessibilitySettingsCloseActionInvoke')) { return $false }
    $closeProbe = & $getNamedArgument $saveCloses[0] 'SettingsProbe'
    if ($closeProbe -isnot [System.Management.Automation.Language.VariableExpressionAst] -or -not (& $saveSame $closeProbe.VariablePath.UserPath 'saveProbe')) { return $false }
    $closeWrite = & $soleWrite $index 'saveCloseInvoke' $Others
    if ($null -eq $closeWrite -or -not [object]::ReferenceEquals((& $soleElement $closeWrite.Right), $saveCloses[0]) -or
        (& $saveUsesOf $index 'saveCloseInvoke').Count -ne 2) { return $false }
    $closeInvokes = @($index.InvokeMembers | Where-Object {
            $saveFolded.Equals($_.Member.Extent.Text, 'Invoke') -and $_.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $saveFolded.Equals((& $saveBareName $_.Expression.VariablePath.UserPath), 'saveCloseInvoke')
        })
    if ($closeInvokes.Count -ne 1 -or -not (& $saveSame $closeInvokes[0].Extent.Text '$saveCloseInvoke.Invoke()')) { return $false }
    $saveInvokes = @($index.InvokeMembers | Where-Object {
            $saveFolded.Equals($_.Member.Extent.Text, 'TryGetCurrentPattern') -and
                $_.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and $saveFolded.Equals($_.Expression.Member.Extent.Text, 'Save')
        })
    if ($saveInvokes.Count -ne 1 -or $saveInvokes[0].Expression.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        -not (& $saveSame $saveInvokes[0].Expression.Expression.VariablePath.UserPath 'verifyScrollback')) { return $false }
    $restoreInvokes = @($index.InvokeMembers | Where-Object {
            $saveFolded.Equals($_.Member.Extent.Text, 'Invoke') -and $_.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $saveFolded.Equals((& $saveBareName $_.Expression.VariablePath.UserPath), 'restoreInvoke')
        })
    if ($restoreInvokes.Count -ne 1 -or -not (& $saveSame $restoreInvokes[0].Extent.Text '$restoreInvoke.Invoke()')) { return $false }
    if ([regex]::Matches($Text, $settingsSaves['a Settings Save invoke']).Count -ne 1 -or
        [regex]::Matches($Text, $settingsSaves['a Settings Save and close']).Count -ne 1) { return $false }
    # (4), the reads: the three arrays only where (3) puts them, the
    # environment only where the launches and the sandbox checks read it.
    foreach ($counted in @(
            @{ Name = 'settingsSaveNotificationArguments'; Uses = 3 }, @{ Name = 'saveProbeArguments'; Uses = 2 },
            @{ Name = 'saveVerifyArguments'; Uses = 2 }, @{ Name = 'settingsProbeEnvironment'; Uses = 7 })) {
        if ((& $saveUsesOf $index $counted.Name).Count -ne $counted.Uses) { return $false }
    }
    # (2), the environment both launches get, and the paths the checks read.
    foreach ($process in @('saveProbeProcess', 'saveVerifyProcess')) {
        $start = & $soleElement (& $soleWrite $index $process $Others).Right
        $environment = & $getNamedArgument $start 'EnvironmentVariables'
        if ($environment -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            -not (& $saveSame $environment.VariablePath.UserPath 'settingsProbeEnvironment')) { return $false }
    }
    $sandboxWrites = [ordered]@{}
    foreach ($pin in @(
            @{ Name = 'settingsProbeEnvironment'; Right = 'Get-InteractiveWin11Environment -Layout $settingsPersistenceLayout' },
            @{ Name = 'sandboxConfigPath'; Right = 'Microsoft.PowerShell.Management\Join-Path $settingsPersistenceLayout.LocalAppData ''noctty\config.ghostty''' })) {
        $write = & $soleWrite $index $pin.Name $Others
        if ($null -eq $write -or -not (& $saveSame $write.Right.Extent.Text $pin.Right)) { return $false }
        $sandboxWrites[$pin.Name] = $write
    }
    # (5), the terminal window each save's banner needs, taken once from its
    # process and read only by its pre-save check.
    foreach ($window in @(@{ Name = 'saveProbeHost'; Right = '$saveProbeProcess.MainWindowHandle' }, @{ Name = 'saveVerifyHost'; Right = '$saveVerifyProcess.MainWindowHandle' })) {
        $write = & $soleWrite $index $window.Name $Others
        if ($null -eq $write -or -not (& $saveSame $write.Right.Extent.Text $window.Right) -or (& $saveUsesOf $index $window.Name).Count -ne 2) { return $false }
    }
    $layoutWrite = & $soleWrite $index 'settingsPersistenceLayout' $Others
    $layoutCall = if ($null -ne $layoutWrite) { & $soleElement $layoutWrite.Right } else { $null }
    if ($layoutCall -isnot [System.Management.Automation.Language.CommandAst] -or
        -not (& $saveSame $layoutCall.GetCommandName() 'Get-InteractiveWin11SandboxLayout')) { return $false }
    $sandboxWrites['settingsPersistenceLayout'] = $layoutWrite
    # (5): one block holds the launches and every statement of (1), (2), (3)
    # and (7) and the sandbox checks, as direct statements, in order.
    $saveBlock = (& $soleWrite $index 'saveProbeProcess' $Others).Parent
    if ($saveBlock -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $false }
    $statements = @($saveBlock.Statements)
    $indexOf = {
        param($Statement)
        for ($i = 0; $i -lt $statements.Count; $i++) { if ([object]::ReferenceEquals($statements[$i], $Statement)) { return $i } }
        -1
    }
    $writeIndex = {
        param([string] $Name)
        $write = & $soleWrite $index $Name $Others
        if ($null -eq $write) { return -1 }
        & $indexOf $write
    }
    # A command's statement in that block: it must be a direct, sole,
    # foreground pipeline there.
    $statementOf = {
        param($Command)
        if ($null -eq (& $soleElement $Command.Parent)) { return -1 }
        & $indexOf $Command.Parent
    }
    $callIndex = {
        param([string] $Command, [string] $Parameter, [string] $Variable)
        $calls = @(& $saveCommandsNamed $index $Command | Where-Object {
                $value = & $getNamedArgument $_ $Parameter
                $value -is [System.Management.Automation.Language.VariableExpressionAst] -and (& $saveSame $value.VariablePath.UserPath $Variable)
            })
        if ($calls.Count -ne 1) { return -1 }
        & $statementOf $calls[0]
    }
    if (@(& $saveCommandsNamed $index 'Assert-AccessibilitySaveLaunchQuiet').Count -ne 2) { return $false }
    $sandboxChecks = @(& $saveCommandsNamed $index 'Assert-AccessibilitySaveSandboxQuiet')
    if ($sandboxChecks.Count -ne $saveSandboxCalls.Count) { return $false }
    $order = [ordered]@{}
    foreach ($sandboxCall in $saveSandboxCalls.GetEnumerator()) {
        $matching = @($sandboxChecks | Where-Object { & $saveSame $_.Extent.Text $sandboxCall.Value })
        $order[$sandboxCall.Key] = if ($matching.Count -eq 1) { & $statementOf $matching[0] } else { -1 }
    }
    $order['Flags'] = & $writeIndex 'settingsSaveNotificationArguments'
    $order['ProbeClass'] = & $writeIndex 'saveProbeClass'
    $order['ProbeArguments'] = & $writeIndex 'saveProbeArguments'
    $order['ProbeStart'] = & $writeIndex 'saveProbeProcess'
    $order['ProbeCheck'] = & $callIndex 'Assert-AccessibilitySaveLaunchQuiet' 'Process' 'saveProbeProcess'
    $order['ProbeHost'] = & $writeIndex 'saveProbeHost'
    $order['ProbeOpen'] = & $writeIndex 'saveProbe'
    $order['ProbeCloseGet'] = & $writeIndex 'saveCloseInvoke'
    $order['ProbeSave'] = & $indexOf ($closeInvokes[0].Parent.Parent)
    $order['ProbeStop'] = & $callIndex 'Stop-InteractiveWin11Process' 'Process' 'saveProbeProcess'
    $order['VerifyClass'] = & $writeIndex 'saveVerifyClass'
    $order['VerifyArguments'] = & $writeIndex 'saveVerifyArguments'
    $order['VerifyStart'] = & $writeIndex 'saveVerifyProcess'
    $order['VerifyCheck'] = & $callIndex 'Assert-AccessibilitySaveLaunchQuiet' 'Process' 'saveVerifyProcess'
    $order['VerifyHost'] = & $writeIndex 'saveVerifyHost'
    $order['VerifyOpen'] = & $writeIndex 'saveVerifyProbe'
    $order['VerifyScrollback'] = & $writeIndex 'verifyScrollback'
    $order['VerifySave'] = & $indexOf ($restoreInvokes[0].Parent.Parent)
    if (@($order.Values | Where-Object { $_ -lt 0 }).Count -ne 0) { return $false }
    foreach ($before in @(
            @('FirstLaunchCheck', 'ProbeStart'), @('Flags', 'ProbeArguments'), @('Flags', 'VerifyArguments'),
            @('ProbeClass', 'ProbeArguments'), @('ProbeArguments', 'ProbeStart'), @('ProbeStart', 'ProbeCheck'), @('ProbeCheck', 'ProbeHost'), @('ProbeHost', 'ProbeOpen'),
            @('ProbeOpen', 'ProbeCloseGet'), @('ProbeCloseGet', 'ProbeSaveCheck'), @('ProbeSaveCheck', 'ProbeSave'), @('ProbeSave', 'ProbeStop'), @('ProbeStop', 'VerifyStartCheck'),
            @('VerifyStartCheck', 'VerifyStart'), @('VerifyClass', 'VerifyArguments'), @('VerifyArguments', 'VerifyStart'), @('VerifyStart', 'VerifyCheck'),
            @('VerifyCheck', 'VerifyHost'), @('VerifyHost', 'VerifyOpen'), @('VerifyOpen', 'VerifyScrollback'), @('VerifyScrollback', 'VerifySaveCheck'), @('VerifySaveCheck', 'VerifySave'))) {
        if ($order[$before[0]] -ge $order[$before[1]]) { return $false }
    }
    # Each save is the statement right after its last check (Opus M, round 6).
    if ($order['ProbeSave'] -ne $order['ProbeSaveCheck'] + 1 -or $order['VerifySave'] -ne $order['VerifySaveCheck'] + 1) { return $false }
    # (7): that block is the leaf's normal-mode branch, a direct statement of
    # its main try, whose catch keeps the error and whose end throws it.
    $modeIf = $saveBlock.Parent
    if ($modeIf -isnot [System.Management.Automation.Language.IfStatementAst] -or -not [object]::ReferenceEquals($modeIf.ElseClause, $saveBlock) -or
        $modeIf.Clauses.Count -ne 2 -or -not (& $saveSame $modeIf.Clauses[0].Item1.Extent.Text '$ThemeDiagnosticOnly') -or
        -not (& $saveSame $modeIf.Clauses[1].Item1.Extent.Text '$ColdDiagnosticOnly')) { return $false }
    $mainBlock = $modeIf.Parent
    $mainTry = $mainBlock.Parent
    if ($mainBlock -isnot [System.Management.Automation.Language.StatementBlockAst] -or $mainTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
        -not [object]::ReferenceEquals($mainTry.Body, $mainBlock) -or $mainTry.CatchClauses.Count -ne 1 -or $mainTry.CatchClauses[0].CatchTypes.Count -ne 0 -or
        $mainTry.CatchClauses[0].Body.Statements.Count -ne 1 -or -not (& $saveSame $mainTry.CatchClauses[0].Body.Statements[0].Extent.Text '$runFailure = $_')) { return $false }
    $outerBlock = $mainTry.Parent
    if ($outerBlock -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $false }
    if (@((& $saveUsesOf $index 'runFailure') | Where-Object { & $isWritten $_ }).Count -ne 2) { return $false }
    $outerStatements = @($outerBlock.Statements)
    $outerAt = { param($Statement) for ($i = 0; $i -lt $outerStatements.Count; $i++) { if ([object]::ReferenceEquals($outerStatements[$i], $Statement)) { return $i } }; -1 }
    $messagesInit = @($outerStatements | Where-Object { & $saveSame $_.Extent.Text '$failureMessages = [System.Collections.Generic.List[string]]::new()' })
    $endIf = @($outerStatements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses.Count -eq 1 -and $null -eq $_.ElseClause -and
                (& $saveSame $_.Clauses[0].Item1.Extent.Text '$failureMessages.Count -gt 0') -and $_.Clauses[0].Item2.Statements.Count -eq 1 -and
                (& $saveSame $_.Clauses[0].Item2.Statements[0].Extent.Text 'throw "Accessibility validation failed: $($failureMessages -join '' | '')"')
        })
    $keepIf = @($outerStatements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses.Count -eq 1 -and $null -eq $_.ElseClause -and
                (& $saveSame $_.Clauses[0].Item1.Extent.Text '$null -ne $runFailure') -and
                @($_.Clauses[0].Item2.Statements | Where-Object {
                        (& $saveSame $_.Extent.Text '$failureMessages.Add("$($runFailure.Exception.Message)$failureLocation")') -and $null -ne (& $soleElement $_)
                    }).Count -eq 1
        })
    if ($messagesInit.Count -ne 1 -or $endIf.Count -ne 1 -or $keepIf.Count -ne 1) { return $false }
    $tryAt = & $outerAt $mainTry
    $initAt = & $outerAt $messagesInit[0]
    $keepAt = & $outerAt $keepIf[0]
    $endAt = & $outerAt $endIf[0]
    if (-not ($tryAt -lt $initAt -and $initAt -lt $keepAt -and $keepAt -lt $endAt)) { return $false }
    # (A): each pinned region holds what it guards.
    $found = & $saveRegionsOf $Text
    if ($found.Problems.Count -ne 0) { return $false }
    $within = {
        param($Node, [string] $Region)
        $r = $found.Regions[$Region]
        $null -ne $r -and $Node.Extent.StartOffset -ge $r.Start -and $Node.Extent.EndOffset -le $r.End
    }
    foreach ($function in @($index.Functions | Where-Object { $saveDefinedSet.Contains($_.Name) })) {
        if (-not (& $within $function 'save-functions')) { return $false }
    }
    foreach ($write in $sandboxWrites.Values) { if (-not (& $within $write 'save-sandbox')) { return $false } }
    foreach ($statementAt in $order.Values) { if (-not (& $within $statements[$statementAt] 'save-flow')) { return $false } }
    foreach ($guarded in @($mainTry.CatchClauses[0], $mainTry.Finally, $messagesInit[0], $keepIf[0], $endIf[0])) {
        if ($null -eq $guarded -or -not (& $within $guarded 'failure-path')) { return $false }
    }
    # A region calls only the cmdlets listed, `Start-Process` and `Join-Path`
    # by their module, or a function a job script defines; the save
    # functions press no button themselves.
    $inRegion = { param($Node) foreach ($r in $found.Regions.Values) { if ($Node.Extent.StartOffset -ge $r.Start -and $Node.Extent.EndOffset -le $r.End) { return $true } }; $false }
    $definedHere = [Collections.Generic.HashSet[string]]::new([string[]]@($index.Functions | ForEach-Object { & $saveBareName $_.Name }), $saveFolded)
    foreach ($command in $index.Commands) {
        if (-not (& $inRegion $command)) { continue }
        $written = $command.GetCommandName()
        if ($null -eq $written) { continue }
        $bare = & $saveCommandName $command
        if ($saveQualifiedCmdlets.ContainsKey($bare) -and -not (& $saveSame $written $saveQualifiedCmdlets[$bare])) { return $false }
        if (-not $saveRegionCmdlets.Contains($bare) -and -not $definedHere.Contains($bare) -and -not $saveLeafFunctionNames.Contains($bare) -and
            -not $Others.FunctionNames.Contains($bare)) { return $false }
    }
    foreach ($member in $index.InvokeMembers) {
        if ($saveFolded.Equals($member.Member.Extent.Text, 'Invoke') -and (& $within $member 'save-functions')) { return $false }
    }
    $true
}
# Every caller gets exactly one bool back, or the contract stops.
$runQuietCheck = {
    param([string] $Text, [string] $LibraryText, $Others)
    $result = @(& $testQuietSettingsSaves $Text $LibraryText $Others)
    if ($result.Count -ne 1 -or $result[0] -isnot [bool]) { throw "The quiet Settings save check returned '$($result -join ',')', not one bool." }
    $result[0]
}
$accessibilityText = $jobFileTexts[$accessibilityLeaf]
$launchLibraryText = $jobFileTexts['scripts\interactive-win11-lib.ps1']
$saveOtherTexts = @{}
foreach ($toastFile in $jobFiles) { if (-not (& $saveSame $toastFile $accessibilityLeaf)) { $saveOtherTexts[$toastFile] = $jobFileTexts[$toastFile] } }
$saveOthers = & $summarizeOtherScripts $saveOtherTexts
if (-not (& $runQuietCheck $accessibilityText $launchLibraryText $saveOthers)) {
    throw 'interactive-win11-accessibility.ps1 must save Settings only in its save probe and verifier processes, each started with every notification off and checked at run time before its save, in the grammar this contract states (Contracts.90-Workflows.ps1, EVIDENCE-TOAST-FOREGROUND); the grammar refuses the forms it does not list.'
}
# The leaf's finally blocks may not end it before its final throw (Sol M1,
# round 6: `exit 0` after `Assert-WindowsHarnessHistoryGuard` in the outer
# history `finally` kept all four pins and swallowed the throw). In every
# finally block, and in every function one calls, transitively (as defined in
# the leaf or another job script): no `exit`; no labeled `break` or
# `continue`, and none that is not inside a loop or switch of its own script
# block, since one in a `ForEach-Object` block unwinds past its caller. The
# parser itself refuses a `return`, `break` or `continue` that leaves a
# finally (ControlLeavingFinally, under PowerShell 7 and 5.1), and so does
# this check. `[Environment]::Exit(...)` and `$Host.SetShouldExit(...)` count as
# an `exit` (Opus L1, round 7), called or not and with the member's name
# quoted or not (Sol L, round 8), and so does a static `Exit` on any type
# (#733's shared Low). A finally may run a script block only
# inline or by a function's name. The flow statements inside the finally blocks themselves are pinned
# one by one ($saveFinallyFlows): today two loop `continue`s in cleanup loops
# and two `return`s of `Wait-AccessibilityCondition` script blocks; the
# outer history `finally` holds none.
$saveFinallyFlows = @{ 'continue' = 2; 'return $compoundExact' = 1; 'return -not [NocttyAccessibilityNative]::IsWindow($settingsHwnd)' = 1 }
$saveFlowTypes = @([System.Management.Automation.Language.ExitStatementAst], [System.Management.Automation.Language.ReturnStatementAst],
    [System.Management.Automation.Language.BreakStatementAst], [System.Management.Automation.Language.ContinueStatementAst])
$testFinallyFlow = {
    param([string] $Text, [hashtable] $OtherTexts)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { return $false }
    $definitions = [Collections.Generic.Dictionary[string, Collections.Generic.List[object]]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in @(@($ast) + @($OtherTexts.GetEnumerator() | ForEach-Object { & $parseToastScript $_.Value $_.Key }))) {
        foreach ($function in $source.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $bare = & $saveBareName $function.Name
            $list = $null
            if (-not $definitions.TryGetValue($bare, [ref]$list)) { $list = [Collections.Generic.List[object]]::new(); $definitions[$bare] = $list }
            $list.Add($function)
        }
    }
    # `[Environment]::Exit(...)` ends the process and `$Host.SetShouldExit(...)`
    # the host, as `exit` does (Opus L1, round 7). Any use of either member
    # counts, called or not (`[Environment]::Exit.Invoke(0)`), and a member is
    # matched by its value, so a quoted name counts too
    # (`[Environment]::'Exit'(0)`; Sol L, round 8). A static `Exit` counts on
    # any type, however the type is written (`([Environment])::Exit(0)`,
    # `$e::Exit(0)`, `[System.Environment, mscorlib]::Exit(0)`,
    # `([type]'System.Environment')::Exit(0)`; #733's shared Low). The
    # residual: a member named at run time (`[Environment]::$name(0)`), and
    # `ForEach-Object SetShouldExit`, which names the method as a command
    # argument.
    $isHostExit = {
        param($Node)
        if ($Node -isnot [System.Management.Automation.Language.MemberExpressionAst] -or
            $Node.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
        $member = $Node.Member.Value
        if ([string]::Equals($member, 'SetShouldExit', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $Node.Static -and [string]::Equals($member, 'Exit', [StringComparison]::OrdinalIgnoreCase)
    }
    $flowsIn = {
        param($Node)
        @($Node.FindAll({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.ExitStatementAst] -or $inner -is [System.Management.Automation.Language.ReturnStatementAst] -or
                        $inner -is [System.Management.Automation.Language.BreakStatementAst] -or $inner -is [System.Management.Automation.Language.ContinueStatementAst] -or
                        (& $isHostExit $inner)
                }, $true))
    }
    $endsEarly = {
        param($Flow)
        if ($Flow -is [System.Management.Automation.Language.ExitStatementAst] -or (& $isHostExit $Flow)) { return $true }
        if ($Flow -is [System.Management.Automation.Language.ReturnStatementAst]) { return $false }
        if ($null -ne $Flow.Label) { return $true }
        for ($at = $Flow.Parent; $null -ne $at; $at = $at.Parent) {
            if ($at -is [System.Management.Automation.Language.LoopStatementAst] -or $at -is [System.Management.Automation.Language.SwitchStatementAst]) { return $false }
            if ($at -is [System.Management.Automation.Language.ScriptBlockAst]) { return $true }
        }
        $true
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    $queued = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # In a finally block itself a script block runs only inline or by a
    # function's name; a function it calls may run one it is given.
    $enqueueCalls = {
        param($Node, [switch] $Finally)
        foreach ($command in $Node.FindAll({ param($inner) $inner -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ($Finally -and $command.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown -and
                $command.CommandElements[0] -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                $command.CommandElements[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
            $name = & $saveCommandName $command
            if ($null -ne $name -and $definitions.ContainsKey($name) -and $queued.Add($name)) { $queue.Enqueue($name) }
        }
        $true
    }
    $seen = @{}
    # A flow statement inside nested finally blocks counts once.
    $counted = [Collections.Generic.HashSet[int]]::new()
    foreach ($try in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $node.Finally }, $true)) {
        foreach ($flow in (& $flowsIn $try.Finally)) {
            if (& $endsEarly $flow) { return $false }
            if ($counted.Add($flow.Extent.StartOffset)) { $seen[$flow.Extent.Text] = 1 + [int]$seen[$flow.Extent.Text] }
        }
        if (-not (& $enqueueCalls $try.Finally -Finally)) { return $false }
    }
    foreach ($flowText in $seen.Keys) {
        if (-not $saveFinallyFlows.ContainsKey($flowText) -or $seen[$flowText] -gt $saveFinallyFlows[$flowText]) { return $false }
    }
    while ($queue.Count -ne 0) {
        foreach ($function in $definitions[$queue.Dequeue()]) {
            foreach ($flow in (& $flowsIn $function.Body)) { if (& $endsEarly $flow) { return $false } }
            if (-not (& $enqueueCalls $function.Body)) { return $false }
        }
    }
    $true
}
if (-not (& $testFinallyFlow $accessibilityText $saveOtherTexts)) {
    throw 'interactive-win11-accessibility.ps1''s finally blocks, and what they call, must not end it before its final throw: no exit, no static Exit (as [Environment]::Exit) or $Host.SetShouldExit, no break or continue outside a loop of its own script block, and only the flow statements pinned in $saveFinallyFlows.'
}
$toastHistoryFinally = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n}"
foreach ($toastControl in @(
        @{ Name = 'exit 0 after the history guard (Sol M1, round 6)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    exit 0`n}" },
        @{ Name = 'return after the history guard'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    return`n}" },
        @{ Name = 'break inside a ForEach-Object block in the history finally'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    1 | ForEach-Object { break }`n}" },
        @{ Name = 'a script block run by variable in the history finally'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    & `$historyCleanup`n}" },
        @{ Name = 'a new loop continue in the main finally'; From = "catch {`n    `$runFailure = `$_`n}`nfinally {`n"; To = "catch {`n    `$runFailure = `$_`n}`nfinally {`n    foreach (`$unused in @()) { continue }`n" },
        @{ Name = 'exit in a function the leaf''s finally calls'; From = "    if (-not `$Existed) {`n"; To = "    exit 0`n    if (-not `$Existed) {`n" },
        @{ Name = '[Environment]::Exit after the history guard (Opus L1, round 7)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    [Environment]::Exit(0)`n}" },
        @{ Name = '$Host.SetShouldExit after the history guard (Opus L1, round 7)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    `$Host.SetShouldExit(0)`n}" },
        @{ Name = '[System.Environment]::Exit in a function the main finally calls (Opus L1, round 7)'; From = "function Stop-AccessibilityEditEventCapture {`n"; To = "function Stop-AccessibilityEditEventCapture {`n    if (`$null -ne `$runFailure) { [System.Environment]::Exit(0) }`n" },
        @{ Name = '[Environment]::''Exit'' in a function the main finally calls (Sol L, round 8)'; From = "function Stop-AccessibilityEditEventCapture {`n"; To = "function Stop-AccessibilityEditEventCapture {`n    if (`$null -ne `$runFailure) { [Environment]::'Exit'(0) }`n" },
        @{ Name = '[Environment]::"Exit" after the history guard (Sol L, round 8)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    [Environment]::`"Exit`"(0)`n}" },
        @{ Name = '$Host.''SetShouldExit'' in a function the main finally calls (Sol L, round 8)'; From = "function Stop-AccessibilityEditEventCapture {`n"; To = "function Stop-AccessibilityEditEventCapture {`n    if (`$null -ne `$runFailure) { `$Host.'SetShouldExit'(0) }`n" },
        @{ Name = '$Host."SetShouldExit" after the history guard (Sol L, round 8)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    `$Host.`"SetShouldExit`"(0)`n}" },
        @{ Name = '[Environment]::Exit.Invoke in a function the main finally calls'; From = "function Stop-AccessibilityEditEventCapture {`n"; To = "function Stop-AccessibilityEditEventCapture {`n    if (`$null -ne `$runFailure) { [Environment]::Exit.Invoke(0) }`n" },
        @{ Name = '$Host.SetShouldExit.Invoke after the history guard'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    `$Host.SetShouldExit.Invoke(0)`n}" },
        @{ Name = 'an assembly-qualified [System.Environment, mscorlib]::''Exit'' in a function the main finally calls (#733)'; From = "function Stop-AccessibilityEditEventCapture {`n"; To = "function Stop-AccessibilityEditEventCapture {`n    if (`$null -ne `$runFailure) { [System.Environment, mscorlib]::'Exit'(0) }`n" },
        @{ Name = '([Environment])::Exit after the history guard (#733)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    ([Environment])::Exit(0)`n}" },
        @{ Name = '$e::Exit on a type held in a variable, in a function the main finally calls (#733)'; From = "function Stop-AccessibilityEditEventCapture {`n"; To = "function Stop-AccessibilityEditEventCapture {`n    `$exitType = [Environment]`n    if (`$null -ne `$runFailure) { `$exitType::Exit(0) }`n" },
        @{ Name = '([type]''System.Environment'')::Exit after the history guard (#733)'; From = $toastHistoryFinally; To = "} finally {`n    Assert-WindowsHarnessHistoryGuard -Guard `$windowsHarnessHistoryGuard`n    ([type]'System.Environment')::Exit(0)`n}" }
    )) {
    $toastMutated = $accessibilityText
    if (([regex]::Matches($toastMutated, [regex]::Escape($toastControl.From))).Count -ne 1) { throw "Finally-flow control '$($toastControl.Name)' lost its anchor." }
    $toastMutated = $toastMutated.Replace($toastControl.From, $toastControl.To)
    if (& $testFinallyFlow $toastMutated $saveOtherTexts) { throw "The finally-flow check accepted $($toastControl.Name)." }
}
$toastLibraryExit = $saveOtherTexts.Clone()
$toastLibraryExit['scripts\interactive-win11-lib.ps1'] = $toastLibraryExit['scripts\interactive-win11-lib.ps1'].Replace('function Stop-InteractiveWin11Process {', "function Stop-InteractiveWin11Process {`n    exit 0")
if ([string]::Equals($toastLibraryExit['scripts\interactive-win11-lib.ps1'], $saveOtherTexts['scripts\interactive-win11-lib.ps1'], [StringComparison]::Ordinal) -or
    (& $testFinallyFlow $accessibilityText $toastLibraryExit)) {
    throw 'The finally-flow check accepted an exit in a library function the leaf''s finally blocks call.'
}

# The leaf without what the saves never touch, for the controls below. Inside
# the leaf's top-level block, its normal-mode block and its two diagnostic
# branches, every character outside the pinned regions, the main try and the
# `$runFailure = $null` it starts from is cut (a cut between statements
# leaves a line end): the other functions, the other checks and the comments
# between them. A parse of it is a fraction of the leaf's. It holds every
# pinned region byte for byte (the same pins) and passes the same grammar.
$saveLeafRegions = (& $saveRegionsOf $accessibilityText).Regions
$saveModeIf = (& $soleWrite $saveLeafIndex 'saveProbeProcess' $saveOthers).Parent.Parent
$saveMainTry = $saveModeIf.Parent.Parent
$saveOuterBlock = $saveMainTry.Parent
$saveCuts = [Collections.Generic.List[object]]::new()
$saveCutAround = {
    param($Block, [object[]] $Kept)
    $spans = @(@($Kept | ForEach-Object { [pscustomobject]@{ Start = $_.Extent.StartOffset; End = $_.Extent.EndOffset } }) +
        @($saveLeafRegions.Values | Where-Object { $_.Start -ge $Block.Extent.StartOffset -and $_.End -le $Block.Extent.EndOffset }) |
        Sort-Object Start)
    $at = $Block.Extent.StartOffset + 1
    foreach ($span in $spans) {
        if ($span.Start -gt $at) { $saveCuts.Add([pscustomobject]@{ Start = $at; End = $span.Start }) }
        if ($span.End -gt $at) { $at = $span.End }
    }
    if ($Block.Extent.EndOffset - 1 -gt $at) { $saveCuts.Add([pscustomobject]@{ Start = $at; End = $Block.Extent.EndOffset - 1 }) }
}
$saveRunFailureInit = @($saveOuterBlock.Statements | Where-Object { & $saveSame $_.Extent.Text '$runFailure = $null' })
if ($saveRunFailureInit.Count -ne 1) { throw 'interactive-win11-accessibility.ps1 must start from $runFailure = $null.' }
& $saveCutAround $saveOuterBlock @($saveMainTry, $saveRunFailureInit[0])
& $saveCutAround $saveModeIf.ElseClause @()
foreach ($saveClause in $saveModeIf.Clauses) { & $saveCutAround $saveClause.Item2 @() }
$saveFixture = $accessibilityText
foreach ($saveCut in @($saveCuts | Sort-Object Start -Descending)) {
    $saveFixture = $saveFixture.Remove($saveCut.Start, $saveCut.End - $saveCut.Start).Insert($saveCut.Start, "`n")
}
if (@(& $getSavePinProblems $saveFixture).Count -ne 0 -or -not (& $runQuietCheck $saveFixture $launchLibraryText $saveOthers) -or
    $saveFixture.Length -ge $accessibilityText.Length / 2) {
    throw 'The quiet Settings save controls must run on the leaf less what the saves never touch, and that must keep the pins and pass the grammar.'
}
$toastEol = "`n"
$saveSandboxFirst = "    $($saveSandboxCalls['FirstLaunchCheck'])`n"
$saveSandboxProbeSave = "    $($saveSandboxCalls['ProbeSaveCheck'])`n"
$saveSandboxVerifyStart = "    $($saveSandboxCalls['VerifyStartCheck'])`n"
$saveSandboxVerifySave = "    $($saveSandboxCalls['VerifySaveCheck'])`n"
$toastQuietLine = "        '--command=cmd.exe'`n        `$settingsSaveNotificationArguments`n"
$toastProbeArguments = "`"--class=`$saveProbeClass`"`n$toastQuietLine"
$toastVerifyArguments = "`"--class=`$saveVerifyClass`"`n$toastQuietLine"
$toastQuietValue = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=false')"
$toastProbeClass = "    `$saveProbeClass = "
$toastProbeStart = "    `$saveProbeProcess = Start-AccessibilityProcessWithEnvironment"
$toastProbeOpen = "    `$saveProbe = Open-AccessibilitySettingsProbe"
$toastCleanup = "    `$saveProbeCleanup = `$saveProbeProcess`n"
$toastProbeCheck = "    Assert-AccessibilitySaveLaunchQuiet -Process `$saveProbeProcess -Description 'settings save probe'`n"
$toastVerifyCheck = "    Assert-AccessibilitySaveLaunchQuiet -Process `$saveVerifyProcess -Description 'settings persistence verifier'`n"
$toastProbeOpenLine = "    `$saveProbe = Open-AccessibilitySettingsProbe -Process `$saveProbeProcess -Description 'settings save probe'`n"
$toastPipelineExtra = "    `$settingsLaunchExtra = @('--title=review' | ForEach-Object { '--app-notifications=true' })`n"
$toastProbeSaveOld = "    Invoke-AccessibilitySettingsCloseAction ``$toastEol        -SettingsProbe `$saveProbe ``$toastEol        -ActionName 'Save and close' ``$toastEol        -Description 'settings save probe'`n"
$toastProbeSave = "    `$saveCloseInvoke.Invoke()`n"
$toastCloseGet = "    `$saveCloseInvoke = Get-AccessibilitySettingsCloseActionInvoke ``$toastEol        -SettingsProbe `$saveProbe ``"
$toastHelperEnd = "        throw `"`$Description action '`$ActionName' exposes no InvokePattern.`"`n    }`n    `$invoke`n}`n"
$toastOpusWrite = "    if (`$ActionName -ceq 'Save and close') {`n        `$legacyDirectory = Microsoft.PowerShell.Management\Join-Path `$settingsPersistenceLayout.LocalAppData 'ghostty'`n        [System.IO.Directory]::CreateDirectory(`$legacyDirectory) | Out-Null`n        [System.IO.File]::WriteAllText((Microsoft.PowerShell.Management\Join-Path `$legacyDirectory 'config'), `"config-file = notify.conf``n`")`n    }`n"
$toastRunFailureInit = "`$runFailure = `$null`n"
$toastKeepAdd = "    `$failureMessages.Add(`"`$(`$runFailure.Exception.Message)`$failureLocation`")`n"
$toastPreamble = "try {`n    `$deadline = [DateTime]::UtcNow.AddSeconds(`$TimeoutSeconds)`n"
# Each control edits the fixture; `Accept` is the grammar's answer and `Pin`
# the regions whose pins it breaks ('' for none: the grammar alone refuses it).
foreach ($toastControl in @(
        # What the leaf has, with the flags written the other allowed way.
        @{ Name = 'the flags as a bare array literal (in the grammar)'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = '--app-notifications=false', '--desktop-notifications=false'"; Accept = $true; Pin = 'save-flow' },
        @{ Name = 'an override before the flags (the flags win)'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--app-notifications=true'`n$toastQuietLine"; Accept = $true; Pin = 'save-flow' },
        @{ Name = 'empty values before the flags (the flags win)'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--app-notifications='`n        '--desktop-notifications='`n$toastQuietLine"; Accept = $true; Pin = 'save-flow' },
        # Values the grammar lets through and the reading refuses.
        @{ Name = 'the save probe without the flags'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--command=cmd.exe'`n"; Accept = $false },
        @{ Name = 'the verifier without the flags'; From = $toastVerifyArguments; To = "`"--class=`$saveVerifyClass`"`n        '--command=cmd.exe'`n"; Accept = $false },
        @{ Name = 'config-reload left on'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=no-clipboard-copy', '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'clipboard-copy left on'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=no-config-reload', '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'desktop notifications left on'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=true')"; Accept = $false },
        @{ Name = 'a later value in the flags themselves'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=false', '--app-notifications=no-clipboard-copy')"; Accept = $false },
        @{ Name = 'app notifications turned back on after the flags'; From = $toastProbeArguments; To = "$toastProbeArguments        '--app-notifications=true'`n"; Accept = $false },
        @{ Name = 'a bare desktop flag after the flags'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--desktop-notifications'`n"; Accept = $false },
        @{ Name = 'desktop notifications as 1 after the flags'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--desktop-notifications=1'`n"; Accept = $false },
        @{ Name = 'an empty app value after the flags'; From = $toastProbeArguments; To = "$toastProbeArguments        '--app-notifications='`n"; Accept = $false },
        @{ Name = 'an empty desktop value after the flags'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--desktop-notifications='`n"; Accept = $false },
        @{ Name = 'a config-file include'; From = $toastProbeArguments; To = "$toastProbeArguments        '--config-file=?C:\x\notify.conf'`n"; Accept = $false },
        @{ Name = 'a later option inside one element'; From = $toastProbeArguments; To = "$toastProbeArguments        '--command=cmd.exe --app-notifications=true'`n"; Accept = $false },
        @{ Name = 'a later option inside a title element'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--title=x --app-notifications=true'`n"; Accept = $false },
        @{ Name = 'a quote inside an element'; From = $toastProbeArguments; To = "$toastProbeArguments        '--title=`"x`"'`n"; Accept = $false },
        @{ Name = 'whitespace in the class prefix'; From = "`$saveProbeClass = `"noctty-accessibility-settings-save-"; To = "`$saveProbeClass = `"noctty-accessibility settings-save-"; Accept = $false },
        # Round 5's byte-exact reading (Opus M): characters PowerShell's
        # comparisons ignore.
        @{ Name = 'a soft hyphen inside false in the flags (Opus M, round 5)'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=fa${saveSoftHyphen}lse', '--desktop-notifications=false')"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'a control character inside false in the flags (Opus M, round 5)'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=fa${saveControl}lse', '--desktop-notifications=false')"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'a soft hyphen inside -e, then an override, in both (Opus M, round 5)'; From = $toastProbeArguments; To = "$toastProbeArguments        '-${saveSoftHyphen}e'`n        '--app-notifications=true'`n"; Then = @(, @($toastVerifyArguments, "$toastVerifyArguments        '-${saveSoftHyphen}e'`n        '--app-notifications=true'`n")); Accept = $false; Pin = 'save-flow' },
        @{ Name = 'a control character inside -e, then an override (Opus M, round 5)'; From = $toastProbeArguments; To = "$toastProbeArguments        '-${saveControl}e'`n        '--app-notifications=true'`n"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'a tab inside an element'; From = $toastProbeArguments; To = "$toastProbeArguments        '--title=a`tb'`n"; Accept = $false; Pin = 'save-flow' },
        # Forms outside the grammar. Round 3's (Sol M, Opus L1-L3) first.
        @{ Name = 'a pipeline in another array after the flags (Sol M, round 3)'; From = $toastProbeClass; To = "$toastPipelineExtra$toastProbeClass"; Then = @(@($toastProbeArguments, "$toastProbeArguments        `$settingsLaunchExtra`n"), @($toastVerifyArguments, "$toastVerifyArguments        `$settingsLaunchExtra`n")); Accept = $false },
        @{ Name = 'a leaf-local containment function (Opus L1, round 3)'; From = $toastProbeClass; To = "    function Get-InteractiveWin11ContainmentArguments { return @('--linux-cgroup=always', '-e', 'cmd.exe') }`n$toastProbeClass"; Accept = $false },
        @{ Name = '-OutVariable +flags (Opus L2, round 3)'; From = $toastProbeClass; To = "    Write-Output '--app-notifications=true' -OutVariable +settingsSaveNotificationArguments | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = 'another process for the save (Opus L3, round 3)'; From = $toastProbeOpen; To = "    `$saveProbeProcess = Start-Process -FilePath `$exe -ArgumentList @(Get-InteractiveWin11ContainmentArguments; '--single-instance=false') -PassThru`n$toastProbeOpen"; Accept = $false },
        @{ Name = 'a pipeline in the flags'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=false' | ForEach-Object { `$_ })"; Accept = $false },
        @{ Name = 'a double-quoted flag'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @(`"--app-notifications=false`", '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'a here-string flag'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @(@'`n--app-notifications=false`n'@, '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'a subexpression flag'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', `$('--desktop-notifications=false'))"; Accept = $false },
        @{ Name = 'a call in the flags'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', (Get-QuietFlag))"; Accept = $false },
        @{ Name = 'an operator in the flags'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=' + 'false', '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'a variable in the flags'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', `$desktopFlag)"; Accept = $false },
        @{ Name = 'two statements in the flags'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false'; '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'an array sum as the flags'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false') + @('--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'a redirection in the launch array'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--command=cmd.exe' 2>`$null`n        `$settingsSaveNotificationArguments`n"; Accept = $false },
        @{ Name = 'a containment call with an argument'; From = "    `$saveProbeArguments = @(`n        Get-InteractiveWin11ContainmentArguments`n"; To = "    `$saveProbeArguments = @(`n        Get-InteractiveWin11ContainmentArguments -Extra`n"; Accept = $false },
        @{ Name = 'the class through a subexpression'; From = "        `"--class=`$saveProbeClass`"`n"; To = "        `"--class=`$(`$saveProbeClass)`"`n"; Accept = $false },
        @{ Name = 'the class from an environment value'; From = "`$saveProbeClass = `"noctty-accessibility-settings-save-`$([Guid]::NewGuid().ToString('N'))`""; To = "`$saveProbeClass = `"noctty-accessibility-settings-save-`$env:USERNAME`""; Accept = $false },
        @{ Name = '-OutVariable flags'; From = $toastProbeClass; To = "    Write-Output '--app-notifications=true' -OutVariable settingsSaveNotificationArguments | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = '-ov +flags'; From = $toastProbeClass; To = "    Write-Output '--app-notifications=true' -ov +settingsSaveNotificationArguments | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = '-PipelineVariable flags'; From = $toastProbeClass; To = "    '--app-notifications=true' | ForEach-Object -PipelineVariable settingsSaveNotificationArguments { `$_ } | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = 'an -OutVar abbreviation'; From = $toastProbeClass; To = "    Write-Output 'x' -OutVar unrelatedOutput | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = 'Set-Variable on the flags'; From = $toastProbeClass; To = "    Set-Variable -Name settingsSaveNotificationArguments -Value @('--app-notifications=true')`n$toastProbeClass"; Accept = $false },
        @{ Name = 'a module-qualified Set-Variable on a built name (Sol L, round 5)'; From = $toastProbeClass; To = "    Microsoft.PowerShell.Utility\Set-Variable -Name ('settingsSaveNotificationArgu' + 'ments') -Value @('--app-notifications=true', '--desktop-notifications=false')`n$toastProbeClass"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'a scoped write to the flags'; From = $toastProbeClass; To = "    `$script:settingsSaveNotificationArguments = @('--app-notifications=true')`n$toastProbeClass"; Accept = $false },
        @{ Name = 'an index write to the flags'; From = $toastProbeClass; To = "    `$settingsSaveNotificationArguments[0] = '--app-notifications=true'`n$toastProbeClass"; Accept = $false },
        @{ Name = 'an index write to the arguments'; From = $toastProbeStart; To = "    `$saveProbeArguments[-1] = '--desktop-notifications=true'`n$toastProbeStart"; Accept = $false },
        @{ Name = 'a += to the arguments'; From = $toastProbeStart; To = "    `$saveProbeArguments += '--app-notifications=true'`n$toastProbeStart"; Accept = $false },
        @{ Name = 'the flags passed by [ref]'; From = $toastProbeClass; To = "    Update-Flags ([ref]`$settingsSaveNotificationArguments)`n$toastProbeClass"; Accept = $false },
        @{ Name = 'a loop over the arguments name'; From = $toastProbeClass; To = "    foreach (`$saveProbeArguments in @()) { }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'a parameter named like the process'; From = $toastProbeClass; To = "    function Use-SaveProcess([object] `$saveProbeProcess) { }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'the class name set twice'; From = "    `$saveProbeArguments = @("; To = "    `$saveProbeClass = 'other'`n    `$saveProbeArguments = @("; Accept = $false },
        @{ Name = 'the process set to null again'; From = $toastCleanup; To = "$toastCleanup    `$saveProbeProcess = `$null`n"; Accept = $false },
        @{ Name = 'the probe opened again'; From = "    `$saveScrollback = Get-AccessibilityScrollbackProbe"; To = "    `$saveProbe = Open-AccessibilitySettingsProbe -Process `$saveVerifyProcess -Description 'x'`n    `$saveScrollback = Get-AccessibilityScrollbackProbe"; Accept = $false },
        @{ Name = 'a third launch'; From = $toastProbeOpen; To = "    `$extraProcess = Start-AccessibilityProcessWithEnvironment -FilePath `$exe -ArgumentList `$saveProbeArguments -WorkingDirectory `$repoRoot -EnvironmentVariables `$settingsProbeEnvironment -RedirectStandardOutput 'a' -RedirectStandardError 'b'`n$toastProbeOpen"; Accept = $false },
        @{ Name = 'Invoke-Expression in the leaf'; From = $toastProbeClass; To = "    Invoke-Expression 'Write-Output 1' | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = '$ExecutionContext in the leaf'; From = $toastProbeClass; To = "    `$ExecutionContext.SessionState.PSVariable.Set('unrelated', 1)`n$toastProbeClass"; Accept = $false },
        @{ Name = 'a save action that is not literal'; From = "        -ActionName 'Save and close' ``"; To = "        -ActionName `$saveAction ``"; Accept = $false },
        @{ Name = 'a second Save invoke'; From = '    $restoreInvoke.Invoke()'; To = "    `$null = `$verifyTheme.Save.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]`$restoreInvoke)`n    `$restoreInvoke.Invoke()"; Accept = $false },
        @{ Name = 'Save and close on another probe'; From = $toastCloseGet; To = $toastCloseGet.Replace('-SettingsProbe $saveProbe', '-SettingsProbe $ownerProbe'); Accept = $false },
        # The probe's save after its last check, as the next statement (Opus M, round 6).
        @{ Name = 'a statement between the probe-save check and its save (Opus M, round 6)'; From = $toastProbeSave; To = "    Start-Sleep -Milliseconds 1`n$toastProbeSave"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'the probe saved before its last check'; From = $toastProbeSave; To = ''; Then = @(, @($saveSandboxProbeSave, "$toastProbeSave$saveSandboxProbeSave")); Accept = $false },
        @{ Name = 'the probe saved through the old close action'; From = $toastProbeSave; To = "    Invoke-AccessibilitySettingsCloseAction -SettingsProbe `$saveProbe -ActionName 'Save and close' -Description 'x'`n"; Accept = $false },
        @{ Name = 'the button pressed by the helper itself'; From = $toastHelperEnd; To = $toastHelperEnd.Replace("    `$invoke`n}", "    `$invoke.Invoke()`n    `$invoke`n}"); Accept = $false; Pin = 'save-functions' },
        @{ Name = 'Opus''s include write in the close helper (Opus M, round 6)'; From = $toastHelperEnd; To = $toastHelperEnd.Replace("    `$invoke`n}", "$toastOpusWrite    `$invoke`n}"); Accept = $true; Pin = 'save-functions' },
        # Opus L1, round 6: what the launch runs and with which environment.
        @{ Name = 'default parameter values for Start-Process (Opus L1, round 6)'; From = $toastRunFailureInit; To = "$toastRunFailureInit`$PSDefaultParameterValues['Start-Process:Environment'] = @{ XDG_CONFIG_HOME = 'H:\elsewhere' }`n"; Accept = $false; Pin = '' },
        @{ Name = 'a function standing in for Start-Process (Opus L1, round 6)'; From = $toastRunFailureInit; To = "$toastRunFailureInit" + "function Start-Process { [System.Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', 'H:\elsewhere'); Microsoft.PowerShell.Management\Start-Process @args }`n"; Accept = $false; Pin = '' },
        @{ Name = 'a function standing in for Get-Content'; From = $toastRunFailureInit; To = "$toastRunFailureInit" + "function global:Get-Content { 'scrollback-limit = 1' }`n"; Accept = $false; Pin = '' },
        @{ Name = 'Start-Process unqualified in the launcher'; From = '        return Microsoft.PowerShell.Management\Start-Process `'; To = '        return Start-Process `'; Accept = $false; Pin = 'save-functions' },
        @{ Name = 'Join-Path unqualified for the saved config'; From = "`$sandboxConfigPath = Microsoft.PowerShell.Management\Join-Path"; To = "`$sandboxConfigPath = Join-Path"; Accept = $false; Pin = 'save-sandbox' },
        @{ Name = 'a region calling a command no job script defines'; From = $toastProbeSave; To = ''; Then = @(, @($saveSandboxProbeSave, "$saveSandboxProbeSave    Invoke-UnknownSaveHelper`n$toastProbeSave")); Accept = $false },
        # Opus L2, round 6: the exe's folder before each launch.
        @{ Name = 'the first sandbox check without the exe (Opus L2, round 6)'; From = $saveSandboxFirst; To = $saveSandboxFirst.Replace(' -ExecutablePath $exe', ''); Accept = $false; Pin = 'save-flow' },
        @{ Name = 'the verifier-start check without the exe'; From = $saveSandboxVerifyStart; To = $saveSandboxVerifyStart.Replace(' -ExecutablePath $exe', ''); Accept = $false },
        # The sandbox checks (item (5); Opus L1, rounds 4 and 5).
        @{ Name = 'the first sandbox check removed'; From = $saveSandboxFirst; To = ''; Accept = $false },
        @{ Name = 'the first sandbox check without -Empty'; From = $saveSandboxFirst; To = $saveSandboxFirst.Replace(' -Empty', ''); Accept = $false },
        @{ Name = 'the probe-save check removed (Opus L1, round 5)'; From = $saveSandboxProbeSave; To = ''; Accept = $false },
        @{ Name = 'the probe-save check after the save (Opus L1, round 5)'; From = $saveSandboxProbeSave; To = ''; Then = @(, @($toastProbeSave, "$toastProbeSave$saveSandboxProbeSave")); Accept = $false },
        @{ Name = 'the verifier-start check removed'; From = $saveSandboxVerifyStart; To = ''; Accept = $false },
        @{ Name = 'the verifier-start check after the verifier starts'; From = $saveSandboxVerifyStart; To = ''; Then = @(, @("    `$saveVerifyCleanup = `$saveVerifyProcess`n", "    `$saveVerifyCleanup = `$saveVerifyProcess`n$saveSandboxVerifyStart")); Accept = $false },
        @{ Name = 'the verifier-save check removed (Opus L1, round 5)'; From = $saveSandboxVerifySave; To = ''; Accept = $false },
        @{ Name = 'a sandbox check on another environment'; From = $saveSandboxVerifySave; To = $saveSandboxVerifySave.Replace('-Environment $settingsProbeEnvironment', '-Environment $otherEnvironment'); Accept = $false },
        @{ Name = 'the probe-save check without its window (CodeRabbit)'; From = $saveSandboxProbeSave; To = $saveSandboxProbeSave.Replace(' -HostOpen ([NocttyAccessibilityNative]::IsWindow($saveProbeHost))', ''); Accept = $false; Pin = 'save-flow' },
        @{ Name = 'the probe-save check on another window'; From = $saveSandboxProbeSave; To = $saveSandboxProbeSave.Replace('IsWindow($saveProbeHost)', 'IsWindow($saveProbe.Hwnd)'); Accept = $false },
        @{ Name = 'the probe window taken after its probe opens'; From = "    `$saveProbeHost = `$saveProbeProcess.MainWindowHandle`n"; To = ''; Then = @(, @($toastProbeOpenLine, "$toastProbeOpenLine    `$saveProbeHost = `$saveProbeProcess.MainWindowHandle`n")); Accept = $false },
        @{ Name = 'the verifier window from another process'; From = "    `$saveVerifyHost = `$saveVerifyProcess.MainWindowHandle`n"; To = "    `$saveVerifyHost = `$saveProbeProcess.MainWindowHandle`n"; Accept = $false },
        @{ Name = 'the probe window written again'; From = $toastProbeOpenLine; To = "$toastProbeOpenLine    `$saveProbeHost = [IntPtr]::Zero`n"; Accept = $false },
        @{ Name = 'the first sandbox check in a block comment'; From = $saveSandboxFirst; To = "    <#`n$saveSandboxFirst    #>`n"; Accept = $false },
        @{ Name = 'the first sandbox check under if ($false)'; From = $saveSandboxFirst; To = "    if (`$false) {`n$saveSandboxFirst    }`n"; Accept = $false },
        @{ Name = 'an include written between the first check and the flags (Opus L1 P1, round 5)'; From = $toastProbeClass; To = "    Set-Content -LiteralPath (Microsoft.PowerShell.Management\Join-Path `$settingsPersistenceLayout.LocalAppData 'ghostty\config') -Value 'config-file = notify.conf'`n$toastProbeClass"; Accept = $true; Pin = 'save-flow' },
        # Round 4's (Opus M, L1, L2; Sol M1, M2).
        @{ Name = 'an alias of the flags written by index (Opus M, round 4)'; From = $toastProbeClass; To = "    `$flagsAlias = `$settingsSaveNotificationArguments`n    `$flagsAlias[0] = '--app-notifications=true'`n$toastProbeClass"; Accept = $false },
        @{ Name = 'an alias of the probe arguments written by index (Opus M, round 4)'; From = $toastProbeStart; To = "    `$argsAlias = `$saveProbeArguments`n    `$argsAlias[0] = '-e'`n$toastProbeStart"; Accept = $false },
        @{ Name = '.SetValue on the flags (Sol M1, round 4)'; From = $toastProbeClass; To = "    `$settingsSaveNotificationArguments.SetValue('--app-notifications=true', 0)`n$toastProbeClass"; Accept = $false },
        @{ Name = '[array]::Copy into the probe arguments (Opus M, round 4)'; From = $toastProbeStart; To = "    [array]::Copy([string[]]@('-e', 'cmd.exe'), `$saveProbeArguments, 2)`n$toastProbeStart"; Accept = $false },
        @{ Name = 'the flags passed to a function that writes them (Opus M, round 4)'; From = $toastProbeClass; To = "    function Set-QuietFirst([object[]] `$Values) { `$Values[0] = '--app-notifications=true' }`n    Set-QuietFirst `$settingsSaveNotificationArguments`n$toastProbeClass"; Accept = $false },
        @{ Name = 'the flags assigned after the first launch (Sol M2, round 4)'; From = "    $toastQuietValue`n"; To = ''; Then = @(, @($toastCleanup, "$toastCleanup    $toastQuietValue`n")); Accept = $false },
        @{ Name = '${function:} replacing the containment function (Opus L1, round 4)'; From = $toastProbeClass; To = "    `${function:Get-InteractiveWin11ContainmentArguments} = { return @('--linux-cgroup=always', '-e', 'cmd.exe') }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'Set-Item on function: (Opus L1, round 4)'; From = $toastProbeClass; To = "    Set-Item -Path function:Get-InteractiveWin11ContainmentArguments -Value { 'x' }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'New-Item on alias: (Opus L1, round 4)'; From = $toastProbeClass; To = "    New-Item -Path alias:Get-InteractiveWin11ContainmentArguments -Value Get-QuietContainment | Out-Null`n$toastProbeClass"; Accept = $false },
        @{ Name = '${function:} replacing the launcher (Opus L1, round 4)'; From = $toastProbeClass; To = "    `${function:Start-AccessibilityProcessWithEnvironment} = { param() }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'Import-Alias (Opus L1, round 4)'; From = $toastProbeClass; To = "    Import-Alias -Path 'aliases.csv'`n$toastProbeClass"; Accept = $false },
        @{ Name = '[scriptblock]::Create dot-sourced (Opus L1, round 4)'; From = $toastProbeStart; To = "    . ([scriptblock]::Create('`$saveProbeArguments += ''--app-notifications=true'''))`n$toastProbeStart"; Accept = $false },
        @{ Name = 'a cast to [scriptblock]'; From = $toastProbeStart; To = "    & ([scriptblock]'Write-Output 1') | Out-Null`n$toastProbeStart"; Accept = $false },
        @{ Name = '$PSCmdlet.SessionState (Opus L1, round 4)'; From = $toastProbeStart; To = "    `$PSCmdlet.SessionState.PSVariable.Set('savePro' + 'beArguments', @())`n$toastProbeStart"; Accept = $false },
        @{ Name = '$host.Runspace.SessionStateProxy (Opus L2, round 5)'; From = $toastPreamble; To = "$toastPreamble    `$host.Runspace.SessionStateProxy.SetVariable('settingsSaveNotificationArgu' + 'ments', @())`n"; Accept = $false; Pin = '' },
        @{ Name = 'a variable: provider write (Opus L1, round 4)'; From = $toastProbeStart; To = "    Set-Item -Path ('variable:savePro' + 'beArguments') -Value @()`n$toastProbeStart"; Accept = $false },
        @{ Name = '& on a computed name (Opus L1, round 4)'; From = $toastProbeStart; To = "    & ('Set-' + 'Variable') -Name ('savePro' + 'beArguments') -Value @()`n$toastProbeStart"; Accept = $false },
        @{ Name = '. on an expanded string'; From = $toastProbeStart; To = "    . `"Set-`$('Variable')`" -Name x -Value 1`n$toastProbeStart"; Accept = $false },
        @{ Name = 'a data section named like the flags (Opus L1, round 4)'; From = $toastProbeClass; To = "    data settingsSaveNotificationArguments { '--app-notifications=true' }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'another environment for the probe (Opus L2, round 4)'; From = "        -ArgumentList `$saveProbeArguments ``$toastEol        -WorkingDirectory `$repoRoot ``$toastEol        -EnvironmentVariables `$settingsProbeEnvironment ``"; To = "        -ArgumentList `$saveProbeArguments ``$toastEol        -WorkingDirectory `$repoRoot ``$toastEol        -EnvironmentVariables `$otherEnvironment ``"; Accept = $false },
        # Round 5's (Opus L1, L2; Sol M). Each fails on its pin; the grammar
        # names it too, inside a region or outside every region.
        @{ Name = 'the environment narrowed before the launches (Opus L1, round 5)'; From = $toastProbeClass; To = "    `$settingsProbeEnvironment.Remove('XDG_CONFIG_HOME')`n$toastProbeClass"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'an alias of the environment written by index, outside every region (Opus L1, round 5)'; From = $toastPreamble; To = "$toastPreamble    `$probeEnvironment = `$settingsProbeEnvironment`n    `$probeEnvironment['XDG_CONFIG_HOME'] = 'H:\elsewhere'`n"; Accept = $false; Pin = '' },
        @{ Name = 'the probe check in the background (Opus L2, round 5)'; From = $toastProbeCheck; To = $toastProbeCheck.Replace("'settings save probe'`n", "'settings save probe' &`n"); Accept = $false; Pin = 'save-flow' },
        @{ Name = 'the verifier check in the background (Opus L2, round 5)'; From = $toastVerifyCheck; To = $toastVerifyCheck.Replace("'settings persistence verifier'`n", "'settings persistence verifier' &`n"); Accept = $false; Pin = 'save-flow' },
        @{ Name = 'function script: redefining the verdict in the save flow (Opus L2, round 5)'; From = $toastProbeClass; To = "    function script:Get-AccessibilitySaveLaunchVerdict { 'quiet' }`n$toastProbeClass"; Accept = $false; Pin = 'save-flow' },
        @{ Name = 'function script: redefining the verdict outside every region (Opus L2, round 5)'; From = $toastPreamble; To = "$toastPreamble    function script:Get-AccessibilitySaveLaunchVerdict { 'quiet' }`n"; Accept = $false; Pin = '' },
        @{ Name = 'function global: redefining the check outside every region'; From = $toastPreamble; To = "$toastPreamble    function global:Assert-AccessibilitySaveLaunchQuiet { }`n"; Accept = $false; Pin = '' },
        @{ Name = 'the error-list addition under if ($false) (Sol M, round 5)'; From = $toastKeepAdd; To = "    if (`$false) { `$failureMessages.Add(`"`$(`$runFailure.Exception.Message)`$failureLocation`") }`n"; Accept = $false; Pin = 'failure-path' },
        # The run-time check (item (7)).
        @{ Name = 'the probe launch without its run-time check'; From = $toastProbeCheck; To = ''; Accept = $false },
        @{ Name = 'the verifier launch without its run-time check'; From = $toastVerifyCheck; To = ''; Accept = $false },
        @{ Name = 'the probe check after its probe opens'; From = $toastProbeCheck; To = ''; Then = @(, @($toastProbeOpenLine, "$toastProbeOpenLine$toastProbeCheck")); Accept = $false },
        @{ Name = 'the probe check under if ($false)'; From = $toastProbeCheck; To = "    if (`$false) {`n$toastProbeCheck    }`n"; Accept = $false },
        @{ Name = 'the probe check in a comment'; From = $toastProbeCheck; To = "    # Assert-AccessibilitySaveLaunchQuiet -Process `$saveProbeProcess -Description 'settings save probe'`n"; Accept = $false },
        @{ Name = 'the probe check inside a try that swallows its error'; From = $toastProbeCheck; To = "    try {`n$toastProbeCheck    } catch { }`n"; Accept = $false },
        @{ Name = 'a third run-time check'; From = $toastProbeCheck; To = "$toastProbeCheck$toastProbeCheck"; Accept = $false },
        @{ Name = 'the main catch dropping the error'; From = "catch {`n    `$runFailure = `$_`n}"; To = "catch {`n    `$runFailure = `$null`n}"; Accept = $false; Pin = 'failure-path' },
        @{ Name = 'the final throw under if ($false)'; From = "if (`$failureMessages.Count -gt 0) {"; To = "if (`$false -and `$failureMessages.Count -gt 0) {"; Accept = $false; Pin = 'failure-path' },
        @{ Name = 'the error cleared before the end'; From = "`$failureMessages = [System.Collections.Generic.List[string]]::new()"; To = "`$runFailure = `$null`n`$failureMessages = [System.Collections.Generic.List[string]]::new()"; Accept = $false; Pin = 'failure-path' },
        # (A) The markers themselves.
        @{ Name = 'the save-flow region ended before the verifier'; From = "    # pin-end: save-flow`n"; To = ''; Then = @(, @("`n    `$saveVerifyClass = ", "`n    # pin-end: save-flow`n    `$saveVerifyClass = ")); Accept = $false; Pin = 'save-flow' },
        @{ Name = 'the failure-path markers removed'; From = "# pin-begin: failure-path`n"; To = ''; Then = @(, @("# pin-end: failure-path`n", '')); Accept = $false; Pin = 'failure-path,markers' },
        @{ Name = 'a launch moved out of the save-functions region'; From = "# pin-end: save-functions`n"; To = ''; Then = @(, @("function Start-AccessibilityProcessWithEnvironment {", "# pin-end: save-functions`nfunction Start-AccessibilityProcessWithEnvironment {")); Accept = $false; Pin = 'save-functions' }
    )) {
    $toastMutated = $saveFixture
    $toastEdits = @(, @($toastControl.From, $toastControl.To)) + @(if ($toastControl.ContainsKey('Then')) { $toastControl.Then })
    foreach ($toastEdit in $toastEdits) {
        if (([regex]::Matches($toastMutated, [regex]::Escape($toastEdit[0]))).Count -ne 1) {
            throw "Quiet Settings save control '$($toastControl.Name)' lost its anchor."
        }
        $toastMutated = $toastMutated.Replace($toastEdit[0], $toastEdit[1])
    }
    if ((& $runQuietCheck $toastMutated $launchLibraryText $saveOthers) -ne $toastControl.Accept) {
        throw "The quiet Settings save check $(if ($toastControl.Accept) { 'refused' } else { 'accepted' }) $($toastControl.Name)."
    }
    $toastChanged = & $saveChangedRegions $toastMutated
    if ($toastControl.ContainsKey('Pin')) {
        if (-not (& $saveSame $toastChanged $toastControl.Pin)) { throw "Quiet Settings save control '$($toastControl.Name)' breaks the pins '$toastChanged', not '$($toastControl.Pin)'." }
    }
    elseif ($toastChanged.Length -eq 0) { throw "Quiet Settings save control '$($toastControl.Name)' breaks no pin." }
}
# The shared containment arguments come first on both command lines, so an
# override there loses to the flags; anything outside the library function's
# grammar, or a definition of it in another job script, refuses the launch.
$toastLibraryEol = if ($launchLibraryText.Contains("`r`n")) { "`r`n" } else { "`n" }
$toastContainmentReturn = "        '--windows-job-object-kill-on-close=true'$toastLibraryEol    )"
if (([regex]::Matches($launchLibraryText, [regex]::Escape($toastContainmentReturn))).Count -ne 1) { throw 'The containment-arguments control lost its anchor.' }
foreach ($toastControl in @(
        @{ Name = 'an override in the containment arguments (the flags win)'; Library = "        '--windows-job-object-kill-on-close=true'$toastLibraryEol        '--app-notifications=true'$toastLibraryEol    )"; Accept = $true },
        @{ Name = 'a variable in the containment arguments'; Library = "        '--windows-job-object-kill-on-close=true'$toastLibraryEol        `$extraContainment$toastLibraryEol    )"; Accept = $false },
        @{ Name = 'a containment element with a space'; Library = "        '--windows-job-object-kill-on-close=true --app-notifications=true'$toastLibraryEol    )"; Accept = $false },
        @{ Name = 'a double-quoted containment element'; Library = "        `"--windows-job-object-kill-on-close=true`"$toastLibraryEol    )"; Accept = $false },
        @{ Name = 'a pipeline in the containment arguments'; Library = "        '--windows-job-object-kill-on-close=true' | Sort-Object$toastLibraryEol    )"; Accept = $false },
        @{ Name = 'a soft hyphen in a containment element'; Library = "        '--windows-job-object-kill-on-close=true'$toastLibraryEol        '-${saveSoftHyphen}e'$toastLibraryEol    )"; Accept = $false }
    )) {
    if ((& $runQuietCheck $saveFixture $launchLibraryText.Replace($toastContainmentReturn, $toastControl.Library) $saveOthers) -ne $toastControl.Accept) {
        throw "The quiet Settings save check $(if ($toastControl.Accept) { 'refused' } else { 'accepted' }) $($toastControl.Name)."
    }
}
foreach ($toastControl in @(
        @{ Name = 'a containment function defined in another job script'; File = 'scripts\interactive-win11-window-lib.ps1'; Text = "function Get-InteractiveWin11ContainmentArguments { return @('--linux-cgroup=always') }" },
        @{ Name = 'another job script naming a grammar variable'; File = 'test\windows\interactive-win11-stateful-lib.ps1'; Text = "function Reset-Flags { `$script:settingsSaveNotificationArguments = @('--app-notifications=true') }" },
        @{ Name = 'a variable cmdlet in another job script'; File = 'scripts\interactive-win11-window-lib.ps1'; Text = "function Reset-Any([string] `$Name) { Set-Variable -Name `$Name -Scope Script -Value `$null }" },
        @{ Name = 'a module-qualified variable cmdlet in another job script (Sol L, round 5)'; File = 'scripts\interactive-win11-window-lib.ps1'; Text = "function Reset-Any([string] `$Name) { Microsoft.PowerShell.Utility\Set-Variable -Name `$Name -Scope Global -Value `$null }" },
        @{ Name = 'a ${function:} write in another job script (Opus L1, round 4)'; File = 'scripts\interactive-win11-window-lib.ps1'; Text = "`${function:Get-InteractiveWin11ContainmentArguments} = { return @('--linux-cgroup=always', '-e', 'cmd.exe') }" },
        @{ Name = '[scriptblock]::Create in another job script'; File = 'test\windows\interactive-win11-stateful-lib.ps1'; Text = "function Invoke-Late([string] `$Text) { . ([scriptblock]::Create(`$Text)) }" },
        @{ Name = 'the run-time check redefined in another job script (Opus L2, round 5)'; File = 'scripts\interactive-win11-window-lib.ps1'; Text = "function global:Assert-AccessibilitySaveLaunchQuiet { }" },
        @{ Name = 'the launcher redefined in another job script'; File = 'test\windows\interactive-win11-stateful-lib.ps1'; Text = "function Start-AccessibilityProcessWithEnvironment { }" },
        @{ Name = 'Join-Path redefined in another job script (Opus L1, round 6)'; File = 'scripts\interactive-win11-lib.ps1'; Text = "function Join-Path { 'H:\elsewhere' }" },
        @{ Name = 'default parameter values in another job script'; File = 'scripts\interactive-win11-window-lib.ps1'; Text = "`$global:PSDefaultParameterValues['Start-Process:WorkingDirectory'] = 'H:\elsewhere'" }
    )) {
    $toastOtherTexts = $saveOtherTexts.Clone()
    $toastOtherTexts[$toastControl.File] += "`n$($toastControl.Text)"
    if (& $runQuietCheck $saveFixture $launchLibraryText (& $summarizeOtherScripts $toastOtherTexts)) {
        throw "The quiet Settings save check accepted $($toastControl.Name)."
    }
}
Remove-Item -LiteralPath Function:\Get-AccessibilityNotificationSettings, Function:\Get-AccessibilitySaveLaunchVerdict -ErrorAction SilentlyContinue
foreach ($leafHarness in @($shaderHarness, (Join-Path $repoRoot 'test\windows\interactive-win11-shader-pacing.ps1'))) {
    # A leaf rebuild in measurement mode rebuilds the measurement generation,
    # never a product-AUMID zig-out build.
    if ((Get-Content -LiteralPath $leafHarness -Raw) -notmatch '(?s)if \(\$Rebuild\) \{\s*if \(Test-InteractiveWin11MeasureMode\) \{[^{}]*?Invoke-InteractiveWin11Build -RepoRoot \$repoRoot\s*\}\s*else \{.*?zig build -Demit-exe=true -Dcustom-shaders=true') {
        throw "Shader leaf rebuilds a product-AUMID build in measurement mode: $leafHarness"
    }
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
        Pattern = '(?ms)Show-StatefulHost \$hostHwnd\r?\n\s+\$shot = Save-StatefulScreenCapture -Hwnd \$surface\.Hwnd .*?Show-StatefulHost \$hostHwnd\r?\n\s+\$argb = Get-StatefulPixel'
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
        Pattern = '(?s)\.blink => if \(t\.cursor_c\.state\(\) == \.dead\) \{\s*t\.cursor_h\.run\('
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
        Pattern = '(?m)^#requires -Version 7\.1\s*$'
        Kind = 'Workflow'
        Description = 'accessibility evidence requires PowerShell 7.1 or newer'
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
        Pattern = '(?ms)- name: Setup Node\.js\s+uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1.*?node-version: 22.*?- name: Deterministic site asset check.*?node scripts/build-site-assets\.mjs --check.*?if \(\$LASTEXITCODE -ne 0\).*?- name: Site unit tests.*?node --test "site/tests/\*\*/\*\.test\.mjs".*?if \(\$LASTEXITCODE -ne 0\)'
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
)
$objectRoot = ConvertFrom-Json -InputObject '{"value":1}' -NoEnumerate
$arrayRoot = ConvertFrom-Json -InputObject '[{"value":1}]' -NoEnumerate
if ($objectRoot.GetType() -ne [System.Management.Automation.PSCustomObject] -or
    $arrayRoot.GetType() -eq [System.Management.Automation.PSCustomObject]) {
    throw 'PowerShell JSON root-kind preservation does not satisfy the evidence contract.'
}

# Design v7 §2.1 checks 1 and 2 (interactive offload; Opus on #740): the frozen set, the visible composite, the release
# readers and the workflows that run them: (1) each file's canonical-text SHA-256 (Get-CanonicalTextSha256, so CRLF and
# LF checkouts agree) is pinned here, and changing one is a deliberate re-pin reviewed against the design (release.yml's
# value is also Contracts.80's $releaseWorkflowSha256); (2) no frozen entry point names NOCTTY_GUI_LAUNCH_POLICY or a
# NOCTTY_GUI_HIDDEN_ variable, so none sets the hidden-desktop route's variables or passes a switch named for them.
# Since the maintainer's decision of 2026-11-22 no release or check requires an interactive run: the release readers
# are pinned in the form that reads no interactive evidence (ReleasePromotionContracts.ps1 refuses one that names it),
# and the composite stays dispatchable but optional.
# Of test.yml, §2.1 freezes only the `windows-interactive` job and the `run_interactive_win11` dispatch input it reads
# (`path#region` keys, Get-FrozenSetRegion), so an edit elsewhere in test.yml, a Dependabot pin bump or a scheduled
# job change, needs no re-pin (Opus on #740: the whole-file pin failed every such edit), and neither does another
# manual input beside it (Sol on #740: the pin covered the whole `workflow_dispatch` block).
$frozenSetSha256 = [ordered]@{
    '.github/workflows/test.yml#windows-interactive' = '44c05e4dac25e44cefaffa5922d191a8674dc4c349af08c18151bb3979adef70'
    '.github/workflows/test.yml#run_interactive_win11' = '8110a2478d5a88e5efbb6abeb16b4da1a44255ff7489b1f18c2e99ef8820750f'
    '.github/workflows/release.yml' = '0d204a0cde96d60e5a38eb2294d1030c6b2cc67b8b3baeee66706a99216871d2'
    'test/windows/interactive-win11-job.ps1' = '8cf5b41cba40803748b193c09a9e19d42b47e5ece2e0262cd2c9f497a2cb0253'
    'test/windows/interactive-win11-validate.ps1' = 'cf24651acd8cf091201fc2f81ad1286f389543502c76124c8d2d08d97d0d4d66'
    'test/windows/flagship/Invoke-InteractiveWin11.ps1' = '189560bc3bc0f67fd26937fd31084176dafe60352703505e26eea5f39459e7ff'
    'test/windows/flagship/scenarios/interactive-win11.json' = '7c0ffbf3a98781a96d2ff0b4e158f0d0aaebd5bb58adfa8fec9418a8766a214a'
    'scripts/release-evidence.ps1' = 'c45bdc54b959084374a47c322307274858c6708adeeabcfdf26ffb362aa1b9e6'
    'scripts/release-manifest.ps1' = 'c28c3af0a2880652ceacccad439e2a989717e6c2ee54327395bf8e231b01e3a7'
    'scripts/release-write-manifest.ps1' = '2871cce6d6a06bcae5f547726738822847a2247abd200225efe8a2c121e91e78'
    'scripts/release-promote.ps1' = '3eef9bae7c13f4f04221a46639eeb4398e006da15c6a23ef053126a49c881d80'
    'scripts/check-accessibility-evidence.ps1' = '22433132e0cd0052f7ad31ba01079a8ad32dc918aa46d122041109d8f10d32e2'
}
# The frozen part of a file: the whole text, or for test.yml one job (Get-YamlJobText) or the one dispatch input the
# job reads: its line under `workflow_dispatch:` `inputs:` and the lines indented below it, never the other inputs.
function Get-FrozenSetRegion([string] $Text, [string] $Region) {
    if (-not $Region) { return $Text }
    if ($Region -ceq 'run_interactive_win11') {
        # Blank lines between the inputs are part of the block (CodeRabbit on #740).
        $dispatch = [regex]::Match($Text, '(?m)^  workflow_dispatch:[^\r\n]*\r?\n(?:(?:    [^\r\n]*|[ \t]*)\r?\n)*', 'None', [TimeSpan]::FromSeconds(5))
        if (-not $dispatch.Success) { return $null }
        $inputs = @([regex]::Matches($dispatch.Value, '(?m)^      run_interactive_win11:[^\r\n]*\r?\n(?:        [^\r\n]*\r?\n)*', 'None', [TimeSpan]::FromSeconds(5)))
        return $(if ($inputs.Count -eq 1) { $inputs[0].Value } else { $null })
    }
    try { $job = Get-YamlJobText -Content $Text -Name $Region -Source "frozen set region $Region" } catch { return $null }
    # The job ends at the next job key or at the end of the file: Get-YamlJobText also takes a top-level key after it
    # and the blank and comment lines before the next job (Opus on #740: a job appended after `windows-interactive`
    # with a leading comment failed the pin). A comment indented inside the job stays the job's.
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($job, '(?<=\n)')) { if ($line.Length -gt 0) { $lines.Add($line) } }
    for ($at = 1; $at -lt $lines.Count; $at++) {
        if ($lines[$at] -cmatch '\A[^\s#]') { $lines.RemoveRange($at, $lines.Count - $at); break }
    }
    while ($lines.Count -gt 1 -and $lines[$lines.Count - 1] -cmatch '\A(?: {0,2}#[^\r\n]*)?\s*\z') { $lines.RemoveAt($lines.Count - 1) }
    return ($lines -join '')
}
function Get-FrozenSetProblems([System.Collections.IDictionary] $Texts) {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $frozenSetSha256.Keys) {
        $path, $region = $key -split '#', 2
        $text = $Texts[$path]
        if ($null -eq $text) { $found.Add("frozen set: $path is missing."); continue }
        $subject = Get-FrozenSetRegion $text $region
        if ($null -eq $subject) { $found.Add("frozen set: $key is missing."); continue }
        $actual = Get-CanonicalTextSha256 -Text $subject
        if (-not [string]::Equals($actual, $frozenSetSha256[$key], [StringComparison]::Ordinal)) {
            $found.Add("frozen set: $key changed (canonical SHA-256 $actual); re-pin it only with a design change that unfreezes it.")
        }
    }
    foreach ($path in @($frozenSetSha256.Keys | ForEach-Object { ($_ -split '#', 2)[0] } | Select-Object -Unique)) {
        $text = $Texts[$path]
        if ($null -eq $text) { continue }
        foreach ($name in @('NOCTTY_GUI_LAUNCH_POLICY', 'NOCTTY_GUI_HIDDEN_')) {
            if ($text.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found.Add("frozen set: $path names $name.") }
        }
    }
    return , $found.ToArray()
}
$frozenSetTexts = [ordered]@{}
foreach ($path in @($frozenSetSha256.Keys | ForEach-Object { ($_ -split '#', 2)[0] } | Select-Object -Unique)) {
    $full = Join-Path $repoRoot $path.Replace('/', '\')
    $frozenSetTexts[$path] = $(if ([IO.File]::Exists($full)) { [IO.File]::ReadAllText($full) } else { $null })
}
$frozenSetProblems = Get-FrozenSetProblems $frozenSetTexts
if ($frozenSetProblems.Count -ne 0) { throw ($frozenSetProblems -join ' ') }
# Controls: a CRLF checkout passes; one changed byte fails (1); an injected variable or switch fails (2) by name.
$frozenSetCrlf = [ordered]@{}
foreach ($path in $frozenSetTexts.Keys) { $frozenSetCrlf[$path] = $frozenSetTexts[$path].Replace("`r`n", "`n").Replace("`n", "`r`n") }
if ((Get-FrozenSetProblems $frozenSetCrlf).Count -ne 0) { throw 'The frozen-set pin refused a CRLF checkout of the same files.' }
foreach ($control in @(
        @{ Name = 'one changed byte'; Path = 'scripts/release-promote.ps1'; Change = { param($t) $t.Substring(0, 40) + [char]([int]$t[40] -bxor 1) + $t.Substring(41) }; Expect = 'scripts/release-promote.ps1 changed' }
        @{ Name = 'the launch-policy variable set'; Path = 'test/windows/interactive-win11-job.ps1'; Change = { param($t) "`$env:NOCTTY_GUI_LAUNCH_POLICY = 'x'`n" + $t }; Expect = 'interactive-win11-job.ps1 names NOCTTY_GUI_LAUNCH_POLICY' }
        @{ Name = 'an edit inside the frozen windows-interactive job'; Path = '.github/workflows/test.yml'; Change = { param($t) $t.Replace("    runs-on: [self-hosted, Windows, X64, noctty-interactive]`n    timeout-minutes: 60", "    runs-on: [self-hosted, Windows, X64, noctty-interactive]`n    timeout-minutes: 61").Replace("    runs-on: [self-hosted, Windows, X64, noctty-interactive]`r`n    timeout-minutes: 60", "    runs-on: [self-hosted, Windows, X64, noctty-interactive]`r`n    timeout-minutes: 61") }; Expect = 'test.yml#windows-interactive changed' }
        @{ Name = 'the dispatch input it reads defaulted on'; Path = '.github/workflows/test.yml'; Change = { param($t) [regex]::Replace($t, '(?m)^(        default: )false(\r?)$', '${1}true$2', 'None', [TimeSpan]::FromSeconds(5)) }; Expect = 'test.yml#run_interactive_win11 changed' }
        @{ Name = 'the dispatch input it reads renamed'; Path = '.github/workflows/test.yml'; Change = { param($t) $t.Replace('      run_interactive_win11:', '      run_interactive_win12:') }; Expect = 'test.yml#run_interactive_win11 is missing' }
        @{ Name = 'a hosted variable in the Test workflow'; Path = '.github/workflows/test.yml'; Change = { param($t) $t.Replace("`njobs:", "`nenv:`n  noctty_gui_hidden_desktop: x`njobs:") }; Expect = 'test.yml names NOCTTY_GUI_HIDDEN_' }
    )) {
    $frozenSetMutated = [ordered]@{}
    foreach ($path in $frozenSetTexts.Keys) { $frozenSetMutated[$path] = $frozenSetTexts[$path] }
    $frozenSetMutated[$control.Path] = & $control.Change $frozenSetTexts[$control.Path]
    $frozenSetControlProblems = Get-FrozenSetProblems $frozenSetMutated
    if ([string]::Equals($frozenSetMutated[$control.Path], $frozenSetTexts[$control.Path], [StringComparison]::Ordinal) -or
        @($frozenSetControlProblems | Where-Object { $_.Contains($control.Expect) }).Count -eq 0) {
        throw "The frozen-set pin accepted $($control.Name)."
    }
}
# The positive half (Opus on #740): an edit to a job §2.1 does not freeze (the bench job's timeout) passes.
$frozenSetOther = [ordered]@{}
foreach ($path in $frozenSetTexts.Keys) { $frozenSetOther[$path] = $frozenSetTexts[$path] }
$frozenBench = Get-YamlJobText -Content $frozenSetTexts['.github/workflows/test.yml'] -Name 'bench' -Source 'test.yml'
$frozenBenchEdited = [regex]::Replace($frozenBench, '(?m)^(    timeout-minutes: )(\d+)', { param($m) $m.Groups[1].Value + ([int]$m.Groups[2].Value + 34) }, 'None', [TimeSpan]::FromSeconds(5))
if ([string]::Equals($frozenBench, $frozenBenchEdited, [StringComparison]::Ordinal)) { throw 'The frozen-set positive control changed nothing in the bench job.' }
$frozenSetOther['.github/workflows/test.yml'] = $frozenSetTexts['.github/workflows/test.yml'].Replace($frozenBench, $frozenBenchEdited)
$frozenOtherProblems = Get-FrozenSetProblems $frozenSetOther
if ($frozenOtherProblems.Count -ne 0) { throw "The frozen-set pin refused an edit to a job it does not freeze: $($frozenOtherProblems -join ' ')" }
# A job appended after the frozen one, with a leading comment, or after a blank line, passes (Opus on #740).
foreach ($frozenLater in @(
        @('', '  # A later job, introduced by a comment.', '  later-job:', '    runs-on: ubuntu-latest', '    steps:', '      - run: echo later'),
        @('', '', '  later-job:', '    runs-on: ubuntu-latest', '    steps:', '      - run: echo later'),
        @('', '# A top-level comment.', 'env:', '  LATER: 1'))) {
    $frozenSetLater = [ordered]@{}
    foreach ($path in $frozenSetTexts.Keys) { $frozenSetLater[$path] = $frozenSetTexts[$path] }
    $frozenLaterYml = $frozenSetTexts['.github/workflows/test.yml']
    $frozenLaterNl = $(if ($frozenLaterYml.Contains("`r`n")) { "`r`n" } else { "`n" })
    $frozenSetLater['.github/workflows/test.yml'] = $frozenLaterYml.TrimEnd("`r", "`n") + $frozenLaterNl + ($frozenLater -join $frozenLaterNl) + $frozenLaterNl
    $frozenLaterProblems = Get-FrozenSetProblems $frozenSetLater
    if ($frozenLaterProblems.Count -ne 0) { throw "The frozen-set pin refused a job or key appended after the frozen job: $($frozenLaterProblems -join ' ')" }
}
# The last line of the frozen job itself is still the job's: changing it fails.
$frozenSetLast = [ordered]@{}
foreach ($path in $frozenSetTexts.Keys) { $frozenSetLast[$path] = $frozenSetTexts[$path] }
$frozenLastJob = Get-FrozenSetRegion $frozenSetTexts['.github/workflows/test.yml'] 'windows-interactive'
$frozenLastBody = $frozenLastJob.TrimEnd("`r", "`n")
$frozenSetLast['.github/workflows/test.yml'] = $frozenSetTexts['.github/workflows/test.yml'].Replace($frozenLastJob, $frozenLastBody + 'x' + $frozenLastJob.Substring($frozenLastBody.Length))
$frozenLastProblems = Get-FrozenSetProblems $frozenSetLast
if (@($frozenLastProblems | Where-Object { $_.Contains('test.yml#windows-interactive changed') }).Count -eq 0) { throw 'The frozen-set pin accepted a change to the frozen job''s last line.' }
# And another manual input, before or after the one the job reads, passes (Sol on #740).
$frozenTestYml = $frozenSetTexts['.github/workflows/test.yml']
$frozenInputNl = $(if ($frozenTestYml.Contains("`r`n")) { "`r`n" } else { "`n" })
$frozenExtraInput = (@('      run_unrelated_check:', '        description: An unrelated manual input', '        required: false', '        default: false', '        type: boolean') -join $frozenInputNl) + $frozenInputNl
foreach ($frozenPlace in @('before', 'after', 'a blank line before')) {
    $frozenSetInput = [ordered]@{}
    foreach ($path in $frozenSetTexts.Keys) { $frozenSetInput[$path] = $frozenSetTexts[$path] }
    $frozenInputs = [regex]::Match($frozenTestYml, '(?m)^    inputs:\r?\n', 'None', [TimeSpan]::FromSeconds(5))
    $frozenAfterInput = [regex]::Match($frozenTestYml, '(?m)^      run_interactive_win11:[^\r\n]*\r?\n(?:        [^\r\n]*\r?\n)*', 'None', [TimeSpan]::FromSeconds(5))
    if (-not $frozenInputs.Success -or -not $frozenAfterInput.Success) { throw 'The frozen-set input control found no dispatch input to place beside.' }
    $frozenAt = $(if ($frozenPlace -ceq 'after') { $frozenAfterInput.Index + $frozenAfterInput.Length } else { $frozenInputs.Index + $frozenInputs.Length })
    $frozenInsert = $(if ($frozenPlace -ceq 'a blank line before') { $frozenExtraInput + $frozenInputNl } else { $frozenExtraInput })
    $frozenSetInput['.github/workflows/test.yml'] = $frozenTestYml.Insert($frozenAt, $frozenInsert)
    $frozenInputProblems = Get-FrozenSetProblems $frozenSetInput
    if ($frozenInputProblems.Count -ne 0) { throw "The frozen-set pin refused an unrelated manual input placed $frozenPlace the one it freezes: $($frozenInputProblems -join ' ')" }
}
