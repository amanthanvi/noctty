#requires -Version 7.0
<#
Checks hidden-win11-tab-tearoff.ps1's marker readers, loaded from that script
through the parser so the functions tested are the ones it runs:
`Find-Marker` (a terminal's UIA text), `Find-ConsoleMarker` (a console's rows)
and `Add-ConsoleMarker` (markers to console windows, a duplicate mapping to
neither). Cases: a marker whole on one row; a marker wrapped inside its last
number, which must come back whole, not cut short at the wrap; a marker with
no `-END`, which is no marker; and two consoles that both show one marker,
wrapped, which must map to neither. Starts nothing; no run directory.
#>
[CmdletBinding()]
param([string] $Harness = (Join-Path $PSScriptRoot 'hidden-win11-tab-tearoff.ps1'))
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Harness, [ref]$null, [ref]$errors)
if ($errors.Count) { throw "$Harness does not parse." }
foreach ($name in @('Find-Marker', 'Find-ConsoleMarker', 'Add-ConsoleMarker')) {
    $found = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $found) { throw "$name is not in $Harness." }
    . ([scriptblock]::Create($found.Extent.Text))
}

$checks = [Collections.Generic.List[object]]::new()
function Check([string]$Name, [bool]$Passed, $Actual) { $checks.Add(@{ Name = $Name; Passed = $Passed; Actual = $Actual }) }

$whole = 'TEAROFF-123-456-789-END'
# UIA text.
$got = Find-Marker "C:\>echo`r`n$whole`r`nC:\>"
Check 'UIA text: a marker whole on its row' ($got -ceq $whole) $got
$got = Find-Marker "C:\>echo`r`nTEAROFF-123-456-7`r`n89-END`r`nC:\>"
Check 'UIA text: a marker wrapped inside its last number comes back whole' ($got -ceq $whole) $got
$got = Find-Marker "TEAROFF-123-456-789`r`nC:\>"
Check 'UIA text: no -END, no marker' ($null -eq $got) $got
# Console rows.
$got = Find-ConsoleMarker @('C:\>echo', $whole, 'C:\>')
Check 'console rows: a marker whole on its row' ($got -ceq $whole) $got
$got = Find-ConsoleMarker @('TEAROFF-123-456-7', '89-END', 'C:\>')
Check 'console rows: a marker wrapped inside its last number comes back whole' ($got -ceq $whole) $got
$got = Find-ConsoleMarker @('TEAROFF-123-4', '56-789-END')
Check 'console rows: a marker wrapped inside its middle number comes back whole' ($got -ceq $whole) $got
# Duplicates: two consoles both show one marker, wrapped differently.
$map = @{}
Add-ConsoleMarker $map (Find-ConsoleMarker @('TEAROFF-123-456-7', '89-END')) ([IntPtr]101)
Add-ConsoleMarker $map (Find-ConsoleMarker @('TEAROFF-1', '23-456-789-END')) ([IntPtr]202)
Add-ConsoleMarker $map (Find-ConsoleMarker @('TEAROFF-9-9-9-END')) ([IntPtr]303)
Check 'a wrapped marker two consoles show maps to neither' ($map.Count -eq 2 -and $map[$whole] -eq [IntPtr]::Zero) ($map.Keys -join ',')
Check 'a marker one console shows maps to its window' ($map['TEAROFF-9-9-9-END'] -eq [IntPtr]303) $map['TEAROFF-9-9-9-END']

$failed = @($checks | Where-Object { -not $_.Passed })
Write-Host ("checks passed {0}/{1}" -f ($checks.Count - $failed.Count), $checks.Count)
if ($failed.Count) { $failed | ForEach-Object { Write-Host ('FAIL: {0} (got {1})' -f $_.Name, $_.Actual) }; exit 1 }
