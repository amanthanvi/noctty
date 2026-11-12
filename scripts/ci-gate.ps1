#requires -Version 5.1
<#
.SYNOPSIS
The always-running gate job of test.yml and windows-arm64.yml.

.DESCRIPTION
`needs` is the toJSON of the gate job's needs context. Every listed job is
expected as `job:flag`. `always` means it must have succeeded. Any other flag
names an output of the `changes` job: when it is 'true' the job must have
succeeded, and when it is 'false' the job must have been skipped. A job that is
skipped while its flag is 'true' (because something it needs failed) or that
succeeded while its flag is 'false' is a problem too, so a skip can never stand
in for a failure.

The gate is the check the `main: CI gates` ruleset requires, one per workflow.
It keeps the old job's name, so a rule written against that name keeps its
meaning. Its job runs under `always()`: under `!cancelled()` a cancelled run
skips it, and a skipped required check counts as passing.
#>
[CmdletBinding()]
param(
    [string] $NeedsJson = $env:NEEDS_JSON,
    [string[]] $Expect,
    [switch] $LibraryOnly
)

function Get-CiGateProblems {
    param(
        [Parameter(Mandatory)] [object] $Needs,
        [Parameter(Mandatory)] [string[]] $Expect
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $changes = $Needs.PSObject.Properties['changes']
    if ($null -eq $changes -or $changes.Value.result -ne 'success') {
        $found = if ($null -eq $changes) { 'missing' } else { $changes.Value.result }
        $problems.Add("changes: expected success, found $found")
        return , $problems.ToArray()
    }
    foreach ($entry in $Expect) {
        $name, $flag = $entry -split ':', 2
        $property = $Needs.PSObject.Properties[$name]
        if ($null -eq $property) { $problems.Add("${name}: missing from needs"); continue }
        $result = $property.Value.result
        if ($flag -eq 'always') {
            if ($result -ne 'success') { $problems.Add("${name}: expected success, found $result") }
            continue
        }
        $output = $changes.Value.outputs.PSObject.Properties[$flag]
        if ($null -eq $output) { $problems.Add("${name}: the changes job has no output '$flag'"); continue }
        # Job outputs are strings. A value that is neither 'true' nor 'false'
        # (empty, a typo) makes every `== 'true'` condition skip its job, so it
        # must not read as "not needed".
        if ($output.Value -ceq 'true') {
            if ($result -ne 'success') { $problems.Add("${name}: needed ($flag=true) and found $result") }
        }
        elseif ($output.Value -ceq 'false') {
            if ($result -ne 'skipped') { $problems.Add("${name}: not needed ($flag=false) and found $result") }
        }
        else {
            $problems.Add("${name}: the changes job output '$flag' is '$($output.Value)', not 'true' or 'false'")
        }
    }
    return , $problems.ToArray()
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
$needs = $NeedsJson | ConvertFrom-Json
# `pwsh -File x.ps1 -Expect a,b` hands a string[] parameter the one string 'a,b'.
$Expect = @($Expect | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$problems = Get-CiGateProblems -Needs $needs -Expect $Expect
foreach ($job in $needs.PSObject.Properties) {
    Write-Host ('{0,-24} {1}' -f $job.Name, $job.Value.result)
}
if ($problems.Count -gt 0) {
    # Not Write-Error: under $ErrorActionPreference = 'Stop' the first one would
    # end the script and hide the rest. ::error:: is a workflow annotation.
    $problems | ForEach-Object { Write-Host "::error title=CI gate::$_" }
    exit 1
}
Write-Host 'Every needed job succeeded and every skipped job was not needed.' -ForegroundColor Green
