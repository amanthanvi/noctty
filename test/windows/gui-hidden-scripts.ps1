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
    # A reader over a table of repo paths, with a Lister note as New-CiScriptFileReader's readers have (the files in a
    # directory, matched case-insensitively). Pass -NoLister for a reader that lists nothing, as a wrapping reader is.
    param([hashtable] $Files, [switch] $NoLister)
    $reader = { param([string] $RepoPath) if ($Files.ContainsKey($RepoPath)) { return $Files[$RepoPath] } return $null }.GetNewClosure()
    if (-not $NoLister) {
        $lister = {
            param([string] $RepoDirectory)
            foreach ($key in @($Files.Keys)) {
                $cut = $key.LastIndexOf('/')
                $parent = $(if ($cut -ge 0) { $key.Substring(0, $cut) } else { '' })
                if ([string]::Equals($parent, $RepoDirectory, [StringComparison]::OrdinalIgnoreCase)) { $key }
            }
        }.GetNewClosure()
        $reader.PSObject.Properties.Add([psnoteproperty]::new('Lister', $lister))
    }
    return $reader
}

$fakeRoot = 'C:\gui-hidden-fixture'
function Get-FixtureWalk {
    param([hashtable] $Files, [string[]] $Entries = @('test/windows/entry.ps1'), [object[]] $LegacyEdges = @(), [switch] $NoLister)
    return Get-ScriptClosure -RepoRoot $fakeRoot -Entries $Entries -Reader (New-TableReader $Files -NoLister:$NoLister) -LegacyEdges $LegacyEdges
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
}
Assert-True ($walk.Problems.Count -eq 0) "The constant compositions, callbacks, native calls and -File on another cmdlet must walk cleanly: $($walk.Problems -join '; ')"
foreach ($member in @('scripts/lib.ps1', 'test/windows/helper.ps1', 'test/windows/expandable.ps1', 'test/windows/native.cs')) {
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

# Every value a run can give a variable where it is read must agree (Greptile, CodeRabbit and Sol on #740). An
# unconditional reassignment replaces what came before (the fast path); a write in a branch, loop, try, scriptblock,
# function or through a scope qualifier only adds a value. 'a.ps1' and 'b.ps1' sit beside the entry; Resolves names
# the one target the walk must take, or $null for an edge it must refuse.
$flowCases = @(
    @{ Name = 'an unconditional reassignment'; Resolves = 'b.ps1'; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; $p = Join-Path $PSScriptRoot ''b.ps1''; . $p' }
    @{ Name = 'a conditional reassignment'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; if ($env:X) { $p = Join-Path $PSScriptRoot ''b.ps1'' }; . $p' }
    @{ Name = 'two literal targets, one in an optional branch'; Resolves = $null; Text = '$t = "$PSScriptRoot\a.ps1"' + "`n" + 'if ($Optional) {' + "`n" + '    $t = "$PSScriptRoot\b.ps1"' + "`n" + '}' + "`n" + '& $t' }
    @{ Name = 'a write only in a branch'; Resolves = $null; Text = 'if ($env:X) { $p = Join-Path $PSScriptRoot ''a.ps1'' }; . $p' }
    @{ Name = 'a write and its read in one branch'; Resolves = 'a.ps1'; Text = 'if ($env:X) { $p = Join-Path $PSScriptRoot ''a.ps1''; . $p }' }
    @{ Name = 'a write and its read in one try'; Resolves = 'a.ps1'; Text = 'try { $p = Join-Path $PSScriptRoot ''a.ps1''; . $p } finally { }' }
    @{ Name = 'a write in a try read after it'; Resolves = $null; Text = 'try { $p = Join-Path $PSScriptRoot ''a.ps1'' } catch { }; . $p' }
    @{ Name = 'a later write in a loop around the read'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; foreach ($i in 1..2) { . $p; $p = Join-Path $PSScriptRoot ''b.ps1'' }' }
    @{ Name = 'a write before the read in the same loop pass'; Resolves = 'b.ps1'; Text = 'while ($true) { $p = Join-Path $PSScriptRoot ''b.ps1''; . $p; $p = Join-Path $PSScriptRoot ''a.ps1''; break }' }
    @{ Name = 'a later write before a scriptblock runs'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; $run = { . $p }; $p = Join-Path $PSScriptRoot ''b.ps1''; & $run' }
    @{ Name = 'a $script: write in a function'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; function Set-P { $script:p = Join-Path $PSScriptRoot ''b.ps1'' }; Set-P; . $p' }
    @{ Name = 'a caller''s variable read in a function'; Resolves = $null; Text = 'function Load { . $p }; function Main { $p = Join-Path $PSScriptRoot ''b.ps1''; Load }; $p = Join-Path $PSScriptRoot ''a.ps1''; Main' }
    @{ Name = 'a script variable a function reads'; Resolves = 'a.ps1'; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; function Load { . $p }; Load' }
    @{ Name = 'a conditional write in a function over a script value'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; function Load { if ($env:X) { $p = Join-Path $PSScriptRoot ''b.ps1'' }; . $p }; Load' }
    @{ Name = 'a parameter with a default'; Resolves = $null; Text = 'function Load([string] $Path = (Join-Path $PSScriptRoot ''a.ps1'')) { . $Path }; Load -Path (Join-Path $PSScriptRoot ''b.ps1'')' }
    @{ Name = 'a multiple assignment'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; $p, $q = (Join-Path $PSScriptRoot ''b.ps1''), 1; . $p' }
    @{ Name = 'Set-Variable'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; Set-Variable -Name p -Value (Join-Path $PSScriptRoot ''b.ps1''); . $p' }
    @{ Name = 'a property assigned after its hashtable'; Resolves = $null; Text = '$t = @{ Path = (Join-Path $PSScriptRoot ''a.ps1'') }; $t.Path = Join-Path $PSScriptRoot ''b.ps1''; . $t.Path' }
    @{ Name = 'a module-qualified Set-Variable'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; Microsoft.PowerShell.Utility\Set-Variable -Name p -Value (Join-Path $PSScriptRoot ''b.ps1''); . $p' }
    @{ Name = 'a prefix of -OutVariable naming it'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; Get-ChildItem -LiteralPath $PSScriptRoot -OutVar p | Out-Null; . $p' }
    @{ Name = 'an -OutVariable whose name is not a literal'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; $n = ''p''; Get-ChildItem -LiteralPath $PSScriptRoot -OutVariable $n | Out-Null; . $p' }
    @{ Name = 'an -OutBuffer, which writes no variable'; Resolves = 'a.ps1'; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; Get-ChildItem -LiteralPath $PSScriptRoot -OutBuffer 1 | Out-Null; . $p' }
    # Scope qualifiers at script level (Opus on #740). A -File entry runs in the global scope, so `$p`, `$script:p`
    # and `$global:p` are one variable there; under & the global one is apart, and dot-sourced in a function so is the
    # script's. A read whose ways disagree is refused; one they agree on resolves.
    @{ Name = 'a $global: write after the script''s (b under -File, a under &)'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; $global:p = Join-Path $PSScriptRoot ''b.ps1''; & $p' }
    @{ Name = 'a $global: write before the script''s'; Resolves = 'a.ps1'; Text = '$global:p = Join-Path $PSScriptRoot ''b.ps1''; $p = Join-Path $PSScriptRoot ''a.ps1''; & $p' }
    @{ Name = 'only a $global: write'; Resolves = 'b.ps1'; Text = '$global:p = Join-Path $PSScriptRoot ''b.ps1''; & $p' }
    @{ Name = 'a $script: write after an unqualified one (a dot-sourced in a function)'; Resolves = $null; Text = '$p = Join-Path $PSScriptRoot ''a.ps1''; $script:p = Join-Path $PSScriptRoot ''b.ps1''; & $p' }
    @{ Name = 'only a $script: write'; Resolves = 'b.ps1'; Text = '$script:p = Join-Path $PSScriptRoot ''b.ps1''; & $p' }
)
foreach ($case in $flowCases) {
    $flowWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $case.Text; 'test/windows/a.ps1' = '1'; 'test/windows/b.ps1' = '2' }
    $taken = @($flowWalk.Members | Where-Object { $_ -cin @('test/windows/a.ps1', 'test/windows/b.ps1') })
    if ($case.Resolves) {
        Assert-True ($flowWalk.Problems.Count -eq 0 -and ($taken -join ',') -ceq "test/windows/$($case.Resolves)") "$($case.Name) must resolve to $($case.Resolves) alone: [$($taken -join ', ')] $($flowWalk.Problems -join '; ')"
    } else {
        Assert-True ($flowWalk.Problems.Count -ge 1 -and $taken.Count -eq 0) "$($case.Name) must leave the edge unresolved, neither target taken: [$($taken -join ', ')] $($flowWalk.Problems -join '; ')"
    }
}

# Join-Path's forms (CodeRabbit on #740): a named -Path with one positional child, both positional, both named in
# either order, and more children after the first. Each must reach its own target.
$joinForms = [ordered]@{
    'named -Path, positional child' = '. (Join-Path -Path $PSScriptRoot ''join-a.ps1'')'
    'all positional' = '. (Join-Path $PSScriptRoot ''join-b.ps1'')'
    'named -ChildPath first' = '. (Join-Path -ChildPath ''join-c.ps1'' -Path $PSScriptRoot)'
    'named -ChildPath, positional parent' = '. (Join-Path -ChildPath ''join-d.ps1'' $PSScriptRoot)'
    'more children' = '. (Join-Path $PSScriptRoot ''join'' ''join-e.ps1'')'
}
$joinTargets = @{
    'named -Path, positional child' = 'test/windows/join-a.ps1'
    'all positional' = 'test/windows/join-b.ps1'
    'named -ChildPath first' = 'test/windows/join-c.ps1'
    'named -ChildPath, positional parent' = 'test/windows/join-d.ps1'
    'more children' = 'test/windows/join/join-e.ps1'
}
foreach ($form in $joinForms.Keys) {
    $joinWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $joinForms[$form]; $joinTargets[$form] = '1' }
    Assert-True ($joinWalk.Problems.Count -eq 0 -and $joinWalk.Members -ccontains $joinTargets[$form]) "Join-Path, $form, must reach $($joinTargets[$form]): $($joinWalk.Problems -join '; ')"
}
$joinResolve = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '. (Join-Path -Resolve $PSScriptRoot ''join-*.ps1'')' }
Assert-True ($joinResolve.Problems.Count -eq 1 -and $joinResolve.Unresolved.Count -eq 1) "Join-Path -Resolve (wildcards) must be unresolved: $($joinResolve.Problems -join '; ')"

# A relative target resolves at run time against the current location, not beside the script (CodeRabbit on #740):
# with a helper.ps1 both beside the nested script and at the repository root (the runner's working directory), the
# walk must take neither, and fail. Each relative form is refused; $MyInvocation.MyCommand.Path anchors like
# $PSScriptRoot.
$relativeFiles = @{ 'test/windows/nested/helper.ps1' = '1'; 'helper.ps1' = '2'; 'test/windows/nested/x.cs' = 'class X {}' }
foreach ($relative in @('. ./helper.ps1', '. .\helper.ps1', '& .\helper.ps1', '. helper.ps1', '. ..\nested\helper.ps1', 'pwsh -NoProfile -File ./helper.ps1', 'cmd /c helper.cmd', 'Add-Type -Path x.cs', '$h = ''./helper.ps1''; . $h')) {
    $files = $relativeFiles.Clone()
    $files['test/windows/nested/entry.ps1'] = $relative
    $relativeWalk = Get-FixtureWalk -Files $files -Entries @('test/windows/nested/entry.ps1')
    Assert-True ($relativeWalk.Problems.Count -eq 1 -and $relativeWalk.Unresolved.Count -eq 1 -and $relativeWalk.Members -cnotcontains 'test/windows/nested/helper.ps1' -and $relativeWalk.Members -cnotcontains 'helper.ps1') "The relative target in '$relative' must be unresolved, neither helper taken: $($relativeWalk.Problems -join '; ') [$($relativeWalk.Members -join ', ')]"
}
foreach ($anchored in @('. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) ''helper.ps1'')', '. (Join-Path (Split-Path $MyInvocation.MyCommand.Path) ''helper.ps1'')', '. "$PSScriptRoot\helper.ps1"')) {
    $files = $relativeFiles.Clone()
    $files['test/windows/nested/entry.ps1'] = $anchored
    $anchoredWalk = Get-FixtureWalk -Files $files -Entries @('test/windows/nested/entry.ps1')
    Assert-True ($anchoredWalk.Problems.Count -eq 0 -and $anchoredWalk.Members -ccontains 'test/windows/nested/helper.ps1' -and $anchoredWalk.Members -cnotcontains 'helper.ps1') "The anchored target in '$anchored' must reach the helper beside the script: $($anchoredWalk.Problems -join '; ')"
}
$functionInvocation = Get-FixtureWalk -Files @{ 'test/windows/entry.ps1' = 'function Load { . (Join-Path (Split-Path $MyInvocation.MyCommand.Path) ''helper.ps1'') }'; 'test/windows/helper.ps1' = '1' }
Assert-True ($functionInvocation.Problems.Count -eq 1) "`$MyInvocation.MyCommand.Path in a function names the function, not the file, and must be unresolved: $($functionInvocation.Problems -join '; ')"

# The ways a script runs another (Sol, CodeRabbit and Opus on #740): each form must reach its child, or leave the
# edge unresolved; none may drop it. A PowerShell reached through a variable or Get-Command is PowerShell; an
# executable the walker cannot name is unresolved when its arguments may run a script.
$fixtureChild = 'C:\gui-hidden-fixture\test\windows\child.ps1'
$reaches = [ordered]@{
    'pwsh from Get-Command .Source through a variable, -File' = '$pwsh = (Get-Command pwsh.exe).Source' + "`n" + '& $pwsh -NoProfile -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'Windows PowerShell from Get-Command through a variable, -File' = '$ps = Get-Command powershell.exe -CommandType Application; & $ps -ExecutionPolicy Bypass -File "$PSScriptRoot\child.ps1"'
    'pwsh joined to an unknown directory, -File:' = '$pwsh = Join-Path $PSHOME ''pwsh.exe''; & $pwsh -NoLogo -File:"$PSScriptRoot\child.ps1"'
    'pwsh''s first positional argument' = 'pwsh -NoProfile -ExecutionPolicy Bypass (Join-Path $PSScriptRoot ''child.ps1'') -Arg 1'
    'a bare absolute path' = "$fixtureChild -Arg 1"
    'Start-Job -FilePath' = 'Start-Job -FilePath (Join-Path $PSScriptRoot ''child.ps1'') | Receive-Job -Wait'
    'Invoke-Command -FilePath' = 'Invoke-Command -ComputerName localhost -FilePath "$PSScriptRoot\child.ps1"'
    'Invoke-Expression of a literal' = 'Invoke-Expression ". ''$PSScriptRoot\child.ps1''"'
    'a local function returning the path' = 'function Get-ChildPath { Join-Path $PSScriptRoot ''child.ps1'' }' + "`n" + '& (Get-ChildPath)'
    'Import-Module of a script path' = 'Import-Module (Join-Path $PSScriptRoot ''child.ps1'') -Force'
}
foreach ($form in $reaches.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $reaches[$form]; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains 'test/windows/child.ps1') "$form must reach the child: $($formWalk.Problems -join '; ')"
}
$refuses = [ordered]@{
    'an executable Get-Command cannot name, -File' = '$exe = (Get-Command $toolName).Source; & $exe -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'a local Get-*ExePath whose body is more than one value' = 'function Get-FixtureExePath { if ($env:X) { return ''C:\x\noctty.exe'' }; return (Join-Path $PSScriptRoot ''child.ps1'') }' + "`n" + '& (Get-FixtureExePath)'
    'a pwsh from Get-Command with -Command' = '$pwsh = Get-Command pwsh; & $pwsh -NoProfile -Command ". ./child.ps1"'
    'Windows PowerShell''s first positional argument (its -Command)' = 'powershell.exe -NoProfile (Join-Path $PSScriptRoot ''child.ps1'')'
    'Start-Process pwsh with an argument list in a variable' = 'Start-Process -FilePath pwsh.exe -ArgumentList $argv'
    'Start-Process pwsh with -Command' = 'Start-Process pwsh -ArgumentList ''-Command'', ''Get-Date'''
    'Start-Process of an executable it cannot resolve' = 'Start-Process -FilePath $unknown -PassThru'
    'Start-Job -FilePath of an unresolved path' = 'Start-Job -FilePath $script'
    'Invoke-Expression of file content' = 'Invoke-Expression (Get-Content -Raw (Join-Path $PSScriptRoot ''child.ps1''))'
    'Invoke-Expression from the pipeline' = 'Get-Content (Join-Path $PSScriptRoot ''child.ps1'') | Invoke-Expression'
    '[scriptblock]::Create of a variable' = '$block = [scriptblock]::Create($text); & $block'
    'Import-Module of an unresolved path' = 'Import-Module $modulePath'
    'a bare relative path' = '.\child.ps1'
}
foreach ($form in $refuses.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $refuses[$form]; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1) "$form must leave its edge unresolved: [$($formWalk.Members -join ', ')]"
}
$quiet = [ordered]@{
    'a helper-named executable with an argument list' = '$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot; Start-Process -FilePath $exe -ArgumentList $argv -PassThru'
    'a module-qualified cmdlet' = 'Microsoft.PowerShell.Utility\Write-Host x'
    'Invoke-Expression of code with no edge' = 'Invoke-Expression ''Get-Date'''
    'Import-Module by name' = 'Import-Module Microsoft.PowerShell.Utility'
    'a function named like Invoke-Command' = 'Invoke-CommandPaletteAction -Action 1'
    'git found by Get-Command' = '$git = (Get-Command git.exe -CommandType Application | Select-Object -First 1).Source; & $git status'
    'Start-Process of a known executable' = 'Start-Process -FilePath (Join-Path $PSScriptRoot ''tool.exe'') -ArgumentList ''-File'', ''x.ps1'''
}
foreach ($form in $quiet.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $quiet[$form] }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members.Count -eq 1) "$form is no script edge: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}

# An empty (zero-byte) file has no edges and is a member like any other (CodeRabbit on #740: the parser's mandatory
# text refused '', and that binding error failed the walk); empty literal code is quiet; a file that does not exist
# still fails the walk as missing.
$emptyWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '. (Join-Path $PSScriptRoot ''empty.ps1''); Invoke-Expression '''''; 'test/windows/empty.ps1' = '' }
Assert-True ($emptyWalk.Problems.Count -eq 0 -and $emptyWalk.Members -ccontains 'test/windows/empty.ps1') "An empty helper and empty literal code must walk cleanly: $($emptyWalk.Problems -join '; ') [$($emptyWalk.Members -join ', ')]"
$emptyEntry = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '' }
Assert-True ($emptyEntry.Problems.Count -eq 0 -and $emptyEntry.Members.Count -eq 1) "An empty entry must walk cleanly: $($emptyEntry.Problems -join '; ')"
$emptyMissing = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '. (Join-Path $PSScriptRoot ''empty.ps1'')' }
Assert-True ($emptyMissing.Problems.Count -eq 1 -and $emptyMissing.Missing -ccontains 'test/windows/empty.ps1') 'A helper that does not exist must still fail the walk as missing, not read as empty.'

# A module-qualified cmdlet (Microsoft.PowerShell.Utility\Add-Type) runs what its bare name runs, so it is the same
# edge (CodeRabbit on #740: a qualified Add-Type -Path was skipped and its C# file left the closure); a qualified
# Set-Variable is a write the resolver cannot read (in the flow cases above). PowerShell resolves no qualified alias
# (`Microsoft.PowerShell.Utility\iex` is not a command), so only the Verb-Noun shape is qualified. An unrelated
# qualified cmdlet stays out (the quiet forms above).
$qualifiedReaches = [ordered]@{
    'a module-qualified Add-Type -Path' = @('Microsoft.PowerShell.Utility\Add-Type -Path (Join-Path $PSScriptRoot ''native.cs'')', 'test/windows/native.cs')
    'a module-qualified Import-Module' = @('Microsoft.PowerShell.Core\Import-Module (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    # Opus on #740 (round 11): a qualified Start-Process of a script still lists it; of PowerShell it is refused.
    'a module-qualified Start-Process' = @('Microsoft.PowerShell.Management\Start-Process (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    'a module-qualified Start-Job' = @('Microsoft.PowerShell.Core\Start-Job -FilePath "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'a module-qualified Invoke-Expression' = @('Microsoft.PowerShell.Utility\Invoke-Expression ". ''$PSScriptRoot\child.ps1''"', 'test/windows/child.ps1')
    'a module-qualified Start-ThreadJob' = @('Microsoft.PowerShell.ThreadJob\Start-ThreadJob -FilePath "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'a module-qualified Invoke-Command' = @('Microsoft.PowerShell.Core\Invoke-Command -ComputerName localhost -FilePath "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'a module-qualified Join-Path in a load' = @('. (Microsoft.PowerShell.Management\Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    'a module-qualified cmdlet called with &' = @('& Microsoft.PowerShell.Core\Import-Module (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
}
foreach ($form in $qualifiedReaches.Keys) {
    $text, $target = $qualifiedReaches[$form]
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $text; 'test/windows/child.ps1' = '1'; 'test/windows/native.cs' = 'class X {}' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains $target) "$form must reach $target`: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
$qualifiedVariable = Get-FixtureWalk @{ 'test/windows/entry.ps1' = 'Microsoft.PowerShell.Utility\Invoke-Expression $code' }
Assert-True ($qualifiedVariable.Problems.Count -eq 1 -and $qualifiedVariable.Unresolved.Count -eq 1) "A module-qualified Invoke-Expression of a variable must be unresolved: $($qualifiedVariable.Problems -join '; ')"
$qualifiedQuiet = Get-FixtureWalk @{ 'test/windows/entry.ps1' = 'Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $PSScriptRoot -File; Microsoft.PowerShell.Utility\Write-Output (Join-Path $PSScriptRoot ''child.ps1'')' }
Assert-True ($qualifiedQuiet.Problems.Count -eq 0 -and $qualifiedQuiet.Members.Count -eq 1) "Unrelated module-qualified cmdlets are no edge: $($qualifiedQuiet.Problems -join '; ') [$($qualifiedQuiet.Members -join ', ')]"

# A cmdlet's arguments are bound as PowerShell binds them before the walker picks the code or the file (CodeRabbit on
# #740: `Invoke-Expression -ErrorAction Stop -Command <code>` scanned `Stop` as the code and never read -Command).
# PowerShell names a parameter by its name or an alias, exactly or by a prefix that names one parameter, aliases
# included (`-LP`, `-l` and `-PSPath` are Start-Job's -LiteralPath; `-v` is -Verbose); every cmdlet also takes the
# common parameters; a switch takes no argument. A name the walker cannot bind leaves the edge unresolved. pwsh's own
# command line is bound by pwsh's parser: `-in` is -Interactive there (Windows PowerShell's -InputFormat), and
# Windows PowerShell runs the rest of its line as code after a parameter only pwsh has (-SettingsFile).
$boundReaches = [ordered]@{
    'Invoke-Expression -ErrorAction Stop -Command <code>' = @('Invoke-Expression -ErrorAction Stop -Command ''. (Join-Path $PSScriptRoot "child.ps1")''', 'test/windows/child.ps1')
    'Invoke-Expression with every common parameter before its positional code' = @('Invoke-Expression -WarningAction SilentlyContinue -InformationAction Ignore -ErrorVariable e -OutVariable o -PipelineVariable p -OutBuffer 1 -ProgressAction Ignore -Verbose -Debug:$false ". ''$PSScriptRoot\child.ps1''"', 'test/windows/child.ps1')
    'Invoke-Expression with abbreviated parameters' = @('Invoke-Expression -ea Stop -pr Ignore -v -c ". ''$PSScriptRoot\child.ps1''"', 'test/windows/child.ps1')
    'Start-Process with common parameters' = @('Start-Process -ErrorAction Stop -FilePath (Join-Path $PSScriptRoot ''child.ps1'') -Verbose', 'test/windows/child.ps1')
    'Start-Job -LP (an alias of -LiteralPath)' = @('Start-Job -LP "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Start-Job -l (a prefix of -LiteralPath)' = @('Start-Job -l "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Start-Job -Verbose, then its positional file' = @('Start-Job -Verbose "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Invoke-Command -PSPath (an alias of -FilePath)' = @('Invoke-Command -ComputerName localhost -PSPath "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Import-Module after common parameters' = @('Import-Module -Verbose -ErrorAction Stop (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    'Add-Type -LP (an alias of -LiteralPath)' = @('Add-Type -LP (Join-Path $PSScriptRoot ''native.cs'')', 'test/windows/native.cs')
    'Add-Type -PSPath (an alias of -LiteralPath)' = @('Add-Type -ErrorAction Stop -PSPath (Join-Path $PSScriptRoot ''native.cs'')', 'test/windows/native.cs')
    'pwsh -in (its -Interactive), then the file' = @('pwsh -NoProfile -in (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    'pwsh -token <value>, then -File' = @('pwsh -NoProfile -token t -File (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    # CodeRabbit on #740: the second positional is -InitializationScript, so a block there must not hide the file.
    'Start-Job <file> <initialization block>' = @('Start-Job (Join-Path $PSScriptRoot ''child.ps1'') { 1 }', 'test/windows/child.ps1')
    'Start-ThreadJob <file> <initialization block>' = @('Start-ThreadJob (Join-Path $PSScriptRoot ''child.ps1'') { 1 }', 'test/windows/child.ps1')
}
foreach ($form in $boundReaches.Keys) {
    $text, $target = $boundReaches[$form]
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $text; 'test/windows/child.ps1' = '1'; 'test/windows/native.cs' = 'class X {}' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains $target) "$form must reach $target`: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
$boundRefuses = [ordered]@{
    'Invoke-Expression with an ambiguous parameter (-e: -ErrorAction or -ErrorVariable)' = 'Invoke-Expression -e Stop ". ''$PSScriptRoot\child.ps1''"'
    'Invoke-Expression with a parameter it does not have' = 'Invoke-Expression -NoSuchParameter x ". ''$PSScriptRoot\child.ps1''"'
    'Invoke-Expression with a splat' = 'Invoke-Expression @iexArguments'
    'Invoke-Expression with a value parameter and no value' = 'Invoke-Expression -ErrorAction'
    'Start-Job of an unresolved positional path' = 'Start-Job $script'
    'Start-ThreadJob of an unresolved positional path' = 'Start-ThreadJob $script'
    'Start-Job of an unresolved file before an initialization block' = 'Start-Job $script { 1 }'
    # Sol on #740: a PowerShell found by a wildcard or fuzzy Get-Command is an executable the walker cannot name.
    'pwsh found by Get-Command with a ? wildcard, then -File' = '$p = (Get-Command -Name "pwsh.ex?" -CommandType Application | Select-Object -First 1).Source; & $p -NoProfile -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'pwsh found by Get-Command pwsh*, then -File' = '& (Get-Command pwsh* | Select-Object -First 1).Source -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'pwsh found by a fuzzy Get-Command, then -File' = '$p = (Get-Command -UseFuzzyMatching pwsh).Source; & $p -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'Invoke-Command of an unresolved positional path after -ComputerName' = 'Invoke-Command -ComputerName localhost $script'
    'Add-Type with a splat' = 'Add-Type @typeArguments'
    'Add-Type -LiteralPath of an unresolved path' = 'Add-Type -LiteralPath $source'
    'Windows PowerShell after -SettingsFile, which only pwsh has' = 'powershell.exe -NoProfile -SettingsFile (Join-Path $PSScriptRoot ''child.ps1'')'
}
foreach ($form in $boundRefuses.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $boundRefuses[$form]; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1) "$form must leave its edge unresolved: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
$boundQuiet = [ordered]@{
    'Invoke-Expression with common parameters and code with no edge' = 'Invoke-Expression -ErrorAction Stop -Command ''Get-Date'''
    'Start-Job of a scriptblock after -Verbose' = 'Start-Job -Verbose -ScriptBlock { 1 }'
    'Start-ThreadJob of a positional scriptblock' = 'Start-ThreadJob { 1 }'
    'Start-Job <block> <initialization block>' = 'Start-Job { 1 } { 2 }'
    'Invoke-Command of a scriptblock on a session' = 'Invoke-Command -Session $session -ScriptBlock { 1 }'
    'Invoke-Command with a positional scriptblock' = 'Invoke-Command $session { 1 }'
    'Add-Type of an assembly, with -ErrorAction' = 'Add-Type -AssemblyName System.Drawing -ErrorAction Stop'
    'Add-Type of source text by position' = 'Add-Type ''public class Fixture {}'''
}
foreach ($form in $boundQuiet.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $boundQuiet[$form] }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members.Count -eq 1) "$form is no script edge: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}

# A name that stands for a command (Opus on #740, each measured dropping its script without a problem): Get-Command of
# a name that is not a literal is read like any other value; an alias's value (Set-Alias, New-Alias, sal, nal,
# `$alias:`) and a PowerShell object's AddCommand argument are the command the name stands for, and AddScript is code.
# A script is an edge; a native program or a cmdlet the walker does not read by name is none; a value it cannot read,
# PowerShell or cmd (whose arguments come later), and a command it reads by name are unresolved.
$namedReaches = [ordered]@{
    'Get-Command of a joined script path, then &' = '$c = Get-Command (Join-Path $PSScriptRoot ''child.ps1''); & $c'
    'Get-Command -Name of an expandable script path, then its .Source' = '& (Get-Command -Name "$PSScriptRoot\child.ps1").Source -Arg 1'
    'Set-Alias to a script, then the alias' = 'Set-Alias go (Join-Path $PSScriptRoot ''child.ps1''); go'
    'New-Alias -Name -Value to a script' = 'New-Alias -Name go -Value "$PSScriptRoot\child.ps1"; go -Arg 1'
    'sal with a named -Value before the positional name' = 'sal -Value (Join-Path $PSScriptRoot ''child.ps1'') go; go'
    'nal with -Force' = 'nal go "$PSScriptRoot\child.ps1" -Force; go'
    'a module-qualified Set-Alias' = 'Microsoft.PowerShell.Utility\Set-Alias go (Join-Path $PSScriptRoot ''child.ps1''); go'
    'an alias assigned through its drive' = '$alias:go = Join-Path $PSScriptRoot ''child.ps1''; go'
    '[PowerShell]::Create().AddCommand of a script' = '[PowerShell]::Create().AddCommand((Join-Path $PSScriptRoot ''child.ps1'')).Invoke()'
    'AddCommand of a Get-Command script' = '$ps = [PowerShell]::Create(); $ps.AddCommand((Get-Command (Join-Path $PSScriptRoot ''child.ps1''))).Invoke()'
    '[System.Management.Automation.PowerShell] AddScript of literal code' = '$ps = [System.Management.Automation.PowerShell]::Create(); [void]$ps.AddScript(". ''$PSScriptRoot\child.ps1''"); $ps.Invoke()'
    # Opus on #740: PowerShell takes an extensionless path to its .ps1 (measured on pwsh 7.6 and Windows PowerShell 5.1).
    'Get-Command of an extensionless script path, then &' = '$c = Get-Command (Join-Path $PSScriptRoot ''child''); & $c'
    'Get-Command of an extensionless expandable path, called at once' = '& (Get-Command "$PSScriptRoot\child")'
    '& of an extensionless joined path' = '& (Join-Path $PSScriptRoot ''child'')'
}
foreach ($form in $namedReaches.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $namedReaches[$form]; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains 'test/windows/child.ps1') "$form must reach the child: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
$namedRefuses = [ordered]@{
    'Get-Command of a name it cannot read, then &' = '$c = Get-Command $name; & $c'
    'Get-Command of a wildcard script path, then &' = '$c = Get-Command (Join-Path $PSScriptRoot ''chil?.ps1''); & $c'
    'Get-Command of a bare script name (a PATH lookup), then &' = '$c = Get-Command child.ps1; & $c'
    # Sol on #740: a wildcard ExternalScript lookup with no extension.
    'Get-Command -CommandType ExternalScript of an extensionless wildcard path, then &' = '$p = Get-Command -Name (Join-Path $PSScriptRoot ''chil*'') -CommandType ExternalScript; & $p'
    'Get-Command of a bare wildcard name, then &' = '$c = Get-Command chil*; & $c'
    'Set-Alias to a value it cannot read' = 'Set-Alias go $somewhere; go'
    'Set-Alias to a relative script' = 'Set-Alias go .\child.ps1; go'
    'Set-Alias to pwsh, whose calls give -File' = 'Set-Alias ps7 pwsh; ps7 -NoProfile -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'Set-Alias to Start-Process, a command read by name' = 'Set-Alias run Start-Process; run pwsh -ArgumentList ''-File'', "$PSScriptRoot\child.ps1"'
    'New-Alias to a module-qualified Invoke-Expression' = 'New-Alias run Microsoft.PowerShell.Utility\Invoke-Expression; run ". ''$PSScriptRoot\child.ps1''"'
    'Set-Alias with a splat' = 'Set-Alias @aliasArguments'
    'Set-Alias with a third positional argument' = 'Set-Alias go (Join-Path $PSScriptRoot ''child.ps1'') extra'
    'an alias defined as an alias: item' = 'Set-Item -Path alias:go -Value (Join-Path $PSScriptRoot ''child.ps1''); go'
    'Import-Alias from a file' = 'Import-Alias -Path (Join-Path $PSScriptRoot ''aliases.csv'')'
    'AddCommand of a value it cannot read' = '[PowerShell]::Create().AddCommand($command).Invoke()'
    'AddCommand of pwsh with -File as arguments' = '[PowerShell]::Create().AddCommand(''pwsh'').AddArgument(''-File'').AddArgument("$PSScriptRoot\child.ps1").Invoke()'
    'AddCommand of Invoke-Expression' = '[PowerShell]::Create().AddCommand(''Invoke-Expression'').AddArgument($code).Invoke()'
    'AddScript of a variable' = '$ps = [PowerShell]::Create(); $ps.AddScript($text).Invoke()'
    'AddScript of file content' = '[PowerShell]::Create().AddScript((Get-Content -Raw (Join-Path $PSScriptRoot ''child.ps1''))).Invoke()'
}
foreach ($form in $namedRefuses.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $namedRefuses[$form]; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1 -and $formWalk.Members -cnotcontains 'test/windows/child.ps1') "$form must leave its edge unresolved, the child not taken: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
# Sol on #740: a path whose leaf is a native command's name is still a path lookup, so `<dir>\cmd` and `<dir>\pwsh`
# run the `.ps1` beside them (measured: ExternalScript, and `& $p` ran the child). Each reaches that script; with no
# script there, the walk fails (a missing member), and a relative one is unresolved; none is read as cmd or pwsh.
foreach ($leafName in @('cmd', 'pwsh', 'powershell')) {
    $lookupTarget = "test/windows/fixtures/$leafName.ps1"
    foreach ($form in @(
            "`$p = Get-Command -Name (Join-Path `$PSScriptRoot 'fixtures\$leafName') -CommandType ExternalScript; & `$p"
            "& (Join-Path `$PSScriptRoot 'fixtures\$leafName')"
            "`$c = Get-Command `"`$PSScriptRoot\fixtures\$leafName`"; & `$c -NoProfile -File (Join-Path `$PSScriptRoot 'child.ps1')"
        )) {
        $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; $lookupTarget = '1'; 'test/windows/child.ps1' = '1' }
        Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains $lookupTarget -and $formWalk.Members -cnotcontains 'test/windows/child.ps1') "$form must reach $lookupTarget, never read as $leafName`: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
        $absentWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; 'test/windows/child.ps1' = '1' }
        Assert-True ($absentWalk.Problems.Count -ge 1 -and $absentWalk.Members -cnotcontains 'test/windows/child.ps1') "$form with no $lookupTarget must fail the walk: $($absentWalk.Problems -join '; ') [$($absentWalk.Members -join ', ')]"
    }
    $relativeWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = "`$c = Get-Command fixtures\$leafName; & `$c"; $lookupTarget = '1' }
    Assert-True ($relativeWalk.Problems.Count -ge 1 -and $relativeWalk.Unresolved.Count -ge 1) "A relative Get-Command fixtures\$leafName must be unresolved: $($relativeWalk.Problems -join '; ')"
}
# Opus on #740: a `<word>\<Verb-Noun>` name is a path lookup unless its module is one PowerShell ships, in every form
# (pwsh 7.6.10 and 5.1 each ran `sub\Run-Child.ps1` for `sub\Run-Child`, `& 'sub\Run-Child'`, `. 'sub\Run-Child'` and
# `& (Get-Command 'sub\Run-Child')`). A relative one is unresolved; one anchored on the script reaches the script.
$qualifiedTarget = 'test/windows/sub/Run-Child.ps1'
foreach ($form in @('sub\Run-Child', "& 'sub\Run-Child'", ". 'sub\Run-Child'", "& (Get-Command 'sub\Run-Child')", "`$c = Get-Command sub\Run-Child; & `$c")) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; $qualifiedTarget = '1' }
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1 -and $formWalk.Members -cnotcontains $qualifiedTarget) "$form must be unresolved, not a module-qualified cmdlet: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
foreach ($form in @("& (Join-Path `$PSScriptRoot 'sub\Run-Child')", ". `"`$PSScriptRoot\sub\Run-Child`"", "& (Get-Command `"`$PSScriptRoot\sub\Run-Child`")")) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; $qualifiedTarget = '1' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains $qualifiedTarget) "$form must reach $qualifiedTarget`: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
foreach ($form in @('Microsoft.PowerShell.Utility\Write-Host x', '& Microsoft.PowerShell.Utility\Get-Date', '$d = Get-Command Microsoft.PowerShell.Management\Get-Item; & $d .')) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members.Count -eq 1) "$form (a cmdlet of a module PowerShell ships) is no script edge: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
# A path lookup resolves only to a `.ps1` that is the one file it may find, matched case-insensitively against every
# sibling with `.ps1` or a PATHEXT extension; any other lookup fails the walk. Sol on #740 (round 5): with
# `<path>.ps1` and `<path>.cmd` both there, `-CommandType Application` ran the `.cmd`. Greptile on #740: with only
# `<path>.exe` (a pwsh), the walk kept the exe as a file and dropped the `-File` child its arguments named. Opus on
# #740: cmd never runs a `.ps1`, so a lookup in cmd's command line is unresolved. Each with the listing reader and with
# one that lists nothing (each extension tried in every case).
$lookupForms = @(
    '$p = Get-Command -Name (Join-Path $PSScriptRoot ''fixtures\sol-lookup-shadow'') -CommandType Application; & $p'
    '$p = Get-Command -Name (Join-Path $PSScriptRoot ''fixtures\sol-lookup-shadow'') -CommandType ExternalScript; & $p'
    '& (Join-Path $PSScriptRoot ''fixtures\sol-lookup-shadow'')'
    '. "$PSScriptRoot\fixtures\sol-lookup-shadow"'
)
foreach ($noLister in @($false, $true)) {
    foreach ($form in $lookupForms) {
        # A `.ps1` alone resolves and is walked.
        $alone = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; 'test/windows/fixtures/sol-lookup-shadow.ps1' = '. (Join-Path $PSScriptRoot ''deeper.ps1'')'; 'test/windows/fixtures/deeper.ps1' = '1' } -NoLister:$noLister
        Assert-True ($alone.Problems.Count -eq 0 -and $alone.Members -ccontains 'test/windows/fixtures/sol-lookup-shadow.ps1' -and $alone.Members -ccontains 'test/windows/fixtures/deeper.ps1') "$form with a .ps1 alone (lister: $(-not $noLister)) must reach and walk it: $($alone.Problems -join '; ') [$($alone.Members -join ', ')]"
        foreach ($case in @(
                @{ Name = 'a .ps1 and a .cmd'; Files = @{ 'test/windows/fixtures/sol-lookup-shadow.ps1' = '1'; 'test/windows/fixtures/sol-lookup-shadow.cmd' = '@echo off' } }
                @{ Name = 'a .cmd alone'; Files = @{ 'test/windows/fixtures/sol-lookup-shadow.cmd' = '@echo off' } }
                @{ Name = 'a .ps1 and a .CmD'; Files = @{ 'test/windows/fixtures/sol-lookup-shadow.ps1' = '1'; 'test/windows/fixtures/sol-lookup-shadow.CmD' = '@echo off' } }
                @{ Name = 'no sibling but a .txt'; Files = @{ 'test/windows/fixtures/sol-lookup-shadow.txt' = 'x' } }
            )) {
            $files = @{ 'test/windows/entry.ps1' = $form }
            foreach ($key in $case.Files.Keys) { $files[$key] = $case.Files[$key] }
            $formWalk = Get-FixtureWalk $files -NoLister:$noLister
            Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1) "$form with $($case.Name) (lister: $(-not $noLister)) must fail the walk: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
        }
    }
}
# A listing reader also sees a sibling whose base name differs in case.
$caseSibling = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '& (Join-Path $PSScriptRoot ''fixtures\sol-lookup-shadow'')'; 'test/windows/fixtures/sol-lookup-shadow.ps1' = '1'; 'test/windows/fixtures/SOL-Lookup-Shadow.cmd' = '@echo off' }
Assert-True ($caseSibling.Problems.Count -ge 1 -and $caseSibling.Unresolved.Count -ge 1) "A listing reader must see a sibling whose base name differs in case, and fail the walk: $($caseSibling.Problems -join '; ')"
# Greptile's form: an extensionless pwsh path with only the exe there, and a -File child.
foreach ($noLister in @($false, $true)) {
    $greptile = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '& (Join-Path $PSScriptRoot ''fixtures\pwsh'') -File (Join-Path $PSScriptRoot ''child.ps1'')'; 'test/windows/fixtures/pwsh.exe' = 'MZ'; 'test/windows/child.ps1' = '1' } -NoLister:$noLister
    Assert-True ($greptile.Problems.Count -ge 1 -and $greptile.Unresolved.Count -ge 1 -and $greptile.Members -cnotcontains 'test/windows/fixtures/pwsh.exe') "An extensionless pwsh path with only pwsh.exe there (lister: $(-not $noLister)) must fail the walk: $($greptile.Problems -join '; ') [$($greptile.Members -join ', ')]"
}
# cmd and batch files are refused (the lead on #740, round 8): every review round from 5 to 8 found a new silent hole in
# reading cmd's language or a batch file's forwarding (Sol, Opus, Greptile, CodeRabbit), and no real member runs a
# resolvable cmd or batch line. So any invocation of cmd or of a .cmd or .bat file is unresolved, in every form; only
# the anchored legacy-only lines are exempt. Each form below, from those rounds, must fail the walk.
$cmdFiles = @{
    'test/windows/fixtures/helper.ps1' = '1'; 'test/windows/fixtures/helper.cmd' = '@echo off'
    'test/windows/fixtures/sol-r6-helper.cmd' = '@echo %1'; 'test/windows/fixtures/second.cmd' = '@echo off'; 'test/windows/fixtures/forward.cmd' = '@%*'
    'test/windows/fixtures/cmd.cmd' = '@echo %*'; 'test/windows/fixtures/pwsh.cmd' = '@echo %*'; 'test/windows/fixtures/powershell.cmd' = '@echo %*'
    'test/windows/fixtures/sol-helper.cmd' = '@echo %1'; 'test/windows/fixtures/tools/pwsh.cmd' = '@echo %*'; 'test/windows/fixtures/powershell.bat' = '@echo %*'
    'test/windows/fixtures/pwsh-shim.cmd' = '@pwsh %*'; 'test/windows/child.ps1' = '1'
}
$cmdRefused = @(
    # Round 5 (Opus): an extensionless path in cmd's command line, also after `call`.
    'cmd /d /c "$PSScriptRoot\fixtures\helper"'
    'cmd.exe /d /k "$PSScriptRoot\fixtures\helper"'
    'cmd /d /c call "$PSScriptRoot\fixtures\helper"'
    # Round 6 (Sol, Opus): a helper with an argument in one string, two segments, a pipe; a batch file forwarding a launch.
    'cmd.exe /d /c "$PSScriptRoot\fixtures\sol-r6-helper sentinel"'
    'cmd.exe /d /c "$PSScriptRoot\fixtures\second.cmd && $PSScriptRoot\fixtures\sol-r6-helper sentinel"'
    'cmd.exe /d /c "$PSScriptRoot\fixtures\second.cmd | $PSScriptRoot\fixtures\sol-r6-helper"'
    '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') powershell.exe -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot ''child.ps1'')'
    'cmd.exe /d /c "$PSScriptRoot\fixtures\forward.cmd" powershell.exe -File "$PSScriptRoot\child.ps1"'
    'Start-Process -FilePath (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') -ArgumentList ''powershell.exe'', ''-File'', (Join-Path $PSScriptRoot ''child.ps1'') -Wait'
    # Round 7 (Greptile, CodeRabbit, Sol): a path named for a shell; `call`; a leading redirect; `/d /c` in one element.
    'cmd.exe /d /c "$PSScriptRoot\fixtures\pwsh" -Version'
    'cmd /c "$PSScriptRoot\fixtures\tools\pwsh -File $PSScriptRoot\child.ps1"'
    'cmd.exe /d /c "$PSScriptRoot\fixtures\powershell" -Version'
    'cmd.exe /d /c "call $PSScriptRoot\fixtures\cmd sentinel"'
    'cmd.exe /d /c "2>nul $PSScriptRoot\fixtures\sol-helper sentinel"'
    'Start-Process -FilePath (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') -ArgumentList "cmd.exe", "/d /c", "$PSScriptRoot\fixtures\sol-helper.cmd sentinel" -Wait'
    # Round 8 (Greptile, Opus, Sol): a later program word; cmd's operators in a word; a glued switch; a shell reading
    # input; a wrapper running a helper named by a plain word.
    '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') run powershell.exe -EncodedCommand ZQBjAGgAbwAgAHgA'
    '& (Join-Path $PSScriptRoot ''fixtures\pwsh-shim.cmd'') ''x&pwsh'''
    'cmd.exe /d /chelper'
    'cmd.exe /d /Rsol-helper'
    '''echo x'' | cmd.exe /d'
    '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') helper'
    # Sol, round 8, exactly: a helper glued to /C or /R, and a forwarding wrapper given a helper's bare name.
    'cmd.exe /d /cverifyfixture'
    'cmd.exe /d /rverifyfixture'
    'cmd.exe /d /c "$PSScriptRoot\fixtures\forward.cmd" verifyfixture'
    'cmd.exe /d /c "$PSScriptRoot\fixtures\forward.cmd" verifyfixture sentinel'
    # Shapes that once resolved, refused now: an explicit batch file, a builtin, cmd running PowerShell, plain words.
    'cmd.exe /d /c "$PSScriptRoot\fixtures\sol-r6-helper.cmd" sentinel'
    'cmd.exe /d /c exit 0'
    'cmd.exe /d /c echo hello'
    'cmd.exe /d /c pwsh -NoProfile -File "$PSScriptRoot\child.ps1"'
    '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') build --verbose 3'
    '& "$PSScriptRoot\fixtures\second.cmd"'
    '. "$PSScriptRoot\fixtures\second.cmd"'
    'Start-Process -FilePath cmd.exe -ArgumentList ''/d'', ''/c'', (Join-Path $PSScriptRoot ''fixtures\second.cmd'') -Wait'
    'Start-Process -FilePath (Join-Path $PSScriptRoot ''fixtures\second.cmd'') -Wait'
    'pwsh -NoProfile -File (Join-Path $PSScriptRoot ''fixtures\second.cmd'')'
    'cmd.exe /d'
    'Set-Alias c cmd.exe; c /d /c exit'
    # CodeRabbit on #740: an executable the walker cannot name (a helper named for an executable it cannot read), given
    # standard input.
    'Start-Process -FilePath (Get-PwshExePath) -RedirectStandardInput (Join-Path $PSScriptRoot ''input.txt'') -Wait'
    # Opus, round 9: a quoted shell name with trailing spaces runs that shell.
    '& ''cmd '' /d /c x.cmd'
    '& ''CMD.EXE  '' /d /c exit'
    'Start-Process ''cmd '' -ArgumentList ''/d'', ''/c'', ''exit'' -Wait'
    'Set-Alias c ''cmd ''; c /d /c exit'
    '& (Get-Command ''cmd '') /d /c exit'
    '& "$PSScriptRoot\fixtures\second.cmd "'
    # Opus, round 9: an executable the walker cannot name, whatever its arguments, and a helper named for cmd.
    '& (Get-PwshExePath) build'
    'Start-Process -FilePath (Get-PwshExePath) -Wait'
    '& (Get-CmdExePath) /d /c exit'
    # Opus, round 9: a bare name beside -WorkingDirectory may be found in that directory.
    'Start-Process -FilePath helper -WorkingDirectory (Join-Path $PSScriptRoot ''fixtures'') -Wait'
    'Start-Process pwsh -WorkingDirectory (Join-Path $PSScriptRoot ''fixtures'') -ArgumentList ''-File'', (Join-Path $PSScriptRoot ''child.ps1'') -Wait'
    # Opus, round 9: the dropped fixture, re-pinned: Start-Process of an extensionless path named pwsh.
    'Start-Process -FilePath (Join-Path $PSScriptRoot ''fixtures\pwsh'') -ArgumentList ''-File'', (Join-Path $PSScriptRoot ''child.ps1'') -Wait'
)
foreach ($form in $cmdRefused) {
    $table = @{ 'test/windows/entry.ps1' = $form }
    foreach ($key in $cmdFiles.Keys) { $table[$key] = $cmdFiles[$key] }
    $formWalk = Get-FixtureWalk $table
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1 -and @($formWalk.Members | Where-Object { $_ -match '(?i)\.(cmd|bat)\z' }).Count -eq 0) "$form must be unresolved (cmd and batch files are refused), and take no batch file: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
# Start-Process of PowerShell is refused (the lead on #740, round 10): Start-Process joins its arguments without
# quoting and PowerShell tokenizes them again, so a packed element (Sol, round 9), a parenthesized string (Greptile),
# a variable (Sol, round 10) and a value slot holding `-f`, `+`, `$( )` or a `u{20} escape (Opus, round 10) each carried
# -Command or -File through. Every form, the plain ones included, is unresolved.
foreach ($form in @(
        '$script = Join-Path $PSScriptRoot ''child.ps1''; Start-Process pwsh -ArgumentList ''-NoProfile'', ''-File'', $script -Wait'
        'Start-Process powershell.exe -ArgumentList ''-NoProfile'', ''-File'', "$PSScriptRoot\child.ps1"'
        'Microsoft.PowerShell.Management\Start-Process pwsh -ArgumentList ''-File'', "$PSScriptRoot\child.ps1"'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', (''{0} -Command x'' -f ''Bypass'')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', "Bypass`u{20}-Command`u{20}x"'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-NonInteractive'', ''-ExecutionPolicy'', "Bypass -Command $testCommand"'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', "Bypass -File $PSScriptRoot\child.ps1"'
        'Start-Process powershell.exe -ArgumentList @(''-NoProfile'', ''-ExecutionPolicy Bypass'', ''-File'', (Join-Path $PSScriptRoot ''child.ps1''))'
        'Start-Process -FilePath pwsh.exe -ArgumentList ''-NoProfile'', ''-File'', ''"x y.ps1"'''
        'Start-Process pwsh -ArgumentList ''-NoProfile -File x.ps1'''
        'Start-Process pwsh -ArgumentList "-NoProfile -File $PSScriptRoot\child.ps1"'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', ''Bypass'', ''-Command'', $testCommand'
        # Greptile on #740 (round 9), against the element allowlist round 10 removed: a parenthesized string, a `$( )`,
        # a concatenation, a -join, a method call, an index, a nested array and a parenthesized path. Each is refused
        # now as a Start-Process of PowerShell.
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', (''Bypass -Command . C:\fixture\child.ps1'')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $(''Bypass -Command x'')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', (''Bypass'' + '' -Command x'')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', ((''Bypass'', ''-Command'', ''x'') -join '' '')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', ''Bypass''.Insert(6, '' -Command x'')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $policies[0]'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', @(''-ExecutionPolicy'', ''Bypass -Command x'')'
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-File'', (Join-Path $PSScriptRoot ''child.ps1'')'
        'Start-Process pwsh -ArgumentList (''-NoProfile'' + '' -File x.ps1'')'
        # Sol on #740 (round 10), CodeRabbit: variable elements, which the removed allowlist accepted as one known
        # value; refused now as a Start-Process of PowerShell.
        '$a = ''Bypass -Command x''; Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $a'
        'param($Policy) Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $Policy'
        '$c = ''-Command''; Start-Process pwsh -ArgumentList ''-NoProfile'', $c, ''Get-Date'''
        'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $options.Policy'
        'if ($x) { $p = ''Bypass'' } else { $p = ''Bypass -Command x'' }; Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $p'
        '$argv = ''-NoProfile'', ''-File'', ''x.ps1''; Start-Process pwsh -ArgumentList $argv'
    )) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1) "$form must be unresolved (Start-Process re-joins a shell's elements): $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
# Opus on #740 (round 10): in an `&`, `.` or bare launch of PowerShell the value slot after a valued option is read.
# PowerShell quotes a scalar argument but expands an array into several, so a variable or computed value there passes
# only as one known string; a literal passes, and -File's value is read as a path.
foreach ($form in @(
        '$policy = @(''Bypass'', ''-Command'', ''x''); & pwsh -NoProfile -ExecutionPolicy $policy'
        'param($Policy) pwsh -NoProfile -ExecutionPolicy $Policy -File (Join-Path $PSScriptRoot ''child.ps1'')'
        '& pwsh -NoProfile -ExecutionPolicy $(Get-FixturePolicy) -File (Join-Path $PSScriptRoot ''child.ps1'')'
        '& powershell.exe -ExecutionPolicy $options.Policy -File "$PSScriptRoot\child.ps1"'
    )) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1) "$form must be unresolved (a value slot that may expand into several arguments): $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
foreach ($form in @(
        '$script = Join-Path $PSScriptRoot ''child.ps1''; & pwsh -NoProfile -File $script'
        '$policy = ''Bypass''; & pwsh -NoProfile -ExecutionPolicy $policy -File (Join-Path $PSScriptRoot ''child.ps1'')'
        '& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\child.ps1"'
        'pwsh -NoProfile -ExecutionPolicy "Bypass" -File (Join-Path $PSScriptRoot ''child.ps1'')'
    )) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains 'test/windows/child.ps1') "$form must still read its child: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}
# Opus, round 9: a quoted pwsh with trailing spaces still reads its child; a system program beside -WorkingDirectory
# stays no edge.
$trailingPwsh = Get-FixtureWalk @{ 'test/windows/entry.ps1' = '& ''pwsh '' -File (Join-Path $PSScriptRoot ''child.ps1'')'; 'test/windows/child.ps1' = '1' }
Assert-True ($trailingPwsh.Problems.Count -eq 0 -and $trailingPwsh.Members -ccontains 'test/windows/child.ps1') "& 'pwsh ' -File must read its child: $($trailingPwsh.Problems -join '; ')"
$systemProgram = Get-FixtureWalk @{ 'test/windows/entry.ps1' = 'Start-Process -FilePath git -ArgumentList ''status'' -WorkingDirectory $PSScriptRoot -Wait' }
Assert-True ($systemProgram.Problems.Count -eq 0 -and $systemProgram.Members.Count -eq 1) "A system program beside -WorkingDirectory is no edge: $($systemProgram.Problems -join '; ')"
# A known non-shell executable given standard input stays no edge.
$sortInput = Get-FixtureWalk @{ 'test/windows/entry.ps1' = 'Start-Process -FilePath sort.exe -RedirectStandardInput (Join-Path $PSScriptRoot ''input.txt'') -Wait' }
Assert-True ($sortInput.Problems.Count -eq 0 -and $sortInput.Members.Count -eq 1) "A known non-shell executable given -RedirectStandardInput is no edge: $($sortInput.Problems -join '; ')"
# The PowerShell readers stay: a bare or rooted pwsh or powershell reads its -File child.
foreach ($form in @('pwsh -NoProfile -File (Join-Path $PSScriptRoot ''child.ps1'')', '& C:\Tools\powershell.exe -File "$PSScriptRoot\child.ps1"', '$child = Join-Path $PSScriptRoot ''child.ps1''; & pwsh.exe -File $child')) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; 'test/windows/child.ps1' = '1' }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members -ccontains 'test/windows/child.ps1') "$form must still read its child: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}

# Opus on #740 (round 6): an extensionless lookup through a production reader's own listing, on a small git tree.
$gitRoot = Join-Path ([IO.Path]::GetTempPath()) ("noctty-gui-lister-git-$([guid]::NewGuid().ToString('N'))")
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $gitRoot 'test\windows\fixtures'))
    [IO.File]::WriteAllText((Join-Path $gitRoot 'test\windows\entry.ps1'), '& (Join-Path $PSScriptRoot ''fixtures\tree-helper'')')
    [IO.File]::WriteAllText((Join-Path $gitRoot 'test\windows\fixtures\tree-helper.ps1'), '1')
    & git -C $gitRoot init -q 2>$null | Out-Null
    & git -C $gitRoot add -A 2>$null | Out-Null
    & git -C $gitRoot -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m fixture 2>$null | Out-Null
    $global:LASTEXITCODE = 0
    $treeWalk = Get-ScriptClosure -RepoRoot $gitRoot -Entries @('test/windows/entry.ps1') -Ref 'HEAD' -LegacyEdges @()
    Assert-True ($treeWalk.Problems.Count -eq 0 -and $treeWalk.Members -ccontains 'test/windows/fixtures/tree-helper.ps1') "A lookup through a git tree's listing must reach its lone .ps1: $($treeWalk.Problems -join '; ') [$($treeWalk.Members -join ', ')]"
    [IO.File]::WriteAllText((Join-Path $gitRoot 'test\windows\fixtures\tree-helper.cmd'), '@echo off')
    & git -C $gitRoot add -A 2>$null | Out-Null
    & git -C $gitRoot -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m sibling 2>$null | Out-Null
    $global:LASTEXITCODE = 0
    $siblingWalk = Get-ScriptClosure -RepoRoot $gitRoot -Entries @('test/windows/entry.ps1') -Ref 'HEAD' -LegacyEdges @()
    Assert-True ($siblingWalk.Problems.Count -ge 1 -and $siblingWalk.Unresolved.Count -ge 1) "A lookup through a git tree's listing must see the .cmd sibling and fail: $($siblingWalk.Problems -join '; ')"
}
finally { Remove-Item -LiteralPath $gitRoot -Recurse -Force -ErrorAction SilentlyContinue }

# Sol on #740 (round 6): the working-tree lister spells every directory as the tree does, so a lookup spelled
# `Fixtures\x` yields the member `fixtures/x.ps1` that a changed path names, through the standalone -Paths route.
$caseRoot = Join-Path ([IO.Path]::GetTempPath()) ("noctty-gui-lister-case-$([guid]::NewGuid().ToString('N'))")
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $caseRoot 'test\windows\fixtures'))
    [IO.File]::WriteAllText((Join-Path $caseRoot 'test\windows\entry.ps1'), '& (Join-Path $PSScriptRoot ''Fixtures\sol-r6-helper'')')
    [IO.File]::WriteAllText((Join-Path $caseRoot 'test\windows\fixtures\sol-r6-helper.ps1'), '1')
    $caseWalk = Get-ScriptClosure -RepoRoot $caseRoot -Entries @('test/windows/entry.ps1') -Reader (New-CiScriptFileReader -RepoRoot $caseRoot) -LegacyEdges @()
    Assert-True ($caseWalk.Problems.Count -eq 0 -and $caseWalk.Members -ccontains 'test/windows/fixtures/sol-r6-helper.ps1' -and $caseWalk.Members -cnotcontains 'test/windows/Fixtures/sol-r6-helper.ps1') "A lookup spelled Fixtures\ must yield the tree's spelling: $($caseWalk.Problems -join '; ') [$($caseWalk.Members -join ', ')]"
    Assert-True (Get-CiGuiSelection -ChangedPaths @('test/windows/fixtures/sol-r6-helper.ps1') -GuiList @($caseWalk.Members)) 'A change to the tree-spelled helper must select the suite through the list the walk gave.'
    # Opus on #740 (round 10): a -File target with trailing spaces runs the trimmed file, and is listed trimmed.
    [IO.File]::WriteAllText((Join-Path $caseRoot 'test\windows\trailing.ps1'), 'pwsh -NoProfile -File "$PSScriptRoot\fixtures\sol-r6-helper.ps1 "')
    $trailingWalk = Get-ScriptClosure -RepoRoot $caseRoot -Entries @('test/windows/trailing.ps1') -Reader (New-CiScriptFileReader -RepoRoot $caseRoot) -LegacyEdges @()
    Assert-True ($trailingWalk.Problems.Count -eq 0 -and $trailingWalk.Members -ccontains 'test/windows/fixtures/sol-r6-helper.ps1' -and @($trailingWalk.Members | Where-Object { $_.EndsWith(' ') }).Count -eq 0) "A -File target with trailing spaces must be listed trimmed: $($trailingWalk.Problems -join '; ') [$($trailingWalk.Members -join ', ')]"
    # CodeRabbit on #740: an `Add-Type -Path` source spelled `Fixtures\Native.CS` is spelled as the tree spells it.
    [IO.File]::WriteAllText((Join-Path $caseRoot 'test\windows\fixtures\native.cs'), 'class X {}')
    [IO.File]::WriteAllText((Join-Path $caseRoot 'test\windows\typed.ps1'), 'Add-Type -Path (Join-Path $PSScriptRoot ''Fixtures\Native.CS'')')
    $typedWalk = Get-ScriptClosure -RepoRoot $caseRoot -Entries @('test/windows/typed.ps1') -Reader (New-CiScriptFileReader -RepoRoot $caseRoot) -LegacyEdges @()
    Assert-True ($typedWalk.Problems.Count -eq 0 -and $typedWalk.Members -ccontains 'test/windows/fixtures/native.cs') "An Add-Type source spelled Fixtures\Native.CS must yield the tree's spelling: $($typedWalk.Problems -join '; ') [$($typedWalk.Members -join ', ')]"
    # Opus on #740 (round 7): an explicit target spelled `Fixtures\` is spelled as the tree spells it too.
    [IO.File]::WriteAllText((Join-Path $caseRoot 'test\windows\explicit.ps1'), '& (Join-Path $PSScriptRoot ''Fixtures\Sol-R6-Helper.ps1'')')
    $explicitWalk = Get-ScriptClosure -RepoRoot $caseRoot -Entries @('test/windows/explicit.ps1') -Reader (New-CiScriptFileReader -RepoRoot $caseRoot) -LegacyEdges @()
    Assert-True ($explicitWalk.Problems.Count -eq 0 -and $explicitWalk.Members -ccontains 'test/windows/fixtures/sol-r6-helper.ps1') "An explicit target spelled Fixtures\Sol-R6-Helper.ps1 must yield the tree's spelling: $($explicitWalk.Problems -join '; ') [$($explicitWalk.Members -join ', ')]"
}
finally { Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction SilentlyContinue }

# Sol on #740 (round 5): a `Microsoft.PowerShell.*\Name` spelling is a cmdlet only when this session's module exports
# that command. `Microsoft.PowerShell.Utility\Run-Child` (the module has no Run-Child) and an invented module's name
# each ran a relative `.ps1`, so each form is a relative path lookup, unresolved; a real cmdlet stays a cmdlet.
foreach ($qualified in @('Microsoft.PowerShell.Utility\Run-Child', 'Microsoft.PowerShell.SolFixture\Run-Child', 'microsoft.powershell.x\Run-Child')) {
    foreach ($form in @($qualified, "& '$qualified'", ". '$qualified'", "& (Get-Command '$qualified')", "Set-Location (Join-Path `$PSScriptRoot 'fixtures'); & '$qualified'")) {
        $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $form; "test/windows/fixtures/$($qualified.Replace('\', '/')).ps1" = '1' }
        Assert-True ($formWalk.Problems.Count -ge 1 -and $formWalk.Unresolved.Count -ge 1) "$form must be unresolved (no such cmdlet, so a relative path): $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
    }
}
Assert-True (Test-CiScriptShippedCmdlet 'Microsoft.PowerShell.Utility\Get-Date') 'Microsoft.PowerShell.Utility\Get-Date must count as a cmdlet.'
Assert-True (-not (Test-CiScriptShippedCmdlet 'Microsoft.PowerShell.Utility\Run-Child')) 'Microsoft.PowerShell.Utility\Run-Child must not count as a cmdlet.'
$namedQuiet = [ordered]@{
    'Get-Command of a joined native path, then &' = '$c = Get-Command (Join-Path $PSScriptRoot ''tool.exe''); & $c'
    'Get-Command of a bare native name, then &' = '$g = Get-Command git; & $g status'
    'Get-Command of a module-qualified cmdlet, then &' = '$d = Get-Command Microsoft.PowerShell.Utility\Get-Date; & $d'
    'Set-Alias to a native program' = 'Set-Alias g git; g status'
    'nal to a cmdlet' = 'nal now Get-Date; now'
    'New-Alias to a joined native path' = 'New-Alias -Name tool -Value (Join-Path $PSScriptRoot ''tool.exe''); tool'
    'an ordinary New-Item' = 'New-Item -ItemType Directory -Path $dir -Force | Out-Null; Set-Item -Path env:FIXTURE -Value 1'
    'AddCommand of a cmdlet' = '[PowerShell]::Create().AddCommand(''Get-Date'').Invoke()'
    'AddScript of code with no edge' = '[PowerShell]::Create().AddScript(''Get-Date'').Invoke()'
}
foreach ($form in $namedQuiet.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $namedQuiet[$form] }
    Assert-True ($formWalk.Problems.Count -eq 0 -and $formWalk.Members.Count -eq 1) "$form is no script edge: $($formWalk.Problems -join '; ') [$($formWalk.Members -join ', ')]"
}

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
foreach ($buildInput in @($plan.buildInputs | Where-Object { -not ([string]$_).EndsWith('/**') })) { Assert-True ($list -ccontains (ConvertTo-CiRepoPath ([string]$buildInput))) "The GUI list must hold build input $buildInput." }
# Named here, not read from the plan, so dropping one from buildInputs fails (Sol on #740, rounds 11 and 12): the
# ConPTY manifest the runner reads (Get-GuiHiddenConptyPins), the stager and its two libraries the measurement build
# runs (src/build/ConptyRedist.zig), and the two sources measure-lib reads for provenance. Each would also select
# through Get-CiPathNeeds' zig, so the list is checked directly.
foreach ($buildInput in @('dist/windows/conpty-redist.json', 'scripts/stage-conpty-redist.ps1', 'scripts/conpty-redist.ps1', 'scripts/windows-architecture.ps1', 'src/apprt/win32_aumid.zig', 'src/apprt/win32/app.zig', '.gitignore', '.gitattributes')) {
    Assert-True ($list -ccontains $buildInput) "The GUI list must hold the build input $buildInput."
}
# A `<dir>/**` build input is every tracked file under it, from the index on the working-tree route and from the
# ref's tree on a ref route, and nothing else; the plan names the measurement build's whole input set that way (Sol on
# #740, round 12). Each route is compared with its own tracked set, so an ignored or untracked local file, or a staged
# change, cannot fail this (Greptile on #740). The references are git's raw `-z` paths, decoded from bytes as UTF-8
# here, apart from the selection's own reader, and each listing's exit code is checked: git's default quoting
# (core.quotePath) would have failed a tracked non-ASCII path (CodeRabbit on #740).
function Get-FixtureGitPaths([string] $Root, [string[]] $Arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($argument in @('-C', $Root) + $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $errors = $process.StandardError.ReadToEndAsync()
        $bytes = [IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($bytes)
        $process.WaitForExit()
        [void]$errors.Result
        if ($process.ExitCode -ne 0) { throw "The fixture's git $($Arguments[0]) failed with exit code $($process.ExitCode)." }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes.ToArray())
    }
    finally { $process.Dispose() }
    return , [string[]]@($text.Split([char]0) | Where-Object { $_ } | Sort-Object -CaseSensitive)
}
foreach ($buildTree in @('src', 'pkg', 'vendor', 'include', 'dist/windows')) {
    Assert-True (@($plan.buildInputs) -ccontains "$buildTree/**") "The plan's buildInputs must name $buildTree/**."
    $inIndex = Get-FixtureGitPaths $repoRoot @('ls-files', '-z', '--full-name', '--', "$buildTree/")
    $inHead = Get-FixtureGitPaths $repoRoot @('ls-tree', '-r', '-z', '--name-only', '--full-tree', 'HEAD', '--', "$buildTree/")
    # Assigned before sorting: the function returns its paths as one array object.
    $working = Get-CiGuiTreeFiles -RepoRoot $repoRoot -Directory $buildTree
    $working = [string[]]@($working | Sort-Object -CaseSensitive)
    $atHead = Get-CiGuiTreeFiles -RepoRoot $repoRoot -Ref 'HEAD' -Directory $buildTree
    $atHead = [string[]]@($atHead | Sort-Object -CaseSensitive)
    Assert-True ($inIndex.Count -gt 0 -and ($working -join '|') -ceq ($inIndex -join '|') -and ($atHead -join '|') -ceq ($inHead -join '|')) "$buildTree/** must expand to its tracked files: the index ($($working.Count) of $($inIndex.Count)) and HEAD ($($atHead.Count) of $($inHead.Count))."
    foreach ($file in $inIndex) { if (-not ($list -ccontains $file)) { Assert-True $false "The GUI list must hold $file, under $buildTree/**." ; break } }
}
# Sol on #740 (round 13): an ignored file under a build tree is no member on either route, on a small git tree; and a
# tracked non-ASCII name comes back as it is spelled, on both routes (CodeRabbit on #740).
$ignoredRoot = Join-Path ([IO.Path]::GetTempPath()) ("noctty-gui-build-tree-$([guid]::NewGuid().ToString('N'))")
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $ignoredRoot 'src\.zig-cache'))
    [IO.File]::WriteAllText((Join-Path $ignoredRoot '.gitignore'), ".zig-cache/`n*.orig`n")
    [IO.File]::WriteAllText((Join-Path $ignoredRoot 'src\main.zig'), 'pub fn main() void {}')
    $nonAscii = 'src/caf' + [char]0xE9 + '.zig'
    [IO.File]::WriteAllText((Join-Path $ignoredRoot $nonAscii.Replace('/', '\')), 'const x = 1;')
    & git -C $ignoredRoot init -q 2>$null | Out-Null
    & git -C $ignoredRoot add -A 2>$null | Out-Null
    & git -C $ignoredRoot -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m fixture 2>$null | Out-Null
    $global:LASTEXITCODE = 0
    [IO.File]::WriteAllText((Join-Path $ignoredRoot 'src\.zig-cache\scratch.txt'), 'ignored')
    [IO.File]::WriteAllText((Join-Path $ignoredRoot 'src\main.zig.orig'), 'ignored')
    $ignoredCheck = @(& git -C $ignoredRoot check-ignore -- 'src/.zig-cache/scratch.txt' 'src/main.zig.orig' 2>$null)
    $global:LASTEXITCODE = 0
    Assert-True ($ignoredCheck.Count -eq 2) "The ignored-file fixture's two files must be ignored by its .gitignore (the precondition): $($ignoredCheck -join ', ')"
    $ignoredWorking = Get-CiGuiTreeFiles -RepoRoot $ignoredRoot -Directory 'src'
    $ignoredWorking = [string[]]@($ignoredWorking | Sort-Object -CaseSensitive)
    $ignoredHead = Get-CiGuiTreeFiles -RepoRoot $ignoredRoot -Ref 'HEAD' -Directory 'src'
    $ignoredHead = [string[]]@($ignoredHead | Sort-Object -CaseSensitive)
    $expectedTree = [string[]]@(@($nonAscii, 'src/main.zig') | Sort-Object -CaseSensitive) -join '|'
    Assert-True (($ignoredWorking -join '|') -ceq $expectedTree -and ($ignoredHead -join '|') -ceq $expectedTree) "An ignored file under src/ must not be listed, and the non-ASCII name must be: the index gave [$($ignoredWorking -join ', ')], HEAD gave [$($ignoredHead -join ', ')]."
    $nonAsciiRefs = Get-FixtureGitPaths $ignoredRoot @('ls-files', '-z', '--full-name', '--', 'src/')
    Assert-True ($nonAsciiRefs -ccontains $nonAscii) "The fixture's own reference must read the non-ASCII name raw: [$($nonAsciiRefs -join ', ')]."
}
finally { Remove-Item -LiteralPath $ignoredRoot -Recurse -Force -ErrorAction SilentlyContinue }
foreach ($file in @('build.zig', 'build.zig.zon')) { Assert-True ($list -ccontains $file) "The GUI list must hold the build input $file." }
# The control: a plan without src/** lists no src/ file the closure does not reach.
$noSrcReader = {
    param([string] $RepoPath)
    $full = Join-Path $repoRoot ($RepoPath.Replace('/', '\'))
    if (-not [IO.File]::Exists($full)) { return $null }
    $text = [IO.File]::ReadAllText($full)
    if ($RepoPath -ceq 'test/windows/gui-hidden-plan.json') { $text = $text.Replace('"src/**",', '') }
    return $text
}.GetNewClosure()
$noSrcList = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $noSrcReader
Assert-True (-not ($noSrcList -ccontains 'src/apprt/win32_aumid.zig') -and -not ($noSrcList -ccontains 'src/apprt/win32/app.zig')) 'A plan without src/** must not list the provenance sources (the control for the tree expansion).'


# Singletons, independent of the computed list (which cannot show its own omissions): each keeps its own
# Get-CiPathNeeds result, so test.yml's flags stay what they were, and each selects the suite.
$singletons = [ordered]@{
    'scripts/dev-windows.cmd' = 'package'
    'scripts/interactive-win11-lib.ps1' = 'package'
    'scripts/interactive-win11-window-lib.ps1' = 'none'
    'test/windows/interactive-win11-stateful-lib.ps1' = 'none'
    'scripts/interactive-win11-measure-lib.ps1' = 'zig'
    'scripts/interactive-win11-realinput.ps1' = 'zig'
    # The helper self-test the suite job runs before the leaves; nothing but the fixed list selects it.
    'test/windows/interactive-win11.ps1' = 'none'
    # The error publisher the suite job runs when it fails, and the schema it checks a result against (Sol on #740).
    'test/windows/gui-hidden-publish-error.ps1' = 'zig'
    'test/windows/flagship/result.schema.json' = 'package'
    # The git policy the measurement preparation's provenance checks run under (Sol on #740, round 13): .gitignore
    # alone selected nothing before it was a build input.
    '.gitignore' = 'none'
    '.gitattributes' = 'zig'
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

# A leaf that starts a PowerShell found by a wildcard Get-Command, with -File of a child only it reaches: the list
# cannot be computed (the edge is unresolved), so the selection runs the suite for a change to that child alone (Sol on
# #740: the walk omitted the child and a child-only change gave gui=false).
$wildChild = 'test/windows/interactive-win11-wildcard-child.ps1'
$wildReader = {
    param([string] $RepoPath)
    if ($RepoPath -ceq 'test/windows/interactive-win11-smoke.ps1') { return (& $workingReader $RepoPath) + "`n" + '$p = (Get-Command -Name "pwsh.ex?" -CommandType Application | Select-Object -First 1).Source; & $p -NoProfile -File (Join-Path $PSScriptRoot ''interactive-win11-wildcard-child.ps1'')' + "`n" }
    if ($RepoPath -ceq $wildChild) { return '1' }
    return & $workingReader $RepoPath
}.GetNewClosure()
$wildThrew = $false
try { [void](Get-CiGuiList -RepoRoot $repoRoot -HeadReader $wildReader -BaseReader $workingReader) } catch { $wildThrew = $true }
Assert-True $wildThrew 'A leaf that runs a wildcard-found PowerShell with -File must make the GUI list fail, so the selection runs the suite.'
$wildSelected = & {
    try { $l = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $wildReader -BaseReader $workingReader; Get-CiGuiSelection -ChangedPaths @($wildChild) -GuiList $l } catch { $true }
}
Assert-True ($wildSelected -eq $true) 'A change only to the wildcard-launched child must select the GUI suite (through the selection''s fallback).'
# Sol's round-3 form: an extensionless wildcard ExternalScript lookup of the child, then `&` of what it found.
$wildScriptChild = 'test/windows/interactive-win11-wildcard-child.ps1'
$wildScriptReader = {
    param([string] $RepoPath)
    if ($RepoPath -ceq 'test/windows/interactive-win11-smoke.ps1') { return (& $workingReader $RepoPath) + "`n" + '$p = Get-Command -Name (Join-Path $PSScriptRoot ''interactive-win11-wildcard-chil*'') -CommandType ExternalScript; & $p' + "`n" }
    if ($RepoPath -ceq $wildScriptChild) { return '1' }
    return & $workingReader $RepoPath
}.GetNewClosure()
$wildScriptThrew = $false
try { [void](Get-CiGuiList -RepoRoot $repoRoot -HeadReader $wildScriptReader -BaseReader $workingReader) } catch { $wildScriptThrew = $true }
Assert-True $wildScriptThrew 'A leaf that runs a script found by an extensionless wildcard ExternalScript lookup must make the GUI list fail.'
$wildScriptSelected = & {
    try { $l = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $wildScriptReader -BaseReader $workingReader; Get-CiGuiSelection -ChangedPaths @($wildScriptChild) -GuiList $l } catch { $true }
}
Assert-True ($wildScriptSelected -eq $true) 'A change only to the child an extensionless wildcard lookup runs must select the GUI suite (through the selection''s fallback).'

# Sol's round-4 form: an extensionless ExternalScript lookup of `fixtures\cmd` from a leaf. The child is a member of
# the list itself, so a change to it alone selects the suite without the fallback.
foreach ($leafName in @('cmd', 'pwsh')) {
    $lookupChild = "test/windows/fixtures/$leafName.ps1"
    $lookupReader = {
        param([string] $RepoPath)
        if ($RepoPath -ceq 'test/windows/interactive-win11-smoke.ps1') { return (& $workingReader $RepoPath) + "`n" + "`$p = Get-Command -Name (Join-Path `$PSScriptRoot 'fixtures\$leafName') -CommandType ExternalScript; & `$p" + "`n" }
        if ($RepoPath -ceq $lookupChild) { return '1' }
        return & $workingReader $RepoPath
    }.GetNewClosure()
    $lookupList = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $lookupReader -BaseReader $workingReader
    Assert-True ($lookupList -ccontains $lookupChild) "The GUI list must hold $lookupChild, which a leaf's Get-Command <dir>\$leafName runs."
    Assert-True (Get-CiGuiSelection -ChangedPaths @($lookupChild) -GuiList $lookupList) "A change only to $lookupChild must select the GUI suite."
}

# Sol's round-5 forms through the selection: an Application lookup that finds the `.cmd`, and a shipped-module name
# the module lacks run from a fixture directory. A change only to the child must select the suite (through the list,
# or through the fallback when the list fails).
$shadowChild = 'test/windows/fixtures/sol-lookup-shadow.cmd'
foreach ($graft in @(
        @{ Line = '$p = Get-Command -Name (Join-Path $PSScriptRoot ''fixtures\sol-lookup-shadow'') -CommandType Application; & $p'; Child = $shadowChild; Files = @{ 'test/windows/fixtures/sol-lookup-shadow.ps1' = '1'; 'test/windows/fixtures/sol-lookup-shadow.cmd' = '@echo off' } }
        @{ Line = 'Set-Location (Join-Path $PSScriptRoot ''fixtures''); & ''Microsoft.PowerShell.Utility\Run-Child'''; Child = 'test/windows/fixtures/Microsoft.PowerShell.Utility/Run-Child.ps1'; Files = @{ 'test/windows/fixtures/Microsoft.PowerShell.Utility/Run-Child.ps1' = '1' } }
        @{ Line = 'cmd /d /c "$PSScriptRoot\fixtures\helper"'; Child = 'test/windows/fixtures/helper.cmd'; Files = @{ 'test/windows/fixtures/helper.ps1' = '1'; 'test/windows/fixtures/helper.cmd' = '@echo off' } }
        @{ Line = '& (Join-Path $PSScriptRoot ''fixtures\pwsh'') -File (Join-Path $PSScriptRoot ''interactive-win11-lookup-child.ps1'')'; Child = 'test/windows/interactive-win11-lookup-child.ps1'; Files = @{ 'test/windows/fixtures/pwsh.exe' = 'MZ'; 'test/windows/interactive-win11-lookup-child.ps1' = '1' } }
        @{ Line = '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') powershell.exe -File (Join-Path $PSScriptRoot ''interactive-win11-forwarded-child.ps1'')'; Child = 'test/windows/interactive-win11-forwarded-child.ps1'; Files = @{ 'test/windows/fixtures/forward.cmd' = '@%*'; 'test/windows/interactive-win11-forwarded-child.ps1' = '1' } }
    )) {
    $graftLine = $graft.Line; $graftFiles = $graft.Files
    $graftReader = {
        param([string] $RepoPath)
        if ($RepoPath -ceq 'test/windows/interactive-win11-smoke.ps1') { return (& $workingReader $RepoPath) + "`n" + $graftLine + "`n" }
        if ($graftFiles.ContainsKey($RepoPath)) { return $graftFiles[$RepoPath] }
        return & $workingReader $RepoPath
    }.GetNewClosure()
    $graftSelected = & {
        try { $l = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $graftReader -BaseReader $workingReader; Get-CiGuiSelection -ChangedPaths @($graft.Child) -GuiList $l } catch { $true }
    }
    Assert-True ($graftSelected -eq $true) "A change only to $($graft.Child), which a leaf runs through '$graftLine', must select the GUI suite."
}

# A build input the plan spells with backslashes (the plan contract takes any path that exists) selects the suite
# under either spelling of a change, since git reports '/' (CodeRabbit on #740: the list kept the backslash form, the
# ordinal lookup missed it, and Get-CiPathNeeds calls the path none). The path is one only the GUI list can select.
$buildFixture = 'test/windows/interactive-win11-build-fixture.ps1'
Assert-True ((Get-CiPathNeeds $buildFixture) -ceq 'none') "$buildFixture must stay a path Get-CiPathNeeds calls none, or the next checks prove nothing."
Assert-True (-not (Get-CiGuiSelection -ChangedPaths @($buildFixture) -GuiList $list)) 'The build-input fixture must not select the suite while no plan names it (the next check''s control).'
$backslashPlan = $planText | ConvertFrom-Json
$backslashPlan.buildInputs = @($backslashPlan.buildInputs) + @($buildFixture.Replace('/', '\'))
$backslashPlanText = $backslashPlan | ConvertTo-Json -Depth 6
$backslashReader = {
    param([string] $RepoPath)
    if ($RepoPath -ceq 'test/windows/gui-hidden-plan.json') { return $backslashPlanText }
    return & $workingReader $RepoPath
}.GetNewClosure()
$backslashList = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $backslashReader
foreach ($spelling in @($buildFixture, $buildFixture.Replace('/', '\'))) {
    Assert-True (Get-CiGuiSelection -ChangedPaths @($spelling) -GuiList $backslashList) "A build input the plan spells with backslashes must select the suite for a change to $spelling."
}

# A prior tree's reader whose undo script also loads a helper that tree alone has. Each helper path is one
# Get-CiPathNeeds calls `none`, so only the GUI list can select it.
$undoText = & $workingReader $undoPath
function New-PriorTreeReader([string] $Helper) {
    # GetNewClosure keeps this function's own variables, so the script's are copied in first.
    $target = $undoPath; $text = $undoText + "`n. (Join-Path `$PSScriptRoot '$(Split-Path -Leaf $Helper)')`n"; $inner = $workingReader
    return {
        param([string] $RepoPath)
        if ($RepoPath -ceq $target) { return $text }
        if ($RepoPath -ceq $Helper) { return '1' }
        return & $inner $RepoPath
    }.GetNewClosure()
}
# A dependency only the base tree's undo script reaches (CodeRabbit on #740): the list walks the base tree, not only
# its plan, which alone would already put the undo script in the list.
$baseOnly = 'test/windows/interactive-win11-base-only-fixture.ps1'
Assert-True ((Get-CiPathNeeds $baseOnly) -ceq 'none') "$baseOnly must stay a path Get-CiPathNeeds calls none, or the next checks prove nothing."
Assert-True (-not (Get-CiGuiSelection -ChangedPaths @($baseOnly) -GuiList $deletedList)) 'The base-only helper must not select the suite while no tree reaches it (the next check''s control).'
$baseOnlyList = Get-CiGuiList -RepoRoot $repoRoot -HeadReader $headReader -BaseReader (New-PriorTreeReader $baseOnly)
Assert-True (Get-CiGuiSelection -ChangedPaths @($baseOnly) -GuiList $baseOnlyList) 'A change to a dependency only the base tree reaches must select the suite.'
# A dependency only a merge base reaches (Sol on #740): main and the pull request both dropped it after the fork, so
# neither tip has it, while the three-dot diff, which runs from the merge base, lists its deletion.
$mergeBaseOnly = 'test/windows/interactive-win11-merge-base-only-fixture.ps1'
Assert-True ((Get-CiPathNeeds $mergeBaseOnly) -ceq 'none') "$mergeBaseOnly must stay a path Get-CiPathNeeds calls none, or the next checks prove nothing."
$tipsList = Get-CiGuiList -RepoRoot $repoRoot -BaseReader $workingReader
Assert-True (-not (Get-CiGuiSelection -ChangedPaths @($mergeBaseOnly) -GuiList $tipsList)) 'The merge-base helper must not select the suite from the two tips alone (the next check''s control).'
$mergeBaseList = Get-CiGuiList -RepoRoot $repoRoot -BaseReader @($workingReader, (New-PriorTreeReader $mergeBaseOnly))
Assert-True (Get-CiGuiSelection -ChangedPaths @($mergeBaseOnly) -GuiList $mergeBaseList) 'A change to a dependency only a merge base reaches must select the suite.'
# The pull request's prior trees: the base tip and every merge base with the head, full names, each once.
$headCommit = [string](& git -C $repoRoot rev-parse --verify HEAD)
$global:LASTEXITCODE = 0
$priorRefs = Get-CiGuiPriorRefs -RepoRoot $repoRoot -Base 'HEAD' -Head 'HEAD'
Assert-True ($priorRefs.Count -eq 1 -and $priorRefs[0] -ceq $headCommit) "The prior trees of HEAD...HEAD must be HEAD's commit once; got [$($priorRefs -join ', ')]."
$threw = $false
try { $null = Get-CiGuiPriorRefs -RepoRoot $repoRoot -Base "no-such-ref-$([guid]::NewGuid().ToString('N'))" -Head 'HEAD' } catch { $threw = $true }
Assert-True $threw 'A base that names no commit must fail the prior trees (the selection then runs the suite).'

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
    # CodeRabbit on #740: the wildcard fixtures catch the list's failure themselves, so they cannot show the
    # production script falling back. A small tree holding the real selection scripts: a leaf that runs its child
    # through a wildcard Get-Command makes the script fall back (exit 0, gui=true) for a change to that child alone;
    # the same leaf with a literal edge selects through the list, and an unrelated change selects nothing.
    # Under a directory with a space in its name (CodeRabbit on #740), so a quoted command path is exercised as one token.
    $miniRoot = Join-Path ([IO.Path]::GetTempPath()) ("noctty gui-selection-tree-$([guid]::NewGuid().ToString('N'))")
    try {
        [void](New-Item -ItemType Directory -Path (Join-Path $miniRoot 'scripts'), (Join-Path $miniRoot 'test\windows'))
        foreach ($name in @('ci-gui-selection.ps1', 'ci-changed-paths.ps1', 'ci-script-closure.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\$name") -Destination (Join-Path $miniRoot "scripts\$name") }
        [IO.File]::WriteAllText((Join-Path $miniRoot 'test\windows\gui-hidden-plan.json'), '{"schemaVersion":1,"buildInputs":["test/windows/gui-hidden-plan.json"],"leaves":[{"id":"smoke","script":"test/windows/interactive-win11-smoke.ps1"}]}')
        [IO.File]::WriteAllText((Join-Path $miniRoot 'test\windows\interactive-win11-wildcard-child.ps1'), '1')
        [void](New-Item -ItemType Directory -Path (Join-Path $miniRoot 'test\windows\fixtures'))
        [IO.File]::WriteAllText((Join-Path $miniRoot 'test\windows\fixtures\sol-r6-helper.cmd'), '@echo %1')
        [IO.File]::WriteAllText((Join-Path $miniRoot 'test\windows\fixtures\pwsh.cmd'), '@echo %*')
        foreach ($name in @('sol-helper.cmd', 'cmd.cmd', 'forward.cmd')) { [IO.File]::WriteAllText((Join-Path $miniRoot "test\windows\fixtures\$name"), '@echo %*') }
        [void](New-Item -ItemType Directory -Path (Join-Path $miniRoot 'test\windows\fixtures\tools'))
        [IO.File]::WriteAllText((Join-Path $miniRoot 'test\windows\fixtures\tools\pwsh.cmd'), '@echo %*')
        foreach ($mini in @(
                @{ Name = 'a wildcard edge, the child changed'; Leaf = '$p = Get-Command -Name (Join-Path $PSScriptRoot ''interactive-win11-wildcard-chil*'') -CommandType ExternalScript; & $p'; Path = 'test/windows/interactive-win11-wildcard-child.ps1'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'a literal edge, the child changed'; Leaf = '& (Join-Path $PSScriptRoot ''interactive-win11-wildcard-child.ps1'')'; Path = 'test/windows/interactive-win11-wildcard-child.ps1'; Expect = 'gui=true'; Fallback = $false }
                @{ Name = 'a literal edge, an unrelated leaf changed'; Leaf = '& (Join-Path $PSScriptRoot ''interactive-win11-wildcard-child.ps1'')'; Path = 'test/windows/interactive-win11-key-input.ps1'; Expect = 'gui=false'; Fallback = $false }
                # cmd and batch files are refused: each form falls back to the suite, under the spaced root (CodeRabbit
                # on #740), an explicit, quoted batch path included.
                @{ Name = 'cmd running the helper by its quoted, explicit path, the helper changed'; Leaf = 'cmd.exe /d /c "$PSScriptRoot\fixtures\sol-r6-helper.cmd" sentinel'; Path = 'test/windows/fixtures/sol-r6-helper.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'a forwarding wrapper running a helper named by a plain word (Sol, round 8)'; Leaf = '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') sol-helper'; Path = 'test/windows/fixtures/sol-helper.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'cmd running an extensionless helper with an argument (Sol, round 6)'; Leaf = 'cmd.exe /d /c "$PSScriptRoot\fixtures\sol-r6-helper sentinel"'; Path = 'test/windows/fixtures/sol-r6-helper.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'cmd running a path named pwsh (Greptile)'; Leaf = 'cmd.exe /d /c "$PSScriptRoot\fixtures\pwsh" -Version'; Path = 'test/windows/fixtures/pwsh.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'cmd running tools\pwsh in one string (CodeRabbit)'; Leaf = 'cmd /c "$PSScriptRoot\fixtures\tools\pwsh -File $PSScriptRoot\interactive-win11-wildcard-child.ps1"'; Path = 'test/windows/fixtures/tools/pwsh.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'cmd calling a path named cmd (Sol, round 7)'; Leaf = 'cmd.exe /d /c "call $PSScriptRoot\fixtures\cmd sentinel"'; Path = 'test/windows/fixtures/cmd.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'cmd with a leading redirect (Sol, round 7)'; Leaf = 'cmd.exe /d /c "2>nul $PSScriptRoot\fixtures\sol-helper sentinel"'; Path = 'test/windows/fixtures/sol-helper.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'a forwarding wrapper running a later powershell.exe -EncodedCommand (Greptile)'; Leaf = '& (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') run powershell.exe -EncodedCommand ZQBjAGgAbwAgAHgA'; Path = 'test/windows/fixtures/forward.cmd'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'Start-Process packing -File into an -ExecutionPolicy element (Sol, round 9)'; Leaf = 'Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', "Bypass -File $PSScriptRoot\interactive-win11-wildcard-child.ps1"'; Path = 'test/windows/interactive-win11-wildcard-child.ps1'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'Start-Process packing -File into a variable after -ExecutionPolicy (Sol, round 10)'; Leaf = '$a = "Bypass -File $PSScriptRoot\interactive-win11-wildcard-child.ps1"; Start-Process pwsh -ArgumentList ''-NoProfile'', ''-ExecutionPolicy'', $a'; Path = 'test/windows/interactive-win11-wildcard-child.ps1'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'an array variable in an & value slot (Opus, round 10)'; Leaf = '$policy = @(''Bypass'', ''-File'', "$PSScriptRoot\interactive-win11-wildcard-child.ps1"); & pwsh -NoProfile -ExecutionPolicy $policy'; Path = 'test/windows/interactive-win11-wildcard-child.ps1'; Expect = 'gui=true'; Fallback = $true }
                @{ Name = 'Start-Process forwarding "/d /c" as one element (Sol, round 7)'; Leaf = 'Start-Process -FilePath (Join-Path $PSScriptRoot ''fixtures\forward.cmd'') -ArgumentList "cmd.exe", "/d /c", "$PSScriptRoot\fixtures\sol-helper.cmd sentinel" -Wait'; Path = 'test/windows/fixtures/sol-helper.cmd'; Expect = 'gui=true'; Fallback = $true }
            )) {
            [IO.File]::WriteAllText((Join-Path $miniRoot 'test\windows\interactive-win11-smoke.ps1'), $mini.Leaf)
            if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
            $said = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $miniRoot 'scripts\ci-gui-selection.ps1') -Paths $mini.Path 3>&1 6>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            $lines = @(if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile })
            $fellBack = @($said | Where-Object { $_.Contains('selection unavailable') }).Count -gt 0
            Assert-True ($code -eq 0 -and $lines.Count -eq 1 -and $lines[0] -ceq $mini.Expect -and $fellBack -eq $mini.Fallback) "The production selection on $($mini.Name) must exit 0, write $($mini.Expect) and fall back: $($mini.Fallback); wrote [$($lines -join ', ')], exit $code, fell back: $fellBack."
        }
    }
    finally { Remove-Item -LiteralPath $miniRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
finally {
    $env:GITHUB_OUTPUT = $savedOutput
    $env:GITHUB_STEP_SUMMARY = $savedSummary
    if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
    $global:LASTEXITCODE = 0
}

Write-Host "gui-hidden-scripts: $script:passed checks passed."
