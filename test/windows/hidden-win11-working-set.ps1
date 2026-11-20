#requires -Version 7.0
<#
.SYNOPSIS
PLAN.md §3.5's working-set workloads: one portable noctty copy on a private desktop runs one fixed workload, and
its private bytes, working set and commit charge are sampled at each stage.

.DESCRIPTION
Run it as
  pwsh -NoProfile -File test/windows/hidden-win11-working-set.ps1 -Bin <portable copy's bin> -Run <new directory>
       -Workload <fixed|scrollback-default|scrollback-max|uia-walk|session-capture|tab-churn>
       [-ExpectedBuildMode ReleaseFast] [-ScrollbackMaxBytes 1073741824]
once per run; each run is a fresh copy, a fresh private desktop and a fresh LOCALAPPDATA. Compare the medians of the
`after` stage over repeated runs (PLAN.md §3.5: the working set after the fixed workload within +10% of Phase 0a's).

The workloads, every one at 140 x 45 cells, the shell System32's cmd.exe started directly with /D:
  fixed               one block of output (25,000 lines), then 20 cycles of a new tab and its close; `after` 7 s
                      later (undo-timeout prunes closed panes after 5 s), once memory settles.
  scrollback-default  4 blocks (100,000 lines) at the default scrollback-limit (10,000,000 bytes), about ten times
                      what that limit retains at this width, so the scrollback is full and recycling; a sample after
                      each block.
  scrollback-max      blocks until the output is 1.25 times what -ScrollbackMaxBytes holds at this width (rows of
                      140 cells take about 1,120 bytes of page), with scrollback-limit = -ScrollbackMaxBytes. noctty
                      has no maximum of its own (scrollback-limit is a usize); 1 GiB is this harness's fixed value.
  uia-walk            scrollback-default's output, then a UIA client in this driver reads the pane's whole
                      DocumentRange once and walks it line by line (TextPattern, Move by Line) to its end. The client
                      finds the pane from this copy's own window handle only.
  session-capture     scrollback-default's output with window-save-state = always and
                      window-save-state-scrollback = 10000 (the session line cap), then 10 checkpoints, each a new tab
                      and its close followed by the session file's next write (win32/session.zig: the capture runs
                      TerminalFormatter over up to the line cap of every pane).
  tab-churn           50 cycles of a new tab and its close, no output.
Every workload samples `start` (after the first pane shows and memory settles) and `after` (its end, settled).

Records in -Run: workingset.json (the parameters, the copy's build mode and SHA-256, the stages with every sample,
the workload's counts, the exit), version.txt (`+version`), noctty.log (the copy's stderr), driver.log, and
guards.json (the outer half's guards).

Safety (AGENTS.md "Running noctty"; the soak's rules, test/windows/interactive-win11-soak.ps1). The outer half copies
-Bin without noctty.ico, places `noctty.portable` beside the exe, writes the config, creates a private desktop and a
kill-on-close job, and starts this script as the driver on that desktop at normal priority, with LOCALAPPDATA,
APPDATA, TEMP and TMP redirected into the run (never for Git Bash or another msys program: nothing here starts one).
Every process names the private desktop in STARTUPINFO. Input is posted, never SendInput, and nothing takes the
foreground. The copy runs with the launch helper's isolation (its own class, --single-instance=false),
`--command=direct:<System32>\cmd.exe /D`, the clipboard denied on the command line and in the config, every default
binding cleared, and no binding that copies. The outer half compares the real startup-attempts.json's and the
product jump list's size and time (never their content) and the PSReadLine history's metadata before and after, and
records the clipboard sequence number before and after. Session state stays in the portable copy. Logs name kinds and
sizes, never a command line or an environment value.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [Parameter(Mandatory)] [ValidateSet('fixed', 'scrollback-default', 'scrollback-max', 'uia-walk', 'session-capture', 'tab-churn')] [string] $Workload,
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $ExpectedBuildMode = 'ReleaseFast',
    [ValidateRange(10000000, 17179869184)] [long] $ScrollbackMaxBytes = 1073741824,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,23}$')] [string] $SandboxName,
    [switch] $Driver,
    [string] $DesktopName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:ProductJumpList = 'c2214d6ebc43ff3f.customDestinations-ms'
$script:ResponseBoundMs = 5000
# One block of output: lines of 80 to 90 bytes, every seventh in an SGR colour; a 140-column row of page holds one.
$script:BlockLines = 25000
$script:RowPageBytes = 1120
$script:Cols = 140
$script:Rows = 45
# psapi.h PROCESS_MEMORY_COUNTERS_EX2, processthreadsapi.h STARTUPINFOW and winnt.h JOBOBJECT_EXTENDED_LIMIT_INFORMATION on
# x64 (AGENTS.md "Win32 FFI").
$script:SdkLayout = 'MemoryCounters=96 workingSet@16 privateUsage@72 sharedCommit@88 Startup=104 desktop@16 flags@60 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16'

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
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);

    public static string Layout() {
        return string.Join(" ", new string[] {
            "MemoryCounters=" + Marshal.SizeOf<MemoryCounters>(), "workingSet@" + Marshal.OffsetOf<MemoryCounters>("workingSet"),
            "privateUsage@" + Marshal.OffsetOf<MemoryCounters>("privateUsage"), "sharedCommit@" + Marshal.OffsetOf<MemoryCounters>("sharedCommit"),
            "Startup=" + Marshal.SizeOf<Startup>(), "desktop@" + Marshal.OffsetOf<Startup>("desktop"),
            "flags@" + Marshal.OffsetOf<Startup>("flags"), "output@" + Marshal.OffsetOf<Startup>("output"),
            "error@" + Marshal.OffsetOf<Startup>("error"), "StartupEx=" + Marshal.SizeOf<StartupEx>(),
            "attributes@" + Marshal.OffsetOf<StartupEx>("attributes"), "JobLimits=" + Marshal.SizeOf<JobLimits>(),
            "limitFlags@" + Marshal.OffsetOf<BasicLimits>("flags") });
    }
    public static string CurrentDesktopName() {
        if (GetDesktopWindow() == IntPtr.Zero) throw new Exception("Current desktop connection failed");
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), 2, name, 512, out needed)) throw new Exception("Desktop name query failed");
        return name.ToString();
    }
    // The driver: suspended, assigned to the job before it runs, no console window, normal priority (no priority
    // flag: a creator at normal priority gives its child normal priority), its desktop named in STARTUPINFO.
    public static ProcessInfo LaunchDriver(string app, string command, string cwd, string desktop, IntPtr job) {
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
    // at normal priority (0x20). No STARTF_USESHOWWINDOW, so a GUI window shows on its desktop.
    public static ProcessInfo Spawn(string app, string command, string cwd, string desktop, string logPath) {
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
            if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, true, 0x00080000 | 0x20, IntPtr.Zero, cwd, ref si, out pi))
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
    // { private bytes, working set, commit charge, peak working set, handles, GDI objects, USER objects }
    public static long[] Sample(IntPtr process) {
        var c = new MemoryCounters(); c.cb = (uint)Marshal.SizeOf<MemoryCounters>();
        if (!K32GetProcessMemoryInfo(process, ref c, c.cb)) throw new Exception("GetProcessMemoryInfo failed: " + Marshal.GetLastWin32Error());
        uint handles; GetProcessHandleCount(process, out handles);
        return new long[] { (long)c.privateUsage.ToUInt64(), (long)c.workingSet.ToUInt64(), (long)(c.privateUsage.ToUInt64() + c.sharedCommit),
            (long)c.peakWorkingSet.ToUInt64(), handles, GetGuiResources(process, 0), GetGuiResources(process, 1) };
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
}
'@
}

function Add-Line([string] $Path, [string] $Line) { [IO.File]::AppendAllText($Path, $Line + "`n", $script:Utf8) }

function Get-Metadata([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 'absent' }
    return '{0}:{1}' -f $item.Length, $item.LastWriteTimeUtc.Ticks
}

# One block of output, deterministic: 25,000 lines of 80 to 90 bytes, every seventh in an SGR colour.
function New-BlockText {
    $builder = [Text.StringBuilder]::new(2400000)
    $esc = [char]27
    for ($i = 0; $i -lt $script:BlockLines; $i++) {
        $text = 'ws line {0:D6} the quick brown fox jumps over the lazy dog 0123456789 abcdefghij' -f $i
        if ($i % 7 -eq 0) { [void]$builder.Append("$esc[3$(1 + $i % 6)m$text$esc[0m`r`n") } else { [void]$builder.Append("$text`r`n") }
    }
    return $builder.ToString()
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

# The settled value of a series of samples: done when the last 10 (5 s at 500 ms) have private bytes within 0.5%
# and working set within 1% of their mean. Pure, so the contract can run it.
function Test-Settled([object[]] $Samples) {
    if ($Samples.Count -lt 10) { return $false }
    $last = @($Samples | Select-Object -Last 10)
    foreach ($field in 'private_bytes', 'working_set') {
        $values = @($last | ForEach-Object { [double]$_.$field })
        $mean = ($values | Measure-Object -Average).Average
        $limit = if ($field -eq 'private_bytes') { 0.005 } else { 0.01 }
        if ($mean -le 0) { return $false }
        if ((($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum) / $mean -gt $limit) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------------------------------------
# The driver: on the private desktop, inside the job, with the environment redirected.
# ---------------------------------------------------------------------------------------------------------
function Invoke-WorkingSetDriver {
    $driverLog = Join-Path $Run 'driver.log'
    function Log([string] $Message) { Add-Line $driverLog ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) }
    $record = [ordered]@{
        Schema = 1; Workload = $Workload; ExpectedBuildMode = $ExpectedBuildMode; BuildMode = $null
        ScrollbackLimitBytes = $null; Blocks = 0; BlocksPlanned = 0; BlockLines = $script:BlockLines
        Cols = $script:Cols; Rows = $script:Rows; Class = $null; ExeSHA256 = $null; DriverPriority = $null; NocttyPriority = $null
        Cycles = 0; CyclesMissed = 0; SessionSaves = 0; Uia = $null; Stages = [Collections.Generic.List[object]]::new()
        Exit = $null; Error = $null
    }
    $recordPath = Join-Path $Run 'workingset.json'
    $process = [IntPtr]::Zero
    try {
        # Normal priority for the measurement (the outer half creates this process without a priority flag).
        [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'Normal'
        $record.DriverPriority = [string][Diagnostics.Process]::GetCurrentProcess().PriorityClass
        if ([WorkingSetNative]::CurrentDesktopName() -cne $DesktopName) { throw 'The driver is not on its private desktop.' }
        if ([WorkingSetNative]::Layout() -cne $script:SdkLayout) { throw "The mirrored structs do not match the SDK's x64 layout: $([WorkingSetNative]::Layout())" }
        $desktopPath = "WinSta0\$DesktopName"
        $exe = Join-Path $Bin 'noctty.exe'
        $work = Join-Path $Run 'work'
        $record.ExeSHA256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()

        $versionPath = Join-Path $Run 'version.txt'
        $check = [WorkingSetNative]::Spawn($exe, ('"{0}" +version' -f $exe), $work, $desktopPath, $versionPath)
        try {
            if ([WorkingSetNative]::WaitForSingleObject($check.process, 60000) -ne 0) { [WorkingSetNative]::Terminate($check.process, 1); throw '+version did not finish in 60 s.' }
            $versionExit = [WorkingSetNative]::ExitCode($check.process)
        } finally { [void][WorkingSetNative]::CloseHandle($check.thread); [void][WorkingSetNative]::CloseHandle($check.process) }
        $modeMatch = [regex]::Match([IO.File]::ReadAllText($versionPath), '(?m)^\s*-\s*build mode\s*:\s*(?:[A-Za-z_.]*\.)?(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)\s*$')
        if ($versionExit -ne 0 -or -not $modeMatch.Success) { throw "noctty +version exited $versionExit with no build mode line." }
        $record.BuildMode = $modeMatch.Groups[1].Value
        if ($record.BuildMode -cne $ExpectedBuildMode) { $record.Error = 'BUILD-MODE'; Log "build mode $($record.BuildMode); not launched"; return 3 }

        $saveState = if ($Workload -eq 'session-capture') { 'always' } else { 'never' }
        $record.ScrollbackLimitBytes = if ($Workload -eq 'scrollback-max') { $ScrollbackMaxBytes } else { 10000000 }
        $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName $SandboxName
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $launchArguments = @(Get-InteractiveWin11LaunchArguments -Layout $layout -UseConfiguredCommand) + @(
            "--command=direct:$cmdPath /D", "--window-save-state=$saveState", '--clipboard-read=deny', '--clipboard-write=deny',
            "--scrollback-limit=$($record.ScrollbackLimitBytes)")
        $class = @($launchArguments | Where-Object { $_ -like '--class=*' } | ForEach-Object { $_.Substring(8) })
        if ($class.Count -ne 1) { throw 'The launch helper gave no single --class.' }
        if (@($launchArguments | Where-Object { $_ -like '--command=*' }).Count -ne 1) { throw 'The copy needs exactly one --command.' }
        foreach ($argument in $launchArguments) { if ($argument -match '"' -or $argument.EndsWith('\')) { throw 'A launch argument cannot be quoted.' } }
        $record.Class = $class[0]
        $commandLine = ('"{0}" ' -f $exe) + (@($launchArguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
        [void][WorkingSetNative]::SetErrorMode([WorkingSetNative]::GetErrorMode() -bor 2)   # SEM_NOGPFAULTERRORBOX, inherited
        $env:GHOSTTY_LOG = 'stderr'
        $pi = [WorkingSetNative]::Spawn($exe, $commandLine, $work, $desktopPath, (Join-Path $Run 'noctty.log'))
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = $pi.process
        [void][WorkingSetNative]::CloseHandle($pi.thread)
        $nocttyPid = $pi.pid
        try { $record.NocttyPriority = [string][Diagnostics.Process]::GetProcessById($nocttyPid).PriorityClass } catch { $record.NocttyPriority = 'unknown' }
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
            return [pscustomobject][ordered]@{ ms = $clock.ElapsedMilliseconds; private_bytes = $v[0]; working_set = $v[1]; commit_charge = $v[2]; peak_working_set = $v[3]; handles = $v[4]; gdi_objects = $v[5]; user_objects = $v[6] }
        }
        # A stage: samples every 500 ms until settled (Test-Settled) or 90 s; the stage's value is its last sample.
        function Add-Stage([string] $Name) {
            $samples = [Collections.Generic.List[object]]::new()
            $started = $clock.ElapsedMilliseconds
            do {
                if (-not [WorkingSetNative]::Alive($process)) { throw "The copy ended during stage $Name." }
                $samples.Add((Read-Sample))
                if (Test-Settled $samples.ToArray()) { break }
                Start-Sleep -Milliseconds 500
            } while ($clock.ElapsedMilliseconds - $started -lt 90000)
            $settled = Test-Settled $samples.ToArray()
            $last = $samples[$samples.Count - 1]
            $record.Stages.Add([ordered]@{ name = $Name; settled = $settled; settle_ms = $clock.ElapsedMilliseconds - $started; value = $last; samples = $samples.ToArray() })
            Log ("stage {0}: private {1:N0} ws {2:N0} commit {3:N0} settled {4}" -f $Name, $last.private_bytes, $last.working_set, $last.commit_charge, $settled)
        }

        if (-not (Wait-For { @(Get-AllSurfaces $true).Count -ge 1 } 90000)) { throw 'The first pane never showed.' }
        $hosts = @(Get-Hosts)
        if ($hosts.Count -ne 1) { throw "Expected one window, found $($hosts.Count)." }
        $hostWindow = $hosts[0]
        $base = @(Get-AllSurfaces $true)[0]
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
        # One block into the base pane: F5 types `"<work>\flood.cmd"` and Enter; the batch file appends a line to
        # flood-count.txt only after its `type` finished, so block k counts once the file holds k lines.
        function Invoke-Block([int] $Index) {
            if (-not [WorkingSetNative]::Responsive($hostWindow, $script:ResponseBoundMs)) { throw "The copy does not answer before block $Index." }
            [WorkingSetNative]::Key($base, $nocttyPid, 0x74)
            if (-not (Wait-For { (Get-FloodCount) -ge $Index } 600000)) { throw "Block $Index was not acknowledged within 600 s." }
            $record.Blocks = $Index
        }
        # One cycle: F2 (new_tab) from the base pane, the new pane shown, F7 (close_tab) on it, the pane gone.
        function Invoke-TabCycle {
            $before = @(Get-AllSurfaces $false)
            [WorkingSetNative]::Key($base, $nocttyPid, 0x71)
            $script:wsNew = [IntPtr]::Zero
            $opened = Wait-For { $now = @(Get-AllSurfaces $true | Where-Object { $before -notcontains $_ }); if ($now.Count -ge 1) { $script:wsNew = $now[0]; return $true }; return $false } 15000
            if (-not $opened) { $record.CyclesMissed++; Log 'cycle: no new pane within 15 s'; return }
            $new = $script:wsNew
            [void](Wait-For { [WorkingSetNative]::Responsive($hostWindow, 1000) } 5000)
            [WorkingSetNative]::Key($new, $nocttyPid, 0x76)
            if (Wait-For { -not ([WorkingSetNative]::IsWindow($new) -and [WorkingSetNative]::IsWindowVisible($new)) } 15000) { $record.Cycles++ }
            else { $record.CyclesMissed++; Log 'cycle: the new pane still shown after 15 s' }
        }

        $record.BlocksPlanned = Get-WorkloadBlocks $Workload $ScrollbackMaxBytes
        switch ($Workload) {
            'fixed' {
                Invoke-Block 1
                for ($i = 0; $i -lt 20; $i++) { Invoke-TabCycle }
                Start-Sleep -Seconds 7
                Add-Stage 'after'
            }
            'tab-churn' {
                for ($i = 0; $i -lt 50; $i++) { Invoke-TabCycle }
                Start-Sleep -Seconds 7
                Add-Stage 'after'
            }
            { $_ -in 'scrollback-default', 'scrollback-max' } {
                for ($k = 1; $k -le $record.BlocksPlanned; $k++) {
                    Invoke-Block $k
                    if ($Workload -eq 'scrollback-default' -or $k % 8 -eq 0 -or $k -eq $record.BlocksPlanned) {
                        $sample = Read-Sample
                        Log ("block {0}: private {1:N0} ws {2:N0}" -f $k, $sample.private_bytes, $sample.working_set)
                        $record.Stages.Add([ordered]@{ name = "block-$k"; settled = $false; settle_ms = 0; value = $sample; samples = @($sample) })
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
                $lines = 0; $chars = 0L; $complete = $false
                while ($uiaWatch.ElapsedMilliseconds -lt 900000) {
                    $chars += $range.GetText(-1).Length
                    $lines++
                    if ($range.Move([System.Windows.Automation.Text.TextUnit]::Line, 1) -eq 0) { $complete = $true; break }
                }
                $record.Uia = [ordered]@{ document_chars = $whole.Length; document_ms = $wholeMs; walked_lines = $lines; walked_chars = $chars; walk_ms = $uiaWatch.ElapsedMilliseconds - $wholeMs; walk_complete = $complete }
                Log "uia: document $($whole.Length) chars in $wholeMs ms; walked $lines lines, complete $complete"
                $whole = $null; $document = $null; $range = $null; $pattern = $null; $element = $null
                Add-Stage 'after'
            }
            'session-capture' {
                for ($k = 1; $k -le $record.BlocksPlanned; $k++) { Invoke-Block $k }
                Add-Stage 'filled'
                $roots = @((Split-Path -Parent $Bin), $env:LOCALAPPDATA, $env:APPDATA)
                function Get-SessionFiles { return @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter 'session-state.json' -ErrorAction SilentlyContinue }) }
                for ($i = 0; $i -lt 10; $i++) {
                    $was = @(Get-SessionFiles | ForEach-Object { '{0}:{1}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks }) -join '|'
                    Invoke-TabCycle
                    if (Wait-For { (@(Get-SessionFiles | ForEach-Object { '{0}:{1}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks }) -join '|') -cne $was } 15000) { $record.SessionSaves++ }
                    else { Log "checkpoint $($i + 1): no session write within 15 s" }
                }
                $files = @(Get-SessionFiles)
                $record.SessionFileBytes = if ($files.Count -ge 1) { $files[0].Length } else { $null }
                Start-Sleep -Seconds 7
                Add-Stage 'after'
            }
        }

        $quitPosts = 0
        foreach ($h in Get-Hosts) { if ([WorkingSetNative]::PostClose($h, $nocttyPid)) { $quitPosts++ } }
        if ([WorkingSetNative]::WaitForSingleObject($process, 60000) -eq 0) { $record.Exit = [WorkingSetNative]::ExitCode($process) }
        else { [WorkingSetNative]::Terminate($process, 1); $record.Exit = 'stuck'; Log 'the copy did not end within 60 s of the quit' }
        Log "quit: $quitPosts posts, exit $($record.Exit)"
        if ($record.CyclesMissed -gt 0) { $record.Error = "CYCLES-MISSED $($record.CyclesMissed)" }
        if ($Workload -eq 'session-capture' -and $record.SessionSaves -ne 10) { $record.Error = "SESSION-SAVES $($record.SessionSaves)" }
        if ($Workload -eq 'uia-walk' -and -not $record.Uia.walk_complete) { $record.Error = 'UIA-WALK-INCOMPLETE' }
        if ($record.Exit -ne 0) { $record.Error = "EXIT $($record.Exit)" }
        return $(if ($record.Error) { 1 } else { 0 })
    } catch {
        $record.Error = $_.Exception.Message
        Log "error: $($_.Exception.Message)"
        if ($process -ne [IntPtr]::Zero -and [WorkingSetNative]::Alive($process)) { [WorkingSetNative]::Terminate($process, 1) }
        return 1
    } finally {
        if ($process -ne [IntPtr]::Zero) { [void][WorkingSetNative]::CloseHandle($process) }
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
    }
}

function Invoke-WorkingSetOuter {
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe') -PathType Leaf)) { throw '-Bin must hold noctty.exe.' }
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'The run directory must be new.' }
    if (($Run + '\').StartsWith($Bin.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The run directory cannot be inside -Bin.' }
    if (-not $SandboxName) { $SandboxName = 'ws-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $copy = Join-Path $Run 'copy'
    $work = Join-Path $Run 'work'
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($name in @('localappdata', 'appdata', 'temp', 'work')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    [void](New-Item -ItemType Directory -Path $copy)
    Get-ChildItem -LiteralPath $Bin -Force | Where-Object { $_.Name -notin @('noctty.ico', 'crash', 'ghostty') } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $copy $_.Name) -Recurse }
    if (-not (Test-Path -LiteralPath (Join-Path $copy 'share')) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Bin) 'share'))) {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $Bin) 'share') -Destination (Join-Path $copy 'share') -Recurse
    }
    if (Test-Path -LiteralPath (Join-Path $copy 'noctty.ico')) { throw 'The copy must not carry noctty.ico beside its exe.' }
    [IO.File]::WriteAllText((Join-Path $copy 'noctty.portable'), '')
    [IO.File]::WriteAllText((Join-Path $work 'block.txt'), (New-BlockText), $script:Utf8)
    $floodCmd = Join-Path $work 'flood.cmd'
    # ASCII only, its paths from its own location (%~dp0), as the soak's.
    [IO.File]::WriteAllText($floodCmd, '@type "%~dp0block.txt" && echo block>>"%~dp0flood-count.txt"' + "`r`n")
    $floodText = '\"' + $floodCmd.Replace('\', '\\') + '\"\r'
    $bindings = [ordered]@{ f2 = 'new_tab'; f5 = "text:$floodText"; f6 = 'close_surface'; f7 = 'close_tab' }
    $chords = @('', 'shift+', 'ctrl+', 'alt+', 'ctrl+shift+', 'alt+shift+', 'ctrl+alt+', 'ctrl+alt+shift+')
    $saveScrollback = if ($Workload -eq 'session-capture') { 10000 } else { 0 }
    @(
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
    ) | Set-Content -LiteralPath (Join-Path $copy 'config.ghostty') -Encoding utf8NoBOM

    $realLocal = [Environment]::GetFolderPath('LocalApplicationData')
    $realRoaming = [Environment]::GetFolderPath('ApplicationData')
    $startupPath = Join-Path $realLocal 'noctty\startup-attempts.json'
    $jumpPath = Join-Path $realRoaming "Microsoft\Windows\Recent\CustomDestinations\$($script:ProductJumpList)"
    $before = [ordered]@{ Startup = Get-Metadata $startupPath; JumpList = Get-Metadata $jumpPath; Clipboard = [HiddenLocal]::GetClipboardSequenceNumber() }
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-working-set.ps1'

    $desktopName = 'noctty-ws-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $saved = @{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $pi = $null; $job = [IntPtr]::Zero; $driverExit = $null; $cleanup = $null; $outerError = $null; $owned = $null
    try {
        $job = [WorkingSetNative]::CreateRunJob()
        $env:LOCALAPPDATA = Join-Path $Run 'localappdata'; $env:APPDATA = Join-Path $Run 'appdata'
        $env:TEMP = Join-Path $Run 'temp'; $env:TMP = $env:TEMP
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Driver -Bin "{2}" -Run "{3}" -Workload {4} -ExpectedBuildMode {5} -ScrollbackMaxBytes {6} -SandboxName {7} -DesktopName {8}' -f `
            $pwsh, $PSCommandPath, $copy, $Run, $Workload, $ExpectedBuildMode, $ScrollbackMaxBytes, $SandboxName, $desktopName
        $pi = [WorkingSetNative]::LaunchDriver($pwsh, $line, $Run, "WinSta0\$desktopName", $job)
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Write-Host "working-set driver PID=$($pi.pid); workload $Workload; evidence=$Run"
        $deadline = [DateTime]::UtcNow.AddMinutes(45)
        while ([HiddenLocal]::WaitForSingleObject($pi.process, 1000) -eq 258) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The driver ran past 45 minutes; the owned job was closed.' }
        }
        [uint32]$code = 0; [void][HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code); $driverExit = $code
    } catch {
        $outerError = $_.Exception.Message
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        if ($job -ne [IntPtr]::Zero) { try { $owned = [HiddenLocal]::StopOwnedJob($job) } catch { $cleanup = $_.Exception.Message } }
        if ($pi) { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
    }
    $after = [ordered]@{ Startup = Get-Metadata $startupPath; JumpList = Get-Metadata $jumpPath; Clipboard = [HiddenLocal]::GetClipboardSequenceNumber() }
    $historyFailure = $null
    try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure = $_.Exception.Message }
    $guards = [ordered]@{
        StartupUnchanged = $before.Startup -ceq $after.Startup
        JumpListUnchanged = $before.JumpList -ceq $after.JumpList
        HistoryUnchanged = $null -eq $historyFailure
        ClipboardSequenceBefore = $before.Clipboard; ClipboardSequenceAfter = $after.Clipboard
        OwnedJobProcesses = $owned; OwnedJobCleanup = $cleanup; DriverExit = $driverExit
    }
    $guards | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Run 'guards.json') -Encoding utf8NoBOM
    $failed = @()
    if (-not $guards.StartupUnchanged) { $failed += 'the real startup-attempts.json changed' }
    if (-not $guards.JumpListUnchanged) { $failed += 'the product jump list changed' }
    if ($historyFailure) { $failed += $historyFailure }
    if ($cleanup) { $failed += "owned job cleanup: $cleanup" }
    if ($outerError) { $failed += $outerError }
    if ($driverExit -eq 3) { $failed += "the copy's build mode is not $ExpectedBuildMode; it was not launched" }
    elseif ($null -ne $driverExit -and $driverExit -ne 0) { $failed += "the driver failed with exit $driverExit (see driver.log and workingset.json)" }
    Write-Host "clipboard sequence number before $($before.Clipboard), after $($after.Clipboard)"
    if ($failed.Count -gt 0) { throw ('working-set harness: ' + ($failed -join '; ')) }
    Write-Host "working-set harness: $Workload complete: $Run"
}

if ($Driver) {
    $code = Invoke-WorkingSetDriver | Select-Object -Last 1
    exit $code
}
Invoke-WorkingSetOuter
