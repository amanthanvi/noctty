#requires -Version 5.1
<#
.SYNOPSIS
Decides which CI jobs a pull request needs, from the files it changes.

.DESCRIPTION
The `changes` job in test.yml and windows-arm64.yml runs this and the compiled
jobs read its outputs in a job-level `if:`. A job skipped that way reports
success, so a required check never stays pending the way it does when a whole
workflow is skipped by `paths:` (GitHub, "Troubleshooting required status
checks"). The `checks` job (contracts, shell integration, site and release copy)
has no switch and runs for every change.

The table below is an allowlist of files that the compiled jobs never read. A
file it does not name runs everything, so a new directory costs minutes until
someone classifies it and never costs a missed test. Push, schedule and manual
runs always run everything. Any failure to read the diff does the same.

What the compiled jobs read (verified against the sources; the guards in
test/windows/ci-scripts.ps1 re-check it on every change):
- Zig tests, bench, exe builds and lib-vt: src/, pkg/, include/, vendor/,
  build.zig(.zon), dist/windows/*, and the three scripts Zig names itself:
  scripts/stage-conpty-redist.ps1 (build step, with the scripts it dot-sources),
  scripts/package-windows.ps1 and scripts/portable-manifest-verification.ps1
  (read by a unit test that compares their managed-file lists).
- Portable package smoke and the ARM64 build job: the packaging scripts, the
  CLI harnesses package-portable-cli.ps1 runs, README.md, LICENSE and the
  icon source in images/.
- Renderer smoke: test/windows/renderer/.
#>
[CmdletBinding()]
param(
    [string] $EventName = $env:GITHUB_EVENT_NAME,
    [string] $BaseSha,
    [string] $HeadSha,
    # The files to classify, instead of asking git (used by the tests).
    [string[]] $Paths,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

# Each rule: first match wins. Needs is what the file can change:
#   none     only the always-on checks job reads it
#   package  the packaging jobs (portable smoke, ARM64 build)
#   renderer the renderer smoke jobs
#   zig      the Zig graph, and with it every compiled job
# Patterns are anchored regexes over the repo-relative path with '/' separators.
$script:CiPathRules = @(
    # Prose and metadata. The checks job runs the site and release copy checks
    # and the contracts that read these files; nothing compiled does.
    @{ Needs = 'none'; Pattern = '^plans/' }
    # A unit test loads every config example in docs/windows.md's profile
    # sections (src/config/Config.zig), so a change to it runs the Zig jobs.
    @{ Needs = 'zig'; Pattern = '^docs/windows\.md$' }
    # docs/ includes docs/agents/log/, the Self-Correction Log AGENTS.md indexes.
    @{ Needs = 'none'; Pattern = '^docs/' }
    @{ Needs = 'none'; Pattern = '^site/' }
    @{ Needs = 'none'; Pattern = '^\.greptile/' }
    @{ Needs = 'none'; Pattern = '^\.agents/' }
    @{ Needs = 'none'; Pattern = '^\.github/(ISSUE_TEMPLATE/|pull_request_template\.md$|PULL_REQUEST_TEMPLATE/|dependabot\.yml$|CODEOWNERS$)' }
    @{ Needs = 'none'; Pattern = '^\.github/workflows/(deploy-site|release|release-readiness)\.yml$' }
    @{ Needs = 'none'; Pattern = '^CODEOWNERS$' }
    @{ Needs = 'none'; Pattern = '^(typos\.toml|\.gitignore|\.prettierignore)$' }
    # README.md and LICENSE are copied into the portable package.
    @{ Needs = 'package'; Pattern = '^(README\.md|LICENSE)$' }
    @{ Needs = 'none'; Pattern = '^[^/]+\.md$' }
    @{ Needs = 'package'; Pattern = '^images/' }

    # Scripts that only the checks job, the release workflows or a person run.
    @{ Needs = 'none'; Pattern = '^scripts/(build-site-assets\.mjs|build-site-payload\.ps1|check-accessibility-evidence\.ps1|check-release-copy\.ps1|check-site-copy\.ps1|check-source-format\.ps1|fetch-zig-deps\.ps1|get-site-header-contract\.ps1|package-package-managers\.ps1|require-site-deployment-head\.ps1|test-release-copy-date\.ps1|test-signing-trust\.ps1|test-windows-build-capabilities\.ps1|update-release-copy\.ps1|upstream-drift\.ps1|verify-cloudflare-pages\.ps1|verify-published-release\.ps1)$' }
    @{ Needs = 'none'; Pattern = '^scripts/(release-[a-z-]+\.ps1|interactive-win11\.(ps1|cmd)|interactive-win11-window-lib\.ps1)$' }
    # Packaging only: dot-sourced by build-package-windows.ps1, package-windows.ps1
    # and the CLI harnesses package-portable-cli.ps1 runs (interactive-win11-lib),
    # none of which a Zig source names. (package-windows.ps1 itself is read by a
    # unit test, so it stays on the default rule.)
    @{ Needs = 'package'; Pattern = '^scripts/(build-package-windows|symbols-verification|signing-trust|interactive-win11-lib|dev-windows)\.(ps1|cmd)$' }

    # Test harnesses the checks job runs, or that only a person or the manual
    # interactive job runs.
    @{ Needs = 'none'; Pattern = '^test/README\.md$' }
    @{ Needs = 'none'; Pattern = '^test/windows/(README\.md|\.gitignore|PSScriptAnalyzerSettings\.psd1|accessibility-evidence\.schema\.json|bench-thresholds\.json|bench-windows\.ps1|Test-InteractiveWin11HintsContracts\.ps1|assert-interactive-runner\.ps1|bash-shell-integration\.ps1|powershell-shell-integration\.ps1|cmd-clink\.(lua|ps1)|conpty-host-spike\.ps1|console-[a-z-]+\.c|issue149-color-payload\.ps1|link-opener-pathext-probe\.ps1|package-chocolatey\.ps1|package-scoop\.ps1|vt-probe-win32-conformance\.ps1|ci-scripts\.ps1|fixtures/.*)$' }
    @{ Needs = 'none'; Pattern = '^test/windows/(interactive-win11[a-z0-9-]*|hidden-win11-[a-z0-9-]+)\.ps1$' }
    @{ Needs = 'none'; Pattern = '^test/windows/flagship/(?!Invoke-PortableSmoke\.ps1$|scenarios/portable-x64\.json$|result\.schema\.json$)' }
    # What package-portable-cli.ps1 and Invoke-PortableSmoke.ps1 run.
    # The executable build also runs the emitted-image import contract.
    @{ Needs = 'zig'; Pattern = '^test/windows/cli-import-contract\.ps1$' }
    @{ Needs = 'package'; Pattern = '^test/windows/(package-portable-cli\.ps1|cli-[a-z-]+\.ps1|test_dll_init\.c|flagship/Invoke-PortableSmoke\.ps1|flagship/scenarios/portable-x64\.json|flagship/result\.schema\.json)$' }
    @{ Needs = 'renderer'; Pattern = '^test/windows/renderer/' }
)

function New-CiSelection {
    param([bool] $Value)
    return [ordered]@{ zig = $Value; renderer = $Value; package = $Value }
}

function ConvertTo-CiRepoPath {
    param([Parameter(Mandatory)] [string] $Path)
    # Git prints '/' paths; a hand-written list may carry '\'. Quoted names with
    # escapes (core.quotePath) fall through to the default rule, which is safe.
    return $Path.Trim().Replace('\', '/')
}

# What one file can change: none, package, renderer or zig (the default).
function Get-CiPathNeeds {
    param([Parameter(Mandatory)] [string] $Path)
    $repoPath = ConvertTo-CiRepoPath $Path
    foreach ($rule in $script:CiPathRules) {
        if ($repoPath -cmatch $rule.Pattern) { return $rule.Needs }
    }
    return 'zig'
}

# The job switches for a list of changed files. An empty list (no diff to read)
# runs everything.
function Get-CiJobSelection {
    param([string[]] $ChangedPaths)

    $selection = New-CiSelection $false
    $files = @($ChangedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($files.Count -eq 0) { return New-CiSelection $true }
    foreach ($file in $files) {
        switch (Get-CiPathNeeds $file) {
            'zig' { $selection.zig = $true }
            'renderer' { $selection.renderer = $true }
            'package' { $selection.package = $true }
        }
    }
    # The Zig graph feeds both smoke jobs, so a Zig change implies them.
    if ($selection.zig) { $selection.renderer = $true; $selection.package = $true }
    return $selection
}

# The flag each compiled job reads in its `if:` (the `changes` job outputs).
# Both workflows print all of them; each reads its own.
function Get-CiJobFlags {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Selection)

    $zig = [bool] $Selection.zig
    $renderer = $zig -or [bool] $Selection.renderer
    $package = $zig -or [bool] $Selection.package
    return [ordered]@{
        tests = $zig
        bench = $zig
        build = $zig
        cross_arm64 = $zig
        lib_vt = $zig
        conpty_probes = $zig
        arm64_tests = $zig
        renderer_smoke = $renderer
        portable_smoke = $package
        arm64_build = $zig -or $renderer -or $package
    }
}

function Get-CiChangedPaths {
    param([string] $Base, [string] $Head)
    # Three dots: the pull request's own changes, whatever main did since the
    # branch point. --no-renames lists both sides of a move. quotepath=false
    # keeps non-ASCII names readable; a name git still quotes (a quote, a tab, a
    # newline) matches no rule and so runs everything.
    $names = & git -c core.quotepath=false diff --name-only --no-renames "$Base...$Head" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "git diff $Base...$Head failed with exit code $LASTEXITCODE." }
    return @($names)
}

# GITHUB_OUTPUT and GITHUB_STEP_SUMMARY want UTF-8 without a byte-order mark,
# which Windows PowerShell 5.1's `-Encoding utf8` would write.
function Add-CiFileLine {
    # AllowEmptyString: a summary has blank lines.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Line)
    [System.IO.File]::AppendAllText($Path, (($Line -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Write-CiOutput {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Value)
    Write-Host "$Name=$Value"
    if ($env:GITHUB_OUTPUT) { Add-CiFileLine -Path $env:GITHUB_OUTPUT -Line "$Name=$Value" }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
$selection = New-CiSelection $true
$reason = "event '$EventName' runs everything"
try {
    if ($PSBoundParameters.ContainsKey('Paths')) {
        $selection = Get-CiJobSelection -ChangedPaths $Paths
        $reason = "$($Paths.Count) listed path(s)"
    }
    elseif ($EventName -eq 'pull_request') {
        if ([string]::IsNullOrWhiteSpace($BaseSha) -or [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw 'A pull request run needs -BaseSha and -HeadSha.'
        }
        $changed = Get-CiChangedPaths -Base $BaseSha -Head $HeadSha
        $selection = Get-CiJobSelection -ChangedPaths $changed
        $reason = "$($changed.Count) changed path(s) in $BaseSha...$HeadSha"
        $summaryLines = @(
            '### Changed paths'
            ''
            "Compiled jobs: zig=$($selection.zig) renderer=$($selection.renderer) package=$($selection.package). The checks job always runs."
            ''
        )
        if ($changed.Count -le 40) {
            $summaryLines += $changed | ForEach-Object { '- `{0}` -> {1}' -f $_, (Get-CiPathNeeds $_) }
        }
        if ($env:GITHUB_STEP_SUMMARY) { Add-CiFileLine -Path $env:GITHUB_STEP_SUMMARY -Line $summaryLines }
    }
}
catch {
    # Reading the diff is an optimisation. When it fails, run everything.
    Write-Warning "Could not decide from the diff ($($_.Exception.Message)); running every job."
    $selection = New-CiSelection $true
    $reason = 'diff unavailable'
}

Write-Host "Job selection ($reason)"
$flags = Get-CiJobFlags -Selection $selection
foreach ($name in $flags.Keys) { Write-CiOutput -Name $name -Value $flags[$name].ToString().ToLowerInvariant() }
# A failed `git diff` was handled above (everything runs), but Actions ends a pwsh
# step with `exit $LASTEXITCODE`, which would still fail the step.
$global:LASTEXITCODE = 0
