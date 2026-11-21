#requires -Version 7.0
<#
.SYNOPSIS
Decides whether a pull request needs the hidden-desktop GUI suite (.github/workflows/gui-hidden.yml).

.DESCRIPTION
`gui` is true when any changed path is one the Zig graph reads (scripts/ci-changed-paths.ps1's `Get-CiPathNeeds`
gives `zig`, which includes every path its table does not name) or is in the GUI list. This script never changes
that classifier, and test.yml's ten outputs stay what they were: only gui-hidden.yml calls it (design v7 §4.5).

The GUI list is computed, never kept by hand: the closure (scripts/ci-script-closure.ps1) of the runner and of every
leaf in test/windows/gui-hidden-plan.json, plus the plan, the flagship scenario, the workflow, this script, the
walker, the fixtures, the suite's contract fragment and the plan's `buildInputs` (what the hosted build preparation
reads through edges no walk shows, such as scripts/dev-windows.cmd). On a pull request it is walked over the head
tree and over the base tree, so a member a change deletes or renames away still counts.

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
# Members that no edge reaches: the suite's own definition and the selection that runs it.
$script:CiGuiFixedMembers = @(
    'test/windows/gui-hidden-plan.json'
    'test/windows/flagship/scenarios/gui-hidden.json'
    '.github/workflows/gui-hidden.yml'
    'scripts/ci-gui-selection.ps1'
    'scripts/ci-script-closure.ps1'
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

function Get-CiGuiList {
    <#
    .SYNOPSIS
    The computed GUI list: repo-relative paths, sorted. With -BaseRef, the union of the head tree (the working tree)
    and that ref's tree. Throws when a walk fails, so the caller can run the suite. -HeadReader and -BaseReader
    (param([string] $RepoPath) returning text or $null) replace the two trees, for the tests.
    #>
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $BaseRef,
        [scriptblock] $HeadReader,
        [scriptblock] $BaseReader
    )
    $list = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($member in $script:CiGuiFixedMembers) { [void]$list.Add($member) }
    $trees = @(@{ Ref = $null; Reader = $HeadReader })
    if (-not [string]::IsNullOrWhiteSpace($BaseRef) -or $BaseReader) { $trees += @{ Ref = $BaseRef; Reader = $BaseReader } }
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
    foreach ($plan in $plans) {
        foreach ($leaf in @($plan.leaves)) { [void]$entries.Add([string]$leaf.script) }
        foreach ($buildInput in @($plan.buildInputs)) { [void]$list.Add([string]$buildInput) }
    }
    foreach ($tree in $trees) {
        # An entry a tree does not have (a new leaf, on the base side) has nothing to walk there.
        $present = @($entries | Where-Object { $null -ne (& $tree.Reader $_) })
        if ($present.Count -eq 0) { continue }
        $closure = Get-ScriptClosure -RepoRoot $RepoRoot -Entries $present -Reader $tree.Reader
        if ($closure.Problems.Count -gt 0) {
            $where = $(if ([object]::ReferenceEquals($tree, $trees[0])) { 'in the head tree' } else { "in the base tree $($tree.Ref)" })
            throw "The GUI closure walk failed $where`: $($closure.Problems -join '; ')"
        }
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
        $list = Get-CiGuiList -RepoRoot $repoRoot -BaseRef $BaseSha
        $gui = Get-CiGuiSelection -ChangedPaths $Paths -GuiList $list
        $reason = "$(@($Paths).Count) listed path(s)"
    }
    elseif ($EventName -eq 'pull_request') {
        if ([string]::IsNullOrWhiteSpace($BaseSha) -or [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw 'A pull request run needs -BaseSha and -HeadSha.'
        }
        $changed = Get-CiChangedPaths -Base $BaseSha -Head $HeadSha
        $list = Get-CiGuiList -RepoRoot $repoRoot -BaseRef $BaseSha
        $gui = Get-CiGuiSelection -ChangedPaths $changed -GuiList $list
        $reason = "$($changed.Count) changed path(s) in $BaseSha...$HeadSha, $($list.Count) GUI path(s)"
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
