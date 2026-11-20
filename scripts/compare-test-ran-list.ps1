#requires -Version 7.0
<#
.SYNOPSIS
Checks that every test that ran in a baseline ran list runs again in a later
one: as OK, as an approved SKIP, or as a ledgered removal.

.DESCRIPTION
Lists come from scripts/capture-test-ran-list.ps1. A test's identity is its
suite and its fully qualified name, as the list writes it (`\`, tab, CR, LF,
other control characters and bytes that are not UTF-8 escaped, so two names
are one identity only when their bytes are equal). Suites are told apart
ordinally, and a list whose suites differ only by case is refused. Zig names
an unnamed `test { ... }` block by its position in its container
(`<container>.test_<n>`, numbered from 0 in each container, file or struct),
so a block added above it renumbers it: the compare counts a
container's unnamed blocks instead (`<container>.test_#`, their number the
multiplicity), which still fails a dropped one. Only a real unnamed block is
counted that way: a named test called "test_0" is `<container>.test.test_0`
and keeps its own identity.

Several -Baseline lists are united, as PLAN.md section 3.2 asks of a forward
merge (the `main` commit it merges and the phase branch before it) and of the
1B branch's carried baseline (the last green phase-side list with the list of
each `main` parent merged meanwhile): an identity counts with the largest
multiplicity any baseline gives it.

Every list must exist, parse, hold rows, carry one green suite record for each
suite its rows name (exit 0, no FAIL row, logged error or leak, counts that
match the rows; `panics=` counts panic-shaped lines a test may print and is not
part of green), record a real build (options, mode and compiler, not
`unknown`), and come from a clean checkout (a `dirty=true` build is refused
unless -AllowDirty). All must agree on the build and on their environment facts
(`# env:` lines, keys and values both compared ordinally, so a key spelled with
another case or a control character is a key of its own that the other list
lacks), so a test that runs only in some environments or with some options
cannot read as dropped or as carried. The build's `source` is compared by class:
a list the capture `built` against one of an executable it did not build, so a
`declared` executable and an `imported` run are one class. Numbers in a list
are ASCII digits. A filtered build (`-Dtest-filter`)
is refused as a baseline unless -AllowFilteredBaseline is given (for a control).

The compiler must match too, except across a crossing the caller declares:
`-CompilerCrossing 0.15.2=0.17.1` lets baselines built by 0.15.2 be compared
with a later list built by 0.17.1: every 1B comparison that crosses compilers
(PLAN.md section 3.2: the carried baseline at 1B.5's first green build, each 1B
forward merge's `main` parent, and 1B's landing merge on `main`). Across it the
mode is compared by meaning (Debug = debug, ReleaseSafe = safe, ReleaseFast =
fast, ReleaseSmall = small: 0.17.1 renamed the optimize modes), and every other
key stays as strict as without it (`source` by class, the rest exactly), options
included: take a ReleaseSafe list with
`-Dtest-optimize=ReleaseSafe` on both compilers (0.17.1 accepts it, and builds
mode `safe`). The verdict names each crossing it used.

The later list fails the check when
  * an identity has fewer occurrences than the baselines give it (DROPPED),
    unless -Removals ledgers them;
  * it has a SKIP that no applicable -ApprovedSkips entry approves
    (UNAPPROVED-SKIP), in the baseline or not: section 3.2 accepts "OK or an
    approved SKIP";
  * an approval exists for a SKIP but its conditions do not hold for this list
    (SKIP-ENVIRONMENT); a fact or build value the list records as `unknown`
    meets no condition, and no condition may name `unknown`;
  * it has any FAIL row.
Tests only the later list has are counted as new; a new test that skips still
needs its approval. A new test that never runs cannot be seen here (see
RAN-LIST-01 in docs/agents/log/test-harnesses.md for 1B.5).

-Removals files hold `<suite><TAB><qualified name><TAB><reason>` lines, and
-ApprovedSkips files `<suite><TAB><qualified name><TAB><requires><TAB><reason>`,
where requires is `-` or `cond[;cond]`, each cond `<fact>=<value>` over the
capture's environment facts or `build:<key>=<value>` over the list's build
(`build:options=-Dcustom-shaders=true` names CI's list, `build:mode=ReleaseSafe`
1A's ReleaseSafe list; a mode matches by meaning). `#` starts a comment line.
Each entry covers one test, an unnamed block's entry one block of its
container. Every entry needs a reason: a removal names the residual- or
dropped-delta-ledger entry it rests on (section 3.2), a skip why the test
skips. Several files of each are merged.

  pwsh scripts/compare-test-ran-list.ps1 -Baseline main-plain.tsv -Candidate branch-plain.tsv `
      -ApprovedSkips test/windows/ran-list-approved-skips.tsv
#>
[CmdletBinding()]
param(
    [string[]] $Baseline = @(),
    [string] $Candidate,
    [string[]] $Removals = @(),
    [string[]] $ApprovedSkips = @(),
    # `<from>=<to>`: baselines built by <from> may be compared with a later list built by <to>.
    [string] $CompilerCrossing,
    [switch] $AllowFilteredBaseline,
    # Accept lists of a checkout with tracked changes (a control).
    [switch] $AllowDirty,
    # Dot-source for the functions only.
    [switch] $LibraryOnly
)

$script:RanListFormat = '# noctty test ran list v4'

function Resolve-RanListPath {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# An optimize mode by its meaning: Zig 0.17.1 renamed Debug, ReleaseSafe,
# ReleaseFast and ReleaseSmall to debug, safe, fast and small.
function Get-RanListModeMeaning {
    param([AllowEmptyString()] [string] $Mode)
    foreach ($pair in @(@('Debug', 'debug'), @('ReleaseSafe', 'safe'), @('ReleaseFast', 'fast'), @('ReleaseSmall', 'small'))) {
        if ((Test-RanListSame $Mode $pair[0]) -or (Test-RanListSame $Mode $pair[1])) { return $pair[1] }
    }
    return $Mode
}

# Whether two values read from files are the same text. PowerShell 7.6's -ceq,
# -eq, -cin and switch ignore control characters ("<ESC>A" -ceq "A" is true),
# so values are compared ordinally.
function Test-RanListSame {
    param([AllowNull()] [AllowEmptyString()] [string] $A, [AllowNull()] [AllowEmptyString()] [string] $B)
    return [string]::Equals($A, $B, [StringComparison]::Ordinal)
}

# The identity the compare keys on. A real unnamed block, `<container>.test_<n>`
# where no segment of the container is `test` or `decltest` (those mark a named
# test or a decltest), loses its number.
function Get-RanListIdentity {
    param([Parameter(Mandatory)] [string] $Suite, [Parameter(Mandatory)] [string] $Name)
    $m = [regex]::Match($Name, '^(?<c>[^\s.]+(?:\.[^\s.]+)*)\.test_[0-9]+$')
    if ($m.Success -and -not (@($m.Groups['c'].Value -split '\.') | Where-Object { (Test-RanListSame $_ 'test') -or (Test-RanListSame $_ 'decltest') })) {
        return "$Suite`t$($m.Groups['c'].Value).test_#"
    }
    return "$Suite`t$Name"
}

# Reads a list. A file that is missing, empty, not a v4 list, cut short,
# inconsistent with its end line, or without a green suite record for each of
# its suites has problems.
function Read-RanList {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    $full = Resolve-RanListPath $Path
    $problems = [Collections.Generic.List[string]]::new()
    # Ordinal maps: PowerShell's [ordered] folds the case of a key.
    $result = [pscustomobject]@{
        Path = $full; Suites = @(); Rows = @(); Problems = $problems
        Build = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        Environment = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    }
    if ([string]::IsNullOrWhiteSpace($full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $problems.Add("The ran list '$Path' does not exist.")
        return $result
    }
    $lines = [System.IO.File]::ReadAllLines($full, [System.Text.UTF8Encoding]::new($false))
    if ($lines.Count -eq 0 -or -not (Test-RanListSame $lines[0] $script:RanListFormat)) {
        $problems.Add("'$full' is not a ran list (its first line is not '$($script:RanListFormat)').")
        return $result
    }
    $rows = [Collections.Generic.List[object]]::new()
    $suites = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $end = $null
    $total = 0
    $revision = $null
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($null -ne $end) { if ($line.Length -gt 0) { $problems.Add("'$full' has text after its end line.") }; continue }
        if ($line.StartsWith('# end: ', [StringComparison]::Ordinal)) { $end = $line; continue }
        if ($line.StartsWith('# revision: ', [StringComparison]::Ordinal)) { $revision = $line.Substring(12); continue }
        if ($line.StartsWith('# build: ', [StringComparison]::Ordinal)) {
            foreach ($pair in ($line.Substring(9) -split "`t")) { if ($pair -cmatch '^([^=]+)=(.*)$') { $result.Build[$Matches[1]] = $Matches[2] } }
            continue
        }
        if ($line -cmatch '^# env: ([^=]+)=(.*)$') { $result.Environment[$Matches[1]] = $Matches[2]; continue }
        if ($line.StartsWith('# suite: ', [StringComparison]::Ordinal)) {
            # [0-9], not \d, which also matches every other script's digits.
            if ($line -cnotmatch '^# suite: ([A-Za-z0-9._-]+) tests=([0-9]+) ok=([0-9]+) skip=([0-9]+) fail=([0-9]+) exit=(-?[0-9]+) errors-logged=([0-9]+) leaked=([0-9]+) panics=([0-9]+)$') {
                $problems.Add("'$full' line $($i + 1) is not a suite record.")
                continue
            }
            if ($suites.ContainsKey($Matches[1])) { $problems.Add("'$full' has two suite records for $($Matches[1])."); continue }
            $suites[$Matches[1]] = [pscustomobject]@{
                Name = $Matches[1]; Tests = [int]$Matches[2]; Ok = [int]$Matches[3]; Skip = [int]$Matches[4]; Fail = [int]$Matches[5]
                Exit = $Matches[6]; ErrorsLogged = [int]$Matches[7]; Leaked = [int]$Matches[8]; Panics = [int]$Matches[9]
            }
            continue
        }
        if ($line.StartsWith('#', [StringComparison]::Ordinal)) { continue }
        $fields = $line -split "`t", 4
        if ($fields.Count -ne 4 -or $fields[0] -cnotmatch '\A[A-Za-z0-9._-]+\z' -or $fields[1] -cnotmatch '^(OK|SKIP|FAIL)$' -or $fields[2] -cnotmatch '^[1-9][0-9]*$' -or $fields[3].Length -eq 0) {
            $problems.Add("'$full' line $($i + 1) is not '<suite><TAB><OK|SKIP|FAIL><TAB><count><TAB><name>'.")
            continue
        }
        $rows.Add([pscustomobject]@{ Suite = $fields[0]; Result = $fields[1]; Count = [int]$fields[2]; Name = $fields[3] })
        $total += [int]$fields[2]
    }
    if ($null -eq $end) { $problems.Add("'$full' has no '# end:' line, so it was cut short.") }
    elseif (-not (Test-RanListSame $end "# end: rows=$($rows.Count) tests=$total")) { $problems.Add("'$full' does not match its end line ($end; read rows=$($rows.Count) tests=$total).") }
    if ([string]::IsNullOrWhiteSpace($revision) -or $revision -ieq 'unknown') { $problems.Add("'$full' names no revision.") }
    foreach ($key in 'source', 'options', 'mode', 'zig') {
        if (-not $result.Build.Contains($key) -or [string]::IsNullOrWhiteSpace($result.Build[$key]) -or $result.Build[$key] -ieq 'unknown') {
            $problems.Add("'$full' records no real build $key; a list needs the options, the mode and the compiler that built it.")
        }
    }
    # Suite labels are compared ordinally: two that differ only by case would be
    # one suite to a case-blind reader and two to this one.
    $labels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    # get_Keys() and get_Values(): a suite or fact named Keys, Values or Count
    # shadows that member of a dictionary.
    foreach ($label in @(@($rows | ForEach-Object Suite) + @($suites.get_Keys()))) { [void] $labels.Add($label) }
    $folded = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($label in $labels) {
        if ($folded.ContainsKey($label)) { $problems.Add("'$full' has suites $($folded[$label]) and $label, which differ only by case.") }
        else { $folded[$label] = $label }
    }
    if ($rows.Count -eq 0) { $problems.Add("'$full' holds no tests; a baseline is never taken as empty.") }
    # One green suite record for each suite the rows name, whose counts are the rows'.
    $rowSuites = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) { [void] $rowSuites.Add($row.Suite) }
    foreach ($name in $rowSuites) {
        if (-not $suites.ContainsKey($name)) { $problems.Add("'$full' has rows for suite $name but no suite record, so its run cannot be shown green."); continue }
        $s = $suites[$name]
        $mine = @($rows | Where-Object Suite -ceq $name)
        $sum = { param($r) (@($mine | Where-Object Result -ceq $r | ForEach-Object Count) | Measure-Object -Sum).Sum }
        $ok = [int](& $sum 'OK'); $skip = [int](& $sum 'SKIP'); $fail = [int](& $sum 'FAIL')
        if ($s.Ok -ne $ok -or $s.Skip -ne $skip -or $s.Fail -ne $fail -or $s.Tests -ne $ok + $skip + $fail) {
            $problems.Add("'$full' suite $name's record (tests=$($s.Tests) ok=$($s.Ok) skip=$($s.Skip) fail=$($s.Fail)) does not match its rows ($ok OK, $skip SKIP, $fail FAIL).")
        }
        $green = (Test-RanListSame $s.Exit '0') -and $s.Fail -eq 0 -and $s.ErrorsLogged -eq 0 -and $s.Leaked -eq 0
        if (-not $green) { $problems.Add("'$full' suite $name is not green (exit $($s.Exit), $($s.Fail) failed, $($s.ErrorsLogged) errors logged, $($s.Leaked) leaked).") }
    }
    foreach ($name in $suites.get_Keys()) { if (-not $rowSuites.Contains($name)) { $problems.Add("'$full' has a suite record for $name but no rows of it.") } }
    $failed = @($rows | Where-Object Result -ceq 'FAIL')
    if ($failed.Count -gt 0) { $problems.Add("'$full' has $($failed.Count) FAIL rows, the first $($failed[0].Suite) $($failed[0].Name).") }
    $result.Rows = $rows.ToArray()
    $result.Suites = @($suites.get_Values())
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
            if ($ok -and $width -eq 4 -and -not (Test-RanListSame $fields[2] '-')) {
                $requires = @($fields[2] -split ';' | ForEach-Object { $_.Trim() })
                # `unknown` is what a list records for a fact it could not
                # measure; no condition may ask for it.
                if (@($requires | Where-Object { $_ -notmatch '^[^=]+=.+$' -or ($_ -split '=', 2)[1].Trim() -ieq 'unknown' }).Count -gt 0) { $ok = $false }
            }
            if (-not $ok) {
                $shape = if ($width -eq 3) { '<suite><TAB><qualified name><TAB><reason>' } else { "<suite><TAB><qualified name><TAB><requires or -><TAB><reason>" }
                $Problems.Add("$Kind file '$full' line $n is not '$shape' with a reason (and no condition on 'unknown').")
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

# The conditions of an approval that do not hold for a list: each as text.
function Get-RanListUnmetConditions {
    param([Parameter(Mandatory)] [object] $Entry, [Parameter(Mandatory)] [object] $List)
    $unmet = @()
    foreach ($req in $Entry.Requires) {
        $key, $value = $req -split '=', 2
        if ($key.StartsWith('build:', [StringComparison]::Ordinal)) {
            $buildKey = $key.Substring(6)
            $have = "$($List.Build[$buildKey])"
            $holds = if (Test-RanListSame $buildKey 'mode') { Test-RanListSame (Get-RanListModeMeaning $have) (Get-RanListModeMeaning $value) } else { Test-RanListSame $have $value }
        }
        else {
            $have = "$($List.Environment[$key])"
            $holds = Test-RanListSame $have $value
        }
        # A value the list could not measure meets no condition, whatever the
        # condition names.
        if ($have -ieq 'unknown') { $holds = $false }
        if (-not $holds) { $unmet += "$key=$value (the list has '$have'$(if ($have -ieq 'unknown') { ', an imported run that recorded no facts' }))" }
    }
    return , $unmet
}

# The verdict: Problems (each one fails the check) and Notes (reported only).
function Compare-RanList {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $BaselineLists,
        [Parameter(Mandatory)] [object] $CandidateList,
        [Collections.Generic.Dictionary[string, object]] $RemovalEntries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal),
        [Collections.Generic.Dictionary[string, object]] $SkipEntries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal),
        [AllowEmptyString()] [string] $CompilerCrossing = '',
        [switch] $AllowFilteredBaseline,
        [switch] $AllowDirty
    )
    $problems = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    if ($BaselineLists.Count -eq 0) { $problems.Add('No baseline was given; a missing baseline fails, it is never taken as empty.') }
    foreach ($list in @($BaselineLists) + @($CandidateList)) { foreach ($p in $list.Problems) { $problems.Add($p) } }
    $crossFrom = $null; $crossTo = $null
    if (-not [string]::IsNullOrWhiteSpace($CompilerCrossing)) {
        if ($CompilerCrossing -notmatch '^([^=\s]+)=([^=\s]+)$' -or (Test-RanListSame $Matches[1] $Matches[2])) { $problems.Add("-CompilerCrossing '$CompilerCrossing' is not '<from>=<to>' with two compilers.") }
        else { $crossFrom = $Matches[1]; $crossTo = $Matches[2] }
    }
    if ($problems.Count -gt 0) { return [pscustomobject]@{ Problems = $problems.ToArray(); Notes = $notes.ToArray() } }

    foreach ($list in @($BaselineLists) + @($CandidateList)) {
        if ((Test-RanListSame $list.Build['dirty'] 'true') -and -not $AllowDirty) { $problems.Add("'$($list.Path)' was built from a checkout with tracked changes (dirty=true), so its tests are not its revision's.") }
    }
    $crossings = 0
    foreach ($list in $BaselineLists) {
        if ((Test-RanListSame $list.Build['filtered'] 'true') -and -not $AllowFilteredBaseline) { $problems.Add("'$($list.Path)' is a filtered build (-Dtest-filter), so it is no baseline.") }
        $crossed = $false
        if (-not (Test-RanListSame $list.Build['zig'] $CandidateList.Build['zig'])) {
            if ($null -ne $crossFrom -and (Test-RanListSame $list.Build['zig'] $crossFrom) -and (Test-RanListSame $CandidateList.Build['zig'] $crossTo)) { $crossed = $true; $crossings++ }
            else {
                $hint = if ($null -eq $crossFrom) { ' (declare -CompilerCrossing <from>=<to> for a planned compiler change)' } else { " (the declared crossing is $crossFrom=$crossTo)" }
                $problems.Add("BUILD-DIFFERS zig: '$($list.Path)' has '$($list.Build['zig'])', '$($CandidateList.Path)' has '$($CandidateList.Build['zig'])'$hint.")
            }
        }
        foreach ($key in 'source', 'options', 'mode', 'target', 'filtered') {
            $a = "$($list.Build[$key])"; $b = "$($CandidateList.Build[$key])"
            if (Test-RanListSame $key 'source') {
                # By class: a built list against a declared or imported one, which are one class.
                $a = $(if (Test-RanListSame $a 'built') { 'built' } else { 'not built' }); $b = $(if (Test-RanListSame $b 'built') { 'built' } else { 'not built' })
            }
            $same = if ((Test-RanListSame $key 'mode') -and $crossed) { Test-RanListSame (Get-RanListModeMeaning $a) (Get-RanListModeMeaning $b) } else { Test-RanListSame $a $b }
            if (-not $same) { $problems.Add("BUILD-DIFFERS $key`: '$($list.Path)' has '$($list.Build[$key])', '$($CandidateList.Path)' has '$($CandidateList.Build[$key])'.") }
        }
        # Both key sets, ordinally (Sort-Object -Unique folds a control character away).
        $facts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($k in @($list.Environment.get_Keys()) + @($CandidateList.Environment.get_Keys())) { [void] $facts.Add($k) }
        foreach ($key in $facts) {
            # A key only one list holds differs, even when the other's value is
            # empty: both read as '' through a [string] parameter.
            if ($list.Environment.Contains($key) -ne $CandidateList.Environment.Contains($key) -or -not (Test-RanListSame $list.Environment[$key] $CandidateList.Environment[$key])) {
                $a = if ($list.Environment.Contains($key)) { "'$($list.Environment[$key])'" } else { 'no such fact' }
                $b = if ($CandidateList.Environment.Contains($key)) { "'$($CandidateList.Environment[$key])'" } else { 'no such fact' }
                $problems.Add("ENV-DIFFERS $key`: '$($list.Path)' has $a, '$($CandidateList.Path)' has $b.")
            }
        }
    }
    if ($crossings -gt 0) { $notes.Add("COMPILER-CROSSING $crossFrom -> ${crossTo}: $crossings baseline(s) built by $crossFrom, compared with a list built by $crossTo (mode by meaning).") }
    elseif ($null -ne $crossFrom) { $notes.Add("UNUSED-CROSSING $crossFrom -> ${crossTo}: no baseline needed it.") }

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
        $all = if ($SkipEntries.ContainsKey($id)) { @($SkipEntries[$id]) } else { @() }
        if ($all.Count -eq 0) { $problems.Add("UNAPPROVED-SKIP $label ($skips skipped, 0 approved)"); continue }
        # Only the approvals whose conditions hold for this list count.
        $applicable = @($all | Where-Object { (Get-RanListUnmetConditions -Entry $_ -List $CandidateList).Count -eq 0 })
        if ($applicable.Count -ge $skips) { $notes.Add("APPROVED-SKIP $label`: $($applicable[0].Reason)"); continue }
        $why = @($all | Where-Object { $_ -notin $applicable } | ForEach-Object { (Get-RanListUnmetConditions -Entry $_ -List $CandidateList) -join '; ' }) -join ' | '
        $problems.Add("SKIP-ENVIRONMENT $label ($skips skipped, $($applicable.Count) of $($all.Count) approvals apply): needs $why.")
    }
    $new = @($later.Keys | Where-Object { -not $union.ContainsKey($_) }).Count
    $notes.Add("$($union.Count) baseline identities checked, $new new in the later list.")
    foreach ($id in $RemovalEntries.Keys) {
        if (-not $union.ContainsKey($id)) { $notes.Add("UNUSED-REMOVAL $($id -replace "`t", ' ') (no baseline has it)") }
    }
    # An approval for a suite this list does not hold (the approvals file covers
    # every suite) is not stale.
    $laterSuites = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $CandidateList.Rows) { [void] $laterSuites.Add($row.Suite) }
    foreach ($id in $SkipEntries.Keys) {
        if (-not $laterSuites.Contains(($id -split "`t", 2)[0])) { continue }
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
$verdict = Compare-RanList -BaselineLists $baselineLists -CandidateList $candidateList -RemovalEntries $removalEntries -SkipEntries $skipEntries -CompilerCrossing $CompilerCrossing -AllowFilteredBaseline:$AllowFilteredBaseline -AllowDirty:$AllowDirty
foreach ($note in $verdict.Notes) { Write-Host $note }
$problems = @($ledgerProblems) + @($verdict.Problems)
foreach ($problem in $problems) { [Console]::Error.WriteLine("RAN LIST: $problem") }
if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine("RAN LIST: FAIL ($($problems.Count) problems)")
    exit 1
}
Write-Host 'Ran list compare: PASS'
exit 0
