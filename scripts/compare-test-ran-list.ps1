#requires -Version 7.0
<#
.SYNOPSIS
Checks that every test that ran in a baseline ran list runs again in a later
one: as OK, as an approved SKIP, or as a ledgered removal.

.DESCRIPTION
Lists come from scripts/capture-test-ran-list.ps1. A test's identity is its
suite and its fully qualified name. An unnamed `test { ... }` block is named by
its position (`<file>.test_<n>`), so a block added above it renumbers it: the
compare counts a file's unnamed blocks instead (`<file>.test_#`, with their
number as the multiplicity), which still fails a dropped one.

Several -Baseline lists are united (a merge's two fork-side parents, or a
carried-forward baseline): an identity counts with the largest multiplicity any
baseline gives it, and as OK if any baseline ran it OK. A baseline must exist,
parse, hold rows and have no FAIL row; a missing or empty one fails the check
and is never taken as empty. The lists' `# build:` options must agree, since a
test that only some options compile would otherwise read as dropped.

For each baseline identity, the later list fails the check when it
  * has it FAIL (any FAIL row fails, baseline or not);
  * has fewer occurrences than the baseline (DROPPED), unless -Removals ledgers it;
  * has it SKIP where the baseline ran it OK (TURNED-SKIP), unless -ApprovedSkips
    lists it.
A test that the baseline already skipped and that still skips is reported
(CARRIED-SKIP) and passes: its skip predates the check, as a hosted runner's
font skips do. Tests only the later list has are counted as new.

-Removals and -ApprovedSkips are tab-separated `<suite><TAB><qualified
name><TAB><reason>` lines; `#` starts a comment line. Every entry needs a
reason: a removal names the residual- or dropped-delta-ledger entry it rests on
(PLAN.md §3.2), a skip its reviewed allowance.

  pwsh scripts/compare-test-ran-list.ps1 -Baseline main-ran-list.tsv -Candidate branch-ran-list.tsv `
      -Removals ran-list-removals.tsv -ApprovedSkips ran-list-skips.tsv
#>
[CmdletBinding()]
param(
    [string[]] $Baseline = @(),
    [string] $Candidate,
    [string] $Removals,
    [string] $ApprovedSkips,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

$script:RanListFormat = '# noctty test ran list v1'

# The identity the compare keys on: a positional unnamed test name loses its number.
function Get-RanListIdentity {
    param([Parameter(Mandatory)] [string] $Suite, [Parameter(Mandatory)] [string] $Name)
    return "$Suite`t$($Name -replace '\.test_\d+$', '.test_#')"
}

# Reads a list into Build, Rows and Problems. A file that is missing, empty,
# not a v1 list, cut short or inconsistent with its end line has problems.
function Read-RanList {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    $problems = [Collections.Generic.List[string]]::new()
    $rows = [Collections.Generic.List[object]]::new()
    $build = $null
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $problems.Add("The ran list '$Path' does not exist.")
        return [pscustomobject]@{ Path = $Path; Build = $null; Rows = @(); Problems = $problems.ToArray() }
    }
    $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))
    if ($lines.Count -eq 0 -or $lines[0] -cne $script:RanListFormat) {
        $problems.Add("'$Path' is not a ran list (its first line is not '$($script:RanListFormat)').")
        return [pscustomobject]@{ Path = $Path; Build = $null; Rows = @(); Problems = $problems.ToArray() }
    }
    $end = $null
    $total = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -ne $end) { if ($line.Length -gt 0) { $problems.Add("'$Path' has text after its end line.") }; continue }
        if ($line.StartsWith('# end: ')) { $end = $line; continue }
        if ($line.StartsWith('# build: ')) { $build = $line.Substring(9); continue }
        if ($line.StartsWith('#')) { continue }
        $fields = $line -split "`t", 4
        if ($fields.Count -ne 4 -or $fields[1] -cnotin @('OK', 'SKIP', 'FAIL') -or $fields[2] -notmatch '^[1-9]\d*$' -or $fields[3].Length -eq 0) {
            $problems.Add("'$Path' line $($i + 1) is not '<suite><TAB><OK|SKIP|FAIL><TAB><count><TAB><name>'.")
            continue
        }
        $rows.Add([pscustomobject]@{ Suite = $fields[0]; Result = $fields[1]; Count = [int]$fields[2]; Name = $fields[3] })
        $total += [int]$fields[2]
    }
    if ($null -eq $end) { $problems.Add("'$Path' has no '# end:' line, so it was cut short.") }
    elseif ($end -cne "# end: rows=$($rows.Count) tests=$total") { $problems.Add("'$Path' does not match its end line ($end; read rows=$($rows.Count) tests=$total).") }
    if ($null -eq $build) { $problems.Add("'$Path' has no '# build:' line.") }
    if ($rows.Count -eq 0) { $problems.Add("'$Path' holds no tests; a baseline is never taken as empty.") }
    return [pscustomobject]@{ Path = $Path; Build = $build; Rows = $rows.ToArray(); Problems = $problems.ToArray() }
}

# Reads a ledger of `<suite><TAB><name><TAB><reason>` lines into a set of identities.
function Read-RanListLedger {
    param([string] $Path, [Parameter(Mandatory)] [string] $Kind, [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.Generic.List[string]] $Problems)
    $entries = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $entries }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $Problems.Add("The $Kind file '$Path' does not exist."); return $entries }
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))) {
        $n++
        if ($line.Trim().Length -eq 0 -or $line.StartsWith('#')) { continue }
        $fields = $line -split "`t"
        if ($fields.Count -ne 3 -or $fields[0].Length -eq 0 -or $fields[1].Length -eq 0 -or $fields[2].Trim().Length -eq 0) {
            $Problems.Add("$Kind line $n is not '<suite><TAB><qualified name><TAB><reason>' with a reason.")
            continue
        }
        $id = Get-RanListIdentity -Suite $fields[0] -Name $fields[1]
        if ($entries.ContainsKey($id)) { $Problems.Add("$Kind lists '$($fields[0]) $($fields[1])' twice.") }
        $entries[$id] = $fields[2]
    }
    return $entries
}

# Per identity: OK, SKIP and FAIL occurrences.
function Get-RanListTally {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows)
    $tally = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) {
        $id = Get-RanListIdentity -Suite $row.Suite -Name $row.Name
        if (-not $tally.ContainsKey($id)) { $tally[$id] = [pscustomobject]@{ OK = 0; SKIP = 0; FAIL = 0 } }
        $tally[$id].($row.Result) += $row.Count
    }
    return $tally
}

# The verdict: Problems (each one fails the check) and Notes (reported only).
function Compare-RanList {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $BaselineLists,
        [Parameter(Mandatory)] [object] $CandidateList,
        [Collections.Generic.Dictionary[string, string]] $RemovalEntries = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal),
        [Collections.Generic.Dictionary[string, string]] $SkipEntries = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    )
    $problems = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    if ($BaselineLists.Count -eq 0) { $problems.Add('No baseline was given; a missing baseline fails, it is never taken as empty.') }
    foreach ($list in @($BaselineLists) + @($CandidateList)) { foreach ($p in $list.Problems) { $problems.Add($p) } }
    if ($problems.Count -gt 0) { return [pscustomobject]@{ Problems = $problems.ToArray(); Notes = $notes.ToArray() } }

    foreach ($list in $BaselineLists) {
        if ($list.Build -cne $CandidateList.Build) { $problems.Add("Build options differ: '$($list.Path)' has '$($list.Build)', '$($CandidateList.Path)' has '$($CandidateList.Build)'.") }
        $failed = @($list.Rows | Where-Object Result -ceq 'FAIL')
        if ($failed.Count -gt 0) { $problems.Add("The baseline '$($list.Path)' is not green: $($failed.Count) FAIL rows, the first $($failed[0].Suite) $($failed[0].Name).") }
    }
    # The union: the largest multiplicity any baseline gives, and OK if any ran it OK.
    $union = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($list in $BaselineLists) {
        $t = Get-RanListTally -Rows $list.Rows
        foreach ($id in $t.Keys) {
            $ran = $t[$id].OK + $t[$id].SKIP
            if (-not $union.ContainsKey($id)) { $union[$id] = [pscustomobject]@{ Ran = 0; OK = 0 } }
            $union[$id].Ran = [Math]::Max($union[$id].Ran, $ran)
            $union[$id].OK = [Math]::Max($union[$id].OK, $t[$id].OK)
        }
    }
    $later = Get-RanListTally -Rows $CandidateList.Rows
    $ids = [string[]] @($union.Keys)
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    foreach ($id in $ids) {
        $label = $id -replace "`t", ' '
        $b = $union[$id]
        $c = if ($later.ContainsKey($id)) { $later[$id] } else { [pscustomobject]@{ OK = 0; SKIP = 0; FAIL = 0 } }
        $present = $c.OK + $c.SKIP
        if ($present -lt $b.Ran) {
            if ($RemovalEntries.ContainsKey($id)) { $notes.Add("LEDGERED-REMOVAL $label ($($b.Ran - $present) of $($b.Ran)): $($RemovalEntries[$id])") }
            else { $problems.Add("DROPPED $label (ran $($b.Ran) in the baseline, $present now)") }
        }
        $turned = [Math]::Min($c.SKIP, [Math]::Max(0, $b.OK - $c.OK))
        if ($turned -gt 0) {
            if ($SkipEntries.ContainsKey($id)) { $notes.Add("APPROVED-SKIP $label`: $($SkipEntries[$id])") }
            else { $problems.Add("TURNED-SKIP $label (OK in the baseline, SKIP now)") }
        }
        if ($c.SKIP - $turned -gt 0) { $notes.Add("CARRIED-SKIP $label (skipped in the baseline too)") }
    }
    foreach ($id in $later.Keys) {
        if ($later[$id].FAIL -gt 0) { $problems.Add("FAILED $($id -replace "`t", ' ') ($($later[$id].FAIL))") }
    }
    $new = @($later.Keys | Where-Object { -not $union.ContainsKey($_) }).Count
    $notes.Add("$($union.Count) baseline identities checked, $new new in the later list.")
    foreach ($id in $RemovalEntries.Keys) {
        if (-not $union.ContainsKey($id) -or ($later.ContainsKey($id) -and $later[$id].OK + $later[$id].SKIP -ge $union[$id].Ran)) { $notes.Add("UNUSED-REMOVAL $($id -replace "`t", ' ')") }
    }
    return [pscustomobject]@{ Problems = $problems.ToArray(); Notes = $notes.ToArray() }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
$ledgerProblems = [Collections.Generic.List[string]]::new()
$removalEntries = Read-RanListLedger -Path $Removals -Kind 'removals' -Problems $ledgerProblems
$skipEntries = Read-RanListLedger -Path $ApprovedSkips -Kind 'approved skips' -Problems $ledgerProblems
$baselineLists = @($Baseline | ForEach-Object { Read-RanList -Path $_ })
$candidateList = Read-RanList -Path $Candidate
$verdict = Compare-RanList -BaselineLists $baselineLists -CandidateList $candidateList -RemovalEntries $removalEntries -SkipEntries $skipEntries
foreach ($note in $verdict.Notes) { Write-Host $note }
$problems = @($ledgerProblems) + @($verdict.Problems)
foreach ($problem in $problems) { [Console]::Error.WriteLine("RAN LIST: $problem") }
if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine("RAN LIST: FAIL ($($problems.Count) problems)")
    exit 1
}
Write-Host 'Ran list compare: PASS'
