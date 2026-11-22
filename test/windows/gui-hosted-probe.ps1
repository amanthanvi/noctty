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
checked against its receipt in -MeasureRepo; Q0 runs it. -TestToolsBin (required by -Part All; with -Part Local it
only feeds the gate's control, which must refuse it) is a `-Drenderer-test-tools=true` build of the same source, which
P3, P4 and P5 run on both desktops on a hosted runner: one build and one fixture. -Part Local runs P4's and P5's
private-desktop facts on the measurement build. Every run takes a build prepared outside it (nothing here builds, or
runs dev-windows.cmd or `cmd /c`) and
uses #727's launch policy: a portable copy without noctty.ico, its own LOCALAPPDATA and APPDATA, every shell the
absolute `direct:<System32>\cmd.exe /D` (no AutoRun), the clipboard read and write denied, `copy-on-select = false`,
`window-save-state = never`, `renderer = d3d11-warp` (a hosted runner has only GDI's OpenGL 1.1) and a seeded
background, #1f6f8b, all set in the copy's portable config.ghostty; the command line carries only the launch helper's
isolation. Each run records that policy as named fields, and reads its shell's real command line by PID to record,
never the text, that it is System32's cmd.exe with /D ahead of any payload.
The P3 fixture's shell is the same cmd with `/D /K type <seed file>`: 20 lines of 64 printable characters (1320
bytes), or, for a withheld-seed control, an empty file. No image, no custom shader, one pane.

Q0 (local and hosted), three arms, each in a driver of its own (design §9: "the CLI, either ConPTY host"): the copy
with its bundled ConPTY host (OpenConsole.exe), the same with the in-box host (NOCTTY_CONPTY=inbox, conhost.exe), and
the copy's CLI run the way PR 1's leaves run it (`noctty.com +version`, and `+list-windows --class=<fresh class>
--format=json --timeout=1000`). Invoke-LocalHiddenDriver (hidden-win11-local-lib.ps1, the #727 soak's model) creates
a private desktop and runs this script again as the driver on it, by name, in a kill-on-close job. The sample is the
job's PIDs plus every Toolhelp descendant of the launched root (PID and creation time). The job permits no breakaway,
so no descendant can leave it (PROBE-JOB-BREAKAWAY-01) and the job's own list is the record; the descendant walk is a
cross-check, and a descendant it finds outside the job is `leftJob`, judged like the rest and stopped by its exact PID
and creation time. Every desktop read holds read-only handles to Default and the private desktop, because
GetThreadDesktop names another process's thread desktop only while the caller holds a handle to it (test-harnesses.md
2026-11-20 PROBE-THREAD-DESKTOP-01). A descendant counts only through a link verified on pinned handles (the candidate
opened first, its parent read from the process itself, every ancestor's handle held); an unverifiable link is counted,
never stopped. The CLI arm's windows are inventoried on both desktops at every poll, as the GUI arms' are once. The
bundled arm's driver also runs the enumeration classifier's own control (an empty desktop, a handle that is not a
desktop, the sentinel's desktop). The driver starts noctty on that desktop by name and records, for every process of the job (noctty, its ConPTY host, the shell) and every
top-level window on the private and the Default desktop, the desktop each is on: a process by its startup desktop
(RTL_USER_PROCESS_PARAMETERS.DesktopInfo, read from its PEB) and its threads' desktops, a window by the desktop it
was enumerated on. Then it stops each of them by exact PID (creation time and job membership checked) and records that
none is left. The claim is "every process and window alive at the sample": it holds only when the sample has the app,
the ConPTY host (the copy's own OpenConsole.exe, or conhost) and the shell, every desktop read in it resolved (a
thread with no USER desktop is kept apart from an unreadable one, which leaves Q0 inconclusive), and both window
inventories are complete; the job's own TotalProcesses is recorded beside the sample, so a descendant that ran and
exited before it (cmd's utf8-console `chcp`) is counted, never hidden.
Positive control: a child the driver starts without naming a desktop reports the private one (the design's M1).
Negative control: a fresh thread of this (Default-desktop) process, moved to a second private desktop with
SetThreadDesktop, starts a child without naming a desktop, in a job of its own; the child reports Default. While it
waits, Q0's own reader must name Default for its startup desktop and its thread desktops (the reader's Default-side
control; unreadable leaves Q0 inconclusive). The children create no window. Q0 passes only when all three arms and
every control pass. The CLI arm is safe locally: the single-instance pipe is named only from --class
(src/apprt/win32/ipc_server.zig), `+list-windows` names a fresh class no instance owns, and `+version` uses no IPC.

The driver admits itself before it starts any copy, taking nothing on trust from its caller: it validates the
measurement build from -MeasureRepo as the outer half does (generation, receipt, the app and CLI hashes), takes the
gate's hashes from that receipt, and refuses to run on Default, on the input desktop, or outside a job.

D3 (GitHub-hosted only: GITHUB_ACTIONS is "true" and RUNNER_ENVIRONMENT "github-hosted"). On the runner's own
Default desktop:
  P1  a probe window takes the foreground (unlocked by a zero-motion mouse input, not an Alt tap, which would open
      a menu loop); with its EDIT focused and no menu loop, SendInput's KEYEVENTF_UNICODE input of BMP, surrogate
      and control units must arrive exactly (SendInput's count and GetLastError recorded). Control: another window
      in front, its own EDIT focused, takes `zz`, and the probe's text is unchanged. Then the noctty arm: the
      measurement copy, foreground, is typed `echo <nonce>>"<file>"` and Enter, and the file must hold the nonce;
      control: the same with a probe window in front, whose EDIT takes the line while no file appears. The BMP and
      surrogate units go through noctty into a file of their own as extra facts. P1 passes only with both arms. Every
      stimulus is sent only from the input desktop to its target in front, and counts only when SendInput inserted
      every event.
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
      evidence. A snapshot counter the record lacks is missing (P3 inconclusive), never an observed 0; the withheld
      readback counts only as the fixture's own background with a measured ink fraction below the floor.
  P4  the copy's env-gated HrInit record (NOCTTY_GUI_PROBE_TRACE, src/os/gui_probe_trace.zig) on the ready app:
      S_OK on Default; the private desktop's HRESULT must be FAILED (severity bit set), the control.
  P5  the toast setting the notifier reads for the measurement build's identities (the product notifier and the
      .measure process AUMID), and their history counts before the run and after noctty's normal exit, on Default
      and on the private desktop.
A probe is conclusive only with its positive record and its control; a missing record is "inconclusive".
-Part Local runs Q0 and the private-desktop facts of P4 and P5 on the measurement build, without touching its user's
desktop; -Part All (D3) refuses to start off a GitHub-hosted runner. Locally the run also keeps the real state's guard
(scripts/interactive-win11-state-guard.ps1: the product jump list, startup-attempts.json, the clipboard sequence),
reads only the measurement identity's toast facts, gives each noctty child a TEMP and TMP under its run directory,
deletes the copies it made under -Work once the record is written (-KeepCopies keeps them), and exits 3 after a
tripped guard and 2 after a failed stage. On a hosted runner the probe is record-only and exits 0.

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
the renderer's readbacks stay in -Work as counts only, and no path, window title or command line enters it, nor any
environment value but the hosted runner's image name and version, each checked against its known shape (else
`unknown`); Write-ProbeRecord writes anything else as rejected-value.
#>
[CmdletBinding()]
param(
    [string] $Bin,
    [string] $MeasureRepo,
    [string] $Work,
    [string] $Out,
    [ValidateSet('Q0', 'Local', 'All')] [string] $Part = 'Q0',
    # Locally, keep the copies a run made under -Work (they are deleted after the record is written otherwise).
    [switch] $KeepCopies,
    # The -Drenderer-test-tools=true build's prefix bin, for P3, P4 and P5 (-Part Local and All).
    [string] $TestToolsBin,
    # The driver half, run by Invoke-LocalHiddenDriver on the private desktop.
    [switch] $Driver,
    [string] $Run,
    [string] $DesktopName,
    [ValidateSet('q0', 'q0-inbox', 'q0-cli', 'private-renderer', 'private-renderer-withheld')] [string] $Task = 'q0',
    # The test-tools build's hashes for the driver's launcher gate, used only on a GitHub-hosted runner. The
    # measurement build's come from its receipt, which the driver validates itself.
    [string] $TestToolsSha256,
    [string] $TestToolsCliSha256,
    # A child that writes the name of its own thread's desktop to this file and exits (the Q0 controls).
    [string] $ReportDesktop,
    # With -ReportDesktop: after the report, wait (at most 30 s) until this file exists, so a reader can read it alive.
    [string] $HoldUntil
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
    if ($HoldUntil) {
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $HoldUntil) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    }
    exit 0
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1')

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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
    [DllImport("user32.dll", SetLastError=true)] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr existing, UIntPtr key, uint threads);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out UIntPtr key, out IntPtr overlapped, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobPort info, uint size);
    // JOBOBJECT_ASSOCIATE_COMPLETION_PORT: x64 size 16.
    [StructLayout(LayoutKind.Sequential)] struct JobPort { public IntPtr key; public IntPtr port; }
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
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr gdiObject);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateEventW(IntPtr attributes, bool manualReset, bool initialState, IntPtr name);
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long time);

    // The SDK's x64 sizes of every struct mirrored here; Assert-ProbeLayout compares them before anything runs.
    public static string Layout() {
        return "Startup=" + Marshal.SizeOf<Startup>() + " StartupEx=" + Marshal.SizeOf<StartupEx>() +
            " ProcessBasic=" + Marshal.SizeOf<ProcessBasic>() + " ProcessEntry=" + Marshal.SizeOf<ProcessEntry>() +
            " parentPid@" + Marshal.OffsetOf<ProcessEntry>("parentPid") + " ThreadEntry=" + Marshal.SizeOf<ThreadEntry>() +
            " Input=" + Marshal.SizeOf<Input>() + " WndClassEx=" + Marshal.SizeOf<WndClassEx>() + " Msg=" + Marshal.SizeOf<Msg>() +
            " GuiThreadInfo=" + Marshal.SizeOf<GuiThreadInfo>() + " focus@" + Marshal.OffsetOf<GuiThreadInfo>("focus") +
            " JobPort=" + Marshal.SizeOf<JobPort>();
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
    // starts `command` without naming a desktop, in `job` before it runs. moveError is 0 when the move succeeded.
    public static ProcessInfo StartFromMovedThread(IntPtr desktop, string app, string command, string cwd, IntPtr job, out int moveError) {
        ProcessInfo result = new ProcessInfo(); int error = -1; Exception failure = null;
        var t = new Thread(() => {
            try {
                error = SetThreadDesktop(desktop) ? 0 : Marshal.GetLastWin32Error();
                result = Start(app, command, cwd, null, null, job, true);
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
            // An exited process has left the job's active list, so it is "gone", not "notInJob".
            if (WaitForSingleObject(h, 0) == 0) return "gone";
            bool inJob;
            if (!IsProcessInJob(h, job, out inJob) || !inJob) return "notInJob";
            if (job == IntPtr.Zero && Array.IndexOf(JobPids(IntPtr.Zero), pid) < 0) return "notInJob";
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

    public sealed class Member { public int Pid; public long Creation; }
    // The job's members at one moment (JobObjectBasicProcessIdList; Zero: this process's own job), each with its
    // creation time read on a handle opened right after the list (0 when it cannot be opened: it has exited). Null when
    // the list cannot be read. Our jobs permit no breakaway (PROBE-JOB-BREAKAWAY-01), so the list is every live
    // descendant in the job.
    public static Member[] JobMembers(IntPtr job) {
        int[] pids;
        try { pids = JobPids(job); } catch (Exception) { return null; }
        var members = new List<Member>();
        foreach (var pid in pids) {
            var member = new Member { Pid = pid };
            IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
            if (h != IntPtr.Zero) {
                long c, e, k, u;
                if (GetProcessTimes(h, out c, out e, out k, out u)) member.Creation = c;
                CloseHandle(h);
            }
            members.Add(member);
        }
        return members.ToArray();
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
        try { return DesktopInfoOf(h); } finally { CloseHandle(h); }
    }
    // The PEB's RTL_USER_PROCESS_PARAMETERS.DesktopInfo through a handle with QUERY_INFORMATION and VM_READ. Until the
    // child's loader normalizes them (Flags bit RTL_USER_PROC_PARAMS_NORMALIZED, at +0x08), the parameters' string
    // buffers are offsets from the block, so a just-created process is read that way.
    static string DesktopInfoOf(IntPtr h) {
        ProcessBasic basic; int returned;
        if (NtQueryInformationProcess(h, 0, out basic, Marshal.SizeOf<ProcessBasic>(), out returned) != 0) return null;
        byte[] pointer = Read(h, basic.peb + 0x20, 8);
        if (pointer == null) return null;
        long parameters = BitConverter.ToInt64(pointer, 0);
        if (parameters == 0) return null;
        byte[] header = Read(h, new IntPtr(parameters), 12);
        if (header == null) return null;
        bool normalized = (BitConverter.ToUInt32(header, 8) & 1) != 0;
        byte[] text = Read(h, new IntPtr(parameters + 0xC0), 16);
        if (text == null) return null;
        int length = BitConverter.ToUInt16(text, 0);
        if (length == 0) return "";
        if (length > 1024) return null;
        long buffer = BitConverter.ToInt64(text, 8);
        if (!normalized) buffer += parameters;
        byte[] chars = Read(h, new IntPtr(buffer), length);
        return chars == null ? null : Encoding.Unicode.GetString(chars);
    }
    static string ImageLeafOf(IntPtr h) {
        var s = new StringBuilder(32768); uint size = (uint)s.Capacity;
        return QueryFullProcessImageNameW(h, 0, s, ref size) ? System.IO.Path.GetFileName(s.ToString()) : null;
    }
    // Whether `pid` is still the process created at `creation` and has not exited (a held handle keeps an exited
    // process's creation time readable, so creation alone is no proof of life).
    public static bool AliveExact(int pid, long creation) {
        IntPtr h = OpenProcess(0x1000 | 0x00100000, false, pid);
        if (h == IntPtr.Zero) return false;
        try {
            long c, e, k, u;
            return GetProcessTimes(h, out c, out e, out k, out u) && c == creation && WaitForSingleObject(h, 0) == 258;
        } finally { CloseHandle(h); }
    }
    public sealed class JoinedProcess { public int Pid; public long Creation; public int Parent; public string Image; public string StartupDesktop; public IntPtr Handle; public bool Unpinned; public bool OpenFailed; public long Taken; }
    // Every process that joins `job`, reported on a completion port (JOB_OBJECT_MSG_NEW_PROCESS) and read the moment it
    // is reported, before a short-lived one can exit: its handle pinned (so its PID cannot be reused while the watch
    // lives), its creation time, its parent (from the process itself), its image's file name and its startup desktop
    // (PEB). The message carries a PID, not a handle, so the PID is recorded only when the process opened is the one
    // reported (CodeRabbit r4647868824): a member of `job` (IsProcessInJob on the opened handle) created no later than
    // the message was taken. Anything else is `Unpinned`, never read, so the job's member stays unobserved and the arm
    // inconclusive (notSeenInJob). Delivery itself is best effort: Windows does not guarantee the message, and a child
    // can exit before it is opened (`OpenFailed`, counted as unopenedJoins; the member then stays unobserved too).
    // So the reader opens first: it takes every waiting message and opens its process at once, and reads one pinned
    // process only when no message waits; and it runs above normal priority. On hosted run 44827416079 the forwarded
    // noctty.exe of `+version` exited before the old one-at-a-time reader opened it; on one CPU with a busy main
    // thread, that reader failed to open 52 to 61 of 62 short-lived joiners. Dispose stops the reader and closes the
    // pins and the port.
    public sealed class JobWatch : IDisposable {
        readonly IntPtr port; readonly IntPtr job; readonly Thread reader; volatile bool stopping;
        // An exception on the reader ends the reading, never the process: what it had not read stays unobserved
        // (notSeenInJob), and the fault is recorded.
        public volatile bool Faulted;
        readonly List<JoinedProcess> joined = new List<JoinedProcess>();
        // Opened, not yet read: a field, so Dispose can close what a fault or a stop leaves here.
        readonly List<JoinedProcess> opened = new List<JoinedProcess>();
        // Whether Dispose saw the reader stop within its wait (council r4, Sol L1).
        public bool Stopped;
        public JobWatch(IntPtr job) {
            this.job = job;
            port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
            if (port == IntPtr.Zero) throw new Exception("CreateIoCompletionPort failed: " + Marshal.GetLastWin32Error());
            var info = new JobPort { key = job, port = port };
            if (!SetInformationJobObject(job, 7, ref info, (uint)Marshal.SizeOf<JobPort>())) { // JobObjectAssociateCompletionPortInformation
                int error = Marshal.GetLastWin32Error(); CloseHandle(port);
                throw new Exception("Associating the job's completion port failed: " + error);
            }
            reader = new Thread(Loop); reader.IsBackground = true; reader.Priority = ThreadPriority.Highest; reader.Start();
        }
        void Loop() {
            try { Run(); } catch (Exception) { Faulted = true; }
        }
        void Run() {
            while (!stopping || opened.Count > 0) {
                uint message; UIntPtr key; IntPtr overlapped;
                // Open first: while a message waits, take it and open its process; read one only once none waits.
                if (!stopping && GetQueuedCompletionStatus(port, out message, out key, out overlapped, opened.Count > 0 ? 0u : 50u)) {
                    if (message != 6) continue; // JOB_OBJECT_MSG_NEW_PROCESS: overlapped carries the PID
                    long taken; GetSystemTimePreciseAsFileTime(out taken);
                    var row = new JoinedProcess { Pid = (int)overlapped.ToInt64(), Taken = taken };
                    row.Handle = OpenProcess(0x1000 | 0x0400 | 0x0010 | 0x00100000, false, row.Pid); // QUERY_LIMITED | QUERY | VM_READ | SYNCHRONIZE
                    if (row.Handle == IntPtr.Zero) row.OpenFailed = true;
                    opened.Add(row);
                    continue;
                }
                if (opened.Count == 0) continue;
                // One read at a time, so a message that arrives during it waits for one read at most. The row leaves the
                // queue only once read, so a fault in the read leaves its handle for Dispose to close.
                var next = opened[0];
                ReadOpened(next);
                opened.RemoveAt(0); lock (joined) joined.Add(next);
            }
        }
        // The pin's checks on the handle opened for the message, then the reads.
        void ReadOpened(JoinedProcess row) {
            IntPtr h = row.Handle;
            if (h == IntPtr.Zero) return;
            long c, e, k, u; bool member;
            bool timed = GetProcessTimes(h, out c, out e, out k, out u);
            if (!IsProcessInJob(h, job, out member) || !member || !timed || c > row.Taken) {
                row.Unpinned = true; CloseHandle(h); row.Handle = IntPtr.Zero; return;
            }
            row.Creation = c;
            int parent; if (ParentOf(h, out parent)) row.Parent = parent;
            row.Image = ImageLeafOf(h);
            row.StartupDesktop = DesktopInfoOf(h);
        }
        public JoinedProcess[] Snapshot() { lock (joined) return joined.ToArray(); }
        public void Dispose() {
            stopping = true; Stopped = reader.Join(2000);
            lock (joined) foreach (var r in joined) if (r.Handle != IntPtr.Zero) CloseHandle(r.Handle);
            // The queue is the reader's own: touched only once it has stopped (else the process's exit closes them).
            if (Stopped) foreach (var r in opened) if (r.Handle != IntPtr.Zero) CloseHandle(r.Handle);
            CloseHandle(port);
        }
    }

    static string Name(IntPtr h) {
        if (h == IntPtr.Zero) return null;
        var s = new StringBuilder(256); int needed;
        return GetUserObjectInformationW(h, 2, s, 512, out needed) ? s.ToString() : null;
    }
    // null: the thread has no desktop (it never touched USER32).
    public static string ThreadDesktop(uint tid) { return Name(GetThreadDesktop(tid)); }
    // A thread's desktop, classified: 0 named (in `name`), 1 none (GetThreadDesktop NULL: the thread never connected
    // to USER, or exited; its error in `error`), 2 unreadable (access denied, or a desktop whose name cannot be read).
    public static int ThreadDesktopState(uint tid, out string name, out int error) {
        name = null; error = 0;
        IntPtr h = GetThreadDesktop(tid);
        if (h == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return error == 5 ? 2 : 1; } // ERROR_ACCESS_DENIED
        name = Name(h);
        return name == null ? 2 : 0;
    }
    // Whether the process's image sits in `folder` (QueryFullProcessImageName), compared here so no path leaves.
    public static bool ImageInFolder(int pid, string folder) {
        IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return false;
        try {
            var s = new StringBuilder(32768); uint size = (uint)s.Capacity;
            if (!QueryFullProcessImageNameW(h, 0, s, ref size)) return false;
            string dir = System.IO.Path.GetDirectoryName(s.ToString());
            return dir != null && string.Equals(System.IO.Path.GetFullPath(dir).TrimEnd('\\'), System.IO.Path.GetFullPath(folder).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        } finally { CloseHandle(h); }
    }
    // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION (48 bytes): TotalProcesses at 36, ActiveProcesses at 40,
    // TotalTerminatedProcesses at 44. Zero: this process's own job. Null when the query fails.
    public static int[] JobAccounting(IntPtr job) {
        IntPtr buffer = Marshal.AllocHGlobal(48);
        try {
            if (!QueryInformationJobObject(job, 1, buffer, 48, IntPtr.Zero)) return null;
            return new int[] { Marshal.ReadInt32(buffer, 36), Marshal.ReadInt32(buffer, 40), Marshal.ReadInt32(buffer, 44) };
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    // A read-only handle to a desktop of this window station (DESKTOP_READOBJECTS), held while another process's
    // thread desktops are read: GetThreadDesktop names a thread's desktop across processes only while the caller
    // holds a handle to that desktop (measured, council r1: with it closed the same threads give NULL, error 5).
    public static IntPtr OpenDesktopReader(string name) { return OpenDesktopW(name, 0, false, 0x0001); }
    public static void CloseDesktopReader(IntPtr h) { if (h != IntPtr.Zero) CloseDesktop(h); }
    // Ends `pid` only if it is still the process created at `creation`, with no job check: for a descendant the
    // caller linked to its root by PID and creation time and found outside the job (our jobs permit no breakaway,
    // PROBE-JOB-BREAKAWAY-01, so this is the cross-check's path). "terminated", "gone", "reused" or "stillRunning".
    public static string StopExactDescendant(int pid, long creation) {
        IntPtr h = OpenProcess(0x0001 | 0x1000 | 0x00100000, false, pid);
        if (h == IntPtr.Zero) return "gone";
        try {
            long c, e, k, u;
            if (!GetProcessTimes(h, out c, out e, out k, out u) || c != creation) return "reused";
            if (WaitForSingleObject(h, 0) == 0) return "gone";
            TerminateProcess(h, 1);
            return WaitForSingleObject(h, 5000) == 0 ? "terminated" : "stillRunning";
        } finally { CloseHandle(h); }
    }
    public sealed class Descendant { public int Pid; public long Creation; }
    static bool ParentOf(IntPtr process, out int parent) {
        ProcessBasic basic; int returned;
        parent = 0;
        if (NtQueryInformationProcess(process, 0, out basic, Marshal.SizeOf<ProcessBasic>(), out returned) != 0) return false;
        parent = (int)basic.parentPid.ToInt64();
        return true;
    }
    // Every descendant of `root` whose link is verified on pinned handles. Each candidate (a Toolhelp row that names a
    // pinned ancestor as its parent) is opened first; its parent PID is read from the pinned process itself
    // (ProcessBasicInformation's InheritedFromUniqueProcessId) and its creation time from the same handle, and it is
    // accepted only when that parent is the pinned ancestor and it was created no earlier. Every accepted handle stays
    // open for the walk, so no ancestor's PID can be reused under it. `unverified` counts the candidates whose link
    // could not be verified: they are never returned, so never stopped. Each is also classified (council r2, Sol M1):
    // `gone` (it no longer runs: OpenProcess says no such process, or the opened process has exited), `reused` (the
    // PID now names a process whose parent is another, so the candidate itself has exited), `older` (created before
    // the ancestor it names: not its child, unless that ancestor's PID was itself reused since the snapshot), or
    // `unresolved`: a candidate that may still run and whose link could not be read. Unresolved is not the only way
    // to miss a live process: when an intermediate's PID is reused by a newer child of the same ancestor, that
    // intermediate's live child reads `older` (council r3, Opus L1). The arm's job still holds such a grandchild, since
    // it permits no breakaway (PROBE-JOB-BREAKAWAY-01): the GUI census counts it through the job's list, and the CLI
    // watch reads it or leaves the arm inconclusive (notSeenInJob). The walk is a cross-check, not the record.
    // `pruned` lists the gone and reused candidates' PIDs: the walk does not pass through them (their PID may name
    // another process now), so their snapshot children are for the caller to account for (Get-ProbeOrphansUnaccounted).
    public static Descendant[] VerifiedDescendants(int root, out int unverified) {
        int gone, reused, older, unresolved; int[] pruned;
        return VerifiedDescendants(root, out unverified, out gone, out reused, out older, out unresolved, out pruned);
    }
    public static Descendant[] VerifiedDescendants(int root, out int unverified, out int gone, out int reused, out int older, out int unresolved, out int[] pruned) {
        unverified = 0; gone = 0; reused = 0; older = 0; unresolved = 0;
        var prunedList = new List<int>();
        pruned = new int[0];
        var result = new List<Descendant>();
        var pins = new List<IntPtr>();
        try {
            IntPtr rootHandle = OpenProcess(0x1000 | 0x00100000, false, root); // QUERY_LIMITED_INFORMATION | SYNCHRONIZE
            if (rootHandle == IntPtr.Zero) return result.ToArray();
            pins.Add(rootHandle);
            long rootCreation, e, k, u;
            if (!GetProcessTimes(rootHandle, out rootCreation, out e, out k, out u)) return result.ToArray();
            var rows = Processes();
            var queue = new Queue<KeyValuePair<int, long>>();
            queue.Enqueue(new KeyValuePair<int, long>(root, rootCreation));
            var seen = new HashSet<int> { root };
            while (queue.Count > 0 && result.Count < 256) {
                var parent = queue.Dequeue();
                foreach (var row in rows) {
                    if (row.Parent != parent.Key || row.Pid == parent.Key || seen.Contains(row.Pid)) continue;
                    IntPtr h = OpenProcess(0x1000 | 0x00100000, false, row.Pid);
                    if (h == IntPtr.Zero) {
                        unverified++;
                        if (Marshal.GetLastWin32Error() == 87) { gone++; prunedList.Add(row.Pid); } else unresolved++; // ERROR_INVALID_PARAMETER: no such process
                        continue;
                    }
                    long creation; int realParent;
                    if (!GetProcessTimes(h, out creation, out e, out k, out u) || !ParentOf(h, out realParent)) {
                        unverified++;
                        if (WaitForSingleObject(h, 0) == 0) { gone++; prunedList.Add(row.Pid); } else unresolved++;
                        CloseHandle(h); continue;
                    }
                    if (realParent != parent.Key || creation < parent.Value) {
                        unverified++;
                        if (WaitForSingleObject(h, 0) == 0) { gone++; prunedList.Add(row.Pid); }
                        else if (realParent != parent.Key) { reused++; prunedList.Add(row.Pid); }
                        else older++;
                        CloseHandle(h); continue;
                    }
                    pins.Add(h); seen.Add(row.Pid);
                    result.Add(new Descendant { Pid = row.Pid, Creation = creation });
                    queue.Enqueue(new KeyValuePair<int, long>(row.Pid, creation));
                }
            }
        } finally { foreach (var h in pins) CloseHandle(h); pruned = prunedList.ToArray(); }
        return result.ToArray();
    }
    // A snapshot child of a pruned PID, read on its own handle: "gone" (no such process, or exited), "alive" (running,
    // and its parent is still that PID), "reused" (running, with another parent: the PID names another process now) or
    // "unreadable".
    public static string ChildState(int pid, int expectedParent) {
        IntPtr h = OpenProcess(0x1000 | 0x00100000, false, pid); // QUERY_LIMITED_INFORMATION | SYNCHRONIZE
        if (h == IntPtr.Zero) return Marshal.GetLastWin32Error() == 87 ? "gone" : "unreadable";
        try {
            if (WaitForSingleObject(h, 0) == 0) return "gone";
            int parent;
            if (!ParentOf(h, out parent)) return "unreadable";
            return parent == expectedParent ? "alive" : "reused";
        } finally { CloseHandle(h); }
    }
    // Whether process `pid` is a member of `job`, checked while a handle to it is open, so the PID cannot be reused under
    // the check: 1 a member, 0 not, -1 unreadable (it cannot be opened, or the check failed). With Zero, `job` is this
    // process's own job, which no handle names: membership is then the job's PID list read while the handle is held.
    public static int OwnerInJob(int pid, IntPtr job) {
        IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return -1;
        try {
            if (job == IntPtr.Zero) {
                var members = JobPids(IntPtr.Zero);
                if (members == null) return -1;
                foreach (var member in members) if (member == pid) return 1;
                return 0;
            }
            bool inJob;
            return IsProcessInJob(h, job, out inJob) ? (inJob ? 1 : 0) : -1;
        } finally { CloseHandle(h); }
    }
    // (6) The input gate before a stimulus (CodeRabbit r4646929628, r4646929642): one GetGUIThreadInfo read on
    // `topLevel`'s GUI thread. "ok" only when the read succeeded, no menu loop is open (GUI_INMENUMODE,
    // GUI_SYSTEMMENUMODE, GUI_POPUPMENUMODE clear) and the focus is `expectedFocus` (Zero: `topLevel` itself or one of
    // its children); else why not.
    public static string InputGate(IntPtr topLevel, IntPtr expectedFocus) {
        int owner; uint tid = GetWindowThreadProcessId(topLevel, out owner);
        if (tid == 0) return "no-gui-thread";
        var info = new GuiThreadInfo { size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        if (!GetGUIThreadInfo(tid, ref info)) return "gui-thread-info-failed";
        if ((info.flags & 0x1C) != 0) return "menu-mode";
        bool focused = expectedFocus != IntPtr.Zero ? info.focus == expectedFocus : (info.focus == topLevel || (info.focus != IntPtr.Zero && IsChild(topLevel, info.focus)));
        return focused ? "ok" : "focus-elsewhere";
    }
    // Whether this process runs inside a job (any job).
    public static bool InJob() { bool r; return IsProcessInJob(new IntPtr(-1), IntPtr.Zero, out r) && r; }
    public static bool ForegroundIs(IntPtr hwnd) { return hwnd != IntPtr.Zero && GetForegroundWindow() == hwnd; }
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
    // enumerated. EnumDesktopWindows returns FALSE both for a failed walk and for a desktop it found nothing on, so
    // every FALSE is unavailable: its last error, or -1 when it set none. A caller proves an inventory with a window it
    // knows must be there.
    public static WindowRow[] DesktopWindows(string desktop, out int error) { return DesktopWindowsWithAccess(desktop, 0x0040 | 0x0001, out error); }
    // The same walk through a handle opened with `access` (normally DESKTOP_ENUMERATE | DESKTOP_READOBJECTS).
    public static WindowRow[] DesktopWindowsWithAccess(string desktop, uint access, out int error) {
        IntPtr d = OpenDesktopW(desktop, 0, false, access);
        if (d == IntPtr.Zero) { error = Marshal.GetLastWin32Error(); return null; }
        try { return WindowsOfHandle(d, out error); } finally { CloseDesktop(d); }
    }
    // The walk: every FALSE is unavailable, with its GetLastError (-1 when it set none, as an empty desktop does).
    static WindowRow[] WindowsOfHandle(IntPtr d, out int error) {
        var rows = new List<WindowRow>();
        bool enumerated = EnumDesktopWindows(d, (h, p) => {
            int pid; GetWindowThreadProcessId(h, out pid);
            var s = new StringBuilder(128); GetClassNameW(h, s, 128);
            rows.Add(new WindowRow { Hwnd = h, Pid = pid, Class = s.ToString(), Visible = IsWindowVisible(h) });
            return true;
        }, IntPtr.Zero);
        if (!enumerated) { int enumError = Marshal.GetLastWin32Error(); error = enumError != 0 ? enumError : -1; return null; }
        error = 0;
        return rows.ToArray();
    }
    // The enumeration control's case (a): the walk through the handle CreateDesktopW returned, so no second open can
    // fail in its place (council r2, Sol L4).
    public static WindowRow[] WindowsOfDesktopHandle(IntPtr desktop, out int error) { return WindowsOfHandle(desktop, out error); }
    // The enumeration control's failed walk: the same walk through a handle that is not a desktop, an event of this
    // process. On the builds measured, EnumDesktopWindows walked every narrowed desktop handle tried (PROBE-ENUM-ACCESS-01),
    // so a handle of the wrong type is the failure a caller can force; Windows answers it with ERROR_INVALID_HANDLE (6).
    public static WindowRow[] WindowsOfNonDesktopHandle(out bool created, out int error) {
        IntPtr e = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
        created = e != IntPtr.Zero;
        if (!created) { error = Marshal.GetLastWin32Error(); return null; }
        try { return WindowsOfHandle(e, out error); } finally { CloseHandle(e); }
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
    // A window class outlives its windows (Close never unregisters it), so each class name is registered once per
    // process and every later Open reuses it. The background is the class's, so one name keeps one colour.
    // ERROR_CLASS_ALREADY_EXISTS (1410) from a registration this cache did not make is reuse too.
    static readonly Dictionary<string, uint> registeredClasses = new Dictionary<string, uint>(StringComparer.OrdinalIgnoreCase);
    public static void RegisterProbeClass(string className, uint bgr) {
        lock (registeredClasses) {
            uint known;
            if (registeredClasses.TryGetValue(className, out known)) {
                if (known != bgr) throw new Exception("The window class " + className + " is registered with another background.");
                return;
            }
            IntPtr brush = CreateSolidBrush(bgr);
            var wc = new WndClassEx { size = Marshal.SizeOf<WndClassEx>(), proc = Marshal.GetFunctionPointerForDelegate(procedure), instance = GetModuleHandleW(null), background = brush, className = className };
            if (RegisterClassExW(ref wc) == 0) {
                int error = Marshal.GetLastWin32Error();
                if (brush != IntPtr.Zero) DeleteObject(brush);
                if (error != 1410) throw new Exception("RegisterClassEx failed: " + error);
            }
            registeredClasses[className] = bgr;
        }
    }
    public static ProbeWindow Open(string className, uint bgr, int x, int y, int w, int h, bool withEdit) {
        return Open(className, bgr, x, y, w, h, withEdit, true);
    }
    // `show` false: the window is never shown (an inventory's sentinel), so it takes no focus and paints nothing.
    public static ProbeWindow Open(string className, uint bgr, int x, int y, int w, int h, bool withEdit, bool show) {
        var win = new ProbeWindow(); var ready = new ManualResetEvent(false); Exception failure = null;
        var t = new Thread(() => {
            try {
                RegisterProbeClass(className, bgr);
                IntPtr instance = GetModuleHandleW(null);
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
                if (show) {
                    ShowWindow(win.Hwnd, 5); // SW_SHOW
                    if (win.Edit != IntPtr.Zero) SetFocus(win.Edit);
                }
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
    // A zero-motion mouse input through SendInput, so this process sent the last input and may set the foreground,
    // then the foreground itself; true when GetForegroundWindow confirms it. Not an Alt tap: a lone Alt press and
    // release puts a window with a system menu in menu mode, which eats the next key (hosted run 44794955668 lost
    // P1's first unit and the cover's input that way).
    public static bool Foreground(IntPtr hwnd, out uint unlockSent, out bool setResult) {
        var nudge = new Input[] { new Input { type = 0 } };
        nudge[0].u.mouse.flags = 0x0001; // MOUSEEVENTF_MOVE, dx = dy = 0
        unlockSent = SendInput(1, nudge, Marshal.SizeOf<Input>());
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
    // The foreground without any injected input (P2's path): SetForegroundWindow, then the attach fallback.
    public static bool ForegroundWithoutInput(IntPtr hwnd, out bool setResult) {
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
    // `line`'s units as KEYEVENTF_UNICODE downs and ups, then Enter (VK_RETURN, scan 0x1C) down and up: one SendInput;
    // its count (2 * length + 2 when every event was inserted), with GetLastError.
    public static uint SendLine(string line, out int error) {
        var inputs = new Input[line.Length * 2 + 2];
        for (int i = 0; i < line.Length; i++) {
            inputs[2 * i] = Key(0, line[i], 0x4);
            inputs[2 * i + 1] = Key(0, line[i], 0x4 | 0x2);
        }
        inputs[line.Length * 2] = Key(0x0D, 0x1C, 0);
        inputs[line.Length * 2 + 1] = Key(0x0D, 0x1C, 0x2);
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        error = Marshal.GetLastWin32Error();
        return sent;
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
# not. Measured on the hosted runner (runs 44793051089 and 44794955668, 1004 x 594 frames, both desktops): seeded 0.1241
# and 0.1251, withheld 0.0018 and 0.0036. The floor sits about 6x below the seeded values and 5.6x above the larger
# withheld one.
$script:SeedInkFloor = 0.02

$script:SdkLayout = 'Startup=104 StartupEx=112 ProcessBasic=48 ProcessEntry=568 parentPid@32 ThreadEntry=28 Input=40 WndClassEx=80 Msg=48 GuiThreadInfo=72 focus@16 JobPort=16'
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
    # Desktop names are case-insensitive: an inherited name keeps whatever casing its parent's string had.
    if ($Private -and [string]::Equals($leaf, $Private, [StringComparison]::OrdinalIgnoreCase)) { return 'private' }
    if ([string]::Equals($leaf, 'Default', [StringComparison]::OrdinalIgnoreCase)) { return 'Default' }
    return 'other'
}

# The record's allowlist: booleans, numbers, null, short strings without a path separator, quote or bracket, and maps
# (keys plain names) and lists of them. A path, command line, environment value or title cannot pass. A value outside
# it is replaced by the token `rejected-value`, and its place listed in $Rejected, so the file never holds it and a
# record is never lost to one field: a failure path's record still reaches the disk. An entry whose key is outside it
# is left out, its place listed as `<map>.#key<n>`: `#` is no key character, so no listed place names an allowed key,
# and no allowed sibling is ever overwritten (council r2, Sol L3).
function ConvertTo-ProbeRecordValue($Value, [string] $Where, [System.Collections.Generic.List[string]] $Rejected) {
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
                $clean[$key] = ConvertTo-ProbeRecordValue $entry.Value "$Where.$key" $Rejected
            } else { $leftOut++; $Rejected.Add("$Where.#key$leftOut") }
        }
        return $clean
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($item in $Value) { $items.Add((ConvertTo-ProbeRecordValue $item "$Where.$index" $Rejected)); $index++ }
        return , $items.ToArray()
    }
    $Rejected.Add($Where); return 'rejected-value'
}

# Writes the record through the allowlist. Anything replaced is counted (rejectedValues) and placed (rejectedAt, the
# first 32 places); a driver's record with replacements leaves the verdicts that read it inconclusive.
function Write-ProbeRecord($Record, [string] $Path) {
    $rejected = [System.Collections.Generic.List[string]]::new()
    $clean = ConvertTo-ProbeRecordValue $Record 'record' $rejected
    # The writer's own two keys: an input entry under either is left out like any rejected key, never overwritten.
    foreach ($reserved in @('rejectedValues', 'rejectedAt')) {
        if ($clean.Contains($reserved)) { $clean.Remove($reserved); $rejected.Add("record.#$reserved") }
    }
    if ($rejected.Count -gt 0) {
        $clean.rejectedValues = $rejected.Count
        $clean.rejectedAt = @($rejected | Select-Object -First 32 | ForEach-Object { if ($_.Length -gt 80) { $_.Substring(0, 80) } else { $_ } })
        Write-Host "gui probe: $($rejected.Count) record value(s) outside the allowlist were written as rejected-value."
    }
    [IO.File]::WriteAllText($Path, ($clean | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

# What the design's §9 asks of each desktop first.
function Get-SessionFacts([string] $Private) {
    $inputError = 0; $inputOpened = $false
    $own = [GuiProbeNative]::OwnDesktop()
    $inputDesktop = [GuiProbeNative]::InputDesktop([ref]$inputError, [ref]$inputOpened)
    $stationFlags = [GuiProbeNative]::StationFlags()
    return [ordered]@{
        sessionId = [GuiProbeNative]::SessionId()
        activeConsoleSessionId = [GuiProbeNative]::ConsoleSessionId()
        # Null when the station query failed (StationFlags -1): never read as visible.
        stationVisible = $(if ($stationFlags -eq -1) { $null } else { ($stationFlags -band 1) -eq 1 })
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

# Whether this thread is on the input desktop now: OpenInputDesktop succeeds and names this thread's desktop. Every
# stimulus checks it right before it is sent.
function Test-ProbeOnInputDesktop {
    $inputError = 0; $opened = $false
    $own = [GuiProbeNative]::OwnDesktop()
    $inputName = [GuiProbeNative]::InputDesktop([ref]$inputError, [ref]$opened)
    return $opened -and $null -ne $own -and $null -ne $inputName -and [string]::Equals($own, $inputName, [StringComparison]::Ordinal)
}

# An HRESULT the record wrote ("0x........") with its severity bit set: FAILED(hr).
function Test-ProbeHResultFailed([AllowNull()] [string] $Hr) {
    return $null -ne $Hr -and $Hr -match '\A0x[0-9a-f]{8}\z' -and ([Convert]::ToUInt32($Hr.Substring(2), 16) -band 0x80000000) -ne 0
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
# tested here and never kept: the facts say only whether it is System32's cmd.exe, whether /D is its first argument,
# whether the fixture's `/K type seed.txt` follows it, and how many arguments follow /D and of which kind (switch,
# quoted or word), never their text.
function Get-ShellLaunchFacts([int] $CopyPid, [bool] $Fixture) {
    $facts = [ordered]@{ shells = 0; read = $false; systemCmd = $false; autoRunOffFirst = $false; payloadAfterD = $null; argumentsAfterD = $null; argumentKindsAfterD = @() }
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
        if ($Fixture) { $facts.payloadAfterD = $rest -match '\A/D\s+/K\s+type\s+seed\.txt(\s|\z)' }
        if ($facts.autoRunOffFirst) {
            $after = @([regex]::Matches($rest.Substring(2), '"[^"]*"?|\S+') | ForEach-Object { $_.Value })
            $facts.argumentsAfterD = $after.Count
            $facts.argumentKindsAfterD = @($after | ForEach-Object { if ($_.StartsWith('"')) { 'quoted' } elseif ($_.StartsWith('/')) { 'switch' } else { 'word' } })
        }
        $after = $null; $rest = $null
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
function Start-ProbeCopy([string] $Exe, [string] $Desktop, [string] $LogPath, [IntPtr] $Job, [string] $TracePath, [string] $CapturePath, [string] $SeedPath, [hashtable] $ExtraEnvironment = @{}) {
    $refusal = Get-ProbeLaunchRefusal $Exe
    if ($refusal) { throw "The launcher refused the copy: $refusal." }
    $build = $(if ((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $script:MeasureExeSha256) { 'measurement' } else { 'test-tools' })
    foreach ($key in $ExtraEnvironment.Keys) { if ($key -cnotin @('NOCTTY_CONPTY')) { throw "The copy takes no extra environment variable $key." } }
    $names = @('GHOSTTY_LOG', 'NOCTTY_GUI_PROBE_TRACE', 'NOCTTY_RENDER_TRACE_FILE', 'NOCTTY_RENDER_TRACE_LIVE', 'NOCTTY_RENDERER_CAPTURE_PATH', 'NOCTTY_RENDERER_STATUS_PATH', 'NOCTTY_CONPTY', 'TEMP', 'TMP')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:GHOSTTY_LOG = 'stderr'
        $env:NOCTTY_GUI_PROBE_TRACE = '1'
        $env:NOCTTY_RENDER_TRACE_FILE = $TracePath
        $env:NOCTTY_RENDER_TRACE_LIVE = '1'
        $env:NOCTTY_CONPTY = $(if ($ExtraEnvironment.ContainsKey('NOCTTY_CONPTY')) { [string]$ExtraEnvironment['NOCTTY_CONPTY'] } else { $null })
        # Locally the noctty child (and its shell) gets a TEMP and TMP under its own run directory. Only this child:
        # no msys or Git Bash process ever gets a redirected TEMP (the /tmp trap).
        $tempRedirected = -not (Test-ProbeHosted)
        if ($tempRedirected) {
            $copyTemp = Join-Path (Split-Path -Parent (Split-Path -Parent $Exe)) 'temp'
            [void][IO.Directory]::CreateDirectory($copyTemp)
            $env:TEMP = $copyTemp; $env:TMP = $copyTemp
        }
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
        $script:LastLaunchPolicy.conptyHost = $(if ($env:NOCTTY_CONPTY -ceq 'inbox') { 'inbox' } else { 'bundled' })
        $script:LastLaunchPolicy.tempRedirected = $tempRedirected
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
        # Each attempt stands alone: what P3 reads is this attempt's, never an earlier capture's, so a capture that
        # later attempts cannot repeat ends the loop uncaptured. A seeded capture still ends it at once.
        $facts.captured = $false; $facts.seeded = $false; $facts.fixtureBackground = $false
        foreach ($key in @('width', 'height', 'colors', 'dominant', 'inkFraction', 'status')) { $facts.Remove($key) }
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
            # The fixture's own frame: its seeded background is the most frequent colour (what a withheld readback
            # must also show before its ink can count as below the floor).
            $facts.fixtureBackground = $frame.Dominant -eq $script:SeedBackground
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
function Get-ToastFacts([string] $Desktop, [IntPtr] $Job, [string] $Private) {
    $script = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
$rows = foreach ($pair in __IDENTITIES__) {
    $row = [ordered]@{ identity = $pair[0]; setting = $null; settingValue = $null; settingHresult = $null; history = $null; historyHresult = $null }
    try {
        $value = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($pair[1]).Setting
        $row.setting = $(if ($null -eq $value) { 'null' } else { [string]$value })
        $row.settingValue = $(if ($null -eq $value) { $null } else { [int]$value })
    } catch { $row.settingHresult = '0x{0:x8}' -f $_.Exception.HResult }
    try { $row.history = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($pair[1])).Count } catch { $row.historyHresult = '0x{0:x8}' -f $_.Exception.HResult }
    $row
}
[Console]::Out.Write((ConvertTo-Json -InputObject @($rows) -Compress))
'@
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Locally only the measurement identity is read: the product identity's setting and history are the maintainer's.
    $identities = $(if (Test-ProbeHosted) { "@(@('product', 'io.github.amanthanvi.noctty'), @('measure', 'io.github.amanthanvi.noctty.measure'))" } else { "@(,@('measure', 'io.github.amanthanvi.noctty.measure'))" })
    $script = $script.Replace('__IDENTITIES__', $identities)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $outPath = Join-Path $script:RunRoot ("toast-" + [guid]::NewGuid().ToString('N') + '.json')
    $pi = [GuiProbeNative]::Start($powershell, ('"{0}" -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand {1}' -f $powershell, $encoded), $script:RunRoot, $Desktop, $outPath, $Job, $true)
    # Where the helper actually started (its PEB's DesktopInfo), so P5's sample says which desktop it is from.
    $helperDesktop = Get-DesktopKind ([GuiProbeNative]::StartupDesktop($pi.pid)) $Private
    try {
        if ([GuiProbeNative]::WaitForSingleObject($pi.process, 60000) -ne 0) { [void][GuiProbeNative]::StopExact($pi.pid, [GuiProbeNative]::CreationTime($pi.pid), $Job); return @{ error = 'timeout'; helperStartupDesktop = $helperDesktop } }
        # Windows PowerShell can still frame redirected output with a CLIXML progress record: take the array itself.
        $match = [regex]::Match([IO.File]::ReadAllText($outPath), '\[\{"identity".*?\}\]')
        if (-not $match.Success) { return @{ error = 'no-json'; helperStartupDesktop = $helperDesktop } }
        $facts = [ordered]@{ helperStartupDesktop = $helperDesktop }
        foreach ($row in ($match.Value | ConvertFrom-Json)) {
            $facts[$row.identity] = [ordered]@{ setting = $row.setting; settingValue = $row.settingValue; settingHresult = $row.settingHresult; history = $row.history; historyHresult = $row.historyHresult }
        }
        return $facts
    } finally { [void][GuiProbeNative]::CloseHandle($pi.thread); [void][GuiProbeNative]::CloseHandle($pi.process) }
}

# Every process of the job now, with its role, its startup desktop and its threads' desktops.
# Read-only handles to the named desktops, held around a desktop census (GetThreadDesktop's handle rule above).
function Open-ProbeDesktopReaders([string[]] $Names) {
    $readers = [ordered]@{}
    foreach ($name in $Names) { if ($name) { $readers[$name] = [GuiProbeNative]::OpenDesktopReader($name) } }
    return $readers
}
function Close-ProbeDesktopReaders($Readers) { foreach ($h in @($Readers.Values)) { [GuiProbeNative]::CloseDesktopReader($h) } }
function Test-ProbeDesktopReadersOpen($Readers) { return $Readers.Count -gt 0 -and @($Readers.Values | Where-Object { $_ -eq [IntPtr]::Zero }).Count -eq 0 }

# One process's desktops, Q0's reader: its startup desktop (PEB DesktopInfo) and each thread's desktop, classified as
# named, no USER desktop (GetThreadDesktop NULL, its errors listed) or unreadable. The caller holds desktop readers for
# every desktop it can meet.
function Get-ProcessDesktopReading([int] $ProcessId, [string] $Private) {
    $threadKinds = [Collections.Generic.List[string]]::new()
    $without = 0; $unreadable = 0
    $noDesktopErrors = [Collections.Generic.SortedSet[int]]::new()
    foreach ($tid in [GuiProbeNative]::Threads($ProcessId)) {
        $name = $null; $readError = 0
        switch ([GuiProbeNative]::ThreadDesktopState($tid, [ref]$name, [ref]$readError)) {
            0 { $threadKinds.Add((Get-DesktopKind $name $Private)) }
            1 { $without++; [void]$noDesktopErrors.Add($readError) }
            default { $unreadable++ }
        }
    }
    return [ordered]@{
        startupDesktop = Get-DesktopKind ([GuiProbeNative]::StartupDesktop($ProcessId)) $Private
        threadDesktops = @($threadKinds | Sort-Object -Unique)
        threadsWithoutDesktop = $without
        noDesktopErrors = @($noDesktopErrors)
        threadsUnreadable = $unreadable
    }
}

# Every descendant of `RootPid` whose link was verified on pinned handles (VerifiedDescendants: each candidate opened
# first, its parent read from the process itself, its creation from the same handle, every ancestor's handle held
# for the walk), as PID -> creation time. A candidate whose link could not be verified is counted in
# $script:LastUnverifiedLinks, never returned, so never stopped; the ones of them that may still run are counted in
# $script:LastUnresolvedLinks (the rest are gone, reused or older). PID-keyed maps are Dictionary[int, ...], never
# [ordered]@{}: an int index on an OrderedDictionary is positional (tooling.md 2026-11-20 PS-ORDERED-INT-INDEX-01).
function Get-ProbeDescendants([int] $RootPid, [int[]] $JobPids = @()) {
    $found = [System.Collections.Generic.Dictionary[int, long]]::new()
    $unverified = 0; $gone = 0; $reused = 0; $older = 0; $unresolved = 0; $pruned = [int[]]@()
    foreach ($descendant in [GuiProbeNative]::VerifiedDescendants($RootPid, [ref]$unverified, [ref]$gone, [ref]$reused, [ref]$older, [ref]$unresolved, [ref]$pruned)) {
        $found[$descendant.Pid] = $descendant.Creation
    }
    $orphans = Get-ProbeOrphansUnaccounted @([GuiProbeNative]::Processes()) @($pruned) $JobPids { param($Child, $Parent) [GuiProbeNative]::ChildState($Child, $Parent) }
    $script:LastUnverifiedLinks = $unverified
    $script:LastOrphansUnaccounted = $orphans
    $script:LastUnresolvedLinks = $unresolved + $orphans
    return , $found
}

# CodeRabbit r4647965406: a pruned candidate (gone or reused between the snapshot and its open) is not walked through,
# since its PID may name another process now, so its snapshot children are accounted for another way. A child that is
# gone, or whose PID now names a process with another parent, is itself pruned and its own children checked the same
# way. A child still running under that PID is accounted for only as a member of the arm's job (then a census row,
# through the job's PID list). Any other (running outside the job, or unreadable) is unaccounted: it may be a live
# descendant whose desktop is unknown, and the census counts it as unresolved, so the arm is inconclusive. Nothing here
# is stopped. `StateOf` takes (child PID, parent PID) and returns ChildState's answer.
function Get-ProbeOrphansUnaccounted($Rows, $Pruned, $JobPids, [scriptblock] $StateOf) {
    $job = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in @($JobPids)) { if ($null -ne $id) { [void]$job.Add([int]$id) } }
    $queue = [System.Collections.Generic.Queue[int]]::new()
    foreach ($id in @($Pruned)) { if ($null -ne $id) { $queue.Enqueue([int]$id) } }
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    $unaccounted = 0
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        if (-not $visited.Add($parent)) { continue }
        foreach ($row in @($Rows | Where-Object { $null -ne $_ -and [int]$_.Parent -eq $parent -and [int]$_.Pid -ne $parent })) {
            $state = & $StateOf ([int]$row.Pid) $parent
            if ($state -in @('gone', 'reused')) { $queue.Enqueue([int]$row.Pid) }
            elseif ($state -eq 'alive' -and $job.Contains([int]$row.Pid)) { }
            else { $unaccounted++ }
        }
    }
    return $unaccounted
}

# Q0's sample: the job's PIDs plus every Toolhelp descendant of the copy (by PID and creation time). A descendant
# outside the job is `leftJob`: it is sampled and judged like any other, and stopped by its exact PID and creation.
function Get-JobProcessRows([IntPtr] $Job, [int] $CopyPid, [string] $Private, [string] $CopyFolder) {
    $all = @{}
    foreach ($row in [GuiProbeNative]::Processes()) { $all[$row.Pid] = $row }
    $rows = [Collections.Generic.List[object]]::new()
    $jobPids = @([GuiProbeNative]::JobPids($Job))
    $descendants = Get-ProbeDescendants $CopyPid $jobPids
    $script:SampleUnverifiedLinks = $script:LastUnverifiedLinks
    $script:SampleUnresolvedLinks = $script:LastUnresolvedLinks
    $systemFolder = [Environment]::GetFolderPath('System')
    foreach ($id in @(@($jobPids) + @($descendants.Keys) | Sort-Object -Unique)) {
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
        if ($descendants.ContainsKey($id) -and $role -eq 'other') { $role = 'noctty-descendant' }
        $inJob = $jobPids -contains $id
        $reading = Get-ProcessDesktopReading $id $Private
        $rows.Add([ordered]@{
            pid = $id
            creation = $(if ($descendants.ContainsKey($id)) { $descendants[$id] } else { [GuiProbeNative]::CreationTime($id) })
            image = $(if ($entry) { $entry.Image } else { $null })
            role = $role
            inJob = $inJob
            leftJob = (-not $inJob -and $role -in @('noctty', 'noctty-descendant'))
            startupDesktop = $reading.startupDesktop
            threadDesktops = $reading.threadDesktops
            threadsWithoutDesktop = $reading.threadsWithoutDesktop
            noDesktopErrors = $reading.noDesktopErrors
            threadsUnreadable = $reading.threadsUnreadable
            # The ConPTY host's folder: the copy's own (the bundled OpenConsole.exe) or System32 (the in-box conhost),
            # compared without a path.
            imageInCopyFolder = $(if ($CopyFolder) { [GuiProbeNative]::ImageInFolder($id, $CopyFolder) } else { $null })
            imageInSystemFolder = [GuiProbeNative]::ImageInFolder($id, $systemFolder)
        })
    }
    return $rows
}

# Every top-level window of the job's processes on the private and the Default desktop. `dropped` holds the walk's
# other windows (owner PID, desktop, class) for Resolve-ProbeLateJoiners; it stays in memory and is never recorded.
# At walk time (CodeRabbit r4647967051), each owner outside the census of a window on a desktop other than the private
# one is checked against the arm's job (`Job`: the CLI's watched job; Zero, the driver's own job, for a GUI arm) on a
# handle held open (OwnerInJob): a member's window is kept as a job window there (ownerRole `job-member`), so the arm
# cannot pass; an owner that cannot be opened is only counted (`ownersUnreadable`). An owner that exits between the
# walk and its open, with its windows, is outside this check.
function Get-JobWindowRows($Processes, [string] $Private, [IntPtr] $PrivateSentinel, [IntPtr] $Job = [IntPtr]::Zero) {
    $byPid = @{}
    foreach ($row in $Processes) { $byPid[$row.pid] = $row }
    $rows = [Collections.Generic.List[object]]::new()
    $dropped = [Collections.Generic.List[object]]::new()
    $counts = [ordered]@{}
    $totals = [ordered]@{}
    $sentinelSeen = $false
    foreach ($desktop in @($Private, 'Default')) {
        $win32Error = 0
        $windows = [GuiProbeNative]::DesktopWindows($desktop, [ref]$win32Error)
        $kind = Get-DesktopKind $desktop $Private
        $counts[$kind] = $(if ($null -eq $windows) { "unavailable $win32Error" } else { 0 })
        $totals[$kind] = $(if ($null -eq $windows) { $null } else { @($windows).Count })
        if ($kind -eq 'private' -and $null -ne $windows) { $sentinelSeen = @($windows | Where-Object { $_.Hwnd -eq $PrivateSentinel }).Count -eq 1 }
        foreach ($window in @($windows)) {
            if ($null -eq $window) { continue }
            if (-not $byPid.ContainsKey($window.Pid)) { $dropped.Add([ordered]@{ pid = [int]$window.Pid; desktop = $kind; class = $window.Class; visible = $window.Visible }); continue }
            $counts[$kind]++
            $rows.Add([ordered]@{ desktop = $kind; class = $window.Class; ownerImage = $byPid[$window.Pid].image; ownerRole = $byPid[$window.Pid].role; visible = $window.Visible })
        }
    }
    # Complete only when both desktops were opened and enumerated and each enumeration shows its positive control: the
    # driver's own hidden sentinel among the private desktop's windows, and at least one window on Default, where
    # the interactive shell always has some (the probe owns none there during Q0). "No copy window on Default" holds
    # only on a complete inventory; anything less leaves Q0 inconclusive.
    $enumerated = @($counts.Values | Where-Object { $_ -isnot [int] }).Count -eq 0
    $complete = $enumerated -and $sentinelSeen -and $null -ne $totals['Default'] -and $totals['Default'] -gt 0
    $owned = Get-ProbeJobOwnedWindows $dropped { param($OwnerPid) [GuiProbeNative]::OwnerInJob($OwnerPid, $Job) }
    foreach ($window in @($owned.windows)) { $rows.Add($window) }
    return [ordered]@{ windows = $rows; counts = $counts; totals = $totals; privateSentinelSeen = $sentinelSeen; complete = $complete; dropped = $dropped
        ownersUnreadable = $owned.ownersUnreadable; ownersTotal = $owned.ownersTotal }
}

# The windows a walk dropped (owner outside the census) on a desktop other than the private one whose owner is a member
# of the arm's job: each owner checked once (`InJob` takes an owner PID and returns OwnerInJob's 1, 0 or -1). A member's
# window becomes an inventory row (ownerRole `job-member`); an unreadable owner is counted and does not gate.
function Get-ProbeJobOwnedWindows($Dropped, [scriptblock] $InJob) {
    $verdicts = @{}
    $windows = [Collections.Generic.List[object]]::new()
    foreach ($window in @($Dropped | Where-Object { $null -ne $_ -and $_.desktop -ne 'private' })) {
        $owner = [int]$window.pid
        if (-not $verdicts.ContainsKey($owner)) { $verdicts[$owner] = [int](& $InJob $owner) }
        if ($verdicts[$owner] -eq 1) {
            $windows.Add([ordered]@{ desktop = $window.desktop; class = $window.class; ownerImage = $null; ownerRole = 'job-member'; visible = $window.visible })
        }
    }
    return [ordered]@{ windows = $windows.ToArray(); ownersUnreadable = @($verdicts.Values | Where-Object { $_ -eq -1 }).Count; ownersTotal = $verdicts.Count }
}

# After a walk (CodeRabbit r4647868866, in the stricter form the lead chose in council r2): the walk kept only the
# census's windows. A job member outside the census (it joined after the census was taken) is a late joiner. A late
# joiner that owns a window the walk dropped, on any desktop but the private one, owns a job window off the private
# desktop: that window is returned as an inventory row (ownerRole `late-joiner`), so the arm cannot pass. A late
# joiner with no such window is only counted. `MemberPids` are the job's members read after the walk (and, in the CLI
# arm, the watch's pinned joiners, whose PIDs cannot be reused while the watch holds them).
function Resolve-ProbeLateJoiners($Inventory, $CensusPids, $MemberPids) {
    $census = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in @($CensusPids)) { if ($null -ne $id) { [void]$census.Add([int]$id) } }
    $late = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in @($MemberPids)) { if ($null -ne $id -and -not $census.Contains([int]$id)) { [void]$late.Add([int]$id) } }
    $windows = @(@($Inventory.dropped) | Where-Object { $null -ne $_ -and $late.Contains([int]$_.pid) -and $_.desktop -ne 'private' } |
        ForEach-Object { [ordered]@{ desktop = $_.desktop; class = $_.class; ownerImage = $null; ownerRole = 'late-joiner'; visible = $_.visible } })
    return [ordered]@{ lateJoiners = $late.Count; windows = $windows }
}

# Ends each listed process by exact PID (its creation time checked), the copy's descendants first, then the copy.
function Stop-ProbeProcesses($Processes, [IntPtr] $Job) {
    $outcomes = [ordered]@{}
    foreach ($row in @($Processes | Where-Object { $_.role -eq 'noctty-descendant' }) + @($Processes | Where-Object { $_.role -eq 'noctty' })) {
        $outcome = $(if ($row.leftJob) { [GuiProbeNative]::StopExactDescendant($row.pid, $row.creation) } else { [GuiProbeNative]::StopExact($row.pid, $row.creation, $Job) })
        $outcomes[$outcome] = 1 + [int]$outcomes[$outcome]
    }
    return $outcomes
}

# Ends the copy with WM_CLOSE to its windows, which writes the render trace's last snapshot. A normal exit is all
# three: WM_CLOSE posted to at least one host window and every post succeeded, the process ended inside the bound,
# and its exit code is 0. A crash before or during the close, or a forced stop, is not one.
function Close-ProbeCopy($Pi, [int] $Seconds) {
    $hosts = @([HiddenLocal]::Hosts($Pi.pid))
    $posted = $hosts.Count -gt 0
    foreach ($h in $hosts) { if (-not [GuiProbeNative]::PostClose($h)) { $posted = $false } }
    $exited = [GuiProbeNative]::WaitForSingleObject($Pi.process, [uint32]($Seconds * 1000)) -eq 0
    $code = $(if ($exited) { [long][GuiProbeNative]::ExitCode($Pi.process) } else { $null })
    return [ordered]@{ closePosted = $posted; exitedInWait = $exited; exitCode = $code; normal = ($posted -and $exited -and $code -eq 0) }
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

# A snapshot counter, or null when the snapshot does not carry it as a number: a missing counter is missing, never an
# observed 0.
function Get-TraceCounter($Snapshot, [string] $Name) {
    $property = $Snapshot.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -isnot [ValueType] -or $property.Value -is [bool]) { return $null }
    return [long]$property.Value
}

function Get-SnapshotFacts($Snapshot) {
    if ($null -eq $Snapshot) { return $null }
    return [ordered]@{
        sequence = Get-TraceCounter $Snapshot 'snapshot_sequence'; swapBuffers = Get-TraceCounter $Snapshot 'swap_buffers_count'
        lastSwapOutputBytes = Get-TraceCounter $Snapshot 'last_swap_process_output_bytes'; paintDraws = Get-TraceCounter $Snapshot 'paint_draw_count'
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
    $result = [ordered]@{ task = $Task; admitted = $true }
    try {
        $own = [GuiProbeNative]::OwnDesktop()
        if (-not [string]::Equals($own, $DesktopName, [StringComparison]::Ordinal)) { throw 'The driver is not on its private desktop.' }
        $result.session = Get-SessionFacts $DesktopName
        # The PEB reader's own control: this driver was created on its desktop by name.
        $result.startupDesktopReaderCheck = [string]::Equals([GuiProbeNative]::StartupDesktop($PID), "WinSta0\$DesktopName", [StringComparison]::Ordinal)
        $exe = Join-Path $Bin 'noctty.exe'

        if ($Task -in @('q0-inbox', 'q0-cli')) {
            # Q0's other arms (design §9's "the CLI, either ConPTY host"): the in-box host, and the copy's CLI.
            $armFacts = $(if ($Task -eq 'q0-inbox') { Invoke-Q0GuiArm $exe 'noctty-q0-inbox' @{ NOCTTY_CONPTY = 'inbox' } } else { Invoke-Q0CliArm $Bin })
            foreach ($key in @($armFacts.Keys)) { $result[$key] = $armFacts[$key] }
        } elseif ($Task -eq 'q0') {
            # Positive control (M1): an ordinary launch, no desktop named, from a driver created on this one.
            $report = Join-Path $Run 'child-positive.txt'
            $pwsh = (Get-Command pwsh.exe).Source
            $child = [GuiProbeNative]::Start($pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -ReportDesktop "{2}"' -f $pwsh, $PSCommandPath, $report), $Run, $null, $null, [IntPtr]::Zero, $true)
            [void][GuiProbeNative]::WaitForSingleObject($child.process, 60000)
            [void][GuiProbeNative]::CloseHandle($child.thread); [void][GuiProbeNative]::CloseHandle($child.process)
            $result.positiveChildDesktop = Get-DesktopKind $(if (Test-Path -LiteralPath $report) { [IO.File]::ReadAllText($report) } else { $null }) $DesktopName
            $armFacts = Invoke-Q0GuiArm $exe 'noctty-q0' @{}
            foreach ($key in @($armFacts.Keys)) { $result[$key] = $armFacts[$key] }
            $result.enumerationControl = Invoke-EnumerationControl
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
            # The toast helper is named on this desktop, never left to inheritance (AGENTS.md "Running noctty").
            if (-not $withheld) { $result.toast = Get-ToastFacts -Desktop "WinSta0\$DesktopName" -Job ([IntPtr]::Zero) -Private $DesktopName }
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
            $result.close = Close-ProbeCopy $pi 20
            $result.normalExit = $result.close.normal
            $result.exitCode = $result.close.exitCode
            $result.log = Read-ProbeLog (Join-Path $Run 'noctty-private.log')
            $result.trace = Read-RenderTrace $trace
            $processes = Get-JobProcessRows ([IntPtr]::Zero) $pi.pid $DesktopName $Bin
            $result.stopped = Stop-ProbeProcesses $processes ([IntPtr]::Zero)
            [void][GuiProbeNative]::CloseHandle($pi.process)
            # P5's private sample after a normal exit only; a forced stop is no such sample.
            if (-not $withheld) { $result.toastAfterNormalExit = $(if ($result.normalExit) { Get-ToastFacts -Desktop "WinSta0\$DesktopName" -Job ([IntPtr]::Zero) -Private $DesktopName } else { $null }) }
        }
        $result.error = $null
    } catch {
        $result.error = 'driver failed'
        [IO.File]::WriteAllText((Join-Path $Run 'driver-error.txt'), $_.Exception.Message)
    }
    Write-ProbeRecord $result (Join-Path $Run "driver-$Task.json")
    return $(if ($result.error) { 1 } else { 0 })
}

# The driver's own admission, before it starts any copy: it takes nothing on trust from its caller. It validates the
# measurement build the way the outer half does (generation and receipt, then the app and the CLI against the
# receipt's hashes) and takes the gate's hashes from that receipt, not from parameters. It must not be on Default or
# on the input desktop, and it must run inside a job. The test-tools hashes come from parameters only on a
# GitHub-hosted runner, the one place the gate allows that build. Null when admitted, else the refusal.
function Get-ProbeDriverRefusal {
    if (-not $MeasureRepo) { return 'no measurement repository' }
    try {
        $measureExe = Get-InteractiveWin11MeasureExePath -RepoRoot $MeasureRepo
        Assert-InteractiveWin11MeasureBuild -RepoRoot $MeasureRepo -ExePath $measureExe
        $receipt = Get-Content -LiteralPath (Get-InteractiveWin11MeasureLayout $MeasureRepo).Receipt -Raw | ConvertFrom-Json
        if ((Get-ProbeHash $measureExe) -cne [string]$receipt.ExeSHA256 -or (Get-ProbeHash (Join-Path (Split-Path -Parent $measureExe) 'noctty.com')) -cne [string]$receipt.CliSHA256) {
            return 'the measurement build does not match its receipt'
        }
        $script:MeasureExeSha256 = [string]$receipt.ExeSHA256
        $script:MeasureCliSha256 = [string]$receipt.CliSHA256
    } catch { return 'the measurement build did not validate' }
    $hostedRun = Test-ProbeHosted
    $script:TestToolsExeSha256 = $(if ($hostedRun -and $TestToolsSha256) { $TestToolsSha256 } else { $null })
    $script:TestToolsCliSha256 = $(if ($hostedRun -and $TestToolsCliSha256) { $TestToolsCliSha256 } else { $null })
    $own = [GuiProbeNative]::OwnDesktop()
    if ($null -eq $own) { return 'its desktop is unreadable' }
    if ((Get-DesktopKind $own '') -eq 'Default') { return 'it is on Default' }
    $inputError = 0; $opened = $false
    $inputName = [GuiProbeNative]::InputDesktop([ref]$inputError, [ref]$opened)
    if (-not $opened -or $null -eq $inputName) { return 'the input desktop is unreadable' }
    if ([string]::Equals($own, $inputName, [StringComparison]::Ordinal)) { return 'it is on the input desktop' }
    if (-not [GuiProbeNative]::InJob()) { return 'it is in no job' }
    return $null
}

# The enumeration classifier's own control, in the driver (DIRECT-UPDATE-720): (a) a fresh desktop the driver creates
# with no windows must come back unavailable (EnumDesktopWindows FALSE; the error as measured, -1 when it set none);
# (b) a failed walk, through a handle that is not a desktop (an event of the driver's), must come back unavailable
# with a Win32 error; (c) this desktop, holding the driver's sentinel, must list it. A successful empty walk cannot be
# told from (a), which is why every FALSE is unavailable. (b) cannot be a desktop handle opened without some right:
# on the builds measured EnumDesktopWindows walked every narrowed handle tried (PROBE-ENUM-ACCESS-01), so a
# DESKTOP_READOBJECTS-only handle is walked too, and is recorded beside the cases as a fact.
function Invoke-EnumerationControl {
    $facts = [ordered]@{}
    $emptyName = 'noctty-gui-probe-empty-' + [guid]::NewGuid().ToString('N')
    $empty = [HiddenLocal]::CreateDesktopW($emptyName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    try {
        if ($empty -eq [IntPtr]::Zero) { $facts.emptyDesktop = [ordered]@{ created = $false } }
        else {
            $enumError = 0
            $rows = [GuiProbeNative]::WindowsOfDesktopHandle($empty, [ref]$enumError)
            $facts.emptyDesktop = [ordered]@{ created = $true; unavailable = ($null -eq $rows); error = $enumError; rows = $(if ($null -ne $rows) { @($rows).Count } else { $null }) }
        }
    } finally { if ($empty -ne [IntPtr]::Zero) { [void][HiddenLocal]::CloseDesktop($empty) } }
    $sentinel = [GuiProbeNative]::Open('NocttyGuiProbeSentinel', 0xFFFFFF, 0, 0, 16, 16, $false, $false)
    try {
        $enumError = 0; $created = $false
        $rows = [GuiProbeNative]::WindowsOfNonDesktopHandle([ref]$created, [ref]$enumError)
        $facts.nonDesktopHandle = [ordered]@{ created = $created; unavailable = ($null -eq $rows); error = $enumError }
        $enumError = 0
        $rows = [GuiProbeNative]::DesktopWindowsWithAccess($DesktopName, 0x0001, [ref]$enumError) # DESKTOP_READOBJECTS only: a fact
        $facts.readObjectsOnly = [ordered]@{
            unavailable = ($null -eq $rows); error = $enumError
            sentinelSeen = ($null -ne $rows -and @($rows | Where-Object { $_.Hwnd -eq $sentinel.Hwnd }).Count -eq 1)
        }
        $enumError = 0
        $rows = [GuiProbeNative]::DesktopWindows($DesktopName, [ref]$enumError)
        $facts.withSentinel = [ordered]@{
            unavailable = ($null -eq $rows); error = $enumError; rows = $(if ($null -ne $rows) { @($rows).Count } else { $null })
            sentinelSeen = ($null -ne $rows -and @($rows | Where-Object { $_.Hwnd -eq $sentinel.Hwnd }).Count -eq 1)
        }
    } finally { [GuiProbeNative]::Close($sentinel) }
    $facts.held = Test-EnumerationControlHeld $facts
    return $facts
}

# The enumeration control's predicate, which the driver records and Q0's summary applies again to the recorded facts:
# (a) only the empty walk's own signature, FALSE with no error (-1), so a failed open or walk cannot stand in for it;
# (b) unavailable with a Win32 error; (c) the sentinel listed.
function Test-EnumerationControlHeld($Facts) {
    if ($null -eq $Facts -or $null -eq $Facts.emptyDesktop -or $null -eq $Facts.nonDesktopHandle -or $null -eq $Facts.withSentinel) { return $false }
    return [bool]$Facts.emptyDesktop.created -and [bool]$Facts.emptyDesktop.unavailable -and $Facts.emptyDesktop.error -eq -1 -and
        [bool]$Facts.nonDesktopHandle.created -and [bool]$Facts.nonDesktopHandle.unavailable -and $Facts.nonDesktopHandle.error -gt 0 -and
        [bool]$Facts.withSentinel.sentinelSeen
}

# One GUI arm of Q0, in the driver: the copy started on this desktop by name (with `ExtraEnvironment`, the in-box host
# for that arm), its process tree and windows sampled with desktop readers for Default and this desktop held, then
# stopped by exact PID. The job's accounting sits beside the sample, so a descendant that exited before it (cmd's
# utf8-console `chcp`, a control's child) is counted, never hidden.
function Invoke-Q0GuiArm([string] $Exe, [string] $LogName, [hashtable] $ExtraEnvironment) {
    $arm = [ordered]@{}
    # The job's count before the copy starts, so the unsampled count is the copy tree's own (the driver's admission
    # ran git in this job before).
    $accountingBefore = [GuiProbeNative]::JobAccounting([IntPtr]::Zero)
    $pi = Start-ProbeCopy -Exe $Exe -Desktop "WinSta0\$DesktopName" -LogPath (Join-Path $Run "$LogName.log") -Job ([IntPtr]::Zero) -TracePath (Join-Path $Run "render-$LogName.json") -ExtraEnvironment $ExtraEnvironment
    try {
        $arm.launchPolicy = $script:LastLaunchPolicy
        $hostWindow = Wait-ProbeHost $pi.pid 45
        $arm.copyReady = $hostWindow -ne [IntPtr]::Zero
        $arm.shell = Get-ShellLaunchFacts $pi.pid $false
        # The ConPTY host and the shell start with the first pane; give them a moment.
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        do {
            $tree = @([GuiProbeNative]::Processes() | Where-Object { $_.Parent -eq $pi.pid })
            if ($tree.Count -gt 0) { break }
            Start-Sleep -Milliseconds 250
        } while ([datetime]::UtcNow -lt $deadline)
        Start-Sleep -Seconds 2
        $readers = Open-ProbeDesktopReaders @('Default', $DesktopName)
        try {
            $arm.desktopReadersOpen = Test-ProbeDesktopReadersOpen $readers
            $processes = Get-JobProcessRows ([IntPtr]::Zero) $pi.pid $DesktopName $Bin
        } finally { Close-ProbeDesktopReaders $readers }
        # The boundary, as one bracketed read (council r4, Sol M; council r3's member set): the job's accounting, its
        # member list (each member's creation time read on a handle opened right after the list), the accounting again.
        # TotalProcesses only grows and our jobs permit no breakaway (PROBE-JOB-BREAKAWAY-01), so an unchanged total
        # proves nothing joined inside the window, and an unchanged active count equal to the list's length then proves
        # nothing left it: the list is the job's member set throughout. An unstable bracket is retried, up to 5 reads; the
        # last one is recorded either way, and the judge checks the rule on it.
        $bracket = $null; $accounting = $null; $members = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $before = [GuiProbeNative]::JobAccounting([IntPtr]::Zero)
            $members = [GuiProbeNative]::JobMembers([IntPtr]::Zero)
            $accounting = [GuiProbeNative]::JobAccounting([IntPtr]::Zero)
            $stable = $null -ne $before -and $null -ne $members -and $null -ne $accounting -and $before[0] -eq $accounting[0] -and
                $before[1] -eq $accounting[1] -and $accounting[1] -eq @($members).Count
            $bracket = [ordered]@{
                attempts = $attempt
                before = $(if ($null -eq $before) { $null } else { [ordered]@{ totalProcesses = $before[0]; activeProcesses = $before[1] } })
                after = $(if ($null -eq $accounting) { $null } else { [ordered]@{ totalProcesses = $accounting[0]; activeProcesses = $accounting[1] } })
            }
            if ($stable) { break }
        }
        $arm.boundaryBracket = $bracket
        $arm.jobMembersAtBoundary = $(if ($null -eq $members) { $null } else { @($members | ForEach-Object { [ordered]@{ pid = $_.Pid; creation = $_.Creation } }) })
        $arm.jobAccounting = $(if ($null -eq $accounting) { $null } else { [ordered]@{ totalProcesses = $accounting[0]; activeProcesses = $accounting[1]; terminatedProcesses = $accounting[2] } })
        $arm.sampledProcesses = @($processes).Count
        $arm.unverifiedDescendantLinks = $script:SampleUnverifiedLinks
        $arm.unresolvedDescendantLinks = $script:SampleUnresolvedLinks
        # Processes that joined the job since the copy started, against the copy's sampled processes in it.
        $copyInJob = @($processes | Where-Object { $_.inJob -and $_.role -in @('noctty', 'noctty-descendant') }).Count
        $arm.jobProcessesNotSampled = $(if ($null -eq $accounting -or $null -eq $accountingBefore) { $null } else { ($accounting[0] - $accountingBefore[0]) - $copyInJob })
        # The inventory's positive control on this desktop: a hidden window of the driver's own, which the
        # enumeration must list.
        $sentinel = [GuiProbeNative]::Open('NocttyGuiProbeSentinel', 0xFFFFFF, 0, 0, 16, 16, $false, $false)
        try { $windows = Get-JobWindowRows $processes $DesktopName $sentinel.Hwnd ([IntPtr]::Zero) } finally { [GuiProbeNative]::Close($sentinel) }
        $arm.windowOwnersUnreadable = $windows.ownersUnreadable
        $arm.windowOwnersTotal = $windows.ownersTotal
        $arm.windowTotals = $windows.totals
        $arm.privateSentinelSeen = $windows.privateSentinelSeen
        $arm.processes = @($processes | ForEach-Object { [ordered]@{
            pid = $_.pid; creation = $_.creation; image = $_.image; role = $_.role; inJob = $_.inJob; leftJob = $_.leftJob; startupDesktop = $_.startupDesktop
            threadDesktops = $_.threadDesktops; threadsWithoutDesktop = $_.threadsWithoutDesktop; noDesktopErrors = $_.noDesktopErrors
            threadsUnreadable = $_.threadsUnreadable; imageInCopyFolder = $_.imageInCopyFolder; imageInSystemFolder = $_.imageInSystemFolder } })
        $arm.windows = $windows.windows
        $arm.windowCounts = $windows.counts
        # As in the CLI arm: a late joiner's window the walk dropped, off the private desktop, is kept as a job window.
        $late = Resolve-ProbeLateJoiners $windows @($processes | ForEach-Object { $_.pid }) @([GuiProbeNative]::JobPids([IntPtr]::Zero))
        $arm.lateJoinersAfterWalk = $late.lateJoiners
        $arm.windows = @(@($arm.windows) + @($late.windows))
        $arm.inventoryComplete = [bool]$windows.complete
        $arm.log = Read-ProbeLog (Join-Path $Run "$LogName.log")
        $arm.stopped = Stop-ProbeProcesses $processes ([IntPtr]::Zero)
        # The copy's processes still running after the stop: the same process, not exited (AliveExact).
        $arm.leftAfterStop = @($processes | Where-Object { $_.role -in @('noctty', 'noctty-descendant') -and [GuiProbeNative]::AliveExact($_.pid, $_.creation) }).Count
    } finally { [void][GuiProbeNative]::CloseHandle($pi.process) }
    return $arm
}

# Q0's CLI arm, in the driver: the copy's noctty.com run the way PR 1's leaves run it. `+version` as shell-command runs
# it through cmd, and `+list-windows --class=<class> --format=json --timeout=1000` as cli-automation does, against a
# fresh class no instance owns. The single-instance pipe is named only from --class (ipc_server.zig), so that client
# can reach no other noctty's pipe, and `+version` uses none. noctty.com forwards to the copy's noctty.exe with the
# parent's lpDesktop and, for a waiting action, nests a job of its own inside the watched one; nothing leaves the
# watched job, which permits no breakaway (PROBE-JOB-BREAKAWAY-01). Each invocation's sample is every process that
# joined it plus every Toolhelp descendant of the root (PID and creation time), polled until the tree is done, desktop
# readers for Default and this desktop held. The job's accounting counts what the polls missed.
function Invoke-Q0CliArm([string] $CopyBin) {
    $arm = [ordered]@{}
    $exe = Join-Path $CopyBin 'noctty.exe'
    $cli = Join-Path $CopyBin 'noctty.com'
    $refusal = Get-ProbeLaunchRefusal $exe
    if ($refusal) { throw "The launcher refused the CLI arm: $refusal." }
    # The copy's portable config, as every start writes it: the forwarded noctty.exe reads it.
    $launch = Get-CopyLaunch $exe $null
    [IO.File]::WriteAllLines((Join-Path $CopyBin 'config.ghostty'), [string[]]$launch.Config, [Text.UTF8Encoding]::new($false))
    $arm.launchPolicy = $launch.Policy
    $class = 'noctty-gui-probe-cli-' + [guid]::NewGuid().ToString('N')
    $shapes = [ordered]@{
        version = @('+version')
        listWindows = @('+list-windows', "--class=$class", '--format=json', '--timeout=1000')
    }
    $invocations = [Collections.Generic.List[object]]::new()
    $readers = Open-ProbeDesktopReaders @('Default', $DesktopName)
    # The window inventory's positive control for every poll: a hidden window of the driver's own on this desktop.
    $sentinel = [GuiProbeNative]::Open('NocttyGuiProbeSentinel', 0xFFFFFF, 0, 0, 16, 16, $false, $false)
    try {
        $arm.desktopReadersOpen = Test-ProbeDesktopReadersOpen $readers
        foreach ($shape in $shapes.Keys) {
            $facts = [ordered]@{ shape = $shape }
            $savedTemp = @($env:TEMP, $env:TMP)
            if (-not (Test-ProbeHosted)) {
                $cliTemp = Join-Path $Run 'cli-temp'
                [void][IO.Directory]::CreateDirectory($cliTemp)
                $env:TEMP = $cliTemp; $env:TMP = $cliTemp
            }
            # A job of the driver's own per invocation, watched on a completion port: every process that joins it (the
            # root, the forwarded noctty.exe, its console host) is read the moment it is created, before a short-lived
            # one exits. Nothing can break away from it (PROBE-JOB-BREAKAWAY-01); the verified-descendant walk below is a
            # cross-check.
            $watchJob = [HiddenLocal]::CreateOwnedJob()
            $watch = $null
            try {
                $watch = [GuiProbeNative+JobWatch]::new($watchJob)
                try { $pi = [GuiProbeNative]::Start($cli, ('"{0}" {1}' -f $cli, ($shapes[$shape] -join ' ')), $CopyBin, "WinSta0\$DesktopName", (Join-Path $Run "cli-$shape.log"), $watchJob, $true) }
                finally { $env:TEMP = $savedTemp[0]; $env:TMP = $savedTemp[1] }
                [void][GuiProbeNative]::CloseHandle($pi.thread)
                $rootCreation = [GuiProbeNative]::CreationTime($pi.pid)
                $seen = [System.Collections.Generic.Dictionary[int, object]]::new()
                $earlyReads = [System.Collections.Generic.Dictionary[int, object]]::new()
                # The CLI tree's windows, inventoried on both desktops at every poll. noctty.com is started with
                # CREATE_NO_WINDOW, so this arm does not test a console window on Default; any other window counts.
                $windowsSeen = [System.Collections.Generic.Dictionary[string, object]]::new()
                $inventoryEveryPoll = $true; $polls = 0; $unverifiedLinks = 0; $unresolvedLinks = 0; $finalPoll = $false; $finalPollRan = $false; $lateJoiners = 0; $ownersUnreadable = 0; $ownersTotal = 0
                $deadline = [datetime]::UtcNow.AddSeconds(30)
                do {
                    $all = @{}
                    foreach ($row in [GuiProbeNative]::Processes()) { $all[$row.Pid] = $row }
                    $descendants = Get-ProbeDescendants $pi.pid @([GuiProbeNative]::JobPids($watchJob))
                    $unverifiedLinks = [Math]::Max($unverifiedLinks, [int]$script:LastUnverifiedLinks)
                    $unresolvedLinks = [Math]::Max($unresolvedLinks, [int]$script:LastUnresolvedLinks)
                    # The watched job's members, each read at its creation; their creation times come from that read.
                    foreach ($joined in $watch.Snapshot()) {
                        if ($joined.Unpinned) { continue }
                        if ($joined.Creation -ne 0 -and -not $earlyReads.ContainsKey($joined.Pid)) { $earlyReads[$joined.Pid] = $joined }
                        if ($joined.Pid -ne $pi.pid -and $joined.Creation -ne 0 -and -not $descendants.ContainsKey($joined.Pid)) { $descendants[$joined.Pid] = $joined.Creation }
                    }
                    $jobPids = @(@([GuiProbeNative]::JobPids($watchJob)) + @($earlyReads.Keys))
                    foreach ($id in @(@($pi.pid) + @($descendants.Keys))) {
                        $creation = $(if ($id -eq $pi.pid) { $rootCreation } else { $descendants[$id] })
                        $alive = [GuiProbeNative]::AliveExact($id, $creation)
                        if (-not $alive -and $seen.ContainsKey($id)) { continue }
                        $reading = $(if ($alive) { Get-ProcessDesktopReading $id $DesktopName } else { $null })
                        if (-not $seen.ContainsKey($id)) {
                            $early = $(if ($earlyReads.ContainsKey($id)) { $earlyReads[$id] } else { $null })
                            # A process gone before any poll read it keeps the watch's read at its creation.
                            if ($null -eq $reading) {
                                if ($null -eq $early) { continue }
                                $reading = [ordered]@{ startupDesktop = Get-DesktopKind $early.StartupDesktop $DesktopName; threadDesktops = @(); threadsUnreadable = 0 }
                            } elseif ($null -ne $early -and $reading.startupDesktop -in @('unreadable', 'none')) {
                                $reading.startupDesktop = Get-DesktopKind $early.StartupDesktop $DesktopName
                            }
                            $image = $(if ($all[$id]) { $all[$id].Image } elseif ($null -ne $early) { $early.Image } else { $null })
                            $role = $(if ($id -eq $pi.pid) { 'cli' } elseif ($image -ieq 'noctty.exe') { 'cli-forwarded' } else { 'cli-descendant' })
                            $seen[$id] = [ordered]@{ pid = $id; creation = $creation; image = $image; role = $role; inJob = $jobPids -contains $id
                                startupDesktop = $reading.startupDesktop; threadDesktops = @($reading.threadDesktops); threadsUnreadable = $reading.threadsUnreadable
                                sampledAlive = $alive }
                        } elseif ($null -ne $reading) {
                            # Later reads add the thread desktops a thread connects to after its first one.
                            $row = $seen[$id]
                            $row.sampledAlive = $true
                            $row.threadDesktops = @(@($row.threadDesktops) + @($reading.threadDesktops) | Sort-Object -Unique)
                            $row.threadsUnreadable = [Math]::Max([int]$row.threadsUnreadable, [int]$reading.threadsUnreadable)
                            if ($row.startupDesktop -in @('unreadable', 'none') -and $reading.startupDesktop -notin @('unreadable', 'none')) { $row.startupDesktop = $reading.startupDesktop }
                            if (-not ($jobPids -contains $id)) { $row.inJob = $false }
                        }
                    }
                    $polls++
                    $inventory = Get-JobWindowRows @($seen.Values) $DesktopName $sentinel.Hwnd $watchJob
                    $ownersUnreadable = [Math]::Max($ownersUnreadable, [int]$inventory.ownersUnreadable)
                    $ownersTotal = [Math]::Max($ownersTotal, [int]$inventory.ownersTotal)
                    if (-not [bool]$inventory.complete) { $inventoryEveryPoll = $false }
                    # A late joiner's window the walk dropped, off the private desktop, is kept as a job window there.
                    $members = @(@([GuiProbeNative]::JobPids($watchJob)) + @($watch.Snapshot() | Where-Object { -not $_.Unpinned -and $_.Creation -ne 0 } | ForEach-Object { $_.Pid }))
                    $late = Resolve-ProbeLateJoiners $inventory @($seen.Keys) $members
                    foreach ($window in @($late.windows)) { $windowsSeen["$($window.desktop)|$($window.class)|$($window.ownerRole)"] = $window }
                    $lateJoiners += $late.lateJoiners
                    foreach ($window in @($inventory.windows)) { $windowsSeen["$($window.desktop)|$($window.class)|$($window.ownerRole)"] = $window }
                    if ($finalPoll) { $finalPollRan = $true; break }
                    # The tree is done once the root has exited and the watched job holds no live process (a forwarded
                    # noctty.exe can outlive the root). One more poll then takes what joined after this one's snapshot,
                    # once the watch has reported every process the job counted.
                    [void][GuiProbeNative]::WaitForSingleObject($pi.process, 20)
                    $accounting = [GuiProbeNative]::JobAccounting($watchJob)
                    # Unreadable accounting is no drain: the loop then runs to its deadline and the tree is not done.
                    if ([GuiProbeNative]::WaitForSingleObject($pi.process, 0) -eq 0 -and $null -ne $accounting -and $accounting[1] -eq 0) {
                        $caughtUp = [datetime]::UtcNow.AddSeconds(2)
                        while (@($watch.Snapshot()).Count -lt $accounting[0] -and [datetime]::UtcNow -lt $caughtUp) { Start-Sleep -Milliseconds 20 }
                        $finalPoll = $true
                    }
                    # A final poll once set runs even past the deadline.
                } while ($finalPoll -or [datetime]::UtcNow -lt $deadline)
                $facts.polls = $polls
                # True only once the poll after the drain has run (council r2, Sol M2).
                $facts.treeDoneInTime = $finalPollRan
                $facts.inventoryCompleteEveryPoll = $inventoryEveryPoll -and $polls -gt 0
                $facts.lateJoinersAfterWalk = $lateJoiners
                $facts.windowOwnersUnreadable = $ownersUnreadable
                $facts.windowOwnersTotal = $ownersTotal
                $facts.windows = @($windowsSeen.Values)
                $facts.windowsOffPrivate = @($windowsSeen.Values | Where-Object { $_.desktop -ne 'private' }).Count
                $facts.unverifiedDescendantLinks = $unverifiedLinks
                $facts.unresolvedDescendantLinks = $unresolvedLinks
                $facts.rootExited = [GuiProbeNative]::WaitForSingleObject($pi.process, 0) -eq 0
                $facts.exitCode = $(if ($facts.rootExited) { [long][GuiProbeNative]::ExitCode($pi.process) } else { $null })
                # Anything of the tree still alive is stopped by its exact PID and creation time: in the job through the
                # job's own check, and a process found outside it (leftJob; the cross-check's path) as the root's verified
                # descendant.
                $stops = [ordered]@{}
                foreach ($row in @($seen.Values)) {
                    $row.leftJob = -not $row.inJob
                    if (-not [GuiProbeNative]::AliveExact($row.pid, $row.creation)) { continue }
                    $outcome = $(if ($row.leftJob) { [GuiProbeNative]::StopExactDescendant($row.pid, $row.creation) } else { [GuiProbeNative]::StopExact($row.pid, $row.creation, $watchJob) })
                    $stops[$outcome] = 1 + [int]$stops[$outcome]
                }
                $facts.stopped = $stops
                $facts.leftAfterStop = @($seen.Values | Where-Object { [GuiProbeNative]::AliveExact($_.pid, $_.creation) }).Count
                [void][GuiProbeNative]::CloseHandle($pi.process)
                $after = [GuiProbeNative]::JobAccounting($watchJob)
                # Every process the watched job ever held, against the ones this arm saw in it.
                $facts.jobProcessesStarted = $(if ($null -ne $after) { $after[0] } else { $null })
                $facts.joinedReported = @($watch.Snapshot()).Count
                $facts.unpinnedJoins = @($watch.Snapshot() | Where-Object { $_.Unpinned }).Count
                # Reported, but gone before it could be opened: the member stays unobserved, which notSeenInJob gates.
                $facts.unopenedJoins = @($watch.Snapshot() | Where-Object { $_.OpenFailed }).Count
                $facts.watchFaulted = $watch.Faulted
                # sampledAlive false: gone before any poll, so only the watch's read at its creation (its startup
                # desktop) stands for it; its threads were never read.
                $facts.processes = @($seen.Values | ForEach-Object { [ordered]@{ image = $_.image; role = $_.role; inJob = $_.inJob; leftJob = [bool]$_.leftJob
                    startupDesktop = $_.startupDesktop; threadDesktops = $_.threadDesktops; threadsUnreadable = $_.threadsUnreadable; sampledAlive = [bool]$_.sampledAlive } })
                $facts.leftJob = @($seen.Values | Where-Object { $_.leftJob }).Count
                $facts.forwardedSeen = @($seen.Values | Where-Object { $_.role -eq 'cli-forwarded' }).Count -ge 1
                $facts.notSeenInJob = $(if ($null -ne $facts.jobProcessesStarted) { $facts.jobProcessesStarted - @($seen.Values | Where-Object { $_.inJob }).Count } else { $null })
            } finally {
                # The pins and the port go first, then the job (by its own handle: it holds only this invocation's tree).
                if ($null -ne $watch) { $watch.Dispose(); $facts.watchStopped = $watch.Stopped }
                try { [void][HiddenLocal]::StopOwnedJob($watchJob) } catch { $facts.watchJobCloseFailed = $true }
            }
            $invocations.Add($facts)
        }
    } finally { [GuiProbeNative]::Close($sentinel); Close-ProbeDesktopReaders $readers }
    $arm.invocations = $invocations
    return $arm
}

if ($Driver) {
    $script:WorkRoot = $Run
    $refusal = Get-ProbeDriverRefusal
    if ($refusal) {
        Write-ProbeRecord ([ordered]@{ task = $Task; admitted = $false; error = 'driver refused' }) (Join-Path $Run "driver-$Task.json")
        [IO.File]::WriteAllText((Join-Path $Run 'driver-error.txt'), "The driver refused itself: $refusal.")
        exit 1
    }
    exit (Invoke-ProbeDriver)
}

# ---- the outer half

# A real-profile guard that did not hold (the real startup state, PSReadLine history or clipboard sequence changed, the
# owned job was not cleaned up, or the run left no guard state): the run's record keeps the evidence, and no later
# copy starts.
# The real-profile guards' state: 'held'; 'tripped' (a guard saw a change, the owned job was not cleaned up, or the run
# left no guard state); or 'unreadable' (CodeRabbit r4646929611): a clipboard sequence sample of 0, which
# GetClipboardSequenceNumber returns 0 when the station's clipboard cannot be read, so equality proves nothing. Equal,
# nonzero samples are the only clipboard evidence.
function Get-ProbeGuardState($Run) {
    $guards = $Run.guards
    if ($null -eq $guards) { return 'tripped' }
    if (-not ([bool]$guards.startupUnchanged -and [bool]$guards.historyUnchanged -and [bool]$guards.ownedJobCleanedUp)) { return 'tripped' }
    if ($null -eq $guards.clipboardSequenceBefore -or $null -eq $guards.clipboardSequenceAfter -or
        $guards.clipboardSequenceBefore -eq 0 -or $guards.clipboardSequenceAfter -eq 0) { return 'unreadable' }
    if (-not [bool]$guards.clipboardUnchanged) { return 'tripped' }
    return 'held'
}
# Locally an unreadable clipboard sample is missing evidence about the user's clipboard: the verdicts that read the
# guards are inconclusive. On a hosted runner the clipboard is the VM's (a fresh one may never have changed it), so the
# sample is recorded ($script:GuardUnreadable) and the other guards still decide.
function Test-ProbeGuardsHeld($Run) {
    $state = Get-ProbeGuardState $Run
    return $state -eq 'held' -or ($state -eq 'unreadable' -and (Test-ProbeHosted))
}
function Test-ProbeGuardsReadable($Run) { return (Get-ProbeGuardState $Run) -ne 'unreadable' -or (Test-ProbeHosted) }

# A tripped guard stops every later launch; an unreadable one stops them locally (the user's clipboard cannot be shown
# untouched). On a hosted runner an unreadable sample is only recorded ($script:GuardUnreadable) and gates no verdict:
# the guard protects the user's clipboard, and the runner's clipboard is not theirs.
function Assert-ProbeGuards($Run, [string] $Name) {
    $state = Get-ProbeGuardState $Run
    if ($state -eq 'tripped' -or ($state -eq 'unreadable' -and -not (Test-ProbeHosted))) {
        $script:GuardTripped = $Name; $script:GuardTrippedState = $state
        throw "A real-profile guard was $state after $Name; no further copy starts."
    }
    if ($state -eq 'unreadable') { $script:GuardUnreadable = $Name }
}

function Invoke-ProbeDriverRun([string] $Name, [string] $StageBin, [string] $TaskName) {
    $runDir = Join-Path $Work $Name
    $guards = $null
    $failure = $null
    try {
        # The shared helper ends with "<label>: PASS", which says only that the driver exited 0; the verdicts are in the
        # record, so that line is reworded as it passes through.
        Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $StageBin -Run $runDir -DesktopPrefix 'noctty-gui-probe-' -TimeoutSeconds 240 `
            -Label "GUI probe $Name" -PassDesktopName -GuardClipboard `
            -DriverArguments @("-Task $TaskName", ('-MeasureRepo "{0}"' -f $MeasureRepo),
                $(if ($script:TestToolsExeSha256) { "-TestToolsSha256 $script:TestToolsExeSha256 -TestToolsCliSha256 $script:TestToolsCliSha256" })) 6>&1 |
            ForEach-Object {
                $message = [string]$_
                if ($message -ceq "GUI probe ${Name}: PASS") { Write-Host "GUI probe ${Name}: driver exited 0 (its verdicts are in the record)" } else { Write-Host $message }
            }
    } catch { $failure = 'the hidden driver or its guards failed' ; [IO.File]::WriteAllText((Join-Path $Work "$Name-outer-error.txt"), $_.Exception.Message) }
    $statePath = Join-Path $runDir 'startup-state.json'
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $guards = [ordered]@{
            startupUnchanged = [bool]$state.Unchanged; historyUnchanged = [bool]$state.HistoryUnchanged
            clipboardUnchanged = [bool]$state.ClipboardUnchanged; ownedJobCleanedUp = [bool]$state.OwnedJobCleanedUp
            # Both numbers, not only their equality: an unchanged zero is no evidence of a live clipboard.
            clipboardSequenceBefore = $(if ($null -ne $state.ClipboardSequenceBefore) { [long]$state.ClipboardSequenceBefore } else { $null })
            clipboardSequenceAfter = $(if ($null -ne $state.ClipboardSequenceAfter) { [long]$state.ClipboardSequenceAfter } else { $null })
        }
    }
    $driverPath = Join-Path $runDir "driver-$TaskName.json"
    $driverRecord = if (Test-Path -LiteralPath $driverPath) { Get-Content -LiteralPath $driverPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
    return [ordered]@{ outer = $failure; guards = $guards; driver = $driverRecord }
}

# The negative control: a thread of this process moved to a second private desktop starts a child without naming one.
# The child runs in a kill-on-close job of its own, which holds nothing else: a child that outlives the wait is
# stopped by its exact PID (creation time and membership checked) and the job is closed, so nothing outlives the probe.
# A normal exit leaves its report read as before.
function Invoke-NegativeControl {
    $name = 'noctty-gui-probe-neg-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($name, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { return [ordered]@{ error = 'CreateDesktop failed' } }
    $job = [IntPtr]::Zero
    $child = $null
    try {
        $job = [HiddenLocal]::CreateOwnedJob()
        $report = Join-Path $Work 'child-negative.txt'
        $release = Join-Path $Work 'child-negative.release'
        $pwsh = (Get-Command pwsh.exe).Source
        $moveError = 0
        $child = [GuiProbeNative]::StartFromMovedThread($desktop, $pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -ReportDesktop "{2}" -HoldUntil "{3}"' -f $pwsh, $PSCommandPath, $report, $release), $Work, $job, [ref]$moveError)
        # The reader's Default-side control: while the child waits, Q0's own reader, with desktop readers for Default
        # and this desktop held, must name Default for both its startup desktop and its thread desktops.
        $null = Wait-Until { Test-Path -LiteralPath $report } 30
        $reading = $null
        $readers = Open-ProbeDesktopReaders @('Default', $name)
        try {
            $readersOpen = Test-ProbeDesktopReadersOpen $readers
            if ([GuiProbeNative]::WaitForSingleObject($child.process, 0) -ne 0) {
                $reading = Get-ProcessDesktopReading $child.pid $name
                # A startup desktop the kinds do not name is recorded by its leaf, when the leaf is plain enough.
                if ($reading.startupDesktop -eq 'other') {
                    $leaf = @(([string][GuiProbeNative]::StartupDesktop($child.pid)) -split '\\')[-1]
                    $reading.startupDesktopLeaf = $(if ($leaf -match '\A[A-Za-z0-9._-]{1,64}\z') { $leaf } else { 'unrecordable' })
                }
            }
        } finally { Close-ProbeDesktopReaders $readers }
        [IO.File]::WriteAllText($release, '')
        $exited = [GuiProbeNative]::WaitForSingleObject($child.process, 60000) -eq 0
        $stop = $null
        if (-not $exited) { $stop = [GuiProbeNative]::StopExact($child.pid, [GuiProbeNative]::CreationTime($child.pid), $job) }
        # True: the reader named Default for both; false: it named something else; null: it could not read them.
        $readerNamesDefault = $null
        if ($readersOpen -and $null -ne $reading -and $reading.threadsUnreadable -eq 0 -and $reading.startupDesktop -notin @('unreadable', 'none') -and @($reading.threadDesktops).Count -gt 0) {
            $readerNamesDefault = $reading.startupDesktop -eq 'Default' -and @($reading.threadDesktops | Where-Object { $_ -ne 'Default' }).Count -eq 0
        }
        return [ordered]@{
            threadMovedError = $moveError
            childExited = $exited
            childStop = $stop
            childDesktop = Get-DesktopKind $(if ($exited -and (Test-Path -LiteralPath $report)) { [IO.File]::ReadAllText($report) } else { $null }) $name
            childReading = $reading
            readerNamesDefault = $readerNamesDefault
        }
    } finally {
        if ($null -ne $child) { [void][GuiProbeNative]::CloseHandle($child.thread); [void][GuiProbeNative]::CloseHandle($child.process) }
        if ($job -ne [IntPtr]::Zero) { try { [void][HiddenLocal]::StopOwnedJob($job) } catch { Write-Host "gui probe: closing the negative control's job failed: $($_.Exception.Message)" } }
        [void][HiddenLocal]::CloseDesktop($desktop)
    }
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

# The census is complete at the sample (council r2, Sol M1): no candidate the walk could not classify that may still
# run (unresolved 0; with no unverified candidate at all, there is none), and, for a GUI arm, no more live processes
# in the job than in-job rows (the job's active count read right after the sample). A process that joined and exited
# before the sample (cmd's chcp) is outside the claim and stays a recorded count (jobProcessesNotSampled).
# The count alone balances an exit against a join (council r3, Sol M), so the job's member set at the boundary is
# compared too, and the boundary is one bracketed read (council r4, Sol M): accounting before and after the member list
# with the same TotalProcesses (nothing joined inside it) and the same active count, equal to the list's length (nothing
# left it). Every member must then be a census row with the same PID and creation time: a stable bracket proves no member
# exited inside it, so a member whose creation could not be read is no exit, and it is inconclusive. A record without
# the bracket or the list is inconclusive.
function Test-ProbeBoundaryBracket($Driver) {
    $bracket = $Driver.boundaryBracket
    if ($null -eq $bracket -or $null -eq $bracket.before -or $null -eq $bracket.after -or $null -eq $Driver.jobMembersAtBoundary) { return $false }
    $count = @($Driver.jobMembersAtBoundary).Count
    return [long]$bracket.before.totalProcesses -eq [long]$bracket.after.totalProcesses -and
        [long]$bracket.before.activeProcesses -eq [long]$bracket.after.activeProcesses -and [long]$bracket.after.activeProcesses -eq $count
}
function Test-ProbeMembersCensused($Driver) {
    $members = $Driver.jobMembersAtBoundary
    if ($null -eq $members -or @($members).Count -lt 1) { return $false }
    if (-not (Test-ProbeBoundaryBracket $Driver)) { return $false }
    $identities = [System.Collections.Generic.HashSet[string]]::new()
    $pids = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($row in @($Driver.processes)) {
        if ($null -eq $row.pid) { continue }
        [void]$pids.Add([long]$row.pid)
        if ($null -ne $row.creation) { [void]$identities.Add("$([long]$row.pid):$([long]$row.creation)") }
    }
    foreach ($member in @($members)) {
        if ($null -eq $member.pid -or $null -eq $member.creation -or [long]$member.creation -eq 0) { return $false }
        if (-not $identities.Contains("$([long]$member.pid):$([long]$member.creation)")) { return $false }
    }
    return $true
}
function Get-ProbeUnresolvedLinks($Facts) {
    if ($null -ne $Facts.unresolvedDescendantLinks) { return [int]$Facts.unresolvedDescendantLinks }
    if ($null -ne $Facts.unverifiedDescendantLinks -and [int]$Facts.unverifiedDescendantLinks -eq 0) { return 0 }
    return $null
}
function Test-ProbeCensusComplete($Driver) {
    $inJobRows = @(@($Driver.processes) | Where-Object { $_.inJob }).Count
    $active = $(if ($Driver.jobAccounting) { $Driver.jobAccounting.activeProcesses } else { $null })
    return (Get-ProbeUnresolvedLinks $Driver) -eq 0 -and $null -ne $active -and [int]$active -le $inJobRows -and (Test-ProbeMembersCensused $Driver)
}

# A GUI arm of Q0 (the bundled or the in-box ConPTY host), from its driver's record: inconclusive without its records
# or a complete census, pass only with the expected roles sampled (the app, the arm's ConPTY host, the shell), nothing of the copy off the
# private desktop (processes, leftJob ones included, and windows), nothing left after the stop, its guards held and
# its shell on the policy.
function Get-Q0GuiArmVerdict($ArmRun, [string] $Kind) {
    $d = $ArmRun.driver
    $driverClean = $null -ne $d -and -not $d.rejectedValues
    $rows = @($(if ($d) { $d.processes }))
    $copyRows = @($rows | Where-Object { $_.role -in @('noctty', 'noctty-descendant') })
    $hostRows = @($copyRows | Where-Object { $_.role -eq 'noctty-descendant' })
    # Every census row but the driver's own is judged by its desktops: an in-job process whose Toolhelp chain does
    # not reach the copy (role `other`, an exited parent between) is a census row like the copy's (council r2, Opus L1).
    $judgedRows = @($copyRows) + @($rows | Where-Object { $_.role -eq 'other' -and [bool]$_.inJob })
    $roles = [ordered]@{
        app = @($copyRows | Where-Object { $_.role -eq 'noctty' -and $_.image -ieq 'noctty.exe' }).Count -eq 1
        conptyHost = $(if ($Kind -eq 'inbox') {
            @($hostRows | Where-Object { $_.image -ieq 'conhost.exe' -and [bool]$_.imageInSystemFolder }).Count -ge 1 -and @($hostRows | Where-Object { $_.image -ieq 'OpenConsole.exe' }).Count -eq 0
        } else {
            # The bundled arm sees the copy's own OpenConsole.exe; a fall back to System32's conhost.exe fails it.
            @($hostRows | Where-Object { $_.image -ieq 'OpenConsole.exe' -and [bool]$_.imageInCopyFolder }).Count -ge 1
        })
        shell = @($hostRows | Where-Object { $_.image -ieq 'cmd.exe' }).Count -ge 1
    }
    $readsResolved = $copyRows.Count -gt 0 -and @($judgedRows | Where-Object { $_.threadsUnreadable -gt 0 -or $_.startupDesktop -in @('unreadable', 'none') }).Count -eq 0
    $offPrivate = @($judgedRows | Where-Object { $_.startupDesktop -ne 'private' -or @($_.threadDesktops | Where-Object { $_ -ne 'private' }).Count -gt 0 }).Count
    $windowsOff = @($(if ($d) { $d.windows | Where-Object { $_.desktop -ne 'private' } })).Count
    $shellPolicy = $null -ne $d -and [bool]$d.shell.read -and [bool]$d.shell.systemCmd -and [bool]$d.shell.autoRunOffFirst
    $census = $driverClean -and (Test-ProbeCensusComplete $d)
    $records = $driverClean -and $null -eq $d.error -and [bool]$d.admitted -and [bool]$d.desktopReadersOpen -and [bool]$d.inventoryComplete -and
        [bool]$d.shell.read -and $readsResolved -and $null -ne $d.jobProcessesNotSampled -and $census -and (Test-ProbeGuardsReadable $ArmRun)
    $positive = $null -ne $d -and [bool]$d.copyReady -and $roles.app -and $roles.conptyHost -and $roles.shell -and $offPrivate -eq 0 -and
        $windowsOff -eq 0 -and $d.leftAfterStop -eq 0 -and (Test-ProbeGuardsHeld $ArmRun) -and $shellPolicy
    return [ordered]@{
        copyProcesses = $copyRows.Count; otherJobProcesses = $judgedRows.Count - $copyRows.Count
        copyProcessesOffPrivate = $offPrivate; copyWindowsOffPrivate = $windowsOff
        leftJob = @($copyRows | Where-Object { $_.leftJob }).Count
        rolesSampled = $roles; desktopReadsResolved = $readsResolved; shellPolicyHeld = $shellPolicy; censusComplete = $census
        jobProcessesNotSampled = $(if ($d) { $d.jobProcessesNotSampled } else { $null })
        verdict = $(if (-not $records) { 'inconclusive' } elseif ($positive) { 'pass' } else { 'fail' })
    }
}

# Q0's CLI arm, from its driver's record: inconclusive without both invocations' forwarded noctty.exe seen, every
# process that joined a watched job read (notSeenInJob 0), no unresolved descendant candidate, each tree drained in time
# with the poll after the drain run (treeDoneInTime), each watched job closed (no watchJobCloseFailed) and every desktop
# read resolved; pass only with every process
# of both trees (leftJob ones included) on the private desktop, each root exited, nothing left after the stop and the
# guards held.
function Get-Q0CliArmVerdict($ArmRun) {
    $d = $ArmRun.driver
    $driverClean = $null -ne $d -and -not $d.rejectedValues
    $invocations = @($(if ($d) { $d.invocations }))
    $all = @($invocations | ForEach-Object { @($_.processes) })
    $readsResolved = $all.Count -gt 0 -and @($all | Where-Object { $_.threadsUnreadable -gt 0 -or $_.startupDesktop -in @('unreadable', 'none') }).Count -eq 0
    $offPrivate = @($all | Where-Object { $_.startupDesktop -ne 'private' -or @($_.threadDesktops | Where-Object { $_ -ne 'private' }).Count -gt 0 }).Count
    $forwarded = $invocations.Count -eq 2 -and @($invocations | Where-Object { -not [bool]$_.forwardedSeen }).Count -eq 0
    $everyJoinedRead = $invocations.Count -gt 0 -and @($invocations | Where-Object { $_.notSeenInJob -ne 0 }).Count -eq 0
    $linksResolved = $invocations.Count -gt 0 -and @($invocations | Where-Object { (Get-ProbeUnresolvedLinks $_) -ne 0 }).Count -eq 0
    $treesDone = $invocations.Count -gt 0 -and @($invocations | Where-Object { $_.treeDoneInTime -ne $true }).Count -eq 0
    $jobsClosed = $invocations.Count -gt 0 -and @($invocations | Where-Object { [bool]$_.watchJobCloseFailed }).Count -eq 0
    $rootsExited = $invocations.Count -gt 0 -and @($invocations | Where-Object { -not [bool]$_.rootExited }).Count -eq 0
    $nothingLeft = @($invocations | Where-Object { $_.leftAfterStop -ne 0 }).Count -eq 0
    $inventories = $invocations.Count -gt 0 -and @($invocations | Where-Object { -not [bool]$_.inventoryCompleteEveryPoll }).Count -eq 0
    $windowsOff = [int](@($invocations | ForEach-Object { [int]$_.windowsOffPrivate }) | Measure-Object -Sum).Sum
    $records = $driverClean -and $null -eq $d.error -and [bool]$d.admitted -and [bool]$d.desktopReadersOpen -and $forwarded -and $readsResolved -and
        $everyJoinedRead -and $linksResolved -and $treesDone -and $jobsClosed -and $inventories -and (Test-ProbeGuardsReadable $ArmRun)
    $positive = $offPrivate -eq 0 -and $windowsOff -eq 0 -and $rootsExited -and $nothingLeft -and (Test-ProbeGuardsHeld $ArmRun)
    return [ordered]@{
        invocations = $invocations.Count; processesSeen = $all.Count; processesOffPrivate = $offPrivate
        leftJob = @($all | Where-Object { $_.leftJob }).Count; forwardedSeen = $forwarded; desktopReadsResolved = $readsResolved
        windowInventoriesComplete = $inventories; windowsOffPrivate = $windowsOff
        exitCodes = @($invocations | ForEach-Object { $_.exitCode })
        notSeenInJob = @($invocations | ForEach-Object { $_.notSeenInJob }); everyJoinedRead = $everyJoinedRead
        linksResolved = $linksResolved; treesDoneInTime = $treesDone; watchJobsClosed = $jobsClosed
        readAtCreationOnly = @($all | Where-Object { -not [bool]$_.sampledAlive }).Count
        verdict = $(if (-not $records) { 'inconclusive' } elseif ($positive) { 'pass' } else { 'fail' })
    }
}

# Q0 over its arms (bundled host, in-box host, CLI) and its controls: the positive child (private) and the PEB
# reader's self-check from the bundled arm's driver; the negative child (Default, after a successful move) and the
# reader's Default-side control on it. Q0 passes only when every arm and every control passes; a failed arm or a
# control that read the wrong desktop fails it; anything missing leaves it inconclusive.
function Get-Q0Summary($Q0) {
    $bundled = Get-Q0GuiArmVerdict $Q0.bundled 'bundled'
    $inbox = Get-Q0GuiArmVerdict $Q0.inbox 'inbox'
    $cli = Get-Q0CliArmVerdict $Q0.cli
    $driverRecord = $(if ($Q0.bundled) { $Q0.bundled.driver } else { $null })
    $neg = $Q0.negativeControl
    $controls = [ordered]@{
        positiveChildPrivate = $(if ($driverRecord -and $null -ne $driverRecord.positiveChildDesktop) { $driverRecord.positiveChildDesktop -eq 'private' } else { $null })
        pebSelfCheck = $(if ($driverRecord -and $null -ne $driverRecord.startupDesktopReaderCheck) { [bool]$driverRecord.startupDesktopReaderCheck } else { $null })
        negativeChildDefault = $(if ($neg -and $neg.threadMovedError -eq 0 -and [bool]$neg.childExited) { $neg.childDesktop -eq 'Default' } else { $null })
        readerNamesDefault = $(if ($neg) { $neg.readerNamesDefault } else { $null })
        # The enumeration classifier's three cases; anything else leaves Q0 inconclusive, never failing it.
        enumerationControl = $(if ($driverRecord -and (Test-EnumerationControlHeld $driverRecord.enumerationControl)) { $true } else { $null })
    }
    $armVerdicts = @($bundled.verdict, $inbox.verdict, $cli.verdict)
    $controlValues = @($controls.Values)
    $verdict = $(if ($armVerdicts -contains 'fail' -or @($controlValues | Where-Object { $_ -eq $false }).Count -gt 0) { 'fail' }
        elseif (@($armVerdicts | Where-Object { $_ -ne 'pass' }).Count -eq 0 -and @($controlValues | Where-Object { $_ -ne $true }).Count -eq 0) { 'pass' }
        else { 'inconclusive' })
    return [ordered]@{
        claim = 'every process and window alive at a sample'
        bundled = $bundled; inbox = $inbox; cli = $cli; controls = $controls
        enumerationControl = $(if ($driverRecord) { $driverRecord.enumerationControl } else { $null })
        verdict = $verdict
    }
}

function Get-Verdict([bool] $Positive, [bool] $Control, [bool] $HaveRecords) {
    if (-not $HaveRecords) { return 'inconclusive' }
    if ($Positive -and $Control) { return 'pass' }
    return 'fail'
}

# P1's noctty arm, on a ready Default-desktop copy (design §9: "a probe window ... then noctty"). The copy is made
# foreground (GetForegroundWindow confirms it) and typed, through SendInput, an ASCII `echo <nonce>>"<file>"` and
# Enter: the positive is that file holding the nonce. The BMP and surrogate units then go the same way into a file of
# their own, recorded as extra facts that no verdict reads. Control: a probe window in front of the copy, its EDIT
# focused, takes the same kind of line with a nonce of its own: the line lands in that EDIT and its file never
# appears. Every stimulus goes only to its target in front, from the input desktop, and counts only when SendInput
# inserted every event.
function Invoke-P1NocttyStimulus([IntPtr] $HostWindow, [string] $RunDir) {
    $arm = [ordered]@{ injected = $false }
    $cover = $null
    try {
        # The shell's prompt is up before anything is typed.
        Start-Sleep -Seconds 3
        $unlockSent = [uint32]0; $setResult = $false
        $arm.foreground = [GuiProbeNative]::Foreground($HostWindow, [ref]$unlockSent, [ref]$setResult)
        $arm.unlockInputSent = $unlockSent
        $arm.onInputDesktop = Test-ProbeOnInputDesktop
        # One GetGUIThreadInfo read on noctty's GUI thread before each send: no menu loop, the focus inside its window.
        $arm.gate = [GuiProbeNative]::InputGate($HostWindow, [IntPtr]::Zero)
        if ($arm.foreground -and $arm.onInputDesktop -and $arm.gate -eq 'ok' -and [GuiProbeNative]::ForegroundIs($HostWindow)) {
            $win32Error = 0
            $nonce = 'p1' + [guid]::NewGuid().ToString('N')
            $file = Join-Path $RunDir 'p1-noctty.txt'
            $line = 'echo ' + $nonce + '>>"' + $file + '"'
            $arm.expectedEvents = 2 * $line.Length + 2
            $arm.sent = [GuiProbeNative]::SendLine($line, [ref]$win32Error); $arm.lastError = $win32Error
            $arm.injected = $true
            $null = Wait-Until { Test-Path -LiteralPath $file } 10
            Start-Sleep -Milliseconds 300
            $arm.fileWritten = Test-Path -LiteralPath $file
            $arm.nonceInFile = $arm.fileWritten -and [string]::Equals(([IO.File]::ReadAllText($file)).Trim(), $nonce, [StringComparison]::Ordinal)
            # Extra facts: the BMP and surrogate units through the same path. cmd writes them in the code page
            # utf8-console set (65001); no verdict reads them.
            $unicode = [string][char]0x00E9 + [char]0xD83D + [char]0xDE00
            $unicodeFile = Join-Path $RunDir 'p1-noctty-unicode.txt'
            $arm.unicodeGate = [GuiProbeNative]::InputGate($HostWindow, [IntPtr]::Zero)
            if ($arm.unicodeGate -eq 'ok' -and (Test-ProbeOnInputDesktop) -and [GuiProbeNative]::ForegroundIs($HostWindow)) {
                $unicodeLine = 'echo ' + $unicode + '>>"' + $unicodeFile + '"'
                $arm.unicodeExpectedEvents = 2 * $unicodeLine.Length + 2
                $arm.unicodeSent = [GuiProbeNative]::SendLine($unicodeLine, [ref]$win32Error)
                $null = Wait-Until { Test-Path -LiteralPath $unicodeFile } 10
                Start-Sleep -Milliseconds 300
                $echoed = $(if (Test-Path -LiteralPath $unicodeFile) { ([IO.File]::ReadAllText($unicodeFile, [Text.UTF8Encoding]::new($false))).Trim() } else { $null })
                $arm.unicodeUnitsInFile = @($(if ($null -ne $echoed) { $echoed.ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ } }))
                $arm.unicodeExact = [string]::Equals($echoed, $unicode, [StringComparison]::Ordinal)
            }
            # Control: a probe window in front of the copy takes the line; the copy's shell never sees it.
            $cover = [GuiProbeNative]::Open('NocttyGuiProbeNocttyCover', 0xFFFFFF, 120, 120, 420, 240, $true)
            $arm.coverForeground = [GuiProbeNative]::Foreground($cover.Hwnd, [ref]$unlockSent, [ref]$setResult)
            $arm.coverGate = [GuiProbeNative]::InputGate($cover.Hwnd, $cover.Edit)
            if ($arm.coverForeground -and $arm.coverGate -eq 'ok' -and (Test-ProbeOnInputDesktop) -and [GuiProbeNative]::ForegroundIs($cover.Hwnd)) {
                $controlNonce = 'p1c' + [guid]::NewGuid().ToString('N')
                $controlFile = Join-Path $RunDir 'p1-noctty-control.txt'
                $controlLine = 'echo ' + $controlNonce + '>>"' + $controlFile + '"'
                $arm.coverExpectedEvents = 2 * $controlLine.Length + 2
                $arm.coverSent = [GuiProbeNative]::SendLine($controlLine, [ref]$win32Error)
                Start-Sleep -Seconds 3
                $arm.controlFileAbsent = -not (Test-Path -LiteralPath $controlFile)
                $coverText = [GuiProbeNative]::Text($cover)
                $arm.coverTookLine = $null -ne $coverText -and $coverText.StartsWith($controlLine, [StringComparison]::Ordinal)
            }
        }
    } catch {
        $arm.failed = $true
        Write-Host "gui probe: P1's noctty arm failed: $($_.Exception.Message)"
    } finally { [GuiProbeNative]::Close($cover) }
    $arm.verdict = Get-Verdict `
        ([bool]$arm.nonceInFile -and $null -ne $arm.sent -and $arm.sent -eq $arm.expectedEvents) `
        ([bool]$arm.controlFileAbsent -and [bool]$arm.coverTookLine -and $null -ne $arm.coverSent -and $arm.coverSent -eq $arm.coverExpectedEvents) `
        ([bool]$arm.injected -and $null -ne $arm.coverSent)
    return $arm
}

# One Default-desktop copy in an owned job, ended by WM_CLOSE. The seeded P3 arm waits for a presented frame that
# committed the seed; the withheld arm for any presented output, then settles 5 s so its shell has printed all it
# will. Only the seeded arm reads the toast facts (P5). With `InputArm`, the copy has no fixture and runs P1's noctty
# arm instead.
function Invoke-DefaultCopy([string] $StageBin, [string] $Name, [bool] $Withheld, [bool] $InputArm = $false) {
    $defaultRun = Join-Path $Work $Name
    [void](New-Item -ItemType Directory -Path $defaultRun)
    $script:RunRoot = $defaultRun
    Copy-Portable $StageBin (Join-Path $defaultRun 'copy\bin')
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
        $fixture = -not $InputArm
        if ($fixture -and -not $Withheld) { $run.toastBefore = Get-ToastFacts -Desktop 'WinSta0\Default' -Job $job }
        $seed = $(if ($fixture) { Join-Path $defaultRun 'seed.txt' } else { $null })
        if ($fixture) { Write-ProbeSeed $seed $Withheld }
        $env:LOCALAPPDATA = Join-Path $defaultRun 'localappdata'; $env:APPDATA = Join-Path $defaultRun 'appdata'
        $trace = Join-Path $defaultRun 'render.json'
        $capture = Join-Path $defaultRun 'frame.bmp'
        $pi = Start-ProbeCopy -Exe (Join-Path $defaultRun 'copy\bin\noctty.exe') -Desktop 'WinSta0\Default' -LogPath (Join-Path $defaultRun 'noctty.log') -Job $job -TracePath $trace -CapturePath $(if ($fixture) { $capture } else { $null }) -SeedPath $seed
        $run.launchPolicy = $script:LastLaunchPolicy
        $env:LOCALAPPDATA = $savedLocal; $env:APPDATA = $savedRoaming
        $hostWindow = Wait-ProbeHost $pi.pid 45
        $run.copyReady = $hostWindow -ne [IntPtr]::Zero
        $run.shell = Get-ShellLaunchFacts $pi.pid $fixture
        if ($run.copyReady -and $fixture) {
            $surface = @([HiddenLocal]::Surfaces($hostWindow))[0]
            $run.snapshot = $(if ($Withheld) { Wait-ProbePresented $surface $trace 1 5 } else { Wait-ProbePresented $surface $trace $script:SeedBytes 0 })
            $run.readback = Invoke-ProbeReadback $surface $capture
        }
        if ($run.copyReady -and $InputArm) { $run.p1 = Invoke-P1NocttyStimulus $hostWindow $defaultRun }
        $run.close = Close-ProbeCopy $pi 20
        $run.normalExit = $run.close.normal
        $run.exitCode = $run.close.exitCode
        $run.log = Read-ProbeLog (Join-Path $defaultRun 'noctty.log')
        $run.trace = Read-RenderTrace $trace
        $left = @([GuiProbeNative]::JobPids($job) | ForEach-Object { [ordered]@{ pid = $_; creation = [GuiProbeNative]::CreationTime($_); role = 'noctty-descendant' } })
        $run.stopped = Stop-ProbeProcesses $left $job
        [void][GuiProbeNative]::CloseHandle($pi.process)
        # P5's after sample only after a normal exit; a forced stop is no such sample.
        if ($fixture -and -not $Withheld) { $run.toastAfter = $(if ($run.normalExit) { Get-ToastFacts -Desktop 'WinSta0\Default' -Job $job } else { $null }) }
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
    $clipboardAfter = [HiddenLocal]::GetClipboardSequenceNumber()
    $run.clipboardUnchanged = $clipboardBefore -eq $clipboardAfter
    $run.guards = [ordered]@{
        startupUnchanged = ($startupBefore.Exists -eq $startupAfter.Exists -and $startupBefore.Hash -eq $startupAfter.Hash -and $startupBefore.Modified -eq $startupAfter.Modified)
        historyUnchanged = $historyHeld; clipboardUnchanged = $run.clipboardUnchanged; ownedJobCleanedUp = -not $cleanupFailed
        clipboardSequenceBefore = [long]$clipboardBefore; clipboardSequenceAfter = [long]$clipboardAfter
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
            $unlockSent = [uint32]0; $setResult = $false
            $p1.foreground = [GuiProbeNative]::Foreground($probe.Hwnd, [ref]$unlockSent, [ref]$setResult)
            $p1.unlockInputSent = $unlockSent; $p1.setForegroundResult = $setResult
            # One GetGUIThreadInfo read before the send: the probe's EDIT focused, no menu loop (Greptile; CodeRabbit).
            $p1.gate = [GuiProbeNative]::InputGate($probe.Hwnd, $probe.Edit)
            # The gate stops at a menu loop or a failed read before it compares the focus: then focus is unknown (null).
            $p1.focusOnEdit = $(if ($p1.gate -eq 'ok') { $true } elseif ($p1.gate -eq 'focus-elsewhere') { $false } else { $null })
            $p1.menuModeBeforeSend = $p1.gate -eq 'menu-mode'
            if ($p1.foreground -and $p1.gate -eq 'ok' -and (Test-ProbeOnInputDesktop) -and [GuiProbeNative]::ForegroundIs($probe.Hwnd)) {
                $win32Error = 0
                $p1.expectedEvents = 2 * $text.Length
                $p1.sent = [GuiProbeNative]::SendUnicode($text, [ref]$win32Error); $p1.lastError = $win32Error; $p1.injected = $true
                $null = Wait-Until { [string]::Equals([GuiProbeNative]::Text($probe), $text, [StringComparison]::Ordinal) } 5
                $received = [GuiProbeNative]::Text($probe)
                $p1.receivedExactly = [string]::Equals($received, $text, [StringComparison]::Ordinal)
                $p1.receivedUnits = @($(if ($null -ne $received) { $received.ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ } }))
                # Control: a second window in front; the probe's text must not change.
                $cover = [GuiProbeNative]::Open('NocttyGuiProbeCover', 0xFFFFFF, 120, 120, 420, 240, $true)
                $p1.coverForeground = [GuiProbeNative]::Foreground($cover.Hwnd, [ref]$unlockSent, [ref]$setResult)
                $p1.coverGate = [GuiProbeNative]::InputGate($cover.Hwnd, $cover.Edit)
                $p1.coverFocusOnEdit = $(if ($p1.coverGate -eq 'ok') { $true } elseif ($p1.coverGate -eq 'focus-elsewhere') { $false } else { $null })
                $p1.coverMenuModeBeforeSend = $p1.coverGate -eq 'menu-mode'
                # The cover's stimulus too goes only to the cover in front, from the input desktop, through the gate.
                if ($p1.coverForeground -and $p1.coverGate -eq 'ok' -and (Test-ProbeOnInputDesktop) -and [GuiProbeNative]::ForegroundIs($cover.Hwnd)) {
                    $p1.coverSent = [GuiProbeNative]::SendUnicode('zz', [ref]$win32Error)
                    Start-Sleep -Milliseconds 800
                    $p1.probeUnchangedWithCoverInFront = [string]::Equals([GuiProbeNative]::Text($probe), $received, [StringComparison]::Ordinal)
                    $coverText = [GuiProbeNative]::Text($cover)
                    $p1.coverReceived = [string]::Equals($coverText, 'zz', [StringComparison]::Ordinal)
                    $p1.coverReceivedUnits = @($(if ($null -ne $coverText) { $coverText.ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ } }))
                }
            }
        } catch {
            $p1.failed = $true
            Write-Host "gui probe: P1 failed: $($_.Exception.Message)"
        } finally { [GuiProbeNative]::Close($cover); [GuiProbeNative]::Close($probe) }
    }
    # The EDIT arm: every event inserted, and the control counts only when the cover itself took its stimulus (in
    # front, its EDIT focused, no menu loop, both events of each unit inserted, and `zz` in it).
    $p1.editVerdict = Get-Verdict ([bool]$p1.receivedExactly -and $null -ne $p1.sent -and $p1.sent -eq $p1.expectedEvents) `
        ([bool]$p1.coverForeground -and $p1.coverGate -eq 'ok' -and $null -ne $p1.coverSent -and $p1.coverSent -eq 4 -and [bool]$p1.coverReceived -and [bool]$p1.probeUnchangedWithCoverInFront) `
        ([bool]$p1.injected -and $null -ne $p1.coverSent)
    $d3.p1 = $p1

    # P1's noctty arm: the measurement copy on this desktop, typed into through SendInput.
    $script:Stage = 'd3-p1-noctty'
    $nocttyInput = Invoke-DefaultCopy $StageBin 'p1-noctty' $false $true
    $d3.p1NocttyCopy = $nocttyInput
    $p1.noctty = $nocttyInput.p1
    Assert-ProbeGuards $nocttyInput 'd3-p1-noctty'
    # P1 passes only with both arms; a failed arm fails it, anything else is inconclusive.
    $armVerdicts = @($p1.editVerdict, $(if ($null -ne $p1.noctty) { $p1.noctty.verdict } else { 'inconclusive' }))
    $p1.verdict = $(if ($armVerdicts -contains 'fail') { 'fail' } elseif (@($armVerdicts | Where-Object { $_ -ne 'pass' }).Count -eq 0) { 'pass' } else { 'inconclusive' })

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
        # The foreground without injected input: P2 sends no stimulus at all.
        $setResult = $false
        $p2.foreground = [GuiProbeNative]::ForegroundWithoutInput($color.Hwnd, [ref]$setResult)
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
    $interactive = Invoke-DefaultCopy $TestToolsStageBin 'default' $false $false
    $d3.default = $interactive
    Assert-ProbeGuards $interactive 'd3-default'
    $script:Stage = 'd3-default-withheld'
    $withheldRun = Invoke-DefaultCopy $TestToolsStageBin 'default-withheld' $true $false
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
    $p3Shells = @($interactive.shell, $withheldRun.shell, $privateRun.driver.shell, $privateWithheldRun.driver.shell)
    $p3ShellsRead = @($p3Shells | Where-Object { $null -ne $_ -and [bool]$_.read }).Count -eq 4
    $p3ShellPolicy = @($p3Shells | Where-Object { $null -ne $_ -and [bool]$_.systemCmd -and [bool]$_.autoRunOffFirst -and [bool]$_.payloadAfterD }).Count -eq 4
    # Every counter P3 reads must be a number the snapshot carried; a missing one leaves P3 inconclusive.
    $p3Counters = $null -ne $interactive.snapshot -and $null -ne $interactive.snapshot.swapBuffers -and $null -ne $interactive.snapshot.lastSwapOutputBytes -and
        $null -ne $withheldRun.snapshot -and $null -ne $withheldRun.snapshot.swapBuffers -and $null -ne $withheldRun.snapshot.lastSwapOutputBytes -and
        $null -ne $privateAfter -and $null -ne $privateAfter.swapBuffers
    # The withheld readback counts only as the fixture's own frame (its seeded background) with a measured ink
    # fraction below the floor; a different background or a failed fixture is no control.
    $privateWithheldReadback = $privateWithheldRun.driver.readback
    $withheldBelowFloor = [bool]$privateWithheldReadback.captured -and [bool]$privateWithheldReadback.fixtureBackground -and
        $null -ne $privateWithheldReadback.inkFraction -and $privateWithheldReadback.inkFraction -lt $script:SeedInkFloor
    $privateDriversClean = $null -ne $privateRun.driver -and -not $privateRun.driver.rejectedValues -and
        $null -ne $privateWithheldRun.driver -and -not $privateWithheldRun.driver.rejectedValues
    $p3Records = $privateDriversClean -and $p3ShellsRead -and $p3Counters -and [bool]$privateReadback.captured -and
        [bool]$privateWithheldReadback.captured -and
        [bool]$defaultLog.logOn -and [bool]$withheldRun.log.logOn -and [bool]$privateLog.logOn -and [bool]$privateWithheldRun.driver.log.logOn
    $d3.p3 = [ordered]@{
        seedBytes = $script:SeedBytes
        seededLastSwapOutputBytes = $interactive.snapshot.lastSwapOutputBytes; seededSwaps = $interactive.snapshot.swapBuffers
        withheldLastSwapOutputBytes = $withheldRun.snapshot.lastSwapOutputBytes; withheldSwaps = $withheldRun.snapshot.swapBuffers
        privateReadbackSeeded = $privateReadback.seeded; privateSwapsAfterReadback = $privateAfter.swapBuffers
        privateWithheldReadbackSeeded = $privateWithheldRun.driver.readback.seeded
        privateWithheldReadbackBelowFloor = $withheldBelowFloor
        # Every arm's shell, read by PID: System32's cmd.exe with /D ahead of the `/K type` payload. An unread shell
        # makes P3 inconclusive; a shell off the policy makes it fail.
        shellPolicyHeld = $p3ShellPolicy
        verdict = Get-Verdict `
            ($p3ShellPolicy -and (Test-WarpOnlyLog $defaultLog) -and $interactive.copyReady -and $interactive.snapshot.swapBuffers -ge 1 -and $interactive.snapshot.lastSwapOutputBytes -ge $script:SeedBytes) `
            ((Test-WarpOnlyLog $withheldRun.log) -and $withheldRun.snapshot.swapBuffers -ge 1 -and $withheldRun.snapshot.lastSwapOutputBytes -lt $script:SeedBytes -and
                (Test-WarpOnlyLog $privateLog) -and $privateRun.driver.copyReady -and [bool]$privateReadback.seeded -and $privateAfter.swapBuffers -eq 0 -and
                (Test-WarpOnlyLog $privateWithheldRun.driver.log) -and $withheldBelowFloor) `
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
        # The private half needs FAILED(hr), the severity bit, as TaskbarProgress.init tests it; a nonzero success is not.
        verdict = Get-Verdict ($defaultLog.hrInit -eq '0x00000000' -and $interactive.copyReady) ((Test-ProbeHResultFailed $privateLog.hrInit) -and $privateRun.driver.copyReady) ($null -ne $defaultLog.hrInit -and $null -ne $privateLog.hrInit -and $null -ne $privateRun.driver -and -not $privateRun.driver.rejectedValues)
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
# Normalized once: each driver gets it on its command line (quoted, so no trailing separator) and validates it itself.
$MeasureRepo = [IO.Path]::GetFullPath($MeasureRepo).TrimEnd('\')
# A -Work inside -MeasureRepo would dirty the checkout the measurement build's provenance needs clean, so it is
# refused before anything is created, unless git ignores it (CodeRabbit r4646929599).
if (($Work + '\').StartsWith($MeasureRepo + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $relative = $Work.Substring($MeasureRepo.Length + 1)
    & git -C $MeasureRepo check-ignore -q --no-index -- $relative 2>$null
    if ($LASTEXITCODE -ne 0) { throw '-Work is inside -MeasureRepo and git does not ignore it; choose a -Work outside the checkout.' }
}
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
    # The runner image's name and version, each only in its known shape (`win25`, `win25-vs2026`; `20261116.315.1`);
    # anything else is recorded as `unknown`, never copied (CodeRabbit r4647868839).
    imageOS = $(if (-not $hosted) { $null } elseif ([string]$env:ImageOS -cmatch '\Awin\d{2}(-vs\d{4})?\z') { $env:ImageOS } else { 'unknown' })
    imageVersion = $(if (-not $hosted) { $null } elseif ([string]$env:ImageVersion -cmatch '\A\d{8}\.\d{1,6}\.\d{1,6}\z') { $env:ImageVersion } else { 'unknown' })
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
$stateGuard = $null
try {
    if (-not $hosted) {
        $script:Stage = 'state-guard'
        $stateGuard = Start-InteractiveWin11StateGuard -Harness 'gui-hosted-probe' -ReceiptDirectory $Work
    }
    $script:Stage = 'launcher-control'
    $record.launcherControl = Invoke-LauncherControl $stageBin $testToolsStageBin
    if ($record.launcherControl.verdict -ne 'pass') { throw 'The launcher gate failed its control; nothing was started.' }
    # Q0's arms (design §9: "window threads, the CLI, either ConPTY host"), each in a driver of its own, then the
    # negative control from this process. Its summary is written in `finally`, so a tripped guard leaves one too.
    $q0 = [ordered]@{}
    $record.q0 = $q0
    $script:Stage = 'q0-bundled'
    $q0.bundled = Invoke-ProbeDriverRun 'q0' $stageBin 'q0'
    Assert-ProbeGuards $q0.bundled 'q0-bundled'
    $script:Stage = 'q0-inbox'
    $q0.inbox = Invoke-ProbeDriverRun 'q0-inbox' $stageBin 'q0-inbox'
    Assert-ProbeGuards $q0.inbox 'q0-inbox'
    $script:Stage = 'q0-cli'
    $q0.cli = Invoke-ProbeDriverRun 'q0-cli' $stageBin 'q0-cli'
    Assert-ProbeGuards $q0.cli 'q0-cli'
    $script:Stage = 'q0-negative'
    $q0.negativeControl = Invoke-NegativeControl
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
    $record.guardTrippedState = $script:GuardTrippedState
    $record.guardUnreadable = $script:GuardUnreadable
    Write-Host "gui probe: failed at stage $($script:Stage): $($_.Exception.Message)"
} finally {
    if ($record.q0 -and $record.q0.Count -gt 0) {
        try { $record.q0.summary = Get-Q0Summary $record.q0 } catch { Write-Host "gui probe: Q0's summary failed: $($_.Exception.Message)" }
    }
    if (-not $record.Contains('guardUnreadable')) { $record.guardUnreadable = $script:GuardUnreadable }
    # Locally, the real state's own guard over the whole run (the product jump list, startup-attempts.json, the
    # clipboard sequence: scripts/interactive-win11-state-guard.ps1, STANDALONE-LEAF-AUMID-01).
    if ($stateGuard) {
        # A clipboard sequence of 0 before and after is no observation (Sol on #744): the guard passed, but the record says
        # unobservable, never held (test-harnesses.md: 2026-11-21 STATE-GUARD-CLIPBOARD-01).
        try { Assert-InteractiveWin11StateGuard -Guard $stateGuard; $record.stateGuard = [ordered]@{ state = $(if ($stateGuard.ClipboardObservable) { 'held' } else { 'unobservable' }); clipboardObservable = [bool]$stateGuard.ClipboardObservable } }
        catch {
            $record.stateGuard = [ordered]@{ state = 'tripped'; clipboardObservable = $(if ($null -ne $stateGuard.PSObject.Properties['ClipboardObservable']) { [bool]$stateGuard.ClipboardObservable } else { $false }) }
            $script:GuardTripped = 'state-guard'; $record.guardTripped = 'state-guard'; $record.guardTrippedState = 'tripped'
            Write-Host "gui probe: the real state's guard did not hold: $($_.Exception.Message)"
        }
    }
    # The effective launch policy of each kind of copy, as its own run recorded it.
    $fixtureRun = $(if ($record.d3) { $record.d3.default } elseif ($record.localPrivate) { $record.localPrivate.driver } else { $null })
    $record.launchPolicy = [ordered]@{
        q0 = $(if ($record.q0 -and $record.q0.bundled -and $record.q0.bundled.driver) { $record.q0.bundled.driver.launchPolicy } else { $null })
        q0Inbox = $(if ($record.q0 -and $record.q0.inbox -and $record.q0.inbox.driver) { $record.q0.inbox.driver.launchPolicy } else { $null })
        q0Cli = $(if ($record.q0 -and $record.q0.cli -and $record.q0.cli.driver) { $record.q0.cli.driver.launchPolicy } else { $null })
        fixture = $(if ($fixtureRun) { $fixtureRun.launchPolicy } else { $null })
        buildPreparedOutsideRun = $true
    }
    Write-ProbeRecord $record $Out
    # Locally, the copies this run made under -Work are deleted once the record is written (records and logs stay),
    # each checked to be a directory inside -Work and not a reparse point. -KeepCopies keeps them.
    if (-not $hosted -and -not $KeepCopies) {
        $workRoot = $Work.TrimEnd('\') + '\'
        $copyDirs = @(@('stage', 'stage-test-tools', 'launcher-control') | ForEach-Object { Join-Path $Work $_ }) +
            @(Get-ChildItem -LiteralPath $Work -Directory -ErrorAction SilentlyContinue | ForEach-Object { (Join-Path $_.FullName 'source'), (Join-Path $_.FullName 'copy') })
        foreach ($dir in $copyDirs) {
            $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or -not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if (-not ([IO.Path]::GetFullPath($item.FullName) + '\').StartsWith($workRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop } catch { Write-Host "gui probe: a copy under -Work could not be deleted: $($_.Exception.Message)" }
        }
    }
}
# Every verdict, not "PASS": the record holds the evidence.
$q0Summary = $(if ($record.q0) { $record.q0.summary } else { $null })
$summaryLine = "gui probe: record written; launcher control $($record.launcherControl.verdict); Q0 $($q0Summary.verdict) (bundled $($q0Summary.bundled.verdict), in-box $($q0Summary.inbox.verdict), CLI $($q0Summary.cli.verdict))"
if ($record.d3) {
    $summaryLine += "; P1 $($record.d3.p1.verdict) (EDIT $($record.d3.p1.editVerdict), noctty $($record.d3.p1.noctty.verdict)); P2 $($record.d3.p2.verdict); P3 $($record.d3.p3.verdict); P4 $($record.d3.p4.verdict); P5 facts only"
}
if ($record.failedStage) { $summaryLine += "; failed at $($record.failedStage)" }
if ($record.guardTripped) { $summaryLine += "; guard $($record.guardTrippedState) at $($record.guardTripped)" }
Write-Host $summaryLine
# Locally a tripped guard or a failed stage ends nonzero; on a hosted runner the probe is record-only and exits 0 once
# the record is written (the workflow uploads it either way).
if (-not $hosted) {
    if ($record.guardTripped) { exit 3 }
    if ($record.failedStage) { exit 2 }
}
exit 0
