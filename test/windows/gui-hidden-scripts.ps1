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
    'Start-Process pwsh.exe -ArgumentList @(...)' = 'Start-Process -FilePath pwsh.exe -ArgumentList @(''-NoProfile'', ''-File'', (Join-Path $PSScriptRoot ''child.ps1'')) -Wait'
    'Start-Process powershell.exe with a comma list' = 'Start-Process powershell.exe -ArgumentList ''-NoProfile'', ''-File'', "$PSScriptRoot\child.ps1"'
    'Start-Job -FilePath' = 'Start-Job -FilePath (Join-Path $PSScriptRoot ''child.ps1'') | Receive-Job -Wait'
    'Invoke-Command -FilePath' = 'Invoke-Command -ComputerName localhost -FilePath "$PSScriptRoot\child.ps1"'
    'Invoke-Expression of a literal' = 'Invoke-Expression ". ''$PSScriptRoot\child.ps1''"'
    'a local function returning the path' = 'function Get-ChildPath { Join-Path $PSScriptRoot ''child.ps1'' }' + "`n" + '& (Get-ChildPath)'
    'cmd /c pwsh -File' = 'cmd.exe /d /c pwsh -NoProfile -File "$PSScriptRoot\child.ps1"'
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
    'a module-qualified Start-Process' = @('Microsoft.PowerShell.Management\Start-Process pwsh -ArgumentList ''-File'', "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'a module-qualified Invoke-Expression' = @('Microsoft.PowerShell.Utility\Invoke-Expression ". ''$PSScriptRoot\child.ps1''"', 'test/windows/child.ps1')
    'a module-qualified Start-Job' = @('Microsoft.PowerShell.Core\Start-Job -FilePath "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
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
    'Start-Process with common parameters' = @('Start-Process -ErrorAction Stop -FilePath pwsh -Verbose -ArgumentList ''-File'', "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Start-Job -LP (an alias of -LiteralPath)' = @('Start-Job -LP "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Start-Job -l (a prefix of -LiteralPath)' = @('Start-Job -l "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Start-Job -Verbose, then its positional file' = @('Start-Job -Verbose "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Invoke-Command -PSPath (an alias of -FilePath)' = @('Invoke-Command -ComputerName localhost -PSPath "$PSScriptRoot\child.ps1"', 'test/windows/child.ps1')
    'Import-Module after common parameters' = @('Import-Module -Verbose -ErrorAction Stop (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    'Add-Type -LP (an alias of -LiteralPath)' = @('Add-Type -LP (Join-Path $PSScriptRoot ''native.cs'')', 'test/windows/native.cs')
    'Add-Type -PSPath (an alias of -LiteralPath)' = @('Add-Type -ErrorAction Stop -PSPath (Join-Path $PSScriptRoot ''native.cs'')', 'test/windows/native.cs')
    'pwsh -in (its -Interactive), then the file' = @('pwsh -NoProfile -in (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
    'pwsh -token <value>, then -File' = @('pwsh -NoProfile -token t -File (Join-Path $PSScriptRoot ''child.ps1'')', 'test/windows/child.ps1')
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
    'Invoke-Command of a scriptblock on a session' = 'Invoke-Command -Session $session -ScriptBlock { 1 }'
    'Invoke-Command with a positional scriptblock' = 'Invoke-Command $session { 1 }'
    'Add-Type of an assembly, with -ErrorAction' = 'Add-Type -AssemblyName System.Drawing -ErrorAction Stop'
    'Add-Type of source text by position' = 'Add-Type ''public class Fixture {}'''
}
foreach ($form in $boundQuiet.Keys) {
    $formWalk = Get-FixtureWalk @{ 'test/windows/entry.ps1' = $boundQuiet[$form] }
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
    # The helper self-test the suite job runs before the leaves; nothing but the fixed list selects it.
    'test/windows/interactive-win11.ps1' = 'none'
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
}
finally {
    $env:GITHUB_OUTPUT = $savedOutput
    $env:GITHUB_STEP_SUMMARY = $savedSummary
    if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile }
    $global:LASTEXITCODE = 0
}

Write-Host "gui-hidden-scripts: $script:passed checks passed."
