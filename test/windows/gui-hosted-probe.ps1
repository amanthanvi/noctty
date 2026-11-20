#requires -Version 7.0
<#
.SYNOPSIS
PR 0 of the interactive offload (the hosted GUI probe): a record-only diagnostic of where noctty's processes and
windows land when it is started from a driver created on a private desktop (Q0), and, on a GitHub-hosted runner
only, of what that runner's own interactive desktop allows (D3: real SendInput, screen reads, a WARP present,
ITaskbarList3::HrInit, the toast setting). It measures; it changes nothing, and nothing gates on it.

.DESCRIPTION
  pwsh -NoProfile -File test/windows/gui-hosted-probe.ps1 -Bin <measurement prefix>\bin -MeasureRepo <repo>
       -Work <new directory> -Out <record.json> [-Part Q0|Local|All] [-TestToolsBin <test-tools prefix>\bin]

-Bin is the measurement build's prefix bin (Invoke-InteractiveWin11MeasureBuild, scripts/interactive-win11-measure-lib.ps1),
checked against its receipt in -MeasureRepo; Q0 runs it. -TestToolsBin (required by -Part Local and All) is a
`-Drenderer-test-tools=true` build of the same source, which P3, P4 and P5 run on both desktops: one build and one
fixture. Every run takes a build prepared outside it (nothing here builds, or runs dev-windows.cmd or `cmd /c`) and
uses #727's launch policy: a portable copy without noctty.ico, its own LOCALAPPDATA and APPDATA, every shell the
absolute `direct:<System32>\cmd.exe /D` (no AutoRun), the clipboard read and write denied, `copy-on-select = false`,
`window-save-state = never`, `renderer = d3d11-warp` (a hosted runner has only GDI's OpenGL 1.1) and a seeded
background, #1f6f8b, all set in the copy's portable config.ghostty; the command line carries only the launch helper's
isolation. Each run records that policy as named fields, and reads its shell's real command line by PID to record,
never the text, that it is System32's cmd.exe with /D ahead of any payload.
The P3 fixture's shell is the same cmd with `/D /K type <seed file>`: 20 lines of 64 printable characters (1320
bytes), or, for a withheld-seed control, an empty file. No image, no custom shader, one pane.

Q0 (local and hosted). Invoke-LocalHiddenDriver (hidden-win11-local-lib.ps1, the #727 soak's model) creates a private
desktop and runs this script again as the driver on it, by name, in a kill-on-close job. The driver starts noctty on
that desktop by name and records, for every process of the job (noctty, its ConPTY host, the shell) and every
top-level window on the private and the Default desktop, the desktop each is on: a process by its startup desktop
(RTL_USER_PROCESS_PARAMETERS.DesktopInfo, read from its PEB) and its threads' desktops, a window by the desktop it
was enumerated on. Then it stops each of them by exact PID (creation time checked) and records that none is left.
Positive control: a child the driver starts without naming a desktop reports the private one (the design's M1).
Negative control: a fresh thread of this (Default-desktop) process, moved to a second private desktop with
SetThreadDesktop, starts a child without naming a desktop; the child reports Default. The children create no window.

D3 (GitHub-hosted only: GITHUB_ACTIONS is "true" and RUNNER_ENVIRONMENT "github-hosted"). On the runner's own
Default desktop:
  P1  a probe window takes the foreground; SendInput's KEYEVENTF_UNICODE input of BMP, surrogate and control units
      must arrive exactly (SendInput's count and GetLastError recorded). Control: with another window in front,
      the probe's text is unchanged. Nothing is injected unless this thread is on the input desktop.
  P2  a window filled with #FF00FF is read back from the screen, one pixel at a time on a grid. Controls: covered
      by another window, and minimised: the same points are not that colour.
  P3  the test-tools copy with renderer = d3d11-warp, for the whole run of every arm: the `d3d11` scope's
      `initialized driver=WARP` line, the `renderer_windows` scope's one line the WARP notice (every notice is logged
      through `setNotice`), and no other backend switch or failed candidate (renderer/Windows.zig,
      win32/gl_startup.zig). On Default the seed was presented: a fresh render-trace snapshot of the pane (requested
      with WM_APP + 8 under NOCTTY_RENDER_TRACE_LIVE, as interactive-win11-first-frame.ps1 does) has
      swap_buffers_count >= 1 and last_swap_process_output_bytes at least the seed's bytes. Controls: the same run
      with the seed withheld stays below the seed's bytes, so a bare clear cannot pass; and on a private desktop the
      same build and fixture rendered the seeded frame, a fresh offscreen readback of that pane (WM_PRINTCLIENT to
      `renderer.capture`, as the parity harness reads it) whose dominant colour is the background seed and whose
      other pixels reach the seed text's floor, then a fresh snapshot requested after the readback has
      swap_buffers_count 0. The private withheld-seed readback must miss that floor (the readback check's own
      control). A failed readback, a missing snapshot or a missing record is "inconclusive"; a paint count is not
      evidence.
  P4  the copy's env-gated HrInit record (NOCTTY_GUI_PROBE_TRACE, src/os/gui_probe_trace.zig) on the ready app:
      S_OK on Default; the private desktop's failing HRESULT the control.
  P5  the toast setting the notifier reads for the measurement build's identities (the product notifier and the
      .measure process AUMID), and their history counts before the run and after noctty's normal exit, on Default
      and on the private desktop.
A probe is conclusive only with its positive record and its control; a missing record is "inconclusive".
-Part Local runs Q0 and the private-desktop facts of P4 and P5 on the measurement build, without touching its user's
desktop; -Part All (D3) refuses to start off a GitHub-hosted runner.

Staging copies each build's prefix bin and refuses the run unless both its app (noctty.exe) and its CLI (noctty.com)
match the build: the measurement receipt's ExeSHA256 and CliSHA256, or the test-tools prefix's own files.

The launcher's gate (Get-ProbeLaunchRefusal, before every noctty start): in measurement mode
(NOCTTY_INTERACTIVE_MEASURE_AUMID=1, which the probe sets for itself and its drivers), only a portable copy, `noctty.portable`
beside it and no `noctty.ico`, with LOCALAPPDATA and APPDATA under the run's work directory, of the receipt-bound
measurement build (its exe's SHA-256) or, on a GitHub-hosted runner only, of the -TestToolsBin build. A stock build
shares the product AUMID and could rewrite the installed app's per-user registration (app-lifecycle.md 2026-10-16
"A portable copy"), so on a local machine nothing but the measurement build starts. Its control runs first and
starts nothing: the measurement copy is accepted, and a copy without the marker, one with the icon, another binary,
the test-tools build off a hosted runner, an unredirected LOCALAPPDATA, measurement mode unset, and a missing or
mismatched noctty.com beside the app are each refused for their own reason. A failed control stops the run before any launch.

The record: one JSON object of values and HRESULTs only. No screen image is formed or kept (single-pixel reads),
the renderer's readbacks stay in -Work as counts only, and no path, environment value, window title or command line
enters it; Assert-ProbeRecordAllowed refuses to write anything else.
#>
[CmdletBinding()]
param(
    [string] $Bin,
    [string] $MeasureRepo,
    [string] $Work,
    [string] $Out,
    [ValidateSet('Q0', 'Local', 'All')] [string] $Part = 'Q0',
    # The -Drenderer-test-tools=true build's prefix bin, for P3, P4 and P5 (-Part Local and All).
    [string] $TestToolsBin,
    # The driver half, run by Invoke-LocalHiddenDriver on the private desktop.
    [switch] $Driver,
    [string] $Run,
    [string] $DesktopName,
    [ValidateSet('q0', 'private-renderer', 'private-renderer-withheld')] [string] $Task = 'q0',
    # The builds the driver's launcher gate allows (the outer half passes the hashes it checked).
    [string] $MeasureSha256,
    [string] $MeasureCliSha256,
    [string] $TestToolsSha256,
    [string] $TestToolsCliSha256,
    # A child that writes the name of its own thread's desktop to this file and exits (the Q0 controls).
    [string] $ReportDesktop
)
$ErrorActionPreference = 'Stop'

if ($ReportDesktop) {
    Add-Type -Namespace GuiProbeChild -Name Desk -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetThreadDesktop(uint tid);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool GetUserObjectInformationW(System.IntPtr h, int index, System.Text.StringBuilder name, int length, out int needed);
'@
    $name = [Text.StringBuilder]::new(256)
    $needed = 0
    $ok = [GuiProbeChild.Desk]::GetUserObjectInformationW([GuiProbeChild.Desk]::GetThreadDesktop([GuiProbeChild.Desk]::GetCurrentThreadId()), 2, $name, 512, [ref]$needed)
    [IO.File]::WriteAllText($ReportDesktop, $(if ($ok) { $name.ToString() } else { '' }))
    exit 0
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

if ([IntPtr]::Size -ne 8) { throw 'The probe reads x64 process structures; run it in 64-bit PowerShell.' }

if (-not ('GuiProbeNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class GuiProbeNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x, y, cx, cy, charsX, charsY, fill, flags; public short show, reservedBytes;
        public IntPtr reservedPointer, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup info; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessBasic { public IntPtr exitStatus, peb, affinity, basePriority, pid, parentPid; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct ProcessEntry {
        public uint size, usage, pid; public IntPtr heapId; public uint moduleId, threads, parentPid; public int basePriority; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string exeFile;
    }
    [StructLayout(LayoutKind.Sequential)] struct ThreadEntry { public uint size, usage, threadId, ownerProcessId; public int basePriority, deltaPriority; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] struct ObjectFlags { public int inherit, reserved; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    // GUITHREADINFO (winuser.h, default packing): x64 size 72, hwndFocus at 16.
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo { public uint size, flags; public IntPtr active, focus, capture, menuOwner, moveSize, caret; public Rect caretRect; }
    [StructLayout(LayoutKind.Sequential)] struct KeyboardInput { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MouseInput { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MouseInput mouse; [FieldOffset(0)] public KeyboardInput key; }
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct WndClassEx {
        public int size; public uint style; public IntPtr proc; public int clsExtra, wndExtra;
        public IntPtr instance, icon, cursor, background; public string menu, className; public IntPtr smallIcon;
    }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr hwnd; public uint message; public IntPtr w, l; public uint time; public Point pt; public uint priv; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);

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
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr info, uint size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("user32.dll", SetLastError=true)] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool Thread32First(IntPtr snapshot, ref ThreadEntry entry);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool Thread32Next(IntPtr snapshot, ref ThreadEntry entry);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int type, out ProcessBasic info, int size, out int returned);
    [DllImport("dwmapi.dll")] static extern int DwmIsCompositionEnabled(out bool enabled);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true)] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", SetLastError=true)] static extern bool EnumDesktopWindows(IntPtr desktop, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);
    [DllImport("user32.dll", SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, ref ObjectFlags flags, int length, out int needed);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int height, bool repaint);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Point p);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, StringBuilder l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern ushort RegisterClassExW(ref WndClassEx wc);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool SetWindowTextW(IntPtr h, string text);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMessageW(out Msg msg, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg msg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr DispatchMessageW(ref Msg msg);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint rgb);

    // The SDK's x64 sizes of every struct mirrored here; Assert-ProbeLayout compares them before anything runs.
    public static string Layout() {
        return "Startup=" + Marshal.SizeOf<Startup>() + " StartupEx=" + Marshal.SizeOf<StartupEx>() +
            " ProcessBasic=" + Marshal.SizeOf<ProcessBasic>() + " ProcessEntry=" + Marshal.SizeOf<ProcessEntry>() +
            " parentPid@" + Marshal.OffsetOf<ProcessEntry>("parentPid") + " ThreadEntry=" + Marshal.SizeOf<ThreadEntry>() +
            " Input=" + Marshal.SizeOf<Input>() + " WndClassEx=" + Marshal.SizeOf<WndClassEx>() + " Msg=" + Marshal.SizeOf<Msg>() +
            " GuiThreadInfo=" + Marshal.SizeOf<GuiThreadInfo>() + " focus@" + Marshal.OffsetOf<GuiThreadInfo>("focus");
    }

    // Starts `command` on `desktop` (null: none named, so the child takes this process's), suspended until it is in
    // `job` (Zero: none), its stdout and stderr in `logPath` (null: none), CREATE_NO_WINDOW for a console child.
    public static ProcessInfo Start(string app, string command, string cwd, string desktop, string logPath, IntPtr job, bool noWindow) {
        // PowerShell passes $null to a string parameter as "": an empty lpDesktop is not NULL (it connects by other
        // rules), so both mean "none" here.
        if (string.IsNullOrEmpty(desktop)) desktop = null;
        if (string.IsNullOrEmpty(logPath)) logPath = null;
        IntPtr log = IntPtr.Zero, list = IntPtr.Zero, handles = IntPtr.Zero;
        try {
            var si = new StartupEx();
            si.info.cb = Marshal.SizeOf<StartupEx>();
            si.info.desktop = desktop;
            uint flags = 0x20 | 0x4 | (noWindow ? 0x08000000u : 0u); // NORMAL_PRIORITY_CLASS | CREATE_SUSPENDED
            bool inherit = false;
            if (logPath != null) {
                var sa = new SecurityAttributes { length = Marshal.SizeOf<SecurityAttributes>(), inherit = 1 };
                log = CreateFileW(logPath, 0x40000000, 3, ref sa, 2, 0x80, IntPtr.Zero);
                if (log == new IntPtr(-1)) { log = IntPtr.Zero; throw new Exception("Creating the log failed: " + Marshal.GetLastWin32Error()); }
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                list = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) { Marshal.FreeHGlobal(list); list = IntPtr.Zero; throw new Exception("InitializeProcThreadAttributeList failed: " + Marshal.GetLastWin32Error()); }
                handles = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(handles, log);
                // PROC_THREAD_ATTRIBUTE_HANDLE_LIST: the child inherits the log and nothing else.
                if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x20002), handles, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                    throw new Exception("UpdateProcThreadAttribute failed: " + Marshal.GetLastWin32Error());
                si.info.flags = 0x100; // STARTF_USESTDHANDLES
                si.info.output = log; si.info.error = log;
                si.attributes = list;
                flags |= 0x00080000; // EXTENDED_STARTUPINFO_PRESENT
                inherit = true;
            }
            ProcessInfo pi;
            if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, inherit, flags, IntPtr.Zero, cwd, ref si, out pi))
                throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
            if ((job != IntPtr.Zero && !AssignProcessToJobObject(job, pi.process)) || ResumeThread(pi.thread) == 0xFFFFFFFF) {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(pi.process, 1); CloseHandle(pi.thread); CloseHandle(pi.process);
                throw new Exception("Assigning or resuming the child failed: " + error);
            }
            return pi;
        } finally {
            if (list != IntPtr.Zero) { DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if (log != IntPtr.Zero) CloseHandle(log);
        }
    }

    // The negative control's launch: a fresh thread of this process is moved to `desktop` with SetThreadDesktop, then
    // starts `command` without naming a desktop. moveError is 0 when the move succeeded.
    public static ProcessInfo StartFromMovedThread(IntPtr desktop, string app, string command, string cwd, out int moveError) {
        ProcessInfo result = new ProcessInfo(); int error = -1; Exception failure = null;
        var t = new Thread(() => {
            try {
                error = SetThreadDesktop(desktop) ? 0 : Marshal.GetLastWin32Error();
                result = Start(app, command, cwd, null, null, IntPtr.Zero, true);
            } catch (Exception e) { failure = e; }
        });
        t.Start(); t.Join();
        moveError = error;
        if (failure != null) throw failure;
        return result;
    }

    public static uint ExitCode(IntPtr process) { uint code; return GetExitCodeProcess(process, out code) ? code : 0xFFFFFFFF; }
    public static bool Alive(IntPtr process) { return WaitForSingleObject(process, 0) == 258; }

    public static long CreationTime(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return 0;
        try { long c, e, k, u; return GetProcessTimes(h, out c, out e, out k, out u) ? c : 0; } finally { CloseHandle(h); }
    }

    // Ends `pid` only if it is still the process created at `creation` and a member of `job` (Zero: this process's own
    // job), both checked on the handle it terminates through: "terminated", "gone", "reused", "notInJob" or
    // "stillRunning". With Zero, membership is the job's PID list read while this handle keeps the PID from reuse.
    public static string StopExact(int pid, long creation, IntPtr job) {
        IntPtr h = OpenProcess(0x0001 | 0x1000 | 0x00100000, false, pid); // TERMINATE | QUERY_LIMITED_INFORMATION | SYNCHRONIZE
        if (h == IntPtr.Zero) return "gone";
        try {
            long c, e, k, u;
            if (!GetProcessTimes(h, out c, out e, out k, out u) || c != creation) return "reused";
            bool inJob;
            if (!IsProcessInJob(h, job, out inJob) || !inJob) return "notInJob";
            if (job == IntPtr.Zero && Array.IndexOf(JobPids(IntPtr.Zero), pid) < 0) return "notInJob";
            if (WaitForSingleObject(h, 0) == 0) return "gone";
            TerminateProcess(h, 1);
            return WaitForSingleObject(h, 5000) == 0 ? "terminated" : "stillRunning";
        } finally { CloseHandle(h); }
    }

    public sealed class ProcRow { public int Pid, Parent; public string Image; }
    public static ProcRow[] Processes() {
        var rows = new List<ProcRow>();
        IntPtr snap = CreateToolhelp32Snapshot(0x2, 0); // TH32CS_SNAPPROCESS
        if (snap == new IntPtr(-1)) throw new Exception("CreateToolhelp32Snapshot failed: " + Marshal.GetLastWin32Error());
        try {
            var entry = new ProcessEntry { size = (uint)Marshal.SizeOf<ProcessEntry>() };
            for (bool more = Process32FirstW(snap, ref entry); more; more = Process32NextW(snap, ref entry))
                rows.Add(new ProcRow { Pid = (int)entry.pid, Parent = (int)entry.parentPid, Image = entry.exeFile });
        } finally { CloseHandle(snap); }
        return rows.ToArray();
    }

    public static uint[] Threads(int pid) {
        var rows = new List<uint>();
        IntPtr snap = CreateToolhelp32Snapshot(0x4, 0); // TH32CS_SNAPTHREAD
        if (snap == new IntPtr(-1)) throw new Exception("CreateToolhelp32Snapshot failed: " + Marshal.GetLastWin32Error());
        try {
            var entry = new ThreadEntry { size = (uint)Marshal.SizeOf<ThreadEntry>() };
            for (bool more = Thread32First(snap, ref entry); more; more = Thread32Next(snap, ref entry))
                if (entry.ownerProcessId == (uint)pid) rows.Add(entry.threadId);
        } finally { CloseHandle(snap); }
        return rows.ToArray();
    }

    // The processes of `job`, or of this process's own job with Zero.
    public static int[] JobPids(IntPtr job) {
        int bytes = 8 + 8 * 1024; IntPtr buffer = Marshal.AllocHGlobal(bytes);
        try {
            if (!QueryInformationJobObject(job, 3, buffer, (uint)bytes, IntPtr.Zero)) throw new Exception("Job process query failed: " + Marshal.GetLastWin32Error());
            int count = Marshal.ReadInt32(buffer, 4); var pids = new int[count];
            for (int i = 0; i < count; i++) pids[i] = (int)Marshal.ReadInt64(buffer, 8 + 8 * i);
            return pids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    static byte[] Read(IntPtr h, IntPtr address, int length) {
        var buffer = new byte[length]; IntPtr read;
        return ReadProcessMemory(h, address, buffer, new IntPtr(length), out read) && read.ToInt64() == length ? buffer : null;
    }

    // The desktop a process was started on, as its RTL_USER_PROCESS_PARAMETERS.DesktopInfo says (x64: the PEB's
    // ProcessParameters at +0x20, DesktopInfo a UNICODE_STRING at +0xC0). "" when it names none, null when unreadable.
    public static string StartupDesktop(int pid) {
        IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid); // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
        if (h == IntPtr.Zero) return null;
        try {
            ProcessBasic basic; int returned;
            if (NtQueryInformationProcess(h, 0, out basic, Marshal.SizeOf<ProcessBasic>(), out returned) != 0) return null;
            byte[] pointer = Read(h, basic.peb + 0x20, 8);
            if (pointer == null) return null;
            byte[] text = Read(h, new IntPtr(BitConverter.ToInt64(pointer, 0)) + 0xC0, 16);
            if (text == null) return null;
            int length = BitConverter.ToUInt16(text, 0);
            if (length == 0) return "";
            if (length > 1024) return null;
            byte[] chars = Read(h, new IntPtr(BitConverter.ToInt64(text, 8)), length);
            return chars == null ? null : Encoding.Unicode.GetString(chars);
        } finally { CloseHandle(h); }
    }

    static string Name(IntPtr h) {
        if (h == IntPtr.Zero) return null;
        var s = new StringBuilder(256); int needed;
        return GetUserObjectInformationW(h, 2, s, 512, out needed) ? s.ToString() : null;
    }
    // null: the thread has no desktop (it never touched USER32).
    public static string ThreadDesktop(uint tid) { return Name(GetThreadDesktop(tid)); }
    public static string OwnDesktop() { return ThreadDesktop(GetCurrentThreadId()); }
    // OpenInputDesktop's own outcome (`opened`, GetLastError when not) and the input desktop's name.
    public static string InputDesktop(out int error, out bool opened) {
        IntPtr h = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS
        opened = h != IntPtr.Zero;
        if (!opened) { error = Marshal.GetLastWin32Error(); return null; }
        try { error = 0; return Name(h); } finally { CloseDesktop(h); }
    }
    public static int StationFlags() {
        var flags = new ObjectFlags(); int needed;
        return GetUserObjectInformationW(GetProcessWindowStation(), 1, ref flags, Marshal.SizeOf<ObjectFlags>(), out needed) ? (int)flags.flags : -1;
    }
    public static uint SessionId() { uint session; return ProcessIdToSessionId(GetCurrentProcessId(), out session) ? session : 0xFFFFFFFF; }
    public static uint ConsoleSessionId() { return WTSGetActiveConsoleSessionId(); }
    public static int Composition() { bool on; return DwmIsCompositionEnabled(out on) != 0 ? -1 : (on ? 1 : 0); }
    public static int Metric(int index) { return GetSystemMetrics(index); }
    public static uint SystemDpi() { return GetDpiForSystem(); }
    public static int PerMonitorAware() { return SetProcessDpiAwarenessContext(new IntPtr(-4)) ? 0 : Marshal.GetLastWin32Error(); }

    public sealed class WindowRow { public IntPtr Hwnd; public int Pid; public string Class; public bool Visible; }
    // The top-level windows of the named desktop of this window station; null with `error` when it cannot be opened or
    // enumerated. A successful enumeration with no windows is an empty array.
    public static WindowRow[] DesktopWindows(string desktop, out int error) {
        IntPtr d = OpenDesktopW(desktop, 0, false, 0x0040 | 0x0001); // DESKTOP_ENUMERATE | DESKTOP_READOBJECTS
        if (d == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return null; }
        try {
            var rows = new List<WindowRow>();
            bool enumerated = EnumDesktopWindows(d, (h, p) => {
                int pid; GetWindowThreadProcessId(h, out pid);
                var s = new StringBuilder(128); GetClassNameW(h, s, 128);
                rows.Add(new WindowRow { Hwnd = h, Pid = pid, Class = s.ToString(), Visible = IsWindowVisible(h) });
                return true;
            }, IntPtr.Zero);
            // The callback never stops the walk, so FALSE with an error is a failed enumeration.
            int enumError = enumerated ? 0 : Marshal.GetLastWin32Error();
            if (!enumerated && enumError != 0) { error = enumError; return null; }
            error = 0;
            return rows.ToArray();
        } finally { CloseDesktop(d); }
    }

    public static bool PostClose(IntPtr h) { return PostMessageW(h, 0x10, IntPtr.Zero, IntPtr.Zero); }

    // ---- D3's own windows: a top-level window of one solid colour, optionally with a multiline EDIT filling it,
    // each on its own thread with its own message loop.
    static readonly Dictionary<IntPtr, IntPtr> editOf = new Dictionary<IntPtr, IntPtr>();
    static readonly WndProc procedure = Procedure;
    static IntPtr Procedure(IntPtr h, uint m, IntPtr w, IntPtr l) {
        IntPtr edit = IntPtr.Zero;
        lock (editOf) editOf.TryGetValue(h, out edit);
        if (m == 0x0007 && edit != IntPtr.Zero) { SetFocus(edit); return IntPtr.Zero; } // WM_SETFOCUS: to the EDIT
        if (m == 0x0005 && edit != IntPtr.Zero) MoveWindow(edit, 0, 0, (int)(l.ToInt64() & 0xFFFF), (int)((l.ToInt64() >> 16) & 0xFFFF), true); // WM_SIZE
        if (m == 0x0002) { PostQuitMessage(0); return IntPtr.Zero; } // WM_DESTROY
        return DefWindowProcW(h, m, w, l);
    }
    public sealed class ProbeWindow { public IntPtr Hwnd, Edit; public uint ThreadId; public Thread Thread; }
    public static ProbeWindow Open(string className, uint bgr, int x, int y, int w, int h, bool withEdit) {
        var win = new ProbeWindow(); var ready = new ManualResetEvent(false); Exception failure = null;
        var t = new Thread(() => {
            try {
                IntPtr instance = GetModuleHandleW(null);
                var wc = new WndClassEx { size = Marshal.SizeOf<WndClassEx>(), proc = Marshal.GetFunctionPointerForDelegate(procedure), instance = instance, background = CreateSolidBrush(bgr), className = className };
                if (RegisterClassExW(ref wc) == 0) throw new Exception("RegisterClassEx failed: " + Marshal.GetLastWin32Error());
                // WS_EX_TOPMOST; WS_OVERLAPPEDWINDOW, shown only once its EDIT exists, so its first WM_SETFOCUS reaches it.
                win.Hwnd = CreateWindowExW(0x8, className, "noctty gui probe", 0x00CF0000, x, y, w, h, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
                if (win.Hwnd == IntPtr.Zero) throw new Exception("CreateWindowEx failed: " + Marshal.GetLastWin32Error());
                if (withEdit) {
                    Rect client; GetClientRect(win.Hwnd, out client);
                    // WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN
                    win.Edit = CreateWindowExW(0, "EDIT", "", 0x50001044, 0, 0, client.Right, client.Bottom, win.Hwnd, new IntPtr(1), instance, IntPtr.Zero);
                    if (win.Edit == IntPtr.Zero) throw new Exception("CreateWindowEx (EDIT) failed: " + Marshal.GetLastWin32Error());
                    lock (editOf) editOf[win.Hwnd] = win.Edit;
                }
                win.ThreadId = GetCurrentThreadId();
                ShowWindow(win.Hwnd, 5); // SW_SHOW
                if (win.Edit != IntPtr.Zero) SetFocus(win.Edit);
                UpdateWindow(win.Hwnd);
            } catch (Exception e) { failure = e; }
            ready.Set();
            if (failure != null) return;
            Msg msg;
            while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
        });
        t.IsBackground = true; t.SetApartmentState(ApartmentState.STA); t.Start(); ready.WaitOne();
        if (failure != null) throw failure;
        win.Thread = t;
        return win;
    }
    public static void Close(ProbeWindow win) { if (win == null) return; PostMessageW(win.Hwnd, 0x10, IntPtr.Zero, IntPtr.Zero); win.Thread.Join(5000); }
    public static void Minimise(ProbeWindow win) { ShowWindow(win.Hwnd, 6); } // SW_MINIMIZE
    // Whether the keyboard focus of the window's own thread is its EDIT (GetGUIThreadInfo's hwndFocus).
    public static bool FocusOnEdit(ProbeWindow win) {
        var info = new GuiThreadInfo { size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        return win != null && win.Edit != IntPtr.Zero && GetGUIThreadInfo(win.ThreadId, ref info) && info.focus == win.Edit;
    }
    public static bool SetText(ProbeWindow win, string text) { return SetWindowTextW(win.Edit, text); }
    public static string Text(ProbeWindow win) {
        IntPtr length;
        if (SendMessageTimeoutW(win.Edit, 0x000E, IntPtr.Zero, IntPtr.Zero, 0x2, 5000, out length) == IntPtr.Zero) return null; // WM_GETTEXTLENGTH
        var s = new StringBuilder(length.ToInt32() + 1); IntPtr copied;
        if (SendMessageTimeoutW(win.Edit, 0x000D, new IntPtr(s.Capacity), s, 0x2, 5000, out copied) == IntPtr.Zero) return null; // WM_GETTEXT
        return s.ToString();
    }
    // The screen point at the centre of a cell of an n x n grid over the window's client area.
    public static Point GridPoint(ProbeWindow win, int n, int row, int column) {
        Rect client; GetClientRect(win.Hwnd, out client);
        var p = new Point { X = (client.Right * (2 * column + 1)) / (2 * n), Y = (client.Bottom * (2 * row + 1)) / (2 * n) };
        ClientToScreen(win.Hwnd, ref p);
        return p;
    }

    static Input Key(ushort vk, ushort scan, uint flags) {
        var input = new Input { type = 1 };
        input.u.key.vk = vk; input.u.key.scan = scan; input.u.key.flags = flags;
        return input;
    }
    // An Alt tap through SendInput, so this process sent the last input and may set the foreground, then the
    // foreground itself; true when GetForegroundWindow confirms it.
    public static bool Foreground(IntPtr hwnd, out uint altSent, out bool setResult) {
        var tap = new Input[] { Key(0x12, 0, 0), Key(0x12, 0, 0x2) };
        altSent = SendInput(2, tap, Marshal.SizeOf<Input>());
        setResult = SetForegroundWindow(hwnd);
        if (GetForegroundWindow() != hwnd) {
            int owner; uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out owner);
            uint me = GetCurrentThreadId();
            bool attached = foregroundThread != 0 && foregroundThread != me && AttachThreadInput(me, foregroundThread, true);
            try { BringWindowToTop(hwnd); setResult = SetForegroundWindow(hwnd) || setResult; }
            finally { if (attached) AttachThreadInput(me, foregroundThread, false); }
        }
        Thread.Sleep(200);
        return GetForegroundWindow() == hwnd;
    }
    // Each UTF-16 unit of `text` as a KEYEVENTF_UNICODE down and up; returns SendInput's count, with GetLastError.
    public static uint SendUnicode(string text, out int error) {
        var inputs = new Input[text.Length * 2];
        for (int i = 0; i < text.Length; i++) {
            inputs[2 * i] = Key(0, text[i], 0x4);
            inputs[2 * i + 1] = Key(0, text[i], 0x4 | 0x2);
        }
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        error = Marshal.GetLastWin32Error();
        return sent;
    }

    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    // The renderer test tools (src/apprt/win32.zig, a -Drenderer-test-tools=true build only): 0x8051 redraws the
    // pane's retained frame; WM_PRINTCLIENT (0x0318) reads its last rendered offscreen target back into the BMP at
    // NOCTTY_RENDERER_CAPTURE_PATH (readback.c) and writes NOCTTY_RENDERER_STATUS_PATH. Elsewhere both answer 0.
    // WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT (WM_APP + 8): the pane writes its render trace now (NOCTTY_RENDER_TRACE_LIVE).
    public static bool RequestTraceSnapshot(IntPtr surface) {
        IntPtr result;
        return SendMessageTimeoutW(surface, 0x8008, IntPtr.Zero, IntPtr.Zero, 0x2, 5000, out result) != IntPtr.Zero;
    }
    public static bool Redraw(IntPtr surface) {
        IntPtr result;
        return SendMessageTimeoutW(surface, 0x8051, IntPtr.Zero, IntPtr.Zero, 0x2, 5000, out result) != IntPtr.Zero && result != IntPtr.Zero;
    }
    public static bool Readback(IntPtr surface) {
        // A DC of this process: the copy cannot draw into it, so the frame reaches only the copy's own BMP.
        IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) return false;
        try {
            IntPtr result;
            return SendMessageTimeoutW(surface, 0x0318, dc, new IntPtr(4), 0x2, 5000, out result) != IntPtr.Zero && result != IntPtr.Zero; // PRF_CLIENT
        } finally { DeleteDC(dc); }
    }
    public sealed class FrameStats { public int Width; public int Height; public int Colors; public long Pixels; public long Seed; public int Dominant; }
    // Counts over the readback's BMP (BITMAPFILEHEADER, BITMAPINFOHEADER, then 32-bit BGRA pixels): the colours,
    // the most frequent one as 0xRRGGBB, and the pixels equal to `seedRgb`.
    public static FrameStats BmpStats(string path, int seedRgb) {
        byte[] b = System.IO.File.ReadAllBytes(path);
        if (b.Length < 54 || b[0] != 0x42 || b[1] != 0x4D) throw new Exception("The readback is not a BMP.");
        int offset = BitConverter.ToInt32(b, 10), width = BitConverter.ToInt32(b, 18), height = Math.Abs(BitConverter.ToInt32(b, 22));
        if (BitConverter.ToInt16(b, 28) != 32 || width <= 0 || height <= 0 || offset < 54 || offset + (long)width * height * 4 > b.Length) throw new Exception("The readback is not a 32-bit BMP.");
        var counts = new Dictionary<int, long>();
        long seed = 0, pixels = (long)width * height;
        for (long i = 0; i < pixels; i++) {
            long at = offset + i * 4;
            int rgb = (b[at + 2] << 16) | (b[at + 1] << 8) | b[at];
            long n; counts.TryGetValue(rgb, out n); counts[rgb] = n + 1;
            if (rgb == seedRgb) seed++;
        }
        int dominant = 0; long best = -1;
        foreach (var kv in counts) if (kv.Value > best) { best = kv.Value; dominant = kv.Key; }
        return new FrameStats { Width = width, Height = height, Colors = counts.Count, Pixels = pixels, Seed = seed, Dominant = dominant };
    }
}
'@
}

# The fixture's seeded background (0xRRGGBB), away from near-black, neutral grey and the class brush.
$script:SeedBackground = 0x1F6F8B
# Every logged renderer backend switch or failed candidate (renderer/Windows.zig, win32/gl_startup.zig).
$script:BackendSwitchPattern = 'startup failed|trying the Direct3D 11 beta|using OpenGL|trying OpenGL on next draw|switched from D3D11|OpenGL fallback failed'
# The P3 fixture's seed: 20 lines of 64 printable ASCII characters with no space and no repeated run (so ConPTY has
# nothing to shorten), each ended by CRLF. Its byte count is the floor a presented seeded frame's output must reach.
$script:SeedLines = @(1..20 | ForEach-Object { 'SEED-{0:d2}-NOCTTY-GUI-PROBE-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ-z' -f $_ })
if (@($script:SeedLines | Where-Object { $_.Length -ne 64 }).Count -ne 0) { throw 'The seed lines must be 64 characters.' }
$script:SeedBytes = [long](@($script:SeedLines | ForEach-Object { $_.Length + 2 }) | Measure-Object -Sum).Sum
# The fraction of a readback's pixels other than the background that the seed's text reaches and a bare prompt does
# not (measured locally: SEED_INK_MEASURED).
$script:SeedInkFloor = 0.02

$script:SdkLayout = 'Startup=104 StartupEx=112 ProcessBasic=48 ProcessEntry=568 parentPid@32 ThreadEntry=28 Input=40 WndClassEx=80 Msg=48 GuiThreadInfo=72 focus@16'
function Assert-ProbeLayout {
    if (-not [string]::Equals([GuiProbeNative]::Layout(), $script:SdkLayout, [StringComparison]::Ordinal)) { throw "The probe's mirrored structs are not the SDK's x64 layout: $([GuiProbeNative]::Layout())" }
}
Assert-ProbeLayout

# ---- the record: values and HRESULTs only

function Format-HResult([long] $Value) { return '0x{0:x8}' -f ([uint32]($Value -band 0xFFFFFFFF)) }

# A desktop name as the record keeps it: never the random private name itself.
function Get-DesktopKind([AllowNull()] [string] $Name, [string] $Private) {
    if ($null -eq $Name) { return 'unreadable' }
    $leaf = ($Name -split '\\')[-1]
    if ($leaf -eq '') { return 'none' }
    if ($Private -and [string]::Equals($leaf, $Private, [StringComparison]::Ordinal)) { return 'private' }
    if ([string]::Equals($leaf, 'Default', [StringComparison]::Ordinal)) { return 'Default' }
    return 'other'
}

# Refuses anything but values: booleans, numbers, null, short strings without a path separator or a quote, maps and
# lists of them. A path, command line, environment value or title cannot pass.
function Assert-ProbeRecordAllowed($Value, [string] $Where = 'record') {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [double]) { return }
    if ($Value -is [string]) {
        if ($Value.Length -gt 80 -or $Value -notmatch '\A[A-Za-z0-9 ._:+#=\-]*\z') { throw "The record holds a value outside its allowlist at $Where." }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or $key -notmatch '\A[A-Za-z][A-Za-z0-9]*\z') { throw "The record holds a key outside its allowlist at $Where." }
            Assert-ProbeRecordAllowed $Value[$key] "$Where.$key"
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $Value) { Assert-ProbeRecordAllowed $item "$Where[$index]"; $index++ }
        return
    }
    throw "The record holds a $($Value.GetType().Name) at $Where."
}

function Write-ProbeRecord($Record, [string] $Path) {
    Assert-ProbeRecordAllowed $Record
    [IO.File]::WriteAllText($Path, ($Record | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

# What the design's §9 asks of each desktop first.
function Get-SessionFacts([string] $Private) {
    $inputError = 0; $inputOpened = $false
    $own = [GuiProbeNative]::OwnDesktop()
    $inputDesktop = [GuiProbeNative]::InputDesktop([ref]$inputError, [ref]$inputOpened)
    return [ordered]@{
        sessionId = [GuiProbeNative]::SessionId()
        activeConsoleSessionId = [GuiProbeNative]::ConsoleSessionId()
        stationVisible = (([GuiProbeNative]::StationFlags() -band 1) -eq 1)
        threadDesktop = Get-DesktopKind $own $Private
        # Whether OpenInputDesktop succeeds here at all (design v6), then which desktop it names.
        openInputDesktopSucceeded = $inputOpened
        inputDesktop = Get-DesktopKind $inputDesktop $Private
        inputDesktopError = $inputError
        onInputDesktop = ($null -ne $own -and $null -ne $inputDesktop -and [string]::Equals($own, $inputDesktop, [StringComparison]::Ordinal))
        dwmComposition = [GuiProbeNative]::Composition()
        screenWidth = [GuiProbeNative]::Metric(0)
        screenHeight = [GuiProbeNative]::Metric(1)
        systemDpi = [GuiProbeNative]::SystemDpi()
    }
}

# ---- launching the copy

# The copy's launch: its command line, which carries only the launch helper's isolation (containment,
# --single-instance=false, its own class), and its portable config.ghostty, which carries the shell and every
# setting. A shell set on the command line would travel as one argument with a space in it, which a caller that
# splits arguments can cut before /D, so cmd's AutoRun would run (design review r6); the config file cannot be split.
# #727's policy: the one shell the absolute System32 cmd with /D (no AutoRun), no -e, the clipboard read and write
# denied, copy-on-select off. A P3 fixture's shell prints the seed file (`/K type <seed>`) on the fixture's grid. The
# policy is read back from the settings and arguments themselves as named fields, never their text.
function Get-CopyLaunch([string] $Exe, [string] $SeedPath) {
    $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName 'gui-probe'
    $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $shell = "direct:$cmdPath /D"
    if ($SeedPath) {
        # A fixed relative name in the shell's working directory, so a work path may hold spaces.
        if ((Split-Path -Leaf $SeedPath) -cne 'seed.txt') { throw 'The seed file must be named seed.txt.' }
        $shell += ' /K type seed.txt'
    }
    $settings = [ordered]@{
        'command' = $shell
        'auto-update' = 'off'
        'window-save-state' = 'never'
        'clipboard-read' = 'deny'
        'clipboard-write' = 'deny'
        'copy-on-select' = 'false'
        'renderer' = 'd3d11-warp'
        'background' = ('#{0:x6}' -f $script:SeedBackground)
        # WM_CLOSE ends the copy without a prompt the probe would not answer, so a close is a normal exit or none.
        'confirm-close-surface' = 'false'
    }
    if ($SeedPath) {
        $settings['working-directory'] = Split-Path -Parent $SeedPath
        $settings['window-width'] = '100'; $settings['window-height'] = '30'
    }
    $arguments = @(Get-InteractiveWin11LaunchArguments -Layout $layout -UseConfiguredCommand)
    foreach ($argument in $arguments) {
        if ($argument -match '[\s"]' -or $argument.StartsWith('--command=', [StringComparison]::Ordinal) -or $argument -ceq '-e') { throw 'The command line may carry only the launch helper''s isolation.' }
    }
    $flag = {
        param([string] $Key)
        $hits = @($arguments | Where-Object { $_.StartsWith("--$Key=", [StringComparison]::Ordinal) })
        if ($hits.Count -eq 1) { return $hits[0].Substring($Key.Length + 3) }
        return "set $($hits.Count) times"
    }
    $tokens = @($(if ($shell.StartsWith('direct:', [StringComparison]::Ordinal)) { $shell.Substring('direct:'.Length) -split ' ' } else { @() }))
    $stimulus = 'none'
    if ($tokens.Count -gt 2) { $stimulus = $(if ($tokens.Count -eq 5 -and $tokens[2] -ceq '/K' -and $tokens[3] -ceq 'type' -and $tokens[4] -ceq 'seed.txt') { 'type-seed-file' } else { 'other' }) }
    $policy = [ordered]@{
        shellSetIn = 'config-file'
        confirmClose = $settings['confirm-close-surface']
        shellKind = $(if ($tokens.Count -ge 1 -and [string]::Equals($tokens[0], $cmdPath, [StringComparison]::OrdinalIgnoreCase)) { 'direct-system32-cmd' } else { 'other' })
        shellAutoRunOff = ($tokens.Count -ge 2 -and $tokens[1] -ceq '/D')
        shellStimulus = $stimulus
        initialCommands = 0
        clipboardRead = $settings['clipboard-read']
        clipboardWrite = $settings['clipboard-write']
        copyOnSelect = $settings['copy-on-select']
        windowSaveState = $settings['window-save-state']
        renderer = $settings['renderer']
        singleInstance = & $flag 'single-instance'
        jobObjectKillOnClose = & $flag 'windows-job-object-kill-on-close'
    }
    $line = ('"{0}" ' -f $Exe) + ($arguments -join ' ')
    $config = @($settings.Keys | ForEach-Object { '{0} = {1}' -f $_, $settings[$_] })
    return [pscustomobject]@{ Line = $line; Config = $config; Policy = $policy }
}

# True when `ProcessId` descends from `Ancestor` in the toolhelp rows `All` (keyed by PID), within 16 hops.
function Test-ProbeDescendant($All, [int] $ProcessId, [int] $Ancestor) {
    $hop = $All[$ProcessId]
    for ($depth = 0; $null -ne $hop -and $depth -lt 16; $depth++) {
        if ($hop.Parent -eq $Ancestor) { return $true }
        if ($hop.Parent -eq $hop.Pid) { return $false }
        $hop = $All[$hop.Parent]
    }
    return $false
}

# The copy's shell as Windows started it, found by PID (the one cmd.exe below the copy). Its command line is read and
# tested here and never kept: the facts say only whether it is System32's cmd.exe and whether /D is its first
# argument, ahead of any payload (the fixture's `/K type <seed>`; Q0's shell has none).
function Get-ShellLaunchFacts([int] $CopyPid, [bool] $Fixture) {
    $facts = [ordered]@{ shells = 0; read = $false; systemCmd = $false; autoRunOffFirst = $false; payloadAfterD = $false }
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    do {
        $all = @{}
        foreach ($row in [GuiProbeNative]::Processes()) { $all[$row.Pid] = $row }
        $shells = @($all.Values | Where-Object { $_.Image -ieq 'cmd.exe' -and (Test-ProbeDescendant $all $_.Pid $CopyPid) })
        if ($shells.Count -ge 1) { break }
        Start-Sleep -Milliseconds 250
    } while ([datetime]::UtcNow -lt $deadline)
    $facts.shells = $shells.Count
    if ($shells.Count -ne 1) { return $facts }
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($shells[0].Pid)" -ErrorAction SilentlyContinue
    $commandLine = $(if ($process) { [string]$process.CommandLine } else { '' })
    if (-not $commandLine) { return $facts }
    $facts.read = $true
    $parsed = [regex]::Match($commandLine, '\A\s*(?:"(?<exe>[^"]+)"|(?<exe>\S+))(?<rest>.*)\z')
    if ($parsed.Success) {
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        $exe = $parsed.Groups['exe'].Value
        $facts.systemCmd = [IO.Path]::IsPathRooted($exe) -and [string]::Equals([IO.Path]::GetFullPath($exe), $cmdPath, [StringComparison]::OrdinalIgnoreCase)
        $rest = $parsed.Groups['rest'].Value.Trim()
        # cmd reads its switches without regard to case, so these matches ignore it too.
        $facts.autoRunOffFirst = $rest -match '\A/D(\s|\z)'
        $facts.payloadAfterD = $(if ($Fixture) { $rest -match '\A/D\s+/K\s+type\s+\S' } else { $rest -match '\A/D\z' })
    }
    $commandLine = $null
    return $facts
}

# Writes the P3 fixture's seed file: the seed, or (withheld) nothing, so the shell prints only its prompt.
function Write-ProbeSeed([string] $Path, [bool] $Withheld) {
    $text = $(if ($Withheld) { '' } else { ($script:SeedLines -join "`r`n") + "`r`n" })
    [IO.File]::WriteAllText($Path, $text, [Text.Encoding]::ASCII)
}

function Test-ProbeHosted { return $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' }

function Get-ProbeHash([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# The launcher's gate: null when `Exe` may start, else why not. A portable copy (the marker beside it, no noctty.ico)
# of the receipt-bound measurement build, or of the test-tools build on a GitHub-hosted runner only, with LOCALAPPDATA
# and APPDATA under the work directory. Anything else could write the installed app's per-user state.
function Get-ProbeLaunchRefusal([string] $Exe) {
    # Measurement mode (NOCTTY_INTERACTIVE_MEASURE_AUMID, interactive-win11-lib.ps1) routes the harness libraries to
    # the measurement build; the outer half sets it and every driver inherits it.
    if (-not (Test-InteractiveWin11MeasureMode)) { return 'measurement mode not set' }
    $dir = Split-Path -Parent $Exe
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'noctty.portable') -PathType Leaf)) { return 'not a portable copy' }
    if (Test-Path -LiteralPath (Join-Path $dir 'noctty.ico')) { return 'carries noctty.ico' }
    if (-not $script:MeasureExeSha256) { return 'no allowed build' }
    $hash = Get-ProbeHash $Exe
    $testTools = (Test-ProbeHosted) -and [bool]$script:TestToolsExeSha256 -and $hash -ceq $script:TestToolsExeSha256
    if (-not ($hash -ceq $script:MeasureExeSha256 -or $testTools)) { return 'not an allowed build' }
    # The CLI beside the app must be the same build's (design v7 §11 item 0).
    $cli = Join-Path $dir 'noctty.com'
    $cliExpected = $(if ($testTools) { $script:TestToolsCliSha256 } else { $script:MeasureCliSha256 })
    if (-not $cliExpected -or -not (Test-Path -LiteralPath $cli -PathType Leaf) -or (Get-ProbeHash $cli) -cne $cliExpected) { return 'CLI not the allowed build' }
    $root = [IO.Path]::GetFullPath($script:WorkRoot).TrimEnd('\') + '\'
    foreach ($name in @('LOCALAPPDATA', 'APPDATA')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value -or -not ([IO.Path]::GetFullPath($value).TrimEnd('\') + '\').StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return "$name not redirected under the work directory" }
    }
    return $null
}

# Starts the copy on `Desktop` (named explicitly) in `Job`, with the probe's records, stderr logging and on-request
# render-trace snapshots on, the test tools' readback files when `CapturePath` is given and the P3 fixture's shell when
# `SeedPath` is. Its launch policy is left in $script:LastLaunchPolicy.
function Start-ProbeCopy([string] $Exe, [string] $Desktop, [string] $LogPath, [IntPtr] $Job, [string] $TracePath, [string] $CapturePath, [string] $SeedPath) {
    $refusal = Get-ProbeLaunchRefusal $Exe
    if ($refusal) { throw "The launcher refused the copy: $refusal." }
    $build = $(if ((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $script:MeasureExeSha256) { 'measurement' } else { 'test-tools' })
    $names = @('GHOSTTY_LOG', 'NOCTTY_GUI_PROBE_TRACE', 'NOCTTY_RENDER_TRACE_FILE', 'NOCTTY_RENDER_TRACE_LIVE', 'NOCTTY_RENDERER_CAPTURE_PATH', 'NOCTTY_RENDERER_STATUS_PATH')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:GHOSTTY_LOG = 'stderr'
        $env:NOCTTY_GUI_PROBE_TRACE = '1'
        $env:NOCTTY_RENDER_TRACE_FILE = $TracePath
        $env:NOCTTY_RENDER_TRACE_LIVE = '1'
        $env:NOCTTY_RENDERER_CAPTURE_PATH = $(if ($CapturePath) { $CapturePath } else { $null })
        $env:NOCTTY_RENDERER_STATUS_PATH = $(if ($CapturePath) { [IO.Path]::ChangeExtension($CapturePath, '.status.json') } else { $null })
        $launch = Get-CopyLaunch $Exe $SeedPath
        # Portable mode reads <copy>\config.ghostty; written fresh for each start.
        [IO.File]::WriteAllLines((Join-Path (Split-Path -Parent $Exe) 'config.ghostty'), [string[]]$launch.Config, [Text.UTF8Encoding]::new($false))
        $script:LastLaunchPolicy = $launch.Policy
        # What the gate checked, beside the arguments' policy.
        $script:LastLaunchPolicy.build = $build
        $script:LastLaunchPolicy.portable = $true
        $script:LastLaunchPolicy.iconAbsent = $true
        $script:LastLaunchPolicy.appAndCliMatchBuild = $true
        $script:LastLaunchPolicy.profileRedirected = $true
        $pi = [GuiProbeNative]::Start($Exe, $launch.Line, (Split-Path -Parent $Exe), $Desktop, $LogPath, $Job, $false)
        [void][GuiProbeNative]::CloseHandle($pi.thread)
        return $pi
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

function Wait-ProbeHost([int] $ProcessId, [int] $Seconds) {
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $hosts = @([HiddenLocal]::Hosts($ProcessId))
        if ($hosts.Count -gt 0 -and @([HiddenLocal]::Surfaces($hosts[0])).Count -gt 0) { return $hosts[0] }
        Start-Sleep -Milliseconds 200
    } while ([datetime]::UtcNow -lt $deadline)
    return [IntPtr]::Zero
}

# The copy's own records from its stderr log, and the control that the log was on at all.
function Read-ProbeLog([string] $Path) {
    # The copy may still hold the log open for writing: read it with read-write sharing (SOAK-01, trap 3).
    $text = ''
    if (Test-Path -LiteralPath $Path) {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
    }
    $hrInit = [regex]::Match($text, 'info\(gui_probe\): gui-probe hrinit hr=(0x[0-9a-f]{8})')
    return [ordered]@{
        # The log's own control: a line every start writes (App.init), so an absent probe line means absent.
        logOn = ($text -match 'info\(win32\): win32 os_build=')
        # One line per D3D11 device created (Direct3D11.zig init).
        warpDeviceLines = [regex]::Matches($text, 'initialized driver=WARP').Count
        hardwareDeviceLines = [regex]::Matches($text, 'initialized driver=hardware').Count
        # The renderer_windows scope's lines (every notice goes through setNotice): one, the WARP notice, and no other.
        rendererWindowsLines = [regex]::Matches($text, '(?m)^\w+\(renderer_windows\): ').Count
        warpNoticeLines = [regex]::Matches($text, '(?m)^warning\(renderer_windows\): D3D11 WARP \(software\): ').Count
        # Every logged backend switch or failed renderer candidate; with none, the WARP device is the one that drew.
        switchLines = [regex]::Matches($text, $script:BackendSwitchPattern).Count
        hrInit = $(if ($hrInit.Success) { $hrInit.Groups[1].Value } else { $null })
        taskbarInitFailedLine = ($text -match 'taskbar progress init failed')
    }
}

# The pane's rendered frame read back through the test tools, fresh each attempt (files removed, the retained frame
# redrawn), until it is the seeded fixture or 20 s pass. The readback holds the shell's text, so only counts leave it.
function Invoke-ProbeReadback([IntPtr] $Surface, [string] $CapturePath) {
    $statusPath = [IO.Path]::ChangeExtension($CapturePath, '.status.json')
    $facts = [ordered]@{ attempts = 0; answered = $false; captured = $false; seeded = $false }
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    do {
        foreach ($path in @($CapturePath, $statusPath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
        $facts.attempts++
        $facts.redrawAnswered = [GuiProbeNative]::Redraw($Surface)
        $facts.answered = [GuiProbeNative]::Readback($Surface)
        if ($facts.answered -and (Test-Path -LiteralPath $CapturePath) -and (Test-Path -LiteralPath $statusPath)) {
            $frame = [GuiProbeNative]::BmpStats($CapturePath, $script:SeedBackground)
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $facts.captured = $true
            $facts.width = $frame.Width; $facts.height = $frame.Height; $facts.colors = $frame.Colors
            $facts.dominant = '#{0:x6}' -f $frame.Dominant
            $facts.inkFraction = [Math]::Round(1 - $frame.Seed / [double]$frame.Pixels, 4)
            $facts.status = [ordered]@{
                backend = [string]$status.backend; warp = [bool]$status.warp; frames = [long]$status.frames
                drawCalls = [long]$status.draw_calls; presents = [long]$status.presents; occluded = [long]$status.occluded
                presentTests = [long]$status.present_tests; lastPresentStatus = Format-HResult ([long]$status.last_present_status)
            }
            # The seeded frame: the background seed is the most frequent colour, and the printed seed's text drew
            # others over it, past what a bare prompt reaches.
            $facts.seeded = $frame.Dominant -eq $script:SeedBackground -and $frame.Colors -ge 3 -and (1 - $frame.Seed / [double]$frame.Pixels) -ge $script:SeedInkFloor
            if ($facts.seeded) { break }
        }
        Start-Sleep -Milliseconds 500
    } while ([datetime]::UtcNow -lt $deadline)
    return $facts
}

function Read-RenderTrace([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [ordered]@{ written = $false; paintDraws = $null; swapBuffers = $null } }
    $trace = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return [ordered]@{ written = $true; paintDraws = [long]$trace.paint_draw_count; swapBuffers = [long]$trace.swap_buffers_count }
}

# The toast setting and history counts for the measurement build's two identities, read by Windows PowerShell 5.1
# (WinRT's projection) on whatever desktop this process is on.
function Get-ToastFacts([string] $Desktop, [IntPtr] $Job) {
    $script = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$rows = foreach ($pair in @(@('product', 'io.github.amanthanvi.noctty'), @('measure', 'io.github.amanthanvi.noctty.measure'))) {
    $row = [ordered]@{ identity = $pair[0]; setting = $null; settingHresult = $null; history = $null; historyHresult = $null }
    try { $row.setting = [string][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($pair[1]).Setting } catch { $row.settingHresult = '0x{0:x8}' -f $_.Exception.HResult }
    try { $row.history = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($pair[1])).Count } catch { $row.historyHresult = '0x{0:x8}' -f $_.Exception.HResult }
    $row
}
[Console]::Out.Write((ConvertTo-Json -InputObject @($rows) -Compress))
'@
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $outPath = Join-Path $script:RunRoot ("toast-" + [guid]::NewGuid().ToString('N') + '.json')
    $pi = [GuiProbeNative]::Start($powershell, ('"{0}" -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand {1}' -f $powershell, $encoded), $script:RunRoot, $Desktop, $outPath, $Job, $true)
    try {
        if ([GuiProbeNative]::WaitForSingleObject($pi.process, 60000) -ne 0) { [void][GuiProbeNative]::StopExact($pi.pid, [GuiProbeNative]::CreationTime($pi.pid), $Job); return @{ error = 'timeout' } }
        # Windows PowerShell can still frame redirected output with a CLIXML progress record: take the array itself.
        $match = [regex]::Match([IO.File]::ReadAllText($outPath), '\[\{"identity".*?\}\]')
        if (-not $match.Success) { return @{ error = 'no-json' } }
        $facts = [ordered]@{}
        foreach ($row in ($match.Value | ConvertFrom-Json)) {
            $facts[$row.identity] = [ordered]@{ setting = $row.setting; settingHresult = $row.settingHresult; history = $row.history; historyHresult = $row.historyHresult }
        }
        return $facts
    } finally { [void][GuiProbeNative]::CloseHandle($pi.thread); [void][GuiProbeNative]::CloseHandle($pi.process) }
}

# Every process of the job now, with its role, its startup desktop and its threads' desktops.
function Get-JobProcessRows([IntPtr] $Job, [int] $CopyPid, [string] $Private) {
    $all = @{}
    foreach ($row in [GuiProbeNative]::Processes()) { $all[$row.Pid] = $row }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($id in [GuiProbeNative]::JobPids($Job)) {
        $entry = $all[$id]
        $role = 'other'
        if ($id -eq $PID) { $role = 'driver' }
        elseif ($id -eq $CopyPid) { $role = 'noctty' }
        else {
            $hop = $entry
            for ($depth = 0; $null -ne $hop -and $depth -lt 16; $depth++) {
                if ($hop.Parent -eq $CopyPid) { $role = 'noctty-descendant'; break }
                if ($hop.Parent -eq $PID) { $role = 'driver-child'; break }
                $hop = $all[$hop.Parent]
            }
        }
        $threadKinds = [Collections.Generic.List[string]]::new()
        $without = 0
        foreach ($tid in [GuiProbeNative]::Threads($id)) {
            $name = [GuiProbeNative]::ThreadDesktop($tid)
            if ($null -eq $name) { $without++ } else { $threadKinds.Add((Get-DesktopKind $name $Private)) }
        }
        $rows.Add([ordered]@{
            pid = $id
            creation = [GuiProbeNative]::CreationTime($id)
            image = $(if ($entry) { $entry.Image } else { $null })
            role = $role
            startupDesktop = Get-DesktopKind ([GuiProbeNative]::StartupDesktop($id)) $Private
            threadDesktops = @($threadKinds | Sort-Object -Unique)
            threadsWithoutDesktop = $without
        })
    }
    return $rows
}

# Every top-level window of the job's processes on the private and the Default desktop.
function Get-JobWindowRows($Processes, [string] $Private) {
    $byPid = @{}
    foreach ($row in $Processes) { $byPid[$row.pid] = $row }
    $rows = [Collections.Generic.List[object]]::new()
    $counts = [ordered]@{}
    foreach ($desktop in @($Private, 'Default')) {
        $win32Error = 0
        $windows = [GuiProbeNative]::DesktopWindows($desktop, [ref]$win32Error)
        $kind = Get-DesktopKind $desktop $Private
        $counts[$kind] = $(if ($null -eq $windows) { "unavailable $win32Error" } else { 0 })
        foreach ($window in @($windows)) {
            if ($null -eq $window -or -not $byPid.ContainsKey($window.Pid)) { continue }
            $counts[$kind]++
            $rows.Add([ordered]@{ desktop = $kind; class = $window.Class; ownerImage = $byPid[$window.Pid].image; ownerRole = $byPid[$window.Pid].role; visible = $window.Visible })
        }
    }
    # Complete only when both desktops were opened and enumerated; an empty but successful one counts.
    $complete = @($counts.Values | Where-Object { $_ -isnot [int] }).Count -eq 0
    return [ordered]@{ windows = $rows; counts = $counts; complete = $complete }
}

# Ends each listed process by exact PID (its creation time checked), the copy's descendants first, then the copy.
function Stop-ProbeProcesses($Processes, [IntPtr] $Job) {
    $outcomes = [ordered]@{}
    foreach ($row in @($Processes | Where-Object { $_.role -eq 'noctty-descendant' }) + @($Processes | Where-Object { $_.role -eq 'noctty' })) {
        $outcome = [GuiProbeNative]::StopExact($row.pid, $row.creation, $Job)
        $outcomes[$outcome] = 1 + [int]$outcomes[$outcome]
    }
    return $outcomes
}

# Ends the copy with WM_CLOSE to its windows (a normal exit, which writes the render trace's last snapshot); true
# when it exited within the bound.
function Close-ProbeCopy($Pi, [int] $Seconds) {
    foreach ($h in @([HiddenLocal]::Hosts($Pi.pid))) { [void][GuiProbeNative]::PostClose($h) }
    return [GuiProbeNative]::WaitForSingleObject($Pi.process, [uint32]($Seconds * 1000)) -eq 0
}

# The render trace as the copy last wrote it, or null while it is absent or mid-write.
function Read-ProbeTraceFile([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $raw = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

# A fresh snapshot of the pane's render trace: requested from its surface and taken only once its sequence passes
# `AfterSequence` (Request-FirstFrameTrace in interactive-win11-first-frame.ps1). Null when none arrives.
function Request-ProbeTraceSnapshot([IntPtr] $Surface, [string] $Path, [uint64] $AfterSequence) {
    if (-not [GuiProbeNative]::RequestTraceSnapshot($Surface)) { return $null }
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    do {
        $snapshot = Read-ProbeTraceFile $Path
        if ($null -ne $snapshot -and [uint64]$snapshot.snapshot_sequence -gt $AfterSequence) { return $snapshot }
        Start-Sleep -Milliseconds 20
    } while ([datetime]::UtcNow -lt $deadline)
    return $null
}

function Get-TraceSequence([string] $Path) {
    $current = Read-ProbeTraceFile $Path
    return $(if ($null -ne $current) { [uint64]$current.snapshot_sequence } else { [uint64]0 })
}

function Get-SnapshotFacts($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    return [ordered]@{
        sequence = [long]$Snapshot.snapshot_sequence; swapBuffers = [long]$Snapshot.swap_buffers_count
        lastSwapOutputBytes = [long]$Snapshot.last_swap_process_output_bytes; paintDraws = [long]$Snapshot.paint_draw_count
    }
}

# Fresh snapshots until the pane has presented a frame that committed at least `MinBytes` of shell output, or 20 s
# pass; then, `SettleSeconds` later, one more, the observed value. The facts of the last snapshot taken.
function Wait-ProbePresented([IntPtr] $Surface, [string] $Path, [long] $MinBytes, [int] $SettleSeconds) {
    $sequence = Get-TraceSequence $Path
    $last = $null
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    do {
        $snapshot = Request-ProbeTraceSnapshot $Surface $Path $sequence
        if ($null -ne $snapshot) {
            $last = $snapshot; $sequence = [uint64]$snapshot.snapshot_sequence
            if ([long]$snapshot.swap_buffers_count -ge 1 -and [long]$snapshot.last_swap_process_output_bytes -ge $MinBytes) { break }
        }
        Start-Sleep -Milliseconds 250
    } while ([datetime]::UtcNow -lt $deadline)
    if ($SettleSeconds -gt 0) {
        Start-Sleep -Seconds $SettleSeconds
        $snapshot = Request-ProbeTraceSnapshot $Surface $Path $sequence
        if ($null -ne $snapshot) { $last = $snapshot }
    }
    return Get-SnapshotFacts $last
}

# ---- the driver half (on the private desktop, inside the job Invoke-LocalHiddenDriver owns)

function Invoke-ProbeDriver {
    $script:RunRoot = $Run
    $result = [ordered]@{ task = $Task }
    try {
        $own = [GuiProbeNative]::OwnDesktop()
        if (-not [string]::Equals($own, $DesktopName, [StringComparison]::Ordinal)) { throw 'The driver is not on its private desktop.' }
        $result.session = Get-SessionFacts $DesktopName
        # The PEB reader's own control: this driver was created on its desktop by name.
        $result.startupDesktopReaderCheck = [string]::Equals([GuiProbeNative]::StartupDesktop($PID), "WinSta0\$DesktopName", [StringComparison]::Ordinal)
        $exe = Join-Path $Bin 'noctty.exe'

        if ($Task -eq 'q0') {
            # Positive control (M1): an ordinary launch, no desktop named, from a driver created on this one.
            $report = Join-Path $Run 'child-positive.txt'
            $pwsh = (Get-Command pwsh.exe).Source
            $child = [GuiProbeNative]::Start($pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -ReportDesktop "{2}"' -f $pwsh, $PSCommandPath, $report), $Run, $null, $null, [IntPtr]::Zero, $true)
            [void][GuiProbeNative]::WaitForSingleObject($child.process, 60000)
            [void][GuiProbeNative]::CloseHandle($child.thread); [void][GuiProbeNative]::CloseHandle($child.process)
            $result.positiveChildDesktop = Get-DesktopKind $(if (Test-Path -LiteralPath $report) { [IO.File]::ReadAllText($report) } else { $null }) $DesktopName

            $pi = Start-ProbeCopy -Exe $exe -Desktop "WinSta0\$DesktopName" -LogPath (Join-Path $Run 'noctty-q0.log') -Job ([IntPtr]::Zero) -TracePath (Join-Path $Run 'render-q0.json')
            $result.launchPolicy = $script:LastLaunchPolicy
            $hostWindow = Wait-ProbeHost $pi.pid 45
            $result.copyReady = $hostWindow -ne [IntPtr]::Zero
            $result.shell = Get-ShellLaunchFacts $pi.pid $false
            # The ConPTY host and the shell start with the first pane; give them a moment.
            $deadline = [datetime]::UtcNow.AddSeconds(20)
            do {
                $tree = @([GuiProbeNative]::Processes() | Where-Object { $_.Parent -eq $pi.pid })
                if ($tree.Count -gt 0) { break }
                Start-Sleep -Milliseconds 250
            } while ([datetime]::UtcNow -lt $deadline)
            Start-Sleep -Seconds 2
            $processes = Get-JobProcessRows ([IntPtr]::Zero) $pi.pid $DesktopName
            $windows = Get-JobWindowRows $processes $DesktopName
            $result.processes = @($processes | ForEach-Object { [ordered]@{ image = $_.image; role = $_.role; startupDesktop = $_.startupDesktop; threadDesktops = $_.threadDesktops; threadsWithoutDesktop = $_.threadsWithoutDesktop } })
            $result.windows = $windows.windows
            $result.windowCounts = $windows.counts
            $result.inventoryComplete = $windows.complete
            $result.log = Read-ProbeLog (Join-Path $Run 'noctty-q0.log')
            $result.stopped = Stop-ProbeProcesses $processes ([IntPtr]::Zero)
            $left = @(@([GuiProbeNative]::JobPids([IntPtr]::Zero)) | Where-Object { $_ -ne $PID -and ($processes | Where-Object { $_.role -in @('noctty', 'noctty-descendant') }).pid -contains $_ })
            $result.leftAfterStop = $left.Count
            [void][GuiProbeNative]::CloseHandle($pi.process)
        } else {
            # The probe window's own plumbing, which P1 relies on, without any input: a window and its EDIT,
            # text set and read back exactly, closed.
            $selfText = 'Ab9' + [char]0x00E9 + [char]0xD83D + [char]0xDE00 + "`t"
            $window = $null
            try {
                $window = [GuiProbeNative]::Open('NocttyGuiProbeSelfTest', 0xFFFFFF, 40, 40, 300, 200, $true)
                [void][GuiProbeNative]::SetText($window, $selfText)
                $result.windowSelfTest = [string]::Equals([GuiProbeNative]::Text($window), $selfText, [StringComparison]::Ordinal)
            } catch { $result.windowSelfTest = $false } finally { [GuiProbeNative]::Close($window) }
            # The private-desktop controls of P3, P4 and P5; the withheld arm prints no seed (P3's readback control).
            $withheld = $Task -eq 'private-renderer-withheld'
            $result.withheld = $withheld
            if (-not $withheld) { $result.toast = Get-ToastFacts -Desktop $null -Job ([IntPtr]::Zero) }
            $seed = Join-Path $Run 'seed.txt'
            Write-ProbeSeed $seed $withheld
            $trace = Join-Path $Run 'render-private.json'
            $capture = Join-Path $Run 'frame-private.bmp'
            $pi = Start-ProbeCopy -Exe $exe -Desktop "WinSta0\$DesktopName" -LogPath (Join-Path $Run 'noctty-private.log') -Job ([IntPtr]::Zero) -TracePath $trace -CapturePath $capture -SeedPath $seed
            $result.launchPolicy = $script:LastLaunchPolicy
            $hostWindow = Wait-ProbeHost $pi.pid 45
            $result.copyReady = $hostWindow -ne [IntPtr]::Zero
            $result.shell = Get-ShellLaunchFacts $pi.pid $true
            if ($result.copyReady) {
                $surface = @([HiddenLocal]::Surfaces($hostWindow))[0]
                $result.readback = Invoke-ProbeReadback $surface $capture
                # A fresh snapshot, requested after the readback: its swap count is the observed value.
                $result.snapshotAfterReadback = Get-SnapshotFacts (Request-ProbeTraceSnapshot $surface $trace (Get-TraceSequence $trace))
            }
            Start-Sleep -Seconds 2
            $result.normalExit = Close-ProbeCopy $pi 20
            $result.exitCode = [GuiProbeNative]::ExitCode($pi.process)
            $result.log = Read-ProbeLog (Join-Path $Run 'noctty-private.log')
            $result.trace = Read-RenderTrace $trace
            $processes = Get-JobProcessRows ([IntPtr]::Zero) $pi.pid $DesktopName
            $result.stopped = Stop-ProbeProcesses $processes ([IntPtr]::Zero)
            [void][GuiProbeNative]::CloseHandle($pi.process)
            # P5's private sample after a normal exit only; a forced stop is no such sample.
            if (-not $withheld) { $result.toastAfterNormalExit = $(if ($result.normalExit) { Get-ToastFacts -Desktop $null -Job ([IntPtr]::Zero) } else { $null }) }
        }
        $result.error = $null
    } catch {
        $result.error = 'driver failed'
        [IO.File]::WriteAllText((Join-Path $Run 'driver-error.txt'), $_.Exception.Message)
    }
    Write-ProbeRecord $result (Join-Path $Run "driver-$Task.json")
    return $(if ($result.error) { 1 } else { 0 })
}

if ($Driver) {
    $script:MeasureExeSha256 = $MeasureSha256; $script:MeasureCliSha256 = $MeasureCliSha256
    $script:TestToolsExeSha256 = $TestToolsSha256; $script:TestToolsCliSha256 = $TestToolsCliSha256
    $script:WorkRoot = $Run
    exit (Invoke-ProbeDriver)
}

# ---- the outer half

# A real-profile guard that did not hold (the real startup state, PSReadLine history or clipboard sequence changed, the
# owned job was not cleaned up, or the run left no guard state): the run's record keeps the evidence, and no later
# copy starts.
function Assert-ProbeGuards($Run, [string] $Name) {
    $guards = $Run.guards
    $held = $null -ne $guards -and [bool]$guards.startupUnchanged -and [bool]$guards.historyUnchanged -and
        [bool]$guards.clipboardUnchanged -and [bool]$guards.ownedJobCleanedUp
    if (-not $held) {
        $script:GuardTripped = $Name
        throw "A real-profile guard did not hold after $Name; no further copy starts."
    }
}

function Invoke-ProbeDriverRun([string] $Name, [string] $StageBin, [string] $TaskName) {
    $runDir = Join-Path $Work $Name
    $guards = $null
    $failure = $null
    try {
        Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $StageBin -Run $runDir -DesktopPrefix 'noctty-gui-probe-' -TimeoutSeconds 240 `
            -Label "GUI probe $Name" -PassDesktopName -GuardClipboard `
            -DriverArguments @("-Task $TaskName", "-MeasureSha256 $script:MeasureExeSha256", "-MeasureCliSha256 $script:MeasureCliSha256",
                $(if ($script:TestToolsExeSha256) { "-TestToolsSha256 $script:TestToolsExeSha256 -TestToolsCliSha256 $script:TestToolsCliSha256" }))
    } catch { $failure = 'the hidden driver or its guards failed' ; [IO.File]::WriteAllText((Join-Path $Work "$Name-outer-error.txt"), $_.Exception.Message) }
    $statePath = Join-Path $runDir 'startup-state.json'
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $guards = [ordered]@{
            startupUnchanged = [bool]$state.Unchanged; historyUnchanged = [bool]$state.HistoryUnchanged
            clipboardUnchanged = [bool]$state.ClipboardUnchanged; ownedJobCleanedUp = [bool]$state.OwnedJobCleanedUp
        }
    }
    $driverPath = Join-Path $runDir "driver-$TaskName.json"
    $driverRecord = if (Test-Path -LiteralPath $driverPath) { Get-Content -LiteralPath $driverPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
    return [ordered]@{ outer = $failure; guards = $guards; driver = $driverRecord }
}

# The negative control: a thread of this process moved to a second private desktop starts a child without naming one.
function Invoke-NegativeControl {
    $name = 'noctty-gui-probe-neg-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($name, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { return [ordered]@{ error = 'CreateDesktop failed' } }
    try {
        $report = Join-Path $Work 'child-negative.txt'
        $pwsh = (Get-Command pwsh.exe).Source
        $moveError = 0
        $child = [GuiProbeNative]::StartFromMovedThread($desktop, $pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -ReportDesktop "{2}"' -f $pwsh, $PSCommandPath, $report), $Work, [ref]$moveError)
        [void][GuiProbeNative]::WaitForSingleObject($child.process, 60000)
        [void][GuiProbeNative]::CloseHandle($child.thread); [void][GuiProbeNative]::CloseHandle($child.process)
        return [ordered]@{
            threadMovedError = $moveError
            childDesktop = Get-DesktopKind $(if (Test-Path -LiteralPath $report) { [IO.File]::ReadAllText($report) } else { $null }) $name
        }
    } finally { [void][HiddenLocal]::CloseDesktop($desktop) }
}

# A log whose copy drew only through WARP for the whole run: the device line, no hardware device, the renderer_windows
# scope's one line the WARP notice, and no backend switch anywhere.
function Test-WarpOnlyLog($Log) {
    return $null -ne $Log -and [bool]$Log.logOn -and $Log.warpDeviceLines -ge 1 -and $Log.hardwareDeviceLines -eq 0 -and
        $Log.rendererWindowsLines -eq 1 -and $Log.warpNoticeLines -eq 1 -and $Log.switchLines -eq 0
}

# The launcher gate's control, before any launch and starting nothing: the measurement copy is accepted, and each
# other kind refused for its own reason.
function Invoke-LauncherControl([string] $StageBin, [string] $TestToolsStageBin) {
    $root = Join-Path $Work 'launcher-control'
    $candidate = {
        param([string] $Name, [string] $Source, [bool] $Marker, [bool] $Icon, [string] $Cli = (Join-Path $StageBin 'noctty.com'))
        $dir = Join-Path $root $Name
        [void](New-Item -ItemType Directory -Path $dir)
        Copy-Item -LiteralPath $Source -Destination (Join-Path $dir 'noctty.exe')
        if ($Cli) { Copy-Item -LiteralPath $Cli -Destination (Join-Path $dir 'noctty.com') }
        if ($Marker) { Set-Content -LiteralPath (Join-Path $dir 'noctty.portable') -Value '' -NoNewline }
        if ($Icon) { [IO.File]::WriteAllBytes((Join-Path $dir 'noctty.ico'), [byte[]]@(0)) }
        return (Join-Path $dir 'noctty.exe')
    }
    $measure = Join-Path $StageBin 'noctty.exe'
    $expected = [ordered]@{
        measurementPortable = 'accepted'; withoutMarker = 'not a portable copy'; withIcon = 'carries noctty.ico'
        otherBinary = 'not an allowed build'; realLocalAppData = 'LOCALAPPDATA not redirected under the work directory'
        measurementModeUnset = 'measurement mode not set'
        cliMissing = 'CLI not the allowed build'; cliMismatch = 'CLI not the allowed build'
    }
    if ($TestToolsStageBin) { $expected.testToolsBuild = $(if (Test-ProbeHosted) { 'accepted' } else { 'not an allowed build' }) }
    $cases = [ordered]@{}
    $savedLocal = $env:LOCALAPPDATA; $savedRoaming = $env:APPDATA
    try {
        $env:LOCALAPPDATA = Join-Path $root 'localappdata'; $env:APPDATA = Join-Path $root 'appdata'
        $allowed = & $candidate 'measurement-portable' $measure $true $false
        $cases.measurementPortable = Get-ProbeLaunchRefusal $allowed
        # An ordinary zig-out shape: the same exe with no portable marker.
        $cases.withoutMarker = Get-ProbeLaunchRefusal (& $candidate 'without-marker' $measure $false $false)
        $cases.withIcon = Get-ProbeLaunchRefusal (& $candidate 'with-icon' $measure $true $true)
        # Another binary, portable-shaped: the measurement bin's CLI wrapper under the exe's name.
        $cases.otherBinary = Get-ProbeLaunchRefusal (& $candidate 'other-binary' (Join-Path $StageBin 'noctty.com') $true $false)
        # The measurement app with no CLI beside it, and with another file under the CLI's name.
        $cases.cliMissing = Get-ProbeLaunchRefusal (& $candidate 'cli-missing' $measure $true $false '')
        $cases.cliMismatch = Get-ProbeLaunchRefusal (& $candidate 'cli-mismatch' $measure $true $false $measure)
        if ($TestToolsStageBin) { $cases.testToolsBuild = Get-ProbeLaunchRefusal (& $candidate 'test-tools' (Join-Path $TestToolsStageBin 'noctty.exe') $true $false (Join-Path $TestToolsStageBin 'noctty.com')) }
        $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = $null
        $cases.measurementModeUnset = Get-ProbeLaunchRefusal $allowed
        $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
        $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming
        $cases.realLocalAppData = Get-ProbeLaunchRefusal $allowed
    } finally { $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming; $env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1' }
    $outcomes = [ordered]@{}
    $pass = $true
    foreach ($key in $expected.Keys) {
        $outcomes[$key] = $(if ($null -eq $cases[$key]) { 'accepted' } else { $cases[$key] })
        if ($outcomes[$key] -cne $expected[$key]) { $pass = $false }
    }
    return [ordered]@{ outcomes = $outcomes; verdict = $(if ($pass) { 'pass' } else { 'fail' }) }
}

function Get-Verdict([bool] $Positive, [bool] $Control, [bool] $HaveRecords) {
    if (-not $HaveRecords) { return 'inconclusive' }
    if ($Positive -and $Control) { return 'pass' }
    return 'fail'
}

# One Default-desktop copy of the test-tools build in an owned job, ended by WM_CLOSE. The seeded arm waits for a
# presented frame that committed the seed; the withheld arm for any presented output, then settles 5 s so its shell
# has printed all it will. Only the seeded arm reads the toast facts (P5).
function Invoke-DefaultCopy([string] $TestToolsStageBin, [string] $Name, [bool] $Withheld) {
    $defaultRun = Join-Path $Work $Name
    [void](New-Item -ItemType Directory -Path $defaultRun)
    $script:RunRoot = $defaultRun
    Copy-Portable $TestToolsStageBin (Join-Path $defaultRun 'copy\bin')
    foreach ($name in @('localappdata', 'appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $defaultRun $name)) }
    $job = [HiddenLocal]::CreateOwnedJob()
    $savedLocal = $env:LOCALAPPDATA; $savedRoaming = $env:APPDATA
    $run = [ordered]@{ withheld = $Withheld }
    $clipboardBefore = [HiddenLocal]::GetClipboardSequenceNumber()
    # The same real-profile guards Invoke-LocalHiddenDriver keeps for a private run.
    $startupBefore = Startup-Fingerprint
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness (Split-Path -Leaf $PSCommandPath)
    $cleanupFailed = $false
    try {
        if (-not $Withheld) { $run.toastBefore = Get-ToastFacts -Desktop 'WinSta0\Default' -Job $job }
        $seed = Join-Path $defaultRun 'seed.txt'
        Write-ProbeSeed $seed $Withheld
        $env:LOCALAPPDATA = Join-Path $defaultRun 'localappdata'; $env:APPDATA = Join-Path $defaultRun 'appdata'
        $trace = Join-Path $defaultRun 'render.json'
        $capture = Join-Path $defaultRun 'frame.bmp'
        $pi = Start-ProbeCopy -Exe (Join-Path $defaultRun 'copy\bin\noctty.exe') -Desktop 'WinSta0\Default' -LogPath (Join-Path $defaultRun 'noctty.log') -Job $job -TracePath $trace -CapturePath $capture -SeedPath $seed
        $run.launchPolicy = $script:LastLaunchPolicy
        $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming
        $hostWindow = Wait-ProbeHost $pi.pid 45
        $run.copyReady = $hostWindow -ne [IntPtr]::Zero
        $run.shell = Get-ShellLaunchFacts $pi.pid $true
        if ($run.copyReady) {
            $surface = @([HiddenLocal]::Surfaces($hostWindow))[0]
            $run.snapshot = $(if ($Withheld) { Wait-ProbePresented $surface $trace 1 5 } else { Wait-ProbePresented $surface $trace $script:SeedBytes 0 })
            $run.readback = Invoke-ProbeReadback $surface $capture
        }
        $run.normalExit = Close-ProbeCopy $pi 20
        $run.exitCode = [GuiProbeNative]::ExitCode($pi.process)
        $run.log = Read-ProbeLog (Join-Path $defaultRun 'noctty.log')
        $run.trace = Read-RenderTrace $trace
        $left = @([GuiProbeNative]::JobPids($job) | ForEach-Object { [ordered]@{ pid = $_; creation = [GuiProbeNative]::CreationTime($_); role = 'noctty-descendant' } })
        $run.stopped = Stop-ProbeProcesses $left $job
        [void][GuiProbeNative]::CloseHandle($pi.process)
        # P5's after sample only after a normal exit; a forced stop is no such sample.
        if (-not $Withheld) { $run.toastAfter = $(if ($run.normalExit) { Get-ToastFacts -Desktop 'WinSta0\Default' -Job $job } else { $null }) }
    } catch {
        $run.failed = $true
        Write-Host "gui probe: the Default-desktop copy $Name failed: $($_.Exception.Message)"
    } finally {
        $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming
        try { $run.ownedJobProcesses = [HiddenLocal]::StopOwnedJob($job) } catch { $cleanupFailed = $true }
    }
    $startupAfter = Startup-Fingerprint
    $historyHeld = $true
    try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyHeld = $false }
    $run.clipboardUnchanged = $clipboardBefore -eq [HiddenLocal]::GetClipboardSequenceNumber()
    $run.guards = [ordered]@{
        startupUnchanged = ($startupBefore.Exists -eq $startupAfter.Exists -and $startupBefore.Hash -eq $startupAfter.Hash -and $startupBefore.Modified -eq $startupAfter.Modified)
        historyUnchanged = $historyHeld; clipboardUnchanged = $run.clipboardUnchanged; ownedJobCleanedUp = -not $cleanupFailed
    }
    return $run
}

function Invoke-D3([string] $StageBin, [string] $TestToolsStageBin, $Record) {
    # The outer record holds this map from the start, so each finished arm survives a later arm's failure.
    $d3 = [ordered]@{}
    $Record.d3 = $d3
    $d3.dpiAwareError = [GuiProbeNative]::PerMonitorAware()
    $d3.session = Get-SessionFacts ''
    $onInput = [bool]$d3.session.onInputDesktop
    Add-Type -AssemblyName System.Drawing

    # P1, real SendInput.
    $script:Stage = 'd3-p1'
    $text = "Ab9" + [char]0x00E9 + [char]0xD83D + [char]0xDE00 + "`t"
    $p1 = [ordered]@{ units = $text.Length; injected = $false }
    if ($onInput) {
        $probe = $null; $cover = $null
        try {
            $probe = [GuiProbeNative]::Open('NocttyGuiProbeInput', 0xFFFFFF, 80, 80, 420, 240, $true)
            $altSent = [uint32]0; $setResult = $false
            $p1.foreground = [GuiProbeNative]::Foreground($probe.Hwnd, [ref]$altSent, [ref]$setResult)
            $p1.altTapSent = $altSent; $p1.setForegroundResult = $setResult
            # The keyboard focus must be the probe's EDIT before anything is sent (Greptile).
            $p1.focusOnEdit = [GuiProbeNative]::FocusOnEdit($probe)
            if ($p1.foreground -and $p1.focusOnEdit) {
                $win32Error = 0
                $p1.sent = [GuiProbeNative]::SendUnicode($text, [ref]$win32Error); $p1.lastError = $win32Error; $p1.injected = $true
                $null = Wait-Until { [string]::Equals([GuiProbeNative]::Text($probe), $text, [StringComparison]::Ordinal) } 5
                $received = [GuiProbeNative]::Text($probe)
                $p1.receivedExactly = [string]::Equals($received, $text, [StringComparison]::Ordinal)
                $p1.receivedUnits = @($(if ($null -ne $received) { $received.ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ } }))
                # Control: a second window in front; the probe's text must not change.
                $cover = [GuiProbeNative]::Open('NocttyGuiProbeCover', 0xFFFFFF, 120, 120, 420, 240, $true)
                $p1.coverForeground = [GuiProbeNative]::Foreground($cover.Hwnd, [ref]$altSent, [ref]$setResult)
                $p1.coverFocusOnEdit = [GuiProbeNative]::FocusOnEdit($cover)
                $p1.coverSent = [GuiProbeNative]::SendUnicode('zz', [ref]$win32Error)
                Start-Sleep -Milliseconds 800
                $p1.probeUnchangedWithCoverInFront = [string]::Equals([GuiProbeNative]::Text($probe), $received, [StringComparison]::Ordinal)
                $p1.coverReceived = [string]::Equals([GuiProbeNative]::Text($cover), 'zz', [StringComparison]::Ordinal)
            }
        } catch {
            $p1.failed = $true
            Write-Host "gui probe: P1 failed: $($_.Exception.Message)"
        } finally { [GuiProbeNative]::Close($cover); [GuiProbeNative]::Close($probe) }
    }
    # The control counts only when the cover itself took the stimulus: in front, its EDIT focused, and `zz` in it.
    $p1.verdict = Get-Verdict ([bool]$p1.receivedExactly) ([bool]$p1.coverForeground -and [bool]$p1.coverFocusOnEdit -and [bool]$p1.coverReceived -and [bool]$p1.probeUnchangedWithCoverInFront) ([bool]$p1.injected)
    $d3.p1 = $p1

    # P2, the screen read back, one pixel at a time on a 5 x 5 grid of the window's client area.
    $script:Stage = 'd3-p2'
    $p2 = [ordered]@{}
    $color = $null; $coverWindow = $null
    $pixel = [Drawing.Bitmap]::new(1, 1)
    $graphics = [Drawing.Graphics]::FromImage($pixel)
    # The fraction of the fixed screen points that read #FF00FF.
    $sample = {
        param($Points)
        $hits = 0
        foreach ($point in $Points) {
            $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, [Drawing.Size]::new(1, 1))
            $c = $pixel.GetPixel(0, 0)
            if ($c.R -eq 255 -and $c.G -eq 0 -and $c.B -eq 255) { $hits++ }
        }
        return $hits / [double]@($Points).Count
    }
    try {
        # COLORREF is 0x00BBGGRR: #FF00FF.
        $color = [GuiProbeNative]::Open('NocttyGuiProbeColor', 0xFF00FF, 160, 160, 400, 300, $false)
        $altSent = [uint32]0; $setResult = $false
        $p2.foreground = [GuiProbeNative]::Foreground($color.Hwnd, [ref]$altSent, [ref]$setResult)
        Start-Sleep -Milliseconds 500
        # The same 25 screen points for every read, taken while the window shows.
        $points = @(for ($row = 0; $row -lt 5; $row++) { for ($column = 0; $column -lt 5; $column++) { [GuiProbeNative]::GridPoint($color, 5, $row, $column) } })
        $p2.magentaFraction = & $sample $points
        # Controls: another window over it, then the window minimised.
        $coverWindow = [GuiProbeNative]::Open('NocttyGuiProbeCoverColor', 0x00FF00, 140, 140, 440, 340, $false)
        Start-Sleep -Milliseconds 500
        $p2.coveredMagentaFraction = & $sample $points
        [GuiProbeNative]::Close($coverWindow); $coverWindow = $null
        [GuiProbeNative]::Minimise($color)
        Start-Sleep -Milliseconds 800
        $p2.minimisedMagentaFraction = & $sample $points
    } catch {
        $p2.failed = $true
        Write-Host "gui probe: P2 failed: $($_.Exception.Message)"
    } finally {
        [GuiProbeNative]::Close($coverWindow)
        [GuiProbeNative]::Close($color)
        $graphics.Dispose(); $pixel.Dispose()
    }
    # Every sample must exist; a measured zero is a value, a missing sample is not.
    $p2Samples = $null -ne $p2.magentaFraction -and $null -ne $p2.coveredMagentaFraction -and $null -ne $p2.minimisedMagentaFraction
    $p2.verdict = Get-Verdict ($p2.magentaFraction -ge 0.9) ($p2Samples -and $p2.coveredMagentaFraction -le 0.1 -and $p2.minimisedMagentaFraction -le 0.1) $p2Samples
    $d3.p2 = $p2

    # P3, P4 and P5 on this (Default) desktop: the seeded fixture, then the same with the seed withheld.
    $script:Stage = 'd3-default'
    $interactive = Invoke-DefaultCopy $TestToolsStageBin 'default' $false
    $d3.default = $interactive
    Assert-ProbeGuards $interactive 'd3-default'
    $script:Stage = 'd3-default-withheld'
    $withheldRun = Invoke-DefaultCopy $TestToolsStageBin 'default-withheld' $true
    $d3.defaultWithheld = $withheldRun
    Assert-ProbeGuards $withheldRun 'd3-default-withheld'

    $script:Stage = 'd3-private'
    $privateRun = Invoke-ProbeDriverRun 'private' $TestToolsStageBin 'private-renderer'
    $d3.private = $privateRun
    Assert-ProbeGuards $privateRun 'd3-private'
    $script:Stage = 'd3-private-withheld'
    $privateWithheldRun = Invoke-ProbeDriverRun 'private-withheld' $TestToolsStageBin 'private-renderer-withheld'
    $d3.privateWithheld = $privateWithheldRun
    Assert-ProbeGuards $privateWithheldRun 'd3-private-withheld'

    $defaultLog = $interactive.log; $privateLog = $privateRun.driver.log
    $privateReadback = $privateRun.driver.readback; $privateAfter = $privateRun.driver.snapshotAfterReadback
    # P3 (design v5 §9). The visible arm: the seed was presented, a fresh snapshot's last swap committed at least the
    # seed's bytes. Its controls: the withheld seed stays below them (a bare clear cannot pass); the private arm's
    # fresh readback of the same build and fixture is the seeded frame and a snapshot taken after it counts no swap;
    # and the private withheld readback misses the seed's floor. WARP-only logs for every arm's whole run.
    $p3Records = $null -ne $interactive.snapshot -and $null -ne $withheldRun.snapshot -and [bool]$privateReadback.captured -and
        $null -ne $privateAfter -and [bool]$privateWithheldRun.driver.readback.captured -and
        [bool]$defaultLog.logOn -and [bool]$withheldRun.log.logOn -and [bool]$privateLog.logOn -and [bool]$privateWithheldRun.driver.log.logOn
    $d3.p3 = [ordered]@{
        seedBytes = $script:SeedBytes
        seededLastSwapOutputBytes = $interactive.snapshot.lastSwapOutputBytes; seededSwaps = $interactive.snapshot.swapBuffers
        withheldLastSwapOutputBytes = $withheldRun.snapshot.lastSwapOutputBytes; withheldSwaps = $withheldRun.snapshot.swapBuffers
        privateReadbackSeeded = $privateReadback.seeded; privateSwapsAfterReadback = $privateAfter.swapBuffers
        privateWithheldReadbackSeeded = $privateWithheldRun.driver.readback.seeded
        # Every arm's shell, read by PID: System32's cmd.exe with /D ahead of the `/K type` payload.
        shellPolicyHeld = (@($interactive.shell, $withheldRun.shell, $privateRun.driver.shell, $privateWithheldRun.driver.shell) |
            Where-Object { -not ($null -ne $_ -and [bool]$_.systemCmd -and [bool]$_.autoRunOffFirst -and [bool]$_.payloadAfterD) }).Count -eq 0
        verdict = Get-Verdict `
            ((Test-WarpOnlyLog $defaultLog) -and $interactive.copyReady -and $interactive.snapshot.swapBuffers -ge 1 -and $interactive.snapshot.lastSwapOutputBytes -ge $script:SeedBytes) `
            ((Test-WarpOnlyLog $withheldRun.log) -and $withheldRun.snapshot.swapBuffers -ge 1 -and $withheldRun.snapshot.lastSwapOutputBytes -lt $script:SeedBytes -and
                (Test-WarpOnlyLog $privateLog) -and $privateRun.driver.copyReady -and [bool]$privateReadback.seeded -and $privateAfter.swapBuffers -eq 0 -and
                (Test-WarpOnlyLog $privateWithheldRun.driver.log) -and -not [bool]$privateWithheldRun.driver.readback.seeded) `
            $p3Records
    }
    $d3.p5 = [ordered]@{
        defaultBefore = $interactive.toastBefore; defaultAfterNormalExit = $interactive.toastAfter
        privateBefore = $privateRun.driver.toast; privateAfterNormalExit = $privateRun.driver.toastAfterNormalExit
        privateCopyExitedNormally = $privateRun.driver.normalExit
        copyExitedNormally = $interactive.normalExit
    }
    $d3.p4 = [ordered]@{
        defaultHrInit = $defaultLog.hrInit; privateHrInit = $privateLog.hrInit
        verdict = Get-Verdict ($defaultLog.hrInit -eq '0x00000000' -and $interactive.copyReady) ($null -ne $privateLog.hrInit -and $privateLog.hrInit -ne '0x00000000' -and $privateRun.driver.copyReady) ($null -ne $defaultLog.hrInit -and $null -ne $privateLog.hrInit)
    }
    return $d3
}

# ---- main

foreach ($required in @('Bin', 'MeasureRepo', 'Work', 'Out')) {
    if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required." }
}
$Bin = (Resolve-Path -LiteralPath $Bin).Path
$Work = [IO.Path]::GetFullPath($Work)
if (Test-Path -LiteralPath $Work) { throw 'The work directory must be new.' }
$hosted = Test-ProbeHosted
# Measurement mode for this run and every driver it starts (STANDALONE-LEAF-AUMID-01): the libraries route to the
# measurement build, and -Bin must be that build's raw prefix exe.
$env:NOCTTY_INTERACTIVE_MEASURE_AUMID = '1'
if (-not [string]::Equals((Get-InteractiveWin11NormalizedPath (Join-Path $Bin 'noctty.exe')), (Get-InteractiveWin11ExePath -RepoRoot $MeasureRepo), [StringComparison]::OrdinalIgnoreCase)) {
    throw '-Bin must be the measurement build of -MeasureRepo (its raw prefix bin).'
}
if ($Part -eq 'All' -and -not $hosted) { throw "D3 runs only on a GitHub-hosted runner (GITHUB_ACTIONS 'true', RUNNER_ENVIRONMENT 'github-hosted')." }
if ($Part -eq 'All' -and -not $TestToolsBin) { throw '-Part All needs -TestToolsBin (a -Drenderer-test-tools=true build).' }
if ($TestToolsBin) {
    # Locally it only feeds the launcher's control, which must refuse it.
    $TestToolsBin = (Resolve-Path -LiteralPath $TestToolsBin).Path
    foreach ($file in @('noctty.exe', 'noctty.com')) { if (-not (Test-Path -LiteralPath (Join-Path $TestToolsBin $file))) { throw "-TestToolsBin must contain $file." } }
}
Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath (Join-Path $Bin 'noctty.exe')

[void](New-Item -ItemType Directory -Path $Work)
$script:RunRoot = $Work
# A copy's source, staged the way #727's soak stages its copy, by plain copies from the build's own prefix bin (no
# harness-library helper): everything but noctty.ico (a portable copy with its icon beside it creates the user's
# AppUserModelId registration when that key is missing) and the portable crash trees, with share\ beside it.
function New-ProbeStage([string] $Source, [string] $Name, [string] $ExeSha256, [string] $CliSha256) {
    $bin = Join-Path $Work "$Name\bin"
    [void](New-Item -ItemType Directory -Path $bin)
    Get-ChildItem -LiteralPath $Source -Force | Where-Object { $_.Name -notin @('noctty.ico', 'crash', 'ghostty') } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bin $_.Name) -Recurse }
    if (Test-Path -LiteralPath (Join-Path $bin 'noctty.ico')) { throw 'The stage must not carry noctty.ico.' }
    # Both the app and the CLI must be the build's own (design v7 §11 item 0); either mismatch stops the run.
    foreach ($file in @(@('noctty.exe', $ExeSha256), @('noctty.com', $CliSha256))) {
        $path = Join-Path $bin $file[0]
        if (-not $file[1] -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-ProbeHash $path) -cne $file[1]) { throw "The staged $($file[0]) does not match its build." }
    }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path $Work "$Name\share") -Recurse }
    return $bin
}
# The launcher gate's inputs: the measurement build's app and CLI hashes from its receipt (checked above against the
# files themselves), and the test-tools build's from its own prefix bin.
$script:WorkRoot = $Work
$measureReceipt = Get-Content -LiteralPath (Get-InteractiveWin11MeasureLayout $MeasureRepo).Receipt -Raw | ConvertFrom-Json
$script:MeasureExeSha256 = [string]$measureReceipt.ExeSHA256
$script:MeasureCliSha256 = [string]$measureReceipt.CliSHA256
if ((Get-ProbeHash (Join-Path $Bin 'noctty.exe')) -cne $script:MeasureExeSha256 -or (Get-ProbeHash (Join-Path $Bin 'noctty.com')) -cne $script:MeasureCliSha256) {
    throw 'The measurement bin does not match its receipt.'
}
$script:TestToolsExeSha256 = $(if ($TestToolsBin) { Get-ProbeHash (Join-Path $TestToolsBin 'noctty.exe') } else { $null })
$script:TestToolsCliSha256 = $(if ($TestToolsBin) { Get-ProbeHash (Join-Path $TestToolsBin 'noctty.com') } else { $null })
$stageBin = New-ProbeStage $Bin 'stage' $script:MeasureExeSha256 $script:MeasureCliSha256
$testToolsStageBin = $(if ($TestToolsBin) { New-ProbeStage $TestToolsBin 'stage-test-tools' $script:TestToolsExeSha256 $script:TestToolsCliSha256 } else { $null })

$record = [ordered]@{
    schema = 1
    probe = 'gui-hosted-probe'
    part = $Part
    hosted = $hosted
    imageOS = $(if ($hosted) { $env:ImageOS } else { $null })
    imageVersion = $(if ($hosted) { $env:ImageVersion } else { $null })
    measurementBuild = $true
    measurementMode = (Test-InteractiveWin11MeasureMode)
    exeSha256 = $script:MeasureExeSha256
    cliSha256 = $script:MeasureCliSha256
    testToolsExeSha256 = $script:TestToolsExeSha256
    testToolsCliSha256 = $script:TestToolsCliSha256
    outerSession = Get-SessionFacts ''
}

# A failure still leaves a record, naming the stage it reached (the exception's text, which can hold a path, goes
# only to this process's output).
$record.failedStage = $null
try {
    $script:Stage = 'launcher-control'
    $record.launcherControl = Invoke-LauncherControl $stageBin $testToolsStageBin
    if ($record.launcherControl.verdict -ne 'pass') { throw 'The launcher gate failed its control; nothing was started.' }
    $script:Stage = 'q0'
    $q0 = Invoke-ProbeDriverRun 'q0' $stageBin 'q0'
    $record.q0 = $q0
    $q0.negativeControl = Invoke-NegativeControl
    $driverRecord = $q0.driver
    $q0Guards = $null -ne $q0.guards -and [bool]$q0.guards.startupUnchanged -and [bool]$q0.guards.historyUnchanged -and
        [bool]$q0.guards.clipboardUnchanged -and [bool]$q0.guards.ownedJobCleanedUp
    $copyProcesses = @($(if ($driverRecord) { $driverRecord.processes | Where-Object { $_.role -in @('noctty', 'noctty-descendant') } }))
    $onDefault = @($copyProcesses | Where-Object { $_.startupDesktop -ne 'private' -or @($_.threadDesktops | Where-Object { $_ -ne 'private' }).Count -gt 0 }).Count
    $windowsOnDefault = @($(if ($driverRecord) { $driverRecord.windows | Where-Object { $_.desktop -ne 'private' } })).Count
    $q0.summary = [ordered]@{
        copyProcesses = $copyProcesses.Count
        copyProcessesOffPrivate = $onDefault
        copyWindowsOffPrivate = $windowsOnDefault
        # The shell Windows started, read by PID: System32's cmd.exe with /D first (so no AutoRun) and nothing after.
        shellPolicyHeld = ($null -ne $driverRecord -and [bool]$driverRecord.shell.systemCmd -and [bool]$driverRecord.shell.autoRunOffFirst -and [bool]$driverRecord.shell.payloadAfterD)
        verdict = Get-Verdict `
            ($null -ne $driverRecord -and $driverRecord.copyReady -and [bool]$driverRecord.inventoryComplete -and $copyProcesses.Count -ge 2 -and $onDefault -eq 0 -and $windowsOnDefault -eq 0 -and $driverRecord.leftAfterStop -eq 0 -and $q0Guards) `
            ($null -ne $driverRecord -and $driverRecord.positiveChildDesktop -eq 'private' -and $q0.negativeControl.threadMovedError -eq 0 -and $q0.negativeControl.childDesktop -eq 'Default' -and $driverRecord.startupDesktopReaderCheck) `
            ($null -ne $driverRecord -and $null -eq $driverRecord.error -and [bool]$driverRecord.inventoryComplete)
    }
    Assert-ProbeGuards $q0 'q0'
    if ($Part -eq 'All') { $script:Stage = 'd3'; [void](Invoke-D3 $stageBin $testToolsStageBin $record) }
    # Locally only the measurement build starts (the launcher's gate): the private-desktop facts of P4 and P5 on it,
    # with no part on this Default desktop. P3's arms need the test-tools build, so they run only on a hosted runner.
    if ($Part -eq 'Local') {
        $script:Stage = 'local-private'
        $record.localPrivate = Invoke-ProbeDriverRun 'private' $stageBin 'private-renderer'
        Assert-ProbeGuards $record.localPrivate 'local-private'
    }
} catch {
    $record.failedStage = $script:Stage
    $record.guardTripped = $script:GuardTripped
    Write-Host "gui probe: failed at stage $($script:Stage): $($_.Exception.Message)"
} finally {
    # The effective launch policy of each kind of copy, as its own run recorded it.
    $fixtureRun = $(if ($record.d3) { $record.d3.default } elseif ($record.localPrivate) { $record.localPrivate.driver } else { $null })
    $record.launchPolicy = [ordered]@{
        q0 = $(if ($q0 -and $q0.driver) { $q0.driver.launchPolicy } else { $null })
        fixture = $(if ($fixtureRun) { $fixtureRun.launchPolicy } else { $null })
        buildPreparedOutsideRun = $true
    }
    Write-ProbeRecord $record $Out
}
Write-Host "gui probe: record written; launcher control $($record.launcherControl.verdict); Q0 $($q0.summary.verdict)$(if ($record.d3) { "; P1 $($record.d3.p1.verdict), P2 $($record.d3.p2.verdict), P3 $($record.d3.p3.verdict), P4 $($record.d3.p4.verdict)" })"
