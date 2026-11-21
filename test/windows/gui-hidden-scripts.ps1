#requires -Version 7.0
[CmdletBinding()]
param()

# Tests for the hidden-desktop GUI suite's selection (design v7 §4.5): scripts/ci-script-closure.ps1, the walker
# that computes which files a hosted leaf can run, and scripts/ci-gui-selection.ps1, which decides from a pull
# request's changed files whether gui-hidden.yml's suite runs. The `changes` job of gui-hidden.yml runs this, and
# Contracts.99-GuiHiddenSelection.ps1 runs it with the flagship contracts. It reads the repository itself (the real
# closure) and synthetic trees; it starts nothing but child pwsh processes of the selection script.
# test/windows/ci-scripts.ps1 pins Get-CiPathNeeds for every tracked path; this file does not repeat that.

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $repoRoot 'scripts\ci-gui-selection.ps1') -LibraryOnly

$script:passed = 0
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

# A reader over a table of repo path -> text (a synthetic tree).
function New-TableReader {
    param([hashtable] $Files)
    return { param([string] $RepoPath) if ($Files.ContainsKey($RepoPath)) { return $Files[$RepoPath] } return $null }.GetNewClosure()
}

$fakeRoot = 'C:\gui-hidden-fixture'
function Get-FixtureWalk {
    param([hashtable] $Files, [string[]] $Entries = @('test/windows/entry.ps1'), [object[]] $LegacyEdges = @())
    return Get-ScriptClosure -RepoRoot $fakeRoot -Entries $Entries -Reader (New-TableReader $Files) -LegacyEdges $LegacyEdges
}

# --- The walker on synthetic trees --------------------------------------------------------------------------------
$walk = Get-FixtureWalk @{
    'test/windows/entry.ps1' = @'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\lib.ps1')
$helper = Join-Path $PSScriptRoot 'helper.ps1'
. $helper
. "$PSScriptRoot\expandable.ps1"
Add-Type -Path (Join-Path $PSScriptRoot 'native.cs')
$exe = Join-Path (Split-Path -Parent $repoRoot) 'noctty.exe'
& $exe +version
& (Join-Path $PSScriptRoot 'child.cmd')
Get-ChildItem -LiteralPath $PSScriptRoot -File | Out-Null
[scriptblock] $callback = { 1 }
& $callback
& { 2 }
'@
    'scripts/lib.ps1' = @'
function Wait-It { param([Parameter(Mandatory)] [scriptblock] $Condition) & $Condition }
$pwsh = (Get-Command pwsh.exe).Source
& $pwsh -NoProfile -Version
'@
    'test/windows/helper.ps1' = '1'
    'test/windows/expandable.ps1' = '2'
    'test/windows/native.cs' = 'class X {}'
    'test/windows/child.cmd' = '@echo off'
}
Assert-True ($walk.Problems.Count -eq 0) "The constant compositions, callbacks, native calls and -File on another cmdlet must walk cleanly: $($walk.Problems -join '; ')"
foreach ($member in @('scripts/lib.ps1', 'test/windows/helper.ps1', 'test/windows/expandable.ps1', 'test/windows/native.cs', 'test/windows/child.cmd')) {
    Assert-True ($walk.Members -ccontains $member) "The walk must reach $member."
}

# A variable feeding a load that branches assign differently: the walk must not keep only the last branch's script
# (that would drop the other from the closure and fail open). It refuses the edge instead; an assignment repeated with
# the same value still resolves.
$branched = Get-FixtureWalk @{
    'test/windows/entry.ps1' = @'
if ($env:FIXTURE_BRANCH) { $loaded = Join-Path $PSScriptRoot 'branch-a.ps1' }
else { $loaded = Join-Path $PSScriptRoot 'branch-b.ps1' }
. $loaded
'@
    'test/windows/branch-a.ps1' = '1'
    'test/windows/branch-b.ps1' = '2'
}
Assert-True (@($branched.Unresolved | Where-Object { $_.Anchor -ceq '. $loaded' }).Count -eq 1 -and $branched.Problems.Count -ge 1) "A load whose variable two branches assign differently must fail the walk: $($branched.Problems -join '; ')"
Assert-True ($branched.Members -cnotcontains 'test/windows/branch-b.ps1' -or $branched.Members -ccontains 'test/windows/branch-a.ps1') 'The walk must never keep one branch''s script and drop the other''s.'
$repeated = Get-FixtureWalk @{
    'test/windows/entry.ps1' = @'
$loaded = Join-Path $PSScriptRoot 'same.ps1'
if ($env:FIXTURE_BRANCH) { $loaded = Join-Path $PSScriptRoot 'same.ps1' }
. $loaded
'@
    'test/windows/same.ps1' = '1'
}
Assert-True ($repeated.Problems.Count -eq 0 -and $repeated.Members -ccontains 'test/windows/same.ps1') "Assignments that agree must still resolve: $($repeated.Problems -join '; ')"

$unlisted = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '$path = Get-Something; & $path' }
Assert-True ($unlisted.Problems.Count -eq 1 -and $unlisted.Unresolved[0].Anchor -ceq '& $path') "An unlisted & `$path to a script must fail the walk: $($unlisted.Problems -join '; ')"

$splat = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '$a = @("-File", "x.ps1"); & powershell.exe @a' }
Assert-True ($splat.Problems.Count -eq 1) 'A splatted PowerShell invocation may run -File and must fail the walk unless listed.'

$stringBuilt = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '$line = ''"{0}" -NoProfile -File "{1}"'' -f $a, $b' }
Assert-True ($stringBuilt.Problems.Count -eq 1) 'A command line built as a string that runs -File must fail the walk unless listed.'

$listed = Get-FixtureWalk -Files @{ 'test/windows/entry.ps1' = '$line = ''"{0}" -NoProfile -File "{1}"'' -f $a, $b' } -LegacyEdges @(
    [pscustomobject]@{ File = 'test/windows/entry.ps1'; Anchor = '-NoProfile -File "{1}"'; Guard = 'fixture' })
Assert-True ($listed.Problems.Count -eq 0 -and $listed.Legacy.Count -eq 1) 'A listed legacy-only edge must pass and be reported with its guard.'

$stale = Get-FixtureWalk -Files @{ 'test/windows/entry.ps1' = '1' } -LegacyEdges @(
    [pscustomobject]@{ File = 'test/windows/entry.ps1'; Anchor = '& $gone'; Guard = 'fixture' })
Assert-True ($stale.Problems.Count -eq 1 -and $stale.Stale.Count -eq 1) 'A legacy-only edge whose file is walked but no longer holds its anchor must fail the walk.'

$cmdScript = Get-FixtureWalk @{ 'test/windows/entry.ps1' = 'param([string] $RepoRoot) $tool = Join-Path $RepoRoot ''scripts\tool.cmd''; & cmd /c $tool' }
Assert-True ($cmdScript.Problems.Count -eq 1) 'cmd /c with a script argument that does not resolve must fail the walk.'

$missing = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '. (Join-Path $PSScriptRoot ''gone.ps1'')' }
Assert-True ($missing.Problems.Count -eq 1 -and $missing.Missing -ccontains 'test/windows/gone.ps1') 'A resolved target that does not exist must fail the walk.'

$flow = Get-FixtureWalk @{
    'test/windows/entry.ps1' = '$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot); . (Join-Path $root ''scripts\a.ps1''); $root = $layout.Other; Write-Host $root'
    'scripts/a.ps1' = '1'
}
Assert-True ($flow.Problems.Count -eq 0 -and $flow.Members -ccontains 'scripts/a.ps1') 'The last assignment before a read decides its value, not a later one.'

# --- The walker on the real closure ---------------------------------------------------------------------------------
$plan = Get-Content -LiteralPath (Join-Path $repoRoot 'test\windows\gui-hidden-plan.json') -Raw | ConvertFrom-Json
$entries = @('test/windows/gui-hidden-runner.ps1') + @($plan.leaves | ForEach-Object { [string]$_.script })
$real = Get-ScriptClosure -RepoRoot $repoRoot -Entries $entries
Assert-True ($real.Problems.Count -eq 0) "The walk over the suite's real closure must pass: $($real.Problems -join '; ')"
Assert-True (@($real.Legacy | Where-Object { $_.File -ceq 'test/windows/vt-probe-win32-conformance.ps1' -and $_.Anchor -ceq '& powershell.exe @scriptArgs' }).Count -eq 1) "vt-probe's -Runtime children must be a listed legacy-only edge."
foreach ($required in @('scripts/interactive-win11-lib.ps1', 'scripts/interactive-win11-measure-lib.ps1', 'test/windows/interactive-win11-stateful-lib.ps1', 'scripts/interactive-win11-window-lib.ps1')) {
    Assert-True ($real.Members -ccontains $required) "The real closure must reach $required."
}

# A permitted callback mutated into an unresolved child-script call: Wait-InteractiveWin11Until's [scriptblock]
# $Condition made a string must fail the walk in the library.
$libPath = 'scripts/interactive-win11-lib.ps1'
$libText = [IO.File]::ReadAllText((Join-Path $repoRoot $libPath))
$typed = '[Parameter(Mandatory)] [scriptblock] $Condition'
Assert-True ($libText.Contains($typed)) 'The callback control lost its anchor in interactive-win11-lib.ps1.'
$mutatedReader = {
    param([string] $RepoPath)
    if ($RepoPath -ceq $libPath) { return $libText.Replace($typed, '[Parameter(Mandatory)] [string] $Condition') }
    $full = Join-Path $repoRoot ($RepoPath.Replace('/', '\'))
    if ([IO.File]::Exists($full)) { return [IO.File]::ReadAllText($full) }
    return $null
}.GetNewClosure()
$mutated = Get-ScriptClosure -RepoRoot $repoRoot -Entries $entries -Reader $mutatedReader
Assert-True (@($mutated.Unresolved | Where-Object { $_.File -ceq $libPath -and $_.Anchor -ceq '& $Condition' }).Count -ge 1) 'A callback mutated into an unresolved child-script call must fail the walk.'

# --- The selection --------------------------------------------------------------------------------------------------
$list = Get-CiGuiList -RepoRoot $repoRoot
foreach ($member in $list) {
    Assert-True (Get-CiGuiSelection -ChangedPaths @($member) -GuiList $list) "GUI list member $member alone must select the suite."
}
foreach ($member in $real.Members) { Assert-True ($list -ccontains $member) "The GUI list must hold closure member $member." }
foreach ($buildInput in @($plan.buildInputs)) { Assert-True ($list -ccontains [string]$buildInput) "The GUI list must hold build input $buildInput." }

# Singletons, independent of the computed list (which cannot show its own omissions): each keeps its own
# Get-CiPathNeeds result, so test.yml's flags stay what they were, and each selects the suite.
$singletons = [ordered]@{
    'scripts/dev-windows.cmd' = 'package'
    'scripts/interactive-win11-lib.ps1' = 'package'
    'scripts/interactive-win11-window-lib.ps1' = 'none'
    'test/windows/interactive-win11-stateful-lib.ps1' = 'none'
    'scripts/interactive-win11-measure-lib.ps1' = 'zig'
    'scripts/interactive-win11-realinput.ps1' = 'zig'
}
foreach ($path in $singletons.Keys) {
    Assert-True ((Get-CiPathNeeds $path) -ceq $singletons[$path]) "$path must keep Get-CiPathNeeds '$($singletons[$path])'."
    Assert-True (Get-CiGuiSelection -ChangedPaths @($path) -GuiList $list) "$path alone must select the suite."
}
# The dual consumers keep their package jobs in test.yml and also select the suite.
foreach ($path in @('scripts/interactive-win11-lib.ps1', 'test/windows/cli-automation.ps1')) {
    Assert-True ((Get-CiPathNeeds $path) -ceq 'package') "$path must stay a package input for test.yml."
    Assert-True ([bool](Get-CiJobSelection -ChangedPaths @($path)).package) "$path must still run test.yml's package jobs."
    Assert-True (Get-CiGuiSelection -ChangedPaths @($path) -GuiList $list) "$path must also select the GUI suite."
}
Assert-True (-not (Get-CiGuiSelection -ChangedPaths @('docs/status.md') -GuiList $list)) 'A docs-only change must not select the suite.'
Assert-True (-not (Get-CiGuiSelection -ChangedPaths @('test/windows/interactive-win11-key-input.ps1') -GuiList $list)) 'A leaf outside the suite''s closure must not select it.'
Assert-True (Get-CiGuiSelection -ChangedPaths @('src/main.zig') -GuiList $list) 'A path the Zig graph reads must select the suite.'
Assert-True (Get-CiGuiSelection -ChangedPaths @('newdir/file.txt') -GuiList $list) 'A path the classifier does not know is zig and must select the suite.'
Assert-True (Get-CiGuiSelection -ChangedPaths @() -GuiList $list) 'An empty diff must select the suite.'
Assert-True (Get-CiGuiSelection -ChangedPaths @('', '  ') -GuiList $list) 'Blank lines only must select the suite.'

# A deleted member: the head tree drops the undo leaf and its script; the base tree still has them, so its closure,
# window-lib included, stays in the list.
$planText = [IO.File]::ReadAllText((Join-Path $repoRoot 'test\windows\gui-hidden-plan.json'))
$headPlan = $planText | ConvertFrom-Json
$headPlan.leaves = @($headPlan.leaves | Where-Object { $_.id -cne 'undo' })
$headPlanText = $headPlan | ConvertTo-Json -Depth 6
$undoPath = 'test/windows/interactive-win11-undo.ps1'
$workingReader = New-CiScriptFileReader -RepoRoot $repoRoot
$headReader = {
    param([string] $RepoPath)
    if ($RepoPath -ceq 'test/windows/gui-hidden-plan.json') { return $headPlanText }
    if ($RepoPath -ceq $undoPath) { return $null }
    return & $workingReader $RepoPath
}.GetNewClosure()
$deletedList = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $headReader -BaseReader $workingReader
Assert-True ($deletedList -ccontains $undoPath) 'A leaf the change deletes must stay in the GUI list through the base tree.'
Assert-True (Get-CiGuiSelection -ChangedPaths @($undoPath) -GuiList $deletedList) 'Deleting a closure member must select the suite.'

# The git tree reader: $null means the tree has no such file, and only that (CodeRabbit on #740). A ref that names no
# tree, and a file the tree lists that git cannot read, throw, so the selection runs the suite rather than reading a
# failed read of the base plan as a base without one.
$gitReader = New-CiScriptFileReader -RepoRoot $repoRoot -Ref 'HEAD'
Assert-True ([string](& $gitReader 'scripts/ci-script-closure.ps1')).Contains('function Get-ScriptClosure') 'The git reader must read a file the tree holds.'
Assert-True ($null -eq (& $gitReader 'scripts/no-such-file.ps1')) 'The git reader must give $null for a path the tree does not hold.'
Assert-True ($null -eq (& $gitReader 'scripts')) 'The git reader must give $null for a directory.'
$threw = $false
try { $null = New-CiScriptFileReader -RepoRoot $repoRoot -Ref "no-such-ref-$([guid]::NewGuid().ToString('N'))" } catch { $threw = $true }
Assert-True $threw 'A ref that names no tree must throw, not read as a tree without files.'
$global:LASTEXITCODE = 0
# A stand-in git whose tree lists the plan but whose object read fails (a missing object, a blobless clone offline).
$unreadableGit = {
    param([string[]] $GitArguments)
    $global:LASTEXITCODE = 0
    switch ($GitArguments[2]) {
        'rev-parse' { return ('a' * 40) }
        'ls-tree' { return "100644 blob $('b' * 40)`ttest/windows/gui-hidden-plan.json$([char]0)" }
        default { $global:LASTEXITCODE = 128; return $null }
    }
}
$unreadable = New-CiScriptFileReader -RepoRoot $repoRoot -Ref 'base' -Git $unreadableGit
$threw = $false
try { $null = & $unreadable 'test/windows/gui-hidden-plan.json' } catch { $threw = $true }
Assert-True $threw 'A file the tree lists that git cannot read must throw, not read as absent.'
Assert-True ($null -eq (& $unreadable 'test/windows/interactive-win11-smoke.ps1')) 'A path the stand-in tree does not list must still read as absent.'
$threw = $false
try { $null = Get-CiGuiList -RepoRoot $repoRoot -BaseReader $unreadable } catch { $threw = $true }
Assert-True $threw 'A base tree whose plan git cannot read must fail the GUI list (the selection then runs the suite), not drop the base side.'
Assert-True ($LASTEXITCODE -eq 0) 'A handled git failure must leave $LASTEXITCODE at 0 (PKG-65).'

# The CLI: events that always run the suite, and an unreadable diff.
$outputFile = Join-Path ([IO.Path]::GetTempPath()) ("noctty-gui-selection-$([guid]::NewGuid().ToString('N')).txt")
$savedOutput = $env:GITHUB_OUTPUT
$savedSummary = $env:GITHUB_STEP_SUMMARY
try {
    $env:GITHUB_OUTPUT = $outputFile
    $env:GITHUB_STEP_SUMMARY = $null
    $selection = Join-Path $repoRoot 'scripts\ci-gui-selection.ps1'
    $runs = @(
        @{ Name = 'push'; Arguments = @('-EventName', 'push'); Expect = 'gui=true' }
        @{ Name = 'schedule'; Arguments = @('-EventName', 'schedule'); Expect = 'gui=true' }
        @{ Name = 'workflow_dispatch'; Arguments = @('-EventName', 'workflow_dispatch'); Expect = 'gui=true' }
        @{ Name = 'an unreadable diff'; Arguments = @('-EventName', 'pull_request', '-BaseSha', 'not-a-sha', '-HeadSha', 'not-a-sha'); Expect = 'gui=true' }
        @{ Name = 'a docs-only list'; Arguments = @('-Paths', 'docs/status.md'); Expect = 'gui=false' }
        @{ Name = 'a suite leaf'; Arguments = @('-Paths', 'test/windows/interactive-win11-smoke.ps1'); Expect = 'gui=true' }
    )
    foreach ($run in $runs) {
        if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
        $arguments = $run.Arguments
        & pwsh -NoProfile -NonInteractive -File $selection @arguments 3>$null 6>$null | Out-Null
        $code = $LASTEXITCODE
        $lines = @(if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile })
        Assert-True ($code -eq 0 -and $lines.Count -eq 1 -and $lines[0] -ceq $run.Expect) "The selection CLI on $($run.Name) must exit 0 and write $($run.Expect); wrote [$($lines -join ', ')], exit $code."
    }
}
finally {
    $env:GITHUB_OUTPUT = $savedOutput
    $env:GITHUB_STEP_SUMMARY = $savedSummary
    if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
    $global:LASTEXITCODE = 0
}

Write-Host "gui-hidden-scripts: $script:passed checks passed."
