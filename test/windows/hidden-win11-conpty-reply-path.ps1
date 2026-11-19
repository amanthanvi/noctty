#requires -Version 7.1
<#
The ConPTY reply path (the kitty report's shortlist #0): which terminal replies
reach a console program through the bundled ConPTY's input, and in what shape,
with Win32 input mode (DEC 9001) on. Supply a built Bin and a NEW Run directory.
noctty is copied into Run as a portable copy, without the noctty.ico a portable
copy needs before it registers the product AUMID, with both AppData roots
redirected; the driver and every window live on a private desktop. Input is
posted key messages only (WM_KEYDOWN/WM_KEYUP pairs, the target's keyboard
state set explicitly), and only to a window on that desktop; nothing touches
the clipboard or the foreground, and the copy runs with clipboard reads and
writes denied. Every noctty launch pins its later tabs to
`direct:<System32>\cmd.exe /D`, and every cmd.exe the harness starts itself is
System32's with /D, so the user's cmd AutoRun stays out of the run. The one
exception is the helper compile: it calls scripts\dev-windows.cmd, whose
`for /f` children are cmd.exe without /D and run the user's AutoRun. An AutoRun
hook such as fnm's then leaves its junctions in the user's own
%LOCALAPPDATA%\fnm_multishells, since the compile runs before LOCALAPPDATA is
redirected, not in the run directory. The real startup ledger, the PowerShell history, the AUMID
registration and the clipboard sequence number are compared before and after,
and no link may remain in the run directory.

Phase 1 runs console-reply-reader.c as noctty's `-e` child once per reader
state (see the C file). Each run first types keys, so conhost has seen 9001
records (reader b shows them as records with their virtual keys; for the
others DECRQM 9001 must come back set), and readers a and a16 then push Kitty
keyboard flags, as yazi does. Every reply then crosses noctty's own write path:
  - real replies: the reader sends DA1, OSC 11 and two kitty graphics queries
    and noctty answers them (cases 6 and 1);
  - injected replies: noctty `text:` bindings write the exact bytes the kitty
    report's cases name, one binding per write, so a split is two bindings
    posted 300 ms apart (cases 1-4, and injected DA1/OSC 11/OSC 4 as controls).
In-band C0 bytes (written by bindings too, never part of a reply) trigger the
reader's queries and delimit the cases.

Reader states, -Readers (a list, or one comma-separated string):
  a, a16, b, c   the default: bundled ConPTY
  c-inbox        reader c behind the in-box conhost (NOCTTY_CONPTY=inbox), the
                 control for d's far end
  d, d-notiming  Windows OpenSSH: noctty runs System32's ssh.exe (no agent,
                 X11 or port forwarding, no GSSAPI delegation), which connects
                 to a one-connection sshd (System32's sshd.exe -d, run as this
                 user on 127.0.0.1 only, keys only, forwarding off, with keys,
                 host key and config made for the run in Run\sshd and deleted
                 after it); reader c runs on the far side, behind the pseudo
                 console sshd makes for the session (the in-box conhost).
                 d-notiming adds -o ObscureKeystrokeTiming=no. The far side
                 runs through sshd's DefaultShell (HKLM\SOFTWARE\OpenSSH;
                 cmd.exe when unset) as this user, with the real LOCALAPPDATA,
                 not the run's, and a PowerShell DefaultShell (pwsh here) also
                 loads the user's own PowerShell profile; both readers are
                 refused without -AllowSshFarSideUserProfileAndLocalAppData,
                 and need a Run path of letters, digits, _ . - and \ only,
                 since the far side's shell gets the reader command unquoted.

Phase 2 (case 7) types into PSReadLine inside noctty (pwsh -NoProfile), with
its history redirected into Run and set to SaveNothing before its first read:
a stale 2033 report (as noctty would send it on a tab switch) and the other
case shapes are injected at the prompt, and a real tab switch is made after
the shell set `?2033h`.

Not measured here (named in the results too): case 7's half after the
prompt-time reset, and stale extra cursors left drawn, both deferred to
Phase 3, when mode 2033 and multiple cursors exist; reader (a') Neovim; reader
(e) WSL, which the user's standing no-WSL rule excludes; case 5, deferred with
OSC 5522; cmd and [Console]::ReadKey as readers; real keyboard input.

-CompileOnly builds the C helpers and the C# and launches nothing.
Results: Run\results.json and Run\results.md. Exit codes:
  0  complete: every requested reader ran every step, case 7 ran (unless
     -SkipPSReadLine) with its controls, and every positive control came back
     as predicted (other rows are observations, recorded, not judged);
  1  incomplete: a reader failed or died (no clean stop in its log), a
     delimiter or readiness wait failed, case 7 failed or showed no prompt
     row before or after its tab switch, a positive control differed from its
     prediction, or a reader ran in the wrong state (its input mode, or a16
     without 16-record reads);
  2  infrastructure failure, in the driver or the outer phase (including a
     NOCTTY_CONPTY the run inherits, and a Run directory whose ACL does not
     read back as this user's alone);
  3  an isolation guard changed (startup ledger, history, AUMID key,
     clipboard sequence number), a link was left in the run directory, or
     an ssh secret could not be deleted (kept, recorded, guards compared).
-Sabotage is for the harness's own controls: it breaks one thing on purpose
(the delimiter, the reader mid-run, or the DA1 control), and the run must
then exit 1. -Sabotage setup fails the setup at the point where reader d's
ssh keys already exist (when d is requested), and the run must exit 2 with
any keys deleted. -Sabotage key holds an ssh secret's file open through the
cleanup, and the run must exit 3 with the guards compared and the failure
recorded. -Sabotage acl gives Everyone a rule on the Run directory once it is
made, and the run must exit 2 with nothing compiled or launched.

Contracts.98-ConptyReplyPath.ps1 pins this script and the reader in two
ways: checks and mutations for each safety property, and SHA-256 pins. This
whole script and the whole reader are pinned, and so, again, are the regions
between `# pin-begin:` and `# pin-end:` comments and the functions the
contract names, so a failure also says which block changed. Any edit to this
script or the reader fails the contract until its pin is updated in the same
change. Not pinned, since other harnesses share them: console-attach-info.c,
which case 7 reads the prompt with; scripts\windows-harness-history.ps1, whose
guard decides exit 3's history branch; and scripts\dev-windows.cmd, which the
helper compile runs (exit 2).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $CompileOnly,
    [switch] $Driver,
    [string[]] $Readers = @('a','a16','b','c'),
    [switch] $AllowSshFarSideUserProfileAndLocalAppData,
    [switch] $SkipPSReadLine,
    [ValidateSet('none','delimiter','reader','control','setup','key','acl')] [string] $Sabotage = 'none',
    [ValidateRange(60,1800)] [int] $DriverTimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
# Any failure this script does not handle is infrastructure (exit 2), in the outer phase and the
# driver alike. The driver's console is hidden, so its failure also goes to driver-error.txt.
trap {
    if(-not $Driver) { Write-Host "Infrastructure: $($_.Exception.Message)"; exit 2 }
    Set-Content -LiteralPath (Join-Path $Run 'driver-error.txt') -Value ("{0}`n{1}" -f $_.Exception.Message,$_.InvocationInfo.PositionMessage); exit 2
}
. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
# Every cmd.exe the harness starts itself is System32's, with /D, so the user's AutoRun stays out of the
# run (the helper compile's dev-windows.cmd is the exception; see the header).
$cmdExe = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
# pin-begin: reader-list (Contracts.98 pins this block by hash; it decides which readers run and are required)
# pwsh -File passes a list as one string; accept "a,b" and @('a','b') alike.
$readerStates = @('a','a16','b','c','c-inbox','d','d-notiming')
$Readers = @($Readers | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach($r in $Readers) { if($r -notin $readerStates) { throw "Unknown reader '$r'; known: $($readerStates -join ', ')." } }
if($Readers.Count -eq 0) { throw 'No reader requested.' }
$sshReaders = @($Readers | Where-Object { $_ -in @('d','d-notiming') })
if($sshReaders.Count -gt 0 -and -not $AllowSshFarSideUserProfileAndLocalAppData) {
    throw 'Readers d and d-notiming run the far side through sshd''s DefaultShell (HKLM\SOFTWARE\OpenSSH; cmd.exe when unset) as this user, with the real LOCALAPPDATA, not the run''s; a PowerShell DefaultShell also loads the user''s own PowerShell profile. Pass -AllowSshFarSideUserProfileAndLocalAppData to accept that.'
}
# pin-end: reader-list
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
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
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
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    // The dead-reader control: one process, by the exact PID the caller identified.
    public static void KillExact(int pid) {
        var h=OpenProcess(0x0001|0x00100000,false,pid); if(h==IntPtr.Zero) throw new Exception("OpenProcess failed: "+Marshal.GetLastWin32Error());
        try { if(!TerminateProcess(h,1)) throw new Exception("TerminateProcess failed"); WaitForSingleObject(h,5000); } finally { CloseHandle(h); }
    }
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
    // Nothing is posted to a window this thread's desktop does not list.
    public static void Keys(IntPtr h,uint target,Stroke[] strokes,int strokeGapMs,int holdMs) {
        if(!OnCallerDesktop(h)) throw new Exception("Refusing to post keys to a window that is not on this private desktop");
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
    f10 = @{ Name='APC OK split mid-body, 1st'; Bytes="${esc}_Gi=31;O" }
    f11 = @{ Name='APC OK split mid-body, 2nd'; Bytes="K${esc}\" }
    f12 = @{ Name='APC split ESC|_, 1st (OK and error)'; Bytes="${esc}" }
    f13 = @{ Name='APC OK split ESC|_, 2nd'; Bytes="_Gi=31;OK${esc}\" }
    f14 = @{ Name='APC OK split ESC|\, 1st'; Bytes="${esc}_Gi=31;OK${esc}" }
    f15 = @{ Name='APC OK split ESC|\, 2nd'; Bytes='\' }
    insert = @{ Name='APC error split mid-body, 1st'; Bytes="${esc}_Gi=31;ENOENT:" }
    home = @{ Name='APC error split mid-body, 2nd'; Bytes="No such file${esc}\" }
    end = @{ Name='APC error split ESC|_, 2nd'; Bytes="_Gi=31;ENOENT:No such file${esc}\" }
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
# -Sabotage's controls: a delimiter that is not one, and a DA1 trigger that triggers nothing.
if($Sabotage -eq 'delimiter') { $bindings.f1.Bytes="$([char]23)" }
if($Sabotage -eq 'control') { $bindings.f4.Bytes="$([char]23)" }

# The steps of a reader session, in order. Keys are bindings (posted as
# bare keys); Typed are keys typed for real (9001 records); Gap is the
# pause between the two writes of a split; Kitty marks the steps only the
# readers that push Kitty flags (a, a16) run.
$stepPlan = @(
    @{ Name='typed: Shift tap, h, i (9001 records)'; Keys=@(); Typed=@(@{Vk=0x10;Shift=$true},@{Vk=0x48},@{Vk=0x49}) }
    @{ Name='mode 9001: DECRQM'; Keys=@('pause') }
    @{ Name='push Kitty flags (CSI > 1 u)'; Keys=@('f2'); Kitty=$true }
    @{ Name='Kitty flags: CSI ? u'; Keys=@('scroll_lock'); Kitty=$true }
    @{ Name='typed after the push: Shift tap, h'; Keys=@(); Typed=@(@{Vk=0x10;Shift=$true},@{Vk=0x48}); Kitty=$true }
    @{ Name='case 6: DA1 (before)'; Keys=@('f4') }
    @{ Name='case 6: OSC 11 (before)'; Keys=@('f5') }
    @{ Name='case 1: noctty kitty reply, OK'; Keys=@('f6') }
    @{ Name='case 1: noctty kitty reply, error'; Keys=@('f7') }
    @{ Name='case 1: APC OK, one write'; Keys=@('f8') }
    @{ Name='case 1: APC error, one write'; Keys=@('f9') }
    @{ Name='case 1: APC OK, split mid-body'; Keys=@('f10','f11'); Gap=300 }
    @{ Name='case 1: APC OK, split ESC|_'; Keys=@('f12','f13'); Gap=300 }
    @{ Name='case 1: APC OK, split ESC|\'; Keys=@('f14','f15'); Gap=300 }
    @{ Name='case 1: APC error, split mid-body'; Keys=@('insert','home'); Gap=300 }
    @{ Name='case 1: APC error, split ESC|_'; Keys=@('f12','end'); Gap=300 }
    @{ Name='case 2: APC feature-shaped'; Keys=@('f16') }
    @{ Name='case 3: 2033 report, visible'; Keys=@('f17') }
    @{ Name='case 3: DECRPM 2033'; Keys=@('f18') }
    @{ Name='case 4: multiple-cursors reply'; Keys=@('f19') }
    @{ Name='case 6: injected OSC 11 reply'; Keys=@('f20') }
    @{ Name='case 6: injected OSC 4 reply'; Keys=@('print_screen') }
    @{ Name='case 6: injected DA1 reply'; Keys=@('f21') }
    @{ Name='case 7 shape: 2033 report, hidden'; Keys=@('f22') }
    @{ Name='case 6: DA1 (after)'; Keys=@('f4') }
    @{ Name='case 6: OSC 11 (after)'; Keys=@('f5') }
    @{ Name='pop Kitty flags (CSI < u)'; Keys=@('f3'); Kitty=$true }
)
function Get-PlannedSteps([string] $Mode) { @($stepPlan | Where-Object { -not $_.Kitty -or $Mode -in @('a','a16') }) }

$notMeasured = @(
    'case 7, after the prompt-time reset: deferred to Phase 3 (PLAN.md section 9.1), when mode 2033 and its reset exist'
    'case 7, stale extra cursors left drawn: deferred to Phase 3, when multiple cursors (kitty shortlist #2) exist'
    'reader (a''), Neovim: not installed on the measuring machine'
    'reader (e), WSL: not used, the user''s standing no-WSL rule'
    'case 5: deferred with OSC 5522'
    'cmd and [Console]::ReadKey as readers: not measured; inferred to read with VT input off, as reader b does'
    'real keyboard input and a visible desktop: posted input on a private desktop only'
)

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
# The product AUMID's registration (and any key a portable copy publishes it
# from): names, value names, kinds and data, hashed. Nothing is printed.
function Aumid-Fingerprint {
    $parent='HKCU:\Software\Classes\AppUserModelId'
    $keys=@(Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'io.github.amanthanvi.noctty*' } | Sort-Object PSChildName)
    $text=foreach($k in $keys) {
        $k.PSChildName
        foreach($n in @($k.GetValueNames() | Sort-Object)) { '{0}={1}:{2}' -f $n,$k.GetValueKind($n),(@($k.GetValue($n,$null,'DoNotExpandEnvironmentNames')) -join ',') }
    }
    return @{ Keys=@($keys | ForEach-Object { $_.PSChildName }); Sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($text -join "`n")))) }
}

if(-not $Driver) {
    # pin-begin: outer-run (Contracts.98 pins the whole outer phase by hash: the compile, what the driver is told, the guards and the outer exit)
    $Bin=(Resolve-Path -LiteralPath $Bin).Path; $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    # The bundled readers must run on the bundled ConPTY: an inherited override would move them to another host.
    if($null -ne [Environment]::GetEnvironmentVariable('NOCTTY_CONPTY')) { throw 'NOCTTY_CONPTY is set in this environment, which would run the bundled readers on another host; the harness sets it itself for c-inbox. Unset it and run again.' }
    if(-not $CompileOnly -and -not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain a built noctty.exe.' }
    if(-not $CompileOnly -and -not (Test-Path -LiteralPath (Join-Path $Bin 'conpty.dll'))) { throw 'Bin must hold the bundled conpty.dll: this measures the bundled ConPTY.' }
    if($sshReaders.Count -gt 0 -and $Run -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9_.\\-]*$') { throw 'Readers d and d-notiming need a Run path of letters, digits, _ . - and \ only: the far side''s shell gets the reader command unquoted.' }
    # Defence in depth for Run's own contents: a protected DACL (this user, SYSTEM and Administrators,
    # inherited by everything in it), read back before anything is written there. It does not guard against
    # a principal with rights on Run's parent folders. Other local accounts are outside this harness's threat
    # model: it runs under the user's own account on a single-user machine.
    $runParent=Split-Path -Parent $Run; if(-not (Test-Path -LiteralPath $runParent)) { [void](New-Item -ItemType Directory -Path $runParent) }
    $runSids=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
    $runAcl=[Security.AccessControl.DirectorySecurity]::new(); $runAcl.SetAccessRuleProtection($true,$false)
    foreach($sid in $runSids) { $runAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')) }
    [void][IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($Run),$runAcl)
    # The ACL control: a rule for Everyone, added once the directory exists, which the read-back must refuse.
    if($Sabotage -eq 'acl') { $aclSabotage=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Run)); $aclSabotage.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Modify','ContainerInherit,ObjectInherit','None','Allow')); [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Run),$aclSabotage) }
    $runRead=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Run))
    $runOthers=@($runRead.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -ne 'Allow' -or $runSids -notcontains $_.IdentityReference.Value })
    if(-not $runRead.AreAccessRulesProtected -or $runOthers.Count -gt 0 -or @($runSids[0],'S-1-5-32-544') -notcontains $runRead.GetOwner([Security.Principal.SecurityIdentifier]).Value) { throw 'The Run directory''s ACL did not read back as this user''s alone; nothing runs from it.' }
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
        # The compiler is the one launch without a desktop: it opens no window and runs before the private one exists.
        $cp=[ReplyPath]::Launch($cmdExe,('"{0}" /d /c ""{1}""' -f $cmdExe,$compile),$root,$null,$compileJob,0x08000000)
        if([ReplyPath]::WaitForSingleObject($cp.process,120000) -ne 0) { throw 'Helper compilation timed out.' }
        [uint32]$compileCode=0; [void][ReplyPath]::GetExitCodeProcess($cp.process,[ref]$compileCode)
        if($compileCode -ne 0) { throw "Helper compilation failed ($compileCode); inspect Run/compile.log." }
    } finally {
        [void][ReplyPath]::StopOwnedJob($compileJob)
        if($cp) { [void][ReplyPath]::CloseHandle($cp.thread); [void][ReplyPath]::CloseHandle($cp.process) }
    }
    if($CompileOnly) { Write-Host 'ConPTY reply-path harness C/C# compilation: PASS; no launches.'; exit 0 }
    $sshDir=Join-Path $Run 'sshd'; $sshSecrets=@('host_ed25519','host_ed25519.pub','client_ed25519','client_ed25519.pub','authorized_keys')
    # Everything from the ssh keys to the last launch runs in one try: the keys go on every exit
    # path, and the guards are compared once their first reading exists.
    $desktop=[IntPtr]::Zero; $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA; $job=[IntPtr]::Zero; $pi=$null; [uint32]$code=2; $guardsRead=$false; $keyHold=$null
    try {
        if($sshReaders.Count -gt 0) {
            [void](New-Item -ItemType Directory -Path $sshDir)
            # The far end of d and d-notiming: keys, host key and config for one
            # loopback sshd, all inside Run, deleted after the run. The private
            # keys are readable by this user only.
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
              'PubkeyAuthentication yes','PasswordAuthentication no','KbdInteractiveAuthentication no','DisableForwarding yes','PermitUserRC no','StrictModes no',
              "PidFile $(Join-Path $sshDir 'sshd.pid')","AllowUsers $user") |
                Set-Content -LiteralPath (Join-Path $sshDir 'sshd_config') -Encoding ascii
            # The far side's facts: which shell sshd runs, and whether it can load a profile there (existence only).
            $openSshKey=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue
            $documents=[Environment]::GetFolderPath('MyDocuments')
            @{Port=$port;SshVersion=((& (Join-Path $openssh 'ssh.exe') -V 2>&1) -join ' ');
              DefaultShell=$(if($openSshKey -and $openSshKey.DefaultShell){[string]$openSshKey.DefaultShell}else{'(unset: cmd.exe)'});
              DefaultShellCommandOption=$(if($openSshKey -and $openSshKey.DefaultShellCommandOption){[string]$openSshKey.DefaultShellCommandOption}else{'(unset)'});
              PwshCurrentUserProfilesExist=@((Test-Path -LiteralPath (Join-Path $documents 'PowerShell\profile.ps1')),(Test-Path -LiteralPath (Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1')))} |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sshDir 'ssh.json')
        }
        # The keys-on-failure control: a setup step that fails once the keys exist.
        if($Sabotage -eq 'setup') { throw 'Sabotage setup: a setup step failed (after reader d''s ssh keys, when it made them).' }
        $before=Startup-Fingerprint; $aumidBefore=Aumid-Fingerprint; $clipboardBefore=[ReplyPath]::GetClipboardSequenceNumber()
        $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-conpty-reply-path.ps1'
        $guardsRead=$true
        # The kept-key control: an ssh secret's file held open, so the cleanup cannot delete it.
        if($Sabotage -eq 'key') { [void](New-Item -ItemType Directory -Force -Path $sshDir); $keyHold=[IO.File]::Open((Join-Path $sshDir 'authorized_keys'),[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        $portable=Join-Path $Run 'source\bin'; [void](New-Item -ItemType Directory -Path $portable)
        # No noctty.ico: a portable copy publishes the product AUMID's registration only with the icon beside it.
        Get-ChildItem -LiteralPath $Bin -File | Where-Object { $_.Name -ne 'noctty.ico' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portable }
        if(Test-Path -LiteralPath (Join-Path $portable 'noctty.ico')) { throw 'The portable copy must not hold noctty.ico.' }
        $share=Join-Path (Split-Path -Parent $Bin) 'share'
        if(Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'source\share') -Recurse }
        Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
        foreach($dir in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $dir)) }
        $desktopName='noctty-replypath-'+[guid]::NewGuid().ToString('N')
        $desktop=[ReplyPath]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
        if($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
        $job=[ReplyPath]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $command='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver -Readers {4} -Sabotage {5}' -f $pwsh,$PSCommandPath,$portable,$Run,($Readers -join ','),$Sabotage
        if($SkipPSReadLine) { $command+=' -SkipPSReadLine' }
        if($AllowSshFarSideUserProfileAndLocalAppData) { $command+=' -AllowSshFarSideUserProfileAndLocalAppData' }
        $pi=[ReplyPath]::Launch($pwsh,$command,$Run,"WinSta0\$desktopName",$job,0x08000000)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([ReplyPath]::WaitForSingleObject($pi.process,500) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw 'Hidden driver timeout; owned job will be stopped.' }
        }
        [void][ReplyPath]::GetExitCodeProcess($pi.process,[ref]$code)
    } catch {
        Write-Host "Infrastructure: $($_.Exception.Message)"; $code=2
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $owned=0
        if($job -ne [IntPtr]::Zero) { try { $owned=[ReplyPath]::StopOwnedJob($job) } catch { $cleanupError=$_.Exception.Message } }
        if($pi) { [void][ReplyPath]::CloseHandle($pi.thread); [void][ReplyPath]::CloseHandle($pi.process) }
        if($desktop -ne [IntPtr]::Zero) { [void][ReplyPath]::CloseDesktop($desktop) }
        # The run's ssh keys go once the run is over, on every path; each by its exact path, best effort:
        # a file that cannot go is recorded and left for the guards, which then exit 3.
        $keysDeleted=$true; $keyFailures=[Collections.Generic.List[string]]::new()
        foreach($name in $sshSecrets) {
            $path=Join-Path $sshDir $name
            if(Test-Path -LiteralPath $path) {
                try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { $keyFailures.Add(('{0}: {1}' -f $name,$_.Exception.GetType().Name)) }
                if(Test-Path -LiteralPath $path) { $keysDeleted=$false }
            }
        }
        if($keyHold) { $keyHold.Dispose() }
        # No link may stay in the run (listed, never followed): a cmd AutoRun hook once left a junction under its LOCALAPPDATA.
        $links=@(Get-ChildItem -LiteralPath $Run -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($Run.Length) })
        $guards=[ordered]@{GuardsRead=$guardsRead;SshKeysDeleted=$keysDeleted;SshKeyDeleteFailures=@($keyFailures);LinksInRun=$links;OwnedJobCleanedUp=($null -eq $cleanupError);OwnedProcessCount=$owned;DriverExit=$code}
        if($guardsRead) {
            $after=Startup-Fingerprint; $aumidAfter=Aumid-Fingerprint; $clipboardAfter=[ReplyPath]::GetClipboardSequenceNumber()
            $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
            $aumidUnchanged=($aumidBefore.Keys -join '|') -ceq ($aumidAfter.Keys -join '|') -and $aumidBefore.Sha256 -ceq $aumidAfter.Sha256
            $clipboardUnchanged=$clipboardBefore -eq $clipboardAfter
            $historyFailure=$null
            try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_.Exception.Message }
            $guards+=[ordered]@{Unchanged=$unchanged;HistoryUnchanged=($null -eq $historyFailure);AumidKeysBefore=$aumidBefore.Keys;AumidKeysAfter=$aumidAfter.Keys;AumidUnchanged=$aumidUnchanged;
                ClipboardSequenceBefore=$clipboardBefore;ClipboardSequenceAfter=$clipboardAfter;ClipboardUnchanged=$clipboardUnchanged}
        }
        if(Test-Path -LiteralPath $Run) { $guards | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json') }
    }
    if(-not $keysDeleted -or $links.Count -gt 0 -or ($guardsRead -and ($historyFailure -or -not $unchanged -or -not $aumidUnchanged -or -not $clipboardUnchanged))) {
        $compared=if($guardsRead) { 'startup ledger unchanged={0}, history unchanged={1}, AUMID key unchanged={2}, clipboard sequence unchanged={3}' -f $unchanged,($null -eq $historyFailure),$aumidUnchanged,$clipboardUnchanged } else { 'ledger, history, AUMID key and clipboard not compared (setup failed before their first reading)' }
        Write-Host ('ISOLATION GUARD CHANGED: {0}, ssh keys deleted={1}, links left in the run={2}; stop launches.' -f $compared,$keysDeleted,$links.Count)
        exit 3
    }
    if($cleanupError) { Write-Host "Infrastructure: $cleanupError"; exit 2 }
    switch($code) {
        0 { Write-Host "ConPTY reply-path harness: COMPLETE; see $(Join-Path $Run 'results.md')."; exit 0 }
        1 { Write-Host "ConPTY reply-path harness: INCOMPLETE (a reader, case 7 or a positive control failed); see $(Join-Path $Run 'results.md')."; exit 1 }
        default { Write-Host "ConPTY reply-path harness: infrastructure failure ($code); inspect results.json and driver-error.txt in Run."; exit 2 }
    }
    # pin-end: outer-run
}

# Driver: on the private desktop, with sandboxed AppData.
$driverDesktop=[ReplyPath]::DesktopName()
if(-not $driverDesktop.StartsWith('noctty-replypath-',[StringComparison]::Ordinal)) { throw 'Driver is not on the task private desktop.' }
if(-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable'))) { throw 'Driver requires portable marker.' }
if(Test-Path -LiteralPath (Join-Path $Bin 'noctty.ico')) { throw 'Driver refuses a portable copy that holds noctty.ico.' }
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
$case7=$null

function Fkey([string] $Key) {
    $s=[ReplyPath+Stroke]::new()
    $s.Vk=switch($Key) { 'pause' { 0x13 } 'scroll_lock' { 0x91 } 'print_screen' { 0x2C } 'insert' { 0x2D } 'home' { 0x24 } 'end' { 0x23 } default { 0x6F+[int]$Key.Substring(1) } }
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
        if(Test-Path -LiteralPath $Path) {
            # The reader renames a finished ready.tmp; still, read shared and retry a file that is busy.
            $t=$null
            try { $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete); try { $t=[IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() } }
            catch [IO.IOException] { $t=$null }
            if($t -and $t.Contains("`n")) { return $t.Trim().Split(',') }
        }
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
    $steps=[Collections.Generic.List[object]]::new(); $session=@{Mode=$Mode;Steps=$steps;Dir=$dir;Planned=@(Get-PlannedSteps $Mode).Count}
    $sessions.Add($session)
    $readerMode=if($Mode -in @('c-inbox','d','d-notiming')) { 'c' } else { $Mode }
    $readerArgs='{0} "{1}" "{2}" "{3}"' -f $readerMode,$log,$ready,$stop
    $sshd=$null; $terminal=$null
    $layout=$null; $surface=[IntPtr]::Zero; $thread=0
    try {
        if($Mode -in @('d','d-notiming')) {
            # One connection (-d), loopback only, this run's config; its debug log stays in Run.
            $sshDir=Join-Path $Run 'sshd'; $ssh=Get-Content -LiteralPath (Join-Path $sshDir 'ssh.json') -Raw | ConvertFrom-Json
            $openssh=Join-Path ([Environment]::GetFolderPath('System')) 'OpenSSH'
            $sshd=[ReplyPath]::Launch((Join-Path $openssh 'sshd.exe'),('"{0}" -d -f "{1}" -E "{2}"' -f (Join-Path $openssh 'sshd.exe'),(Join-Path $sshDir 'sshd_config'),(Join-Path $sshDir "sshd-debug-$Mode.log")),$sshDir,"WinSta0\$driverDesktop",$job,0x08000000)
            # Connect only once this run's sshd, by its PID, owns the listening port.
            $deadline=[datetime]::UtcNow.AddSeconds(15)
            while($true) {
                $listener=@(Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $ssh.Port -ErrorAction SilentlyContinue)
                if($listener.Count -gt 0 -and @($listener | Where-Object { $_.OwningProcess -ne $sshd.pid }).Count -gt 0) { throw 'Another process listens on the run''s sshd port; nothing connects.' }
                if($listener.Count -gt 0) { break }
                if([datetime]::UtcNow -ge $deadline -or [ReplyPath]::WaitForSingleObject($sshd.process,0) -eq 0) { throw 'The run''s sshd did not start listening.' }
                Start-Sleep -Milliseconds 100
            }
            $session.Ssh=@{Version=$ssh.SshVersion;SshdPid=$sshd.pid;DefaultShell=$ssh.DefaultShell;DefaultShellCommandOption=$ssh.DefaultShellCommandOption;PwshCurrentUserProfilesExist=$ssh.PwshCurrentUserProfilesExist}
            $timing=if($Mode -eq 'd-notiming') { ' -o ObscureKeystrokeTiming=no' } else { '' }
            $sshArgs='-tt -a -x -k -F none -p {0} -i "{1}" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ClearAllForwardings=yes -o UserKnownHostsFile="{2}" -o StrictHostKeyChecking=accept-new{3} 127.0.0.1' -f $ssh.Port,(Join-Path $sshDir 'client_ed25519'),(Join-Path $sshDir 'known_hosts'),$timing
            $command='"{0}" --config-file="{1}" --window-save-state=never "--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}" {4} {5} {6}' -f $exe,$config,$cmdExe,(Join-Path $openssh 'ssh.exe'),$sshArgs,$reader,$readerArgs.Replace('"','')
        } else {
            $command='"{0}" --config-file="{1}" --window-save-state=never "--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}" {4}' -f $exe,$config,$cmdExe,$reader,$readerArgs
        }
        if($Mode -eq 'c-inbox') { $env:NOCTTY_CONPTY='inbox' }
        try { $terminal=[ReplyPath]::Launch($exe,$command,$Bin,"WinSta0\$driverDesktop",$job,0x08000000) }
        finally { if($Mode -eq 'c-inbox') { Remove-Item Env:NOCTTY_CONPTY } }
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
        $session.Ready=@{Pid=[int]$probe[0];InputModeBefore=('0x{0:x}' -f [uint32]$probe[1]);InputMode=('0x{0:x}' -f [uint32]$probe[2]);OutputMode=('0x{0:x}' -f [uint32]$probe[3]);InputCodePage=[int]$probe[4];
            LocalAppDataInRun=$(switch($probe[6]) { '1' { $true } '0' { $false } '2' { 'unset' } default { 'unknown' } })}
        if($Mode -in @('d','d-notiming')) {
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
        foreach($planned in @(Get-PlannedSteps $Mode)) {
            $count=Delimiters $log
            $start=[ReplyPath]::Ticks()
            if($planned.Typed) { [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@($planned.Typed | ForEach-Object { Vk $_.Vk -Shift:([bool]$_.Shift) }),60,150) }
            $first=$true
            foreach($k in $planned.Keys) {
                if(-not $first -and $planned.Gap) { Start-Sleep -Milliseconds $planned.Gap }
                [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey $k)),20,60); $first=$false
            }
            Start-Sleep -Milliseconds 400 # a reply to a query arrives before the delimiter
            [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey 'f1')),20,60)
            $deadline=[datetime]::UtcNow.AddSeconds(5)
            while((Delimiters $log) -le $count) {
                if([datetime]::UtcNow -ge $deadline) { $steps.Add(@{Name=$planned.Name;Keys=$planned.Keys;Start=$start;Barrier='TIMEOUT'}); throw "Delimiter after '$($planned.Name)' never reached the reader ($Mode)." }
                Start-Sleep -Milliseconds 20
            }
            $steps.Add(@{Name=$planned.Name;Keys=$planned.Keys;Start=$start;Barrier='OK'})
            if($Sabotage -eq 'reader' -and $planned.Name -eq 'mode 9001: DECRQM') {
                # The dead-reader control: stop this session's reader, by its own PID, once it is identified.
                $victim=Get-Process -Id $session.Ready.Pid -ErrorAction SilentlyContinue
                if($victim -and $victim.Path -ieq $reader) { [ReplyPath]::KillExact($session.Ready.Pid) } else { throw 'Sabotage reader: the reader PID did not identify the reader.' }
            }
        }
    } catch {
        $failures.Add("reader ${Mode}: $($_.Exception.Message)")
    } finally {
        if($layout) { try { [ReplyPath]::RestoreLayout($surface,$thread,$layout) } catch { $failures.Add("reader ${Mode}: layout restore: $($_.Exception.Message)") } }
        Set-Content -LiteralPath $stop -Value '' -NoNewline
        if($terminal) {
            if([ReplyPath]::WaitForSingleObject($terminal.process,10000) -ne 0) {
                # Only this launch's own process handle, which the run's job owns.
                $session.Stopped='terminated after the reader stopped'
                [void][ReplyPath]::TerminateProcess($terminal.process,1); [void][ReplyPath]::WaitForSingleObject($terminal.process,5000)
            } else { $session.Stopped='exited after the reader stopped' }
            [void][ReplyPath]::CloseHandle($terminal.thread); [void][ReplyPath]::CloseHandle($terminal.process)
        }
        if($sshd) {
            # sshd -d serves one connection and exits; otherwise stop this launch's own handle.
            if([ReplyPath]::WaitForSingleObject($sshd.process,10000) -ne 0) { $session.SshdStopped='terminated'; [void][ReplyPath]::TerminateProcess($sshd.process,1); [void][ReplyPath]::WaitForSingleObject($sshd.process,5000) }
            else { $session.SshdStopped='exited after its one connection' }
            [void][ReplyPath]::CloseHandle($sshd.thread); [void][ReplyPath]::CloseHandle($sshd.process)
        }
    }
    $session.Log=@(Read-Log $log)
    $session.StateProblems=@(Get-ReaderStateProblems $session)
}

# Whether a reader ran in the state it is named for: its console input mode
# (b 0x98; the others VT input on, line, echo and processed input off), and,
# once every planned step finished, the record readers' read size (a16 never
# more than 16 records a read and at least one read of 16; a and b at least
# one read above 16).
function Get-ReaderStateProblems($Session) {
    $p=[Collections.Generic.List[string]]::new()
    if(-not $Session.Ready) { return @() }
    $modeBefore=[Convert]::ToUInt32($Session.Ready.InputModeBefore.Substring(2),16)
    $mode=[Convert]::ToUInt32($Session.Ready.InputMode.Substring(2),16)
    $wanted=if($Session.Mode -eq 'b') { [uint32]0x98 } else { (($modeBefore -bor 7) -bxor 7) -bor 0x200 }
    if($mode -ne $wanted) { $p.Add(('reader {0}: input mode 0x{1:x}, expected 0x{2:x}' -f $Session.Mode,$mode,$wanted)) }
    $finished=@($Session.Steps | Where-Object { $_.Barrier -eq 'OK' }).Count -eq $Session.Planned
    if($finished -and $Session.Mode -in @('a','a16','b')) {
        $reads=@($Session.Log | Where-Object { $_ -like 'READ,*' } | ForEach-Object { [int]$_.Split(',')[2] })
        $largest=if($reads.Count) { ($reads | Measure-Object -Maximum).Maximum } else { 0 }
        if($Session.Mode -eq 'a16' -and $largest -ne 16) { $p.Add("reader a16: its largest read was $largest records, expected 16") }
        if($Session.Mode -in @('a','b') -and $largest -le 16) { $p.Add("reader $($Session.Mode): no read above 16 records, expected 64-record reads") }
    }
    # A clean stop: the reader saw the stop file and wrote its last line. One that died after the last step has none.
    if($finished -and -not @($Session.Log | Where-Object { $_ -like 'STOP,*' }).Count) { $p.Add("reader $($Session.Mode): no clean stop in its log (it exited before it saw the stop file)") }
    return @($p)
}

# Splits a reader log at its delimiters: segment i is what arrived for step i.
function Get-Segments($Session) {
    $segments=[Collections.Generic.List[object]]::new()
    $current=@{Records=[Collections.Generic.List[string]]::new();Units=[Text.StringBuilder]::new();Reads=[Collections.Generic.List[string]]::new();Commands=[Collections.Generic.List[string]]::new()}
    $control=@(1,2,4,5,6,14,15,16,18)
    $byteMode=$Session.Mode -in @('c','c-inbox','d','d-notiming')
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
# Control marks a positive control: the run is incomplete unless it comes back
# as predicted. Readers c-inbox, d and d-notiming have the in-box conhost for a
# pseudo console, which answers DA1 and DECRQM itself and returns no OSC 11 or
# kitty reply (docs/windows-vt-conformance.md, the measured query ownership
# differential); for their injected replies the prediction is reader c's, from
# the 1.24 source, except d-notiming's, where ssh.exe forwards its 16-record
# reads unmerged and the in-box far end keeps only the last (council round 1).
function Get-Prediction([string] $Step, [string] $Mode, [string] $Written) {
    $vtInput=$Mode -ne 'b'
    $inbox=$Mode -in @('c-inbox','d','d-notiming')
    if($Step -eq 'mode 9001: DECRQM') { if($inbox) { return @{Text='answered by the in-box conhost';Regex='^\x1b\[\?9001;[0-4]\$y$';Control=$true} } else { return @{Text='set (1)';Regex='^\x1b\[\?9001;1\$y$';Control=$true} } }
    if($Step -eq 'Kitty flags: CSI ? u') { return @{Text='flags 1';Regex='^\x1b\[\?1u$';Control=$true} }
    if($Step -like 'case 6: DA1 (*') {
        if($inbox) { return @{Text='the in-box conhost''s own DA1';Regex='^\x1b\[\?61;[0-9;]+c$';Control=$true} }
        return @{Text='noctty''s DA1';Regex='^\x1b\[\?62;[0-9;]+c$';Control=$true}
    }
    if($Step -like 'case 6: OSC 11 (*') {
        if($inbox) { return @{Text='no reply (in-box conhost)';Exact=''} }
        return @{Text='noctty''s OSC 11 reply';Regex='^\x1b\]11;rgb:[0-9a-f]{4}/[0-9a-f]{4}/[0-9a-f]{4}(\x1b\\|\x07)$';Control=$true}
    }
    if($Step -like 'case 1: noctty kitty reply, *') {
        if($inbox) { return @{Text='no reply (in-box conhost)';Exact=''} }
        if(-not $vtInput) { return @{Text='lone \';Exact='\'} }
        if($Step -like '*, OK') { return @{Text='whole';Regex='^\x1b_Gi=31;OK\x1b\\$'} }
        return @{Text='whole';Regex='^\x1b_Gi=32;E[A-Z]+:[^\x1b]*\x1b\\$'}
    }
    $prediction=$null
    if($Step -like 'case 1: APC*' -or $Step -like 'case 2:*') {
        if(-not $vtInput) { $prediction=@{Text='lone \';Exact='\'} }
        elseif($Step -like '*ESC|_*') { $prediction=@{Text='the run without its ESC';Exact=$Written.Substring(1)} }
        else { $prediction=@{Text='whole';Exact=$Written} }
    } elseif($Step -like 'case 3:*' -or $Step -like 'case 4:*' -or $Step -like 'case 6: injected*' -or $Step -like 'case 7 shape:*') {
        if($vtInput) { $prediction=@{Text='whole, as an escape';Exact=$Written} } else { $prediction=@{Text='whole, as typed text';Exact=$Written} }
        # The injected controls: an OSC and a DA1 reply must reach a bundled reader, and a DA1 reply an in-box one.
        if(($Step -like 'case 6: injected*' -and -not $inbox) -or $Step -eq 'case 6: injected DA1 reply') { $prediction.Control=$true }
    }
    if($prediction -and $Mode -eq 'd-notiming' -and $prediction.Exact.Length -gt 16) {
        $prediction=@{Text='its last read only (16-record reads, unmerged)';Exact=$prediction.Exact.Substring(16)}
    }
    return $prediction
}

# A row's verdict: INCOMPLETE when its step never finished (no delimiter),
# '-' without a prediction, otherwise the observed bytes against it, ordinally
# (pwsh 7's -ceq compares in the invariant culture, where ICU gives ESC and the
# other controls no weight).
function Get-Verdict($Prediction, [string] $Observed, [string] $Barrier) {
    if($Barrier -ne 'OK') { return 'INCOMPLETE' }
    if(-not $Prediction) { return '-' }
    if($Prediction.Regex) { if($Observed -cmatch $Prediction.Regex) { return 'as predicted' }; return 'DIFFERS' }
    if([string]::Equals($Observed,[string]$Prediction.Exact,[StringComparison]::Ordinal)) { return 'as predicted' }
    return 'DIFFERS'
}

# The run's exit: 2 for infrastructure, 1 when the run is incomplete or a
# positive control differs, 0 when every requested reader ran every planned
# step, case 7 ran with its controls (unless skipped), and every control held.
function Get-RunExit($Failures, $Rows, $Sessions, $Requested, $Case7, [bool] $Case7Requested) {
    $why=[Collections.Generic.List[string]]::new()
    if(@($Failures | Where-Object { $_ -like 'infrastructure*' -or $_ -like 'owned job*' }).Count -gt 0) { return @{Code=2;Why=@($Failures)} }
    foreach($f in $Failures) { $why.Add($f) }
    foreach($mode in $Requested) {
        $s=@($Sessions | Where-Object { $_.Mode -eq $mode })
        if($s.Count -ne 1) { $why.Add("reader ${mode}: no session"); continue }
        $done=@($s[0].Steps | Where-Object { $_.Barrier -eq 'OK' }).Count
        if($done -ne $s[0].Planned) { $why.Add("reader ${mode}: $done of $($s[0].Planned) steps") }
    }
    foreach($s in $Sessions) { foreach($q in @($s.StateProblems)) { if($q) { $why.Add($q) } } }
    foreach($r in @($Rows | Where-Object { $_.Control -and $_.Verdict -ne 'as predicted' })) { $why.Add("control failed: $($r.Reader) / $($r.Step)") }
    if($Case7Requested) {
        if(-not $Case7 -or -not $Case7.Complete) { $why.Add('case 7: incomplete') }
        elseif(-not $Case7.InjectedReportShown) { $why.Add('case 7: the injected 2033 report did not show at the prompt (positive control)') }
        elseif(-not $Case7.TabSwitched) { $why.Add('case 7: the tab switch did not happen (positive control)') }
    }
    return @{Code=$(if($why.Count -gt 0) { 1 } else { 0 });Why=@($why)}
}

try {
    foreach($mode in $Readers) { Invoke-ReaderSession $mode }

    # pin-begin: case-7 (Contracts.98 pins this block by hash: its rows and its two positive controls)
    if(-not $SkipPSReadLine) {
        # Case 7: PSReadLine. History goes to a run-local file, never saved, before the first read;
        # the ready file is written only once both options read back. The shell then sets ?2033h.
        $case7=@{Steps=[Collections.Generic.List[object]]::new();Complete=$false;NotMeasured=@($notMeasured | Select-Object -First 2)}
        $dir=Join-Path $Run 'psreadline'; [void](New-Item -ItemType Directory -Path $dir)
        $shellReady=Join-Path $dir 'ready.txt'; $shellHistory=Join-Path $dir 'history.txt'
        # Both paths go into the startup as single-quoted literals, their quotes escaped: a Run may hold an apostrophe.
        $historyLiteral=[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shellHistory)
        $readyLiteral=[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($shellReady)
        $pwshExe=(Get-Command pwsh.exe).Source
        $startup="Set-PSReadLineOption -HistorySavePath '$historyLiteral' -HistorySaveStyle SaveNothing; if((Get-PSReadLineOption).HistorySaveStyle -eq 'SaveNothing' -and (Get-PSReadLineOption).HistorySavePath -ceq '$historyLiteral') { [Console]::Write([char]27+'[?2033h'); Set-Content -LiteralPath '$readyLiteral' -Value ready }"
        $command='"{0}" --config-file="{1}" --window-save-state=never "--command=direct:{2} /D" --clipboard-write=deny --clipboard-read=deny -e "{3}" -NoLogo -NoProfile -NoExit -Command "{4}"' -f $exe,$config,$cmdExe,$pwshExe,$startup
        $shell=[ReplyPath]::Launch($exe,$command,$Bin,"WinSta0\$driverDesktop",$job,0x08000000)
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
            if(-not [ReplyPath]::OnCallerDesktop($surface)) { throw 'The pwsh surface is not on the private desktop; nothing is posted to it.' }
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
                    if([ReplyPath]::WaitForSingleObject($p.process,10000) -ne 0) { throw "attach timeout ($Label)" }
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
            # The positive control for the null below: the injected report shows as typed text.
            $case7.InjectedReportShown=[bool](@($case7.Steps[0].Prompt) -join '' -cmatch '\[\?999;2n$')
            # The real thing today: ?2033h was set by the shell's startup; switch away and back.
            $shellBefore=Read-Shell 'before-tab-switch'
            [ReplyPath]::Keys($surface,$thread,[ReplyPath+Stroke[]]@((Fkey 'f23')),20,60)
            Start-Sleep -Milliseconds 2500
            $surfacesDuring=@([ReplyPath]::Surfaces($shell.pid)).Count; $visibleDuring=[ReplyPath]::IsWindowVisible($surface)
            $second=@([ReplyPath]::Surfaces($shell.pid) | Where-Object { $_ -ne $surface } | Select-Object -First 1)
            if($second.Count -eq 1) { [ReplyPath]::Keys($second[0],[ReplyPath]::WindowThread($second[0]),[ReplyPath+Stroke[]]@((Fkey 'f24')),20,60) }
            Start-Sleep -Milliseconds 1500
            $visibleAfter=[ReplyPath]::IsWindowVisible($surface)
            $afterSwitch=Read-Shell 'after-tab-switch'
            $case7.TabSwitch=@{SurfacesDuring=$surfacesDuring;PwshSurfaceVisibleDuring=$visibleDuring;PwshSurfaceVisibleAfter=$visibleAfter;PromptBefore=$shellBefore.Prompt;PromptAfter=$afterSwitch.Prompt}
            $case7.TabSwitched=($surfacesDuring -ge 2 -and -not $visibleDuring -and $visibleAfter)
            # The switch's null needs its evidence: a PS prompt row both before and after it.
            if(@($shellBefore.Prompt).Count -ne 1 -or @($afterSwitch.Prompt).Count -ne 1) { throw 'No PS prompt row before or after the tab switch, so the switch''s null is not shown.' }
            $case7.Complete=$true
        } catch {
            $failures.Add("case 7: $($_.Exception.Message)")
        } finally {
            if($layout) { try { [ReplyPath]::RestoreLayout($surface,$thread,$layout) } catch { $failures.Add("case 7: layout restore: $($_.Exception.Message)") } }
            [void][ReplyPath]::CloseHandle($shell.thread); [void][ReplyPath]::CloseHandle($shell.process)
        }
    }
    # pin-end: case-7
} catch {
    $failures.Add("infrastructure: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)")
} finally {
    $owned=0; try { $owned=[ReplyPath]::StopOwnedJob($job) } catch { $failures.Add("owned job cleanup: $($_.Exception.Message)") }
}

# pin-begin: driver-results (Contracts.98 pins this block by hash: each row, its control flag and the run's exit)
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
        $verdict=Get-Verdict $prediction $observed $step.Barrier
        $rows.Add([ordered]@{Reader=$session.Mode;Step=$step.Name;Written=(Show $written);WrittenHex=(Hex $written);Observed=(Show $observed);ObservedHex=(Hex $observed);
            Predicted=$(if($prediction){$prediction.Text}else{'-'});Control=[bool]($prediction -and $prediction.Control);Verdict=$verdict;
            Reads=@($(if($segment){$segment.Reads}));Records=@($(if($segment){$segment.Records}));Commands=@($(if($segment){$segment.Commands}))})
    }
}
$exit=Get-RunExit $failures $rows $sessions $Readers $case7 (-not $SkipPSReadLine)
# pin-end: driver-results
$os=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$inboxConhost=Join-Path ([Environment]::GetFolderPath('System')) 'conhost.exe'
$controls=@($rows | Where-Object { $_.Control })
$result=[ordered]@{
    Harness='hidden-win11-conpty-reply-path.ps1'
    Exit=$exit.Code
    Why=$exit.Why
    Sabotage=$Sabotage
    Controls=('{0}/{1} as predicted' -f @($controls | Where-Object { $_.Verdict -eq 'as predicted' }).Count,$controls.Count)
    Windows=[ordered]@{CurrentBuild=$os.CurrentBuild;UBR=$os.UBR;DisplayVersion=$os.DisplayVersion;InBoxConhost=(Get-Item -LiteralPath $inboxConhost).VersionInfo.FileVersion}
    ConPty=[ordered]@{File=(Join-Path $Bin 'conpty.dll');FileVersion=(Get-Item -LiteralPath (Join-Path $Bin 'conpty.dll')).VersionInfo.FileVersion;OpenConsole=(Get-Item -LiteralPath (Join-Path $Bin 'OpenConsole.exe')).VersionInfo.FileVersion;Sha256=(Get-FileHash -LiteralPath (Join-Path $Bin 'conpty.dll')).Hash.ToLowerInvariant()}
    Readers=@($sessions | ForEach-Object { [ordered]@{Mode=$_.Mode;Ready=$_.Ready;Steps=$_.Steps.Count;Planned=$_.Planned;Stopped=$_.Stopped;Ssh=$_.Ssh;SshdStopped=$_.SshdStopped} })
    Rows=$rows
    Case7=$case7
    NotMeasured=$notMeasured
    OwnedProcessCount=$owned
    Failures=$failures
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'results.json') -Encoding utf8
$md=[Collections.Generic.List[string]]::new()
$md.Add(('Exit {0}; controls {1}; sabotage {2}.' -f $exit.Code,$result.Controls,$Sabotage))
foreach($w in $exit.Why) { $md.Add("- $w") }
$md.Add('')
$md.Add('| Reader | Step | Written | Observed (key-down units / bytes) | Predicted | Control | Verdict |'); $md.Add('|---|---|---|---|---|---|---|')
# A cell's own '|' would split its row (three split-APC steps per reader have one): escaped, as GFM reads it.
function Cell($Text) { ([string]$Text).Replace('|','\|') }
foreach($r in $rows) { $md.Add(('| {0} | {1} | `{2}` | `{3}` | {4} | {5} | {6} |' -f (Cell $r.Reader),(Cell $r.Step),(Cell $r.Written),(Cell $r.Observed),(Cell $r.Predicted),$(if($r.Control){'yes'}else{''}),(Cell $r.Verdict))) }
if($case7) {
    $md.Add(''); $md.Add('Case 7 (PSReadLine):'); $md.Add('')
    $md.Add('| Injected | Prompt line |'); $md.Add('|---|---|')
    foreach($s in $case7.Steps) { $md.Add(('| `{0}` | `{1}` |' -f (Cell $s.Written),(Cell (@($s.Prompt) -join '')))) }
    if($case7.TabSwitch) { $md.Add(''); $md.Add(('Tab switch with ?2033h set: surfaces during {0}, pwsh hidden during {1}, visible after {2}; prompt before `{3}`, after `{4}`.' -f $case7.TabSwitch.SurfacesDuring,(-not $case7.TabSwitch.PwshSurfaceVisibleDuring),$case7.TabSwitch.PwshSurfaceVisibleAfter,(@($case7.TabSwitch.PromptBefore) -join ''),(@($case7.TabSwitch.PromptAfter) -join ''))) }
}
$md.Add(''); $md.Add('Not measured:'); foreach($n in $notMeasured) { $md.Add("- $n") }
$md | Set-Content -LiteralPath (Join-Path $Run 'results.md') -Encoding utf8
exit $exit.Code
