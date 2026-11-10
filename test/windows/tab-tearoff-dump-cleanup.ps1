#requires -Version 7.0
<#
Checks what hidden-win11-tab-tearoff.ps1 does with the console dumps a run
left once the driver is done (`Settle-ConsoleDumps`, loaded from that script
through the parser so the function tested is the one it runs). Each case is a
directory with two dumps (`attach-<8 hex>.txt` and its `.log`), a file with a
similar name (`attach-x`) and another file, and the `startup-state.json`
`Invoke-LocalHiddenDriver` writes:

- the job not confirmed empty (`OwnedJobCleanedUp` false: what a failed or
  timed-out `StopOwnedJob` records), and no state at all: nothing is
  deleted, and each dump is reported by path;
- the job confirmed empty: the two dumps go, nothing else;
- a dump held open with no sharing: its failed deletion is reported, not
  swallowed.

Starts no process and touches no desktop. Run with -Run <new directory>.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Run)
$ErrorActionPreference = 'Stop'
$Run = [IO.Path]::GetFullPath($Run)
if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hidden-win11-tab-tearoff.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'hidden-win11-tab-tearoff.ps1 does not parse.' }
$found = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Settle-ConsoleDumps' }, $true)
if (-not $found) { throw 'Settle-ConsoleDumps is not in hidden-win11-tab-tearoff.ps1.' }
. ([scriptblock]::Create($found.Extent.Text))

$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Passed) { $checks.Add(@{ Name = $Name; Passed = $Passed }) }
function New-Case([string]$Name, $Cleaned) {
    $dir = Join-Path $Run $Name
    [void](New-Item -ItemType Directory -Path $dir)
    foreach ($file in @('attach-0123abcd.txt', 'attach-0123abcd.txt.log', 'attach-x', 'other.txt')) { Set-Content -LiteralPath (Join-Path $dir $file) -Value 'x' }
    if ($null -ne $Cleaned) { @{ OwnedJobCleanedUp = $Cleaned } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'startup-state.json') }
    return $dir
}
function Present([string]$Dir) { return @(Get-ChildItem -LiteralPath $Dir -File | ForEach-Object { $_.Name } | Sort-Object) -join ',' }
$all = 'attach-0123abcd.txt,attach-0123abcd.txt.log,attach-x,other.txt,startup-state.json'

[void](New-Item -ItemType Directory -Path $Run)
# The job cleanup failed: nothing goes, both dumps are reported.
$dir = New-Case 'job-not-empty' $false
$r = Settle-ConsoleDumps $dir
Check 'job cleanup failed: no dump deleted' ((Present $dir) -eq $all)
Check 'job cleanup failed: both dumps reported by path' ($r.Left.Count -eq 2 -and @($r.Left | Where-Object { $_ -like (Join-Path $dir 'attach-0123abcd.txt*') }).Count -eq 2 -and $r.Removed.Count -eq 0 -and $r.Failed.Count -eq 0)
# No state at all (the driver never got that far): the same.
$dir = New-Case 'no-state' $null
$r = Settle-ConsoleDumps $dir
Check 'no job state: no dump deleted, both reported' ((Present $dir) -eq 'attach-0123abcd.txt,attach-0123abcd.txt.log,attach-x,other.txt' -and $r.Left.Count -eq 2)
# The job confirmed empty: the two dumps go, nothing else.
$dir = New-Case 'job-empty' $true
$r = Settle-ConsoleDumps $dir
Check 'job empty: the dumps go and nothing else' ((Present $dir) -eq 'attach-x,other.txt,startup-state.json' -and $r.Removed.Count -eq 2 -and $r.Left.Count -eq 0 -and $r.Failed.Count -eq 0)
# A dump that cannot be deleted: reported, not swallowed.
$dir = New-Case 'locked' $true
$held = [IO.File]::Open((Join-Path $dir 'attach-0123abcd.txt'), 'Open', 'Read', 'None')
try { $r = Settle-ConsoleDumps $dir } finally { $held.Dispose() }
Check 'a dump that cannot be deleted is reported' ($r.Failed.Count -eq 1 -and $r.Failed[0] -like ((Join-Path $dir 'attach-0123abcd.txt') + ':*') -and (Test-Path -LiteralPath (Join-Path $dir 'attach-0123abcd.txt')))

$failed = @($checks | Where-Object { -not $_.Passed })
Write-Host ("checks passed {0}/{1}" -f ($checks.Count - $failed.Count), $checks.Count)
if ($failed.Count) { $failed | ForEach-Object { Write-Host ('FAIL: ' + $_.Name) }; exit 1 }
