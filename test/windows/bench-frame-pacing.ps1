#requires -Version 7.2
<#
.SYNOPSIS
bench-windows.ps1's frame-interval p95 (frame_time_p95_ms) under the per-copy rules: each run a fresh portable copy of
the receipt-bound measurement build, its shell the config's cmd.exe, timed from the copy's own render trace.

.DESCRIPTION
Run it through bench-windows.ps1 -Metric frame-pacing, or as
  pwsh -NoProfile -File test/windows/bench-frame-pacing.ps1 -MeasureRepo <repo with a measurement build>
       -RunRoot <new directory> [-Runs 5] [-Visible] [-ExpectedBuildMode ReleaseFast]
with -RunRoot outside -MeasureRepo or in a directory git ignores there. -MeasureRepo is a checkout whose measurement
generation Invoke-InteractiveWin11MeasureBuild built (scripts/interactive-win11-measure-lib.ps1); only that build is
launched, admitted as test/windows/hidden-win11-working-set.ps1 admits it (#739's functions, copied byte for byte and
held identical by the contract: Get-WorkingSetMeasureBuild, Read-WorkingSetPlainFile, Test-WorkingSetCopy and the
rest). Each run is a fresh copy in <RunRoot>\run-<n>, a fresh LOCALAPPDATA, APPDATA, TEMP and TMP, and (in a dry run)
a fresh private desktop; runs go one at a time (a session-wide mutex refuses a second harness), and the series stops
at the first run that does not complete.

Two modes.
  Dry run (the default): everything on a private desktop. The copy, its config and argv, the workload and the trace
          run exactly as in a visible run, but the visible part (the foreground and a composed present) is refused:
          the driver evaluates the visible run's preconditions on its own desktop, records why they fail, and never
          takes the foreground. Nothing composes a private desktop and SwapBuffers does not wait there (renderer.md,
          2026-10-14 LAT-01 trap 1), so its intervals are a check of the pipeline, not a measurement: the summary
          gives them as dry_run_p95_ms, never as frame_time_p95_ms.
  -Visible: the measurement. The copy runs on Default, which must be the caller's desktop and the input desktop
          (unlocked), composed by DWM, in a local session, the shell accepting notifications (no full-screen app or
          presentation mode), the display on, no screen saver running and Windows' foreground lock
          (SPI_GETFOREGROUNDLOCKTIMEOUT) longer than the idle time seen plus every run's longest duration
          (Get-FramePacingLockNeedMs: it counts from the user's last input, so it stays in force through the series;
          rechecked before each launch, and a run's staging is bounded), with no keyboard or mouse input for 300 s
          before the series (the pinned $script:MinIdleSeconds); the machine must be under 30% busy (waited for up to
          -QuietWaitSeconds, 900 by default, and nothing is launched when it never was; test-harnesses.md
          MEASUREMENT-HARNESS-RERUN-01). The series holds the display and the system on. Real input is detected by
          its injected flag, not inferred from ticks (GetLastInputInfo cannot tell the harness's unlock from the
          user): from admission to the series' end the outer half holds low-level keyboard and mouse hooks
          (WH_KEYBOARD_LL, WH_MOUSE_LL) on a thread with its own message loop, any event without LLKHF_INJECTED or
          LLMHF_INJECTED sets the series' event (the callbacks read only each event's flags and extra info and keep
          counts), and hooks that do not install refuse -Visible. Each hook's proof of life is the harness's own
          input of its kind, marked with a random nonzero 31-bit marker drawn for the series (an injected mouse event's
          extra info was measured reaching a low-level hook with only its low 32 bits, UNLOCK-HOOK-01; a key's width is
          unmeasured, and a 31-bit marker fits either): the mouse hook must see the unlock
          before the foreground is taken, the keyboard hook a VK_NONAME probe sent once the copy is in front, and the
          outer half's marked counts must show both after each run; Windows removes a low-level hook that times out
          without notice. Keystrokes into an elevated window and input a software KVM injects escape the flag; the
          tick, the second line, still sees them, except within milliseconds of the unlock and the keyboard probe,
          and the copy then ends at the driver's next tick check: every driver wait polls at 100 ms, and what does
          not poll is bounded per step (a trace request's message call up to 5 s if the copy stops answering, the
          display reading up to 2 s, the bounded foreground and probe workers up to 5 s; about 7 s for two back to
          back). A series that does not pass (exit 0) writes pacing.json from an allowlist (no number but the input
          counts and the exit code, no free text, reason codes from a fixed set) and the rest to diagnostics.json.
          A tick that moved by a run's end, or by the series' end, voids it like hook-seen input; the series reads its
          final input after the watch stops. The input gate (Test-FramePacingInputGate) reads
          that event first and the session's last-input tick second, right before each launch on Default (the
          visible driver's too),
          the unlock, the copy in front, the keyboard probe, each workload key and the measured window, and at each
          100 ms poll of every wait; on real input nothing further starts, takes the foreground or sends input, and
          the copy is ended, by the driver at its next poll or by the outer half, which waits on the hooks' latch and
          the driver together and closes the run's job the moment it observes the latch, with no grace (immediately
          on observation, plus OS scheduling latency; guards.json's LatchToKillMs records the delay). Input seen at
          any point in a series, by the hooks or the tick at any read, latches: the series is inconclusive and
          publishes nothing, whatever a driver's exit or a later matching read says. The copy takes the foreground
          through a bounded call: a marked absolute mouse move to the cursor's own pixel unlocks it (a zero-delta move
          never reaches the mouse hook; UNLOCK-HOOK-01), never an Alt tap (PROBE-ALT-TAP-01), then one
          SetForegroundWindow, with no AttachThreadInput fallback, no BringWindowToTop and no keyboard-state reset; the
          native worker checks the event right before its input and its foreground call, waits for the activation before
          it reports a refusal, and runs joined within 5 s, a timeout cancelling what it has not done
          (VISIBLE-PACING-CERT-01 trap (1)). noctty's own startup activation
          (Host.present) is not the harness's call and it cannot stop it: the foreground lock holds it back from a
          returning user under Microsoft's documented rules, except when no window holds the foreground, the user's
          input lands on the copy, or a right passes down the launch chain (inferred, not measured). The first
          includes a returning user whose foreground window goes away while the copy starts: the copy's first show
          can then take the foreground while their input arrives, a residual the harness accepts, bounded by the
          close on observing that input. A copy that took the foreground from another window before the unlock makes
          the run inconclusive. The lock is read again right before each copy's launch. A run in which any other
          input came, the foreground or the pane's focus changed, the display went off, a screen saver started or the
          machine was busy right before the window is inconclusive, never a sample. "Away" means no keyboard or mouse
          input: a gamepad or a video watched without input is not seen. Run it only while the machine's user is away
          (AGENTS.md "Running noctty"). A dry run posts the probe's VK_NONAME to the copy's pane instead and requires
          cmd's console unchanged and then exactly its prompt plus F5's command, read from its top-left cell through the
          cursor so a prompt or command that wraps is read whole.

The workload (bench-windows.ps1's `stream` throughput workload, without its PowerShell producer): 4,194,304 bytes of
printable ASCII from bench-windows.ps1's own generator (WritePayload, seed 121, copied byte for byte and held
identical by the contract), then the end marker framed as bench-windows.ps1 frames it (SGR reset, CUP 1;1, EL 2, a
unique token), in work\stream.bin. The copy's config binds F5 to the text `type stream.bin & echo.>done.flag` and F6
to `\r`; the driver posts F5, waits for the echo to go quiet, arms the render trace's target (WM_APP + 9 with 0: the
first swap that presents the end marker) and posts F6, so cmd's own `type` writes the payload and then done.flag.
Nothing is sent to the pane inside the window (noctty writes a trace snapshot on the presenting thread): the driver
polls done.flag as a file, waits 1 s, and only then requests one snapshot at a time until one shows the end marker's
swap; a snapshot that still shows the target armed landed inside the window, is counted (SnapshotsInWindow), and makes
the run inconclusive. The samples are the trace's intervals between consecutive successful SwapBuffers from the arm
through that swap (target_swap_interval_qpc_ticks over qpc_frequency, kept in memory by the trace, at most 2,048 a
run, an overflow fails the run); frame_time_p95_ms is their nearest-rank p95, pooled over the completed runs, as
bench-windows.ps1 aggregates its own. The first interval may hold the gap from the
newline's echo to the first payload frame. cmd's `type` delivers the payload at about 2.4 MB/s, a tenth of the bench's
PowerShell producer, so a run's window is about 1.8 s with about 420 intervals, and these numbers are not comparable
with the bench's own table (test-harnesses.md FRAME-PACING-01). The grid is 140 x 43 (window-width = 140,
window-height = 45, Consolas 16, renderer = opengl, read through the pane's pseudoconsole before the workload, as
#739 reads it). Runs compare only when
their WorkloadSha256 (these constants, the payload's SHA-256 and the config with the run's directory taken out),
app, renderer, transport and both ConPTY bundle digests match (a difference fails the series) and their display mode
(the window's monitor's width, height and refresh, read at each run's start and again after its window, where a
change makes the run inconclusive), DPI and grid match (a difference makes the series inconclusive). Each group of
runs alike in all nine fields is reported on its own (Groups), never combined across them. frame_time_p95_ms and its
median are published only for a visible series that passes (exit 0), every run completed and comparable; a passing dry
run has both null and gives dry_run_p95_ms, and a series that does not pass has neither field, since its pacing.json
is the allowlisted verdict (below), and the console says no measurement was published (a dry run that does not pass
prints "dry run: no timing published"). The exit code, by precedence:
3 a tripped guard, else 1 a failed run or a build or workload difference, else 2 an inconclusive run or an
environment difference, else 0 (Get-FramePacingExitCode).

Records in <RunRoot>: pacing.json (the summary: the mode, each run's status and statistics, each comparability group's,
the pooled p95 over the completed runs, and the real and injected input events a visible series' hooks saw; for every
series but a pass, only the allowlisted verdict, with the full summary in diagnostics.json beside it, written after it),
and per
run in run-<n>: run.json (the parameters, the copy's build mode, the SHA-256 of its app, CLI,
config and receipt, the ConPTY pair beside the build's, the transport and renderer its log names, the grid, the
window's client size, DPI and monitor mode before and after, the busy share before the launch, before the window and
after it, the timer resolution, the display's power state before and after, every input-gate check, every interval,
the snapshots inside the window, the visible part's facts, the keyboard probe's outcome or, in a dry run, its
effect on cmd's console, the exit), version.txt, noctty.log (the copy's stderr), driver.log, render-trace.json
(the copy's last trace snapshot), and guards.json.

Safety (AGENTS.md "Running noctty"; #739's rules). The outer half copies the measurement build without noctty.ico,
places `noctty.portable` beside the exe, writes the config and the payload, creates the desktop (dry run) and a
kill-on-close job, and starts this script as the driver at normal priority with LOCALAPPDATA, APPDATA, TEMP and TMP
inside the run (never for Git Bash or another msys program: nothing here starts one). The driver re-proves its
isolation before it starts anything: a job; in a dry run its own desktop, neither Default nor the input desktop; in a
visible run Default, the input desktop; those four variables inside the run; no inherited NOCTTY_ or GHOSTTY_
variable; and the build, the copy, the config bytes and the payload check out again. The native launches refuse any
other desktop. The copy is launched with exactly the expected argument list (the launch helper's isolation, its own
class, --single-instance=false, --window-save-state=never, the clipboard denied, --config-default-files=false and
--config-file=<copy>\config.ghostty) and nothing that sets the shell, read back from its own command line by PID.
Its shell is the config's `command = direct:<System32>\cmd.exe /D`, the only command; it starts no PowerShell (and
the driver checks none runs under the copy at the end). The config denies the clipboard, clears every default
binding and binds nothing that copies. The copy's environment adds only GHOSTTY_LOG, NOCTTY_RENDER_TRACE_FILE,
NOCTTY_RENDER_TRACE_LIVE and NOCTTY_BENCH_END_MARKER, never logged. Input is posted, never SendInput, except the
visible run's unlock (an absolute move to the cursor's own pixel) and its VK_NONAME keyboard probe, each marked and
behind the gate, and nothing attaches to another thread's input or resets key state; the visible series' hooks read only
each event's flags and extra info, count it and pass it on. The outer half compares the real startup-attempts.json's,
session-state.json's and the product jump list's size and time and the PSReadLine history's metadata before and after
each run, and
records the clipboard sequence number before and after. The shared state guard deletes a measurement-identity jump
list that did not exist before a run and whose creation and write times both fall inside it, whoever wrote it; run
one measurement workload at a time (the frame-pacing mutex covers only this harness).
What runs is the run's own copy: its path is checked before any launch and its image read back by PID, and the driver
runs in the run's own job, checked before it resumes and again by the outer half. Logs name kinds and sizes, never a
command line or an environment value.
#>
[CmdletBinding()]
param(
    [string] $MeasureRepo,
    [string] $RunRoot,
    [ValidateRange(1, 50)] [int] $Runs = 5,
    [switch] $Visible,
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')] [string] $ExpectedBuildMode = 'ReleaseFast',
    [ValidateRange(0, 3600)] [int] $QuietWaitSeconds = 900,
    # Internal: the driver half and its grid probe.
    [switch] $Driver,
    [string] $Run,
    [string] $Bin,
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,23}$')] [string] $SandboxName,
    [string] $DesktopName,
    [int] $GridProbePid = 0,
    # Internal: the dry run's console probe (the shell's PID and the file name's tag).
    [int] $CursorProbePid = 0,
    [ValidatePattern('^[a-z-]{1,24}$')] [string] $CursorProbeName = 'line',
    # Internal: the series' random marker, which the visible run's own injected input carries in its extra info.
    [long] $InputMarker = 0,
    # Internal: the named event the visible series' input watch signals on real keyboard or mouse input.
    [string] $InputWatchEvent,
    # Internal: the session's last-input tick a visible run's driver must still see (the tick the outer half saw idle,
    # then each run's after its own unlock); -1 in a dry run.
    [long] $QuietSinceTick = -1,
    # Internal: how long Windows' foreground lock must last for this series (Get-FramePacingLockNeedMs, from the
    # outer half's admission); -1 in a dry run.
    [long] $ForegroundLockNeededMs = -1
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
# The real startup ledger, the product jump list and the clipboard sequence: the shared state guard.
. (Join-Path $repoRoot 'scripts\interactive-win11-state-guard.ps1')
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:ResponseBoundMs = 5000
# The workload's constants. A change to any of them, to the generator or to the config changes WorkloadSha256, and
# runs with different WorkloadSha256 are not comparable. Cols, Rows, FontFamily and FontSize are bench-windows.ps1's
# defaults; GridRows is the grid a run must show before the workload (measured on the 0a build).
$script:Cols = 140
$script:Rows = 45
$script:GridRows = 43
$script:FontFamily = 'Consolas'
$script:FontSize = 16
$script:PayloadWorkload = 'stream'
$script:PayloadBytes = 4194304
$script:PayloadSeed = 121
$script:IntervalCapacity = 2048
$script:QuietMs = 1000
$script:EchoQuietMs = 500
$script:QuietBusyPercent = 30
# The visible run's gates (Opus on #741, pinned by the contract): no keyboard or mouse input for 300 s before a series,
# a foreground call bounded at 5 s, the shell accepting notifications (5) and the display on (1); and the wait after
# the producer's end before the one snapshot that reads the window, so no snapshot request lands inside it.
$script:MinIdleSeconds = 300
$script:ForegroundBoundMs = 5000
$script:NotificationsAccepted = 5
$script:DisplayOn = 1
$script:DrainMs = 1000
# The outer half ends a driver that runs past the first, a visible run's staging and guard setup that ran past the
# second is inconclusive before its driver starts (Sol on #741), and the third, their sum, is the longest a run can
# take before its copy is gone; Windows' foreground lock must outlast the user's idle time plus that bound for every
# run still to come (Get-FramePacingLockNeedMs; Greptile on #741: the lock counts from the user's last input, so a
# 200,000 ms lock has already expired after the 300 s the series waits for).
$script:DriverDeadlineMs = 1800000
$script:StagingBoundMs = 300000
# A hook that did not see the harness's own marked input may have been removed (Windows drops a low-level hook that
# times out, without notice): the driver refuses the run with one of these, and the outer half keeps such a run failed
# whatever input stop follows (Greptile on #741).
$script:MouseHookMissed = 'The input watch''s mouse hook did not see the harness''s own unlock, so it may have been removed; the run is refused.'
$script:KeyHookMissed = 'The input watch''s keyboard hook did not see the harness''s own key probe, so it may have been removed; the run is refused.'
$script:RunBoundMs = 2100000
# win32/consts.zig WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT and WM_WINHOSTTY_RENDER_TRACE_TARGET (WM_APP + 8 and + 9), as
# bench-windows.ps1 names them.
$script:WmRenderTraceSnapshot = [uint32](0x8000 + 8)
$script:WmRenderTraceTarget = [uint32](0x8000 + 9)
# processthreadsapi.h STARTUPINFOW and STARTUPINFOEXW, winnt.h JOBOBJECT_EXTENDED_LIMIT_INFORMATION, tlhelp32.h
# PROCESSENTRY32W, consoleapi2.h CONSOLE_SCREEN_BUFFER_INFO with COORD and SMALL_RECT, winuser.h INPUT with MOUSEINPUT
# and LASTINPUTINFO, minwinbase.h SECURITY_ATTRIBUTES, processthreadsapi.h PROCESS_INFORMATION, windef.h RECT, and
# winuser.h WNDCLASSEXW, MSG, KBDLLHOOKSTRUCT and MSLLHOOKSTRUCT, on x64 (AGENTS.md "Win32 FFI"; none of those
# headers changes the packing). INPUT's union is MOUSEINPUT's 32 bytes, the largest member, after 4 bytes of padding;
# SECURITY_ATTRIBUTES pads its DWORD to the pointer after it and its BOOL to 24; MSG's 44 bytes of fields pad to 48;
# KBDLLHOOKSTRUCT's four DWORDs reach its ULONG_PTR at 16 (24), MSLLHOOKSTRUCT's POINT and three DWORDs pad to 24 (32);
# KEYBDINPUT's two WORDs and two DWORDs pad to its ULONG_PTR at 16 (24), and INPUT holding it pads to INPUT's 40.
$script:SdkLayout = 'Startup=104 desktop@16 flags@60 show@64 output@88 error@96 StartupEx=112 attributes@104 JobLimits=144 limitFlags@16 ProcessEntry=568 processId@8 heapId@16 parentProcessId@32 exeFile@44 ScreenBufferInfo=22 cursor@4 wAttributes@8 window@10 maxWindow@18 Coord=4 SmallRect=8 Input=40 mouse@8 MouseInput=32 mouseFlags@12 mouseExtra@24 KeyInput=40 keybd@8 KeybdInput=24 keybdFlags@4 keybdExtra@16 LastInput=8 SecurityAttributes=24 saDescriptor@8 saInherit@16 ProcessInfo=24 piThread@8 piPid@16 piTid@20 Rect=16 rectRight@8 rectBottom@12 WndClassEx=80 wcProc@8 wcClassName@64 Msg=48 msgWParam@16 msgTime@32 KbdHook=24 kbdFlags@8 kbdExtra@16 MouseHook=32 mouseHookFlags@12 mouseHookExtra@24'

if (-not ('FramePacingNative' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class FramePacingNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup info; public IntPtr attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential)] struct MouseInput { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint type; public MouseInput mouse; }
    // INPUT with KEYBDINPUT (winuser.h): the union is MOUSEINPUT's 32 bytes, so the struct pads to INPUT's 40.
    [StructLayout(LayoutKind.Sequential)] struct KeybdInput { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential, Size=40)] struct KeyInput { public uint type; public KeybdInput keybd; }
    [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint size, time; }
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
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
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
    // The run's job, as #739's: its processes die when the harness closes it (KILL_ON_JOB_CLOSE), and an unhandled
    // exception ends a process instead of waiting in WER's dialog (DIE_ON_UNHANDLED_EXCEPTION).
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
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder name, int length, out int needed);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, KeyInput[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput info);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("dwmapi.dll")] static extern int DwmIsCompositionEnabled(out bool enabled);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out int value, int size);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr monitor, IntPtr info);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplaySettingsW")] static extern bool EnumDisplaySettingsRaw(string device, int mode, IntPtr devmode);
    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint minimum, out uint maximum, out uint current);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("kernel32.dll")] static extern ushort GetActiveProcessorGroupCount();
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    public delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct WndClassEx { public uint size, style; public WndProc proc; public int clsExtra, wndExtra; public IntPtr instance, icon, cursor, background; public string menu, className; public IntPtr iconSmall; }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern ushort RegisterClassExW(ref WndClassEx c);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool UnregisterClassW(string name, IntPtr instance);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowExW(uint exStyle, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PeekMessageW(out Msg m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref Msg m);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr RegisterPowerSettingNotification(IntPtr recipient, ref Guid setting, uint flags);
    [DllImport("user32.dll")] static extern bool UnregisterPowerSettingNotification(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandleW(IntPtr name);
    // The console display's power state (GUID_CONSOLE_DISPLAY_STATE: 0 off, 1 on, 2 dimmed), or -1 when no answer came
    // within `ms` (Opus on #741: DWM's composition flag cannot see a monitor that is off). Registering a window for the
    // setting delivers its current value at once; a message-only window on a worker thread takes it and goes away.
    public static int DisplayPower(int ms) {
        int state = -1;
        var t = new Thread(() => {
            string cls = "FramePacingPower" + Guid.NewGuid().ToString("N");
            IntPtr instance = GetModuleHandleW(IntPtr.Zero);
            WndProc proc = (h, m, w, l) => {
                // WM_POWERBROADCAST, PBT_POWERSETTINGCHANGE; POWERBROADCAST_SETTING is the GUID (16), DataLength (4), Data.
                if (m == 0x0218 && w.ToInt64() == 0x8013 && l != IntPtr.Zero && Marshal.ReadInt32(l, 16) >= 4) state = Marshal.ReadInt32(l, 20);
                return DefWindowProcW(h, m, w, l);
            };
            var wc = new WndClassEx { size = (uint)Marshal.SizeOf<WndClassEx>(), proc = proc, instance = instance, className = cls };
            if (RegisterClassExW(ref wc) == 0) return;
            IntPtr hwnd = CreateWindowExW(0, cls, "", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, instance, IntPtr.Zero); // HWND_MESSAGE
            if (hwnd == IntPtr.Zero) { UnregisterClassW(cls, instance); return; }
            Guid setting = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
            IntPtr reg = RegisterPowerSettingNotification(hwnd, ref setting, 0); // DEVICE_NOTIFY_WINDOW_HANDLE
            try {
                var clock = System.Diagnostics.Stopwatch.StartNew();
                while (state < 0 && clock.ElapsedMilliseconds < ms) {
                    Msg msg;
                    while (PeekMessageW(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessageW(ref msg); }
                    Thread.Sleep(10);
                }
            } finally {
                if (reg != IntPtr.Zero) UnregisterPowerSettingNotification(reg);
                DestroyWindow(hwnd); UnregisterClassW(cls, instance); GC.KeepAlive(proc);
            }
        });
        t.IsBackground = true; t.Start(); t.Join(ms + 1000);
        return state;
    }
    // The shell's view of the user (SHQueryUserNotificationState): 5 is QUNS_ACCEPTS_NOTIFICATIONS; a full-screen
    // app, presentation mode, quiet time or a locked session give another value (Opus on #741). -1 when it failed.
    public static int NotificationState() { int s; return SHQueryUserNotificationState(out s) == 0 ? s : -1; }
    // The display and the system kept on for the calling thread while a visible series runs (ES_CONTINUOUS |
    // ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED; Opus on #741: the series starts after 300 s with no input, where the
    // display timeout fires), then released. Neither touches the session's last-input time.
    public static bool HoldDisplay() { return SetThreadExecutionState(0x80000000 | 0x2 | 0x1) != 0; }
    public static void ReleaseDisplay() { SetThreadExecutionState(0x80000000); }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)] static extern bool SpiUint(uint action, uint param, out uint value, uint winIni);
    // SPI_GETSCREENSAVERRUNNING (0x0072): 1 while a screen saver runs, 0 when none, -1 when the read failed (Opus on
    // #741: holding the display on does not stop a screen saver).
    public static int ScreenSaverRunning() { uint v; return SpiUint(0x0072, 0, out v, 0) ? (v != 0 ? 1 : 0) : -1; }
    // SPI_GETFOREGROUNDLOCKTIMEOUT (0x2000) in ms, or -1 when the read failed (Sol on #741).
    public static long ForegroundLockTimeout() { uint v; return SpiUint(0x2000, 0, out v, 0) ? (long)v : -1; }

    // The visible series' input watch (the lead and CodeRabbit on #741). Low-level keyboard and mouse hooks
    // (WH_KEYBOARD_LL, WH_MOUSE_LL) on a dedicated thread with its own message loop, in the outer half, from admission
    // to the end of the series. An event without LLKHF_INJECTED or LLMHF_INJECTED is real hardware input: it is counted
    // and sets the series' named, manual-reset event, which every driver opens and reads before each step. An injected
    // event is counted, and only one carrying the series' random marker in its extra info (the harness's own unlock or
    // key probe; Opus and Sol on #741) sets an auto-reset event of its own kind ("<name>-mouse" or "<name>-key"),
    // which a driver waits on to see that the hook of that kind saw its own input. Windows removes a low-level hook
    // whose callback runs past LowLevelHooksTimeout without notice, and a removed hook would leave the real-input event
    // clear for good, so each hook's proof of life is the harness's own marked input. The callbacks stay trivial so
    // they cannot time out: two words read (the flags and the extra info), a counter, at most one SetEvent.
    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct KbdHook { public uint vk, scan, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MouseHook { public int x, y; public uint data, flags, time; public UIntPtr extra; }
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetMessageW(out Msg m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint thread, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateEventW(IntPtr sa, bool manualReset, bool initialState, string name);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr OpenEventW(uint access, bool inherit, string name);
    [DllImport("kernel32.dll")] static extern bool SetEvent(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")] static extern uint WaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long count);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long frequency);
    static IntPtr watchEvent = IntPtr.Zero, mouseEvent = IntPtr.Zero, keyEvent = IntPtr.Zero, inputMarker = IntPtr.Zero;
    static long realInputs, injectedInputs, markedMice, markedKeys;
    static Thread watchThread;
    static volatile uint watchThreadId;
    static ManualResetEvent watchCancel;
    static HookProc keyboardProc, mouseProc;
    // One hook event, by its flags (KBDLLHOOKSTRUCT.flags, MSLLHOOKSTRUCT.flags) and extra info: real, the harness's
    // own marked input (mouse or key), or another program's injected input, which is counted and proves nothing.
    static void Classify(bool keyboard, uint flags, IntPtr extra) {
        bool injected = keyboard ? (flags & 0x10) != 0 : (flags & 0x01) != 0;
        if (!injected) { Interlocked.Increment(ref realInputs); if (watchEvent != IntPtr.Zero) SetEvent(watchEvent); return; }
        Interlocked.Increment(ref injectedInputs);
        if (inputMarker == IntPtr.Zero || extra != inputMarker) return;
        if (keyboard) { Interlocked.Increment(ref markedKeys); if (keyEvent != IntPtr.Zero) SetEvent(keyEvent); }
        else { Interlocked.Increment(ref markedMice); if (mouseEvent != IntPtr.Zero) SetEvent(mouseEvent); }
    }
    public static long RealInputs() { return Interlocked.Read(ref realInputs); }
    public static long InjectedInputs() { return Interlocked.Read(ref injectedInputs); }
    public static long MarkedMouseInputs() { return Interlocked.Read(ref markedMice); }
    public static long MarkedKeyInputs() { return Interlocked.Read(ref markedKeys); }
    public static void ResetWatchCounts() {
        Interlocked.Exchange(ref realInputs, 0); Interlocked.Exchange(ref injectedInputs, 0);
        Interlocked.Exchange(ref markedMice, 0); Interlocked.Exchange(ref markedKeys, 0);
    }
    // The hooks' callbacks read two words of the event, its flags (KBDLLHOOKSTRUCT.flags at 8, MSLLHOOKSTRUCT.flags at
    // 12) and its extra info (at 16 and 24), as Layout() pins them, and nothing else: never the key code, scan code,
    // position or time, which a keyboard hook would otherwise see for every key the user types, passwords included
    // (the lead on #741). Classify keeps only counts. Then the next hook. Public so the contract can deliver a synthetic
    // event to them.
    public static IntPtr KeyboardEvent(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) Classify(true, (uint)Marshal.ReadInt32(lParam, 8), Marshal.ReadIntPtr(lParam, 16));
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }
    public static IntPtr MouseEvent(int code, IntPtr wParam, IntPtr lParam) {
        if (code >= 0) Classify(false, (uint)Marshal.ReadInt32(lParam, 12), Marshal.ReadIntPtr(lParam, 24));
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }
    // Creates the series' three events, keeps its marker, and installs both hooks; true only when both are in place
    // within `ms`. The thread checks this watch's cancellation before it installs anything and before its message
    // loop, so a watch given up on during startup never installs its hooks late (CodeRabbit on #741).
    public static bool StartWatch(string eventName, int ms, IntPtr marker) {
        if (watchThread != null || marker == IntPtr.Zero) return false;
        IntPtr real = CreateEventW(IntPtr.Zero, true, false, eventName);
        if (real == IntPtr.Zero) return false;
        IntPtr mouse = CreateEventW(IntPtr.Zero, false, false, eventName + "-mouse");
        IntPtr key = CreateEventW(IntPtr.Zero, false, false, eventName + "-key");
        if (mouse == IntPtr.Zero || key == IntPtr.Zero) { CloseHandle(real); CloseOwn(mouse); CloseOwn(key); return false; }
        watchEvent = real; mouseEvent = mouse; keyEvent = key; inputMarker = marker;
        var cancel = new ManualResetEvent(false);
        watchCancel = cancel;
        bool installed = false;
        var ready = new ManualResetEvent(false);
        keyboardProc = KeyboardEvent;
        mouseProc = MouseEvent;
        watchThread = new Thread(() => {
            Msg first; PeekMessageW(out first, IntPtr.Zero, 0, 0, 0); // PM_NOREMOVE: the queue StopWatch posts to exists
            watchThreadId = GetCurrentThreadId();
            // The hooks come out on every path, in the finally (Sol on #741), and StartWatch is released even when
            // this thread throws.
            IntPtr kh = IntPtr.Zero, mh = IntPtr.Zero;
            try {
                if (!cancel.WaitOne(0)) {
                    IntPtr module = GetModuleHandleW(IntPtr.Zero);
                    kh = SetWindowsHookExW(13, keyboardProc, module, 0);
                    mh = SetWindowsHookExW(14, mouseProc, module, 0);
                }
                installed = kh != IntPtr.Zero && mh != IntPtr.Zero;
                ready.Set();
                if (installed && !cancel.WaitOne(0)) { Msg msg; while (GetMessageW(out msg, IntPtr.Zero, 0, 0) > 0) { } }
            } finally {
                if (kh != IntPtr.Zero) UnhookWindowsHookEx(kh);
                if (mh != IntPtr.Zero) UnhookWindowsHookEx(mh);
                ready.Set();
            }
        });
        watchThread.IsBackground = true;
        watchThread.Start();
        if (!ready.WaitOne(ms) || !installed) { StopWatch(); return false; }
        return true;
    }
    // Cancels the watch, asks its thread to leave its loop and waits for it to unhook. Only then are its events closed
    // and its state cleared (CodeRabbit on #741: a callback must never signal a closed, possibly reused, handle); a
    // thread that has not ended within 2 s keeps them, false is returned, and the process's exit ends it.
    public static bool StopWatch() {
        if (watchThread != null) {
            watchCancel.Set();
            uint tid = watchThreadId;
            if (tid != 0) PostThreadMessageW(tid, 0x0012, IntPtr.Zero, IntPtr.Zero); // WM_QUIT
            if (!watchThread.Join(2000)) return false;
            watchThread = null; watchThreadId = 0; watchCancel = null;
        }
        if (watchEvent != IntPtr.Zero) { CloseHandle(watchEvent); watchEvent = IntPtr.Zero; }
        if (mouseEvent != IntPtr.Zero) { CloseHandle(mouseEvent); mouseEvent = IntPtr.Zero; }
        if (keyEvent != IntPtr.Zero) { CloseHandle(keyEvent); keyEvent = IntPtr.Zero; }
        inputMarker = IntPtr.Zero;
        return true;
    }
    // The outer half's wait on a driver (the lead, Sol and Opus on #741): on the series' real-input latch and the
    // driver together, the latch first, so a latch set by the time the driver ends still reads as input
    // (WaitForMultipleObjects reports the lowest signalled index). The moment it sees the latch it closes the run's
    // job itself, which ends the driver and the copy wherever the driver is: no grace, and nothing between the wait's
    // return and TerminateJobObject but one counter read. `observed` and `closed` are QueryPerformanceCounter readings
    // at the wait's return and at TerminateJobObject's. Returns 1 the latch seen and the job terminated, 2 the latch
    // seen and TerminateJobObject failed, 0 the driver ended, 0x102 the timeout, -1 a failed wait. Without a latch (a
    // dry run has no watch) it waits on the driver alone. Public with its latch so the contract can drive it.
    public static int Supervise(IntPtr latch, IntPtr process, IntPtr job, uint ms, out long observed, out long closed) {
        observed = 0; closed = 0;
        if (latch == IntPtr.Zero) { uint single = WaitForSingleObject(process, ms); return single == 0 ? 0 : single == 0x102 ? 0x102 : -1; }
        uint r = WaitForMultipleObjects(2, new IntPtr[] { latch, process }, false, ms);
        QueryPerformanceCounter(out observed);
        if (r == 0) { bool terminated = TerminateJobObject(job, 1); QueryPerformanceCounter(out closed); return terminated ? 1 : 2; }
        return r == 1 ? 0 : r == 0x102 ? 0x102 : -1;
    }
    // The supervision on this series' own latch, the real-input event the watch created.
    public static int SuperviseDriver(IntPtr process, IntPtr job, uint ms, out long observed, out long closed) {
        return Supervise(watchEvent, process, job, ms, out observed, out closed);
    }
    public static long PerformanceFrequency() { long f; return QueryPerformanceFrequency(out f) ? f : 0; }
    public static long PerformanceCounter() { long c; return QueryPerformanceCounter(out c) ? c : 0; }
    // A driver's handles to the series' three events (SYNCHRONIZE only: it can wait on them, never set or clear the
    // real-input one), or zero; and whether real input has signalled the watch. Anything but WAIT_TIMEOUT counts as
    // input (Sol on #741: a failed wait, a zero or closed handle, must never read as quiet).
    public static IntPtr OpenWatch(string eventName) { return OpenEventW(0x00100000, false, eventName); }
    public static IntPtr OpenMouseWatch(string eventName) { return OpenEventW(0x00100000, false, eventName + "-mouse"); }
    public static IntPtr OpenKeyWatch(string eventName) { return OpenEventW(0x00100000, false, eventName + "-key"); }
    public static bool RealInputSignalled(IntPtr watch) { return watch == IntPtr.Zero || WaitForSingleObject(watch, 0) != 0x102; }

    public static string Layout() {
        return string.Join(" ", new string[] {
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
            "SmallRect=" + Marshal.SizeOf<SmallRect>(), "Input=" + Marshal.SizeOf<Input>(), "mouse@" + Marshal.OffsetOf<Input>("mouse"),
            "MouseInput=" + Marshal.SizeOf<MouseInput>(), "mouseFlags@" + Marshal.OffsetOf<MouseInput>("flags"), "mouseExtra@" + Marshal.OffsetOf<MouseInput>("extra"),
            "KeyInput=" + Marshal.SizeOf<KeyInput>(), "keybd@" + Marshal.OffsetOf<KeyInput>("keybd"), "KeybdInput=" + Marshal.SizeOf<KeybdInput>(),
            "keybdFlags@" + Marshal.OffsetOf<KeybdInput>("flags"), "keybdExtra@" + Marshal.OffsetOf<KeybdInput>("extra"),
            "LastInput=" + Marshal.SizeOf<LastInput>(),
            "SecurityAttributes=" + Marshal.SizeOf<SecurityAttributes>(), "saDescriptor@" + Marshal.OffsetOf<SecurityAttributes>("descriptor"),
            "saInherit@" + Marshal.OffsetOf<SecurityAttributes>("inherit"), "ProcessInfo=" + Marshal.SizeOf<ProcessInfo>(),
            "piThread@" + Marshal.OffsetOf<ProcessInfo>("thread"), "piPid@" + Marshal.OffsetOf<ProcessInfo>("pid"), "piTid@" + Marshal.OffsetOf<ProcessInfo>("tid"),
            "Rect=" + Marshal.SizeOf<Rect>(), "rectRight@" + Marshal.OffsetOf<Rect>("right"), "rectBottom@" + Marshal.OffsetOf<Rect>("bottom"),
            "WndClassEx=" + Marshal.SizeOf<WndClassEx>(), "wcProc@" + Marshal.OffsetOf<WndClassEx>("proc"), "wcClassName@" + Marshal.OffsetOf<WndClassEx>("className"),
            "Msg=" + Marshal.SizeOf<Msg>(), "msgWParam@" + Marshal.OffsetOf<Msg>("wParam"), "msgTime@" + Marshal.OffsetOf<Msg>("time"),
            "KbdHook=" + Marshal.SizeOf<KbdHook>(), "kbdFlags@" + Marshal.OffsetOf<KbdHook>("flags"), "kbdExtra@" + Marshal.OffsetOf<KbdHook>("extra"),
            "MouseHook=" + Marshal.SizeOf<MouseHook>(), "mouseHookFlags@" + Marshal.OffsetOf<MouseHook>("flags"), "mouseHookExtra@" + Marshal.OffsetOf<MouseHook>("extra") });
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
    // The input desktop's name, or null when it cannot be opened or read (a locked session's Winlogon desktop).
    public static string InputDesktopName() {
        IntPtr h = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS
        if (h == IntPtr.Zero) return null;
        try { return NameOf(h); } finally { CloseDesktop(h); }
    }
    static bool Same(string a, string b) { return string.Equals(a, b, StringComparison.OrdinalIgnoreCase); }
    // Why a launch may not go onto `target`, or null (all names "WinSta0\\<desktop>"; `input` is null when the input
    // desktop cannot be read, as in a locked session). A dry run's driver goes onto a private desktop only: never the
    // caller's own, Default or the input desktop (#739's rule); a dry run's child onto the caller's own desktop only,
    // never Default or the input desktop. A visible run's driver and child go onto Default only, from Default, while
    // Default is the input desktop. Pure, so the contract tables it; both launches call it with the live names.
    public static string DesktopRefusal(string target, string own, string input, bool visible, bool driver) {
        if (string.IsNullOrEmpty(target)) return "A launch must name its desktop";
        if (input == null) return "The input desktop is unreadable";
        string def = "WinSta0\\Default", inp = "WinSta0\\" + input;
        if (visible) {
            if (!Same(target, def) || !Same(own, def) || !Same(inp, def))
                return driver ? "A visible driver starts only on Default, from Default, while Default is the input desktop" : "A visible child starts only on Default, from Default, while Default is the input desktop";
            return null;
        }
        if (driver) return Same(target, own) || Same(target, def) || Same(target, inp) ? "The driver must start on a private desktop, not the caller's, Default or the input desktop" : null;
        if (!Same(target, own)) return "A child must start on the caller's own desktop";
        if (Same(target, def) || Same(target, inp)) return "A child must not start on Default or the input desktop";
        return null;
    }
    // Whether `process` runs in the job `job` (not merely in some job).
    public static bool InJobOf(IntPtr process, IntPtr job) { bool r; return IsProcessInJob(process, job, out r) && r; }
    // The driver: suspended, assigned to the run's own job and checked a member of it before it runs (Sol on #741: a
    // driver that resumed outside it would escape the kill-on-close cleanup), no console window, normal priority (no
    // priority flag), its desktop named in STARTUPINFO and admitted by DesktopRefusal.
    public static ProcessInfo LaunchDriver(string app, string command, string cwd, string desktop, IntPtr job, bool visible) {
        if (string.IsNullOrEmpty(desktop)) throw new Exception("A launch must name its desktop");
        string refusal = DesktopRefusal(desktop, "WinSta0\\" + CurrentDesktopName(), InputDesktopName(), visible, true);
        if (refusal != null) throw new Exception(refusal);
        var si = new Startup { cb = Marshal.SizeOf<Startup>(), desktop = desktop, flags = 1, show = 0 }; ProcessInfo pi;
        if (!CreateProcessW(app, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false, 0x08000004, IntPtr.Zero, cwd, ref si, out pi))
            throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, pi.process) || !InJobOf(pi.process, job) || ResumeThread(pi.thread) == 0xFFFFFFFF) {
            TerminateProcess(pi.process, 1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("The driver is not in the run's own job; it was ended before it ran");
        }
        return pi;
    }
    // A child of the driver on `desktop`, its standard output and error in `logPath` (the only handle it inherits),
    // at normal priority (0x20), with no console window (0x08000000) when `noWindow`. No STARTF_USESHOWWINDOW, so a GUI
    // window shows on its desktop (renderer.md LAT-01 trap 3). Its desktop is admitted by DesktopRefusal: the caller's
    // own, never Default or the input desktop in a dry run; Default while it is the input desktop in a visible run.
    public static ProcessInfo Spawn(string app, string command, string cwd, string desktop, string logPath, bool noWindow, bool visible) {
        if (string.IsNullOrEmpty(desktop)) throw new Exception("A launch must name its desktop");
        string refusal = DesktopRefusal(desktop, "WinSta0\\" + CurrentDesktopName(), InputDesktopName(), visible, false);
        if (refusal != null) throw new Exception(refusal);
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
    // A key as a posted WM_KEYDOWN/WM_KEYUP pair to a window of `pid`, and nothing else: no AttachThreadInput and no
    // keyboard-state reset, unlike #739's Key (the lead on #741: in a visible run noctty's thread is in front and its
    // input state is the user's). The config binds F5 and F6 under all eight modifier chords, so a modifier the
    // thread sees latched cannot change what the key does.
    public static void PostKey(IntPtr h, int pid, int vk) {
        if (Owner(h) != pid) throw new Exception("The window is not this copy's");
        if (!PostMessageW(h, 0x100, new IntPtr(vk), new IntPtr(1))) throw new Exception("Key-down post failed");
        if (!PostMessageW(h, 0x101, new IntPtr(vk), new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    // A render-trace control message (WM_APP + 8 or + 9) to a pane of `pid`, sent with SMTO_ABORTIFHUNG and a bound;
    // true when the pane answered.
    public static bool TraceMessage(IntPtr surface, int pid, uint message, ulong wParam, uint ms) {
        if (Owner(surface) != pid) throw new Exception("The pane is not this copy's");
        IntPtr result; return SendMessageTimeoutW(surface, message, new IntPtr((long)wParam), IntPtr.Zero, 2, ms, out result) != IntPtr.Zero;
    }
    // The visible run's foreground, bounded (test-harnesses.md VISIBLE-PACING-CERT-01 trap (1): these cross-thread
    // calls can wait on the target's UI thread with no bound). The window must be this copy's, not hung, and answer
    // WM_NULL within the bound first; the calls then run on a worker thread joined within the bound, and a timeout is
    // an environment failure, never retried. The unlock is a marked absolute mouse move to the cursor's own pixel
    // (test-harnesses.md UNLOCK-HOOK-01: a zero-delta move never reaches the mouse hook), not an Alt tap, which can
    // leave the window in a menu loop that takes the next key (PROBE-ALT-TAP-01). The foreground is then one
    // SetForegroundWindow, which Windows allows the process that sent the last input. There is no attach fallback
    // and no raising call: the lead on #741 had both removed, since attaching to the user's foreground thread resets
    // its key state and could clear a modifier a returning user holds.
    // The series' input watch is the gate (the lead, Sol and CodeRabbit on #741: GetLastInputInfo cannot tell the
    // unlock from the user's input): immediately before its one SendInput and its one SetForegroundWindow the worker
    // reads the watch's event (`watch`, the outer half's hooks; a failed read counts as input), and real input, or the
    // cancellation a timeout sets, stops it with nothing further sent or taken. The unlock carries the series' marker
    // and must be seen twice: the session's tick must move from the series' tick to a valid one within 1 s
    // ("unlock-not-observed"; a failed read, -1, is never a move), and the mouse hook must have seen the marked event
    // (`mouseWatch`), its proof of life ("unlock-not-seen-by-hook" otherwise). The tick is read again right before the
    // foreground call (Sol on #741). Activation lands on the copy's own queue, so a bounded WM_NULL round trip and a
    // poll of up to 500 ms, reading the watch each time, come before "refused" (CodeRabbit on #741). The worker works
    // on its own duplicates of the handles, closed when it ends, so a caller that gave up on it may close its own.
    // `unlockTick` is the tick the unlock moved to (-1 when it was not sent or not seen).
    public static string Foreground(IntPtr hwnd, int pid, int boundMs, long expectedTick, IntPtr watch, IntPtr mouseWatch, IntPtr marker, out long unlockTick) {
        unlockTick = -1;
        if (Owner(hwnd) != pid) return "not-this-copy";
        if (watch == IntPtr.Zero || mouseWatch == IntPtr.Zero || marker == IntPtr.Zero) return "no-input-watch";
        if (IsHungAppWindow(hwnd) || !Responsive(hwnd, (uint)boundMs)) return "hung";
        IntPtr real = DuplicateOwn(watch), mouse = DuplicateOwn(mouseWatch);
        if (real == IntPtr.Zero || mouse == IntPtr.Zero) { CloseOwn(real); CloseOwn(mouse); return "no-input-watch"; }
        var cancel = new ManualResetEvent(false);
        string outcome = null;
        long tick = -1;
        var worker = new Thread(() => {
            try {
                // The unlock aimed at the cursor's own pixel, before the gate (UNLOCK-HOOK-01). The cursor is read
                // again after the gate's last check, and the unlock goes only if it is still on that pixel
                // ("unlock-raced"); after the hook's signal it is read once more ("unlock-moved-cursor"), a read that
                // normally, but not always, follows the move: the hook signals from inside its callback, before
                // Windows applies the move. No coordinate leaves this worker.
                CursorPoint aim;
                var unlock = UnlockHere(marker, out aim);
                if (unlock == null) { outcome = "unlock-unaimed"; return; }
                long before = LastInputTick();
                if (before < 0 || before != expectedTick) { outcome = "input-before-unlock"; return; }
                WaitForSingleObject(mouse, 0); // an earlier marked event's signal: the next one must be this unlock's
                if ((outcome = Halt(cancel, real, "real-input-before-unlock")) != null) return;
                if ((outcome = CursorAway(aim, "unlock-raced")) != null) return;
                if (SendInput(1, unlock, Marshal.SizeOf<Input>()) != 1) { outcome = "unlock-not-inserted"; return; }
                long now = WaitTickMove(before, 1000);
                // The unlock's tick is the harness's own even when the hook missed it (Greptile on #741, as the probe).
                if (now >= 0 && now != before) tick = now;
                bool hookSaw = WaitForSingleObject(mouse, 1000) == 0;
                if ((outcome = ProbeSeen("unlock", before, now, hookSaw)) != null) return;
                if ((outcome = CursorAway(aim, "unlock-moved-cursor")) != null) return;
                if (LastInputTick() != now) { outcome = "input-before-foreground"; return; }
                if ((outcome = Halt(cancel, real, "real-input-before-foreground")) != null) return;
                SetForegroundWindow(hwnd);
                Responsive(hwnd, 500);
                var activation = System.Diagnostics.Stopwatch.StartNew();
                while (GetForegroundWindow() != hwnd && activation.ElapsedMilliseconds < 500) {
                    if ((outcome = Halt(cancel, real, "real-input-during-activation")) != null) return;
                    Thread.Sleep(10);
                }
                outcome = GetForegroundWindow() == hwnd ? "ok" : "refused";
            } finally { CloseOwn(real); CloseOwn(mouse); }
        });
        worker.IsBackground = true;
        worker.Start();
        if (!worker.Join(boundMs)) { cancel.Set(); return "timeout"; }
        unlockTick = tick;
        return outcome ?? "unknown";
    }
    // The keyboard hook's proof of life (the lead and CodeRabbit on #741), once the copy is in front and after the
    // driver's gate: one VK_NONAME (0xFC) down and up, marked like the unlock, which the copy takes as a key with no
    // binding and no character (win32/input.zig's "VK_NONAME, the frame-pacing keyboard probe" test: nothing with
    // Win32 input mode off, one KEY_EVENT_RECORD each way with no character with it on). The worker checks that the
    // copy is still in front, then the session's tick and the watch, right before its one SendInput; then the tick
    // must move to a valid one and the keyboard hook must see the marked key ("key-probe-not-seen-by-hook"
    // otherwise). Bounded, cancelled on a timeout, and on its own handle duplicates, as Foreground. `probeTick` is the
    // tick the probe moved to, which the run expects from then on.
    public static string KeyProbe(IntPtr hwnd, int pid, int boundMs, long expectedTick, IntPtr watch, IntPtr keyWatch, IntPtr marker, out long probeTick) {
        probeTick = -1;
        if (Owner(hwnd) != pid) return "not-this-copy";
        if (watch == IntPtr.Zero || keyWatch == IntPtr.Zero || marker == IntPtr.Zero) return "no-input-watch";
        IntPtr real = DuplicateOwn(watch), key = DuplicateOwn(keyWatch);
        if (real == IntPtr.Zero || key == IntPtr.Zero) { CloseOwn(real); CloseOwn(key); return "no-input-watch"; }
        var cancel = new ManualResetEvent(false);
        string outcome = null;
        long tick = -1;
        var worker = new Thread(() => {
            try {
                WaitForSingleObject(key, 0); // an earlier marked key's signal: the next one must be this probe's
                if (GetForegroundWindow() != hwnd) { outcome = "not-in-front"; return; }
                long before = LastInputTick();
                if (before < 0 || before != expectedTick) { outcome = "input-before-key-probe"; return; }
                if ((outcome = Halt(cancel, real, "real-input-before-key-probe")) != null) return;
                if (SendInput(2, KeyProbeInput(marker), Marshal.SizeOf<KeyInput>()) != 2) { outcome = "key-probe-not-inserted"; return; }
                long now = WaitTickMove(before, 1000);
                // The tick the probe moved is the harness's own even when the hook missed it (Greptile on #741), so
                // the outer half never reads it as a user's input and a dead hook stays a failure.
                if (now >= 0 && now != before) tick = now;
                bool hookSaw = WaitForSingleObject(key, 1000) == 0;
                if ((outcome = ProbeSeen("key-probe", before, now, hookSaw)) != null) return;
                outcome = "ok";
            } finally { CloseOwn(real); CloseOwn(key); }
        });
        worker.IsBackground = true;
        worker.Start();
        if (!worker.Join(boundMs)) { cancel.Set(); return "timeout"; }
        probeTick = tick;
        return outcome ?? "unknown";
    }
    // Why the worker stops before its next step: a timeout's cancellation (CodeRabbit on #741: the caller has already
    // returned "timeout", and no later step may run), or real input on the watch. null to go on.
    static string Halt(ManualResetEvent cancel, IntPtr watch, string why) {
        if (cancel.WaitOne(0)) return "cancelled";
        return RealInputSignalled(watch) ? why : null;
    }
    // The session's tick after an input, waited for up to `ms` while it is unchanged or unreadable (-1).
    static long WaitTickMove(long before, int ms) {
        var waited = System.Diagnostics.Stopwatch.StartNew();
        long now = LastInputTick();
        while ((now < 0 || now == before) && waited.ElapsedMilliseconds < ms) { Thread.Sleep(5); now = LastInputTick(); }
        return now;
    }
    // Whether the harness's own input (`what`: "unlock" or "key-probe") was seen (CodeRabbit, Sol and the lead on
    // #741): from valid ticks before and after it that differ (a failed read is -1, never a move), and only when the
    // hook of its kind saw it marked. A hook that never saw it may be gone, and the run is refused. null when it was
    // seen. Public for the contract's table.
    public static string ProbeSeen(string what, long before, long now, bool hookSaw) {
        if (before < 0 || now < 0 || now == before) return what + "-not-observed";
        if (!hookSaw) return what + "-not-seen-by-hook";
        return null;
    }
    static IntPtr DuplicateOwn(IntPtr handle) {
        IntPtr copy;
        return DuplicateHandle(new IntPtr(-1), handle, new IntPtr(-1), out copy, 0, false, 2) ? copy : IntPtr.Zero; // DUPLICATE_SAME_ACCESS
    }
    static void CloseOwn(IntPtr handle) { if (handle != IntPtr.Zero) CloseHandle(handle); }
    public static bool IsForeground(IntPtr hwnd) { return GetForegroundWindow() == hwnd; }
    // Whether any window holds the foreground (Opus on #741: read right before the copy's launch).
    public static bool AnyForeground() { return GetForegroundWindow() != IntPtr.Zero; }
    // The unlock: one absolute mouse move to the cursor's own pixel (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE |
    // MOUSEEVENTF_VIRTUALDESK, at the normalized coordinates nx, ny) with the series' marker in its extra info, aimed
    // at the pixel the cursor is on. A zero-delta relative move registers as session input but never reaches a
    // low-level mouse hook, so the hook could never prove itself alive with it (test-harnesses.md UNLOCK-HOOK-01,
    // measured on the visible desktop). An absolute move replaces motion rather than adding to it: any pointer motion
    // after the worker's last read of the pointer and before its move can be undone, once, including motion Windows
    // holds while a low-level hook runs. The gap is normally microseconds, and longer only if Windows suspends the
    // worker's thread at that moment; the outer half closes the run's job as soon as it observes the hook's latch
    // (the supervision bound: on observation, plus OS scheduling latency). The hook sees that motion as real, so the
    // series is voided. Never a key, which can leave the window in a menu loop (PROBE-ALT-TAP-01), and never a
    // relative motion.
    static Input[] UnlockInput(IntPtr marker, int nx, int ny) {
        var unlock = new Input[] { new Input { type = 0 } };
        unlock[0].mouse.dx = nx; unlock[0].mouse.dy = ny;
        unlock[0].mouse.flags = 0xC001; // MOUSEEVENTF_MOVE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_ABSOLUTE
        unlock[0].mouse.extra = marker;
        return unlock;
    }
    // A pixel's normalized absolute coordinate on the virtual desktop (origin and size from SM_XVIRTUALSCREEN and
    // SM_CXVIRTUALSCREEN, or their Y pair): the smallest value that Windows' floor mapping, pixel = floor(n * size /
    // 65536), sends back to that pixel (the mapping the harness assumes; Wine's `>> 16` is the prior art). Nearest
    // rounding is guaranteed to agree on an axis of up to 32,768 pixels; above that it can fail, though not at every
    // width (half-up rounding first misses at 32,769; on 38,400, offset 3 normalizes to 6, which floor maps to 3 and
    // nearest to 4; Sol and Opus on #746). Public so the contract can table it.
    public static int Normalize(int pixel, int origin, int size) { return (int)Math.Ceiling((pixel - origin) * 65536.0 / size); }
    [StructLayout(LayoutKind.Sequential)] struct CursorPoint { public int x, y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out CursorPoint p);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    // The unlock aimed at the cursor's own pixel (`aim`), read in physical pixels (per-monitor DPI awareness on the
    // calling worker thread, so the cursor and the virtual desktop agree on a scaled display), or null when the switch
    // to that awareness, the cursor or the virtual desktop cannot be read (Opus on #746: an unaware read aims at
    // another row). Measured at one pixel: the cursor ended on it (UNLOCK-HOOK-01). Each run reads it again after the
    // hook's signal (CursorAway), which normally, but not always, follows the move.
    static Input[] UnlockHere(IntPtr marker, out CursorPoint aim) {
        aim = new CursorPoint();
        if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero) return null; // PER_MONITOR_AWARE_V2
        if (!GetCursorPos(out aim)) return null;
        int left = GetSystemMetrics(76), top = GetSystemMetrics(77), width = GetSystemMetrics(78), height = GetSystemMetrics(79);
        if (width <= 0 || height <= 0) return null;
        return UnlockInput(marker, Normalize(aim.x, left, width), Normalize(aim.y, top, height));
    }
    // `why` when the cursor is not on the aimed pixel or cannot be read, else null; on the aiming worker thread, so in
    // the same physical pixels. Nothing about the position leaves it.
    static string CursorAway(CursorPoint aim, string why) {
        CursorPoint now;
        return GetCursorPos(out now) && now.x == aim.x && now.y == aim.y ? null : why;
    }
    // The keyboard probe: VK_NONAME (0xFC) down, then up (flags 2), scan code 0, the series' marker in each.
    static KeyInput[] KeyProbeInput(IntPtr marker) {
        var probe = new KeyInput[] { new KeyInput { type = 1 }, new KeyInput { type = 1 } };
        probe[0].keybd.vk = 0xFC; probe[0].keybd.extra = marker;
        probe[1].keybd.vk = 0xFC; probe[1].keybd.flags = 0x0002; probe[1].keybd.extra = marker;
        return probe;
    }
    // Every field of what the unlock and the probe give SendInput, for the contract (Sol on #741: the payload, not a
    // text pattern).
    public static string UnlockPayload(IntPtr marker, int nx, int ny) {
        var u = UnlockInput(marker, nx, ny);
        return "count=" + u.Length + " type=" + u[0].type + " dx=" + u[0].mouse.dx + " dy=" + u[0].mouse.dy + " data=" + u[0].mouse.data +
            " flags=" + u[0].mouse.flags + " time=" + u[0].mouse.time + " extra=" + u[0].mouse.extra;
    }
    public static string KeyProbePayload(IntPtr marker) {
        var p = KeyProbeInput(marker);
        var parts = new List<string>();
        foreach (var k in p) parts.Add("type=" + k.type + " vk=" + k.keybd.vk + " scan=" + k.keybd.scan + " flags=" + k.keybd.flags + " time=" + k.keybd.time + " extra=" + k.keybd.extra);
        return "count=" + p.Length + " " + string.Join("; ", parts);
    }
    // Whether DWM composes the desktop (1, 0, or -1 when the query failed) and whether it cloaks a window (DWMWA_CLOAKED).
    public static int Composition() { bool on; return DwmIsCompositionEnabled(out on) != 0 ? -1 : (on ? 1 : 0); }
    public static int Cloaked(IntPtr h) { int v; return DwmGetWindowAttribute(h, 14, out v, 4) != 0 ? -1 : v; }
    public static bool RemoteSession() { return GetSystemMetrics(0x1000) != 0; } // SM_REMOTESESSION
    // The session's last input as GetLastInputInfo's tick, and { that tick, the milliseconds since it } from one read
    // (CodeRabbit on #741: two reads can describe two inputs), 32-bit ticks wrapping; -1 when the read failed.
    public static long LastInputTick() { var li = new LastInput { size = (uint)Marshal.SizeOf<LastInput>() }; return GetLastInputInfo(ref li) ? (long)li.time : -1; }
    public static long[] LastInputNow() {
        var li = new LastInput { size = (uint)Marshal.SizeOf<LastInput>() };
        if (!GetLastInputInfo(ref li)) return new long[] { -1, -1 };
        return new long[] { (long)li.time, (long)unchecked(GetTickCount() - li.time) };
    }
    // The system timer's current resolution in 100 ns units (NtQueryTimerResolution), or -1.
    public static long TimerResolution() { uint a, b, c; return NtQueryTimerResolution(out a, out b, out c) != 0 ? -1 : (long)c; }
    // The share of all processors' time not idle over `ms` (GetSystemTimes; kernel time includes idle), percent, or -1.
    // On a machine with more than one processor group GetSystemTimes covers only the calling thread's group
    // (CodeRabbit on #741), so the share is unverifiable there: -1, which a visible run treats as not quiet.
    public static int ProcessorGroups() { return GetActiveProcessorGroupCount(); }
    // GetSystemTimes as { idle, kernel, user }, or null with more than one processor group or a failed read; the share
    // between two readings, or -1. A driver reads the gate between them (the lead and Sol on #741, round 6).
    public static long[] SystemTimes() {
        if (GetActiveProcessorGroupCount() != 1) return null;
        long i, k, u; return GetSystemTimes(out i, out k, out u) ? new long[] { i, k, u } : null;
    }
    public static double BusyShare(long[] before, long[] after) {
        if (before == null || after == null) return -1;
        double total = (double)((after[1] - before[1]) + (after[2] - before[2]));
        return total <= 0 ? -1 : 100.0 * (1.0 - (double)(after[0] - before[0]) / total);
    }
    // The window's monitor's current mode: { width, height, refresh Hz }, or zeros. MONITORINFOEXW is 104 bytes with
    // szDevice at 40; DEVMODEW is 220 bytes with dmSize at 68, dmPelsWidth at 172, dmPelsHeight at 176 and
    // dmDisplayFrequency at 184 (bench-windows.ps1's offsets).
    public static long[] MonitorMode(IntPtr h) {
        IntPtr monitor = MonitorFromWindow(h, 2); // MONITOR_DEFAULTTONEAREST
        if (monitor == IntPtr.Zero) return new long[] { 0, 0, 0 };
        IntPtr info = Marshal.AllocHGlobal(104), mode = Marshal.AllocHGlobal(220);
        try {
            Marshal.Copy(new byte[104], 0, info, 104); Marshal.WriteInt32(info, 0, 104);
            if (!GetMonitorInfoW(monitor, info)) return new long[] { 0, 0, 0 };
            string device = Marshal.PtrToStringUni(IntPtr.Add(info, 40));
            Marshal.Copy(new byte[220], 0, mode, 220); Marshal.WriteInt16(mode, 68, 220);
            if (!EnumDisplaySettingsRaw(device, -1, mode)) return new long[] { 0, 0, 0 }; // ENUM_CURRENT_SETTINGS
            return new long[] { Marshal.ReadInt32(mode, 172), Marshal.ReadInt32(mode, 176), Marshal.ReadInt32(mode, 184) };
        } finally { Marshal.FreeHGlobal(info); Marshal.FreeHGlobal(mode); }
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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ReadConsoleOutputCharacterW(IntPtr output, StringBuilder text, uint length, Coord start, out uint read);
    // The text of `pid`'s console (a pane's shell, whose console is the pane's pseudoconsole) from its top-left cell
    // through the cursor, row after row, so a prompt or command that wraps is read whole (Greptile on #741), after the
    // count of those cells: "cells<TAB>text", or an error word. For the dry run's keyboard-probe check (the lead on
    // #741: cmd must show no stray character). Detaches this process from its own console first.
    public static string ConsoleTextToCursor(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) return "attach-failed-" + Marshal.GetLastWin32Error();
        IntPtr output = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (output == new IntPtr(-1)) return "conout-failed-" + Marshal.GetLastWin32Error();
        try {
            ScreenBufferInfo info;
            if (!GetConsoleScreenBufferInfo(output, out info)) return "info-failed-" + Marshal.GetLastWin32Error();
            int cells = info.cursor.y * info.size.x + info.cursor.x;
            var text = new StringBuilder(cells + 1);
            uint read = 0;
            if (cells > 0 && !ReadConsoleOutputCharacterW(output, text, (uint)cells, new Coord { x = 0, y = 0 }, out read)) return "read-failed-" + Marshal.GetLastWin32Error();
            return cells + "\t" + text.ToString(0, (int)read);
        } finally { CloseHandle(output); FreeConsole(); }
    }
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

# bench-windows.ps1's payload generator (NocttyBenchNative.Next and WritePayload), byte for byte: the contract holds the
# two copies identical, so this workload's bytes are the bench's.
if (-not ('FramePacingPayload' -as [type])) {
Add-Type @'
using System;
using System.IO;
using System.Text;
public static class FramePacingPayload {
    private static uint Next(ref uint state) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    }

    public static void WritePayload(string path, long length, uint seed, string workload, int rows, int cols) {
        uint state = seed == 0 ? 1u : seed;
        byte[] buffer = new byte[65536];
        long written = 0;
        int column = 0;
        byte[] pendingAltScreenSequence = null;
        int pendingAltScreenOffset = 0;
        bool pendingScrollLineFeed = false;
        using (FileStream stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read, buffer.Length, FileOptions.SequentialScan)) {
            while (written < length) {
                int count = (int)Math.Min(buffer.Length, length - written);
                int offset = 0;
                while (offset < count) {
                    uint random = Next(ref state);
                    if (workload == "alt-screen") {
                        if (pendingAltScreenSequence == null) {
                            string sequence = String.Format("\x1b[{0};{1}H{2}", 1 + random % (uint)rows, 1 + (random >> 8) % (uint)cols, (char)(33 + (random >> 16) % 94));
                            byte[] bytes = Encoding.ASCII.GetBytes(sequence);
                            long remainingPayload = length - (written + offset);
                            if (bytes.LongLength > remainingPayload) {
                                while (offset < count) buffer[offset++] = (byte)' ';
                                continue;
                            }
                            pendingAltScreenSequence = bytes;
                            pendingAltScreenOffset = 0;
                        }
                        int available = Math.Min(pendingAltScreenSequence.Length - pendingAltScreenOffset, count - offset);
                        Array.Copy(pendingAltScreenSequence, pendingAltScreenOffset, buffer, offset, available);
                        offset += available;
                        pendingAltScreenOffset += available;
                        if (pendingAltScreenOffset == pendingAltScreenSequence.Length) {
                            pendingAltScreenSequence = null;
                            pendingAltScreenOffset = 0;
                        }
                    }
                    else if (workload == "scroll" && pendingScrollLineFeed) {
                        buffer[offset++] = (byte)'\n';
                        pendingScrollLineFeed = false;
                        column = 0;
                    }
                    else if (workload == "scroll" && column >= cols - 2 && length - (written + offset) >= 2) {
                        buffer[offset++] = (byte)'\r';
                        pendingScrollLineFeed = true;
                    }
                    else {
                        buffer[offset++] = (byte)(33 + random % 94);
                        column++;
                    }
                }
                stream.Write(buffer, 0, count);
                written += count;
            }
        }
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

# The default config files portable mode would also read under a copy (src/config/file_load.zig: the legacy
# ghostty/config and the pre-rename winghostty/config.ghostty, rooted at the portable root by src/os/xdg.zig
# portablePath). The copy reads the default files and then discards their settings (--config-default-files=false),
# so only the generated file's settings take effect; a staged copy holding either is refused as well (Sol, round 3).
function Get-WorkingSetStrayConfigs([string] $Copy) {
    return @(@('ghostty\config', 'winghostty\config.ghostty') | Where-Object { Test-Path -LiteralPath (Join-Path $Copy $_) })
}

# Whether an argv is exactly the expected one: the same arguments, in the same order, compared ordinally.
function Test-WorkingSetArgv([string[]] $Actual, [string[]] $Expected) {
    if ($null -eq $Actual -or $Actual.Count -ne $Expected.Count) { return $false }
    for ($i = 0; $i -lt $Expected.Count; $i++) { if (-not [string]::Equals($Actual[$i], $Expected[$i], [StringComparison]::Ordinal)) { return $false } }
    return $true
}

# A file another process may still hold open for writing (the copy's log), read whole; empty when absent.
function Read-SharedText([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { return [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
}

function Get-BenchMedian {
    param([Parameter(Mandatory)] [double[]] $Samples)
    if ($Samples.Count -eq 0) { return $null }
    $sorted = @($Samples | Sort-Object)
    $middle = [int] [Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double] $sorted[$middle] }
    return ([double] $sorted[$middle - 1] + [double] $sorted[$middle]) / 2.0
}

function Get-BenchPercentile {
    param(
        [Parameter(Mandatory)] [double[]] $Samples,
        [ValidateRange(0, 100)] [double] $Percentile
    )
    if ($Samples.Count -eq 0) { return $null }
    $sorted = @($Samples | Sort-Object)
    if ($Percentile -eq 0) { return [double] $sorted[0] }
    $rank = [int] [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count)
    return [double] $sorted[[Math]::Max(0, $rank - 1)]
}

# The copy's config for a run, exactly: what the outer half writes and what the driver requires byte for byte before
# its first launch. The shell is System32's cmd.exe run directly with /D (no AutoRun), the only command. F5 types
# `type stream.bin & echo.>done.flag` and F6 a carriage return, relative to the pane's working directory, so the run's
# path never reaches cmd's parser (#739's rule); cmd writes done.flag once `type` has written the whole payload, which
# the driver waits for by polling the file, never the pane (Opus on #741). Every binding is bound under each modifier chord, so a modifier the window's
# thread still holds cannot turn a posted key into another action; nothing else is bound.
function New-FramePacingConfigText([string] $Run) {
    $work = Join-Path $Run 'work'
    $bindings = [ordered]@{ f5 = 'text:type stream.bin & echo.>done.flag'; f6 = 'text:\r' }
    $chords = @('', 'shift+', 'ctrl+', 'alt+', 'ctrl+shift+', 'alt+shift+', 'ctrl+alt+', 'ctrl+alt+shift+')
    $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    $lines = @(
        "command = direct:$cmdPath /D"
        'auto-update = off'
        'confirm-close-surface = false'
        'desktop-notifications = false'
        'clipboard-read = deny'
        'clipboard-write = deny'
        'copy-on-select = false'
        'renderer = opengl'
        "window-width = $($script:Cols)"
        "window-height = $($script:Rows)"
        "font-family = $($script:FontFamily)"
        "font-size = $($script:FontSize)"
        'cursor-style-blink = false'
        "working-directory = $work"
        'keybind = clear'
        foreach ($key in $bindings.Keys) { foreach ($chord in $chords) { "keybind = $chord$key=$($bindings[$key])" } }
    )
    return ($lines -join "`n") + "`n"
}

# Whether a staged config is byte for byte New-FramePacingConfigText's for this run.
function Test-FramePacingConfigBytes([string] $Path, [string] $Run) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $staged = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
    $expected = [Convert]::ToBase64String($script:Utf8.GetBytes((New-FramePacingConfigText $Run)))
    return [string]::Equals($staged, $expected, [StringComparison]::Ordinal)
}

# The copy's exact argv: the launch helper's containment and isolation arguments (scripts/interactive-win11-lib.ps1),
# then the harness's own, in this order and nothing else; the final command line and the copy's real one by PID must
# each split into exactly this list (#739's rule), so nothing can set the shell on the command line.
function Get-FramePacingExpectedArgv([string] $Exe, [string] $Class, [string] $ConfigPath) {
    return [string[]]@($Exe, '--linux-cgroup=always', '--linux-cgroup-hard-fail=true', '--windows-job-object-kill-on-close=true',
        '--single-instance=false', "--class=$Class", '--window-save-state=never', '--clipboard-read=deny', '--clipboard-write=deny',
        '--config-default-files=false', "--config-file=$ConfigPath")
}

# The end marker's frame, as bench-windows.ps1's stream producer writes it after the payload: SGR reset, CUP 1;1, EL 2,
# then the token, so the token is committed at the start of the visible top row (src/termio/bench_marker.zig).
function Get-FramePacingMarkerTail([string] $Marker) {
    $esc = [char]27
    return [Text.Encoding]::ASCII.GetBytes("$esc[0m$esc[1;1H$esc[2K$Marker")
}

# work\stream.bin: the generator's payload, then the marker's frame and token.
function Write-FramePacingPayload([string] $Path, [string] $Marker) {
    [FramePacingPayload]::WritePayload($Path, $script:PayloadBytes, $script:PayloadSeed, $script:PayloadWorkload, $script:Rows, $script:Cols)
    $tail = Get-FramePacingMarkerTail $Marker
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($tail, 0, $tail.Length) } finally { $stream.Dispose() }
}

# The payload's SHA-256 without its marker (the marker is new each run): the first PayloadBytes bytes of stream.bin.
function Get-FramePacingPayloadSha256([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $body = [byte[]]::new($script:PayloadBytes)
        $read = 0
        while ($read -lt $body.Length) { $n = $stream.Read($body, $read, $body.Length - $read); if ($n -le 0) { break }; $read += $n }
        if ($read -ne $body.Length) { return $null }
        return Get-BytesSha256 $body
    } finally { $stream.Dispose() }
}

# The workload's identity: SHA-256 over its constants, the payload's SHA-256 and the config with the run's own
# directory written as <run>. Runs compare only when it matches.
function Get-FramePacingWorkloadSha256([string] $PayloadSha256, [string] $ConfigPath, [string] $RunRoot) {
    $root = $RunRoot.TrimEnd('\')
    $config = ([IO.File]::ReadAllLines($ConfigPath) -join "`n").Replace($root, '<run>')
    $constants = 'workload={0} bytes={1} seed={2} cols={3} rows={4} grid={3}x{5} font={6}@{7} capacity={8} quiet={9}ms echo={10}ms producer=cmd-type arm=WM_APP+9:0 end=first-marker-swap stat=nearest-rank-p95' -f `
        $script:PayloadWorkload, $script:PayloadBytes, $script:PayloadSeed, $script:Cols, $script:Rows, $script:GridRows,
        $script:FontFamily, $script:FontSize, $script:IntervalCapacity, $script:QuietMs, $script:EchoQuietMs
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($script:Utf8.GetBytes("$constants`n$PayloadSha256`n$config"))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# Why the visible part may not run with these facts about this process's session, or $null when it may: the caller on
# Default, Default the input desktop (unlocked, nothing else in front), DWM composing it, a local session, the shell
# accepting notifications (no full-screen app or presentation mode), the display on, and no keyboard or mouse input for
# the minimum idle time, or, once the series has a tick (QuietSinceTick), none since that tick: the harness's own
# unlock moves the session's last input, so a later run cannot wait out the idle time again. "Away" is only that: a
# gamepad or a video watched without input is not seen. Pure, so the contract can run it; the dry run's driver records
# its answer on its desktop.
function Get-FramePacingVisibleRefusal($Facts) {
    if (-not [string]::Equals([string]$Facts.OwnDesktop, 'Default', [StringComparison]::OrdinalIgnoreCase)) { return 'this process is not on Default' }
    if ($null -eq $Facts.InputDesktop -or -not [string]::Equals([string]$Facts.InputDesktop, 'Default', [StringComparison]::OrdinalIgnoreCase)) { return 'Default is not the input desktop (the session is locked or another desktop is in front)' }
    if ($Facts.Composition -ne 1) { return 'DWM does not compose the desktop' }
    if ($Facts.RemoteSession) { return 'the session is remote' }
    if ($Facts.NotificationState -ne $script:NotificationsAccepted) { return "the shell does not accept notifications (state $($Facts.NotificationState): a full-screen app, presentation mode, quiet time or a locked session)" }
    if ($Facts.DisplayPower -ne $script:DisplayOn) { return "the display is not on (state $($Facts.DisplayPower))" }
    if ($Facts.ScreenSaverRunning -ne 0) { return "a screen saver is running, or its state is unreadable ($($Facts.ScreenSaverRunning))" }
    $lockShortfall = Get-FramePacingLockShortfall $Facts.ForegroundLockTimeoutMs $Facts.ForegroundLockNeededMs
    if ($lockShortfall) { return "$lockShortfall, and noctty's own startup activation could take the foreground from a returning user" }
    if ($Facts.QuietSinceTick -ge 0) {
        if ($Facts.LastInputTick -ne $Facts.QuietSinceTick) { return 'the session had input since the series last saw it idle' }
    } elseif ($Facts.IdleMs -lt 0 -or $Facts.IdleMs -lt $Facts.MinIdleMs) { return "the session had input $([Math]::Floor([Math]::Max(0, $Facts.IdleMs) / 1000)) s ago, under the $([Math]::Floor($Facts.MinIdleMs / 1000)) s minimum" }
    return $null
}

# Whether cmd's console after a step is the console before it plus exactly `$Typed` (nothing, for the keyboard probe):
# both read from the top-left cell through the cursor, so a prompt or a command that wraps across rows compares whole
# (Greptile on #741). Pure, so the contract tables it.
function Test-FramePacingConsoleTyped($Before, $After, [string] $Typed) {
    return $After.Cells -eq $Before.Cells + $Typed.Length -and [string]::Equals($After.Text, $Before.Text + $Typed, [StringComparison]::Ordinal)
}

# How long the foreground lock must last for a visible series (Greptile on #741). The lock counts from the user's last
# input, and the series begins after at least MinIdleSeconds of none, so it must outlast the idle time seen at
# admission (at least the minimum) plus every run's longest duration, RunBoundMs each; then it is still in force when
# the last run's copy starts, and the copy's own foreground before the unlock tests it. Pure, so the contract tables it.
function Get-FramePacingLockNeedMs([long] $IdleMs, [long] $MinIdleMs, [int] $Runs) {
    return [long][Math]::Max($IdleMs, $MinIdleMs) + [long]$Runs * [long]$script:RunBoundMs
}

# Whether the foreground lock falls short of what the series still needs (Greptile and Sol on #741): the lock must
# exceed the need, the idle time since the user's last input plus each remaining run's longest. Returns the reason,
# or null. Pure, so the contract tables it; the admission and each launch use it.
function Get-FramePacingLockShortfall([long] $LockMs, [long] $NeedMs) {
    if ($NeedMs -lt 0 -or $LockMs -le $NeedMs) { return "Windows' foreground lock timeout is $LockMs ms, not over the $NeedMs ms the series still needs (the user's idle time plus each remaining run's longest), so it could expire during the series" }
    return $null
}

# The series' random marker for its own injected input (Opus on #741): nonzero, so a zero extra info never matches,
# and within 31 bits (test-harnesses.md UNLOCK-HOOK-01): an injected mouse event's extra info reaches a low-level hook
# with only its low 32 bits, so a wider marker never matches the harness's own unlock.
function New-FramePacingInputMarker {
    $bytes = [byte[]]::new(4)
    do { [Security.Cryptography.RandomNumberGenerator]::Fill($bytes); $marker = [long]([BitConverter]::ToUInt32($bytes, 0) -band 0x7FFFFFFF) } while ($marker -eq 0)
    return $marker
}

# The one PowerShell read of the session's last input (the lead and Sol on #741, round 9): GetLastInputInfo's tick and
# the milliseconds since it, from one native read. Given $Ticks (a run's, the outer half's or the series end's), a tick
# other than the one they expect, or a failed read, latches $Ticks.Broken before this returns; without them (the
# admission's first read, which sets the series' baseline) it only reads. No other PowerShell code reads the tick:
# the contract scans for any other call to the native reads.
function Read-FramePacingInputTick($Ticks) {
    $last = [FramePacingNative]::LastInputNow()
    if ($null -ne $Ticks) {
        $expected = if ($null -ne $Ticks.Unlock) { $Ticks.Unlock } else { $Ticks.Series }
        if ([long]$last[0] -lt 0 -or $null -eq $expected -or [long]$expected -lt 0 -or [long]$last[0] -ne [long]$expected) { $Ticks.Broken = $true }
    }
    return [pscustomobject]@{ Tick = [long]$last[0]; IdleMs = [long]$last[1] }
}

# This process's facts for Get-FramePacingVisibleRefusal; $LockNeededMs is the series' lock bound (-1 when unknown).
# A driver passes its run's ticks, so a session tick that moved since the series' baseline latches the run here too
# (the lead and Sol on #741, round 9); the admission passes none.
function Get-FramePacingSessionFacts([long] $QuietSinceTick, [long] $LockNeededMs, $Ticks) {
    $read = Read-FramePacingInputTick $Ticks
    $last = @($read.Tick, $read.IdleMs)
    return [pscustomobject]@{
        OwnDesktop = [FramePacingNative]::CurrentDesktopName(); InputDesktop = [FramePacingNative]::InputDesktopName()
        Composition = [FramePacingNative]::Composition(); RemoteSession = [FramePacingNative]::RemoteSession()
        NotificationState = [FramePacingNative]::NotificationState(); DisplayPower = [FramePacingNative]::DisplayPower(2000)
        ScreenSaverRunning = [FramePacingNative]::ScreenSaverRunning(); ForegroundLockTimeoutMs = [FramePacingNative]::ForegroundLockTimeout(); ForegroundLockNeededMs = $LockNeededMs
        LastInputTick = $last[0]; IdleMs = $last[1]; MinIdleMs = [long]$script:MinIdleSeconds * 1000; QuietSinceTick = $QuietSinceTick
    }
}

# The visible run's input gate (Sol, Opus, Greptile, CodeRabbit and the lead on #741). First the series' input
# watch: any real (non-injected) keyboard or mouse input its low-level hooks saw since admission breaks the run;
# GetLastInputInfo cannot tell the harness's injected unlock from the user's input, the hooks' injected flag can.
# Then, as a second line, the session's last input must be the tick the run expects: the series' own (the tick the
# outer half saw idle, or the last run's own unlock) until this run's unlock, and the unlock's own after it. The driver
# checks it right before each launch on Default, the unlock, each workload key, the arm and after the window, and the
# outer half before each driver; each check is recorded, and before the window a break throws INCONCLUSIVE, so
# nothing further starts, takes the foreground or sends input. $Port gives RealInputSeen(), LastInputTick() (and
# Foreground()), so the contract can drive the gate with a stand-in. Returns $null or why the run breaks.
function Test-FramePacingInputGate($Port, $Ticks, [string] $Before) {
    $real = [bool]$Port.RealInputSeen()
    $now = [long]$Port.LastInputTick($Ticks)
    $expected = if ($null -ne $Ticks.Unlock) { $Ticks.Unlock } else { $Ticks.Series }
    $Ticks.Checks.Add([ordered]@{ before = $Before; real = $real; tick = $now })
    # Any break latches (the lead and Sol on #741, round 8): Broken is set and nothing clears it, so the run and the
    # series stay voided even if a later read returns the expected tick (GetLastInputInfo is not incremental).
    if ($real) { $Ticks.Broken = $true; return "real (non-injected) keyboard or mouse input came before $Before" }
    if ($null -eq $expected -or [long]$expected -lt 0) { $Ticks.Broken = $true; return "the run has no expected input tick before $Before" }
    if ($now -ne [long]$expected) { $Ticks.Broken = $true; return "the session had input before $Before" }
    return $null
}
# A poll's read of the gate (the lead and Sol on #741, round 8): one read of the watch and the tick; a mismatch is
# recorded, latched and stops the step at once, never read again and accepted. Only a break is recorded, so the
# 100 ms polls add no entry to the record while the session stays quiet.
function Assert-FramePacingPollGate($Port, $Ticks, [string] $During) {
    $real = [bool]$Port.RealInputSeen()
    $now = [long]$Port.LastInputTick($Ticks)
    $expected = if ($null -ne $Ticks.Unlock) { $Ticks.Unlock } else { $Ticks.Series }
    if (-not $real -and $null -ne $expected -and [long]$expected -ge 0 -and $now -eq [long]$expected) { return }
    $Ticks.Checks.Add([ordered]@{ before = $During; real = $real; tick = $now })
    $Ticks.Broken = $true
    throw "INCONCLUSIVE: $(if ($real) { 'real (non-injected) keyboard or mouse input came' } else { "the session's input tick moved ($expected to $now)" }) during $During."
}
function Assert-FramePacingInputGate($Port, $Ticks, [string] $Before) {
    $break = Test-FramePacingInputGate $Port $Ticks $Before
    if ($break) { throw "INCONCLUSIVE: $break." }
}
# The visible run's foreground: the input gate first, then the bounded call with the series' tick, whose worker reads
# the input watch again right before its one unlock input and each foreground call. The unlock's own tick becomes the
# tick the run expects.
function Invoke-FramePacingForeground($Port, $Ticks, [IntPtr] $HostWindow, [int] $NocttyPid) {
    Assert-FramePacingInputGate $Port $Ticks 'the harness''s unlock'
    $result = $Port.Foreground($HostWindow, $NocttyPid, $script:ForegroundBoundMs, [long]$Ticks.Series)
    if ([long]$result.UnlockTick -ge 0) { $Ticks.Unlock = [long]$result.UnlockTick }
    if ([string]$result.Outcome -match '^(real-)?input-') { $Ticks.Broken = $true }
    # A mouse hook that never saw the harness's own marked unlock may have been removed (Windows drops a low-level
    # hook that times out, silently), and then nothing sees a returning user's mouse: the run is refused outright,
    # never measured and never merely inconclusive (CodeRabbit and the lead on #741).
    if ([string]::Equals([string]$result.Outcome, 'unlock-not-seen-by-hook', [StringComparison]::Ordinal)) { throw $script:MouseHookMissed }
    return [string]$result.Outcome
}
# The keyboard hook's proof of life, once the copy is in front (the lead on #741): the gate first, then the bounded
# native probe with the tick the run expects; its own tick becomes the one the run expects from then on. A keyboard
# hook that never saw the marked key refuses the run outright.
function Invoke-FramePacingKeyProbe($Port, $Ticks, [IntPtr] $HostWindow, [int] $NocttyPid) {
    Assert-FramePacingInputGate $Port $Ticks 'the keyboard probe'
    $result = $Port.KeyProbe($HostWindow, $NocttyPid, $script:ForegroundBoundMs, [long]$Ticks.Unlock)
    if ([long]$result.ProbeTick -ge 0) { $Ticks.Unlock = [long]$result.ProbeTick }
    if ([string]$result.Outcome -match '^(real-)?input-') { $Ticks.Broken = $true }
    if ([string]::Equals([string]$result.Outcome, 'key-probe-not-seen-by-hook', [StringComparison]::Ordinal)) { throw $script:KeyHookMissed }
    return [string]$result.Outcome
}
# The production ports: a driver's reads the series' watch through its event handles ($Watch, $MouseWatch and
# $KeyWatch, zero in a dry run) and drives the native bounded foreground and key probe with them and the series'
# marker; the outer half's reads the hooks' own count.
function New-FramePacingPort([IntPtr] $Watch, [IntPtr] $MouseWatch, [IntPtr] $KeyWatch, [long] $Marker) {
    $port = [pscustomobject]@{ Kind = 'native'; Watch = $Watch; MouseWatch = $MouseWatch; KeyWatch = $KeyWatch; Marker = $Marker }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputSeen -Value { [FramePacingNative]::RealInputSignalled($this.Watch) }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { param($Ticks) (Read-FramePacingInputTick $Ticks).Tick }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name Foreground -Value {
        param([IntPtr] $HostWindow, [int] $OwnerPid, [int] $BoundMs, [long] $ExpectedTick)
        $unlock = [long]-1
        $outcome = [FramePacingNative]::Foreground($HostWindow, $OwnerPid, $BoundMs, $ExpectedTick, $this.Watch, $this.MouseWatch, [IntPtr]$this.Marker, [ref]$unlock)
        return [pscustomobject]@{ Outcome = $outcome; UnlockTick = $unlock }
    }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name KeyProbe -Value {
        param([IntPtr] $HostWindow, [int] $OwnerPid, [int] $BoundMs, [long] $ExpectedTick)
        $tick = [long]-1
        $outcome = [FramePacingNative]::KeyProbe($HostWindow, $OwnerPid, $BoundMs, $ExpectedTick, $this.Watch, $this.KeyWatch, [IntPtr]$this.Marker, [ref]$tick)
        return [pscustomobject]@{ Outcome = $outcome; ProbeTick = $tick }
    }
    return $port
}
function New-FramePacingOuterPort {
    $port = [pscustomobject]@{ Kind = 'outer' }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputSeen -Value { [FramePacingNative]::RealInputs() -gt 0 }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { param($Ticks) (Read-FramePacingInputTick $Ticks).Tick }
    return $port
}
# The visible series' input watch: both low-level hooks installed, or -Visible is refused, never a fallback to the
# input tick alone (the lead on #741). $Start installs them for the named event and says whether both are in place;
# the contract passes a stand-in that fails.
function Start-FramePacingInputWatch([scriptblock] $Start, [string] $EventName) {
    if (-not (& $Start $EventName)) { throw '-Visible is refused: the low-level input hooks could not be installed, and a visible run never falls back to the input tick alone.' }
}

# The trace's intervals in milliseconds (QPC ticks over the trace's own frequency) and their statistics.
function Get-FramePacingIntervalStats([object[]] $Ticks, [double] $Frequency) {
    $ms = [double[]]@($Ticks | ForEach-Object { [double]$_ * 1000.0 / $Frequency })
    if ($ms.Count -eq 0) { return [pscustomobject]@{ Ms = [double[]]@(); Count = 0; P95 = $null; Median = $null; Max = $null; Sum = 0.0 } }
    return [pscustomobject]@{
        Ms = $ms; Count = $ms.Count; P95 = (Get-BenchPercentile -Samples $ms -Percentile 95); Median = (Get-BenchMedian -Samples $ms)
        Max = ($ms | Measure-Object -Maximum).Maximum; Sum = ($ms | Measure-Object -Sum).Sum
    }
}

# What keeps a run's record from counting, as a list (empty: the run counts). Problems of the visible run's
# environment (the foreground, focus or the session's input changed during the workload, a busy machine) start with
# "inconclusive:"; the run is then neither a sample nor a product failure. Pure, so the contract can run it.
function Get-FramePacingRecordProblems($Record) {
    $problems = [Collections.Generic.List[string]]::new()
    if ($null -eq $Record) { return @('no record') }
    if ($Record.Schema -ne 1) { $problems.Add("schema $($Record.Schema)") }
    if ($Record.Error) { $problems.Add("error: $($Record.Error)") }
    if ($Record.Exit -ne 0) { $problems.Add("exit $($Record.Exit)") }
    if ($Record.QuitPosts -lt 1) { $problems.Add('no close post took') }
    if ($Record.GridCols -ne $script:Cols -or $Record.GridRows -ne $script:GridRows) { $problems.Add("grid $($Record.GridCols)x$($Record.GridRows)") }
    if (-not [string]::Equals([string]$Record.Transport, 'bundled', [StringComparison]::Ordinal)) { $problems.Add("transport $($Record.Transport)") }
    if (-not [string]::Equals([string]$Record.Renderer, 'opengl', [StringComparison]::Ordinal)) { $problems.Add("renderer $($Record.Renderer)") }
    if ($Record.LaunchConfigDefaultFiles -ne $false -or -not $Record.LaunchConfigFile) { $problems.Add('the copy was not launched with only the generated config') }
    if (-not $Record.ConptyDllSHA256 -or -not [string]::Equals([string]$Record.ConptyDllSHA256, [string]$Record.PrefixConptyDllSHA256, [StringComparison]::Ordinal) -or -not $Record.OpenConsoleSHA256 -or -not [string]::Equals([string]$Record.OpenConsoleSHA256, [string]$Record.PrefixOpenConsoleSHA256, [StringComparison]::Ordinal)) {
        $problems.Add('the ConPTY pair is not the build''s')
    }
    if ($Record.PowerShellUnderCopy -ne 0) { $problems.Add("$($Record.PowerShellUnderCopy) PowerShell processes under the copy") }
    if (-not $Record.EndMarkerPresented) { $problems.Add('no swap presented the end marker') }
    if ($null -eq $Record.SnapshotsInWindow -or $Record.SnapshotsInWindow -ne 0) { $problems.Add("inconclusive: $($Record.SnapshotsInWindow) render-trace snapshot requests landed inside the measured window") }
    $intervals = @($Record.IntervalsMs)
    if ($Record.IntervalOverflow -ne 0) { $problems.Add("$($Record.IntervalOverflow) intervals past the trace's capacity") }
    if ($Record.IntervalCount -lt 2 -or $intervals.Count -ne $Record.IntervalCount) { $problems.Add("$($intervals.Count) intervals for a count of $($Record.IntervalCount) (at least 2 needed)") }
    if (@($intervals | Where-Object { [double]$_ -le 0 }).Count -gt 0) { $problems.Add('a nonpositive interval') }
    if (-not $Record.DisplayMode -or $Record.DisplayMode -notmatch '\A[1-9]\d*x[1-9]\d*@[1-9]\d*\z') { $problems.Add("no display mode for the window's monitor ($($Record.DisplayMode))") }
    elseif (-not [string]::Equals([string]$Record.DisplayMode, [string]$Record.DisplayModeAfter, [StringComparison]::Ordinal)) { $problems.Add("inconclusive: the window's display mode changed during the run ($($Record.DisplayMode) to $($Record.DisplayModeAfter))") }
    if ([string]::Equals([string]$Record.Mode, 'dry-run', [StringComparison]::Ordinal)) {
        if (-not $Record.VisibleRefusal) { $problems.Add('the dry run''s desktop passed the visible checks') }
        if (-not [string]::Equals([string]$Record.Foreground, 'skipped', [StringComparison]::Ordinal)) { $problems.Add("the dry run's foreground was $($Record.Foreground), not skipped") }
    } elseif ([string]::Equals([string]$Record.Mode, 'visible', [StringComparison]::Ordinal)) {
        if ($Record.VisibleRefusal) { $problems.Add("inconclusive: the visible run was refused: $($Record.VisibleRefusal)") }
        if (-not [string]::Equals([string]$Record.Foreground, 'ok', [StringComparison]::Ordinal)) { $problems.Add("inconclusive: the foreground was $($Record.Foreground)") }
        # The keyboard hook's proof of life (Opus on #741, round 5): a visible run is never complete without it.
        # A driver that refused the run because the keyboard hook missed its probe has failed it with that reason (Opus
        # and Sol on #741, rounds 8 and 9): the probe was sent, so no line calls it "not sent" or the run inconclusive.
        # After a mouse-hook miss the probe really was not sent, and the line stays (Opus on #741, round 10).
        if (-not [string]::Equals([string]$Record.KeyProbe, 'ok', [StringComparison]::Ordinal) -and -not [string]::Equals([string]$Record.Error, $script:KeyHookMissed, [StringComparison]::Ordinal)) { $problems.Add("inconclusive: the keyboard probe was $(if ($null -eq $Record.KeyProbe) { 'not sent' } else { $Record.KeyProbe })") }
        if ($Record.Cloaked -ne 0) { $problems.Add("inconclusive: DWM cloaked the window ($($Record.Cloaked))") }
        if (-not $Record.ForegroundHeld) { $problems.Add('inconclusive: the window lost the foreground during the workload') }
        if (-not $Record.FocusHeld) { $problems.Add('inconclusive: the pane''s focus changed during the workload') }
        if ($Record.InputDuringRun) { $problems.Add('inconclusive: the session had input during the workload') }
        if ($null -eq $Record.BusyPercentBefore -or $Record.BusyPercentBefore -lt 0 -or $Record.BusyPercentBefore -ge $script:QuietBusyPercent) { $problems.Add("inconclusive: the machine was $($Record.BusyPercentBefore)% busy before the workload") }
        if ($null -eq $Record.BusyPercentAtArm -or $Record.BusyPercentAtArm -lt 0 -or $Record.BusyPercentAtArm -ge $script:QuietBusyPercent) { $problems.Add("inconclusive: the machine was $($Record.BusyPercentAtArm)% busy right before the measured window") }
        if ($Record.DisplayPowerBefore -ne $script:DisplayOn -or $Record.DisplayPowerAfter -ne $script:DisplayOn) { $problems.Add("inconclusive: the display was not on through the window ($($Record.DisplayPowerBefore) to $($Record.DisplayPowerAfter))") }
        if (-not $Record.RefreshHz -or $Record.RefreshHz -le 1) { $problems.Add("no refresh rate for the window's monitor ($($Record.RefreshHz))") }
    } else { $problems.Add("mode $($Record.Mode)") }
    return $problems.ToArray()
}

# The grid probe: a child of the driver, on its desktop, that attaches to a pane's shell's console (the pane's
# pseudoconsole) and writes "columns,rows" to -Run's grid.txt.
# The dry run's console probe: a child of the driver, on its desktop, that attaches to the pane's shell's console and
# writes its text from the top-left through the cursor to -Run's cursor-<tag>.txt, which the driver reads and deletes.
if ($CursorProbePid -gt 0) {
    [IO.File]::WriteAllText((Join-Path $Run "cursor-$CursorProbeName.txt"), [FramePacingNative]::ConsoleTextToCursor([uint32]$CursorProbePid))
    exit 0
}

if ($GridProbePid -gt 0) {
    [IO.File]::WriteAllText((Join-Path $Run 'grid.txt'), [FramePacingNative]::ConsoleGrid([uint32]$GridProbePid))
    exit 0
}

# ---------------------------------------------------------------------------------------------------------
# The driver: on its desktop (private in a dry run, Default in a visible one), inside the job, the environment
# redirected.
# ---------------------------------------------------------------------------------------------------------
function Invoke-FramePacingDriver {
    $driverLog = Join-Path $Run 'driver.log'
    function Log([string] $Message) { Add-Line $driverLog ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) }
    $mode = if ($Visible) { 'visible' } else { 'dry-run' }
    $record = [ordered]@{
        Schema = 1; Mode = $mode; HarnessSha256 = (Get-FramePacingLoadedHarnessSha256); ExpectedBuildMode = $ExpectedBuildMode; BuildMode = $null; MeasureHead = $null
        Cols = $script:Cols; Rows = $script:Rows; GridCols = $null; GridRows = $null; FontFamily = $script:FontFamily; FontSize = $script:FontSize
        Class = $null; ExeSHA256 = $null; CliSHA256 = $null; ReceiptSHA256 = $null; ConfigSHA256 = $null; DriverPriority = $null; NocttyPriority = $null
        PayloadBytes = $script:PayloadBytes; PayloadSeed = $script:PayloadSeed; PayloadSha256 = $null; MarkerLength = $null; WorkloadSha256 = $null
        ClientWidth = $null; ClientHeight = $null; Dpi = $null; MonitorWidth = $null; MonitorHeight = $null; RefreshHz = $null; DisplayMode = $null; DisplayModeAfter = $null
        LaunchConfigDefaultFiles = $null; LaunchConfigFile = $null; Transport = $null; Renderer = $null
        ConptyDllSHA256 = $null; PrefixConptyDllSHA256 = $null; OpenConsoleSHA256 = $null; PrefixOpenConsoleSHA256 = $null; EffectiveDirs = $null
        VisibleRefusal = $null; Composition = $null; NotificationState = $null; Cloaked = $null; Foreground = $null; ForegroundHeld = $null; FocusHeld = $null
        InputDuringRun = $null; InputBreak = $null; InputTicks = [ordered]@{ Series = $QuietSinceTick; Unlock = $null; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
        BusyPercentBefore = $null; BusyPercentAtArm = $null; BusyPercentAfter = $null; QuietWaitMs = 0; ProcessorGroups = $null; TimerResolutionBefore100ns = $null; TimerResolutionAfter100ns = $null
        DisplayPowerBefore = $null; DisplayPowerAfter = $null; SnapshotsInWindow = $null; PresentAfterDoneMs = $null
        ScreenSaverBeforeUnlock = $null; ScreenSaverAtArm = $null; ForegroundLockTimeoutMs = $null; ForegroundLockTimeoutAtLaunchMs = $null; ForegroundLockNeededMs = $ForegroundLockNeededMs; ForegroundBeforeLaunch = $null; ForegroundBeforeUnlock = $null; ForegroundTakenFromNone = $false
        KeyProbe = $null; DryProbePromptUnchanged = $null; DryProbeCommandIntact = $null
        QpcFrequency = $null; EndMarkerPresented = $false; IntervalCount = 0; IntervalOverflow = $null; IntervalsMs = [double[]]@()
        P95Ms = $null; MedianMs = $null; MaxMs = $null; WindowMs = $null; SwapsBefore = $null; SwapsAfter = $null
        ShellsUnderCopy = $null; PowerShellUnderCopy = $null; QuitPosts = 0; Exit = $null; Error = $null
    }
    $recordPath = Join-Path $Run 'run.json'
    # Everything the catch and finally read is set before the try (Greptile on #741: under StrictMode an early throw,
    # such as the session locking, reached an unset $watch in the finally, which threw before run.json was written).
    $process = [IntPtr]::Zero
    $watch = [IntPtr]::Zero
    $mouseWatch = [IntPtr]::Zero
    $keyWatch = [IntPtr]::Zero
    try {
        (Get-Process -Id $PID).PriorityClass = 'Normal'
        $record.DriverPriority = [string](Get-Process -Id $PID).PriorityClass
        if (-not [string]::Equals([FramePacingNative]::Layout(), $script:SdkLayout, [StringComparison]::Ordinal)) { throw "The mirrored structs do not match the SDK's x64 layout: $([FramePacingNative]::Layout())" }
        # The driver's own admission, before it starts anything: it takes nothing on trust from its caller.
        $own = [FramePacingNative]::CurrentDesktopName()
        $inputDesktop = [FramePacingNative]::InputDesktopName()
        if (-not [string]::Equals($own, $DesktopName, [StringComparison]::Ordinal)) { throw 'The driver is not on the desktop it was given.' }
        if ($null -eq $inputDesktop) { throw 'The input desktop is unreadable.' }
        if ($Visible) {
            if (-not [string]::Equals($own, 'Default', [StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($inputDesktop, 'Default', [StringComparison]::OrdinalIgnoreCase)) { throw 'A visible driver must run on Default while Default is the input desktop.' }
        } else {
            if (-not $own.StartsWith('noctty-fp-', [StringComparison]::Ordinal)) { throw 'The driver is not on its private desktop.' }
            if ([string]::Equals($own, 'Default', [StringComparison]::OrdinalIgnoreCase)) { throw 'The driver is on Default.' }
            if ([string]::Equals($own, $inputDesktop, [StringComparison]::OrdinalIgnoreCase)) { throw 'The driver is on the input desktop.' }
        }
        if (-not [FramePacingNative]::InJob()) { throw 'The driver is in no job.' }
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
        # No inherited NOCTTY_ or GHOSTTY_ variable (an inherited NOCTTY_CONPTY would move the copy to another host,
        # and others change what the copy traces or shows): the copy's only ones are the four this driver sets.
        $inherited = @([Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { ([string]$_).StartsWith('NOCTTY_', [StringComparison]::OrdinalIgnoreCase) -or ([string]$_).StartsWith('GHOSTTY_', [StringComparison]::OrdinalIgnoreCase) })
        if ($inherited.Count -ne 0) { throw "The driver inherited $($inherited.Count) NOCTTY_ or GHOSTTY_ variables." }
        # What it launches is the staged copy: the run's own copy directory, the portable marker, no noctty.ico, the
        # harness's config byte for byte, and the measurement build's bytes.
        if (-not [string]::Equals([IO.Path]::GetFullPath($Bin).TrimEnd('\'), (Join-Path $runPrefix 'copy'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The copy is not the run''s own copy directory.' }
        if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.portable') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $Bin 'noctty.ico'))) { throw 'The copy is not a portable copy without noctty.ico.' }
        $configPath = Join-Path $Bin 'config.ghostty'
        if (-not (Test-FramePacingConfigBytes $configPath $Run)) { throw "The copy's config is not byte for byte the harness's for this run." }
        $configCommands = @([IO.File]::ReadAllLines($configPath) | Where-Object { $_ -match '^\s*(initial-)?command\s*=' })
        $cmdPath = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
        if ($configCommands.Count -ne 1 -or -not [string]::Equals($configCommands[0], "command = direct:$cmdPath /D", [StringComparison]::Ordinal)) { throw "The copy's config must set exactly one command, System32's cmd.exe with /D, and no initial-command." }
        $record.ConfigSHA256 = Get-Sha256 $configPath
        $stray = @(Get-WorkingSetStrayConfigs $Bin); if ($stray.Count -gt 0) { throw "The copy holds another config file ($($stray -join ', ')), which the app's default search would read." }
        $build = Get-WorkingSetMeasureBuild $MeasureRepo
        if (-not (Test-WorkingSetCopy $Bin $build)) { throw "The copy's noctty.exe or noctty.com is not the measurement build's." }
        $record.MeasureHead = $build.Head
        $record.CliSHA256 = Get-Sha256 (Join-Path $Bin 'noctty.com')
        $record.ReceiptSHA256 = $build.ReceiptSha256
        foreach ($file in @(@('conpty.dll', 'ConptyDllSHA256'), @('OpenConsole.exe', 'OpenConsoleSHA256'))) {
            $staged = Join-Path $Bin $file[0]; $built = Join-Path $build.Bin $file[0]
            if (-not (Test-Path -LiteralPath $staged -PathType Leaf) -or -not (Test-Path -LiteralPath $built -PathType Leaf)) { throw "The copy or the build has no $($file[0])." }
            $record[$file[1]] = Get-Sha256 $staged
            $record['Prefix' + $file[1]] = Get-Sha256 $built
            if (-not [string]::Equals([string]$record[$file[1]], [string]$record['Prefix' + $file[1]], [StringComparison]::Ordinal)) { throw "The copy's $($file[0]) is not the measurement build's." }
        }
        # The payload: the generator's bytes for these constants, then this run's marker in its frame.
        $work = Join-Path $Run 'work'
        $streamPath = Join-Path $work 'stream.bin'
        $marker = [IO.File]::ReadAllText((Join-Path $work 'marker.txt'))
        if ($marker -notmatch '\ANB[0-9a-f]{16}\z') { throw 'The run''s marker is not a fresh token.' }
        $checkPath = Join-Path $Run 'temp\payload-check.bin'
        Write-FramePacingPayload $checkPath $marker
        if (-not [string]::Equals((Get-Sha256 $checkPath), (Get-Sha256 $streamPath), [StringComparison]::Ordinal)) { throw 'The staged payload is not the generator''s with this run''s marker.' }
        Remove-Item -LiteralPath $checkPath
        $record.PayloadSha256 = Get-FramePacingPayloadSha256 $streamPath
        $record.MarkerLength = $marker.Length

        $desktopPath = "WinSta0\$DesktopName"
        # The series' input watch, opened before anything is launched: a visible run without it starts nothing.
        if ($Visible) {
            if ([string]::IsNullOrEmpty($InputWatchEvent)) { throw 'A visible driver needs the series'' input watch.' }
            $watch = [FramePacingNative]::OpenWatch($InputWatchEvent)
            if ($watch -eq [IntPtr]::Zero) { throw 'The visible driver cannot open the series'' input watch; it starts nothing.' }
            $mouseWatch = [FramePacingNative]::OpenMouseWatch($InputWatchEvent)
            $keyWatch = [FramePacingNative]::OpenKeyWatch($InputWatchEvent)
            if ($mouseWatch -eq [IntPtr]::Zero -or $keyWatch -eq [IntPtr]::Zero) { throw 'The visible driver cannot open the series'' marked-input watches; it starts nothing.' }
            if ($InputMarker -eq 0) { throw 'A visible driver needs the series'' input marker.' }
        }
        $port = New-FramePacingPort $watch $mouseWatch $keyWatch $InputMarker
        # The input gate right before each launch on Default (a dry run launches only onto its private desktop).
        function Assert-Quiet([string] $Before) { if ($Visible) { Assert-FramePacingInputGate $port $record.InputTicks $Before } }
        # The gate read at each poll of a visible run's waits (Opus and Sol on #741): this process's own reads of the
        # watch and the tick the run expects (the unlock's once there is one, the series' before), recording a gate
        # check only when one shows input, which then stops the run at once and the catch ends the copy.
        function Assert-QuietPoll([string] $During) {
            if (-not $Visible) { return }
            Assert-FramePacingPollGate $port $record.InputTicks $During
        }
        # A wait with the gate read at each 100 ms of it (the lead and Sol on #741, round 6: input the hooks cannot see
        # moves only the tick, so every wait reads it): a sleep, a process's end (true when it ended within $Ms), and
        # the machine's load over 2 s, BusyPercent's share sampled around the polls.
        function Wait-FramePacingPolled([int] $Ms, [string] $During) { for ($waited = 0; $waited -lt $Ms; $waited += 100) { Start-Sleep -Milliseconds 100; Assert-QuietPoll $During } }
        function Wait-FramePacingProcess([IntPtr] $Process, [int] $Ms, [string] $During) {
            for ($waited = 0; $waited -lt $Ms; $waited += 100) {
                if ([FramePacingNative]::WaitForSingleObject($Process, 100) -eq 0) { return $true }
                Assert-QuietPoll $During
            }
            return [FramePacingNative]::WaitForSingleObject($Process, 0) -eq 0
        }
        function Measure-FramePacingBusy([string] $During) {
            $before = [FramePacingNative]::SystemTimes()
            Wait-FramePacingPolled 2000 $During
            return [Math]::Round([FramePacingNative]::BusyShare($before, [FramePacingNative]::SystemTimes()), 1)
        }
        # A quiet machine (MEASUREMENT-HARNESS-RERUN-01): a visible run waits for under 30% busy, up to
        # -QuietWaitSeconds, and launches nothing when it never was (Sol and CodeRabbit on #741); a dry run only records
        # the share. The share is unverifiable, and so never quiet, with more than one processor group.
        $record.ProcessorGroups = [FramePacingNative]::ProcessorGroups()
        $record.BusyPercentBefore = Measure-FramePacingBusy 'the load reading'
        if ($Visible) {
            $quietClock = [Diagnostics.Stopwatch]::StartNew()
            while (($record.BusyPercentBefore -lt 0 -or $record.BusyPercentBefore -ge $script:QuietBusyPercent) -and $quietClock.ElapsedMilliseconds -lt [long]$QuietWaitSeconds * 1000) {
                Wait-FramePacingPolled 10000 'the quiet wait'
                $record.BusyPercentBefore = Measure-FramePacingBusy 'the load reading'
            }
            $record.QuietWaitMs = $quietClock.ElapsedMilliseconds
            if ($record.BusyPercentBefore -lt 0 -or $record.BusyPercentBefore -ge $script:QuietBusyPercent) { throw "INCONCLUSIVE: the machine was not under $($script:QuietBusyPercent)% busy within $QuietWaitSeconds s (last $($record.BusyPercentBefore)%); nothing was launched." }
        }
        $record.TimerResolutionBefore100ns = [FramePacingNative]::TimerResolution()
        Log "busy $($record.BusyPercentBefore)% after $($record.QuietWaitMs) ms; timer resolution $($record.TimerResolutionBefore100ns) x 100 ns"
        # The visible part's preconditions on this driver's own session, after the wait and before any launch: in a
        # dry run they must refuse (it never takes the foreground and its intervals are not a measurement); in a
        # visible run they must hold, the session's last input still the series' tick among them.
        $facts = Get-FramePacingSessionFacts $QuietSinceTick $ForegroundLockNeededMs $(if ($Visible) { $record.InputTicks } else { $null })
        $record.Composition = $facts.Composition
        $record.NotificationState = $facts.NotificationState
        $record.ForegroundLockTimeoutMs = $facts.ForegroundLockTimeoutMs
        $record.VisibleRefusal = Get-FramePacingVisibleRefusal $facts
        if ($Visible -and $record.VisibleRefusal) { throw "INCONCLUSIVE: the visible run is refused: $($record.VisibleRefusal)" }
        if (-not $Visible -and -not $record.VisibleRefusal) { throw 'The dry run''s desktop passed the visible checks.' }
        Log "visible part: $(if ($record.VisibleRefusal) { "refused ($($record.VisibleRefusal))" } else { 'allowed' })"

        # What runs is the run's own copy (Sol on #741): its path, derived from the run independently of $Bin, here; the
        # launched image read back by PID after the launch.
        $copyExe = Join-Path ($runPrefix + 'copy') 'noctty.exe'
        $exe = Join-Path $Bin 'noctty.exe'
        if (-not [string]::Equals([IO.Path]::GetFullPath($exe), $copyExe, [StringComparison]::OrdinalIgnoreCase)) { throw 'The executable to launch is not the run''s own copy.' }
        $record.ExeSHA256 = Get-Sha256 $exe
        $versionPath = Join-Path $Run 'version.txt'
        Assert-Quiet '+version'
        $check = [FramePacingNative]::Spawn($exe, ('"{0}" +version' -f $exe), $work, $desktopPath, $versionPath, $false, [bool]$Visible)
        try {
            if (-not (Wait-FramePacingProcess $check.process 60000 '+version')) { [FramePacingNative]::Terminate($check.process, 1); throw '+version did not finish in 60 s.' }
            $versionExit = [FramePacingNative]::ExitCode($check.process)
        } finally { [void][FramePacingNative]::CloseHandle($check.thread); [void][FramePacingNative]::CloseHandle($check.process) }
        $modeMatch = [regex]::Match([IO.File]::ReadAllText($versionPath), '(?m)^\s*-\s*build mode\s*:\s*(?:[A-Za-z_.]*\.)?(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)\s*$')
        if ($versionExit -ne 0 -or -not $modeMatch.Success) { throw "noctty +version exited $versionExit with no build mode line." }
        $record.BuildMode = $modeMatch.Groups[1].Value
        if (-not [string]::Equals([string]$record.BuildMode, $ExpectedBuildMode, [StringComparison]::Ordinal) -or -not [string]::Equals([string]$build.Optimize, $ExpectedBuildMode, [StringComparison]::Ordinal)) { $record.Error = 'BUILD-MODE'; Log "build mode $($record.BuildMode); not launched"; return 3 }

        $layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot -SandboxName $SandboxName
        $launchArguments = @(Get-InteractiveWin11LaunchArguments -Layout $layout -UseConfiguredCommand) + @(
            '--window-save-state=never', '--clipboard-read=deny', '--clipboard-write=deny',
            '--config-default-files=false', "--config-file=$configPath")
        $class = @($launchArguments | Where-Object { $_ -like '--class=*' } | ForEach-Object { $_.Substring(8) })
        if ($class.Count -ne 1) { throw 'The launch helper gave no single --class.' }
        if (@($launchArguments | Where-Object { $_ -like '--command=*' -or $_ -eq '-e' }).Count -ne 0) { throw 'The command line must not set the shell.' }
        foreach ($argument in $launchArguments) { if ($argument -match '"' -or $argument.EndsWith('\')) { throw 'A launch argument cannot be quoted.' } }
        $record.Class = $class[0]
        $commandLine = ('"{0}" ' -f $exe) + (@($launchArguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
        $expectedArgv = Get-FramePacingExpectedArgv $exe "noctty-interactive-$($layout.SandboxId)" $configPath
        if (-not (Test-WorkingSetArgv ([FramePacingNative]::SplitCommandLine($commandLine)) $expectedArgv)) { throw "The copy's command line is not exactly the expected argument list." }
        $record.LaunchConfigDefaultFiles = $false
        $record.LaunchConfigFile = $configPath
        $record.WorkloadSha256 = Get-FramePacingWorkloadSha256 $record.PayloadSha256 $configPath $Run
        [void][FramePacingNative]::SetErrorMode([FramePacingNative]::GetErrorMode() -bor 2)   # SEM_NOGPFAULTERRORBOX, inherited
        # The foreground lock read again right before the launch, after +version's wait (Sol on #741, round 5): a
        # setting changed since the session facts were read must still outlast this run and every run after it.
        if ($Visible) {
            $record.ForegroundLockTimeoutAtLaunchMs = [FramePacingNative]::ForegroundLockTimeout()
            $lockShortfall = Get-FramePacingLockShortfall $record.ForegroundLockTimeoutAtLaunchMs $ForegroundLockNeededMs
            if ($lockShortfall) { throw "INCONCLUSIVE: right before the copy's launch, $lockShortfall; the copy was not launched." }
        }
        # The copy's environment: the log on stderr, the live render trace into the run, and this run's end marker.
        $tracePath = Join-Path $Run 'render-trace.json'
        $env:GHOSTTY_LOG = 'stderr'
        $env:NOCTTY_RENDER_TRACE_FILE = $tracePath
        $env:NOCTTY_RENDER_TRACE_LIVE = '1'
        $env:NOCTTY_BENCH_END_MARKER = $marker
        # Whether any window holds the foreground right before the copy starts (Opus on #741): with none, the copy's
        # own activation taking it is a path the lock does not cover and harmless while the user is away; with one,
        # the copy taking it contradicts the lock claim.
        if ($Visible) { $record.ForegroundBeforeLaunch = $(if ([FramePacingNative]::AnyForeground()) { 'a window' } else { 'none' }) }
        Assert-Quiet 'the copy''s launch'
        $pi = [FramePacingNative]::Spawn($exe, $commandLine, $work, $desktopPath, (Join-Path $Run 'noctty.log'), $false, [bool]$Visible)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = $pi.process
        [void][FramePacingNative]::CloseHandle($pi.thread)
        $nocttyPid = $pi.pid
        # What the copy really received and what really runs, by PID: exactly the same argument list and the run's own
        # copy's image, or the run stops. The command line itself is never logged or recorded.
        $launched = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $nocttyPid" -ErrorAction Stop
        $launchedLine = [string]$launched.CommandLine
        if (-not (Test-WorkingSetArgv ([FramePacingNative]::SplitCommandLine($launchedLine)) $expectedArgv)) { throw 'The copy was not launched with exactly the expected argument list.' }
        if (-not [string]::Equals([string]$launched.ExecutablePath, $copyExe, [StringComparison]::OrdinalIgnoreCase)) { throw 'The launched image is not the run''s own copy.' }
        $launchedLine = $null; $launched = $null
        try { $record.NocttyPriority = [string](Get-Process -Id $nocttyPid -ErrorAction Stop).PriorityClass } catch { $record.NocttyPriority = 'unknown' }
        if (-not [string]::Equals([string]$record.NocttyPriority, 'Normal', [StringComparison]::Ordinal)) { throw "The copy runs at $($record.NocttyPriority) priority, not Normal." }
        Log "launched ($mode), build mode $($record.BuildMode)"

        function Get-Hosts { return @([FramePacingNative]::Hosts($nocttyPid)) }
        function Get-AllSurfaces([bool] $VisibleOnly) { $list = @(); foreach ($h in Get-Hosts) { $list += @([FramePacingNative]::Surfaces($h, $VisibleOnly)) }; return $list }
        function Wait-For([scriptblock] $Predicate, [int] $Ms) {
            $deadline = $clock.ElapsedMilliseconds + $Ms
            do {
                Assert-QuietPoll 'a wait'
                if (& $Predicate) { return $true }
                if (-not [FramePacingNative]::Alive($process)) { return $false }
                Start-Sleep -Milliseconds 100
            } while ($clock.ElapsedMilliseconds -lt $deadline)
            return [bool](& $Predicate)
        }
        if (-not (Wait-For { @(Get-AllSurfaces $true).Count -ge 1 } 90000)) { throw 'The first pane never showed.' }
        $hosts = @(Get-Hosts)
        if ($hosts.Count -ne 1) { throw "Expected one window, found $($hosts.Count)." }
        $hostWindow = $hosts[0]
        $panes = @(Get-AllSurfaces $false)
        if ($panes.Count -ne 1) { throw "Expected one pane, found $($panes.Count)." }
        $pane = $panes[0]
        $client = [FramePacingNative]::ClientAndDpi($pane)
        $record.ClientWidth = $client[0]; $record.ClientHeight = $client[1]; $record.Dpi = $client[2]
        $monitorMode = [FramePacingNative]::MonitorMode($hostWindow)
        $record.MonitorWidth = $monitorMode[0]; $record.MonitorHeight = $monitorMode[1]; $record.RefreshHz = $monitorMode[2]
        $record.DisplayMode = '{0}x{1}@{2}' -f $monitorMode[0], $monitorMode[1], $monitorMode[2]

        # The grid, before the workload, as #739 reads it: a probe child attaches to the pane's shell's console.
        [void](Wait-For { $script:fpShells = @([FramePacingNative]::Children($nocttyPid, 'cmd.exe')); $script:fpShells.Count -eq 1 } 30000)
        $shells = @($script:fpShells)
        if ($shells.Count -ne 1) { throw "Expected one shell under the copy, found $($shells.Count)." }
        $pwsh = (Get-Command pwsh.exe).Source
        $gridFile = Join-Path $Run 'grid.txt'
        Assert-Quiet 'the grid probe'
        $probe = [FramePacingNative]::Spawn($pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -GridProbePid {3}' -f $pwsh, $PSCommandPath, $Run, $shells[0]), $Run, $desktopPath, (Join-Path $Run 'grid-probe.log'), $true, [bool]$Visible)
        try {
            if (-not (Wait-FramePacingProcess $probe.process 60000 'the grid probe')) { [FramePacingNative]::Terminate($probe.process, 1); throw 'The grid probe did not finish in 60 s.' }
            if ([FramePacingNative]::ExitCode($probe.process) -ne 0) { throw 'The grid probe failed.' }
        } finally { [void][FramePacingNative]::CloseHandle($probe.thread); [void][FramePacingNative]::CloseHandle($probe.process) }
        $grid = [regex]::Match([IO.File]::ReadAllText($gridFile), '\A(\d+),(\d+)\z')
        if (-not $grid.Success) { throw "The grid probe read no grid ($([IO.File]::ReadAllText($gridFile)))." }
        $record.GridCols = [int]$grid.Groups[1].Value; $record.GridRows = [int]$grid.Groups[2].Value
        if ($record.GridCols -ne $script:Cols -or $record.GridRows -ne $script:GridRows) { throw "The grid is $($record.GridCols)x$($record.GridRows), not $($script:Cols)x$($script:GridRows)." }

        # The dry run's console probe: cmd's console from its top-left through the cursor, read through the pane's
        # pseudoconsole as the grid is, written to a file the driver reads and deletes (it holds the prompt, so only
        # lengths are ever logged).
        function Read-FramePacingConsoleText([string] $Name) {
            $file = Join-Path $Run "cursor-$Name.txt"
            $cursorProbe = [FramePacingNative]::Spawn($pwsh, ('"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -CursorProbePid {3} -CursorProbeName {4}' -f $pwsh, $PSCommandPath, $Run, $shells[0], $Name), $Run, $desktopPath, (Join-Path $Run "cursor-$Name.log"), $true, [bool]$Visible)
            try {
                if (-not (Wait-FramePacingProcess $cursorProbe.process 60000 'the console probe')) { [FramePacingNative]::Terminate($cursorProbe.process, 1); throw 'The cursor probe did not finish in 60 s.' }
                if ([FramePacingNative]::ExitCode($cursorProbe.process) -ne 0) { throw 'The cursor probe failed.' }
            } finally { [void][FramePacingNative]::CloseHandle($cursorProbe.thread); [void][FramePacingNative]::CloseHandle($cursorProbe.process) }
            $raw = [IO.File]::ReadAllText($file)
            Remove-Item -LiteralPath $file
            $read = [regex]::Match($raw, '\A(\d+)\t(.*)\z', [Text.RegularExpressions.RegexOptions]::Singleline)
            if (-not $read.Success -or $read.Groups[2].Value.Length -ne [int]$read.Groups[1].Value) { throw "The cursor probe read no console text ($($raw.Length) characters)." }
            return [pscustomobject]@{ Cells = [int]$read.Groups[1].Value; Text = $read.Groups[2].Value }
        }

        # The render trace: a snapshot the pane writes on request (WM_APP + 8), read once it is newer than the last.
        $script:fpSequence = [uint64]0
        function Request-Trace {
            if (-not [FramePacingNative]::TraceMessage($pane, $nocttyPid, $script:WmRenderTraceSnapshot, 0, $script:ResponseBoundMs)) { throw 'The pane did not answer a render-trace snapshot request within the bound.' }
            $deadline = $clock.ElapsedMilliseconds + 10000
            do {
                $raw = Read-SharedText $tracePath
                if ($raw) {
                    $snapshot = $null
                    try { $snapshot = $raw | ConvertFrom-Json } catch { $snapshot = $null }
                    if ($null -ne $snapshot -and [uint64]$snapshot.snapshot_sequence -gt $script:fpSequence) { $script:fpSequence = [uint64]$snapshot.snapshot_sequence; return $snapshot }
                }
                Assert-QuietPoll 'a render-trace snapshot'
                Start-Sleep -Milliseconds 5
            } while ($clock.ElapsedMilliseconds -lt $deadline)
            throw 'No fresh render-trace snapshot within 10 s.'
        }
        # Quiet: no swap and no output wake for $QuietMs, within $CapMs.
        function Wait-Quiet([int] $QuietMs, [int] $CapMs) {
            $last = Request-Trace
            $since = $clock.ElapsedMilliseconds; $start = $since
            while ($clock.ElapsedMilliseconds - $start -lt $CapMs) {
                Start-Sleep -Milliseconds 100
                Assert-QuietPoll 'a quiet wait'
                $next = Request-Trace
                if ([uint64]$next.swap_buffers_count -ne [uint64]$last.swap_buffers_count -or [uint64]$next.io_output_wakeup_count -ne [uint64]$last.io_output_wakeup_count) { $last = $next; $since = $clock.ElapsedMilliseconds; continue }
                if ($clock.ElapsedMilliseconds - $since -ge $QuietMs) { return $next }
            }
            throw "The pane did not go quiet for $QuietMs ms within $CapMs ms."
        }
        $settled = Wait-Quiet $script:QuietMs 30000
        if ([uint64]$settled.swap_buffers_count -lt 1) { throw 'The pane presented no frame before the workload.' }

        # The visible part. A dry run skips it (its preconditions refused above); a visible run takes the foreground
        # through the bounded call, then reads the window's composition state.
        $record.DisplayPowerBefore = [FramePacingNative]::DisplayPower(2000)
        if ($Visible) {
            # The display must be on (Opus on #741), and the input gate holds right before the unlock, inside
            # Invoke-FramePacingForeground and again on the native worker: a user who came back keeps the foreground.
            if ($record.DisplayPowerBefore -ne $script:DisplayOn) { throw "INCONCLUSIVE: the display is not on (state $($record.DisplayPowerBefore)); the foreground was not taken." }
            # Whether the copy already holds the foreground before the harness's unlock (Opus on #741). The foreground
            # lock should keep noctty's own startup activation behind the user's window; a copy in front got there by a
            # path the lock does not cover (no foreground window at all, the user's last input landing on the copy, a
            # right passed down the launch chain), so the run is inconclusive and the series stops. With this machine's
            # lock, which never expires, every visible run tests the claim.
            $record.ForegroundBeforeUnlock = [FramePacingNative]::IsForeground($hostWindow)
            if ($record.ForegroundBeforeUnlock) {
                if ([string]::Equals([string]$record.ForegroundBeforeLaunch, 'none', [StringComparison]::Ordinal)) { $record.ForegroundTakenFromNone = $true }
                else { throw 'INCONCLUSIVE: the copy took the foreground from another window before the harness''s unlock, which the foreground lock should have prevented.' }
            }
            $record.ScreenSaverBeforeUnlock = [FramePacingNative]::ScreenSaverRunning()
            if ($record.ScreenSaverBeforeUnlock -ne 0) { throw "INCONCLUSIVE: a screen saver is running or unreadable ($($record.ScreenSaverBeforeUnlock)); the foreground was not taken." }
            $record.Foreground = Invoke-FramePacingForeground $port $record.InputTicks $hostWindow $nocttyPid
            $record.Cloaked = [FramePacingNative]::Cloaked($hostWindow)
            if ([FramePacingNative]::IsIconic($hostWindow)) { $record.Foreground = 'minimized' }
            Log "foreground: $($record.Foreground); cloaked $($record.Cloaked)"
            if (-not [string]::Equals([string]$record.Foreground, 'ok', [StringComparison]::Ordinal)) { throw "INCONCLUSIVE: the foreground was $($record.Foreground)." }
            Assert-Quiet 'the copy in front'
            $record.KeyProbe = Invoke-FramePacingKeyProbe $port $record.InputTicks $hostWindow $nocttyPid
            Log "keyboard probe: $($record.KeyProbe)"
            if (-not [string]::Equals([string]$record.KeyProbe, 'ok', [StringComparison]::Ordinal)) { throw "INCONCLUSIVE: the keyboard probe was $($record.KeyProbe)." }
            $settled = Wait-Quiet $script:QuietMs 30000
        } else {
            $record.Foreground = 'skipped'
            # The keyboard probe's effect, measured where it can be (the lead on #741): the same VK_NONAME down and up,
            # posted to the copy's pane as the harness drives keys on a private desktop, must leave cmd's console as it
            # was through the cursor, and the command F5 types next must land after its prompt intact (below), read
            # from the top-left so a prompt or command that wraps is read whole (Greptile on #741).
            $promptBefore = Read-FramePacingConsoleText 'before-probe'
            Assert-Quiet 'the dry run''s key probe'
            [FramePacingNative]::PostKey($pane, $nocttyPid, 0xFC)
            [void](Wait-Quiet $script:EchoQuietMs 15000)
            $promptAfter = Read-FramePacingConsoleText 'after-probe'
            $record.DryProbePromptUnchanged = Test-FramePacingConsoleTyped $promptBefore $promptAfter ''
            if (-not $record.DryProbePromptUnchanged) { throw "The keyboard probe changed cmd's console ($($promptBefore.Cells) cells to $($promptAfter.Cells))." }
        }

        # The command, then the arm, then Enter: F5 types `type stream.bin` (echoed, then quiet), the target is armed
        # (WM_APP + 9 with 0: the first swap that presents the end marker), and F6's carriage return runs it.
        $before = Request-Trace
        Assert-Quiet 'the command key'
        [FramePacingNative]::PostKey($pane, $nocttyPid, 0x74)
        if (-not (Wait-For { [uint64](Request-Trace).last_swap_process_output_generation -gt [uint64]$before.last_swap_process_output_generation } 15000)) { throw 'No swap presented the command''s echo within 15 s.' }
        $echoed = Wait-Quiet $script:EchoQuietMs 15000
        if (-not $Visible) {
            $typed = 'type stream.bin & echo.>done.flag'
            $command = Read-FramePacingConsoleText 'after-command'
            $record.DryProbeCommandIntact = Test-FramePacingConsoleTyped $promptBefore $command $typed
            if (-not $record.DryProbeCommandIntact) { throw "The command F5 typed after the keyboard probe is not intact after cmd's prompt ($($promptBefore.Cells) cells to $($command.Cells))." }
        }
        $focusChanges = [uint64]$echoed.surface_focus_change_count
        $record.SwapsBefore = [uint64]$echoed.swap_buffers_count
        # The machine's load right before the window (Sol on #741), acted on at once in a visible run (CodeRabbit on
        # #741: a busy machine must not first fail the capture), a screen saver read again, then the input gate.
        $record.BusyPercentAtArm = Measure-FramePacingBusy 'the load reading before the window'
        if ($Visible -and ($record.BusyPercentAtArm -lt 0 -or $record.BusyPercentAtArm -ge $script:QuietBusyPercent)) { throw "INCONCLUSIVE: the machine was $($record.BusyPercentAtArm)% busy right before the measured window; it was not started." }
        if ($Visible) {
            $record.ScreenSaverAtArm = [FramePacingNative]::ScreenSaverRunning()
            if ($record.ScreenSaverAtArm -ne 0) { throw "INCONCLUSIVE: a screen saver is running or unreadable ($($record.ScreenSaverAtArm)) right before the measured window; it was not started." }
        }
        Assert-Quiet 'the measured window'
        $donePath = Join-Path $work 'done.flag'
        if (Test-Path -LiteralPath $donePath) { throw 'The producer''s end file exists before the run.' }
        # The arm, then F6 with nothing between but the gate: no snapshot confirms the arm inside the window
        # (CodeRabbit on #741); the snapshot after the window shows it took (the target was 0 and its swap captured).
        if (-not [FramePacingNative]::TraceMessage($pane, $nocttyPid, $script:WmRenderTraceTarget, 0, $script:ResponseBoundMs)) { throw 'The pane did not answer the trace''s arm within the bound.' }
        Assert-Quiet 'the start key'
        [FramePacingNative]::PostKey($pane, $nocttyPid, 0x75)
        # The window, with nothing sent to the pane inside it (Opus on #741: noctty writes a snapshot on the presenting
        # thread, under the lock each swap takes). cmd's done.flag is polled as a file; then, $DrainMs apart, one
        # snapshot at a time until one shows the end marker's swap. A snapshot that still shows the target armed landed
        # inside the window and is counted, and the verdict accepts none; the trace keeps up to 2,048 intervals in
        # memory (render_trace.zig), and an overflow fails the run.
        # Input inside the window makes a visible run inconclusive, never a timeout's hard failure (CodeRabbit on
        # #741): each poll reads the gate (Assert-QuietPoll, this process's own reads, which reach nothing of the
        # copy's), and a timeout, or a snapshot that fails, checks the gate before it is reported.
        if (-not (Wait-For { Test-Path -LiteralPath $donePath -PathType Leaf } 120000)) {
            Assert-Quiet 'the payload''s timeout'
            throw 'cmd did not finish writing the payload within 120 s.'
        }
        $doneQpc = [Diagnostics.Stopwatch]::GetTimestamp()
        $snapshotsInWindow = 0
        $presented = $null
        $presentDeadline = $clock.ElapsedMilliseconds + 120000
        while ($null -eq $presented) {
            # $DrainMs between snapshots, the gate read at each 100 ms of it (Opus on #741, round 5: input the hooks
            # cannot see stops the run within a poll here too).
            for ($drained = 0; $drained -lt $script:DrainMs; $drained += 100) { Start-Sleep -Milliseconds 100; Assert-QuietPoll 'the end marker''s swap' }
            if (-not [FramePacingNative]::Alive($process)) { throw 'The copy ended before it presented the end marker.' }
            try { $s = Request-Trace } catch { Assert-Quiet 'the end marker''s snapshot'; throw }
            if ([uint64]$s.first_target_swap_qpc_ticks -gt 0 -and [uint64]$s.first_target_swap_benchmark_end_marker_generation -gt 0) { $presented = $s }
            else {
                $snapshotsInWindow++
                if ($clock.ElapsedMilliseconds -ge $presentDeadline) { Assert-Quiet 'the end marker''s timeout'; throw 'No swap presented the end marker within 120 s of the producer''s end.' }
            }
        }
        $record.SnapshotsInWindow = $snapshotsInWindow
        if (-not $presented.PSObject.Properties['target_process_output_bytes'] -or [uint64]$presented.target_process_output_bytes -ne 0) { throw 'The trace''s target was not armed for the end marker.' }
        if ([uint64]$presented.qpc_frequency -eq [uint64][Diagnostics.Stopwatch]::Frequency) {
            $record.PresentAfterDoneMs = [Math]::Round(([double][uint64]$presented.first_target_swap_qpc_ticks - [double]$doneQpc) * 1000.0 / [double]$presented.qpc_frequency, 3)
        }
        $record.EndMarkerPresented = $true
        $record.SwapsAfter = [uint64]$presented.swap_buffers_count
        $record.QpcFrequency = [uint64]$presented.qpc_frequency
        $record.IntervalOverflow = [uint64]$presented.target_swap_interval_overflow_count
        $stats = Get-FramePacingIntervalStats @($presented.target_swap_interval_qpc_ticks) ([double]$presented.qpc_frequency)
        $record.IntervalsMs = [double[]]@($stats.Ms | ForEach-Object { [Math]::Round($_, 6) })
        $record.IntervalCount = $stats.Count
        if ($stats.Count -gt 0) { $record.P95Ms = [Math]::Round($stats.P95, 6); $record.MedianMs = [Math]::Round($stats.Median, 6); $record.MaxMs = [Math]::Round($stats.Max, 6); $record.WindowMs = [Math]::Round($stats.Sum, 6) }
        # Held through the workload (a visible run only counts it so): the foreground, the pane's focus, and no input;
        # and the window's display mode (Greptile on #741), read again now.
        $modeAfter = [FramePacingNative]::MonitorMode($hostWindow)
        $record.DisplayModeAfter = '{0}x{1}@{2}' -f $modeAfter[0], $modeAfter[1], $modeAfter[2]
        $record.ForegroundHeld = [FramePacingNative]::IsForeground($hostWindow)
        $record.FocusHeld = [bool]$presented.surface_focused -and [uint64]$presented.surface_focus_change_count -eq $focusChanges
        $record.DisplayPowerAfter = [FramePacingNative]::DisplayPower(2000)
        if ($Visible) {
            $record.InputBreak = Test-FramePacingInputGate $port $record.InputTicks 'the end of the measured window'
            $record.InputDuringRun = $null -ne $record.InputBreak
        }
        Log ("workload: {0} intervals, p95 {1} ms, median {2} ms, overflow {3}, snapshots in the window {4}, presented {5} ms after cmd's end; foreground held {6}, focus held {7}, input {8}" -f $record.IntervalCount, $record.P95Ms, $record.MedianMs, $record.IntervalOverflow, $record.SnapshotsInWindow, $record.PresentAfterDoneMs, $record.ForegroundHeld, $record.FocusHeld, $record.InputDuringRun)
        # Input by the end of the window makes the run inconclusive, and the copy, still in front, is ended now rather
        # than after the readings below (Opus on #741, round 5).
        if ($record.InputDuringRun) { throw "INCONCLUSIVE: $($record.InputBreak); the copy was ended at once." }

        # No PowerShell under the copy: its children and its shell's.
        $record.ShellsUnderCopy = @([FramePacingNative]::Children($nocttyPid, 'cmd.exe')).Count
        $record.PowerShellUnderCopy = 0
        foreach ($parent in @($nocttyPid) + @($shells)) { foreach ($name in @('powershell.exe', 'pwsh.exe')) { $record.PowerShellUnderCopy += @([FramePacingNative]::Children($parent, $name)).Count } }
        $record.BusyPercentAfter = Measure-FramePacingBusy 'the load reading after the window'
        $record.TimerResolutionAfter100ns = [FramePacingNative]::TimerResolution()
        # The gate once more before the quit (Opus on #741, round 5): input during the readings above ends the copy now.
        Assert-Quiet 'the quit'

        foreach ($h in Get-Hosts) { if ([FramePacingNative]::PostClose($h, $nocttyPid)) { $record.QuitPosts++ } }
        if ($record.QuitPosts -lt 1) { Log 'quit: no close post took' }
        if (Wait-FramePacingProcess $process 60000 'the copy''s quit') { $record.Exit = [FramePacingNative]::ExitCode($process) }
        else { [FramePacingNative]::Terminate($process, 1); $record.Exit = 'stuck'; Log 'the copy did not end within 60 s of the quit' }
        Log "quit: $($record.QuitPosts) posts, exit $($record.Exit)"
        # The transport and the renderer, from the copy's own log: the bundled ConPTY from its own conpty.dll (src/pty.zig's
        # startup marker), and OpenGL with no backend fallback (src/renderer/Windows.zig's warnings).
        $nocttyLog = Read-SharedText (Join-Path $Run 'noctty.log')
        $record.Transport = if ($nocttyLog.Contains('using the in-box conhost')) { 'inbox' } elseif ($nocttyLog.IndexOf('using bundled ConPTY: ' + (Join-Path $Bin 'conpty.dll'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { 'bundled' } else { 'unknown' }
        $record.Renderer = if ($nocttyLog.Contains('startup failed') -or $nocttyLog.Contains('Direct3D 11') -or $nocttyLog.Contains('D3D11')) { 'fallback' } else { 'opengl' }
        # Exit 0 complete, 2 inconclusive (every problem the visible run's environment), 1 anything else.
        $problems = @(Get-FramePacingRecordProblems ([pscustomobject]$record))
        if ($problems.Count -gt 0 -and -not $record.Error) {
            $soft = @($problems | Where-Object { $_.StartsWith('inconclusive:', [StringComparison]::Ordinal) })
            $record.Error = $(if ($soft.Count -eq $problems.Count) { 'INCONCLUSIVE: ' } else { '' }) + ($problems -join '; ')
        }
        if (-not $record.Error) { return 0 }
        return $(if ($record.Error.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal)) { 2 } else { 1 })
    } catch {
        $record.Error = $_.Exception.Message
        Log "error: $($_.Exception.Message)"
        if ($process -ne [IntPtr]::Zero -and [FramePacingNative]::Alive($process)) { [FramePacingNative]::Terminate($process, 1) }
        return $(if ($record.Error.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal)) { 2 } else { 1 })
    } finally {
        if ($process -ne [IntPtr]::Zero) { [void][FramePacingNative]::CloseHandle($process) }
        if ($record.InputTicks.Checks -is [Collections.Generic.List[object]]) { $record.InputTicks.Checks = [object[]]$record.InputTicks.Checks.ToArray() }
        if ($watch -ne [IntPtr]::Zero) { [void][FramePacingNative]::CloseHandle($watch) }
        if ($mouseWatch -ne [IntPtr]::Zero) { [void][FramePacingNative]::CloseHandle($mouseWatch) }
        if ($keyWatch -ne [IntPtr]::Zero) { [void][FramePacingNative]::CloseHandle($keyWatch) }
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
    }
}

# ---------------------------------------------------------------------------------------------------------
# The outer half: admission, the copies, the guards and the summary.
# ---------------------------------------------------------------------------------------------------------
function Invoke-FramePacingOuter {
    # Only the receipt-bound measurement build, before anything is created or started.
    $build = Get-WorkingSetMeasureBuild $MeasureRepo
    # No NOCTTY_ or GHOSTTY_ variable for the copy to inherit, before anything is created.
    $inherited = @([Environment]::GetEnvironmentVariables('Process').Keys | Where-Object { ([string]$_).StartsWith('NOCTTY_', [StringComparison]::OrdinalIgnoreCase) -or ([string]$_).StartsWith('GHOSTTY_', [StringComparison]::OrdinalIgnoreCase) })
    if ($inherited.Count -ne 0) { throw "This environment holds $($inherited.Count) NOCTTY_ or GHOSTTY_ variables, which the copy would inherit; clear them first." }
    $fonts = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction Stop
    if (-not ($fonts.PSObject.Properties.Name -match '^Consolas .*TrueType')) { throw 'The workload''s font, Consolas, is not installed.' }
    # A visible run only from Default, unlocked, composed, local and idle; a dry run never touches Default.
    $quietSince = [long]-1
    $watchEvent = $null
    $lockNeeded = [long]-1
    $inputMarker = [long]0
    $admissionIdleMs = [long]-1
    $seriesClock = [Diagnostics.Stopwatch]::StartNew()
    # The harness this process is executing (Sol on #741, round 10, and on #744): each driver records the same hash
    # of its own loaded script, and a driver that ran other text voids the series as harness-changed.
    $harnessSha256 = Get-FramePacingLoadedHarnessSha256
    if ($Visible) {
        $facts = Get-FramePacingSessionFacts -1 -1 $null
        $lockNeeded = Get-FramePacingLockNeedMs $facts.IdleMs $facts.MinIdleMs $Runs
        $facts.ForegroundLockNeededMs = $lockNeeded
        Write-Host "frame pacing: the foreground lock is $($facts.ForegroundLockTimeoutMs) ms; this series needs over $lockNeeded ms"
        $refusal = Get-FramePacingVisibleRefusal $facts
        if ($refusal) { throw "-Visible is refused: $refusal." }
        $quietSince = [long]$facts.LastInputTick
        $admissionIdleMs = [long]$facts.IdleMs
        $seriesClock.Restart()
        $watchEvent = 'Local\noctty-frame-pacing-input-' + [guid]::NewGuid().ToString('N')
        $inputMarker = New-FramePacingInputMarker
    }
    if ([string]::IsNullOrWhiteSpace($RunRoot)) { throw 'Pass -RunRoot, a new directory for the runs.' }
    $root = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $RunRoot))
    if (Test-Path -LiteralPath $root) { throw 'The run root must be new.' }
    if (($root + '\').StartsWith($build.Bin.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The run root cannot be inside the build.' }
    Assert-WorkingSetRunPlacement $root $build.Repo
    $mutex = [Threading.Mutex]::new($false, 'Local\noctty-bench-frame-pacing')
    $owned = $false
    $held = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another frame-pacing run is active in this session.' }
        # The input watch from admission to the series' end (the lead on #741), before anything is staged.
        if ($Visible) {
            [FramePacingNative]::ResetWatchCounts()
            Start-FramePacingInputWatch { param([string] $Name) [FramePacingNative]::StartWatch($Name, 5000, [IntPtr]$inputMarker) } $watchEvent
            $break = Test-FramePacingInputGate (New-FramePacingOuterPort) ([ordered]@{ Series = $quietSince; Unlock = $null; Checks = [Collections.Generic.List[object]]::new() }) 'the series'' first run'
            if ($break) { throw "-Visible is refused: $break." }
        }
        # The display and the system stay on for a visible series (Opus on #741), released when it ends.
        if ($Visible) { $held = [FramePacingNative]::HoldDisplay(); if (-not $held) { throw 'The display could not be held on for the series.' } }
        [void](New-Item -ItemType Directory -Path $root)
        $results = [Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le $Runs; $i++) {
            # The lock must still outlast this run and every run after it, counted from the user's last input: the idle
            # time seen at admission plus the series' time since (Sol on #741), against the lock as it reads now (Sol on
            # #741, round 5: a setting changed during the series). Otherwise nothing more is launched.
            $needNow = [long]-1
            if ($Visible) {
                $needNow = Get-FramePacingLockNeedMs ($admissionIdleMs + $seriesClock.ElapsedMilliseconds) $facts.MinIdleMs ($Runs - $i + 1)
                $shortfall = Get-FramePacingLockShortfall ([FramePacingNative]::ForegroundLockTimeout()) $needNow
                if ($shortfall) {
                    $results.Add([pscustomobject]@{ Run = (Join-Path $root "run-$i"); Status = 'inconclusive'; Failures = @("inconclusive: $shortfall; run $i was not launched"); Record = $null })
                    Write-Host "frame pacing run $i of $($Runs): inconclusive (the foreground lock would not outlast the series)"
                    break
                }
            }
            $mouseBefore = if ($Visible) { [FramePacingNative]::MarkedMouseInputs() } else { [long]0 }
            $keyBefore = if ($Visible) { [FramePacingNative]::MarkedKeyInputs() } else { [long]0 }
            $result = Invoke-FramePacingOuterRun $build (Join-Path $root "run-$i") $quietSince $watchEvent $needNow $inputMarker
            # The hooks' proof of life from this side too (Opus and CodeRabbit on #741): a run whose foreground was
            # taken sent one marked unlock, which the mouse hook must have counted, and a run whose key probe passed
            # one marked key, which the keyboard hook must have.
            if ($Visible) {
                $silence = Get-FramePacingHookSilence $result.Record $mouseBefore ([FramePacingNative]::MarkedMouseInputs()) $keyBefore ([FramePacingNative]::MarkedKeyInputs()) ([FramePacingNative]::RealInputs())
                # The run's own result, edited in place (Opus on #741, round 9): a rebuilt one could drop a field, its
                # input latch among them.
                if ($silence) { $result.Status = Get-FramePacingSilencedStatus $result.Status $silence; $result.Failures = @(@($result.Failures) + $silence.Line) }
            }
            $results.Add($result)
            if ($Visible -and $null -ne $result.Record -and $null -ne $result.Record.InputTicks -and $null -ne $result.Record.InputTicks.Unlock) { $quietSince = [long]$result.Record.InputTicks.Unlock }
            Write-Host "frame pacing run $i of $($Runs): $($result.Status)"
            if (-not [string]::Equals($result.Status, 'complete', [StringComparison]::Ordinal)) { break }
        }
        return Complete-FramePacingSeries (New-FramePacingSeriesPort) $root $build @($results.ToArray()) $quietSince $harnessSha256
    } finally {
        # Stopped whenever this series may have started one, even when the start was refused (Sol and CodeRabbit on
        # #741: a watch given up on during startup is joined here); a thread that will not end is said, and this
        # process's exit ends it.
        if ($Visible -and -not [FramePacingNative]::StopWatch()) { Write-Host 'frame pacing: the input watch''s thread did not end within 2 s; this process''s exit removes its hooks.' }
        if ($held) { [FramePacingNative]::ReleaseDisplay() }
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# The series' end (the lead and Sol on #741, round 6). Every run has ended and its job, with its copy, is closed when
# this runs. A visible series then stops its watch (the hooks come out), and only then reads the final real-input count
# and the session's tick against $Baseline (the last tick the harness's own marked input left), so input the hooks
# could still count never lands after the verdict's reading; then the summary. Input after the unhook reaches no copy.
# $Port gives StopWatch() (true once the hooks are out), RealInputs(), InjectedInputs() and LastInputTick(). Returns
# the summary's exit code.
function Complete-FramePacingSeries($Port, [string] $Root, $Build, [object[]] $Results, [long] $Baseline, [string] $HarnessSha256) {
    if (-not $Visible) { return Write-FramePacingSummary $Root $Build $Results $null $null $false $false $HarnessSha256 }
    $stopped = [bool]$Port.StopWatch()
    $final = Get-FramePacingFinalInput $stopped ([long]$Port.RealInputs()) ([long]$Port.LastInputTick([ordered]@{ Series = $Baseline; Unlock = $null; Broken = $false })) $Baseline
    return Write-FramePacingSummary $Root $Build $Results $final.RealInputs $(if ($stopped) { [long]$Port.InjectedInputs() } else { $null }) $final.TickMoved $final.TickUnread $HarnessSha256
}

# The series' final input reading: the hooks' real-input count, null when the watch did not stop (its count could
# still move), whether the session's tick left the baseline, an unreadable tick counting as moved, and whether it
# could not be read at all (TickUnread, for the summary's wording). Pure, so the contract tables it.
function Get-FramePacingFinalInput([bool] $Stopped, [long] $RealInputs, [long] $Tick, [long] $Baseline) {
    return [pscustomobject]@{ RealInputs = $(if ($Stopped) { $RealInputs } else { $null }); TickMoved = $null -ne (Get-FramePacingTickStop $Tick $Baseline); TickUnread = $Tick -lt 0 }
}

# The outer half's series port: the watch's stop and counts, and the session's tick.
function New-FramePacingSeriesPort {
    $port = [pscustomobject]@{ Kind = 'series' }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name StopWatch -Value { [FramePacingNative]::StopWatch() }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name RealInputs -Value { [FramePacingNative]::RealInputs() }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name InjectedInputs -Value { [FramePacingNative]::InjectedInputs() }
    Add-Member -InputObject $port -MemberType ScriptMethod -Name LastInputTick -Value { param($Ticks) (Read-FramePacingInputTick $Ticks).Tick }
    return $port
}

# One run: a fresh copy, payload, config, desktop (dry run) and job; the driver; the guards; the record's verdict.
function Invoke-FramePacingOuterRun($build, [string] $Run, [long] $QuietSince, [string] $WatchEvent, [long] $LockNeededMs, [long] $InputMarker) {
    $stagingClock = [Diagnostics.Stopwatch]::StartNew()
    $source = $build.Bin
    $copy = Join-Path $Run 'copy'
    $work = Join-Path $Run 'work'
    # Staging. A failure here (CodeRabbit on #741: the build replaced mid-series fails the copy's receipt check) is a
    # failed run before any launch, so the series still writes diagnostics.json with the runs before it.
    try {
        [void](New-Item -ItemType Directory -Path $Run)
        foreach ($name in @('localappdata', 'appdata', 'temp', 'work')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
        [void](New-Item -ItemType Directory -Path $copy)
        Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -notin @('noctty.ico', 'crash', 'ghostty') } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $copy $_.Name) -Recurse }
        if (-not (Test-Path -LiteralPath (Join-Path $copy 'share')) -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $source) 'share'))) {
            Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $source) 'share') -Destination (Join-Path $copy 'share') -Recurse
        }
        if (Test-Path -LiteralPath (Join-Path $copy 'noctty.ico')) { throw 'The copy must not carry noctty.ico beside its exe.' }
        if (-not (Test-WorkingSetCopy $copy $build)) { throw 'The copied noctty.exe or noctty.com does not match the receipt.' }
        [IO.File]::WriteAllText((Join-Path $copy 'noctty.portable'), '')
        $marker = 'NB' + [guid]::NewGuid().ToString('N').Substring(0, 16)
        [IO.File]::WriteAllText((Join-Path $work 'marker.txt'), $marker)
        Write-FramePacingPayload (Join-Path $work 'stream.bin') $marker
        [IO.File]::WriteAllText((Join-Path $copy 'config.ghostty'), (New-FramePacingConfigText $Run), $script:Utf8)
    } catch {
        return [pscustomobject]@{ Run = $Run; Status = 'failed'; Failures = @("staging failed before any launch: $($_.Exception.Message)"); Record = $null }
    }

    $realLocal = [Environment]::GetFolderPath('LocalApplicationData')
    $realDirs = @($realLocal, [Environment]::GetFolderPath('ApplicationData'), [IO.Path]::GetTempPath()) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    $sessionPath = Join-Path $realLocal 'noctty\session-state.json'
    $sessionBefore = Get-Metadata $sessionPath
    $stateGuard = Start-InteractiveWin11StateGuard -Harness 'bench-frame-pacing' -ReceiptDirectory $Run
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'bench-frame-pacing.ps1'

    $sandboxName = 'fp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $desktop = [IntPtr]::Zero
    if ($Visible) { $desktopName = 'Default' }
    else {
        $desktopName = 'noctty-fp-' + [guid]::NewGuid().ToString('N')
        $desktop = [HiddenLocal]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
        if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    }
    $saved = @{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $pi = $null; $job = [IntPtr]::Zero; $driverExit = $null; $cleanup = $null; $outerError = $null; $ownedProcesses = $null; $notLaunched = $null; $inputStopped = $null
    $state = -1; $latchToKillMs = $null; $observed = [long]0
    $outerTicks = [ordered]@{ Series = $QuietSince; Unlock = $null; Broken = $false; Checks = [Collections.Generic.List[object]]::new() }
    $frequency = [FramePacingNative]::PerformanceFrequency()
    Write-Host "frame-pacing run: $(if ($Visible) { 'visible' } else { 'dry run' }); evidence=$Run"
    try {
        $job = [FramePacingNative]::CreateRunJob()
        $env:LOCALAPPDATA = Join-Path $Run 'localappdata'; $env:APPDATA = Join-Path $Run 'appdata'
        $env:TEMP = Join-Path $Run 'temp'; $env:TMP = $env:TEMP
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Driver -MeasureRepo "{2}" -Bin "{3}" -Run "{4}" -ExpectedBuildMode {5} -SandboxName {6} -DesktopName {7} -QuietWaitSeconds {8} -QuietSinceTick {9}' -f `
            $pwsh, $PSCommandPath, $build.Repo, $copy, $Run, $ExpectedBuildMode, $sandboxName, $desktopName, $QuietWaitSeconds, $QuietSince
        if ($Visible) { $line += " -Visible -InputWatchEvent $WatchEvent -ForegroundLockNeededMs $LockNeededMs -InputMarker $InputMarker" }
        # A visible run's staging and guard setup inside their bound, which the lock bound counts on (Sol on #741),
        # then the input gate before the driver too, though it has no window (CodeRabbit and Opus on #741): a user who
        # came back while the run was staged gets nothing started on Default.
        if ($Visible -and $stagingClock.ElapsedMilliseconds -gt $script:StagingBoundMs) { $notLaunched = "the run's staging and guard setup took $($stagingClock.ElapsedMilliseconds) ms, over the $($script:StagingBoundMs) ms the foreground-lock bound allows" }
        if ($Visible -and -not $notLaunched) {
            $notLaunched = Test-FramePacingInputGate (New-FramePacingOuterPort) $outerTicks 'the visible driver''s launch'
        }
        if ($notLaunched) { throw "INCONCLUSIVE: $notLaunched." }
        $pi = [FramePacingNative]::LaunchDriver($pwsh, $line, $Run, "WinSta0\$desktopName", $job, [bool]$Visible)
        # The driver runs in this run's own job (Sol on #741), checked again from this side.
        if (-not [FramePacingNative]::InJobOf($pi.process, $job)) { [FramePacingNative]::Terminate($pi.process, 1); throw 'The driver is not in the run''s own job.' }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        # The deadline on a monotonic clock (CodeRabbit on #741): a wall clock stepped back would stretch it.
        $driverClock = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            [long]$observed = 0; [long]$closed = 0
            $state = [FramePacingNative]::SuperviseDriver($pi.process, $job, 1000, [ref]$observed, [ref]$closed)
            if ($state -eq 1 -or $state -eq 2) {
                # Real input the hooks saw (the lead on #741, round 5): SuperviseDriver terminated the run's job the
                # moment it saw the latch, with no grace, which ends the driver and the copy wherever the driver is.
                # Here the job's processes are waited out and its handle closed; LatchToKillMs runs from the
                # observation until then (Sol on #741, round 6), when no process of the run is left.
                if ($state -eq 2) { $cleanup = 'TerminateJobObject failed when the real-input latch was observed' }
                try { $ownedProcesses = [HiddenLocal]::StopOwnedJob($job); if ($state -eq 1 -and $frequency -gt 0) { $latchToKillMs = [Math]::Round(([FramePacingNative]::PerformanceCounter() - $observed) * 1000.0 / $frequency, 3) } } catch { if (-not $cleanup) { $cleanup = $_.Exception.Message } } finally { $job = [IntPtr]::Zero }
                [void][HiddenLocal]::WaitForSingleObject($pi.process, 5000)
                break
            }
            if ($state -eq 0) { break }
            if ($state -ne 0x102) { throw 'The wait on the driver failed.' }
            if ($driverClock.ElapsedMilliseconds -ge $script:DriverDeadlineMs) { throw 'The driver ran past 30 minutes; the owned job was closed.' }
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
        if ($desktop -ne [IntPtr]::Zero) { [void][HiddenLocal]::CloseDesktop($desktop) }
    }
    # Real input stops the run whatever the driver's exit says (the lead on #741, round 5): the latch seen during the
    # run, or input the hooks counted by now, after the driver ended.
    $inputStopped = Get-FramePacingSupervisionStop $state $(if ($Visible) { [FramePacingNative]::RealInputs() } else { [long]0 })
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
        OwnedJobProcesses = $ownedProcesses; OwnedJobCleanup = $cleanup; DriverExit = $driverExit; LatchToKillMs = $latchToKillMs
    }
    $guards | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Run 'guards.json') -Encoding utf8NoBOM
    Write-Host (Format-InteractiveWin11ClipboardReading $guards.ClipboardSequenceBefore $guards.ClipboardSequenceAfter)
    $guardFailures = @()
    if ($stateFailure) { $guardFailures += $stateFailure }
    if (-not $guards.SessionUnchanged) { $guardFailures += 'the real session-state.json changed' }
    if ($historyFailure) { $guardFailures += $historyFailure }
    # What the outer half itself saw go wrong, and what it checks of the record whatever the run's outcome: the mode,
    # where the copy ran from (each directory inside the run, none a real one) and, once it launched, its config file.
    $outerFailures = @()
    if ($cleanup) { $outerFailures += "owned job cleanup: $cleanup" }
    if ($outerError) { $outerFailures += $outerError }
    if ($driverExit -eq 3) { $outerFailures += "the copy's build mode is not $ExpectedBuildMode; it was not launched" }
    $recordPath = Join-Path $Run 'run.json'
    # A record the job's close cut short (Opus on #741, round 5) reads as none: a run stopped for real input is then
    # inconclusive (Get-FramePacingInputStop), any other run failed with the reason, and the series still writes its
    # summary.
    $read = Read-FramePacingRunRecord $recordPath
    $record = $read.Record
    if ($read.Problem -and -not $inputStopped) { $outerFailures += $read.Problem }
    # The session's tick after the run (the lead and Sol on #741, round 6): anything but the last tick the harness's
    # own marked input left (the probe's, else the unlock's, else the series') is input the hooks did not see, and
    # stops the run like theirs.
    if ($Visible -and -not $inputStopped -and $null -ne $record) {
        $afterTicks = [ordered]@{ Series = $(if ($null -ne $record.InputTicks -and $null -ne $record.InputTicks.Unlock) { [long]$record.InputTicks.Unlock } else { $QuietSince }); Unlock = $null; Broken = $false }
        $afterRun = Read-FramePacingInputTick $afterTicks
        $inputStopped = Get-FramePacingTickStop $afterRun.Tick ([long]$afterTicks.Series)
    }
    if ($null -ne $record) {
        $wantMode = if ($Visible) { 'visible' } else { 'dry-run' }
        if (-not [string]::Equals([string]$record.Mode, $wantMode, [StringComparison]::Ordinal)) { $outerFailures += "mode $($record.Mode), not $wantMode" }
        if ($record.LaunchConfigFile -and -not [string]::Equals([string]$record.LaunchConfigFile, (Join-Path $copy 'config.ghostty'), [StringComparison]::OrdinalIgnoreCase)) { $outerFailures += "the copy's config file was not its own generated one" }
        if ($null -ne $record.EffectiveDirs) {
            foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) {
                $dir = [string]$record.EffectiveDirs.$name
                if (-not $dir -or -not ($dir.TrimEnd('\') + '\').StartsWith($Run.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or @($realDirs | Where-Object { [string]::Equals($_, $dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                    $outerFailures += "the copy's $name was not the run's own"
                }
            }
        } else { $outerFailures += 'no effective directories' }
    }
    $problems = @(Get-FramePacingRecordProblems $record)
    $driverError = if ($null -ne $record -and $record.Error) { [string]$record.Error } else { $null }
    $status = Get-FramePacingRunStatus @($guardFailures) @($outerFailures) $driverExit $driverError @($problems)
    $stop = if ($notLaunched) { "the visible driver was not launched: $notLaunched" } elseif ($inputStopped) { $inputStopped } else { $null }
    $stopFailure = Get-FramePacingInputStop $guardFailures $outerFailures $(if ($notLaunched) { $outerError } else { $null }) $stop (Test-FramePacingHookMissed $driverError)
    if ($stopFailure) { $status = 'inconclusive'; $outerFailures = @($stopFailure); $problems = @() }
    # The run's own input latch, which the series ORs with its final reads (the lead and Sol on #741, round 8).
    $inputSeen = Test-FramePacingRunInput ([bool]$inputStopped -or [bool]$outerTicks.Broken) $record
    return [pscustomobject]@{ Run = $Run; Status = $status; Failures = @($guardFailures + $outerFailures + $problems); Record = $record; InputSeen = $inputSeen }
}

# Whether a run saw input (the lead and Sol on #741, round 8): the outer half's own stop or gate break, or any break
# the driver latched in its record (InputTicks.Broken: a gate, a poll or a native worker that saw input). A later
# read that matched never clears it. Pure, so the contract tables it.
function Test-FramePacingRunInput([bool] $OuterSaw, $Record) {
    if ($OuterSaw) { return $true }
    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties['InputTicks'] -or $null -eq $Record.InputTicks) { return $false }
    $broken = $Record.InputTicks.PSObject.Properties['Broken']
    return $null -ne $broken -and [bool]$broken.Value
}

# Why the outer half stops a run for real input, or null (the lead on #741, round 5). $State is SuperviseDriver's last
# result: 1 the latch seen and the run's job closed at once (the delay goes to guards.json only, Sol on #741, round 8),
# 2 the latch seen and the close failed. Otherwise any real input the hooks counted in the series by the time the
# driver's end was read stops the run too, whatever the driver's exit says: a driver that ended cleanly after the
# user came back publishes nothing. Pure, so the contract tables it.
function Get-FramePacingSupervisionStop([int] $State, [long] $RealInputs) {
    if ($State -eq 1) { return "real (non-injected) keyboard or mouse input came during the run; the outer half closed the run's job when it observed the input (guards.json records the delay)" }
    if ($State -eq 2) { return "real (non-injected) keyboard or mouse input came during the run, and closing the run's job failed" }
    if ($RealInputs -ne 0) { return "real (non-injected) keyboard or mouse input came during the series ($RealInputs events) by the time this run's driver ended; the run stops whatever the driver's exit says" }
    return $null
}

# Input the hooks did not see, from the session's last-input tick (the lead and Sol on #741, round 6): a tick other
# than $Expected, the last one the harness's own marked input left, or an unreadable one, stops the run or the series.
# Returns the stop line, or null. Pure, so the contract tables it.
function Get-FramePacingTickStop([long] $Tick, [long] $Expected) {
    if ($Tick -ge 0 -and $Tick -eq $Expected) { return $null }
    return "the session's last-input tick moved ($Expected to $Tick) with no input the hooks saw as real (a software KVM, an elevated window); the run stops whatever the driver's exit says"
}

# A run's record, run.json: [pscustomobject] Record (null when the file is missing or does not parse) and Problem
# (why it did not parse, or null). The driver writes it last, and a job closed on real input can cut that write short
# (Opus on #741, round 5). Pure but for the read, so the contract tables it.
function Read-FramePacingRunRecord([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Record = $null; Problem = $null } }
    try { return [pscustomobject]@{ Record = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop); Problem = $null } }
    catch { return [pscustomobject]@{ Record = $null; Problem = "the run's record could not be read: $($_.Exception.Message)" } }
}

# The hooks' silence after a run (Opus and CodeRabbit on #741): a visible run whose foreground was "ok" sent one
# marked unlock, which the mouse hook must have counted, and one whose key probe was "ok" one marked key, which the
# keyboard hook must have; a count of its kind that did not move means that hook may have been removed (Windows drops
# a low-level hook that times out, without notice), and the series stops. A run whose foreground was taken owes the
# keyboard probe too (Opus on #741, round 5): a probe that did not come back "ok" leaves the keyboard hook unproven,
# unless real input ($RealInputs, the series' count) stopped the run first. Returns [pscustomobject] Line and Removed
# (a count that did not move: the hook may be gone, which fails the run; an unproven hook leaves the run's own
# status, never worse than inconclusive: Get-FramePacingSilencedStatus), or null. Pure, so the contract tables it.
function Get-FramePacingHookSilence($Record, [long] $MouseBefore, [long] $MouseAfter, [long] $KeyBefore, [long] $KeyAfter, [long] $RealInputs) {
    if ($null -eq $Record) { return $null }
    $field = { param([string] $Name) $property = $Record.PSObject.Properties[$Name]; if ($null -ne $property) { [string]$property.Value } else { '' } }
    # A driver that refused the run because the keyboard hook missed its probe has already failed it with that reason
    # (Opus on #741, rounds 8 and 10): no second line calls the run inconclusive or the sent probe "not sent". After a
    # mouse-hook miss the foreground was never taken, so no probe was owed.
    if ([string]::Equals((& $field 'Error'), $script:KeyHookMissed, [StringComparison]::Ordinal)) { return $null }
    $foregroundTaken = [string]::Equals((& $field 'Foreground'), 'ok', [StringComparison]::Ordinal)
    $probed = [string]::Equals((& $field 'KeyProbe'), 'ok', [StringComparison]::Ordinal)
    if ($foregroundTaken -and $MouseAfter -le $MouseBefore) { return [pscustomobject]@{ Removed = $true; Line = "the input watch's mouse hook did not count the run's own marked unlock (count $MouseBefore, then $MouseAfter), so it may have been removed; the series stops" } }
    if ($foregroundTaken -and -not $probed -and $RealInputs -eq 0) {
        # The cause, as the driver recorded it (Opus on #741, round 6): a refusal, or input the hooks did not see.
        $probe = & $field 'KeyProbe'; $why = & $field 'Error'
        return [pscustomobject]@{ Removed = $false; Line = "inconclusive: the copy was in front but the keyboard probe was $(if ($probe) { "'$probe'" } else { 'not sent' })$(if ($why) { " ($why)" }), so the input watch's keyboard hook has no proof of life for the run; the series stops" }
    }
    if ($probed -and $KeyAfter -le $KeyBefore) { return [pscustomobject]@{ Removed = $true; Line = "the input watch's keyboard hook did not count the run's own marked key probe (count $KeyBefore, then $KeyAfter), so it may have been removed; the series stops" } }
    return $null
}

# A run's status after the hooks' silence check (Sol on #741, round 6): a tripped guard stays; a hook that may have
# been removed fails the run; an unproven keyboard hook (a probe refused or never sent) leaves an inconclusive or
# failed run as it was and makes a complete one inconclusive, never failed. Pure, so the contract tables it.
function Get-FramePacingSilencedStatus([string] $Status, $Silence) {
    if ($null -eq $Silence -or [string]::Equals($Status, 'guard-tripped', [StringComparison]::Ordinal)) { return $Status }
    if ($Silence.Removed) { return 'failed' }
    if ([string]::Equals($Status, 'complete', [StringComparison]::Ordinal)) { return 'inconclusive' }
    return $Status
}

# A visible run stopped for the session's sake (a driver the gate or the staging bound kept from launching, or one
# whose job the outer half closed on real input) is inconclusive only when that stop was the run's sole problem
# (CodeRabbit on #741): a tripped guard still wins, and an outer failure beside it, such as an owned-job cleanup that
# failed, keeps the run failed with that failure on record. So does a driver that refused the run because a hook
# missed the harness's own marked input ($HookMissed, Greptile on #741): input after that is no reason to call a
# possibly removed hook inconclusive. The one outer failure that may stand beside a stop is the deliberate no-launch
# refusal ($NoLaunchRefusal, the outer half's own INCONCLUSIVE throw before any launch): any other outer error, such as
# the driver's deadline, keeps the run failed even when input came during its cleanup (CodeRabbit on #741). Returns
# the run's one failure line, or null when Get-FramePacingRunStatus's status stands. Pure, so the contract tables it.
function Get-FramePacingInputStop([string[]] $GuardFailures, [string[]] $OuterFailures, [string] $NoLaunchRefusal, [string] $Stop, [bool] $HookMissed) {
    if (-not $Stop -or $HookMissed -or @($GuardFailures).Count -gt 0) { return $null }
    if (@($OuterFailures | Where-Object { -not [string]::Equals($_, $NoLaunchRefusal, [StringComparison]::Ordinal) }).Count -gt 0) { return $null }
    return "inconclusive: $Stop"
}

# Whether a driver refused its run because a hook missed the harness's own marked input (Greptile on #741). Pure.
function Test-FramePacingHookMissed([string] $DriverError) {
    return [string]::Equals($DriverError, $script:MouseHookMissed, [StringComparison]::Ordinal) -or [string]::Equals($DriverError, $script:KeyHookMissed, [StringComparison]::Ordinal)
}

# A run's status: a tripped guard first, then the outer half's own failures; a driver that exited 2 with an
# INCONCLUSIVE error is inconclusive (its record may lack what an aborted run never measured); any other nonzero exit,
# or any record problem that is not the visible run's environment, fails the run; a record whose only problems are the
# environment's is inconclusive. Pure, so the contract can run it.
function Get-FramePacingRunStatus([string[]] $GuardFailures, [string[]] $OuterFailures, $DriverExit, [string] $DriverError, [string[]] $Problems) {
    if (@($GuardFailures).Count -gt 0) { return 'guard-tripped' }
    if (@($OuterFailures).Count -gt 0) { return 'failed' }
    if ($DriverExit -eq 2 -and $DriverError -and $DriverError.StartsWith('INCONCLUSIVE:', [StringComparison]::Ordinal)) { return 'inconclusive' }
    if ($null -eq $DriverExit -or $DriverExit -ne 0) { return 'failed' }
    $soft = @($Problems | Where-Object { ([string]$_).StartsWith('inconclusive:', [StringComparison]::Ordinal) })
    if ($soft.Count -ne @($Problems).Count) { return 'failed' }
    if ($soft.Count -gt 0) { return 'inconclusive' }
    return 'complete'
}

# The completed runs' statistics (Greptile, CodeRabbit, Sol and Opus on #741): each comparability group's own
# intervals, p95 and median (a group is every run alike in all nine key fields below, never combined across them, not
# even for diagnostics), and one pool only when every run is comparable. The environment must match (the display
# mode, the DPI and the grid: a difference makes the series inconclusive) and so must the build and workload
# (WorkloadSha256, the app's SHA-256, the renderer, the transport and both ConPTY digests: a difference fails the
# series); otherwise nothing is pooled. Pure, so the contract can run it.
function Get-FramePacingSeries([object[]] $Records) {
    $value = { param($Record, [string] $Field) if ($Field -eq 'Grid') { '{0}x{1}' -f $Record.GridCols, $Record.GridRows } else { [string]$Record.$Field } }
    $mixedEnvironment = @(foreach ($field in @('DisplayMode', 'Dpi', 'Grid')) { if (@($Records | ForEach-Object { & $value $_ $field } | Select-Object -Unique).Count -gt 1) { $field } })
    $mixedBuild = @(foreach ($field in @('WorkloadSha256', 'ExeSHA256', 'Renderer', 'Transport', 'ConptyDllSHA256', 'OpenConsoleSHA256')) { if (@($Records | ForEach-Object { & $value $_ $field } | Select-Object -Unique).Count -gt 1) { $field } })
    $modes = @($Records | ForEach-Object { [string]$_.DisplayMode } | Select-Object -Unique)
    $workloads = @($Records | ForEach-Object { [string]$_.WorkloadSha256 } | Select-Object -Unique)
    $keyFields = @('DisplayMode', 'Dpi', 'Grid', 'WorkloadSha256', 'ExeSHA256', 'Renderer', 'Transport', 'ConptyDllSHA256', 'OpenConsoleSHA256')
    $keyOf = { param($Record) (@(foreach ($field in $keyFields) { '{0}={1}' -f $field, (& $value $Record $field) }) -join ';') }
    $keys = @($Records | ForEach-Object { & $keyOf $_ } | Select-Object -Unique)
    $groups = @(foreach ($key in $keys) {
            $runs = @($Records | Where-Object { [string]::Equals((& $keyOf $_), $key, [StringComparison]::Ordinal) })
            $first = $runs[0]
            $intervals = [double[]]@($runs | ForEach-Object { @($_.IntervalsMs) } | ForEach-Object { [double]$_ })
            [ordered]@{ display_mode = [string]$first.DisplayMode; dpi = $first.Dpi; grid = (& $value $first 'Grid'); workload = [string]$first.WorkloadSha256
                exe = [string]$first.ExeSHA256; renderer = [string]$first.Renderer; transport = [string]$first.Transport
                conpty = [string]$first.ConptyDllSHA256; openconsole = [string]$first.OpenConsoleSHA256; runs = $runs.Count; intervals = $intervals.Count
                p95_ms = $(if ($intervals.Count -gt 0) { [Math]::Round((Get-BenchPercentile -Samples $intervals -Percentile 95), 6) } else { $null })
                median_ms = $(if ($intervals.Count -gt 0) { [Math]::Round((Get-BenchMedian -Samples $intervals), 6) } else { $null }) }
        })
    # A typed array, never an `if` statement's output: an empty pool from an `if` unwraps to $null, and StrictMode then
    # throws on .Count before pacing.json is written (Greptile on #741).
    [double[]]$pooled = @(if ($mixedEnvironment.Count -eq 0 -and $mixedBuild.Count -eq 0) { $Records | ForEach-Object { @($_.IntervalsMs) } | ForEach-Object { [double]$_ } })
    return [pscustomobject]@{
        Modes = $modes; Workloads = $workloads; Groups = $groups; Pooled = $pooled; Mixed = $modes.Count -gt 1
        MixedEnvironment = $mixedEnvironment; MixedBuild = $mixedBuild
        P95 = $(if ($pooled.Count -gt 0) { [Math]::Round((Get-BenchPercentile -Samples $pooled -Percentile 95), 6) } else { $null })
        Median = $(if ($pooled.Count -gt 0) { [Math]::Round((Get-BenchMedian -Samples $pooled), 6) } else { $null })
    }
}

# The summary over the series, pacing.json in the run root: each run's status and statistics, each comparability
# group's, and the pooled nearest-rank p95 over the completed runs when they are comparable (Get-FramePacingSeries),
# with the counts of real and injected input events the visible series' hooks saw ($RealInputs, $InjectedInputs; null
# in a dry run).
# frame_time_p95_ms and its median are published only for a visible series whose every run completed and whose runs
# are comparable; a passing dry run has them null, a series that does not pass has them absent (its pacing.json is the
# allowlist), and the console says no measurement was published (Sol and CodeRabbit on #741). A dry run gives
# dry_run_p95_ms, not a measurement. Any timing statistic is written only when the series' verdict is a pass, exit 0
# (the lead and Sol on #744, round 2). Returns Get-FramePacingExitCode's code.
function Write-FramePacingSummary([string] $Root, $Build, [object[]] $Results, $RealInputs, $InjectedInputs, [bool] $TickMoved, [bool] $TickUnread, [string] $HarnessSha256) {
    $completed = @($Results | Where-Object { [string]::Equals($_.Status, 'complete', [StringComparison]::Ordinal) })
    $series = Get-FramePacingSeries @($completed | ForEach-Object { $_.Record })
    # Real input at any point in a visible series (the lead on #741, round 5) makes it inconclusive and publishes
    # nothing, whatever each run's status says; a count that was not read counts as input.
    # Each run's own latch counts too (the lead and Sol on #741, round 8): input any run saw stays seen, whatever the
    # final reads say.
    $inputRuns = @($Results | Where-Object { $null -ne $_.PSObject.Properties['InputSeen'] -and [bool]$_.InputSeen } | ForEach-Object { Split-Path -Leaf $_.Run })
    $inputSeen = $Visible -and ($null -eq $RealInputs -or [long]$RealInputs -ne 0 -or $TickMoved -or $inputRuns.Count -gt 0)
    # A driver that ran other bytes than the series started with voids it too, in either mode (Sol on #741, round 10),
    # and so does a series with no hash of its own to compare against: it fails closed (Opus on #744).
    $harnessChanged = [string]::IsNullOrEmpty($HarnessSha256) -or (Test-FramePacingHarnessChanged $Results $HarnessSha256)
    $voided = $inputSeen -or $harnessChanged
    # Nor does its pacing.json carry any other timing statistic or duration (Sol on #741, rounds 7 to 9): a voided
    # series writes pacing.json from the allowlist below, and the full summary, statistics included, to diagnostics.json.
    $publish = $Visible -and -not $voided -and $completed.Count -eq $Runs -and $series.Pooled.Count -gt 0 -and @($series.MixedEnvironment).Count -eq 0 -and @($series.MixedBuild).Count -eq 0
    $summary = [ordered]@{
        Schema = 1; Mode = $(if ($Visible) { 'visible' } else { 'dry-run' }); Measurement = [bool]$Visible
        RunsRequested = $Runs; RunsCompleted = $completed.Count; MeasureHead = $Build.Head; ExeSHA256 = $Build.ExeSha256
        WorkloadSha256 = $(if (@($series.Workloads).Count -eq 1) { @($series.Workloads)[0] } else { $null })
        DisplayModes = @($series.Modes); Groups = @($series.Groups)
        HarnessSha256 = $HarnessSha256; RealInputsSeen = $RealInputs; InjectedInputsSeen = $InjectedInputs; TickMovedFromBaseline = $(if ($Visible) { $TickMoved } else { $null })
        PooledIntervals = $series.Pooled.Count; Aggregation = 'nearest-rank p95 over the pooled intervals of the completed runs, all alike in the nine comparability fields'
        frame_time_p95_ms = $(if ($publish) { $series.P95 } else { $null })
        frame_time_median_ms = $(if ($publish) { $series.Median } else { $null })
        dry_run_p95_ms = $(if (-not $Visible -and -not $voided -and $series.Pooled.Count -gt 0) { $series.P95 } else { $null })
        Runs = @($Results | ForEach-Object { [ordered]@{ run = (Split-Path -Leaf $_.Run); status = $_.Status; failures = @($_.Failures); display_mode = $(if ($_.Record) { $_.Record.DisplayMode } else { $null }); intervals = $(if ($_.Record) { $_.Record.IntervalCount } else { 0 }); p95_ms = $(if ($_.Record) { $_.Record.P95Ms } else { $null }) } })
    }
    if (@($series.MixedBuild).Count -gt 0) { $summary.Error = "the completed runs differ in $(@($series.MixedBuild) -join ', ')" }
    if ($harnessChanged) { $summary.Error = (@($(if ($summary.Contains('Error')) { $summary.Error }), 'a run''s driver ran other harness bytes than the series started with') | Where-Object { $_ }) -join '; ' }
    $inconclusive = @()
    if (@($series.MixedEnvironment).Count -gt 0) { $inconclusive += "the completed runs differ in $(@($series.MixedEnvironment) -join ', ') ($(@($series.Modes) -join ', ')); each comparability group is reported in Groups and none is pooled" }
    if ($inputSeen) {
        # What voided it, by observation (Sol on #741, round 7).
        $voids = @()
        $counted = $null -ne $RealInputs -and [long]$RealInputs -ne 0
        if ($null -eq $RealInputs) { $voids += 'the input watch did not stop, so its count could not be read' }
        elseif ($counted) { $voids += "hook count $RealInputs" }
        # One input can move both the count and the tick, and the harness has no event identity to tell them apart
        # (Sol on #741, round 8), so a tick beside a count is not claimed as a second source.
        if ($TickUnread) { $voids += 'the session''s last-input tick could not be read' }
        elseif ($TickMoved -and $counted) { $voids += 'tick also moved (may be the same input)' }
        elseif ($TickMoved) { $voids += 'the session''s last-input tick left the series'' baseline with no input the hooks counted as real' }
        if ($inputRuns.Count -gt 0) { $voids += "input seen during $($inputRuns -join ', ')" }
        $inconclusive += "input voided the series: $($voids -join '; '); no measurement and no timing statistic is published"
    }
    if ($inconclusive.Count -gt 0) { $summary.Inconclusive = $inconclusive -join '; ' }
    $exitCode = Get-FramePacingExitCode @($Results | ForEach-Object { [string]$_.Status }) $summary.Contains('Error') $summary.Contains('Inconclusive') $completed.Count $Runs
    # Timing only for a pass (the lead and Sol on #744, round 2): a failure (exit 1), an inconclusive series (2) or a
    # tripped guard (3) withholds every timing statistic, like a series input or a changed harness voided. A driver
    # that ran changed text and left no readable record fails its run, and the earlier runs' timing must not stand for
    # the series. A dry run's dry_run_p95_ms is a clean dry run's alone, in either file.
    $withheld = $voided -or $exitCode -ne 0
    $diagnosticsFailure = $null
    if ($withheld) {
        # A withheld series writes pacing.json from an allowlist, not by scrubbing (the lead and Sol on #741, round 9):
        # the schema, the verdict (voided for input or a changed harness, else the exit's), the exit code, reason codes
        # from a fixed set (no text, no numbers), the input counts, the series' id and the harness's and measurement's
        # identities. Everything else, every message, duration and run, goes to diagnostics.json beside it.
        $allowed = [ordered]@{
            Schema = 1; Verdict = $(if ($voided) { 'voided' } elseif ($exitCode -eq 3) { 'guard-tripped' } elseif ($exitCode -eq 2) { 'inconclusive' } else { 'failed' }); ExitCode = $exitCode
            Reasons = @(Get-FramePacingVoidReasons $Results $RealInputs $TickMoved $TickUnread $inputRuns.Count (@($series.MixedBuild).Count -gt 0) (@($series.MixedEnvironment).Count -gt 0) $completed.Count $harnessChanged)
            RealInputsSeen = $RealInputs; InjectedInputsSeen = $InjectedInputs; SeriesId = (Split-Path -Leaf $Root)
            HarnessSha256 = $HarnessSha256; MeasureHead = $Build.Head; ExeSHA256 = $Build.ExeSha256
        }
        try { $allowed | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $Root 'pacing.json') -Encoding utf8NoBOM }
        finally {
            # The verdict first, then its details, whether or not the verdict was written (Sol on #744, rounds 3 and 4):
            # a pacing.json that cannot be written still throws as before, after diagnostics.json keeps the series'
            # exit code and statistics; a diagnostics.json that cannot be written is a warning on the console line,
            # never a changed verdict or exit code.
            $summary.ExitCode = $exitCode
            $summary.dry_run_p95_ms = $null
            try { $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Root 'diagnostics.json') -Encoding utf8NoBOM -ErrorAction Stop }
            catch { $diagnosticsFailure = $_.Exception.Message }
        }
    } else {
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Root 'pacing.json') -Encoding utf8NoBOM
    }
    $last = $Results[$Results.Count - 1]
    foreach ($failure in @($last.Failures)) { Write-Host "  $failure" }
    if ($summary.Contains('Inconclusive')) { Write-Host "  $($summary.Inconclusive)" }
    $label = if ($Visible) { if ($null -ne $summary.frame_time_p95_ms) { "frame_time_p95_ms $($summary.frame_time_p95_ms)" } else { 'no measurement published' } }
        elseif ($null -ne $summary.dry_run_p95_ms) { "dry run: dry_run_p95_ms $($summary.dry_run_p95_ms) (not a measurement)" } elseif ($withheld) { 'dry run: no timing published' } else { 'dry run: no pooled intervals' }
    $details = if (-not $withheld) { '' } elseif ($null -ne $diagnosticsFailure) { "; warning: diagnostics.json could not be written ($diagnosticsFailure); the verdict and exit code stand" } else { "; diagnostics=$(Join-Path $Root 'diagnostics.json')" }
    Write-Host "frame pacing: $($completed.Count) of $Runs runs complete; $label; summary=$(Join-Path $Root 'pacing.json')$details"
    return $exitCode
}

# The reason codes a withheld series' pacing.json may carry (the lead and Sol on #741, round 9; every verdict but a pass
# since #744, round 2): a fixed set, no text and no numbers.
$script:FramePacingVoidReasons = @('hook-count', 'tick-moved', 'tick-unread', 'watch-not-stopped', 'run-saw-input', 'guard-tripped', 'run-failed', 'run-inconclusive', 'incomplete', 'mixed-build', 'mixed-environment', 'harness-changed')
# A withheld series' reasons, each a member of FramePacingVoidReasons. Not pure: it reads the caller's $Visible (the
# series' mode, which gates the watch and tick reasons); otherwise it reads only its arguments, so the contract tables
# it with $Visible set in the calling scope.
function Get-FramePacingVoidReasons([object[]] $Results, $RealInputs, [bool] $TickMoved, [bool] $TickUnread, [int] $InputRuns, [bool] $MixedBuild, [bool] $MixedEnvironment, [int] $Completed, [bool] $HarnessChanged) {
    $statuses = @($Results | ForEach-Object { [string]$_.Status })
    $reasons = [Collections.Generic.List[string]]::new()
    # The watch and the tick are a visible series' alone (Greptile on #744): a dry run passes no count, and has no
    # watch to have not stopped.
    if ($Visible) {
        if ($null -eq $RealInputs) { $reasons.Add('watch-not-stopped') } elseif ([long]$RealInputs -ne 0) { $reasons.Add('hook-count') }
        if ($TickUnread) { $reasons.Add('tick-unread') } elseif ($TickMoved) { $reasons.Add('tick-moved') }
    }
    if ($InputRuns -gt 0) { $reasons.Add('run-saw-input') }
    if ($statuses -contains 'guard-tripped') { $reasons.Add('guard-tripped') }
    if ($statuses -contains 'failed') { $reasons.Add('run-failed') }
    if ($statuses -contains 'inconclusive') { $reasons.Add('run-inconclusive') }
    if ($Completed -ne $Runs) { $reasons.Add('incomplete') }
    if ($MixedBuild) { $reasons.Add('mixed-build') }
    if ($MixedEnvironment) { $reasons.Add('mixed-environment') }
    if ($HarnessChanged) { $reasons.Add('harness-changed') }
    return [string[]]$reasons.ToArray()
}

# The harness's identity: the SHA-256 of the script text this process parsed and is executing (Sol on #744), never
# the file on disk, which an edit can replace after the load and before a hash of it. The root of any of the script's
# functions' syntax trees is the whole parsed script, held in memory since the load. It covers this file alone, not
# the scripts it dot-sources: it catches an accidental change to bench-frame-pacing.ps1 during a series, and is not a
# seal against tampering.
function Get-FramePacingLoadedHarnessSha256 {
    $ast = ${function:Get-FramePacingLoadedHarnessSha256}.Ast
    while ($null -ne $ast.Parent) { $ast = $ast.Parent }
    return Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($ast.Extent.Text))
}

# Whether any run's driver ran other harness bytes than the series started with (Sol on #741, round 10): a run with a
# record whose HarnessSha256 is missing or differs. Runs with no record (none was launched, or its job was closed
# before it wrote one) carry no hash to compare. Pure, so the contract tables it.
function Test-FramePacingHarnessChanged([object[]] $Results, [string] $SeriesSha256) {
    foreach ($result in @($Results)) {
        if ($null -eq $result.Record) { continue }
        $property = $result.Record.PSObject.Properties['HarnessSha256']
        if ($null -eq $property -or -not [string]::Equals([string]$property.Value, $SeriesSha256, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# The series' exit code, by precedence, highest first (Opus and CodeRabbit on #741): 3 a tripped guard; 1 a failed run
# or a build or workload difference among the completed runs; 2 an inconclusive run or an environment difference; 0
# every run complete and comparable. A series that both trips a guard and fails exits 3. Pure, so the contract tables it.
function Get-FramePacingExitCode([string[]] $Statuses, [bool] $BuildDiffers, [bool] $EnvironmentDiffers, [int] $Completed, [int] $Requested) {
    $has = { param([string] $Status) @($Statuses | Where-Object { [string]::Equals($_, $Status, [StringComparison]::Ordinal) }).Count -gt 0 }
    if (& $has 'guard-tripped') { return 3 }
    if ($BuildDiffers -or (& $has 'failed')) { return 1 }
    if ($EnvironmentDiffers -or (& $has 'inconclusive')) { return 2 }
    if ($Completed -ne $Requested) { return 1 }
    return 0
}

if ($Driver) {
    $code = Invoke-FramePacingDriver | Select-Object -Last 1
    exit $code
}
exit (Invoke-FramePacingOuter | Select-Object -Last 1)
