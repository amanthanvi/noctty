#requires -Version 7.0
<#
MEASUREMENT ONLY: one renderer scratch run of noctty on a private desktop.

Reconstructed from the committed LAT-01/LAT-02/PKG-37 drivers
(origin/pkg37-measurement-harness 39d1ec0c0: lat02-harness/lat-driver3.ps1
and pkg37-harness/anim-probe.ps1). The two drivers are merged here: -Tool echo
is lat-driver3.ps1 (lat-echo.exe plus posted keys), -Tool held / anim is
anim-probe.ps1 (held.exe or anim.exe, optional expose every -InvalidateMs).
Everything the drivers measured is unchanged: noctty's latency trace (the
measurement-only patch, NOCTTY_LATENCY_TRACE_FILE, NOCTTY_LAT_VSYNC_HZ),
QPC-stamped key posts, the same noctty flags, the same waits.

Outer mode (no -Driver), on the user's desktop, shows nothing:
  * guards before and after: the real startup-attempts.json (hash + mtime),
    the real %LOCALAPPDATA%\noctty top-level files, noctty's jump list file in
    the real CustomDestinations folder, the AUMID registration key's
    last-write time, GetClipboardSequenceNumber, and the PSReadLine history
    metadata (scripts/windows-harness-history.ps1, copied from main 576cdadf3);
    any change throws "stop launches";
  * a NEW run directory: a portable copy (.exe/.dll only, no noctty.ico, plus
    noctty.portable), LOCALAPPDATA and APPDATA redirected into it;
  * CreateDesktopW, then this script again with -Driver on that desktop
    (lpDesktop = WinSta0\<desktop>, CREATE_NO_WINDOW, BELOW_NORMAL as the
    original driver), in an owned kill-on-close job.
Driver mode, on the private desktop: starts noctty with lpDesktop set, posts
WM_KEYDOWN/WM_KEYUP pairs (never SendInput), asks noctty to dump its trace,
then stops its own job after logging every PID in it (name, parent, start
time). Nothing touches the clipboard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [ValidateSet('echo','held','anim')] [string] $Tool = 'echo',
    [string] $ToolDir = (Join-Path $env:TEMP 'w14\notrun\builds\helpers\bin'),
    # echo: DelayMs/Mode/Pattern/Count/Seed/Style as lat-driver3.ps1.
    # held/anim: A1/A2 are the tool's two numbers, as anim-probe's DelayMs/Count
    # (held: hold_ms cycles; anim: fps seconds).
    [int] $DelayMs = 0,
    [ValidateSet('vt','records','ssh')] [string] $Mode = 'vt',
    [ValidateSet('steady','burst','cursor')] [string] $Pattern = 'steady',
    [int] $Count = 240,
    [int] $Seed = 1,
    [ValidateSet('plain','line','tui')] [string] $Style = 'plain',
    [int] $A1 = 0,
    [int] $A2 = 0,
    [int] $InvalidateMs = 0,
    [ValidateSet('bundled','inbox')] [string] $ConPty = 'bundled',
    [string[]] $Extra = @(),
    [int] $VsyncHz = 0,
    [switch] $VsyncSync,
    [int] $DriverTimeoutSeconds = 240,
    # The original drivers started the driver (and so noctty and the tool) at
    # BELOW_NORMAL, by inheritance. Normal and AboveNormal are for validation on
    # a loaded machine only: they pin the class on every process in the owned
    # jobs (JOB_OBJECT_LIMIT_PRIORITY_CLASS), noctty's children included.
    # pacing-stall2 load batch: 'Idle' keeps the driver at BelowNormal (outside
    # noctty's job, no class limit on the outer job) and pins IDLE_PRIORITY_CLASS
    # (0x40) on noctty's job only (JOB_OBJECT_LIMIT_PRIORITY_CLASS), so noctty and
    # every child it starts run at Idle class, below the injected BelowNormal load.
    [ValidateSet('BelowNormal','Normal','AboveNormal','Idle')] [string] $Priority = 'BelowNormal',
    [switch] $Driver
)
$ErrorActionPreference = 'Stop'
$DesktopPrefix = 'noctty-notrun-'
# 0 = no job class limit (BelowNormal: inherited from the driver, as the originals).
$jobClass = switch($Priority){ 'BelowNormal'{[uint32]0} 'Normal'{[uint32]0x20} 'AboveNormal'{[uint32]0x8000} 'Idle'{[uint32]0} }
# The job the driver makes for noctty: the same as the outer job, except Idle.
$innerJobClass = if($Priority -eq 'Idle') { [uint32]0x40 } else { $jobClass }
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class NrLat {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime,jobTime; public uint flags; public UIntPtr minWorking,maxWorking;
        public uint activeProcesses; public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io; public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime,kernelTime,periodUserTime,periodKernelTime;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct ProcessEntry {
        public uint size,usage,pid; public IntPtr heapId; public uint moduleId,threads,parent; public int priority; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string exe;
    }
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,int length,out int needed);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow c,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow c,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code,uint type);
    [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h,IntPtr r,IntPtr g,uint f);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll")] public static extern bool QueryPerformanceCounter(out long c);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr p,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr p,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr p);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j,int t,ref JobLimits l,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p,uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr j,uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr j,int t,out JobAccounting a,uint size,IntPtr r);
    [DllImport("kernel32.dll",EntryPoint="QueryInformationJobObject")] static extern bool QueryJobPids(IntPtr j,int t,IntPtr buf,uint size,IntPtr r);
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags,uint pid);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern bool Process32FirstW(IntPtr s,ref ProcessEntry e);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern bool Process32NextW(IntPtr s,ref ProcessEntry e);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr p,out long create,out long exit,out long kernel,out long user);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegOpenKeyExW(IntPtr root,string sub,int opts,int sam,out IntPtr key);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegQueryInfoKeyW(IntPtr k,IntPtr cls,IntPtr clsLen,IntPtr res,out int subKeys,out int maxSub,out int maxCls,out int values,out int maxName,out int maxData,out int sec,out long lastWrite);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr k);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
    // Whole-machine CPU counters (100 ns units); busy% between two reads = 1 - didle/(dkernel+duser).
    public static long[] SystemTimes() { long i,k,u; GetSystemTimes(out i,out k,out u); return new long[]{i,k,u}; }
    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min,out uint max,out uint cur);
    // Current system timer resolution in ms (another process can lower it to 1 or 0.5 ms; a
    // timer-driven present cadence depends on it).
    public static double TimerResMs() { uint a,b,c; NtQueryTimerResolution(out a,out b,out c); return c/10000.0; }
    public static double BusyPct(long[] a,long[] b) { double idle=b[0]-a[0], total=(b[1]-a[1])+(b[2]-a[2]); return total<=0?0:100.0*(1-idle/total); }
    public static IntPtr CreateOwnedJob() { return CreateOwnedJob(0); }
    // priorityClass 0 = no class limit (children inherit as usual).
    public static IntPtr CreateOwnedJob(uint priorityClass) {
        var j=CreateJobObjectW(IntPtr.Zero,null); if(j==IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var l=new JobLimits(); l.basic.flags=0x2000;
        if(priorityClass!=0) { l.basic.flags|=0x20; l.basic.priority=priorityClass; }
        if(!SetInformationJobObject(j,9,ref l,(uint)Marshal.SizeOf<JobLimits>())) { CloseHandle(j); throw new Exception("Job limit failed"); }
        return j;
    }
    // Every process in the owned job, described by exact PID, image name,
    // parent PID and creation time (FILETIME ticks). No command lines.
    public static string DescribeJob(IntPtr j) {
        int cap=256; IntPtr buf=Marshal.AllocHGlobal(8+cap*IntPtr.Size);
        try {
            if(!QueryJobPids(j,3,buf,(uint)(8+cap*IntPtr.Size),IntPtr.Zero)) return "pid-list-unavailable";
            int n=Marshal.ReadInt32(buf,4); var pids=new HashSet<uint>();
            for(int i=0;i<n;i++) pids.Add((uint)Marshal.ReadIntPtr(buf,8+i*IntPtr.Size).ToInt64());
            var sb=new StringBuilder(); var snap=CreateToolhelp32Snapshot(2,0);
            var e=new ProcessEntry(); e.size=(uint)Marshal.SizeOf<ProcessEntry>();
            if(Process32FirstW(snap,ref e)) do {
                if(!pids.Contains(e.pid)) continue;
                long created=0,x,k,u; var h=OpenProcess(0x1000,false,(int)e.pid);
                if(h!=IntPtr.Zero) { GetProcessTimes(h,out created,out x,out k,out u); CloseHandle(h); }
                sb.Append(e.pid).Append(':').Append(e.exe).Append(":ppid=").Append(e.parent).Append(":created=").Append(created).Append(":basepri=").Append(e.priority).Append(' ');
            } while(Process32NextW(snap,ref e));
            CloseHandle(snap); return sb.ToString().TrimEnd();
        } finally { Marshal.FreeHGlobal(buf); }
    }
    public static uint StopOwnedJob(IntPtr j) {
        try {
            if(!TerminateJobObject(j,1)) throw new Exception("Owned job termination failed");
            var deadline=DateTime.UtcNow.AddSeconds(5);
            do { JobAccounting a;
                if(!QueryInformationJobObject(j,1,out a,(uint)Marshal.SizeOf<JobAccounting>(),IntPtr.Zero)) throw new Exception("Owned job accounting failed");
                if(a.activeProcesses==0) return a.totalProcesses; Thread.Sleep(10);
            } while(DateTime.UtcNow<deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(j); }
    }
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,uint flags) {
        // A GUI target must not get STARTF_USESHOWWINDOW/SW_HIDE, or its first
        // ShowWindow hides it and the renderer never presents (LAT-01 trap 3).
        if(String.IsNullOrEmpty(desktop) || !desktop.StartsWith("WinSta0\\")) throw new Exception("every child needs an explicit WinSta0\\<desktop>");
        bool gui=(flags&0x80000000u)!=0; flags&=0x7FFFFFFFu;
        var s=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=gui?0:1,show=0 }; ProcessInfo p;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags|0x4,IntPtr.Zero,cwd,ref s,out p))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,p.process)||ResumeThread(p.thread)==0xFFFFFFFF) {
            TerminateProcess(p.process,1); CloseHandle(p.thread); CloseHandle(p.process); throw new Exception("Owned launch assignment/resume failed");
        }
        return p;
    }
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr Surface(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") EnumChildWindows(h,(c,q)=> { if(Class(c)=="noctty.win32") found=c; return true; },IntPtr.Zero);
            return true;
        },IntPtr.Zero); return found;
    }
    public static string DesktopName() {
        var name=new StringBuilder(256); int needed;
        if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,name,name.Capacity*2,out needed)) throw new Exception("Driver desktop identity unavailable");
        return name.ToString();
    }
    // HKCU key last-write time (FILETIME ticks) or -1 when absent. Values are never read.
    public static long KeyLastWrite(string sub) {
        IntPtr k; if(RegOpenKeyExW(new IntPtr(unchecked((int)0x80000001)),sub,0,0x20019,out k)!=0) return -1;
        try { int a,b,c,d,e,f,g; long t; if(RegQueryInfoKeyW(k,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out a,out b,out c,out d,out e,out f,out g,out t)!=0) return -2; return t; }
        finally { RegCloseKey(k); }
    }
    // One scheduled key message. Due is in Stopwatch (QPC) ticks.
    public class Ev { public long Due; public bool Down; public int Index; public int Vk; public long Posted; }
    public static void Play(IntPtr h, List<Ev> evs) {
        timeBeginPeriod(1);
        Thread.CurrentThread.Priority=ThreadPriority.Highest;
        evs.Sort((a,b)=>a.Due.CompareTo(b.Due));
        foreach(var e in evs) {
            for(;;) {
                long now=Stopwatch.GetTimestamp(); long left=e.Due-now;
                if(left<=0) break;
                long ms=left*1000/Stopwatch.Frequency;
                if(ms>=2) Thread.Sleep((int)(ms-1)); else Thread.SpinWait(50);
            }
            uint scan=MapVirtualKeyW((uint)e.Vk,0);
            long l=1L|((long)scan<<16);
            if(!e.Down) l|=0xC0000000L;
            if(e.Vk>=0x21 && e.Vk<=0x28) l|=1L<<24;
            e.Posted=Stopwatch.GetTimestamp();
            if(!PostMessageW(h,e.Down?0x100u:0x101u,new IntPtr(e.Vk),new IntPtr(l))) throw new Exception("Key post failed");
        }
    }
}
'@

function File-Fingerprint([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $i=Get-Item -LiteralPath $Path -Force
    return '{0}:{1}:{2}' -f $i.Length,$i.LastWriteTimeUtc.Ticks,(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Real-State {
    # Resolved through known folders, so the values are the real ones even
    # while LOCALAPPDATA/APPDATA are redirected for the child.
    $local=[Environment]::GetFolderPath('LocalApplicationData'); $roaming=[Environment]::GetFolderPath('ApplicationData')
    $nocttyDir=Join-Path $local 'noctty'
    $top=[ordered]@{}
    if(Test-Path -LiteralPath $nocttyDir) { Get-ChildItem -LiteralPath $nocttyDir -File -Force | Sort-Object Name | ForEach-Object { $top[$_.Name]='{0}:{1}' -f $_.Length,$_.LastWriteTimeUtc.Ticks } }
    return [ordered]@{
        StartupAttempts = File-Fingerprint (Join-Path $nocttyDir 'startup-attempts.json')
        NocttyTopFiles = ($top.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
        # noctty's product-AUMID jump list (app-lifecycle.md 2026-10-16, STANDALONE-LEAF-AUMID-01).
        JumpList = File-Fingerprint (Join-Path $roaming 'Microsoft\Windows\Recent\CustomDestinations\c2214d6ebc43ff3f.customDestinations-ms')
        AumidKeyLastWrite = [NrLat]::KeyLastWrite('Software\Classes\AppUserModelId\io.github.amanthanvi.noctty')
        ClipboardSequence = [NrLat]::GetClipboardSequenceNumber()
    }
}

if(-not $Driver) {
    . (Join-Path $PSScriptRoot 'lib\windows-harness-history.ps1')
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    # pacing-stall2 copy: the only change from notrun\scratch\probe.ps1 is this root.
    if(-not $Run.StartsWith((Join-Path $env:TEMP 'w14\pacing-stall2\runs\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Run directory must be under pacing-stall2\runs.' }
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    $toolExe=Join-Path $ToolDir $(if($Tool -eq 'echo'){'lat-echo.exe'}else{"$Tool.exe"})
    if(-not (Test-Path -LiteralPath $toolExe)) { throw "missing $toolExe" }
    $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'notrun-probe'
    $before=Real-State
    [void](New-Item -ItemType Directory -Path $Run)
    $portable=Join-Path $Run 'app\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | Where-Object { $_.Extension -in '.exe','.dll' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'app\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    Copy-Item -LiteralPath $toolExe -Destination (Join-Path $Run 'lat-echo.exe')
    foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    [ordered]@{ Bin=$Bin; Tool=$Tool; DelayMs=$DelayMs; Mode=$Mode; Pattern=$Pattern; Count=$Count; Seed=$Seed; Style=$Style;
        A1=$A1; A2=$A2; InvalidateMs=$InvalidateMs; ConPty=$ConPty; VsyncHz=$VsyncHz; VsyncSync=[bool]$VsyncSync; Extra=$Extra; Priority=$Priority } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'params.json')
    $desktopName=$DesktopPrefix+[guid]::NewGuid().ToString('N')
    $desktop=[NrLat]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $envKeys='LOCALAPPDATA','APPDATA','NOCTTY_LATENCY_TRACE_FILE','NOCTTY_RENDER_TRACE_FILE','NOCTTY_RENDER_TRACE_LIVE','NOCTTY_CONPTY','NOCTTY_LAT_VSYNC_HZ','NOCTTY_LAT_VSYNC_SYNC'
    $saved=@{}; foreach($k in $envKeys) { $saved[$k]=[Environment]::GetEnvironmentVariable($k) }
    $job=[IntPtr]::Zero; $pi=$null; $code=1; $outerLog=Join-Path $Run 'outer.log'
    try {
        $job=[NrLat]::CreateOwnedJob($jobClass)
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $env:NOCTTY_LATENCY_TRACE_FILE=Join-Path $Run 'latency.txt'
        $env:NOCTTY_RENDER_TRACE_FILE=Join-Path $Run 'render.json'; $env:NOCTTY_RENDER_TRACE_LIVE='1'
        if($ConPty -eq 'inbox') { $env:NOCTTY_CONPTY='inbox' } else { $env:NOCTTY_CONPTY=$null }
        if($VsyncHz -gt 0) { $env:NOCTTY_LAT_VSYNC_HZ="$VsyncHz" } else { $env:NOCTTY_LAT_VSYNC_HZ=$null }
        if($VsyncSync) { $env:NOCTTY_LAT_VSYNC_SYNC='1' } else { $env:NOCTTY_LAT_VSYNC_SYNC=$null }
        $pwsh=(Get-Command pwsh.exe).Source
        $argList=@('-NoProfile','-NonInteractive','-File',"`"$PSCommandPath`"",'-Bin',"`"$portable`"",'-Run',"`"$Run`"",'-Tool',$Tool,
            '-DelayMs',$DelayMs,'-Mode',$Mode,'-Pattern',$Pattern,'-Count',$Count,'-Seed',$Seed,'-Style',$Style,'-A1',$A1,'-A2',$A2,
            '-InvalidateMs',$InvalidateMs,'-ConPty',$ConPty,'-VsyncHz',$VsyncHz,'-Priority',$Priority,'-Driver')
        if($Extra.Count -gt 0) { $argList+=@('-Extra',(($Extra | ForEach-Object { "`"$_`"" }) -join ',')) }
        $command="`"$pwsh`" "+($argList -join ' ')
        # CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS, as lat-driver3.ps1 (0x08004000);
        # noctty and the tool inherit below-normal from the driver. Other classes come from the job limit.
        $flags=switch($Priority){ 'BelowNormal'{0x08004000} 'Normal'{0x08000000} 'AboveNormal'{0x08008000} 'Idle'{0x08004000} }
        $cpu0=[NrLat]::SystemTimes(); $timer0=[NrLat]::TimerResMs()
        $pi=[NrLat]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job,$flags)
        Add-Content -LiteralPath $outerLog -Value ("driver pid={0} desktop={1} priority={2}" -f $pi.pid,$desktopName,$Priority)
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        # Per-500 ms whole-machine busy samples: a short burst hides in the run average.
        $win=[NrLat]::SystemTimes(); $busyMax=0.0; $busyOver80=0; $windows=0
        while([NrLat]::WaitForSingleObject($pi.process,500) -eq 258) {
            $now=[NrLat]::SystemTimes(); $b=[NrLat]::BusyPct($win,$now); $win=$now; $windows++
            if($b -gt $busyMax) { $busyMax=$b }; if($b -gt 80) { $busyOver80++ }
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [uint32]$code=0; [void][NrLat]::GetExitCodeProcess($pi.process,[ref]$code)
        # Whole-machine CPU busy over the driver's life: a run on a loaded machine is not a result.
        $busy=[NrLat]::BusyPct($cpu0,[NrLat]::SystemTimes())
        [ordered]@{ cpu_busy_pct=[math]::Round($busy,1); cpu_busy_max_500ms_pct=[math]::Round($busyMax,1);
            windows_500ms=$windows; windows_over_80pct=$busyOver80; priority=$Priority; logical_processors=[Environment]::ProcessorCount;
            timer_resolution_ms_before=$timer0; timer_resolution_ms_after=[NrLat]::TimerResMs() } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'load.json')
    } finally {
        foreach($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k,$saved[$k]) }
        $cleanupError=$null
        if($job -ne [IntPtr]::Zero) {
            try { Add-Content -LiteralPath $outerLog -Value ("job before stop: " + [NrLat]::DescribeJob($job)); [void][NrLat]::StopOwnedJob($job) } catch { $cleanupError=$_ }
        }
        if($pi) { [void][NrLat]::CloseHandle($pi.thread); [void][NrLat]::CloseHandle($pi.process) }
        [void][NrLat]::CloseDesktop($desktop)
        $after=Real-State
        $diff=@($before.Keys | Where-Object { "$($before[$_])" -cne "$($after[$_])" })
        [ordered]@{ Before=$before; After=$after; Changed=$diff } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Run 'guard.json')
        Assert-WindowsHarnessHistoryGuard -Guard $historyGuard
        if($diff.Count -gt 0) { throw ("Real user state changed during the run ({0}); stop launches and report it." -f ($diff -join ',')) }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Driver failed ($code); see $Run\driver.log" }
    Write-Host "run complete: $Run"
    exit 0
}

# --- Driver, on the private desktop ---
$log=Join-Path $Run 'driver.log'
function Log([string]$m) { Add-Content -LiteralPath $log -Value ("{0:o} {1}" -f [datetime]::UtcNow,$m) }
try {
    $deskName=[NrLat]::DesktopName()
    if(-not $deskName.StartsWith($DesktopPrefix,[StringComparison]::Ordinal)) { throw 'Driver is not on the private desktop.' }
    if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable'))) { throw 'Portable marker missing.' }
    if(Test-Path -LiteralPath (Join-Path $Bin 'noctty.ico')) { throw 'noctty.ico beside a scratch copy could create an AUMID registration.' }
    foreach($dir in @('LOCALAPPDATA','APPDATA')) {
        $value=[Environment]::GetEnvironmentVariable($dir)
        if(-not $value -or -not [IO.Path]::GetFullPath($value).StartsWith($Run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'AppData isolation failed.' }
    }
    $job=[NrLat]::CreateOwnedJob($innerJobClass)
    Log ("noctty job priority class limit=0x{0:X}" -f $innerJobClass)
    $toolLog=Join-Path $Run $(if($Tool -eq 'echo'){'echo.txt'}else{'anim.txt'})
    $ready=Join-Path $Run $(if($Tool -eq 'echo'){'echo-ready.txt'}else{'anim-ready.txt'})
    $args2=@('--window-save-state=never','--confirm-close-surface=false','--auto-update=off','--command=cmd.exe',
        '--window-width=100','--window-height=30','--window-position-x=200','--window-position-y=200')+$Extra
    $exe=Join-Path $Bin 'noctty.exe'
    $toolPath=Join-Path $Run 'lat-echo.exe'
    $toolArgs=if($Tool -eq 'echo') { "$DelayMs $Mode `"$toolLog`" `"$ready`" $Style" } else { "$A1 $A2 `"$toolLog`" `"$ready`"" }
    $cmd="`"$exe`" "+($args2 -join ' ')+" -e `"$toolPath`" $toolArgs"
    Log ("launch: tool={0} args={1} noctty_flags={2}" -f $Tool,$toolArgs.Replace($Run,'<run>'),(($args2) -join ' '))
    # Always name the private desktop: a child started with a null lpDesktop
    # from this driver lands on the Default desktop (LAT-01 trap 2).
    $p=[NrLat]::Launch($exe,$cmd,$Run,"WinSta0\$deskName",$job,[uint32]2147483648)
    Log ("noctty pid={0}" -f $p.pid)
    $deadline=[datetime]::UtcNow.AddSeconds(30); $h=[IntPtr]::Zero
    while([datetime]::UtcNow -lt $deadline) {
        $h=[NrLat]::Surface($p.pid)
        if($h -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $ready)) { break }
        Start-Sleep -Milliseconds 100
    }
    if($h -eq [IntPtr]::Zero) { throw 'noctty surface not found.' }
    if(-not (Test-Path -LiteralPath $ready)) { throw 'tool never became ready.' }
    Log "surface=0x$('{0:X}' -f $h.ToInt64())"
    if($Tool -eq 'echo') {
        Start-Sleep -Milliseconds 2500
        $rng=[Random]::new($Seed); $f=[Diagnostics.Stopwatch]::Frequency
        $evs=[Collections.Generic.List[NrLat+Ev]]::new()
        $t=[Diagnostics.Stopwatch]::GetTimestamp()+[long]($f/2)
        for($i=0;$i -lt $Count;$i++) {
            $vk=0x41+($i % 26)
            if($Pattern -eq 'cursor' -and $i -ge 40) { $vk=if((($i-40) % 2) -eq 0) { 0x25 } else { 0x27 } }
            if($Pattern -ne 'burst') { $gap=83+$rng.Next(0,43); $hold=50+$rng.Next(0,61) }
            else { $gap=if(($i % 6) -eq 0 -and $i -gt 0) { 420+$rng.Next(0,80) } else { 30+$rng.Next(0,12) }; $hold=40+$rng.Next(0,51) }
            if($i -gt 0) { $t+=[long]($gap*$f/1000) }
            $evs.Add([NrLat+Ev]@{Due=$t;Down=$true;Index=$i;Vk=$vk})
            $evs.Add([NrLat+Ev]@{Due=$t+[long]($hold*$f/1000);Down=$false;Index=$i;Vk=$vk})
        }
        [NrLat]::Play($h,$evs)
        $lines=foreach($e in $evs) { if($e.Down) { "D {0} {1} {2}" -f $e.Index,$e.Posted,$e.Vk } else { "U {0} {1} {2}" -f $e.Index,$e.Posted,$e.Vk } }
        Set-Content -LiteralPath (Join-Path $Run 'keys.txt') -Value $lines
        Start-Sleep -Milliseconds 1500
    } else {
        # anim-probe.ps1's wait: 1.5 s + A2 s + 1 s (held: A2 cycles of A1+100 ms each).
        $waitUntil=[datetime]::UtcNow.AddMilliseconds(1500 + 1000 * $A2 + 1000)
        # The tools write their log only at fclose, after the last cycle/frame. On
        # a loaded machine the tool can still be running at the original fixed
        # wait; then keep waiting (and invalidating) up to 30 s more for the log.
        # Nothing after the tool's last mark enters any count.
        $lateUntil=$waitUntil.AddSeconds(30)
        $toolDone={ (Test-Path -LiteralPath $toolLog) -and ((Get-Item -LiteralPath $toolLog).Length -gt 0) }
        $inval=Join-Path $Run 'inval.txt'
        while($true) {
            $now=[datetime]::UtcNow
            if($now -ge $waitUntil -and ((& $toolDone) -or $now -ge $lateUntil)) { break }
            if($InvalidateMs -gt 0) {
                # PKG-37: invalidate the terminal child as an expose would (WM_PAINT with no renderer frame reserved).
                # As in anim-probe.ps1: Start-Sleep with no timeBeginPeriod in this process, so the real period
                # is what the system timer gives; inval.txt has every QPC-stamped invalidation.
                [long]$q=0; [void][NrLat]::QueryPerformanceCounter([ref]$q)
                [void][NrLat]::RedrawWindow($h,[IntPtr]::Zero,[IntPtr]::Zero,1)
                Add-Content -LiteralPath $inval -Value "I $q"
                Start-Sleep -Milliseconds $InvalidateMs
            } else { Start-Sleep -Milliseconds 100 }
        }
        $late=([datetime]::UtcNow-$waitUntil).TotalMilliseconds
        if($late -gt 150) { Log ("tool log late: waited {0:n0} ms past the original fixed wait" -f $late) }
        if(-not (& $toolDone)) { Log 'tool log still empty: the tool never finished (starved?)' }
    }
    $trace=Join-Path $Run 'latency.txt'
    if(-not [NrLat]::PostMessageW($h,0x8008,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'snapshot post failed' }
    $deadline=[datetime]::UtcNow.AddSeconds(10); $last=-1
    while([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if(Test-Path -LiteralPath $trace) { $len=(Get-Item -LiteralPath $trace).Length; if($len -gt 0 -and $len -eq $last) { break }; $last=$len }
    }
    Log "trace bytes=$last"
    Log ("job before stop: " + [NrLat]::DescribeJob($job))
    [void][NrLat]::StopOwnedJob($job)
    if($last -le 0) { throw 'no latency trace (is this a trace-patched build?)' }
    exit 0
} catch {
    Log "ERROR $_"
    exit 1
}
