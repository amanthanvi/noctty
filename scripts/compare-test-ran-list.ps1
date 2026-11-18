#requires -Version 7.0
<#
.SYNOPSIS
Checks that every test that ran in a baseline ran list runs again in a later
one: as OK, as an approved SKIP, or as a ledgered removal.

.DESCRIPTION
Lists come from scripts/capture-test-ran-list.ps1. A test's identity is its
suite and its fully qualified name. Zig names an unnamed `test { ... }` block
by its position in its container (`<container>.test_<n>`, numbered from 0 in
each container, file or struct), so a block added above it renumbers it: the
compare counts a container's unnamed blocks instead (`<container>.test_#`,
their number the multiplicity), which still fails a dropped one. Only a real
unnamed block is counted that way: a named test called "test_0" is
`<container>.test.test_0` and keeps its own identity.

Several -Baseline lists are united, as PLAN.md §3.2 asks of a forward merge
(the `main` commit it merges and the phase branch before it) and of the 1B
branch's carried baseline (the last green phase-side list with the list of
each `main` parent merged meanwhile): an identity counts with the largest
multiplicity any baseline gives it. Every list must exist, parse, hold rows
and be green: each suite exited 0 with no FAIL row, logged error, leak or
panic, so a `-TestLog` import whose exit code was not given is refused. Every
list must record a real build (options and compiler, not `unknown`), and all
must agree on it and on their environment facts (`# env:` lines), so a test
that runs only in some environments or with some options cannot read as
dropped or as carried. A filtered build (`-Dtest-filter`) is refused as a
baseline unless -AllowFilteredBaseline is given (for a control).

The later list fails the check when
  * an identity has fewer occurrences than the baselines give it (DROPPED),
    unless -Removals ledgers them;
  * it has a SKIP that no -ApprovedSkips entry approves (UNAPPROVED-SKIP), in
    the baseline or not: PLAN.md §3.2 accepts "OK or an approved SKIP";
  * an approved SKIP's entry names environment facts the list does not have
    (SKIP-ENVIRONMENT);
  * it has any FAIL row.
Tests only the later list has are counted as new; a new test that skips still
needs its approval. A new test that never runs cannot be seen here (see
RAN-LIST-01 in docs/agents/log/test-harnesses.md for 1B.5).

-Removals files hold `<suite><TAB><qualified name><TAB><reason>` lines, and
-ApprovedSkips files `<suite><TAB><qualified name><TAB><requires><TAB><reason>`,
where requires is `-` or `fact=value[;fact=value]` over the capture's
environment facts; `#` starts a comment line. Each entry covers one test, an
unnamed block's entry one block of its container. Every entry needs a reason:
a removal names the residual- or dropped-delta-ledger entry it rests on
(PLAN.md §3.2), a skip why the test skips. Several files of each are merged.

  pwsh scripts/compare-test-ran-list.ps1 -Baseline main-plain.tsv -Candidate branch-plain.tsv `
      -ApprovedSkips test/windows/ran-list-approved-skips.tsv
#>
[CmdletBinding()]
param(
    [string[]] $Baseline = @(),
    [string] $Candidate,
    [string[]] $Removals = @(),
    [string[]] $ApprovedSkips = @(),
    [switch] $AllowFilteredBaseline,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

$script:RanListFormat = '# noctty test ran list v2'

function Resolve-RanListPath {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# The identity the compare keys on. A real unnamed block, `<container>.test_<n>`
# where no segment of the container is `test` or `decltest` (those mark a named
# test or a decltest), loses its number.
function Get-RanListIdentity {
    param([Parameter(Mandatory)] [string] $Suite, [Parameter(Mandatory)] [string] $Name)
    $m = [regex]::Match($Name, '^(?<c>[^\s.]+(?:\.[^\s.]+)*)\.test_\d+$')
    if ($m.Success -and -not (@($m.Groups['c'].Value -split '\.') | Where-Object { $_ -ceq 'test' -or $_ -ceq 'decltest' })) {
        return "$Suite`t$($m.Groups['c'].Value).test_#"
    }
    return "$Suite`t$Name"
}

# Reads a list. A file that is missing, empty, not a v2 list, cut short or
# inconsistent with its end line has problems.
function Read-RanList {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    $full = Resolve-RanListPath $Path
    $problems = [Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{ Path = $full; Build = [ordered]@{}; Environment = [ordered]@{}; Suites = @(); Rows = @(); Problems = $problems }
    if ([string]::IsNullOrWhiteSpace($full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $problems.Add("The ran list '$Path' does not exist.")
        return $result
    }
    $lines = [System.IO.File]::ReadAllLines($full, [System.Text.UTF8Encoding]::new($false))
    if ($lines.Count -eq 0 -or $lines[0] -cne $script:RanListFormat) {
        $problems.Add("'$full' is not a ran list (its first line is not '$($script:RanListFormat)').")
        return $result
    }
    $rows = [Collections.Generic.List[object]]::new()
    $suites = [Collections.Generic.List[object]]::new()
    $end = $null
    $total = 0
    $revision = $null
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -ne $end) { if ($line.Length -gt 0) { $problems.Add("'$full' has text after its end line.") }; continue }
        if ($line.StartsWith('# end: ')) { $end = $line; continue }
        if ($line.StartsWith('# revision: ')) { $revision = $line.Substring(12); continue }
        if ($line.StartsWith('# build: ')) {
            foreach ($pair in ($line.Substring(9) -split "`t")) { if ($pair -match '^([^=]+)=(.*)$') { $result.Build[$Matches[1]] = $Matches[2] } }
            continue
        }
        if ($line -match '^# env: ([^=]+)=(.*)$') { $result.Environment[$Matches[1]] = $Matches[2]; continue }
        if ($line -match '^# suite: (\S+) tests=(\d+) ok=(\d+) skip=(\d+) fail=(\d+) exit=(\S+) errors-logged=(\d+) leaked=(\d+) panics=(\d+)$') {
            $suites.Add([pscustomobject]@{ Name = $Matches[1]; Fail = [int]$Matches[5]; Exit = $Matches[6]; ErrorsLogged = [int]$Matches[7]; Leaked = [int]$Matches[8]; Panics = [int]$Matches[9] })
            continue
        }
        if ($line.StartsWith('#')) { continue }
        $fields = $line -split "`t", 4
        if ($fields.Count -ne 4 -or $fields[1] -cnotin @('OK', 'SKIP', 'FAIL') -or $fields[2] -notmatch '^[1-9]\d*$' -or $fields[3].Length -eq 0) {
            $problems.Add("'$full' line $($i + 1) is not '<suite><TAB><OK|SKIP|FAIL><TAB><count><TAB><name>'.")
            continue
        }
        $rows.Add([pscustomobject]@{ Suite = $fields[0]; Result = $fields[1]; Count = [int]$fields[2]; Name = $fields[3] })
        $total += [int]$fields[2]
    }
    if ($null -eq $end) { $problems.Add("'$full' has no '# end:' line, so it was cut short.") }
    elseif ($end -cne "# end: rows=$($rows.Count) tests=$total") { $problems.Add("'$full' does not match its end line ($end; read rows=$($rows.Count) tests=$total).") }
    if ([string]::IsNullOrWhiteSpace($revision) -or $revision -ieq 'unknown') { $problems.Add("'$full' names no revision.") }
    foreach ($key in 'source', 'options', 'zig') {
        if (-not $result.Build.Contains($key) -or [string]::IsNullOrWhiteSpace($result.Build[$key]) -or $result.Build[$key] -ieq 'unknown') {
            $problems.Add("'$full' records no real build $key; a list needs the options and the compiler that built it.")
        }
    }
    if ($rows.Count -eq 0) { $problems.Add("'$full' holds no tests; a baseline is never taken as empty.") }
    if ($suites.Count -eq 0) { $problems.Add("'$full' has no suite line.") }
    foreach ($s in $suites) {
        $green = $s.Exit -ceq '0' -and $s.Fail -eq 0 -and $s.ErrorsLogged -eq 0 -and $s.Leaked -eq 0 -and $s.Panics -eq 0
        if (-not $green) { $problems.Add("'$full' suite $($s.Name) is not green (exit $($s.Exit), $($s.Fail) failed, $($s.ErrorsLogged) errors logged, $($s.Leaked) leaked, $($s.Panics) panics).") }
    }
    $failed = @($rows | Where-Object Result -ceq 'FAIL')
    if ($failed.Count -gt 0) { $problems.Add("'$full' has $($failed.Count) FAIL rows, the first $($failed[0].Suite) $($failed[0].Name).") }
    $result.Rows = $rows.ToArray()
    $result.Suites = $suites.ToArray()
    return $result
}

# Reads ledger files into identity -> list of entries (Reason, Requires). An
# unnamed block's identity collects one entry per block.
function Read-RanListLedger {
    param(
        [AllowEmptyCollection()] [string[]] $Paths = @(),
        [Parameter(Mandatory)] [ValidateSet('removals', 'approved skips')] [string] $Kind,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [Collections.Generic.List[string]] $Problems
    )
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $exact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $width = if ($Kind -eq 'removals') { 3 } else { 4 }
    foreach ($path in @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $full = Resolve-RanListPath $path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $Problems.Add("The $Kind file '$full' does not exist."); continue }
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines($full, [System.Text.UTF8Encoding]::new($false))) {
            $n++
            if ($line.Trim().Length -eq 0 -or $line.StartsWith('#')) { continue }
            $fields = $line -split "`t"
            $ok = $fields.Count -eq $width -and $fields[0].Length -gt 0 -and $fields[1].Length -gt 0 -and $fields[$width - 1].Trim().Length -gt 0
            $requires = @()
            if ($ok -and $width -eq 4 -and $fields[2] -cne '-') {
                $requires = @($fields[2] -split ';' | ForEach-Object { $_.Trim() })
                if (@($requires | Where-Object { $_ -notmatch '^[^=]+=.+$' }).Count -gt 0) { $ok = $false }
            }
            if (-not $ok) {
                $shape = if ($width -eq 3) { '<suite><TAB><qualified name><TAB><reason>' } else { "<suite><TAB><qualified name><TAB><requires or -><TAB><reason>" }
                $Problems.Add("$Kind file '$full' line $n is not '$shape' with a reason.")
                continue
            }
            if (-not $exact.Add("$($fields[0])`t$($fields[1])")) { $Problems.Add("$Kind lists '$($fields[0]) $($fields[1])' twice."); continue }
            $id = Get-RanListIdentity -Suite $fields[0] -Name $fields[1]
            if (-not $entries.ContainsKey($id)) { $entries[$id] = [Collections.Generic.List[object]]::new() }
            $entries[$id].Add([pscustomobject]@{ Reason = $fields[$width - 1]; Requires = $requires })
        }
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

function Format-RanListMap {
    param([System.Collections.IDictionary] $Map)
    return (@($Map.Keys | Sort-Object | ForEach-Object { "$_=$($Map[$_])" }) -join ', ')
}

# The verdict: Problems (each one fails the check) and Notes (reported only).
function Compare-RanList {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $BaselineLists,
        [Parameter(Mandatory)] [object] $CandidateList,
        [Collections.Generic.Dictionary[string, object]] $RemovalEntries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal),
        [Collections.Generic.Dictionary[string, object]] $SkipEntries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal),
        [switch] $AllowFilteredBaseline
    )
    $problems = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    if ($BaselineLists.Count -eq 0) { $problems.Add('No baseline was given; a missing baseline fails, it is never taken as empty.') }
    foreach ($list in @($BaselineLists) + @($CandidateList)) { foreach ($p in $list.Problems) { $problems.Add($p) } }
    if ($problems.Count -gt 0) { return [pscustomobject]@{ Problems = $problems.ToArray(); Notes = $notes.ToArray() } }

    $buildKeys = @('options', 'mode', 'target', 'zig', 'filtered')
    foreach ($list in $BaselineLists) {
        if ($list.Build['filtered'] -ceq 'true' -and -not $AllowFilteredBaseline) { $problems.Add("'$($list.Path)' is a filtered build (-Dtest-filter), so it is no baseline.") }
        foreach ($key in $buildKeys) {
            if ("$($list.Build[$key])" -cne "$($CandidateList.Build[$key])") {
                $problems.Add("BUILD-DIFFERS $key`: '$($list.Path)' has '$($list.Build[$key])', '$($CandidateList.Path)' has '$($CandidateList.Build[$key])'.")
            }
        }
        $facts = @(@($list.Environment.Keys) + @($CandidateList.Environment.Keys) | Sort-Object -Unique)
        foreach ($key in $facts) {
            if ("$($list.Environment[$key])" -cne "$($CandidateList.Environment[$key])") {
                $problems.Add("ENV-DIFFERS $key`: '$($list.Path)' has '$($list.Environment[$key])', '$($CandidateList.Path)' has '$($CandidateList.Environment[$key])'.")
            }
        }
    }
    # The union: the largest multiplicity any baseline gives.
    $union = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($list in $BaselineLists) {
        $t = Get-RanListTally -Rows $list.Rows
        foreach ($id in $t.Keys) {
            $ran = $t[$id].OK + $t[$id].SKIP
            $union[$id] = [Math]::Max($ran, $(if ($union.ContainsKey($id)) { $union[$id] } else { 0 }))
        }
    }
    $later = Get-RanListTally -Rows $CandidateList.Rows
    $ids = [string[]] @($union.Keys)
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    foreach ($id in $ids) {
        $label = $id -replace "`t", ' '
        $c = if ($later.ContainsKey($id)) { $later[$id] } else { [pscustomobject]@{ OK = 0; SKIP = 0; FAIL = 0 } }
        $missing = $union[$id] - ($c.OK + $c.SKIP)
        if ($missing -le 0) { continue }
        $ledgered = if ($RemovalEntries.ContainsKey($id)) { $RemovalEntries[$id].Count } else { 0 }
        if ($ledgered -ge $missing) { $notes.Add("LEDGERED-REMOVAL $label ($missing of $($union[$id])): $($RemovalEntries[$id][0].Reason)") }
        else { $problems.Add("DROPPED $label (ran $($union[$id]) in the baseline, $($c.OK + $c.SKIP) now$(if ($ledgered) { ", $ledgered ledgered" }))") }
    }
    $laterIds = [string[]] @($later.Keys)
    [Array]::Sort($laterIds, [StringComparer]::Ordinal)
    foreach ($id in $laterIds) {
        $label = $id -replace "`t", ' '
        if ($later[$id].FAIL -gt 0) { $problems.Add("FAILED $label ($($later[$id].FAIL))") }
        $skips = $later[$id].SKIP
        if ($skips -eq 0) { continue }
        $approvals = if ($SkipEntries.ContainsKey($id)) { @($SkipEntries[$id]) } else { @() }
        if ($approvals.Count -lt $skips) {
            $problems.Add("UNAPPROVED-SKIP $label ($skips skipped, $($approvals.Count) approved)")
            continue
        }
        foreach ($entry in $approvals) {
            foreach ($req in $entry.Requires) {
                $key, $value = $req -split '=', 2
                if ("$($CandidateList.Environment[$key])" -cne $value) {
                    $problems.Add("SKIP-ENVIRONMENT $label is approved only with $key=$value; the list has '$($CandidateList.Environment[$key])'.")
                }
            }
        }
        $notes.Add("APPROVED-SKIP $label`: $($approvals[0].Reason)")
    }
    $new = @($later.Keys | Where-Object { -not $union.ContainsKey($_) }).Count
    $notes.Add("$($union.Count) baseline identities checked, $new new in the later list.")
    foreach ($id in $RemovalEntries.Keys) {
        if (-not $union.ContainsKey($id)) { $notes.Add("UNUSED-REMOVAL $($id -replace "`t", ' ') (no baseline has it)") }
    }
    # An approval for a suite this list does not hold (the approvals file covers
    # every suite) is not stale.
    $laterSuites = @($CandidateList.Rows | ForEach-Object Suite | Sort-Object -Unique)
    foreach ($id in $SkipEntries.Keys) {
        if (($id -split "`t", 2)[0] -cnotin $laterSuites) { continue }
        if (-not $later.ContainsKey($id) -or $later[$id].SKIP -eq 0) { $notes.Add("UNUSED-SKIP-APPROVAL $($id -replace "`t", ' ')") }
    }
    return [pscustomobject]@{ Problems = $problems.ToArray(); Notes = $notes.ToArray() }
}

if ($LibraryOnly) { return }

$ErrorActionPreference = 'Stop'
$ledgerProblems = [Collections.Generic.List[string]]::new()
$removalEntries = Read-RanListLedger -Paths $Removals -Kind 'removals' -Problems $ledgerProblems
$skipEntries = Read-RanListLedger -Paths $ApprovedSkips -Kind 'approved skips' -Problems $ledgerProblems
$baselineLists = @($Baseline | ForEach-Object { Read-RanList -Path $_ })
$candidateList = Read-RanList -Path $Candidate
$verdict = Compare-RanList -BaselineLists $baselineLists -CandidateList $candidateList -RemovalEntries $removalEntries -SkipEntries $skipEntries -AllowFilteredBaseline:$AllowFilteredBaseline
foreach ($note in $verdict.Notes) { Write-Host $note }
$problems = @($ledgerProblems) + @($verdict.Problems)
foreach ($problem in $problems) { [Console]::Error.WriteLine("RAN LIST: $problem") }
if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine("RAN LIST: FAIL ($($problems.Count) problems)")
    exit 1
}
Write-Host 'Ran list compare: PASS'
exit 0
