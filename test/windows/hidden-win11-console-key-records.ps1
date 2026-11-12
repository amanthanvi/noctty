#requires -Version 7.0
<#
Console-API key record regression (Win32 input mode, DEC 9001). Supply a built
Bin and a NEW Run directory. Copies koreterm into Run with koreterm.portable and
redirects both AppData roots. All windows and the driver live on a private
desktop. No real input, foreground changes, clipboard access, or protocol
requests; only posted key messages whose characters the target's own
TranslateMessage produces, as a keyboard's would.

Two console clients run the same observer (console-input-records.c,
ReadConsoleInputW in mode 0x98, no kitty/MOK requests): one inside koreterm, so
its records come from ConPTY decoding koreterm's win32-input-mode sequences, and
one in a real console window (conhost.exe) on the same desktop, so its records
are what Windows itself produces for the same key messages. Each case posts
the same key messages to both and compares every KEY_EVENT record field.

A second phase types into PSReadLine inside koreterm and checks that Shift+Enter
adds a continuation line instead of running the line (one history entry for
two lines). PSReadLine's history file is redirected into the run and set to
SaveNothing before its first read; the real files' size and time are checked
before and after (metadata only, never hashed or read).

-Observe records every failure and returns success (infrastructure failures
still fail). -CompileOnly validates the C/C# harness without launching
anything. -Baseline* lets the caller pin the adopted startup-attempts.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Observe,
    [switch] $CompileOnly,
    [switch] $Driver,
    [switch] $SkipPSReadLine,
    [ValidatePattern('^[a-fA-F0-9]{64}$')] [string] $BaselineHash,
    [string] $BaselineModifiedUtc,
    [ValidateRange(10,600)] [int] $DriverTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class KeyRecords {
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
    [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr hwnd; public uint message; public UIntPtr w; public IntPtr l; public uint time; public int x,y; public uint extra; }
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,int length,out int needed);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow c,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow c,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a,uint b,bool attach);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool PeekMessageW(out Message m,IntPtr h,uint a,uint b,uint remove);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint t,out IntPtr result);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyExW(uint code,uint type,IntPtr layout);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] static extern int GetKeyboardLayoutList(int count,[Out] IntPtr[] layouts);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr LoadKeyboardLayoutW(string id,uint flags);
    [DllImport("user32.dll")] static extern bool UnloadKeyboardLayout(IntPtr layout);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern short VkKeyScanExW(char c,IntPtr layout);
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
    public static IntPtr CreateOwnedJob() {
        var j=CreateJobObjectW(IntPtr.Zero,null); if(j==IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var l=new JobLimits(); l.basic.flags=0x2000;
        if(!SetInformationJobObject(j,9,ref l,(uint)Marshal.SizeOf<JobLimits>())) { CloseHandle(j); throw new Exception("Job limit failed"); }
        return j;
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
    // flags: CREATE_SUSPENDED (0x4) and BELOW_NORMAL_PRIORITY_CLASS (0x4000) are always added.
    // Suspended creation establishes job ownership before any child can start.
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,uint flags) {
        var s=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo p;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags|0x4004,IntPtr.Zero,cwd,ref s,out p))
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
            if(id==pid && Class(h)=="koreterm.win32.host") EnumChildWindows(h,(c,q)=> { if(Class(c)=="koreterm.win32") found=c; return true; },IntPtr.Zero);
            return true;
        },IntPtr.Zero); return found;
    }
    public static string DesktopName() {
        var name=new StringBuilder(256); int needed;
        if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,name,name.Capacity*2,out needed)) throw new Exception("Driver desktop identity unavailable");
        return name.ToString();
    }
    // EnumWindows lists only the calling thread's desktop: a window that is
    // not listed is on another desktop, and must not be driven.
    public static bool OnCallerDesktop(IntPtr target) {
        bool found=false;
        EnumWindows((h,p)=> { if(h==target) found=true; return !found; },IntPtr.Zero);
        return found;
    }
    static void Send(IntPtr h,uint m,int w,long l) {
        IntPtr result; if(SendMessageTimeoutW(h,m,new IntPtr(w),new IntPtr(l),2,2000,out result)==IntPtr.Zero) throw new Exception("Timed key message failed");
    }
    static void Post(IntPtr h,uint m,int w,long l) {
        if(!PostMessageW(h,m,new IntPtr(w),new IntPtr(l))) throw new Exception("Key post failed");
    }
    public class Stroke {
        public int Vk; public bool Ctrl,Alt,AltGr,Shift,Extended; public int Repeats=1;
        public bool DownOnly,UpOnly;
        // Bit 25 of lParam: the key message of the left Ctrl Windows synthesizes for AltGr.
        public bool Fake;
    }
    static void KeyState(byte[] state,Stroke k,bool down) {
        if(k.Ctrl||k.AltGr) state[0x11]=state[0xA2]=0x80;
        if(k.Alt) state[0x12]=state[0xA4]=0x80;
        if(k.AltGr) { state[0x12]=state[0xA5]=0x80; }
        if(k.Shift) state[0x10]=state[0xA0]=0x80;
        state[k.Vk]=down?(byte)0x80:(byte)0;
    }
    // Posts (or sends) the key messages of each stroke to h with the thread's
    // keyboard state set the way the keyboard driver would set it, then a
    // marker key whose record acknowledges that the whole sequence reached the
    // observer. Modifiers stay set until that barrier, since a posted message
    // is translated later by the target's own pump. No WM_CHAR is posted: the
    // target's TranslateMessage produces the characters, as for a keyboard.
    // target is the thread that pumps h's messages. For a console window
    // GetWindowThreadProcessId reports the console client, not conhost's input
    // thread, so the caller finds that thread (InputThreadCandidates).
    // Strokes are spaced like typing (strokeGapMs), because conhost's input
    // thread translates a key when it dequeues it and posts the characters
    // behind whatever is already queued; keys posted all at once come back
    // with their records interleaved. Without a marker the modifiers are held
    // for holdMs so the target translates the posted keys before they drop.
    public static void Keys(IntPtr h,uint target,Stroke[] strokes,bool synchronous,int marker,Func<bool> acknowledged,int strokeGapMs,int holdMs) {
        uint current=GetCurrentThreadId(); Message message;
        PeekMessageW(out message,IntPtr.Zero,0,0,0); // Give this thread an input queue.
        if(target==0 || !AttachThreadInput(current,target,true)) throw new Exception("AttachThreadInput failed");
        var saved=new byte[256]; bool captured=false;
        try {
            captured=GetKeyboardState(saved); if(!captured) throw new Exception("GetKeyboardState failed");
            var layout=GetKeyboardLayout(target);
            foreach(var k in strokes) {
                var state=new byte[256]; KeyState(state,k,true);
                if(!SetKeyboardState(state)) throw new Exception("SetKeyboardState failed");
                long scan=(long)MapVirtualKeyExW((uint)k.Vk,0,layout);
                long l=1L | (scan<<16) | (k.Extended?1L<<24:0) | (k.Fake?1L<<25:0);
                // Alt alone makes a system key message with the context bit; with Ctrl
                // held (AltGr) Windows posts ordinary key messages.
                bool sys=k.Alt && !k.Ctrl && !k.AltGr;
                uint down=sys?0x104u:0x100u,up=sys?0x105u:0x101u;
                if(sys) l|=1L<<29;
                if(!k.UpOnly) for(int i=0;i<k.Repeats;i++) {
                    long dl=i==0?l:(l|(1L<<30));
                    if(synchronous) Send(h,down,k.Vk,dl); else Post(h,down,k.Vk,dl);
                }
                if(!k.DownOnly) {
                    if(strokeGapMs>0) Thread.Sleep(strokeGapMs);
                    KeyState(state,k,false);
                    if(!SetKeyboardState(state)) throw new Exception("SetKeyboardState failed");
                    if(synchronous) Send(h,up,k.Vk,l|0xC0000000L); else Post(h,up,k.Vk,l|0xC0000000L);
                }
                if(strokeGapMs>0) Thread.Sleep(strokeGapMs);
            }
            if(marker==0 && holdMs>0) Thread.Sleep(holdMs);
            if(marker>0) {
                // The last stroke's modifiers stay set until the barrier: the
                // target translates the posted key later, and must still see them.
                long markerL=1L | ((long)MapVirtualKeyExW((uint)marker,0,layout)<<16);
                if(synchronous) { Send(h,0x100,marker,markerL); Send(h,0x101,marker,markerL|0xC0000000L); }
                else { Post(h,0x100,marker,markerL); Post(h,0x101,marker,markerL|0xC0000000L); }
                var deadline=DateTime.UtcNow.AddSeconds(5);
                while(!acknowledged()) {
                    if(DateTime.UtcNow>=deadline) throw new Exception("Console key acknowledgment timed out");
                    Thread.Sleep(10);
                }
            }
        } finally {
            bool restored=!captured || SetKeyboardState(saved);
            bool detached=AttachThreadInput(current,target,false);
            if(!restored || !detached) throw new Exception("Keyboard state restore/detach failed");
        }
    }
    public class LayoutScope { public IntPtr Old,Current; public bool NewlyLoaded; }
    // Only the hidden target thread is activated; do not broadcast a change.
    public static LayoutScope UseLayout(IntPtr h,uint tid,string id) {
        var layouts=new IntPtr[GetKeyboardLayoutList(0,null)]; GetKeyboardLayoutList(layouts.Length,layouts);
        var scope=new LayoutScope { Old=GetKeyboardLayout(tid),Current=LoadKeyboardLayoutW(id,0x80) };
        if(scope.Current==IntPtr.Zero) return null;
        scope.NewlyLoaded=Array.IndexOf(layouts,scope.Current)<0;
        IntPtr result;
        if(SendMessageTimeoutW(h,0x50,IntPtr.Zero,scope.Current,2,2000,out result)==IntPtr.Zero || GetKeyboardLayout(tid)!=scope.Current) {
            RestoreLayout(h,tid,scope); return null;
        }
        return scope;
    }
    public static void RestoreLayout(IntPtr h,uint tid,LayoutScope scope) {
        IntPtr result;
        if(SendMessageTimeoutW(h,0x50,IntPtr.Zero,scope.Old,2,2000,out result)==IntPtr.Zero || GetKeyboardLayout(tid)!=scope.Old)
            throw new Exception("Hidden target keyboard layout restore failed");
        if(scope.NewlyLoaded && !UnloadKeyboardLayout(scope.Current)) throw new Exception("Task-loaded keyboard layout unload failed");
    }
    public static IntPtr ThreadLayout(uint tid) { return GetKeyboardLayout(tid); }
    public static uint WindowThread(IntPtr h) { int pid; return GetWindowThreadProcessId(h,out pid); }
    // The threads of process pid that own top-level windows on this desktop,
    // except the console window itself (whose reported thread is the client's).
    // conhost's input thread owns its touch/IME indicator windows.
    public static uint[] InputThreadCandidates(int pid) {
        var preferred=new List<uint>(); var others=new List<uint>();
        EnumWindows((h,p)=> { int id; uint tid=GetWindowThreadProcessId(h,out id); string cls=Class(h);
            if(id!=pid || cls=="ConsoleWindowClass") return true;
            var list=(cls.Contains("UAC")||cls.Contains("Touch Tooltip")||cls.Contains("Cicero"))?preferred:others;
            if(!list.Contains(tid)) list.Add(tid); return true; },IntPtr.Zero);
        foreach(var t in others) if(!preferred.Contains(t)) preferred.Add(t);
        return preferred.ToArray();
    }
}
'@

function Startup-Fingerprint {
    $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'koreterm\startup-attempts.json'
    if(-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false; Hash=$null; Modified=$null } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Assert-AdoptedStartup($Fingerprint) {
    if(($BaselineHash -and $Fingerprint.Hash -ne $BaselineHash.ToLowerInvariant()) -or
        ($BaselineModifiedUtc -and (-not $Fingerprint.Exists -or
            [datetimeoffset]::Parse($Fingerprint.Modified) -ne [datetimeoffset]::Parse($BaselineModifiedUtc)))) {
        throw 'Real startup state differs from the adopted baseline; stop launches.'
    }
}
if(-not $Driver) {
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not $CompileOnly -and -not (Test-Path -LiteralPath (Join-Path $Bin 'koreterm.exe'))) { throw 'Bin must contain a built koreterm.exe.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $compile=Join-Path $Run 'compile.cmd'; $helper=Join-Path $Run 'console-input-records.exe'; $attach=Join-Path $Run 'console-attach-info.exe'
    @('@echo off',('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" > "{4}" 2>&1' -f
        (Join-Path $root 'scripts\dev-windows.cmd'),(Join-Path $PSScriptRoot 'console-input-records.c'),$helper,(Join-Path $Run 'console-input-records.obj'),(Join-Path $Run 'compile.log')),
        'if errorlevel 1 exit /b %errorlevel%',
        ('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" >> "{4}" 2>&1' -f
        (Join-Path $root 'scripts\dev-windows.cmd'),(Join-Path $PSScriptRoot 'console-attach-info.c'),$attach,(Join-Path $Run 'console-attach-info.obj'),(Join-Path $Run 'compile.log')),
        'exit /b %errorlevel%') | Set-Content -LiteralPath $compile -Encoding ascii
    $compileJob=[KeyRecords]::CreateOwnedJob(); $cp=$null
    try {
        $cp=[KeyRecords]::Launch($env:ComSpec,('"{0}" /d /c ""{1}""' -f $env:ComSpec,$compile),$root,$null,$compileJob,0x08000000)
        if([KeyRecords]::WaitForSingleObject($cp.process,60000) -ne 0) { throw 'Helper compilation timed out.' }
        [uint32]$compileCode=0; [void][KeyRecords]::GetExitCodeProcess($cp.process,[ref]$compileCode)
        if($compileCode -ne 0 -or -not (Test-Path -LiteralPath $helper) -or -not (Test-Path -LiteralPath $attach)) { throw "Helper compilation failed ($compileCode); inspect Run/compile.log." }
    } finally {
        [void][KeyRecords]::StopOwnedJob($compileJob)
        if($cp) { [void][KeyRecords]::CloseHandle($cp.thread); [void][KeyRecords]::CloseHandle($cp.process) }
    }
    if($CompileOnly) { Write-Host 'Console key record harness C/C# compilation: PASS; no launches.'; exit }
    $before=Startup-Fingerprint; Assert-AdoptedStartup $before; $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-console-key-records.ps1'
    $portable=Join-Path $Run 'source\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'source\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'koreterm.portable') -Value '' -NoNewline
    foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    $desktopName='koreterm-keyrec-'+[guid]::NewGuid().ToString('N')
    $desktop=[KeyRecords]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA; $job=[IntPtr]::Zero; $pi=$null; $code=1
    try {
        $job=[KeyRecords]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $command='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver' -f $pwsh,$PSCommandPath,$portable,$Run
        if($Observe) { $command+=' -Observe' }; if($SkipPSReadLine) { $command+=' -SkipPSReadLine' }
        $pi=[KeyRecords]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job,0x08000000)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([KeyRecords]::WaitForSingleObject($pi.process,500) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [uint32]$code=0; [void][KeyRecords]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $owned=0
        if($job -ne [IntPtr]::Zero) { try { $owned=[KeyRecords]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][KeyRecords]::CloseHandle($pi.thread); [void][KeyRecords]::CloseHandle($pi.process) }
        [void][KeyRecords]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyFailure=$null
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }
        @{Before=$before;After=$after;Unchanged=$unchanged;HistoryUnchanged=($null -eq $historyFailure);
            OwnedJobCleanedUp=($null -eq $cleanupError);OwnedProcessCount=$owned} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if($historyFailure) { throw $historyFailure }
        if(-not $unchanged) { throw 'Real startup state changed; stop launches.' }; Assert-AdoptedStartup $after
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Console key record driver failed ($code); inspect results.json in Run." }
    Write-Host 'Console key record harness completed; inspect per-case results.json.'; exit
}

# Driver: every child inherits this private desktop and sandboxed AppData.
$driverDesktop=[KeyRecords]::DesktopName()
if(-not $driverDesktop.StartsWith('koreterm-keyrec-',[StringComparison]::Ordinal)) { throw 'Driver is not on the task private desktop.' }
if(-not (Test-Path -LiteralPath (Join-Path $Bin 'koreterm.portable'))) { throw 'Driver requires portable marker.' }
foreach($dir in @('LOCALAPPDATA','APPDATA')) {
    $value=[Environment]::GetEnvironmentVariable($dir)
    if(-not $value -or -not [IO.Path]::GetFullPath($value).StartsWith($Run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Driver AppData isolation failed.' }
}
$checks=[Collections.Generic.List[object]]::new(); $job=[KeyRecords]::CreateOwnedJob(); $terminal=$null; $reference=$null; $shell=$null
$helper=Join-Path $Run 'console-input-records.exe'; $attachInfo=Join-Path $Run 'console-attach-info.exe'
$records=Join-Path $Run 'records.csv'; $ready=Join-Path $Run 'ready.txt'; $stop=Join-Path $Run 'stop.txt'
$refRecords=Join-Path $Run 'ref-records.csv'; $refReady=Join-Path $Run 'ref-ready.txt'; $refStop=Join-Path $Run 'ref-stop.txt'
function Read-Records([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)) { return @() }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try { $csv=$reader.ReadToEnd() } finally { $reader.Dispose() }
    # The observer may be appending. Only parse complete CSV rows.
    $end=$csv.LastIndexOf("`n")
    if($end -lt 0) { return @() }
    $csv=$csv.Substring(0,$end+1)
    return @($csv | ConvertFrom-Csv | Where-Object { $_.Event -eq 'KEY' } | ForEach-Object {
        @{KeyDown=[int]$_.KeyDown;Repeat=[int]$_.Repeat;VirtualKey=[int]$_.VirtualKey;ScanCode=[int]$_.ScanCode;CodeUnit=[int]$_.CodeUnit;ControlState=[uint32]$_.ControlState} })
}
function Wait-Ready([string]$Path,[IntPtr]$Process,[int]$Seconds) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do {
        if(Test-Path -LiteralPath $Path) { $text=(Get-Content -LiteralPath $Path -Raw); if($text -and $text.Contains("`n")) { return $text.Trim().Split(',') } }
        if([KeyRecords]::WaitForSingleObject($Process,0) -eq 0) { throw "Process exited before its observer was ready ($Path)." }
        Start-Sleep -Milliseconds 50
    } while([datetime]::UtcNow -lt $deadline)
    throw "Observer ready timeout: $Path"
}
function Record-Text($r) { 'KEY kd={0} rc={1} vk={2} sc={3} uc={4} cs={5}' -f $r.KeyDown,$r.Repeat,$r.VirtualKey,$r.ScanCode,$r.CodeUnit,$r.ControlState }
function Expand-Repeats([hashtable[]]$Records) {
    $out=@()
    foreach($r in $Records) { for($n=0;$n -lt [Math]::Max(1,$r.Repeat);$n++) { $c=$r.Clone(); $c.Repeat=1; $out+=$c } }
    return $out
}
function Run-Keys([IntPtr]$Target,[uint32]$Thread,[string]$Path,[KeyRecords+Stroke[]]$Strokes,[int]$Marker) {
    $offset=@(Read-Records $Path).Count
    $acknowledged=[Func[bool]] {
        $snapshot=@(Read-Records $Path)
        for($i=$offset;$i -lt $snapshot.Count;$i++) {
            if($snapshot[$i].VirtualKey -eq $Marker -and $snapshot[$i].KeyDown -eq 0) { return $true }
        }
        return $false
    }
    [KeyRecords]::Keys($Target,$Thread,$Strokes,$false,$Marker,$acknowledged,120,0)
    # The barrier proves the messages were processed, not that every record
    # is in: conhost's TranslateMessageEx posts a key's WM_CHARs behind the
    # messages already queued, so they can land after the marker's records.
    # Wait for the stream to settle, then drop the marker's records wherever
    # they are.
    $all=@(Read-Records $Path); $settled=[datetime]::UtcNow.AddMilliseconds(250); $deadline=[datetime]::UtcNow.AddSeconds(3)
    while([datetime]::UtcNow -lt $settled -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
        $again=@(Read-Records $Path)
        if($again.Count -ne $all.Count) { $all=$again; $settled=[datetime]::UtcNow.AddMilliseconds(250) }
    }
    $actual=if($all.Count -gt $offset) { @($all[$offset..($all.Count-1)]) } else { @() }
    $markers=@($actual | Where-Object { $_.VirtualKey -eq $Marker })
    if($markers.Count -ne 2) { throw "Console case barrier: expected the marker's two records, found $($markers.Count)." }
    return @($actual | Where-Object { $_.VirtualKey -ne $Marker })
}
function Stroke([int]$Vk,[switch]$Ctrl,[switch]$Alt,[switch]$AltGr,[switch]$Shift,[switch]$Extended,[int]$Repeats=1,[switch]$DownOnly,[switch]$UpOnly,[switch]$Fake) {
    $s=[KeyRecords+Stroke]::new(); $s.Vk=$Vk; $s.Ctrl=$Ctrl.IsPresent; $s.Alt=$Alt.IsPresent; $s.AltGr=$AltGr.IsPresent; $s.Shift=$Shift.IsPresent
    $s.Extended=$Extended.IsPresent; $s.Repeats=$Repeats; $s.DownOnly=$DownOnly.IsPresent; $s.UpOnly=$UpOnly.IsPresent; $s.Fake=$Fake.IsPresent; return $s
}
# Posts the same strokes to koreterm's surface and to the reference console
# window, and compares every record. Expect (optional) pins fields the case
# is about, so a reference that is itself wrong cannot pass the case.
function Compare-Case([string]$Name,[KeyRecords+Stroke[]]$Strokes,[hashtable[]]$Expect=@(),[string]$Layout=$null,[bool]$CompareReleases=$true) {
    $marker=if(($Strokes | Where-Object { $_.Vk -eq 0x70 }).Count -gt 0) { 0x71 } else { 0x70 }
    $scopes=@(); $status='PASS'; $detail=@()
    try {
        if($Layout) {
            foreach($target in @(@{Window=$surface;Thread=$surfaceThread},@{Window=$refWindow;Thread=$refThread})) {
                $scope=[KeyRecords]::UseLayout($target.Window,$target.Thread,$Layout)
                if($null -eq $scope) { $checks.Add(@{Name=$Name;Status='UNSUPPORTED';Error="layout $Layout unavailable"}); return }
                $scopes+=@{Target=$target.Window;Thread=$target.Thread;Scope=$scope}
            }
            Start-Sleep -Milliseconds 200
        }
        $ours=Run-Keys $surface $surfaceThread $records $Strokes $marker
        $theirs=Run-Keys $refWindow $refThread $refRecords $Strokes $marker
        # A dead key's release is where the two console hosts differ by
        # design (see the case list); such cases compare key downs only and
        # pin their releases through Expect.
        # Windows coalesces a posted autorepeat into one message with a repeat
        # count when the target has not dequeued the previous one; the record
        # carries that count, so both sides are compared expanded.
        $oursCompared=@(Expand-Repeats @($ours | Where-Object { $CompareReleases -or $_.KeyDown -eq 1 }))
        $theirsCompared=@(Expand-Repeats @($theirs | Where-Object { $CompareReleases -or $_.KeyDown -eq 1 }))
        if($oursCompared.Count -ne $theirsCompared.Count) { $status='FAIL'; $detail+="record count koreterm=$($oursCompared.Count) conhost=$($theirsCompared.Count)" }
        else {
            for($i=0;$i -lt $oursCompared.Count;$i++) {
                foreach($f in @('KeyDown','VirtualKey','ScanCode','CodeUnit','ControlState')) {
                    # conhost zeroes the scan code of a "fake" character message (the
                    # accent a dead key flushes before Enter); koreterm keeps the key's.
                    # Only that record, in a dead-key case, is exempt.
                    if($f -eq 'ScanCode' -and -not $CompareReleases -and $theirsCompared[$i][$f] -eq 0 -and $theirsCompared[$i]['CodeUnit'] -ne 0) { continue }
                    if($oursCompared[$i][$f] -ne $theirsCompared[$i][$f]) { $status='FAIL'; $detail+="record $i ${f}: koreterm=$($oursCompared[$i][$f]) conhost=$($theirsCompared[$i][$f])" }
                }
            }
        }
        foreach($e in $Expect) {
            $hit=@($ours | Where-Object { $ok=$true; foreach($k in $e.Keys) { if($_[$k] -ne $e[$k]) { $ok=$false } }; $ok })
            if($hit.Count -ne 1) { $status='FAIL'; $detail+=('expected exactly one koreterm record with '+(($e.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')+", found $($hit.Count)") }
        }
        $checks.Add(@{Name=$Name;Status=$status;Detail=$detail;Koreterm=@($ours | ForEach-Object { Record-Text $_ });Conhost=@($theirs | ForEach-Object { Record-Text $_ })})
    } catch {
        $checks.Add(@{Name=$Name;Status='FAIL';Error=$_.Exception.Message})
    } finally {
        foreach($s in $scopes) { try { [KeyRecords]::RestoreLayout($s.Target,$s.Thread,$s.Scope) } catch { $checks.Add(@{Name="$Name layout restore";Status='FAIL';Error=$_.Exception.Message}) } }
    }
}
try {
    $config=Join-Path $Bin 'key-records.ghostty'
    @('shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false','keybind = clear','window-width = 80','window-height = 24') |
        Set-Content -LiteralPath $config
    $exe=Join-Path $Bin 'koreterm.exe'
    $command='"{0}" --config-file="{1}" -e "{2}" "{3}" "{4}" "{5}"' -f $exe,$config,$helper,$records,$ready,$stop
    $terminal=[KeyRecords]::Launch($exe,$command,$Bin,"WinSta0\$driverDesktop",$job,0x08000000)
    # The reference: the same observer in a real console window on this desktop.
    # conhost.exe is started as the parent so that the desktop binding is this
    # launch's, not the console driver's; its window is hidden (SW_HIDE) and
    # checked against this desktop before anything is posted to it.
    $conhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
    $reference=[KeyRecords]::Launch($conhost,('"{0}" "{1}" "{2}" "{3}" "{4}"' -f $conhost,$helper,$refRecords,$refReady,$refStop),$Run,"WinSta0\$driverDesktop",$job,0x10)
    $deadline=[datetime]::UtcNow.AddSeconds(45); $surface=[IntPtr]::Zero
    do {
        $surface=[KeyRecords]::Surface($terminal.pid)
        if($surface -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $ready)) { break }
        if([KeyRecords]::WaitForSingleObject($terminal.process,0) -eq 0) { throw 'Koreterm exited before observer ready.' }
        Start-Sleep -Milliseconds 50
    } while([datetime]::UtcNow -lt $deadline)
    if($surface -eq [IntPtr]::Zero) { throw 'Hidden startup timed out: no koreterm surface.' }
    $probe=Wait-Ready $ready $terminal.process 45
    if($probe.Count -lt 2 -or $probe[1] -ne '152') { throw 'Console observer input mode was not 0x98.' }
    $refProbe=Wait-Ready $refReady $reference.process 30
    if($refProbe.Count -lt 3 -or $refProbe[1] -ne '152') { throw 'Reference observer input mode was not 0x98.' }
    $refWindow=[IntPtr][int64]$refProbe[2]
    if($refWindow -eq [IntPtr]::Zero -or -not [KeyRecords]::IsWindow($refWindow)) { throw 'Reference console window unavailable.' }
    if(-not [KeyRecords]::OnCallerDesktop($refWindow)) { throw 'Reference console window is not on the task private desktop; nothing is posted to it.' }
    $surfaceThread=[KeyRecords]::WindowThread($surface)
    # conhost's input thread: the console window reports the client's thread,
    # so pick the conhost thread whose key state reaches the records (a Shift
    # press must come back with SHIFT_PRESSED).
    $refThread=[uint32]0; $threadProbe=@()
    foreach($candidate in [KeyRecords]::InputThreadCandidates($reference.pid)) {
        try {
            $probeRecords=Run-Keys $refWindow $candidate $refRecords ([KeyRecords+Stroke[]]@((Stroke 0x72 -Shift))) 0x70
            $threadProbe+=("thread {0}: {1}" -f $candidate,(@($probeRecords | ForEach-Object { Record-Text $_ }) -join ' | '))
            if(@($probeRecords | Where-Object { $_.VirtualKey -eq 0x72 -and $_.KeyDown -eq 1 -and ($_.ControlState -band 16) -ne 0 }).Count -eq 1) { $refThread=$candidate; break }
        } catch { $threadProbe+=("thread {0}: {1}" -f $candidate,$_.Exception.Message) }
    }
    $checks.Add(@{Name='conhost input thread probe';Status=$(if($refThread -ne 0){'PASS'}else{'FAIL'});Thread=$refThread;Candidates=@([KeyRecords]::InputThreadCandidates($reference.pid));Probe=$threadProbe})
    if($refThread -eq 0) { throw 'conhost input thread not found: no candidate thread carried Shift into the reference records.' }
    $usLayout=[KeyRecords]::UseLayout($surface,$surfaceThread,'00000409'); $refUsLayout=[KeyRecords]::UseLayout($refWindow,$refThread,'00000409')
    if($null -eq $usLayout -or $null -eq $refUsLayout) {
        throw ('Hidden target US keyboard layout could not be controlled: koreterm={0} (layout 0x{1:X}) conhost={2} (layout 0x{3:X}, thread {4}).' -f
            ($null -ne $usLayout),[KeyRecords]::ThreadLayout($surfaceThread).ToInt64(),($null -ne $refUsLayout),[KeyRecords]::ThreadLayout($refThread).ToInt64(),$refThread)
    }
    Start-Sleep -Milliseconds 400

    $cases=@(
        # The console host translates key breaks too: the release carries 'a'.
        @{Name='a';Strokes=@((Stroke 0x41));Expect=@(@{KeyDown=1;VirtualKey=0x41;CodeUnit=97},@{KeyDown=0;VirtualKey=0x41;CodeUnit=97})},
        @{Name='Shift+a';Strokes=@((Stroke 0x41 -Shift));Expect=@(@{KeyDown=1;VirtualKey=0x41;CodeUnit=65;ControlState=16})},
        @{Name='Shift+Enter';Strokes=@((Stroke 13 -Shift));Expect=@(@{KeyDown=1;VirtualKey=13;CodeUnit=13;ControlState=16})},
        @{Name='Ctrl+Enter';Strokes=@((Stroke 13 -Ctrl));Expect=@(@{KeyDown=1;VirtualKey=13;ControlState=8})},
        @{Name='Ctrl+[';Strokes=@((Stroke 0xDB -Ctrl));Expect=@(@{KeyDown=1;VirtualKey=0xDB;CodeUnit=27;ControlState=8})},
        @{Name='Ctrl+i';Strokes=@((Stroke 0x49 -Ctrl));Expect=@(@{KeyDown=1;VirtualKey=0x49;CodeUnit=9;ControlState=8})},
        @{Name='Ctrl+m';Strokes=@((Stroke 0x4D -Ctrl));Expect=@(@{KeyDown=1;VirtualKey=0x4D;CodeUnit=13;ControlState=8})},
        @{Name='Ctrl+period';Strokes=@((Stroke 0xBE -Ctrl));Expect=@(@{KeyDown=1;VirtualKey=0xBE;ControlState=8})},
        @{Name='Ctrl+comma';Strokes=@((Stroke 0xBC -Ctrl));Expect=@(@{KeyDown=1;VirtualKey=0xBC;CodeUnit=0;ControlState=8})},
        @{Name='Ctrl+Shift+Enter';Strokes=@((Stroke 13 -Ctrl -Shift));Expect=@(@{KeyDown=1;VirtualKey=13;ControlState=24})},
        @{Name='Shift+Escape';Strokes=@((Stroke 27 -Shift));Expect=@(@{KeyDown=1;VirtualKey=27;CodeUnit=27;ControlState=16})},
        @{Name='Shift+Tab';Strokes=@((Stroke 9 -Shift));Expect=@(@{KeyDown=1;VirtualKey=9;CodeUnit=9;ControlState=16})},
        @{Name='Alt+a';Strokes=@((Stroke 0x41 -Alt));Expect=@(@{KeyDown=1;VirtualKey=0x41;ControlState=2})},
        @{Name='Left arrow';Strokes=@((Stroke 0x25 -Extended));Expect=@(@{KeyDown=1;VirtualKey=0x25;CodeUnit=0;ControlState=256})},
        @{Name='Shift press alone';Strokes=@((Stroke 0x10 -Shift));Expect=@(@{KeyDown=1;VirtualKey=0x10;CodeUnit=0})},
        @{Name='Autorepeat a x3';Strokes=@((Stroke 0x41 -Repeats 3));Expect=@(@{KeyDown=0;VirtualKey=0x41})},
        @{Name='Alt+o-umlaut (German)';Strokes=@((Stroke 0xC0 -Alt));Expect=@(@{KeyDown=1;CodeUnit=246;ControlState=2});Layout='00000407'},
        @{Name='AltGr+q = @ (German)';Strokes=@((Stroke 0x51 -AltGr));Expect=@(@{KeyDown=1;VirtualKey=0x51;CodeUnit=64;ControlState=9});Layout='00000407'},
        @{Name='AltGr+7 = { (German)';Strokes=@((Stroke 0x37 -AltGr));Expect=@(@{KeyDown=1;VirtualKey=0x37;CodeUnit=123;ControlState=9});Layout='00000407'},
        # A latched dead key's break reads back as two accents in the console
        # host (one record attributed to the following key); koreterm sends the
        # accent once on that release, as Windows Terminal does. Key downs
        # are compared with conhost; the releases are pinned here.
        @{Name='Dead acute then e (German)';Strokes=@((Stroke 0xDD),(Stroke 0x45));CompareReleases=$false;
            Expect=@(@{KeyDown=1;VirtualKey=0xDD;CodeUnit=0},@{KeyDown=0;VirtualKey=0xDD;CodeUnit=180},@{KeyDown=1;VirtualKey=0x45;CodeUnit=233},@{KeyDown=0;VirtualKey=0x45;CodeUnit=101});Layout='00000407'},
        @{Name='Dead acute then Enter (German)';Strokes=@((Stroke 0xDD),(Stroke 13));CompareReleases=$false;
            Expect=@(@{KeyDown=0;VirtualKey=0xDD;CodeUnit=180},@{KeyDown=1;VirtualKey=13;CodeUnit=180},@{KeyDown=1;VirtualKey=13;CodeUnit=13},@{KeyDown=0;VirtualKey=13;CodeUnit=13});Layout='00000407'},
        # A Shift tap while the dead key is held leaves the accent latched: the
        # dead key's release still carries it once, and e still composes.
        @{Name='Dead acute, Shift tap, then e (German)';Strokes=@((Stroke 0xDD -DownOnly),(Stroke 0x10),(Stroke 0xDD -UpOnly),(Stroke 0x45));CompareReleases=$false;
            Expect=@(@{KeyDown=1;VirtualKey=0xDD;CodeUnit=0},@{KeyDown=1;VirtualKey=0x10;CodeUnit=0;ControlState=16},@{KeyDown=0;VirtualKey=0xDD;CodeUnit=180},@{KeyDown=1;VirtualKey=0x45;CodeUnit=233});Layout='00000407'},
        # AltGr as Windows posts it: the left Ctrl key messages carry bit 25
        # (FAKE_KEYSTROKE) and the console host ignores them, down and up; the
        # right Alt and the key are recorded with the raw LEFT_CTRL|RIGHT_ALT state.
        @{Name='AltGr+q with the fake Ctrl messages (German)';Strokes=@((Stroke 0x11 -AltGr -Fake -DownOnly),(Stroke 0x12 -AltGr -Extended -DownOnly),(Stroke 0x51 -AltGr),(Stroke 0x12 -Ctrl -Extended -UpOnly),(Stroke 0x11 -Fake -UpOnly));
            Expect=@(@{KeyDown=1;VirtualKey=0x12;CodeUnit=0;ControlState=265},@{KeyDown=1;VirtualKey=0x51;CodeUnit=64;ControlState=9},@{KeyDown=0;VirtualKey=0x12;CodeUnit=0;ControlState=264});Layout='00000407'}
    )
    foreach($number in 13..24) {
        $vk=0x70+$number-1
        $cases+=@{Name="F$number";Strokes=@((Stroke $vk));Expect=@(@{KeyDown=1;VirtualKey=$vk;CodeUnit=0},@{KeyDown=0;VirtualKey=$vk;CodeUnit=0})}
    }
    foreach($case in $cases) { Compare-Case $case.Name $case.Strokes $case.Expect $case.Layout ($case.CompareReleases -ne $false) }

    if(-not $SkipPSReadLine) {
        # Phase 2: PSReadLine. Shift+Enter must add a line, not run the line.
        $shellReady=Join-Path $Run 'shell-ready.txt'; $count=Join-Path $Run 'history-count.txt'
        $pwshExe=(Get-Command pwsh.exe).Source
        # History goes to a run-local file and is never saved, before the first read. The ready file
        # is written only once both options read back, so nothing is typed into an unisolated pwsh.
        $shellHistory=Join-Path $Run 'shell-history.txt'
        $shellCommand='"{0}" --config-file="{1}" -e "{2}" -NoLogo -NoProfile -NoExit -Command "Set-PSReadLineOption -HistorySavePath ''{4}'' -HistorySaveStyle SaveNothing; if((Get-PSReadLineOption).HistorySaveStyle -eq ''SaveNothing'' -and (Get-PSReadLineOption).HistorySavePath -ceq ''{4}'') {{ Set-Content -LiteralPath ''{3}'' -Value ready }}"' -f $exe,$config,$pwshExe,$shellReady,$shellHistory
        $shell=[KeyRecords]::Launch($exe,$shellCommand,$Bin,"WinSta0\$driverDesktop",$job,0x08000000)
        $deadline=[datetime]::UtcNow.AddSeconds(60); $shellSurface=[IntPtr]::Zero
        do {
            $shellSurface=[KeyRecords]::Surface($shell.pid)
            if($shellSurface -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $shellReady)) { break }
            if([KeyRecords]::WaitForSingleObject($shell.process,0) -eq 0) { throw 'Koreterm (pwsh) exited before ready.' }
            Start-Sleep -Milliseconds 100
        } while([datetime]::UtcNow -lt $deadline)
        if($shellSurface -eq [IntPtr]::Zero -or -not (Test-Path -LiteralPath $shellReady)) { throw 'pwsh inside koreterm did not become ready.' }
        $shellThread=[KeyRecords]::WindowThread($shellSurface)
        $shellLayout=[KeyRecords]::UseLayout($shellSurface,$shellThread,'00000409')
        if($null -eq $shellLayout) { throw 'pwsh surface US layout could not be controlled.' }
        Start-Sleep -Milliseconds 1500 # PSReadLine's first prompt.
        $layoutHandle=[KeyRecords]::ThreadLayout($shellThread)
        $shellPids=@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.ParentProcessId -eq $shell.pid } | Select-Object -ExpandProperty ProcessId)
        # Posted like typing; the keyboard state is held until the surface's
        # pump has translated the keys.
        function Type-Text([string]$Text) {
            $strokes=@()
            foreach($ch in $Text.ToCharArray()) {
                $scan=[KeyRecords]::VkKeyScanExW($ch,$layoutHandle)
                if($scan -eq -1) { throw "untypable character $ch" }
                $vk=$scan -band 0xFF; $shift=(($scan -shr 8) -band 1) -ne 0
                $strokes+=(Stroke $vk -Shift:$shift)
            }
            [KeyRecords]::Keys($shellSurface,$shellThread,[KeyRecords+Stroke[]]$strokes,$false,0,$null,40,250)
        }
        function Read-Shell([string]$Label) {
            if($shellPids.Count -eq 0) { return @('(pwsh pid not found)') }
            $out=Join-Path $Run ("shell-{0}.txt" -f $Label)
            $p=[KeyRecords]::Launch($attachInfo,('"{0}" {1} "{2}" dump' -f $attachInfo,$shellPids[0],$out),$Run,"WinSta0\$driverDesktop",$job,0x08000000)
            try {
                if([KeyRecords]::WaitForSingleObject($p.process,10000) -ne 0) { return @('(attach timeout)') }
                return @(Get-Content -LiteralPath $out | Where-Object { $_ -ne '' })
            } finally { [void][KeyRecords]::CloseHandle($p.thread); [void][KeyRecords]::CloseHandle($p.process) }
        }
        Type-Text 'echo A'
        [KeyRecords]::Keys($shellSurface,$shellThread,[KeyRecords+Stroke[]]@((Stroke 13 -Shift)),$false,0,$null,40,250)
        Start-Sleep -Milliseconds 500
        $afterShiftEnter=Read-Shell 'after-shift-enter'
        Type-Text 'echo B'
        [KeyRecords]::Keys($shellSurface,$shellThread,[KeyRecords+Stroke[]]@((Stroke 13)),$false,0,$null,40,250)
        Start-Sleep -Milliseconds 900
        Type-Text ("(Get-History).Count | Set-Content -LiteralPath '{0}'" -f $count)
        [KeyRecords]::Keys($shellSurface,$shellThread,[KeyRecords+Stroke[]]@((Stroke 13)),$false,0,$null,40,250)
        $deadline=[datetime]::UtcNow.AddSeconds(15); $value=$null
        do { if(Test-Path -LiteralPath $count) { $value=(Get-Content -LiteralPath $count -Raw).Trim(); if($value) { break } }; Start-Sleep -Milliseconds 100 } while([datetime]::UtcNow -lt $deadline)
        $final=Read-Shell 'final'
        try { [KeyRecords]::RestoreLayout($shellSurface,$shellThread,$shellLayout) } catch { $checks.Add(@{Name='PSReadLine layout restore';Status='FAIL';Error=$_.Exception.Message}) }
        # The -NoExit -Command startup line is history entry 1. Shift+Enter joining
        # the two typed lines makes them entry 2 (3 if it ran the first line),
        # and the screen read right after it shows PSReadLine's `>>` continuation.
        $continuation=@($afterShiftEnter | Where-Object { $_ -like '>>*' }).Count -gt 0
        $checks.Add(@{Name='PSReadLine Shift+Enter adds a line';Status=$(if($value -eq '2' -and $continuation){'PASS'}else{'FAIL'});HistoryCount=$value;ContinuationShown=$continuation;ScreenAfterShiftEnter=$afterShiftEnter;ScreenFinal=$final})
    }
} catch {
    $checks.Add(@{Name='Infrastructure';Status='FAIL';Error=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage})
} finally {
    $cleanupError=$null; $owned=0
    if($usLayout -and $surface) { try { [KeyRecords]::RestoreLayout($surface,$surfaceThread,$usLayout) } catch { $checks.Add(@{Name='Infrastructure';Status='FAIL';Error=$_.Exception.Message}) } }
    if($refUsLayout -and $refWindow) { try { [KeyRecords]::RestoreLayout($refWindow,$refThread,$refUsLayout) } catch { $checks.Add(@{Name='Infrastructure';Status='FAIL';Error=$_.Exception.Message}) } }
    foreach($s in @($stop,$refStop)) { Set-Content -LiteralPath $s -Value '' -NoNewline }
    Start-Sleep -Milliseconds 300
    try { $owned=[KeyRecords]::StopOwnedJob($job) } catch { $cleanupError=$_; $checks.Add(@{Name='Owned job cleanup';Status='FAIL';Error=$_.Exception.Message}) }
    foreach($p in @($terminal,$reference,$shell)) { if($p) { [void][KeyRecords]::CloseHandle($p.thread); [void][KeyRecords]::CloseHandle($p.process) } }
    @{InputMode=152;ProtocolsRequested=@();Delivery='posted key messages, characters from the target TranslateMessage';
        ObserverPID=$(if($probe){[int]$probe[0]}else{$null});ReferenceObserverPID=$(if($refProbe){[int]$refProbe[0]}else{$null});
        TerminalPID=$(if($terminal){$terminal.pid}else{$null});OwnedProcessCount=$owned;OwnedJobCleanedUp=($null -eq $cleanupError);Checks=@($checks)} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'results.json')
}
if(@($checks | Where-Object {$_.Name -eq 'Infrastructure' -or $_.Name -eq 'Owned job cleanup'}).Count -gt 0) { exit 2 }
if(-not $Observe -and @($checks | Where-Object {$_.Status -eq 'FAIL'}).Count -gt 0) { exit 1 }
exit 0
