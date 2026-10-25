#requires -Version 7.0
<#
Exercise Clink's real script discovery, stopping prompt filters, C/D hooks, and
a resize at the prompt. Supply an already extracted official portable Clink;
never installs or modifies AutoRun. -Bin additionally runs the test inside a
copied portable noctty build. Without -Bin, an explicit conhost runs cmd on the
private desktop. The resize step narrows that desktop's terminal window and
posts Enter to it; no real input, clipboard, shell profiles, or user history.
Its checks read the console's own buffer through Clink, so with -Bin they cover
Clink and ConPTY, not noctty's grid: interactive-win11-conpty-sync.ps1 -Clink
compares those, and src/terminal/resize_replay.zig replays the shape headless.
Evidence is retained in a NEW Run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Clink,
    [Parameter(Mandatory)][string]$Run,
    [string]$Bin,
    [string]$IntegrationScript = (Join-Path $PSScriptRoot '../../src/shell-integration/cmd/noctty-shell-integration.lua')
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'cmd-clink.ps1'
try {

$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class ClinkSmoke {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title; public int x,y,cx,cy,charsX,charsY,fill,flags;
        public short show,reservedBytes; public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct Limits {
        public long processTime,jobTime; public uint flags; public UIntPtr minWorking,maxWorking;
        public uint active; public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public Limits basic; public IO io; public UIntPtr processMemory,jobMemory,peakProcess,peakJob;
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr d);
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr OpenDesktopW(string n,int f,bool inherit,uint a);
    [DllImport("user32.dll")] static extern bool EnumDesktopWindows(IntPtr d,EnumWindow cb,IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int i,StringBuilder s,int n,out int needed);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr p,IntPtr t,bool inherit,uint flags,IntPtr env,string cwd,ref Startup s,out PI pi);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h,uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j,int t,ref ExtendedLimits l,int n);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h,out long c,out long e,out long k,out long u);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr h,int f,StringBuilder s,ref int n);
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left,top,right,bottom; }
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code,uint type);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p,EnumWindow cb,IntPtr l);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    static string ClassOf(IntPtr h) { var s=new StringBuilder(256); GetClassNameW(h,s,256); return s.ToString(); }
    static long Created(IntPtr p) { long c,e,k,u; if(!GetProcessTimes(p,out c,out e,out k,out u)) throw new Exception("Process time query failed"); return c; }
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
    static bool InJob(int pid,IntPtr job) {
        var h=OpenProcess(0x1000,false,pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if(h==IntPtr.Zero) return false;
        try { bool inJob; return IsProcessInJob(h,job,out inJob) && inJob; } finally { CloseHandle(h); }
    }
    static IntPtr OpenPrivateDesktop(string desktop) {
        // A null handle would make EnumDesktopWindows walk the caller's own
        // (interactive) desktop.
        var desk=OpenDesktopW(desktop,0,false,1);
        if(desk==IntPtr.Zero) throw new Exception("Cannot open the private desktop");
        return desk;
    }
    // The resize step, once the test's prompt is waiting: narrow the window,
    // and press Enter once the test has checked the result. Posted messages
    // to the window on the private desktop, never real input.
    static void ResizeStep(string desktop,int pid,IntPtr job,string ready,string done,Func<bool> alive) {
        Func<string,int,bool> waitFor=(path,ms)=>{ var until=DateTime.UtcNow.AddMilliseconds(ms); while(DateTime.UtcNow<until && alive()) { if(System.IO.File.Exists(path)) return true; System.Threading.Thread.Sleep(50); } return false; };
        if(!waitFor(ready,30000)) return;
        // The terminal window itself: noctty's host, or the console window.
        // conhost reports its window as owned by the console's client (cmd),
        // not by itself, so that one is matched by its owner being one of
        // this harness's processes (all in its job).
        IntPtr window=IntPtr.Zero;
        var desk=OpenPrivateDesktop(desktop);
        try {
            EnumDesktopWindows(desk,(h,p)=>{int owner; GetWindowThreadProcessId(h,out owner); var c=ClassOf(h); if((c=="ConsoleWindowClass" && InJob(owner,job)) || (owner==pid && c=="noctty.win32.host" && IsWindowVisible(h))) { window=h; return false; } return true;},IntPtr.Zero);
        } finally { CloseDesktop(desk); }
        if(window==IntPtr.Zero) throw new Exception("No terminal window to resize on the private desktop");
        Rect r; if(!GetWindowRect(window,out r)) throw new Win32Exception(Marshal.GetLastWin32Error());
        // SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
        SetWindowPos(window,IntPtr.Zero,0,0,(r.right-r.left)*3/5,r.bottom-r.top,0x16);
        // Without it the checks never ran; pressing Enter would let the test
        // finish without them.
        if(!waitFor(done,30000)) throw new Exception("The resize step's checks did not finish");
        long down=1|((long)MapVirtualKeyW(0x0D,0)<<16);
        if(ClassOf(window)=="noctty.win32.host") {
            IntPtr surface=IntPtr.Zero;
            EnumChildWindows(window,(h,p)=>{ if(IsWindowVisible(h) && ClassOf(h)=="noctty.win32") { surface=h; return false; } return true; },IntPtr.Zero);
            if(surface==IntPtr.Zero) throw new Exception("No noctty terminal surface to press Enter in");
            // The key-down/key-up pair only: noctty's pump runs
            // TranslateMessage, which makes the WM_CHAR, so a posted WM_CHAR as
            // well would type Enter twice (AGENTS.md, Running noctty).
            PostMessageW(surface,0x0100,(IntPtr)0x0D,(IntPtr)down);
            PostMessageW(surface,0x0101,(IntPtr)0x0D,(IntPtr)(down|0xC0000000L));
        } else {
            // conhost takes a bare WM_CHAR; with a posted WM_KEYDOWN in front
            // of it, nothing reached cmd (measured on a private desktop).
            PostMessageW(window,0x0102,(IntPtr)13,(IntPtr)down);
        }
    }
    public static int Run(string app,string args,string cwd,string desktop,string ready,string done) {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        var si=new Startup {cb=Marshal.SizeOf<Startup>(),desktop="WinSta0\\"+desktop}; PI pi;
        // Explicit conhost for the console case; GUI noctty creates its own ConPTY.
        if(!CreateProcessW(app,new StringBuilder("\""+app+"\" "+args),IntPtr.Zero,IntPtr.Zero,false,4,IntPtr.Zero,cwd,ref si,out pi)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var created=Created(pi.process);
        var job=CreateJobObjectW(IntPtr.Zero,null);
        try {
            var limits=new ExtendedLimits(); limits.basic.flags=0x2000; // KILL_ON_JOB_CLOSE
            if(job==IntPtr.Zero || !SetInformationJobObject(job,9,ref limits,Marshal.SizeOf<ExtendedLimits>()) || !AssignProcessToJobObject(job,pi.process)) throw new Exception("Owned job setup failed");
            var path=new StringBuilder(32768); int n=path.Capacity;
            if(!QueryFullProcessImageNameW(pi.process,0,path,ref n) || !String.Equals(path.ToString(),app,StringComparison.OrdinalIgnoreCase)) throw new Exception("Launch identity mismatch");
            if(ResumeThread(pi.thread)==0xffffffff) throw new Exception("Resume failed");
            var desk=OpenPrivateDesktop(desktop); bool verified=false;
            try {
                for(int attempt=0; attempt<200 && !verified; attempt++) {
                    EnumDesktopWindows(desk,(h,p)=>{int owner; GetWindowThreadProcessId(h,out owner); if(owner==pi.pid || (ClassOf(h)=="ConsoleWindowClass" && InJob(owner,job))) verified=true; return true;},IntPtr.Zero);
                    if(!verified) System.Threading.Thread.Sleep(10);
                }
            } finally { CloseDesktop(desk); }
            if(!verified) throw new Exception("No owned window on the private desktop");
            var process=pi.process;
            ResizeStep(desktop,pi.pid,job,ready,done,()=>WaitForSingleObject(process,0)!=0);
            if(WaitForSingleObject(pi.process,60000)!=0) throw new Exception("Clink smoke timeout");
            return pi.pid;
        } finally {
            if(WaitForSingleObject(pi.process,0)!=0) {
                var path=new StringBuilder(32768); int n=path.Capacity;
                if(Created(pi.process)==created && QueryFullProcessImageNameW(pi.process,0,path,ref n) && String.Equals(path.ToString(),app,StringComparison.OrdinalIgnoreCase)) TerminateProcess(pi.process,1);
            }
            // The private job owns all descendants from before resume; closing it
            // bounds cleanup even if a test command leaves a helper running.
            if(job!=IntPtr.Zero) CloseHandle(job);
            CloseHandle(pi.thread); CloseHandle(pi.process);
        }
    }
}
'@
function Fingerprint([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.Length):$($item.LastWriteTimeUtc.Ticks):$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)"
}
$ledger = Join-Path $env:LOCALAPPDATA 'noctty/startup-attempts.json'
$before = Fingerprint $ledger
# A wrong -Clink would otherwise surface only as a timeout, once cmd fails to
# start it.
if (-not (Test-Path -LiteralPath $Clink -PathType Leaf)) { throw "-Clink must name clink_x64.exe in an extracted portable Clink: $Clink" }
$Clink = (Resolve-Path -LiteralPath $Clink).ProviderPath
$Run = [IO.Path]::GetFullPath($Run)
if (Test-Path -LiteralPath $Run) { throw 'Run must be a new directory.' }
New-Item -ItemType Directory -Path $Run | Out-Null
foreach ($dir in 'appdata','localappdata','profile','integration','scripts') { New-Item -ItemType Directory -Path (Join-Path $Run $dir) | Out-Null }
Copy-Item -LiteralPath $IntegrationScript -Destination (Join-Path $Run 'integration')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cmd-clink.lua') -Destination (Join-Path $Run 'profile/zz-noctty-smoke.lua')
# Clink loads the first .inputrc it finds, in the profile before %USERPROFILE%,
# %LOCALAPPDATA%, %APPDATA% and %HOME%; an empty one here keeps a user's own out.
[IO.File]::WriteAllText((Join-Path $Run 'profile/.inputrc'), '')
# clink.autostart = nul: otherwise Clink runs a clink_start.cmd from the -Clink
# folder at the first prompt.
[IO.File]::WriteAllLines((Join-Path $Run 'profile/clink_settings'), [string[]]@('clink.autoupdate = off', 'clink.autostart = nul'))
$script = Join-Path $Run ('integration/' + [IO.Path]::GetFileName($IntegrationScript))
$result = Join-Path $Run 'results.txt'
# The resize step's handshake with the test's Lua: it writes `ready` at the
# prompt, the harness narrows the window, it writes `done`, the harness
# presses Enter.
$resizeReady = Join-Path $Run 'resize-ready.txt'
$resizeDone = Join-Path $Run 'resize-done.txt'
$batch = Join-Path $Run 'launch.cmd'
# `--scripts` names an empty folder: without it Clink takes the script folder a
# Clink started with `--scripts` left in the hidden variable `=clink.scripts`
# (no CLINK_* scrub reaches it) and searches it before any other.
@"
@echo off
"$Clink" inject -q -p "$Run\profile" --scripts "$Run\scripts"
"@ | Set-Content -LiteralPath $batch -Encoding utf8NoBOM
if ($Bin) {
    $portable = Join-Path $Run 'portable'
    Copy-Item -LiteralPath $Bin -Destination $portable -Recurse
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    $app = Join-Path $portable 'noctty.exe'
    # A class of its own, so the copy never hands its command line to a
    # running noctty over the single-instance pipe.
    $arguments = '--config-default-files=false --auto-update=off --confirm-close-surface=false --window-save-state=never --single-instance=false --class=noctty-test-clink-' + [guid]::NewGuid().ToString('n') + ' -e C:\Windows\System32\cmd.exe /d /k "' + $batch + '"'
} else {
    $app = Join-Path $env:SystemRoot 'System32/conhost.exe'
    $arguments = 'C:\Windows\System32\cmd.exe /d /k "' + $batch + '"'
}
$environment = @{
    APPDATA = (Join-Path $Run 'appdata'); LOCALAPPDATA = (Join-Path $Run 'localappdata')
    CLINK_PATH = (Join-Path $Run 'integration'); NOCTTY_CLINK_SCRIPT = $script; NOCTTY_CLINK_RESULTS = $result
    NOCTTY_CLINK_RESIZE_READY = $resizeReady; NOCTTY_CLINK_RESIZE_DONE = $resizeDone
}
# Clink reads its overrides from CLINK_* variables, and several beat `inject -p`
# or add places to load from (CLINK_PROFILE, CLINK_SETTINGS, CLINK_INPUTRC,
# CLINK_CUSTOMPROMPT, CLINK_COLORTHEME, CLINK_THEMES_DIR, CLINK_COMPLETIONS_DIR).
# Every inherited one is removed for the run and put back after; removed, not
# set to $null, which PowerShell passes as "" and so leaves an empty override.
# Script folders registered with `clink installscripts` would load too, and
# nothing turns them off, so the run refuses to start with any registered.
# Read through the registry API: a property of Get-ItemProperty's null result
# throws under Set-StrictMode, and Get-ItemPropertyValue throws for a key that
# exists without the value, whatever -ErrorAction says.
function Test-ClinkInstalledScripts([string] $SubKey = 'Software\Clink', [string] $ValueName = 'InstalledScripts') {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($null -eq $key) { return $false }
    try { return -not [string]::IsNullOrWhiteSpace([string]$key.GetValue($ValueName)) }
    finally { $key.Dispose() }
}
if (Test-ClinkInstalledScripts) {
    throw 'Clink script folders are registered with clink installscripts (HKCU\Software\Clink InstalledScripts); they would load into the test.'
}
$savedClink = @{}
foreach ($variable in @(Get-ChildItem -Path Env: | Where-Object { $_.Name -like 'CLINK_*' })) { $savedClink[$variable.Name] = $variable.Value }
$saved = @{}
$desktopName = 'noctty-clink-' + [guid]::NewGuid().ToString('n')
$desktop = [ClinkSmoke]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x1ff,[IntPtr]::Zero)
if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
try {
    foreach ($name in $savedClink.Keys) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction Ignore }
    foreach ($key in $environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$environment[$key]) }
    $childPid = [ClinkSmoke]::Run($app,$arguments,$Run,$desktopName,$resizeReady,$resizeDone)
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    foreach ($name in $savedClink.Keys) { Set-Item -LiteralPath "Env:\$name" -Value $savedClink[$name] }
    [void][ClinkSmoke]::CloseDesktop($desktop)
    $after = Fingerprint $ledger
    @{Before=$before;After=$after;Unchanged=($before -eq $after);Pid=$childPid;Desktop=$desktopName} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'isolation.json')
    if ($before -ne $after) { throw 'Real startup ledger changed during Clink smoke.' }
}
if (-not (Test-Path -LiteralPath $result)) { throw 'Clink produced no results.' }
$lines = Get-Content -LiteralPath $result
$lines | Write-Output
if ('PASS ALL' -notin $lines) { throw 'Clink smoke failed.' }

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
