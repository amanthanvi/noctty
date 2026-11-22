#requires -Version 7.0
<#
.SYNOPSIS
Decides whether a pull request needs the hidden-desktop GUI suite (.github/workflows/gui-hidden.yml).

.DESCRIPTION
`gui` is true when any changed path is one the Zig graph reads (scripts/ci-changed-paths.ps1's `Get-CiPathNeeds`
gives `zig`, which includes every path its table does not name) or is in the GUI list. This script never changes
that classifier, and test.yml's ten outputs stay what they were: only gui-hidden.yml calls it (design v7 §4.5).

The GUI list is computed, never kept by hand: the closure (scripts/ci-script-closure.ps1) of the runner and of every
leaf in test/windows/gui-hidden-plan.json, plus the fixed members (the plan, the flagship scenario, the workflow, the
helper self-test it runs, this script, the walker, the fixtures, the suite's contract fragment, and the git policy the
measurement preparation's provenance checks run under, .gitignore and .gitattributes) and the plan's `buildInputs`
(what the hosted build preparation and the runner read through edges no walk shows: the measurement build's whole
input set, src/**, pkg/**, vendor/**, include/**, dist/windows/**, build.zig and build.zig.zon, with
scripts/dev-windows.cmd and the ConPTY stager and its two libraries; a `<dir>/**` entry is every tracked file under
that directory in each tree walked). On a pull request it is walked over the head tree, the base tip and every merge
base of the two, so a member a change deletes or renames away still counts: the changed paths are a three-dot diff,
from the merge base, which can describe a member neither tip has.

Push, schedule and manual runs need the suite. So do an empty diff, blank lines only, an unreadable diff and any
failure to compute the list: deciding is an optimisation, and failing to decide runs the suite.
#>
[CmdletBinding()]
param(
    [string] $EventName = $env:GITHUB_EVENT_NAME,
    [string] $BaseSha,
    [string] $HeadSha,
    # The changed files, instead of asking git (used by the tests).
    [string[]] $Paths,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

# Dot-sourcing ci-changed-paths.ps1 binds its parameters (the same names as these) in this scope, so keep this
# script's own values first.
$script:CiGuiArguments = @{
    EventName = $EventName
    BaseSha = $BaseSha
    HeadSha = $HeadSha
    Paths = $Paths
    PathsGiven = $PSBoundParameters.ContainsKey('Paths')
    LibraryOnly = [bool]$LibraryOnly
}
. (Join-Path $PSScriptRoot 'ci-changed-paths.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'ci-script-closure.ps1')

$script:CiGuiPlanPath = 'test/windows/gui-hidden-plan.json'
$script:CiGuiRunnerPath = 'test/windows/gui-hidden-runner.ps1'
# Members that no edge reaches: the suite's own definition, the selection that runs it, the helper self-test the
# suite job runs before the leaves (Sol on #740: Get-CiPathNeeds calls it none, so nothing else selected it), and the
# error publisher it runs when it fails.
$script:CiGuiFixedMembers = @(
    'test/windows/gui-hidden-plan.json'
    'test/windows/flagship/scenarios/gui-hidden.json'
    '.github/workflows/gui-hidden.yml'
    'test/windows/interactive-win11.ps1'
    # The error publisher the suite job runs when it fails, apart from the runner (Sol on #740), and the schema it
    # checks a result against.
    'test/windows/gui-hidden-publish-error.ps1'
    'test/windows/flagship/result.schema.json'
    'scripts/ci-gui-selection.ps1'
    'scripts/ci-script-closure.ps1'
    # The selection's own inputs (Opus on #740): it dot-sources ci-changed-paths.ps1 (Get-CiChangedPaths,
    # Get-CiPathNeeds), and the gate's verdict is ci-gate.ps1.
    'scripts/ci-changed-paths.ps1'
    'scripts/ci-gate.ps1'
    # The git policy the measurement preparation's provenance checks run under (Sol and Opus on #740, round 13): the
    # clean-checkout status reads .gitignore (it keeps the restored cache and .sandbox/ out), and the checkout bytes it
    # compares with their blobs, and `git archive`, follow .gitattributes. .gitignore alone selected nothing before.
    '.gitignore'
    '.gitattributes'
    'test/windows/gui-hidden-scripts.ps1'
    'test/windows/flagship/contracts/Contracts.99-GuiHiddenSelection.ps1'
)

function Get-CiGuiPlan {
    # The plan as read through $Reader, or $null when that tree has none.
    param([Parameter(Mandatory)] [scriptblock] $Reader)
    $text = & $Reader $script:CiGuiPlanPath
    if ($null -eq $text) { return $null }
    $plan = $text | ConvertFrom-Json
    if ($plan.schemaVersion -ne 1 -or $null -eq $plan.leaves) { throw "$script:CiGuiPlanPath is not a version 1 plan." }
    return $plan
}

function Get-CiGuiPriorRefs {
    <#
    .SYNOPSIS
    The prior trees a pull request's list walks, as full commit names, each once: the base tip and every merge base
    of the base and the head. The changed paths are the three-dot diff (Get-CiChangedPaths), so they run from the
    merge base, and a member that main and the pull request both removed after the fork is described by that tree
    alone (Sol on #740); the base tip keeps a member main added since. Throws when git cannot answer.
    #>
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $Base, [Parameter(Mandatory)] [string] $Head)
    $tip = @(& git -C $RepoRoot rev-parse --verify --quiet "$Base^{commit}" 2>$null)
    $tipCode = $LASTEXITCODE
    $bases = @(& git -C $RepoRoot merge-base --all $Base $Head 2>$null)
    $basesCode = $LASTEXITCODE
    # A handled failure must not leave Actions' implicit `exit $LASTEXITCODE` failing the step (PKG-65).
    $global:LASTEXITCODE = 0
    if ($tipCode -ne 0 -or $tip.Count -ne 1) { throw "$Base does not name a commit." }
    if ($basesCode -ne 0 -or $bases.Count -eq 0) { throw "git merge-base $Base $Head failed with exit code $basesCode." }
    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($tip + $bases)) { if (-not $refs.Contains([string]$name)) { $refs.Add([string]$name) } }
    return , $refs.ToArray()
}

function Get-CiGuiTreeFiles {
    <#
    .SYNOPSIS
    The repo paths of every tracked file under -Directory (a repo directory, '/'-separated) in -Ref's tree, or in the
    index when -Ref is empty: what a `<dir>/**` build input names. The measurement build reads its whole input set, so
    the plan lists it by tree, not file by file (Sol on #740, rounds 11 and 12: the ConPTY manifest, then the two
    sources measure-lib reads for provenance, were each missing from a hand-kept list). The working-tree route lists
    the index, not the directory, so an ignored or untracked local file is no member, as on the ref route (Sol, round
    13). Throws when git cannot list.
    #>
    param([Parameter(Mandatory)] [string] $RepoRoot, [string] $Ref, [Parameter(Mandatory)] [string] $Directory)
    $arguments = $(if ([string]::IsNullOrWhiteSpace($Ref)) { @('ls-files', '-z', '--full-name', '--', "$Directory/") } else { @('ls-tree', '-r', '-z', '--name-only', '--full-tree', $Ref, '--', "$Directory/") })
    return , (Invoke-CiGuiGitPaths -RepoRoot $RepoRoot -Arguments $arguments -What $(if ($Ref) { $Ref } else { 'the index' }))
}

function Invoke-CiGuiGitPaths {
    <#
    .SYNOPSIS
    The NUL-separated paths a git listing (-z) writes, decoded as UTF-8 whatever the console's code page: PowerShell
    reads a native command's output through [Console]::OutputEncoding, and under code page 437 a tracked
    `src/caf<e-acute>.zig` came back garbled, naming no changed path (CodeRabbit on #740). Throws when git fails.
    #>
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string[]] $Arguments, [string] $What)
    $info = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($argument in @('-C', $RepoRoot) + $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        # Standard error is drained alongside, so a full pipe cannot stall git.
        $errors = $process.StandardError.ReadToEndAsync()
        $text = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        [void]$errors.Result
        if ($process.ExitCode -ne 0) { throw "git $($Arguments[0]) for $What failed with exit code $($process.ExitCode)." }
    }
    finally { $process.Dispose() }
    return , [string[]]@($text.Split([char]0) | Where-Object { $_ })
}

function Get-CiGuiList {
    <#
    .SYNOPSIS
    The computed GUI list: repo-relative paths, sorted. The union over the head tree (the working tree) and each
    prior tree: each -BaseRef's tree (Get-CiGuiPriorRefs names them for a pull request) and each -BaseReader. Throws
    when a read or a walk fails, so the caller can run the suite. -HeadReader and -BaseReader (param([string]
    $RepoPath) returning text or $null) replace trees, for the tests; a `<dir>/**` build input is listed from the
    index for them.
    #>
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string[]] $BaseRef,
        [scriptblock] $HeadReader,
        [scriptblock[]] $BaseReader
    )
    $list = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($member in $script:CiGuiFixedMembers) { [void]$list.Add($member) }
    $trees = @(@{ Ref = $null; Reader = $HeadReader; Where = 'in the head tree' })
    foreach ($ref in @($BaseRef | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { $trees += @{ Ref = $ref; Reader = $null; Where = "in the base tree $ref" } }
    foreach ($reader in @($BaseReader | Where-Object { $null -ne $_ })) { $trees += @{ Ref = $null; Reader = $reader; Where = 'in a prior tree' } }
    $plans = @()
    foreach ($tree in $trees) {
        if (-not $tree.Reader) { $tree.Reader = New-CiScriptFileReader -RepoRoot $RepoRoot -Ref $tree.Ref }
        $tree.Plan = Get-CiGuiPlan -Reader $tree.Reader
        if ($tree.Plan) { $plans += $tree.Plan }
    }
    if ($plans.Count -eq 0) { throw "No tree has $script:CiGuiPlanPath." }
    # Every tree walks every plan's leaves, so a leaf one side drops still counts on the other.
    $entries = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    [void]$entries.Add($script:CiGuiRunnerPath)
    $buildTrees = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($plan in $plans) {
        foreach ($leaf in @($plan.leaves)) { [void]$entries.Add([string]$leaf.script) }
        # In the form Get-CiGuiSelection gives a changed path, so a build input the plan spells with backslashes still
        # matches git's '/' (CodeRabbit on #740). A `<dir>/**` entry is expanded in each tree below.
        foreach ($buildInput in @($plan.buildInputs)) {
            $path = ConvertTo-CiRepoPath ([string]$buildInput)
            if ($path.EndsWith('/**', [StringComparison]::Ordinal)) { [void]$buildTrees.Add($path.Substring(0, $path.Length - 3)) }
            else { [void]$list.Add($path) }
        }
    }
    foreach ($tree in $trees) {
        foreach ($directory in $buildTrees) {
            foreach ($file in (Get-CiGuiTreeFiles -RepoRoot $RepoRoot -Ref $tree.Ref -Directory $directory)) { [void]$list.Add($file) }
        }
        # An entry a tree does not have (a new leaf, on the base side) has nothing to walk there.
        $present = @($entries | Where-Object { $null -ne (& $tree.Reader $_) })
        if ($present.Count -eq 0) { continue }
        $closure = Get-ScriptClosure -RepoRoot $RepoRoot -Entries $present -Reader $tree.Reader
        if ($closure.Problems.Count -gt 0) { throw "The GUI closure walk failed $($tree.Where): $($closure.Problems -join '; ')" }
        foreach ($member in $closure.Members) { [void]$list.Add($member) }
    }
    foreach ($entry in $entries) { [void]$list.Add($entry) }
    return [string[]]@($list)
}

function Get-CiGuiSelection {
    <#
    .SYNOPSIS
    True when the changed paths need the GUI suite: an empty list (no diff to read), any `zig` path, or any path in
    the GUI list.
    #>
    param([string[]] $ChangedPaths, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $GuiList)
    $files = @($ChangedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-CiRepoPath $_ })
    if ($files.Count -eq 0) { return $true }
    $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$GuiList, [StringComparer]::Ordinal)
    foreach ($file in $files) {
        if ((Get-CiPathNeeds $file) -ceq 'zig') { return $true }
        if ($set.Contains($file)) { return $true }
    }
    return $false
}

if ($script:CiGuiArguments.LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
$EventName = $script:CiGuiArguments.EventName
$BaseSha = $script:CiGuiArguments.BaseSha
$HeadSha = $script:CiGuiArguments.HeadSha
$Paths = $script:CiGuiArguments.Paths
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gui = $true
$reason = "event '$EventName' runs the suite"
try {
    if ($script:CiGuiArguments.PathsGiven) {
        $priorRefs = $(if (-not [string]::IsNullOrWhiteSpace($BaseSha) -and -not [string]::IsNullOrWhiteSpace($HeadSha)) { Get-CiGuiPriorRefs -RepoRoot $repoRoot -Base $BaseSha -Head $HeadSha } else { @($BaseSha) })
        $list = Get-CiGuiList -RepoRoot $repoRoot -BaseRef $priorRefs
        $gui = Get-CiGuiSelection -ChangedPaths $Paths -GuiList $list
        $reason = "$(@($Paths).Count) listed path(s)"
    }
    elseif ($EventName -eq 'pull_request') {
        if ([string]::IsNullOrWhiteSpace($BaseSha) -or [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw 'A pull request run needs -BaseSha and -HeadSha.'
        }
        $changed = Get-CiChangedPaths -Base $BaseSha -Head $HeadSha
        $priorRefs = Get-CiGuiPriorRefs -RepoRoot $repoRoot -Base $BaseSha -Head $HeadSha
        $list = Get-CiGuiList -RepoRoot $repoRoot -BaseRef $priorRefs
        $gui = Get-CiGuiSelection -ChangedPaths $changed -GuiList $list
        $reason = "$($changed.Count) changed path(s) in $BaseSha...$HeadSha, $($list.Count) GUI path(s) over the head and $($priorRefs.Count) prior tree(s)"
        $summaryLines = @('### Hidden-desktop GUI suite', '', "gui=$($gui.ToString().ToLowerInvariant()) ($reason).", '')
        if ($changed.Count -le 40) {
            $summaryLines += $changed | ForEach-Object {
                $why = $(if ((Get-CiPathNeeds $_) -ceq 'zig') { 'zig' } elseif ($list -ccontains (ConvertTo-CiRepoPath $_)) { 'gui list' } else { '-' })
                '- `{0}` -> {1}' -f $_, $why
            }
        }
        if ($env:GITHUB_STEP_SUMMARY) { Add-CiFileLine -Path $env:GITHUB_STEP_SUMMARY -Line $summaryLines }
    }
}
catch {
    # Deciding is an optimisation. When it fails, run the suite.
    Write-Warning "Could not decide from the diff ($($_.Exception.Message)); running the GUI suite."
    $gui = $true
    $reason = 'selection unavailable'
}

Write-Host "GUI suite selection ($reason)"
Write-CiOutput -Name 'gui' -Value $gui.ToString().ToLowerInvariant()
# A failed `git diff` was handled above, but Actions ends a pwsh step with `exit $LASTEXITCODE` (PKG-65).
$global:LASTEXITCODE = 0
