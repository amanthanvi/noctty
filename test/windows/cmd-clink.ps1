#requires -Version 7.0
<#
Exercise Clink's real script discovery, stopping prompt filters, and C/D hooks.
Supply an already extracted official portable Clink; never installs or modifies
AutoRun. -Bin additionally runs the test inside a copied portable noctty build.
Without -Bin, an explicit conhost runs cmd on the private desktop. No real input,
clipboard, shell profiles, or user history. Evidence is retained in a NEW Run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Clink,
    [Parameter(Mandatory)][string]$Run,
    [string]$Bin,
    [string]$IntegrationScript = (Join-Path $PSScriptRoot '../../src/shell-integration/cmd/noctty-shell-integration.lua')
)
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
    static long Created(IntPtr p) { long c,e,k,u; if(!GetProcessTimes(p,out c,out e,out k,out u)) throw new Exception("Process time query failed"); return c; }
    public static int Run(string app,string args,string cwd,string desktop) {
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
            var desk=OpenDesktopW(desktop,0,false,1); bool verified=false;
            try {
                for(int attempt=0; attempt<200 && !verified; attempt++) {
                    EnumDesktopWindows(desk,(h,p)=>{int owner; GetWindowThreadProcessId(h,out owner); if(owner==pi.pid) verified=true; return true;},IntPtr.Zero);
                    if(!verified) System.Threading.Thread.Sleep(10);
                }
            } finally { if(desk!=IntPtr.Zero) CloseDesktop(desk); }
            if(!verified) throw new Exception("No owned window on the private desktop");            if(WaitForSingleObject(pi.process,45000)!=0) throw new Exception("Clink smoke timeout");
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
$Run = [IO.Path]::GetFullPath($Run)
if (Test-Path -LiteralPath $Run) { throw 'Run must be a new directory.' }
New-Item -ItemType Directory -Path $Run | Out-Null
foreach ($dir in 'appdata','localappdata','profile','integration') { New-Item -ItemType Directory -Path (Join-Path $Run $dir) | Out-Null }
Copy-Item -LiteralPath $IntegrationScript -Destination (Join-Path $Run 'integration')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cmd-clink.lua') -Destination (Join-Path $Run 'profile/zz-noctty-smoke.lua')
$script = Join-Path $Run ('integration/' + [IO.Path]::GetFileName($IntegrationScript))
$result = Join-Path $Run 'results.txt'
$batch = Join-Path $Run 'launch.cmd'
@"
@echo off
"$([IO.Path]::GetFullPath($Clink))" inject -q -p "$Run\profile"
"@ | Set-Content -LiteralPath $batch -Encoding utf8NoBOM
if ($Bin) {
    $portable = Join-Path $Run 'portable'
    Copy-Item -LiteralPath $Bin -Destination $portable -Recurse
    Set-Content -LiteralPath (Join-Path $portable 'noctty.portable') -Value '' -NoNewline
    $app = Join-Path $portable 'noctty.exe'
    $args = '--config-default-files=false --auto-update=off --confirm-close-surface=false --window-save-state=never -e C:\Windows\System32\cmd.exe /d /k "' + $batch + '"'
} else {
    $app = Join-Path $env:SystemRoot 'System32/conhost.exe'
    $args = 'C:\Windows\System32\cmd.exe /d /k "' + $batch + '"'
}
$environment = @{
    APPDATA = (Join-Path $Run 'appdata'); LOCALAPPDATA = (Join-Path $Run 'localappdata')
    CLINK_PATH = (Join-Path $Run 'integration'); NOCTTY_CLINK_SCRIPT = $script; NOCTTY_CLINK_RESULTS = $result
}
$saved = @{}
$desktopName = 'noctty-clink-' + [guid]::NewGuid().ToString('n')
$desktop = [ClinkSmoke]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x1ff,[IntPtr]::Zero)
if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
try {
    foreach ($key in $environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$environment[$key]) }
    $childPid = [ClinkSmoke]::Run($app,$args,$Run,$desktopName)
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    [void][ClinkSmoke]::CloseDesktop($desktop)
    $after = Fingerprint $ledger
    @{Before=$before;After=$after;Unchanged=($before -eq $after);Pid=$childPid;Desktop=$desktopName} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'isolation.json')
    if ($before -ne $after) { throw 'Real startup ledger changed during Clink smoke.' }
}
if (-not (Test-Path -LiteralPath $result)) { throw 'Clink produced no results.' }
$lines = Get-Content -LiteralPath $result
$lines | Write-Output
if ('PASS ALL' -notin $lines) { throw 'Clink smoke failed.' }
