#requires -Version 7.0
<#
.SYNOPSIS
The hidden-desktop GUI suite's runner (interactive offload PR 1; design §4). It runs each leaf in
test/windows/gui-hidden-plan.json on a private desktop of its own, against a fresh portable copy of the receipt-bound
measurement build, and fails a leaf that fails, that loaded the real-input module, whose shells ran without /D, whose
job gained a noctty process the launcher did not start, that left a reparse point, or that put a window on Default.

.DESCRIPTION
  pwsh -NoProfile -File test/windows/gui-hidden-runner.ps1 -MeasureRepo <repo> -Work <new directory>
       -Out <new or empty directory> [-Build] [-Leaves <id>,...] [-KeepFailedCopies]

The build (design §4.2). Every leaf starts only a fresh portable copy of the measurement build that
Invoke-InteractiveWin11MeasureBuild (scripts/interactive-win11-measure-lib.ps1) made for -MeasureRepo's HEAD, with
NOCTTY_INTERACTIVE_MEASURE_AUMID=1: its own AUMID keeps the product's jump list and registration out of reach, and
a portable copy without noctty.ico never gets a jump list nor writes the AUMID registration (test-harnesses.md
STANDALONE-LEAF-AUMID-01; app-lifecycle.md 2026-10-16 "A portable copy"). -Build builds that generation first and is
refused off a GitHub-hosted runner: locally the generation is prepared beforehand, outside any run and redirect, and
never by a plain `zig build` (the product-AUMID zig-out build). The raw generation is validated once, under its lock,
before staging and again at the end (Assert-InteractiveWin11MeasureBuild). Each copy is staged from it (everything in
the prefix's bin but noctty.ico, crash, ghostty and the PDBs, plus share), and its app and CLI are hashed separately
against the receipt's ExeSHA256 and CliSHA256, and its ConPTY pair (conpty.dll, OpenConsole.exe) against the prefix's
bytes as validated. At the end the generation must still match those hashes and the receipt's own bytes, not only
itself. Each launch is then checked cheaply in the leaf (file identity, marker, icon, measurement mode, desktop, the
argument rule, and the command line read back from the started process; scripts/interactive-win11-lib.ps1,
Start-InteractiveWin11HostedProcess), and all four files are re-hashed when the leaf ends. A passing leaf's copy is
deleted at once; a failing one's at the end unless -KeepFailedCopies.

The launch (design §4.1). Each leaf is its own `pwsh -NoProfile -NonInteractive -File <leaf>`, started suspended on
a private desktop created for it (`WinSta0\noctty-gh-<32 hex>`, named in lpDesktop), inside a job that permits no
breakaway (PROBE-JOB-BREAKAWAY-01) and kills on close and on an unhandled exception (SOAK-01), with
NOCTTY_GUI_HIDDEN_DESKTOP, NOCTTY_GUI_HIDDEN_EXE and NOCTTY_GUI_HIDDEN_RUN set: the leaf's libraries refuse any other
desktop and never bootstrap or build. The copy's config sets the shell (`command = direct:<System32>\cmd.exe /D`),
the clipboard denied, no copy on select, no update check, no desktop notification and `window-save-state = never`.
Each leaf gets a fresh run token (<run>\staged.json): its sandbox is <run>\sandbox-<token>, and every noctty class it
names ends in the token, so no two runs (nor a run and the legacy route) share a sandbox or an IPC pipe. Every app
launch states --single-instance (false, or true only for the IPC leaves, inside their run's class); every IPC action
names the run's class (Get-InteractiveWin11HostedArgumentRefusal).

What the runner observes (design §4.1 "Every process is accounted for"). A completion port on the job reports every
process it gains; each is opened at once and read only when no message waits (PROBE-JOB-WATCH-OPEN-FIRST-01). Every
cmd.exe is tested, never kept: its loaded image must be System32's cmd.exe (path and identity), its command line must
name it, with /D among the switches before /C, /R or /K. Every noctty.exe or noctty.com must be the copy's (image path
and identity) and keep the argument rule on its command line, and be accounted for: started by the launcher (its PID
and creation time recorded before it ran), a noctty.com started by a shell inside the terminal (the shell the exact
child of an accounted noctty.exe; shell-command's PATH lookup), or a noctty.exe an accounted noctty.com forwarded.
A leaf passes only with every joiner read (the job's TotalProcesses against the processes read, each with its image),
every cmd read and passing, at least the plan's expectedShells of them, and every noctty accounted for. The k-th cmd
read creates `shell-read-<k>.flag` in the leaf's run directory, the barrier a one-shot `/c` stimulus waits on. While
the leaf runs, and once more before its job is ended, no window of its job may sit on Default (polled every 500 ms: a
window that opens and closes between two samples is not seen). Afterwards the leaf's receipt must be complete and say
the real-input module never loaded, the copy's config must still hold the launch policy (read back, a later line
winning), and no reparse point may sit under its run directory (the measured AutoRun symptom, conpty.md REPLY-PATH-01
item (6)).

The state guards, around the whole run: scripts/interactive-win11-state-guard.ps1 (the product jump list,
startup-attempts.json, the clipboard sequence) and the PSReadLine history guard. A tripped guard exits 3. Keep the
session unlocked during a local run: OpenInputDesktop fails on a locked workstation, and the leaf refuses to start.

-Out must be new or empty. It receives only result.json (the flagship result schema, scenario
windows.gui-hidden.suite) and receipts/: one JSON object per leaf run now and run.json (the build's hashes and head,
the hosted image's name and version, the two AutoRun booleans, the guards), of allowlisted values: booleans, numbers
and short strings without a path separator, quote or bracket (Write-GuiHiddenRecord, from gui-hosted-probe.ps1's record
writer, #738). No path, command line, window title or environment value enters either; a failed leaf's log reaches its
receipt only as the lines that rule admits. The console gets leaf ids and failure kinds; everything else (logs, the
runner's errors, the guard's receipts, copies) stays under -Work. A run of some leaves (-Leaves) is for diagnosis: its
result is `skip` when they pass, never `pass`. Exit codes: 0 pass, 1 a leaf failed, 2 a validation, staging, generation
or runner failure (with a result when -Out could be opened), 3 a tripped state guard.
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
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
        public uint attributes; public long created, accessed, written;
        public uint volumeSerial, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(IntPtr file, out FileInfo info);
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CommandLineToArgvW(string line, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);

    // A file's identity, its volume serial and file index read from one handle: the same file whatever path or
    // spelling reaches it. Null when unreadable.
    public static string FileId(string path) {
        if (string.IsNullOrEmpty(path)) return null;
        IntPtr file = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x80, IntPtr.Zero); // FILE_READ_ATTRIBUTES, share all, OPEN_EXISTING
        if (file == new IntPtr(-1)) return null;
        try {
            FileInfo info;
            if (!GetFileInformationByHandle(file, out info)) return null;
            return string.Format("{0:x8}:{1:x8}{2:x8}", info.volumeSerial, info.indexHigh, info.indexLow);
        } finally { CloseHandle(file); }
    }

    // Whether `imagePath` is `expectedPath`, by full path and by identity: the loaded image, not the command line's
    // claim (a process's command line need not name its image; CodeRabbit on #740).
    public static bool SameImage(string imagePath, string expectedPath, string expectedId) {
        if (string.IsNullOrEmpty(imagePath) || string.IsNullOrEmpty(expectedPath) || string.IsNullOrEmpty(expectedId)) return false;
        if (!string.Equals(imagePath, expectedPath, StringComparison.OrdinalIgnoreCase)) return false;
        return string.Equals(FileId(imagePath), expectedId, StringComparison.Ordinal);
    }

    // `line` split by CommandLineToArgvW, as the process's C runtime splits it; null when it cannot be split.
    public static string[] SplitCommandLine(string line) {
        if (string.IsNullOrEmpty(line)) return null;
        int count;
        IntPtr argv = CommandLineToArgvW(line, out count);
        if (argv == IntPtr.Zero) return null;
        try {
            var result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        } finally { LocalFree(argv); }
    }

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

    // Whether `commandLine` starts System32's cmd.exe with /D among its switches before /C, /R or /K (cmd reads
    // switches without regard to case, and runs /R as /C: `cmd /R /D x` reads `/D x` as its command and runs AutoRun;
    // Opus on #740). The text is tested here and never kept. A command line holding a control character is not read
    // (0); else 1, with the two facts set.
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
            if (token.Length >= 2 && "CcKkRr".IndexOf(token[1]) >= 0) break;
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

    static string ImagePathOf(IntPtr process) {
        var name = new StringBuilder(32768); uint size = (uint)name.Capacity;
        return QueryFullProcessImageNameW(process, 0, name, ref size) ? name.ToString() : null;
    }

    // One joiner. Only facts leave the reader: an image's leaf name and booleans. A noctty's split command line
    // (`Argv`) stays in memory for the argument rule and is never written.
    public sealed class JoinedProcess {
        public int Pid; public long Taken; public IntPtr Handle; public bool OpenFailed; public bool Unpinned;
        public long Creation; public int Parent; public string Image;
        public bool IsCmd; public bool CmdRead; public bool CmdSystem; public bool CmdImageSystem; public bool CmdAutoRunOff; public int CmdOrdinal;
        public bool IsNoctty; public bool InCopy; public string[] Argv;
    }

    // The job's completion-port reader (gui-hosted-probe.ps1's JobWatch, #738, PROBE-JOB-WATCH-OPEN-FIRST-01): every
    // waiting message's process is opened first and its handle held; one opened process is read only when no message
    // waits; the reader runs above normal priority, and a fault ends the reading, never the process.
    public sealed class JobWatch : IDisposable {
        readonly IntPtr port; readonly IntPtr job; readonly Thread reader; readonly string systemCmd; readonly string flagDirectory;
        readonly string systemCmdId, appPath, appId, cliPath, cliId;
        volatile bool stopping; int cmdCount; int taken;
        public volatile bool Faulted;
        // How many joiners the reader has taken from the port (each gets a row, opened or not).
        public int Taken { get { return Volatile.Read(ref taken); } }
        public bool Stopped;
        readonly List<JoinedProcess> joined = new List<JoinedProcess>();
        readonly List<JoinedProcess> opened = new List<JoinedProcess>();
        // `appPath` and `cliPath` are the staged copy's noctty.exe and noctty.com; a noctty joiner is in the copy only
        // when its image is one of them by path and identity.
        public JobWatch(IntPtr job, string systemCmd, string flagDirectory, string appPath, string cliPath) {
            this.job = job; this.systemCmd = systemCmd; this.flagDirectory = flagDirectory;
            this.appPath = appPath; this.cliPath = cliPath;
            systemCmdId = FileId(systemCmd); appId = FileId(appPath); cliId = FileId(cliPath);
            if (systemCmdId == null || appId == null || cliId == null) throw new Exception("The watch could not read System32's cmd.exe or the copy's identity.");
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
            string imagePath = ImagePathOf(h);
            row.Image = imagePath == null ? null : Path.GetFileName(imagePath);
            if (row.Image != null && (string.Equals(row.Image, "noctty.exe", StringComparison.OrdinalIgnoreCase) || string.Equals(row.Image, "noctty.com", StringComparison.OrdinalIgnoreCase))) {
                row.IsNoctty = true;
                row.InCopy = string.Equals(row.Image, "noctty.exe", StringComparison.OrdinalIgnoreCase) ? SameImage(imagePath, appPath, appId) : SameImage(imagePath, cliPath, cliId);
                row.Argv = SplitCommandLine(CommandLineOf(h));
            }
            if (row.Image != null && string.Equals(row.Image, "cmd.exe", StringComparison.OrdinalIgnoreCase)) {
                row.IsCmd = true;
                bool system, autoRunOff;
                string line = CommandLineOf(h);
                row.CmdRead = CmdVerdict(line, systemCmd, out system, out autoRunOff) == 1;
                line = null;
                // System32's only when the loaded image is System32's cmd.exe (path and identity) and the command line
                // names it too.
                row.CmdImageSystem = SameImage(imagePath, systemCmd, systemCmdId);
                row.CmdSystem = system && row.CmdImageSystem; row.CmdAutoRunOff = autoRunOff;
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
        # A rejected value leaves the verdicts that read it inconclusive: the written record fails too.
        if ($clean.Contains('passed')) { $clean.passed = $false }
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
# `Build` holds the hashes taken when the generation was validated: the app and CLI (the receipt's ExeSHA256 and
# CliSHA256) and the ConPTY pair (conpty.dll and OpenConsole.exe, which the copy's app loads from beside itself,
# pty.zig; no receipt names them, so the prefix's own bytes at validation are the reference, as
# hidden-win11-working-set.ps1 checks its copy's pair, #739). Throws on any difference.
function New-GuiHiddenCopy([string] $Bin, [string] $Copy, [System.Collections.IDictionary] $Build) {
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
    foreach ($file in $script:GuiHiddenBuildFiles) {
        $staged = Join-Path $Copy $file.Name
        if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) { throw "The copy has no $($file.Name)." }
        if (-not [string]::Equals((Get-GuiHiddenHash $staged), [string]$Build[$file.Key], [StringComparison]::Ordinal)) { throw "The staged $($file.Name) is not the measurement build's." }
    }
}

# The files of a copy that are hashed at validation, at staging and when each leaf ends: name and Build key.
$script:GuiHiddenBuildFiles = @(
    [pscustomobject]@{ Name = 'noctty.exe'; Key = 'exeSha256' }
    [pscustomobject]@{ Name = 'noctty.com'; Key = 'cliSha256' }
    [pscustomobject]@{ Name = 'conpty.dll'; Key = 'conptyDllSha256' }
    [pscustomobject]@{ Name = 'OpenConsole.exe'; Key = 'openConsoleSha256' }
)

# Every reparse point under `Roots`, counted and never entered: the walk lists one directory at a time, without
# recursion of its own, and descends only into plain directories, so a junction's target (which could be anywhere,
# the user's real profile included) is never read (Greptile on #740). `Visited`, when given, receives every path the
# walk listed, for its control.
function Get-GuiHiddenReparsePointCount([string[]] $Roots, [System.Collections.Generic.List[string]] $Visited = $null) {
    $count = 0
    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $false
    $options.AttributesToSkip = [IO.FileAttributes]::None
    $options.IgnoreInaccessible = $false
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $count++; continue }
        $pending = [System.Collections.Generic.Stack[string]]::new()
        $pending.Push($root)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory, '*', $options)) {
                if ($null -ne $Visited) { $Visited.Add($entry) }
                $attributes = [IO.File]::GetAttributes($entry)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $count++ }
                elseif (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry) }
            }
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

# The leaf's verdict on its job's processes (design §4.1): every joiner read; every cmd read, System32's (its loaded
# image by path and identity, and its command line) and with /D before its payload, at least `ExpectedShells` of them;
# every noctty.exe or noctty.com in the copy (image path and identity), keeping the argument rule
# (Get-InteractiveWin11HostedArgumentRefusal, with `Token`), and accounted for by one of exactly three routes:
# - the launcher recorded it (its PID and creation time, written before it ran);
# - a noctty.com that a shell inside the terminal started: the shell (System32 cmd with /D, or powershell.exe or
#   pwsh.exe) is the exact child of an accounted noctty.exe, and is not the leaf (shell-command's PATH lookup, §4.2);
# - a noctty.exe that an accounted noctty.com forwarded (its exact child).
# "Exact child": the child's parent PID is a read joiner created no later than the child, so a reused PID cannot
# vouch. Anything else fails, whoever started it (H2 on #740; Opus M1: a leaf's own shell starting noctty).
function Get-GuiHiddenProcessVerdict($Rows, [hashtable] $Launcher, [int] $TotalProcesses, [int] $ExpectedShells, [string] $Token, [int] $LeafPid) {
    # A joiner counts as read only with its image too: one whose image could not be read (opened and pinned, but
    # QueryFullProcessImageName failed) could be a cmd or a noctty, so it is unreadable, and the verdict fails.
    $isRead = { param($Row) -not $Row.OpenFailed -and -not $Row.Unpinned -and -not [string]::IsNullOrEmpty($Row.Image) }
    $byPid = @{}
    foreach ($row in $Rows) { if (& $isRead $row) { $byPid[$row.Pid] = $row } }
    $read = @($Rows | Where-Object { & $isRead $_ }).Count
    $cmds = @($Rows | Where-Object { $_.IsCmd })
    $nocttyRows = @($Rows | Where-Object { $_.IsNoctty })
    $parentOf = {
        param($Row)
        $parent = $byPid[$Row.Parent]
        if ($null -eq $parent -or $parent.Pid -eq $Row.Pid -or $parent.Creation -gt $Row.Creation) { return $null }
        return $parent
    }
    $accounted = @{}
    $argumentRefused = 0; $argvUnread = 0; $outsideCopy = 0
    foreach ($row in @($nocttyRows | Sort-Object Creation)) {
        if (-not $row.InCopy) { $outsideCopy++ }
        if ($null -eq $row.Argv -or $row.Argv.Count -lt 1) { $argvUnread++ }
        elseif (Get-InteractiveWin11HostedArgumentRefusal -Arguments @($row.Argv | Select-Object -Skip 1) -Token $Token) { $argumentRefused++ }
        $recorded = $Launcher.ContainsKey($row.Pid) -and $Launcher[$row.Pid] -eq $row.Creation
        $parent = & $parentOf $row
        $viaShell = $false; $forwarded = $false
        if ($null -ne $parent -and $row.Image -ieq 'noctty.com' -and $parent.Pid -ne $LeafPid) {
            $shellOk = $(if ($parent.IsCmd) { $parent.CmdRead -and $parent.CmdSystem -and $parent.CmdAutoRunOff } else { $parent.Image -ieq 'powershell.exe' -or $parent.Image -ieq 'pwsh.exe' })
            $terminal = & $parentOf $parent
            $viaShell = $shellOk -and $null -ne $terminal -and $terminal.Image -ieq 'noctty.exe' -and $accounted.ContainsKey($terminal.Pid)
        }
        if ($null -ne $parent -and $row.Image -ieq 'noctty.exe') {
            $forwarded = $parent.Image -ieq 'noctty.com' -and $accounted.ContainsKey($parent.Pid)
        }
        if ($row.InCopy -and ($recorded -or $viaShell -or $forwarded)) { $accounted[$row.Pid] = $true }
    }
    $unaccounted = $nocttyRows.Count - $accounted.Count
    $cmdPassing = @($cmds | Where-Object { $_.CmdRead -and $_.CmdSystem -and $_.CmdAutoRunOff }).Count
    $verdict = [ordered]@{
        jobTotalProcesses = $TotalProcesses
        processesRead = $read
        unopened = @($Rows | Where-Object { $_.OpenFailed }).Count
        unpinned = @($Rows | Where-Object { $_.Unpinned }).Count
        imageUnread = @($Rows | Where-Object { -not $_.OpenFailed -and -not $_.Unpinned -and [string]::IsNullOrEmpty($_.Image) }).Count
        shellsExpected = $ExpectedShells
        shellsObserved = $cmds.Count
        shellsPassing = $cmdPassing
        shellsUnread = @($cmds | Where-Object { -not $_.CmdRead }).Count
        shellsNotSystemCmd = @($cmds | Where-Object { $_.CmdRead -and -not $_.CmdSystem }).Count
        shellsImageNotSystemCmd = @($cmds | Where-Object { -not $_.CmdImageSystem }).Count
        shellsWithoutAutoRunOff = @($cmds | Where-Object { $_.CmdRead -and -not $_.CmdAutoRunOff }).Count
        nocttyProcesses = $nocttyRows.Count
        nocttyUnaccounted = $unaccounted
        nocttyOutsideCopy = $outsideCopy
        nocttyArgvUnread = $argvUnread
        nocttyArgumentRefused = $argumentRefused
    }
    $verdict.passed = $TotalProcesses -eq $Rows.Count -and $read -eq $Rows.Count -and $cmdPassing -eq $cmds.Count -and
        $cmds.Count -ge $ExpectedShells -and $unaccounted -eq 0 -and $outsideCopy -eq 0 -and $argvUnread -eq 0 -and $argumentRefused -eq 0
    return $verdict
}

# The leaf's receipt, judged strictly (Sol and CodeRabbit on #740): schemaVersion 1, `realInputLoaded` present and a
# JSON boolean, `psEdition` and `psVersion` present and of their shapes. Anything else (no file, unparsable JSON, an
# empty object, a missing or null or string field) is invalid, and an invalid receipt fails the leaf; nothing is cast.
function Test-GuiHiddenLeafReceipt([string] $Path) {
    $result = [ordered]@{ present = $false; valid = $false; realInputLoaded = $null; psEdition = $null; psVersion = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $result.present = $true
    try { $receipt = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop } catch { return $result }
    if ($receipt -isnot [System.Management.Automation.PSCustomObject]) { return $result }
    $names = @($receipt.PSObject.Properties.Name)
    foreach ($name in @('schemaVersion', 'realInputLoaded', 'psEdition', 'psVersion')) { if ($name -cnotin $names) { return $result } }
    if ($receipt.schemaVersion -isnot [long] -and $receipt.schemaVersion -isnot [int]) { return $result }
    if ($receipt.schemaVersion -ne 1) { return $result }
    if ($receipt.realInputLoaded -isnot [bool]) { return $result }
    if ($receipt.psEdition -isnot [string] -or $receipt.psEdition -cnotmatch '\A(Core|Desktop)\z') { return $result }
    if ($receipt.psVersion -isnot [string] -or $receipt.psVersion -cnotmatch '\A[0-9]{1,3}\.[0-9]{1,3}\z') { return $result }
    $result.valid = $true
    $result.realInputLoaded = [bool]$receipt.realInputLoaded
    $result.psEdition = [string]$receipt.psEdition
    $result.psVersion = [string]$receipt.psVersion
    return $result
}

# The launch policy as the copy's config.ghostty holds it when the leaf ends, read back rather than assumed (Opus L5 on
# #740): each key's last value (a later line wins), kept only when it is one of the known values (else `other`), and
# whether the shell is System32's cmd with /D. `forbiddenKeys` counts lines that set what the argument rule governs, or
# include another file.
function Get-GuiHiddenConfigPolicy([string] $Path) {
    $values = @{}
    $forbidden = 0
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '\A\s*(#|\z)') { continue }
            if ($line -notmatch '\A\s*([A-Za-z0-9-]+)\s*=\s*(.*?)\s*\z') { $forbidden++; continue }
            $key = $Matches[1].ToLowerInvariant(); $value = $Matches[2]
            if ($key -in @('class', 'single-instance', 'gtk-single-instance', 'config-file', 'config-default-files')) { $forbidden++ }
            $values[$key] = $value
        }
    }
    $known = {
        param([string] $Key, [string[]] $Allowed)
        if (-not $values.ContainsKey($Key)) { return 'unset' }
        if ($values[$Key] -cin $Allowed) { return $values[$Key] }
        return 'other'
    }
    $cmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $policy = [ordered]@{
        configPresent = Test-Path -LiteralPath $Path -PathType Leaf
        shellKind = $(if (-not $values.ContainsKey('command')) { 'unset' } elseif ([string]::Equals($values['command'], "direct:$cmd /D", [StringComparison]::OrdinalIgnoreCase)) { 'config-direct-system32-cmd' } else { 'other' })
        clipboardRead = & $known 'clipboard-read' @('deny', 'ask', 'allow')
        clipboardWrite = & $known 'clipboard-write' @('deny', 'ask', 'allow')
        copyOnSelect = & $known 'copy-on-select' @('false', 'true', 'clipboard')
        autoUpdate = & $known 'auto-update' @('off', 'check', 'download')
        desktopNotifications = & $known 'desktop-notifications' @('false', 'true')
        windowSaveState = & $known 'window-save-state' @('never', 'always', 'default')
        renderer = & $known 'renderer' @('opengl', 'd3d11', 'd3d11-warp')
        forbiddenKeys = $forbidden
    }
    $policy.held = $policy.configPresent -and $policy.shellKind -ceq 'config-direct-system32-cmd' -and $policy.clipboardRead -ceq 'deny' -and
        $policy.clipboardWrite -ceq 'deny' -and $policy.copyOnSelect -ceq 'false' -and $policy.autoUpdate -ceq 'off' -and
        $policy.desktopNotifications -ceq 'false' -and $policy.windowSaveState -cne 'other' -and $policy.renderer -cne 'other' -and $forbidden -eq 0
    return $policy
}

# A failed leaf's own log, for the uploaded receipt: its line count, and only the lines the record's string rule
# admits (no path, quote or bracket; at most 80 characters), the rest counted as withheld. Nothing reaches the
# console (Sol L8 on #740: an app's diagnostics can sit in a leaf's exception text).
function Get-GuiHiddenLogDigest([string] $Path) {
    $digest = [ordered]@{ lines = 0; withheld = 0; kept = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $digest }
    $lines = @([IO.File]::ReadAllLines($Path))
    $digest.lines = $lines.Count
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($lines | Select-Object -Last 40)) {
        if ($line.Length -le 80 -and $line -cmatch '\A[A-Za-z0-9 ._:+#=\-]*\z') { $kept.Add($line) } else { $digest.withheld++ }
    }
    $digest.kept = $kept.ToArray()
    return $digest
}

# The kinds of failure a leaf record shows, for the console (counts and kinds only).
function Get-GuiHiddenFailureKinds($Record) {
    $kinds = [System.Collections.Generic.List[string]]::new()
    if ($Record.error) { $kinds.Add("runner-$($Record.stage)") }
    if ($Record.timedOut) { $kinds.Add('timeout') }
    if ($null -ne $Record.exitCode -and $Record.exitCode -ne 0) { $kinds.Add("exit-$($Record.exitCode)") }
    if ($Record.processes -and -not $Record.processes.passed) { $kinds.Add('processes') }
    if ($Record.defaultWindows -gt 0 -or $Record.defaultWalkFailed) { $kinds.Add('default-desktop') }
    if ($Record.receipt -and -not $Record.receipt.valid) { $kinds.Add('receipt-invalid') }
    if ($Record.receipt -and $Record.receipt.realInputLoaded -eq $true) { $kinds.Add('real-input-loaded') }
    if ($Record.launchPolicy -and -not $Record.launchPolicy.held) { $kinds.Add('launch-policy') }
    if ($Record.reparsePoints -gt 0) { $kinds.Add('reparse-point') }
    if ($Record.appUnchanged -eq $false -or $Record.cliUnchanged -eq $false -or $Record.conptyUnchanged -eq $false) { $kinds.Add('copy-changed') }
    if ($Record.watchFaulted -or $Record.watchStopped -eq $false) { $kinds.Add('watch') }
    if ($Record.rejectedValues) { $kinds.Add('record-rejected') }
    if ($kinds.Count -eq 0 -and -not $Record.passed) { $kinds.Add('unknown') }
    return $kinds.ToArray()
}

# Runs one leaf on its own private desktop and returns its record (allowlisted values only).
function Invoke-GuiHiddenLeaf($Leaf, [string] $Bin, [System.Collections.IDictionary] $Build, [string] $RunRoot) {
    $id = [string]$Leaf.id
    $run = Join-Path $RunRoot $id
    [void](New-Item -ItemType Directory -Path $run)
    $copy = Join-Path $run 'copy'
    $record = [ordered]@{ leaf = $id; passed = $false; stage = 'staging' }
    $desktop = [IntPtr]::Zero; $job = [IntPtr]::Zero; $watch = $null; $pi = $null
    $saved = @{}
    try {
        New-GuiHiddenCopy -Bin $Bin -Copy $copy -Build $Build
        # A fresh run token per leaf (Get-InteractiveWin11HostedRunToken): the leaf's sandbox is <run>\sandbox-<token>
        # and every class it names ends in the token, so no two runs share either (H1 on #740).
        $token = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $run 'staged.json'), ([ordered]@{ exeSha256 = $Build.exeSha256; cliSha256 = $Build.cliSha256; runToken = $token } | ConvertTo-Json))
        foreach ($name in @('localappdata', 'appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $run $name)) }
        $record.stage = 'launch'
        $desktopName = 'noctty-gh-' + [guid]::NewGuid().ToString('N')
        $desktop = [GuiHiddenRunnerNative]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
        if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
        $job = [GuiHiddenRunnerNative]::CreateRunJob()
        $systemCmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $watch = [GuiHiddenRunnerNative+JobWatch]::new($job, $systemCmd, $run, (Join-Path $copy 'noctty.exe'), (Join-Path $copy 'noctty.com'))
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
        $leafPid = $pi.pid
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        $saved = @{}
        $deadline = $started.AddSeconds([int]$Leaf.timeoutSeconds)
        $defaultWindows = 0; $defaultWalkFailed = $false; $timedOut = $false
        # One sample of Default: a failed PID query or walk is a failed sample, never a clean one (CodeRabbit on #740).
        $sampleDefault = {
            $pids = [GuiHiddenRunnerNative]::JobPids($job)
            if ($null -eq $pids) { $script:GuiHiddenSampleFailed = $true; return 0 }
            if ($pids.Count -eq 0) { return 0 }
            $found = [GuiHiddenRunnerNative]::DefaultWindowsOf($pids)
            if ($found -lt 0) { $script:GuiHiddenSampleFailed = $true; return 0 }
            return $found
        }
        $script:GuiHiddenSampleFailed = $false
        while ([GuiHiddenRunnerNative]::WaitForSingleObject($pi.process, 500) -eq 258) {
            $defaultWindows += & $sampleDefault
            if ([datetime]::UtcNow -ge $deadline) { $timedOut = $true; break }
        }
        # A last sample before the job is ended, so a window a remaining process opened after the last poll is seen
        # before StopRunJob takes it away (CodeRabbit on #740). Polling cannot see a window that opens and closes
        # between two samples (every 500 ms).
        $defaultWindows += & $sampleDefault
        $defaultWalkFailed = $script:GuiHiddenSampleFailed
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
        $record.processes = Get-GuiHiddenProcessVerdict $rows $launcher $total ([int]$Leaf.expectedShells) $token $leafPid
        $rows = $null
        $record.defaultWindows = $defaultWindows
        $record.defaultWalkFailed = $defaultWalkFailed
        $record.receipt = Test-GuiHiddenLeafReceipt (Join-Path $run 'leaf-receipt.json')
        $record.realInputLoaded = $record.receipt.realInputLoaded
        $after = [ordered]@{}
        foreach ($file in $script:GuiHiddenBuildFiles) { $after[$file.Key] = Get-GuiHiddenHash (Join-Path $copy $file.Name) }
        $record.appUnchanged = [string]::Equals($after.exeSha256, $Build.exeSha256, [StringComparison]::Ordinal)
        $record.cliUnchanged = [string]::Equals($after.cliSha256, $Build.cliSha256, [StringComparison]::Ordinal)
        $record.conptyUnchanged = [string]::Equals($after.conptyDllSha256, $Build.conptyDllSha256, [StringComparison]::Ordinal) -and
            [string]::Equals($after.openConsoleSha256, $Build.openConsoleSha256, [StringComparison]::Ordinal)
        # The leaf's sandbox, copy, logs and run state all sit under its run directory (the sandbox by its token).
        $record.reparsePoints = Get-GuiHiddenReparsePointCount @($run)
        $policy = Get-GuiHiddenConfigPolicy (Join-Path $copy 'config.ghostty')
        $policy.autoRunOffObserved = $record.processes.shellsWithoutAutoRunOff -eq 0 -and $record.processes.shellsObserved -ge [int]$Leaf.expectedShells
        $policy.portable = Test-Path -LiteralPath (Join-Path $copy 'noctty.portable') -PathType Leaf
        $policy.iconAbsent = -not (Test-Path -LiteralPath (Join-Path $copy 'noctty.ico'))
        $policy.measurementMode = $true
        $policy.held = $policy.held -and $policy.autoRunOffObserved -and $policy.portable -and $policy.iconAbsent
        $record.launchPolicy = $policy
        # The renderer the copies used: the configured backend, and how many of the leaf's noctty logs report the
        # OpenGL-to-D3D11 fallback (renderer/Windows.zig's warning; counted, never copied).
        $logs = Join-Path $run "sandbox-$token\logs"
        $record.rendererFallbackLogs = @(Get-ChildItem -LiteralPath $logs -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { [IO.File]::ReadAllText($_.FullName).Contains('; trying the Direct3D 11 beta') }).Count
        $record.passed = -not $timedOut -and $exitCode -eq 0 -and $record.processes.passed -and $defaultWindows -eq 0 -and -not $defaultWalkFailed -and
            $record.receipt.valid -and $record.receipt.realInputLoaded -eq $false -and $record.appUnchanged -and $record.cliUnchanged -and
            $record.conptyUnchanged -and $record.reparsePoints -eq 0 -and $policy.held -and -not $record.watchFaulted -and $record.watchStopped
        $record.stage = 'done'
    }
    catch {
        $record.passed = $false
        $record.error = 'the runner failed at its ' + $record.stage + ' stage'
        $record.errorKind = $_.Exception.GetType().Name
        # The message can hold a path: it stays in the work directory.
        try { [IO.File]::AppendAllText((Join-Path $run 'runner-error.txt'), ($_ | Out-String)) } catch { }
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
    }
    if (-not $record.passed) { $record.failureLog = Get-GuiHiddenLogDigest (Join-Path $run 'leaf.log') }
    if ($record.passed -and (Test-Path -LiteralPath $copy)) { Remove-Item -LiteralPath $copy -Recurse -Force }
    return $record
}

# ---- main

# A value of a known shape, else 'unknown' (gui-hosted-probe.ps1's rule for the hosted image's name and version, #738).
function Get-GuiHiddenShaped([string] $Value, [string] $Pattern) {
    if ($Value -and $Value -cmatch $Pattern) { return $Value }
    return 'unknown'
}

# Whether a `Command Processor\AutoRun` value exists under `Root` (design §4.2: two booleans, never the value).
function Test-GuiHiddenAutoRunPresent([string] $Root) {
    $key = Get-Item -LiteralPath "$Root\Software\Microsoft\Command Processor" -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $false }
    return @($key.GetValueNames()) -contains 'AutoRun'
}

# The hashes the run is bound to, taken under the generation's lock right after it was validated: the receipt file's
# bytes, the receipt's app and CLI hashes, and the prefix's ConPTY pair. The end-of-run check compares the generation
# with these, not only with itself (CodeRabbit on #740: a rebuild at the same head would validate against its own
# receipt).
function Get-GuiHiddenBuildBinding([string] $ReceiptPath, [string] $Bin) {
    $receipt = [IO.File]::ReadAllText($ReceiptPath) | ConvertFrom-Json
    $binding = [ordered]@{
        head = [string]$receipt.Head
        receiptSha256 = Get-GuiHiddenHash $ReceiptPath
        exeSha256 = ([string]$receipt.ExeSHA256).ToLowerInvariant()
        cliSha256 = ([string]$receipt.CliSHA256).ToLowerInvariant()
        conptyDllSha256 = $null
        openConsoleSha256 = $null
    }
    if ($binding.exeSha256 -notmatch '\A[0-9a-f]{64}\z' -or $binding.cliSha256 -notmatch '\A[0-9a-f]{64}\z') { throw 'The measurement receipt lacks the app''s or the CLI''s hash.' }
    if ($binding.head -cnotmatch '\A[0-9a-f]{40}\z') { throw 'The measurement receipt lacks its head.' }
    foreach ($file in @(@('conpty.dll', 'conptyDllSha256'), @('OpenConsole.exe', 'openConsoleSha256'))) {
        $path = Join-Path $Bin $file[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The measurement build has no $($file[0])." }
        $binding[$file[1]] = Get-GuiHiddenHash $path
    }
    return $binding
}

function Write-GuiHiddenRunnerError([string] $Context) {
    # The detail stays under -Work; the console gets its kind.
    if ($script:GuiHiddenWork -and (Test-Path -LiteralPath $script:GuiHiddenWork)) {
        try { [IO.File]::AppendAllText((Join-Path $script:GuiHiddenWork 'runner-error.txt'), "$Context`n" + ($_ | Out-String)) } catch { }
    }
}

$startedAt = [datetime]::UtcNow
$exit = 0
$outReady = $false
$script:GuiHiddenWork = $null
$leafRecords = [System.Collections.Generic.List[object]]::new()
$receiptNames = [System.Collections.Generic.List[string]]::new()
$runRecord = [ordered]@{ hosted = (Test-GuiHiddenHosted); built = [bool]$Build }
$selected = @()
$plan = $null
$subset = $false
$failureKind = $null

# Validation: any failure here exits 2, with a result when -Out could be opened (CodeRabbit on #740).
try {
    if (-not $MeasureRepo -or -not $Work -or -not $Out) { throw 'Usage: -MeasureRepo <repo> -Work <new directory> -Out <empty or new directory> [-Build] [-Leaves id,...]' }
    $Out = [IO.Path]::GetFullPath($Out)
    # -Out holds this run's files only: new or empty, so no earlier receipt can be listed as this run's (Sol and
    # CodeRabbit on #740). Nothing in it is ever deleted.
    if (Test-Path -LiteralPath $Out) {
        if (-not (Test-Path -LiteralPath $Out -PathType Container)) { throw 'The output path is not a directory.' }
        if (@(Get-ChildItem -LiteralPath $Out -Force).Count -gt 0) { throw 'The output directory must be new or empty.' }
    }
    [void](New-Item -ItemType Directory -Force -Path (Join-Path $Out 'receipts'))
    $outReady = $true
    if ($Build -and -not (Test-GuiHiddenHosted)) { throw '-Build runs only on a GitHub-hosted runner; locally, prepare the measurement build beforehand with Invoke-InteractiveWin11MeasureBuild.' }
    $MeasureRepo = (Resolve-Path -LiteralPath $MeasureRepo).Path
    $Work = [IO.Path]::GetFullPath($Work)
    if (Test-Path -LiteralPath $Work) { throw 'The work directory must be new.' }
    [void](New-Item -ItemType Directory -Path $Work)
    $script:GuiHiddenWork = $Work
    foreach ($drive in @(([IO.Path]::GetPathRoot($Work)), ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('System'))))) {
        $free = ([IO.DriveInfo]::new($drive)).AvailableFreeSpace
        if ($free -le 20GB) { throw "The runner stops with 20 GB or less free on $drive." }
    }
    $plan = Get-GuiHiddenPlan
    # `pwsh -File` passes `-Leaves a,b` as one string: split it.
    $Leaves = @($Leaves | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $selected = @($plan.leaves | Where-Object { $Leaves.Count -eq 0 -or $_.id -in $Leaves })
    if ($Leaves.Count -gt 0 -and $selected.Count -ne $Leaves.Count) { throw 'An -Leaves id is not in the plan.' }
    # A subset run is for diagnosis: its result never passes the full scenario (CodeRabbit on #740).
    $subset = $selected.Count -lt @($plan.leaves).Count
}
catch {
    Write-Host "gui-hidden: validation failed: $($_.Exception.Message)"
    $exit = 2
    $failureKind = 'validation'
}
$runRecord.leavesPlanned = $(if ($plan) { @($plan.leaves).Count } else { 0 })
$runRecord.leavesSelected = $selected.Count
$runRecord.subset = $subset
$runRecord.imageOs = Get-GuiHiddenShaped $env:ImageOS '\A[A-Za-z0-9._-]{1,32}\z'
$runRecord.imageVersion = Get-GuiHiddenShaped $env:ImageVersion '\A[0-9][0-9.]{0,31}\z'
$runRecord.autoRunHkcu = Test-GuiHiddenAutoRunPresent 'HKCU:'
$runRecord.autoRunHklm = Test-GuiHiddenAutoRunPresent 'HKLM:'

if ($exit -eq 0) {
    $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
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
            $bin = Split-Path -Parent $rawExe
            $binding = Get-GuiHiddenBuildBinding $measureLayout.Receipt $bin
            foreach ($key in @($binding.Keys)) { $runRecord[$key] = $binding[$key] }
        }
        catch {
            Write-GuiHiddenRunnerError 'measurement build'
            Write-Host "gui-hidden: the measurement build is not usable ($($_.Exception.GetType().Name)); details under -Work"
            $runRecord.stagingFailed = $true
            $exit = 2
            $failureKind = 'staging'
        }
        if ($exit -eq 0) {
            $runRoot = Join-Path $Work 'leaves'
            [void](New-Item -ItemType Directory -Path $runRoot)
            foreach ($leaf in $selected) {
                Write-Host "gui-hidden: $($leaf.id)"
                $leafRecord = Invoke-GuiHiddenLeaf -Leaf $leaf -Bin $bin -Build $binding -RunRoot $runRoot
                $leafRecords.Add($leafRecord)
                # The record writer applies its rejections (and the failed verdict they mean) before it writes, so the
                # receipt and the result carry one verdict (CodeRabbit on #740).
                $rejected = Write-GuiHiddenRecord $leafRecord (Join-Path $Out "receipts\$($leaf.id).json")
                $receiptNames.Add("$($leaf.id).json")
                if ($rejected -gt 0) { $leafRecord.passed = $false; $leafRecord.rejectedValues = $rejected }
                if ($leafRecord.passed) { Write-Host "gui-hidden: $($leaf.id) PASS" }
                else {
                    # Kinds only; the leaf's log stays under -Work, its allowlisted tail in the receipt (Sol L8 on #740).
                    Write-Host ("gui-hidden: {0} FAIL ({1})" -f $leaf.id, ((Get-GuiHiddenFailureKinds $leafRecord) -join ', '))
                }
                if (-not $leafRecord.passed -and $exit -eq 0) { $exit = 1; $failureKind = 'leaf' }
            }
            # The generation at the end: still valid, and still the one the copies were staged from.
            try {
                Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $rawExe
                $end = Get-GuiHiddenBuildBinding $measureLayout.Receipt $bin
                $runRecord.generationUnchanged = @($binding.Keys | Where-Object { -not [string]::Equals([string]$binding[$_], [string]$end[$_], [StringComparison]::Ordinal) }).Count -eq 0
            }
            catch { Write-GuiHiddenRunnerError 'final generation check'; $runRecord.generationUnchanged = $false }
            if (-not $runRecord.generationUnchanged -and $exit -ne 1) { $exit = 2; $failureKind = 'generation' }
            if (-not $KeepFailedCopies) {
                foreach ($leaf in $selected) {
                    $copy = Join-Path $runRoot "$($leaf.id)\copy"
                    if (Test-Path -LiteralPath $copy) { Remove-Item -LiteralPath $copy -Recurse -Force }
                }
            }
        }
    }
    catch {
        # A runner exception never leaves a passing result behind (CodeRabbit on #740).
        Write-GuiHiddenRunnerError 'suite'
        Write-Host "gui-hidden: the runner stopped ($($_.Exception.GetType().Name)); details under -Work"
        $runRecord.runnerStopped = $true
        $exit = 2
        $failureKind = 'runner'
    }
    finally {
        $guardFailure = $null
        $runRecord.stateGuardHeld = $true; $runRecord.historyGuardHeld = $true; $runRecord.startupUnchanged = $true
        try { Assert-InteractiveWin11StateGuard -Guard $stateGuard } catch { $runRecord.stateGuardHeld = $false; $guardFailure = 'state' }
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $runRecord.historyGuardHeld = $false; if (-not $guardFailure) { $guardFailure = 'history' } }
        $startupAfter = Startup-Fingerprint
        if ($startupBefore.Exists -ne $startupAfter.Exists -or $startupBefore.Hash -ne $startupAfter.Hash -or $startupBefore.Modified -ne $startupAfter.Modified) {
            $runRecord.startupUnchanged = $false
            if (-not $guardFailure) { $guardFailure = 'startup' }
        }
        $runRecord.stateGuardsHeld = $null -eq $guardFailure
        if ($guardFailure) { Write-Host "gui-hidden: a state guard tripped ($guardFailure); details under -Work"; $exit = 3; $failureKind = 'state-guard' }
    }
}

if ($outReady) {
    $runRecord.exit = $exit
    Write-GuiHiddenRecord $runRecord (Join-Path $Out 'receipts\run.json') | Out-Null
    $receiptNames.Add('run.json')
    $finishedAt = [datetime]::UtcNow
    $allPassed = $leafRecords.Count -eq $selected.Count -and $selected.Count -gt 0 -and @($leafRecords | Where-Object { -not $_.passed }).Count -eq 0
    # A subset run that passed is `skip`, never `pass`: leaves-pass is the whole plan's.
    $status = $(if ($exit -eq 0 -and -not $subset) { 'pass' } elseif ($exit -eq 0) { 'skip' } elseif ($exit -eq 1) { 'fail' } else { 'error' })
    $leafStatus = $(if (-not $allPassed) { 'fail' } elseif ($subset) { 'skip' } else { 'pass' })
    $policyPass = $leafRecords.Count -gt 0 -and @($leafRecords | Where-Object { -not ($_.processes -and $_.processes.passed -and $_.launchPolicy -and $_.launchPolicy.held) }).Count -eq 0
    $inputPass = $leafRecords.Count -gt 0 -and @($leafRecords | Where-Object { -not ($_.receipt -and $_.receipt.valid -and $_.receipt.realInputLoaded -eq $false) }).Count -eq 0
    $commit = $(if ($runRecord.head -match '\A[0-9a-f]{40}\z') { [string]$runRecord.head } else { $null })
    $runId = $(if ($env:GITHUB_RUN_ID -match '\A[0-9]+\z') { $env:GITHUB_RUN_ID } else { $null })
    $runAttempt = $(if ($env:GITHUB_RUN_ATTEMPT -match '\A[0-9]+\z') { [int]$env:GITHUB_RUN_ATTEMPT } else { $null })
    $fallbackLeaves = @($leafRecords | Where-Object { $_.rendererFallbackLogs -gt 0 }).Count
    $measurements = [ordered]@{
        'suite.leavesPlanned' = $runRecord.leavesPlanned
        'suite.leavesSelected' = $runRecord.leavesSelected
        'suite.subset' = $subset
        'build.receiptSha256' = $runRecord.receiptSha256
        'build.exeSha256' = $runRecord.exeSha256
        'build.cliSha256' = $runRecord.cliSha256
        'build.conptyDllSha256' = $runRecord.conptyDllSha256
        'build.openConsoleSha256' = $runRecord.openConsoleSha256
        'build.generationUnchanged' = $runRecord.generationUnchanged
        'host.autoRunHkcu' = $runRecord.autoRunHkcu
        'host.autoRunHklm' = $runRecord.autoRunHklm
        'guards.state' = $runRecord.stateGuardHeld
        'guards.history' = $runRecord.historyGuardHeld
        'guards.startup' = $runRecord.startupUnchanged
    }
    foreach ($leafRecord in $leafRecords) {
        $measurements["$($leafRecord.leaf).passed"] = [bool]$leafRecord.passed
        if ($leafRecord.processes) { $measurements["$($leafRecord.leaf).shellsObserved"] = [int]$leafRecord.processes.shellsObserved }
        if ($leafRecord.receipt) { $measurements["$($leafRecord.leaf).realInputLoaded"] = $leafRecord.receipt.realInputLoaded }
    }
    $receipts = @($receiptNames | ForEach-Object {
        [ordered]@{ kind = 'other'; path = "receipts/$_"; sha256 = (Get-GuiHiddenHash (Join-Path $Out "receipts\$_")) }
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
        environment = [ordered]@{
            os = 'Windows'; architecture = 'x86_64'; hosted = [bool](Test-GuiHiddenHosted); desktop = 'private'
            imageOs = $runRecord.imageOs; imageVersion = $runRecord.imageVersion
            rendererConfigured = 'opengl'
            rendererFallbackLeaves = $fallbackLeaves
        }
        measurements = $measurements
        assertions = @(
            [ordered]@{ id = 'leaves-pass'; status = $leafStatus; message = $(if ($subset) { "subset run: $($selected.Count) of $($runRecord.leavesPlanned) leaves" } else { $null }) }
            [ordered]@{ id = 'launch-policy'; status = $(if ($policyPass) { 'pass' } else { 'fail' }); message = $null }
            [ordered]@{ id = 'real-input-absent'; status = $(if ($inputPass) { 'pass' } else { 'fail' }); message = $null }
            [ordered]@{ id = 'state-guards'; status = $(if ($runRecord.stateGuardsHeld) { 'pass' } else { 'fail' }); message = $null }
        )
        artifacts = $receipts
        failure = $(if ($exit -eq 0) { $null } else { [ordered]@{ message = "exit $exit ($failureKind)"; type = $status } })
    }
    [IO.File]::WriteAllText((Join-Path $Out 'result.json'), ($result | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
}
Write-Host "gui-hidden: exit $exit$(if ($failureKind) { " ($failureKind)" })"
exit $exit
