#requires -Version 7.0
<#
Budget for the Zig tests that skip themselves (PKG-76, F207).

Some tests return error.SkipZigTest when the machine lacks something: the complex-script shaping tests
load system fonts such as "Arial Unicode MS", which a hosted runner does not have. `zig build test`
reports only a total ("74 skipped"), so a test that starts skipping in CI looks the same as one that
always did, and shaping regressions for Devanagari, Tibetan or Bengali pass unobserved.

This reads the per-test output of the test executable (`ghostty-test.exe`, run directly, prints
`N/M <qualified name>...OK|SKIP|FAIL`) and fails when
  * a test in the guarded family (names starting with `familyPrefix`) skips and is not on the runner's
    allowlist, or
  * the total number of skipped tests is above the runner's `maxTotalSkipped`, or
  * the log is incomplete or inconsistent (no closing `N passed; N skipped; N failed.` line, or counts that
    disagree with the tests parsed), so a crash cannot pass as a budget.
An allowlisted test that runs is fine: the list is an upper bound, because a developer's machine has
more fonts than a runner. Lower the numbers when a skip goes away; raise them only with a reason in
the commit, since that is the decision this check exists to force.

  pwsh scripts/check-test-skips.ps1 -TestLog ghostty-test.log -Runner windows-2025
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TestLog,
    [Parameter(Mandatory)] [string] $Runner,
    [string] $BudgetFile = (Join-Path $PSScriptRoot '..\test\windows\test-skip-budget.json'),
    # Validate the run, then print guarded skips without enforcing a runner budget, to draft an allowlist.
    [switch] $Report
)
$ErrorActionPreference = 'Stop'

$budget = Get-Content -LiteralPath $BudgetFile -Raw | ConvertFrom-Json
if ($budget.schema_version -ne 1) { throw "Unsupported budget schema $($budget.schema_version)." }
$prefix = [string]$budget.familyPrefix
$limits = $budget.runners.$Runner
if (-not $limits -and -not $Report) {
    throw "No budget for runner '$Runner'. Known runners: $(($budget.runners.PSObject.Properties.Name) -join ', ')."
}

$announced = 0
$summary = $null
$parsed = [Collections.Generic.List[object]]::new()
$pending = $null
$problems = [Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $TestLog) {
    # The runner prints `N/M name...` and then OK, SKIP or FAIL, on the same line unless the test logged
    # in between: the log lines follow the header and the result stands alone on a later line.
    if ($null -ne $pending) {
        if ($line -match '^(OK|SKIP|FAIL)(?: \([^)]+\))?\s*$') {
            $parsed.Add([pscustomobject]@{ Index = $pending.Index; Name = $pending.Name; Result = $Matches[1] })
            $pending = $null
            continue
        }
    }
    $header = [regex]::Match($line, '^(\d+)/(\d+) (.*?)\.\.\.(.*)$')
    if ($header.Success) {
        if ($null -ne $summary) { $problems.Add('A per-test header follows the closing line.') }
        if ($null -ne $pending) { $problems.Add("Test $($pending.Index) has no result before the next header.") }
        if ([int]$header.Groups[1].Value -ne $parsed.Count + 1) { $problems.Add('Per-test indexes are not sequential.') }
        $count = [int]$header.Groups[2].Value
        if ($announced -ne 0 -and $count -ne $announced) { $problems.Add('Per-test announced totals changed within the run.') }
        if ($announced -eq 0) { $announced = $count }
        $item = [pscustomobject]@{ Index = [int]$header.Groups[1].Value; Name = $header.Groups[3].Value }
        $rest = $header.Groups[4].Value
        if ($rest -match '^(OK|SKIP|FAIL)(?: \([^)]+\))?\s*$') { $parsed.Add([pscustomobject]@{ Index = $item.Index; Name = $item.Name; Result = $Matches[1] }); $pending = $null }
        else { $pending = $item }
        continue
    }
    $total = [regex]::Match($line, '^(\d+) passed; (\d+) skipped; (\d+) failed\.$')
    $allPassed = [regex]::Match($line, '^All (\d+) tests passed\.$')
    if ($total.Success -or $allPassed.Success) {
        if ($null -ne $summary) { $problems.Add('The log contains more than one closing line.') }
        if ($null -ne $pending) { $problems.Add("Test $($pending.Index) has no result before the closing line.") }
        $summary = if ($total.Success) { @{ Passed = [int]$total.Groups[1].Value; Skipped = [int]$total.Groups[2].Value; Failed = [int]$total.Groups[3].Value } }
            else { @{ Passed = [int]$allPassed.Groups[1].Value; Skipped = 0; Failed = 0 } }
    }
    elseif ($line -match '^\d+/\d+\b|^(OK|SKIP|FAIL)(?: \([^)]+\))?\s*$') { $problems.Add('Malformed per-test header or result without a pending test.') }
}
if ($parsed.Count -eq 0) { $problems.Add('The log holds no per-test lines; run ghostty-test.exe directly and pass its output.') }
elseif ($null -eq $summary) { $problems.Add("The log has no closing 'N passed; N skipped; N failed.' line, so the run did not finish ($($parsed.Count) of $announced tests reported).") }
elseif ($parsed.Count -ne $announced -or ($summary.Passed + $summary.Skipped + $summary.Failed) -ne $announced) {
    $problems.Add("The log is inconsistent: $($parsed.Count) tests parsed, $announced announced, the closing line counts $($summary.Passed + $summary.Skipped + $summary.Failed).")
}
if ($null -ne $summary) {
    foreach ($status in @{ OK = 'Passed'; SKIP = 'Skipped'; FAIL = 'Failed' }.GetEnumerator()) {
        $actual = @($parsed | Where-Object Result -eq $status.Key).Count
        if ($actual -ne $summary[$status.Value]) { $problems.Add("Parsed $actual $($status.Value) tests but the closing line says $($summary[$status.Value]).") }
    }
}
if (@($parsed | Where-Object Result -eq 'FAIL').Count -gt 0) { $problems.Add('The test run contains failed tests.') }
# Reporting may relax the allowlist, never the requirement for a complete, successful test run.
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { [Console]::Error.WriteLine("SKIP BUDGET: $problem") }
    exit 1
}

$skipped = @($parsed | Where-Object Result -eq 'SKIP')
$family = @($skipped | Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::Ordinal) })
Write-Host ("{0} tests, {1} skipped, {2} of them in '{3}'" -f $parsed.Count, $skipped.Count, $family.Count, $prefix)
if ($Report) {
    foreach ($test in $family) { Write-Host "  $($test.Name)" }
    exit 0
}

$allowed = @($limits.allowedSkips)
foreach ($test in $family) {
    if ($allowed -cnotcontains $test.Name) {
        $problems.Add("A test in '$prefix' skips and is not on the '$Runner' allowlist: $($test.Name)")
    }
}
if ($skipped.Count -gt [int]$limits.maxTotalSkipped) {
    $problems.Add("$($skipped.Count) tests skipped; the '$Runner' budget is $($limits.maxTotalSkipped).")
}
$stale = @($allowed | Where-Object { $name = $_; -not ($skipped | Where-Object { $_.Name -ceq $name }) })
if ($stale.Count -gt 0) {
    Write-Host "Allowlisted but not skipped here ($($stale.Count)); the list can shrink once every runner agrees:"
    foreach ($name in $stale) { Write-Host "  $name" }
}
if ($skipped.Count -lt [int]$limits.maxTotalSkipped) {
    Write-Host "Skipped $($skipped.Count) against a budget of $($limits.maxTotalSkipped); lower maxTotalSkipped if this holds on the runner."
}
foreach ($problem in $problems) { [Console]::Error.WriteLine("SKIP BUDGET: $problem") }
if ($problems.Count -gt 0) { exit 1 }
Write-Host "Skip budget for '$Runner': PASS"
