# The hidden-desktop GUI suite's selection and boundaries (interactive offload PR 1; design v7 §4.3, §4.5). Pinned
# here, each rule with a control that must be refused (and, where a rule could over-reach, one that must pass):
#   (a) .github/workflows/gui-hidden.yml's shape: its triggers, no workflow-level `paths:` (PKG-65), contents: read,
#       test.yml's concurrency, the three jobs and their conditions, the helper self-test before the suite step, the
#       gate's verdict step and its arguments, the upload allowlist and its 90-day retention, and action pins
#       identical to test.yml's;
#   (b) the real-input module contract: in the closure of the runner and of every plan leaf, no file but
#       scripts/interactive-win11-realinput.ps1 declares a real-input or foreground entry point or the methods built
#       on them, a PowerShell member access to one outside the module goes through [InteractiveWin11RealInput] (or a
#       nested class of it) only, and the module keeps its tripwire;
#   (c) no plan leaf calls Show-StatefulHost;
#   (d) the plan's buildInputs name what the hosted build preparation reads through edges no walk shows;
#   (e) the plan and the flagship scenario agree;
#   (f) test/windows/gui-hidden-scripts.ps1, the walker's and the selection's fixtures, passes.
# Nothing here starts noctty or touches a desktop.
$guiHiddenProblems = & {
    $problems = [System.Collections.Generic.List[string]]::new()
    . (Join-Path $repoRoot 'scripts\ci-gui-selection.ps1') -LibraryOnly

    $planPath = Join-Path $repoRoot 'test\windows\gui-hidden-plan.json'
    $scenarioPath = Join-Path $repoRoot 'test\windows\flagship\scenarios\gui-hidden.json'
    $workflowPath = Join-Path $repoRoot '.github\workflows\gui-hidden.yml'
    $testWorkflowPath = Join-Path $repoRoot '.github\workflows\test.yml'
    $modulePath = 'scripts/interactive-win11-realinput.ps1'
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $leafEntries = @($plan.leaves | ForEach-Object { [string]$_.script })
    $entries = @('test/windows/gui-hidden-runner.ps1') + $leafEntries

    # ---- (a) the workflow -----------------------------------------------------------------------------------------
    function Get-GuiHiddenWorkflowProblems([string] $Text, [string] $TestText) {
        $found = [System.Collections.Generic.List[string]]::new()
        $need = {
            param([string] $Pattern, [string] $What)
            if ($Text -notmatch $Pattern) { $found.Add("gui-hidden.yml: $What") }
        }
        # A step of a job by name, or $null when the job holds it other than once (a mutation can drop it).
        $findStep = {
            param([string] $JobText, [string] $Name, [string] $Job)
            if ([regex]::Matches($JobText, '(?m)^      - name:[ \t]+' + [regex]::Escape($Name) + '[ \t]*\r?$').Count -ne 1) { return $null }
            return Get-YamlStepBlock -Content $JobText -Name $Name -Source "gui-hidden.yml :: $Job"
        }
        & $need '(?m)^on:\r?\n  push:\r?\n    branches: \[main\]\r?\n  pull_request: \{\}\r?\n  schedule:\r?\n    - cron: "[0-9 *]+"\r?\n  workflow_dispatch:\r?\n    inputs:\r?\n      soak_seconds:\r?\n' 'triggers on push to main, every pull request, a schedule and dispatch with soak_seconds'
        if ($Text -match '(?m)^\s*(?:paths|paths-ignore|branches-ignore)\s*:') { $found.Add('gui-hidden.yml: no paths, paths-ignore or branches-ignore filter (PKG-65: a skipped workflow leaves a required check pending)') }
        & $need '(?m)^permissions:\r?\n  contents: read\r?\n\r?\n' 'top-level permissions are contents: read alone'
        if ([regex]::Matches($Text, '(?m)^\s*[a-z-]+: write\s*$').Count -ne 0 -or [regex]::Matches($Text, '(?m)^\s*permissions:').Count -ne 1) { $found.Add('gui-hidden.yml: no other permissions block and no write permission') }
        $concurrency = '(?m)^concurrency:\r?\n  group: (?<group>.+)\r?\n  cancel-in-progress: (?<cancel>.+)\r?\n'
        $mine = [regex]::Match($Text, $concurrency)
        $theirs = [regex]::Match($TestText, $concurrency)
        if (-not $mine.Success -or -not $theirs.Success -or $mine.Groups['group'].Value -cne $theirs.Groups['group'].Value -or $mine.Groups['cancel'].Value -cne $theirs.Groups['cancel'].Value) {
            $found.Add('gui-hidden.yml: concurrency is test.yml''s (a push to main is never cancelled)')
        }
        $jobsAt = [regex]::Match($Text, '(?m)^jobs:\s*$')
        $jobsText = $(if ($jobsAt.Success) { $Text.Substring($jobsAt.Index) } else { '' })
        $jobNames = @([regex]::Matches($jobsText, '(?m)^  ([a-z][a-z0-9-]*):\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (($jobNames -join ',') -cne 'changes,suite,gui-hidden-gate') { $found.Add("gui-hidden.yml: exactly the jobs changes, suite and gui-hidden-gate (found $($jobNames -join ','))") ; return , $found.ToArray() }
        $changes = Get-YamlJobText -Content $Text -Name 'changes' -Source 'gui-hidden.yml'
        $suite = Get-YamlJobText -Content $Text -Name 'suite' -Source 'gui-hidden.yml'
        $gate = Get-YamlJobText -Content $Text -Name 'gui-hidden-gate' -Source 'gui-hidden.yml'
        $headRef = [regex]::Escape('ref: ${{ github.event_name == ''pull_request'' && github.event.pull_request.head.sha || github.sha }}')
        foreach ($job in @(@{ Name = 'changes'; Text = $changes }, @{ Name = 'suite'; Text = $suite }, @{ Name = 'gui-hidden-gate'; Text = $gate })) {
            if ($job.Text -notmatch "(?m)^          $headRef\s*$") { $found.Add("gui-hidden.yml: $($job.Name) checks out the explicit pull request head, as test.yml does") }
            if ($job.Text -notmatch '(?m)^          persist-credentials: false\s*$') { $found.Add("gui-hidden.yml: $($job.Name) checks out with persist-credentials: false") }
        }
        if ($changes -notmatch '(?m)^      gui: \$\{\{ steps\.filter\.outputs\.gui \}\}\s*$' -or $changes -notmatch '(?m)^          fetch-depth: 0\s*$') { $found.Add('gui-hidden.yml: changes outputs gui from the filter step and fetches the whole history') }
        if ($changes -match '(?m)^    (?:if|needs|continue-on-error):') { $found.Add('gui-hidden.yml: changes always runs, on its own') }
        $filter = Get-YamlStepBlock -Content $changes -Name 'Decide whether the change needs the GUI suite' -Source 'gui-hidden.yml :: changes'
        if ($filter -notmatch '(?m)^        id: filter\s*$' -or $filter -notmatch '(?m)^        run: \./scripts/ci-gui-selection\.ps1 -EventName \$env:EVENT_NAME -BaseSha \$env:BASE_SHA -HeadSha \$env:HEAD_SHA\s*$') { $found.Add('gui-hidden.yml: the filter step runs scripts/ci-gui-selection.ps1 with the event, base and head') }
        $tests = Get-YamlStepBlock -Content $changes -Name 'GUI selection tests (walker, selection)' -Source 'gui-hidden.yml :: changes'
        if ($tests -notmatch '(?m)^        run: \./test/windows/gui-hidden-scripts\.ps1\s*$' -or $tests -match '(?m)^        (?:if|continue-on-error):') { $found.Add('gui-hidden.yml: changes runs test/windows/gui-hidden-scripts.ps1 unconditionally') }
        # A failed changes job keeps the suite from starting, so changes publishes and uploads the error result itself,
        # after its tests, through the standalone publisher (Sol on #740: a runner that did not parse failed the walk,
        # and nothing was uploaded).
        # An upload step's `path: |` block scalar, its lines one pattern each: every line after it that is blank or
        # indented past `path:`, so a path after a blank separator is read too (CodeRabbit on #740: the old pattern
        # stopped at the first blank line). A folded `path: >` (one string) or none gives no paths. Both uploads.
        $uploadPaths = {
            param([string] $Step)
            $found = [System.Collections.Generic.List[string]]::new()
            if ($null -eq $Step) { return , $found.ToArray() }
            $stepLines = @($Step -split '\r?\n')
            $at = @(for ($i = 0; $i -lt $stepLines.Count; $i++) { if ($stepLines[$i] -match '\A          path: \|[+-]?\s*\z') { $i } })
            if ($at.Count -eq 1) {
                for ($i = $at[0] + 1; $i -lt $stepLines.Count; $i++) {
                    $line = $stepLines[$i]
                    if ($line.Trim().Length -eq 0) { continue }
                    if (-not $line.StartsWith('           ', [StringComparison]::Ordinal)) { break }
                    $found.Add($line.Trim())
                }
            }
            return , $found.ToArray()
        }
        # Both uploads list exactly these three patterns, one per line: the upload action reads one pattern a line, so a
        # line that holds all three joined by '|' matches nothing (CodeRabbit on #740: a '|' join accepted that line).
        $expectedUpload = @('${{ runner.temp }}/gui-hidden/result.json', '${{ runner.temp }}/gui-hidden/result.json.sha256', '${{ runner.temp }}/gui-hidden/receipts/**') -join "`n"
        $changesPublish = & $findStep $changes 'Publish an error result when the selection failed' 'changes'
        $changesUpload = & $findStep $changes 'Upload the selection''s error result' 'changes'
        $changesTestsAt = $changes.IndexOf('      - name: GUI selection tests (walker, selection)', [StringComparison]::Ordinal)
        $changesPublishAt = $changes.IndexOf('      - name: Publish an error result when the selection failed', [StringComparison]::Ordinal)
        $changesUploadAt = $changes.IndexOf('      - name: Upload the selection''s error result', [StringComparison]::Ordinal)
        if ($null -eq $changesPublish -or $changesPublish -notmatch '(?m)^        if: failure\(\)\s*$' -or $changesPublish -notmatch '(?m)^        shell: pwsh\s*$' -or
            $changesPublish -notmatch '(?m)^        run: pwsh -NoProfile -File test/windows/gui-hidden-publish-error\.ps1 -Kind gui-selection -Out \(Join-Path \$env:RUNNER_TEMP ''gui-hidden''\)\s*$' -or
            $null -eq $changesUpload -or $changesUpload -notmatch '(?m)^        if: failure\(\)\s*$' -or
            $changesUpload -notmatch '(?m)^          name: gui-hidden-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\s*$' -or
            ((& $uploadPaths $changesUpload) -join "`n") -cne $expectedUpload -or
            $changesUpload -notmatch '(?m)^          retention-days: 90\s*$' -or
            $changesPublish -match '(?m)^        continue-on-error:' -or $changesUpload -match '(?m)^        continue-on-error:' -or
            $changesTestsAt -lt 0 -or $changesPublishAt -lt $changesTestsAt -or $changesUploadAt -lt $changesPublishAt) {
            $found.Add('gui-hidden.yml: when changes fails, it publishes an error result through test/windows/gui-hidden-publish-error.ps1 and uploads only the result, its hash and the receipts, after its tests')
        }
        if ($suite -notmatch '(?m)^    name: Windows Server 2025 Hidden-Desktop GUI\s*$' -or $suite -notmatch '(?m)^    needs: changes\s*$' -or
            [regex]::Matches($suite, '(?m)^    if:').Count -ne 1 -or $suite -notmatch "(?m)^    if: needs\.changes\.outputs\.gui == 'true'\s*$" -or
            $suite -notmatch '(?m)^    runs-on: windows-2025\s*$' -or $suite -match '(?m)^    continue-on-error:') {
            $found.Add('gui-hidden.yml: suite is "Windows Server 2025 Hidden-Desktop GUI" on windows-2025, needs changes, and runs on the gui flag alone')
        }
        # The helper self-test (design v7 §3 row 0, §11; Sol and Opus on #740) runs in the suite job, before the suite
        # step, on every run of the job.
        $selfTest = & $findStep $suite 'Interactive harness helper self-test' 'suite'
        $selfTestAt = $suite.IndexOf('      - name: Interactive harness helper self-test', [StringComparison]::Ordinal)
        $runnerAt = $suite.IndexOf('      - name: Hidden-desktop GUI suite', [StringComparison]::Ordinal)
        if ($null -eq $selfTest -or $selfTest -notmatch '(?m)^        shell: pwsh\s*$' -or $selfTest -notmatch '(?m)^        id: selftest\s*$' -or
            $selfTest -notmatch '(?m)^        run: pwsh -NoProfile -NonInteractive -File test/windows/interactive-win11\.ps1\s*$' -or
            $selfTest -match '(?m)^        (?:if|continue-on-error):' -or $selfTestAt -lt 0 -or $runnerAt -lt 0 -or $selfTestAt -gt $runnerAt) {
            $found.Add('gui-hidden.yml: the suite job runs test/windows/interactive-win11.ps1 (the helper self-test) unconditionally, before the suite step')
        }
        # A failed self-test still leaves a record: the next step publishes an error result for it, between the suite
        # step and the upload (the lead on #740: the first hosted failure uploaded nothing).
        $publish = & $findStep $suite 'Publish an error result when the job failed without one' 'suite'
        $publishAt = $suite.IndexOf('      - name: Publish an error result when the job failed without one', [StringComparison]::Ordinal)
        $uploadAt = $suite.IndexOf('      - name: Upload the suite''s result and receipts', [StringComparison]::Ordinal)
        if ($null -eq $publish -or $publish -notmatch '(?m)^        if: failure\(\)\s*$' -or $publish -notmatch '(?m)^        shell: pwsh\s*$' -or
            $publish -notmatch '(?m)^          SELFTEST_OUTCOME: \$\{\{ steps\.selftest\.outcome \}\}\s*$' -or
            $publish -notmatch '(?m)^        run: pwsh -NoProfile -File test/windows/gui-hidden-publish-error\.ps1 -Kind \$\(if \(\$env:SELFTEST_OUTCOME -ceq ''failure''\) \{ ''helper-self-test'' \} else \{ ''suite-no-result'' \}\) -Out \(Join-Path \$env:RUNNER_TEMP ''gui-hidden''\)\s*$' -or
            $publish -match '(?m)^        continue-on-error:' -or $publishAt -lt $runnerAt -or $uploadAt -lt $publishAt) {
            $found.Add('gui-hidden.yml: after the suite step and before the upload, a job that failed without a complete result publishes one through test/windows/gui-hidden-publish-error.ps1, apart from the runner')
        }
        $run = Get-YamlStepBlock -Content $suite -Name 'Hidden-desktop GUI suite' -Source 'gui-hidden.yml :: suite'
        if ($run -notmatch '(?m)^        run: pwsh -NoProfile -File test/windows/gui-hidden-runner\.ps1 -MeasureRepo \$env:GITHUB_WORKSPACE -Work \(Join-Path \$env:RUNNER_TEMP ''gui-hidden-work''\) -Out \(Join-Path \$env:RUNNER_TEMP ''gui-hidden''\) -Build\s*$' -or
            $run -match '(?m)^        (?:if|continue-on-error):') { $found.Add('gui-hidden.yml: the suite step runs the runner with -Build into RUNNER_TEMP\gui-hidden, unconditionally') }
        $upload = Get-YamlStepBlock -Content $suite -Name 'Upload the suite''s result and receipts' -Source 'gui-hidden.yml :: suite'
        $paths = & $uploadPaths $upload
        if (($paths -join "`n") -cne $expectedUpload) { $found.Add('gui-hidden.yml: the upload holds exactly the result, its hash and the receipts (design §4.5 allowlist), no log directory') }
        if ($upload -notmatch '(?m)^        if: always\(\)\s*$' -or $upload -notmatch '(?m)^          name: gui-hidden-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\s*$' -or
            $upload -notmatch '(?m)^          if-no-files-found: warn\s*$') { $found.Add('gui-hidden.yml: the upload runs always, is named per run and attempt, and warns on no files') }
        if ([regex]::Matches($upload, '(?m)^          retention-days: 90\s*$').Count -ne 1 -or [regex]::Matches($Text, 'retention-days:').Count -ne 2 -or
            [regex]::Matches($Text, '(?m)^          retention-days: 90\s*$').Count -ne 2) { $found.Add('gui-hidden.yml: both uploads are kept 90 days (PLAN §8.1)') }
        # The gate's verdict is its named step, and that step runs whenever the job does (CodeRabbit on #740: a verdict
        # step limited to manual runs let a pull request's gate pass on checkout alone).
        $verdict = & $findStep $gate 'Every needed job succeeded and every skipped job was not needed' 'gui-hidden-gate'
        if ($gate -notmatch '(?m)^    name: gui-hidden-gate\s*$' -or $gate -notmatch '(?m)^    needs: \[changes, suite\]\s*$' -or
            $gate -notmatch '(?m)^    if: \$\{\{ always\(\) \}\}\s*$' -or $gate -match '(?m)^    continue-on-error:' -or $null -eq $verdict -or
            $verdict -notmatch '(?m)^        run: \./scripts/ci-gate\.ps1 -NeedsJson \$env:NEEDS_JSON -Expect changes:always,suite:gui\s*$' -or
            $verdict -notmatch '(?m)^          NEEDS_JSON: \$\{\{ toJSON\(needs\) \}\}\s*$' -or
            $verdict -match '(?m)^        (?:if|continue-on-error):') {
            $found.Add('gui-hidden.yml: gui-hidden-gate needs both jobs and runs under always(), and its verdict step runs scripts/ci-gate.ps1 -Expect changes:always,suite:gui with no step-level if or continue-on-error')
        }
        foreach ($use in [regex]::Matches($Text, '(?m)^\s*(?:-\s+)?uses:\s+(?<action>[^\s@]+)@(?<ref>[^\s#]+)')) {
            $pin = "uses: $($use.Groups['action'].Value)@$($use.Groups['ref'].Value)"
            if ($use.Groups['ref'].Value -cnotmatch '^[0-9a-f]{40}$' -or -not $TestText.Contains($pin)) { $found.Add("gui-hidden.yml: $pin is pinned to the same full commit SHA test.yml uses") }
        }
        return , $found.ToArray()
    }
    $workflowText = [IO.File]::ReadAllText($workflowPath)
    $testText = [IO.File]::ReadAllText($testWorkflowPath)
    foreach ($problem in (Get-GuiHiddenWorkflowProblems $workflowText $testText)) { $problems.Add($problem) }
    $workflowControls = @(
        @{ Name = 'a workflow-level paths filter'; Old = "  pull_request: {}`n"; New = "  pull_request:`n    paths: ['src/**']`n" }
        @{ Name = 'a log directory in the upload'; Old = "            `${{ runner.temp }}/gui-hidden/receipts/**`n"; New = "            `${{ runner.temp }}/gui-hidden/receipts/**`n            `${{ runner.temp }}/gui-hidden-work/**/logs/**`n" }
        @{ Name = 'the retention dropped'; Old = "          retention-days: 90`n"; New = '' }
        @{ Name = 'a shorter retention'; Old = 'retention-days: 90'; New = 'retention-days: 14' }
        @{ Name = 'the suite gated on more than its flag'; Old = "    if: needs.changes.outputs.gui == 'true'"; New = "    if: needs.changes.outputs.gui == 'true' && github.event_name != 'schedule'" }
        @{ Name = 'the gate under !cancelled()'; Old = '    if: ${{ always() }}'; New = '    if: ${{ !cancelled() }}' }
        @{ Name = 'the gate without the suite flag'; Old = '-Expect changes:always,suite:gui'; New = '-Expect changes:always' }
        @{ Name = 'a write permission'; Old = "permissions:`n  contents: read`n"; New = "permissions:`n  contents: read`n  actions: write`n" }
        @{ Name = 'a cancelled push to main'; Old = "  cancel-in-progress: true`n"; New = '  cancel-in-progress: ${{ github.ref_name != ''main'' }}' + "`n" }
        @{ Name = 'an unpinned action'; Old = 'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'; New = 'actions/upload-artifact@v7' }
        @{ Name = 'an extra upload path after a blank line'; Old = "            `${{ runner.temp }}/gui-hidden/receipts/**`n"; New = "            `${{ runner.temp }}/gui-hidden/receipts/**`n`n            `${{ runner.temp }}/gui-hidden-work/**`n" }
        @{ Name = 'the verdict step limited to manual runs'; Old = "      - name: Every needed job succeeded and every skipped job was not needed`n"; New = "      - name: Every needed job succeeded and every skipped job was not needed`n        if: github.event_name == 'workflow_dispatch'`n" }
        @{ Name = 'the verdict step allowed to fail'; Old = "      - name: Every needed job succeeded and every skipped job was not needed`n"; New = "      - name: Every needed job succeeded and every skipped job was not needed`n        continue-on-error: true`n" }
        @{ Name = 'the helper self-test dropped'; Old = "      - name: Interactive harness helper self-test`n        id: selftest`n        shell: pwsh`n        run: pwsh -NoProfile -NonInteractive -File test/windows/interactive-win11.ps1`n"; New = '' }
        @{ Name = 'the helper self-test limited to pushes'; Old = "      - name: Interactive harness helper self-test`n"; New = "      - name: Interactive harness helper self-test`n        if: github.event_name == 'push'`n" }
        @{ Name = 'the helper self-test allowed to fail'; Old = "      - name: Interactive harness helper self-test`n"; New = "      - name: Interactive harness helper self-test`n        continue-on-error: true`n" }
        @{ Name = 'the self-test without the id the error step reads'; Old = "        id: selftest`n"; New = '' }
        @{ Name = 'no error result for a job that failed without one'; Old = "      - name: Publish an error result when the job failed without one`n"; New = "      - name: Publish nothing`n" }
        @{ Name = 'the error result published on every run'; Old = "      - name: Publish an error result when the job failed without one`n        if: failure()`n"; New = "      - name: Publish an error result when the job failed without one`n        if: always()`n" }
        @{ Name = 'the error result published only for a failed self-test (a suite that died without a result left none)'; Old = "      - name: Publish an error result when the job failed without one`n        if: failure()`n"; New = "      - name: Publish an error result when the job failed without one`n        if: failure() && steps.selftest.outcome == 'failure'`n" }
        @{ Name = 'the error result published from cmd, which does not run its Join-Path'; Old = "      - name: Publish an error result when the job failed without one`n        if: failure()`n        shell: pwsh`n"; New = "      - name: Publish an error result when the job failed without one`n        if: failure()`n        shell: cmd`n" }
        @{ Name = 'the error result published through the runner, which a runner that does not parse cannot do'; Old = 'run: pwsh -NoProfile -File test/windows/gui-hidden-publish-error.ps1 -Kind '; New = 'run: pwsh -NoProfile -File test/windows/gui-hidden-runner.ps1 -PublishError ' }
        @{ Name = 'the result''s hash left out of the suite''s upload'; Old = "            `${{ runner.temp }}/gui-hidden/result.json.sha256`n            `${{ runner.temp }}/gui-hidden/receipts/**`n          # Kept 90 days"; New = "            `${{ runner.temp }}/gui-hidden/receipts/**`n          # Kept 90 days" }
        @{ Name = 'the result''s hash left out of the selection''s upload'; Old = "            `${{ runner.temp }}/gui-hidden/result.json.sha256`n            `${{ runner.temp }}/gui-hidden/receipts/**`n          retention-days: 90`n          if-no-files-found: warn`n`n  suite:"; New = "            `${{ runner.temp }}/gui-hidden/receipts/**`n          retention-days: 90`n          if-no-files-found: warn`n`n  suite:" }
        @{ Name = 'the selection''s upload paths folded into one string'; Old = "      - name: Upload the selection's error result`n        if: failure()`n        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2`n        with:`n          name: gui-hidden-`${{ github.run_id }}-`${{ github.run_attempt }}`n          path: |`n"; New = "      - name: Upload the selection's error result`n        if: failure()`n        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2`n        with:`n          name: gui-hidden-`${{ github.run_id }}-`${{ github.run_attempt }}`n          path: >`n" }
        @{ Name = 'the suite''s upload paths on one line joined by |'; Old = "            `${{ runner.temp }}/gui-hidden/result.json`n            `${{ runner.temp }}/gui-hidden/result.json.sha256`n            `${{ runner.temp }}/gui-hidden/receipts/**`n          # Kept 90 days"; New = "            `${{ runner.temp }}/gui-hidden/result.json|`${{ runner.temp }}/gui-hidden/result.json.sha256|`${{ runner.temp }}/gui-hidden/receipts/**`n          # Kept 90 days" }
        @{ Name = 'the selection''s upload paths on one line joined by |'; Old = "            `${{ runner.temp }}/gui-hidden/result.json`n            `${{ runner.temp }}/gui-hidden/result.json.sha256`n            `${{ runner.temp }}/gui-hidden/receipts/**`n          retention-days: 90`n          if-no-files-found: warn`n`n  suite:"; New = "            `${{ runner.temp }}/gui-hidden/result.json|`${{ runner.temp }}/gui-hidden/result.json.sha256|`${{ runner.temp }}/gui-hidden/receipts/**`n          retention-days: 90`n          if-no-files-found: warn`n`n  suite:" }
        @{ Name = 'no error result when the selection failed'; Old = "      - name: Publish an error result when the selection failed`n"; New = "      - name: Publish nothing when the selection failed`n" }
        @{ Name = 'the selection''s error result published through the runner'; Old = 'run: pwsh -NoProfile -File test/windows/gui-hidden-publish-error.ps1 -Kind gui-selection'; New = 'run: pwsh -NoProfile -File test/windows/gui-hidden-runner.ps1 -PublishError gui-selection' }
        @{ Name = 'the selection''s upload run on every run'; Old = "      - name: Upload the selection's error result`n        if: failure()`n"; New = "      - name: Upload the selection's error result`n        if: always()`n" }
        @{ Name = 'a log directory in the selection''s upload'; Old = "            `${{ runner.temp }}/gui-hidden/receipts/**`n          retention-days: 90`n          if-no-files-found: warn`n`n  suite:"; New = "            `${{ runner.temp }}/gui-hidden/receipts/**`n            `${{ runner.temp }}/gui-hidden-work/**`n          retention-days: 90`n          if-no-files-found: warn`n`n  suite:" }
    )
    $lfWorkflow = $workflowText.Replace("`r`n", "`n")
    # A validator returns its problems as one array object (`return , $found.ToArray()`), so a mutation's count is
    # read from the assigned result: `@(<call>).Count` is 1 for an empty result (measured, pwsh 7.6.10; CodeRabbit on
    # #740), and a control counted that way could never report an accepted mutation.
    foreach ($control in $workflowControls) {
        if (-not $lfWorkflow.Contains($control.Old)) { $problems.Add("gui-hidden.yml workflow control '$($control.Name)' lost its anchor."); continue }
        $mutated = $lfWorkflow.Replace($control.Old, $control.New)
        $controlProblems = Get-GuiHiddenWorkflowProblems $mutated $testText
        if ($controlProblems.Count -eq 0) { $problems.Add("The gui-hidden.yml shape check accepted $($control.Name).") }
    }

    # ---- (b) the real-input module contract -----------------------------------------------------------------------
    $bannedEntryPoints = @('SendInput', 'keybd_event', 'mouse_event', 'SetForegroundWindow', 'BringWindowToTop', 'SetActiveWindow', 'SwitchToThisWindow', 'SetCursorPos')
    $bannedMembers = $bannedEntryPoints + @('ForceForeground', 'SubmitInputs')
    $entryAlternation = ($bannedEntryPoints | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # C# text without its comments; string and character literals are kept, so a "//" inside one stays.
    function Remove-GuiHiddenCSharpComments([string] $Text) {
        $builder = [Text.StringBuilder]::new($Text.Length)
        $i = 0
        $n = $Text.Length
        while ($i -lt $n) {
            $c = $Text[$i]
            $next = $(if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 })
            if ($c -eq [char]'/' -and $next -eq [char]'/') { while ($i -lt $n -and $Text[$i] -ne [char]"`n") { $i++ }; continue }
            if ($c -eq [char]'/' -and $next -eq [char]'*') {
                $end = $Text.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
                $i = $(if ($end -lt 0) { $n } else { $end + 2 })
                [void]$builder.Append(' ')
                continue
            }
            if ($c -eq [char]'@' -and $next -eq [char]'"') {
                $j = $i + 2
                while ($j -lt $n) {
                    if ($Text[$j] -eq [char]'"') { if ($j + 1 -lt $n -and $Text[$j + 1] -eq [char]'"') { $j += 2; continue }; break }
                    $j++
                }
                [void]$builder.Append($Text, $i, [Math]::Min($n, $j + 1) - $i); $i = $j + 1; continue
            }
            if ($c -eq [char]'"' -or $c -eq [char]"'") {
                $j = $i + 1
                while ($j -lt $n -and $Text[$j] -ne $c -and $Text[$j] -ne [char]"`n") { if ($Text[$j] -eq [char]'\') { $j++ }; $j++ }
                [void]$builder.Append($Text, $i, [Math]::Min($n, $j + 1) - $i); $i = $j + 1; continue
            }
            [void]$builder.Append($c)
            $i++
        }
        return $builder.ToString()
    }

    # The C# sources of a parsed PowerShell file: strings passed to Add-Type (directly, or through a variable assigned
    # from a literal) and any string that holds DllImport or extern.
    function Get-GuiHiddenCSharpSources($Ast) {
        $sources = [System.Collections.Generic.Dictionary[int, string]]::new()
        $add = { param($node) if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $sources[$node.Extent.StartOffset] = $node.Value } }
        foreach ($command in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $name = $command.CommandElements[0]
            if ($name -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $name.Value -ine 'Add-Type') { continue }
            for ($i = 1; $i -lt $command.CommandElements.Count; $i++) {
                $element = $command.CommandElements[$i]
                $argument = $element
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($element.ParameterName -notin @('TypeDefinition', 'MemberDefinition')) { continue }
                    $argument = $(if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $command.CommandElements.Count) { $i++; $command.CommandElements[$i] })
                }
                if ($argument -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $variable = $argument.VariablePath.UserPath
                    foreach ($assignment in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ieq $variable }, $true))) {
                        foreach ($literal in @($assignment.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) { & $add $literal }
                    }
                } else { & $add $argument }
            }
        }
        foreach ($literal in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))) {
            if ($literal.Value -cmatch 'DllImport|\bextern\b') { & $add $literal }
        }
        return @($sources.Values)
    }

    # What a C# text declares that only the module may: a banned entry point (by extern name or EntryPoint), a method
    # named ForceForeground or SubmitInputs, or a class or struct named InteractiveWin11RealInput.
    function Get-GuiHiddenCSharpDeclarations([string] $Text) {
        $code = Remove-GuiHiddenCSharpComments $Text
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($match in [regex]::Matches($code, "(?s)\bextern\b[^;{}]*?\b(?<name>$entryAlternation)\s*\(")) { $found.Add("extern $($match.Groups['name'].Value)") }
        foreach ($match in [regex]::Matches($code, "EntryPoint\s*=\s*""(?<name>$entryAlternation)""")) { $found.Add("EntryPoint $($match.Groups['name'].Value)") }
        foreach ($match in [regex]::Matches($code, '(?m)\b(?:public|private|internal|protected|static)\b[^;{}()=]*\b(?<name>ForceForeground|SubmitInputs)\s*\(')) { $found.Add("method $($match.Groups['name'].Value)") }
        foreach ($match in [regex]::Matches($code, '\b(?:class|struct)\s+InteractiveWin11RealInput\b')) { $found.Add('class InteractiveWin11RealInput') }
        return , $found.ToArray()
    }

    # The module contract over a tree: the closure of $Entries, read through $Reader. Returns its problems, the walk's
    # own first: a helper it could not resolve or find was never scanned, whatever the members say (CodeRabbit on #740).
    function Get-GuiHiddenModuleProblems {
        param([string[]] $Entries, [scriptblock] $Reader, [string] $Module, [string] $Root = $repoRoot, [switch] $RequireModuleInClosure)
        $found = [System.Collections.Generic.List[string]]::new()
        $closure = Get-ScriptClosure -RepoRoot $Root -Entries $Entries -Reader $Reader
        foreach ($problem in $closure.Problems) { $found.Add("the closure walk: $problem") }
        $members = @($closure.Members)
        foreach ($path in $members) {
            $text = & $Reader $path
            if ($null -eq $text) { continue }
            $isModule = [string]::Equals($path, $Module, [StringComparison]::Ordinal)
            $kind = [IO.Path]::GetExtension($path).ToLowerInvariant()
            if ($kind -eq '.cs') {
                if (-not $isModule) { foreach ($declaration in (Get-GuiHiddenCSharpDeclarations $text)) { $found.Add("${path}: declares $declaration outside the real-input module") } }
                continue
            }
            if ($kind -notin @('.ps1', '.psm1')) { continue }
            $code = Remove-PowerShellComments $text
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors)
            $declarations = [System.Collections.Generic.List[string]]::new()
            foreach ($source in (Get-GuiHiddenCSharpSources $ast)) {
                foreach ($declaration in (Get-GuiHiddenCSharpDeclarations $source)) { $declarations.Add($declaration) }
            }
            if (-not $isModule) {
                foreach ($declaration in $declarations) { $found.Add("${path}: declares $declaration outside the real-input module") }
                foreach ($member in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
                    if ($member.Member.Value -notin $bannedMembers) { continue }
                    $receiver = $member.Expression
                    $allowed = $member.Static -and $receiver -is [System.Management.Automation.Language.TypeExpressionAst] -and
                        $receiver.TypeName.FullName -imatch '\AInteractiveWin11RealInput(?:\+[A-Za-z][A-Za-z0-9]*)?\z'
                    if (-not $allowed) { $found.Add("${path}: $($member.Extent.Text) reaches $($member.Member.Value) other than through [InteractiveWin11RealInput]") }
                }
            } else {
                $classes = @($declarations | Where-Object { $_ -ceq 'class InteractiveWin11RealInput' })
                if ($classes.Count -ne 1) { $found.Add("${path}: the module declares exactly one InteractiveWin11RealInput class (found $($classes.Count))") }
                $first = @($ast.EndBlock.Statements)[0]
                $tripwire = $first -is [System.Management.Automation.Language.IfStatementAst] -and $first.Clauses.Count -eq 1 -and $null -eq $first.ElseClause -and
                    $first.Clauses[0].Item1.Extent.Text -ceq '$env:NOCTTY_GUI_HIDDEN_DESKTOP' -and
                    @($first.Clauses[0].Item2.Statements).Count -eq 1 -and @($first.Clauses[0].Item2.Statements)[0] -is [System.Management.Automation.Language.ThrowStatementAst]
                if (-not $tripwire) { $found.Add("${path}: the module's first statement throws when NOCTTY_GUI_HIDDEN_DESKTOP is set (its tripwire)") }
                if (@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count -ne 0) { $found.Add("${path}: the module defines no PowerShell function") }
            }
        }
        if ($RequireModuleInClosure -and $members -cnotcontains $Module) { $found.Add("$Module is not in the hosted closure: window-lib's loader line must reach it") }
        return , $found.ToArray()
    }

    $workingReader = New-CiScriptFileReader -RepoRoot $repoRoot
    if ($null -eq (& $workingReader $modulePath)) { $problems.Add("$modulePath does not exist.") }
    foreach ($problem in (Get-GuiHiddenModuleProblems -Entries $entries -Reader $workingReader -Module $modulePath -RequireModuleInClosure)) { $problems.Add("Module contract: $problem") }

    # Controls on a synthetic tree: a valid one passes; each mutation must be refused, and the three that only touch
    # comments or prose must pass.
    $fixtureModule = @'
if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw 'The real-input module never loads in hosted mode.' }
if (-not ('InteractiveWin11RealInput' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class __REALINPUT_FIXTURE__ {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint SendInput(uint c, IntPtr i, int s);
    public static bool ForceForeground(IntPtr h, bool a, bool b) { return SetForegroundWindow(h); }
}
"@
}
'@
    # The class name goes in by substitution, so Contracts.30's shadow scan, which reads every script's text, never
    # takes this fixture for a second definition of the module's type.
    $fixtureModule = $fixtureModule.Replace('__REALINPUT_FIXTURE__', 'InteractiveWin11RealInput')
    $fixtureLib = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class FixtureWindowNative {
    // SetForegroundWindow lives in the module now.
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) { [FixtureDesktop]::Assert($env:NOCTTY_GUI_HIDDEN_DESKTOP) } else { . (Join-Path $PSScriptRoot 'interactive-win11-realinput.ps1') }
'@
    $fixtureLeaf = @'
. (Join-Path $PSScriptRoot '..\..\scripts\fixture-lib.ps1')
# A comment may name SetForegroundWindow.
[void][InteractiveWin11RealInput]::ForceForeground($h, $true, $true)
if (-not $ok) { throw 'SendInput failed for the fixture' }
'@
    $baseFiles = @{
        'scripts/interactive-win11-realinput.ps1' = $fixtureModule
        'scripts/fixture-lib.ps1' = $fixtureLib
        'test/windows/fixture-leaf.ps1' = $fixtureLeaf
    }
    $runFixture = {
        param([hashtable] $Files)
        $tableReader = { param([string] $RepoPath) if ($Files.ContainsKey($RepoPath)) { return $Files[$RepoPath] } return $null }.GetNewClosure()
        return @(Get-GuiHiddenModuleProblems -Entries @('test/windows/fixture-leaf.ps1') -Reader $tableReader -Module 'scripts/interactive-win11-realinput.ps1' -Root 'C:\gui-hidden-fixture' -RequireModuleInClosure)
    }
    $baseProblems = & $runFixture $baseFiles
    if ($baseProblems.Count -ne 0) { $problems.Add("The module contract refused its valid fixture: $($baseProblems -join '; ')") }
    $moduleControls = @(
        @{ Name = 'a stray declaration in a leaf''s Add-Type string'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '# A comment'; New = "Add-Type -MemberDefinition '[DllImport(""user32.dll"")] public static extern bool SetForegroundWindow(System.IntPtr h);' -Name Stray -Namespace Fixture`n# A comment" }
        @{ Name = 'an EntryPoint alias'; Refuse = $true; File = 'scripts/fixture-lib.ps1'; Old = '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'; New = '[DllImport("user32.dll", EntryPoint = "SetForegroundWindow")] public static extern bool Front(IntPtr h);' }
        @{ Name = 'a member access on another type'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '[InteractiveWin11RealInput]::ForceForeground'; New = '[FixtureWindowNative]::SetForegroundWindow' }
        @{ Name = 'a member access through a variable'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '[void][InteractiveWin11RealInput]::ForceForeground($h, $true, $true)'; New = '$t = [InteractiveWin11RealInput]; [void]$t::ForceForeground($h, $true, $true)' }
        @{ Name = 'a child script holding a declaration'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '# A comment'; New = "& (Join-Path `$PSScriptRoot 'fixture-child.ps1')`n# A comment"; Extra = @{ 'test/windows/fixture-child.ps1' = "Add-Type '[DllImport(""user32.dll"")] public static extern uint SendInput(uint c, System.IntPtr i, int s);' -Name Child -Namespace Fixture" } }
        @{ Name = 'a -File child script holding a declaration'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '# A comment'; New = "pwsh -NoProfile -File (Join-Path `$PSScriptRoot 'fixture-child.ps1')`n# A comment"; Extra = @{ 'test/windows/fixture-child.ps1' = "Add-Type '[DllImport(""user32.dll"")] public static extern uint SendInput(uint c, System.IntPtr i, int s);' -Name Child -Namespace Fixture" } }
        @{ Name = 'a second class named InteractiveWin11RealInput'; Refuse = $true; File = 'scripts/fixture-lib.ps1'; Old = 'public static class FixtureWindowNative {'; New = 'public static class InteractiveWin11RealInput { }' + "`n" + 'public static class FixtureWindowNative {' }
        @{ Name = 'the module''s tripwire removed'; Refuse = $true; File = 'scripts/interactive-win11-realinput.ps1'; Old = "if (`$env:NOCTTY_GUI_HIDDEN_DESKTOP) { throw 'The real-input module never loads in hosted mode.' }`n"; New = '' }
        @{ Name = 'a method named SubmitInputs outside the module'; Refuse = $true; File = 'scripts/fixture-lib.ps1'; Old = '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'; New = '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); public static bool SubmitInputs(int n) { return n > 0; }' }
        @{ Name = 'the module off the loader line'; Refuse = $true; File = 'scripts/fixture-lib.ps1'; Old = " else { . (Join-Path `$PSScriptRoot 'interactive-win11-realinput.ps1') }"; New = '' }
        # A closure the walk could not finish is no evidence: the module is still in it, but a missing or unresolved
        # helper was never scanned (CodeRabbit on #740).
        @{ Name = 'a leaf that loads a helper that does not exist'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '# A comment'; New = ". (Join-Path `$PSScriptRoot 'fixture-missing.ps1')`n# A comment" }
        @{ Name = 'a leaf that loads a script the walker cannot resolve'; Refuse = $true; File = 'test/windows/fixture-leaf.ps1'; Old = '# A comment'; New = ". `$helperPath`n# A comment" }
        @{ Name = 'a banned name in a PowerShell comment'; Refuse = $false; File = 'test/windows/fixture-leaf.ps1'; Old = '# A comment may name SetForegroundWindow.'; New = '# A comment may name [FixtureWindowNative]::SetForegroundWindow($h) and SendInput.' }
        @{ Name = 'a banned name in a C# comment'; Refuse = $false; File = 'scripts/fixture-lib.ps1'; Old = '// SetForegroundWindow lives in the module now.'; New = '// [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h); /* SendInput( */' }
        @{ Name = 'a banned name in a message string'; Refuse = $false; File = 'test/windows/fixture-leaf.ps1'; Old = "throw 'SendInput failed for the fixture'"; New = "throw 'SendInput failed, then SetForegroundWindow(h) and keybd_event did too'" }
    )
    foreach ($control in $moduleControls) {
        $files = @{}
        foreach ($key in $baseFiles.Keys) { $files[$key] = $baseFiles[$key].Replace("`r`n", "`n") }
        if (-not $files[$control.File].Contains($control.Old)) { $problems.Add("Module contract control '$($control.Name)' lost its anchor."); continue }
        $files[$control.File] = $files[$control.File].Replace($control.Old, $control.New)
        if ($control.Extra) { foreach ($key in $control.Extra.Keys) { $files[$key] = $control.Extra[$key] } }
        $controlProblems = & $runFixture $files
        if ($control.Refuse -and $controlProblems.Count -eq 0) { $problems.Add("The module contract accepted $($control.Name).") }
        if (-not $control.Refuse -and $controlProblems.Count -ne 0) { $problems.Add("The module contract refused $($control.Name): $($controlProblems -join '; ')") }
    }

    # ---- (c) no plan leaf calls Show-StatefulHost -----------------------------------------------------------------
    function Get-GuiHiddenStatefulHostCalls([string] $Text) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput((Remove-PowerShellComments $Text), [ref]$tokens, [ref]$errors)
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ieq 'Show-StatefulHost' }, $true)).Count
    }
    foreach ($leaf in $leafEntries) {
        $text = & $workingReader $leaf
        if ($null -ne $text -and (Get-GuiHiddenStatefulHostCalls $text) -ne 0) { $problems.Add("$leaf calls Show-StatefulHost, which takes the foreground; no hosted leaf may call it.") }
    }
    if ((Get-GuiHiddenStatefulHostCalls "Show-StatefulHost `$hostHwnd`n# Show-StatefulHost in a comment") -ne 1 -or (Get-GuiHiddenStatefulHostCalls '# Show-StatefulHost $h') -ne 0) {
        $problems.Add('The Show-StatefulHost check must count a call and ignore a comment.')
    }

    # ---- (d) build inputs, (e) the plan and the scenario ----------------------------------------------------------
    $script:GuiHiddenTrackedPaths = [System.Collections.Generic.HashSet[string]]::new([string[]]@(git -C $repoRoot ls-files), [StringComparer]::Ordinal)
    if ($script:GuiHiddenTrackedPaths.Count -eq 0) { throw 'git ls-files listed nothing; the build-input check needs the tracked paths.' }
    # Every directory that holds a tracked file, spelled as Git tracks it: what a `<dir>/**` build input may name.
    $script:GuiHiddenTrackedDirectories = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($trackedPath in $script:GuiHiddenTrackedPaths) {
        for ($cut = $trackedPath.LastIndexOf('/'); $cut -gt 0; $cut = $trackedPath.LastIndexOf('/', $cut - 1)) {
            if (-not $script:GuiHiddenTrackedDirectories.Add($trackedPath.Substring(0, $cut))) { break }
        }
    }
    function Get-GuiHiddenPlanProblems($Plan, $Scenario) {
        $found = [System.Collections.Generic.List[string]]::new()
        if ($Plan.schemaVersion -ne 1 -or $Plan.scenario -cne 'windows.gui-hidden.suite' -or $Scenario.id -cne 'windows.gui-hidden.suite') { $found.Add('the plan is version 1 and names the scenario windows.gui-hidden.suite, which the flagship scenario is') }
        # What the build preparation runs, and the measurement build's whole input set by tree (Sol on #740, round 12).
        foreach ($required in @('scripts/dev-windows.cmd', 'scripts/interactive-win11-measure-lib.ps1', 'build.zig', 'build.zig.zon', 'src/**', 'pkg/**', 'vendor/**', 'include/**', 'dist/windows/**', 'scripts/stage-conpty-redist.ps1', 'scripts/conpty-redist.ps1', 'scripts/windows-architecture.ps1')) {
            if (@($Plan.buildInputs) -cnotcontains $required) { $found.Add("the plan's buildInputs name $required, which the hosted build preparation reads") }
        }
        foreach ($buildInput in @($Plan.buildInputs)) {
            # A `<dir>/**` entry names every file under a tracked directory; the rules below apply to <dir>.
            $tree = ([string]$buildInput).EndsWith('/**', [StringComparison]::Ordinal)
            $path = $(if ($tree) { ([string]$buildInput).Substring(0, ([string]$buildInput).Length - 3) } else { [string]$buildInput })
            # A canonical repo path (slashes, no `.` or `..` segment, no leading separator), the spelling the changed-path
            # list uses, so the selection's ordinal lookup cannot miss it (CodeRabbit on #740).
            if ($path -cnotmatch '\A(?!\.{1,2}/)[A-Za-z0-9_-][A-Za-z0-9_.-]*(/(?!\.{1,2}(/|\z))[A-Za-z0-9_.-]+)*\z') { $found.Add("build input $buildInput is a canonical repo path") }
            # Spelled as Git tracks it, ordinally: a case-only variant exists on a case-insensitive checkout but misses the
            # changed-path list's ordinal lookup (CodeRabbit on #740).
            elseif ($tree -and -not $script:GuiHiddenTrackedDirectories.Contains($path)) { $found.Add("build input $buildInput names a tracked directory, spelled as Git tracks it") }
            elseif (-not $tree -and -not $script:GuiHiddenTrackedPaths.Contains($path)) { $found.Add("build input $buildInput is a tracked path, spelled as Git tracks it") }
        }
        $ids = @($Plan.leaves | ForEach-Object { [string]$_.id })
        if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { $found.Add('the plan''s leaf ids are unique') }
        $steps = @($Scenario.steps | ForEach-Object { [string]$_.id })
        if (($ids -join ',') -cne ($steps -join ',')) { $found.Add("the plan's leaf ids ($($ids -join ',')) are the flagship scenario's step ids ($($steps -join ',')), in order") }
        foreach ($leaf in @($Plan.leaves)) {
            if ([string]$leaf.script -cnotmatch '\Atest/windows/[A-Za-z0-9-]+\.ps1\z' -or -not (Test-Path -LiteralPath (Join-Path $repoRoot ([string]$leaf.script).Replace('/', '\')) -PathType Leaf)) { $found.Add("leaf $($leaf.id): its script is an existing test/windows/*.ps1") }
            if ($leaf.expectedShells -isnot [long] -and $leaf.expectedShells -isnot [int] -or $leaf.expectedShells -lt 0) { $found.Add("leaf $($leaf.id): expectedShells is a whole number") }
            if ($leaf.timeoutSeconds -isnot [long] -and $leaf.timeoutSeconds -isnot [int] -or $leaf.timeoutSeconds -le 0) { $found.Add("leaf $($leaf.id): timeoutSeconds is positive") }
            if (@($leaf.arguments | Where-Object { $_ -isnot [string] }).Count -ne 0) { $found.Add("leaf $($leaf.id): arguments are strings") }
        }
        return , $found.ToArray()
    }
    $scenario = Get-Content -LiteralPath $scenarioPath -Raw | ConvertFrom-Json
    foreach ($problem in (Get-GuiHiddenPlanProblems $plan $scenario)) { $problems.Add("gui-hidden-plan.json: $problem") }
    $planText = Get-Content -LiteralPath $planPath -Raw
    $planControls = @(
        @{ Name = 'a duplicate leaf id'; Change = { param($p) $p.leaves[1].id = $p.leaves[0].id } }
        @{ Name = 'a leaf the scenario does not list'; Change = { param($p) $p.leaves[0].id = 'not-in-the-scenario' } }
        @{ Name = 'buildInputs without dev-windows.cmd'; Change = { param($p) $p.buildInputs = @($p.buildInputs | Where-Object { $_ -cne 'scripts/dev-windows.cmd' }) } }
        @{ Name = 'a missing leaf script'; Change = { param($p) $p.leaves[0].script = 'test/windows/no-such-leaf.ps1' } }
        @{ Name = 'a build input spelled with ./'; Change = { param($p) $p.buildInputs = @($p.buildInputs) + @('./scripts/dev-windows.cmd') } }
        @{ Name = 'a build input spelled with a backslash'; Change = { param($p) $p.buildInputs = @($p.buildInputs) + @('scripts\dev-windows.cmd') } }
        @{ Name = 'a build input differing from the tracked path in case only'; Change = { param($p) $p.buildInputs = @($p.buildInputs) + @('scripts/Dev-windows.cmd') } }
        @{ Name = 'buildInputs without src/**'; Change = { param($p) $p.buildInputs = @($p.buildInputs | Where-Object { $_ -cne 'src/**' }) } }
        @{ Name = 'a build tree differing from the tracked directory in case only'; Change = { param($p) $p.buildInputs = @($p.buildInputs) + @('Src/**') } }
        @{ Name = 'a build tree that is no tracked directory'; Change = { param($p) $p.buildInputs = @($p.buildInputs) + @('no-such-dir/**') } }
        @{ Name = 'a build tree spelled with one star'; Change = { param($p) $p.buildInputs = @($p.buildInputs) + @('src/*') } }
    )
    foreach ($control in $planControls) {
        $mutated = $planText | ConvertFrom-Json
        & $control.Change $mutated
        # Assigned, never wrapped in @(): see the workflow controls.
        $controlProblems = Get-GuiHiddenPlanProblems $mutated $scenario
        if ($controlProblems.Count -eq 0) { $problems.Add("The plan check accepted $($control.Name).") }
    }

    # ---- (f) the walker's and the selection's fixtures ------------------------------------------------------------
    try { & (Join-Path $repoRoot 'test\windows\gui-hidden-scripts.ps1') | Out-Null }
    catch { $problems.Add("test/windows/gui-hidden-scripts.ps1 failed: $($_.Exception.Message)") }

    return , $problems.ToArray()
}
foreach ($problem in @($guiHiddenProblems)) {
    Add-ContractFailure -Description $problem -SourceFragment $script:CurrentContractFragment
}
