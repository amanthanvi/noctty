#requires -Version 7.2
<#
.SYNOPSIS
PLAN.md §3.5's working-set workloads: one portable copy of the receipt-bound measurement build on a private desktop
runs one fixed workload, and its private bytes and working set are sampled at each stage.

.DESCRIPTION
Run it as
  pwsh -NoProfile -File test/windows/hidden-win11-working-set.ps1 -MeasureRepo <repo with a measurement build>
       -Run <new directory> -Workload <fixed|scrollback-default|scrollback-max|uia-walk|session-capture|tab-churn>
       [-ExpectedBuildMode ReleaseFast] [-ScrollbackMaxBytes 1073741824]
once per run, with -Run outside -MeasureRepo or in a directory git ignores there (a run inside the checkout is refused
before anything is created). -MeasureRepo is a checkout whose measurement generation Invoke-InteractiveWin11MeasureBuild built
(scripts/interactive-win11-measure-lib.ps1): the harness launches only that build, after
Assert-InteractiveWin11MeasureBuild and after the copied noctty.exe and noctty.com match the receipt's hashes; any
other binary, a plain zig-out build included, is refused before anything starts. Each run is a fresh copy, a fresh
private desktop and a fresh LOCALAPPDATA, one run at a time (a session-wide mutex refuses a second).

Comparing runs. A later phase compares its working set with Phase 0a's by running the 0a measurement build and the
new one interleaved, under the same harness version, and comparing the medians of each workload's `after` stage; the
stored 0a numbers are the reference level, not the comparison. Only completed runs count (driver exit 0, every guard
unchanged, every required stage present, and every stage settled but the scrollback workloads' block-<n> samples),
and only runs whose WorkloadSha256 (the workload, its effective scrollback limit and planned blocks, the constants
below, the output block, the flood batch file and the config with the run's directory taken out), recorded grid,
transport (the bundled ConPTY) and both ConPTY bundle digests (conpty.dll and OpenConsole.exe) match.

The workloads, every one on a 140 x 43 grid (read before `start` through the pane's pseudoconsole: the config's
window-width = 140 and window-height = 45 give 43 rows on the measurement machine at 144 DPI, measured on the 0a build
and on this harness's), the shell System32's cmd.exe started directly with /D (the copy's config `command`):
  fixed               one block of output (25,000 lines), then 20 cycles of a new tab and its close; `after` 7 s
                      later (undo-timeout prunes closed panes after 5 s) and once the copy is back to its one base
                      pane (waited for, at most 30 s; the run fails otherwise), once memory settles.
  scrollback-default  4 blocks (100,000 lines) at the default scrollback-limit (10,000,000 bytes), about ten times
                      what that limit retains at this width, so the scrollback is full and recycling; a sample after
                      each block.
  scrollback-max      blocks until the output is 1.25 times what -ScrollbackMaxBytes holds at 1,120 bytes a row
                      (measured: about 44 MB of private bytes a block, so about twice the limit), with
                      scrollback-limit = -ScrollbackMaxBytes. noctty has no maximum of its own (scrollback-limit is a
                      usize); Settings' up-down stops at 2,147,483,647, which caps -ScrollbackMaxBytes. The
                      default, 1 GiB, is Phase 0a's large scrollback point; 2,147,483,647 is not measured.
  uia-walk            scrollback-default's output, then a UIA client in this driver reads the pane's whole
                      DocumentRange once and walks it line by line (TextPattern, Move by Line) to its end. It reads
                      only what UIA exposes at the bottom of the scrollback (win32_uia/text.zig
                      `accessibleHistoryRows`: min(40,000 cells / columns, 500) history rows plus the viewport, 329
                      lines here), not a scrolling walk of the whole scrollback: the window slides only with a
                      scrolled viewport (`snapshotDocumentWindow`), which this workload never scrolls. The walk is
                      complete only when it ended, the document holds the last block's last line, and the walk
                      counted the whole document: 329 lines on this grid (the history rows, the viewport and the one
                      line more a walk counts). The client finds the pane from this copy's own window handle only.
  session-capture     scrollback-default's output with window-save-state = always and
                      window-save-state-scrollback = 10000 (the session line cap), then 10 checkpoints, each a new tab
                      and its close, then a session write after the close that holds a new snapshot of the base pane
                      (a captured_at_unix_ms later than its close and the last one counted, of exactly the lines its
                      budget gives, 3,717 at 140 columns: a halved slice does not count), read from the copy's own
                      session-state.json (win32/session.zig: the capture runs TerminalFormatter over up to the line
                      cap, pre-limited by the 512 KiB snapshot budget to (budget - 96 bytes of overhead) / (columns + 1) lines, 3,717 at 140
                      columns). The only workload that saves session state, an exception to AGENTS.md's
                      --window-save-state=never: the file stays in the portable copy, and the real
                      session-state.json is guarded like startup-attempts.json.
  tab-churn           50 cycles of a new tab and its close, no output.
A block counts once the batch file acknowledged it (flood-count.txt holds its number) and the pane parsed through
its end: the batch file sets the console title to `ws-block-<n>` after the block, and the copy's window title must
show it. Every workload samples `start` (after the first pane shows and memory settles) and `after` (its end,
settled); a stage that does not settle within 90 s fails the run, as does a settled stage whose panes are not
exactly the base pane. Settled: the last 10 samples, 500 ms apart, have private bytes within 0.5% and working set
within 1% of their mean (range over mean); the stage's value is its last sample. The scrollback workloads'
block-<n> entries are the exception, by design: one immediate sample each, right after its block, not settled and
exempt from the settle and base-pane checks (the comparison uses the settled `after`).

The memory fields, all from the held noctty process handle (K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS_EX2):
private_bytes = PrivateUsage (what Windows calls the process's commit charge), working_set = WorkingSetSize,
peak_working_set = PeakWorkingSetSize, private_plus_shared_commit = PrivateUsage + SharedCommitUsage. The handle,
GDI and USER counts are null when their query failed, never 0.

Records in -Run: workingset.json (the parameters, the copy's build mode, the SHA-256 of its app, CLI and config and of
the admitted receipt, the receipt's head, the ConPTY pair's SHA-256 beside the build's, the transport its log names,
the scrollback limit it was launched with, each session checkpoint's times and line count, the
workload's SHA-256, the grid, the window's client size and DPI, the stages with every sample, the workload's counts,
the exit), version.txt (`+version`), noctty.log (the copy's stderr), driver.log, and guards.json (the outer half's
guards). The outer half declares a run complete only after it checked workingset.json (Get-WorkingSetRecordProblems).

Safety (AGENTS.md "Running noctty"; the soak's rules, test/windows/interactive-win11-soak.ps1). The outer half copies
the measurement build without noctty.ico, places `noctty.portable` beside the exe, writes the config, creates a
private desktop and a kill-on-close job, and starts this script as the driver on that desktop at normal priority,
with LOCALAPPDATA, APPDATA, TEMP and TMP redirected into the run (never for Git Bash or another msys program: nothing
here starts one). The driver re-proves that isolation before it starts anything: it runs in a job, on its own
desktop (neither Default nor the input desktop), with those four variables inside the run, and the build and the
copy check out against the receipt again. Every process the harness creates directly names the private desktop in
STARTUPINFO, and the native launches refuse any other: a child only on the driver's own desktop, the driver never on
the caller's, Default or the input desktop. The driver's re-admission runs git through the measure library, which
names no desktop; per CreateProcess such a child inherits its parent's desktop, the driver's private one (read, not
measured). The staged config must be byte for byte the harness's own for the run, and only its settings take
effect: the copy is launched with exactly the expected argument list, --config-default-files=false and
--config-file=<copy>\config.ghostty among it. noctty still reads its default config files, then discards their
settings (Config.loadCliArgs), so the settings in effect are the command line's and that file's; a staged copy
holding a legacy config (ghostty\config, winghostty\config.ghostty) is refused as well. NOCTTY_CONPTY must be unset, the
copy's conpty.dll and OpenConsole.exe must match the build's, and a run on any transport but the bundled ConPTY
fails. Input is posted,
never SendInput, and nothing takes the foreground. The copy runs with the launch helper's isolation (its own class,
--single-instance=false), the clipboard denied on the command line and in the config, every default binding
cleared, and no binding that copies. The outer half compares the real startup-attempts.json's, the real
session-state.json's and the product jump list's size and time (never their content) and the PSReadLine history's
metadata before and after, and records the clipboard sequence number before and after. Logs name kinds and sizes,
never a command line or an environment value.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [Parameter(Mandatory)] [string] $Run,
    [ValidateSet('fixed', 'scrollback-default', 'scrollback-max', 'uia-walk', 'session-capture', 'tab-churn')] [string] $Workload,
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $ExpectedBuildMode = 'ReleaseFast',
    [ValidateRange(10000000, 2147483647)] [long] $ScrollbackMaxBytes = 1073741824,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,23}$')] [string] $SandboxName,
    [switch] $Driver,
    [string] $Bin,
    [string] $DesktopName,
    # Internal: the grid probe, a child of the driver that attaches to a pane's pseudoconsole.
    [int] $GridProbePid = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
# The real startup ledger, the product jump list and the clipboard sequence: the shared state guard, which holds
# their paths and names (the job's and the validate run's guard too).
. (Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1')
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:ResponseBoundMs = 5000
# The workload's constants. A change to any of them, to New-BlockText, to the flood batch file or to the config
# changes WorkloadSha256, and runs with different WorkloadSha256 are not comparable. One block of output: lines of 82
# or 91 bytes, every seventh in an SGR colour; a 140-column row of page holds one. Cols and Rows are the config's
# window-width and window-height. GridRows is the grid's row count a run must show before `start`: what that config
# gave on the measurement machine (144 DPI), on the 0a build and on this harness's, not the configured 45 (measured
# 2026-11-20; the flagship configured-size leaf likewise accepts a configured size with a tolerance).
$script:BlockLines = 25000
$script:RowPageBytes = 1120
$script:Cols = 140
$script:Rows = 45
$script:GridRows = 43
$script:FixedCycles = 20
$script:ChurnCycles = 50
$script:SessionCheckpoints = 10
$script:PruneSeconds = 7
$script:SettleSamples = 10
$script:SampleMs = 500
$script:SettleCapMs = 90000
# What the product gives a full payload, for the payload checks (Sol, round 2). Not workload inputs, so not hashed as
# constants (SessionLineCap reaches WorkloadSha256 only through the config's window-save-state-scrollback line): the
# session capture's budget and storage overhead (win32_session_state.zig
# max_total_scrollback_bytes, scrollback_snapshot_storage_overhead), the line cap the config sets
# (window-save-state-scrollback), and the UIA document's history budget (win32_uia/text.zig
# accessible_history_target_cells, accessible_history_max_rows).
$script:SessionBudgetBytes = 524288
$script:SessionOverheadBytes = 96
$script:SessionLineCap = 10000
$script:UiaHistoryCells = 40000
$script:UiaHistoryMaxRows = 500
# psapi.h PROCESS_MEMORY_COUNTERS_EX2, processthreadsapi.h STARTUPINFOW, winnt.h JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
# tlhelp32.h PROCESSENTRY32W, and consoleapi2.h CONSOLE_SCREEN_BUFFER_INFO with wincontypes.h COORD and SMALL_RECT, on
# x64 (AGENTS.md "Win32 FFI"). None of those headers changes the packing (no pshpack), so x64's natural alignment
# holds: PROCESSENTRY32W is 564 bytes of fields padded to 568, with 4 bytes of padding before th32DefaultHeapID.
$script:SdkLayout = 'MemoryCounters=96 peakWorkingSet@8 workingSet@16 privateUsage@72 sharedCommit@88 Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8'

if (-not ('WorkingSetNative' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WorkingSetNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup info; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential)] struct MemoryCounters {
        public uint cb, pageFaults;
        public UIntPtr peakWorkingSet, workingSet, quotaPeakPaged, quotaPaged, quotaPeakNonPaged, quotaNonPaged,
            pagefile, peakPagefile, privateUsage, privateWorkingSet;
        public ulong sharedCommit;
    }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref StartupEx si, out ProcessInfo pi);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessHandleCount(IntPtr h, out uint count);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetProcessMemoryInfo(IntPtr h, ref MemoryCounters counters, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);
    [DllImport("kernel32.dll")] public static extern uint GetErrorMode();
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION (winnt.h): 144 bytes on x64, pinned by Layout().
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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr sa, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits limits, uint size);
    // The run's job, as the soak's (test-harnesses.md, 2026-11-18 SOAK-01 trap 5): its processes die when the
    // harness closes it (KILL_ON_JOB_CLOSE), and an unhandled exception ends a process instead of waiting in WER's
    // dialog (DIE_ON_UNHANDLED_EXCEPTION), whatever the process's error mode is by then.
    public static IntPtr CreateRunJob() {
        var job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Exception("CreateJobObject failed: " + Marshal.GetLastWin32Error());
        var limits = new JobLimits(); limits.basic.flags = 0x2000 | 0x400;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) {
            CloseHandle(job); throw new Exception("SetInformationJobObject failed: " + Marshal.GetLastWin32Error());
        }
        return job;
    }
    // Whether this process runs inside a job (any job).
    public static bool InJob() { bool r; return IsProcessInJob(new IntPtr(-1), IntPtr.Zero, out r) && r; }
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);

    public static string Layout() {
        return string.Join(" ", new string[] {
            "MemoryCounters=" + Marshal.SizeOf<MemoryCounters>(), "peakWorkingSet@" + Marshal.OffsetOf<MemoryCounters>("peakWorkingSet"),
            "workingSet@" + Marshal.OffsetOf<MemoryCounters>("workingSet"),
            "privateUsage@" + Marshal.OffsetOf<MemoryCounters>("privateUsage"), "sharedCommit@" + Marshal.OffsetOf<MemoryCounters>("sharedCommit"),
            "Startup=" + Marshal.SizeOf<Startup>(), "desktop@" + Marshal.OffsetOf<Startup>("desktop"),
            "flags@" + Marshal.OffsetOf<Startup>("flags"), "show@" + Marshal.OffsetOf<Startup>("show"),
            "output@" + Marshal.OffsetOf<Startup>("output"),
            "error@" + Marshal.OffsetOf<Startup>("error"), "StartupEx=" + Marshal.SizeOf<StartupEx>(),
            "attributes@" + Marshal.OffsetOf<StartupEx>("attributes"), "JobLimits=" + Marshal.SizeOf<JobLimits>(),
            "limitFlags@" + Marshal.OffsetOf<BasicLimits>("flags"),
            "ProcessEntry=" + Marshal.SizeOf<ProcessEntry>(), "processId@" + Marshal.OffsetOf<ProcessEntry>("processId"),
            "heapId@" + Marshal.OffsetOf<ProcessEntry>("heapId"), "parentProcessId@" + Marshal.OffsetOf<ProcessEntry>("parentProcessId"),
            "exeFile@" + Marshal.OffsetOf<ProcessEntry>("exeFile"),
            "ScreenBufferInfo=" + Marshal.SizeOf<ScreenBufferInfo>(), "cursor@" + Marshal.OffsetOf<ScreenBufferInfo>("cursor"),
            "wAttributes@" + Marshal.OffsetOf<ScreenBufferInfo>("attributes"), "window@" + Marshal.OffsetOf<ScreenBufferInfo>("window"),
            "maxWindow@" + Marshal.OffsetOf<ScreenBufferInfo>("maxWindow"), "Coord=" + Marshal.SizeOf<Coord>(),
            "SmallRect=" + Marshal.SizeOf<SmallRect>() });
    }
    static string NameOf(IntPtr desktop) {
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformationW(desktop, 2, name, 512, out needed)) return null;
        return name.ToString();
    }
    public static string CurrentDesktopName() {
        if (GetDesktopWindow() == IntPtr.Zero) throw new Exception("Current desktop connection failed");
        var name = NameOf(GetThreadDesktop(GetCurrentThreadId()));
        if (name == null) throw new Exception("Desktop name query failed");
        return name;
    }
    // A command line split the way the C runtime and CommandLineToArgvW split it, for reading launch values back.
    public static string[] SplitCommandLine(string commandLine) {
        int count; IntPtr argv = CommandLineToArgvW(commandLine, out count);
        if (argv == IntPtr.Zero) throw new Exception("CommandLineToArgvW failed: " + Marshal.GetLastWin32Error());
        try {
            var result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        } finally { LocalFree(argv); }
    }
    // The input desktop's name, or null when it cannot be opened or read.
    public static string InputDesktopName() {
        IntPtr h = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS
        if (h == IntPtr.Zero) return null;
        try { return NameOf(h); } finally { CloseDesktop(h); }
    }
    // The driver: suspended, assigned to the job before it runs, no console window, normal priority (no priority
    // flag: a creator at normal priority gives its child normal priority), its desktop named in STARTUPINFO.
    public static ProcessInfo LaunchDriver(string app, string command, string cwd, string desktop, IntPtr job) {
        if (string.IsNullOrEmpty(desktop)) throw new Exception("A launch must name its desktop");
        // Onto a private desktop: never the caller's own, Default or the input desktop (Opus, round 2).
        string input = InputDesktopName();
        if (input == null || string.Equals(desktop, "WinSta0\\" + CurrentDesktopName(), StringComparison.OrdinalIgnoreCase) || string.Equals(desktop, "WinSta0\\Default", StringComparison.OrdinalIgnoreCase) || string.Equals(desktop, "WinSta0\\" + input, StringComparison.OrdinalIgnoreCase))
            throw new Exception("The driver must start on a private desktop, not the caller's, Default or the input desktop");
        var si = new Startup { cb = Marshal.SizeOf<Startup>(), desktop = desktop, flags = 1, show = 0 }; ProcessInfo pi;
        if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false, 0x08000004, IntPtr.Zero, cwd, ref si, out pi))
            throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, pi.process) || ResumeThread(pi.thread) == 0xFFFFFFFF) {
            TerminateProcess(pi.process, 1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume owned driver failed");
        }
        return pi;
    }
    // A child of the driver on `desktop`, its standard output and error in `logPath` (the only handle it inherits),
    // at normal priority (0x20), with no console window (0x08000000) when `noWindow`. No STARTF_USESHOWWINDOW, so a
    // GUI window shows on its desktop.
    public static ProcessInfo Spawn(string app, string command, string cwd, string desktop, string logPath, bool noWindow) {
        if (string.IsNullOrEmpty(desktop)) throw new Exception("A launch must name its desktop");
        // Only onto the caller's own desktop, and never Default or the input desktop (Opus, round 2): the driver has
        // re-proved it runs on its private desktop, so no caller can route a child to the user's.
        string own = "WinSta0\\" + CurrentDesktopName();
        if (!string.Equals(desktop, own, StringComparison.OrdinalIgnoreCase)) throw new Exception("A child must start on the caller's own desktop");
        string input = InputDesktopName();
        if (input == null || string.Equals(desktop, "WinSta0\\Default", StringComparison.OrdinalIgnoreCase) || string.Equals(desktop, "WinSta0\\" + input, StringComparison.OrdinalIgnoreCase))
            throw new Exception("A child must not start on Default or the input desktop");
        var sa = new SecurityAttributes { length = Marshal.SizeOf<SecurityAttributes>(), inherit = 1 };
        IntPtr log = CreateFileW(logPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
        if (log == new IntPtr(-1)) throw new Exception("Creating the log file failed: " + Marshal.GetLastWin32Error());
        IntPtr list = IntPtr.Zero, handles = IntPtr.Zero;
        try {
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            list = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
            handles = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(handles, log);
            if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x20002), handles, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
            var si = new StartupEx();
            si.info.cb = Marshal.SizeOf<StartupEx>();
            si.info.desktop = desktop;
            si.info.flags = 0x100;
            si.info.output = log; si.info.error = log;
            si.attributes = list;
            ProcessInfo pi;
            if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true, 0x00080000 | 0x20 | (noWindow ? 0x08000000u : 0u), IntPtr.Zero, cwd, ref si, out pi))
                throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
            return pi;
        } finally {
            if (list != IntPtr.Zero) { DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            CloseHandle(log);
        }
    }
    public static bool Alive(IntPtr process) { return WaitForSingleObject(process, 0) == 258; }
    public static long ExitCode(IntPtr process) {
        uint code; if (!GetExitCodeProcess(process, out code)) throw new Exception("GetExitCodeProcess failed: " + Marshal.GetLastWin32Error());
        return code;
    }
    public static void Terminate(IntPtr process, uint code) { TerminateProcess(process, code); }
    // { private bytes (PrivateUsage), working set, private plus shared commit, peak working set, handles, GDI objects,
    // USER objects }. A count whose query failed is -1 (published as unavailable), never 0.
    public static long[] Sample(IntPtr process) {
        var c = new MemoryCounters(); c.cb = (uint)Marshal.SizeOf<MemoryCounters>();
        if (!K32GetProcessMemoryInfo(process, ref c, c.cb)) throw new Exception("GetProcessMemoryInfo failed: " + Marshal.GetLastWin32Error());
        uint handles; long handleCount = GetProcessHandleCount(process, out handles) ? (long)handles : -1;
        return new long[] { (long)c.privateUsage.ToUInt64(), (long)c.workingSet.ToUInt64(), (long)(c.privateUsage.ToUInt64() + c.sharedCommit),
            (long)c.peakWorkingSet.ToUInt64(), handleCount, Gui(process, 0), Gui(process, 1) };
    }
    // GetGuiResources returns 0 both for none and for a failure; a failure sets the last error.
    static long Gui(IntPtr process, uint kind) {
        Marshal.SetLastPInvokeError(0);
        uint v = GetGuiResources(process, kind);
        return v == 0 && Marshal.GetLastPInvokeError() != 0 ? -1 : (long)v;
    }
    static string Class(IntPtr h) { var s = new StringBuilder(128); GetClassNameW(h, s, 128); return s.ToString(); }
    // This copy's host windows (owner pid `pid`).
    public static IntPtr[] Hosts(int pid) {
        var list = new List<IntPtr>();
        EnumWindows((h, p) => { int id; GetWindowThreadProcessId(h, out id);
            if (id == pid && Class(h) == "noctty.win32.host") list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr[] Surfaces(IntPtr host, bool visibleOnly) {
        var list = new List<IntPtr>();
        EnumChildWindows(host, (c, p) => { if (Class(c) == "noctty.win32" && (!visibleOnly || IsWindowVisible(c))) list.Add(c); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    public static int Owner(IntPtr h) { int pid; GetWindowThreadProcessId(h, out pid); return pid; }
    // A window's caption text (internal text, read without sending a message to its thread).
    public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left, top, right, bottom; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    // { client width, client height, DPI } of a window.
    public static long[] ClientAndDpi(IntPtr h) {
        Rect r; if (!GetClientRect(h, out r)) return new long[] { -1, -1, GetDpiForWindow(h) };
        return new long[] { r.right - r.left, r.bottom - r.top, GetDpiForWindow(h) };
    }
    public static bool Responsive(IntPtr h, uint ms) {
        IntPtr result; return SendMessageTimeoutW(h, 0, IntPtr.Zero, IntPtr.Zero, 2, ms, out result) != IntPtr.Zero;
    }
    public static bool PostClose(IntPtr h, int pid) { return Owner(h) == pid && PostMessageW(h, 0x10, IntPtr.Zero, IntPtr.Zero); }
    // A key as a posted WM_KEYDOWN/WM_KEYUP pair to a window of `pid`, after clearing the keyboard state the
    // window's thread reads (the soak's Key; test-harnesses.md, 2026-11-08 trap 7).
    public static void Key(IntPtr h, int pid, int vk) {
        int owner; uint tid = GetWindowThreadProcessId(h, out owner); uint me = GetCurrentThreadId();
        if (tid == 0 || owner != pid) throw new Exception("The window is not this copy's");
        if (!AttachThreadInput(me, tid, true)) throw new Exception("AttachThreadInput failed: " + Marshal.GetLastWin32Error());
        try { if (!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed"); }
        finally { AttachThreadInput(me, tid, false); }
        if (!PostMessageW(h, 0x100, new IntPtr(vk), new IntPtr(1))) throw new Exception("Key-down post failed");
        if (!PostMessageW(h, 0x101, new IntPtr(vk), new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct ProcessEntry {
        public uint size, usage, processId; public IntPtr heapId; public uint moduleId, threads, parentProcessId;
        public int basePriority; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string exeFile;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    // The PIDs of `parent`'s children whose executable is `exe` (case-insensitive).
    public static int[] Children(int parent, string exe) {
        var list = new List<int>();
        IntPtr snap = CreateToolhelp32Snapshot(2, 0); // TH32CS_SNAPPROCESS
        if (snap == new IntPtr(-1)) throw new Exception("CreateToolhelp32Snapshot failed: " + Marshal.GetLastWin32Error());
        try {
            var e = new ProcessEntry { size = (uint)Marshal.SizeOf<ProcessEntry>() };
            for (bool ok = Process32FirstW(snap, ref e); ok; ok = Process32NextW(snap, ref e)) {
                if ((int)e.parentProcessId == parent && string.Equals(e.exeFile, exe, StringComparison.OrdinalIgnoreCase)) list.Add((int)e.processId);
                e.size = (uint)Marshal.SizeOf<ProcessEntry>();
            }
        } finally { CloseHandle(snap); }
        return list.ToArray();
    }

    [StructLayout(LayoutKind.Sequential)] struct Coord { public short x, y; }
    [StructLayout(LayoutKind.Sequential)] struct SmallRect { public short left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct ScreenBufferInfo { public Coord size, cursor; public ushort attributes; public SmallRect window; public Coord maxWindow; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleScreenBufferInfo(IntPtr output, out ScreenBufferInfo info);
    // The grid of `pid`'s console (a pane's shell, whose console is the pane's pseudoconsole): "columns,rows" from its
    // screen buffer's window, or an error word. Detaches this process from its own console first.
    public static string ConsoleGrid(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) return "attach-failed-" + Marshal.GetLastWin32Error();
        IntPtr output = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (output == new IntPtr(-1)) return "conout-failed-" + Marshal.GetLastWin32Error();
        try {
            ScreenBufferInfo info;
            if (!GetConsoleScreenBufferInfo(output, out info)) return "info-failed-" + Marshal.GetLastWin32Error();
            return (info.window.right - info.window.left + 1) + "," + (info.window.bottom - info.window.top + 1);
        } finally { CloseHandle(output); FreeConsole(); }
    }
}
'@
}

function Add-Line([string] $Path, [string] $Line) { [IO.File]::AppendAllText($Path, $Line + "`n", $script:Utf8) }

function Get-Metadata([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'absent' }
    return '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
}

function Get-Sha256([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
# One file's bytes without following a reparse point (Sol, round 5): CreateFileW with FILE_FLAG_OPEN_REPARSE_POINT,
# the opened handle refused if it is a reparse point or a directory, then the bytes read from that handle.
function Read-WorkingSetPlainFile([string] $Path) {
    if (-not ('WorkingSetPlainRead' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class WorkingSetPlainRead {
    // BY_HANDLE_FILE_INFORMATION (fileapi.h, no pshpack): 13 DWORDs, FILETIMEs as DWORD pairs, 52 bytes.
    [StructLayout(LayoutKind.Sequential)] public struct ByHandle {
        public uint attributes, createdLow, createdHigh, accessedLow, accessedHigh, writtenLow, writtenHigh;
        public uint volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandle info);
    // The mirror's size and every field's offset, checked against the SDK's before the first read (AGENTS.md "Win32 FFI").
    public static string Layout() {
        return string.Join(" ", new[] { "ByHandle=" + Marshal.SizeOf<ByHandle>(),
            "attributes@" + Marshal.OffsetOf<ByHandle>("attributes"), "createdLow@" + Marshal.OffsetOf<ByHandle>("createdLow"),
            "createdHigh@" + Marshal.OffsetOf<ByHandle>("createdHigh"), "accessedLow@" + Marshal.OffsetOf<ByHandle>("accessedLow"),
            "accessedHigh@" + Marshal.OffsetOf<ByHandle>("accessedHigh"), "writtenLow@" + Marshal.OffsetOf<ByHandle>("writtenLow"),
            "writtenHigh@" + Marshal.OffsetOf<ByHandle>("writtenHigh"), "volume@" + Marshal.OffsetOf<ByHandle>("volume"),
            "sizeHigh@" + Marshal.OffsetOf<ByHandle>("sizeHigh"), "sizeLow@" + Marshal.OffsetOf<ByHandle>("sizeLow"),
            "links@" + Marshal.OffsetOf<ByHandle>("links"), "indexHigh@" + Marshal.OffsetOf<ByHandle>("indexHigh"),
            "indexLow@" + Marshal.OffsetOf<ByHandle>("indexLow") });
    }
    public static byte[] Read(string path) {
        // GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT
        using (SafeFileHandle handle = CreateFileW(path, 0x80000000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new IOException("Opening the file failed: " + Marshal.GetLastWin32Error());
            ByHandle info;
            if (!GetFileInformationByHandle(handle, out info)) throw new IOException("Reading the opened file's attributes failed: " + Marshal.GetLastWin32Error());
            if ((info.attributes & 0x400) != 0) throw new IOException("The opened file is a reparse point.");
            if ((info.attributes & 0x10) != 0) throw new IOException("The opened file is a directory.");
            using (var stream = new FileStream(handle, FileAccess.Read))
            using (var bytes = new MemoryStream()) { stream.CopyTo(bytes); return bytes.ToArray(); }
        }
    }
}
'@
    }
    # fileapi.h BY_HANDLE_FILE_INFORMATION on x64 (no pshpack; FILETIME is two DWORDs, low then high).
    $wantLayout = 'ByHandle=52 attributes@0 createdLow@4 createdHigh@8 accessedLow@12 accessedHigh@16 writtenLow@20 writtenHigh@24 volume@28 sizeHigh@32 sizeLow@36 links@40 indexHigh@44 indexLow@48'
    if (-not [string]::Equals([WorkingSetPlainRead]::Layout(), $wantLayout, [StringComparison]::Ordinal)) { throw "The no-follow read's struct does not match the SDK's x64 layout: $([WorkingSetPlainRead]::Layout())" }
    return [WorkingSetPlainRead]::Read($Path)
}
function Get-BytesSha256([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# The receipt-bound measurement build of -MeasureRepo, admitted the way Assert-InteractiveWin11MeasureBuild admits it
# (its generation, receipt, source patch and executable), with the prefix's noctty.exe and noctty.com matching the
# receipt's hashes. Throws for anything else: a repository with only a plain zig-out build has no generation, so it
# is refused before anything starts.
function Get-WorkingSetMeasureBuild([string] $Repo) {
    if ([string]::IsNullOrWhiteSpace($Repo)) { throw 'Pass -MeasureRepo: only a receipt-bound measurement build is launched.' }
    $Repo = (Resolve-Path -LiteralPath $Repo).Path
    $exe = Get-InteractiveWin11MeasureExePath -RepoRoot $Repo
    $layout = Get-InteractiveWin11MeasureLayout $Repo
    # One admitted receipt (Sol, round 4; CodeRabbit on #739): its bytes are read once, under the generation's build
    # lock held across the library's admission (a builder needs that lock exclusively to replace the receipt), and
    # must still be the receipt on disk when the admission has passed; that second read only compares. The fields,
    # the hashes checked below and the recorded digest all come from the one read. Before anything opens the receipt,
    # its path is checked as the library checks it: inside the measure repo, no reparse point anywhere on it; the
    # read itself does not follow one and re-checks the opened handle (Sol, round 5).
    Assert-InteractiveWin11MeasurePlainPath $layout.Root
    Assert-InteractiveWin11MeasurePlainPath (Join-Path $layout.Root 'build.lock')
    $lock = [IO.File]::Open((Join-Path $layout.Root 'build.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if (-not ([IO.Path]::GetFullPath($layout.Receipt)).StartsWith($layout.Repo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The measurement receipt is not inside the measure repo.' }
        Assert-InteractiveWin11MeasurePlainPath $layout.Receipt
        $receiptBytes = Read-WorkingSetPlainFile $layout.Receipt
        Assert-InteractiveWin11MeasureBuild -RepoRoot $Repo -ExePath $exe
        $receiptAfter = Read-WorkingSetPlainFile $layout.Receipt
    } finally { $lock.Dispose() }
    if (-not [string]::Equals([Convert]::ToBase64String($receiptBytes), [Convert]::ToBase64String($receiptAfter), [StringComparison]::Ordinal)) { throw 'The measurement receipt changed during admission.' }
    $receipt = [Text.Encoding]::UTF8.GetString($receiptBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $cli = Join-Path (Split-Path -Parent $exe) 'noctty.com'
    if (-not [string]::Equals((Get-Sha256 $exe), [string]$receipt.ExeSHA256, [StringComparison]::Ordinal) -or -not [string]::Equals((Get-Sha256 $cli), [string]$receipt.CliSHA256, [StringComparison]::Ordinal)) {
        throw 'The measurement build does not match its receipt.'
    }
    return [pscustomobject]@{ Repo = $Repo; Bin = Split-Path -Parent $exe; Head = [string]$receipt.Head; ExeSha256 = [string]$receipt.ExeSHA256; CliSha256 = [string]$receipt.CliSHA256; Optimize = [string]$receipt.Optimize; ReceiptSha256 = Get-BytesSha256 $receiptBytes }
}

# Whether a copy's noctty.exe and noctty.com are the admitted build's bytes.
function Test-WorkingSetCopy([string] $Copy, $Build) {
    foreach ($pair in @(@('noctty.exe', $Build.ExeSha256), @('noctty.com', $Build.CliSha256))) {
        $path = Join-Path $Copy $pair[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or -not [string]::Equals((Get-Sha256 $path), [string]$pair[1], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

# A -Run inside -MeasureRepo would leave untracked files in the checkout whose clean state the measurement build's
# provenance needs (the driver's admission would then refuse the run), so it is refused before anything is created,
# unless git ignores it (CodeRabbit on #739; the rule #738 has for its -Work).
function Assert-WorkingSetRunPlacement([string] $Run, [string] $Repo) {
    $Run = $Run.TrimEnd('\'); $Repo = $Repo.TrimEnd('\')
    if (-not ($Run + '\').StartsWith($Repo + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
    $relative = if ($Run.Length -gt $Repo.Length) { $Run.Substring($Repo.Length + 1) } else { '.' }
    & git -C $Repo check-ignore -q --no-index -- $relative 2>$null
    if ($LASTEXITCODE -ne 0) { throw '-Run is inside -MeasureRepo and git does not ignore it; choose a -Run outside the checkout or in a directory git ignores.' }
}

# The copy's config for a run, exactly: what the outer half writes and what the driver requires byte for byte before
# its first launch, so an initial-command or a second command, in any spelling, cannot change the first pane's shell
# (Sol, round 2). The run's directory appears only in working-directory, a value noctty passes to CreateProcess
# (it expands only a leading ~/): F5 types `.\flood.cmd`, relative to the pane's working directory, so the run's path
# never reaches cmd's parser, where a %USERNAME%, ^ or & in it would be expanded or reinterpreted (CodeRabbit on #739).
function New-WorkingSetConfigText([string] $Workload, [string] $Run) {
    $work = Join-Path $Run 'work'
    $floodText = '.\\flood.cmd\r'
    $bindings = [ordered]@{ f2 = 'new_tab'; f5 = "text:$floodText"; f6 = 'close_surface'; f7 = 'close_tab' }
    $chords = @('', 'shift+', 'ctrl+', 'alt+', 'ctrl+shift+', 'alt+shift+', 'ctrl+alt+', 'ctrl+alt+shift+')
    $saveScrollback = if ($Workload -eq 'session-capture') { $script:SessionLineCap } else { 0 }
    $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $lines = @(
        "command = direct:$cmdPath /D"
        'auto-update = off'
        'confirm-close-surface = false'
        'desktop-notifications = false'
        'clipboard-read = deny'
        'clipboard-write = deny'
        'copy-on-select = false'
        "window-width = $($script:Cols)"
        "window-height = $($script:Rows)"
        "window-save-state-scrollback = $saveScrollback"
        "working-directory = $work"
        'keybind = clear'
        foreach ($key in $bindings.Keys) { foreach ($chord in $chords) { "keybind = $chord$key=$($bindings[$key])" } }
    )
    return ($lines -join "`n") + "`n"
}

# The default config files portable mode would also read under a copy (src/config/file_load.zig: the legacy
# ghostty/config and the pre-rename winghostty/config.ghostty, rooted at the portable root by src/os/xdg.zig
# portablePath). The copy reads the default files and then discards their settings (--config-default-files=false),
# so only the generated file's settings take effect; a staged copy holding either is refused as well (Sol, round 3).
function Get-WorkingSetStrayConfigs([string] $Copy) {
    return @(@('ghostty\config', 'winghostty\config.ghostty') | Where-Object { Test-Path -LiteralPath (Join-Path $Copy $_) })
}

# What an argv says about the copy's scrollback limit and config: every --scrollback-limit, --config-default-files and
# --config-file in it (Opus and Sol, round 3).
function Get-WorkingSetLaunchValues([string[]] $Argv) {
    return [pscustomobject]@{
        ScrollbackLimits = @($Argv | Where-Object { $_ -like '--scrollback-limit=*' } | ForEach-Object { $_.Substring(19) })
        DefaultFiles = @($Argv | Where-Object { $_ -like '--config-default-files*' })
        ConfigFiles = @($Argv | Where-Object { $_ -like '--config-file*' } | ForEach-Object { if ($_ -like '--config-file=*') { $_.Substring(14) } else { $_ } })
    }
}

# The copy's exact argv for a run (Sol, round 4): the launch helper's containment and isolation arguments
# (scripts/interactive-win11-lib.ps1), then the harness's own, in this order and nothing else. The final command
# line and the copy's real one by PID must each split into exactly this list, so an extra option (a CLI
# initial-command) or a malformed value cannot get through.
function Get-WorkingSetExpectedArgv([string] $Exe, [string] $Class, [string] $SaveState, [string] $ConfigPath, [long] $Limit) {
    return [string[]]@($Exe, '--linux-cgroup=always', '--linux-cgroup-hard-fail=true', '--windows-job-object-kill-on-close=true',
        '--single-instance=false', "--class=$Class", "--window-save-state=$SaveState", '--clipboard-read=deny', '--clipboard-write=deny',
        '--config-default-files=false', "--config-file=$ConfigPath", "--scrollback-limit=$Limit")
}

# Whether an argv is exactly the expected one: the same arguments, in the same order, compared ordinally.
function Test-WorkingSetArgv([string[]] $Actual, [string[]] $Expected) {
    if ($null -eq $Actual -or $Actual.Count -ne $Expected.Count) { return $false }
    for ($i = 0; $i -lt $Expected.Count; $i++) { if (-not [string]::Equals($Actual[$i], $Expected[$i], [StringComparison]::Ordinal)) { return $false } }
    return $true
}

# Whether a staged config is byte for byte New-WorkingSetConfigText's for this run.
function Test-WorkingSetConfigBytes([string] $Path, [string] $Workload, [string] $Run) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $staged = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    $expected = [Convert]::ToBase64String($script:Utf8.GetBytes((New-WorkingSetConfigText $Workload $Run)))
    return [string]::Equals($staged, $expected, [StringComparison]::Ordinal)
}

# A file another process may still hold open for writing (the copy's log), read whole; empty when absent.
function Read-SharedText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { return [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
}

# The payload the product gives a full checkpoint and a full walk on the expected grid (Sol, round 2): a session
# snapshot pre-limited by its budget to (budget - overhead) / (columns + 1) lines, at most the line cap (3,717 at 140
# columns; the formatter's retry halves it, which must not count), and a UIA document of the history rows plus the
# viewport, which a walk by line counts with one line more at its end (329 at 140 x 43, in every run measured).
function Get-ExpectedSessionLines {
    return [int][Math]::Min($script:SessionLineCap, [Math]::Floor(($script:SessionBudgetBytes - $script:SessionOverheadBytes) / ($script:Cols + 1)))
}
function Get-ExpectedUiaLines {
    return [int]([Math]::Min([Math]::Floor($script:UiaHistoryCells / $script:Cols), $script:UiaHistoryMaxRows) + $script:GridRows + 1)
}

# The workload's name exactly as one of the six, compared ordinally (Sol, round 5: a culture-aware comparison skips a
# soft hyphen), so every later comparison of it is between exact literals.
function Assert-WorkingSetWorkloadName([string] $Name) {
    if (@('fixed', 'scrollback-default', 'scrollback-max', 'uia-walk', 'session-capture', 'tab-churn' | Where-Object { [string]::Equals($_, $Name, [StringComparison]::Ordinal) }).Count -ne 1) {
        throw 'The workload must be exactly one of the six names.'
    }
}

# One block of output, deterministic: 25,000 lines of 82 or 91 bytes, every seventh in an SGR colour.
function New-BlockText {
    $builder = [Text.StringBuilder]::new(2400000)
    $esc = [char]27
    for ($i = 0; $i -lt $script:BlockLines; $i++) {
        $text = 'ws line {0:D6} the quick brown fox jumps over the lazy dog 0123456789 abcdefghij' -f $i
        if ($i % 7 -eq 0) { [void]$builder.Append("$esc[3$(1 + $i % 6)m$text$esc[0m`r`n") } else { [void]$builder.Append("$text`r`n") }
    }
    return $builder.ToString()
}

# The flood batch file: the block, then the console title `ws-block-<n>` (n read from next-block.txt, which the
# driver writes before each block; `set /p` reads it without a child cmd), then the acknowledgement line. ASCII only,
# its paths from its own location (%~dp0), as the soak's; one statement a line, so %n% expands after `set /p` ran.
function New-FloodCmdText {
    return (@(
            '@type "%~dp0block.txt" || exit /b 1'
            '@set /p n=<"%~dp0next-block.txt"'
            '@title ws-block-%n%'
            '@echo block>>"%~dp0flood-count.txt"'
        ) -join "`r`n") + "`r`n"
}

# How many blocks a workload writes (each acknowledged before the next).
function Get-WorkloadBlocks([string] $Name, [long] $MaxBytes) {
    switch ($Name) {
        'fixed' { return 1 }
        'scrollback-default' { return 4 }
        'uia-walk' { return 4 }
        'session-capture' { return 4 }
        'tab-churn' { return 0 }
        'scrollback-max' { return [int][Math]::Ceiling(1.25 * $MaxBytes / $script:RowPageBytes / $script:BlockLines) }
    }
}

# The stages a completed run of a workload holds, in order (the per-block samples of the scrollback cases included).
function Get-WorkloadStages([string] $Name, [int] $BlocksPlanned) {
    switch ($Name) {
        'fixed' { return @('start', 'after') }
        'tab-churn' { return @('start', 'after') }
        'uia-walk' { return @('start', 'filled', 'after') }
        'session-capture' { return @('start', 'filled', 'after') }
        'scrollback-default' { return @('start') + @(1..$BlocksPlanned | ForEach-Object { "block-$_" }) + @('after') }
        'scrollback-max' { return @('start') + @(1..$BlocksPlanned | Where-Object { $_ % 8 -eq 0 -or $_ -eq $BlocksPlanned } | ForEach-Object { "block-$_" }) + @('after') }
    }
}

# The workload's identity: SHA-256 over the workload, its scrollback limit and its planned blocks, the constants,
# the block's and the flood batch file's SHA-256 and the config with the run's own directory written as <run>: it now
# appears only in working-directory; the escaped form is still taken out because configs before the relative F5
# binding carried it there, so Phase 0a's configs hash as they did. Runs compare only when it matches.
function Get-WorkloadSha256([string] $Name, [long] $ScrollbackLimitBytes, [int] $BlocksPlanned, [string] $BlockSha256, [string] $FloodSha256, [string] $ConfigPath, [string] $RunRoot) {
    $root = $RunRoot.TrimEnd('\')
    $config = ([IO.File]::ReadAllLines($ConfigPath) -join "`n").Replace($root.Replace('\', '\\'), '<run>').Replace($root, '<run>')
    $constants = 'workload={11} scrollback={12} blocks={13} cols={0} rows={1} grid={0}x{14} block={2} rowpage={3} fixed={4} churn={5} checkpoints={6} prune={7} settle={8}x{9}ms cap={10} rule=0.005/0.01' -f `
        $script:Cols, $script:Rows, $script:BlockLines, $script:RowPageBytes, $script:FixedCycles, $script:ChurnCycles,
        $script:SessionCheckpoints, $script:PruneSeconds, $script:SettleSamples, $script:SampleMs, $script:SettleCapMs,
        $Name, $ScrollbackLimitBytes, $BlocksPlanned, $script:GridRows
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes("$constants`n$BlockSha256`n$FloodSha256`n$config"))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# The settled value of a series of samples: done when the last $script:SettleSamples (10, 500 ms apart: about 4.5 s)
# have private bytes within 0.5% and working set within 1% of their mean. Pure, so the contract can run it.
function Test-Settled([object[]] $Samples) {
    if ($Samples.Count -lt $script:SettleSamples) { return $false }
    $last = @($Samples | Select-Object -Last $script:SettleSamples)
    foreach ($field in 'private_bytes', 'working_set') {
        $values = @($last | ForEach-Object { [double]$_.$field })
        $mean = ($values | Measure-Object -Average).Average
        $limit = if ($field -eq 'private_bytes') { 0.005 } else { 0.01 }
        if ($mean -le 0) { return $false }
        if ((($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum) / $mean -gt $limit) { return $false }
    }
    return $true
}

# What keeps a run's record from counting, as a list (empty: the run counts). The outer half runs it on
# workingset.json before it declares the run complete. Pure, so the contract can run it.
function Get-WorkingSetRecordProblems($Record) {
    $problems = [Collections.Generic.List[string]]::new()
    if ($null -eq $Record) { return @('no record') }
    if ($Record.Schema -ne 2) { $problems.Add("schema $($Record.Schema)") }
    if ($Record.Error) { $problems.Add("error: $($Record.Error)") }
    if ($Record.Exit -ne 0) { $problems.Add("exit $($Record.Exit)") }
    if ($Record.QuitPosts -lt 1) { $problems.Add('no close post took') }
    if ($Record.GridCols -ne $script:Cols -or $Record.GridRows -ne $script:GridRows) { $problems.Add("grid $($Record.GridCols)x$($Record.GridRows)") }
    if ($Record.Blocks -ne $Record.BlocksPlanned -or $Record.BlocksPlanned -ne (Get-WorkloadBlocks $Record.Workload $Record.ScrollbackLimitBytes)) { $problems.Add("blocks $($Record.Blocks) of $($Record.BlocksPlanned)") }
    $wantCycles = switch ($Record.Workload) { 'fixed' { $script:FixedCycles } 'tab-churn' { $script:ChurnCycles } 'session-capture' { $script:SessionCheckpoints } default { 0 } }
    if ($Record.Cycles -ne $wantCycles -or $Record.CyclesMissed -ne 0) { $problems.Add("cycles $($Record.Cycles) of $wantCycles, $($Record.CyclesMissed) missed") }
    if ($Record.Workload -eq 'session-capture' -and $Record.SessionSaves -ne $script:SessionCheckpoints) { $problems.Add("session snapshots $($Record.SessionSaves)") }
    if ($Record.Workload -eq 'session-capture') {
        # Each counted snapshot was taken after its close and after the one before it.
        $pairs = @($Record.SessionSnapshots)
        if ($pairs.Count -ne $Record.SessionSaves) { $problems.Add("session snapshot times $($pairs.Count) for $($Record.SessionSaves) snapshots") }
        $last = [uint64]0
        $expectedLines = Get-ExpectedSessionLines
        foreach ($pair in $pairs) {
            if ([uint64]$pair.snapshot_at_unix_ms -le [uint64]$pair.close_at_unix_ms -or [uint64]$pair.snapshot_at_unix_ms -le $last) { $problems.Add('a session snapshot not after its close and the one before'); break }
            if ([int]$pair.lines -ne $expectedLines -or [int]$pair.fixture_lines -lt $expectedLines - 10) { $problems.Add("a session snapshot of $($pair.lines) lines ($($pair.fixture_lines) the fixture's), not $expectedLines"); break }
            $last = [uint64]$pair.snapshot_at_unix_ms
        }
    }
    if ($Record.Workload -eq 'uia-walk') {
        $expectedLines = Get-ExpectedUiaLines
        if ($null -eq $Record.Uia -or -not $Record.Uia.walk_complete -or -not $Record.Uia.walk_ended -or -not $Record.Uia.holds_last_line -or [int]$Record.Uia.walked_lines -ne $expectedLines) {
            $problems.Add("UIA walk incomplete: $($Record.Uia.walked_lines) lines of $expectedLines")
        }
    }
    if (-not [string]::Equals([string]$Record.Transport, 'bundled', [StringComparison]::Ordinal)) { $problems.Add("transport $($Record.Transport)") }
    if ($Record.LaunchConfigDefaultFiles -ne $false -or -not $Record.LaunchConfigFile) { $problems.Add('the copy was not launched with only the generated config') }
    if (-not $Record.ConptyDllSHA256 -or -not [string]::Equals([string]$Record.ConptyDllSHA256, [string]$Record.PrefixConptyDllSHA256, [StringComparison]::Ordinal) -or -not $Record.OpenConsoleSHA256 -or -not [string]::Equals([string]$Record.OpenConsoleSHA256, [string]$Record.PrefixOpenConsoleSHA256, [StringComparison]::Ordinal)) {
        $problems.Add('the ConPTY pair is not the build''s')
    }
    $want = @(Get-WorkloadStages $Record.Workload $Record.BlocksPlanned)
    $got = @($Record.Stages | ForEach-Object { $_.name })
    if (-not [string]::Equals(($want -join ','), ($got -join ','), [StringComparison]::Ordinal)) { $problems.Add("stages $($got -join ',') not $($want -join ',')") }
    foreach ($stage in @($Record.Stages | Where-Object { $_.name -notlike 'block-*' })) {
        if (-not $stage.settled) { $problems.Add("stage $($stage.name) not settled") }
        if (-not $stage.base_pane_only) { $problems.Add("stage $($stage.name) not at the base pane alone") }
    }
    return $problems.ToArray()
}

# The grid probe: a child of the driver, on its desktop, that attaches to a pane's shell's console (the pane's
# pseudoconsole) and writes "columns,rows" to -Run's grid.txt.
if ($GridProbePid -gt 0) {
    [IO.File]::WriteAllText((Join-Path $Run 'grid.txt'), [WorkingSetNative]::ConsoleGrid([uint32]$GridProbePid))
    exit 0
}

# ---------------------------------------------------------------------------------------------------------
# The driver: on the private desktop, inside the job, with the environment redirected.
# ---------------------------------------------------------------------------------------------------------
function Invoke-WorkingSetDriver {
    $driverLog = Join-Path $Run 'driver.log'
    function Log([string] $Message) { Add-Line $driverLog ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) }
    # The record's lists, built as List[object], become plain arrays before anything reads or writes the record, so
    # the verdict's @($Record.<list>) does not depend on how a PowerShell version wraps a List (Greptile on #739).
    function ConvertTo-RecordArrays {
        foreach ($name in @('Stages', 'SessionSnapshots')) {
            if ($record[$name] -is [Collections.Generic.List[object]]) { $record[$name] = [object[]]$record[$name].ToArray() }
        }
    }
    $record = [ordered]@{
        Schema = 2; Workload = $Workload; ExpectedBuildMode = $ExpectedBuildMode; BuildMode = $null; MeasureHead = $null
        ScrollbackLimitBytes = $null; Blocks = 0; BlocksPlanned = 0; BlockLines = $script:BlockLines
        Cols = $script:Cols; Rows = $script:Rows; GridCols = $null; GridRows = $null
        Class = $null; ExeSHA256 = $null; DriverPriority = $null; NocttyPriority = $null
        WorkloadSha256 = $null; BlockSha256 = $null; FloodSha256 = $null; ClientWidth = $null; ClientHeight = $null; Dpi = $null
        Cycles = 0; CyclesMissed = 0; SessionSaves = 0; SessionFileBytes = $null; SessionLines = $null; Uia = $null
        SessionSnapshots = [Collections.Generic.List[object]]::new()
        LaunchScrollbackLimit = $null; LaunchConfigDefaultFiles = $null; LaunchConfigFile = $null; ConfigSHA256 = $null; CliSHA256 = $null; ReceiptSHA256 = $null; Transport = $null
        ConptyDllSHA256 = $null; PrefixConptyDllSHA256 = $null; OpenConsoleSHA256 = $null; PrefixOpenConsoleSHA256 = $null
        EffectiveDirs = $null; Stages = [Collections.Generic.List[object]]::new(); QuitPosts = 0; Exit = $null; Error = $null
    }
    $recordPath = Join-Path $Run 'workingset.json'
    $process = [IntPtr]::Zero
    try {
        # Normal priority for the measurement (the outer half creates this process without a priority flag).
        Assert-WorkingSetWorkloadName $Workload
        (Get-Process -Id $PID).PriorityClass = 'Normal'
        $record.DriverPriority = [string](Get-Process -Id $PID).PriorityClass
        if (-not [string]::Equals([WorkingSetNative]::Layout(), $script:SdkLayout, [StringComparison]::Ordinal)) { throw "The mirrored structs do not match the SDK's x64 layout: $([WorkingSetNative]::Layout())" }
        # The driver's own admission, before it starts anything: it takes nothing on trust from its caller. It must
        # run in a job, on its own desktop (neither Default nor the input desktop), with LOCALAPPDATA, APPDATA, TEMP
        # and TMP inside the run, and the build and the copy must check out against the receipt again.
        $own = [WorkingSetNative]::CurrentDesktopName()
        $inputDesktop = [WorkingSetNative]::InputDesktopName()
        if (-not [string]::Equals($own, $DesktopName, [StringComparison]::Ordinal) -or -not $own.StartsWith('noctty-ws-', [StringComparison]::Ordinal)) { throw 'The driver is not on its private desktop.' }
        if ([string]::Equals($own, 'Default', [StringComparison]::OrdinalIgnoreCase)) { throw 'The driver is on Default.' }
        if ($null -eq $inputDesktop) { throw 'The input desktop is unreadable.' }
        if ([string]::Equals($own, $inputDesktop, [StringComparison]::OrdinalIgnoreCase)) { throw 'The driver is on the input desktop.' }
        if (-not [WorkingSetNative]::InJob()) { throw 'The driver is in no job.' }
        $runPrefix = [IO.Path]::GetFullPath($Run).TrimEnd('\') + '\'
        $effective = [ordered]@{}
        foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace($value) -or -not ([IO.Path]::GetFullPath($value).TrimEnd('\') + '\').StartsWith($runPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$name is not inside the run."
            }
            $effective[$name] = [IO.Path]::GetFullPath($value)
        }
        $record.EffectiveDirs = $effective
        # The bundled ConPTY only (Sol, round 2): an inherited NOCTTY_CONPTY would move the copy to another host.
        if ($null -ne [Environment]::GetEnvironmentVariable('NOCTTY_CONPTY')) { throw 'NOCTTY_CONPTY is set; the copy would not run on the bundled ConPTY.' }
        # What it launches is the staged copy: the run's own copy directory, the portable marker, no noctty.ico, the
        # harness's config, and the measurement build's bytes.
        if (-not [string]::Equals([IO.Path]::GetFullPath($Bin).TrimEnd('\'), (Join-Path $runPrefix 'copy'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The copy is not the run''s own copy directory.' }
        if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $Bin 'noctty.ico'))) { throw 'The copy is not a portable copy without noctty.ico.' }
        $config = @([IO.File]::ReadAllLines((Join-Path $Bin 'config.ghostty')))
        foreach ($wanted in @('keybind = clear', 'clipboard-read = deny', 'clipboard-write = deny', 'copy-on-select = false', 'auto-update = off')) {
            if (@($config | Where-Object { [string]::Equals($_, $wanted, [StringComparison]::Ordinal) }).Count -eq 0) { throw "The copy's config is not the harness's (no '$wanted')." }
        }
        # Byte for byte the harness's own config for this run (New-WorkingSetConfigText), before the first launch: an
        # initial-command or a second command, in any spelling, would change the first pane's shell (Sol, round 2).
        if (-not (Test-WorkingSetConfigBytes (Join-Path $Bin 'config.ghostty') $Workload $Run)) { throw "The copy's config is not byte for byte the harness's for this run." }
        $record.ConfigSHA256 = Get-Sha256 (Join-Path $Bin 'config.ghostty')
        $stray = @(Get-WorkingSetStrayConfigs $Bin); if ($stray.Count -gt 0) { throw "The copy holds another config file ($($stray -join ', ')), which the app's default search would read." }
        $build = Get-WorkingSetMeasureBuild $MeasureRepo
        if (-not (Test-WorkingSetCopy $Bin $build)) { throw "The copy's noctty.exe or noctty.com is not the measurement build's." }
        $record.MeasureHead = $build.Head
        $record.CliSHA256 = Get-Sha256 (Join-Path $Bin 'noctty.com')
        $record.ReceiptSHA256 = $build.ReceiptSha256
        # The ConPTY pair the copy loads is the measurement build's, byte for byte (Sol, round 2).
        foreach ($file in @(@('conpty.dll', 'ConptyDllSHA256'), @('OpenConsole.exe', 'OpenConsoleSHA256'))) {
            $staged = Join-Path $Bin $file[0]; $built = Join-Path $build.Bin $file[0]
            if (-not (Test-Path -LiteralPath $staged -PathType Leaf) -or -not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "The copy or the build has no $($file[0])." }
            $record[$file[1]] = Get-Sha256 $staged
            $record['Prefix' + $file[1]] = Get-Sha256 $built
            if (-not [string]::Equals([string]$record[$file[1]], [string]$record['Prefix' + $file[1]], [StringComparison]::Ordinal)) { throw "The copy's $($file[0]) is not the measurement build's." }
        }
        $desktopPath = "WinSta0\$DesktopName"
        $exe = Join-Path $Bin 'noctty.exe'
        $work = Join-Path $Run 'work'
        $record.ExeSHA256 = Get-Sha256 $exe
        $record.BlockSha256 = Get-Sha256 (Join-Path $work 'block.txt')
        $record.FloodSha256 = Get-Sha256 (Join-Path $work 'flood.cmd')

        $versionPath = Join-Path $Run 'version.txt'
        $check = [WorkingSetNative]::Spawn($exe, ('"{0}" +version' -f $exe), $work, $desktopPath, $versionPath, $false)
        try {
            if ([WorkingSetNative]::WaitForSingleObject($check.process, 60000) -ne 0) { [WorkingSetNative]::Terminate($check.process, 1); throw '+version did not finish in 60 s.' }
            $versionExit = [WorkingSetNative]::ExitCode($check.process)
        } finally { [void][WorkingSetNative]::CloseHandle($check.thread); [void][WorkingSetNative]::CloseHandle($check.process) }
        $modeMatch = [regex]::Match([IO.File]::ReadAllText($versionPath), '(?m)^\s*-\s*build mode\s*:\s*(?:[A-Za-z_.]*\.)?(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)\s*$')
        if ($versionExit -ne 0 -or -not $modeMatch.Success) { throw "noctty +version exited $versionExit with no build mode line." }
        $record.BuildMode = $modeMatch.Groups[1].Value
        if (-not [string]::Equals([string]$record.BuildMode, $ExpectedBuildMode, [StringComparison]::Ordinal) -or -not [string]::Equals([string]$build.Optimize, $ExpectedBuildMode, [StringComparison]::Ordinal)) { $record.Error = 'BUILD-MODE'; Log "build mode $($record.BuildMode); not launched"; return 3 }

        $saveState = if ($Workload -eq 'session-capture') { 'always' } else { 'never' }
        $record.ScrollbackLimitBytes = if ($Workload -eq 'scrollback-max') { $ScrollbackMaxBytes } else { 10000000 }
        # The shell is the config's `command` (System32's cmd.exe run directly with /D, so no cmd AutoRun runs);
        # the command line carries none.
        $configCommands = @([IO.File]::ReadAllLines((Join-Path $Bin 'config.ghostty')) | Where-Object { $_ -match '^\s*(initial-)?command\s*=' })
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        if ($configCommands.Count -ne 1 -or -not [string]::Equals($configCommands[0], "command = direct:$cmdPath /D", [StringComparison]::Ordinal)) { throw "The copy's config must set exactly one command, System32's cmd.exe with /D, and no initial-command." }
        $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName $SandboxName
        $launchArguments = @(Get-InteractiveWin11LaunchArguments -Layout $layout -UseConfiguredCommand) + @(
            "--window-save-state=$saveState", '--clipboard-read=deny', '--clipboard-write=deny',
            '--config-default-files=false', "--config-file=$(Join-Path $Bin 'config.ghostty')",
            "--scrollback-limit=$($record.ScrollbackLimitBytes)")
        $class = @($launchArguments | Where-Object { $_ -like '--class=*' } | ForEach-Object { $_.Substring(8) })
        if ($class.Count -ne 1) { throw 'The launch helper gave no single --class.' }
        if (@($launchArguments | Where-Object { $_ -like '--command=*' -or $_ -eq '-e' }).Count -ne 0) { throw 'The command line must not set the shell.' }
        foreach ($argument in $launchArguments) { if ($argument -match '"' -or $argument.EndsWith('\')) { throw 'A launch argument cannot be quoted.' } }
        $record.Class = $class[0]
        $commandLine = ('"{0}" ' -f $exe) + (@($launchArguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
        # The copy's argv, exactly (Sol, round 4): the final command line must split into the expected list, the
        # helper's arguments and the harness's in order and nothing else (the workload's limit,
        # --config-default-files=false and the generated config among them; Opus and Sol, round 3), or nothing
        # starts. The record and the workload hash take their values from it.
        $expectedArgv = Get-WorkingSetExpectedArgv $exe "noctty-interactive-$($layout.SandboxId)" $saveState (Join-Path $Bin 'config.ghostty') $record.ScrollbackLimitBytes
        if (-not (Test-WorkingSetArgv ([WorkingSetNative]::SplitCommandLine($commandLine)) $expectedArgv)) { throw "The copy's command line is not exactly the expected argument list." }
        $planned = Get-WorkingSetLaunchValues $expectedArgv
        $record.LaunchScrollbackLimit = [long]@($planned.ScrollbackLimits)[0]
        $record.LaunchConfigDefaultFiles = $false
        $record.LaunchConfigFile = @($planned.ConfigFiles)[0]
        $record.BlocksPlanned = Get-WorkloadBlocks $Workload $record.LaunchScrollbackLimit
        $record.WorkloadSha256 = Get-WorkloadSha256 $Workload $record.LaunchScrollbackLimit $record.BlocksPlanned $record.BlockSha256 $record.FloodSha256 (Join-Path $Bin 'config.ghostty') $Run
        [void][WorkingSetNative]::SetErrorMode([WorkingSetNative]::GetErrorMode() -bor 2)   # SEM_NOGPFAULTERRORBOX, inherited
        $env:GHOSTTY_LOG = 'stderr'
        $pi = [WorkingSetNative]::Spawn($exe, $commandLine, $work, $desktopPath, (Join-Path $Run 'noctty.log'), $false)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = $pi.process
        [void][WorkingSetNative]::CloseHandle($pi.thread)
        $nocttyPid = $pi.pid
        # And what the copy really received, from its own command line by PID (as #738 reads a shell's): exactly the
        # same list, or the run stops. The command line itself is never logged or recorded.
        $launchedLine = [string](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $nocttyPid" -ErrorAction Stop).CommandLine
        if (-not (Test-WorkingSetArgv ([WorkingSetNative]::SplitCommandLine($launchedLine)) $expectedArgv)) { throw 'The copy was not launched with exactly the expected argument list.' }
        $launchedLine = $null
        try { $record.NocttyPriority = [string](Get-Process -Id $nocttyPid -ErrorAction Stop).PriorityClass } catch { $record.NocttyPriority = 'unknown' }
        if (-not [string]::Equals([string]$record.NocttyPriority, 'Normal', [StringComparison]::Ordinal)) { throw "The copy runs at $($record.NocttyPriority) priority, not Normal." }
        Log "launched, workload $Workload, build mode $($record.BuildMode), save state $saveState, scrollback $($record.ScrollbackLimitBytes)"

        function Get-Hosts { return @([WorkingSetNative]::Hosts($nocttyPid)) }
        function Get-AllSurfaces([bool] $VisibleOnly) { $list = @(); foreach ($h in Get-Hosts) { $list += @([WorkingSetNative]::Surfaces($h, $VisibleOnly)) }; return $list }
        function Wait-For([scriptblock] $Predicate, [int] $Ms) {
            $deadline = $clock.ElapsedMilliseconds + $Ms
            do {
                if (& $Predicate) { return $true }
                if (-not [WorkingSetNative]::Alive($process)) { return $false }
                Start-Sleep -Milliseconds 100
            } while ($clock.ElapsedMilliseconds -lt $deadline)
            return [bool](& $Predicate)
        }
        function Read-Sample {
            $v = [WorkingSetNative]::Sample($process)
            $panes = @(Get-AllSurfaces $false)
            return [pscustomobject][ordered]@{
                ms = $clock.ElapsedMilliseconds; surfaces = $panes.Count; base_pane_only = ($panes.Count -eq 1 -and $panes[0] -eq $script:wsBase)
                private_bytes = $v[0]; working_set = $v[1]; private_plus_shared_commit = $v[2]; peak_working_set = $v[3]
                handles = $(if ($v[4] -lt 0) { $null } else { $v[4] }); gdi_objects = $(if ($v[5] -lt 0) { $null } else { $v[5] }); user_objects = $(if ($v[6] -lt 0) { $null } else { $v[6] })
            }
        }
        # A stage: samples every $script:SampleMs until settled (Test-Settled) or $script:SettleCapMs; the stage's value
        # is its last sample. A stage that never settled, or whose last sample is not the base pane alone, fails the run.
        function Add-Stage([string] $Name) {
            $samples = [Collections.Generic.List[object]]::new()
            $started = $clock.ElapsedMilliseconds
            do {
                if (-not [WorkingSetNative]::Alive($process)) { throw "The copy ended during stage $Name." }
                $samples.Add((Read-Sample))
                if (Test-Settled $samples.ToArray()) { break }
                Start-Sleep -Milliseconds $script:SampleMs
            } while ($clock.ElapsedMilliseconds - $started -lt $script:SettleCapMs)
            $settled = Test-Settled $samples.ToArray()
            if (-not $settled) { $script:wsUnsettled += @($Name) }
            $last = $samples[$samples.Count - 1]
            $record.Stages.Add([ordered]@{ name = $Name; settled = $settled; base_pane_only = $last.base_pane_only; settle_ms = $clock.ElapsedMilliseconds - $started; value = $last; samples = $samples.ToArray() })
            Log ("stage {0}: private {1:N0} ws {2:N0} settled {3} base pane only {4}" -f $Name, $last.private_bytes, $last.working_set, $settled, $last.base_pane_only)
        }

        if (-not (Wait-For { @(Get-AllSurfaces $true).Count -ge 1 } 90000)) { throw 'The first pane never showed.' }
        $hosts = @(Get-Hosts)
        if ($hosts.Count -ne 1) { throw "Expected one window, found $($hosts.Count)." }
        $hostWindow = $hosts[0]
        $firstPanes = @(Get-AllSurfaces $false)
        if ($firstPanes.Count -ne 1) { throw "Expected one pane at the start, found $($firstPanes.Count)." }
        $base = $firstPanes[0]
        $script:wsBase = $base
        $script:wsUnsettled = @()
        $client = [WorkingSetNative]::ClientAndDpi($base)
        $record.ClientWidth = $client[0]; $record.ClientHeight = $client[1]; $record.Dpi = $client[2]

        # The grid, before `start`: the base pane's shell's console is the pane's pseudoconsole, whose window is the
        # terminal's grid. A probe child attaches to it (the driver keeps its own console).
        $shells = @()
        [void](Wait-For { $script:wsShells = @([WorkingSetNative]::Children($nocttyPid, 'cmd.exe')); $script:wsShells.Count -eq 1 } 30000)
        $shells = @($script:wsShells)
        if ($shells.Count -ne 1) { throw "Expected one shell under the copy, found $($shells.Count)." }
        $pwsh = (Get-Command pwsh.exe).Source
        $gridFile = Join-Path $Run 'grid.txt'
        $probe = [WorkingSetNative]::Spawn($pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -GridProbePid {3}' -f $pwsh, $PSCommandPath, $Run, $shells[0]), $Run, $desktopPath, (Join-Path $Run 'grid-probe.log'), $true)
        try {
            if ([WorkingSetNative]::WaitForSingleObject($probe.process, 60000) -ne 0) { [WorkingSetNative]::Terminate($probe.process, 1); throw 'The grid probe did not finish in 60 s.' }
            if ([WorkingSetNative]::ExitCode($probe.process) -ne 0) { throw 'The grid probe failed.' }
        } finally { [void][WorkingSetNative]::CloseHandle($probe.thread); [void][WorkingSetNative]::CloseHandle($probe.process) }
        $grid = [regex]::Match([IO.File]::ReadAllText($gridFile), '\A(\d+),(\d+)\z')
        if (-not $grid.Success) { throw "The grid probe read no grid ($([IO.File]::ReadAllText($gridFile)))." }
        $record.GridCols = [int]$grid.Groups[1].Value; $record.GridRows = [int]$grid.Groups[2].Value
        if ($record.GridCols -ne $script:Cols -or $record.GridRows -ne $script:GridRows) { throw "The grid is $($record.GridCols)x$($record.GridRows), not $($script:Cols)x$($script:GridRows)." }
        Add-Stage 'start'

        $floodCount = Join-Path $work 'flood-count.txt'
        function Get-FloodCount {
            if (-not (Test-Path -LiteralPath $floodCount)) { return 0 }
            try {
                $stream = [IO.File]::Open($floodCount, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
            } catch [IO.IOException] { return -1 }
            return @($text -split "`n" | Where-Object { $_.Trim() }).Count
        }
        # One block into the base pane: F5 types `.\flood.cmd` (the pane's working directory is <work>) and Enter. Block k counts once the batch file
        # acknowledged it (flood-count.txt holds k lines, written after its `type` and its title) and the copy's window
        # title shows `ws-block-k`, which the pane parsed after the block's last byte.
        function Invoke-Block([int] $Index) {
            if (-not [WorkingSetNative]::Responsive($hostWindow, $script:ResponseBoundMs)) { throw "The copy does not answer before block $Index." }
            [IO.File]::WriteAllText((Join-Path $work 'next-block.txt'), "$Index`r`n")
            [WorkingSetNative]::Key($base, $nocttyPid, 0x74)
            if (-not (Wait-For { (Get-FloodCount) -ge $Index } 600000)) { throw "Block $Index was not acknowledged within 600 s." }
            if (-not (Wait-For { [WorkingSetNative]::Title($hostWindow).Contains("ws-block-$Index") } 60000)) { throw "The pane did not reach the end of block $Index within 60 s." }
            $record.Blocks = $Index
        }
        # One cycle: F2 (new_tab) from the base pane, the new pane shown, F7 (close_tab) on it, the pane gone.
        function Invoke-TabCycle {
            $before = @(Get-AllSurfaces $false)
            [WorkingSetNative]::Key($base, $nocttyPid, 0x71)
            $script:wsNew = [IntPtr]::Zero
            $opened = Wait-For { $now = @(Get-AllSurfaces $true | Where-Object { $before -notcontains $_ }); if ($now.Count -ge 1) { $script:wsNew = $now[0]; return $true }; return $false } 15000
            if (-not $opened) { $record.CyclesMissed++; Log 'cycle: no new pane within 15 s'; return $false }
            $new = $script:wsNew
            [void](Wait-For { [WorkingSetNative]::Responsive($hostWindow, 1000) } 5000)
            # The close's time, on the clock captured_at_unix_ms uses: session-capture counts only a snapshot after it.
            $script:wsCloseAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            [WorkingSetNative]::Key($new, $nocttyPid, 0x76)
            if (Wait-For { -not ([WorkingSetNative]::IsWindow($new) -and [WorkingSetNative]::IsWindowVisible($new)) } 15000) { $record.Cycles++; return $true }
            $record.CyclesMissed++; Log 'cycle: the new pane still shown after 15 s'
            return $false
        }

        # After the last close: undo-timeout (5 s) prunes the closed panes; wait for the copy to be back to its base
        # pane alone before the stage, at most 30 s more (test-harnesses.md, SOAK-01 trap 2).
        function Wait-Pruned {
            Start-Sleep -Seconds $script:PruneSeconds
            if (-not (Wait-For { $panes = @(Get-AllSurfaces $false); $panes.Count -eq 1 -and $panes[0] -eq $base } 30000)) { throw "$(@(Get-AllSurfaces $false).Count) panes left 30 s after the prune, or the base pane is gone." }
        }

        switch ($Workload) {
            'fixed' {
                Invoke-Block 1
                for ($i = 0; $i -lt $script:FixedCycles; $i++) { [void](Invoke-TabCycle) }
                Wait-Pruned
                Add-Stage 'after'
            }
            'tab-churn' {
                for ($i = 0; $i -lt $script:ChurnCycles; $i++) { [void](Invoke-TabCycle) }
                Wait-Pruned
                Add-Stage 'after'
            }
            { $_ -in 'scrollback-default', 'scrollback-max' } {
                for ($k = 1; $k -le $record.BlocksPlanned; $k++) {
                    Invoke-Block $k
                    if ($Workload -eq 'scrollback-default' -or $k % 8 -eq 0 -or $k -eq $record.BlocksPlanned) {
                        $sample = Read-Sample
                        Log ("block {0}: private {1:N0} ws {2:N0}" -f $k, $sample.private_bytes, $sample.working_set)
                        $record.Stages.Add([ordered]@{ name = "block-$k"; settled = $false; base_pane_only = $sample.base_pane_only; settle_ms = 0; value = $sample; samples = @($sample) })
                    }
                }
                Add-Stage 'after'
            }
            'uia-walk' {
                for ($k = 1; $k -le $record.BlocksPlanned; $k++) { Invoke-Block $k }
                Add-Stage 'filled'
                Add-Type -AssemblyName UIAutomationClient
                Add-Type -AssemblyName UIAutomationTypes
                $uiaWatch = [Diagnostics.Stopwatch]::StartNew()
                $element = [System.Windows.Automation.AutomationElement]::FromHandle($base)
                $pattern = $null
                if (-not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) { throw 'The pane has no TextPattern.' }
                $document = $pattern.DocumentRange
                $whole = $document.GetText(-1)
                $wholeMs = $uiaWatch.ElapsedMilliseconds
                $range = $document.Clone()
                [void]$range.MoveEndpointByRange([System.Windows.Automation.Text.TextPatternRangeEndpoint]::End, $range, [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start)
                $range.ExpandToEnclosingUnit([System.Windows.Automation.Text.TextUnit]::Line)
                $lines = 0; $chars = 0L; $ended = $false
                while ($uiaWatch.ElapsedMilliseconds -lt 900000) {
                    $chars += $range.GetText(-1).Length
                    $lines++
                    if ($range.Move([System.Windows.Automation.Text.TextUnit]::Line, 1) -eq 0) { $ended = $true; break }
                }
                # Complete only when the walk reached the end, the document holds the last block's last line, and
                # the walk counted the whole bottom-of-scrollback document: the history rows, the viewport and the
                # one line more a walk counts (Get-ExpectedUiaLines, 329 at 140 x 43; Sol, round 2).
                $lastLine = 'ws line {0:D6} the quick brown fox' -f ($script:BlockLines - 1)
                $expectedLines = Get-ExpectedUiaLines
                $holdsFixture = $whole.Contains($lastLine)
                $record.Uia = [ordered]@{ document_chars = $whole.Length; document_ms = $wholeMs; walked_lines = $lines; walked_chars = $chars; walk_ms = $uiaWatch.ElapsedMilliseconds - $wholeMs
                    walk_ended = $ended; holds_last_line = $holdsFixture; expected_lines = $expectedLines; walk_complete = ($ended -and $holdsFixture -and $lines -eq $expectedLines) }
                Log "uia: document $($whole.Length) chars in $wholeMs ms; walked $lines lines, ended $ended, holds the last line $holdsFixture"
                $whole = $null; $document = $null; $range = $null; $pattern = $null; $element = $null
                Add-Stage 'after'
            }
            'session-capture' {
                for ($k = 1; $k -le $record.BlocksPlanned; $k++) { Invoke-Block $k }
                Add-Stage 'filled'
                # Only the copy's own session file (portable mode: beside its exe).
                $sessionFile = Join-Path $Bin 'session-state.json'
                # The base pane's snapshot in the session file: its time and its fixture lines, or $null when the
                # file is absent, mid-write or holds no single tab with one snapshot.
                function Read-BaseSnapshot {
                    if (-not (Test-Path -LiteralPath $sessionFile -PathType Leaf)) { return $null }
                    try { $state = [IO.File]::ReadAllText($sessionFile) | ConvertFrom-Json -Depth 64 } catch { return $null }
                    $tabs = @($state.windows | ForEach-Object { $_.tabs })
                    if ($tabs.Count -ne 1) { return $null }
                    $panes = @($tabs[0].layout.nodes | Where-Object { $_.PSObject.Properties['pane'] } | ForEach-Object { $_.pane })
                    if ($panes.Count -ne 1 -or $null -eq $panes[0].PSObject.Properties['scrollback'] -or $null -eq $panes[0].scrollback) { return $null }
                    $snapshot = $panes[0].scrollback
                    $fixture = @($snapshot.lines | Where-Object { $_ -match '\Aws line \d{6} the quick brown fox' }).Count
                    return [pscustomobject]@{ At = [uint64]$snapshot.captured_at_unix_ms; Lines = @($snapshot.lines).Count; Fixture = $fixture }
                }
                $previous = [uint64]0
                $expectedLines = Get-ExpectedSessionLines
                $script:wsLastSeen = $null
                for ($i = 0; $i -lt $script:SessionCheckpoints; $i++) {
                    # The close's checkpoint (1 s after the last persist_session) is the write this counts: a snapshot of
                    # the base pane alone, taken after this close and after the last one counted, of exactly the lines
                    # its budget gives (Get-ExpectedSessionLines, 3,717 at 140 columns; a halved slice from the
                    # formatter's retry does not count, Sol, round 2), all but the pane's last few rows the fixture's.
                    # A display-change or deferred structural save from before the close does not count (CodeRabbit on
                    # #739); each counted checkpoint's times and line counts are recorded for the outer half's check.
                    if (-not (Invoke-TabCycle)) { continue }
                    $closeAt = [uint64]$script:wsCloseAt
                    $script:wsSnapshot = $null
                    $seen = Wait-For { $s = Read-BaseSnapshot; if ($null -ne $s) { $script:wsLastSeen = $s.Lines }; if ($null -ne $s -and $s.At -gt $previous -and $s.At -gt $closeAt -and $s.Lines -eq $expectedLines -and $s.Fixture -ge $expectedLines - 10) { $script:wsSnapshot = $s; return $true }; return $false } 15000
                    if ($seen) {
                        $record.SessionSaves++; $previous = $script:wsSnapshot.At; $record.SessionLines = $script:wsSnapshot.Lines
                        $record.SessionSnapshots.Add([pscustomobject]@{ close_at_unix_ms = $closeAt; snapshot_at_unix_ms = $script:wsSnapshot.At; lines = $script:wsSnapshot.Lines; fixture_lines = $script:wsSnapshot.Fixture })
                    }
                    else { Log "checkpoint $($i + 1): no new base-pane snapshot of $expectedLines lines with the fixture within 15 s (last seen: $($script:wsLastSeen) lines)" }
                }
                $record.SessionFileBytes = if (Test-Path -LiteralPath $sessionFile) { (Get-Item -LiteralPath $sessionFile).Length } else { $null }
                Wait-Pruned
                Add-Stage 'after'
            }
        }

        foreach ($h in Get-Hosts) { if ([WorkingSetNative]::PostClose($h, $nocttyPid)) { $record.QuitPosts++ } }
        if ($record.QuitPosts -lt 1) { Log 'quit: no close post took' }
        if ([WorkingSetNative]::WaitForSingleObject($process, 60000) -eq 0) { $record.Exit = [WorkingSetNative]::ExitCode($process) }
        else { [WorkingSetNative]::Terminate($process, 1); $record.Exit = 'stuck'; Log 'the copy did not end within 60 s of the quit' }
        Log "quit: $($record.QuitPosts) posts, exit $($record.Exit)"
        # The transport the copy ran on, from its own log (src/pty.zig's startup marker): the bundled ConPTY from the
        # copy's own conpty.dll, never the in-box conhost (Sol, round 2).
        $nocttyLog = Read-SharedText (Join-Path $Run 'noctty.log')
        $record.Transport = if ($nocttyLog.Contains('using the in-box conhost')) { 'inbox' } elseif ($nocttyLog.IndexOf('using bundled ConPTY: ' + (Join-Path $Bin 'conpty.dll'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { 'bundled' } else { 'unknown' }
        if ($script:wsUnsettled.Count -gt 0) { $record.Error = "UNSETTLED $($script:wsUnsettled -join ',')" }
        ConvertTo-RecordArrays
        $problems = @(Get-WorkingSetRecordProblems ([pscustomobject]$record))
        if ($problems.Count -gt 0 -and -not $record.Error) { $record.Error = $problems -join '; ' }
        return $(if ($record.Error) { 1 } else { 0 })
    } catch {
        $record.Error = $_.Exception.Message
        Log "error: $($_.Exception.Message)"
        if ($process -ne [IntPtr]::Zero -and [WorkingSetNative]::Alive($process)) { [WorkingSetNative]::Terminate($process, 1) }
        return 1
    } finally {
        if ($process -ne [IntPtr]::Zero) { [void][WorkingSetNative]::CloseHandle($process) }
        ConvertTo-RecordArrays
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
    }
}

function Invoke-WorkingSetOuter {
    if (-not $Workload) { throw 'Pass -Workload.' }
    Assert-WorkingSetWorkloadName $Workload
    # Only the receipt-bound measurement build, before anything is created or started.
    $build = Get-WorkingSetMeasureBuild $MeasureRepo
    $source = $build.Bin
    # The bundled ConPTY only (Sol, round 2), before anything is created: the copy inherits this environment.
    if ($null -ne [Environment]::GetEnvironmentVariable('NOCTTY_CONPTY')) { throw 'NOCTTY_CONPTY is set in this environment; the copy would not run on the bundled ConPTY. Clear it first.' }
    # A relative -Run is taken from PowerShell's location, not the process's directory.
    $Run = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $Run))
    # One run at a time on this session: copies run together differ by tens of MiB (SOAK-01 trap 6).
    $mutex = [Threading.Mutex]::new($false, 'Local\noctty-hidden-win11-working-set')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another working-set run is active in this session.' }
        Invoke-WorkingSetOuterRun $build $source $Run
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-WorkingSetOuterRun($build, [string] $source, [string] $Run) {
    if (Test-Path -LiteralPath $Run) { throw 'The run directory must be new.' }
    if (($Run + '\').StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The run directory cannot be inside the build.' }
    Assert-WorkingSetRunPlacement $Run $build.Repo
    if (-not $SandboxName) { $SandboxName = 'ws-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $copy = Join-Path $Run 'copy'
    $work = Join-Path $Run 'work'
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($name in @('localappdata', 'appdata', 'temp', 'work')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    [void](New-Item -ItemType Directory -Path $copy)
    Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -notin @('noctty.ico', 'crash', 'ghostty') } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $copy $_.Name) -Recurse }
    if (-not (Test-Path -LiteralPath (Join-Path $copy 'share')) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $source) 'share'))) {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $source) 'share') -Destination (Join-Path $copy 'share') -Recurse
    }
    if (Test-Path -LiteralPath (Join-Path $copy 'noctty.ico')) { throw 'The copy must not carry noctty.ico beside its exe.' }
    if (-not (Test-WorkingSetCopy $copy $build)) { throw "The copied noctty.exe or noctty.com does not match the receipt." }
    [IO.File]::WriteAllText((Join-Path $copy 'noctty.portable'), '')
    [IO.File]::WriteAllText((Join-Path $work 'block.txt'), (New-BlockText), $script:Utf8)
    $floodCmd = Join-Path $work 'flood.cmd'
    [IO.File]::WriteAllText($floodCmd, (New-FloodCmdText))
    [IO.File]::WriteAllText((Join-Path $copy 'config.ghostty'), (New-WorkingSetConfigText $Workload $Run), $script:Utf8)

    $realLocal = [Environment]::GetFolderPath('LocalApplicationData')
    $realDirs = @($realLocal, [Environment]::GetFolderPath('ApplicationData'), [IO.Path]::GetTempPath()) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    # The real session file (session-capture saves session state): guarded here, beside the shared guard.
    $sessionPath = Join-Path $realLocal 'noctty\session-state.json'
    $sessionBefore = Get-Metadata $sessionPath
    $stateGuard = Start-InteractiveWin11StateGuard -Harness 'hidden-win11-working-set' -ReceiptDirectory $Run
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-working-set.ps1'

    $desktopName = 'noctty-ws-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $saved = @{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $pi = $null; $job = [IntPtr]::Zero; $driverExit = $null; $cleanup = $null; $outerError = $null; $ownedProcesses = $null
    try {
        $job = [WorkingSetNative]::CreateRunJob()
        $env:LOCALAPPDATA = Join-Path $Run 'localappdata'; $env:APPDATA = Join-Path $Run 'appdata'
        $env:TEMP = Join-Path $Run 'temp'; $env:TMP = $env:TEMP
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Driver -MeasureRepo "{2}" -Bin "{3}" -Run "{4}" -Workload {5} -ExpectedBuildMode {6} -ScrollbackMaxBytes {7} -SandboxName {8} -DesktopName {9}' -f `
            $pwsh, $PSCommandPath, $build.Repo, $copy, $Run, $Workload, $ExpectedBuildMode, $ScrollbackMaxBytes, $SandboxName, $desktopName
        $pi = [WorkingSetNative]::LaunchDriver($pwsh, $line, $Run, "WinSta0\$desktopName", $job)
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Write-Host "working-set driver PID=$($pi.pid); workload $Workload; evidence=$Run"
        $deadline = [DateTime]::UtcNow.AddMinutes(45)
        while ([HiddenLocal]::WaitForSingleObject($pi.process, 1000) -eq 258) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The driver ran past 45 minutes; the owned job was closed.' }
        }
        [uint32]$code = 0
        if (-not [HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code)) { throw 'The driver exit code could not be read.' }
        $driverExit = $code
    } catch {
        $outerError = $_.Exception.Message
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        if ($job -ne [IntPtr]::Zero) { try { $ownedProcesses = [HiddenLocal]::StopOwnedJob($job) } catch { $cleanup = $_.Exception.Message } }
        if ($pi) { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
    }
    $sessionAfter = Get-Metadata $sessionPath
    $stateFailure = $null
    try { Assert-InteractiveWin11StateGuard -Guard $stateGuard } catch { $stateFailure = $_.Exception.Message }
    $historyFailure = $null
    try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure = $_.Exception.Message }
    $guards = [ordered]@{
        StateGuardPassed = $null -eq $stateFailure
        SessionUnchanged = [string]::Equals($sessionBefore, $sessionAfter, [StringComparison]::Ordinal)
        HistoryUnchanged = $null -eq $historyFailure
        # The guard's own samples and verdict, never a second reading (Sol on #744): a 0/0 reading is unobservable,
        # never held (test-harnesses.md: 2026-11-21 STATE-GUARD-CLIPBOARD-01).
        ClipboardSequenceBefore = $stateGuard.ClipboardBefore; ClipboardSequenceAfter = $(if ($null -ne $stateGuard.PSObject.Properties['ClipboardAfter']) { $stateGuard.ClipboardAfter } else { $null })
        ClipboardObservable = $(if ($null -ne $stateGuard.PSObject.Properties['ClipboardObservable']) { [bool]$stateGuard.ClipboardObservable } else { $false })
        OwnedJobProcesses = $ownedProcesses; OwnedJobCleanup = $cleanup; DriverExit = $driverExit
    }
    $guards | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Run 'guards.json') -Encoding utf8NoBOM
    $failed = @()
    if ($stateFailure) { $failed += $stateFailure }
    if (-not $guards.SessionUnchanged) { $failed += 'the real session-state.json changed' }
    if ($historyFailure) { $failed += $historyFailure }
    if ($cleanup) { $failed += "owned job cleanup: $cleanup" }
    if ($outerError) { $failed += $outerError }
    if ($driverExit -eq 3) { $failed += "the copy's build mode is not $ExpectedBuildMode; it was not launched" }
    elseif ($null -ne $driverExit -and $driverExit -ne 0) { $failed += "the driver failed with exit $driverExit (see driver.log and workingset.json)" }
    # The artifact itself, before the run counts: every required stage present and settled at the base pane alone,
    # the counts, the grid, a close that took and a clean exit.
    $recordPath = Join-Path $Run 'workingset.json'
    $record = if (Test-Path -LiteralPath $recordPath) { Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json } else { $null }
    $failed += @(Get-WorkingSetRecordProblems $record | ForEach-Object { "record: $_" })
    # The record is the run this half asked for: its workload, the limit the copy was launched with, and the blocks
    # that limit plans (Opus, round 2).
    if ($null -ne $record) {
        $wantLimit = if ($Workload -eq 'scrollback-max') { $ScrollbackMaxBytes } else { 10000000 }
        if (-not [string]::Equals([string]$record.Workload, $Workload, [StringComparison]::Ordinal)) { $failed += "record: workload $($record.Workload), not $Workload" }
        if ($record.ScrollbackLimitBytes -ne $wantLimit -or $record.LaunchScrollbackLimit -ne $wantLimit) { $failed += "record: scrollback limit $($record.LaunchScrollbackLimit), not $wantLimit" }
        if ($record.BlocksPlanned -ne (Get-WorkloadBlocks $Workload $wantLimit)) { $failed += "record: $($record.BlocksPlanned) blocks planned, not $(Get-WorkloadBlocks $Workload $wantLimit)" }
        if (-not [string]::Equals([string]$record.LaunchConfigFile, (Join-Path $copy 'config.ghostty'), [StringComparison]::OrdinalIgnoreCase)) { $failed += "record: the copy's config file was not its own generated one" }
    }
    # Where the driver ran the copy from: each directory inside the run, none of them a real one.
    if ($null -ne $record -and $null -ne $record.EffectiveDirs) {
        foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) {
            $dir = [string]$record.EffectiveDirs.$name
            if (-not $dir -or -not ($dir.TrimEnd('\') + '\').StartsWith($Run.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or @($realDirs | Where-Object { [string]::Equals($_, $dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                $failed += "record: the copy's $name was not the run's own"
            }
        }
    } elseif ($null -ne $record) { $failed += 'record: no effective directories' }
    Write-Host (Format-InteractiveWin11ClipboardReading $guards.ClipboardSequenceBefore $guards.ClipboardSequenceAfter)
    if ($failed.Count -gt 0) { throw ('working-set harness: ' + ($failed -join '; ')) }
    Write-Host "working-set harness: $Workload complete: $Run"
}

if ($Driver) {
    $code = Invoke-WorkingSetDriver | Select-Object -Last 1
    exit $code
}
Invoke-WorkingSetOuter
