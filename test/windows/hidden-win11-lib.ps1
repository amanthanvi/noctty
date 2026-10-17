# Shared by the hidden-desktop harnesses that start portable copies of noctty
# (hidden-win11-profile-matrix.ps1, hidden-win11-embedding-idle.ps1). Dot-source it.
#
# Safety rules these harnesses keep (AGENTS.md, test/windows/README.md):
#   * The driver and noctty use explicit desktop names and inherit ONE desktop
#     handle, which their ordinary shell/discovery launches can propagate.
#     The driver self-reports its connected desktop before parent approval.
#     Named-desktop enumeration checks actual job window PIDs; Default rejects all job windows.
#     Sampling does not isolate short-lived processes or external brokers.
#   * Launches are restricted to ephemeral GitHub-hosted runners until the exact
#     bundled and in-box ConPTY host placement has been observed there.
#   * Every noctty is a copy with a `noctty.portable` marker, with LOCALAPPDATA
#     and APPDATA redirected into the run directory.
#   * The real startup-attempts.json and the real PSReadLine history file are
#     checked by size, time and hash before and after, never read.
#   * The clipboard sequence number is logged before and after. Nothing here
#     can copy (no selection, no copy key, no OSC 52 answer).
#   * A noctty with the product AppUserModelID would replace the real taskbar
#     jump list, so the binary must carry the measurement AUMID unless
#     -AllowProductAumid says the machine is an ephemeral runner.

if (-not ('HiddenWin' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class HiddenWin {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll", SetLastError=true)] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", SetLastError=true)] static extern bool EnumDesktopWindows(IntPtr desktop, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", SetLastError=true)] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeoutMs, out IntPtr result);
    public static bool Send(IntPtr h, uint m, long w, long l) {
        IntPtr result;
        return SendMessageTimeoutW(h, m, new IntPtr(w), new IntPtr(l), 2, 5000, out result) != IntPtr.Zero;
    }
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateDesktopW(string n, IntPtr dev, IntPtr mode, int flags, uint access, ref SecurityAttributes sa);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", SetLastError=true)] static extern bool DestroyWindow(IntPtr hwnd);
    public static IntPtr CreateDriverSentinel() {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted")
            throw new Exception("Driver sentinel requires an ephemeral GitHub-hosted runner");
        // Hidden WS_POPUP, WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW. Never shown or activated.
        var hwnd = CreateWindowExW(0x08000080, "STATIC", "", 0x80000000, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Create driver sentinel");
        return hwnd;
    }
    public static void DestroyDriverSentinel(IntPtr hwnd) {
        if (!DestroyWindow(hwnd)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Destroy driver sentinel");
    }
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr job, int type, out JobAccounting accounting, uint size, IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime, kernelTime, periodUserTime, periodKernelTime;
        public uint pageFaults, totalProcesses, activeProcesses, terminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime, jobTime; public uint flags;
        public UIntPtr minWorking, maxWorking; public uint activeProcesses;
        public UIntPtr affinity; public uint priority, scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }
    public static IntPtr CreateOwnedJob() {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var limits = new JobLimits(); limits.basic.flags = 0x2000; // KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) {
            CloseHandle(job); throw new Exception("SetInformationJobObject failed");
        }
        return job;
    }
    public static uint StopOwnedJob(IntPtr job) {
        try {
            if (!TerminateJobObject(job, 1)) throw new Exception("Terminate owned job failed");
            var deadline = DateTime.UtcNow.AddSeconds(5);
            do {
                JobAccounting accounting;
                if (!QueryInformationJobObject(job, 1, out accounting, (uint)Marshal.SizeOf<JobAccounting>(), IntPtr.Zero))
                    throw new Exception("Query owned job failed");
                if (accounting.activeProcesses == 0) return accounting.totalProcesses;
                System.Threading.Thread.Sleep(10);
            } while (DateTime.UtcNow < deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(job); }
    }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public bool inherit; }
    public static IntPtr CreateInheritedDesktop(string name) {
        var sa = new SecurityAttributes { length = Marshal.SizeOf<SecurityAttributes>(), inherit = true };
        var desktop = CreateDesktopW(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, ref sa);
        if (desktop == IntPtr.Zero) throw new Exception("Create inheritable desktop failed: " + Marshal.GetLastWin32Error());
        return desktop;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes sa, uint disposition, uint flags, IntPtr template);
    // Starts a process suspended on an explicit desktop, assigns it to the owned job and resumes it.
    // stderrPath, when not empty, is created and becomes the child's standard error (its other
    // standard handles are null). PowerShell hands a $null string to .NET as "".
    public static ProcessInfo Launch(string app, string command, string cwd, string desktop, IntPtr job, string stderrPath) {
        // No STARTF_USESHOWWINDOW: a window hidden by the launcher takes no posted input, and this
        // desktop is never displayed anyway.
        var si = new Startup { cb = Marshal.SizeOf<Startup>(), desktop = desktop }; ProcessInfo pi;
        IntPtr err = IntPtr.Zero;
        if (!string.IsNullOrEmpty(stderrPath)) {
            var sa = new SecurityAttributes { length = Marshal.SizeOf<SecurityAttributes>(), inherit = true };
            err = CreateFileW(stderrPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
            if (err == new IntPtr(-1)) throw new Exception("Creating the stderr file failed: " + Marshal.GetLastWin32Error());
            si.flags |= 0x100; si.error = err;
        }
        bool created;
        try { created = CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true, 0x08004004, IntPtr.Zero, cwd, ref si, out pi); }
        finally { if (err != IntPtr.Zero) CloseHandle(err); }
        if (!created) throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, pi.process) || ResumeThread(pi.thread) == 0xFFFFFFFF) {
            TerminateProcess(pi.process, 1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume owned process failed");
        }
        return pi;
    }
    static string Class(IntPtr h) { var s = new StringBuilder(128); GetClassNameW(h, s, 128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list = new List<IntPtr>(); EnumWindows((h, p) => { int id; GetWindowThreadProcessId(h, out id);
            if (id == pid && Class(h) == "noctty.win32.host") list.Add(h); return true;
        }, IntPtr.Zero); return list.ToArray();
    }
    // Every visible top-level window the process owns, dialogs included, whatever its class.
    public static string[] VisibleTopLevelClasses(int pid) {
        var list = new List<string>(); EnumWindows((h, p) => { int id; GetWindowThreadProcessId(h, out id);
            if (id == pid && IsWindowVisible(h)) list.Add(Class(h)); return true;
        }, IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr[] Surfaces(IntPtr host) {
        var list = new List<IntPtr>();
        EnumChildWindows(host, (c, p) => { if (Class(c) == "noctty.win32" && IsWindowVisible(c)) list.Add(c); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint threadId);
    // SetLastError=true also refreshes .NET's cached last error after this call.
    [DllImport("kernel32.dll", SetLastError=true)] static extern void SetLastError(uint error);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);
    public static string CurrentDesktopName() {
        // Connect this calling thread to its assigned desktop without creating a window.
        if (GetDesktopWindow() == IntPtr.Zero) throw new Exception("Current desktop connection failed");
        var name = ThreadDesktopName(GetCurrentThreadId());
        if (string.IsNullOrEmpty(name)) throw new Exception("Current thread has no connected desktop");
        return name;
    }
    public static string ThreadDesktopName(uint threadId) {
        SetLastError(0);
        var desktop = GetThreadDesktop(threadId);
        if (desktop == IntPtr.Zero) {
            int error = Marshal.GetLastWin32Error();
            if (error == 0) return null; // Non-GUI thread with no desktop connection.
            throw new System.ComponentModel.Win32Exception(error, "GetThreadDesktop");
        }
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformationW(desktop, 2, name, 512, out needed))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetUserObjectInformationW");
        return name.ToString();
    }
    public static string CurrentWindowStationName() {
        var station = GetProcessWindowStation();
        if (station == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetProcessWindowStation");
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformationW(station, 2, name, 512, out needed))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Window station GetUserObjectInformationW");
        return name.ToString();
    }
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr info, uint size, IntPtr returned);
    public static int[] JobProcessIds(IntPtr job) {
        const int bytes = 65536;
        var buffer = Marshal.AllocHGlobal(bytes);
        try {
            if (!QueryInformationJobObject(job, 3, buffer, bytes, IntPtr.Zero)) throw new Exception("Job process query failed");
            int assigned = Marshal.ReadInt32(buffer), count = Marshal.ReadInt32(buffer, 4);
            if (count < 0 || count != assigned || count > (bytes - 8) / IntPtr.Size) throw new Exception("Job process query incomplete");
            var ids = new int[count];
            for (int i = 0; i < count; i++) ids[i] = checked((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64());
            return ids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public sealed class DesktopObservation {
        public int ProcessId, ThreadId;
        public string Name, Desktop, Error, ErrorApi;
        public int? ErrorCode;
        public bool Exited, ThreadExited, Unconnected;
    }
    static bool ConclusivelyExited(Process process) {
        try { return process.HasExited; } catch { return false; }
    }
    static bool ConclusivelyThreadExited(Process process, int threadId) {
        try {
            // Refresh the retained process instance, not a new lookup by a reusable PID.
            process.Refresh();
            foreach (ProcessThread thread in process.Threads)
                if (thread.Id == threadId) return false;
            return true;
        } catch { return false; }
    }
    public static DesktopObservation[] ObserveDesktopThreads(int[] ids) {
        var rows = new List<DesktopObservation>();
        foreach (int id in ids) {
            Process process;
            try { process = Process.GetProcessById(id); }
            catch (ArgumentException) { rows.Add(new DesktopObservation { ProcessId = id, Exited = true }); continue; }
            using (process) {
                var row = new DesktopObservation { ProcessId = id };
                try {
                    // Retain the process handle before enumerating its threads, so an exit
                    // check concerns this process instance rather than a subsequently reused PID.
                    var handle = process.Handle;
                    row.Name = process.ProcessName;
                    var threads = process.Threads;
                    if (threads.Count == 0) throw new Exception("No observed threads");
                    foreach (ProcessThread thread in threads) {
                        row = new DesktopObservation { ProcessId = id, ThreadId = thread.Id, Name = process.ProcessName };
                        rows.Add(row);
                        try {
                            row.Desktop = ThreadDesktopName((uint)thread.Id);
                            row.Unconnected = row.Desktop == null;
                        }
                        catch (Exception error) {
                            // Only our fixed API labels and numeric codes leave this native seam.
                            // Keep them even when a fresh exit check explains the query race.
                            var nativeError = error as System.ComponentModel.Win32Exception;
                            if (nativeError != null) {
                                row.ErrorApi = nativeError.Message;
                                row.ErrorCode = nativeError.NativeErrorCode;
                            }
                            row.Exited = ConclusivelyExited(process);
                            row.ThreadExited = !row.Exited && ConclusivelyThreadExited(process, row.ThreadId);
                            if (!row.Exited && !row.ThreadExited)
                                row.Error = nativeError == null ? "Thread desktop query failed" : row.ErrorApi + " failed";
                        }
                    }
                } catch {
                    row.Exited = ConclusivelyExited(process);
                    if (!row.Exited) row.Error = "Process thread enumeration failed";
                    if (!rows.Contains(row)) rows.Add(row);
                }
            }
        }
        return rows.ToArray();
    }
    public sealed class DesktopWindowObservation {
        public int ProcessId, ThreadId;
        public bool CompletedAttempt;
    }
    // EnumWindows sees the calling thread's desktop. Call only from the outer Default driver.
    // No window titles or unrelated window metadata are retained.
    public static DesktopWindowObservation[] DefaultJobWindows(IntPtr job) {
        var ids = new HashSet<int>(JobProcessIds(job));
        var rows = new List<DesktopWindowObservation>();
        for (int attempt = 0; attempt < 3; attempt++) {
            int attemptStart = rows.Count;
            bool ownerFailed = false; int ownerError = 0;
            SetLastError(0);
            bool complete = EnumWindows((h, p) => {
                int id; int tid = GetWindowThreadProcessId(h, out id);
                if (tid == 0) { ownerFailed = true; ownerError = Marshal.GetLastWin32Error(); return false; }
                if (ids.Contains(id)) rows.Add(new DesktopWindowObservation { ProcessId = id, ThreadId = tid });
                return true;
            }, IntPtr.Zero);
            int error = ownerFailed ? ownerError : Marshal.GetLastWin32Error();
            if (complete && !ownerFailed) {
                for (int i = attemptStart; i < rows.Count; i++) rows[i].CompletedAttempt = true;
                return rows.ToArray();
            }
            if (error == 1400 && attempt < 2) continue; // A window disappeared during this enumeration.
            var failure = new System.ComponentModel.Win32Exception(error, ownerFailed ? "GetWindowThreadProcessId" : "EnumWindows");
            failure.Data["ObservedWindows"] = rows.ToArray();
            throw failure;
        }
        throw new Exception("Window enumeration attempts exhausted");
    }
    // Enumerate the named desktop directly; do not attach or infer membership from a launch string.
    public static DesktopWindowObservation[] PrivateJobWindows(IntPtr job, string desktopName) {
        var ids = new HashSet<int>(JobProcessIds(job));
        var rows = new List<DesktopWindowObservation>();
        var desktop = OpenDesktopW(desktopName, 0, false, 0x0001); // DESKTOP_READOBJECTS
        if (desktop == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "OpenDesktopW");
        Exception failure = null;
        System.ComponentModel.Win32Exception cleanupFailure = null;
        try {
            for (int attempt = 0; attempt < 3; attempt++) {
                int attemptStart = rows.Count;
                bool ownerFailed = false; int ownerError = 0;
                SetLastError(0);
                bool complete = EnumDesktopWindows(desktop, (h, p) => {
                    int id; int tid = GetWindowThreadProcessId(h, out id);
                    if (tid == 0) { ownerFailed = true; ownerError = Marshal.GetLastWin32Error(); return false; }
                    if (ids.Contains(id)) rows.Add(new DesktopWindowObservation { ProcessId = id, ThreadId = tid });
                    return true;
                }, IntPtr.Zero);
                int error = ownerFailed ? ownerError : Marshal.GetLastWin32Error();
                if (complete && !ownerFailed) {
                    for (int i = attemptStart; i < rows.Count; i++) rows[i].CompletedAttempt = true;
                    break;
                }
                if (error == 1400 && attempt < 2) continue;
                var queryFailure = new System.ComponentModel.Win32Exception(error, ownerFailed ? "GetWindowThreadProcessId" : "EnumDesktopWindows");
                queryFailure.Data["ObservedWindows"] = rows.ToArray();
                throw queryFailure;
            }
        } catch (Exception error) { failure = error; }
        finally {
            if (!CloseDesktop(desktop)) cleanupFailure = new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CloseDesktop");
        }
        if (failure != null) {
            if (cleanupFailure != null) { failure.Data["CleanupApi"] = "CloseDesktop"; failure.Data["CleanupCode"] = cleanupFailure.NativeErrorCode; }
            throw failure;
        }
        if (cleanupFailure != null) throw cleanupFailure;
        return rows.ToArray();
    }
    public static bool ContainsBytes(byte[] hay, byte[] needle) {
        int last = hay.Length - needle.Length;
        for (int i = 0; i <= last; i++) {
            if (hay[i] != needle[0]) continue;
            int j = 1; while (j < needle.Length && hay[i + j] == needle[j]) j++;
            if (j == needle.Length) return true;
        }
        return false;
    }
}
'@
}

function Assert-HiddenRunner {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
        throw 'Hidden desktop launches require an ephemeral GitHub-hosted runner. Exact ConPTY host desktop placement must be observed there before permitting local launches.'
    }
}

# Window membership is observed with documented desktop enumeration APIs. This
# proves sampled UI placement, not desktop membership of windowless threads.
function Assert-HiddenDesktop([IntPtr] $Job, [string] $DesktopName, [string] $ReceiptPath, [int] $DriverPid = $PID, [int] $RequiredWindowPid = 0, [switch] $NoWindows) {
    try {
        if ($DesktopName -cnotmatch '^noctty-hw-[0-9a-f]{32}$') { throw 'Invalid desktop name' }
        $ids = @([HiddenWin]::JobProcessIds($Job))
        $rows = @([HiddenWin]::PrivateJobWindows($Job, $DesktopName))
        foreach ($row in $rows) {
            if ($row.ProcessId -le 0 -or $row.ThreadId -le 0 -or $ids -notcontains $row.ProcessId) { throw 'Invalid window owner' }
        }
        if ($DriverPid -eq $PID -and [HiddenWin]::CurrentDesktopName() -cne $DesktopName) { throw 'Wrong driver desktop' }
    } catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        $nativeStages = @('OpenDesktopW', 'EnumDesktopWindows', 'GetWindowThreadProcessId', 'CloseDesktop', 'GetThreadDesktop', 'GetUserObjectInformationW')
        $fixedStages = @('Invalid desktop name', 'Invalid window owner', 'Wrong driver desktop', 'Job process query failed', 'Job process query incomplete', 'Current desktop connection failed', 'Current thread has no connected desktop')
        $errorStage = $null; $errorApi = $null; $errorCode = $null; $cleanupApi = $null; $cleanupCode = $null
        if ($failure -is [ComponentModel.Win32Exception] -and $nativeStages -ccontains $failure.Message) {
            $errorStage = $errorApi = $failure.Message
            $errorCode = $failure.NativeErrorCode
        } elseif ($fixedStages -ccontains $failure.Message) { $errorStage = $failure.Message }
        if ($failure.Data['CleanupApi'] -ceq 'CloseDesktop' -and $failure.Data['CleanupCode'] -is [int]) {
            $cleanupApi = 'CloseDesktop'; $cleanupCode = $failure.Data['CleanupCode']
        }
        $observedWindows = @()
        if ($errorApi) {
            foreach ($window in @($failure.Data['ObservedWindows'])) {
                if ($null -ne $window -and $window.ProcessId -is [int] -and $window.ThreadId -is [int] -and $window.ProcessId -gt 0 -and $window.ThreadId -gt 0) {
                    $observedWindows += @{ ProcessId = $window.ProcessId; ThreadId = $window.ThreadId }
                }
            }
        }
        @{ At = [datetime]::UtcNow.ToString('o'); ExpectedDesktop = $DesktopName; Error = 'Private desktop window query failed'
            ErrorStage = $errorStage; ErrorApi = $errorApi; ErrorCode = $errorCode; CleanupErrorApi = $cleanupApi; CleanupErrorCode = $cleanupCode; Windows = $observedWindows } |
            ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $ReceiptPath
        throw 'Hidden desktop private-window query failed; further launches are blocked.'
    }
    @{ At = [datetime]::UtcNow.ToString('o'); ExpectedDesktop = $DesktopName; Oracle = 'EnumDesktopWindows'; Windows = $rows; RequiredWindowPid = $RequiredWindowPid } |
        ConvertTo-Json -Depth 5 -Compress | Add-Content -LiteralPath $ReceiptPath
    if ($RequiredWindowPid -gt 0 -and ($ids -notcontains $RequiredWindowPid -or @($rows | Where-Object { $_.ProcessId -eq $RequiredWindowPid -and $_.CompletedAttempt -eq $true }).Count -eq 0)) {
        throw 'Window startup required process window is absent; further input is blocked.'
    }
    if ($NoWindows -and $rows.Count) { throw 'Hidden desktop unexpected private job window; further launches are blocked.' }
}

# The child cannot launch noctty until the Default observer validates this receipt.
function Wait-HiddenDriverApproval([string] $Run, [string] $DesktopName) {
    if ($DesktopName -cnotmatch '^noctty-hw-[0-9a-f]{32}$' -or [HiddenWin]::CurrentDesktopName() -cne $DesktopName) { throw 'Hidden desktop driver self-check failed.' }
    @{ ProcessId = $PID; Desktop = $DesktopName; WindowStation = [HiddenWin]::CurrentWindowStationName(); SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'driver-desktop.json')
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath (Join-Path $Run 'driver-desktop-approved'))) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'Hidden desktop driver approval timed out.' }
        Start-Sleep -Milliseconds 50
    }
}

function Close-HiddenDriverSentinel([IntPtr] $Sentinel, [string] $Run, [switch] $WaitForParent, $PrimaryFailure = $null, [IntPtr] $OwnedJob = [IntPtr]::Zero) {
    $failure = $null; $destroyed = $false; $jobCleaned = $OwnedJob -eq [IntPtr]::Zero
    if ($OwnedJob -ne [IntPtr]::Zero) {
        try { $null = [HiddenWin]::StopOwnedJob($OwnedJob); $jobCleaned = $true } catch { $failure = $_ }
    }
    if ($WaitForParent -and $jobCleaned) {
        try {
            Set-Content -LiteralPath (Join-Path $Run 'driver-desktop-release-requested') -Value ''
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            while (-not (Test-Path -LiteralPath (Join-Path $Run 'driver-desktop-released'))) {
                if ([datetime]::UtcNow -ge $deadline) { throw 'Driver sentinel release timed out' }
                Start-Sleep -Milliseconds 50
            }
        } catch { $failure = $_ }
    }
    try { [HiddenWin]::DestroyDriverSentinel($Sentinel); $destroyed = $true } catch { if ($null -eq $failure) { $failure = $_ } }
    try {
        @{ Destroyed = $destroyed; OwnedJobCleanedUp = $jobCleaned; ReleaseRequired = [bool]$WaitForParent; CleanupFailed = $null -ne $failure; PrimaryFailurePreserved = $null -ne $PrimaryFailure } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'driver-sentinel-cleanup.json')
    } catch { if ($null -eq $failure) { $failure = $_ } }
    if ($failure -and $null -eq $PrimaryFailure) { throw $failure }
}

function Approve-HiddenDriver([IntPtr] $Job, [string] $Run, [string] $DesktopName, [int] $DriverPid) {
    $path = Join-Path $Run 'driver-desktop.json'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if ($receipt.ProcessId -ne $DriverPid -or @([HiddenWin]::JobProcessIds($Job)) -notcontains $DriverPid -or
        $receipt.Desktop -cne $DesktopName -or $receipt.WindowStation -cne [HiddenWin]::CurrentWindowStationName() -or
        $receipt.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId) { throw 'Hidden desktop driver receipt mismatch; further launches are blocked.' }
    Assert-HiddenDesktop -Job $Job -DesktopName $DesktopName -DriverPid $DriverPid -RequiredWindowPid $DriverPid -ReceiptPath (Join-Path $Run 'driver-sentinel-windows.jsonl')
    Set-Content -LiteralPath (Join-Path $Run 'driver-desktop-approved') -Value ''
    return $true
}

# Called every outer wait tick, independently of the slower thread metadata receipt.
# A failure escapes the wait loop and immediately closes the entire owned driver job.
function Assert-HiddenDefaultDesktop([IntPtr] $Job, [string] $ReceiptPath) {
    try { $windows = @([HiddenWin]::DefaultJobWindows($Job)) }
    catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        $errorApi = $null; $errorCode = $null; $observedWindows = @()
        if ($failure -is [ComponentModel.Win32Exception] -and @('EnumWindows', 'GetWindowThreadProcessId') -ccontains $failure.Message) {
            $errorApi = $failure.Message; $errorCode = $failure.NativeErrorCode
            foreach ($window in @($failure.Data['ObservedWindows'])) {
                if ($null -ne $window -and $window.ProcessId -is [int] -and $window.ThreadId -is [int] -and $window.ProcessId -gt 0 -and $window.ThreadId -gt 0) {
                    $observedWindows += @{ ProcessId = $window.ProcessId; ThreadId = $window.ThreadId }
                }
            }
        }
        @{ At = [datetime]::UtcNow.ToString('o'); Desktop = 'Default'; Error = 'Default desktop window query failed'
            ErrorApi = $errorApi; ErrorCode = $errorCode; Windows = $observedWindows } |
            ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $ReceiptPath
        throw 'Hidden desktop default-window query failed; further launches are blocked.'
    }
    if ($windows.Count) {
        @{ At = [datetime]::UtcNow.ToString('o'); Desktop = 'Default'; Windows = $windows } |
            ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $ReceiptPath
        throw 'Hidden desktop job window found on Default; further launches are blocked.'
    }
}

function Get-FileFingerprint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false } }
    $item = Get-Item -LiteralPath $Path
    return @{ Exists = $true; Length = $item.Length; Modified = $item.LastWriteTimeUtc.ToString('o'); Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Test-SameFingerprint($A, $B) {
    return $A.Exists -eq $B.Exists -and $A.Hash -eq $B.Hash -and $A.Modified -eq $B.Modified
}

# The state a run must not touch on the machine it runs on: the real recovery ledger and the
# real PowerShell history file (a pwsh in a test pane loads PSReadLine). Metadata and a hash
# only; their contents are never read into the output.
function Get-RealStateFingerprints {
    $history = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    return @{
        Startup = Get-FileFingerprint (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json')
        History = Get-FileFingerprint $history
    }
}

# A copy of the product AUMID would replace the real jump list for every launch; the measurement
# build carries ".measure" after it (apply_aumid_isolate.py, never committed).
function Assert-MeasureAumid([string] $Exe, [switch] $AllowProductAumid) {
    if ($AllowProductAumid) { return }
    $needle = [Text.Encoding]::Unicode.GetBytes('io.github.amanthanvi.noctty.measure')
    if (-not [HiddenWin]::ContainsBytes([IO.File]::ReadAllBytes($Exe), $needle)) {
        throw 'noctty.exe does not carry the measurement AppUserModelID (io.github.amanthanvi.noctty.measure). A launch would replace the real taskbar jump list. Build with scripts that apply the measurement patch, or pass -AllowProductAumid on an ephemeral machine.'
    }
}

# The measurement AUMID does not isolate Server.register's real COM CLSID. An idle server
# could receive the user's live console handoff while noctty is their delegated terminal.
# Read only that one selection and fail closed on an unreadable key; there is no bypass.
function Assert-EmbeddingDelegationSafe {
    try { $selection = Get-ItemProperty -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return }
    $terminal = [guid]::Empty
    if ([guid]::TryParse([string]$selection.DelegationTerminal, [ref]$terminal) -and
        $terminal -eq [guid]'33368C6F-D328-410C-B225-26DC9F12C728') {
        throw 'Embedding launch blocked: noctty is the selected delegated terminal. The measurement AUMID does not isolate the real COM handoff CLSID; use a sandbox with independent console delegation.'
    }
}

function Copy-PortableBin([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}

# Runs `-Script` again as a driver on a desktop created here, in an owned kill-on-close job, with
# LOCALAPPDATA and APPDATA redirected into `-Run`, then checks that nothing real changed.
function Invoke-HiddenDriver {
    param(
        [Parameter(Mandatory)] [string] $Script, [Parameter(Mandatory)] [string] $Bin, [Parameter(Mandatory)] [string] $Run,
        [Parameter(Mandatory)] [int] $TimeoutSeconds, [string[]] $ExtraArguments = @(), [Parameter(Mandatory)] [string] $Label
    )
    Assert-HiddenRunner
    if ([HiddenWin]::CurrentDesktopName() -cne 'Default') { throw 'Outer hidden harness must observe the Default desktop.' }
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Bin must contain noctty.exe.' }
    $before = Get-RealStateFingerprints
    $clipboardBefore = [HiddenWin]::GetClipboardSequenceNumber()
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-PortableBin $Bin (Join-Path $Run 'source\bin')
    $artifacts = foreach ($name in @('noctty.exe', 'conpty.dll', 'OpenConsole.exe')) {
        @{ Name = $name; Fingerprint = Get-FileFingerprint (Join-Path $Run "source\bin\$name") }
    }
    @{ OSVersion = [Environment]::OSVersion.Version.ToString(); Artifacts = @($artifacts) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'runtime-artifacts.json')
    foreach ($name in @('localappdata', 'appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-hw-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenWin]::CreateInheritedDesktop($desktopName)
    $oldLocal = $env:LOCALAPPDATA; $oldRoaming = $env:APPDATA
    $pi = $null; $job = [IntPtr]::Zero; $code = 1
    try {
        $job = [HiddenWin]::CreateOwnedJob()
        $env:LOCALAPPDATA = Join-Path $Run 'localappdata'; $env:APPDATA = Join-Path $Run 'appdata'
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver' -f $pwsh, $Script, (Join-Path $Run 'source\bin'), $Run
        foreach ($argument in $ExtraArguments) { $line += ' ' + $argument }
        # CREATE_NO_WINDOW (0x08000000) is part of Launch's flags.
        $pi = [HiddenWin]::Launch($pwsh, $line, $Run, "WinSta0\$desktopName", $job, '')
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $approved = $false; $released = $false
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([HiddenWin]::WaitForSingleObject($pi.process, 100) -eq 258) {
            Assert-HiddenDefaultDesktop -Job $job -ReceiptPath (Join-Path $Run 'default-desktop-windows.jsonl')
            if (-not $approved) { $approved = Approve-HiddenDriver -Job $job -Run $Run -DesktopName $desktopName -DriverPid $pi.pid }
            if ($approved -and -not $released) {
                Assert-HiddenDesktop -Job $job -DesktopName $desktopName -DriverPid $pi.pid -RequiredWindowPid $pi.pid -ReceiptPath (Join-Path $Run 'driver-desktops.jsonl')
                if (Test-Path -LiteralPath (Join-Path $Run 'driver-desktop-release-requested')) {
                    $released = $true
                    Set-Content -LiteralPath (Join-Path $Run 'driver-desktop-released') -Value ''
                }
            }
            if ([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $TimeoutSeconds seconds; the owned process job will be closed." }
        }
        Assert-HiddenDefaultDesktop -Job $job -ReceiptPath (Join-Path $Run 'default-desktop-windows.jsonl')
        [uint32]$exit = 0
        if (-not [HiddenWin]::GetExitCodeProcess($pi.process, [ref]$exit)) { throw 'Hidden driver exit code query failed.' }
        if ($exit -eq 0 -and -not $approved) { throw 'Hidden desktop driver exited without verified self-receipt.' }
        $code = [int]$exit
    } finally {
        $env:LOCALAPPDATA = $oldLocal; $env:APPDATA = $oldRoaming
        $cleanupError = $null; $ownedProcessCount = 0
        if ($job -ne [IntPtr]::Zero) { try { $ownedProcessCount = [HiddenWin]::StopOwnedJob($job) } catch { $cleanupError = $_ } }
        if ($pi) { [void][HiddenWin]::CloseHandle($pi.thread); [void][HiddenWin]::CloseHandle($pi.process) }
        [void][HiddenWin]::CloseDesktop($desktop)
        $after = Get-RealStateFingerprints
        $clipboardAfter = [HiddenWin]::GetClipboardSequenceNumber()
        $startupUnchanged = Test-SameFingerprint $before.Startup $after.Startup
        $historyUnchanged = Test-SameFingerprint $before.History $after.History
        @{ Before = $before; After = $after; StartupUnchanged = $startupUnchanged; HistoryUnchanged = $historyUnchanged; OwnedJobCleanedUp = ($null -eq $cleanupError); OwnedProcessCount = $ownedProcessCount; ClipboardSequenceBefore = $clipboardBefore; ClipboardSequenceAfter = $clipboardAfter } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Run 'real-state.json')
        if (-not $startupUnchanged) { throw 'Real startup-attempts.json changed; stop launches and report it.' }
        if (-not $historyUnchanged) { throw 'The real PowerShell history file changed; stop launches and report it.' }
        if ($clipboardBefore -ne $clipboardAfter) { throw "Clipboard sequence number changed ($clipboardBefore -> $clipboardAfter); stop launches and report it." }
        if ($cleanupError) { throw $cleanupError }
    }
    # The driver has no console of its own: print what it recorded.
    foreach ($results in @(Get-ChildItem -LiteralPath $Run -Filter '*-results.json' -File)) {
        $document = Get-Content -LiteralPath $results.FullName -Raw | ConvertFrom-Json
        $total = @($document.Checks).Count
        foreach ($check in @($document.Checks | Where-Object { -not $_.Passed })) {
            Write-Host ("FAIL {0}{1}: expected {2}, got {3}" -f $(if ($check.Case) { "[$($check.Case)] " } else { '' }), $check.Name, $check.Expected, $check.Actual)
        }
        foreach ($case in @($document.Cases | Where-Object { $_.Result -eq 'skipped' })) { Write-Host ("SKIP [{0}] {1}" -f $case.Profile, $case.Reason) }
        Write-Host ("{0}: {1} checks" -f $results.Name, $total)
    }
    if ($code -ne 0) { throw "Hidden driver failed with exit $code; inspect the results in $Run." }
    Write-Host "${Label}: PASS"
}

# Starts a portable noctty on the driver's desktop. The returned object owns the process.
function Start-HiddenNoctty {
    param([Parameter(Mandatory)] [string] $Dir, [Parameter(Mandatory)] [string[]] $Arguments, [Parameter(Mandatory)] [string] $DesktopName, [Parameter(Mandatory)] [IntPtr] $Job, [string] $StderrPath)
    Assert-HiddenRunner
    Assert-HiddenDesktop -Job $Job -DesktopName $DesktopName -ReceiptPath (Join-Path $Dir 'launch-desktops.jsonl')
    $exe = Join-Path $Dir 'noctty.exe'
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'noctty.portable'))) { throw 'Portable marker missing; launch blocked.' }
    $line = '"{0}" {1}' -f $exe, ($Arguments -join ' ')
    $pi = [HiddenWin]::Launch($exe, $line, $Dir, "WinSta0\$DesktopName", $Job, $StderrPath)
    $process = [Diagnostics.Process]::GetProcessById($pi.pid)
    [void][HiddenWin]::CloseHandle($pi.thread)
    return @{ Process = $process; Pid = $pi.pid; Handle = $pi.process; StartTime = $process.StartTime }
}

function Get-HiddenExitCode($Started) {
    [uint32]$code = 0
    if (-not [HiddenWin]::GetExitCodeProcess($Started.Handle, [ref]$code)) { return $null }
    return [int]$code
}

# A key as TranslateMessage would deliver it: the surface drops a WM_CHAR that no WM_KEYDOWN announced.
function Send-Key([IntPtr] $Hwnd, [int] $Vk, [int] $Char) {
    $scan = [HiddenWin]::MapVirtualKeyW([uint32]$Vk, 0)
    $down = [int64](1 -bor ([int64]$scan -shl 16)); $up = $down -bor 0xC0000000L
    $ok = [HiddenWin]::Send($Hwnd, 0x0100, $Vk, $down)
    if ($Char -ne 0) { $ok = [HiddenWin]::Send($Hwnd, 0x0102, $Char, $down) -and $ok }
    $ok = [HiddenWin]::Send($Hwnd, 0x0101, $Vk, $up) -and $ok
    if (-not $ok) { throw ('SendMessageTimeout to 0x{0:X} failed or timed out' -f $Hwnd.ToInt64()) }
}

# Letters, digits and space go as their own keys; everything else as VK_PACKET.
function Send-Text([IntPtr] $Hwnd, [string] $Text) {
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 13) { Send-Key $Hwnd 0x0D 13 }
        elseif (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x61 -and $code -le 0x7A) -or $code -eq 0x20) {
            Send-Key $Hwnd ([int][char]::ToUpperInvariant($ch)) $code
        }
        else { Send-Key $Hwnd 0xE7 $code }
        Start-Sleep -Milliseconds 15
    }
}

# Every descendant of `RootPid` with its name and command line. Callers reduce the command line to a
# redacted shape before anything is written down.
function Get-Descendants([int] $RootPid) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
    $found = [Collections.Generic.List[object]]::new(); $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue($RootPid)
    while ($queue.Count) {
        $parent = $queue.Dequeue()
        foreach ($child in $all | Where-Object { $_.ParentProcessId -eq $parent }) { $found.Add($child); $queue.Enqueue([int]$child.ProcessId) }
    }
    return $found.ToArray()
}

# A command line reduced to what a check needs: the run directory and the user profile become
# placeholders, and only the first arguments, each cut short, are kept.
function Get-RedactedCommandLine([string] $CommandLine, [string[]] $Roots, [int] $MaxArguments = 13, [int] $MaxArgumentLength = 80) {
    if (-not $CommandLine) { return '' }
    $text = $CommandLine
    foreach ($root in $Roots) { if ($root) { $text = $text.Replace($root, '<run>') } }
    $text = $text.Replace($env:USERPROFILE, '<user>')
    $parts = [regex]::Matches($text, '"[^"]*"|\S+') | ForEach-Object { $_.Value } | Select-Object -First $MaxArguments
    return ($parts | ForEach-Object { if ($_.Length -gt $MaxArgumentLength) { $_.Substring(0, $MaxArgumentLength) + '...' } else { $_ } }) -join ' '
}
