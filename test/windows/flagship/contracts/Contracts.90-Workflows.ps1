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
    if ($conptyStep -notmatch ($probeVariable + ": '1'")) { throw "Missing scoped probe variable: $probeVariable" }
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
    $needsMatch = [regex]::Match($gateJob, '(?m)^    needs: \[(?<list>[^\]]*)\]\s*$')
    $needed = @($needsMatch.Groups['list'].Value -split ',\s*' | Where-Object { $_ })
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
# Parses a script's text; -Tokens also returns its tokens.
$parseToastScript = {
    param([string] $Text, [string] $Name, [switch] $Tokens)
    $parsedTokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$parsedTokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Name does not parse: $($errors[0].Message)" }
    if ($Tokens) { [pscustomobject]@{ Ast = $ast; Tokens = $parsedTokens } } else { $ast }
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
# The composite starts the command-finish leaf once, inside `$parallelRuns`, only
# under an if whose one clause is `-not $DeferCommandFinish`; the progress leaf
# beside it under no if; it declares the switch and only reads it, each read the
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
    foreach ($launch in @($toast[0], $progress[0])) {
        if (-not (& $isWithin $launch.Command $parallel[0])) { return $false }
    }
    $ifs = @(for ($at = $toast[0].Command.Parent; -not [object]::ReferenceEquals($at, $parallel[0]); $at = $at.Parent) {
        if ($at -is [System.Management.Automation.Language.IfStatementAst]) { $at }
    })
    if ($ifs.Count -ne 1 -or $ifs[0].Clauses.Count -ne 1 -or $null -ne $ifs[0].ElseClause -or
        $ifs[0].Clauses[0].Item1.Extent.Text -cne '-not $DeferCommandFinish' -or
        -not (& $isWithin $toast[0].Command $ifs[0].Clauses[0].Item2)) { return $false }
    for ($at = $progress[0].Command.Parent; -not [object]::ReferenceEquals($at, $parallel[0]); $at = $at.Parent) {
        if ($at -is [System.Management.Automation.Language.IfStatementAst]) { return $false }
    }
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
$flagshipInteractiveText = Get-Content -LiteralPath $flagshipInteractive -Raw
if ([regex]::Matches($flagshipInteractiveText, '(?m)^\s*\[switch\] \$DeferCommandFinish\s*$').Count -ne 1 -or
    [regex]::Matches($flagshipInteractiveText, [regex]::Escape("if (`$DeferCommandFinish) { `$arguments += '-DeferCommandFinish' }")).Count -ne 1) {
    throw 'Invoke-InteractiveWin11.ps1 must declare -DeferCommandFinish and pass it on to the composite.'
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
$progressStateBytes = '(?:' + (($progressStates | ForEach-Object { '0x{0:x2}' -f [int][char]$_ }) -join '|') + ')'
$osc9TextSource = '\]9;(?!4;' + $progressStateClass + '|9;)'
$osc9ByteSource = '(?i)0x5d\s*,\s*0x39\s*,\s*0x3b(?!\s*,\s*0x34\s*,\s*0x3b\s*,\s*' + $progressStateBytes + '\b)(?!\s*,\s*0x39\s*,\s*0x3b\b)'

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
    'an OSC 777 notification (bytes)' = '(?i)0x5d\s*,\s*0x37\s*,\s*0x37\s*,\s*0x37'
    'an OSC 99 notification (bytes)' = '(?i)0x5d\s*,\s*0x39\s*,\s*0x39\s*,\s*0x3b'
    'an OSC 7501 program status (bytes)' = '(?i)0x5d\s*,\s*0x37\s*,\s*0x35\s*,\s*0x30\s*,\s*0x31'
    'a reload_config action' = '[''"]reload_config[''"]'
    # A copy raises the clipboard-copy notice (`Surface.copySelectionToClipboards`,
    # `copy_last_command_output`), which `desktop-notifications` does not gate.
    'a clipboard copy' = '(?i)\bcopy_to_clipboard\b|\bcopy_last_command_output\b|\bcopy-or-paste\b|\bcopy-on-select\b|\bright-click-action\b'
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
# repository root, in test\windows or in scripts, is read too.
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
        foreach ($token in (& $parseToastScript $text $file -Tokens).Tokens) {
            if ($token -isnot [System.Management.Automation.Language.StringToken] -or $token.Value -notmatch '\.ps1$') { continue }
            foreach ($base in @($directory, '', 'test\windows', 'scripts')) {
                $relative = if ($base) { Join-Path $base $token.Value } else { $token.Value }
                $candidate = [IO.Path]::GetRelativePath($repoRoot, [IO.Path]::GetFullPath((Join-Path $repoRoot $relative)))
                if ($null -ne (& $Read $candidate)) { $queue.Enqueue($candidate); break }
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
# The patterns see the sources they were written for: the toast leaf's own
# config, and both Settings saves.
if (-not [regex]::IsMatch($jobFileTexts[$toastLeaf], $toastSources['a notify-on-command-finish setting']) -or
    -not [regex]::IsMatch($jobFileTexts[$toastLeaf], $toastSources['desktop-notifications = true']) -or
    @($settingsSaves.Values | Where-Object { -not [regex]::IsMatch($jobFileTexts[$accessibilityLeaf], $_) }).Count -ne 0) {
    throw 'The toast-source inventory no longer matches the sources it was written for.'
}
$nonToastLeaf = 'test\windows\interactive-win11-shaders.ps1'
$isToastSourceIn = {
    param([string] $Text)
    @(& $findToastSources $nonToastLeaf ($jobFileTexts[$nonToastLeaf] + "`n" + $Text)).Count -ne 0
}
$asOscText = { param([string] $Body) '"' + [char]0x60 + 'e]' + $Body + [char]0x60 + 'a"' }
$asOscBytes = { param([string] $Body) '[byte[]](0x1b,0x5d,' + ((@($Body.ToCharArray()) | ForEach-Object { '0x{0:x2}' -f [int]$_ }) -join ',') + ',0x07)' }
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
    foreach ($osc9Form in @((& $asOscText $osc9Case.Input), (& $asOscBytes $osc9Case.Input))) {
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

# The accessibility leaf's two Settings saves, in two layers.
# The static grammar below refuses every form it does not list, and so every
# write or redefinition it can see in the source. It evaluates no PowerShell,
# so it cannot see a name or a command built at run time. The run-time check,
# in the leaf, covers that: right after each saving launch, before any save,
# the leaf reads that process's own command line and stops unless it leaves
# every notification off (`Assert-AccessibilitySaveLaunchQuiet`, item (7)).
# (1) Saves. Exactly one `Invoke-AccessibilitySettingsCloseAction` with
#     `-ActionName 'Save and close'`, on `-SettingsProbe $saveProbe`, and exactly
#     one `.Save.TryGetCurrentPattern(`, on `$verifyScrollback.Save`.
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
#     puts them: the flags as an element of each launch array, each launch
#     array as its launch's `-ArgumentList`, so no alias, method call or
#     parameter can reach them. The leaf uses no variable or alias cmdlet, no
#     `Invoke-Expression`, no common variable parameter and no
#     `$ExecutionContext`. No job script uses a variable or alias cmdlet,
#     `Import-Alias` or `Invoke-Expression`; a `function:`, `variable:` or
#     `alias:` drive, as a variable or a path; a `data` section;
#     `[scriptblock]::Create` or a cast to `[scriptblock]`; `SessionState`,
#     `InvokeCommand` or `InvokeProvider`; `$PSCmdlet`; or `&` or `.` on a name
#     built by an expression (a variable, a member, a literal, a script block or
#     `(Join-Path ...)` are the targets allowed).
# (5) Order. The statements of (2), (3), (6) and (7) are direct statements of
#     the one block that holds both launches, in this order: the flags before
#     each launch array, each class name and launch array before its launch,
#     each launch before its run-time check, each check before its probe opens,
#     the default-config check before the first launch, and the include check
#     after the first process stops and before the second launch.
# (6) The arguments those forms give: no element holds whitespace, a quote or
#     a backtick (`Start-Process -ArgumentList` joins the elements with spaces
#     and quotes nothing), none is `--config-file` (an include is read after
#     the command line, `Config.load`, and wins), and the notification settings
#     they leave are all off, read by the leaf's own
#     `Get-AccessibilityNotificationSettings`. At run time the leaf finds no
#     default config file in the saving sandbox before the first launch, and no
#     `config-file` line in the saved file before the verifier starts.
# (7) The run-time check. `Assert-AccessibilitySaveLaunchQuiet -Process <that
#     process>` follows each launch; it reads only that process's command line,
#     by its id, never prints it, and throws unless
#     `Get-AccessibilitySaveLaunchVerdict` finds every notification off. The
#     block that holds the launches sits in the leaf's normal-mode branch, a
#     direct statement of the leaf's main `try`, whose `catch` keeps the error
#     and whose end throws it, so a failed check stops the leaf before its save.
# A save then shows its banner and, with `config-reload` off and that banner
# shown, `settingsNotifySuccessThunk` returns before the toast (settings.md
# PROFILES-4 trap 7).
$saveRuntimeAst = & $parseToastScript $jobFileTexts[$accessibilityLeaf] 'interactive-win11-accessibility.ps1'
$saveRuntimeFunctions = [ordered]@{}
foreach ($saveRuntimeName in @('Get-AccessibilityNotificationSettings', 'Get-AccessibilitySaveLaunchVerdict', 'Assert-AccessibilitySaveLaunchQuiet')) {
    $saveRuntimeFound = @($saveRuntimeAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq $saveRuntimeName
            }, $true))
    if ($saveRuntimeFound.Count -ne 1) { throw "interactive-win11-accessibility.ps1 must define $saveRuntimeName once." }
    $saveRuntimeFunctions[$saveRuntimeName] = $saveRuntimeFound[0]
}
# The leaf's own reading, defined here from its source: the static check, the
# table below and the run-time check share it.
. ([scriptblock]::Create($saveRuntimeFunctions['Get-AccessibilityNotificationSettings'].Extent.Text))
. ([scriptblock]::Create($saveRuntimeFunctions['Get-AccessibilitySaveLaunchVerdict'].Extent.Text))
$getEffectiveNotifications = {
    param([string[]] $Arguments)
    Get-AccessibilityNotificationSettings -Arguments $Arguments
}
$toastQuietPair = @('--app-notifications=false', '--desktop-notifications=false')
foreach ($toastCase in @(
        @{ Name = 'no arguments'; Arguments = @(); Expected = 'True True True' },
        @{ Name = 'the quiet pair'; Arguments = $toastQuietPair; Expected = 'False False False' },
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
        @{ Name = 'an override after -e'; Arguments = $toastQuietPair + @('-e', 'cmd.exe', '--app-notifications=true'); Expected = 'False False False' },
        @{ Name = 'an override after -toastactivated'; Arguments = $toastQuietPair + @('-toastactivated', '--app-notifications=true'); Expected = 'False False False' },
        @{ Name = 'a key in another case'; Arguments = $toastQuietPair + @('--App-Notifications=true'); Expected = 'False False False' }
    )) {
    $toastEffective = & $getEffectiveNotifications ([string[]]$toastCase.Arguments)
    $toastActual = "$($toastEffective.Desktop) $($toastEffective.ClipboardCopy) $($toastEffective.ConfigReload)"
    if ($toastActual -cne $toastCase.Expected) {
        throw "The effective notification reading of $($toastCase.Name) is '$toastActual' (desktop, clipboard-copy, config-reload); noctty reads '$($toastCase.Expected)'."
    }
}

# (7) The run-time check's reading, on synthetic command lines.
$saveLaunchLine = '"C:\Program Files\noctty\noctty.exe" --linux-cgroup=always --linux-cgroup-hard-fail=true --windows-job-object-kill-on-close=true --single-instance=false --class=noctty-accessibility-settings-save-0123 --command=cmd.exe'
foreach ($toastCase in @(
        @{ Name = 'the clean case'; Line = "$saveLaunchLine --app-notifications=false --desktop-notifications=false"; Expected = 'quiet' },
        @{ Name = 'an unquoted program name'; Line = 'C:\noctty\noctty.exe --app-notifications=false --desktop-notifications=false'; Expected = 'quiet' },
        @{ Name = 'tabs and runs of spaces'; Line = "noctty.exe`t--app-notifications=false `t  --desktop-notifications=false"; Expected = 'quiet' },
        @{ Name = 'an override before the flags'; Line = "$saveLaunchLine --app-notifications=true --app-notifications=false --desktop-notifications=false"; Expected = 'quiet' },
        @{ Name = 'an override after the flags'; Line = "$saveLaunchLine --app-notifications=false --desktop-notifications=false --app-notifications=true"; Expected = 'it leaves the clipboard-copy notice, config-reload notifications on' },
        @{ Name = 'an empty desktop value after the flags'; Line = "$saveLaunchLine --app-notifications=false --desktop-notifications=false --desktop-notifications="; Expected = 'it leaves desktop-notifications on' },
        @{ Name = 'an empty app value after the flags'; Line = "$saveLaunchLine --app-notifications=false --desktop-notifications=false --app-notifications="; Expected = 'it leaves the clipboard-copy notice, config-reload notifications on' },
        @{ Name = 'a --config-file'; Line = "$saveLaunchLine --app-notifications=false --desktop-notifications=false --config-file=C:\x\notify.conf"; Expected = 'it names a --config-file' },
        @{ Name = 'a bare --config-file before the flags'; Line = "$saveLaunchLine --config-file --app-notifications=false --desktop-notifications=false"; Expected = 'it names a --config-file' },
        @{ Name = 'a quote after the program name'; Line = "$saveLaunchLine --title=`"a b`" --app-notifications=false --desktop-notifications=false"; Expected = 'its arguments hold a quote' },
        @{ Name = '-e before the flags'; Line = "$saveLaunchLine -e cmd.exe --app-notifications=false --desktop-notifications=false"; Expected = 'it leaves desktop-notifications, the clipboard-copy notice, config-reload notifications on' },
        @{ Name = 'no flags'; Line = $saveLaunchLine; Expected = 'it leaves desktop-notifications, the clipboard-copy notice, config-reload notifications on' },
        @{ Name = 'an empty command line'; Line = ''; Expected = 'its command line could not be read' },
        @{ Name = 'no command line'; Line = $null; Expected = 'its command line could not be read' },
        @{ Name = 'an unclosed program name'; Line = '"noctty.exe --app-notifications=false --desktop-notifications=false'; Expected = 'its program name is not closed' }
    )) {
    $toastVerdict = Get-AccessibilitySaveLaunchVerdict -CommandLine $toastCase.Line
    if ($toastVerdict -cne $toastCase.Expected) {
        throw "The run-time verdict on $($toastCase.Name) is '$toastVerdict'; expected '$($toastCase.Expected)'."
    }
}
# The check itself, with the process lookup swapped for a stand-in: it reads the
# process it is given, by its id, returns nothing when the launch is quiet,
# throws otherwise, and never puts the command line in its error.
$saveAssertText = $saveRuntimeFunctions['Assert-AccessibilitySaveLaunchQuiet'].Extent.Text
$saveCimCall = 'CimCmdlets\Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction Stop'
if ([regex]::Matches($saveAssertText, [regex]::Escape($saveCimCall)).Count -ne 1 -or
    [regex]::Matches($saveAssertText, 'CimCmdlets\\Get-CimInstance').Count -ne 1) {
    throw 'Assert-AccessibilitySaveLaunchQuiet must read the command line of the process it is given, by its id, once.'
}
foreach ($saveRuntimeFunction in $saveRuntimeFunctions.Values) {
    if (@($saveRuntimeFunction.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -match '^(?i)(Write-|Out-|Tee-Object|Add-Content|Set-Content|Export-|echo$|tee$)'
                }, $true)).Count -ne 0) {
        throw "$($saveRuntimeFunction.Name) must not print or write anything, the command line least of all."
    }
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
            @{ Name = 'no command line'; Line = $null; Throws = $false; Fails = $true },
            @{ Name = 'a lookup that fails'; Line = "$saveLaunchLine --app-notifications=false --desktop-notifications=false"; Throws = $true; Fails = $true }
        )) {
        $script:toastCimLine = $toastCase.Line
        $script:toastCimThrows = $toastCase.Throws
        $script:toastCimRead = $null
        $toastError = $null
        $toastOutput = @()
        try { $toastOutput = @(Assert-AccessibilitySaveLaunchQuiet -Process $toastSelf -Description 'contract probe' 6>&1 5>&1 4>&1 3>&1) }
        catch { $toastError = $_.Exception.Message }
        if ($script:toastCimRead -cne "Win32_Process|ProcessId = $($toastSelf.Id)") {
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

$saveGrammarNames = @('settingsSaveNotificationArguments', 'saveProbeArguments', 'saveVerifyArguments', 'saveProbeClass', 'saveVerifyClass',
    'saveProbeProcess', 'saveVerifyProcess', 'saveProbe', 'saveVerifyProbe', 'verifyScrollback')
$saveVariableCmdlets = @('Set-Variable', 'New-Variable', 'Get-Variable', 'Remove-Variable', 'Clear-Variable', 'Set-Alias', 'New-Alias',
    'Invoke-Expression', 'Import-Alias', 'sv', 'set', 'nv', 'gv', 'rv', 'clv', 'sal', 'nal', 'iex', 'ipal')
$saveVariableParameters = @('OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'PipelineVariable')
$saveGuidPart = '$([Guid]::NewGuid().ToString(''N''))'
$isSingleQuoted = {
    param($Node)
    $Node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $Node.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuoted
}
# A pipeline of exactly one element and no redirection; that element, or $null.
$soleElement = {
    param($Pipeline)
    if ($Pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $Pipeline.PipelineElements.Count -ne 1) { return $null }
    $element = $Pipeline.PipelineElements[0]
    if ($element.Redirections.Count -ne 0) { return $null }
    $element
}
# Forms through which a script could write a variable, define a function or
# alias, or run a command, by a name the source does not spell (item (4)).
$saveDynamicForms = {
    param([System.Management.Automation.Language.Ast] $Ast)
    @($Ast.FindAll({
                param($node)
                if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    return $node.VariablePath.DriveName -in @('function', 'variable', 'alias') -or $node.VariablePath.UserPath -ieq 'PSCmdlet'
                }
                if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                    return $node.Value -match '^(?i)\s*(function|variable|alias):'
                }
                if ($node -is [System.Management.Automation.Language.DataStatementAst]) { return $true }
                if ($node -is [System.Management.Automation.Language.TypeExpressionAst]) {
                    return $node.TypeName.FullName -match '^(?i)(System\.Management\.Automation\.)?scriptblock$'
                }
                if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
                    return $node.Type.TypeName.FullName -match '^(?i)(System\.Management\.Automation\.)?scriptblock$' -and
                        $node.Child -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]
                }
                if ($node -is [System.Management.Automation.Language.MemberExpressionAst]) {
                    return $node.Member.Extent.Text -in @('SessionState', 'InvokeCommand', 'InvokeProvider')
                }
                if ($node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown) {
                    $target = $node.CommandElements[0]
                    if ($target -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $target -is [System.Management.Automation.Language.VariableExpressionAst] -or
                        $target -is [System.Management.Automation.Language.MemberExpressionAst] -or
                        $target -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $false }
                    if ($target -is [System.Management.Automation.Language.ParenExpressionAst]) {
                        $inner = & $soleElement $target.Pipeline
                        return -not ($inner -is [System.Management.Automation.Language.CommandAst] -and $inner.GetCommandName() -ieq 'Join-Path')
                    }
                    return $true
                }
                $false
            }, $true))
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
        if ($parent -is [System.Management.Automation.Language.ConvertExpressionAst] -and $parent.Type.TypeName.FullName -ieq 'ref') { return $true }
        if ($parent -is [System.Management.Automation.Language.ForEachStatementAst] -and [object]::ReferenceEquals($parent.Variable, $at)) { return $true }
        if ($parent -is [System.Management.Automation.Language.ParameterAst]) { return $true }
        if ($parent -is [System.Management.Automation.Language.StatementAst] -or $parent -is [System.Management.Automation.Language.CommandAst]) { return $false }
    }
    $false
}
# The one plain `$name = ...` of a grammar variable, or $null when the name is
# spelled, written or named in any other way, in the leaf or another job script.
# One walk of a script's variables and strings, kept for the AST it was made
# for: the checks below ask it about every grammar name.
# Parsed library texts, by text.
$saveLibraryAsts = @{}
$walkOf = {
    param([System.Management.Automation.Language.Ast] $Ast)
    if ($null -ne $script:saveWalk -and [object]::ReferenceEquals($script:saveWalk.Ast, $Ast)) { return $script:saveWalk }
    $script:saveWalk = [pscustomobject]@{
        Ast = $Ast
        Variables = @($Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
        Strings = @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                }, $true))
    }
    $script:saveWalk
}
$soleWrite = {
    param([System.Management.Automation.Language.ScriptBlockAst] $Ast, [string] $Name, $Others)
    $spelled = '^(?i)\+?((global|local|script|private|variable|using|env):)?' + [regex]::Escape($Name) + '$'
    $plain = $null
    $walk = & $walkOf $Ast
    foreach ($use in @($walk.Variables | Where-Object { $_.VariablePath.UserPath -match $spelled })) {
        if ($use.VariablePath.UserPath -ine $Name) { return $null }
        if (-not (& $isWritten $use)) { continue }
        $parent = $use.Parent
        if ($null -ne $plain -or $parent -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or
            -not [object]::ReferenceEquals($parent.Left, $use) -or $parent.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { return $null }
        $plain = $parent
    }
    if (@($walk.Strings | Where-Object { $_.Value -match $spelled }).Count -ne 0) { return $null }
    if ($Others.Joined -match ('(?i)' + [regex]::Escape($Name))) { return $null }
    $plain
}
# What the grammar asks of the other job scripts, read once per set of texts.
$summarizeOtherScripts = {
    param([hashtable] $Texts)
    $variableCmdlet = $false
    $containmentElsewhere = $false
    foreach ($other in $Texts.GetEnumerator()) {
        $otherAst = & $parseToastScript $other.Value $other.Key
        if (@($otherAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $saveVariableCmdlets
                    }, $true)).Count -ne 0) { $variableCmdlet = $true }
        if ($other.Key -cne 'scripts\interactive-win11-lib.ps1' -and @($otherAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq 'Get-InteractiveWin11ContainmentArguments'
                    }, $true)).Count -ne 0) { $containmentElsewhere = $true }
    }
    $dynamicForms = $false
    foreach ($other in $Texts.GetEnumerator()) {
        if ((& $saveDynamicForms (& $parseToastScript $other.Value $other.Key)).Count -ne 0) { $dynamicForms = $true }
    }
    [pscustomobject]@{ VariableCmdlet = $variableCmdlet; ContainmentElsewhere = $containmentElsewhere; DynamicForms = $dynamicForms; Joined = (@($Texts.Values) -join "`n") }
}
# The arguments one launch gives noctty, or $null when any part is outside the
# grammar.
$readLaunchArguments = {
    param([System.Management.Automation.Language.ScriptBlockAst] $Ast, [string] $ArgumentsName, [string] $LibraryText, $Others)
    $write = & $soleWrite $Ast $ArgumentsName $Others
    if ($null -eq $write) { return $null }
    $right = & $soleElement $write.Right
    if ($right -isnot [System.Management.Automation.Language.CommandExpressionAst] -and $write.Right -is [System.Management.Automation.Language.CommandExpressionAst]) { $right = $write.Right }
    if ($right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or $right.Redirections.Count -ne 0) { return $null }
    $elements = & $arrayStatements $right.Expression
    if ($null -eq $elements) { return $null }
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($element in $elements) {
        if ($element -is [System.Management.Automation.Language.CommandAst]) {
            if ($element.GetCommandName() -cne 'Get-InteractiveWin11ContainmentArguments' -or $element.CommandElements.Count -ne 1) { return $null }
            if (-not $saveLibraryAsts.ContainsKey($LibraryText)) { $saveLibraryAsts[$LibraryText] = & $parseToastScript $LibraryText 'interactive-win11-lib.ps1' }
            $library = $saveLibraryAsts[$LibraryText]
            $definitions = @($library.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq 'Get-InteractiveWin11ContainmentArguments'
            }, $true))
            if ($definitions.Count -ne 1 -or $null -ne $definitions[0].Parameters -or $null -ne $definitions[0].Body.ParamBlock -or
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
            $expression.NestedExpressions[0].VariablePath.UserPath -ceq $Matches['name'] -and $Matches['name'] -cin $saveGrammarNames) {
            $classWrite = & $soleWrite $Ast $Matches['name'] $Others
            if ($null -eq $classWrite -or $classWrite.Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
                $classWrite.Right.Redirections.Count -ne 0) { return $null }
            $class = $classWrite.Right.Expression
            if ($class -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                $class.StringConstantType -ne [System.Management.Automation.Language.StringConstantType]::DoubleQuoted -or
                $class.NestedExpressions.Count -ne 1 -or $class.NestedExpressions[0] -isnot [System.Management.Automation.Language.SubExpressionAst] -or
                $class.NestedExpressions[0].Extent.Text -cne $saveGuidPart -or
                $class.Value -cnotmatch ('^(?<prefix>[A-Za-z0-9-]+)' + [regex]::Escape($saveGuidPart) + '$')) { return $null }
            $resolved.Add('--class=' + $Matches['prefix'] + ('0' * 32))
            continue
        }
        if ($expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $expression.VariablePath.UserPath -ceq 'settingsSaveNotificationArguments') {
            $flagsWrite = & $soleWrite $Ast 'settingsSaveNotificationArguments' $Others
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
$testQuietSettingsSaves = {
    param([string] $Text, [string] $LibraryText, $Others)
    $ast = & $parseToastScript $Text 'interactive-win11-accessibility.ps1'
    # (4), the leaf-wide part.
    foreach ($command in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        if ($command.GetCommandName() -in $saveVariableCmdlets) { return $false }
        foreach ($parameter in @($command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })) {
            if ($parameter.ParameterName -in @('ov', 'ev', 'wv', 'iv', 'pv')) { return $false }
            foreach ($variableParameter in $saveVariableParameters) {
                $stem = $variableParameter.Length - 'ariable'.Length
                if ($parameter.ParameterName.Length -ge $stem -and $variableParameter.StartsWith($parameter.ParameterName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            }
        }
    }
    if (@($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -match '(?i)ExecutionContext'
                }, $true)).Count -ne 0) { return $false }
    if ($Others.VariableCmdlet -or $Others.ContainmentElsewhere -or $Others.DynamicForms) { return $false }
    if ((& $saveDynamicForms $ast).Count -ne 0) { return $false }
    if (@($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ieq 'Get-InteractiveWin11ContainmentArguments'
                }, $true)).Count -ne 0) { return $false }
    # (2) and (3): the two launches and what each is given.
    $starts = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq 'Start-AccessibilityProcessWithEnvironment'
    }, $true))
    if ($starts.Count -ne 2) { return $false }
    $launched = @{}
    foreach ($process in @('saveProbeProcess', 'saveVerifyProcess')) {
        $write = & $soleWrite $ast $process $Others
        if ($null -eq $write) { return $false }
        $start = & $soleElement $write.Right
        if ($start -isnot [System.Management.Automation.Language.CommandAst] -or $start.GetCommandName() -cne 'Start-AccessibilityProcessWithEnvironment') { return $false }
        $argumentList = & $getNamedArgument $start 'ArgumentList'
        if ($argumentList -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
        $resolvedArguments = & $readLaunchArguments $ast $argumentList.VariablePath.UserPath $LibraryText $Others
        if ($null -eq $resolvedArguments -or $argumentList.VariablePath.UserPath -cnotin $saveGrammarNames) { return $false }
        # (5).
        if (@($resolvedArguments | Where-Object { $_ -match '[\s"''`]' -or $_ -match '^--config-file(=|$)' }).Count -ne 0) { return $false }
        $effective = & $getEffectiveNotifications $resolvedArguments
        if ($effective.Desktop -or $effective.ClipboardCopy -or $effective.ConfigReload) { return $false }
        $launched[$process] = $start
    }
    if (@($starts | Where-Object { $s = $_; @($launched.Values | Where-Object { [object]::ReferenceEquals($_, $s) }).Count -eq 1 }).Count -ne 2) { return $false }
    foreach ($tie in @(
            @{ Name = 'saveProbe'; Command = 'Open-AccessibilitySettingsProbe'; Parameter = 'Process'; Source = 'saveProbeProcess' },
            @{ Name = 'saveVerifyProbe'; Command = 'Open-AccessibilitySettingsProbe'; Parameter = 'Process'; Source = 'saveVerifyProcess' },
            @{ Name = 'verifyScrollback'; Command = 'Get-AccessibilityScrollbackProbe'; Parameter = 'SettingsProbe'; Source = 'saveVerifyProbe' })) {
        $write = & $soleWrite $ast $tie.Name $Others
        if ($null -eq $write) { return $false }
        $call = & $soleElement $write.Right
        if ($call -isnot [System.Management.Automation.Language.CommandAst] -or $call.GetCommandName() -cne $tie.Command) { return $false }
        $source = & $getNamedArgument $call $tie.Parameter
        if ($source -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $source.VariablePath.UserPath -cne $tie.Source) { return $false }
    }
    # (1): the saves, on those probes.
    $closes = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq 'Invoke-AccessibilitySettingsCloseAction'
    }, $true))
    $saveCloses = [Collections.Generic.List[object]]::new()
    foreach ($close in $closes) {
        $action = & $getNamedArgument $close 'ActionName'
        if (-not (& $isSingleQuoted $action)) { return $false }
        if ($action.Value -ceq 'Save and close') { $saveCloses.Add($close) }
    }
    if ($saveCloses.Count -ne 1) { return $false }
    $closeProbe = & $getNamedArgument $saveCloses[0] 'SettingsProbe'
    if ($closeProbe -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $closeProbe.VariablePath.UserPath -cne 'saveProbe') { return $false }
    $saveInvokes = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Extent.Text -ieq 'TryGetCurrentPattern' -and
            $node.Expression -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Expression.Member.Extent.Text -ieq 'Save'
    }, $true))
    if ($saveInvokes.Count -ne 1 -or $saveInvokes[0].Expression.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $saveInvokes[0].Expression.Expression.VariablePath.UserPath -cne 'verifyScrollback') { return $false }
    if ([regex]::Matches($Text, $settingsSaves['a Settings Save invoke']).Count -ne 1 -or
        [regex]::Matches($Text, $settingsSaves['a Settings Save and close']).Count -ne 1) { return $false }
    # (4), the reads: the three arrays only where (3) puts them, the
    # default-config list only where its check reads it.
    foreach ($counted in @(
            @{ Name = 'settingsSaveNotificationArguments'; Uses = 3 }, @{ Name = 'saveProbeArguments'; Uses = 2 },
            @{ Name = 'saveVerifyArguments'; Uses = 2 }, @{ Name = 'settingsDefaultConfigFiles'; Uses = 2 })) {
        $countedPattern = '^(?i)((global|local|script|private|variable|using|env):)?' + [regex]::Escape($counted.Name) + '$'
        $uses = @((& $walkOf $ast).Variables | Where-Object { $_.VariablePath.UserPath -match $countedPattern }).Count
        if ($uses -ne $counted.Uses) { return $false }
    }
    if ($null -eq (& $soleWrite $ast 'settingsDefaultConfigFiles' $Others)) { return $false }
    # (2), the environment both launches get, and the paths the checks read.
    foreach ($process in @('saveProbeProcess', 'saveVerifyProcess')) {
        $start = & $soleElement (& $soleWrite $ast $process $Others).Right
        $environment = & $getNamedArgument $start 'EnvironmentVariables'
        if ($environment -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            $environment.VariablePath.UserPath -cne 'settingsProbeEnvironment') { return $false }
    }
    foreach ($pin in @(
            @{ Name = 'settingsProbeEnvironment'; Right = 'Get-InteractiveWin11Environment -Layout $settingsPersistenceLayout' },
            @{ Name = 'sandboxConfigPath'; Right = 'Join-Path $settingsPersistenceLayout.LocalAppData ''noctty\config.ghostty''' })) {
        $write = & $soleWrite $ast $pin.Name $Others
        if ($null -eq $write -or $write.Right.Extent.Text -cne $pin.Right) { return $false }
    }
    $layoutWrite = & $soleWrite $ast 'settingsPersistenceLayout' $Others
    $layoutCall = if ($null -ne $layoutWrite) { & $soleElement $layoutWrite.Right } else { $null }
    if ($layoutCall -isnot [System.Management.Automation.Language.CommandAst] -or
        $layoutCall.GetCommandName() -cne 'Get-InteractiveWin11SandboxLayout') { return $false }
    # (5): one block holds the launches and every statement of (2), (3), (6)
    # and (7), as direct statements, in order.
    $saveBlock = (& $soleWrite $ast 'saveProbeProcess' $Others).Parent
    if ($saveBlock -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $false }
    $statements = @($saveBlock.Statements)
    $indexOf = {
        param($Statement)
        for ($i = 0; $i -lt $statements.Count; $i++) { if ([object]::ReferenceEquals($statements[$i], $Statement)) { return $i } }
        -1
    }
    $normalized = { param([string] $Value) ($Value.Replace("`r`n", "`n") -replace '(?m)^[ \t]+', '').Trim() }
    $textIndex = {
        param([string] $Value)
        $want = & $normalized $Value
        $found = @(for ($i = 0; $i -lt $statements.Count; $i++) { if ((& $normalized $statements[$i].Extent.Text) -ceq $want) { $i } })
        if ($found.Count -eq 1) { $found[0] } else { -1 }
    }
    $writeIndex = {
        param([string] $Name)
        $write = & $soleWrite $ast $Name $Others
        if ($null -eq $write) { return -1 }
        & $indexOf $write
    }
    $callIndex = {
        param([string] $Command, [string] $Parameter, [string] $Variable)
        $calls = @($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq $Command
                }, $true) | Where-Object {
                $value = & $getNamedArgument $_ $Parameter
                $value -is [System.Management.Automation.Language.VariableExpressionAst] -and $value.VariablePath.UserPath -ceq $Variable
            })
        if ($calls.Count -ne 1 -or $calls[0].Parent -isnot [System.Management.Automation.Language.PipelineAst] -or
            $calls[0].Parent.PipelineElements.Count -ne 1) { return -1 }
        & $indexOf $calls[0].Parent
    }
    if (@($ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ieq 'Assert-AccessibilitySaveLaunchQuiet'
                }, $true)).Count -ne 2) { return $false }
    $order = [ordered]@{
        DefaultList = & $textIndex $saveNoDefaultConfigList
        DefaultLoop = & $textIndex $saveNoDefaultConfigLoop
        Flags = & $writeIndex 'settingsSaveNotificationArguments'
        ProbeClass = & $writeIndex 'saveProbeClass'
        ProbeArguments = & $writeIndex 'saveProbeArguments'
        ProbeStart = & $writeIndex 'saveProbeProcess'
        ProbeCheck = & $callIndex 'Assert-AccessibilitySaveLaunchQuiet' 'Process' 'saveProbeProcess'
        ProbeOpen = & $writeIndex 'saveProbe'
        ProbeStop = & $callIndex 'Stop-InteractiveWin11Process' 'Process' 'saveProbeProcess'
        IncludeCheck = & $textIndex $saveNoIncludeGuard
        VerifyClass = & $writeIndex 'saveVerifyClass'
        VerifyArguments = & $writeIndex 'saveVerifyArguments'
        VerifyStart = & $writeIndex 'saveVerifyProcess'
        VerifyCheck = & $callIndex 'Assert-AccessibilitySaveLaunchQuiet' 'Process' 'saveVerifyProcess'
        VerifyOpen = & $writeIndex 'saveVerifyProbe'
        VerifyScrollback = & $writeIndex 'verifyScrollback'
    }
    if (@($order.Values | Where-Object { $_ -lt 0 }).Count -ne 0) { return $false }
    foreach ($before in @(
            @('DefaultList', 'DefaultLoop'), @('DefaultLoop', 'ProbeStart'), @('Flags', 'ProbeArguments'), @('Flags', 'VerifyArguments'),
            @('ProbeClass', 'ProbeArguments'), @('ProbeArguments', 'ProbeStart'), @('ProbeStart', 'ProbeCheck'), @('ProbeCheck', 'ProbeOpen'),
            @('ProbeOpen', 'ProbeStop'), @('ProbeStop', 'IncludeCheck'), @('IncludeCheck', 'VerifyStart'), @('VerifyClass', 'VerifyArguments'),
            @('VerifyArguments', 'VerifyStart'), @('VerifyStart', 'VerifyCheck'), @('VerifyCheck', 'VerifyOpen'), @('VerifyOpen', 'VerifyScrollback'))) {
        if ($order[$before[0]] -ge $order[$before[1]]) { return $false }
    }
    # (7): that block is the leaf's normal-mode branch, a direct statement of
    # its main try, whose catch keeps the error and whose end throws it.
    $modeIf = $saveBlock.Parent
    if ($modeIf -isnot [System.Management.Automation.Language.IfStatementAst] -or -not [object]::ReferenceEquals($modeIf.ElseClause, $saveBlock) -or
        $modeIf.Clauses.Count -ne 2 -or $modeIf.Clauses[0].Item1.Extent.Text -cne '$ThemeDiagnosticOnly' -or
        $modeIf.Clauses[1].Item1.Extent.Text -cne '$ColdDiagnosticOnly') { return $false }
    $mainBlock = $modeIf.Parent
    $mainTry = $mainBlock.Parent
    if ($mainBlock -isnot [System.Management.Automation.Language.StatementBlockAst] -or $mainTry -isnot [System.Management.Automation.Language.TryStatementAst] -or
        -not [object]::ReferenceEquals($mainTry.Body, $mainBlock) -or $mainTry.CatchClauses.Count -ne 1 -or $mainTry.CatchClauses[0].CatchTypes.Count -ne 0 -or
        $mainTry.CatchClauses[0].Body.Statements.Count -ne 1 -or $mainTry.CatchClauses[0].Body.Statements[0].Extent.Text -cne '$runFailure = $_') { return $false }
    $outerBlock = $mainTry.Parent
    if ($outerBlock -isnot [System.Management.Automation.Language.StatementBlockAst]) { return $false }
    $runFailureWrites = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -match '^(?i)((global|local|script|private|variable|using|env):)?runFailure$'
            }, $true) | Where-Object { & $isWritten $_ })
    if ($runFailureWrites.Count -ne 2) { return $false }
    $endIf = @($outerBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses.Count -eq 1 -and $null -eq $_.ElseClause -and
                $_.Clauses[0].Item1.Extent.Text -ceq '$failureMessages.Count -gt 0' -and $_.Clauses[0].Item2.Statements.Count -eq 1 -and
                $_.Clauses[0].Item2.Statements[0].Extent.Text -ceq 'throw "Accessibility validation failed: $($failureMessages -join '' | '')"'
        })
    $keepIf = @($outerBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and $_.Clauses.Count -eq 1 -and
                $_.Clauses[0].Item1.Extent.Text -ceq '$null -ne $runFailure' -and
                $_.Clauses[0].Item2.Extent.Text.Contains('$failureMessages.Add("$($runFailure.Exception.Message)$failureLocation")')
        })
    if ($endIf.Count -ne 1 -or $keepIf.Count -ne 1 -or (& { $s = @($outerBlock.Statements); [array]::IndexOf($s, $mainTry) }) -ge
        (& { $s = @($outerBlock.Statements); [array]::IndexOf($s, $keepIf[0]) }) -or
        (& { $s = @($outerBlock.Statements); [array]::IndexOf($s, $keepIf[0]) }) -ge (& { $s = @($outerBlock.Statements); [array]::IndexOf($s, $endIf[0]) })) { return $false }
    $true
}
# Every caller gets exactly one bool back, or the contract stops.
$runQuietCheck = {
    param([string] $Text, [string] $LibraryText, $Others)
    $result = @(& $testQuietSettingsSaves $Text $LibraryText $Others)
    if ($result.Count -ne 1 -or $result[0] -isnot [bool]) { throw "The quiet Settings save check returned '$($result -join ',')', not one bool." }
    $result[0]
}
$saveNoDefaultConfigGuard = @'
    $settingsDefaultConfigFiles = @('noctty\config.ghostty', 'ghostty\config', 'winghostty\config.ghostty')
    foreach ($defaultConfigFile in $settingsDefaultConfigFiles) {
        if ([System.IO.File]::Exists((Join-Path $settingsPersistenceLayout.LocalAppData $defaultConfigFile))) {
            throw "The settings save sandbox already holds $defaultConfigFile; the saving processes would read it."
        }
    }
'@
$saveNoIncludeGuard = @'
    if ((Get-Content -LiteralPath $sandboxConfigPath -Raw) -match '(?m)^\s*config-file\s*=') {
        throw 'The saved settings file names a config-file include; the verifier would read it after its command line.'
    }
'@
$saveNoDefaultConfigList = ($saveNoDefaultConfigGuard.Replace("`r`n", "`n") -split "`n")[0]
$saveNoDefaultConfigLoop = @(($saveNoDefaultConfigGuard.Replace("`r`n", "`n") -split "`n") | Select-Object -Skip 1) -join "`n"
$accessibilityText = $jobFileTexts[$accessibilityLeaf]
$toastEol = if ($accessibilityText.Contains("`r`n")) { "`r`n" } else { "`n" }
$saveNoDefaultConfigGuard = $saveNoDefaultConfigGuard.Replace("`r`n", "`n").Replace("`n", $toastEol)
$saveNoIncludeGuard = $saveNoIncludeGuard.Replace("`r`n", "`n").Replace("`n", $toastEol)
$launchLibraryText = $jobFileTexts['scripts\interactive-win11-lib.ps1']
$saveOtherTexts = @{}
foreach ($toastFile in $jobFiles) { if ($toastFile -cne $accessibilityLeaf) { $saveOtherTexts[$toastFile] = $jobFileTexts[$toastFile] } }
$saveOthers = & $summarizeOtherScripts $saveOtherTexts
if (-not (& $runQuietCheck $accessibilityText $launchLibraryText $saveOthers)) {
    throw 'interactive-win11-accessibility.ps1 must save Settings only in its save probe and verifier processes, each started with every notification off and checked at run time before its save, in the grammar this contract states (Contracts.90-Workflows.ps1, EVIDENCE-TOAST-FOREGROUND); the grammar refuses the forms it does not list.'
}
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
foreach ($toastControl in @(
        # What the leaf has, with the flags written the other allowed way.
        @{ Name = 'the flags as a bare array literal (in the grammar)'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = '--app-notifications=false', '--desktop-notifications=false'"; Accept = $true },
        @{ Name = 'an override before the flags (the flags win)'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--app-notifications=true'`n$toastQuietLine"; Accept = $true },
        @{ Name = 'empty values before the flags (the flags win)'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--app-notifications='`n        '--desktop-notifications='`n$toastQuietLine"; Accept = $true },
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
        @{ Name = 'Save and close on another probe'; From = "    Invoke-AccessibilitySettingsCloseAction ``$toastEol        -SettingsProbe `$saveProbe ``"; To = "    Invoke-AccessibilitySettingsCloseAction ``$toastEol        -SettingsProbe `$ownerProbe ``"; Accept = $false },
        @{ Name = 'the default-config check removed'; From = $saveNoDefaultConfigGuard; To = ''; Accept = $false },
        @{ Name = 'the include check removed'; From = $saveNoIncludeGuard; To = ''; Accept = $false },
        @{ Name = 'the include check after the verifier starts'; From = $saveNoIncludeGuard; To = ''; Then = @(, @("    `$saveVerifyCleanup = `$saveVerifyProcess`n", "    `$saveVerifyCleanup = `$saveVerifyProcess`n$saveNoIncludeGuard")); Accept = $false },
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
        @{ Name = 'a variable: provider write (Opus L1, round 4)'; From = $toastProbeStart; To = "    Set-Item -Path ('variable:savePro' + 'beArguments') -Value @()`n$toastProbeStart"; Accept = $false },
        @{ Name = '& on a computed name (Opus L1, round 4)'; From = $toastProbeStart; To = "    & ('Set-' + 'Variable') -Name ('savePro' + 'beArguments') -Value @()`n$toastProbeStart"; Accept = $false },
        @{ Name = '. on an expanded string'; From = $toastProbeStart; To = "    . `"Set-`$('Variable')`" -Name x -Value 1`n$toastProbeStart"; Accept = $false },
        @{ Name = 'a data section named like the flags (Opus L1, round 4)'; From = $toastProbeClass; To = "    data settingsSaveNotificationArguments { '--app-notifications=true' }`n$toastProbeClass"; Accept = $false },
        @{ Name = 'the default-config check in a block comment (Opus L2, round 4)'; From = $saveNoDefaultConfigGuard; To = "    <#`n$saveNoDefaultConfigGuard`n    #>"; Accept = $false },
        @{ Name = 'the default-config check under if ($false) (Opus L2, round 4)'; From = $saveNoDefaultConfigGuard; To = "    if (`$false) {`n$saveNoDefaultConfigGuard`n    }"; Accept = $false },
        @{ Name = 'the include check in a block comment (Opus L2, round 4)'; From = $saveNoIncludeGuard; To = "    <#`n$saveNoIncludeGuard`n    #>"; Accept = $false },
        @{ Name = 'another environment for the probe (Opus L2, round 4)'; From = "        -ArgumentList `$saveProbeArguments ``$toastEol        -WorkingDirectory `$repoRoot ``$toastEol        -EnvironmentVariables `$settingsProbeEnvironment ``"; To = "        -ArgumentList `$saveProbeArguments ``$toastEol        -WorkingDirectory `$repoRoot ``$toastEol        -EnvironmentVariables `$otherEnvironment ``"; Accept = $false },
        # The run-time check (item (7)).
        @{ Name = 'the probe launch without its run-time check'; From = $toastProbeCheck; To = ''; Accept = $false },
        @{ Name = 'the verifier launch without its run-time check'; From = $toastVerifyCheck; To = ''; Accept = $false },
        @{ Name = 'the probe check after its probe opens'; From = $toastProbeCheck; To = ''; Then = @(, @($toastProbeOpenLine, "$toastProbeOpenLine$toastProbeCheck")); Accept = $false },
        @{ Name = 'the probe check under if ($false)'; From = $toastProbeCheck; To = "    if (`$false) {`n$toastProbeCheck    }`n"; Accept = $false },
        @{ Name = 'the probe check in a comment'; From = $toastProbeCheck; To = "    # Assert-AccessibilitySaveLaunchQuiet -Process `$saveProbeProcess -Description 'settings save probe'`n"; Accept = $false },
        @{ Name = 'the probe check inside a try that swallows its error'; From = $toastProbeCheck; To = "    try {`n$toastProbeCheck    } catch { }`n"; Accept = $false },
        @{ Name = 'a third run-time check'; From = $toastProbeCheck; To = "$toastProbeCheck$toastProbeCheck"; Accept = $false },
        @{ Name = 'the main catch dropping the error'; From = "catch {$toastEol    `$runFailure = `$_$toastEol}"; To = "catch {$toastEol    `$runFailure = `$null$toastEol}"; Accept = $false },
        @{ Name = 'the final throw under if ($false)'; From = "if (`$failureMessages.Count -gt 0) {"; To = "if (`$false -and `$failureMessages.Count -gt 0) {"; Accept = $false },
        @{ Name = 'the error cleared before the end'; From = "`$failureMessages = [System.Collections.Generic.List[string]]::new()"; To = "`$runFailure = `$null`n`$failureMessages = [System.Collections.Generic.List[string]]::new()"; Accept = $false }
    )) {
    $toastMutated = $accessibilityText
    $toastEdits = @(, @($toastControl.From, $toastControl.To)) + @(if ($toastControl.ContainsKey('Then')) { $toastControl.Then })
    foreach ($toastEdit in $toastEdits) {
        $toastFrom = $toastEdit[0].Replace("`r`n", "`n").Replace("`n", $toastEol)
        $toastTo = $toastEdit[1].Replace("`r`n", "`n").Replace("`n", $toastEol)
        if (([regex]::Matches($toastMutated, [regex]::Escape($toastFrom))).Count -ne 1) {
            throw "Quiet Settings save control '$($toastControl.Name)' lost its anchor."
        }
        $toastMutated = $toastMutated.Replace($toastFrom, $toastTo)
    }
    if ((& $runQuietCheck $toastMutated $launchLibraryText $saveOthers) -ne $toastControl.Accept) {
        throw "The quiet Settings save check $(if ($toastControl.Accept) { 'refused' } else { 'accepted' }) $($toastControl.Name)."
    }
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
        @{ Name = 'a pipeline in the containment arguments'; Library = "        '--windows-job-object-kill-on-close=true' | Sort-Object$toastLibraryEol    )"; Accept = $false }
    )) {
    if ((& $runQuietCheck $accessibilityText $launchLibraryText.Replace($toastContainmentReturn, $toastControl.Library) $saveOthers) -ne $toastControl.Accept) {
        throw "The quiet Settings save check $(if ($toastControl.Accept) { 'refused' } else { 'accepted' }) $($toastControl.Name)."
    }
}
$toastOtherDefinition = $saveOtherTexts.Clone()
$toastOtherDefinition['scripts\interactive-win11-window-lib.ps1'] += "`nfunction Get-InteractiveWin11ContainmentArguments { return @('--linux-cgroup=always') }"
if (& $runQuietCheck $accessibilityText $launchLibraryText (& $summarizeOtherScripts $toastOtherDefinition)) {
    throw 'The quiet Settings save check accepted a containment function defined in another job script.'
}
$toastOtherWrite = $saveOtherTexts.Clone()
$toastOtherWrite['test\windows\interactive-win11-stateful-lib.ps1'] += "`nfunction Reset-Flags { `$script:settingsSaveNotificationArguments = @('--app-notifications=true') }"
if (& $runQuietCheck $accessibilityText $launchLibraryText (& $summarizeOtherScripts $toastOtherWrite)) {
    throw 'The quiet Settings save check accepted another job script naming a grammar variable.'
}
$toastOtherCmdlet = $saveOtherTexts.Clone()
$toastOtherCmdlet['scripts\interactive-win11-window-lib.ps1'] += "`nfunction Reset-Any([string] `$Name) { Set-Variable -Name `$Name -Scope Script -Value `$null }"
if (& $runQuietCheck $accessibilityText $launchLibraryText (& $summarizeOtherScripts $toastOtherCmdlet)) {
    throw 'The quiet Settings save check accepted a variable cmdlet in another job script.'
}
$toastOtherFunction = $saveOtherTexts.Clone()
$toastOtherFunction['scripts\interactive-win11-window-lib.ps1'] += "`n`${function:Get-InteractiveWin11ContainmentArguments} = { return @('--linux-cgroup=always', '-e', 'cmd.exe') }"
if (& $runQuietCheck $accessibilityText $launchLibraryText (& $summarizeOtherScripts $toastOtherFunction)) {
    throw 'The quiet Settings save check accepted a ${function:} write in another job script (Opus L1, round 4).'
}
$toastOtherCreate = $saveOtherTexts.Clone()
$toastOtherCreate['test\windows\interactive-win11-stateful-lib.ps1'] += "`nfunction Invoke-Late([string] `$Text) { . ([scriptblock]::Create(`$Text)) }"
if (& $runQuietCheck $accessibilityText $launchLibraryText (& $summarizeOtherScripts $toastOtherCreate)) {
    throw 'The quiet Settings save check accepted [scriptblock]::Create in another job script.'
}
Remove-Item -LiteralPath Function:\Get-AccessibilityNotificationSettings, Function:\Get-AccessibilitySaveLaunchVerdict -ErrorAction SilentlyContinue
Remove-Variable -Scope Script -Name saveWalk -ErrorAction SilentlyContinue
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
