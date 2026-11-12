# Shared by interactive-win11-stale-modes.ps1 and interactive-win11-mouse-input.ps1, which run
# their worker and a portable koreterm copy on a newly created hidden desktop. Dot-source it.
# [HiddenDesktopNative] holds the desktop, process, owned-job and window plumbing both use;
# each harness keeps its own input and fixture code.

function Get-Fingerprint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.Ticks):$($item.Length):$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)"
}

# Real shell histories are private. Guard only their metadata; never open or hash them.
function Get-HistoryMetadata([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
}

if (-not ('HiddenDesktopNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class HiddenDesktopNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI {
        public int cb; public string reserved, desktop, title;
        public int x,y,xsize,ysize,xchars,ychars,fill,flags;
        public short show, cbReserved; public IntPtr reserved2, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] public struct SA {
        public int size; public IntPtr descriptor; [MarshalAs(UnmanagedType.Bool)] public bool inherit;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateFileW(string path, uint access, uint share, ref SA security, uint creation, uint flags, IntPtr template);
    public delegate bool EnumProc(IntPtr hwnd, IntPtr arg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr security);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateProcessW(string application, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref SI startup, out PI info);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObjectW(IntPtr security, string name);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr data, uint size, out uint returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool member);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    public static int[] JobPids(IntPtr job) {
        // This harness has few children. MORE_DATA fails closed rather than
        // truncating an unexpectedly large process list.
        int size=8+IntPtr.Size*256; IntPtr buffer=Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if(!QueryInformationJobObject(job,3,buffer,(uint)size,out returned)) throw new Exception("Query owned job failed: "+Marshal.GetLastWin32Error());
            int count=Marshal.ReadInt32(buffer,4); var ids=new int[count];
            for(int i=0;i<count;i++) ids[i]=(int)Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size);
            return ids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static int[] ReapOwnedJob(IntPtr job) {
        var stopped=new List<int>();
        // Exited processes can remain in job accounting briefly. Poll for
        // up to ten seconds while retaining the strict empty-job oracle.
        var timer=System.Diagnostics.Stopwatch.StartNew();
        while(timer.ElapsedMilliseconds<10000) {
            int[] ids=JobPids(job); if(ids.Length==0) return stopped.ToArray();
            foreach(int id in ids) {
                // Hold the exact process handle and freshly verify membership
                // before terminating. A reused PID outside our job is skipped.
                IntPtr handle=OpenProcess(0x00101001,false,id);
                if(handle==IntPtr.Zero) continue;
                try {
                    bool member;
                    if(!IsProcessInJob(handle,job,out member)) throw new Exception("Owned job membership query failed");
                    if(!member) continue;
                    uint code;
                    if(!GetExitCodeProcess(handle,out code)) throw new Exception("Owned process query failed");
                    if(code!=259) continue;
                    if(!TerminateProcess(handle,1)) {
                        if(!GetExitCodeProcess(handle,out code) || code==259) throw new Exception("Owned process termination failed");
                    } else stopped.Add(id);
                    uint remaining=(uint)Math.Max(0,10000-timer.ElapsedMilliseconds);
                    uint waited=WaitForSingleObject(handle,remaining);
                    // At the deadline, let the final job-accounting query
                    // decide whether all processes have exited.
                    if(waited!=0 && waited!=258) throw new Exception("Waiting for owned process failed");
                } finally { CloseHandle(handle); }
            }
            System.Threading.Thread.Sleep(10);
        }
        if(JobPids(job).Length!=0) throw new Exception("Owned job still has processes after cleanup");
        return stopped.ToArray();
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    public static string ClassOf(IntPtr hwnd) { var s=new StringBuilder(256); GetClassNameW(hwnd,s,256); return s.ToString(); }
    // The last top-level window of `cls` that process `pid` owns, in the order Windows enumerates
    // them, or zero.
    public static IntPtr TopWindow(int pid,string cls) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,a)=> { int p; GetWindowThreadProcessId(h,out p); if(p==pid && ClassOf(h)==cls) found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static IntPtr Host(int pid) { return TopWindow(pid,"koreterm.win32.host"); }
    public static IntPtr Surface(IntPtr host) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(h,a)=> { if(ClassOf(h)=="koreterm.win32") found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static void Send(IntPtr hwnd,uint msg,int value,long bits) {
        UIntPtr result;
        if(SendMessageTimeoutW(hwnd,msg,(UIntPtr)(uint)value,(IntPtr)bits,2,5000,out result)==IntPtr.Zero)
            throw new Exception("SendMessageTimeout failed: "+Marshal.GetLastWin32Error());
    }
}
'@
}

function Start-Hidden([string] $Application, [string] $Command, [string] $Directory, [string] $Desktop, [IntPtr] $OwnerJob = [IntPtr]::Zero, [switch] $NewProcessGroup, [string] $LogPath, [hashtable] $EnvironmentOverrides = @{}) {
    if (-not $Desktop -or $Desktop -notmatch '^[^\\]+\\[^\\]+$' -or $Desktop -match '\\Default$') { throw 'Explicit private desktop required.' }
    $si = [HiddenDesktopNative+SI]::new()
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][HiddenDesktopNative+SI])
    $si.desktop = $Desktop
    $pi = [HiddenDesktopNative+PI]::new()
    # CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS; suspend owned drivers
    # until their job assignment is complete. A new process group is opt-in
    # for the Modes/All controller normalization exercise, never the matrix.
    $flags = if ($OwnerJob -ne [IntPtr]::Zero) { 0x08004004 } else { 0x08004000 }
    if ($NewProcessGroup) { $flags = $flags -bor 0x200 } # CREATE_NEW_PROCESS_GROUP
    $environmentBlock = [IntPtr]::Zero
    $logHandle = [IntPtr]::Zero
    $inputHandle = [IntPtr]::Zero
    try {
        if ($EnvironmentOverrides.Count -ne 0) {
            # Redirect the driver from its first instruction, including
            # PowerShell startup and Add-Type, without changing this parent.
            $entries = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $entries[$entry.Key] = $entry.Value }
            foreach ($name in $EnvironmentOverrides.Keys) { $entries[$name] = $EnvironmentOverrides[$name] }
            $lines = foreach ($entry in $entries.GetEnumerator()) { $entry.Key + '=' + $entry.Value }
            $environmentBlock = [Runtime.InteropServices.Marshal]::StringToHGlobalUni(($lines -join "`0") + "`0`0")
            $flags = $flags -bor 0x400 # CREATE_UNICODE_ENVIRONMENT
        }
        if ($LogPath) {
            $security = [HiddenDesktopNative+SA]::new()
            $security.size = [Runtime.InteropServices.Marshal]::SizeOf($security)
            $security.inherit = $true
            $logHandle = [HiddenDesktopNative]::CreateFileW($LogPath, 0x40000000, 1, [ref]$security, 1, 0x80, [IntPtr]::Zero)
            if ($logHandle -eq [IntPtr](-1)) { throw 'Opening compiler log failed.' }
            $inputHandle = [HiddenDesktopNative]::CreateFileW('NUL', 2147483648, 3, [ref]$security, 3, 0x80, [IntPtr]::Zero)
            if ($inputHandle -eq [IntPtr](-1)) { throw 'Opening compiler input failed.' }
            $si.flags = 0x100 # STARTF_USESTDHANDLES
            $si.stdin = $inputHandle; $si.stdout = $logHandle; $si.stderr = $logHandle
        }
        if (-not [HiddenDesktopNative]::CreateProcessW($Application, [Text.StringBuilder]::new($Command),
                [IntPtr]::Zero, [IntPtr]::Zero, [bool]$LogPath, $flags, $environmentBlock, $Directory, [ref]$si, [ref]$pi)) {
            throw "CreateProcessW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    }
    finally {
        if ($environmentBlock -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($environmentBlock) }
        foreach ($handle in @($logHandle, $inputHandle)) {
            if ($handle -ne [IntPtr]::Zero -and $handle -ne [IntPtr](-1)) { [void][HiddenDesktopNative]::CloseHandle($handle) }
        }
    }
    try {
        # Assign the suspended driver before its first instruction: every
        # descendant inherits containment even if the worker cannot finalize.
        if ($OwnerJob -ne [IntPtr]::Zero) {
            if (-not [HiddenDesktopNative]::AssignProcessToJobObject($OwnerJob, $pi.process)) {
                [void][HiddenDesktopNative]::TerminateProcess($pi.process, 1)
                throw 'Assigning suspended driver to owned job failed.'
            }
            if ([HiddenDesktopNative]::ResumeThread($pi.thread) -eq [uint32]::MaxValue) {
                [void][HiddenDesktopNative]::TerminateProcess($pi.process, 1)
                throw 'Resuming contained driver failed.'
            }
        }
        if ($LogPath) {
            # #477: wait through the original PI handle. A fast compiler
            # failure must retain its exit code and log, even after PID exit.
            $wait = [HiddenDesktopNative]::WaitForSingleObject($pi.process, 60000)
            if ($wait -eq 258) {
                if (-not [HiddenDesktopNative]::TerminateProcess($pi.process, 1) -or
                    [HiddenDesktopNative]::WaitForSingleObject($pi.process, 10000) -ne 0) {
                    throw "Terminating timed-out compiler failed; see $LogPath"
                }
                throw "Console fixture compilation timed out; see $LogPath"
            }
            if ($wait -ne 0) { throw "Waiting for compiler failed; see $LogPath" }
            $exitCode = [uint32]259
            if (-not [HiddenDesktopNative]::GetExitCodeProcess($pi.process, [ref]$exitCode)) { throw "Reading compiler exit code failed; see $LogPath" }
            return $exitCode
        }
    }
    finally {
        [void][HiddenDesktopNative]::CloseHandle($pi.thread)
        [void][HiddenDesktopNative]::CloseHandle($pi.process)
    }
    return [Diagnostics.Process]::GetProcessById($pi.pid)
}

function Stop-Owned([Diagnostics.Process] $Process, [string] $ExpectedPath, [datetime] $StartTime) {
    # Re-read the exact PID immediately before termination; reject PID reuse
    # and executable changes. No name/pattern or system-wide tree kill.
    $fresh = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if (-not $fresh) { return }
    if ($fresh.StartTime -ne $StartTime -or $fresh.Path -ne $ExpectedPath) { throw "PID identity changed: $($Process.Id)" }
    $fresh.Kill()
    if (-not $fresh.WaitForExit(10000)) { throw "Owned process $($fresh.Id) did not exit." }
}
