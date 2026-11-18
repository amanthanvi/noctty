#requires -Version 7.0
<#
.SYNOPSIS
PLAN.md §3.5's soak: one portable noctty copy on a private desktop, driven by posted input for -Minutes and
sampled every minute, its run directory judged afterwards by ci/soak_judge.py.

.DESCRIPTION
Run it as
  pwsh -NoProfile -File test/windows/interactive-win11-soak.ps1 -Bin <portable copy> -Run <new directory>
       -ExpectedBuildMode ReleaseFast -Minutes 480 [-SandboxName soak-fast]
then judge the run with
  python -I ci/soak_judge.py <run> --min-minutes 480 --other-run <the night's other run>
(60 and no --other-run for Phase 0a's hour-long runs). -Bin is a portable copy's directory: the packaged
layout (noctty.exe with share\ inside it, as the portable ZIP extracts) or zig-out\bin with share\ beside it.

What it does. The outer half (this process, on the user's desktop) copies -Bin into <run>\copy, places the
`noctty.portable` marker beside the exe and the soak's config.ghostty, creates a private desktop and a
kill-on-close job, and starts this script again as the driver on that desktop, inside the job, with
LOCALAPPDATA, APPDATA, TEMP and TMP redirected into the run directory. The driver checks the copy's build mode
through `noctty.exe +version` (the copy is never launched on a mismatch), turns on SEM_NOGPFAULTERRORBOX (which
the copy inherits, so a crash ends the process instead of waiting in a WER dialog), starts the copy with
Get-InteractiveWin11LaunchArguments (`--single-instance=false`, its own `--class`, `--command=cmd.exe`) and
`--window-save-state=never`, naming the private desktop in STARTUPINFO, and holds the process handle from
CreateProcess on. Each minute it runs scripted churn (new tabs, right and down splits, output floods through
cmd, window resizes, pane and tab closes; every tenth minute and the first are idle), returns the copy to its
baseline of one tab with one pane, waits, and samples. The samples come from the held handle: its PID and
creation time, whether the host window answers WM_NULL through SendMessageTimeout within 5 s, the handle count,
the threads with each one's start address (module+offset) and description, private bytes, working set,
commit charge, GDI and USER objects and the job's other processes. After the last minute it posts WM_CLOSE to
the copy's windows and takes the exit code from GetExitCodeProcess on the held handle. The outer half then
copies every file of the copy's crash directories (portable mode: <copy>\crash and <copy>\ghostty\crash) and
every WER report, Application Error or Hang event and LocalDumps dump that names the copy's full path (or its
PID) after its launch into <run>\crash.

Records (ci/soak_judge.py documents each): run.tsv, samples.tsv, metrics.tsv, threads.tsv and crash\, read by
the judge; timing.tsv (when each minute's sample was taken), harness.json (the parameters, controls and
workload totals), version.txt (`+version`), noctty.log (the copy's stderr log, GHOSTTY_LOG=stderr),
driver.log and guards.json, read by people.

Controls (§3.5, Phase 0a). -InjectHandleEachMinute duplicates one event handle into the soaked process each
minute (DuplicateHandle with the soaked process as the target), so the slope check must fail on the handle
count. -KillAtMinute 5 ends the soaked process with exit code 3 (TerminateProcess, the end a ReleaseSafe panic
gives) right after minute 5's sample, so the process rules must fail it. Neither is written to run.tsv: the
judge judges a control blind.

Safety (AGENTS.md "Running noctty"). Every process starts on the private desktop, named in lpDesktop, inside
the job; input is posted, never SendInput, and nothing takes the foreground. The copy is portable with
LOCALAPPDATA and APPDATA redirected, so the real %LOCALAPPDATA%\noctty is never written: the outer half
compares the size and time of its startup-attempts.json (never its content) before and after, and fails the
run when they change. Nothing can copy: the config clears every default binding, binds none that copies, and
denies OSC 52 reads and writes; the clipboard sequence number is logged before and after for the record, not
judged (an hour-long run on a machine in use sees the user's own copies). PSReadLine history is guarded by
metadata (scripts/windows-harness-history.ps1), and the product jump list's file by size and time (a portable
copy writes none, app-lifecycle.md 2026-10-16). Logs name kinds and sizes, never a command line or an
environment value.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [Parameter(Mandatory)] [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $ExpectedBuildMode,
    [ValidateRange(1, 1440)] [int] $Minutes = 480,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,23}$')] [string] $SandboxName,
    [ValidateRange(0, 1440)] [int] $KillAtMinute = 0,
    [switch] $InjectHandleEachMinute,
    [ValidateRange(10, 600)] [int] $QuitSeconds = 60,
    [switch] $Driver,
    [string] $DesktopName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
$script:Utf8 = [Text.UTF8Encoding]::new($false)
# The product jump list's file (app-lifecycle.md, the 2026-10-20 STANDALONE-LEAF-AUMID-01 entry in
# test-harnesses.md): a portable copy must leave it alone.
$script:ProductJumpList = 'c2214d6ebc43ff3f.customDestinations-ms'
$script:ResponseBoundMs = 5000

if (-not ('SoakNative' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class SoakNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup info; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    // PROCESS_MEMORY_COUNTERS_EX2 (psapi.h): 96 bytes on x64, pinned by MemoryCountersSize.
    [StructLayout(LayoutKind.Sequential)] struct MemoryCounters {
        public uint cb, pageFaults;
        public UIntPtr peakWorkingSet, workingSet, quotaPeakPaged, quotaPaged, quotaPeakNonPaged, quotaNonPaged,
            pagefile, peakPagefile, privateUsage, privateWorkingSet;
        public ulong sharedCommit;
    }
    [StructLayout(LayoutKind.Sequential)] struct ThreadEntry {
        public uint size, usage, threadId, ownerProcessId; public int basePriority, deltaPriority; public uint flags;
    }
    [StructLayout(LayoutKind.Sequential)] struct ModuleInfo { public IntPtr baseOfDll; public uint sizeOfImage; public IntPtr entryPoint; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref StartupEx si, out ProcessInfo pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint share, ref SecurityAttributes sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessHandleCount(IntPtr h, out uint count);
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);
    [DllImport("kernel32.dll")] public static extern uint GetErrorMode();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateEventW(IntPtr sa, bool manual, bool initial, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr thread, out IntPtr description);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool Thread32First(IntPtr snapshot, ref ThreadEntry entry);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool Thread32Next(IntPtr snapshot, ref ThreadEntry entry);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetProcessMemoryInfo(IntPtr h, ref MemoryCounters counters, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32EnumProcessModulesEx(IntPtr h, [Out] IntPtr[] modules, uint size, out uint needed, uint filter);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool K32GetModuleInformation(IntPtr h, IntPtr module, out ModuleInfo info, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint K32GetModuleBaseNameW(IntPtr h, IntPtr module, StringBuilder name, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr info, uint size, IntPtr returned);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationThread(IntPtr thread, int type, out IntPtr info, int size, out int returned);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int type, out uint info, int size, out int returned);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);

    public static int MemoryCountersSize { get { return Marshal.SizeOf<MemoryCounters>(); } }

    // The name of the desktop this thread runs on.
    public static string CurrentDesktopName() {
        if (GetDesktopWindow() == IntPtr.Zero) throw new Exception("Current desktop connection failed");
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), 2, name, 512, out needed)) throw new Exception("Desktop name query failed");
        return name.ToString();
    }

    // Starts `app` on `desktop` with its standard output and error in `logPath`, the only handle it
    // inherits (PROC_THREAD_ATTRIBUTE_HANDLE_LIST), at `priority` (a priority-class creation flag).
    public static ProcessInfo Spawn(string app, string command, string cwd, string desktop, string logPath, uint priority) {
        var sa = new SecurityAttributes { length = Marshal.SizeOf<SecurityAttributes>(), inherit = 1 };
        IntPtr log = CreateFileW(logPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero); // GENERIC_WRITE, share read|write, CREATE_ALWAYS
        if (log == new IntPtr(-1)) throw new Exception("Creating the log file failed: " + Marshal.GetLastWin32Error());
        IntPtr list = IntPtr.Zero, handles = IntPtr.Zero;
        try {
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            list = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error());
            handles = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(handles, log);
            // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
            if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x20002), handles, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
            var si = new StartupEx();
            si.info.cb = Marshal.SizeOf<StartupEx>();
            si.info.desktop = desktop;
            si.info.flags = 0x100; // STARTF_USESTDHANDLES; no STARTF_USESHOWWINDOW, so the window shows on its desktop
            si.info.output = log; si.info.error = log;
            si.attributes = list;
            ProcessInfo pi;
            // EXTENDED_STARTUPINFO_PRESENT | priority. Not CREATE_DEFAULT_ERROR_MODE: the error mode is inherited.
            if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true, 0x00080000 | priority, IntPtr.Zero, cwd, ref si, out pi))
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
    public static void Terminate(IntPtr process, uint code) {
        if (!TerminateProcess(process, code)) throw new Exception("TerminateProcess failed: " + Marshal.GetLastWin32Error());
    }
    public static long CreationTime(IntPtr process) {
        long creation, exit, kernel, user;
        if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) throw new Exception("GetProcessTimes failed: " + Marshal.GetLastWin32Error());
        return creation;
    }
    // The creation time of another process by PID, or 0 when it cannot be opened.
    public static long CreationTimeOf(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return 0;
        try { return CreationTime(h); } finally { CloseHandle(h); }
    }
    // ProcessDefaultHardErrorMode: SetErrorMode's process mode, where SEM_NOGPFAULTERRORBOX (2) is kept as is.
    public static uint HardErrorMode(IntPtr process) {
        uint mode; int returned;
        int status = NtQueryInformationProcess(process, 12, out mode, 4, out returned);
        if (status != 0) throw new Exception("NtQueryInformationProcess failed: 0x" + status.ToString("x8"));
        return mode;
    }
    public static long HandleCount(IntPtr process) {
        uint count; if (!GetProcessHandleCount(process, out count)) throw new Exception("GetProcessHandleCount failed: " + Marshal.GetLastWin32Error());
        return count;
    }
    // { private bytes, working set, commit charge (private + shared commit) }
    public static long[] Memory(IntPtr process) {
        var c = new MemoryCounters(); c.cb = (uint)Marshal.SizeOf<MemoryCounters>();
        if (!K32GetProcessMemoryInfo(process, ref c, c.cb)) throw new Exception("GetProcessMemoryInfo failed: " + Marshal.GetLastWin32Error());
        return new long[] { (long)c.privateUsage.ToUInt64(), (long)c.workingSet.ToUInt64(), (long)(c.privateUsage.ToUInt64() + c.sharedCommit) };
    }
    public static long Gui(IntPtr process, uint kind) { return GetGuiResources(process, kind); }

    static string Clean(string s) {
        if (s == null) return "";
        var b = new StringBuilder();
        foreach (char ch in s) { if (b.Length >= 64) break; b.Append(ch < 0x20 || ch == 0x7f ? '?' : ch); }
        return b.ToString();
    }
    // One "tid<TAB>start<TAB>name" row per thread of `pid`, its start as module+offset.
    public static string[] Threads(IntPtr process, int pid) {
        var modules = new List<Tuple<long,long,string>>();
        var handles = new IntPtr[1024]; uint needed;
        if (K32EnumProcessModulesEx(process, handles, (uint)(handles.Length * IntPtr.Size), out needed, 3)) {
            int n = (int)Math.Min(handles.Length, needed / IntPtr.Size);
            for (int i = 0; i < n; i++) {
                ModuleInfo info; var name = new StringBuilder(260);
                if (!K32GetModuleInformation(process, handles[i], out info, (uint)Marshal.SizeOf<ModuleInfo>())) continue;
                K32GetModuleBaseNameW(process, handles[i], name, 260);
                modules.Add(Tuple.Create(info.baseOfDll.ToInt64(), (long)info.sizeOfImage, Clean(name.ToString())));
            }
        }
        IntPtr snap = CreateToolhelp32Snapshot(4, 0); // TH32CS_SNAPTHREAD
        if (snap == new IntPtr(-1)) throw new Exception("CreateToolhelp32Snapshot failed: " + Marshal.GetLastWin32Error());
        var rows = new List<string>();
        try {
            var e = new ThreadEntry { size = (uint)Marshal.SizeOf<ThreadEntry>() };
            for (bool ok = Thread32First(snap, ref e); ok; ok = Thread32Next(snap, ref e)) {
                if (e.ownerProcessId != (uint)pid) continue;
                string start = "?", name = "";
                IntPtr t = OpenThread(0x0040 | 0x0800, false, e.threadId); // THREAD_QUERY_INFORMATION | _LIMITED_
                if (t != IntPtr.Zero) {
                    try {
                        IntPtr address; int returned;
                        if (NtQueryInformationThread(t, 9, out address, IntPtr.Size, out returned) == 0) { // ThreadQuerySetWin32StartAddress
                            long a = address.ToInt64();
                            start = "0x" + a.ToString("x");
                            foreach (var m in modules) if (a >= m.Item1 && a < m.Item1 + m.Item2) { start = m.Item3 + "+0x" + (a - m.Item1).ToString("x"); break; }
                        }
                        IntPtr text;
                        if (GetThreadDescription(t, out text) >= 0 && text != IntPtr.Zero) {
                            name = Clean(Marshal.PtrToStringUni(text)); LocalFree(text);
                        }
                    } finally { CloseHandle(t); }
                }
                rows.Add(e.threadId + "\t" + start + "\t" + name);
                e.size = (uint)Marshal.SizeOf<ThreadEntry>();
            }
        } finally { CloseHandle(snap); }
        return rows.ToArray();
    }

    // The processes of the job this process runs in (QueryInformationJobObject on the caller's job).
    public static int[] JobPids() {
        const int bytes = 65536; var buffer = Marshal.AllocHGlobal(bytes);
        try {
            if (!QueryInformationJobObject(IntPtr.Zero, 3, buffer, bytes, IntPtr.Zero)) throw new Exception("Job process query failed: " + Marshal.GetLastWin32Error());
            int count = Marshal.ReadInt32(buffer, 4); var ids = new int[count];
            for (int i = 0; i < count; i++) ids[i] = (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64();
            return ids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    static string Class(IntPtr h) { var s = new StringBuilder(128); GetClassNameW(h, s, 128); return s.ToString(); }
    // Every noctty host window on this desktop, as (hwnd, owner pid) pairs.
    public static long[] Hosts() {
        var list = new List<long>();
        EnumWindows((h, p) => { int id; GetWindowThreadProcessId(h, out id);
            if (Class(h) == "noctty.win32.host") { list.Add(h.ToInt64()); list.Add(id); } return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr[] Surfaces(IntPtr host, bool visibleOnly) {
        var list = new List<IntPtr>();
        EnumChildWindows(host, (c, p) => { if (Class(c) == "noctty.win32" && (!visibleOnly || IsWindowVisible(c))) list.Add(c); return true; }, IntPtr.Zero);
        return list.ToArray();
    }
    public static bool Responsive(IntPtr h, uint ms) {
        IntPtr result; return SendMessageTimeoutW(h, 0, IntPtr.Zero, IntPtr.Zero, 2, ms, out result) != IntPtr.Zero; // WM_NULL, SMTO_ABORTIFHUNG
    }
    public static bool PostClose(IntPtr h) { return PostMessageW(h, 0x10, IntPtr.Zero, IntPtr.Zero); }
    // A key as a posted WM_KEYDOWN/WM_KEYUP pair, after clearing the keyboard state the window's thread
    // reads (attaching resets it, AttachThreadInput's documentation; test-harnesses.md, 2026-11-08 trap 7).
    public static void Key(IntPtr h, int vk) {
        int pid; uint tid = GetWindowThreadProcessId(h, out pid); uint me = GetCurrentThreadId();
        if (tid == 0) throw new Exception("No window thread");
        if (!AttachThreadInput(me, tid, true)) throw new Exception("AttachThreadInput failed: " + Marshal.GetLastWin32Error());
        try { if (!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed"); }
        finally { AttachThreadInput(me, tid, false); }
        if (!PostMessageW(h, 0x100, new IntPtr(vk), new IntPtr(1))) throw new Exception("Key-down post failed");
        if (!PostMessageW(h, 0x101, new IntPtr(vk), new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    // Sizes the window without moving or activating it; true when its rectangle then has that size.
    public static bool Resize(IntPtr h, int width, int height) {
        if (!SetWindowPos(h, IntPtr.Zero, 0, 0, width, height, 0x0002 | 0x0004 | 0x0010)) return false; // NOMOVE|NOZORDER|NOACTIVATE
        Rect r; return GetWindowRect(h, out r) && r.Right - r.Left == width && r.Bottom - r.Top == height;
    }
    static IntPtr injected = IntPtr.Zero;
    // The negative control: one more handle in `target`, which it never closes.
    public static bool Inject(IntPtr target) {
        if (injected == IntPtr.Zero) injected = CreateEventW(IntPtr.Zero, true, false, null);
        if (injected == IntPtr.Zero) return false;
        IntPtr copy; return DuplicateHandle(GetCurrentProcess(), injected, target, out copy, 0, false, 2); // DUPLICATE_SAME_ACCESS
    }
}
'@
}

function Add-Line([string] $Path, [string] $Line) {
    [IO.File]::AppendAllText($Path, $Line + "`n", $script:Utf8)
}

function Get-Metadata([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'absent' }
    return '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
}

# Output for the floods: ASCII text with SGR colours and some lines that wrap, about 256 KiB.
function New-FloodText {
    $lines = [Collections.Generic.List[string]]::new()
    $esc = [char]27
    for ($i = 0; $i -lt 3600; $i++) {
        $color = 31 + ($i % 7)
        $text = 'soak flood line {0:D5} the quick brown fox jumps over the lazy dog' -f $i
        if ($i % 50 -eq 0) { $text = $text + (' wrap' * 60) }
        $lines.Add("$esc[${color}m$text$esc[0m")
    }
    return ($lines -join "`r`n") + "`r`n"
}

# ---------------------------------------------------------------------------------------------------------
# The driver: on the private desktop, inside the job, with the environment redirected.
# ---------------------------------------------------------------------------------------------------------
function Invoke-SoakDriver {
    $driverLog = Join-Path $Run 'driver.log'
    function Log([string] $Message) { Add-Line $driverLog ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) }
    $harness = [ordered]@{
        ExpectedBuildMode = $ExpectedBuildMode; Minutes = $Minutes; SandboxName = $SandboxName
        KillAtMinute = $KillAtMinute; InjectHandleEachMinute = [bool]$InjectHandleEachMinute
        QuitSeconds = $QuitSeconds; ResponseBoundMs = $script:ResponseBoundMs
        BuildMode = $null; Launched = $false; Injected = 0; Killed = $null; Churn = 0; Missed = 0
        LateSamples = 0; WorstLatenessMs = 0; HardErrorModes = @(); QuitMs = $null; Error = $null
    }
    $harnessPath = Join-Path $Run 'harness.json'
    $process = [IntPtr]::Zero
    try {
        if ([SoakNative]::CurrentDesktopName() -cne $DesktopName) { throw 'The driver is not on its private desktop.' }
        $desktopPath = "WinSta0\$DesktopName"
        $exe = Join-Path $Bin 'noctty.exe'
        $work = Join-Path $Run 'work'
        $runTsv = Join-Path $Run 'run.tsv'
        $samplesTsv = Join-Path $Run 'samples.tsv'
        $metricsTsv = Join-Path $Run 'metrics.tsv'
        $threadsTsv = Join-Path $Run 'threads.tsv'
        $timingTsv = Join-Path $Run 'timing.tsv'
        Add-Line $metricsTsv "minute`thandles`tthreads`tprivate_bytes`tworking_set`tcommit_charge`tgdi_objects`tuser_objects`tchildren`tsurfaces`tchurn`tmissed"
        Add-Line $threadsTsv "minute`ttid`tstart`tname"
        Add-Line $timingTsv "minute`tsampled_ms`tlate_ms`tworkload_ms"
        if ([SoakNative]::MemoryCountersSize -ne 96) { throw "PROCESS_MEMORY_COUNTERS_EX2 is $([SoakNative]::MemoryCountersSize) bytes, not 96." }

        # The build mode, from the copy's own `+version` (src/cli/version.zig); no launch on a mismatch.
        $versionPath = Join-Path $Run 'version.txt'
        $check = [SoakNative]::Spawn($exe, ('"{0}" +version' -f $exe), $work, $desktopPath, $versionPath, 0x20)
        try {
            if ([SoakNative]::WaitForSingleObject($check.process, 60000) -ne 0) {
                [SoakNative]::Terminate($check.process, 1); throw '+version did not finish in 60 s.'
            }
            $versionExit = [SoakNative]::ExitCode($check.process)
        } finally { [void][SoakNative]::CloseHandle($check.thread); [void][SoakNative]::CloseHandle($check.process) }
        $versionText = [IO.File]::ReadAllText($versionPath)
        $modeMatch = [regex]::Match($versionText, '(?m)^\s*-\s*build mode\s*:\s*(?:[A-Za-z_.]*\.)?(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)\s*$')
        if ($versionExit -ne 0 -or -not $modeMatch.Success) { throw "noctty +version exited $versionExit with no build mode line." }
        $harness.BuildMode = $modeMatch.Groups[1].Value
        if ($harness.BuildMode -cne $ExpectedBuildMode) {
            Log "build mode $($harness.BuildMode), expected $ExpectedBuildMode; not launched"
            $harness.Error = 'BUILD-MODE'
            return 3
        }

        # The launch: the helper's isolation (contract 30), its own class, the private desktop.
        $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName $SandboxName
        $launchArguments = @(Get-InteractiveWin11LaunchArguments -Layout $layout) + @('--window-save-state=never')
        $class = @($launchArguments | Where-Object { $_ -like '--class=*' } | ForEach-Object { $_.Substring(8) })
        if ($class.Count -ne 1) { throw 'The launch helper gave no single --class.' }
        foreach ($argument in $launchArguments) { if ($argument -match '[\s"]') { throw 'A launch argument needs quoting.' } }
        $commandLine = ('"{0}" ' -f $exe) + ($launchArguments -join ' ')
        [void][SoakNative]::SetErrorMode([SoakNative]::GetErrorMode() -bor 2)   # SEM_NOGPFAULTERRORBOX, inherited
        $env:GHOSTTY_LOG = 'stderr'
        $pi = [SoakNative]::Spawn($exe, $commandLine, $work, $desktopPath, (Join-Path $Run 'noctty.log'), 0x20)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = $pi.process
        [void][SoakNative]::CloseHandle($pi.thread)
        $nocttyPid = $pi.pid
        $start = [SoakNative]::CreationTime($process)
        $harness.Launched = $true
        $harness.HardErrorModes += [SoakNative]::HardErrorMode($process)
        $mode = if (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable') -PathType Leaf) { 'portable' } else { 'standard' }
        Add-Line $runTsv "launch`t$nocttyPid`t$start"
        Add-Line $runTsv "mode`t$mode"
        Add-Line $runTsv "class`t$($class[0])"
        Add-Line $runTsv "exe`t$exe"
        Add-Line $runTsv "planned`t$Minutes"
        Log "launched pid $nocttyPid, build mode $($harness.BuildMode), $mode, $Minutes minutes planned"

        function Get-Mine {
            $pairs = [SoakNative]::Hosts(); $mine = @(); $others = @()
            for ($i = 0; $i -lt $pairs.Count; $i += 2) {
                $entry = [pscustomobject]@{ Hwnd = [IntPtr]$pairs[$i]; Pid = [int]$pairs[$i + 1] }
                if ($entry.Pid -eq $nocttyPid) { $mine += $entry } else { $others += $entry }
            }
            return [pscustomobject]@{ Mine = $mine; Others = $others }
        }
        function Get-AllSurfaces([bool] $VisibleOnly) {
            $list = @()
            foreach ($h in (Get-Mine).Mine) { $list += @([SoakNative]::Surfaces($h.Hwnd, $VisibleOnly)) }
            return $list
        }
        function Wait-For([scriptblock] $Predicate, [int] $Ms) {
            $deadline = $clock.ElapsedMilliseconds + $Ms
            do {
                if (& $Predicate) { return $true }
                if (-not [SoakNative]::Alive($process)) { return $false }
                Start-Sleep -Milliseconds 100
            } while ($clock.ElapsedMilliseconds -lt $deadline)
            return [bool](& $Predicate)
        }

        $ready = Wait-For { @(Get-AllSurfaces $true).Count -ge 1 } 90000
        Log "first pane shown: $ready"
        $baseWidth = 1000; $baseHeight = 700
        $host0 = @((Get-Mine).Mine)
        if ($ready -and $host0.Count -ge 1) { [void][SoakNative]::Resize($host0[0].Hwnd, $baseWidth, $baseHeight) }
        if ([SoakNative]::Alive($process)) { $harness.HardErrorModes += [SoakNative]::HardErrorMode($process) }
        $floodCount = Join-Path $work 'flood-count.txt'
        # The floods finished so far: one line each in flood-count.txt, which cmd appends to. While cmd has it
        # open the read fails; that is "not yet" (-1), never a failed step.
        function Get-FloodCount {
            if (-not (Test-Path -LiteralPath $floodCount)) { return 0 }
            try {
                $stream = [IO.File]::Open($floodCount, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
            } catch [IO.IOException] { return -1 }
            return @($text -split "`n" | Where-Object { $_.Trim() }).Count
        }
        function Get-SettledFloodCount {
            [void](Wait-For { $script:soakFloods = Get-FloodCount; $script:soakFloods -ge 0 } 10000)
            return $script:soakFloods
        }

        # One minute of churn: verified actions count as churn, unverified ones as missed. The copy is back
        # at its baseline (one tab, one pane) when it returns, or the miss is counted.
        function Invoke-Churn([int] $Minute, [long] $OpenUntilMs) {
            $r = [pscustomobject]@{ Churn = 0; Missed = 0 }
            $hosts = @((Get-Mine).Mine)
            if ($hosts.Count -ne 1) { $r.Missed++; return $r }
            $hostWindow = $hosts[0].Hwnd
            $all = @(Get-AllSurfaces $false)
            if ($all.Count -ne 1) { $r.Missed++; return $r }
            $base = $all[0]
            # Each step counts itself: verified is churn, anything else (its effect not seen in time, or an
            # error, which is logged) is a miss, and the next steps and the return to the baseline still run.
            $open = {
                param([IntPtr] $From, [int] $Vk)
                if ($clock.ElapsedMilliseconds -ge $OpenUntilMs -or $From -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
                $script:soakNew = [IntPtr]::Zero
                try {
                    $before = @(Get-AllSurfaces $false)
                    [SoakNative]::Key($From, $Vk)
                    $ok = Wait-For {
                        $now = @(Get-AllSurfaces $true | Where-Object { $before -notcontains $_ })
                        if ($now.Count -ge 1) { $script:soakNew = $now[0]; return $true }
                        return $false
                    } 15000
                } catch { Log "minute $Minute open step error: $($_.Exception.Message)"; $ok = $false }
                if ($ok) { $r.Churn++ } else { $r.Missed++ }
                return $script:soakNew
            }
            $flood = {
                param([IntPtr] $Target)
                if ($clock.ElapsedMilliseconds -ge $OpenUntilMs -or $Target -eq [IntPtr]::Zero) { return }
                try {
                    $count = Get-SettledFloodCount
                    [SoakNative]::Key($Target, 0x74)   # F5: text, runs flood.cmd
                    $ok = $count -ge 0 -and (Wait-For { (Get-FloodCount) -gt $count } 30000)
                } catch { Log "minute $Minute flood step error: $($_.Exception.Message)"; $ok = $false }
                if ($ok) { $r.Churn++ } else { $r.Missed++ }
            }
            $close = {
                param([IntPtr[]] $Gone, [IntPtr] $Via, [int] $Vk)
                if ($Via -eq [IntPtr]::Zero) { return }
                try {
                    [SoakNative]::Key($Via, $Vk)
                    $ok = Wait-For { @($Gone | Where-Object { [SoakNative]::IsWindow($_) -and [SoakNative]::IsWindowVisible($_) }).Count -eq 0 } 15000
                } catch { Log "minute $Minute close step error: $($_.Exception.Message)"; $ok = $false }
                if ($ok) { $r.Churn++ } else { $r.Missed++ }
            }
            $s1 = & $open $base 0x71                 # F2: new_tab
            & $flood $s1
            $s2 = & $open $s1 0x72                   # F3: new_split:right
            $s3 = & $open $s2 0x73                   # F4: new_split:down
            & $flood $s3
            if ($clock.ElapsedMilliseconds -lt $OpenUntilMs) {
                foreach ($size in @(@(1300, 850), @(800, 560), @($baseWidth, $baseHeight))) {
                    if ([SoakNative]::Resize($hostWindow, $size[0], $size[1]) -and [SoakNative]::Responsive($hostWindow, $script:ResponseBoundMs)) { $r.Churn++ } else { $r.Missed++ }
                    Start-Sleep -Milliseconds 300
                }
            }
            $s4 = & $open ($(if ($s3 -ne [IntPtr]::Zero) { $s3 } elseif ($s2 -ne [IntPtr]::Zero) { $s2 } else { $s1 })) 0x71
            & $flood $s4
            & $close @($s4) $s4 0x75                # F6: close_surface (its tab closes with it)
            & $close @($s3) $s3 0x75
            $rest = @(@($s1, $s2) | Where-Object { $_ -ne [IntPtr]::Zero })
            if ($rest.Count -gt 0) { & $close $rest $rest[-1] 0x76 }   # F7: close_tab
            if ($Minute % 5 -eq 2) {
                & $flood $base
                # F8: clear_screen, after the base pane's flood (not counted: nothing shows it took effect)
                try { [SoakNative]::Key($base, 0x77) } catch { Log "minute $Minute clear step error: $($_.Exception.Message)" }
            }
            # Back to the baseline: closed panes stay hidden for undo until undo-timeout (5 s) prunes them.
            if (-not (Wait-For { @(Get-AllSurfaces $false).Count -eq 1 } 30000)) {
                $r.Missed++
                foreach ($left in @(Get-AllSurfaces $true | Where-Object { $_ -ne $base })) {
                    try { [SoakNative]::Key($left, 0x75) } catch { Log "minute $Minute cleanup step error: $($_.Exception.Message)" }
                }
                [void](Wait-For { @(Get-AllSurfaces $false).Count -eq 1 } 30000)
            }
            return $r
        }

        for ($minute = 1; $minute -le $Minutes; $minute++) {
            $due = [long]$minute * 60000
            $workStarted = $clock.ElapsedMilliseconds
            $load = [pscustomobject]@{ Churn = 0; Missed = 0 }
            if ($minute -ge 2 -and $minute % 10 -ne 0 -and [SoakNative]::Alive($process)) {
                try { $load = Invoke-Churn $minute ($due - 30000) }
                catch { Log "minute $minute churn error: $($_.Exception.Message)"; $load.Missed++ }
            }
            $workMs = $clock.ElapsedMilliseconds - $workStarted
            if ($InjectHandleEachMinute -and [SoakNative]::Alive($process)) {
                if ([SoakNative]::Inject($process)) { $harness.Injected++ } else { Log "minute $minute injection failed" }
            }
            while ($clock.ElapsedMilliseconds -lt $due) { Start-Sleep -Milliseconds ([Math]::Min(500, [Math]::Max(1, $due - $clock.ElapsedMilliseconds))) }
            $sampledMs = $clock.ElapsedMilliseconds
            $late = $sampledMs - $due
            if ($late -gt 5000) { $harness.LateSamples++ }
            $harness.WorstLatenessMs = [Math]::Max($harness.WorstLatenessMs, $late)
            $harness.Churn += $load.Churn; $harness.Missed += $load.Missed
            if (-not [SoakNative]::Alive($process)) {
                Add-Line $samplesTsv "$minute`t-`t-`t-"
                Add-Line $metricsTsv ("$minute" + ("`t-" * 11))
            } else {
                $windows = Get-Mine
                $mine = @($windows.Mine)
                if ($mine.Count -eq 0 -and @($windows.Others).Count -gt 0) {
                    # A noctty window on this desktop that is not the launched process's: a restart.
                    $other = @($windows.Others)[0]
                    $answer = if ([SoakNative]::Responsive($other.Hwnd, $script:ResponseBoundMs)) { 'yes' } else { 'no' }
                    Add-Line $samplesTsv "$minute`t$($other.Pid)`t$([SoakNative]::CreationTimeOf($other.Pid))`t$answer"
                } else {
                    $answered = $mine.Count -gt 0
                    foreach ($h in $mine) { if (-not [SoakNative]::Responsive($h.Hwnd, $script:ResponseBoundMs)) { $answered = $false } }
                    Add-Line $samplesTsv ("$minute`t$nocttyPid`t$start`t" + $(if ($answered) { 'yes' } else { 'no' }))
                }
                $threads = @([SoakNative]::Threads($process, $nocttyPid))
                $memory = [SoakNative]::Memory($process)
                $children = @([SoakNative]::JobPids() | Where-Object { $_ -ne $PID -and $_ -ne $nocttyPid }).Count
                $surfaces = @(Get-AllSurfaces $false).Count
                Add-Line $metricsTsv ((@($minute, [SoakNative]::HandleCount($process), $threads.Count, $memory[0], $memory[1], $memory[2],
                    [SoakNative]::Gui($process, 0), [SoakNative]::Gui($process, 1), $children, $surfaces, $load.Churn, $load.Missed)) -join "`t")
                foreach ($row in $threads) { Add-Line $threadsTsv "$minute`t$row" }
            }
            Add-Line $timingTsv "$minute`t$sampledMs`t$late`t$workMs"
            if ($KillAtMinute -eq $minute -and [SoakNative]::Alive($process)) {
                [SoakNative]::Terminate($process, 3)   # the kill control: the end a ReleaseSafe panic gives
                [void][SoakNative]::WaitForSingleObject($process, 10000)
                $harness.Killed = $minute
                Log "kill control: ended the process with exit code 3 after minute $minute"
            }
        }

        # The harness's own quit, bounded; the exit code from the held handle.
        if (-not [SoakNative]::Alive($process)) {
            $end = "early`t$([SoakNative]::ExitCode($process))"
        } else {
            $harness.HardErrorModes += [SoakNative]::HardErrorMode($process)
            $quitClock = [Diagnostics.Stopwatch]::StartNew()
            foreach ($h in @((Get-Mine).Mine)) { [void][SoakNative]::PostClose($h.Hwnd) }
            if ([SoakNative]::WaitForSingleObject($process, [uint32]($QuitSeconds * 1000)) -eq 0) {
                $harness.QuitMs = $quitClock.ElapsedMilliseconds
                $end = "quit`t$([SoakNative]::ExitCode($process))"
            } else {
                $end = "stuck`t-"
                [SoakNative]::Terminate($process, 1)
                [void][SoakNative]::WaitForSingleObject($process, 10000)
            }
        }
        $suppressed = $harness.HardErrorModes.Count -gt 0 -and @($harness.HardErrorModes | Where-Object { ($_ -band 2) -eq 0 }).Count -eq 0
        Add-Line $runTsv ("wer`t" + $(if ($suppressed) { 'suppressed' } else { 'default' }))
        Add-Line $runTsv "end`t$end"
        Log "ended: $($end -replace "`t", ' ')"
        return 0
    } catch {
        $harness.Error = $_.Exception.Message
        Log "driver error: $($_.Exception.Message)"
        return 1
    } finally {
        if ($process -ne [IntPtr]::Zero) { [void][SoakNative]::CloseHandle($process) }
        $harness | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $harnessPath -Encoding utf8NoBOM
    }
}

# ---------------------------------------------------------------------------------------------------------
# The outer half: prepares the run, runs the driver, collects crash evidence and checks the guards.
# ---------------------------------------------------------------------------------------------------------
function Copy-CrashEvidence([string] $Copy, [string] $Mode, [string] $Destination, [string] $ExePath, [long] $Launch, [int] $NocttyPid) {
    $problems = [Collections.Generic.List[string]]::new()
    $sources = if ($Mode -eq 'portable') {
        [ordered]@{ 'copy-crash' = (Join-Path $Copy 'crash'); 'copy-ghostty-crash' = (Join-Path $Copy 'ghostty\crash') }
    } else {
        [ordered]@{ 'state-noctty-crash' = (Join-Path $Run 'localappdata\noctty\crash'); 'state-ghostty-crash' = (Join-Path $Run 'localappdata\ghostty\crash') }
    }
    foreach ($label in $sources.Keys) {
        $source = $sources[$label]
        if (-not (Test-Path -LiteralPath $source)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse -Force)) {
            $relative = [IO.Path]::GetRelativePath($source, $file.FullName)
            $target = Join-Path (Join-Path $Destination $label) $relative
            [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target))
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
    # WER: reports whose application path is this copy's, written after its launch.
    $launchUtc = [DateTime]::FromFileTimeUtc($Launch)
    $realLocal = [Environment]::GetFolderPath('LocalApplicationData')
    $werRoots = foreach ($base in @((Join-Path $env:ProgramData 'Microsoft\Windows\WER'), (Join-Path $realLocal 'Microsoft\Windows\WER'), (Join-Path $Run 'localappdata\Microsoft\Windows\WER'))) {
        foreach ($leaf in @('ReportArchive', 'ReportQueue')) { Join-Path $base $leaf }
    }
    foreach ($root in $werRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try { $reports = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop | Where-Object { $_.LastWriteTimeUtc -ge $launchUtc.AddMinutes(-2) }) }
        catch { $problems.Add("WER folder unreadable: $root"); continue }
        foreach ($report in $reports) {
            $file = Join-Path $report.FullName 'Report.wer'
            if (-not (Test-Path -LiteralPath $file)) { continue }
            try { $text = [IO.File]::ReadAllText($file) } catch { $problems.Add("WER report unreadable: $file"); continue }
            $app = [regex]::Match($text, '(?m)^AppPath=(.*?)\r?$')
            $time = [regex]::Match($text, '(?m)^EventTime=(\d+)\r?$')
            if ($app.Success -and $app.Groups[1].Value -ieq $ExePath -and (-not $time.Success -or [long]$time.Groups[1].Value -ge $Launch)) {
                Copy-Item -LiteralPath $report.FullName -Destination (Join-Path $Destination "wer\$($report.Name)") -Recurse
            }
        }
    }
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $launchUtc.ToLocalTime() } -ErrorAction Stop)
    } catch {
        $events = @()
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $problems.Add('Application event log unreadable') }
    }
    foreach ($event in $events) {
        if (@($event.Properties | Where-Object { "$($_.Value)" -ieq $ExePath }).Count -gt 0) {
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'wer'))
            [IO.File]::WriteAllText((Join-Path $Destination "wer\event-$($event.Id)-$($event.RecordId).xml"), $event.ToXml(), $script:Utf8)
        }
    }
    foreach ($dumps in @((Join-Path $realLocal 'CrashDumps'), (Join-Path $Run 'localappdata\CrashDumps'))) {
        $dump = Join-Path $dumps "noctty.exe.$NocttyPid.dmp"
        if ($NocttyPid -gt 0 -and (Test-Path -LiteralPath $dump)) {
            [void](New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'wer'))
            Copy-Item -LiteralPath $dump -Destination (Join-Path $Destination "wer\$(Split-Path -Leaf $dump)")
        }
    }
    if ($problems.Count -gt 0) {
        # Fail closed: a report that could not be ruled out is one the judge counts (CRASH-REPORT).
        [IO.File]::WriteAllLines((Join-Path $Destination 'wer-scan-incomplete.txt'), $problems.ToArray())
    }
    return $problems.ToArray()
}

function Invoke-SoakOuter {
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe') -PathType Leaf)) { throw '-Bin must hold noctty.exe.' }
    if ($KillAtMinute -gt $Minutes) { throw '-KillAtMinute is past the planned minutes.' }
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'The run directory must be new.' }
    if (-not $SandboxName) { $SandboxName = 'soak-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $copy = Join-Path $Run 'copy'
    $work = Join-Path $Run 'work'
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($name in @('localappdata', 'appdata', 'temp', 'crash', 'work')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    Copy-Item -LiteralPath $Bin -Destination $copy -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $copy 'share')) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Bin) 'share'))) {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $Bin) 'share') -Destination (Join-Path $copy 'share') -Recurse
    }
    [IO.File]::WriteAllText((Join-Path $copy 'noctty.portable'), '')
    [IO.File]::WriteAllText((Join-Path $work 'flood.txt'), (New-FloodText), $script:Utf8)
    $floodCmd = Join-Path $work 'flood.cmd'
    [IO.File]::WriteAllText($floodCmd, ('@type "{0}"' -f (Join-Path $work 'flood.txt')) + "`r`n" + ('@echo flood>>"{0}"' -f (Join-Path $work 'flood-count.txt')) + "`r`n")
    $floodText = '\"' + $floodCmd.Replace('\', '\\') + '\"\r'
    # The soak's config (portable mode reads <copy>\config.ghostty). Every default binding is cleared, so no
    # key the harness posts can copy, paste or open anything; F2 to F8 are the churn's.
    @(
        'auto-update = off'
        'window-save-state = never'
        'confirm-close-surface = false'
        'desktop-notifications = false'
        'clipboard-read = deny'
        'clipboard-write = deny'
        'copy-on-select = false'
        "working-directory = $work"
        'keybind = clear'
        'keybind = f2=new_tab'
        'keybind = f3=new_split:right'
        'keybind = f4=new_split:down'
        "keybind = f5=text:$floodText"
        'keybind = f6=close_surface'
        'keybind = f7=close_tab'
        'keybind = f8=clear_screen'
    ) | Set-Content -LiteralPath (Join-Path $copy 'config.ghostty') -Encoding utf8NoBOM

    $realLocal = [Environment]::GetFolderPath('LocalApplicationData')
    $realRoaming = [Environment]::GetFolderPath('ApplicationData')
    $startupPath = Join-Path $realLocal 'noctty\startup-attempts.json'
    $jumpPath = Join-Path $realRoaming "Microsoft\Windows\Recent\CustomDestinations\$($script:ProductJumpList)"
    $before = [ordered]@{ Startup = Get-Metadata $startupPath; JumpList = Get-Metadata $jumpPath; Clipboard = [HiddenLocal]::GetClipboardSequenceNumber() }
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-soak.ps1'

    $desktopName = 'noctty-soak-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $saved = @{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $pi = $null; $job = [IntPtr]::Zero; $driverExit = $null; $cleanup = $null
    try {
        $job = [HiddenLocal]::CreateOwnedJob()
        $env:LOCALAPPDATA = Join-Path $Run 'localappdata'; $env:APPDATA = Join-Path $Run 'appdata'
        $env:TEMP = Join-Path $Run 'temp'; $env:TMP = $env:TEMP
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Driver -Bin "{2}" -Run "{3}" -ExpectedBuildMode {4} -Minutes {5} -SandboxName {6} -KillAtMinute {7} -QuitSeconds {8} -DesktopName {9}' -f `
            $pwsh, $PSCommandPath, $copy, $Run, $ExpectedBuildMode, $Minutes, $SandboxName, $KillAtMinute, $QuitSeconds, $desktopName
        if ($InjectHandleEachMinute) { $line += ' -InjectHandleEachMinute' }
        $pi = [HiddenLocal]::Launch($pwsh, $line, $Run, "WinSta0\$desktopName", $job)
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Write-Host "soak driver PID=$($pi.pid); $Minutes minutes planned; evidence=$Run"
        $deadline = [DateTime]::UtcNow.AddMinutes($Minutes + 20).AddSeconds($QuitSeconds)
        while ([HiddenLocal]::WaitForSingleObject($pi.process, 1000) -eq 258) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The soak driver ran past its bound; the owned job will be closed.' }
        }
        [uint32]$code = 0; [void][HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code); $driverExit = $code
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        $owned = $null
        if ($job -ne [IntPtr]::Zero) { try { $owned = [HiddenLocal]::StopOwnedJob($job) } catch { $cleanup = $_.Exception.Message } }
        if ($pi) { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
    }
    $runRows = @{}
    if (Test-Path -LiteralPath (Join-Path $Run 'run.tsv')) {
        foreach ($row in [IO.File]::ReadAllLines((Join-Path $Run 'run.tsv'))) { $p = $row -split "`t"; if (-not $runRows.ContainsKey($p[0])) { $runRows[$p[0]] = $p } }
    }
    $wer = @()
    if ($runRows.ContainsKey('launch')) {
        $mode = if ($runRows.ContainsKey('mode')) { $runRows['mode'][1] } else { 'portable' }
        $wer = @(Copy-CrashEvidence $copy $mode (Join-Path $Run 'crash') (Join-Path $copy 'noctty.exe') ([long]$runRows['launch'][2]) ([int]$runRows['launch'][1]))
    }
    $after = [ordered]@{ Startup = Get-Metadata $startupPath; JumpList = Get-Metadata $jumpPath; Clipboard = [HiddenLocal]::GetClipboardSequenceNumber() }
    $historyFailure = $null
    try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure = $_.Exception.Message }
    $guards = [ordered]@{
        StartupUnchanged = $before.Startup -ceq $after.Startup
        JumpListUnchanged = $before.JumpList -ceq $after.JumpList
        HistoryUnchanged = $null -eq $historyFailure
        ClipboardSequenceBefore = $before.Clipboard; ClipboardSequenceAfter = $after.Clipboard
        OwnedJobProcesses = $owned; OwnedJobCleanup = $cleanup; DriverExit = $driverExit; WerScanProblems = $wer
    }
    $guards | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Run 'guards.json') -Encoding utf8NoBOM
    $failed = @()
    if (-not $guards.StartupUnchanged) { $failed += 'the real startup-attempts.json changed' }
    if (-not $guards.JumpListUnchanged) { $failed += 'the product jump list changed' }
    if ($historyFailure) { $failed += $historyFailure }
    if ($cleanup) { $failed += "owned job cleanup: $cleanup" }
    if ($driverExit -eq 3) { $failed += "the copy's build mode is not $ExpectedBuildMode; it was not launched" }
    elseif ($driverExit -ne 0) { $failed += "the driver failed with exit $driverExit (see driver.log and harness.json)" }
    Write-Host "soak records: $Run"
    Write-Host ("judge with: python -I ci/soak_judge.py `"{0}`" --min-minutes <60 or 480> [--other-run <the other copy's run>]" -f $Run)
    if ($failed.Count -gt 0) { throw ('soak harness: ' + ($failed -join '; ')) }
    Write-Host 'soak harness: records complete'
}

if ($Driver) {
    $code = Invoke-SoakDriver | Select-Object -Last 1
    exit $code
}
Invoke-SoakOuter
