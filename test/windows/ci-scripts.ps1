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
. (Join-Path $repoRoot 'scripts\capture-test-ran-list.ps1') -LibraryOnly
. (Join-Path $repoRoot 'scripts\compare-test-ran-list.ps1') -LibraryOnly
$ranLog = ConvertFrom-ZigRunnerLog -Lines @('1/4 a.test.one...OK', '2/4 a.test.two...[default] (warn): x', 'more', 'SKIP', '3/4 b.test_0...OK', '4/4 b.test.f...error: no', 'FAIL (TestUnexpectedResult)', '3 passed; 0 skipped; 1 failed.')
Assert-True ($ranLog.Problems.Count -eq 2 -and $ranLog.Problems[0] -like 'Parsed 2 passed tests*') 'The ran-list parser checks the closing counts against the results it read.'
$ranLog = ConvertFrom-ZigRunnerLog -Lines @('1/4 a.test.one...OK', '2/4 a.test.two...[default] (warn): x', 'more', 'SKIP', '3/4 b.test_0...OK', '4/4 b.test.f...error: no', 'FAIL (TestUnexpectedResult)', '2 passed; 1 skipped; 1 failed.')
Assert-True ($ranLog.Problems.Count -eq 0 -and $ranLog.Tests.Count -eq 4 -and $ranLog.Tests[1].Result -ceq 'SKIP' -and $ranLog.Tests[3].Result -ceq 'FAIL') 'A logging test keeps its result for its own line, and FAIL stands alone after its message.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/3 a.test.one...OK', '2/3 a.test.two...')).Problems -join ' ' -like '*did not finish*') 'A log that stops inside the run is refused, so a crash cannot shrink a list.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('1/3 a.test.one...OK', 'All 1 tests passed.')).Problems -join ' ' -like '*inconsistent*') 'A closing line that does not cover the announced tests is refused.'
Assert-True ((ConvertFrom-ZigRunnerLog -Lines @('All 0 tests passed.')).Problems -join ' ' -like '*no per-test lines*') 'A log without per-test lines (a build-runner log) is refused.'

$ranTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ran-list-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ranTemp | Out-Null
function New-RanListFile {
    param([string] $Name, [object[]] $Tests, [string] $Build = '-Demit-test-exe=true', [string] $SuiteName = 'ghostty-test')
    $rows = @(Get-RanListRows -SuiteName $SuiteName -Tests @($Tests | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Result = $_[1] } }))
    $suite = [pscustomobject]@{ Name = $SuiteName; Tests = $Tests.Count; Ok = 0; Skip = 0; Fail = 0; Exit = 0 }
    $path = Join-Path $ranTemp $Name
    [System.IO.File]::WriteAllText($path, (Format-RanList -Rows $rows -Suites @($suite) -Revision 'r' -BuildOptions $Build), [System.Text.UTF8Encoding]::new($false))
    return $path
}
function New-RanLedger {
    param([string] $Name, [string[]] $Lines)
    $path = Join-Path $ranTemp $Name
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    return $path
}
function Get-RanVerdict {
    param([string[]] $Baselines, [string] $Later, [string] $RemovalFile, [string] $SkipFile)
    $ledgerProblems = [Collections.Generic.List[string]]::new()
    $ranRemovals = Read-RanListLedger -Path $RemovalFile -Kind 'removals' -Problems $ledgerProblems
    $skips = Read-RanListLedger -Path $SkipFile -Kind 'approved skips' -Problems $ledgerProblems
    $v = Compare-RanList -BaselineLists @($Baselines | ForEach-Object { Read-RanList -Path $_ }) -CandidateList (Read-RanList -Path $Later) -RemovalEntries $ranRemovals -SkipEntries $skips
    return [pscustomobject]@{ Problems = @($ledgerProblems) + @($v.Problems); Notes = $v.Notes }
}
try {
    $base = New-RanListFile 'base.tsv' @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('B.test.upper', 'OK'))
    $text = [System.IO.File]::ReadAllText($base)
    Assert-True ($text -cmatch "(?s)ghostty-test`tOK`t1`tB\.test\.upper\n.*ghostty-test`tOK`t1`ta\.test\.one\n" -and $text.EndsWith("# end: rows=6 tests=6`n") -and -not $text.Contains("`r")) 'A list is sorted ordinally, LF-terminated and closed by its end line.'
    $read = Read-RanList -Path $base
    Assert-True ($read.Problems.Count -eq 0 -and $read.Rows.Count -eq 6 -and $read.Build -ceq '-Demit-test-exe=true') 'A written list reads back whole.'

    $v = Get-RanVerdict -Baselines @($base) -Later $base
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join "`n") -like '*CARRIED-SKIP ghostty-test a.test.font*') 'Control: the same list passes, and a test the baseline already skipped is carried.'

    $dropped = New-RanListFile 'dropped.tsv' @(@('a.test.one', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('B.test.upper', 'OK'))
    $v = Get-RanVerdict -Baselines @($base) -Later $dropped
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -ceq 'DROPPED ghostty-test a.test.two (ran 1 in the baseline, 0 now)') 'Control: a dropped test fails.'
    $ranRemovals = New-RanLedger 'removals.tsv' @('# suite, name, the ledger entry', "ghostty-test`ta.test.two`tdropped-delta ledger D-1: the subject was not taken")
    $v = Get-RanVerdict -Baselines @($base) -Later $dropped -RemovalFile $ranRemovals
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join "`n") -like '*LEDGERED-REMOVAL ghostty-test a.test.two (1 of 1): dropped-delta ledger D-1*') 'Control: a ledgered removal passes.'
    $noReason = New-RanLedger 'no-reason.tsv' @("ghostty-test`ta.test.two`t ")
    Assert-True ((Get-RanVerdict -Baselines @($base) -Later $dropped -RemovalFile $noReason).Problems.Count -eq 2) 'A removal without a reason is no ledger entry.'

    $turned = New-RanListFile 'turned.tsv' @(@('a.test.one', 'SKIP'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('B.test.upper', 'OK'))
    $v = Get-RanVerdict -Baselines @($base) -Later $turned
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -ceq 'TURNED-SKIP ghostty-test a.test.one (OK in the baseline, SKIP now)') 'Control: a test turned SKIP fails unless approved.'
    $skips = New-RanLedger 'skips.tsv' @("ghostty-test`ta.test.one`tglyph gating while glyph_protocol = false")
    $v = Get-RanVerdict -Baselines @($base) -Later $turned -SkipFile $skips
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join "`n") -like '*APPROVED-SKIP ghostty-test a.test.one: glyph gating*') 'An approved SKIP passes.'

    $missing = Join-Path $ranTemp 'no-such-baseline.tsv'
    $v = Get-RanVerdict -Baselines @($missing) -Later $base
    Assert-True ($v.Problems.Count -ge 1 -and $v.Problems[0] -like "*no-such-baseline.tsv' does not exist.") 'Control: a missing baseline fails.'
    Assert-True ((Compare-RanList -BaselineLists @() -CandidateList (Read-RanList -Path $base)).Problems[0] -like 'No baseline was given*') 'No baseline at all fails; it is never taken as empty.'
    $empty = New-RanListFile 'empty.tsv' @()
    Assert-True ((Get-RanVerdict -Baselines @($empty) -Later $base).Problems -join ' ' -like '*holds no tests*') 'An empty baseline fails.'
    $cut = Join-Path $ranTemp 'cut.tsv'
    [System.IO.File]::WriteAllText($cut, ($text -replace '# end: .*\n$', ''), [System.Text.UTF8Encoding]::new($false))
    Assert-True ((Get-RanVerdict -Baselines @($cut) -Later $base).Problems -join ' ' -like '*cut short*') 'A list cut short before its end line fails.'
    $lost = Join-Path $ranTemp 'lost-row.tsv'
    [System.IO.File]::WriteAllText($lost, ($text -replace "ghostty-test`tOK`t1`ta\.test\.two\n", ''), [System.Text.UTF8Encoding]::new($false))
    Assert-True ((Get-RanVerdict -Baselines @($lost) -Later $base).Problems -join ' ' -like '*does not match its end line*') 'A list that lost a row no longer matches its end line.'

    $failing = New-RanListFile 'failing.tsv' @(@('a.test.one', 'FAIL'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('B.test.upper', 'OK'))
    $v = Get-RanVerdict -Baselines @($base) -Later $failing
    Assert-True (($v.Problems -join "`n") -like '*FAILED ghostty-test a.test.one (1)*' -and ($v.Problems -join "`n") -like '*DROPPED ghostty-test a.test.one*') 'A FAIL in the later list fails.'
    Assert-True ((Get-RanVerdict -Baselines @($failing) -Later $base).Problems -join ' ' -like '*is not green*') 'A baseline with a FAIL row is refused.'

    $renumbered = New-RanListFile 'renumbered.tsv' @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    Assert-True ((Get-RanVerdict -Baselines @($base) -Later $renumbered).Problems.Count -eq 0) 'Renumbered unnamed blocks pass (an added block above them).'
    $lessUnnamed = New-RanListFile 'less-unnamed.tsv' @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_1', 'OK'), @('B.test.upper', 'OK'))
    Assert-True (((Get-RanVerdict -Baselines @($base) -Later $lessUnnamed).Problems -join ' ') -ceq 'DROPPED ghostty-test b.test_# (ran 2 in the baseline, 1 now)') 'A dropped unnamed block fails by its file''s count.'

    $otherBuild = New-RanListFile 'other-build.tsv' @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('B.test.upper', 'OK')) -Build '-Demit-test-exe=true -Dcustom-shaders=true'
    Assert-True (((Get-RanVerdict -Baselines @($base) -Later $otherBuild).Problems -join ' ') -like 'Build options differ*') 'Lists built with different options are not compared.'

    $phase = New-RanListFile 'phase.tsv' @(@('a.test.one', 'OK'), @('c.test.phase', 'OK'))
    $v = Get-RanVerdict -Baselines @($base, $phase) -Later $base
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -like 'DROPPED ghostty-test c.test.phase*') 'Two baselines are united: a test only the second ran must run again.'
    $twice = New-RanListFile 'twice.tsv' @(@('a.test.one', 'OK'), @('a.test.one', 'OK'))
    Assert-True ((Get-RanListRows -SuiteName 's' -Tests @([pscustomobject]@{ Name = 'x'; Result = 'OK' }, [pscustomobject]@{ Name = 'x'; Result = 'OK' }))[0].Count -eq 2) 'A test that runs twice is one row of multiplicity 2.'
    Assert-True (((Get-RanVerdict -Baselines @($twice) -Later $phase).Problems -join ' ') -like 'DROPPED ghostty-test a.test.one (ran 2 in the baseline, 1 now)*') 'A lower multiplicity is a drop.'
    $vt = New-RanListFile 'vt.tsv' @(, @('a.test.one', 'OK')) -SuiteName 'ghostty-vt-test'
    Assert-True (((Get-RanVerdict -Baselines @($vt) -Later $base).Problems -join ' ') -like 'DROPPED ghostty-vt-test a.test.one*') 'The suite is part of the identity: a test that ran in another executable does not count.'

    # The four controls PLAN.md §3.2 names, through the script's own exit code.
    $compareScript = Join-Path $repoRoot 'scripts\compare-test-ran-list.ps1'
    $cliCases = @(
        @{ Name = 'same list'; Args = @('-Baseline', $base, '-Candidate', $base); Exit = 0 }
        @{ Name = 'dropped test'; Args = @('-Baseline', $base, '-Candidate', $dropped); Exit = 1 }
        @{ Name = 'turned SKIP'; Args = @('-Baseline', $base, '-Candidate', $turned); Exit = 1 }
        @{ Name = 'approved SKIP'; Args = @('-Baseline', $base, '-Candidate', $turned, '-ApprovedSkips', $skips); Exit = 0 }
        @{ Name = 'ledgered removal'; Args = @('-Baseline', $base, '-Candidate', $dropped, '-Removals', $ranRemovals); Exit = 0 }
        @{ Name = 'missing baseline'; Args = @('-Baseline', $missing, '-Candidate', $base); Exit = 1 }
        @{ Name = 'no baseline'; Args = @('-Candidate', $base); Exit = 1 }
    )
    foreach ($case in $cliCases) {
        $output = & pwsh -NoProfile -NonInteractive -File $compareScript @($case.Args) 2>&1
        Assert-True ($LASTEXITCODE -eq $case.Exit) "Ran list compare, $($case.Name): expected exit $($case.Exit), got $LASTEXITCODE ($($output -join ' | '))."
    }
}
finally {
    Remove-Item -LiteralPath $ranTemp -Recurse -Force -ErrorAction SilentlyContinue
}

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
