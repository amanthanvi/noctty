#requires -Version 7.0
<#
MEASUREMENT ONLY (pacing-stall2): a copy of notrun\scratch\runner.ps1 with
three changes, nothing else in the measurements changed:
  1. Quiet gate: before each run, wait until whole-machine CPU busy (GetSystemTimes,
     1 s samples) is under -QuietBelowPct (25) for -QuietSeconds (10) consecutive
     seconds. Every wait is logged to quiet.log (each sample; top 3 processes by
     CPU, name and PID only, whenever a sample is over the bar). A run is never
     started without the gate; past -Deadline the batch stops instead.
  2. Build sentinel: during waits and around each run, any process whose image is
     a build tool (zig, cl, link, lld-link, clang, rustc, cargo, msbuild, cmake,
     ninja) that was not there before is logged by name, PID, parent PID and
     start time (no command lines).
  3. watchdog.ps1 runs beside each probe (started before the gate, stopped after
     the probe), logging into <measurement>\<side>-p<k>.wd\.
Runs go to pacing-stall2\runs\<Name> (probe.ps1 copy here refuses anything else).

runner-load.ps1 (injected-load batch) = runner-stall2.ps1 plus:
  4. probe-load.ps1 (probe.ps1 plus an 'Idle' choice: driver BelowNormal outside
     noctty's job, noctty's job limited to IDLE_PRIORITY_CLASS 0x40).
  5. After the gate opens and before the probe starts, -LoadExe runs as `load`
     (one spinning thread per logical processor, busy -BusyMs / idle -IdleMs,
     BELOW_NORMAL_PRIORITY_CLASS, CREATE_NO_WINDOW, lpDesktop = a private
     desktop, in a kill-on-close job owned by this runner). Its bursts go to
     <side>-p<k>.load\bursts.txt (QPC). When the probe ends: stop file, then, if
     it has not exited within 5 s, TerminateProcess on the exact handle this
     runner created (PID and creation time logged).
  6. During key playback: base and current priority of every thread of the
     driver, noctty, the load and the watchdog (Snap, NtQuerySystemInformation)
     and each one's priority class, into <side>-p<k>.load\prio.txt.
  The probe runs through Start-Process (stdout + stderr into the same
  <side>-p<k>.probe.txt afterwards) so the runner can sample priorities.
#>
[CmdletBinding()]
param(
    [string[]] $Measurement = @('lat02'),
    [int] $Pairs = 20,
    [string] $A = (Join-Path $env:TEMP 'w14\notrun\builds\main-cur-rf-lt\bin'),
    [string] $ALabel = 'main-cur',
    [string] $B = (Join-Path $env:TEMP 'w14\notrun\builds\pacing-cur-rf-lt\bin'),
    [string] $BLabel = 'pacing-cur',
    [Parameter(Mandatory)] [string] $Name,
    [string] $OutRoot = (Join-Path $env:TEMP 'w14\pacing-stall2\runs'),
    [switch] $Alternate,
    [int] $QuietBelowPct = 25,
    [int] $QuietSeconds = 10,
    [datetime] $Deadline = (Get-Date).AddHours(3),
    [ValidateSet('BelowNormal','Normal','AboveNormal','Idle')] [string] $Priority = 'Idle',
    [Parameter(Mandatory)] [string] $LoadExe,
    [int] $BusyMs = 2000,
    [int] $IdleMs = 4000,
    [switch] $NoWatchdog
)
$ErrorActionPreference = 'Stop'
$Measurement = @($Measurement | ForEach-Object { $_.Split(',') })
foreach ($m in $Measurement) { if ($m -notin @('held','expose','expose-saver','saver60','lat02')) { throw "unknown measurement '$m'" } }
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$probe = Join-Path $here 'probe-load.ps1'
$metrics = Join-Path $here 'analyze\metrics.py'
$report = Join-Path $here 'analyze\report.py'
$watchdog = Join-Path $root 'watchdog.ps1'
$python = (Get-Command python.exe).Source
$pwshExe = (Get-Command pwsh.exe).Source
$dll = Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Filter 'StallWatch-*.dll' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Add-Type -Path $dll.FullName
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class W14Load {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime, jobTime; public uint flags; public UIntPtr minWorking, maxWorking;
        public uint activeProcesses; public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits { public BasicLimits basic; public IoCounters io; public UIntPtr pm, jm, ppm, pjm; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr mode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a, string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int t, ref JobLimits l, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern uint GetPriorityClass(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] public static extern bool GetProcessTimes(IntPtr h, out long c, out long e, out long k, out long u);
    public static IntPtr KillOnCloseJob() {
        var j = CreateJobObjectW(IntPtr.Zero, null); if (j == IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var l = new JobLimits(); l.basic.flags = 0x2000;
        if (!SetInformationJobObject(j, 9, ref l, (uint)Marshal.SizeOf(typeof(JobLimits)))) { CloseHandle(j); throw new Exception("job limit failed"); }
        return j;
    }
    // CREATE_SUSPENDED, assigned to the job, then resumed; lpDesktop must be WinSta0\<private>.
    public static ProcessInfo Launch(string exe, string args, string desktop, IntPtr job, uint flags) {
        if (String.IsNullOrEmpty(desktop) || !desktop.StartsWith("WinSta0\\")) throw new Exception("explicit WinSta0\\<desktop> required");
        var s = new Startup(); s.cb = Marshal.SizeOf(typeof(Startup)); s.desktop = desktop; s.flags = 1; s.show = 0; ProcessInfo p;
        if (!CreateProcessW(exe, new StringBuilder("\"" + exe + "\" " + args), IntPtr.Zero, IntPtr.Zero, false, flags | 0x4, IntPtr.Zero, null, ref s, out p))
            throw new Exception("CreateProcess failed " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, p.process) || ResumeThread(p.thread) == 0xFFFFFFFF) { TerminateProcess(p.process, 1); CloseHandle(p.thread); CloseHandle(p.process); throw new Exception("assign/resume failed"); }
        return p;
    }
    public static long Created(IntPtr h) { long c, e, k, u; return GetProcessTimes(h, out c, out e, out k, out u) ? c : 0; }
    public static string ClassOf(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return "?";
        try { uint c = GetPriorityClass(h); return "0x" + c.ToString("X"); } finally { CloseHandle(h); }
    }
}
'@
function Prio-Line([string]$role, [uint32]$procId) {
    if (-not $procId) { return "$role pid=? (not found)" }
    $sn = [W14Stall.Snap]::Take($procId); $pr = $sn.P[$procId]
    if (-not $pr -or -not $pr.Threads) { return "$role pid=$procId gone" }
    $hist = $pr.Threads | Group-Object BasePrio | Sort-Object { [int]$_.Name } -Descending | ForEach-Object { '{0}x{1}' -f $_.Name, $_.Count }
    $cur = $pr.Threads | Group-Object Prio | Sort-Object { [int]$_.Name } -Descending | ForEach-Object { '{0}x{1}' -f $_.Name, $_.Count }
    return ('{0} {1}:{2} class={3} threads={4} base_prio[{5}] cur_prio[{6}]' -f $role, $pr.Name, $procId, [W14Load]::ClassOf($procId), $pr.Threads.Count, ($hist -join ' '), ($cur -join ' '))
}
if (-not (Test-Path -LiteralPath $LoadExe)) { throw "no load exe $LoadExe" }

function Assert-TraceBuild([string]$Bin) {
    $exe = Join-Path $Bin 'noctty.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "no noctty.exe in $Bin" }
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
    if (-not $text.Contains('NOCTTY_LATENCY_TRACE_FILE') -or -not $text.Contains('NOCTTY_LAT_VSYNC_HZ')) { throw "$Bin is not a trace-patched build" }
}
Assert-TraceBuild $A
Assert-TraceBuild $B

$spec = @{
    'held'         = @{ Tool='held'; A1=200; A2=10; VsyncHz=60; InvalidateMs=0;  Extra=@() }
    'expose'       = @{ Tool='held'; A1=200; A2=10; VsyncHz=0;  InvalidateMs=50; Extra=@() }
    'expose-saver' = @{ Tool='held'; A1=200; A2=10; VsyncHz=0;  InvalidateMs=50; Extra=@('--power-saver-rendering=on') }
    'saver60'      = @{ Tool='anim'; A1=60;  A2=10; VsyncHz=60; InvalidateMs=0;  Extra=@('--power-saver-rendering=on') }
    'lat02'        = @{ Tool='echo'; DelayMs=0; Mode='ssh'; Pattern='steady'; Count=240; Style='plain'; VsyncHz=60; Extra=@() }
}

$batch = Join-Path $OutRoot $Name
if (Test-Path -LiteralPath $batch) { throw "batch dir exists: $batch" }
[void](New-Item -ItemType Directory -Force -Path $batch)
$order = if ($Alternate) { 'ABBA' } else { 'ABAB' }
[ordered]@{ Sides=@{ A=$ALabel; B=$BLabel }; Bins=@{ A=$A; B=$B }; Measurements=$Measurement; Pairs=$Pairs; Order=$order;
    Validation=$false; Priority=$Priority; LoadExe=$LoadExe; BusyMs=$BusyMs; IdleMs=$IdleMs; QuietBelowPct=$QuietBelowPct; QuietSeconds=$QuietSeconds; Watchdog=(-not $NoWatchdog);
    Started=(Get-Date).ToString('o'); RunnerPid=$PID } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $batch 'batch.json')
$logFile = Join-Path $batch 'runner.log'
$quietLog = Join-Path $batch 'quiet.log'
function Say([string]$m) { $line = "{0:HH:mm:ss} {1}" -f (Get-Date), $m; Add-Content -LiteralPath $logFile -Value $line; Write-Host $line }
function QSay([string]$m) { Add-Content -LiteralPath $quietLog -Value ("{0} {1:HH:mm:ss.fff} {2}" -f [Diagnostics.Stopwatch]::GetTimestamp(), (Get-Date), $m) }

$buildNames = @('zig.exe','cl.exe','link.exe','lld-link.exe','clang.exe','clang++.exe','clang-cl.exe','rustc.exe','cargo.exe','msbuild.exe','MSBuild.exe','cmake.exe','ninja.exe')
$buildSeen = @{}
function Check-Builds([object]$snap, [string]$where) {
    foreach ($p in $snap.P.Values) {
        if ($buildNames -notcontains $p.Name) { continue }
        $key = '{0}-{1}' -f $p.Pid, $p.Create
        if ($buildSeen.ContainsKey($key)) { continue }
        $buildSeen[$key] = $true
        $parent = $snap.P[$p.Ppid]
        $msg = 'BUILD PROCESS {0} pid={1} ppid={2} parent={3} created={4:o} seen_at={5}' -f $p.Name, $p.Pid, $p.Ppid, $(if ($parent) { $parent.Name } else { '?' }), [datetime]::FromFileTime($p.Create), $where
        Say $msg; QSay $msg
    }
}
$snap0 = [W14Stall.Snap]::Take(0)
foreach ($p in $snap0.P.Values) { if ($buildNames -contains $p.Name) { $buildSeen['{0}-{1}' -f $p.Pid, $p.Create] = $true; QSay ('build tool already running at batch start: {0} pid={1}' -f $p.Name, $p.Pid) } }

function SysTimes { $i = 0L; $k = 0L; $u = 0L; [void][W14Stall.N]::GetSystemTimes([ref]$i, [ref]$k, [ref]$u); return @($i, $k, $u) }
function Wait-Quiet([string]$label) {
    $t0 = Get-Date; $ok = 0; $n = 0; $max = 0.0
    QSay "wait start for $label (need $QuietSeconds consecutive 1 s samples under $QuietBelowPct%)"
    $prevSnap = [W14Stall.Snap]::Take(0); $prevT = SysTimes
    while ($true) {
        if ((Get-Date) -ge $Deadline) { QSay "DEADLINE reached while waiting for $label"; return $null }
        Start-Sleep -Milliseconds 1000
        $t = SysTimes; $idle = $t[0] - $prevT[0]; $tot = ($t[1] - $prevT[1]) + ($t[2] - $prevT[2]); $prevT = $t
        $busy = if ($tot -le 0) { 0 } else { 100.0 * (1 - $idle / $tot) }
        $snap = [W14Stall.Snap]::Take(0); $tc = 0.0
        $top = [W14Stall.Snap]::Top($prevSnap, $snap, 3, [ref]$tc, 0); $prevSnap = $snap
        Check-Builds $snap "wait:$label"
        $n++
        if ($busy -lt $QuietBelowPct) { $ok++; QSay ('sample busy={0:n0}% ok={1} | {2}' -f $busy, $ok, $top) }
        else { if ($busy -gt $max) { $max = $busy }; $ok = 0; QSay ('sample busy={0:n0}% OVER | {1}' -f $busy, $top) }
        if ($ok -ge $QuietSeconds) { $s = ((Get-Date) - $t0).TotalSeconds; QSay ('wait end for {0}: {1:n0} s, {2} samples, max over-bar {3:n0}%' -f $label, $s, $n, $max); return ('quiet after {0:n0} s' -f $s) }
    }
}

Say ("batch {0}: A={1} ({2}) B={3} ({4}) pairs={5} order={6} gate=<{7}% for {8} s deadline={9:HH:mm} watchdog={10}" -f $Name,$ALabel,$A,$BLabel,$B,$Pairs,$order,$QuietBelowPct,$QuietSeconds,$Deadline,(-not $NoWatchdog))
$stop = $false
foreach ($m in $Measurement) {
    if ($stop) { break }
    $s = $spec[$m]
    $mdir = Join-Path $batch $m
    [void](New-Item -ItemType Directory -Force -Path $mdir)
    for ($p = 1; $p -le $Pairs -and -not $stop; $p++) {
        $sides = @('A','B'); if ($Alternate -and ($p % 2 -eq 0)) { $sides = @('B','A') }
        foreach ($side in $sides) {
            $bin = if ($side -eq 'A') { $A } else { $B }
            $run = Join-Path $mdir "$side-p$p"
            $probeArgs = @('-NoProfile','-NonInteractive','-File',$probe,'-Bin',$bin,'-Run',$run,'-Tool',$s.Tool,'-VsyncHz',$s.VsyncHz)
            if ($s.Tool -eq 'echo') {
                $probeArgs += @('-DelayMs',$s.DelayMs,'-Mode',$s.Mode,'-Pattern',$s.Pattern,'-Count',$s.Count,'-Style',$s.Style,'-Seed',($p * 100))
            } else {
                $probeArgs += @('-A1',$s.A1,'-A2',$s.A2,'-InvalidateMs',$s.InvalidateMs)
            }
            if ($s.Extra.Count -gt 0) { $probeArgs += @('-Extra',$s.Extra[0]) }
            $probeArgs += @('-Priority',$Priority)
            $wd = $null; $wdDir = Join-Path $mdir "$side-p$p.wd"; $wdStop = Join-Path $wdDir 'stop'
            if (-not $NoWatchdog) {
                [void](New-Item -ItemType Directory -Force -Path $wdDir)
                $wdArgs = @('-NoProfile','-NonInteractive','-File',$watchdog,'-RunDir',$run,'-BuildBin',$bin,'-WrapperPid',$PID,'-OutDir',$wdDir,'-StopFile',$wdStop)
                $wd = Start-Process -FilePath $pwshExe -ArgumentList $wdArgs -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $wdDir 'wd.out') -RedirectStandardError (Join-Path $wdDir 'wd.err')
            }
            $gate = Wait-Quiet "$m $side-p$p"
            if (-not $gate) {
                Say "DEADLINE: stopping before $m $side-p$p (gate never met)"
                if ($wd) { Set-Content -LiteralPath $wdStop -Value 'stop'; [void]$wd.WaitForExit(30000) }
                $stop = $true; break
            }
            Check-Builds ([W14Stall.Snap]::Take(0)) "before:$m $side-p$p"
            # --- injected load: start after the gate, before the probe (so before the first key) ---
            $ldDir = Join-Path $mdir "$side-p$p.load"; [void](New-Item -ItemType Directory -Force -Path $ldDir)
            $prioFile = Join-Path $ldDir 'prio.txt'; $ldStop = Join-Path $ldDir 'stop'
            $ldDeskName = 'w14-load-' + [guid]::NewGuid().ToString('N')
            $ldDesk = [W14Load]::CreateDesktopW($ldDeskName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
            if ($ldDesk -eq [IntPtr]::Zero) { throw 'load CreateDesktop failed' }
            $ldJob = [W14Load]::KillOnCloseJob()
            $ldArgs = ('load "{0}" "{1}" 180 {2} {3}' -f (Join-Path $ldDir 'bursts.txt'), $ldStop, $BusyMs, $IdleMs)
            # BELOW_NORMAL_PRIORITY_CLASS | CREATE_NO_WINDOW
            $ld = [W14Load]::Launch($LoadExe, $ldArgs, "WinSta0\$ldDeskName", $ldJob, [uint32]0x08004000)
            $ldCreated = [W14Load]::Created($ld.process)
            $ldLine = ('load pid={0} name={1} created={2:o} class=0x{3:X} desktop={4}' -f $ld.pid, (Split-Path -Leaf $LoadExe), [datetime]::FromFileTime($ldCreated), [W14Load]::GetPriorityClass($ld.process), $ldDeskName)
            Set-Content -LiteralPath $prioFile -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $ldLine)
            $t0 = Get-Date
            $probeOutFile = Join-Path $mdir "$side-p$p.probe.txt"
            $pp = Start-Process -FilePath $pwshExe -ArgumentList $probeArgs -NoNewWindow -PassThru -RedirectStandardOutput $probeOutFile -RedirectStandardError (Join-Path $mdir "$side-p$p.probe.err.txt")
            $ppHandle = $pp.Handle
            $prioDone = 0; $surfaceAt = $null
            while (-not $pp.WaitForExit(250)) {
                if ($prioDone -ge 2) { continue }
                $drvLog = Join-Path $run 'driver.log'
                if (-not $surfaceAt -and (Test-Path -LiteralPath $drvLog) -and (Select-String -LiteralPath $drvLog -Pattern 'surface=0x' -Quiet)) { $surfaceAt = Get-Date }
                # keys start ~3 s after the surface; sample at +6 s and +16 s (inside playback)
                $due = if ($surfaceAt) { $surfaceAt.AddSeconds($(if ($prioDone -eq 0) { 6 } else { 16 })) } else { $null }
                if ($due -and (Get-Date) -ge $due) {
                    $drvPid = 0; $nocPid = 0
                    $om = [regex]::Match((Get-Content -LiteralPath (Join-Path $run 'outer.log') -Raw -ErrorAction SilentlyContinue), 'driver pid=(\d+)'); if ($om.Success) { $drvPid = [uint32]$om.Groups[1].Value }
                    $dm = [regex]::Match((Get-Content -LiteralPath $drvLog -Raw -ErrorAction SilentlyContinue), 'noctty pid=(\d+)'); if ($dm.Success) { $nocPid = [uint32]$dm.Groups[1].Value }
                    $lines = @(("{0:HH:mm:ss.fff} sample {1} (surface+{2} s) qpc={3}" -f (Get-Date), ($prioDone + 1), $(if ($prioDone -eq 0) { 6 } else { 16 }), [Diagnostics.Stopwatch]::GetTimestamp()),
                        (Prio-Line 'driver' $drvPid), (Prio-Line 'noctty' $nocPid), (Prio-Line 'load' ([uint32]$ld.pid)), (Prio-Line 'watchdog' $(if ($wd) { [uint32]$wd.Id } else { [uint32]0 })))
                    Add-Content -LiteralPath $prioFile -Value $lines
                    $prioDone++
                }
            }
            $pp.WaitForExit()
            $rc = $pp.ExitCode
            # --- stop the load: stop file, then the exact handle created above ---
            Set-Content -LiteralPath $ldStop -Value 'stop'
            if ([W14Load]::WaitForSingleObject($ld.process, 5000) -eq 0) { Add-Content -LiteralPath $prioFile -Value ("{0:HH:mm:ss.fff} load pid={1} exited on stop file" -f (Get-Date), $ld.pid) }
            else {
                $same = ([W14Load]::Created($ld.process) -eq $ldCreated)
                if ($same) { [void][W14Load]::TerminateProcess($ld.process, 1); [void][W14Load]::WaitForSingleObject($ld.process, 5000) }
                Add-Content -LiteralPath $prioFile -Value ("{0:HH:mm:ss.fff} load pid={1} did not exit in 5 s; identity_same={2}; terminated exact handle" -f (Get-Date), $ld.pid, $same)
            }
            [void][W14Load]::CloseHandle($ld.thread); [void][W14Load]::CloseHandle($ld.process); [void][W14Load]::CloseHandle($ldJob); [void][W14Load]::CloseDesktop($ldDesk)
            Get-Content -LiteralPath (Join-Path $mdir "$side-p$p.probe.err.txt") -ErrorAction SilentlyContinue | Add-Content -LiteralPath $probeOutFile
            Check-Builds ([W14Stall.Snap]::Take(0)) "after:$m $side-p$p"
            $wdSummary = ''
            if ($wd) {
                Set-Content -LiteralPath $wdStop -Value 'stop'
                if (-not $wd.WaitForExit(240000)) { Say "watchdog pid=$($wd.Id) still running 240 s after the probe (left alone)" }
                $wl = Join-Path $wdDir 'watchdog.log'
                if (Test-Path -LiteralPath $wl) {
                    $sum = Select-String -LiteralPath $wl -Pattern ' SUMMARY ' | Select-Object -Last 1
                    $wdSummary = if ($sum) { ($sum.Line -split ' SUMMARY ', 2)[1] } else { 'no SUMMARY (see watchdog.log)' }
                    if (Select-String -LiteralPath $wl -Pattern ' TRIGGER ' -Quiet) { $wdSummary += ' STACKS-TAKEN' }
                }
            }
            $probeOut = Get-Content -LiteralPath (Join-Path $mdir "$side-p$p.probe.txt") -Raw -ErrorAction SilentlyContinue
            if ($rc -ne 0) {
                Say ("FAILED {0} {1}-p{2} rc={3} ({4:n0} s) wd: {5}" -f $m,$side,$p,$rc,((Get-Date)-$t0).TotalSeconds,$wdSummary)
                if ($probeOut -match 'stop launches') { Say 'real user state guard tripped: stopping the batch'; throw "guard tripped in $run" }
                continue
            }
            $line = & $python -I $metrics $run --json (Join-Path $run 'metrics.json')
            Say ("{0} {1}-p{2} [{3}] ({4:n0} s, gate: {5}) {6} | wd: {7}" -f $m,$side,$p,$(if($side -eq 'A'){$ALabel}else{$BLabel}),((Get-Date)-$t0).TotalSeconds,$gate,($line -join ' '),$wdSummary)
        }
    }
}
& $python -I $report $batch | Out-Null
Say "report: $(Join-Path $batch 'report.txt')"
