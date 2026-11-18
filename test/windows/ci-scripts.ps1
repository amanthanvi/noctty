[CmdletBinding()]
param()

# Tests for the CI helper scripts: scripts/ci-changed-paths.ps1 (the path filter
# that lets a docs-only or script-only pull request skip the compiled CI jobs),
# scripts/ci-gate.ps1 (the gate that keeps a skip from standing in for a
# failure), and the parsers of the nightly report jobs, scripts/ci-test-timing.ps1
# and scripts/ci-bench-trend.ps1. Besides fixed cases, the filter guards read the
# repository itself: the filter is an allowlist of files the compiled jobs never
# read, and these checks re-derive "never read" from the Zig sources and from the
# scripts the compiled jobs run. One more check reads the installer script for
# what Setup asks Restart Manager to close, which compiling it does not check.

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $repoRoot 'scripts\ci-changed-paths.ps1') -LibraryOnly
. (Join-Path $repoRoot 'scripts\ci-gate.ps1') -LibraryOnly

$script:passed = 0
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Get-FlagText {
    param([string[]] $Paths)
    $flags = Get-CiJobFlags -Selection (Get-CiJobSelection -ChangedPaths $Paths)
    return (($flags.Keys | Where-Object { $flags[$_] } | Sort-Object) -join ',')
}

$tracked = @(& git -C $repoRoot ls-files)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) { throw 'git ls-files failed.' }
$trackedSet = [System.Collections.Generic.HashSet[string]]::new([string[]] $tracked, [System.StringComparer]::Ordinal)

# --- Fixed cases ------------------------------------------------------------
$allFlags = 'arm64_build,arm64_tests,bench,build,conpty_probes,cross_arm64,lib_vt,portable_smoke,renderer_smoke,tests'
$cases = @(
    @{ Name = 'docs only'; Paths = @('docs/status.md', 'AGENTS.md', 'docs/agents/log/conpty.md', 'CONTRIBUTING.md', 'plans/x.md'); Expect = '' }
    @{ Name = 'site only'; Paths = @('site/index.html', 'site/tests/a.test.mjs'); Expect = '' }
    @{ Name = 'release script only'; Paths = @('scripts/release-publish-github.ps1', 'scripts/verify-published-release.ps1'); Expect = '' }
    @{ Name = 'check script only'; Paths = @('scripts/check-site-copy.ps1'); Expect = '' }
    @{ Name = 'a harness only'; Paths = @('test/windows/interactive-win11-undo.ps1', 'test/windows/flagship/contracts/Contracts.90-Workflows.ps1'); Expect = '' }
    @{ Name = 'the shell integration test only'; Paths = @('test/windows/powershell-shell-integration.ps1'); Expect = '' }
    @{ Name = 'a Zig source'; Paths = @('src/apprt/win32.zig'); Expect = $allFlags }
    @{ Name = 'a shell integration script is source'; Paths = @('src/shell-integration/powershell/integration.ps1'); Expect = $allFlags }
    @{ Name = 'a script the Zig tests read'; Paths = @('scripts/package-windows.ps1'); Expect = $allFlags }
    @{ Name = 'the other script the Zig tests read'; Paths = @('scripts/portable-manifest-verification.ps1'); Expect = $allFlags }
    @{ Name = 'the conpty staging script'; Paths = @('scripts/stage-conpty-redist.ps1'); Expect = $allFlags }
    @{ Name = 'a build input'; Paths = @('build.zig.zon'); Expect = $allFlags }
    @{ Name = 'the packaged icon'; Paths = @('dist/windows/noctty.ico'); Expect = $allFlags }
    @{ Name = 'the test workflow'; Paths = @('.github/workflows/test.yml'); Expect = $allFlags }
    @{ Name = 'the ARM64 workflow'; Paths = @('.github/workflows/windows-arm64.yml'); Expect = $allFlags }
    @{ Name = 'this filter'; Paths = @('scripts/ci-changed-paths.ps1'); Expect = $allFlags }
    @{ Name = 'the gate'; Paths = @('scripts/ci-gate.ps1'); Expect = $allFlags }
    @{ Name = 'the renderer harness'; Paths = @('test/windows/renderer/Invoke-RendererParity.ps1'); Expect = 'arm64_build,renderer_smoke' }
    @{ Name = 'the README'; Paths = @('README.md'); Expect = 'arm64_build,portable_smoke' }
    @{ Name = 'the portable smoke harness'; Paths = @('test/windows/package-portable-cli.ps1', 'test/windows/cli-shell-command.ps1'); Expect = 'arm64_build,portable_smoke' }
    @{ Name = 'a packaging-only script'; Paths = @('scripts/symbols-verification.ps1'); Expect = 'arm64_build,portable_smoke' }
    @{ Name = 'docs plus a Zig source'; Paths = @('docs/status.md', 'src/config/Config.zig'); Expect = $allFlags }
    @{ Name = 'the docs a unit test reads'; Paths = @('docs/windows.md'); Expect = $allFlags }
    @{ Name = 'docs plus the README'; Paths = @('docs/status.md', 'README.md'); Expect = 'arm64_build,portable_smoke' }
    @{ Name = 'a path the table does not know'; Paths = @('newdir/file.txt'); Expect = $allFlags }
    @{ Name = 'a quoted git path'; Paths = @('"docs/\303\251.md"'); Expect = $allFlags }
    @{ Name = 'a backslash path'; Paths = @('docs\status.md'); Expect = '' }
    @{ Name = 'an empty diff'; Paths = @(); Expect = $allFlags }
    @{ Name = 'blank lines only'; Paths = @('', '  '); Expect = $allFlags }
)
foreach ($case in $cases) {
    $found = Get-FlagText -Paths $case.Paths
    Assert-True ($found -ceq $case.Expect) "Path filter case '$($case.Name)': expected [$($case.Expect)], found [$found]."
}

# The CLI path: a fixed list in, GITHUB_OUTPUT lines out.
$outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ci-paths-$([guid]::NewGuid().ToString('N')).txt")
try {
    $env:GITHUB_OUTPUT = $outputFile
    & (Join-Path $repoRoot 'scripts\ci-changed-paths.ps1') -Paths @('docs/status.md') 6>$null | Out-Null
    $lines = @(Get-Content -LiteralPath $outputFile)
    Assert-True ($lines -contains 'tests=false' -and $lines -contains 'arm64_build=false' -and $lines.Count -eq 10) 'A docs-only list must switch every compiled job off.'
    Remove-Item -LiteralPath $outputFile
    & (Join-Path $repoRoot 'scripts\ci-changed-paths.ps1') -EventName push 6>$null | Out-Null
    $lines = @(Get-Content -LiteralPath $outputFile)
    Assert-True (($lines | Where-Object { $_ -like '*=true' }).Count -eq 10) 'A push must run every job.'
    Remove-Item -LiteralPath $outputFile
    & (Join-Path $repoRoot 'scripts\ci-changed-paths.ps1') -EventName pull_request -BaseSha 'not-a-sha' -HeadSha 'not-a-sha' 3>$null 6>$null | Out-Null
    $lines = @(Get-Content -LiteralPath $outputFile)
    Assert-True (($lines | Where-Object { $_ -like '*=true' }).Count -eq 10) 'An unreadable diff must run every job.'
}
finally {
    $env:GITHUB_OUTPUT = $null
    if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
}
# The pull-request path with a real revision pair, the job summary on. The first
# hosted run of this filter failed open here (an empty summary line was rejected
# by a mandatory parameter) and only a warning in the log said so.
$revisions = @(& git -C $repoRoot rev-list -n 2 HEAD)
if ($revisions.Count -eq 2) {
    $summaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ci-summary-$([guid]::NewGuid().ToString('N')).md")
    $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ci-output-$([guid]::NewGuid().ToString('N')).txt")
    try {
        $env:GITHUB_STEP_SUMMARY = $summaryFile
        $env:GITHUB_OUTPUT = $outputFile
        $warnings = & (Join-Path $repoRoot 'scripts\ci-changed-paths.ps1') -EventName pull_request -BaseSha $revisions[1] -HeadSha $revisions[0] 3>&1 6>$null | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        Assert-True (@($warnings).Count -eq 0) "The real diff path must not fail open: $(@($warnings) -join '; ')"
        $summary = [System.IO.File]::ReadAllText($summaryFile)
        Assert-True ($summary -match '### Changed paths' -and $summary -match 'Compiled jobs: zig=') 'The job summary must be written.'
        Assert-True ((@(Get-Content -LiteralPath $outputFile)).Count -eq 10) 'The real diff path must write all ten flags.'
        Assert-True ([System.IO.File]::ReadAllBytes($outputFile)[0] -ne 0xEF) 'GITHUB_OUTPUT must not start with a byte-order mark.'
    }
    finally {
        $env:GITHUB_STEP_SUMMARY = $null
        $env:GITHUB_OUTPUT = $null
        Remove-Item -LiteralPath $summaryFile, $outputFile -ErrorAction Ignore
    }
}
# Actions ends a `shell: pwsh` step with `exit $LASTEXITCODE` when that variable
# exists, so a git failure the script handled (it fails open) must not leave a
# nonzero code behind. Reproduce the step's tail in a child process.
$stepTail = "& '$(Join-Path $repoRoot 'scripts\ci-changed-paths.ps1')' -EventName pull_request -BaseSha not-a-sha -HeadSha not-a-sha 3>`$null 6>`$null | Out-Null; if (Test-Path -LiteralPath variable:\LASTEXITCODE) { exit `$LASTEXITCODE }"
& pwsh -NoProfile -Command $stepTail
Assert-True ($LASTEXITCODE -eq 0) "A handled git failure must not fail the changes step (exit code $LASTEXITCODE)."

# --- The table itself -------------------------------------------------------
# A rule that matches no tracked file is clutter that hides a rename: the file
# it was written for now takes the default rule and nobody notices.
foreach ($rule in $script:CiPathRules) {
    $hit = $tracked | Where-Object { $_ -cmatch $rule.Pattern } | Select-Object -First 1
    Assert-True ($null -ne $hit) "Path filter rule matches no tracked file (renamed or deleted?): $($rule.Pattern)"
}
foreach ($rule in $script:CiPathRules) {
    Assert-True ($rule.Needs -in @('none', 'package', 'renderer', 'zig')) "Unknown Needs '$($rule.Needs)'."
}

# --- Guard: files Zig names -------------------------------------------------
# Zig reads repository files only through a string literal, so a literal that
# names a tracked file outside src/ is an input of the tests or the build, and
# the file must keep every compiled job. This is how scripts/package-windows.ps1
# stopped being "script-only": a unit test compares its managed-file list.
# Evidence labels in vt_probe.zig are printed, never opened.
$zigLabelOnly = @{
    'src/cli/vt_probe.zig' = @('test/windows/interactive-win11-command-finish.ps1', 'test/windows/interactive-win11-progress.ps1')
}
$zigFiles = @($tracked | Where-Object { $_ -like '*.zig' -and ($_ -like 'src/*' -or $_ -like 'pkg/*' -or $_ -eq 'build.zig') })
$zigNamedFiles = 0
foreach ($zigFile in $zigFiles) {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines((Join-Path $repoRoot $zigFile))) {
        $lineNumber++
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('//')) { continue }
        foreach ($literal in [regex]::Matches($line, '"(?:[^"\\]|\\.)*"')) {
            $text = $literal.Value.Replace('\\', '/')
            # A path in a literal starts the literal or follows ./ or ../; one that
            # follows another separator (C:/site/index.html) is some other tree.
            foreach ($candidate in [regex]::Matches($text, '(?<![\w:/.-])(?:\.{1,2}/)*((?:scripts|docs|site|plans|images|example|dist|include|vendor|test|\.github)/[\w./-]+)')) {
                $name = $candidate.Groups[1].Value
                if (-not $trackedSet.Contains($name)) { continue }
                if ($zigLabelOnly.ContainsKey($zigFile) -and $name -in $zigLabelOnly[$zigFile]) { continue }
                $zigNamedFiles++
                Assert-True ((Get-CiPathNeeds $name) -ceq 'zig') "${zigFile}:${lineNumber} names '$name', which the path filter classifies as '$(Get-CiPathNeeds $name)'; a file the Zig graph reads must run every compiled job."
            }
        }
    }
}
Assert-True ($zigNamedFiles -gt 0) 'The Zig literal scan found nothing; the pattern is broken.'

# --- Guard: files the compiled jobs run ------------------------------------
# Follows every repository file a compiled job's scripts name, through
# dot-sourcing and Join-Path, and requires each to keep the jobs that run it.
function Get-ScriptReferences {
    param([string] $RelativePath)

    $full = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return @() }
    $text = [System.IO.File]::ReadAllText($full)
    $dir = ''
    $slash = $RelativePath.LastIndexOf('/')
    if ($slash -ge 0) { $dir = $RelativePath.Substring(0, $slash + 1) }
    $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($text, '[''"]([\w.\\/-]+\.(?:ps1|cmd|c|json|psd1|glsl))[''"]')) { $names.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, '(?<![\w.-])((?:scripts|test|dist|src)[/\\][\w./\\-]+\.(?:ps1|cmd|c|json|zig))')) { $names.Add($m.Groups[1].Value) }
    foreach ($name in $names) {
        $relative = $name.Replace('\', '/')
        if ($relative.StartsWith('./')) { $relative = $relative.Substring(2) }
        foreach ($candidate in @("$dir$relative", $relative)) {
            if ($trackedSet.Contains($candidate)) { [void] $found.Add($candidate); break }
        }
    }
    return @($found)
}

function Get-ScriptClosure {
    param([string[]] $Roots)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($root in $Roots) { if ($trackedSet.Contains($root) -and $seen.Add($root)) { $queue.Enqueue($root) } }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($current -like '*.zig') { continue }   # the Zig side is the literal scan above
        foreach ($next in (Get-ScriptReferences $current)) {
            if ($seen.Add($next)) { $queue.Enqueue($next) }
        }
    }
    return @($seen)
}

function Get-JobRoots {
    param([string] $WorkflowPath, [string] $JobId)

    $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot $WorkflowPath))
    $match = [regex]::Match($text, '(?ms)^  ' + [regex]::Escape($JobId) + ':\s*(?:#.*)?\r?\n.*?(?=^  \S[^\r\n]*:\s*(?:#.*)?$|\z)')
    if (-not $match.Success) { throw "Workflow job not found: $JobId in $WorkflowPath" }
    # A comment naming a script does not run it.
    $code = ($match.Value -split '\r?\n' | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
    $roots = foreach ($m in [regex]::Matches($code, '(?<![\w.-])(?:\./)?((?:scripts|test)/[\w./-]+\.(?:ps1|cmd))')) { $m.Groups[1].Value }
    return @($roots | Select-Object -Unique)
}

# job -> the classes that may run it (a class that needs less would skip it).
$compiledJobs = @(
    @{ File = '.github/workflows/test.yml'; Job = 'tests'; Allowed = @('zig') }
    @{ File = '.github/workflows/test.yml'; Job = 'bench'; Allowed = @('zig') }
    @{ File = '.github/workflows/test.yml'; Job = 'build'; Allowed = @('zig') }
    @{ File = '.github/workflows/test.yml'; Job = 'cross-arm64'; Allowed = @('zig') }
    @{ File = '.github/workflows/test.yml'; Job = 'windows-lib-vt'; Allowed = @('zig') }
    @{ File = '.github/workflows/test.yml'; Job = 'windows-conpty-probes'; Allowed = @('zig') }
    @{ File = '.github/workflows/test.yml'; Job = 'renderer-smoke'; Allowed = @('zig', 'renderer') }
    @{ File = '.github/workflows/test.yml'; Job = 'windows-portable-smoke'; Allowed = @('zig', 'package') }
    @{ File = '.github/workflows/windows-arm64.yml'; Job = 'arm64-tests'; Allowed = @('zig') }
    @{ File = '.github/workflows/windows-arm64.yml'; Job = 'arm64-build'; Allowed = @('zig', 'package', 'renderer') }
)
$closureFiles = 0
foreach ($job in $compiledJobs) {
    $roots = @(Get-JobRoots -WorkflowPath $job.File -JobId $job.Job)
    foreach ($file in (Get-ScriptClosure -Roots $roots)) {
        $closureFiles++
        $needs = Get-CiPathNeeds $file
        Assert-True ($needs -in $job.Allowed) "$($job.File) job '$($job.Job)' runs or reads '$file', which the path filter classifies as '$needs'; a PR changing only that file would skip the job."
    }
}
Assert-True ($closureFiles -gt 10) 'The script closure found almost nothing; the extraction is broken.'

# --- The gate ---------------------------------------------------------------
function New-Needs {
    param([hashtable] $Results, [hashtable] $Outputs, [string] $Changes = 'success')
    $needs = [ordered]@{ changes = [ordered]@{ result = $Changes; outputs = $Outputs } }
    foreach ($name in $Results.Keys) { $needs[$name] = [ordered]@{ result = $Results[$name]; outputs = @{} } }
    return ($needs | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}
$expect = @('checks:always', 'tests:tests', 'build:build')
$on = @{ tests = 'true'; build = 'true' }
$off = @{ tests = 'false'; build = 'false' }
function Get-GateText { param($Needs) return ((Get-CiGateProblems -Needs $Needs -Expect $expect) -join '; ') }

Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'success'; build = 'success' } $on)) -eq '') 'The gate must pass when every needed job succeeded.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'skipped'; build = 'skipped' } $off)) -eq '') 'The gate must pass a docs-only run whose compiled jobs were skipped.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'failure'; build = 'success' } $on)) -like 'tests: needed*failure*') 'A failed needed job must fail the gate.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'cancelled'; build = 'success' } $on)) -like 'tests: needed*cancelled*') 'A cancelled needed job must fail the gate.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'success'; build = 'skipped' } $on)) -like 'build: needed*skipped*') 'A needed job that was skipped (its own needs failed) must fail the gate.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'skipped'; tests = 'skipped'; build = 'skipped' } $off)) -like 'checks: expected success*skipped*') 'The always-on checks job must not be skippable.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'failure'; tests = 'skipped'; build = 'skipped' } $off)) -like 'checks: expected success*failure*') 'A failed checks job must fail a docs-only run.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'success'; build = 'success' } $off)) -like '*not needed*success*') 'A job that ran although its flag was off signals a broken workflow condition.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'success'; build = 'success' } $on -Changes 'failure')) -like 'changes: expected success*') 'A failed changes job must fail the gate.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'success' } $on)) -like 'build: missing*') 'A job missing from needs must fail the gate.'
Assert-True ((Get-GateText (New-Needs @{ checks = 'success'; tests = 'success'; build = 'success' } @{ tests = 'true' })) -like "build: the changes job has no output 'build'") 'An unknown flag must fail the gate.'

# The CLI prints every problem, not just the first, and exits 1.
$twoFailures = New-Needs @{ checks = 'success'; tests = 'failure'; build = 'cancelled' } $on
# The JSON travels in NEEDS_JSON: a native command line loses its double quotes in
# Windows PowerShell 5.1.
$env:NEEDS_JSON = $twoFailures | ConvertTo-Json -Depth 6 -Compress
$gateOutput = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts\ci-gate.ps1') -Expect ($expect -join ",") 2>&1 | Out-String
Assert-True ($LASTEXITCODE -eq 1 -and $gateOutput -match 'tests: needed' -and $gateOutput -match 'build: needed') "The gate must name every failed job and exit 1 (exit $LASTEXITCODE, output: $gateOutput)."
$env:NEEDS_JSON = (New-Needs @{ checks = 'success'; tests = 'success'; build = 'success' } $on) | ConvertTo-Json -Depth 6 -Compress
$gateOk = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts\ci-gate.ps1') -Expect ($expect -join ",") 2>&1 | Out-String
$env:NEEDS_JSON = $null
Assert-True ($LASTEXITCODE -eq 0) "The gate must exit 0 when every needed job succeeded (exit $LASTEXITCODE, output: $gateOk)."
foreach ($bad in @('', 'tru', 'TRUE', 'unknown')) {
    $badNeeds = New-Needs @{ checks = 'success'; tests = 'skipped'; build = 'skipped' } @{ tests = $bad; build = 'false' }
    Assert-True ((Get-GateText $badNeeds) -like "tests: the changes job output 'tests' is '$bad', not 'true' or 'false'") "A malformed flag [$bad] must fail the gate instead of reading as not needed."
}

# --- Test timing parser -----------------------------------------------------
. (Join-Path $repoRoot 'scripts\ci-test-timing.ps1') -LibraryOnly
function New-Lines {
    param([object[]] $Pairs)
    return @($Pairs | ForEach-Object { @{ Seconds = $_[0]; Text = $_[1] } })
}
$quiet = @(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(1.0, '1/3 a...OK'), @(3.5, '2/3 b...OK'), @(3.6, '3/3 c...SKIP'))))
Assert-True ($quiet.Count -eq 3 -and $quiet[0].Seconds -eq 1.0 -and $quiet[1].Seconds -eq 2.5 -and $quiet[2].Seconds -eq 0.1 -and $quiet[2].Result -ceq 'SKIP') 'Quiet tests are timed from the previous end to their own.'
# A test that logs ends its header line early; its OK comes on a line of its own,
# and it, not its neighbour, owns the time in between.
$logged = @(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(0.2, '1/3 a...[warn] something'), @(0.3, 'more output'), @(1.6, 'OK'), @(1.65, '2/3 b...OK'), @(1.7, '3/3 c...OK'))))
Assert-True ($logged.Count -eq 3 -and $logged[0].Name -ceq 'a' -and $logged[0].Seconds -eq 1.6 -and $logged[0].Result -ceq 'OK' -and $logged[1].Seconds -eq 0.05) 'A test that logs keeps its time and its result until its own OK.'
$failed = @(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(0.5, '1/2 a...error: boom'), @(0.9, 'FAIL (TestUnexpectedResult)'), @(1.0, '2/2 b...OK'))))
Assert-True ($failed.Count -eq 2 -and $failed[0].Result -ceq 'FAIL (TestUnexpectedResult)' -and $failed[0].Seconds -eq 0.9) 'A failing test that logged ends at its FAIL line.'
$cut = @(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(1.0, '1/3 a...OK'), @(2.0, '2/3 b...'), @(2.5, '3/3 c...OK'))))
Assert-True ($cut.Count -eq 3 -and $cut[1].Result -ceq 'incomplete' -and $cut[2].Name -ceq 'c') 'A test whose end never printed is closed where the next one starts.'
$eof = @(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(1.0, '1/2 a...OK'), @(2.0, '2/2 b...'))))
Assert-True ($eof.Count -eq 2 -and $eof[1].Result -ceq 'incomplete' -and $eof[1].Seconds -eq 1.0) 'A log that ends inside a test reports it as incomplete.'
$eofLogged = @(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(1.0, '1/2 a...OK'), @(2.0, '2/2 b...'), @(4.5, 'a log line'))))
Assert-True ($eofLogged[1].Result -ceq 'incomplete' -and $eofLogged[1].Seconds -eq 3.5) 'An incomplete last test is charged the time up to the last line.'
Assert-True (@(ConvertFrom-ZigTestLines -Lines (New-Lines @(@(1.0, 'All 3 tests passed.')))).Count -eq 0) 'Lines outside a test are ignored.'

# --- Nightly bench trend: which earlier run is the baseline ----------------
. (Join-Path $repoRoot 'scripts\ci-bench-trend.ps1') -LibraryOnly
$trendCalls = [System.Collections.Generic.List[string]]::new()
$trendApi = {
    param($Path)
    $trendCalls.Add($Path)
    if ($Path -like '*/workflows/test.yml/runs?*') {
        return '{"workflow_runs":[{"id":300},{"id":250},{"id":200},{"id":100}]}' | ConvertFrom-Json
    }
    if ($Path -like '*/runs/250/artifacts*') { return '{"artifacts":[{"name":"bench-trend-250","expired":true}]}' | ConvertFrom-Json }
    if ($Path -like '*/runs/200/artifacts*') { return '{"artifacts":[{"name":"renderer-x64-200","expired":false}]}' | ConvertFrom-Json }
    if ($Path -like '*/runs/100/artifacts*') { return '{"artifacts":[{"name":"bench-trend-100","expired":false}]}' | ConvertFrom-Json }
    return '{"artifacts":[]}' | ConvertFrom-Json
}
$baseline = Get-PreviousTrendArtifact -Repository 'owner/repo' -CurrentRunId '300' -Api $trendApi
Assert-True ($null -ne $baseline -and $baseline.RunId -ceq '100' -and $baseline.Name -ceq 'bench-trend-100') 'The baseline skips the current run, an expired artifact and a run without a trend artifact.'
Assert-True ($trendCalls[0] -like '*event=schedule*' -and -not ($trendCalls -like '*/runs/300/*')) 'Only scheduled runs are candidates, and the current run is never queried.'
Assert-True ($trendCalls[0] -like '*per_page=100*') 'The run listing must cover the whole 90-day artifact retention window.'
Assert-True ($null -eq (Get-PreviousTrendArtifact -Repository 'owner/repo' -CurrentRunId '300' -Api { param($Path) '{"workflow_runs":[],"artifacts":[]}' | ConvertFrom-Json })) 'With no earlier nightly there is no baseline.'

# --- Ran list: capture parser and compare (PLAN.md §3.2) --------------------
# Top-level names here start with $ran: dot-sourcing a script also declares its
# param() names, typed, in this scope.
. (Join-Path $repoRoot 'scripts\capture-test-ran-list.ps1') -LibraryOnly
. (Join-Path $repoRoot 'scripts\compare-test-ran-list.ps1') -LibraryOnly
$ranFixtures = Join-Path $repoRoot 'test\windows\ran-list-fixtures'
function Read-RanFixture { param([string] $Name) return [System.IO.File]::ReadAllLines((Join-Path $ranFixtures "$Name.stderr.txt")) }

# Native fixture output (Zig 0.15.2's stock runner; test/windows/ran-list-fixtures).
$ranLog = ConvertFrom-ZigRunnerLog -Lines (Read-RanFixture 'swap')
Assert-True (($ranLog.Problems -join ' ') -like '*Test 1*2 result-shaped lines*Test 2*2 result-shaped lines*' -and $ranLog.Tests.Count -eq 0) 'A test that prints the other result word makes its block ambiguous, so its output cannot swap two results (native fixture swap).'
$ranLog = ConvertFrom-ZigRunnerLog -Lines (Read-RanFixture 'leak')
Assert-True ($ranLog.Problems.Count -eq 0 -and $ranLog.Leaked -eq 1 -and $ranLog.ErrorsLogged -eq 1 -and $ranLog.Tests.Count -eq 2 -and @($ranLog.Tests | Where-Object Result -ceq 'OK').Count -eq 2) 'A leak is read from the trailers: the tests themselves report OK (native fixture leak).'
$ranLog = ConvertFrom-ZigRunnerLog -Lines (Read-RanFixture 'logged_error')
Assert-True ($ranLog.Problems.Count -eq 0 -and $ranLog.ErrorsLogged -eq 1 -and $ranLog.Leaked -eq 0) 'A logged error is read from the trailers (native fixture logged_error).'
$ranLog = ConvertFrom-ZigRunnerLog -Lines (Read-RanFixture 'names')
$ranNames = @($ranLog.Tests | ForEach-Object Name)
Assert-True ($ranLog.Problems.Count -eq 0 -and ($ranNames -join '|') -ceq 'names.test.wait...done|names.test.test_0|names.test.test_1|names.test_0|names.test_1|names.Inner.test.nested|names.Inner.test_0') "A quiet test's name may hold '...', and named and unnamed tests keep their Zig names (native fixture names): $($ranNames -join '|')"
$ranLog = ConvertFrom-ZigRunnerLog -Lines (Read-RanFixture 'dots_output')
Assert-True ($ranLog.Problems[0] -like "*cannot be told from the output*" -and $ranLog.Tests.Count -eq 0) "Output holding '...' on a header line is refused, not guessed (native fixture dots_output)."
# The index sequence, and the closing line.
$ranLog = ConvertFrom-ZigRunnerLog -Lines @('1/3 a.test.one...OK', '1/3 a.test.one...OK', '2/3 a.test.two...OK', '3/3 a.test.three...OK', 'All 3 tests passed.')
Assert-True (($ranLog.Problems -join ' ') -like '*out of sequence*') 'A repeated index is refused.'
$ranLog = ConvertFrom-ZigRunnerLog -Lines @('1/3 a.test.one...OK', '3/3 a.test.three...OK', 'All 3 tests passed.')
Assert-True (($ranLog.Problems -join ' ') -like '*out of sequence*') 'A skipped index is refused.'
$ranLog = ConvertFrom-ZigRunnerLog -Lines @('1/2 a.test.one...[x] (warn): y', '7/9 fake.test.z...OK', 'OK', '2/2 a.test.two...OK', 'All 2 tests passed.')
Assert-True (($ranLog.Problems -join ' ') -like '*test 7 of 9 out of sequence*') 'Output shaped like a runner header is refused.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/3 a.test.one...OK', '2/3 a.test.two...')).Problems -join ' ' -like '*did not finish*') 'A log that stops inside the run is refused, so a crash cannot shrink a list.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/3 a.test.one...OK', 'All 1 tests passed.')).Problems -join ' ' -like '*inconsistent*') 'A closing line that does not cover the announced tests is refused.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('All 0 tests passed.')).Problems -join ' ' -like '*no per-test lines*') 'A log without per-test lines (a build-runner log) is refused.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/1 a.test.one...OK', 'All 1 tests passed.', 'stray text')).Problems -join ' ' -like '*follow the closing line*') 'Text after the closing line that is not a trailer is refused.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/1 a.test.one...thread 4 panic: boom', 'All 1 tests passed.')).Problems.Count -ge 1) 'A block without a result is refused.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/1 a.test.one...OK', 'thread 4 panic: late', 'All 1 tests passed.')).Panics -eq 1) 'A panic line is counted.'

# Identities: only Zig's real unnamed blocks are counted by container.
Assert-True ((Get-RanListIdentity -Suite 's' -Name 'names.test_0') -ceq "s`tnames.test_#" -and (Get-RanListIdentity -Suite 's' -Name 'names.Inner.test_3') -ceq "s`tnames.Inner.test_#") 'An unnamed block is counted by its container.'
Assert-True ((Get-RanListIdentity -Suite 's' -Name 'names.test.test_0') -ceq "s`tnames.test.test_0" -and (Get-RanListIdentity -Suite 's' -Name 'a.test.x.test_1') -ceq "s`ta.test.x.test_1" -and (Get-RanListIdentity -Suite 's' -Name 'a.decltest.test_0') -ceq "s`ta.decltest.test_0") 'A named test or decltest called test_<n> keeps its own identity.'

$ranTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ran-list-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ranTemp | Out-Null
$ranBuild = [ordered]@{ source = 'built'; options = '(none)'; mode = 'Debug'; target = 'native-native.win10_rs5-msvc'; zig = '0.15.2'; dirty = 'false'; filtered = 'false' }
$ranEnv = [ordered]@{ 'cwd-on-temp-drive' = 'true'; 'font:Arial Unicode MS' = 'absent'; 'env:NOCTTY_RUN_LOCAL_PATH_SWEEP' = 'unset' }
function New-RanListFile {
    param([string] $Name, [object[]] $Tests, [System.Collections.IDictionary] $Build = $ranBuild, [System.Collections.IDictionary] $Environment = $ranEnv, [string] $SuiteName = 'ghostty-test', [string] $Exit = '0', [int] $Leaked = 0)
    $rows = @(Get-RanListRows -SuiteName $SuiteName -Tests @($Tests | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Result = $_[1] } }))
    $suite = [pscustomobject]@{ Name = $SuiteName; Tests = $Tests.Count; Ok = 0; Skip = 0; Fail = @($Tests | Where-Object { $_[1] -ceq 'FAIL' }).Count; Exit = $Exit; ErrorsLogged = 0; Leaked = $Leaked; Panics = 0 }
    $path = Join-Path $ranTemp $Name
    [System.IO.File]::WriteAllText($path, (Format-RanList -Rows $rows -Suites @($suite) -Revision 'r1' -Build $Build -Environment $Environment), [System.Text.UTF8Encoding]::new($false))
    return $path
}
function New-RanLedger {
    param([string] $Name, [string[]] $Lines)
    $path = Join-Path $ranTemp $Name
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    return $path
}
function Get-RanVerdict {
    param([string[]] $Baselines, [string] $Later, [string[]] $RemovalFiles = @(), [string[]] $SkipFiles = @(), [switch] $AllowFiltered)
    $ledgerProblems = [Collections.Generic.List[string]]::new()
    $removed = Read-RanListLedger -Paths $RemovalFiles -Kind 'removals' -Problems $ledgerProblems
    $approved = Read-RanListLedger -Paths $SkipFiles -Kind 'approved skips' -Problems $ledgerProblems
    $v = Compare-RanList -BaselineLists @($Baselines | ForEach-Object { Read-RanList -Path $_ }) -CandidateList (Read-RanList -Path $Later) -RemovalEntries $removed -SkipEntries $approved -AllowFilteredBaseline:$AllowFiltered
    return [pscustomobject]@{ Problems = @($ledgerProblems) + @($v.Problems); Notes = $v.Notes }
}
$ranSavedLocation = Get-Location
$ranSavedDirectory = [Environment]::CurrentDirectory
try {
    $ranBaseTests = @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    $ranBase = New-RanListFile 'base.tsv' $ranBaseTests
    $ranSkips = New-RanLedger 'skips.tsv' @('# suite, name, requires, reason', "ghostty-test`ta.test.font`tfont:Arial Unicode MS=absent`tneeds the font")
    $ranText = [System.IO.File]::ReadAllText($ranBase)
    Assert-True ($ranText -cmatch "(?s)ghostty-test`tOK`t1`tB\.test\.upper\n.*ghostty-test`tOK`t1`ta\.test\.one\n" -and $ranText.EndsWith("# end: rows=7 tests=7`n") -and -not $ranText.Contains("`r") -and $ranText -cmatch '(?m)^# env: cwd-on-temp-drive=true$' -and $ranText -cmatch "(?m)^# build: source=built`toptions=\(none\)`t") 'A list is sorted ordinally, LF-terminated, closed by its end line, and records its build and environment.'
    $ranRead = Read-RanList -Path $ranBase
    Assert-True ($ranRead.Problems.Count -eq 0 -and $ranRead.Rows.Count -eq 7 -and $ranRead.Build['zig'] -ceq '0.15.2' -and $ranRead.Environment['font:Arial Unicode MS'] -ceq 'absent') 'A written list reads back whole.'

    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranBase -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join "`n") -like '*APPROVED-SKIP ghostty-test a.test.font: needs the font*') 'Control: the same list passes when its skip is approved.'
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranBase
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -ceq 'UNAPPROVED-SKIP ghostty-test a.test.font (1 skipped, 0 approved)') 'Control: a test skipped in the baseline and skipped again fails without an approval (PLAN.md §3.2: OK or an approved SKIP).'
    $ranOtherEnv = [ordered]@{ 'cwd-on-temp-drive' = 'true'; 'font:Arial Unicode MS' = 'present'; 'env:NOCTTY_RUN_LOCAL_PATH_SWEEP' = 'unset' }
    $ranPresent = New-RanListFile 'font-present.tsv' $ranBaseTests -Environment $ranOtherEnv
    $v = Get-RanVerdict -Baselines @($ranPresent) -Later $ranPresent -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -like 'SKIP-ENVIRONMENT ghostty-test a.test.font is approved only with font:Arial Unicode MS=absent*') 'An approval that names an environment does not cover a list taken in another.'
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranPresent -SkipFiles @($ranSkips)
    Assert-True (($v.Problems -join "`n") -like '*ENV-DIFFERS font:Arial Unicode MS*') 'Lists taken in different environments are not compared.'

    $ranDropped = New-RanListFile 'dropped.tsv' @(@('a.test.one', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranDropped -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -ceq 'DROPPED ghostty-test a.test.two (ran 1 in the baseline, 0 now)') 'Control: a dropped test fails.'
    $ranRemovals = New-RanLedger 'removals.tsv' @('# suite, name, the ledger entry', "ghostty-test`ta.test.two`tdropped-delta ledger D-1: the subject was not taken")
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranDropped -RemovalFiles @($ranRemovals) -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join "`n") -like '*LEDGERED-REMOVAL ghostty-test a.test.two (1 of 1): dropped-delta ledger D-1*') 'Control: a ledgered removal passes.'
    $ranNoReason = New-RanLedger 'no-reason.tsv' @("ghostty-test`ta.test.two`t ")
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranDropped -RemovalFiles @($ranNoReason) -SkipFiles @($ranSkips)).Problems.Count -eq 2) 'A removal without a reason is no ledger entry.'

    $ranTurned = New-RanListFile 'turned.tsv' @(@('a.test.one', 'SKIP'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranTurned -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -ceq 'UNAPPROVED-SKIP ghostty-test a.test.one (1 skipped, 0 approved)') 'Control: a test turned SKIP fails unless approved.'
    $ranSkipsMore = New-RanLedger 'skips-more.tsv' @("ghostty-test`ta.test.one`t-`tglyph gating while glyph_protocol = false")
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranTurned -SkipFiles @($ranSkips, $ranSkipsMore)
    Assert-True ($v.Problems.Count -eq 0) 'An approved SKIP passes, and several approval files are merged.'
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranBase -SkipFiles @($ranSkips, $ranSkips)).Problems -join ' ' -like '*twice*') 'An entry listed twice across files is refused.'
    $ranNewSkip = New-RanListFile 'new-skip.tsv' ($ranBaseTests + @(, @('c.test.added', 'SKIP')))
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranNewSkip -SkipFiles @($ranSkips)).Problems -join ' ' -like '*UNAPPROVED-SKIP ghostty-test c.test.added*') 'A new test that skips needs an approval too.'

    $v = Get-RanVerdict -Baselines @((Join-Path $ranTemp 'no-such-baseline.tsv')) -Later $ranBase -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -ge 1 -and $v.Problems[0] -like "*no-such-baseline.tsv' does not exist.") 'Control: a missing baseline fails.'
    Assert-True ((Compare-RanList -BaselineLists @() -CandidateList (Read-RanList -Path $ranBase)).Problems[0] -like 'No baseline was given*') 'No baseline at all fails; it is never taken as empty.'
    Assert-True ((Get-RanVerdict -Baselines @((New-RanListFile 'empty.tsv' @())) -Later $ranBase).Problems -join ' ' -like '*holds no tests*') 'An empty baseline fails.'
    $ranCut = Join-Path $ranTemp 'cut.tsv'
    [System.IO.File]::WriteAllText($ranCut, ($ranText -replace '# end: .*\n$', ''), [System.Text.UTF8Encoding]::new($false))
    Assert-True ((Get-RanVerdict -Baselines @($ranCut) -Later $ranBase).Problems -join ' ' -like '*cut short*') 'A list cut short before its end line fails.'
    $ranLost = Join-Path $ranTemp 'lost-row.tsv'
    [System.IO.File]::WriteAllText($ranLost, ($ranText -replace "ghostty-test`tOK`t1`ta\.test\.two\n", ''), [System.Text.UTF8Encoding]::new($false))
    Assert-True ((Get-RanVerdict -Baselines @($ranLost) -Later $ranBase).Problems -join ' ' -like '*does not match its end line*') 'A list that lost a row no longer matches its end line.'

    $ranFailing = New-RanListFile 'failing.tsv' @(@('a.test.one', 'FAIL'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranFailing -SkipFiles @($ranSkips)).Problems -join ' ' -like '*not green*') 'A list with a FAIL fails as the later list.'
    Assert-True ((Get-RanVerdict -Baselines @($ranFailing) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ' -like '*not green*') 'A baseline with a FAIL is refused.'
    $ranLeaky = New-RanListFile 'leaky.tsv' $ranBaseTests -Exit '1' -Leaked 1
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranLeaky -SkipFiles @($ranSkips)).Problems -join ' ' -like '*not green (exit 1*1 leaked*') 'A run that exited 1 (a leak, every test OK) fails as the later list.'
    Assert-True ((Get-RanVerdict -Baselines @($ranLeaky) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ' -like '*not green*') 'A run that exited 1 is refused as a baseline.'

    $ranRenumbered = New-RanListFile 'renumbered.tsv' ($ranBaseTests + @(, @('b.test_3', 'OK')))
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranRenumbered -SkipFiles @($ranSkips)).Problems.Count -eq 0) 'Renumbered unnamed blocks pass (an added block).'
    $ranLessUnnamed = New-RanListFile 'less-unnamed.tsv' @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('B.test.upper', 'OK'))
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranLessUnnamed -SkipFiles @($ranSkips)).Problems -join ' ') -ceq 'DROPPED ghostty-test b.test_# (ran 3 in the baseline, 1 now)') "Dropped unnamed blocks fail by their container's count."
    $ranOneBlock = New-RanLedger 'one-block.tsv' @("ghostty-test`tb.test_2`tblock moved upstream")
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranLessUnnamed -RemovalFiles @($ranOneBlock) -SkipFiles @($ranSkips)).Problems -join ' ') -ceq 'DROPPED ghostty-test b.test_# (ran 3 in the baseline, 1 now, 1 ledgered)') 'One removal entry covers one unnamed block, not its whole container.'
    $ranTwoBlocks = New-RanLedger 'two-blocks.tsv' @("ghostty-test`tb.test_1`tblock moved upstream", "ghostty-test`tb.test_2`tblock moved upstream")
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranLessUnnamed -RemovalFiles @($ranTwoBlocks) -SkipFiles @($ranSkips)).Problems.Count -eq 0) 'Two removal entries cover two unnamed blocks.'
    $ranNamedZero = New-RanListFile 'named-zero.tsv' @(, @('a.test.test_0', 'OK'))
    $ranNamedOne = New-RanListFile 'named-one.tsv' @(, @('a.test.test_1', 'OK'))
    Assert-True (((Get-RanVerdict -Baselines @($ranNamedZero) -Later $ranNamedOne).Problems -join ' ') -ceq 'DROPPED ghostty-test a.test.test_0 (ran 1 in the baseline, 0 now)') 'A named test called test_0 replaced by one called test_1 is a drop, not a renumbered block.'

    $ranOtherBuild = New-RanListFile 'other-build.tsv' $ranBaseTests -Build ([ordered]@{ source = 'built'; options = '-Dcustom-shaders=true'; mode = 'Debug'; target = 'native-native.win10_rs5-msvc'; zig = '0.15.2'; dirty = 'false'; filtered = 'false' })
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranOtherBuild -SkipFiles @($ranSkips)).Problems -join ' ') -like 'BUILD-DIFFERS options*') 'Lists built with different options are not compared.'
    $ranOtherZig = New-RanListFile 'other-zig.tsv' $ranBaseTests -Build ([ordered]@{ source = 'built'; options = '(none)'; mode = 'Debug'; target = 'native-native.win10_rs5-msvc'; zig = '0.17.1'; dirty = 'false'; filtered = 'false' })
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranOtherZig -SkipFiles @($ranSkips)).Problems -join ' ') -like 'BUILD-DIFFERS zig*') 'Lists built by different compilers are not compared.'
    $ranUnknown = New-RanListFile 'unknown-build.tsv' $ranBaseTests -Build ([ordered]@{ source = 'declared'; options = 'unknown'; zig = 'unknown'; filtered = 'false' })
    Assert-True (((Get-RanVerdict -Baselines @($ranUnknown) -Later $ranUnknown -SkipFiles @($ranSkips)).Problems -join ' ') -like '*records no real build options*') 'A list whose build is unknown is refused.'
    $ranFiltered = New-RanListFile 'filtered.tsv' $ranBaseTests -Build ([ordered]@{ source = 'built'; options = '-Dtest-filter=resize_replay'; mode = 'Debug'; target = 'native-native.win10_rs5-msvc'; zig = '0.15.2'; dirty = 'false'; filtered = 'true' })
    Assert-True (((Get-RanVerdict -Baselines @($ranFiltered) -Later $ranFiltered -SkipFiles @($ranSkips)).Problems -join ' ') -like '*filtered build*no baseline*') 'A filtered list is no baseline.'
    Assert-True ((Get-RanVerdict -Baselines @($ranFiltered) -Later $ranFiltered -SkipFiles @($ranSkips) -AllowFiltered).Problems.Count -eq 0) 'A filtered list can be the baseline of a control when that is asked for.'

    $ranPhase = New-RanListFile 'phase.tsv' @(@('a.test.one', 'OK'), @('c.test.phase', 'OK'))
    $v = Get-RanVerdict -Baselines @($ranBase, $ranPhase) -Later $ranBase -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -like 'DROPPED ghostty-test c.test.phase*') 'Several baselines are united: a test only the second ran must run again.'
    Assert-True ((Get-RanListRows -SuiteName 's' -Tests @([pscustomobject]@{ Name = 'x'; Result = 'OK' }, [pscustomobject]@{ Name = 'x'; Result = 'OK' }))[0].Count -eq 2) 'A test that runs twice is one row of multiplicity 2.'
    $ranTwice = New-RanListFile 'twice.tsv' @(@('a.test.one', 'OK'), @('a.test.one', 'OK'))
    Assert-True (((Get-RanVerdict -Baselines @($ranTwice) -Later $ranPhase).Problems -join ' ') -like 'DROPPED ghostty-test a.test.one (ran 2 in the baseline, 1 now)*') 'A lower multiplicity is a drop.'
    $ranVt = New-RanListFile 'vt.tsv' @(, @('a.test.one', 'OK')) -SuiteName 'ghostty-vt-test'
    Assert-True (((Get-RanVerdict -Baselines @($ranVt) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ') -like 'DROPPED ghostty-vt-test a.test.one*') 'The suite is part of the identity: a test that ran in another executable does not count.'

    # The plan's four controls, and more, through the scripts' own exit codes.
    $ranCompare = Join-Path $repoRoot 'scripts\compare-test-ran-list.ps1'
    $ranCapture = Join-Path $repoRoot 'scripts\capture-test-ran-list.ps1'
    $ranCases = @(
        @{ Name = 'same list, skip approved'; Args = @('-Baseline', $ranBase, '-Candidate', $ranBase, '-ApprovedSkips', $ranSkips); Exit = 0 }
        @{ Name = 'same list, skip not approved'; Args = @('-Baseline', $ranBase, '-Candidate', $ranBase); Exit = 1 }
        @{ Name = 'dropped test'; Args = @('-Baseline', $ranBase, '-Candidate', $ranDropped, '-ApprovedSkips', $ranSkips); Exit = 1 }
        @{ Name = 'turned SKIP'; Args = @('-Baseline', $ranBase, '-Candidate', $ranTurned, '-ApprovedSkips', $ranSkips); Exit = 1 }
        @{ Name = 'ledgered removal'; Args = @('-Baseline', $ranBase, '-Candidate', $ranDropped, '-Removals', $ranRemovals, '-ApprovedSkips', $ranSkips); Exit = 0 }
        @{ Name = 'missing baseline'; Args = @('-Baseline', (Join-Path $ranTemp 'no-such-baseline.tsv'), '-Candidate', $ranBase, '-ApprovedSkips', $ranSkips); Exit = 1 }
        @{ Name = 'no baseline'; Args = @('-Candidate', $ranBase, '-ApprovedSkips', $ranSkips); Exit = 1 }
        @{ Name = 'leaky run'; Args = @('-Baseline', $ranBase, '-Candidate', $ranLeaky, '-ApprovedSkips', $ranSkips); Exit = 1 }
    )
    foreach ($case in $ranCases) {
        $output = & pwsh -NoProfile -NonInteractive -File $ranCompare @($case.Args) 2>&1
        Assert-True ($LASTEXITCODE -eq $case.Exit) "Ran list compare, $($case.Name): expected exit $($case.Exit), got $LASTEXITCODE ($($output -join ' | '))."
    }

    # The capture's own command line on native fixture logs (declared mode).
    $ranDeclared = @('-Revision', 'r1', '-BuildOptions', 'none', '-ZigVersion', '0.15.2')
    $ranExits = @{}
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $ranFixtures 'exit-codes.tsv'))) { if ($l -match "^(\w+)`t(-?\d+)$") { $ranExits[$Matches[1]] = $Matches[2] } }
    $ranCaptureCases = @(
        @{ Name = 'swap'; Exit = 1; Wrote = $false }
        @{ Name = 'leak'; Exit = 1; Wrote = $true }
        @{ Name = 'logged_error'; Exit = 1; Wrote = $true }
        @{ Name = 'names'; Exit = 0; Wrote = $true }
        @{ Name = 'dots_output'; Exit = 1; Wrote = $false }
    )
    foreach ($case in $ranCaptureCases) {
        $out = Join-Path $ranTemp "capture-$($case.Name).tsv"
        $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures "$($case.Name).stderr.txt") -TestLogExitCode $ranExits[$case.Name] -Suite fixture @ranDeclared -OutFile $out 2>&1
        Assert-True ($LASTEXITCODE -eq $case.Exit -and (Test-Path -LiteralPath $out) -eq $case.Wrote) "Ran list capture of native fixture $($case.Name): expected exit $($case.Exit) and a list $($case.Wrote), got $LASTEXITCODE and $(Test-Path -LiteralPath $out) ($($output -join ' | '))."
    }
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $ranTemp 'capture-leak.tsv')) -cmatch '(?m)^# suite: fixture tests=2 ok=2 skip=0 fail=0 exit=1 errors-logged=1 leaked=1 panics=0$') 'A captured leak keeps its exit code and trailers in the list.'
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestLogExitCode 0 -Revision r1 -BuildOptions unknown -ZigVersion 0.15.2 -OutFile (Join-Path $ranTemp 'unknown.tsv') 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'unknown.tsv'))) "A declared capture refuses an unknown build ($($output -join ' | '))."
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') @ranDeclared -OutFile (Join-Path $ranTemp 'no-exit.tsv') 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'no-exit.tsv'))) "A log import needs the exit code of the run that wrote it ($($output -join ' | '))."
    # The environment check runs before anything does.
    $ranHere = Get-RanListEnvironment -Directory $ranTemp
    $ranFlipped = [ordered]@{}
    foreach ($key in $ranHere.Keys) { $ranFlipped[$key] = $ranHere[$key] }
    $ranFlipped['store-alias'] = $(if ($ranHere['store-alias'] -ceq 'present') { 'absent' } else { 'present' })
    $ranEnvBase = New-RanListFile 'env-base.tsv' $ranBaseTests -Environment $ranFlipped
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestLogExitCode 0 @ranDeclared -WorkingDirectory $ranTemp -EnvironmentOf $ranEnvBase -OutFile (Join-Path $ranTemp 'env.tsv') 2>&1
    Assert-True ($LASTEXITCODE -eq 1 -and ($output -join ' ') -like '*environment fact store-alias*' -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'env.tsv'))) "A capture whose environment differs from its baseline's stops before it runs ($($output -join ' | '))."
    Assert-True (@($ranHere.Keys) -contains 'temp-makes-8dot3-names' -and @($ranHere.Keys) -contains 'font:Noto Serif Tibetan' -and $ranHere['env:NOCTTY_RUN_LOCAL_PATH_SWEEP'] -cin @('unset', '1', 'other')) 'The capture records the facts the environment-dependent tests read.'

    # Paths resolve against PowerShell's location, not .NET's current directory.
    $ranOld = New-Item -ItemType Directory -Path (Join-Path $ranTemp 'old')
    $ranNew = New-Item -ItemType Directory -Path (Join-Path $ranTemp 'new')
    Copy-Item -LiteralPath $ranBase -Destination (Join-Path $ranOld 'candidate.tsv')
    Copy-Item -LiteralPath $ranDropped -Destination (Join-Path $ranNew 'candidate.tsv')
    Copy-Item -LiteralPath $ranBase -Destination (Join-Path $ranNew 'base.tsv')
    Copy-Item -LiteralPath $ranSkips -Destination (Join-Path $ranNew 'skips.tsv')
    [Environment]::CurrentDirectory = $ranOld.FullName
    Set-Location -LiteralPath $ranNew.FullName
    $null = & $ranCompare -Baseline base.tsv -Candidate candidate.tsv -ApprovedSkips skips.tsv *>&1
    Assert-True ($LASTEXITCODE -eq 1) 'After Set-Location, a relative -Candidate is the one in the new location (it drops a test), not the old .NET directory''s.'
    $ranDeclaredMap = @{ Revision = 'r1'; BuildOptions = 'none'; ZigVersion = '0.15.2' }
    $null = & $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestLogExitCode 0 @ranDeclaredMap -OutFile relative.tsv *>&1
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $ranNew 'relative.tsv')) -and -not (Test-Path -LiteralPath (Join-Path $ranOld 'relative.tsv'))) 'After Set-Location, a relative -OutFile is written in the new location.'
}
finally {
    Set-Location -LiteralPath $ranSavedLocation
    [Environment]::CurrentDirectory = $ranSavedDirectory
    Remove-Item -LiteralPath $ranTemp -Recurse -Force -ErrorAction SilentlyContinue
}

# The seeded approvals: every entry parses, has a reason, and names only facts the capture records.
$ranLedgerProblems = [Collections.Generic.List[string]]::new()
$ranSeed = Read-RanListLedger -Paths @((Join-Path $repoRoot 'test\windows\ran-list-approved-skips.tsv')) -Kind 'approved skips' -Problems $ranLedgerProblems
$ranSeedCount = @($ranSeed.Values | ForEach-Object { $_ }).Count
$ranFactKeys = @('cwd-on-temp-drive', 'temp-makes-8dot3-names', 'store-alias') + @($script:RanListFonts | ForEach-Object { "font:$_" }) + @($script:RanListProbeVariables | ForEach-Object { "env:$_" })
$ranBadFacts = @($ranSeed.Values | ForEach-Object { $_ } | ForEach-Object { $_.Requires } | Where-Object { $_ } | ForEach-Object { ($_ -split '=', 2)[0] } | Where-Object { $_ -cnotin $ranFactKeys })
Assert-True ($ranLedgerProblems.Count -eq 0 -and $ranSeedCount -eq 196 -and $ranBadFacts.Count -eq 0) "The seeded approved skips parse (196 entries) and name known facts only ($($ranLedgerProblems -join '; ') $($ranBadFacts -join ', '))."

# --- Installer: what Setup asks Restart Manager to close --------------------
# The native ARM64 build job compiles dist/windows/noctty.iss on a pull request
# that touches it, with the runner image's Inno Setup (6.7.1 when measured; the
# job skips the installer if the image has none), but a clean compile says
# nothing about what Setup asks Restart Manager to close. This check pins that.
# OpenConsole.exe (the bundled ConPTY host, one per pane) is an RmUnknownApp:
# registered, it fails every non-forced RmShutdown before noctty is asked, and
# Setup aborts. A forced close would kill the programs running in noctty's
# terminals.
$setup = @{}
$inSetup = $false
foreach ($line in [System.IO.File]::ReadLines((Join-Path $repoRoot 'dist\windows\noctty.iss'))) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^\[(.+)\]$') { $inSetup = $Matches[1] -eq 'Setup'; continue }
    if ($inSetup -and $trimmed -match '^([A-Za-z]+)\s*=\s*(.*)$') { $setup[$Matches[1]] = $Matches[2].Trim() }
}
Assert-True ($setup.ContainsKey('AppId')) 'The installer script parse found no [Setup] section; the parser is broken.'
$closeApps = "$($setup['CloseApplications'])"
Assert-True ($closeApps -in @('yes', 'true', '1')) "noctty.iss must ask running copies to close (CloseApplications=yes), and never force it; found '$closeApps'."
$excludes = @("$($setup['CloseApplicationsFilterExcludes'])" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Assert-True ($excludes -contains 'OpenConsole.exe') "noctty.iss must keep OpenConsole.exe out of Restart Manager (CloseApplicationsFilterExcludes); found '$($excludes -join ',')'."
# Inno's default filter is *.exe,*.dll,*.chm.
$filter = @($(if ($setup.ContainsKey('CloseApplicationsFilter')) { $setup['CloseApplicationsFilter'] } else { '*.exe,*.dll,*.chm' }) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($kept in @('noctty.exe', 'conpty.dll')) {
    $held = @($filter | Where-Object { $kept -like $_ }).Count -and -not @($excludes | Where-Object { $kept -like $_ }).Count
    Assert-True $held "noctty.iss must still close what holds $kept; CloseApplicationsFilter is '$($filter -join ',')', CloseApplicationsFilterExcludes '$($excludes -join ',')'."
}

# The CLI cases above run git against a bad revision on purpose. Actions ends a
# pwsh step with `exit $LASTEXITCODE`, so leave it clean.
$global:LASTEXITCODE = 0
Write-Host "CI script tests passed ($script:passed assertions, $zigNamedFiles Zig-named files and $closureFiles script references checked)." -ForegroundColor Green
