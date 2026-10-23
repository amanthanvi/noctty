# Shared by the hidden-desktop harnesses that run on a developer machine
# (hidden-win11-docked-search.ps1, -single-tab-close, -dpi-geometry,
# -quick-terminal-identity, -session-restore, -default-shell, -restore-quarantine,
# -app-delivery, -window-start and -restart-manager). Dot-source it. The hosted-runner harnesses use
# hidden-win11-lib.ps1 instead.
#
# What it gives them:
#   * [HiddenLocal]: the private desktop, the owned kill-on-close job, and the
#     two launches: Launch (suspended, assigned to the job before it runs,
#     CREATE_NO_WINDOW, below-normal priority) for the driver, Spawn
#     (CREATE_NO_WINDOW) for a case. Both name their desktop explicitly in
#     STARTUPINFO.lpDesktop and start the window hidden.
#   * Invoke-LocalHiddenDriver: the outer half of a harness. It runs the harness
#     again as its driver on a new private desktop, inside that job, with
#     LOCALAPPDATA and APPDATA redirected into the run directory, and checks
#     that the real startup-attempts.json, the real PSReadLine history files'
#     size and time (scripts/windows-harness-history.ps1) and, with
#     -GuardClipboard, the clipboard sequence number did not change.
#   * Small helpers the harnesses had each copied.
#   * Assert-EmbeddingDelegationSafe, from hidden-win11-embedding-guard.ps1 (the
#     one copy, shared with hidden-win11-lib.ps1), for a harness that starts
#     `noctty.exe -Embedding`.

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
. (Join-Path $PSScriptRoot 'hidden-win11-embedding-guard.ps1')

if (-not ('HiddenLocal' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HiddenLocal {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,int length,out int needed);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job,int type,ref JobLimits limits,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
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
    // Every terminal pane of a host, in the order Windows enumerates them.
    public static IntPtr[] Surfaces(IntPtr host) {
        var list=new List<IntPtr>();
        EnumChildWindows(host,(c,p)=> { if(Class(c)=="noctty.win32") list.Add(c); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    // The name of the desktop of the thread that owns `h`.
    public static string WindowDesktop(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid); var name=new StringBuilder(256); int needed;
        if(tid==0 || !GetUserObjectInformationW(GetThreadDesktop((uint)tid),2,name,512,out needed)) throw new Exception("Window desktop query failed");
        return name.ToString();
    }
    // Starts a process on the named desktop, with no console window.
    public static ProcessInfo Spawn(string app,string command,string cwd,string desktop) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        return pi;
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
}

# Hash and time of the real startup-attempts.json; its contents are never read.
function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}

function Jump-List-Files {
    $dir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\Recent\CustomDestinations'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.customDestinations-ms' -File | ForEach-Object { @{ Path=$_.FullName; Written=[DateTimeOffset]$_.LastWriteTimeUtc } })
}

# A portable copy: every file of the source bin directory, the share directory beside it, and
# the `noctty.portable` marker that keeps the copy's state inside its own directory.
function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}

# Records one assertion in the calling harness's $script:checks.
function Check([string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}

function Wait-Until([scriptblock]$Predicate,[int]$Seconds=10) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do { if(& $Predicate) { return $true }; Start-Sleep -Milliseconds 50 } while([datetime]::UtcNow -lt $deadline)
    return [bool](& $Predicate)
}

function Rect-Array($r) { return @($r.Left,$r.Top,$r.Right,$r.Bottom) }
function Rect-Same($a,$b,[int]$Tolerance=2) {
    return [Math]::Abs($a.Left-$b.Left) -le $Tolerance -and [Math]::Abs($a.Top-$b.Top) -le $Tolerance -and [Math]::Abs($a.Right-$b.Right) -le $Tolerance -and [Math]::Abs($a.Bottom-$b.Bottom) -le $Tolerance
}

function Hash-Of([string]$Path) { if(Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } return $null }

# The outer half of a harness: `-Script` runs again with `-Driver` on a new private desktop, in an
# owned kill-on-close job, with LOCALAPPDATA and APPDATA redirected into `-Run`. Its command line is
# `-Bin <run>\source\bin -Run <run>`, then `-DesktopName <name>` with -PassDesktopName, then
# `-DriverArguments`. `-RunFiles` (name to text) are written into the new run directory first.
function Invoke-LocalHiddenDriver {
    param(
        [Parameter(Mandatory)] [string] $Script, [Parameter(Mandatory)] [string] $Bin, [Parameter(Mandatory)] [string] $Run,
        [Parameter(Mandatory)] [string] $DesktopPrefix, [Parameter(Mandatory)] [int] $TimeoutSeconds, [Parameter(Mandatory)] [string] $Label,
        [string] $ExpectedStartupHash, [string] $ExpectedStartupModified,
        [switch] $PassDesktopName, [string[]] $DriverArguments = @(), [hashtable] $RunFiles = @{}, [switch] $GuardClipboard
    )
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Source Bin must contain noctty.exe.' }
    $before = Startup-Fingerprint
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness (Split-Path -Leaf $Script)
    if ($GuardClipboard) { $clipBefore = [HiddenLocal]::GetClipboardSequenceNumber() }
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($file in $RunFiles.GetEnumerator()) { [IO.File]::WriteAllText((Join-Path $Run $file.Key), $file.Value) }
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = $DesktopPrefix + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero
    try {
        $job=[HiddenLocal]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}"' -f $pwsh,$Script,(Join-Path $Run 'source\bin'),$Run
        if ($PassDesktopName) { $line += ' -DesktopName "{0}"' -f $desktopName }
        foreach ($argument in $DriverArguments) { $line += ' ' + $argument }
        $line += ' -Driver'
        $pi=[HiddenLocal]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([HiddenLocal]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $TimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$code=0; [void][HiddenLocal]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[HiddenLocal]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        if ($GuardClipboard) { $clipAfter=[HiddenLocal]::GetClipboardSequenceNumber() }
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyFailure=$null
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }
        $state=@{ Before=$before; After=$after; Unchanged=$unchanged; HistoryUnchanged=($null -eq $historyFailure); OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount }
        if ($GuardClipboard) {
            $state.ClipboardSequenceBefore=$clipBefore; $state.ClipboardSequenceAfter=$clipAfter; $state.ClipboardUnchanged=($clipBefore -eq $clipAfter)
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if ($historyFailure) { throw $historyFailure }
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($GuardClipboard -and $clipBefore -ne $clipAfter) { throw "Clipboard sequence number moved ($clipBefore -> $clipAfter); stop launches and report it." }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host "${Label}: PASS"
}
