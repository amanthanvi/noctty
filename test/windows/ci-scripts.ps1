#requires -Version 7.1
# Encoding.Latin1 and Convert.FromHexString (here and in the ran-list capture) need .NET 5.
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
# A fixture executable's --results record and its stderr (built with src/test_runner.zig).
function Read-RanRecord { param([string] $Name) return Read-ZigTestResults -Path (Join-Path $ranFixtures "$Name.results.txt") }
function Read-RanFixture { param([string] $Name) return [System.IO.File]::ReadAllLines((Join-Path $ranFixtures "$Name.stderr.txt")) }
# A child's output as one line: PowerShell colours an error message and wraps it at the console width.
function Join-RanOutput { param([object[]] $Output) return ((@($Output) -join ' ') -replace '\x1b\[[0-9;]*m', '' -replace '[\s|]+', ' ') }
function Get-RanResults { param([object] $Record) return (@($Record.Tests | ForEach-Object { "$($_.Name)=$($_.Result)" }) -join '|') }

# The runner's record holds what the runner decided, whatever a test printed
# (council round 3 on #726): native fixtures, each printing what used to fool
# a reader of the printed lines.
$ranRecord = Read-RanRecord 'printed'
Assert-True ($ranRecord.Problems.Count -eq 0 -and (Get-RanResults $ranRecord) -ceq 'printed.test.coverage=SKIP|printed.test.platform=OK') "A test that prints the other's result word, its own output running into the runner's result, cannot swap two results (native fixture printed, Sol): $(Get-RanResults $ranRecord)"
$ranRecord = Read-RanRecord 'forge'
Assert-True ($ranRecord.Problems.Count -eq 0 -and (Get-RanResults $ranRecord) -ceq 'forge.test.first=SKIP|forge.test.second=OK') "A test that prints the next test's exact header cannot take its result (native fixture forge, Opus): $(Get-RanResults $ranRecord)"
$ranRecord = Read-RanRecord 'swap'
Assert-True ($ranRecord.Problems.Count -eq 0 -and (Get-RanResults $ranRecord) -ceq 'swap.test.coverage=SKIP|swap.test.platform=OK') "Two tests that print each other's result word keep their own (native fixture swap): $(Get-RanResults $ranRecord)"
$ranRecord = Read-RanRecord 'bytes'
Assert-True ($ranRecord.Problems.Count -eq 0 -and (@($ranRecord.Tests | ForEach-Object Name) -join '|') -ceq 'bytes.test.coverage\xfe|bytes.test.coverage\xff|bytes.test.carriage\r\nreturn') "Names that differ only in a byte that is not UTF-8 stay two names, and a CR LF is kept (native fixture bytes, Sol): $(@($ranRecord.Tests | ForEach-Object Name) -join '|')"
$ranRecord = Read-RanRecord 'leak'
Assert-True ($ranRecord.Problems.Count -eq 0 -and $ranRecord.Tests[0].Leaked -and -not $ranRecord.Tests[1].Leaked -and $ranRecord.End.Leaked -eq 1 -and $ranRecord.End.ErrorsLogged -eq 1 -and (Get-RanResults $ranRecord) -ceq 'leak.test.leaks one byte=OK|leak.test.fine=OK') 'The record marks the test that leaked, and counts the leak and the error the allocator logged (native fixture leak).'
$ranRecord = Read-RanRecord 'logged_error'
Assert-True ($ranRecord.Problems.Count -eq 0 -and $ranRecord.End.ErrorsLogged -eq 1 -and $ranRecord.End.Leaked -eq 0) 'The record counts a logged error (native fixture logged_error).'
$ranRecord = Read-RanRecord 'names'
$ranNames = @($ranRecord.Tests | ForEach-Object Name) -join '|'
Assert-True ($ranRecord.Problems.Count -eq 0 -and $ranNames -ceq 'names.test.wait...done|names.test.test_0|names.test.test_1|names.test_0|names.test_1|names.Inner.test.nested|names.Inner.test_0') "Names keep their '...', and named and unnamed tests their Zig names (native fixture names): $ranNames"
$ranRecord = Read-RanRecord 'multiline'
Assert-True ($ranRecord.Problems.Count -eq 0 -and (Get-RanResults $ranRecord) -ceq 'multiline.test.coverage...\nsecond=OK') 'A name that holds ... and a newline is read whole, the newline written \n (native fixture multiline).'
Assert-True ((Get-RanResults (Read-RanRecord 'glued')) -ceq 'glued.test.loads=OK' -and (Get-RanResults (Read-RanRecord 'dots_output')) -ceq 'dots_output.test.loads=OK') 'Output holding ..., with or without a newline before the result, changes no name (native fixtures glued and dots_output).'
Assert-True ($ranRecord.Zig -ceq '0.15.2' -and $ranRecord.Mode -ceq 'Debug') 'The record names the compiler and the mode that built the executable.'
Assert-True ((Get-ZigPanicLineCount -Lines (Read-RanFixture 'leak')) -eq 0 -and (Get-ZigPanicLineCount -Lines @('thread 4 panic: boom', 'panic: sample', 'a panic: in a line')) -eq 2) 'Panic-shaped stderr lines are counted, for a reader only.'
# The bytes fixture's stderr is the runner's own bytes, kept by .gitattributes `-text -whitespace`: the
# names' FE and FF and the CR LF of one (council round 4 on #726, Opus L3).
$ranRawText = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $ranFixtures 'bytes.stderr.txt')))
Assert-True ($ranRawText.Contains("coverage$([char]0xFE)...OK`n") -and $ranRawText.Contains("coverage$([char]0xFF)...OK`n") -and $ranRawText.Contains("carriage`r`nreturn...OK`n")) 'The bytes fixture holds the runner''s raw stderr: bytes FE and FF, and the CR LF of a name.'
Assert-True ([System.IO.File]::ReadAllLines((Join-Path $repoRoot 'scripts\capture-test-ran-list.ps1'))[0] -ceq '#requires -Version 7.1' -and [System.IO.File]::ReadAllLines($PSCommandPath)[0] -ceq '#requires -Version 7.1') 'The capture and this harness declare PowerShell 7.1, the first with Convert.FromHexString and Encoding.Latin1 (bot threads on #726).'

# Names as rows write them: UTF-8 kept, everything else escaped, one text per byte string.
foreach ($ranCase in @(
        @{ Bytes = [byte[]] @(0x61, 0x5C, 0x62); Text = 'a\\b' }
        @{ Bytes = [byte[]] @(0x09, 0x0D, 0x0A); Text = '\t\r\n' }
        @{ Bytes = [byte[]] @(0xC3, 0xA9, 0xE2, 0x80, 0x94); Text = [string][char]0xE9 + [char]0x2014 }
        @{ Bytes = [byte[]] @(0xF0, 0x9F, 0x98, 0x80); Text = [char]::ConvertFromUtf32(0x1F600) }
        @{ Bytes = [byte[]] @(0xFE); Text = '\xfe' }
        @{ Bytes = [byte[]] @(0xFF); Text = '\xff' }
        @{ Bytes = [byte[]] @(0x80); Text = '\x80' }
        @{ Bytes = [byte[]] @(0xC0, 0x80); Text = '\xc0\x80' }
        @{ Bytes = [byte[]] @(0xE0, 0x80, 0x80); Text = '\xe0\x80\x80' }
        @{ Bytes = [byte[]] @(0xED, 0xA0, 0x80); Text = '\xed\xa0\x80' }
        @{ Bytes = [byte[]] @(0xF4, 0x90, 0x80, 0x80); Text = '\xf4\x90\x80\x80' }
        @{ Bytes = [byte[]] @(0xF5, 0x80); Text = '\xf5\x80' }
        @{ Bytes = [byte[]] @(0xE2, 0x80); Text = '\xe2\x80' }
        @{ Bytes = [byte[]] @(0x01, 0x7F, 0xC2, 0x85); Text = '\x01\x7f\xc2\x85' })) {
    $ranText = ConvertTo-RanListName -Bytes $ranCase.Bytes
    Assert-True ([string]::Equals($ranText, $ranCase.Text, [StringComparison]::Ordinal)) "A name's bytes $(($ranCase.Bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ' ') are written '$($ranCase.Text)', not '$ranText'."
}

# Identities: only Zig's real unnamed blocks are counted by container.
Assert-True ((Get-RanListIdentity -Suite 's' -Name 'names.test_0') -ceq "s`tnames.test_#" -and (Get-RanListIdentity -Suite 's' -Name 'names.Inner.test_3') -ceq "s`tnames.Inner.test_#") 'An unnamed block is counted by its container.'
Assert-True ((Get-RanListIdentity -Suite 's' -Name 'names.test.test_0') -ceq "s`tnames.test.test_0" -and (Get-RanListIdentity -Suite 's' -Name 'a.test.x.test_1') -ceq "s`ta.test.x.test_1" -and (Get-RanListIdentity -Suite 's' -Name 'a.decltest.test_0') -ceq "s`ta.decltest.test_0") 'A named test or decltest called test_<n> keeps its own identity.'
Assert-True ((Get-RanListIdentity -Suite 's' -Name "x.test_$([char]0x0660)") -ceq "s`tx.test_$([char]0x0660)") 'A name that ends in test_ and a non-ASCII digit is no unnamed block (council round 4 on #726, Opus L1).'
Assert-True ((Get-RanListModeMeaning 'Debug') -ceq 'debug' -and (Get-RanListModeMeaning 'ReleaseSafe') -ceq (Get-RanListModeMeaning 'safe') -and (Get-RanListModeMeaning 'ReleaseFast') -cne (Get-RanListModeMeaning 'safe')) 'Modes compare by meaning across 0.17.1''s renaming.'
Assert-True (@(Get-RanListFactKeys) -notcontains 'store-alias') 'No fact is recorded that no approval reads (the Store alias, council round 3, Sol).'
# Font facts (Greptile P1 on #726): discovery also scans the font directories, so a
# file the registry does not name counts by the families its `name` table declares,
# and one that cannot be read makes an absent font `unknown`, which no approval meets.
$ranJet = Join-Path $repoRoot 'src\font\res\JetBrainsMonoNoNF-Regular.ttf'
Assert-True ((Get-RanListFontFamilies -Path $ranJet) -contains 'JetBrains Mono' -and (Get-RanListFontFamilies -Path (Join-Path $repoRoot 'src\font\res\CodeNewRoman-Regular.otf')) -contains 'Code New Roman') 'A TrueType and a CFF OpenType font read their family names.'
foreach ($ranCase in @(
        @{ Name = 'a registered name'; Registered = @('Arial Unicode MS (TrueType)', 'Marlett (TrueType)'); Files = @(); Expect = 'present|absent|absent' }
        @{ Name = 'an unregistered file of another family'; Registered = @(); Files = @('Marlett'); Expect = 'absent|absent|absent' }
        @{ Name = 'an unreadable unregistered file'; Registered = @(); Files = @($null); Expect = 'unknown|unknown|unknown' }
        @{ Name = 'an unreadable file and one of a family'; Registered = @(); Files = @($null, 'Noto Sans Chakma Bold'); Expect = 'unknown|present|unknown' }
        @{ Name = 'a registered name and an unreadable file'; Registered = @('Arial Unicode MS (TrueType)'); Files = @($null); Expect = 'present|unknown|unknown' })) {
    # Each unregistered file's declared families, or $null for one that cannot be read.
    $ranFamilies = [Collections.Generic.List[object]]::new()
    foreach ($e in $ranCase.Files) { $ranFamilies.Add($(if ($null -eq $e) { $null } else { [string[]] @($e) })) }
    $ranFonts = Get-RanListFontFacts -RegisteredNames $ranCase.Registered -UnregisteredFamilies $ranFamilies.ToArray()
    $ranGot = @('Arial Unicode MS', 'Noto Sans Chakma', 'Noto Serif Tibetan' | ForEach-Object { $ranFonts["font:$_"] }) -join '|'
    Assert-True ($ranGot -ceq $ranCase.Expect) "Font facts for $($ranCase.Name): expected $($ranCase.Expect), got $ranGot."
}

$ranTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ran-list-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ranTemp | Out-Null
$ranBuild = [ordered]@{ source = 'built'; options = '(none)'; mode = 'Debug'; target = 'native-native.win10_rs5-msvc'; zig = '0.15.2'; dirty = 'false'; filtered = 'false' }
$ranEnv = [ordered]@{ 'cwd-on-temp-drive' = 'true'; 'font:Arial Unicode MS' = 'absent'; 'env:NOCTTY_RUN_LOCAL_PATH_SWEEP' = 'unset' }
function New-RanBuild {
    param([System.Collections.IDictionary] $Change)
    $b = [ordered]@{}
    foreach ($k in $ranBuild.Keys) { $b[$k] = $ranBuild[$k] }
    foreach ($k in $Change.Keys) { $b[$k] = $Change[$k] }
    return $b
}
function New-RanEnv {
    param([System.Collections.IDictionary] $Change)
    $e = [ordered]@{}
    foreach ($k in $ranEnv.Keys) { $e[$k] = $ranEnv[$k] }
    foreach ($k in $Change.Keys) { $e[$k] = $Change[$k] }
    return $e
}
# Suites: @{ Name; Tests = @(@(name, result), ...); Exit; Leaked; ErrorsLogged; Panics }; or one suite through -Tests.
function New-RanListFile {
    param([string] $Name, [object[]] $Tests, [System.Collections.IDictionary] $Build = $ranBuild, [System.Collections.IDictionary] $Environment = $ranEnv, [string] $SuiteName = 'ghostty-test', [string] $Exit = '0', [int] $Leaked = 0, [int] $ErrorsLogged = 0, [int] $Panics = 0, [object[]] $Suites = $null)
    if ($null -eq $Suites) { $Suites = @(@{ Name = $SuiteName; Tests = $Tests; Exit = $Exit; Leaked = $Leaked; ErrorsLogged = $ErrorsLogged; Panics = $Panics }) }
    $allRows = @(); $records = @()
    foreach ($s in $Suites) {
        $parsed = @($s.Tests | ForEach-Object { [pscustomobject]@{ Name = $_[0]; Result = $_[1] } })
        $allRows += @(Get-RanListRows -SuiteName $s.Name -Tests $parsed)
        $records += [pscustomobject]@{
            Name = $s.Name; Tests = $parsed.Count
            Ok = @($parsed | Where-Object Result -ceq 'OK').Count; Skip = @($parsed | Where-Object Result -ceq 'SKIP').Count; Fail = @($parsed | Where-Object Result -ceq 'FAIL').Count
            Exit = $(if ($null -ne $s.Exit) { $s.Exit } else { '0' }); ErrorsLogged = [int]$s.ErrorsLogged; Leaked = [int]$s.Leaked; Panics = [int]$s.Panics
        }
    }
    $path = Join-Path $ranTemp $Name
    [System.IO.File]::WriteAllText($path, (Format-RanList -Rows $allRows -Suites $records -Revision 'r1' -Build $Build -Environment $Environment), [System.Text.UTF8Encoding]::new($false))
    return $path
}
function New-RanLedger {
    param([string] $Name, [string[]] $Lines)
    $path = Join-Path $ranTemp $Name
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    return $path
}
function New-RanRecord {
    param([string] $Name, [string[]] $Lines, [switch] $NoLineEnd)
    $path = Join-Path $ranTemp "$Name.results.txt"
    $text = ($Lines -join "`n") + $(if ($NoLineEnd) { '' } else { "`n" })
    [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::Latin1.GetBytes($text))
    return $path
}
function Get-RanVerdict {
    param([string[]] $Baselines, [string] $Later, [string[]] $RemovalFiles = @(), [string[]] $SkipFiles = @(), [switch] $AllowFiltered, [switch] $AllowDirty, [string] $Crossing = '')
    $ledgerProblems = [Collections.Generic.List[string]]::new()
    $removed = Read-RanListLedger -Paths $RemovalFiles -Kind 'removals' -Problems $ledgerProblems
    $approved = Read-RanListLedger -Paths $SkipFiles -Kind 'approved skips' -Problems $ledgerProblems
    $v = Compare-RanList -BaselineLists @($Baselines | ForEach-Object { Read-RanList -Path $_ }) -CandidateList (Read-RanList -Path $Later) -RemovalEntries $removed -SkipEntries $approved -AllowFilteredBaseline:$AllowFiltered -AllowDirty:$AllowDirty -CompilerCrossing $Crossing
    return [pscustomobject]@{ Problems = @($ledgerProblems) + @($v.Problems); Notes = $v.Notes }
}
$ranSavedLocation = Get-Location
$ranSavedDirectory = [Environment]::CurrentDirectory
try {
    # A record that does not stand for a whole run fails the capture.
    $ranHead = @('noctty test results v1', 'zig 0.15.2', 'mode Debug', 'shard 1/1')
    $ranT1 = 'test 1 OK 0 612e746573742e6f6e65'
    $ranT2 = 'test 2 SKIP 0 612e746573742e74776f'
    $ranEndLine = 'end tests=2 ok=1 skip=1 fail=0 leaked=0 errors-logged=0'
    $ranRecord = Read-ZigTestResults -Path (New-RanRecord 'whole' ($ranHead + @($ranT1, $ranT2, $ranEndLine)))
    Assert-True ($ranRecord.Problems.Count -eq 0 -and (Get-RanResults $ranRecord) -ceq 'a.test.one=OK|a.test.two=SKIP') 'A whole record reads.'
    foreach ($ranCase in @(
            @{ Name = 'no-end'; Lines = $ranHead + @($ranT1, $ranT2); Expect = '*no end line, so the run stopped after test 2*' }
            @{ Name = 'cut'; Lines = $ranHead + @($ranT1, $ranT2, $ranEndLine); NoLineEnd = $true; Expect = '*does not end in a line end*' }
            @{ Name = 'order'; Lines = $ranHead + @($ranT2, $ranT1, $ranEndLine); Expect = '*is test 2, not test 1*' }
            @{ Name = 'gap'; Lines = $ranHead + @($ranT1, ($ranT2 -replace '^test 2', 'test 3'), $ranEndLine); Expect = '*is test 3, not test 2*' }
            @{ Name = 'count'; Lines = $ranHead + @($ranT1, $ranT2, ($ranEndLine -replace 'tests=2', 'tests=3')); Expect = '*does not add up*' }
            @{ Name = 'results'; Lines = $ranHead + @($ranT1, $ranT2, ($ranEndLine -replace 'ok=1 skip=1', 'ok=2 skip=0')); Expect = '*does not add up*' }
            @{ Name = 'leaks'; Lines = $ranHead + @($ranT1, $ranT2, ($ranEndLine -replace 'leaked=0', 'leaked=1')); Expect = '*does not add up*' }
            @{ Name = 'upper'; Lines = $ranHead + @(($ranT1 -replace '6e65$', '6E65'), $ranT2, $ranEndLine); Expect = '*line 5 is not a test or end line*' }
            @{ Name = 'odd'; Lines = $ranHead + @(($ranT1 + '6'), $ranT2, $ranEndLine); Expect = '*line 5 is not a test or end line*' }
            @{ Name = 'empty-name'; Lines = $ranHead + @('test 1 OK 0 ', $ranT2, $ranEndLine); Expect = '*line 5 is not a test or end line*' }
            @{ Name = 'shard'; Lines = @('noctty test results v1', 'zig 0.15.2', 'mode Debug', 'shard 2/4', $ranT1, $ranT2, $ranEndLine); Expect = '*shard 2/4 of a run, not a whole run*' }
            @{ Name = 'header'; Lines = @('noctty test results v2', 'zig 0.15.2', 'mode Debug', 'shard 1/1', $ranT1, $ranT2, $ranEndLine); Expect = '*does not start with*' }
            @{ Name = 'after'; Lines = $ranHead + @($ranT1, $ranT2, $ranEndLine, $ranEndLine); Expect = '*text after its end line*' }
            @{ Name = 'crlf'; Lines = ((($ranHead + @($ranT1, $ranT2, $ranEndLine)) -join "`r`n") -split "`n"); Expect = '*holds bytes the runner does not write*' }
            @{ Name = 'byte'; Lines = $ranHead + @($ranT1, $ranT2, ($ranEndLine + [char]0xFF)); Expect = '*holds bytes the runner does not write*' })) {
        $ranRecord = Read-ZigTestResults -Path (New-RanRecord $ranCase.Name $ranCase.Lines -NoLineEnd:([bool]$ranCase.NoLineEnd))
        Assert-True (($ranRecord.Problems -join ' ') -like $ranCase.Expect) "A record '$($ranCase.Name)' is refused ($($ranRecord.Problems -join ' | '))."
    }
    Assert-True ((Read-ZigTestResults -Path (Join-Path $ranTemp 'none.results.txt')).Problems -join ' ' -like '*no results file*') 'A run that wrote no record is refused (the stock runner takes no --results).'
    # A one-face collection built from the TrueType font: `ttcf`, version 1.0, one
    # face at 16, then the font with its table offsets moved by 16.
    $ranTtf = [System.IO.File]::ReadAllBytes($ranJet)
    $ranTtc = [byte[]]::new($ranTtf.Length + 16)
    [System.Text.Encoding]::ASCII.GetBytes('ttcf').CopyTo($ranTtc, 0)
    $ranTtc[5] = 1; $ranTtc[11] = 1; $ranTtc[15] = 16
    [Array]::Copy($ranTtf, 0, $ranTtc, 16, $ranTtf.Length)
    for ($i = 0; $i -lt (([int]$ranTtf[4] -shl 8) -bor $ranTtf[5]); $i++) {
        $at = 16 + 12 + 16 * $i + 8
        [long] $ranOffset = 16
        for ($k = 0; $k -lt 4; $k++) { $ranOffset += [long]$ranTtc[$at + $k] -shl (8 * (3 - $k)) }
        for ($k = 0; $k -lt 4; $k++) { $ranTtc[$at + $k] = [byte](($ranOffset -shr (8 * (3 - $k))) -band 0xFF) }
    }
    $ranTtcPath = Join-Path $ranTemp 'one.ttc'
    [System.IO.File]::WriteAllBytes($ranTtcPath, $ranTtc)
    $ranJunk = Join-Path $ranTemp 'junk.ttf'
    [System.IO.File]::WriteAllBytes($ranJunk, [byte[]] @(1..64))
    $ranCut = Join-Path $ranTemp 'cut.ttf'
    [System.IO.File]::WriteAllBytes($ranCut, [byte[]] $ranTtf[0..199])
    Assert-True ((Get-RanListFontFamilies -Path $ranTtcPath) -contains 'JetBrains Mono' -and $null -eq (Get-RanListFontFamilies -Path $ranJunk) -and $null -eq (Get-RanListFontFamilies -Path $ranCut)) 'A collection reads its faces'' families; a file that is no font, or is cut short, reads as unknown.'
    $ranFontDir = New-Item -ItemType Directory -Path (Join-Path $ranTemp 'fonts')
    foreach ($n in 'a.ttf', 'b.TTF', 'c.otc', 'd.fon', 'e.txt') { [System.IO.File]::WriteAllBytes((Join-Path $ranFontDir $n), [byte[]] @(0)) }
    New-Item -ItemType Directory -Path (Join-Path $ranFontDir 'f.ttf') | Out-Null
    $ranUnregistered = @(foreach ($p in (Get-RanListUnregisteredFontFiles -RegisteredPaths @((Join-Path $ranFontDir 'A.TTF')) -Directories @($ranFontDir.FullName, (Join-Path $ranTemp 'no-such-dir')))) { Split-Path -Leaf $p }) | Sort-Object
    Assert-True (($ranUnregistered -join '|') -ceq 'b.TTF|c.otc') "The font scan takes the files discovery takes, less those the registry names: $($ranUnregistered -join '|')"

    $ranBaseTests = @(@('a.test.one', 'OK'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    $ranBase = New-RanListFile 'base.tsv' $ranBaseTests
    $ranSkips = New-RanLedger 'skips.tsv' @('# suite, name, requires, reason', "ghostty-test`ta.test.font`tfont:Arial Unicode MS=absent`tneeds the font")
    $ranText = [System.IO.File]::ReadAllText($ranBase)
    Assert-True ($ranText -cmatch "(?s)ghostty-test`tOK`t1`tB\.test\.upper\n.*ghostty-test`tOK`t1`ta\.test\.one\n" -and $ranText.EndsWith("# end: rows=7 tests=7`n") -and -not $ranText.Contains("`r") -and $ranText -cmatch '(?m)^# env: cwd-on-temp-drive=true$' -and $ranText -cmatch "(?m)^# build: source=built`toptions=\(none\)`t" -and $ranText.StartsWith("# noctty test ran list v4`n")) 'A list is sorted ordinally, LF-terminated, closed by its end line, and records its build and environment.'
    $ranRead = Read-RanList -Path $ranBase
    Assert-True ($ranRead.Problems.Count -eq 0 -and $ranRead.Rows.Count -eq 7 -and $ranRead.Build['zig'] -ceq '0.15.2' -and $ranRead.Environment['font:Arial Unicode MS'] -ceq 'absent') 'A written list reads back whole.'

    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranBase -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join "`n") -like '*APPROVED-SKIP ghostty-test a.test.font: needs the font*') 'Control: the same list passes when its skip is approved.'
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranBase
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -ceq 'UNAPPROVED-SKIP ghostty-test a.test.font (1 skipped, 0 approved)') 'Control: a test skipped in the baseline and skipped again fails without an approval (PLAN.md §3.2: OK or an approved SKIP).'
    $ranPresent = New-RanListFile 'font-present.tsv' $ranBaseTests -Environment (New-RanEnv @{ 'font:Arial Unicode MS' = 'present' })
    $v = Get-RanVerdict -Baselines @($ranPresent) -Later $ranPresent -SkipFiles @($ranSkips)
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -like "SKIP-ENVIRONMENT ghostty-test a.test.font (1 skipped, 0 of 1 approvals apply): needs font:Arial Unicode MS=absent (the list has 'present')*") 'An approval that names an environment does not cover a list taken in another.'
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranPresent -SkipFiles @($ranSkips)
    Assert-True (($v.Problems -join "`n") -like '*ENV-DIFFERS font:Arial Unicode MS*') 'Lists taken in different environments are not compared.'
    # Fact keys are ordinal too (council round 4 on #726, Sol L1): a key spelled with
    # another case, or with a control character, is a key the other list lacks.
    $ranUpper = Join-Path $ranTemp 'upper-key.tsv'
    [System.IO.File]::WriteAllText($ranUpper, ($ranText -creplace '# env: cwd-on-temp-drive=', '# env: CWD-ON-TEMP-DRIVE='), [System.Text.UTF8Encoding]::new($false))
    $ranExtra = Join-Path $ranTemp 'esc-key.tsv'
    [System.IO.File]::WriteAllText($ranExtra, ($ranText -creplace '(# env: cwd-on-temp-drive=true\n)', "`$1# env: cwd-on-temp-driv$([char]27)e=false`n"), [System.Text.UTF8Encoding]::new($false))
    foreach ($ranCase in @(@{ Name = 'a key in capitals'; Path = $ranUpper; Expect = '*ENV-DIFFERS CWD-ON-TEMP-DRIVE*' }, @{ Name = 'an extra key holding ESC'; Path = $ranExtra; Expect = "*ENV-DIFFERS cwd-on-temp-driv$([char]27)e*" })) {
        Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranCase.Path -SkipFiles @($ranSkips)).Problems -join ' ') -like $ranCase.Expect) "A list with $($ranCase.Name) differs in its environment."
        $ranCrossedKey = Join-Path $ranTemp "crossed-$([IO.Path]::GetFileName($ranCase.Path))"
        [System.IO.File]::WriteAllText($ranCrossedKey, ([System.IO.File]::ReadAllText($ranCase.Path) -creplace 'mode=Debug', 'mode=debug' -creplace 'zig=0\.15\.2', 'zig=0.17.1'), [System.Text.UTF8Encoding]::new($false))
        Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranCrossedKey -SkipFiles @($ranSkips) -Crossing '0.15.2=0.17.1').Problems -join ' ') -like $ranCase.Expect) "Across the crossing a list with $($ranCase.Name) differs in its environment."
    }
    # An approval may also name the build: one for 1A's ReleaseSafe list does not cover the Debug list.
    $ranBuildSkips = New-RanLedger 'build-skips.tsv' @("ghostty-test`ta.test.font`tbuild:mode=ReleaseSafe`tskips in ReleaseSafe only")
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranBase -SkipFiles @($ranBuildSkips)
    Assert-True ($v.Problems.Count -eq 1 -and $v.Problems[0] -like "SKIP-ENVIRONMENT*needs build:mode=ReleaseSafe (the list has 'Debug')*") 'An approval that names a build does not cover another build of the same suite.'
    $ranSafe = New-RanListFile 'safe.tsv' $ranBaseTests -Build (New-RanBuild @{ mode = 'safe'; zig = '0.17.1' })
    Assert-True ((Get-RanVerdict -Baselines @($ranSafe) -Later $ranSafe -SkipFiles @($ranBuildSkips)).Problems.Count -eq 0) 'A build condition on the mode matches by meaning (safe is ReleaseSafe).'
    # Only the approvals whose conditions hold count for a block (CodeRabbit on #726).
    $ranTwoConditions = New-RanLedger 'two-conditions.tsv' @("ghostty-test`tc.test_0`tfont:Arial Unicode MS=present`tone", "ghostty-test`tc.test_1`tfont:Arial Unicode MS=absent`ttwo")
    $ranUnnamedSkip = New-RanListFile 'unnamed-skip.tsv' @(@('c.test_0', 'SKIP'), @('c.test_1', 'OK'))
    Assert-True ((Get-RanVerdict -Baselines @($ranUnnamedSkip) -Later $ranUnnamedSkip -SkipFiles @($ranTwoConditions)).Problems.Count -eq 0) 'One skipped block passes when one of its container''s approvals applies, whatever the other needs.'
    # `unknown` meets no condition, and no condition may name it (council round 3, Sol).
    $ranUnknownSkip = New-RanLedger 'unknown-skip.tsv' @("ghostty-test`ta.test.font`tenv:NOCTTY_RUN_LOCAL_PATH_SWEEP=unknown`tasks for what was not measured")
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranBase -SkipFiles @($ranUnknownSkip)).Problems -join ' ' -like "*line 1 is not*no condition on 'unknown'*") 'A ledger condition on unknown is refused.'
    $ranUnknownList = Read-RanList -Path (New-RanListFile 'unknown-env.tsv' $ranBaseTests -Environment (New-RanEnv @{ 'env:NOCTTY_RUN_LOCAL_PATH_SWEEP' = 'unknown' }))
    $ranEntry = [pscustomobject]@{ Reason = 'r'; Requires = @('env:NOCTTY_RUN_LOCAL_PATH_SWEEP=unknown') }
    Assert-True ((Get-RanListUnmetConditions -Entry $ranEntry -List $ranUnknownList).Count -eq 1) 'An unknown fact meets no condition, not even one that names unknown.'

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
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranTurned -SkipFiles @($ranSkips, $ranSkipsMore)).Problems.Count -eq 0) 'An approved SKIP passes, and several approval files are merged.'
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
    # One suite record per suite, matching its rows (CodeRabbit on #726).
    $ranNoSuite = Join-Path $ranTemp 'no-suite.tsv'
    [System.IO.File]::WriteAllText($ranNoSuite, ($ranText -replace '(?m)^# suite: .*\n', ''), [System.Text.UTF8Encoding]::new($false))
    Assert-True ((Get-RanVerdict -Baselines @($ranNoSuite) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ' -like '*rows for suite ghostty-test but no suite record*') 'Rows without their suite record are refused: the run cannot be shown green.'
    $ranBadCount = Join-Path $ranTemp 'bad-count.tsv'
    [System.IO.File]::WriteAllText($ranBadCount, ($ranText -replace 'ok=6 skip=1', 'ok=7 skip=0'), [System.Text.UTF8Encoding]::new($false))
    Assert-True ((Get-RanVerdict -Baselines @($ranBadCount) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ' -like '*record*does not match its rows*') 'A suite record whose counts are not its rows'' is refused.'
    # Suites whose names differ only by case (council round 3, Sol and Opus L2): a
    # green `Unit` and a leaking `unit`, in either order.
    foreach ($ranPair in @(@('Unit', 'unit'), @('unit', 'Unit'))) {
        $ranCaseList = New-RanListFile "case-$($ranPair[0]).tsv" -Suites @(
            @{ Name = $ranPair[0]; Tests = @(, @('a.test.one', 'OK')) }
            @{ Name = $ranPair[1]; Tests = @(, @('a.test.two', 'OK')); Exit = '1'; Leaked = 1; ErrorsLogged = 1 })
        $v = Get-RanVerdict -Baselines @($ranCaseList) -Later $ranCaseList
        Assert-True (($v.Problems -join ' ') -like '*differ only by case*' -and ($v.Problems -join ' ') -like "*suite $($ranPair[1]) is not green*") "Suites $($ranPair[0]) and $($ranPair[1]) are refused, and the leaking one is seen ($($v.Problems -join ' | '))."
    }

    # Each green condition on its own, with exit 0 (council round 2 on #726, Opus L2).
    $ranFailing = New-RanListFile 'failing.tsv' @(@('a.test.one', 'FAIL'), @('a.test.two', 'OK'), @('a.test.font', 'SKIP'), @('b.test_0', 'OK'), @('b.test_1', 'OK'), @('b.test_2', 'OK'), @('B.test.upper', 'OK'))
    foreach ($ranCase in @(
            @{ Name = 'a FAIL'; Path = $ranFailing }
            @{ Name = 'exit 1'; Path = (New-RanListFile 'exit1.tsv' $ranBaseTests -Exit '1') }
            @{ Name = 'a leak'; Path = (New-RanListFile 'leaky.tsv' $ranBaseTests -Leaked 1) }
            @{ Name = 'a logged error'; Path = (New-RanListFile 'logged.tsv' $ranBaseTests -ErrorsLogged 1) })) {
        Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later $ranCase.Path -SkipFiles @($ranSkips)).Problems -join ' ' -like '*not green*') "A later list with only $($ranCase.Name) wrong is not green."
        Assert-True ((Get-RanVerdict -Baselines @($ranCase.Path) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ' -like '*not green*') "A baseline with only $($ranCase.Name) wrong is refused."
    }
    Assert-True ((Get-RanVerdict -Baselines @($ranBase) -Later (New-RanListFile 'panicky.tsv' $ranBaseTests -Panics 1) -SkipFiles @($ranSkips)).Problems.Count -eq 0) 'A list whose only blemish is panic-shaped log lines is green: a test can print them (bot threads on #726).'
    foreach ($ranCase in @(@{ Suite = [pscustomobject]@{ Exit = 0; Fail = 0; ErrorsLogged = 0; Leaked = 0; Panics = 0 }; Green = $true }
            @{ Suite = [pscustomobject]@{ Exit = 0; Fail = 0; ErrorsLogged = 1; Leaked = 0; Panics = 0 }; Green = $false }
            @{ Suite = [pscustomobject]@{ Exit = 0; Fail = 0; ErrorsLogged = 0; Leaked = 1; Panics = 0 }; Green = $false }
            @{ Suite = [pscustomobject]@{ Exit = 0; Fail = 0; ErrorsLogged = 0; Leaked = 0; Panics = 1 }; Green = $true }
            @{ Suite = [pscustomobject]@{ Exit = 0; Fail = 1; ErrorsLogged = 0; Leaked = 0; Panics = 0 }; Green = $false }
            @{ Suite = [pscustomobject]@{ Exit = 3; Fail = 0; ErrorsLogged = 0; Leaked = 0; Panics = 0 }; Green = $false })) {
        Assert-True ((Test-RanListSuiteGreen $ranCase.Suite) -eq $ranCase.Green) "The capture's green check holds each condition on its own ($($ranCase.Suite | ConvertTo-Json -Compress))."
    }

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
    $ranMultiA = New-RanListFile 'multi-a.tsv' @(, @('x.test.coverage...\nfirst', 'OK'))
    $ranMultiB = New-RanListFile 'multi-b.tsv' @(, @('x.test.coverage...\nsecond', 'OK'))
    Assert-True (((Get-RanVerdict -Baselines @($ranMultiA) -Later $ranMultiB).Problems -join ' ') -ceq 'DROPPED ghostty-test x.test.coverage...\nfirst (ran 1 in the baseline, 0 now)') 'Two names that differ only after a newline are two identities (council round 2, Sol M3).'
    # The native fixture's two names that differ only in a byte that is not UTF-8 (council round 3, Sol).
    $ranBytes = @((Read-RanRecord 'bytes').Tests)
    $ranFe = New-RanListFile 'bytes-fe.tsv' @(, @($ranBytes[0].Name, 'OK'))
    $ranFf = New-RanListFile 'bytes-ff.tsv' @(, @($ranBytes[1].Name, 'OK'))
    Assert-True (((Get-RanVerdict -Baselines @($ranFe) -Later $ranFf).Problems -join ' ') -ceq 'DROPPED ghostty-test bytes.test.coverage\xfe (ran 1 in the baseline, 0 now)') 'A test whose name ends in byte FE replaced by one ending in FF is a drop.'

    # Build identity: options, compiler and the planned crossing (council round 2, Sol M1 and Opus M1).
    $ranOtherBuild = New-RanListFile 'other-build.tsv' $ranBaseTests -Build (New-RanBuild @{ options = '-Dcustom-shaders=true' })
    # `source` compares by class (council round 4 on #726, Sol L4): declared and imported are one.
    $ranDeclaredSource = New-RanListFile 'declared-source.tsv' $ranBaseTests -Build (New-RanBuild @{ source = 'declared' })
    $ranImportedSource = New-RanListFile 'imported-source.tsv' $ranBaseTests -Build (New-RanBuild @{ source = 'imported' })
    $ranImportedCrossed = New-RanListFile 'imported-crossed.tsv' $ranBaseTests -Build (New-RanBuild @{ source = 'imported'; zig = '0.17.1'; mode = 'debug' })
    Assert-True ((Get-RanVerdict -Baselines @($ranDeclaredSource) -Later $ranImportedSource -SkipFiles @($ranSkips)).Problems.Count -eq 0 -and (Get-RanVerdict -Baselines @($ranDeclaredSource) -Later $ranImportedCrossed -SkipFiles @($ranSkips) -Crossing '0.15.2=0.17.1').Problems.Count -eq 0) 'A declared executable''s list and an imported run''s are one source class, with or without the crossing.'
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranImportedSource -SkipFiles @($ranSkips)).Problems -join ' ') -like '*BUILD-DIFFERS source*') 'A built list and an imported one are not.'
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranOtherBuild -SkipFiles @($ranSkips)).Problems -join ' ') -like 'BUILD-DIFFERS options*') 'Lists built with different options are not compared.'
    $ranZig17 = New-RanListFile 'zig17.tsv' $ranBaseTests -Build (New-RanBuild @{ zig = '0.17.1'; mode = 'debug' })
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranZig17 -SkipFiles @($ranSkips)
    Assert-True ((($v.Problems -join ' ') -like '*BUILD-DIFFERS zig*declare -CompilerCrossing*') -and (($v.Problems -join ' ') -like '*BUILD-DIFFERS mode*')) 'A 0.15.2 baseline and a 0.17.1 list are not compared without a declared crossing.'
    $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranZig17 -SkipFiles @($ranSkips) -Crossing '0.15.2=0.17.1'
    Assert-True ($v.Problems.Count -eq 0 -and ($v.Notes -join ' ') -like '*COMPILER-CROSSING 0.15.2 -> 0.17.1: 1 baseline(s)*') 'With the crossing declared they are, mode by meaning, and the verdict names the crossing.'
    Assert-True (((Get-RanVerdict -Baselines @($ranZig17) -Later $ranBase -SkipFiles @($ranSkips) -Crossing '0.15.2=0.17.1').Problems -join ' ') -like '*BUILD-DIFFERS zig*declared crossing is 0.15.2=0.17.1*') 'A crossing is one way: 0.17.1 baselines are not compared with a 0.15.2 list.'
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranZig17 -SkipFiles @($ranSkips) -Crossing '0.15.2').Problems -join ' ') -like "*-CompilerCrossing '0.15.2' is not*") 'A malformed crossing is refused.'
    # Across the crossing only the compiler may differ, and the mode only in its spelling
    # (council round 3, Opus L3): each other key and each fact, one at a time.
    foreach ($ranCase in @(
            @{ Key = 'mode'; Build = @{ mode = 'safe' }; Expect = '*BUILD-DIFFERS mode*' }
            @{ Key = 'options'; Build = @{ options = '-Dcustom-shaders=true' }; Expect = '*BUILD-DIFFERS options*' }
            @{ Key = 'target'; Build = @{ target = 'aarch64-windows.win10_rs5-msvc' }; Expect = '*BUILD-DIFFERS target*' }
            @{ Key = 'source'; Build = @{ source = 'declared' }; Expect = '*BUILD-DIFFERS source*' }
            @{ Key = 'filtered'; Build = @{ filtered = 'true' }; Expect = '*BUILD-DIFFERS filtered*' }
            @{ Key = 'an environment fact'; Env = @{ 'font:Arial Unicode MS' = 'present' }; Expect = '*ENV-DIFFERS font:Arial Unicode MS*' })) {
        $ranChange = @{ zig = '0.17.1'; mode = 'debug' }
        if ($ranCase.Build) { foreach ($k in $ranCase.Build.Keys) { $ranChange[$k] = $ranCase.Build[$k] } }
        $ranEnvChange = if ($ranCase.Env) { New-RanEnv $ranCase.Env } else { $ranEnv }
        $ranCrossed = New-RanListFile "crossed-$($ranCase.Key -replace '\W', '-').tsv" $ranBaseTests -Build (New-RanBuild $ranChange) -Environment $ranEnvChange
        $v = Get-RanVerdict -Baselines @($ranBase) -Later $ranCrossed -SkipFiles @($ranSkips) -Crossing '0.15.2=0.17.1'
        Assert-True ((($v.Problems -join ' ') -like $ranCase.Expect) -and ($v.Problems -join ' ') -notlike '*BUILD-DIFFERS zig*') "Across the crossing a list that differs in $($ranCase.Key) still fails ($($v.Problems -join ' | '))."
    }
    # Values read from a list compare ordinally: pwsh 7.6's -ceq ignores a control
    # character (common brief, PWSH-CEQ-ICU), so `<ESC>0` would equal `0`.
    $ranEsc = [string][char]27
    Assert-True (-not (Test-RanListSame "${ranEsc}A" 'A') -and -not (Test-RanListSame (Get-RanListModeMeaning "${ranEsc}Debug") 'debug')) 'Values and modes compare ordinally, control characters included.'
    $ranEscOptions = New-RanListFile 'esc-options.tsv' $ranBaseTests -Build (New-RanBuild @{ options = "(none)$ranEsc" })
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranEscOptions -SkipFiles @($ranSkips)).Problems -join ' ') -like '*BUILD-DIFFERS options*') 'Options that differ only by a control character are not the same build.'
    $ranEscFact = New-RanListFile 'esc-fact.tsv' $ranBaseTests -Environment (New-RanEnv @{ 'cwd-on-temp-drive' = "true$ranEsc" })
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranEscFact -SkipFiles @($ranSkips)).Problems -join ' ') -like '*ENV-DIFFERS cwd-on-temp-drive*') 'Facts that differ only by a control character differ.'
    $ranEscExit = Join-Path $ranTemp 'esc-exit.tsv'
    [System.IO.File]::WriteAllText($ranEscExit, ($ranText -replace 'exit=0', "exit=${ranEsc}0"), [System.Text.UTF8Encoding]::new($false))
    Assert-True (((Get-RanVerdict -Baselines @($ranEscExit) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ') -like '*is not a suite record*') 'A suite record whose exit is not a number is refused, not read as green.'
    # [0-9], not \d: .NET's \d matches every script's digits, and pwsh's -ceq takes
    # U+0660 for 0 (council round 4 on #726, Opus L1).
    foreach ($ranDigit in [char]0x0660, [char]0x0966) {
        $ranDigitExit = Join-Path $ranTemp "digit-exit-$([int]$ranDigit).tsv"
        [System.IO.File]::WriteAllText($ranDigitExit, ($ranText -replace 'exit=0', "exit=$ranDigit"), [System.Text.UTF8Encoding]::new($false))
        Assert-True (((Get-RanVerdict -Baselines @($ranDigitExit) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ') -like '*is not a suite record*') "A suite record whose exit is the digit U+$('{0:X4}' -f [int]$ranDigit) is refused, not read as green."
    }
    $ranDigitCount = Join-Path $ranTemp 'digit-count.tsv'
    [System.IO.File]::WriteAllText($ranDigitCount, ($ranText -creplace "ghostty-test`tOK`t1`ta\.test\.two", "ghostty-test`tOK`t1$([char]0x0661)`ta.test.two"), [System.Text.UTF8Encoding]::new($false))
    Assert-True (((Get-RanVerdict -Baselines @($ranDigitCount) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ') -like "*is not '<suite><TAB><OK|SKIP|FAIL><TAB><count>*") 'A row whose count is a non-ASCII digit is refused.'
    $ranEscResult = Join-Path $ranTemp 'esc-result.tsv'
    [System.IO.File]::WriteAllText($ranEscResult, ($ranText -replace "ghostty-test`tOK`t1`ta\.test\.two", "ghostty-test`t${ranEsc}OK`t1`ta.test.two"), [System.Text.UTF8Encoding]::new($false))
    Assert-True (((Get-RanVerdict -Baselines @($ranEscResult) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ') -like "*is not '<suite><TAB><OK|SKIP|FAIL>*") 'A row whose result is not exactly OK, SKIP or FAIL is refused.'
    $ranUnknown = New-RanListFile 'unknown-build.tsv' $ranBaseTests -Build ([ordered]@{ source = 'declared'; options = 'unknown'; zig = 'unknown'; filtered = 'false' })
    Assert-True (((Get-RanVerdict -Baselines @($ranUnknown) -Later $ranUnknown -SkipFiles @($ranSkips)).Problems -join ' ') -like '*records no real build options*') 'A list whose build is unknown is refused.'
    $ranNoMode = New-RanListFile 'no-mode.tsv' $ranBaseTests -Build ([ordered]@{ source = 'declared'; options = '(none)'; zig = '0.15.2'; filtered = 'false' })
    Assert-True (((Get-RanVerdict -Baselines @($ranNoMode) -Later $ranNoMode -SkipFiles @($ranSkips)).Problems -join ' ') -like '*records no real build mode*') 'A list that names no mode is refused (the record always names one).'
    $ranFiltered = New-RanListFile 'filtered.tsv' $ranBaseTests -Build (New-RanBuild @{ options = '-Dtest-filter=resize_replay'; filtered = 'true' })
    Assert-True (((Get-RanVerdict -Baselines @($ranFiltered) -Later $ranFiltered -SkipFiles @($ranSkips)).Problems -join ' ') -like '*filtered build*no baseline*') 'A filtered list is no baseline.'
    Assert-True ((Get-RanVerdict -Baselines @($ranFiltered) -Later $ranFiltered -SkipFiles @($ranSkips) -AllowFiltered).Problems.Count -eq 0) 'A filtered list can be the baseline of a control when that is asked for.'
    $ranDirty = New-RanListFile 'dirty.tsv' $ranBaseTests -Build (New-RanBuild @{ dirty = 'true' })
    Assert-True (((Get-RanVerdict -Baselines @($ranDirty) -Later $ranBase -SkipFiles @($ranSkips)).Problems -join ' ') -like '*dirty=true*') 'A baseline from a checkout with tracked changes is refused (council round 2, Opus L3).'
    Assert-True (((Get-RanVerdict -Baselines @($ranBase) -Later $ranDirty -SkipFiles @($ranSkips)).Problems -join ' ') -like '*dirty=true*') 'So is a later list from one.'
    Assert-True ((Get-RanVerdict -Baselines @($ranDirty) -Later $ranDirty -SkipFiles @($ranSkips) -AllowDirty).Problems.Count -eq 0) 'A dirty list can be compared in a control when that is asked for.'

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
        @{ Name = 'compiler change, undeclared'; Args = @('-Baseline', $ranBase, '-Candidate', $ranZig17, '-ApprovedSkips', $ranSkips); Exit = 1 }
        @{ Name = 'compiler change, declared'; Args = @('-Baseline', $ranBase, '-Candidate', $ranZig17, '-ApprovedSkips', $ranSkips, '-CompilerCrossing', '0.15.2=0.17.1'); Exit = 0 }
    )
    foreach ($case in $ranCases) {
        $output = & pwsh -NoProfile -NonInteractive -File $ranCompare @($case.Args) 2>&1
        Assert-True ($LASTEXITCODE -eq $case.Exit) "Ran list compare, $($case.Name): expected exit $($case.Exit), got $LASTEXITCODE ($($output -join ' | '))."
    }

    # The capture's own command line on native fixture runs, imported: each
    # run's stderr, its record and its exit code.
    $ranExits = @{}
    foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $ranFixtures 'exit-codes.tsv'))) { if ($l -match "^([\w.-]+)`t(-?\d+)$") { $ranExits[$Matches[1]] = $Matches[2] } }
    function Invoke-RanImport {
        param([string] $Fixture, [string] $Out, [string] $Exit = $ranExits[$Fixture], [string] $Stderr = (Join-Path $ranFixtures "$Fixture.stderr.txt"), [string] $Results = (Join-Path $ranFixtures "$Fixture.results.txt"), [string[]] $More = @())
        return & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog $Stderr -TestResults $Results -TestLogExitCode $Exit -Suite fixture -Revision r1 -BuildOptions none -OutFile $Out @More 2>&1
    }
    $ranPanicLog = Join-Path $ranTemp 'panic.stderr.txt'
    [System.IO.File]::WriteAllLines($ranPanicLog, @(Read-RanFixture 'names') + @('thread 4 panic: reached after the end line'))
    $ranPrintedTrailers = Join-Path $ranTemp 'printed-trailers.stderr.txt'
    [System.IO.File]::WriteAllLines($ranPrintedTrailers, @('1/7 names.test.wait...', '1 errors were logged.', '1 tests leaked memory.', 'panic: a sample the test prints', 'OK') + @(Read-RanFixture 'names' | Select-Object -Skip 1))
    $ranCaptureCases = @(
        @{ Name = 'printed'; Exit = 0; Wrote = $true }
        @{ Name = 'forge'; Exit = 0; Wrote = $true }
        @{ Name = 'bytes'; Exit = 0; Wrote = $true }
        @{ Name = 'leak'; Exit = 1; Wrote = $true }
        @{ Name = 'leak'; ExitCode = '0'; Exit = 1; Wrote = $true; Note = ' with exit 0' }
        @{ Name = 'logged_error'; ExitCode = '0'; Exit = 1; Wrote = $true; Note = ' with exit 0' }
        @{ Name = 'leak'; Stderr = (Join-Path $ranFixtures 'names.stderr.txt'); Exit = 1; Wrote = $true; Note = ' with a log that prints no trailer: the record''s leak still fails it' }
        @{ Name = 'names'; Stderr = $ranPanicLog; ExitCode = '0'; Exit = 0; Wrote = $true; Note = ' with a panic-shaped line in its log and exit 0: the record decides' }
        @{ Name = 'names'; Results = (New-RanRecord 'relabelled' (@([System.IO.File]::ReadAllLines((Join-Path $ranFixtures 'names.results.txt'))) -replace '^zig 0\.15\.2$', 'zig 0.17.1' -replace '^mode Debug$', 'mode safe')); Exit = 0; Wrote = $true; Note = ' from a record that names 0.17.1 and mode safe' }
        @{ Name = 'names'; Results = (New-RanRecord 'cut-names' ([System.IO.File]::ReadAllLines((Join-Path $ranFixtures 'names.results.txt')) | Select-Object -SkipLast 1)); Exit = 1; Wrote = $false; Note = ' with its record cut before the end line' }
        @{ Name = 'names'; Results = (Join-Path $ranTemp 'no-record.results.txt'); Exit = 1; Wrote = $false; Note = ' without its record' }
        @{ Name = 'names'; Stderr = $ranPrintedTrailers; ExitCode = '0'; Exit = 0; Wrote = $true; Note = ' whose test prints trailer- and panic-shaped lines (bot threads on #726)' }
        @{ Name = 'names'; Results = (New-RanRecord 'leak-only' @('noctty test results v1', 'zig 0.15.2', 'mode Debug', 'shard 1/1', 'test 1 OK 1 612e746573742e6f6e65', 'end tests=1 ok=1 skip=0 fail=0 leaked=1 errors-logged=0')); ExitCode = '0'; Exit = 1; Wrote = $true; Note = ' from a record that counts a leak and no logged error' }
        @{ Name = 'names'; Results = (New-RanRecord 'no-test' @('noctty test results v1', 'zig 0.15.2', 'mode Debug', 'shard 1/1', 'end tests=0 ok=0 skip=0 fail=0 leaked=0 errors-logged=0')); ExitCode = '0'; Exit = 1; Wrote = $false; Note = ' from a record that holds no test' }
    )
    $ranN = 0
    foreach ($case in $ranCaptureCases) {
        $ranN++
        $out = Join-Path $ranTemp "capture-$ranN-$($case.Name).tsv"
        $more = @{ Fixture = $case.Name; Out = $out }
        if ($case.ExitCode) { $more.Exit = $case.ExitCode }
        if ($case.Stderr) { $more.Stderr = $case.Stderr }
        if ($case.Results) { $more.Results = $case.Results }
        $output = Invoke-RanImport @more
        Assert-True ($LASTEXITCODE -eq $case.Exit -and (Test-Path -LiteralPath $out) -eq $case.Wrote) "Ran list capture of native fixture $($case.Name)$($case.Note): expected exit $($case.Exit) and a list $($case.Wrote), got $LASTEXITCODE and $(Test-Path -LiteralPath $out) ($($output -join ' | '))."
    }
    $ranPrinted = Join-Path $ranTemp 'capture-1-printed.tsv'
    $ranPrintedText = [System.IO.File]::ReadAllText($ranPrinted)
    Assert-True ($ranPrintedText -cmatch "(?m)^fixture`tSKIP`t1`tprinted\.test\.coverage$" -and $ranPrintedText -cmatch "(?m)^fixture`tOK`t1`tprinted\.test\.platform$" -and $ranPrintedText -cmatch '(?m)^# build: source=imported\toptions=\(none\)\tfiltered=false\tmode=Debug\tzig=0\.15\.2$') "The captured list holds the record's results, and the record's mode and compiler."
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $ranTemp 'capture-4-leak.tsv')) -cmatch '(?m)^# suite: fixture tests=2 ok=2 skip=0 fail=0 exit=1 errors-logged=1 leaked=1 panics=0$') 'A captured leak keeps its exit code and the record''s counts in the list.'
    Assert-True ((Get-RanVerdict -Baselines @((Join-Path $ranTemp 'capture-5-leak.tsv')) -Later (Join-Path $ranTemp 'capture-5-leak.tsv')).Problems -join ' ' -like '*not green (exit 0*1 leaked*') 'A leak with exit 0 is still not green.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $ranTemp 'capture-8-names.tsv')) -cmatch '(?m)^# suite: fixture tests=7 ok=7 skip=0 fail=0 exit=0 errors-logged=0 leaked=0 panics=1$') 'A panic line in the log is counted in the list.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $ranTemp 'capture-9-names.tsv')) -cmatch '(?m)^# build: source=imported\toptions=\(none\)\tfiltered=false\tmode=safe\tzig=0\.17\.1$') 'The list records the compiler and the mode its record names.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $ranTemp 'capture-7-leak.tsv')) -cmatch '(?m)^# suite: fixture tests=2 ok=2 skip=0 fail=0 exit=1 errors-logged=1 leaked=1 panics=0$') 'A run whose log prints no trailer keeps the record''s leak and logged error.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $ranTemp 'capture-12-names.tsv')) -cmatch '(?m)^# suite: fixture tests=7 ok=7 skip=0 fail=0 exit=0 errors-logged=0 leaked=0 panics=1$') 'A test''s printed trailers change no count; its panic-shaped line is only counted.'
    $output = Invoke-RanImport -Fixture 'names' -Out (Join-Path $ranTemp 'no-test-again.tsv') -Results (Join-Path $ranTemp 'no-test.results.txt') -Exit '0'
    Assert-True ((Join-RanOutput $output) -like '*fixture: the record holds no test*') "A suite that ran no test is refused at capture, by name (bot threads on #726): $(Join-RanOutput $output)"
    # Sol's false pass, end to end: the baseline ran coverage OK and skipped platform,
    # which alone is approved; the later run skips coverage while it prints OK.
    $ranSolBase = New-RanListFile 'sol-base.tsv' -Build ([ordered]@{ source = 'imported'; options = '(none)'; filtered = 'false'; mode = 'Debug'; zig = '0.15.2' }) -Environment (Read-RanList -Path $ranPrinted).Environment -Suites @(@{ Name = 'fixture'; Tests = @(@('printed.test.coverage', 'OK'), @('printed.test.platform', 'SKIP')) })
    $ranSolSkips = New-RanLedger 'sol-skips.tsv' @("fixture`tprinted.test.platform`t-`tthe platform skips")
    $v = Get-RanVerdict -Baselines @($ranSolBase) -Later $ranPrinted -SkipFiles @($ranSolSkips)
    Assert-True (($v.Problems -join ' ') -ceq 'UNAPPROVED-SKIP fixture printed.test.coverage (1 skipped, 0 approved)') "A test that skips while it prints OK fails as an unapproved skip (council round 3, Sol's High): $($v.Problems -join ' | ')"
    $ranForgeSkips = New-RanLedger 'forge-skips.tsv' @("fixture`tforge.test.second`t-`tthe second skips")
    Assert-True (((Get-RanVerdict -Baselines @((Join-Path $ranTemp 'capture-2-forge.tsv')) -Later (Join-Path $ranTemp 'capture-2-forge.tsv') -SkipFiles @($ranForgeSkips)).Problems -join ' ') -ceq 'UNAPPROVED-SKIP fixture forge.test.first (1 skipped, 0 approved)') 'A test that prints the next header skips under its own name (council round 3, Opus L1).'
    # Several inputs need a -Command call: `pwsh -File` hands `a,b` to the script as one value.
    function Invoke-RanCaptureCommand { param([string] $Arguments) return & pwsh -NoProfile -NonInteractive -Command "& '$ranCapture' $Arguments; exit `$LASTEXITCODE" 2>&1 }
    function Get-RanFixturePath { param([string] $Name) return "'$(Join-Path $ranFixtures $Name)'" }
    # Two suites whose labels differ only by case are refused at capture (council round 3, Sol and Opus L2).
    $output = Invoke-RanCaptureCommand "-TestLog $(Get-RanFixturePath 'names.stderr.txt'), $(Get-RanFixturePath 'leak.stderr.txt') -TestResults $(Get-RanFixturePath 'names.results.txt'), $(Get-RanFixturePath 'leak.results.txt') -TestLogExitCode 0, 1 -Suite Unit, unit -Revision r1 -BuildOptions none -OutFile '$(Join-Path $ranTemp 'case.tsv')'"
    Assert-True ($LASTEXITCODE -ne 0 -and (Join-RanOutput $output) -like "*Suite 'unit' is given twice*case*" -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'case.tsv'))) "The capture refuses suites Unit and unit ($($output -join ' | '))."
    # The Kelvin sign U+212A matches [A-Za-z] when case is folded (council round 4 on #726, Sol L2).
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestResults (Join-Path $ranFixtures 'names.results.txt') -TestLogExitCode 0 -Suite ([string][char]0x212A) -Revision r1 -BuildOptions none -OutFile (Join-Path $ranTemp 'kelvin.tsv') 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and (Join-RanOutput $output) -like '*must be ASCII letters*' -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'kelvin.tsv'))) "The capture refuses a suite label the compare would refuse ($(Join-RanOutput $output))."
    # One list is one compiler: a record from another refuses the list.
    $ranOther = New-RanRecord 'other-zig' (@([System.IO.File]::ReadAllLines((Join-Path $ranFixtures 'names.results.txt'))) -replace '^zig 0\.15\.2$', 'zig 0.17.1')
    $output = Invoke-RanCaptureCommand "-TestLog $(Get-RanFixturePath 'names.stderr.txt'), $(Get-RanFixturePath 'glued.stderr.txt') -TestResults '$ranOther', $(Get-RanFixturePath 'glued.results.txt') -TestLogExitCode 0, 0 -Suite one, two -Revision r1 -BuildOptions none -OutFile '$(Join-Path $ranTemp 'two-zig.tsv')'"
    Assert-True ($LASTEXITCODE -ne 0 -and (Join-RanOutput $output) -like '*compiler differs*0.17.1*' -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'two-zig.tsv'))) "Records from two compilers make no list ($($output -join ' | '))."
    # An imported run never takes the importer's environment (council round 2, Sol M2).
    Assert-True ($ranPrintedText -cmatch '(?m)^# build: source=imported\t' -and @([regex]::Matches($ranPrintedText, '(?m)^# env: [^=]+=unknown$')).Count -eq (Get-RanListFactKeys).Count) 'An imported run records every environment fact as unknown when it recorded none.'
    $ranImportSkip = New-RanLedger 'import-skip.tsv' @("fixture`tprinted.test.coverage`tfont:Arial Unicode MS=absent`tneeds the font")
    Assert-True (((Get-RanVerdict -Baselines @($ranPrinted) -Later $ranPrinted -SkipFiles @($ranImportSkip)).Problems -join ' ') -like "*SKIP-ENVIRONMENT*an imported run that recorded no facts*") 'An approval that needs a fact does not cover an imported run that could not record it.'
    $ranFacts = Join-Path $ranTemp 'run-facts.txt'
    $null = & pwsh -NoProfile -NonInteractive -File $ranCapture -WriteFacts $ranFacts -WorkingDirectory $ranTemp 2>&1
    $ranWritten = Read-RanListFacts -Path $ranFacts
    # `unknown` only for a probe that can fail: the 8.3 probe (no Scripting.FileSystemObject) and a font file it cannot read.
    $ranBadWritten = @(Get-RanListFactKeys | Where-Object { -not $ranWritten.Contains($_) -or "$($ranWritten[$_])" -cnotmatch $(if ($_ -ceq 'temp-makes-8dot3-names' -or $_.StartsWith('font:', [StringComparison]::Ordinal)) { '^(true|false|present|absent|unknown)$' } else { '^(true|false|unset|1|other)$' }) })
    Assert-True ($LASTEXITCODE -eq 0 -and $ranWritten.Count -eq (Get-RanListFactKeys).Count -and $ranBadWritten.Count -eq 0) "-WriteFacts records each fact of the run's environment ($($ranBadWritten -join ', '))."
    $out = Join-Path $ranTemp 'capture-with-facts.tsv'
    $null = Invoke-RanImport -Fixture 'names' -Out $out -More @('-TestLogFacts', $ranFacts)
    $ranImportedFacts = (Read-RanList -Path $out).Environment
    $ranMismatch = @(Get-RanListFactKeys | Where-Object { -not [string]::Equals("$($ranImportedFacts[$_])", "$($ranWritten[$_])", [StringComparison]::Ordinal) })
    Assert-True ($LASTEXITCODE -eq 0 -and $ranMismatch.Count -eq 0) "An imported run takes each fact as -TestLogFacts recorded it ($($ranMismatch -join ', '))."
    # -EnvironmentOf reads keys ordinally (council round 4 on #726, Sol L1).
    $ranUpperOf = Join-Path $ranTemp 'upper-of.tsv'
    [System.IO.File]::WriteAllText($ranUpperOf, ([System.IO.File]::ReadAllText($out) -creplace '# env: cwd-on-temp-drive=', '# env: CWD-ON-TEMP-DRIVE='), [System.Text.UTF8Encoding]::new($false))
    $output = Invoke-RanImport -Fixture 'names' -Out (Join-Path $ranTemp 'upper-of-run.tsv') -More @('-TestLogFacts', $ranFacts, '-EnvironmentOf', $ranUpperOf)
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like '*environment fact*CWD-ON-TEMP-DRIVE*nothing was built or run*') "-EnvironmentOf stops on a baseline whose key differs only by case ($(Join-RanOutput $output))."
    $ranEscOf = Join-Path $ranTemp 'esc-of.tsv'
    [System.IO.File]::WriteAllText($ranEscOf, ([System.IO.File]::ReadAllText($out) -creplace '(# env: cwd-on-temp-drive=[a-z]+\n)', "`$1# env: cwd-on-temp-driv$([char]27)e=false`n"), [System.Text.UTF8Encoding]::new($false))
    $output = Invoke-RanImport -Fixture 'names' -Out (Join-Path $ranTemp 'esc-of-run.tsv') -More @('-TestLogFacts', $ranFacts, '-EnvironmentOf', $ranEscOf)
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like '*environment fact*nothing was built or run*') "-EnvironmentOf stops on a baseline with an extra key holding ESC ($(Join-RanOutput $output))."
    # A baseline whose canonical fact differs, followed by the same key in capitals with
    # this run's value: a map that folded case would keep the second value and pass.
    $ranHereFact = [regex]::Match([System.IO.File]::ReadAllText($out), '(?m)^# env: cwd-on-temp-drive=([a-z]+)$').Groups[1].Value
    $ranFlipFact = $(if ($ranHereFact -ceq 'true') { 'false' } else { 'true' })
    $ranShadowOf = Join-Path $ranTemp 'shadow-of.tsv'
    [System.IO.File]::WriteAllText($ranShadowOf, ([System.IO.File]::ReadAllText($out) -creplace '# env: cwd-on-temp-drive=[a-z]+\n', "# env: cwd-on-temp-drive=$ranFlipFact`n# env: CWD-ON-TEMP-DRIVE=$ranHereFact`n"), [System.Text.UTF8Encoding]::new($false))
    $output = Invoke-RanImport -Fixture 'names' -Out (Join-Path $ranTemp 'shadow-of-run.tsv') -More @('-TestLogFacts', $ranFacts, '-EnvironmentOf', $ranShadowOf)
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like "*environment fact cwd-on-temp-drive is '$ranHereFact' here and '$ranFlipFact'*") "-EnvironmentOf keeps a baseline's fact apart from the same key in capitals ($(Join-RanOutput $output))."
    # A facts file is read ordinally too: a key in capitals is no fact the capture knows.
    $ranUpperFacts = Join-Path $ranTemp 'upper-facts.txt'
    [System.IO.File]::WriteAllText($ranUpperFacts, ([System.IO.File]::ReadAllText($ranFacts) -creplace '# env: cwd-on-temp-drive=', '# env: CWD-ON-TEMP-DRIVE='), [System.Text.UTF8Encoding]::new($false))
    $null = Invoke-RanImport -Fixture 'names' -Out (Join-Path $ranTemp 'upper-facts.tsv') -More @('-TestLogFacts', $ranUpperFacts)
    Assert-True ($LASTEXITCODE -eq 0 -and [System.IO.File]::ReadAllText((Join-Path $ranTemp 'upper-facts.tsv')) -cmatch '(?m)^# env: cwd-on-temp-drive=unknown$') 'A facts file whose key differs only by case leaves that fact unknown.'
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestResults (Join-Path $ranFixtures 'names.results.txt') -TestLogExitCode 0 -Revision r1 -BuildOptions unknown -OutFile (Join-Path $ranTemp 'unknown.tsv') 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'unknown.tsv'))) "An imported run refuses an unknown build ($($output -join ' | '))."
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestResults (Join-Path $ranFixtures 'names.results.txt') -Revision r1 -BuildOptions none -OutFile (Join-Path $ranTemp 'no-exit.tsv') 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'no-exit.tsv'))) "An import needs the exit code of the run that wrote it ($($output -join ' | '))."
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -TestLog (Join-Path $ranFixtures 'names.stderr.txt') -TestLogExitCode 0 -Revision r1 -BuildOptions none -OutFile (Join-Path $ranTemp 'no-record.tsv') 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and (Join-RanOutput $output) -like '*one -TestResults*' -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'no-record.tsv'))) "A log without its record cannot be imported ($($output -join ' | '))."
    # The environment check comes first: in build mode, before the build (council round 2, Opus L6).
    $ranHere = Get-RanListEnvironment -Directory $ranTemp
    $ranFlipped = [ordered]@{}
    foreach ($key in $ranHere.Keys) { $ranFlipped[$key] = $ranHere[$key] }
    $ranFlipped['cwd-on-temp-drive'] = $(if ($ranHere['cwd-on-temp-drive'] -ceq 'true') { 'false' } else { 'true' })
    $ranEnvBase = New-RanListFile 'env-base.tsv' $ranBaseTests -Environment $ranFlipped
    # A checkout whose scripts\dev-windows.cmd stands in for the build: it
    # half-installs into the --prefix it is given, notes that prefix, and fails;
    # or, with stub-edits.txt beside it, edits a tracked file and succeeds.
    $ranRepo = Join-Path $ranTemp 'checkout'
    New-Item -ItemType Directory -Path (Join-Path $ranRepo 'scripts') -Force | Out-Null
    $ranStub = @('@echo off', ':next', 'if "%~1"=="" exit /b 3', 'if "%~1"=="--prefix" goto found', 'shift', 'goto next', ':found', 'if exist stub-edits.txt (echo edited>> README& exit /b 0)', 'mkdir "%~2\bin"', 'echo partial> "%~2\bin\ghostty-test.exe"', 'echo %~2> stub-ran.txt', 'exit /b 3')
    [System.IO.File]::WriteAllText((Join-Path $ranRepo 'scripts\dev-windows.cmd'), (($ranStub -join "`r`n") + "`r`n"))
    [System.IO.File]::WriteAllText((Join-Path $ranRepo 'README'), "x`n")
    $null = & git -C $ranRepo init -q 2>&1
    $null = & git -C $ranRepo add README scripts/dev-windows.cmd 2>&1
    $null = & git -C $ranRepo -c user.name=ci -c user.email=ci@invalid -c core.autocrlf=false commit -q -m x 2>&1
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -Checkout $ranRepo -BuildOptions none -EnvironmentOf $ranEnvBase -OutFile (Join-Path $ranTemp 'env-build.tsv') 2>&1
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like '*environment fact cwd-on-temp-drive*nothing was built or run*' -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'env-build.build.log')) -and -not (Test-Path -LiteralPath (Join-Path $ranRepo 'stub-ran.txt'))) "Build mode checks -EnvironmentOf before it builds anything ($($output -join ' | '))."
    # A failed build leaves no prefix behind (council round 2, Opus L7).
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -Checkout $ranRepo -BuildOptions none -OutFile (Join-Path $ranTemp 'failed-build.tsv') 2>&1
    $ranStubRan = Join-Path $ranRepo 'stub-ran.txt'
    $ranHalf = if (Test-Path -LiteralPath $ranStubRan) { Join-Path $ranRepo ([System.IO.File]::ReadAllText($ranStubRan).Trim()) } else { $null }
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like '*The build failed*' -and $null -ne $ranHalf -and $ranHalf -like '*\.zig-cache\ran-list-*' -and -not (Test-Path -LiteralPath $ranHalf) -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'failed-build.tsv'))) "A failed build's half-installed prefix is removed ($($output -join ' | '))."
    Remove-Item -LiteralPath $ranStubRan
    # A tracked file that changes during the build makes no list (council round 3, Opus L4).
    [System.IO.File]::WriteAllText((Join-Path $ranRepo 'stub-edits.txt'), '')
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -Checkout $ranRepo -BuildOptions none -OutFile (Join-Path $ranTemp 'edited-build.tsv') 2>&1
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like '*changed during the build*no list written*' -and -not (Test-Path -LiteralPath (Join-Path $ranTemp 'edited-build.tsv'))) "A checkout edited during the build is refused ($($output -join ' | '))."
    Remove-Item -LiteralPath (Join-Path $ranRepo 'stub-edits.txt')
    $null = & git -C $ranRepo checkout -q -- README 2>&1
    # The same check after the run, on its own: HEAD and tracked files.
    $ranState = Get-RanListCheckoutState -Root $ranRepo
    Assert-RanListCheckoutUnchanged -Root $ranRepo -Before $ranState -When 'during the run'
    [System.IO.File]::WriteAllText((Join-Path $ranRepo 'README'), "changed`n")
    $ranThrew = try { Assert-RanListCheckoutUnchanged -Root $ranRepo -Before $ranState -When 'during the run'; $false } catch { $_.Exception.Message -like '*changed during the run*' }
    Assert-True $ranThrew 'A tracked file edited during the run is seen.'
    $null = & git -C $ranRepo checkout -q -- README 2>&1
    $null = & git -C $ranRepo -c user.name=ci -c user.email=ci@invalid commit -q --allow-empty -m y 2>&1
    $ranThrew = try { Assert-RanListCheckoutUnchanged -Root $ranRepo -Before $ranState -When 'during the run'; $false } catch { $_.Exception.Message -like '*changed during the run*' }
    Assert-True $ranThrew 'A commit made during the run is seen.'
    # Build mode refuses a checkout with tracked changes unless asked (council round 2, Opus L3).
    [System.IO.File]::WriteAllText((Join-Path $ranRepo 'README'), "changed`n")
    $output = & pwsh -NoProfile -NonInteractive -File $ranCapture -Checkout $ranRepo -BuildOptions none -OutFile (Join-Path $ranTemp 'dirty-build.tsv') 2>&1
    Assert-True ($LASTEXITCODE -eq 1 -and (Join-RanOutput $output) -like '*has tracked changes*' -and -not (Test-Path -LiteralPath $ranStubRan)) "Build mode refuses a dirty checkout before it builds ($($output -join ' | '))."
    Assert-True (@($ranHere.Keys) -contains 'temp-makes-8dot3-names' -and @($ranHere.Keys) -contains 'font:Noto Serif Tibetan' -and $ranHere['env:NOCTTY_RUN_LOCAL_PATH_SWEEP'] -cin @('unset', '1', 'other')) 'The capture records the facts the environment-dependent tests read.'
    # Without LOCALAPPDATA there is no per-user font directory, and the probe still
    # records every fact (Greptile on #731).
    $ranSavedLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $null
        $ranNoUser = Get-RanListEnvironment -Directory $ranTemp
    }
    finally { $env:LOCALAPPDATA = $ranSavedLocalAppData }
    Assert-True ($ranNoUser.Count -eq (Get-RanListFactKeys).Count -and @('Arial Unicode MS', 'Noto Sans Chakma', 'Noto Serif Tibetan' | Where-Object { $ranNoUser["font:$_"] -cin @('present', 'absent', 'unknown') }).Count -eq 3) 'The environment probe runs without LOCALAPPDATA.'

    # Paths resolve against PowerShell's location, not .NET's current directory:
    # old holds a list that would pass, new one that drops a test, with the
    # baseline and approvals in both (council round 2, Opus L1).
    $ranOld = New-Item -ItemType Directory -Path (Join-Path $ranTemp 'old')
    $ranNew = New-Item -ItemType Directory -Path (Join-Path $ranTemp 'new')
    foreach ($dir in $ranOld, $ranNew) {
        Copy-Item -LiteralPath $ranBase -Destination (Join-Path $dir 'base.tsv')
        Copy-Item -LiteralPath $ranSkips -Destination (Join-Path $dir 'skips.tsv')
    }
    Copy-Item -LiteralPath $ranBase -Destination (Join-Path $ranOld 'candidate.tsv')
    Copy-Item -LiteralPath $ranDropped -Destination (Join-Path $ranNew 'candidate.tsv')
    $null = & pwsh -NoProfile -NonInteractive -File $ranCompare -Baseline (Join-Path $ranOld 'base.tsv') -Candidate (Join-Path $ranOld 'candidate.tsv') -ApprovedSkips (Join-Path $ranOld 'skips.tsv') 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'The old directory''s candidate passes (so a resolver that read it would pass).'
    [Environment]::CurrentDirectory = $ranOld.FullName
    Set-Location -LiteralPath $ranNew.FullName
    # The compare writes its problems to the console's stderr, which *>&1 does not take in process.
    $ranStderr = [System.IO.StringWriter]::new()
    $ranConsoleError = [Console]::Error
    [Console]::SetError($ranStderr)
    try { $null = & $ranCompare -Baseline base.tsv -Candidate candidate.tsv -ApprovedSkips skips.tsv *>&1 }
    finally { [Console]::SetError($ranConsoleError) }
    Assert-True ($LASTEXITCODE -eq 1 -and $ranStderr.ToString().Trim() -ceq "RAN LIST: DROPPED ghostty-test a.test.two (ran 1 in the baseline, 0 now)$([Environment]::NewLine)RAN LIST: FAIL (1 problems)") "After Set-Location, relative paths are the new location's: its candidate drops a test, and only that ($($ranStderr.ToString().Trim()))."
    $ranImportMap = @{ TestLog = (Join-Path $ranFixtures 'names.stderr.txt'); TestResults = (Join-Path $ranFixtures 'names.results.txt'); TestLogExitCode = 0; Revision = 'r1'; BuildOptions = 'none' }
    $null = & $ranCapture @ranImportMap -OutFile relative.tsv *>&1
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
$ranBadFacts = @($ranSeed.Values | ForEach-Object { $_ } | ForEach-Object { $_.Requires } | Where-Object { $_ } | ForEach-Object { ($_ -split '=', 2)[0] } | Where-Object { $_ -cnotin (Get-RanListFactKeys) -and -not $_.StartsWith('build:') })
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
