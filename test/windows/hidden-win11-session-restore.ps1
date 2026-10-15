#requires -Version 7.0
<#
Portable, hidden-desktop integration regression for session-file compatibility
and restore placement (PKG-44). Run with -Bin <source bin directory> -Run <new
evidence directory>. The run directory must not already exist. Every file the
app reads or writes is a sample this script creates beside a portable copy of
the app: the real %LOCALAPPDATA%\noctty is never written or deleted, and only
the hash and time of its startup state file are read, before and after. Never switches desktops,
injects real input or registers a global hotkey, and nothing it does can copy (the
clipboard belongs to the window station, not the desktop); the clipboard sequence number is logged
before and after and a change fails the run. Optional
ExpectedStartupHash/ExpectedStartupModified pin an adopted baseline.
DriverTimeoutSeconds bounds the hidden driver and its owned process job.
Results contain only window geometry, process IDs, file hashes and assertions.
It exits 1 when a check fails, so it can be run against a build that still has
the problems to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 420,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Sr {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public class State { public Rect Rect; public uint Dpi; public bool Visible,Iconic,Zoomed; }
    [StructLayout(LayoutKind.Sequential)] struct MonInfo { public int cb; public Rect monitor, work; public uint flags; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    delegate bool EnumMonitor(IntPtr m, IntPtr dc, ref Rect r, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumMonitor cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr m, ref MonInfo info);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action,uint param,out Rect value,uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job,int type,ref JobLimits limits,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr job,int type,out JobAccounting accounting,uint size,IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime,kernelTime,periodUserTime,periodKernelTime;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime,jobTime; public uint flags;
        public UIntPtr minWorking,maxWorking; public uint activeProcesses;
        public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io;
        public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    public static IntPtr CreateOwnedJob() {
        var job=CreateJobObjectW(IntPtr.Zero,null);
        if(job==IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var limits=new JobLimits(); limits.basic.flags=0x2000; // KILL_ON_JOB_CLOSE
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<JobLimits>())) {
            CloseHandle(job); throw new Exception("SetInformationJobObject failed");
        }
        return job;
    }
    public static uint StopOwnedJob(IntPtr job) {
        try {
            if(!TerminateJobObject(job,1)) throw new Exception("Terminate owned job failed");
            var deadline=DateTime.UtcNow.AddSeconds(5);
            do {
                JobAccounting accounting;
                if(!QueryInformationJobObject(job,1,out accounting,(uint)Marshal.SizeOf<JobAccounting>(),IntPtr.Zero))
                    throw new Exception("Query owned job failed");
                if(accounting.activeProcesses==0) return accounting.totalProcesses;
                System.Threading.Thread.Sleep(10);
            } while(DateTime.UtcNow<deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(job); }
    }
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") list.Add(h); return true;
        },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr[] Surfaces(IntPtr host) {
        var list=new List<IntPtr>();
        EnumChildWindows(host,(c,p)=> { if(Class(c)=="noctty.win32") list.Add(c); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static Rect PrimaryWork() {
        Rect r; if(!SystemParametersInfoW(0x30,0,out r,0)) throw new Exception("SPI_GETWORKAREA failed"); return r;
    }
    // The work area of every monitor, in the physical pixels the app uses.
    public static Rect[] Works() {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            var list=new List<Rect>();
            EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr m,IntPtr dc,ref Rect r,IntPtr p)=> {
                var info=new MonInfo { cb=Marshal.SizeOf<MonInfo>() };
                if(GetMonitorInfoW(m,ref info)) list.Add(info.work);
                return true;
            },IntPtr.Zero);
            return list.ToArray();
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static State Read(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r;
            if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed");
            return new State { Rect=r,Dpi=GetDpiForWindow(h),Visible=IsWindowVisible(h),Iconic=IsIconic(h),Zoomed=IsZoomed(h) };
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static void Move(IntPtr h,int x,int y,int w,int ht) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { if(!SetWindowPos(h,IntPtr.Zero,x,y,w,ht,0x14)) throw new Exception("SetWindowPos failed"); }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        // Assign the suspended driver before it can spawn children. The job
        // owns only this launch and its descendants, including terminal shells.
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08004004,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,pi.process)||ResumeThread(pi.thread)==0xFFFFFFFF) {
            TerminateProcess(pi.process,1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume owned driver failed");
        }
        return pi;
    }
}
'@
function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}
if (-not $Driver) {
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Source Bin must contain noctty.exe.' }
    $before = Startup-Fingerprint
    $clipboardBefore = [Sr]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-sr-' + [guid]::NewGuid().ToString('N')
    $desktop = [Sr]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero
    try {
        $job=[Sr]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver' -f $pwsh,$PSCommandPath,(Join-Path $Run 'source\bin'),$Run
        $pi=[Sr]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Sr]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$code=0; [void][Sr]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Sr]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Sr]::CloseHandle($pi.thread); [void][Sr]::CloseHandle($pi.process) }
        [void][Sr]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $clipboardAfter=[Sr]::GetClipboardSequenceNumber()
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{ Before=$before; After=$after; Unchanged=$unchanged; OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount; ClipboardSequenceBefore=$clipboardBefore; ClipboardSequenceAfter=$clipboardAfter } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($clipboardBefore -ne $clipboardAfter) { throw "Clipboard sequence number changed ($clipboardBefore -> $clipboardAfter); stop launches and report it." }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden session restore: PASS'
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Sr]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
function Rect-Array($r) { return @($r.Left,$r.Top,$r.Right,$r.Bottom) }
function Rect-Same($a,$b,[int]$Tolerance=2) {
    return [Math]::Abs($a.Left-$b.Left) -le $Tolerance -and [Math]::Abs($a.Top-$b.Top) -le $Tolerance -and [Math]::Abs($a.Right-$b.Right) -le $Tolerance -and [Math]::Abs($a.Bottom-$b.Bottom) -le $Tolerance
}
function Inside-AWork($r,$works) {
    foreach($w in $works) { if($r.Left -ge $w.Left -and $r.Top -ge $w.Top -and $r.Right -le $w.Right -and $r.Bottom -le $w.Bottom) { return $true } }
    return $false
}
function Sample([string]$Name,$h) { $s=[Sr]::Read($h); $script:samples.Add(@{Name=$Name; State=$s}); return $s }
function Hash-Of([string]$Path) { if(Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } return $null }
function Siblings([string]$Dir,[string]$Pattern) { return @(Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction SilentlyContinue | ForEach-Object Name) }

# A sample session this script writes itself: one window of one tab and one
# pane, with fields a later build might add at every level.
function Session-Json($x,$y,$w,$h,[string]$State,[string]$Cwd,[bool]$Extra) {
    $pane = @{ cwd=$Cwd }
    $window = @{ selected_tab=0; tabs=@(@{ selected_leaf=0; layout=@{ root=0; nodes=@(@{ pane=$pane }) } }) }
    if($null -ne $x) { $window.x=$x; $window.y=$y; $window.width=$w; $window.height=$h; $window.state=$State }
    $doc = @{ schema_version=1; windows=@($window) }
    if($Extra) {
        $doc.added_later=@{ generation=7 }
        $window.monitor='\\.\DISPLAY9'
        $window.tabs[0].pinned=$true
        $window.tabs[0].layout.hint='grid'
        $pane.env=@{ A='b' }
    }
    return ($doc | ConvertTo-Json -Depth 12 -Compress)
}

function New-Case([string]$Name,[hashtable]$Files,[string]$Extra='') {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    foreach($relative in $Files.Keys) {
        $target=Join-Path $dir $relative
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target))
        Set-Content -LiteralPath $target -Value $Files[$relative] -NoNewline -Encoding utf8NoBOM
    }
    $config=Join-Path $dir 'session.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false','window-save-state = always','confirm-close-surface = false',$Extra) | Set-Content -LiteralPath $config
    return @{ Name=$Name; Dir=$dir; Config=$config }
}
function Start-Case($case,[switch]$NoLedgerWait) {
    $exe=Join-Path $case.Dir 'noctty.exe'
    $p=Start-Process -FilePath $exe -ArgumentList @("--config-file=`"$($case.Config)`"") -WorkingDirectory $case.Dir -WindowStyle Hidden -PassThru
    $script:processes.Add(@{Case=$case.Name;Pid=$p.Id;StartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.ProcessName})
    $case.Process=$p
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    do {
        $hosts=@([Sr]::Hosts($p.Id))
        $ready=$NoLedgerWait.IsPresent
        $ledger=Join-Path $case.Dir 'startup-attempts.json'
        if(-not $ready -and (Test-Path -LiteralPath $ledger)) {
            try {
                $attempts=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready=$attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if($ready -and $hosts.Count -and @([Sr]::Surfaces($hosts[0])).Count -gt 0) {
            Start-Sleep -Milliseconds 600
            $case.Host=$hosts[0]
            return $case
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline -and -not $p.HasExited)
    # The startup failure is the finding; a cleanup error must not hide it.
    $cleanup=$null
    try { Stop-Case $case } catch { $cleanup=$_.Exception.Message }
    throw "Window startup failed for case $($case.Name).$(if($cleanup){" Cleanup: $cleanup"})"
}
function Stop-Case($case) {
    foreach($h in [Sr]::Hosts($case.Process.Id)) { [void][Sr]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if(-not $case.Process.WaitForExit(8000)) {
        $p=Get-Process -Id $case.Process.Id -ErrorAction SilentlyContinue
        if(-not $p) { return }   # It exited between the wait and the lookup.
        if($p.StartTime -eq $case.Process.StartTime -and $p.Path -eq $case.Process.Path) { Stop-Process -Id $p.Id -Force }
        else { throw 'Exact process identity changed during cleanup.' }
    }
}
try {
    $work=[Sr]::PrimaryWork()
    $works=@([Sr]::Works())
    $script:samples.Add(@{Name='work-areas'; State=@($works | ForEach-Object { ,(Rect-Array $_) })})

    # G037: a session a newer build wrote is left exactly as it was.
    $newerSession='{"schema_version":2,"windows":[{"layout_v2":{"zones":[1,2]}}],"future":true}'
    $case=New-Case 'newer-session' @{ 'session-state.json'=$newerSession }
    $path=Join-Path $case.Dir 'session-state.json'
    $hashBefore=Hash-Of $path
    $case=Start-Case $case
    try { [void](Sample 'newer-session-window' $case.Host) } finally { Stop-Case $case }
    Check 'newer-schema session untouched by a launch and a close' ((Hash-Of $path) -eq $hashBefore) $hashBefore (Hash-Of $path)
    Check 'newer-schema session not quarantined' ((Siblings $case.Dir 'session-state.json.corrupt*').Count -eq 0) 0 (Siblings $case.Dir 'session-state.json.corrupt*')

    # G037: a field this build does not know does not lose the session.
    $cwd=(Join-Path $Run 'added-field\bin')
    $savedX=$work.Left+200; $savedY=$work.Top+150
    $case=New-Case 'added-field' @{ 'session-state.json'=(Session-Json $savedX $savedY 900 600 'normal' $cwd $true) }
    $case=Start-Case $case
    try {
        $state=Sample 'added-field-restored' $case.Host
        Check 'session with added fields restored at its saved rect' (Rect-Same $state.Rect ([pscustomobject]@{Left=$savedX;Top=$savedY;Right=$savedX+900;Bottom=$savedY+600})) @($savedX,$savedY,($savedX+900),($savedY+600)) (Rect-Array $state.Rect)
        Check 'session with added fields not quarantined' ((Siblings $case.Dir 'session-state.json.corrupt*').Count -eq 0) 0 (Siblings $case.Dir 'session-state.json.corrupt*')

        # F044: maximized, the file records the rect it un-maximizes to, in
        # screen coordinates, and that it restores to maximized.
        $moveX=$work.Left+260; $moveY=$work.Top+210
        [Sr]::Move($case.Host,$moveX,$moveY,800,560); Start-Sleep -Milliseconds 400
        $normal=Sample 'added-field-moved' $case.Host
        [void][Sr]::ShowWindow($case.Host,3)   # SW_MAXIMIZE
        Start-Sleep -Milliseconds 600
        Check 'window maximized' ([Sr]::Read($case.Host)).Zoomed $true ([Sr]::Read($case.Host)).Zoomed
    } finally { Stop-Case $case }
    $saved=Get-Content -LiteralPath (Join-Path $case.Dir 'session-state.json') -Raw | ConvertFrom-Json
    $w=$saved.windows[0]
    Check 'saved normal rect of a maximized window is its screen rect' ($null -ne $w.x -and (Rect-Same ([pscustomobject]@{Left=$w.x;Top=$w.y;Right=$w.x+$w.width;Bottom=$w.y+$w.height}) $normal.Rect)) (Rect-Array $normal.Rect) @($w.x,$w.y,($w.x+$w.width),($w.y+$w.height))
    Check 'saved state is maximized' ($w.state -eq 'maximized') 'maximized' $w.state
    Check 'saved file carries the current schema only' ($saved.schema_version -eq 1 -and $null -eq $saved.added_later) 1 $saved.schema_version

    # F044: a window saved where no monitor is comes back on one.
    $case=New-Case 'missing-monitor' @{ 'session-state.json'=(Session-Json 30000 30000 700 500 'normal' (Join-Path $Run 'missing-monitor\bin') $false) }
    $case=Start-Case $case
    try {
        $state=Sample 'missing-monitor-restored' $case.Host
        Check 'window saved on a missing monitor is inside a work area' (Inside-AWork $state.Rect $works) 'inside a work area' (Rect-Array $state.Rect)
        Check 'window saved on a missing monitor keeps its size, whatever the DPI of the monitor it lands on' ((($state.Rect.Right-$state.Rect.Left) -eq 700) -and (($state.Rect.Bottom-$state.Rect.Top) -eq 500)) @(700,500) @(($state.Rect.Right-$state.Rect.Left),($state.Rect.Bottom-$state.Rect.Top))
    } finally { Stop-Case $case }

    # F044: a window saved on a monitor other than the one the host is created
    # on (the primary) comes back at exactly its saved rect, not rescaled by
    # the DPI difference between the two.
    $others=@($works | Where-Object { $_.Left -ne $work.Left -or $_.Top -ne $work.Top })
    if($others.Count -gt 0) {
        $other=$others[0]; $ox=$other.Left+100; $oy=$other.Top+100
        $case=New-Case 'other-monitor' @{ 'session-state.json'=(Session-Json $ox $oy 900 600 'normal' (Join-Path $Run 'other-monitor\bin') $false) }
        $case=Start-Case $case
        try {
            $state=Sample 'other-monitor-restored' $case.Host
            Check 'window saved on another monitor comes back at its saved rect' (Rect-Same $state.Rect ([pscustomobject]@{Left=$ox;Top=$oy;Right=$ox+900;Bottom=$oy+600})) @($ox,$oy,($ox+900),($oy+600)) (Rect-Array $state.Rect)
        } finally { Stop-Case $case }
    }

    $case=New-Case 'missing-monitor-maximized' @{ 'session-state.json'=(Session-Json (-30000) (-30000) 700 500 'maximized' (Join-Path $Run 'missing-monitor-maximized\bin') $false) }
    $case=Start-Case $case
    try {
        $state=Sample 'missing-monitor-maximized-restored' $case.Host
        Check 'window saved maximized is maximized' $state.Zoomed $true $state.Zoomed
        [void][Sr]::ShowWindow($case.Host,9)   # SW_RESTORE
        Start-Sleep -Milliseconds 600
        $normal=Sample 'missing-monitor-maximized-unmaximized' $case.Host
        Check 'un-maximizing goes to a rect inside a work area' ((-not $normal.Zoomed) -and (Inside-AWork $normal.Rect $works)) 'normal, inside a work area' @{Zoomed=$normal.Zoomed; Rect=(Rect-Array $normal.Rect)}
    } finally { Stop-Case $case }

    # F044: Windows caps what it is given (a left edge to 16 bits, a width to the
    # largest window), so a rect that spans every monitor as saved can be off
    # all of them once placed. It must be judged on what the window ends up as.
    $case=New-Case 'extreme-rect' @{ 'session-state.json'=(Session-Json (-2000000000) ($work.Top+50) 2100000000 480 'normal' (Join-Path $Run 'extreme-rect\bin') $false) }
    $case=Start-Case $case
    try {
        $state=Sample 'extreme-rect-restored' $case.Host
        Check 'window saved with an extreme rect ends up on a monitor' (Inside-AWork $state.Rect $works) 'inside a work area' (Rect-Array $state.Rect)
    } finally { Stop-Case $case }

    # G037: a recovery ledger a newer build wrote is not counted and not replaced.
    $newerLedger='{"schema_version":2,"attempts":[{"started_at_unix_ms":100,"phase":"init"}],"future":1}'
    $case=New-Case 'newer-ledger' @{ 'startup-attempts.json'=$newerLedger }
    $ledger=Join-Path $case.Dir 'startup-attempts.json'
    $hashBefore=Hash-Of $ledger
    $case=Start-Case $case -NoLedgerWait
    try { [void](Sample 'newer-ledger-window' $case.Host) } finally { Stop-Case $case }
    Check 'newer-schema ledger untouched by a launch and a close' ((Hash-Of $ledger) -eq $hashBefore) $hashBefore (Hash-Of $ledger)

    # G037: the shell integration script a newer build installed is kept, and
    # one an older build left is replaced. Ordered by the revision it declares.
    $newerScript="# noctty-integration-revision: 9999`n# installed by a newer build`n"
    $case=New-Case 'script-newer' @{ 'shell-integration\powershell\integration.ps1'=$newerScript }
    $script=Join-Path $case.Dir 'shell-integration\powershell\integration.ps1'
    $case=Start-Case $case
    try { } finally { Stop-Case $case }
    Check 'integration.ps1 from a newer build kept' ((Get-Content -LiteralPath $script -Raw) -eq $newerScript) $newerScript ((Get-Content -LiteralPath $script -Raw).Length)
    Check 'no temporary integration copy left behind' ((Siblings (Split-Path -Parent $script) '*.tmp').Count -eq 0) 0 (Siblings (Split-Path -Parent $script) '*.tmp')

    $case=New-Case 'script-older' @{ 'shell-integration\powershell\integration.ps1'="# noctty-integration-revision: 0`n# installed by an older build`n" }
    $script=Join-Path $case.Dir 'shell-integration\powershell\integration.ps1'
    $case=Start-Case $case
    try { } finally { Stop-Case $case }
    Check 'integration.ps1 from an older build replaced' ((Get-Item -LiteralPath $script).Length -gt 1000) 'embedded script' (Get-Item -LiteralPath $script).Length
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Win32 window state on a never-switched desktop with sample session files written by this script; real pointer, shell input, a top or left taskbar and a removed monitor are not exercised (a missing monitor is a rect where none is).'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'session-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){exit 1}
