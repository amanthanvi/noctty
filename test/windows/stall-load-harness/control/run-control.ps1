#requires -Version 7.0
# MEASUREMENT ONLY (pacing-stall2 positive control driver). Creates a private
# desktop (CreateDesktopW), starts control-child.ps1 in Windows PowerShell on it
# (lpDesktop = WinSta0\<desktop>, CREATE_NO_WINDOW, in an owned kill-on-close
# job), runs watchdog.ps1 in control mode against its WinForms window, then
# stops only its own job and closes the desktop. Logs the clipboard sequence
# number before and after; never reads or writes the clipboard.
param([Parameter(Mandatory)][string]$OutDir, [string]$SymPath, [int]$SleepMs = 3000)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class W14Ctl {
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
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a,b,c,d,e,f; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits { public BasicLimits basic; public IoCounters io; public UIntPtr pm,jm,ppm,pjm; }
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j,int t,ref JobLimits l,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j,IntPtr p);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p,uint c);
    [DllImport("kernel32.dll")] public static extern bool TerminateJobObject(IntPtr j,uint c);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static IntPtr Job() {
        var j=CreateJobObjectW(IntPtr.Zero,null); var l=new JobLimits(); l.basic.flags=0x2000;
        if(!SetInformationJobObject(j,9,ref l,(uint)Marshal.SizeOf(typeof(JobLimits)))) throw new Exception("job limit failed");
        return j;
    }
    public static ProcessInfo Launch(string app,string cmd,string cwd,string desktop,IntPtr job) {
        if(!desktop.StartsWith("WinSta0\\")) throw new Exception("needs WinSta0\\<desktop>");
        var s=new Startup{cb=Marshal.SizeOf(typeof(Startup)),desktop=desktop}; ProcessInfo p;
        if(!CreateProcessW(app,new StringBuilder(cmd),IntPtr.Zero,IntPtr.Zero,false,0x08000004,IntPtr.Zero,cwd,ref s,out p)) throw new Exception("CreateProcess failed "+Marshal.GetLastWin32Error());
        if(!AssignProcessToJobObject(job,p.process)||ResumeThread(p.thread)==0xFFFFFFFF) { TerminateProcess(p.process,1); throw new Exception("assign/resume failed"); }
        return p;
    }
}
'@
[void](New-Item -ItemType Directory -Force -Path $OutDir)
$log = Join-Path $OutDir 'control.log'
function Say($m) { Add-Content -LiteralPath $log -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $m) }
$clip0 = [W14Ctl]::GetClipboardSequenceNumber()
$name = 'w14-stall2-ctl-' + [guid]::NewGuid().ToString('N')
$desk = [W14Ctl]::CreateDesktopW($name, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
if ($desk -eq [IntPtr]::Zero) { throw 'CreateDesktop failed' }
$job = [W14Ctl]::Job()
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ready = Join-Path $OutDir 'ready.txt'; $childOut = Join-Path $OutDir 'child.log'
$cmd = "`"$ps`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\control-child.ps1`" -Ready `"$ready`" -Out `"$childOut`" -SleepMs $SleepMs"
try {
    $p = [W14Ctl]::Launch($ps, $cmd, $OutDir, "WinSta0\$name", $job)
    Say ("child pid={0} desktop={1} clipboard_seq={2}" -f $p.pid, $name, $clip0)
    $wdArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'watchdog.ps1'), '-TargetPid', $p.pid, '-Desktop', $name, '-ExpectImage', $ps,
        '-ClassPrefix', 'WindowsForms10.Window.8.app', '-OutDir', (Join-Path $OutDir 'wd'), '-ReadyFile', $ready)
    if ($SymPath) { $wdArgs += @('-SymPath', $SymPath) }
    $wd = Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList $wdArgs -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $OutDir 'wd.out') -RedirectStandardError (Join-Path $OutDir 'wd.err')
    Say ("watchdog pid={0}" -f $wd.Id)
    $r = [W14Ctl]::WaitForSingleObject($p.process, 120000)
    Say ("child wait={0}" -f $(if ($r -eq 0) { 'exited' } else { 'timeout' }))
    if (-not $wd.WaitForExit(240000)) { Say 'watchdog still running after 240 s' } else { Say ("watchdog exit={0}" -f $wd.ExitCode) }
} finally {
    [void][W14Ctl]::TerminateJobObject($job, 1); [void][W14Ctl]::CloseHandle($job)
    [void][W14Ctl]::CloseDesktop($desk)
    Say ("done clipboard_seq before={0} after={1}" -f $clip0, [W14Ctl]::GetClipboardSequenceNumber())
}
