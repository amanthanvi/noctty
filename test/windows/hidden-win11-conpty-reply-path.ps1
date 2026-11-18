#requires -Version 7.0
<#
The ConPTY reply path (the kitty report's shortlist #0): which terminal replies
reach a console program through the bundled ConPTY's input, and in what shape,
with Win32 input mode (DEC 9001) on. Supply a built Bin and a NEW Run directory.
noctty is copied into Run as a portable copy with both AppData roots
redirected; the driver and every window live on a private desktop. Input is
posted key messages only (WM_KEYDOWN/WM_KEYUP pairs, the target's keyboard
state set explicitly); nothing touches the clipboard or the foreground.

Phase 1 runs console-reply-reader.c as noctty's `-e` child once per reader
state (a, a16, b, c; see the C file). Each run first types keys, so conhost has
seen 9001 records (reader b shows them as records with their virtual keys; for
the others DECRQM 9001 must come back set), and readers a and a16 then push
Kitty keyboard flags, as yazi does. Every reply then crosses noctty's own
write path:
  - real replies: the reader sends DA1, OSC 11 and two kitty graphics queries
    and noctty answers them (cases 6 and 1);
  - injected replies: noctty `text:` bindings write the exact bytes the kitty
    report's cases name, one binding per write, so a split is two bindings
    posted 300 ms apart (cases 1-4, and injected DA1/OSC 11 as controls).
In-band C0 bytes (written by bindings too, never part of a reply) trigger the
reader's queries and delimit the cases.

Two more reader states, each opt-in:
  c-inbox  reader c behind the in-box conhost (NOCTTY_CONPTY=inbox), the
           control for d's far end;
  d        Windows OpenSSH: noctty runs System32's ssh.exe, which connects to
           a one-connection sshd (System32's sshd.exe in debug mode, run as
           this user, on 127.0.0.1 only, with a key pair, host key and config
           made for the run in Run\sshd; no service is installed or touched),
           and reader c runs on the far side, behind the pseudo console sshd
           makes for the session (the in-box conhost).

Phase 2 (case 7) types into PSReadLine inside noctty, with its history
redirected into Run and set to SaveNothing before its first read: a stale
2033 report (as noctty would send it on a tab switch) and the other case
shapes are injected at the prompt, and a real tab switch is made after the
shell set `?2033h`. The prompt row is read back from the console buffer.

-CompileOnly builds the C helpers and the C# and launches nothing.
Results: Run\results.json and Run\results.md. Exit 0 when the run completed
(observations are recorded, not judged), 2 for an infrastructure failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $CompileOnly,
    [switch] $Driver,
    [ValidateSet('a','a16','b','c','c-inbox','d')] [string[]] $Readers = @('a','a16','b','c'),
    # The driver's copy of -Readers: pwsh -File passes it as one comma-separated string.
    [ValidatePattern('^(a|a16|b|c|c-inbox|d)(,(a|a16|b|c|c-inbox|d))*$')] [string] $ReaderList,
    [switch] $SkipPSReadLine,
    [ValidateRange(60,1800)] [int] $DriverTimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class ReplyPath {
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
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
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
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr p,uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr j,uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr j,int t,out JobAccounting a,uint size,IntPtr r);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long t);
    public static long Ticks() { long t; QueryPerformanceCounter(out t); return t; }
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
    // CREATE_SUSPENDED and BELOW_NORMAL_PRIORITY_CLASS are always added, so the
    // job owns the process before it runs. desktop names the child's desktop
    // explicitly: a child does not inherit a private desktop by itself.
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
    // Every terminal surface of process pid, in z order under its host.
    public static IntPtr[] Surfaces(int pid) {
        var found=new List<IntPtr>();
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") EnumChildWindows(h,(c,q)=> { if(Class(c)=="noctty.win32") found.Add(c); return true; },IntPtr.Zero);
            return true;
        },IntPtr.Zero); return found.ToArray();
    }
    public static string DesktopName() {
        var name=new StringBuilder(256); int needed;
        if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,name,name.Capacity*2,out needed)) throw new Exception("Driver desktop identity unavailable");
        return name.ToString();
    }
    // EnumWindows lists only the calling thread's desktop.
    public static bool OnCallerDesktop(IntPtr target) {
        bool found=false;
        EnumWindows((h,p)=> { if(h==target) { found=true; return false; } EnumChildWindows(h,(c,q)=> { if(c==target) found=true; return !found; },IntPtr.Zero); return !found; },IntPtr.Zero);
        return found;
    }
    static void Post(IntPtr h,uint m,int w,long l) {
        if(!PostMessageW(h,m,new IntPtr(w),new IntPtr(l))) throw new Exception("Key post failed");
    }
    public class Stroke { public int Vk; public bool Shift; }
    // Posts each stroke's WM_KEYDOWN/WM_KEYUP pair with the target thread's
    // keyboard state set to exactly that key (and Shift when asked), held
    // holdMs past the last stroke so the target's own pump translates it.
    // No WM_CHAR is posted: the target's TranslateMessage makes the characters.
    public static void Keys(IntPtr h,uint target,Stroke[] strokes,int strokeGapMs,int holdMs) {
        uint current=GetCurrentThreadId(); Message message;
        PeekMessageW(out message,IntPtr.Zero,0,0,0);
        if(target==0 || !AttachThreadInput(current,target,true)) throw new Exception("AttachThreadInput failed");
        var saved=new byte[256]; bool captured=false;
        try {
            captured=GetKeyboardState(saved); if(!captured) throw new Exception("GetKeyboardState failed");
            var layout=GetKeyboardLayout(target);
            foreach(var k in strokes) {
                var state=new byte[256];
                if(k.Shift) state[0x10]=state[0xA0]=0x80;
                state[k.Vk]=0x80;
                if(!SetKeyboardState(state)) throw new Exception("SetKeyboardState failed");
                long scan=(long)MapVirtualKeyExW((uint)k.Vk,0,layout);
                long l=1L | (scan<<16);
                Post(h,0x100,k.Vk,l);
                if(strokeGapMs>0) Thread.Sleep(strokeGapMs);
                state[k.Vk]=0; if(k.Vk==0x10) { state[0x10]=state[0xA0]=0; }
                if(!SetKeyboardState(state)) throw new Exception("SetKeyboardState failed");
                Post(h,0x101,k.Vk,l|0xC0000000L);
                if(strokeGapMs>0) Thread.Sleep(strokeGapMs);
            }
            if(holdMs>0) Thread.Sleep(holdMs);
        } finally {
            bool restored=!captured || SetKeyboardState(saved);
            bool detached=AttachThreadInput(current,target,false);
            if(!restored || !detached) throw new Exception("Keyboard state restore/detach failed");
        }
    }
    public class LayoutScope { public IntPtr Old,Current; public bool NewlyLoaded; }
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
}
'@

# The bytes each binding writes. Controls are read by the reader (see
# console-reply-reader.c); the rest are the kitty report's case shapes.
$esc = [char]27
$bindings = [ordered]@{
    f1  = @{ Name='delimiter'; Bytes="$([char]2)" }
    f2  = @{ Name='push Kitty flags'; Bytes="$([char]1)" }
    f3  = @{ Name='pop Kitty flags'; Bytes="$([char]15)" }
    f4  = @{ Name='DA1 query'; Bytes="$([char]4)" }
    f5  = @{ Name='OSC 11 query'; Bytes="$([char]5)" }
    f6  = @{ Name='kitty query, OK'; Bytes="$([char]6)" }
    f7  = @{ Name='kitty query, error'; Bytes="$([char]14)" }
    f8  = @{ Name='APC OK'; Bytes="${esc}_Gi=31;OK${esc}\" }
    f9  = @{ Name='APC error'; Bytes="${esc}_Gi=31;ENOENT:No such file${esc}\" }
    f10 = @{ Name='APC split mid-body, 1st'; Bytes="${esc}_Gi=31;O" }
    f11 = @{ Name='APC split mid-body, 2nd'; Bytes="K${esc}\" }
    f12 = @{ Name='APC split ESC|_, 1st'; Bytes="${esc}" }
    f13 = @{ Name='APC split ESC|_, 2nd'; Bytes="_Gi=31;OK${esc}\" }
    f14 = @{ Name='APC split ESC|\, 1st'; Bytes="${esc}_Gi=31;OK${esc}" }
    f15 = @{ Name='APC split ESC|\, 2nd'; Bytes='\' }
    f16 = @{ Name='APC feature-shaped'; Bytes="${esc}_Gi=31,e=T,U=1;OK${esc}\" }
    f17 = @{ Name='2033 report, visible'; Bytes="${esc}[?999;1n" }
    f18 = @{ Name='DECRPM 2033'; Bytes="${esc}[?2033;2`$y" }
    f19 = @{ Name='multiple-cursors reply'; Bytes="${esc}[>1;2;3;29;30;40;100;101 q" }
    f20 = @{ Name='injected OSC 11 reply'; Bytes="${esc}]11;rgb:1e1e/1e1e/1e1e${esc}\" }
    # A second OSC shape: the in-box conhost takes an OSC 11 reply off its input itself.
    print_screen = @{ Name='injected OSC 4 reply'; Bytes="${esc}]4;1;rgb:cdcd/0000/0000${esc}\" }
    f21 = @{ Name='injected DA1 reply'; Bytes="${esc}[?62;22c" }
    f22 = @{ Name='2033 report, hidden'; Bytes="${esc}[?999;2n" }
    pause = @{ Name='DECRQM 9001 query'; Bytes="$([char]16)" }
    scroll_lock = @{ Name='Kitty flags query'; Bytes="$([char]18)" }
}
function Binding-Line([string] $Key, [string] $Bytes) {
    # Every byte as \xNN, so nothing in a reply (=, ;, spaces) meets the config parser.
    'keybind = {0}=text:{1}' -f $Key, (-join ([Text.Encoding]::ASCII.GetBytes($Bytes) | ForEach-Object { '\x{0:x2}' -f $_ }))
}
function Hex([string] $Text) { -join ([Text.Encoding]::ASCII.GetBytes($Text) | ForEach-Object { '{0:x2}' -f $_ }) }
function Show([string] $Text) {
    -join ($Text.ToCharArray() | ForEach-Object {
        $c=[int]$_
        if($c -eq 27) { 'ESC' } elseif($c -lt 32 -or $c -eq 127) { '<{0:x2}>' -f $c } else { [string]$_ } })
}

function Startup-Fingerprint {
    $path=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if(-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false; Hash=$null; Modified=$null } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}

if(-not $Driver) {
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if(-not $CompileOnly -and -not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    if(-not $CompileOnly -and -not (Test-Path -LiteralPath (Join-Path $Bin 'conpty.dll'))) { throw 'Bin must hold the bundled conpty.dll: this measures the bundled ConPTY.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $compile=Join-Path $Run 'compile.cmd'
    $lines=@('@echo off')
    foreach($source in @('console-reply-reader','console-attach-info')) {
        $lines+=('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" >> "{4}" 2>&1' -f
            (Join-Path $root 'scripts\dev-windows.cmd'),(Join-Path $PSScriptRoot "$source.c"),(Join-Path $Run "$source.exe"),(Join-Path $Run "$source.obj"),(Join-Path $Run 'compile.log'))
        $lines+='if errorlevel 1 exit /b %errorlevel%'
    }
    $lines+='exit /b 0'
    $lines | Set-Content -LiteralPath $compile -Encoding ascii
    $compileJob=[ReplyPath]::CreateOwnedJob(); $cp=$null
    try {
        $cp=[ReplyPath]::Launch($env:ComSpec,('"{0}" /d /c ""{1}""' -f $env:ComSpec,$compile),$root,$null,$compileJob,0x08000000)
        if([ReplyPath]::WaitForSingleObject($cp.process,120000) -ne 0) { throw 'Helper compilation timed out.' }
        [uint32]$compileCode=0; [void][ReplyPath]::GetExitCodeProcess($cp.process,[ref]$compileCode)
        if($compileCode -ne 0) { throw "Helper compilation failed ($compileCode); inspect Run/compile.log." }
    } finally {
        [void][ReplyPath]::StopOwnedJob($compileJob)
        if($cp) { [void][ReplyPath]::CloseHandle($cp.thread); [void][ReplyPath]::CloseHandle($cp.process) }
    }
    if($CompileOnly) { Write-Host 'ConPTY reply-path harness C/C# compilation: PASS; no launches.'; exit 0 }
    if($Readers -contains 'd') {
        # Reader d's far end: keys, host key and config for one loopback sshd,
        # all inside Run. The private keys are readable by this user only.
        $sshDir=Join-Path $Run 'sshd'; [void](New-Item -ItemType Directory -Path $sshDir)
        $openssh=Join-Path ([Environment]::GetFolderPath('System')) 'OpenSSH'
        foreach($tool in @('ssh.exe','sshd.exe','ssh-keygen.exe')) { if(-not (Test-Path -LiteralPath (Join-Path $openssh $tool))) { throw "Reader d needs $tool in $openssh." } }
        foreach($name in @('host_ed25519','client_ed25519')) {
            & (Join-Path $openssh 'ssh-keygen.exe') -q -t ed25519 -N '' -C "noctty-replypath-$name" -f (Join-Path $sshDir $name)
            if($LASTEXITCODE -ne 0) { throw "ssh-keygen failed for $name." }
            & icacls.exe (Join-Path $sshDir $name) /inheritance:r /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" | Out-Null
            if($LASTEXITCODE -ne 0) { throw "Could not restrict $name to this user." }
        }
        Copy-Item -LiteralPath (Join-Path $sshDir 'client_ed25519.pub') -Destination (Join-Path $sshDir 'authorized_keys')
        $listening=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalPort })
        $port=Get-Random -Minimum 47000 -Maximum 49000; while($listening -contains $port) { $port=Get-Random -Minimum 47000 -Maximum 49000 }
        $user=[Environment]::UserName
        @("Port $port",'ListenAddress 127.0.0.1',"HostKey $(Join-Path $sshDir 'host_ed25519')","AuthorizedKeysFile $(Join-Path $sshDir 'authorized_keys')",
          'PubkeyAuthentication yes','PasswordAuthentication no','KbdInteractiveAuthentication no','StrictModes no',"PidFile $(Join-Path $sshDir 'sshd.pid')","AllowUsers $user") |
            Set-Content -LiteralPath (Join-Path $sshDir 'sshd_config') -Encoding ascii
        @{Port=$port;SshVersion=((& (Join-Path $openssh 'ssh.exe') -V 2>&1) -join ' ')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sshDir 'ssh.json')
    }
    $before=Startup-Fingerprint; $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-conpty-reply-path.ps1'
    $portable=Join-Path $Run 'source\bin'; [void](New-Item -ItemType Directory -Path $portable)
    Get-ChildItem -LiteralPath $Bin -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'source\share') -Recurse }
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
    $desktopName='noctty-replypath-'+[guid]::NewGuid().ToString('N')
    $desktop=[ReplyPath]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA; $job=[IntPtr]::Zero; $pi=$null; $code=1
    try {
        $job=[ReplyPath]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $command='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver -ReaderList {4}' -f $pwsh,$PSCommandPath,$portable,$Run,($Readers -join ',')
        if($SkipPSReadLine) { $command+=' -SkipPSReadLine' }
        $pi=[ReplyPath]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job,0x08000000)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([ReplyPath]::WaitForSingleObject($pi.process,500) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [uint32]$code=0; [void][ReplyPath]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $owned=0
        if($job -ne [IntPtr]::Zero) { try { $owned=[ReplyPath]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][ReplyPath]::CloseHandle($pi.thread); [void][ReplyPath]::CloseHandle($pi.process) }
        [void][ReplyPath]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyFailure=$null
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }
        @{Unchanged=$unchanged;HistoryUnchanged=($null -eq $historyFailure);OwnedJobCleanedUp=($null -eq $cleanupError);OwnedProcessCount=$owned} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if($historyFailure) { throw $historyFailure }
        if(-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "ConPTY reply-path driver failed ($code); inspect results.json in Run." }
    Write-Host "ConPTY reply-path harness completed; see $(Join-Path $Run 'results.md')."; exit 0
}

# Driver: on the private desktop, with sandboxed AppData. Its own console is
# hidden, so a failure before the results are written goes to driver-error.txt.
trap { if(-not $Driver) { break }; Set-Content -LiteralPath (Join-Path $Run 'driver-error.txt') -Value ("{0}`n{1}" -f $_.Exception.Message,$_.InvocationInfo.PositionMessage); exit 2 }
if($ReaderList) { $Readers=$ReaderList.Split(',') }
$driverDesktop=[ReplyPath]::DesktopName()
if(-not $driverDesktop.StartsWith('noctty-replypath-',[StringComparison]::Ordinal)) { throw 'Driver is not on the task private desktop.' }
if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable'))) { throw 'Driver requires portable marker.' }
foreach($dir in @('LOCALAPPDATA','APPDATA')) {
    $value=[Environment]::GetEnvironmentVariable($dir)
    if(-not $value -or -not [IO.Path]::GetFullPath($value).StartsWith($Run.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Driver AppData isolation failed.' }
}
$exe=Join-Path $Bin 'noctty.exe'; $reader=Join-Path $Run 'console-reply-reader.exe'; $attachInfo=Join-Path $Run 'console-attach-info.exe'
$config=Join-Path $Bin 'reply-path.ghostty'
$configLines=@('shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false',
    'quit-after-last-window-closed = true','keybind = clear','window-width = 100','window-height = 30',
    'keybind = f23=new_tab','keybind = f24=previous_tab')
foreach($key in $bindings.Keys) { $configLines+=(Binding-Line $key $bindings[$key].Bytes) }
$configLines | Set-Content -LiteralPath $config -Encoding ascii
$job=[ReplyPath]::CreateOwnedJob(); $sessions=[Collections.Generic.List[object]]::new(); $failures=[Collections.Generic.List[string]]::new()
$frequency=[Diagnostics.Stopwatch]::Frequency

function Fkey([string] $Key) {
    $s=[ReplyPath+Stroke]::new()
    $s.Vk=switch($Key) { 'pause' { 0x13 } 'scroll_lock' { 0x91 } 'print_screen' { 0x2C } default { 0x6F+[int]$Key.Substring(1) } }
    return $s
}
function Vk([int] $Vk, [switch] $Shift) { $s=[ReplyPath+Stroke]::new(); $s.Vk=$Vk; $s.Shift=$Shift.IsPresent; return $s }
function Read-Log([string] $Path) {
    if(-not (Test-Path -LiteralPath $Path)) { return @() }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $r=[IO.StreamReader]::new($stream)
    try { $text=$r.ReadToEnd() } finally { $r.Dispose() }
    $end=$text.LastIndexOf("`n"); if($end -lt 0) { return @() }
    return @($text.Substring(0,$end).Split("`n") | ForEach-Object { $_.TrimEnd("`r") })
}
function Delimiters([string] $Path) { @(Read-Log $Path | Where-Object { $_ -like 'CMD,*,02,*' }).Count }
function Wait-Ready([string] $Path, $Process, [int] $Seconds) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do {
        if(Test-Path -LiteralPath $Path) { $t=Get-Content -LiteralPath $Path -Raw; if($t -and $t.Contains("`n")) { return $t.Trim().Split(',') } }
        if([ReplyPath]::WaitForSingleObject($Process.process,0) -eq 0) { throw "Process exited before ready ($Path)." }
        Start-Sleep -Milliseconds 50
    } while([datetime]::UtcNow -lt $deadline)
    throw "Ready timeout: $Path"
}

# One reader session: noctty runs the reader; every step ends with the
# delimiter binding, and the next step waits until the reader logged it.
function Invoke-ReaderSession([string] $Mode) {
    $dir=Join-Path $Run "reader-$Mode"; [void](New-Item -ItemType Directory -Path $dir)
    $log=Join-Path $dir 'reader.log'; $ready=Join-Path $dir 'ready.txt'; $stop=Join-Path $dir 'stop.txt'
    $steps=[Collections.Generic.List[object]]::new(); $session=@{Mode=$Mode;Steps=$steps;Dir=$dir}
    $readerMode=if($Mode -in @('c-inbox','d')) { 'c' } else { $Mode }
    $readerArgs='{0} "{1}" "{2}" "{3}"' -f $readerMode,$log,$ready,$stop
    $sshd=$null
    if($Mode -eq 'd') {
        # One connection (-d), loopback only, this run's config; its debug log stays in Run.
        if($Run -match '\s') { throw 'Reader d needs a Run path without spaces: the far side gets the reader command unquoted.' }
        $sshDir=Join-Path $Run 'sshd'; $ssh=Get-Content -LiteralPath (Join-Path $sshDir 'ssh.json') -Raw | ConvertFrom-Json
        $openssh=Join-Path ([Environment]::GetFolderPath('System')) 'OpenSSH'
        $sshd=[ReplyPath]::Launch((Join-Path $openssh 'sshd.exe'),('"{0}" -d -f "{1}" -E "{2}"' -f (Join-Path $openssh 'sshd.exe'),(Join-Path $sshDir 'sshd_config'),(Join-Path $sshDir 'sshd-debug.log')),$sshDir,"WinSta0\$driverDesktop",$job,0x08000000)
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while(-not (Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $ssh.Port -ErrorAction SilentlyContinue)) {
            if([datetime]::UtcNow -ge $deadline -or [ReplyPath]::WaitForSingleObject($sshd.process,0) -eq 0) { throw 'The run''s sshd did not start listening.' }
            Start-Sleep -Milliseconds 100
        }
        $session.Ssh=@{Version=$ssh.SshVersion;SshdPid=$sshd.pid}
        $sshArgs='-tt -F none -p {0} -i "{1}" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o UserKnownHostsFile="{2}" -o StrictHostKeyChecking=accept-new 127.0.0.1' -f $ssh.Port,(Join-Path $sshDir 'client_ed25519'),(Join-Path $sshDir 'known_hosts')
        $command='"{0}" --config-file="{1}" --window-save-state=never --command=cmd.exe -e "{2}" {3} {4} {5}' -f $exe,$config,(Join-Path $openssh 'ssh.exe'),$sshArgs,$reader,$readerArgs.Replace('"','')
    } else {
        $command='"{0}" --config-file="{1}" --window-save-state=never --command=cmd.exe -e "{2}" {3}' -f $exe,$config,$reader,$readerArgs
    }
    if($Mode -eq 'c-inbox') { $env:NOCTTY_CONPTY='inbox' }
    try { $terminal=[ReplyPath]::Launch($exe,$command,$Bin,"WinSta0\$driverDesktop",$job,0x08000000) }
    finally { if($Mode -eq 'c-inbox') { Remove-Item Env:NOCTTY_CONPTY } }
    $layout=$null; $surface=[IntPtr]::Zero; $thread=0
    try {
        $deadline=[datetime]::UtcNow.AddSeconds(60)
        do {
            $all=[ReplyPath]::Surfaces($terminal.pid); if($all.Count -gt 0) { $surface=$all[0] }
            if($surface -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $ready)) { break }
            if([ReplyPath]::WaitForSingleObject($terminal.process,0) -eq 0) { throw "noctty exited before the reader was ready ($Mode)." }
            Start-Sleep -Milliseconds 50
        } while([datetime]::UtcNow -lt $deadline)
        if($surface -eq [IntPtr]::Zero) { throw "No noctty surface ($Mode)." }
        if(-not [ReplyPath]::OnCallerDesktop($surface)) { throw 'The noctty surface is not on the private desktop; nothing is posted to it.' }
        $probe=Wait-Ready $ready $terminal 30
        $session.Ready=@{Pid=[int]$probe[0];InputModeBefore=('0x{0:x}' -f [uint32]$probe[1]);InputMode=('0x{0:x}' -f [uint32]$probe[2]);OutputMode=('0x{0:x}' -f [uint32]$probe[3]);InputCodePage=[int]$probe[4]}
        if($Mode -eq 'd') {
            # ssh.exe's own console input mode, read from its pseudo console (noctty's bundled one).
            $sshPid=@(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.ParentProcessId -eq $terminal.pid } | Select-Object -ExpandProperty ProcessId)
            if($sshPid.Count -eq 1) {
                $out=Join-Path $dir 'ssh-console.txt'
                $p=[ReplyPath]::Launch($attachInfo,('"{0}" {1} "{2}"' -f $attachInfo,$sshPid[0],$out),$dir,"WinSta0\$driverDesktop",$job,0x08000000)
                try { if([ReplyPath]::WaitForSingleObject($p.process,10000) -eq 0 -and (Test-Path -LiteralPath $out)) { $session.Ssh.ClientInputMode=('0x{0:x}' -f [uint32](Get-Content -LiteralPath $out -TotalCount 1).Split(',')[0]) } }
                finally { [void][ReplyPath]::CloseHandle($p.thread); [void][ReplyPath]::CloseHandle($p.process) }
            } else { $session.Ssh.ClientInputMode="ssh.exe not found under noctty ($($sshPid.Count))" }
        }
        $thread=[ReplyPath]::WindowThread($surface)
        $layout=[ReplyPath]::UseLayout($surface,$thread,'00000409')
        if($null -eq $layout) { throw 'The surface thread US layout could not be set.' }
        Start-Sleep -Milliseconds 800

        function Step([string] $Name, [string[]] $Keys, [int] $GapMs=0, [object[]] $Typed=@()) {
            $count=Delimiters $log
            $start=[ReplyPath]::Ticks()
            if($Typed.Count -gt 0) { [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]$Typed,60,150) }
            $first=$true
            foreach($k in $Keys) {
                if(-not $first -and $GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
                [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey $k)),20,60); $first=$false
            }
            Start-Sleep -Milliseconds 400 # a reply to a query arrives before the delimiter
            [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey 'f1')),20,60)
            $deadline=[datetime]::UtcNow.AddSeconds(5)
            while((Delimiters $log) -le $count) {
                if([datetime]::UtcNow -ge $deadline) { $steps.Add(@{Name=$Name;Keys=$Keys;Start=$start;Barrier='TIMEOUT'}); throw "Delimiter after '$Name' never reached the reader ($Mode)." }
                Start-Sleep -Milliseconds 20
            }
            $steps.Add(@{Name=$Name;Keys=$Keys;Start=$start;Barrier='OK'})
        }
        # Real state: typed keys go to conhost as 9001 records first.
        Step 'typed: Shift tap, h, i (9001 records)' @() 0 @((Vk 0x10 -Shift),(Vk 0x48),(Vk 0x49))
        Step 'mode 9001: DECRQM' @('pause')
        if($Mode -in @('a','a16')) {
            Step 'push Kitty flags (CSI > 1 u)' @('f2')
            Step 'Kitty flags: CSI ? u' @('scroll_lock')
            Step 'typed after the push: Shift tap, h' @() 0 @((Vk 0x10 -Shift),(Vk 0x48))
        }
        Step 'case 6: DA1 (before)' @('f4')
        Step 'case 6: OSC 11 (before)' @('f5')
        Step 'case 1: noctty kitty reply, OK' @('f6')
        Step 'case 1: noctty kitty reply, error' @('f7')
        Step 'case 1: APC OK, one write' @('f8')
        Step 'case 1: APC error, one write' @('f9')
        Step 'case 1: APC OK, split mid-body' @('f10','f11') 300
        Step 'case 1: APC OK, split ESC|_' @('f12','f13') 300
        Step 'case 1: APC OK, split ESC|\' @('f14','f15') 300
        Step 'case 2: APC feature-shaped' @('f16')
        Step 'case 3: 2033 report, visible' @('f17')
        Step 'case 3: DECRPM 2033' @('f18')
        Step 'case 4: multiple-cursors reply' @('f19')
        Step 'case 6: injected OSC 11 reply' @('f20')
        Step 'case 6: injected OSC 4 reply' @('print_screen')
        Step 'case 6: injected DA1 reply' @('f21')
        Step 'case 7 shape: 2033 report, hidden' @('f22')
        Step 'case 6: DA1 (after)' @('f4')
        Step 'case 6: OSC 11 (after)' @('f5')
        if($Mode -in @('a','a16')) { Step 'pop Kitty flags (CSI < u)' @('f3') }
    } catch {
        $failures.Add("reader ${Mode}: $($_.Exception.Message)")
    } finally {
        if($layout) { try { [ReplyPath]::RestoreLayout($surface,$thread,$layout) } catch { $failures.Add("reader ${Mode}: layout restore: $($_.Exception.Message)") } }
        Set-Content -LiteralPath $stop -Value '' -NoNewline
        if([ReplyPath]::WaitForSingleObject($terminal.process,10000) -ne 0) {
            # Only this launch's own process handle, which the run's job owns.
            $session.Stopped='terminated after the reader stopped'
            [void][ReplyPath]::TerminateProcess($terminal.process,1); [void][ReplyPath]::WaitForSingleObject($terminal.process,5000)
        } else { $session.Stopped='exited after the reader stopped' }
        [void][ReplyPath]::CloseHandle($terminal.thread); [void][ReplyPath]::CloseHandle($terminal.process)
        if($sshd) {
            # sshd -d serves one connection and exits; otherwise stop this launch's own handle.
            if([ReplyPath]::WaitForSingleObject($sshd.process,10000) -ne 0) { $session.SshdStopped='terminated'; [void][ReplyPath]::TerminateProcess($sshd.process,1); [void][ReplyPath]::WaitForSingleObject($sshd.process,5000) }
            else { $session.SshdStopped='exited after its one connection' }
            [void][ReplyPath]::CloseHandle($sshd.thread); [void][ReplyPath]::CloseHandle($sshd.process)
        }
    }
    $session.Log=@(Read-Log $log)
    $sessions.Add($session)
}

# Splits a reader log at its delimiters: segment i is what arrived for step i.
function Get-Segments($Session) {
    $segments=[Collections.Generic.List[object]]::new()
    $current=@{Records=[Collections.Generic.List[string]]::new();Units=[Text.StringBuilder]::new();Reads=[Collections.Generic.List[string]]::new();Commands=[Collections.Generic.List[string]]::new()}
    $control=@(1,2,4,5,6,14,15,16,18)
    $byteMode=$Session.Mode -in @('c','c-inbox','d')
    foreach($line in $Session.Log) {
        $f=$line.Split(',')
        switch($f[0]) {
            'READ' { $current.Reads.Add("read of $($f[2]) records") }
            'PEEK' { if([int]$f[2] -gt 0) { $current.Reads.Add("peek of $($f[2]) records") } }
            'SKIP' { $current.Reads.Add("skipped $($f[2]) records without a character") }
            'KEY' {
                $current.Records.Add(('kd={0} vk={1} sc={2} uc={3} cs={4}' -f $f[1],$f[3],$f[4],$f[5],$f[6]))
                if(-not $byteMode -and $f[1] -eq '1' -and [int]$f[5] -ne 0 -and [int]$f[5] -notin $control) { [void]$current.Units.Append([char][int]$f[5]) }
            }
            'BYTES' {
                $current.Reads.Add("ReadFile of $($f[2]) bytes")
                $hex=$f[3]
                for($i=0;$i -lt $hex.Length;$i+=2) { $b=[Convert]::ToInt32($hex.Substring($i,2),16); if($b -notin $control) { [void]$current.Units.Append([char]$b) } }
            }
            'CMD' {
                if($f[2] -eq '02') { $segments.Add($current); $current=@{Records=[Collections.Generic.List[string]]::new();Units=[Text.StringBuilder]::new();Reads=[Collections.Generic.List[string]]::new();Commands=[Collections.Generic.List[string]]::new()} }
                else { $current.Commands.Add("wrote $($f[2]): $($f[3])") }
            }
        }
    }
    return ,$segments
}

# What the source predicts (kitty report section 3) for a step and reader.
# Readers c-inbox and d have the in-box conhost for a pseudo console, which
# answers DA1 and DECRQM itself and returns no OSC 11 or kitty reply
# (docs/windows-vt-conformance.md, the measured query ownership differential);
# for injected replies the prediction is reader c's, from the 1.24 source.
function Get-Prediction([string] $Step, [string] $Mode, [string] $Written) {
    $vtInput=$Mode -ne 'b'
    $inbox=$Mode -in @('c-inbox','d')
    if($Step -eq 'mode 9001: DECRQM') { if($inbox) { return @{Text='answered by the in-box conhost';Regex='^\x1b\[\?9001;[0-4]\$y$'} } else { return @{Text='set (1)';Regex='^\x1b\[\?9001;1\$y$'} } }
    if($Step -eq 'Kitty flags: CSI ? u') { return @{Text='flags 1';Regex='^\x1b\[\?1u$'} }
    if($inbox -and $Step -like 'case 6: DA1*' -and $Step -notlike '*injected*') { return @{Text='the in-box conhost''s own DA1';Regex='^\x1b\[\?61;[0-9;]+c$'} }
    if($inbox -and (($Step -like 'case 6: OSC 11*' -and $Step -notlike '*injected*') -or $Step -like 'case 1: noctty kitty*')) { return @{Text='no reply (in-box conhost)';Exact=''} }
    if($Step -like 'case 1: noctty kitty reply, OK') { if($vtInput) { return @{Text='whole';Regex='^\x1b_Gi=31;OK\x1b\\$'} } else { return @{Text='lone \';Regex='^\\$'} } }
    if($Step -like 'case 1: noctty kitty reply, error') { if($vtInput) { return @{Text='whole';Regex='^\x1b_Gi=32;E[A-Z]+:[^\x1b]*\x1b\\$'} } else { return @{Text='lone \';Regex='^\\$'} } }
    if($Step -like 'case 6: DA1*' -and $Step -notlike '*injected*') { return @{Text='a DA1 reply';Regex='^\x1b\[\?[0-9;]+c$'} }
    if($Step -like 'case 6: OSC 11*' -and $Step -notlike '*injected*') { return @{Text='an OSC 11 reply';Regex='^\x1b\]11;rgb:[0-9a-f]+/[0-9a-f]+/[0-9a-f]+(\x1b\\|\x07)$'} }
    if($Step -like 'case 1: APC*' -or $Step -like 'case 2:*') {
        if(-not $vtInput) { return @{Text='lone \';Exact='\'} }
        if($Step -like '*ESC|_*') { return @{Text='the run without its ESC';Exact=$Written.Substring(1)} }
        return @{Text='whole';Exact=$Written}
    }
    if($Step -like 'case 3:*' -or $Step -like 'case 4:*' -or $Step -like 'case 6: injected*' -or $Step -like 'case 7 shape:*') {
        if($vtInput) { return @{Text='whole, as an escape';Exact=$Written} } else { return @{Text='whole, as typed text';Exact=$Written} }
    }
    return $null
}

try {
    foreach($mode in $Readers) { Invoke-ReaderSession $mode }

    if(-not $SkipPSReadLine) {
        # Case 7: PSReadLine. History goes to a run-local file, never saved, before the first read;
        # the ready file is written only once both options read back. The shell then sets ?2033h.
        $dir=Join-Path $Run 'psreadline'; [void](New-Item -ItemType Directory -Path $dir)
        $shellReady=Join-Path $dir 'ready.txt'; $shellHistory=Join-Path $dir 'history.txt'
        $pwshExe=(Get-Command pwsh.exe).Source
        $startup="Set-PSReadLineOption -HistorySavePath '$shellHistory' -HistorySaveStyle SaveNothing; if((Get-PSReadLineOption).HistorySaveStyle -eq 'SaveNothing' -and (Get-PSReadLineOption).HistorySavePath -ceq '$shellHistory') { [Console]::Write([char]27+'[?2033h'); Set-Content -LiteralPath '$shellReady' -Value ready }"
        $command='"{0}" --config-file="{1}" --window-save-state=never --command=cmd.exe -e "{2}" -NoLogo -NoProfile -NoExit -Command "{3}"' -f $exe,$config,$pwshExe,$startup
        $shell=[ReplyPath]::Launch($exe,$command,$Bin,"WinSta0\$driverDesktop",$job,0x08000000)
        $case7=@{Steps=[Collections.Generic.List[object]]::new()}
        $layout=$null
        try {
            $deadline=[datetime]::UtcNow.AddSeconds(60); $surface=[IntPtr]::Zero
            do {
                $all=[ReplyPath]::Surfaces($shell.pid); if($all.Count -gt 0) { $surface=$all[0] }
                if($surface -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $shellReady)) { break }
                if([ReplyPath]::WaitForSingleObject($shell.process,0) -eq 0) { throw 'noctty (pwsh) exited before ready.' }
                Start-Sleep -Milliseconds 100
            } while([datetime]::UtcNow -lt $deadline)
            if($surface -eq [IntPtr]::Zero -or -not (Test-Path -LiteralPath $shellReady)) { throw 'pwsh inside noctty did not become ready (history isolation not confirmed); nothing typed.' }
            if(-not [ReplyPath]::OnCallerDesktop($surface)) { throw 'The pwsh surface is not on the private desktop.' }
            $thread=[ReplyPath]::WindowThread($surface)
            $layout=[ReplyPath]::UseLayout($surface,$thread,'00000409')
            if($null -eq $layout) { throw 'pwsh surface US layout could not be set.' }
            Start-Sleep -Milliseconds 2000 # PSReadLine's first prompt
            $shellPids=@(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.ParentProcessId -eq $shell.pid } | Select-Object -ExpandProperty ProcessId)
            if($shellPids.Count -ne 1) { throw "Expected one pwsh child of noctty, found $($shellPids.Count)." }
            function Read-Shell([string] $Label) {
                $out=Join-Path $dir ("screen-{0}.txt" -f $Label)
                $p=[ReplyPath]::Launch($attachInfo,('"{0}" {1} "{2}" dump' -f $attachInfo,$shellPids[0],$out),$dir,"WinSta0\$driverDesktop",$job,0x08000000)
                try {
                    if([ReplyPath]::WaitForSingleObject($p.process,10000) -ne 0) { return @{Error='attach timeout'} }
                    $text=@(Get-Content -LiteralPath $out -Encoding utf8)
                    $head=$text[0].Split(',')
                    $rows=@($text | Select-Object -Skip 1 | Where-Object { $_ -ne '' })
                    return @{InputMode=('0x{0:x}' -f [uint32]$head[0]);Rows=$rows;Prompt=@($rows | Where-Object { $_ -like 'PS *' } | Select-Object -Last 1)}
                } finally { [void][ReplyPath]::CloseHandle($p.thread); [void][ReplyPath]::CloseHandle($p.process) }
            }
            $case7.AtPrompt=Read-Shell 'at-prompt'
            foreach($inject in @(@{Key='f22';Name='2033 report, hidden (what a tab switch would send with ?2033 stale)'},
                                 @{Key='f17';Name='2033 report, visible'},
                                 @{Key='f18';Name='DECRPM 2033'},
                                 @{Key='f19';Name='multiple-cursors reply'},
                                 @{Key='f8';Name='APC OK'},
                                 @{Key='f20';Name='injected OSC 11 reply'})) {
                [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey $inject.Key)),20,60)
                Start-Sleep -Milliseconds 800
                $screen=Read-Shell $inject.Key
                $case7.Steps.Add(@{Name=$inject.Name;Written=(Show $bindings[$inject.Key].Bytes);Prompt=$screen.Prompt;InputMode=$screen.InputMode})
                # Escape is RevertLine at a PSReadLine prompt.
                [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Vk 0x1B)),20,60)
                Start-Sleep -Milliseconds 500
            }
            # The real thing today: ?2033h was set by the shell's startup; switch away and back.
            $before=Read-Shell 'before-tab-switch'
            [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey 'f23')),20,60)
            Start-Sleep -Milliseconds 2500
            $surfacesDuring=@([ReplyPath]::Surfaces($shell.pid)).Count; $visibleDuring=[ReplyPath]::IsWindowVisible($surface)
            $second=@([ReplyPath]::Surfaces($shell.pid) | Where-Object { $_ -ne $surface } | Select-Object -First 1)
            if($second.Count -eq 1) { [ReplyPath]::Keys($second[0],[ReplyPath]::WindowThread($second[0]),[ReplyPath+Stroke[]]@((Fkey 'f24')),20,60) }
            Start-Sleep -Milliseconds 1500
            $visibleAfter=[ReplyPath]::IsWindowVisible($surface)
            $afterSwitch=Read-Shell 'after-tab-switch'
            $case7.TabSwitch=@{SurfacesDuring=$surfacesDuring;PwshSurfaceVisibleDuring=$visibleDuring;PwshSurfaceVisibleAfter=$visibleAfter;PromptBefore=$before.Prompt;PromptAfter=$afterSwitch.Prompt}
        } catch {
            $failures.Add("case 7: $($_.Exception.Message)")
        } finally {
            if($layout) { try { [ReplyPath]::RestoreLayout($surface,$thread,$layout) } catch { $failures.Add("case 7: layout restore: $($_.Exception.Message)") } }
            [void][ReplyPath]::CloseHandle($shell.thread); [void][ReplyPath]::CloseHandle($shell.process)
        }
    }
} catch {
    $failures.Add("infrastructure: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)")
} finally {
    $owned=0; try { $owned=[ReplyPath]::StopOwnedJob($job) } catch { $failures.Add("owned job cleanup: $($_.Exception.Message)") }
}

# Results.
$rows=[Collections.Generic.List[object]]::new()
foreach($session in $sessions) {
    $segments=Get-Segments $session
    for($i=0;$i -lt $session.Steps.Count;$i++) {
        $step=$session.Steps[$i]
        $segment=if($i -lt $segments.Count) { $segments[$i] } else { $null }
        $observed=if($segment) { $segment.Units.ToString() } else { '' }
        $written=-join @($step.Keys | ForEach-Object { $bindings[$_].Bytes } | Where-Object { [int][char]$_[0] -ge 27 -or $_.Length -gt 1 })
        $prediction=Get-Prediction $step.Name $session.Mode $written
        $verdict='-'
        if($prediction) {
            if($prediction.Regex) { $verdict=if($observed -cmatch $prediction.Regex) { 'as predicted' } else { 'DIFFERS' } }
            else { $verdict=if($observed -ceq $prediction.Exact) { 'as predicted' } else { 'DIFFERS' } }
        }
        $rows.Add([ordered]@{Reader=$session.Mode;Step=$step.Name;Written=(Show $written);WrittenHex=(Hex $written);Observed=(Show $observed);ObservedHex=(Hex $observed);
            Predicted=$(if($prediction){$prediction.Text}else{'-'});Verdict=$verdict;Reads=@($(if($segment){$segment.Reads}));Records=@($(if($segment){$segment.Records}));Commands=@($(if($segment){$segment.Commands}))})
    }
}
$result=[ordered]@{
    Harness='hidden-win11-conpty-reply-path.ps1'
    ConPty=[ordered]@{File=(Join-Path $Bin 'conpty.dll');FileVersion=(Get-Item -LiteralPath (Join-Path $Bin 'conpty.dll')).VersionInfo.FileVersion;OpenConsole=(Get-Item -LiteralPath (Join-Path $Bin 'OpenConsole.exe')).VersionInfo.FileVersion;Sha256=(Get-FileHash -LiteralPath (Join-Path $Bin 'conpty.dll')).Hash.ToLowerInvariant()}
    Readers=@($sessions | ForEach-Object { [ordered]@{Mode=$_.Mode;Ready=$_.Ready;Steps=$_.Steps.Count;Stopped=$_.Stopped;Ssh=$_.Ssh;SshdStopped=$_.SshdStopped} })
    Rows=$rows
    Case7=$case7
    OwnedProcessCount=$owned
    Failures=$failures
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'results.json') -Encoding utf8
$md=[Collections.Generic.List[string]]::new()
$md.Add('| Reader | Step | Written | Observed (key-down units / bytes) | Predicted | Verdict |'); $md.Add('|---|---|---|---|---|---|')
foreach($r in $rows) { $md.Add(('| {0} | {1} | `{2}` | `{3}` | {4} | {5} |' -f $r.Reader,$r.Step,$r.Written,$r.Observed,$r.Predicted,$r.Verdict)) }
$md | Set-Content -LiteralPath (Join-Path $Run 'results.md') -Encoding utf8
if(@($failures | Where-Object { $_ -like 'infrastructure*' -or $_ -like 'owned job*' }).Count -gt 0) { exit 2 }
exit 0
