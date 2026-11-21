#requires -Version 7.0
<#
.SYNOPSIS
The hidden-desktop GUI suite's runner (interactive offload PR 1; design §4). It runs each leaf in
test/windows/gui-hidden-plan.json on a private desktop of its own, against a fresh portable copy of the receipt-bound
measurement build, and fails a leaf that fails, that loaded the real-input module, whose shells ran without /D, whose
job gained a noctty process the launcher did not start, that left a reparse point, or that put a window on Default.

.DESCRIPTION
  pwsh -NoProfile -File test/windows/gui-hidden-runner.ps1 -MeasureRepo <repo> -Work <new directory> -Out <directory>
       [-Build] [-Leaves <id>,...] [-KeepFailedCopies]

The build (design §4.2). Every leaf starts only a fresh portable copy of the measurement build that
Invoke-InteractiveWin11MeasureBuild (scripts/interactive-win11-measure-lib.ps1) made for -MeasureRepo's HEAD, with
NOCTTY_INTERACTIVE_MEASURE_AUMID=1: its own AUMID keeps the product's jump list and registration out of reach, and
a portable copy without noctty.ico never gets a jump list nor writes the AUMID registration (test-harnesses.md
STANDALONE-LEAF-AUMID-01; app-lifecycle.md 2026-10-16 "A portable copy"). -Build builds that generation first and is
refused off a GitHub-hosted runner: locally the generation is prepared beforehand, outside any run and redirect, and
never by a plain `zig build` (the product-AUMID zig-out build). The raw generation is validated once, under its lock,
before staging and again at the end (Assert-InteractiveWin11MeasureBuild). Each copy is staged from it (everything in
the prefix's bin but noctty.ico, crash, ghostty and the PDBs, plus share), and its app and CLI are hashed separately
against the receipt's ExeSHA256 and CliSHA256. Each launch is then checked cheaply in the leaf (file identity, marker,
icon, measurement mode, desktop; scripts/interactive-win11-lib.ps1, Start-InteractiveWin11HostedProcess), and both
files are re-hashed when the leaf ends. A passing leaf's copy is deleted at once; a failing one's at the end unless
-KeepFailedCopies.

The launch (design §4.1). Each leaf is its own `pwsh -NoProfile -NonInteractive -File <leaf>`, started suspended on
a private desktop created for it (`WinSta0\noctty-gh-<32 hex>`, named in lpDesktop), inside a job that permits no
breakaway (PROBE-JOB-BREAKAWAY-01) and kills on close and on an unhandled exception (SOAK-01), with
NOCTTY_GUI_HIDDEN_DESKTOP, NOCTTY_GUI_HIDDEN_EXE and NOCTTY_GUI_HIDDEN_RUN set: the leaf's libraries refuse any other
desktop and never bootstrap or build. The copy's config sets the shell (`command = direct:<System32>\cmd.exe /D`),
the clipboard denied, no copy on select, no update check, no desktop notification and `window-save-state = never`.

What the runner observes (design §4.1 "Every process is accounted for"). A completion port on the job reports every
process it gains; each is opened at once and read only when no message waits (PROBE-JOB-WATCH-OPEN-FIRST-01). Every
cmd.exe's command line is read by its handle and tested, never kept: it must be System32's cmd.exe with /D among the
switches before /C or /K. A leaf passes only with every joiner read (the job's TotalProcesses against the processes
read), every cmd read and passing, at least the plan's expectedShells of them, and every noctty.exe or noctty.com
started by the launcher (its PID and creation time recorded before it ran), forwarded by a noctty the launcher
started, or started from a shell inside the terminal (shell-command's PATH lookup, a deliberate descendant). The
k-th cmd read creates `shell-read-<k>.flag` in the leaf's run directory, the barrier a one-shot `/c` stimulus waits
on. While the leaf runs, no window of its job may sit on Default. Afterwards the leaf's receipt must say the
real-input module never loaded, and no reparse point may sit under its sandbox, copy or run directory (the measured
AutoRun symptom, conpty.md REPLY-PATH-01 item (6)).

The state guards, around the whole run: scripts/interactive-win11-state-guard.ps1 (the product jump list,
startup-attempts.json, the clipboard sequence) and the PSReadLine history guard. A tripped guard exits 3. Keep the
session unlocked during a local run: OpenInputDesktop fails on a locked workstation, and the leaf refuses to start.

-Out receives only result.json (the flagship result schema, scenario windows.gui-hidden.suite) and receipts/, one
JSON object per leaf of allowlisted values: booleans, numbers and short strings without a path separator, quote or
bracket (Write-GuiHiddenRecord, from gui-hosted-probe.ps1's record writer, #738). No path, command line, window title
or environment value enters either. Everything else (logs, the guard's receipts, copies) stays under -Work.
Exit codes: 0 pass, 1 a leaf failed, 2 a staging or validation failure, 3 a tripped state guard.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [string] $Work,
    [string] $Out,
    [switch] $Build,
    [string[]] $Leaves = @(),
    [switch] $KeepFailedCopies
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1')

if ([IntPtr]::Size -ne 8) { throw 'The runner reads x64 process structures; run it in 64-bit PowerShell.' }

if (-not ('GuiHiddenRunnerNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class GuiHiddenRunnerNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x, y, cx, cy, charsX, charsY, fill, flags; public short show, reservedBytes;
        public IntPtr reservedPointer, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup info; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
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
    [StructLayout(LayoutKind.Sequential)] struct JobPort { public IntPtr key, port; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessBasic { public IntPtr exitStatus, peb, affinity, basePriority, pid, parentPid; }
    public delegate bool EnumWindow(IntPtr window, IntPtr parameter);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref StartupEx startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobPort port, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr buffer, int size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool member);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr existing, UIntPtr key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out UIntPtr key, out IntPtr overlapped, uint milliseconds);
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long time);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int type, out ProcessBasic info, int size, out int returned);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int type, IntPtr buffer, int size, out int returned);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError = true)] static extern bool EnumDesktopWindows(IntPtr desktop, EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out int pid);

    // The run's job: kill on close (0x2000) and on an unhandled exception (0x400, SOAK-01), and no breakaway flag, so
    // no descendant can leave it (PROBE-JOB-BREAKAWAY-01) and its own list and accounting are the record.
    public static IntPtr CreateRunJob() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Exception("CreateJobObject failed: " + Marshal.GetLastWin32Error());
        var limits = new JobLimits(); limits.basic.flags = 0x2000 | 0x400;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JobLimits)))) {
            int error = Marshal.GetLastWin32Error(); CloseHandle(job);
            throw new Exception("SetInformationJobObject failed: " + error);
        }
        return job;
    }

    // Ends every process of the job and waits (at most 10 s) until none is active. Returns the job's TotalProcesses.
    public static int StopRunJob(IntPtr job) {
        TerminateJobObject(job, 1);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        int[] accounting;
        do {
            accounting = JobAccounting(job);
            if (accounting != null && accounting[1] == 0) return accounting[0];
            Thread.Sleep(20);
        } while (DateTime.UtcNow < deadline);
        throw new Exception("The leaf's job still had active processes ten seconds after it was ended.");
    }

    // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION (48 bytes): TotalProcesses at 36, ActiveProcesses at 40. Null on failure.
    public static int[] JobAccounting(IntPtr job) {
        IntPtr buffer = Marshal.AllocHGlobal(48);
        try {
            if (!QueryInformationJobObject(job, 1, buffer, 48, IntPtr.Zero)) return null;
            return new int[] { Marshal.ReadInt32(buffer, 36), Marshal.ReadInt32(buffer, 40) };
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    // JOBOBJECT_BASIC_PROCESS_ID_LIST: two ULONGs, then ULONG_PTR ids. Null on failure.
    public static int[] JobPids(IntPtr job) {
        int size = 8 + 8 * 1024;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            if (!QueryInformationJobObject(job, 3, buffer, size, IntPtr.Zero)) return null;
            int count = Marshal.ReadInt32(buffer, 4);
            var pids = new int[count];
            for (int i = 0; i < count; i++) pids[i] = (int)Marshal.ReadInt64(buffer, 8 + 8 * i);
            return pids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    // Starts `command` suspended on `desktop` (named), assigns it to `job` before it runs, then resumes it. Its standard
    // output and error go to `logPath`, the only handle it inherits (PROC_THREAD_ATTRIBUTE_HANDLE_LIST). CREATE_NO_WINDOW.
    public static ProcessInfo Launch(string app, string command, string cwd, string desktop, IntPtr job, string logPath) {
        IntPtr log = IntPtr.Zero, list = IntPtr.Zero, handles = IntPtr.Zero;
        try {
            var sa = new SecurityAttributes { length = Marshal.SizeOf(typeof(SecurityAttributes)), inherit = 1 };
            log = CreateFileW(logPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
            if (log == new IntPtr(-1)) { log = IntPtr.Zero; throw new Exception("Creating the leaf log failed: " + Marshal.GetLastWin32Error()); }
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            list = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) { Marshal.FreeHGlobal(list); list = IntPtr.Zero; throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error()); }
            handles = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(handles, log);
            if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x20002), handles, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
            var si = new StartupEx();
            si.info.cb = Marshal.SizeOf(typeof(StartupEx));
            si.info.desktop = desktop;
            si.info.flags = 0x100; // STARTF_USESTDHANDLES
            si.info.output = log; si.info.error = log;
            si.attributes = list;
            uint flags = 0x20 | 0x4 | 0x08000000 | 0x00080000; // NORMAL_PRIORITY | SUSPENDED | NO_WINDOW | EXTENDED_STARTUPINFO
            ProcessInfo pi;
            if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, cwd, ref si, out pi))
                throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
            if (!AssignProcessToJobObject(job, pi.process) || ResumeThread(pi.thread) == 0xFFFFFFFF) {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(pi.process, 1); CloseHandle(pi.thread); CloseHandle(pi.process);
                throw new Exception("Assigning or resuming the leaf failed: " + error);
            }
            return pi;
        } finally {
            if (list != IntPtr.Zero) { DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (log != IntPtr.Zero) CloseHandle(log);
        }
    }

    public static uint ExitCode(IntPtr process) { uint code; return GetExitCodeProcess(process, out code) ? code : 0xFFFFFFFF; }

    // Whether `commandLine` starts System32's cmd.exe with /D among its switches before /C or /K (cmd reads switches
    // without regard to case). The text is tested here and never kept. A command line holding a control character is
    // not read (0); else 1, with the two facts set.
    public static int CmdVerdict(string commandLine, string systemCmd, out bool system, out bool autoRunOff) {
        system = false; autoRunOff = false;
        if (string.IsNullOrEmpty(commandLine)) return 0;
        foreach (char c in commandLine) if (c < 0x20 || c == 0x7F) return 0;
        string text = commandLine.TrimStart();
        string exe, rest;
        if (text.StartsWith("\"")) {
            int end = text.IndexOf('"', 1);
            if (end < 0) return 0;
            exe = text.Substring(1, end - 1); rest = text.Substring(end + 1);
        } else {
            int space = text.IndexOf(' ');
            exe = space < 0 ? text : text.Substring(0, space); rest = space < 0 ? "" : text.Substring(space);
        }
        try { system = Path.IsPathRooted(exe) && string.Equals(Path.GetFullPath(exe), systemCmd, StringComparison.OrdinalIgnoreCase); }
        catch (Exception) { system = false; }
        foreach (string token in rest.Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)) {
            if (!token.StartsWith("/")) break;
            if (token.Length >= 2 && (token[1] == 'C' || token[1] == 'c' || token[1] == 'K' || token[1] == 'k')) break;
            if (string.Equals(token, "/D", StringComparison.OrdinalIgnoreCase)) autoRunOff = true;
        }
        return 1;
    }

    static string CommandLineOf(IntPtr process) {
        int length;
        NtQueryInformationProcess(process, 60, IntPtr.Zero, 0, out length); // ProcessCommandLineInformation
        if (length <= 16 || length > (1 << 20)) return null;
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try {
            if (NtQueryInformationProcess(process, 60, buffer, length, out length) != 0) return null;
            int bytes = (ushort)Marshal.ReadInt16(buffer);
            IntPtr text = Marshal.ReadIntPtr(buffer, 8); // UNICODE_STRING x64: Length, MaximumLength, padding, Buffer
            return bytes == 0 || text == IntPtr.Zero ? null : Marshal.PtrToStringUni(text, bytes / 2);
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    static string ImageLeafOf(IntPtr process) {
        var name = new StringBuilder(32768); uint size = (uint)name.Capacity;
        return QueryFullProcessImageNameW(process, 0, name, ref size) ? Path.GetFileName(name.ToString()) : null;
    }

    public sealed class JoinedProcess {
        public int Pid; public long Taken; public IntPtr Handle; public bool OpenFailed; public bool Unpinned;
        public long Creation; public int Parent; public string Image;
        public bool IsCmd; public bool CmdRead; public bool CmdSystem; public bool CmdAutoRunOff; public int CmdOrdinal;
    }

    // The job's completion-port reader (gui-hosted-probe.ps1's JobWatch, #738, PROBE-JOB-WATCH-OPEN-FIRST-01): every
    // waiting message's process is opened first and its handle held; one opened process is read only when no message
    // waits; the reader runs above normal priority, and a fault ends the reading, never the process.
    public sealed class JobWatch : IDisposable {
        readonly IntPtr port; readonly IntPtr job; readonly Thread reader; readonly string systemCmd; readonly string flagDirectory;
        volatile bool stopping; int cmdCount; int taken;
        public volatile bool Faulted;
        // How many joiners the reader has taken from the port (each gets a row, opened or not).
        public int Taken { get { return Volatile.Read(ref taken); } }
        public bool Stopped;
        readonly List<JoinedProcess> joined = new List<JoinedProcess>();
        readonly List<JoinedProcess> opened = new List<JoinedProcess>();
        public JobWatch(IntPtr job, string systemCmd, string flagDirectory) {
            this.job = job; this.systemCmd = systemCmd; this.flagDirectory = flagDirectory;
            port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
            if (port == IntPtr.Zero) throw new Exception("CreateIoCompletionPort failed: " + Marshal.GetLastWin32Error());
            var info = new JobPort { key = job, port = port };
            if (!SetInformationJobObject(job, 7, ref info, (uint)Marshal.SizeOf(typeof(JobPort)))) {
                int error = Marshal.GetLastWin32Error(); CloseHandle(port);
                throw new Exception("Associating the job's completion port failed: " + error);
            }
            reader = new Thread(Loop); reader.IsBackground = true; reader.Priority = ThreadPriority.Highest; reader.Start();
        }
        void Loop() { try { Run(); } catch (Exception) { Faulted = true; } }
        void Run() {
            while (!stopping || opened.Count > 0) {
                uint message; UIntPtr key; IntPtr overlapped;
                if (!stopping && GetQueuedCompletionStatus(port, out message, out key, out overlapped, opened.Count > 0 ? 0u : 50u)) {
                    if (message != 6) continue; // JOB_OBJECT_MSG_NEW_PROCESS: overlapped carries the PID
                    long at; GetSystemTimePreciseAsFileTime(out at);
                    var row = new JoinedProcess { Pid = (int)overlapped.ToInt64(), Taken = at };
                    Interlocked.Increment(ref taken);
                    row.Handle = OpenProcess(0x1000 | 0x0400 | 0x0010 | 0x00100000, false, row.Pid); // QUERY_LIMITED | QUERY | VM_READ | SYNCHRONIZE
                    if (row.Handle == IntPtr.Zero) row.OpenFailed = true;
                    opened.Add(row);
                    continue;
                }
                if (opened.Count == 0) continue;
                var next = opened[0];
                ReadOpened(next);
                opened.RemoveAt(0); lock (joined) joined.Add(next);
            }
        }
        void ReadOpened(JoinedProcess row) {
            IntPtr h = row.Handle;
            if (h == IntPtr.Zero) return;
            long c, e, k, u; bool member;
            bool timed = GetProcessTimes(h, out c, out e, out k, out u);
            if (!IsProcessInJob(h, job, out member) || !member || !timed || c > row.Taken) {
                row.Unpinned = true; CloseHandle(h); row.Handle = IntPtr.Zero; return;
            }
            row.Creation = c;
            ProcessBasic basic; int returned;
            if (NtQueryInformationProcess(h, 0, out basic, Marshal.SizeOf(typeof(ProcessBasic)), out returned) == 0) row.Parent = (int)basic.parentPid.ToInt64();
            row.Image = ImageLeafOf(h);
            if (row.Image != null && string.Equals(row.Image, "cmd.exe", StringComparison.OrdinalIgnoreCase)) {
                row.IsCmd = true;
                bool system, autoRunOff;
                string line = CommandLineOf(h);
                row.CmdRead = CmdVerdict(line, systemCmd, out system, out autoRunOff) == 1;
                line = null;
                row.CmdSystem = system; row.CmdAutoRunOff = autoRunOff;
                cmdCount++;
                row.CmdOrdinal = cmdCount;
                // The barrier a one-shot stimulus waits on: this cmd has been read.
                try { File.WriteAllText(Path.Combine(flagDirectory, "shell-read-" + cmdCount + ".flag"), ""); } catch (Exception) { }
            }
        }
        public JoinedProcess[] Snapshot() { lock (joined) return joined.ToArray(); }
        public void Dispose() {
            stopping = true; Stopped = reader.Join(5000);
            lock (joined) foreach (var r in joined) if (r.Handle != IntPtr.Zero) { CloseHandle(r.Handle); r.Handle = IntPtr.Zero; }
            if (Stopped) foreach (var r in opened) if (r.Handle != IntPtr.Zero) CloseHandle(r.Handle);
            CloseHandle(port);
        }
    }

    // The windows on Default whose thread belongs to one of `pids`: their count, or -1 when the walk failed with an
    // error (an empty walk is FALSE with error 0, DIRECT-UPDATE-720; PROBE-ENUM-ACCESS-01).
    public static int DefaultWindowsOf(int[] pids) {
        var set = new HashSet<int>(pids);
        IntPtr desktop = OpenDesktopW("Default", 0, false, 0x0001 | 0x0040); // DESKTOP_READOBJECTS | DESKTOP_ENUMERATE
        if (desktop == IntPtr.Zero) return -1;
        try {
            int count = 0;
            bool ok = EnumDesktopWindows(desktop, (w, p) => { int pid; GetWindowThreadProcessId(w, out pid); if (set.Contains(pid)) count++; return true; }, IntPtr.Zero);
            if (!ok && Marshal.GetLastWin32Error() != 0) return -1;
            return count;
        } finally { CloseDesktop(desktop); }
    }
}
'@
}

# ---- the record: values only (gui-hosted-probe.ps1's allowlist, #738)

# Booleans, numbers, null, short strings without a path separator, quote or bracket, and maps (keys plain names) and
# lists of them. A value outside it becomes `rejected-value`, its place listed, so no path or command line can enter.
function ConvertTo-GuiHiddenRecordValue($Value, [string] $Where, [System.Collections.Generic.List[string]] $Rejected) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool] -or $Value -is [decimal] -or
        ($Value.GetType().IsPrimitive -and $Value -isnot [char] -and $Value -isnot [IntPtr] -and $Value -isnot [UIntPtr])) { return $Value }
    if ($Value -is [string]) {
        if ($Value.Length -le 80 -and $Value -cmatch '\A[A-Za-z0-9 ._:+#=\-]*\z') { return $Value }
        $Rejected.Add($Where); return 'rejected-value'
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        $leftOut = 0
        # Entries, not $Value[$key]: an int key on an ordered map indexes by position (PS-ORDERED-INT-INDEX-01).
        foreach ($entry in @($Value.GetEnumerator())) {
            $key = $entry.Key
            if ($key -is [string] -and $key -cmatch '\A[A-Za-z][A-Za-z0-9]*\z') {
                $clean[$key] = ConvertTo-GuiHiddenRecordValue $entry.Value "$Where.$key" $Rejected
            } else { $leftOut++; $Rejected.Add("$Where.#key$leftOut") }
        }
        return $clean
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($item in $Value) { $items.Add((ConvertTo-GuiHiddenRecordValue $item "$Where.$index" $Rejected)); $index++ }
        return , $items.ToArray()
    }
    $Rejected.Add($Where); return 'rejected-value'
}

function Write-GuiHiddenRecord($Record, [string] $Path) {
    $rejected = [System.Collections.Generic.List[string]]::new()
    $clean = ConvertTo-GuiHiddenRecordValue $Record 'record' $rejected
    foreach ($reserved in @('rejectedValues', 'rejectedAt')) {
        if ($clean.Contains($reserved)) { $clean.Remove($reserved); $rejected.Add("record.#$reserved") }
    }
    if ($rejected.Count -gt 0) {
        $clean.rejectedValues = $rejected.Count
        $clean.rejectedAt = @($rejected | Select-Object -First 32 | ForEach-Object { if ($_.Length -gt 80) { $_.Substring(0, 80) } else { $_ } })
    }
    [IO.File]::WriteAllText($Path, ($clean | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return $rejected.Count
}

# ---- helpers

function Test-GuiHiddenHosted { return $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' }

function Get-GuiHiddenHash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-GuiHiddenPlan {
    $plan = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gui-hidden-plan.json') -Raw | ConvertFrom-Json
    if ($plan.schemaVersion -ne 1 -or $plan.scenario -cne 'windows.gui-hidden.suite') { throw 'gui-hidden-plan.json has an unknown schema.' }
    return $plan
}

# The policy's config, written at staging for a leaf that writes none of its own (the leaf's own writes go through
# Write-InteractiveWin11HostedConfig, which appends the same lines).
function Get-GuiHiddenBaseConfig {
    return @(Get-InteractiveWin11HostedPolicyConfig) + @('window-save-state = never')
}

# Stages `Bin` (the validated generation's prefix bin) into a fresh portable copy at `Copy`, the way the soak does:
# everything but noctty.ico, crash, ghostty and the PDBs, plus the prefix's share; the marker; the policy's config.
# Both executables are then hashed against the receipt. Throws on any difference.
function New-GuiHiddenCopy([string] $Bin, [string] $Copy, [string] $ExeSha256, [string] $CliSha256) {
    if (Test-Path -LiteralPath $Copy) { throw 'The copy directory must be new.' }
    [void](New-Item -ItemType Directory -Path $Copy)
    Get-ChildItem -LiteralPath $Bin -Force | Where-Object { $_.Name -notin @('noctty.ico', 'crash', 'ghostty') -and $_.Extension -ne '.pdb' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Copy $_.Name) -Recurse }
    $share = Join-Path (Split-Path -Parent $Bin) 'share'
    if (-not (Test-Path -LiteralPath $share -PathType Container)) { throw 'The generation has no share directory.' }
    Copy-Item -LiteralPath $share -Destination (Join-Path $Copy 'share') -Recurse
    if (Test-Path -LiteralPath (Join-Path $Copy 'noctty.ico')) { throw 'The copy must not carry noctty.ico.' }
    [IO.File]::WriteAllText((Join-Path $Copy 'noctty.portable'), '')
    [IO.File]::WriteAllLines((Join-Path $Copy 'config.ghostty'), [string[]](Get-GuiHiddenBaseConfig), [Text.UTF8Encoding]::new($false))
    if (-not [string]::Equals((Get-GuiHiddenHash (Join-Path $Copy 'noctty.exe')), $ExeSha256, [StringComparison]::Ordinal)) { throw 'The staged noctty.exe is not the receipt''s.' }
    if (-not [string]::Equals((Get-GuiHiddenHash (Join-Path $Copy 'noctty.com')), $CliSha256, [StringComparison]::Ordinal)) { throw 'The staged noctty.com is not the receipt''s.' }
}

# Every reparse point under `Roots`, counted without following any (.NET's enumeration does not recurse into one).
function Get-GuiHiddenReparsePointCount([string[]] $Roots) {
    $count = 0
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $options = [IO.EnumerationOptions]::new()
        $options.RecurseSubdirectories = $true
        $options.AttributesToSkip = [IO.FileAttributes]::None
        $options.IgnoreInaccessible = $false
        if (([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $count++; continue }
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($root, '*', $options)) {
            if (([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $count++ }
        }
    }
    return $count
}

# The launcher's record: `<pid> <creation>` per line, written by Start-InteractiveWin11HostedProcess before each start ran.
function Get-GuiHiddenLauncherRecords([string] $Path) {
    $records = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $records }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $parts = $line -split ' '
        if ($parts.Count -eq 2) { $records[[int]$parts[0]] = [long]$parts[1] }
    }
    return $records
}

# The leaf's verdict on its job's processes (design §4.1): every joiner read; every cmd read, System32's and with /D
# before its payload, at least `ExpectedShells` of them; every noctty.exe or noctty.com started by the launcher, or
# forwarded by a noctty it started, or started from a shell inside the terminal.
function Get-GuiHiddenProcessVerdict($Rows, [hashtable] $Launcher, [int] $TotalProcesses, [int] $ExpectedShells) {
    $byPid = @{}
    foreach ($row in $Rows) { if (-not $row.OpenFailed -and -not $row.Unpinned) { $byPid[$row.Pid] = $row } }
    $read = @($Rows | Where-Object { -not $_.OpenFailed -and -not $_.Unpinned }).Count
    $cmds = @($Rows | Where-Object { $_.IsCmd })
    $nocttyRows = @($Rows | Where-Object { $_.Image -and ($_.Image -ieq 'noctty.exe' -or $_.Image -ieq 'noctty.com') })
    $unaccounted = 0
    foreach ($row in $nocttyRows) {
        $recorded = $Launcher.ContainsKey($row.Pid) -and $Launcher[$row.Pid] -eq $row.Creation
        if ($recorded) { continue }
        $parent = $byPid[$row.Parent]
        $fromLauncherNoctty = $null -ne $parent -and $Launcher.ContainsKey($parent.Pid) -and $Launcher[$parent.Pid] -eq $parent.Creation -and
            ($parent.Image -ieq 'noctty.com' -or $parent.Image -ieq 'noctty.exe')
        $fromShell = $null -ne $parent -and ($parent.Image -ieq 'cmd.exe' -or $parent.Image -ieq 'powershell.exe' -or $parent.Image -ieq 'pwsh.exe') -and
            $parent.Pid -ne $script:LeafPid
        if (-not ($fromLauncherNoctty -or $fromShell)) { $unaccounted++ }
    }
    $cmdPassing = @($cmds | Where-Object { $_.CmdRead -and $_.CmdSystem -and $_.CmdAutoRunOff }).Count
    $verdict = [ordered]@{
        jobTotalProcesses = $TotalProcesses
        processesRead = $read
        unopened = @($Rows | Where-Object { $_.OpenFailed }).Count
        unpinned = @($Rows | Where-Object { $_.Unpinned }).Count
        shellsExpected = $ExpectedShells
        shellsObserved = $cmds.Count
        shellsPassing = $cmdPassing
        shellsUnread = @($cmds | Where-Object { -not $_.CmdRead }).Count
        shellsNotSystemCmd = @($cmds | Where-Object { $_.CmdRead -and -not $_.CmdSystem }).Count
        shellsWithoutAutoRunOff = @($cmds | Where-Object { $_.CmdRead -and -not $_.CmdAutoRunOff }).Count
        nocttyProcesses = $nocttyRows.Count
        nocttyUnaccounted = $unaccounted
    }
    $verdict.passed = $TotalProcesses -eq $Rows.Count -and $read -eq $Rows.Count -and $cmdPassing -eq $cmds.Count -and
        $cmds.Count -ge $ExpectedShells -and $unaccounted -eq 0
    return $verdict
}

# Runs one leaf on its own private desktop and returns its record (allowlisted values only).
function Invoke-GuiHiddenLeaf($Leaf, [string] $Bin, [string] $ExeSha256, [string] $CliSha256, [string] $RunRoot) {
    $id = [string]$Leaf.id
    $run = Join-Path $RunRoot $id
    [void](New-Item -ItemType Directory -Path $run)
    $copy = Join-Path $run 'copy'
    $record = [ordered]@{ leaf = $id; passed = $false; stage = 'staging' }
    $desktop = [IntPtr]::Zero; $job = [IntPtr]::Zero; $watch = $null; $pi = $null
    $saved = @{}
    try {
        New-GuiHiddenCopy -Bin $Bin -Copy $copy -ExeSha256 $ExeSha256 -CliSha256 $CliSha256
        [IO.File]::WriteAllText((Join-Path $run 'staged.json'), (@{ exeSha256 = $ExeSha256; cliSha256 = $CliSha256 } | ConvertTo-Json))
        foreach ($name in @('localappdata', 'appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $run $name)) }
        $record.stage = 'launch'
        $desktopName = 'noctty-gh-' + [guid]::NewGuid().ToString('N')
        $desktop = [GuiHiddenRunnerNative]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
        if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
        $job = [GuiHiddenRunnerNative]::CreateRunJob()
        $systemCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $watch = [GuiHiddenRunnerNative+JobWatch]::new($job, $systemCmd, $run)
        $leafEnvironment = [ordered]@{
            NOCTTY_GUI_HIDDEN_DESKTOP = "WinSta0\$desktopName"
            NOCTTY_GUI_HIDDEN_EXE = (Join-Path $copy 'noctty.exe')
            NOCTTY_GUI_HIDDEN_RUN = $run
            NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
            LOCALAPPDATA = (Join-Path $run 'localappdata')
            APPDATA = (Join-Path $run 'appdata')
        }
        foreach ($name in $leafEnvironment.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $leafEnvironment[$name]) }
        $pwsh = (Get-Command pwsh.exe).Source
        $script = Join-Path $repoRoot ([string]$Leaf.script)
        $arguments = @($Leaf.arguments | ForEach-Object { [string]$_ })
        foreach ($argument in $arguments) { if ($argument -match '[\s"]') { throw 'A plan argument cannot hold whitespace or a quote.' } }
        $line = ('"{0}" -NoProfile -NonInteractive -File "{1}"' -f $pwsh, $script) + $(if ($arguments.Count) { ' ' + ($arguments -join ' ') } else { '' })
        $started = [datetime]::UtcNow
        $pi = [GuiHiddenRunnerNative]::Launch($pwsh, $line, $repoRoot, "WinSta0\$desktopName", $job, (Join-Path $run 'leaf.log'))
        $script:LeafPid = $pi.pid
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        $saved = @{}
        $deadline = $started.AddSeconds([int]$Leaf.timeoutSeconds)
        $defaultWindows = 0; $defaultWalkFailed = $false; $timedOut = $false
        while ([GuiHiddenRunnerNative]::WaitForSingleObject($pi.process, 500) -eq 258) {
            $pids = [GuiHiddenRunnerNative]::JobPids($job)
            if ($null -ne $pids -and $pids.Count -gt 0) {
                $found = [GuiHiddenRunnerNative]::DefaultWindowsOf($pids)
                if ($found -lt 0) { $defaultWalkFailed = $true } elseif ($found -gt 0) { $defaultWindows += $found }
            }
            if ([datetime]::UtcNow -ge $deadline) { $timedOut = $true; break }
        }
        $record.stage = 'judge'
        $exitCode = $(if ($timedOut) { -1 } else { [int][GuiHiddenRunnerNative]::ExitCode($pi.process) })
        $record.seconds = [math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 1)
        $record.timedOut = $timedOut
        $record.exitCode = $exitCode
        $total = [GuiHiddenRunnerNative]::StopRunJob($job)
        # The reader takes every joiner the job reported before it stops (at most 5 s); the verdict gates on the job's
        # own TotalProcesses, so one it missed fails the leaf rather than passing unread.
        $drainDeadline = [datetime]::UtcNow.AddSeconds(5)
        while ($watch.Taken -lt $total -and [datetime]::UtcNow -lt $drainDeadline) { Start-Sleep -Milliseconds 50 }
        Start-Sleep -Milliseconds 100
        $watch.Dispose()
        $record.watchFaulted = [bool]$watch.Faulted
        $record.watchStopped = [bool]$watch.Stopped
        $rows = @($watch.Snapshot())
        $watch = $null
        $launcher = Get-GuiHiddenLauncherRecords (Join-Path $run 'launcher-pids.txt')
        $record.processes = Get-GuiHiddenProcessVerdict $rows $launcher $total ([int]$Leaf.expectedShells)
        $record.defaultWindows = $defaultWindows
        $record.defaultWalkFailed = $defaultWalkFailed
        $receiptPath = Join-Path $run 'leaf-receipt.json'
        $receipt = $(if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } else { $null })
        $record.receiptPresent = $null -ne $receipt
        $record.realInputLoaded = $(if ($receipt) { [bool]$receipt.realInputLoaded } else { $null })
        $record.psEdition = $(if ($receipt) { [string]$receipt.psEdition } else { $null })
        $record.psVersion = $(if ($receipt) { [string]$receipt.psVersion } else { $null })
        $record.appUnchanged = [string]::Equals((Get-GuiHiddenHash (Join-Path $copy 'noctty.exe')), $ExeSha256, [StringComparison]::Ordinal)
        $record.cliUnchanged = [string]::Equals((Get-GuiHiddenHash (Join-Path $copy 'noctty.com')), $CliSha256, [StringComparison]::Ordinal)
        $sandbox = Join-Path $repoRoot (".sandbox\win11\{0}\{1}" -f (Get-InteractiveWin11WorktreeId -RepoRoot $repoRoot), [string]$Leaf.sandbox)
        $record.reparsePoints = Get-GuiHiddenReparsePointCount @($sandbox, $run)
        $record.launchPolicy = [ordered]@{
            shellSetIn = 'config-file'
            shellKind = 'config-direct-system32-cmd'
            autoRunOffObserved = $record.processes.shellsWithoutAutoRunOff -eq 0 -and $record.processes.shellsObserved -ge [int]$Leaf.expectedShells
            clipboardRead = 'deny'; clipboardWrite = 'deny'; copyOnSelect = 'false'; autoUpdate = 'off'; desktopNotifications = 'false'
            portable = $true; iconAbsent = $true; measurementMode = $true
        }
        $record.passed = -not $timedOut -and $exitCode -eq 0 -and $record.processes.passed -and $defaultWindows -eq 0 -and -not $defaultWalkFailed -and
            $record.receiptPresent -and $record.realInputLoaded -eq $false -and $record.appUnchanged -and $record.cliUnchanged -and
            $record.reparsePoints -eq 0 -and -not $record.watchFaulted -and $record.watchStopped
        $record.stage = 'done'
    }
    catch {
        $record.error = 'the runner failed at its ' + $record.stage + ' stage'
        Write-Host "gui-hidden: $id failed at $($record.stage): $($_.Exception.Message)"
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        if ($null -ne $watch) { $watch.Dispose() }
        if ($job -ne [IntPtr]::Zero) {
            try { [void][GuiHiddenRunnerNative]::StopRunJob($job) } catch { $record.passed = $false; $record.jobCleanupFailed = $true }
            [void][GuiHiddenRunnerNative]::CloseHandle($job)
        }
        if ($pi) { [void][GuiHiddenRunnerNative]::CloseHandle($pi.thread); [void][GuiHiddenRunnerNative]::CloseHandle($pi.process) }
        if ($desktop -ne [IntPtr]::Zero) { [void][GuiHiddenRunnerNative]::CloseDesktop($desktop) }
        $script:LeafPid = 0
    }
    if ($record.passed -and (Test-Path -LiteralPath $copy)) { Remove-Item -LiteralPath $copy -Recurse -Force }
    return $record
}

# ---- main

$script:LeafPid = 0
if (-not $MeasureRepo -or -not $Work -or -not $Out) { throw 'Usage: -MeasureRepo <repo> -Work <new directory> -Out <directory> [-Build] [-Leaves id,...]' }
if ($Build -and -not (Test-GuiHiddenHosted)) { throw '-Build runs only on a GitHub-hosted runner; locally, prepare the measurement build beforehand with Invoke-InteractiveWin11MeasureBuild.' }
$MeasureRepo = (Resolve-Path -LiteralPath $MeasureRepo).Path
$Work = [IO.Path]::GetFullPath($Work)
$Out = [IO.Path]::GetFullPath($Out)
if (Test-Path -LiteralPath $Work) { throw 'The work directory must be new.' }
[void](New-Item -ItemType Directory -Path $Work)
[void](New-Item -ItemType Directory -Force -Path (Join-Path $Out 'receipts'))
foreach ($drive in @(([IO.Path]::GetPathRoot($Work)), ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('System'))))) {
    $free = ([IO.DriveInfo]::new($drive)).AvailableFreeSpace
    if ($free -le 20GB) { throw "The runner stops with 20 GB or less free on $drive." }
}

$plan = Get-GuiHiddenPlan
$selected = @($plan.leaves | Where-Object { $Leaves.Count -eq 0 -or $_.id -in $Leaves })
if ($Leaves.Count -gt 0 -and $selected.Count -ne $Leaves.Count) { throw 'An -Leaves id is not in the plan.' }

$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
$startedAt = [datetime]::UtcNow
$exit = 0
$leafRecords = [System.Collections.Generic.List[object]]::new()
$runRecord = [ordered]@{ hosted = (Test-GuiHiddenHosted); built = [bool]$Build; leavesPlanned = $selected.Count }
$historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'gui-hidden-runner.ps1'
$guardDirectory = Join-Path $Work 'state-guard'
[void](New-Item -ItemType Directory -Path $guardDirectory)
$stateGuard = Start-InteractiveWin11StateGuard -Harness 'gui-hidden-runner.ps1' -ReceiptDirectory $guardDirectory
$startupBefore = Startup-Fingerprint
try {
    try {
        if ($Build) { Invoke-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo }
        $measureLayout = Get-InteractiveWin11MeasureLayout $MeasureRepo
        $rawExe = Get-InteractiveWin11MeasureExePath -RepoRoot $MeasureRepo
        Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $rawExe
        $receipt = Get-Content -LiteralPath $measureLayout.Receipt -Raw | ConvertFrom-Json
        $exeSha256 = ([string]$receipt.ExeSHA256).ToLowerInvariant()
        $cliSha256 = ([string]$receipt.CliSHA256).ToLowerInvariant()
        if ($exeSha256 -notmatch '\A[0-9a-f]{64}\z' -or $cliSha256 -notmatch '\A[0-9a-f]{64}\z') { throw 'The measurement receipt lacks the app''s or the CLI''s hash.' }
        $runRecord.head = [string]$receipt.Head
        $bin = Split-Path -Parent $rawExe
    }
    catch {
        Write-Host "gui-hidden: the measurement build is not usable: $($_.Exception.Message)"
        $runRecord.stagingFailed = $true
        $exit = 2
    }
    if ($exit -eq 0) {
        $runRoot = Join-Path $Work 'leaves'
        [void](New-Item -ItemType Directory -Path $runRoot)
        foreach ($leaf in $selected) {
            Write-Host "gui-hidden: $($leaf.id)"
            $leafRecord = Invoke-GuiHiddenLeaf -Leaf $leaf -Bin $bin -ExeSha256 $exeSha256 -CliSha256 $cliSha256 -RunRoot $runRoot
            $leafRecords.Add($leafRecord)
            $rejected = Write-GuiHiddenRecord $leafRecord (Join-Path $Out "receipts\$($leaf.id).json")
            if ($rejected -gt 0) { $leafRecord.passed = $false }
            Write-Host ("gui-hidden: {0} {1}" -f $leaf.id, $(if ($leafRecord.passed) { 'PASS' } else { 'FAIL' }))
            if (-not $leafRecord.passed) {
                # The leaf's own messages (never noctty's logs, which stay under -Work), to diagnose a failure.
                $leafLog = Join-Path $runRoot "$($leaf.id)\leaf.log"
                if (Test-Path -LiteralPath $leafLog) { Get-Content -LiteralPath $leafLog -Tail 40 | ForEach-Object { Write-Host "  | $_" } }
            }
            if (-not $leafRecord.passed -and $exit -eq 0) { $exit = 1 }
        }
        try { Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $rawExe; $runRecord.generationUnchanged = $true }
        catch { $runRecord.generationUnchanged = $false; if ($exit -eq 0) { $exit = 2 } }
        if (-not $KeepFailedCopies) {
            foreach ($leaf in $selected) {
                $copy = Join-Path $runRoot "$($leaf.id)\copy"
                if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Recurse -Force }
            }
        }
    }
}
finally {
    $guardFailure = $null
    try { Assert-InteractiveWin11StateGuard -Guard $stateGuard } catch { $guardFailure = $_.Exception.Message }
    try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { if (-not $guardFailure) { $guardFailure = $_.Exception.Message } }
    $startupAfter = Startup-Fingerprint
    if ($startupBefore.Exists -ne $startupAfter.Exists -or $startupBefore.Hash -ne $startupAfter.Hash -or $startupBefore.Modified -ne $startupAfter.Modified) {
        if (-not $guardFailure) { $guardFailure = 'the real startup state changed' }
    }
    $runRecord.stateGuardsHeld = $null -eq $guardFailure
    if ($guardFailure) { Write-Host "gui-hidden: a state guard tripped: $guardFailure"; $exit = 3 }
    Write-GuiHiddenRecord $runRecord (Join-Path $Out 'receipts\run.json') | Out-Null

    $finishedAt = [datetime]::UtcNow
    $status = $(if ($exit -eq 0) { 'pass' } elseif ($exit -eq 1) { 'fail' } else { 'error' })
    $leafPass = $leafRecords.Count -eq $selected.Count -and @($leafRecords | Where-Object { -not $_.passed }).Count -eq 0
    $policyPass = $leafRecords.Count -gt 0 -and @($leafRecords | Where-Object { -not ($_.processes -and $_.processes.passed) }).Count -eq 0
    $inputPass = $leafRecords.Count -gt 0 -and @($leafRecords | Where-Object { $_.realInputLoaded -ne $false }).Count -eq 0
    $commit = $(if ($runRecord.head -match '\A[0-9a-f]{40}\z') { [string]$runRecord.head } else { $null })
    $runId = $(if ($env:GITHUB_RUN_ID -match '\A[0-9]+\z') { $env:GITHUB_RUN_ID } else { $null })
    $runAttempt = $(if ($env:GITHUB_RUN_ATTEMPT -match '\A[0-9]+\z') { [int]$env:GITHUB_RUN_ATTEMPT } else { $null })
    $measurements = [ordered]@{}
    foreach ($leafRecord in $leafRecords) {
        $measurements["$($leafRecord.leaf).passed"] = [bool]$leafRecord.passed
        if ($leafRecord.processes) { $measurements["$($leafRecord.leaf).shellsObserved"] = [int]$leafRecord.processes.shellsObserved }
    }
    $receipts = @(Get-ChildItem -LiteralPath (Join-Path $Out 'receipts') -Filter '*.json' | Sort-Object Name | ForEach-Object {
        [ordered]@{ kind = 'other'; path = "receipts/$($_.Name)"; sha256 = (Get-GuiHiddenHash $_.FullName) }
    })
    $result = [ordered]@{
        schema_version = 'noctty.verification.result.v1'
        scenario_id = 'windows.gui-hidden.suite'
        status = $status
        started_at = $startedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        finished_at = $finishedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        duration_ms = [int64]($finishedAt - $startedAt).TotalMilliseconds
        baseline_commit = $null
        implementation_commit = $commit
        workflow_run_id = $runId
        workflow_run_attempt = $runAttempt
        environment = [ordered]@{ os = 'Windows'; architecture = 'x86_64'; hosted = [bool](Test-GuiHiddenHosted); desktop = 'private' }
        measurements = $measurements
        assertions = @(
            [ordered]@{ id = 'leaves-pass'; status = $(if ($leafPass) { 'pass' } else { 'fail' }); message = $null }
            [ordered]@{ id = 'launch-policy'; status = $(if ($policyPass) { 'pass' } else { 'fail' }); message = $null }
            [ordered]@{ id = 'real-input-absent'; status = $(if ($inputPass) { 'pass' } else { 'fail' }); message = $null }
            [ordered]@{ id = 'state-guards'; status = $(if ($runRecord.stateGuardsHeld) { 'pass' } else { 'fail' }); message = $null }
        )
        artifacts = $receipts
        failure = $(if ($exit -eq 0) { $null } else { [ordered]@{ message = "exit $exit"; type = $status } })
    }
    [IO.File]::WriteAllText((Join-Path $Out 'result.json'), ($result | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
Write-Host "gui-hidden: $status (exit $exit)"
exit $exit
