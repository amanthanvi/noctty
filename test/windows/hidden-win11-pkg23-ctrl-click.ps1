#requires -Version 7.0
<#
.SYNOPSIS
PKG-23 on a private desktop: Ctrl+click terminal row 0 while cmd streams numbered URLs with
scrollback-limit = 0, and require every click to open its whole URL.

.DESCRIPTION
The regression the 2026-10-11 PKG-23 entry in docs/agents/log/terminal-core.md measured by hand:
a left release over a link resolves and copies the link under the renderer state mutex and opens
the copy after the unlock (`linkAtLocked`, `processLinks` in src/Surface.zig; the 2026-11-20
LEFT-RELEASE-LOCK entry). Before the fix, main opened 94 of 300 clicks and 73 of those URLs were
torn; with it, 300 of 300 opened, all whole.

Supply a clean checkout with a completed Debug measurement build as -MeasureRepo
(Invoke-InteractiveWin11MeasureBuild) and a new run directory as -Run. The outer half admits only
that receipt-bound Debug build, then runs this script again as its driver on a new private desktop
(hidden-win11-local-lib.ps1), with LOCALAPPDATA and APPDATA redirected into the run, against a fresh
portable copy without noctty.ico, and checks the real startup ledger, PowerShell history, clipboard
sequence number and jump-list folder afterwards.

Every open goes to the Debug-only trace seam: with NOCTTY_WIN32_OPEN_URL_TRACE_FILE set, the
Win32 opener (`dispatchOpenTarget` in src/apprt/win32/app.zig) writes the URL to that file
(`recordOpenUrlForTest` in src/apprt/win32.zig, which truncates it, so the file holds one open)
and returns before ShellExecuteW. Before anything starts, the outer half checks that seam in the
source the measurement build was made from (Get-Pkg23SeamProblems over the receipt-checked
extraction, not this checkout). Every URL names the reserved .invalid host, so even an open that
reached the shell would load nothing. Before any streaming, ONE DRY CLICK on a still screen must
prove the seam: the build is Debug (its own +version) and the click writes exactly the expected
URL, which that source returns after, before the shell. The driver's job also gains no process
(while the same counter saw the copy and its shell start); that is supporting evidence only, since
an open can be handed to a broker outside the job. If the proof fails, the run stops there
(exit 4) and nothing more is clicked; a copy that dies or stops answering at that first release is
a product failure (exit 1), and nothing more is clicked either.

Then cmd prints https://pkg23.invalid/<eight digits>/<the same digits> forever, and the driver posts -Clicks Ctrl+left
clicks (WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP with MK_CONTROL; no key message) on row 0,
in column 0, each after a Ctrl move to a cell with no link, so every click refreshes the link
under the pointer (`mouseRefreshLinks`) and, with click-repeat-interval = 1, counts as a single
click. Column 0 is where the 2026-10-11 probe clicked; a pass there does not cover a click
inside the link, which opened nothing at column 3 on stone at 5c7a99a13 and opened on main at
358ce0f6a (test-harnesses.md, PKG23-HARNESS-01 trap (3)). After each click
it waits for the record, copies its exact bytes to pkg23\records\click-NNNN.txt and deletes the
trace before the next click, then watches 150 ms for a second open (and 1 s after the last
click). The checker (Get-Pkg23Verdict) then requires every click to have a record that is one
CRLF-terminated line holding a whole, self-checking URL of the stream (its number twice; none
missing, none partial, none torn), no open for no click, the numbers never to go back, and row 0
to have moved during the clicks.
Its controls (Invoke-Pkg23CheckerControls) run first in every mode, so a checker that would accept
a missing or partial record stops the run before anything starts; -ControlOnly runs only them.

Results: pkg23-results.json (counts, the dry-click proof, checks; no path, coordinate, command
line or environment value), pkg23\dry.txt, pkg23\records\, pkg23\version.txt, startup-state.json.
Exit 0: every check passed. 1: a check failed, the copy failed at the dry click, or the run did
not finish. 3: an isolation guard changed (startup ledger, history, clipboard, a new jump-list
file, a reparse point in the run). 4: the build is not Debug, its source lacks the seam, or the
dry click did not prove the seam; nothing more was clicked.

Limits: posted messages on a never-shown desktop. A modifier held at the real keyboard can still
reach a posted click (test-harnesses.md, 2026-11-18 SOAK-01 trap 4), and turns that click into one
no link answers; the driver clears the target thread's key state before each click, which a
private-desktop driver cannot verify. Text links only: the OSC 8 path (`osc8URI`) is not streamed.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [string] $Run,
    [ValidateRange(2, 1000)] [int] $Clicks = 300,
    [switch] $DryClickOnly,
    [switch] $ControlOnly,
    [ValidateRange(60, 7200)] [int] $DriverTimeoutSeconds = 1800,
    [string] $Bin,
    [string] $DesktopName,
    [switch] $Driver
)
$ErrorActionPreference = 'Stop'

# --- The checker. Pure functions over in-memory records, so its controls start nothing.

# The URL the dry click must record, and the URL every streamed row holds: cmd's /L counter
# from 10000000 written twice, so every number has eight digits, a cut anywhere changes the
# shape, and a record spliced from two rows does not repeat its own number.
$script:Pkg23DryUrl = 'https://pkg23.invalid/00000000'
$script:Pkg23StreamPattern = '\Ahttps://pkg23\.invalid/(1[0-9]{7})/\1\z'

# One trace record: `missing` (no trace file for the click), `partial` (not exactly one
# CRLF-terminated line), `torn` (one line, but not a whole URL of the pattern) or `whole`.
function Get-Pkg23RecordStatus([AllowNull()] [byte[]] $Bytes, [string] $Pattern) {
    if ($null -eq $Bytes) { return 'missing' }
    $text = [Text.Encoding]::Latin1.GetString($Bytes)
    if ($text.Length -lt 2 -or -not $text.EndsWith("`r`n", [StringComparison]::Ordinal)) { return 'partial' }
    $line = $text.Substring(0, $text.Length - 2)
    if ($line.Length -eq 0 -or $line.IndexOfAny([char[]]@([char]13, [char]10)) -ge 0) { return 'partial' }
    if ([regex]::IsMatch($line, $Pattern)) { return 'whole' }
    return 'torn'
}

# The stream's verdict over `$Records` (click number to the record's bytes; a click with no
# record has no key, and any other key is an extra record) for `$Clicks` clicks. `$LiveExtras`
# counts the opens the driver saw that belong to no click: a second open after a click's record
# was cleared, a record later than its click's wait, a trace left after the last click.
function Get-Pkg23Verdict([hashtable] $Records, [int] $Clicks, [int] $LiveExtras) {
    $counts = [ordered]@{ whole = 0; missing = 0; partial = 0; torn = 0 }
    $numbers = [Collections.Generic.List[long]]::new()
    $ordered = $true
    for ($i = 1; $i -le $Clicks; $i++) {
        # Assigned, never the output of an `if`: the pipeline would unroll an empty record to $null.
        $bytes = $null
        if ($Records.ContainsKey($i)) { $bytes = [byte[]] $Records[$i] }
        $status = Get-Pkg23RecordStatus $bytes $script:Pkg23StreamPattern
        $counts[$status]++
        if ($status -ne 'whole') { continue }
        $line = [Text.Encoding]::Latin1.GetString($bytes, 0, $bytes.Length - 2)
        $number = [long] [regex]::Match($line, $script:Pkg23StreamPattern).Groups[1].Value
        if ($numbers.Count -gt 0 -and $number -lt $numbers[$numbers.Count - 1]) { $ordered = $false }
        $numbers.Add($number)
    }
    $extra = @($Records.Keys | Where-Object { $_ -isnot [int] -or $_ -lt 1 -or $_ -gt $Clicks }).Count + $LiveExtras
    $moved = $numbers.Count -ge 2 -and $numbers[$numbers.Count - 1] -gt $numbers[0]
    $distinct = @($numbers | Sort-Object -Unique).Count
    return [ordered]@{
        Clicks = $Clicks; Opened = $Clicks - $counts.missing; Whole = $counts.whole
        Missing = $counts.missing; Partial = $counts.partial; Torn = $counts.torn; Extra = $extra
        Ordered = $ordered; Moved = $moved; DistinctNumbers = $distinct
        FirstNumber = $(if ($numbers.Count) { $numbers[0] } else { $null })
        LastNumber = $(if ($numbers.Count) { $numbers[$numbers.Count - 1] } else { $null })
        Passed = ($Clicks -ge 2 -and $extra -eq 0 -and $counts.whole -eq $Clicks -and $ordered -and $moved)
    }
}

# The dry click's verdict: a Debug build, exactly the dry URL recorded, and no process the job gained,
# with the counter's positive control: the same count rose by at least two (the copy and its shell)
# across the launch, so a process an open started would have shown.
function Get-Pkg23DryVerdict([AllowNull()] [byte[]] $Bytes, [AllowNull()] [string] $BuildMode,
    [long] $JobProcessesBefore, [long] $JobProcessesAfter, [string[]] $NewProcesses, [long] $LaunchProcesses) {
    $status = Get-Pkg23RecordStatus $Bytes ('\A' + [regex]::Escape($script:Pkg23DryUrl) + '\z')
    $quiet = $JobProcessesAfter -eq $JobProcessesBefore -and @($NewProcesses).Count -eq 0
    $counted = $LaunchProcesses -ge 2
    return [ordered]@{
        BuildMode = $BuildMode; Record = $status
        JobProcessesBefore = $JobProcessesBefore; JobProcessesAfter = $JobProcessesAfter; NewProcesses = @($NewProcesses)
        LaunchProcesses = $LaunchProcesses
        Passed = ([string]::Equals($BuildMode, 'Debug', [StringComparison]::Ordinal) -and $status -eq 'whole' -and $quiet -and $counted)
    }
}

# The seam the dry click relies on, as the source a build was made from has it: a link open past
# the confirmed schemes is queued as a target, a queued target reaches dispatchOpenTarget, which in
# Debug returns once the trace has recorded the URL, before shellExecuteOpenTarget (whose only
# caller it is); the trace truncates its file at every open and writes the URL and one CRLF.
# Returns the rules that do not hold, none for a sound seam. Case-sensitive, over Zig source text.
function Get-Pkg23SeamProblems([string] $AppText, [string] $Win32Text) {
    $problems = [Collections.Generic.List[string]]::new()
    $appRules = @(
        @{ Name = 'a link open past the confirmed schemes is queued as a target'; Pattern = '(?s)fn open\(self: LinkRequest, checked: \[\]const u8\) !void \{\s+const scheme = confirmedLinkScheme\(checked\) orelse return self\.app\.deferOpenTarget\(checked\);' }
        @{ Name = 'deferOpenTarget queues a target'; Pattern = '(?s)fn deferOpenTarget\(self: \*App, target: \[\]const u8\) !void \{\s+const alloc = self\.core_app\.alloc;\s+const owned = try alloc\.dupe\(u8, target\);\s+errdefer alloc\.free\(owned\);\s+try self\.deferShellRequest\(\.\{ \.target = owned \}\);\s+\}' }
        @{ Name = 'a queued target is dispatched through dispatchOpenTarget'; Pattern = '\.target => \|target\| return openWin32Target\(self\.core_app\.alloc, self, target, dispatchOpenTarget\),' }
        @{ Name = 'in Debug, dispatchOpenTarget returns once the trace has recorded the URL'; Pattern = '(?s)fn dispatchOpenTarget\(self: \*App, target: \[\]const u8\) !void \{\s+if \(self\.test_open_target\) \|hook\| return hook\(self, target\);\s+if \(builtin\.mode == \.Debug and\s+try recordOpenUrlForTest\(self\.core_app\.alloc, target\)\) return;\s+return shellExecuteOpenTarget\(self, target\);\s+\}' }
    )
    foreach ($rule in $appRules) { if ($AppText -cnotmatch $rule.Pattern) { $problems.Add($rule.Name) } }
    if ([regex]::Matches($AppText, 'shellExecuteOpenTarget\(').Count -ne 2) { $problems.Add('shellExecuteOpenTarget has its definition and one caller, dispatchOpenTarget') }
    $win32Rules = @(
        @{ Name = 'the trace reads NOCTTY_WIN32_OPEN_URL_TRACE_FILE at each open, truncates the file, and then returns true'; Pattern = '(?s)pub fn recordOpenUrlForTest\(alloc: Allocator, url: \[\]const u8\) !bool \{.*?"NOCTTY_WIN32_OPEN_URL_TRACE_FILE",.*?const file = try std\.fs\.createFileAbsolute\(path, \.\{ \.truncate = true \}\);\s+defer file\.close\(\);\s+try writeOpenUrlTrace\(file, url\);\s+return true;' }
        @{ Name = 'a trace record is the URL and one CRLF'; Pattern = 'try writer\.interface\.print\("\{s\}\\r\\n", \.\{url\}\);' }
    )
    foreach ($rule in $win32Rules) { if ($Win32Text -cnotmatch $rule.Pattern) { $problems.Add($rule.Name) } }
    return , $problems.ToArray()
}

# The unary comma keeps each byte array whole through the pipeline.
function ConvertTo-Pkg23Bytes([string] $Text) { return , [Text.Encoding]::Latin1.GetBytes($Text) }
function Get-Pkg23StreamRecord([long] $Number) { return , (ConvertTo-Pkg23Bytes "https://pkg23.invalid/$Number/$Number`r`n") }

# The checker's controls: every way a record can be missing, partial or torn, and an open for no
# click, must fail it, a whole run must pass it, and a dry click that recorded nothing, recorded
# part of its URL or started a process must fail. Throws on the first control that does not behave; returns how many ran.
function Invoke-Pkg23CheckerControls {
    $a = Get-Pkg23StreamRecord 10000005
    $b = Get-Pkg23StreamRecord 10000210
    $c = Get-Pkg23StreamRecord 10000473
    $cases = @(
        @{ Name = 'three whole records in order'; Records = @{ 1 = $a; 2 = $b; 3 = $c }; Passed = $true; Expect = @{ Whole = 3; Opened = 3 } }
        @{ Name = 'a missing record'; Records = @{ 1 = $a; 3 = $c }; Passed = $false; Expect = @{ Missing = 1; Opened = 2 } }
        @{ Name = 'a missing last record'; Records = @{ 1 = $a; 2 = $b }; Passed = $false; Expect = @{ Missing = 1 } }
        @{ Name = 'a record without its line end'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes 'https://pkg23.invalid/10000210/10000210'); 3 = $c }; Passed = $false; Expect = @{ Partial = 1; Opened = 3 } }
        @{ Name = 'a record cut inside the URL'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes 'https://pkg23.inv'); 3 = $c }; Passed = $false; Expect = @{ Partial = 1 } }
        @{ Name = 'an empty record'; Records = @{ 1 = $a; 2 = [byte[]]@(); 3 = $c }; Passed = $false; Expect = @{ Partial = 1 } }
        @{ Name = 'a bare line end'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes "`r`n"); 3 = $c }; Passed = $false; Expect = @{ Partial = 1 } }
        @{ Name = 'two records in one file'; Records = @{ 1 = $a; 2 = [byte[]]($b + $c); 3 = $c }; Passed = $false; Expect = @{ Partial = 1 } }
        @{ Name = 'a torn URL on a whole line'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes "https://pkg23.inval`r`n"); 3 = $c }; Passed = $false; Expect = @{ Torn = 1 } }
        @{ Name = 'a URL with text around it'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes "see https://pkg23.invalid/10000210/10000210 now`r`n"); 3 = $c }; Passed = $false; Expect = @{ Torn = 1 } }
        @{ Name = 'a URL short of a digit'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes "https://pkg23.invalid/1000021/1000021`r`n"); 3 = $c }; Passed = $false; Expect = @{ Torn = 1 } }
        @{ Name = 'a URL spliced from two rows'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes "https://pkg23.invalid/10000210/10000473`r`n"); 3 = $c }; Passed = $false; Expect = @{ Torn = 1 } }
        @{ Name = 'the dry URL in the stream'; Records = @{ 1 = $a; 2 = (ConvertTo-Pkg23Bytes "$($script:Pkg23DryUrl)`r`n"); 3 = $c }; Passed = $false; Expect = @{ Torn = 1 } }
        @{ Name = 'a record for no click'; Records = @{ 1 = $a; 2 = $b; 3 = $c; 4 = $c }; Passed = $false; Expect = @{ Extra = 1; Whole = 3 } }
        @{ Name = 'a number that goes back'; Records = @{ 1 = $a; 2 = $c; 3 = $b }; Passed = $false; Expect = @{ Ordered = $false; Whole = 3 } }
        @{ Name = 'a stream that never moved'; Records = @{ 1 = $a; 2 = $a; 3 = $a }; Passed = $false; Expect = @{ Moved = $false; Whole = 3 } }
        @{ Name = 'an open the driver saw for no click'; Records = @{ 1 = $a; 2 = $b; 3 = $c }; Live = 1; Passed = $false; Expect = @{ Extra = 1; Whole = 3 } }
    )
    $ran = 0
    foreach ($case in $cases) {
        $live = 0
        if ($case.ContainsKey('Live')) { $live = $case.Live }
        $verdict = Get-Pkg23Verdict $case.Records 3 $live
        if ($verdict.Passed -ne $case.Passed) { throw "PKG-23 checker control '$($case.Name)': expected Passed=$($case.Passed), got $($verdict.Passed)." }
        foreach ($key in $case.Expect.Keys) {
            if ($verdict[$key] -ne $case.Expect[$key]) { throw "PKG-23 checker control '$($case.Name)': expected $key=$($case.Expect[$key]), got $($verdict[$key])." }
        }
        $ran++
    }
    $dry = ConvertTo-Pkg23Bytes "$($script:Pkg23DryUrl)`r`n"
    $dryCases = @(
        @{ Name = 'a dry click that recorded its URL and started nothing'; Bytes = $dry; Mode = 'Debug'; After = 7; New = @(); Launch = 3; Passed = $true }
        @{ Name = 'a dry click that recorded nothing'; Bytes = $null; Mode = 'Debug'; After = 7; New = @(); Launch = 3; Passed = $false }
        @{ Name = 'a dry click that recorded part of its URL'; Bytes = (ConvertTo-Pkg23Bytes 'https://pkg23.invalid/0000'); Mode = 'Debug'; After = 7; New = @(); Launch = 3; Passed = $false }
        @{ Name = 'a dry click that recorded another URL'; Bytes = $a; Mode = 'Debug'; After = 7; New = @(); Launch = 3; Passed = $false }
        @{ Name = 'a dry click after which the job gained a process'; Bytes = $dry; Mode = 'Debug'; After = 8; New = @(); Launch = 3; Passed = $false }
        @{ Name = 'a dry click after which a new process ran in the job'; Bytes = $dry; Mode = 'Debug'; After = 7; New = @('msedge'); Launch = 3; Passed = $false }
        @{ Name = 'a dry click on a build that is not Debug'; Bytes = $dry; Mode = 'ReleaseSafe'; After = 7; New = @(); Launch = 3; Passed = $false }
        @{ Name = 'a dry click whose job counter did not see the launch'; Bytes = $dry; Mode = 'Debug'; After = 7; New = @(); Launch = 0; Passed = $false }
    )
    foreach ($case in $dryCases) {
        $verdict = Get-Pkg23DryVerdict $case.Bytes $case.Mode 7 $case.After $case.New $case.Launch
        if ($verdict.Passed -ne $case.Passed) { throw "PKG-23 checker control '$($case.Name)': expected Passed=$($case.Passed), got $($verdict.Passed)." }
        $ran++
    }
    return $ran
}

if ($ControlOnly) {
    $count = Invoke-Pkg23CheckerControls
    "PKG-23 checker controls: PASS ($count controls)"
    exit 0
}

. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
$desktopPrefix = 'noctty-pkg23-'

# --- The outer half: admission, the private-desktop driver, and the guards it checks afterwards.

# Jump-list files that did not exist before `$Since` and were written after it: a copy that
# committed a jump list of its own would add one. The user's own noctty may rewrite an existing
# file meanwhile, so only new files count. Names and times only, never content or paths in results.
function Get-Pkg23NewJumpListFiles([string[]] $Before, [DateTimeOffset] $Since) {
    return @(Jump-List-Files | Where-Object { $Before -notcontains $_.Path -and $_.Written -ge $Since })
}

# Reparse points anywhere under `$Root`, walked without following one (a recursive .NET
# enumeration follows junctions): cmd's AutoRun once left a junction in a redirected LOCALAPPDATA.
function Get-Pkg23ReparsePointCount([string] $Root) {
    $count = 0
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($Root))
    while ($pending.Count -gt 0) {
        foreach ($entry in $pending.Pop().EnumerateFileSystemInfos()) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $count++ }
            elseif ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry) }
        }
    }
    return $count
}

if (-not $Driver) {
    if (-not $MeasureRepo -or -not $Run) { throw 'Pass -MeasureRepo (a clean checkout with a completed measurement build) and -Run (a new directory).' }
    # Before anything else: the results read below must be this run's, never an earlier run's in the same place.
    if (Test-Path -LiteralPath $Run) { Write-Host 'PKG-23: -Run must name a new directory; nothing was launched.'; exit 1 }
    # The checker must refuse a missing or partial record before anything starts.
    $controls = Invoke-Pkg23CheckerControls
    . (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-measure-lib.ps1')
    $exe = Get-InteractiveWin11MeasureExePath -RepoRoot $MeasureRepo
    Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $exe
    $layout = Get-InteractiveWin11MeasureLayout -RepoRoot $MeasureRepo
    $receipt = Get-Content -LiteralPath $layout.Receipt -Raw | ConvertFrom-Json
    if (-not [string]::Equals([string]$receipt.Optimize, 'Debug', [StringComparison]::Ordinal)) {
        Write-Host 'PKG-23: the open-URL trace seam exists only in a Debug build, and the measurement build is not Debug; nothing was launched.'
        exit 4
    }
    # The seam in the source this build was made from (the receipt-checked extraction), not this
    # checkout's: a build whose opener does not stop at the trace would hand the dry click to the shell.
    $seamProblems = Get-Pkg23SeamProblems ([IO.File]::ReadAllText((Join-Path $layout.Source 'src\apprt\win32\app.zig'))) `
        ([IO.File]::ReadAllText((Join-Path $layout.Source 'src\apprt\win32.zig')))
    if ($seamProblems.Count -ne 0) {
        Write-Host "PKG-23: the measurement build's source does not have the trace seam this harness relies on ($($seamProblems -join '; ')); nothing was launched."
        exit 4
    }
    $jumpBefore = @(Jump-List-Files | ForEach-Object { $_.Path })
    $since = [DateTimeOffset]::UtcNow
    $driverArguments = @('-Clicks', [string]$Clicks)
    if ($DryClickOnly) { $driverArguments += '-DryClickOnly' }
    $driverError = $null
    try {
        Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin (Split-Path -Parent $exe) -Run $Run -DesktopPrefix $desktopPrefix `
            -TimeoutSeconds $DriverTimeoutSeconds -Label 'PKG-23 driver' -PassDesktopName -GuardClipboard -OmitIcon `
            -DriverArguments $driverArguments
    } catch { $driverError = $_ }
    $statePath = Join-Path $Run 'startup-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw $driverError }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $newJump = @(Get-Pkg23NewJumpListFiles $jumpBefore $since).Count
    $reparse = Get-Pkg23ReparsePointCount $Run
    $resultsPath = Join-Path $Run 'pkg23-results.json'
    $results = if (Test-Path -LiteralPath $resultsPath) { Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json } else { $null }
    $guards = [ordered]@{
        StartupUnchanged = [bool]$state.Unchanged; HistoryUnchanged = [bool]$state.HistoryUnchanged
        ClipboardUnchanged = [bool]$state.ClipboardUnchanged; OwnedJobCleanedUp = [bool]$state.OwnedJobCleanedUp
        NewJumpListFiles = $newJump; ReparsePoints = $reparse; CheckerControls = $controls
    }
    $guards | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'pkg23-guards.json')
    if (-not $guards.StartupUnchanged -or -not $guards.HistoryUnchanged -or -not $guards.ClipboardUnchanged -or $newJump -ne 0 -or $reparse -ne 0) {
        Write-Host "PKG-23: an isolation guard changed (startup=$($guards.StartupUnchanged) history=$($guards.HistoryUnchanged) clipboard=$($guards.ClipboardUnchanged) new jump-list files=$newJump reparse points=$reparse); stop launches and report it."
        exit 3
    }
    if ($null -ne $results -and $results.Stage -eq 'dry-product-failure') {
        Write-Host "PKG-23: FAIL, the copy died or stopped answering at the dry click's link release (alive $($results.DryClickCopy.Alive), answering $($results.DryClickCopy.Responds)); nothing more was clicked."
        exit 1
    }
    if ($null -ne $results -and $results.Stage -eq 'dry-failed') {
        Write-Host "PKG-23: the dry click did not prove the trace seam (build mode $($results.DryClick.BuildMode), record $($results.DryClick.Record), job processes $($results.DryClick.JobProcessesBefore) -> $($results.DryClick.JobProcessesAfter), new: $(@($results.DryClick.NewProcesses) -join ', ')); nothing more was clicked."
        exit 4
    }
    if ($null -ne $results -and $null -ne $results.DryClick) {
        Write-Host "PKG-23 dry click: $(if ($results.DryClick.Passed) { 'PASS' } else { 'FAIL' }) (build mode $($results.DryClick.BuildMode), record $($results.DryClick.Record), job processes $($results.DryClick.JobProcessesBefore) -> $($results.DryClick.JobProcessesAfter))"
    }
    if ($null -ne $results -and $null -ne $results.Verdict) {
        $v = $results.Verdict
        Write-Host ("PKG-23 Ctrl+click: {0} clicks={1} opened={2} whole={3} missing={4} partial={5} torn={6} extra={7} ordered={8} moved={9} distinct={10} duration={11:N1}s" -f `
            $(if ($v.Passed) { 'PASS' } else { 'FAIL' }), $v.Clicks, $v.Opened, $v.Whole, $v.Missing, $v.Partial, $v.Torn, $v.Extra, $v.Ordered, $v.Moved, $v.DistinctNumbers, [double]$results.ClickSeconds)
    }
    if ($driverError) { Write-Host "PKG-23: FAIL ($($driverError.Exception.Message))"; exit 1 }
    Write-Host 'PKG-23: PASS'
    exit 0
}

# --- The driver. This branch runs only on the new private desktop; children inherit it.

Assert-LocalHiddenFixture $Bin $Run $DesktopName $desktopPrefix
# cmd captures +version and runs the stream; these literal paths are part of its input.
if ($Run -match '[\x00-\x1f"%!^&|<>]') { throw 'Unsupported cmd metacharacter in run path.' }
if ([IntPtr]::Size -ne 8) { throw 'The job queries below read a 64-bit layout.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Pkg23Native {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int show);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(int from, int to, bool attach);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, int size, out int returned);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    public static void PostClose(IntPtr h) { if (!PostMessageW(h, 0x10, IntPtr.Zero, IntPtr.Zero)) throw new Exception("WM_CLOSE post failed"); }
    // Whether the thread that owns `h` handles a sent WM_NULL within two seconds
    // (SMTO_ABORTIFHUNG): a copy stuck on a lock fails it.
    public static bool Responds(IntPtr h) { IntPtr r; return SendMessageTimeoutW(h, 0, IntPtr.Zero, IntPtr.Zero, 0x2, 2000, out r) != IntPtr.Zero; }
    public static int Owner(IntPtr h) { int pid; GetWindowThreadProcessId(h, out pid); return pid; }
    public static string ClassOf(IntPtr h) { var s = new StringBuilder(128); GetClassNameW(h, s, 128); return s.ToString(); }
    public static int[] ClientSize(IntPtr h) {
        Rect r; if (!GetClientRect(h, out r)) throw new Exception("Client measurement failed");
        return new int[] { r.Right - r.Left, r.Bottom - r.Top };
    }
    // A Ctrl move to the park cell (px, py), then a Ctrl+left click at client (x, y), as a mouse
    // with Ctrl held posts them: Ctrl lives only in the messages' key flags (MK_CONTROL), and no
    // key message is posted, so the shell reads nothing.
    public static void CtrlClick(IntPtr h, int px, int py, int x, int y) {
        var park = new IntPtr(((py & 0xFFFF) << 16) | (px & 0xFFFF));
        var l = new IntPtr(((y & 0xFFFF) << 16) | (x & 0xFFFF));
        if (!PostMessageW(h, 0x200, new IntPtr(0x8), park) ||
            !PostMessageW(h, 0x200, new IntPtr(0x8), l) || !PostMessageW(h, 0x201, new IntPtr(0x9), l) ||
            !PostMessageW(h, 0x202, new IntPtr(0x8), l)) throw new Exception("Click post failed");
    }
    // Clears the key state of the UI thread that owns `h`, so a posted click reads no modifier
    // the person at the real keyboard holds: this thread joins that thread's input queue for the
    // call; no input is sent.
    public static void ClearKeys(IntPtr h) {
        int pid; int tid = GetWindowThreadProcessId(h, out pid); int me = GetCurrentThreadId();
        if (!AttachThreadInput(me, tid, true)) throw new Exception("AttachThreadInput failed");
        try { if (!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed"); }
        finally { AttachThreadInput(me, tid, false); }
    }
    // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION (48 bytes) of this process's own job: TotalProcesses,
    // every process the job ever held, at offset 36. A null handle names the caller's job.
    public static long JobTotalProcesses() {
        IntPtr buffer = Marshal.AllocHGlobal(48);
        try {
            int returned;
            if (!QueryInformationJobObject(IntPtr.Zero, 1, buffer, 48, out returned)) throw new Exception("The driver's job could not be read: " + Marshal.GetLastWin32Error());
            return (uint)Marshal.ReadInt32(buffer, 36);
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    // JOBOBJECT_BASIC_PROCESS_ID_LIST of this process's own job: the count at offset 4, then
    // ULONG_PTR process numbers from offset 8.
    public static long[] JobProcessIds() {
        const int capacity = 1024; int size = 8 + 8 * capacity;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            int returned;
            if (!QueryInformationJobObject(IntPtr.Zero, 3, buffer, size, out returned)) throw new Exception("The driver's job process list could not be read: " + Marshal.GetLastWin32Error());
            int count = Marshal.ReadInt32(buffer, 4);
            var ids = new long[count];
            for (int i = 0; i < count; i++) ids[i] = Marshal.ReadInt64(buffer, 8 + 8 * i);
            return ids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
[void][Pkg23Native]::SetThreadDpiAwarenessContext([IntPtr](-4))

$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
$env:XDG_STATE_HOME = $env:LOCALAPPDATA
$env:XDG_CONFIG_HOME = $env:LOCALAPPDATA
$env:XDG_CACHE_HOME = $env:LOCALAPPDATA
$env:USERPROFILE = $Run
$env:HOME = $Run
$temp = Join-Path $Run 'temp'
[void][IO.Directory]::CreateDirectory($temp)
$env:TEMP = $temp
$env:TMP = $temp
$desktop = "WinSta0\$DesktopName"
$cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$exe = Join-Path $Bin 'noctty.exe'
$work = Join-Path $Run 'pkg23'
$recordsDir = Join-Path $work 'records'
$traceDir = Join-Path $work 'trace'
$tracePath = Join-Path $traceDir 'open-url.txt'
foreach ($dir in @($work, $recordsDir, $traceDir)) { [void][IO.Directory]::CreateDirectory($dir) }
$dryShown = Join-Path $Bin 'pkg23-dry-shown.txt'
$streamStarted = Join-Path $Bin 'pkg23-stream-started.txt'
$script:checks = [Collections.Generic.List[object]]::new()
$results = [ordered]@{
    Stage = 'start'; Clicks = $Clicks; DryClickOnly = [bool]$DryClickOnly
    DryClick = $null; DryClickCopy = $null; Verdict = $null; ClickSeconds = $null; ExtraOpens = 0; LateRecordsDiscarded = 0
    Checks = $script:checks
    Limit = 'Posted window messages on a never-shown private desktop; real pointer input, a modifier held at the real keyboard, and OSC 8 links are not exercised.'
}

# The stream: the dry URL on a still screen until a key arrives, then numbered URLs forever.
# ASCII with CRLF line ends; its markers sit beside it (%~dp0), found through the working directory.
$stream = @(
    '@echo off'
    "echo $($script:Pkg23DryUrl)"
    'echo dry>"%~dp0pkg23-dry-shown.txt"'
    'pause >nul'
    'echo stream>"%~dp0pkg23-stream-started.txt"'
    'for /L %%i in (10000000,1,99999999) do echo https://pkg23.invalid/%%i/%%i'
)
[IO.File]::WriteAllText((Join-Path $Bin 'pkg23-stream.cmd'), (($stream -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
# The copy's own config (a portable copy reads config.ghostty at its root; no --config-file).
# System32's cmd.exe runs directly with /D, so no AutoRun runs; the clipboard is denied and
# copy-on-select is off; a class of its own keeps every IPC pipe apart from any other noctty.
@(
    "command = direct:$cmd /D /C pkg23-stream.cmd", "working-directory = $Bin", 'shell-integration = none',
    'single-instance = false', "class = noctty-test-pkg23-$([guid]::NewGuid().ToString('N'))", 'window-save-state = never',
    'confirm-close-surface = false', 'copy-on-select = false', 'clipboard-read = deny', 'clipboard-write = deny',
    'auto-update = off', 'desktop-notifications = false', 'keybind = clear', 'scrollback-limit = 0', 'click-repeat-interval = 1',
    'window-width = 100', 'window-height = 30', 'window-padding-x = 4', 'window-padding-y = 4'
) | Set-Content -LiteralPath (Join-Path $Bin 'config.ghostty') -Encoding utf8NoBOM

# The copy's build mode, from its own +version (src/cli/version.zig), before anything starts.
function Get-Pkg23BuildMode {
    $stdout = Join-Path $work 'version.txt'
    $stderr = Join-Path $work 'version.err.txt'
    $line = '"{0}" /d /s /c ""{1}" +version >"{2}" 2>"{3}""' -f $cmd, (Join-Path $Bin 'noctty.com'), $stdout, $stderr
    $pi = [HiddenLocal]::Spawn($cmd, $line, $Bin, $desktop)
    try {
        [uint32] $code = 0
        if ([HiddenLocal]::WaitForSingleObject($pi.process, 60000) -ne 0 -or -not [HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code)) {
            throw '+version did not finish in 60 s. The outer job owns cleanup.'
        }
    } finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
    $match = [regex]::Match([IO.File]::ReadAllText($stdout), '(?m)^\s*-\s*build mode\s*:\s*(?:[A-Za-z_.]*\.)?(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)\s*$')
    if ($code -ne 0 -or -not $match.Success) { return $null }
    return $match.Groups[1].Value
}

# The trace file's bytes, or $null while it is absent or held without sharing.
function Read-Pkg23Trace {
    try {
        $stream = [IO.File]::Open($tracePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try {
            $buffer = [IO.MemoryStream]::new()
            $stream.CopyTo($buffer)
            return , $buffer.ToArray()
        } finally { $stream.Dispose() }
    } catch [IO.IOException] { return $null } catch [UnauthorizedAccessException] { return $null }
}

# Waits for the trace to hold a line end; returns the last bytes read ($null if none) and whether they ended.
function Wait-Pkg23Record([int] $Milliseconds) {
    $deadline = [datetime]::UtcNow.AddMilliseconds($Milliseconds)
    $last = $null
    do {
        $bytes = Read-Pkg23Trace
        if ($null -ne $bytes) {
            $last = $bytes
            if ($bytes.Length -ge 2 -and $bytes[$bytes.Length - 2] -eq 13 -and $bytes[$bytes.Length - 1] -eq 10) { return @{ Bytes = $bytes; Ended = $true } }
        }
        Start-Sleep -Milliseconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    return @{ Bytes = $last; Ended = $false }
}

# Whether a trace file appears within `$Milliseconds`.
function Test-Pkg23TraceAppears([int] $Milliseconds) {
    $deadline = [datetime]::UtcNow.AddMilliseconds($Milliseconds)
    do {
        if ([IO.File]::Exists($tracePath)) { return $true }
        Start-Sleep -Milliseconds 5
    } while ([datetime]::UtcNow -lt $deadline)
    return [IO.File]::Exists($tracePath)
}

# Deletes the trace and waits until it is gone, so the next click's record is its own.
function Clear-Pkg23Trace {
    $deadline = [datetime]::UtcNow.AddSeconds(2)
    do {
        try { [IO.File]::Delete($tracePath) } catch [IO.IOException] { } catch [UnauthorizedAccessException] { }
        if (-not [IO.File]::Exists($tracePath)) { return }
        Start-Sleep -Milliseconds 10
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'The trace record could not be cleared before the next click.'
}

# Posts one Ctrl+click to the known pane of the known process on this desktop, after a Ctrl move
# to the park cell.
function Send-Pkg23Click($Pane, [int] $X, [int] $Y) {
    if ([Pkg23Native]::Owner($Pane) -ne $script:noctty.pid -or [Pkg23Native]::ClassOf($Pane) -cne 'noctty.win32' -or
        [HiddenLocal]::WindowDesktop($Pane) -cne $DesktopName) { throw 'The click target is not the owned terminal pane on the private desktop.' }
    [Pkg23Native]::ClearKeys($Pane)
    [Pkg23Native]::CtrlClick($Pane, $script:parkX, $script:parkY, $X, $Y)
}

function Test-Pkg23Running { return [HiddenLocal]::WaitForSingleObject($script:noctty.process, 0) -eq 258 }

# Closes the copy's windows; stops it through its own launch handle if it has not exited in 10 s.
function Close-Pkg23Copy {
    if ($null -eq $script:noctty) { return }
    foreach ($h in [HiddenLocal]::Hosts($script:noctty.pid)) { [Pkg23Native]::PostClose($h) }
    $forced = $false
    if ([HiddenLocal]::WaitForSingleObject($script:noctty.process, 10000) -eq 258) {
        $forced = $true
        [void][HiddenLocal]::TerminateProcess($script:noctty.process, 1)
        [void][HiddenLocal]::WaitForSingleObject($script:noctty.process, 5000)
    }
    [uint32] $code = 0
    [void][HiddenLocal]::GetExitCodeProcess($script:noctty.process, [ref]$code)
    Check 'noctty closed on WM_CLOSE with exit 0' (-not $forced -and $code -eq 0) 'closed, exit 0' @{ Forced = $forced; Exit = $code }
    [void][HiddenLocal]::CloseHandle($script:noctty.thread); [void][HiddenLocal]::CloseHandle($script:noctty.process)
    $script:noctty = $null
}

# The driver's steps; a `return` ends them, and the caller's finally closes the copy.
function Invoke-Pkg23Driver {
    $results.Stage = 'build-mode'
    $buildMode = Get-Pkg23BuildMode
    if (-not [string]::Equals($buildMode, 'Debug', [StringComparison]::Ordinal)) {
        $results.DryClick = Get-Pkg23DryVerdict $null $buildMode 0 0 @() 0
        $results.Stage = 'dry-failed'
        return
    }

    $results.Stage = 'launch'
    # The seam reads this at every open (recordOpenUrlForTest); the copy inherits it.
    $env:NOCTTY_WIN32_OPEN_URL_TRACE_FILE = $tracePath
    $line = '"{0}" --single-instance=false --window-save-state=never' -f $exe
    $launchBefore = [Pkg23Native]::JobTotalProcesses()
    $script:noctty = [HiddenLocal]::Spawn($exe, $line, $Bin, $desktop)
    $ledger = Join-Path $Bin 'startup-attempts.json'
    $hostWindow = [IntPtr]::Zero
    $ready = Wait-Until {
        $hosts = @([HiddenLocal]::Hosts($script:noctty.pid))
        $started = $false
        if (Test-Path -LiteralPath $ledger) {
            try {
                $attempts = (Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $started = $attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready'
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if ($started -and $hosts.Count -eq 1 -and @([HiddenLocal]::Surfaces($hosts[0])).Count -eq 1) { $script:hostWindow = $hosts[0]; return $true }
        return $false
    } 30
    if (-not $ready) { throw 'The copy did not reach ready with one window and one pane in 30 s.' }
    $hostWindow = $script:hostWindow
    if ([HiddenLocal]::WindowDesktop($hostWindow) -cne $DesktopName) { throw 'The copy''s window is not on the private desktop.' }
    [void][Pkg23Native]::ShowWindow($hostWindow, 4)   # SW_SHOWNOACTIVATE, on the never-shown desktop
    $pane = @([HiddenLocal]::Surfaces($hostWindow))[0]
    if (-not (Wait-Until { Test-Path -LiteralPath $dryShown } 20)) { throw 'The stream did not show its dry URL in 20 s.' }
    Start-Sleep -Milliseconds 1500   # ConPTY renders the line to the pane
    $launchProcesses = [Pkg23Native]::JobTotalProcesses() - $launchBefore

    # Row 0, column 0 (the URL's first cell, where the October probe clicked), and a park cell in
    # row 2 past the end of its URL, from the configured 100x30 grid and 4 pt padding; an estimate
    # off by a third of a cell still lands on both cells.
    $size = [Pkg23Native]::ClientSize($pane)
    $dpi = [double][Pkg23Native]::GetDpiForWindow($pane)
    $pad = [Math]::Floor(4 * $dpi / 72)   # scaledPadding in src/Surface.zig floors points * dpi / 72
    $cellWidth = ($size[0] - 2 * $pad) / 100.0
    $cellHeight = ($size[1] - 2 * $pad) / 30.0
    $y = [int]($pad + $cellHeight / 2)
    $x = [int]($pad + $cellWidth / 2)
    $script:parkX = [int]($pad + 70.5 * $cellWidth)
    $script:parkY = [int]($pad + 2.5 * $cellHeight)
    if ($cellWidth -lt 2 -or $cellHeight -lt 4) { throw 'The pane is too small to place a click on row 0.' }

    # (a) The dry click: the build is Debug, the record is exactly the dry URL, and the job gains no
    # process, so the seam replaced ShellExecuteW. Anything else stops the run here.
    $results.Stage = 'dry'
    Clear-Pkg23Trace
    $before = [Pkg23Native]::JobTotalProcesses()
    $idsBefore = @([Pkg23Native]::JobProcessIds())
    Send-Pkg23Click $pane $x $y
    $dry = Wait-Pkg23Record 5000
    Start-Sleep -Milliseconds 1500   # time for any process an open would start to join the job
    $after = [Pkg23Native]::JobTotalProcesses()
    $newNames = @(@([Pkg23Native]::JobProcessIds()) | Where-Object { $idsBefore -notcontains $_ } | ForEach-Object {
        $process = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($process) { $process.ProcessName } else { 'exited' }
    })
    if ($null -ne $dry.Bytes) { [IO.File]::WriteAllBytes((Join-Path $work 'dry.txt'), $dry.Bytes) }
    # A copy that died or stopped answering at its first link release is a product failure (a
    # LEFT-RELEASE-LOCK regression panics or deadlocks there), not an unproven seam; either way
    # nothing more is clicked.
    $alive = Test-Pkg23Running
    $responds = $alive -and [Pkg23Native]::Responds($hostWindow)
    $results.DryClickCopy = [ordered]@{ Alive = $alive; Responds = $responds }
    Check 'the copy survived the dry click and answers messages' ($alive -and $responds) 'alive, answering' $results.DryClickCopy
    if (-not ($alive -and $responds)) { $results.Stage = 'dry-product-failure'; return }
    $results.DryClick = Get-Pkg23DryVerdict $dry.Bytes $buildMode $before $after $newNames $launchProcesses
    Check 'the dry click proved that the trace seam replaced the open' $results.DryClick.Passed 'Debug, the dry URL recorded whole, no process gained' $results.DryClick
    if (-not $results.DryClick.Passed) { $results.Stage = 'dry-failed'; return }
    Clear-Pkg23Trace
    if ($DryClickOnly) { $results.Stage = 'done'; return }

    # The stream: one key releases cmd's pause.
    $results.Stage = 'stream'
    [Pkg23Native]::ClearKeys($pane)
    [HiddenLocal]::PostSurfaceKey($pane, $script:noctty.pid, $DesktopName, 0x0D)
    if (-not (Wait-Until { Test-Path -LiteralPath $streamStarted } 15)) { throw 'The stream did not start in 15 s.' }
    Start-Sleep -Milliseconds 1500   # the screen fills and scrolls, so row 0 changes under the clicks

    $results.Stage = 'clicks'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $Clicks; $i++) {
        if (-not (Test-Pkg23Running)) { throw "The copy exited before click $i." }
        Send-Pkg23Click $pane $x $y
        $record = Wait-Pkg23Record 3000
        if ($null -ne $record.Bytes) { [IO.File]::WriteAllBytes((Join-Path $recordsDir ('click-{0:D4}.txt' -f $i)), $record.Bytes) }
        else {
            # An open later than the wait must not land as the next click's record.
            Start-Sleep -Milliseconds 500
            if ([IO.File]::Exists($tracePath)) { $results.LateRecordsDiscarded++ }
        }
        Clear-Pkg23Trace
        # A second open from the same click would rewrite the trace now; count it, never as the next click's.
        if (Test-Pkg23TraceAppears 150) { $results.ExtraOpens++; Clear-Pkg23Trace }
    }
    $timer.Stop()
    $results.ClickSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2)
    if (Test-Pkg23TraceAppears 1000) { $results.ExtraOpens++; Clear-Pkg23Trace }   # after the last click
    Check 'the copy stayed up through every click' (Test-Pkg23Running) $true (Test-Pkg23Running)
    Check 'no click opened twice and no record came late' ($results.ExtraOpens -eq 0 -and $results.LateRecordsDiscarded -eq 0) 0 `
        @{ ExtraOpens = $results.ExtraOpens; LateRecordsDiscarded = $results.LateRecordsDiscarded }

    $records = @{}
    foreach ($file in [IO.Directory]::GetFiles($recordsDir)) {
        $name = [IO.Path]::GetFileName($file)
        $match = [regex]::Match($name, '\Aclick-([0-9]{4})\.txt\z')
        if ($match.Success) { $records[[int]$match.Groups[1].Value] = [IO.File]::ReadAllBytes($file) } else { $records[$name] = [byte[]]@() }
    }
    $verdict = Get-Pkg23Verdict $records $Clicks ($results.ExtraOpens + $results.LateRecordsDiscarded)
    $results.Verdict = $verdict
    Check "every click opened ($($verdict.Opened) of $Clicks)" ($verdict.Missing -eq 0) $Clicks $verdict.Opened
    Check "every record is one whole line ($($verdict.Partial) partial)" ($verdict.Partial -eq 0) 0 $verdict.Partial
    Check "every URL is whole ($($verdict.Whole) of $Clicks, $($verdict.Torn) torn)" ($verdict.Whole -eq $Clicks) $Clicks $verdict.Whole
    Check 'no record for a click that was not made' ($verdict.Extra -eq 0) 0 $verdict.Extra
    Check 'the opened numbers never went back' $verdict.Ordered $true $verdict.Ordered
    Check 'row 0 moved during the clicks' $verdict.Moved $true @{ Distinct = $verdict.DistinctNumbers }
    Check 'the checker passed the run' $verdict.Passed $true $verdict.Passed
    $results.Stage = 'done'
}

$script:noctty = $null
try {
    Invoke-Pkg23Driver
} catch {
    $script:checks.Add(@{ Name = 'Harness execution'; Passed = $false; Error = $_.Exception.Message })
} finally {
    try { Close-Pkg23Copy } catch { $script:checks.Add(@{ Name = 'Close the copy'; Passed = $false; Error = $_.Exception.Message }) }
    $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'pkg23-results.json')
}
if ($results.Stage -eq 'dry-failed') { exit 4 }
$failed = @($script:checks | Where-Object { -not $_.Passed })
if ($failed.Count -or $results.Stage -ne 'done') { exit 1 }
exit 0
