#requires -Version 7.0
<#
Portable, hidden-desktop integration regression for the docked search bar
(PKG-41): which match the first Enter selects and how Enter, F3 and the arrow
keys walk the matches, the "Invalid pattern" label for a regex that does not
compile, and the narrow-pane collapse that drops the toggles and then
previous/next instead of overlapping them. Run with -Bin <source bin
directory> -Run <new evidence directory>. The run directory must not already
exist.

Never switches desktops, injects real input or touches the clipboard: every
action is a posted window message. The search copies nothing, and the
configuration denies clipboard reads and writes and copy-on-select besides.
GetClipboardSequenceNumber (a counter, it reads no contents) is recorded
before and after, and the run fails when it moved. Optional
ExpectedStartupHash/ExpectedStartupModified pin an adopted baseline of the
real startup-attempts.json; either way it is fingerprinted before and after.
DriverTimeoutSeconds bounds the hidden driver and its owned process job.
Results contain only control geometry, label text, process IDs and
assertions. It exits 1 when a check fails, so it can be run against a build
that still has the problem to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 300,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Ds {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo {
        public int cbSize, flags; public IntPtr active, focus, capture, menuOwner, moveSize, caret; public Rect caretRect;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(int thread,ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(int from,int to,bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job,int type,ref JobLimits limits,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr process,uint code);
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
    // The first child of `host` with the control ID, in the order Windows
    // enumerates them, or zero.
    public static IntPtr Child(IntPtr host,int id) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(c,p)=> { if(GetDlgCtrlID(c)==id) { found=c; return false; } return true; },IntPtr.Zero);
        return found;
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static uint Dpi(IntPtr h) { return GetDpiForWindow(h); }
    public static Rect RectOf(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed"); return r; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    public static int ClientWidth(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; if(!GetClientRect(h,out r)) throw new Exception("Client measurement failed"); return r.Right-r.Left; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    // Resizes `host` so its client area is `clientWidth` wide, keeping its position.
    public static void SetClientWidth(IntPtr host,int clientWidth) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect w; Rect c; GetWindowRect(host,out w); GetClientRect(host,out c);
            int frame=(w.Right-w.Left)-(c.Right-c.Left);
            if(!SetWindowPos(host,IntPtr.Zero,w.Left,w.Top,clientWidth+frame,w.Bottom-w.Top,0x14)) throw new Exception("SetWindowPos failed");
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static string Text(IntPtr h) {
        var sb=new StringBuilder(512); SendMessageW(h,0x0D,new IntPtr(512),sb); return sb.ToString();
    }
    public static void SetText(IntPtr h,string text) { SendMessageW(h,0x0C,IntPtr.Zero,text); }
    public static void Click(IntPtr h) { if(!PostMessageW(h,0xF5,IntPtr.Zero,IntPtr.Zero)) throw new Exception("BM_CLICK post failed"); }
    public static void Key(IntPtr h,int key) {
        if(!PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    public static void Chars(IntPtr h,string text) {
        foreach(char ch in text) if(!PostMessageW(h,0x102,new IntPtr(ch),new IntPtr(1))) throw new Exception("Char post failed");
    }
    // The window with the keyboard focus in the UI thread that owns `h`.
    public static IntPtr FocusOf(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid);
        var info=new GuiThreadInfo(); info.cbSize=Marshal.SizeOf<GuiThreadInfo>();
        if(!GetGUIThreadInfo(tid,ref info)) throw new Exception("GetGUIThreadInfo failed");
        return info.focus;
    }
    // Moves the keyboard focus of the UI thread that owns `h` to `h` without
    // injecting input: this thread joins that thread's input queue for the call.
    public static void FocusOn(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid); int me=GetCurrentThreadId();
        if(!AttachThreadInput(me,tid,true)) throw new Exception("AttachThreadInput failed");
        try { SetFocus(h); } finally { AttachThreadInput(me,tid,false); }
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
    $clipBefore = [Ds]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-search-' + [guid]::NewGuid().ToString('N')
    $desktop = [Ds]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero
    try {
        $job=[Ds]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -DesktopName "{4}" -Driver' -f $pwsh,$PSCommandPath,(Join-Path $Run 'source\bin'),$Run,$desktopName
        $pi=[Ds]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Ds]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$code=0; [void][Ds]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Ds]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
        [void][Ds]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $clipAfter=[Ds]::GetClipboardSequenceNumber()
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        @{ Before=$before; After=$after; Unchanged=$unchanged; ClipboardSequenceBefore=$clipBefore; ClipboardSequenceAfter=$clipAfter; ClipboardUnchanged=($clipBefore -eq $clipAfter); OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($clipBefore -ne $clipAfter) { throw "Clipboard sequence number moved ($clipBefore -> $clipAfter); stop launches and report it." }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden docked search: PASS'
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Ds]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$desktopPath="WinSta0\$DesktopName"
function Check([string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
function Wait-Until([scriptblock]$Predicate,[int]$Seconds=10) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do { if(& $Predicate) { return $true }; Start-Sleep -Milliseconds 50 } while([datetime]::UtcNow -lt $deadline)
    return [bool](& $Predicate)
}
# ID of each docked search control (src/apprt/win32/consts.zig).
$Id=@{ Bg=2100; Edit=2101; Prev=2102; Next=2103; Regex=2104; Case=2105; Word=2106; Results=2107; Close=2108 }
function Pane($h) {
    $all=@([Ds]::Surfaces($h)); $shown=@($all|Where-Object {[Ds]::Visible($_)})
    if($shown.Count) { return $shown[0] }
    if($all.Count) { return $all[0] }
    throw 'Host has no pane.'
}
function Label($h) { $r=[Ds]::Child($h,$Id.Results); if($r -eq [IntPtr]::Zero){return $null}; return [Ds]::Text($r) }
# Waits for the results label to leave `$From`, then returns what it shows.
function Label-After($h,[string]$From,[int]$Seconds=4) {
    [void](Wait-Until { (Label $h) -ne $From } $Seconds)
    Start-Sleep -Milliseconds 150
    return (Label $h)
}
function Wait-Label($h,[scriptblock]$Is,[int]$Seconds=6) {
    [void](Wait-Until { $t=Label $h; $null -ne $t -and (& $Is $t) } $Seconds)
    return (Label $h)
}
function Press-Edit($h,[int]$Key) { [Ds]::Key([Ds]::Child($h,$Id.Edit),$Key) }
function Set-Query($h,[string]$Text) {
    # An edit of the query as a user's typing makes: the text changes and
    # EN_CHANGE reaches the search bar.
    [Ds]::SetText([Ds]::Child($h,$Id.Edit),$Text)
}
function Launch-Case([string]$Name) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    $fill=Join-Path $dir 'fill.cmd'
    @('@echo off','for /L %%i in (1,1,60) do echo needlex %%i','ping -n 3600 127.0.0.1 >nul') | Set-Content -LiteralPath $fill -Encoding ascii
    $config=Join-Path $dir 'search.ghostty'
    # The batch file is found through the working directory, so the run path
    # may hold spaces without any quoting for cmd.exe.
    @("working-directory = $dir",'command = cmd.exe /d /c fill.cmd','shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false',
      'copy-on-select = false','clipboard-read = deny','clipboard-write = deny',
      'keybind = f4=start_search') | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    $pi=[Ds]::Spawn($exe,('"{0}" --config-file="{1}"' -f $exe,$config),$dir,$desktopPath)
    $script:processes.Add(@{Case=$Name;Pid=$pi.pid})
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    do {
        $hosts=@([Ds]::Hosts($pi.pid))
        $ready=$false
        $ledger=Join-Path $dir 'startup-attempts.json'
        if(Test-Path -LiteralPath $ledger) {
            try {
                $attempts=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready=$attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if($ready -and $hosts.Count -and @([Ds]::Surfaces($hosts[0])).Count -gt 0) {
            [void][Ds]::ShowWindow($hosts[0],4)
            Start-Sleep -Milliseconds 400
            return @{Pi=$pi; Pid=$pi.pid; Host=$hosts[0]}
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline)
    Close-Case @{Pi=$pi; Pid=$pi.pid}
    throw "Window startup failed for case $Name."
}
function Close-Case($case) {
    foreach($h in [Ds]::Hosts($case.Pid)) { [void][Ds]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if([Ds]::WaitForSingleObject($case.Pi.process,5000) -eq 258) {
        # The handle is this launch's own process: no name or pattern match.
        [void][Ds]::TerminateProcess($case.Pi.process,1)
        [void][Ds]::WaitForSingleObject($case.Pi.process,5000)
    }
    [void][Ds]::CloseHandle($case.Pi.thread); [void][Ds]::CloseHandle($case.Pi.process)
}
function Open-Search($h) {
    [Ds]::Key((Pane $h),0x73)            # F4: start_search
    [void](Wait-Until { [Ds]::Child($h,$Id.Edit) -ne [IntPtr]::Zero -and [Ds]::Visible([Ds]::Child($h,$Id.Edit)) } 8)
    Start-Sleep -Milliseconds 300
}
function Scaled([int]$base,[uint32]$dpi) { if($dpi -le 96){return $base}; return [int][Math]::Truncate($base*$dpi/96.0) }
try {
    # G052 and G063 on a buffer with 60 matches of "needlex".
    $case=Launch-Case 'navigate'
    try {
        $h=$case.Host
        Start-Sleep -Milliseconds 4000       # the batch file prints its 60 lines
        Open-Search $h
        Check 'search bar opened' ([Ds]::Visible([Ds]::Child($h,$Id.Edit))) $true ([Ds]::Visible([Ds]::Child($h,$Id.Edit)))
        [Ds]::Chars([Ds]::Child($h,$Id.Edit),'needlex')
        $typed=Wait-Label $h { param($t) $t -match '^\d+$' }
        Check 'typing the query shows the total, nothing selected' ($typed -eq '60') '60' $typed

        # G052: the first Enter selects the newest match, nearest the bottom.
        $steps=[Collections.Generic.List[string]]::new(); $last=$typed
        foreach($step in @(@('Enter',13),@('Enter again',13),@('Enter again',13),@('F3',0x72),@('Up',0x26))) {
            Press-Edit $h $step[1]
            $last=Label-After $h $last; $steps.Add($last)
        }
        Check 'the first Enter selects the newest match' ($steps[0] -eq '1/60') '1/60' $steps[0]
        Check 'Enter walks toward the newest and wraps to the oldest' ($steps[1] -eq '60/60' -and $steps[2] -eq '59/60') @('60/60','59/60') @($steps[1],$steps[2])
        Check 'F3 goes the way Enter goes' ($steps[3] -eq '58/60') '58/60' $steps[3]
        Check 'Up goes the opposite way' ($steps[4] -eq '59/60') '59/60' $steps[4]
        $script:samples.Add(@{Name='navigation labels'; Labels=@($typed)+$steps})

        # G063: an invalid regex is not "No matches", and the next edit clears it.
        [Ds]::Click([Ds]::Child($h,$Id.Regex))
        Start-Sleep -Milliseconds 400
        Set-Query $h 'need('
        $invalid=Wait-Label $h { param($t) $t -eq 'Invalid pattern' }
        Check 'an unparsable regex reads Invalid pattern' ($invalid -eq 'Invalid pattern') 'Invalid pattern' $invalid
        Set-Query $h 'need()'
        $valid=Wait-Label $h { param($t) $t -match '^\d+$' }
        Check 'the next edit makes it a search again' ($valid -eq '60') '60' $valid
        Set-Query $h 'zzzzq'
        $none=Wait-Label $h { param($t) $t -eq 'No matches' }
        Check 'a valid regex with no match still reads No matches' ($none -eq 'No matches') 'No matches' $none
        Set-Query $h '['
        $again=Wait-Label $h { param($t) $t -eq 'Invalid pattern' }
        Check 'a bad pattern reads Invalid pattern again' ($again -eq 'Invalid pattern') 'Invalid pattern' $again
        [Ds]::Click([Ds]::Child($h,$Id.Regex))   # regex off: "[" is literal text
        $literal=Wait-Label $h { param($t) $t -ne 'Invalid pattern' }
        Check 'a toggle clears the mark: the literal text is searched' ($literal -eq 'No matches') 'No matches' $literal
        $script:samples.Add(@{Name='invalid pattern labels'; Labels=@($invalid,$valid,$none,$again,$literal)})
    } finally { Close-Case $case }

    # F079: the controls of the bar as the pane narrows.
    $case=Launch-Case 'narrow'
    try {
        $h=$case.Host
        Start-Sleep -Milliseconds 2500
        Open-Search $h
        [Ds]::Chars([Ds]::Child($h,$Id.Edit),'needlex')
        [void](Wait-Label $h { param($t) $t -match '^\d+$' })
        $dpi=[Ds]::Dpi($h)
        $thresholdNav=2*(Scaled 8 $dpi)+(Scaled 30 $dpi)+(Scaled 10 $dpi)+(2*(Scaled 30 $dpi)+(Scaled 2 $dpi)+(Scaled 10 $dpi))+(Scaled 120 $dpi)
        $thresholdToggles=$thresholdNav+(3*(Scaled 30 $dpi)+2*(Scaled 2 $dpi)+(Scaled 10 $dpi))
        $script:samples.Add(@{Name='thresholds'; Dpi=$dpi; Nav=$thresholdNav; Toggles=$thresholdToggles})
        $focusMoved=$null
        $widths=@(1100,($thresholdToggles+40),($thresholdToggles-1),($thresholdNav+30),($thresholdNav-1),[int](232*$dpi/96),[int](200*$dpi/96))
        foreach($width in $widths) {
            [Ds]::SetClientWidth($h,$width)
            Start-Sleep -Milliseconds 700
            $bg=[Ds]::Child($h,$Id.Bg)
            $frame=[Ds]::RectOf($bg); $frameW=$frame.Right-$frame.Left
            $rects=[ordered]@{}
            foreach($name in 'Close','Word','Case','Regex','Next','Prev','Results','Edit') {
                $c=[Ds]::Child($h,$Id[$name])
                $vis=$c -ne [IntPtr]::Zero -and [Ds]::Visible($c)
                $r=if($vis){[Ds]::RectOf($c)}else{$null}
                $rects[$name]=@{Visible=$vis; Left=$(if($r){$r.Left}); Right=$(if($r){$r.Right})}
            }
            $script:samples.Add(@{Name="width $width"; ClientWidth=[Ds]::ClientWidth($h); FrameWidth=$frameW; Controls=$rects})
            $togglesShown=$rects.Word.Visible -and $rects.Case.Visible -and $rects.Regex.Visible
            $togglesHidden=-not $rects.Word.Visible -and -not $rects.Case.Visible -and -not $rects.Regex.Visible
            $navShown=$rects.Next.Visible -and $rects.Prev.Visible
            $navHidden=-not $rects.Next.Visible -and -not $rects.Prev.Visible
            Check "frame $frameW px: toggles shown exactly when they fit" ((($frameW -ge $thresholdToggles) -and $togglesShown) -or (($frameW -lt $thresholdToggles) -and $togglesHidden)) @{Shown=($frameW -ge $thresholdToggles)} @{Shown=$togglesShown;Hidden=$togglesHidden}
            Check "frame $frameW px: previous and next shown exactly when they fit" ((($frameW -ge $thresholdNav) -and $navShown) -or (($frameW -lt $thresholdNav) -and $navHidden)) @{Shown=($frameW -ge $thresholdNav)} @{Shown=$navShown;Hidden=$navHidden}
            $shown=@($rects.GetEnumerator()|Where-Object {$_.Value.Visible}|Sort-Object {$_.Value.Left})
            $overlap=$false
            for($i=1;$i -lt $shown.Count;$i++) { if($shown[$i].Value.Left -lt $shown[$i-1].Value.Right) { $overlap=$true } }
            $outside=@($shown|Where-Object {$_.Value.Left -lt $frame.Left -or $_.Value.Right -gt $frame.Right})
            Check "frame $frameW px: no control overlaps another or leaves the frame" (-not $overlap -and $outside.Count -eq 0) 'none' @{Overlap=$overlap;Outside=@($outside|ForEach-Object{$_.Key})}
            $editW=$rects.Edit.Right-$rects.Edit.Left
            if($frameW -ge (2*(Scaled 8 $dpi)+(Scaled 30 $dpi)+(Scaled 10 $dpi)+(Scaled 120 $dpi))) {
                Check "frame $frameW px: the edit keeps its minimum width" ($rects.Edit.Visible -and $editW -ge (Scaled 120 $dpi)) (Scaled 120 $dpi) $editW
            }
            Check "frame $frameW px: the close button and the edit stay" ($rects.Close.Visible -and $rects.Edit.Visible) $true @{Close=$rects.Close.Visible;Edit=$rects.Edit.Visible}
            if($width -eq 1100) {
                # With a toggle focused, narrowing the pane hands the focus to
                # the edit instead of leaving the keyboard with no window.
                [Ds]::FocusOn([Ds]::Child($h,$Id.Regex)); Start-Sleep -Milliseconds 200
                $focusMoved=@{Before=([Ds]::FocusOf($h) -eq [Ds]::Child($h,$Id.Regex))}
            }
            if($width -eq ($thresholdToggles-1)) {
                $focusMoved.After=([Ds]::FocusOf($h) -eq [Ds]::Child($h,$Id.Edit))
                Check 'hiding the focused toggle moves the focus to the edit' ($focusMoved.Before -and $focusMoved.After) 'focus on the regex toggle, then on the edit' $focusMoved
            }
        }
        # Back to a wide pane: the controls return, and Enter still steps.
        [Ds]::SetClientWidth($h,1100); Start-Sleep -Milliseconds 700
        Check 'the toggles return when the pane widens' ([Ds]::Visible([Ds]::Child($h,$Id.Regex)) -and [Ds]::Visible([Ds]::Child($h,$Id.Prev))) $true ([Ds]::Visible([Ds]::Child($h,$Id.Regex)))
        [Ds]::SetClientWidth($h,[int](232*$dpi/96)); Start-Sleep -Milliseconds 700
        $navVisible=@([Ds]::Visible([Ds]::Child($h,$Id.Prev)),[Ds]::Visible([Ds]::Child($h,$Id.Next)),[Ds]::Visible([Ds]::Child($h,$Id.Regex)))
        Check 'previous, next and the toggles are hidden at 232 DIP' (-not ($navVisible -contains $true)) 'none visible' $navVisible
        $before=Label $h
        Press-Edit $h 13
        $stepped=Label-After $h $before
        Check 'Enter steps through the matches with previous and next hidden' ($stepped -match '^\d+/60$') 'N/60' $stepped
    } finally { Close-Case $case }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Posted window messages and Win32 geometry on a never-switched desktop; real pointer and shell input, a global hotkey, the clipboard and visual composition are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'search-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){exit 1}
