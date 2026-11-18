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

# The accessibility leaf's Settings saves run only in its two probe processes,
# and noctty starts each with every notification off. What counts is what the
# command line leaves each setting at. The reading below models the rules of
# `cli/args.zig` (`parse`, `parseIntoField`, `parseBool`, `parsePackedStruct`)
# and `Config.parseManuallyHook` for the forms these launches can use: every
# `--key=value` replaces the field whole, a packed value starting from the
# defaults; an empty value resets the field to its default; the last one wins;
# a bare `--desktop-notifications` is true; a value noctty cannot parse changes
# nothing; nothing after `-e`, `-Embedding` or `-ToastActivated` is
# configuration. Anything it does not model fails closed: a `--config-file`
# (an include is read after the command line, `Config.load`, and its values
# win), an element with whitespace or a quote (`Start-Process -ArgumentList`
# joins the elements with spaces and quotes nothing, so one element can reach
# noctty as several arguments), and a variable changed in any way but its one
# plain assignment. A save then shows its banner and, with `config-reload` off
# and that banner shown, `settingsNotifySuccessThunk` returns before the toast
# (settings.md PROFILES-4 trap 7).
$parseNocttyBool = {
    param([string] $Text)
    if ($Text -cin @('1', 't', 'T', 'true')) { $true } elseif ($Text -cin @('0', 'f', 'F', 'false')) { $false } else { $null }
}
$getEffectiveNotifications = {
    param([string[]] $Arguments)
    $state = [ordered]@{ Desktop = $true; ClipboardCopy = $true; ConfigReload = $true }
    foreach ($argument in $Arguments) {
        if ($argument -ceq '-e' -or $argument -ieq '-Embedding' -or $argument -ieq '-ToastActivated') { break }
        if (-not $argument.StartsWith('--', [StringComparison]::Ordinal)) { continue }
        $key = $argument.Substring(2)
        $value = $null
        $equals = $key.IndexOf('=')
        if ($equals -ge 0) { $value = $key.Substring($equals + 1); $key = $key.Substring(0, $equals) }
        if ($key -ceq 'desktop-notifications') {
            if ($null -ne $value -and $value.Length -eq 0) { $state.Desktop = $true; continue }
            $parsedBool = & $parseNocttyBool $(if ($null -eq $value) { 't' } else { $value })
            if ($null -ne $parsedBool) { $state.Desktop = $parsedBool }
        }
        elseif ($key -ceq 'app-notifications' -and $null -ne $value) {
            if ($value.Length -eq 0) { $state.ClipboardCopy = $true; $state.ConfigReload = $true; continue }
            $parsedBool = & $parseNocttyBool $value
            if ($null -ne $parsedBool) { $state.ClipboardCopy = $parsedBool; $state.ConfigReload = $parsedBool; continue }
            $fields = [ordered]@{ ClipboardCopy = $true; ConfigReload = $true }
            $valid = $true
            foreach ($part in $value.Split(',')) {
                $part = $part.Trim(' ', "`t")
                $on = -not $part.StartsWith('no-', [StringComparison]::Ordinal)
                if (-not $on) { $part = $part.Substring(3) }
                if ($part -ceq 'clipboard-copy') { $fields.ClipboardCopy = $on }
                elseif ($part -ceq 'config-reload') { $fields.ConfigReload = $on }
                else { $valid = $false; break }
            }
            if ($valid) { $state.ClipboardCopy = $fields.ClipboardCopy; $state.ConfigReload = $fields.ConfigReload }
        }
    }
    [pscustomobject]$state
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
# A variable's one plain assignment (`$name = ...`), or $null when the variable
# is changed in any other way or used where its value could change: a scoped
# spelling (`$script:name`), an index or member write, `+=` and the other
# operators, a variable cmdlet or anything else naming it as a string, `[ref]`.
# The reads a launch makes are allowed: an element of an `@( )` array, an
# argument of the start, a part of an expanded string.
$findSoleAssignment = {
    param([System.Management.Automation.Language.ScriptBlockAst] $Ast, [string] $Name)
    $plain = $null
    $spelled = '^(?i)((global|local|script|private|variable|using|env):)?' + [regex]::Escape($Name) + '$'
    foreach ($use in @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -match $spelled
                }, $true))) {
        if ($use.VariablePath.UserPath -ine $Name) { return $null }
        $parent = $use.Parent
        if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($parent.Left, $use)) {
            if ($parent.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals -or $null -ne $plain) { return $null }
            $plain = $parent
            continue
        }
        if ($parent -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { continue }
        if ($parent -is [System.Management.Automation.Language.CommandExpressionAst] -and $parent.Parent -is [System.Management.Automation.Language.PipelineAst] -and
            $parent.Parent.Parent -is [System.Management.Automation.Language.StatementBlockAst] -and
            $parent.Parent.Parent.Parent -is [System.Management.Automation.Language.ArrayExpressionAst]) { continue }
        if ($parent -is [System.Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -ceq 'Start-AccessibilityProcessWithEnvironment') { continue }
        return $null
    }
    if (@($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match $spelled
                }, $true)).Count -ne 0) { return $null }
    $plain
}
# An expanded string's value with each part known: a variable whose one plain
# assignment is a string made the same way, or a fresh GUID's 32 hex digits;
# $null for anything else.
$guidPart = '$([Guid]::NewGuid().ToString(''N''))'
$expandString = {
    param([System.Management.Automation.Language.ScriptBlockAst] $Ast, $Expression, [int] $Depth)
    if ($Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Expression.Value }
    if ($Expression -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst] -or $Depth -gt 4) { return $null }
    $text = $Expression.Value
    foreach ($part in $Expression.NestedExpressions) {
        if ($part -is [System.Management.Automation.Language.SubExpressionAst] -and $part.Extent.Text -ceq $guidPart) {
            $text = $text.Replace($guidPart, ('0' * 32))
            continue
        }
        if ($part -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $null }
        $assignment = & $findSoleAssignment $Ast $part.VariablePath.UserPath
        if ($null -eq $assignment -or $assignment.Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
        $value = & $expandString $Ast $assignment.Right.Expression ($Depth + 1)
        if ($null -eq $value) { return $null }
        $text = $text.Replace($part.Extent.Text, $value)
    }
    $text
}
# A launch's arguments as noctty gets them, from the parsed array literal; $null
# when one cannot be known from the source (a variable without one plain literal
# assignment, a command other than the shared containment arguments, an
# expanded string with a part it cannot know) or when one element could reach
# noctty as more than one argument (whitespace or a quote in it).
$resolveLaunchArguments = {
    param([System.Management.Automation.Language.ScriptBlockAst] $Ast, [System.Management.Automation.Language.ArrayExpressionAst] $Array, [string] $LibraryText)
    $resolved = [Collections.Generic.List[string]]::new()
    foreach ($statement in $Array.SubExpression.Statements) {
        if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1) { return $null }
        $element = $statement.PipelineElements[0]
        if ($element -is [System.Management.Automation.Language.CommandAst]) {
            if ($element.GetCommandName() -cne 'Get-InteractiveWin11ContainmentArguments' -or $element.CommandElements.Count -ne 1) { return $null }
            $library = & $parseToastScript $LibraryText 'interactive-win11-lib.ps1'
            $definition = @($library.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-InteractiveWin11ContainmentArguments'
            }, $true))
            if ($definition.Count -ne 1 -or $definition[0].Body.EndBlock.Statements.Count -ne 1 -or
                $definition[0].Body.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.ReturnStatementAst]) { return $null }
            $returned = $definition[0].Body.EndBlock.Statements[0].Pipeline.PipelineElements[0].Expression
            if ($returned -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { return $null }
            foreach ($item in $returned.SubExpression.Statements) {
                $value = $item.PipelineElements[0].Expression
                if ($item.PipelineElements.Count -ne 1 -or $value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
                $resolved.Add($value.Value)
            }
            continue
        }
        $expression = $element.Expression
        if ($expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            $value = & $expandString $Ast $expression 0
            if ($null -eq $value) { return $null }
            $resolved.Add($value)
            continue
        }
        if ($expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $assignment = & $findSoleAssignment $Ast $expression.VariablePath.UserPath
            if ($null -eq $assignment -or $assignment.Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
            $literal = $assignment.Right.Expression
            if ($literal -isnot [System.Management.Automation.Language.ArrayExpressionAst] -or $literal.SubExpression.Statements.Count -ne 1) { return $null }
            $items = $literal.SubExpression.Statements[0].PipelineElements[0].Expression
            $values = if ($items -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($items.Elements) } else { @($items) }
            foreach ($value in $values) {
                if ($value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
                $resolved.Add($value.Value)
            }
            continue
        }
        return $null
    }
    if (@($resolved | Where-Object { $_ -match '[\s"''`]' }).Count -ne 0) { return $null }
    , [string[]]$resolved
}
$testQuietSettingsSaves = {
    param([string] $Text, [string] $LibraryText)
    $ast = & $parseToastScript $Text 'interactive-win11-accessibility.ps1'
    $starts = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Start-AccessibilityProcessWithEnvironment'
    }, $true))
    $processes = @{}
    foreach ($start in $starts) {
        $assignment = $start.Parent
        while ($null -ne $assignment -and $assignment -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { $assignment = $assignment.Parent }
        if ($null -eq $assignment -or $assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
        $argumentList = & $getNamedArgument $start 'ArgumentList'
        if ($argumentList -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
        $arguments = & $findSoleAssignment $ast $argumentList.VariablePath.UserPath
        if ($null -eq $arguments -or $arguments.Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
            $arguments.Right.Expression -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { return $false }
        $resolvedArguments = & $resolveLaunchArguments $ast $arguments.Right.Expression $LibraryText
        if ($null -eq $resolvedArguments) { return $false }
        if (@($resolvedArguments | Where-Object { $_ -match '^--config-file(=|$)' }).Count -ne 0) { return $false }
        $effective = & $getEffectiveNotifications $resolvedArguments
        if ($effective.Desktop -or $effective.ClipboardCopy -or $effective.ConfigReload) { return $false }
        $processes[$assignment.Left.VariablePath.UserPath] = $true
    }
    if ($processes.Count -ne 2 -or -not $processes.ContainsKey('saveProbeProcess') -or -not $processes.ContainsKey('saveVerifyProcess')) { return $false }
    # Each save is made on a Settings window one of those processes opened.
    foreach ($required in @(
            '$saveProbe = Open-AccessibilitySettingsProbe -Process $saveProbeProcess -Description',
            '$saveVerifyProbe = Open-AccessibilitySettingsProbe -Process $saveVerifyProcess -Description',
            '$verifyScrollback = Get-AccessibilityScrollbackProbe -SettingsProbe $saveVerifyProbe -Description',
            '$verifyScrollback.Save.TryGetCurrentPattern(')) {
        if ([regex]::Matches($Text, [regex]::Escape($required)).Count -ne 1) { return $false }
    }
    if ([regex]::Matches($Text, $settingsSaves['a Settings Save invoke']).Count -ne 1 -or
        [regex]::Matches($Text, $settingsSaves['a Settings Save and close']).Count -ne 1 -or
        [regex]::Matches($Text, "Invoke-AccessibilitySettingsCloseAction\s*``\s*-SettingsProbe \`$saveProbe\s*``\s*-ActionName 'Save and close'").Count -ne 1) { return $false }
    $true
}
$accessibilityText = $jobFileTexts[$accessibilityLeaf]
$launchLibraryText = $jobFileTexts['scripts\interactive-win11-lib.ps1']
if (-not (& $testQuietSettingsSaves $accessibilityText $launchLibraryText)) {
    throw 'interactive-win11-accessibility.ps1 must save Settings only in its save probe and verifier processes, and noctty must start each with desktop-notifications and both app-notifications off, read from argument lists the check can resolve (no --config-file, no element with whitespace or a quote, each variable assigned once).'
}
$toastEol = if ($accessibilityText.Contains("`r`n")) { "`r`n" } else { "`n" }
$toastQuietLine = "        '--command=cmd.exe'`n        `$settingsSaveNotificationArguments`n"
$toastProbeArguments = "`"--class=`$saveProbeClass`"`n$toastQuietLine"
$toastVerifyArguments = "`"--class=`$saveVerifyClass`"`n$toastQuietLine"
$toastQuietValue = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=false')"
$toastProbeClass = "    `$saveProbeClass = "
$toastProbeStart = "    `$saveProbeProcess = Start-AccessibilityProcessWithEnvironment"
$toastContainmentReturn = "        '--windows-job-object-kill-on-close=true'`n    )"
foreach ($toastControl in @(
        @{ Name = 'the save probe without the flags'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--command=cmd.exe'`n"; Accept = $false },
        @{ Name = 'the verifier without the flags'; From = $toastVerifyArguments; To = "`"--class=`$saveVerifyClass`"`n        '--command=cmd.exe'`n"; Accept = $false },
        @{ Name = 'config-reload left on'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=no-clipboard-copy', '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'clipboard-copy left on'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=no-config-reload', '--desktop-notifications=false')"; Accept = $false },
        @{ Name = 'desktop notifications left on'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=true')"; Accept = $false },
        @{ Name = 'a later value in the flags themselves'; From = $toastQuietValue; To = "`$settingsSaveNotificationArguments = @('--app-notifications=false', '--desktop-notifications=false', '--app-notifications=no-clipboard-copy')"; Accept = $false },
        @{ Name = 'the flags emptied later'; From = $toastProbeClass; To = "    `$settingsSaveNotificationArguments = @()`n$toastProbeClass"; Accept = $false },
        @{ Name = 'the save probe arguments rewritten'; From = $toastProbeStart; To = "    `$saveProbeArguments += @()`n$toastProbeStart"; Accept = $false },
        @{ Name = 'app notifications turned back on after the flags'; From = $toastProbeArguments; To = "$toastProbeArguments        '--app-notifications=true'`n"; Accept = $false },
        @{ Name = 'a bare desktop flag after the flags'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--desktop-notifications'`n"; Accept = $false },
        @{ Name = 'desktop notifications as 1 after the flags'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--desktop-notifications=1'`n"; Accept = $false },
        @{ Name = 'an empty app value after the flags (Sol M1, round 2)'; From = $toastProbeArguments; To = "$toastProbeArguments        '--app-notifications='`n"; Accept = $false },
        @{ Name = 'an empty desktop value after the flags (Sol M1, round 2)'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--desktop-notifications='`n"; Accept = $false },
        @{ Name = 'empty values before the flags (the flags win)'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--app-notifications='`n        '--desktop-notifications='`n$toastQuietLine"; Accept = $true },
        @{ Name = 'a config-file include (Opus L1, round 2)'; From = $toastProbeArguments; To = "$toastProbeArguments        '--config-file=?C:\x\notify.conf'`n"; Accept = $false },
        @{ Name = 'a later option inside one element (Sol M2, round 2)'; From = $toastProbeArguments; To = "$toastProbeArguments        '--command=cmd.exe --app-notifications=true'`n"; Accept = $false },
        @{ Name = 'a later option inside a title element (Opus L2, round 2)'; From = $toastVerifyArguments; To = "$toastVerifyArguments        '--title=x --app-notifications=true'`n"; Accept = $false },
        @{ Name = 'a quote inside an element'; From = $toastProbeArguments; To = "$toastProbeArguments        '--title=`"x`"'`n"; Accept = $false },
        @{ Name = 'whitespace through an expanded class name'; From = "`$saveProbeClass = `"noctty-accessibility-settings-save-"; To = "`$saveProbeClass = `"noctty-accessibility settings-save-"; Accept = $false },
        @{ Name = 'the flags set again in script scope (Opus L2, round 2)'; From = $toastProbeClass; To = "    `$script:settingsSaveNotificationArguments = @('--app-notifications=true')`n$toastProbeClass"; Accept = $false },
        @{ Name = 'the flags set again by Set-Variable (Opus L2, round 2)'; From = $toastProbeClass; To = "    Set-Variable -Name settingsSaveNotificationArguments -Value @('--app-notifications=true')`n$toastProbeClass"; Accept = $false },
        @{ Name = 'an index write to the flags (Opus L2, round 2)'; From = $toastProbeClass; To = "    `$settingsSaveNotificationArguments[0] = '--app-notifications=true'`n$toastProbeClass"; Accept = $false },
        @{ Name = 'an index write to the arguments (Opus L2, round 2)'; From = $toastProbeStart; To = "    `$saveProbeArguments[-1] = '--desktop-notifications=true'`n$toastProbeStart"; Accept = $false },
        @{ Name = 'a scoped += to the arguments (Opus L2, round 2)'; From = $toastProbeStart; To = "    `$script:saveProbeArguments += '--app-notifications=true'`n$toastProbeStart"; Accept = $false },
        @{ Name = 'the class name set twice'; From = "    `$saveProbeArguments = @("; To = "    `$saveProbeClass = 'other'`n    `$saveProbeArguments = @("; Accept = $false },
        @{ Name = 'an argument that cannot be read'; From = $toastProbeArguments; To = "$toastProbeArguments        `$extraProbeArguments`n"; Accept = $false },
        @{ Name = 'an override in an expanded string'; From = $toastProbeArguments; To = "$toastProbeArguments        `"--app-notifications=`$probeNotifications`"`n"; Accept = $false },
        @{ Name = 'an override before the flags (the flags win)'; From = $toastProbeArguments; To = "`"--class=`$saveProbeClass`"`n        '--app-notifications=true'`n$toastQuietLine"; Accept = $true },
        @{ Name = 'a second Save invoke'; From = '    $restoreInvoke.Invoke()'; To = "    `$null = `$verifyTheme.Save.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]`$restoreInvoke)`n    `$restoreInvoke.Invoke()"; Accept = $false },
        @{ Name = 'Save and close on another probe'; From = "    Invoke-AccessibilitySettingsCloseAction ``$toastEol        -SettingsProbe `$saveProbe ``"; To = "    Invoke-AccessibilitySettingsCloseAction ``$toastEol        -SettingsProbe `$ownerProbe ``"; Accept = $false }
    )) {
    $toastFrom = $toastControl.From.Replace("`n", $toastEol).Replace("`r`r", "`r")
    $toastTo = $toastControl.To.Replace("`n", $toastEol).Replace("`r`r", "`r")
    if (([regex]::Matches($accessibilityText, [regex]::Escape($toastFrom))).Count -ne 1) {
        throw "Quiet Settings save control '$($toastControl.Name)' lost its anchor."
    }
    if ((& $testQuietSettingsSaves $accessibilityText.Replace($toastFrom, $toastTo) $launchLibraryText) -ne $toastControl.Accept) {
        throw "The quiet Settings save check $(if ($toastControl.Accept) { 'refused' } else { 'accepted' }) $($toastControl.Name)."
    }
}
# The shared containment arguments come first on both command lines, so an
# override there loses to the flags; a containment list the check cannot read
# refuses the launch, and so does one holding an element with whitespace.
$toastLibraryEol = if ($launchLibraryText.Contains("`r`n")) { "`r`n" } else { "`n" }
$toastContainmentFrom = $toastContainmentReturn.Replace("`n", $toastLibraryEol)
if (([regex]::Matches($launchLibraryText, [regex]::Escape($toastContainmentFrom))).Count -ne 1) { throw 'The containment-arguments control lost its anchor.' }
if (-not (& $testQuietSettingsSaves $accessibilityText $launchLibraryText.Replace($toastContainmentFrom, "        '--windows-job-object-kill-on-close=true'$toastLibraryEol        '--app-notifications=true'$toastLibraryEol    )"))) {
    throw 'The quiet Settings save check refused an override in the containment arguments, which come before the flags.'
}
if (& $testQuietSettingsSaves $accessibilityText $launchLibraryText.Replace($toastContainmentFrom, "        '--windows-job-object-kill-on-close=true'$toastLibraryEol        `$extraContainment$toastLibraryEol    )")) {
    throw 'The quiet Settings save check accepted containment arguments it cannot read.'
}
if (& $testQuietSettingsSaves $accessibilityText $launchLibraryText.Replace($toastContainmentFrom, "        '--windows-job-object-kill-on-close=true --app-notifications=true'$toastLibraryEol    )")) {
    throw 'The quiet Settings save check accepted a containment element that reaches noctty as two arguments.'
}
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
