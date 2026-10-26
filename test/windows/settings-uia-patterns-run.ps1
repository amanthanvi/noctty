<#
.SYNOPSIS
    SET91 hidden-desktop UIA regression runner (no build step).
.DESCRIPTION
    Requires PowerShell 7 and an already staged portable MEASUREMENT build, with
    its AUMID isolated and HKCU registration disabled outside the tracked tree.
    Pass its verified SHA-256. The runner checks the measurement AUMID literal,
    copies the stage into a NEW output directory, and owns only that copy.

    Every child has explicit lpDesktop and CREATE_NO_WINDOW. A kill-on-close job
    owns the worker tree; retained process handles bound each UIA client. No
    desktop switch, global input, Narrator, history contents or clipboard content.
    Real startup/history metadata and clipboard counter bracket the batch.

    Runtime requires -Run. With both cohort counts zero, the original 30 UIA
    cases run. Otherwise ColdOpenCount independent cold opens and ReloadCount
    checkbox Save/fresh-process readbacks run through the same fixture paths.
    Settings opens through the existing host command palette after a distinct new
    portable startup attempt is ready. -RawPostedF9 preserves one raw posted pair
    for reproduction, with a modifier-only async sample at the keydown post.
    An inactive desktop can make that sample zero; it does not prove the
    foreground session's modifiers are up.
    Renderer selects d3d11 (default) or opengl. CPU load remains an external experiment.
    Each launch gets a private NOCTTY_SETTINGS_OPEN_TRACE JSONL path; receipts
    summarize stage tags only and retain the original trace without printing it.
    -RequireTrace asserts a valid route-specific trace and successful Settings dispatch;
    leave it unset for a build without the optional product instrumentation.
    NOCTTY_SETTINGS_COMBO_TRACE separately records native CB_SHOWDROPDOWN
    delivery and return, keyed by control ID. Exercise receipts attach those
    records to the HRESULT and before/returned/100 ms popup observations.
    -RequireComboTrace rejects a missing diagnostic trace and successful enabled
    operations without a native show/return pair for their control.
    Any clipboard sequence change stops launches without attribution.

    Results: summary.json, cases.json, per-control probe JSON, guard snapshots,
    attempts.json and attempt-NNNN.json (stages, HWND identity, startup and trace),
    and task-only portable config. Failures preserve artifacts. No cleanup of
    shared shell state is attempted; guard changes fail the run for inspection.
    Individual attempt receipts are atomically published at each stage; attempts.json
    is a compact receipt index updated at attempt completion/failure. The parent
    stops the owned job after 300 seconds without an updated individual receipt.
    Real Narrator/NVDA and performance measurements remain separate obligations.
.EXAMPLE
    ./settings-uia-patterns-run.ps1 -Run -PortableExe C:/task/stage/noctty.exe `
        -ExpectedExeSha256 <verified-sha256> -OutputDirectory C:/task/set91-run-01
.EXAMPLE
    ./settings-uia-patterns-run.ps1 -CompileOnly
.EXAMPLE
    ./settings-uia-patterns-run.ps1 -TestTraceParser
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $PortableExe,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedExeSha256,
    [string] $OutputDirectory,
    [switch] $Run,
    [ValidateRange(0,10000)][int] $ColdOpenCount = 0,
    [ValidateRange(0,10000)][int] $ReloadCount = 0,
    [switch] $RequireTrace,
    [switch] $RequireComboTrace,
    [switch] $RawPostedF9,
    [ValidateSet('d3d11','opengl')][string] $Renderer = 'd3d11',
    [switch] $CompileOnly,
    [switch] $TestTraceParser,
    [Parameter(DontShow)][string] $WorkerDesktop
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'settings-open-readiness.psm1') -Force
. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
if ($TestTraceParser) { Test-SettingsOpenTraceParser; return }

if (-not ('Set91.Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Set91
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public int X, Y, Width, Height, XChars, YChars, Fill, Flags;
            public short Show, ReservedBytes;
            public IntPtr ReservedPointer, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr Process, Thread; public int Pid, Tid; }
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits
        {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr Minimum, Maximum;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters { public ulong R1, R2, R3, B1, B2, B3; }
        [StructLayout(LayoutKind.Sequential)]
        struct JobLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
        }
        public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
        [StructLayout(LayoutKind.Sequential)]
        struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode,
            uint flags, uint access, IntPtr security);
        [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
        [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool GetUserObjectInformationW(IntPtr obj, int index, StringBuilder text,
            uint bytes, out uint needed);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int count);
        [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y,
            int width, int height, uint flags);
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll", SetLastError = true)]
        static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr w, IntPtr l,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
        static extern IntPtr ReadControlText(IntPtr hwnd, uint message, IntPtr w, StringBuilder text,
            uint flags, uint timeout, out IntPtr result);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSecurity,
            IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string cwd,
            ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr handle, uint ms);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObjectW(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr job, int info, ref JobLimits limits, int bytes);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        static string ObjectName(IntPtr handle)
        {
            var text = new StringBuilder(256);
            uint needed;
            if (!GetUserObjectInformationW(handle, 2, text, 512, out needed))
                throw new InvalidOperationException("Desktop lookup failed");
            return text.ToString();
        }
        public static void AssertDesktop(IntPtr hwnd, string expected)
        {
            int pid;
            uint tid = hwnd == IntPtr.Zero ? GetCurrentThreadId() : GetWindowThreadProcessId(hwnd, out pid);
            if (tid == 0 || expected == "Default" || ObjectName(GetThreadDesktop(tid)) != expected)
                throw new InvalidOperationException("Private desktop mismatch");
        }
        static string ClassName(IntPtr hwnd)
        {
            var text = new StringBuilder(256);
            GetClassNameW(hwnd, text, 256);
            return text.ToString();
        }
        public static IntPtr Top(int pid, string className)
        {
            IntPtr result = IntPtr.Zero;
            EnumWindows((hwnd, data) => {
                int owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner == pid && ClassName(hwnd) == className && IsWindowVisible(hwnd)) result = hwnd;
                return true;
            }, IntPtr.Zero);
            return result;
        }
        public static IntPtr Child(IntPtr parent, int id, string className)
        {
            IntPtr result = IntPtr.Zero;
            EnumChildWindows(parent, (hwnd, data) => {
                if ((id < 0 || GetDlgCtrlID(hwnd) == id) &&
                    (String.IsNullOrEmpty(className) || ClassName(hwnd) == className)) result = hwnd;
                return true;
            }, IntPtr.Zero);
            return result;
        }
        public static long Send(IntPtr hwnd, uint message, long w, long l)
        {
            IntPtr result;
            if (hwnd == IntPtr.Zero || SendMessageTimeoutW(hwnd, message, (IntPtr)w, (IntPtr)l,
                2, 5000, out result) == IntPtr.Zero) throw new InvalidOperationException("Window message timed out");
            return result.ToInt64();
        }
        public sealed class MessageReceipt
        {
            public long Hwnd, Result;
            public uint Message, RequestedTimeoutMilliseconds;
            public bool Sent, Success, FailedOrTimedOut;
            public int Error;
            public int? AsyncModifierMaskAtPost;
            public double ElapsedMilliseconds;
        }
        [DllImport("kernel32.dll", EntryPoint = "SetLastError")] static extern void ClearError(uint error);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        static int AsyncModifiersAtPost()
        {
            // Authorized metadata only: high bits of Shift, Ctrl and Alt, sampled once at posting.
            int mask = 0;
            if ((GetAsyncKeyState(0x10) & 0x8000) != 0) mask |= 1;
            if ((GetAsyncKeyState(0x11) & 0x8000) != 0) mask |= 2;
            if ((GetAsyncKeyState(0x12) & 0x8000) != 0) mask |= 4;
            return mask;
        }
        public static MessageReceipt Message(IntPtr hwnd, uint message, long w, long l, bool sent)
        { return MessageTimeout(hwnd, message, w, l, sent, 5000); }
        static MessageReceipt MessageTimeout(IntPtr hwnd, uint message, long w, long l, bool sent, uint timeout)
        {
            var timer = System.Diagnostics.Stopwatch.StartNew();
            int? modifiers = !sent && message == 0x100 && w == 0x78 ? (int?)AsyncModifiersAtPost() : null;
            ClearError(0);
            IntPtr result = IntPtr.Zero;
            bool ok = sent ? SendMessageTimeoutW(hwnd, message, (IntPtr)w, (IntPtr)l,
                0x23, timeout, out result) != IntPtr.Zero : PostMessageW(hwnd, message, (IntPtr)w, (IntPtr)l);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            return new MessageReceipt { Hwnd = hwnd.ToInt64(), Message = message,
                Result = result.ToInt64(), Sent = sent, Success = ok, Error = error,
                RequestedTimeoutMilliseconds = sent ? timeout : 0, FailedOrTimedOut = !ok,
                AsyncModifierMaskAtPost = modifiers,
                ElapsedMilliseconds = timer.Elapsed.TotalMilliseconds };
        }
        public static MessageReceipt CommandMessage(IntPtr hwnd, uint message, long w, long l)
        { return MessageTimeout(hwnd, message, w, l, true, 15000); }
        public static MessageReceipt SetFixtureQuery(IntPtr hwnd, string query)
        {
            IntPtr text = Marshal.StringToHGlobalUni(query);
            try { return MessageTimeout(hwnd, 0xC, 0, text.ToInt64(), true, 15000); }
            finally { Marshal.FreeHGlobal(text); }
        }
        public static string FixtureControlText(IntPtr hwnd)
        {
            var text = new StringBuilder(2048);
            IntPtr result;
            if (ReadControlText(hwnd, 0xD, (IntPtr)text.Capacity, text, 0x23, 5000, out result) == IntPtr.Zero)
                throw new InvalidOperationException("Fixture control text timed out");
            return text.ToString();
        }
        public sealed class WindowReceipt
        {
            public long Hwnd;
            public int Pid, ControlId;
            public uint Tid;
            public string Class, Desktop;
            public bool Exists, Visible, Enabled;
        }
        public static WindowReceipt Window(IntPtr hwnd)
        {
            int pid;
            uint tid = GetWindowThreadProcessId(hwnd, out pid);
            string desktop = "";
            if (tid != 0) { try { desktop = ObjectName(GetThreadDesktop(tid)); } catch { desktop = "unavailable"; } }
            return new WindowReceipt { Hwnd = hwnd.ToInt64(), Pid = pid, Tid = tid,
                Class = ClassName(hwnd), Desktop = desktop, ControlId = GetDlgCtrlID(hwnd),
                Exists = IsWindow(hwnd), Visible = IsWindowVisible(hwnd), Enabled = IsWindowEnabled(hwnd) };
        }
        public static WindowReceipt[] Windows(int pid)
        {
            var rows = new List<WindowReceipt>();
            EnumWindows((hwnd, data) => {
                int owner;
                GetWindowThreadProcessId(hwnd, out owner);
                if (owner == pid) {
                    rows.Add(Window(hwnd));
                    EnumChildWindows(hwnd, (child, unused) => { rows.Add(Window(child)); return true; }, IntPtr.Zero);
                }
                return true;
            }, IntPtr.Zero);
            return rows.ToArray();
        }
        public static bool FullyClipped(IntPtr hwnd, IntPtr viewport)
        {
            Rect control, clip;
            if (!GetWindowRect(hwnd, out control) || !GetWindowRect(viewport, out clip))
                throw new InvalidOperationException("Control geometry unavailable");
            return control.Bottom <= clip.Top || control.Top >= clip.Bottom ||
                control.Right <= clip.Left || control.Left >= clip.Right;
        }
        public static bool IsCloseButton(IntPtr hwnd)
        {
            // Inspect only this fixture button's bounded caption, never a window title.
            var text = new StringBuilder(32);
            IntPtr result;
            return ReadControlText(hwnd, 0xD, (IntPtr)text.Capacity, text, 2, 2000, out result) != IntPtr.Zero &&
                text.ToString() == "Close";
        }
        public static string Quote(string value)
        {
            // Windows CommandLineToArgvW quoting, including a trailing backslash.
            var text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { text.Append('\\', slashes * 2 + 1); text.Append(c); }
                else { text.Append('\\', slashes); text.Append(c); }
                slashes = 0;
            }
            text.Append('\\', slashes * 2);
            return text.Append('"').ToString();
        }
        public static IntPtr CreateJob()
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            var limits = new JobLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(typeof(JobLimits))))
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(job);
                throw new Win32Exception(error);
            }
            return job;
        }
        public sealed class OwnedProcess : IDisposable
        {
            public IntPtr Handle;
            public int Pid;
            public uint FinalExitCode;
            public bool WasTerminated;
            public uint ExitCode()
            {
                uint code;
                if (!GetExitCodeProcess(Handle, out code)) throw new InvalidOperationException("Process status failed");
                return code;
            }
            public void Dispose()
            {
                if (Handle == IntPtr.Zero) return;
                // Let job termination settle; retain exact ownership if cleanup fails.
                uint wait = WaitForSingleObject(Handle, 5000);
                if (wait == 258)
                {
                    WasTerminated = TerminateProcess(Handle, 1);
                    if (WaitForSingleObject(Handle, 5000) != 0)
                        throw new InvalidOperationException("Owned process termination failed");
                }
                else if (wait != 0) throw new InvalidOperationException("Owned process wait failed");
                FinalExitCode = ExitCode();
                if (!CloseHandle(Handle)) throw new InvalidOperationException("Owned process handle close failed");
                Handle = IntPtr.Zero;
            }
        }
        public static OwnedProcess Launch(string exe, string[] args, string desktop, string cwd, IntPtr job)
        {
            if (String.IsNullOrEmpty(desktop) || desktop == "Default")
                throw new InvalidOperationException("Explicit private desktop required");
            var command = new StringBuilder(Quote(exe));
            foreach (string arg in args) command.Append(' ').Append(Quote(arg));
            var startup = new StartupInfo();
            startup.Size = Marshal.SizeOf(typeof(StartupInfo));
            startup.Desktop = "WinSta0\\" + desktop;
            // Windows are shown normally on the private desktop. SW_HIDE
            // would override the app's first ShowWindow and hide the fixture.
            startup.Flags = 0;
            ProcessInfo info;
            // Suspended until job assignment; every console helper uses CREATE_NO_WINDOW.
            if (!CreateProcessW(exe, command, IntPtr.Zero, IntPtr.Zero, false,
                0x08004004, IntPtr.Zero, cwd, ref startup, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var owned = new OwnedProcess { Handle = info.Process, Pid = info.Pid };
            try
            {
                if (job != IntPtr.Zero && !AssignProcessToJobObject(job, info.Process))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (ResumeThread(info.Thread) == UInt32.MaxValue)
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return owned;
            }
            catch { owned.Dispose(); throw; }
            finally { CloseHandle(info.Thread); }
        }
    }
}
"@
}
$client = Join-Path $PSScriptRoot 'settings-uia-patterns.ps1'
if ($CompileOnly) {
    & $client -CompileOnly
    'SET91 runner and native UIA client: compile-only PASS; runtime NOT RUN'
    return
}
if (-not $Run) { throw 'Runtime requires explicit -Run with verified portable stage parameters; use -CompileOnly otherwise.' }
if (-not $PortableExe -or -not $OutputDirectory -or -not $ExpectedExeSha256) {
    throw 'PortableExe, ExpectedExeSha256 and a new OutputDirectory are required.'
}
function Write-Json([string] $Path, $Value) {
    Write-SettingsOpenReceipt -Path $Path -Value $Value
}
function Assert-Contract([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Get-TraceSummary {
    param([string] $Path, [AllowEmptyCollection()][string[]] $Lines, [AllowEmptyString()][string] $Text)
    # Lines models complete records; Text models a possibly partial writer snapshot, without file access.
    $inMemory = $PSBoundParameters.ContainsKey('Lines') -or $PSBoundParameters.ContainsKey('Text')
    $summary = [ordered]@{ file = [IO.Path]::GetFileName($Path); exists = $inMemory -or [IO.File]::Exists($Path); rows = 0; invalidRows = 0; tags = @{}
        pendingFinalLine = $false; readable = $false; records = [Collections.Generic.List[object]]::new() }
    if (-not $summary.exists) { return $summary }
    try {
        if ($inMemory) {
            if ($PSBoundParameters.ContainsKey('Lines')) { $Text = if ($Lines.Count) { ($Lines -join "`n") + "`n" } else { '' } }
            $summary.bytes = [Text.Encoding]::UTF8.GetByteCount($Text)
        } else {
            # The product retains its writer handle. Read only the bounded length observed at open,
            # sharing writes and atomic replacement/deletion; a subsequent poll takes a fresh snapshot.
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $summary.bytes = $stream.Length
                if ($summary.bytes -le 128KB) {
                    $buffer = [byte[]]::new([int]$summary.bytes)
                    $read = 0
                    while ($read -lt $buffer.Length) {
                        $count = $stream.Read($buffer, $read, $buffer.Length - $read)
                        if ($count -eq 0) { break }
                        $read += $count
                    }
                    $Text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                }
            } finally { $stream.Dispose() }
        }
        if ($summary.bytes -gt 128KB) { $summary.reason = 'summary-size-limit; full trace retained'; return $summary }
        $parsed = ConvertFrom-SettingsOpenTrace -Text $Text
        foreach ($key in $parsed.Keys) { $summary[$key] = $parsed[$key] }
    } catch { $summary.reason = 'trace-summary-unavailable; full trace retained' }
    return $summary
}
function Save-Attempt {
    param([switch] $UpdateIndex)
    if ($null -eq $script:attempt) { return }
    $script:attempt.elapsedMilliseconds = $script:attemptClock.Elapsed.TotalMilliseconds
    $script:attempt.trace = Get-TraceSummary (Join-Path $OutputDirectory $script:attempt.traceFile)
    Write-Json (Join-Path $OutputDirectory ('attempt-{0:D4}.json' -f $script:attempt.index)) $script:attempt
    if ($UpdateIndex) {
        # Compact index only at attempt completion/failure; individual receipts hold the complete stages.
        $index = @(foreach ($item in $script:attempts) {
            [ordered]@{ index = $item.index; pid = $item.pid; stage = $item.stage
                receipt = ('attempt-{0:D4}.json' -f $item.index); elapsedMilliseconds = $item.elapsedMilliseconds }
        })
        Write-Json (Join-Path $OutputDirectory 'attempts.json') $index
    }
}
function Add-Stage([string] $Stage, $Data) {
    if ($null -eq $script:attempt) { return }
    $script:attempt.stage = $Stage
    $script:attempt.stages.Add([ordered]@{ stage = $Stage; utc = [DateTimeOffset]::UtcNow.ToString('o')
        elapsedMilliseconds = $script:attemptClock.Elapsed.TotalMilliseconds; data = $Data })
    Save-Attempt
}
function Save-Diagnostics([string] $Stage, [string] $Reason) {
    if ($null -eq $script:attempt) { return }
    # Preserve the first failing boundary when an outer case or cleanup also catches it.
    if ($script:attempt.Contains('failureStage')) { return }
    $script:attempt.failureStage = $Stage
    $script:attempt.error = $Reason
    if ($null -ne $script:openClock) { $script:attempt.openElapsedMilliseconds = $script:openClock.Elapsed.TotalMilliseconds }
    $script:attempt.startup = Get-NewReadyAttempt -State (Read-StartupAttempt -Path $startupPath) -PreviousStartedAt $script:attempt.previousStartedAt
    $rows = if ($script:process) { @([Set91.Native]::Windows($script:process.Pid)) } else { @() }
    $script:attempt.windows = @($rows)
    $script:attempt.wmNull = @(foreach ($window in $rows) {
        if ($window.Class -in 'noctty.win32.host','noctty.win32','noctty.win32.settings') {
            [Set91.Native]::Message([IntPtr]$window.Hwnd, 0, 0, 0, $true)
        }
    })
    $script:attempt.settingsWindows = @($rows | Where-Object Class -eq 'noctty.win32.settings')
    if ($script:process) {
        $script:attempt.process = [ordered]@{ pid = $script:process.Pid; exitCode = $script:process.ExitCode()
            waitResult = [Set91.Native]::WaitForSingleObject($script:process.Handle, 0) }
    }
    Add-Stage "failure-$Stage" ([ordered]@{ reason = $Reason })
    Save-Attempt -UpdateIndex
}
function Get-WorkerProgressState([string] $Token, [string] $PreviousToken, [double] $ElapsedSeconds,
        [double] $LastProgressSeconds, [double] $LimitSeconds = 300) {
    if ($Token -cne $PreviousToken) { $LastProgressSeconds = $ElapsedSeconds }
    return [ordered]@{ token = $Token; lastProgressSeconds = $LastProgressSeconds
        idleSeconds = $ElapsedSeconds - $LastProgressSeconds
        stalled = ($ElapsedSeconds - $LastProgressSeconds) -ge $LimitSeconds }
}
function Wait-For([scriptblock] $Read, [string] $Description, [int] $Seconds = 15) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-ClipboardGuard
        $value = & $Read
        $ready = if ($value -is [IntPtr]) { $value -ne [IntPtr]::Zero } else { [bool]$value }
        if ($ready) { Add-Stage $Description ([ordered]@{ waitMilliseconds = $watch.Elapsed.TotalMilliseconds }); return $value }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt $Seconds)
    Save-Diagnostics $Description 'stage-timeout'
    throw "Timeout: $Description"
}
function Ctl([IntPtr] $Parent, [int] $Id) {
    $hwnd = [Set91.Native]::Child($Parent, $Id, '')
    Assert-Contract ($hwnd -ne [IntPtr]::Zero) "Missing fixture control $Id"
    [Set91.Native]::AssertDesktop($hwnd, $WorkerDesktop)
    $identity = [Set91.Native]::Window($hwnd)
    Assert-Contract ($identity.Pid -eq $script:process.Pid) 'Control owner mismatch.'
    return $hwnd
}
function Click([IntPtr] $Hwnd) {
    Assert-ClipboardGuard
    [void][Set91.Native]::Send($Hwnd, 0xF5, 0, 0)
}
function Get-GuardSnapshot {
    # Metadata only for the maintainer's noctty profile and history files.
    # Shell jump-list hashes below remain a separate guard.
    $roam = [Environment]::GetFolderPath('ApplicationData')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $paths = [ordered]@{
        startup = Join-Path $local 'noctty/startup-attempts.json'
        psreadline = Join-Path $roam 'Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt'
        documentsHistory = Join-Path $docs 'PowerShell/PSReadLine/ConsoleHost_history.txt'
    }
    $files = foreach ($label in $paths.Keys) {
        $item = Get-Item -LiteralPath $paths[$label] -ErrorAction SilentlyContinue
        if ($item) {
            [ordered]@{ label = $label; exists = $true; bytes = $item.Length
                mtime = $item.LastWriteTimeUtc.Ticks }
        } else { [ordered]@{ label = $label; exists = $false } }
    }
    $destinations = @(Get-ChildItem -LiteralPath (Join-Path $roam 'Microsoft/Windows/Recent/CustomDestinations') `
        -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            [ordered]@{ name = $_.Name; bytes = $_.Length; mtime = $_.LastWriteTimeUtc.Ticks
                sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash }
        })
    return [ordered]@{ clipboard = [Set91.Native]::GetClipboardSequenceNumber(); files = @($files)
        destinations = $destinations }
}
function Assert-ClipboardGuard {
    $sequence = [Set91.Native]::GetClipboardSequenceNumber()
    if ($sequence -eq $script:clipboardBase) { return }
    # Parent and worker can observe the same change: each owns its receipt.
    $name = if ($WorkerDesktop) { 'clipboard-stop-worker.json' } else { 'clipboard-stop-parent.json' }
    Write-Json (Join-Path $OutputDirectory $name) ([ordered]@{
        utc = [DateTimeOffset]::UtcNow.ToString('o'); before = $script:clipboardBase; after = $sequence
        action = 'STOP launches; no attribution; no clipboard contents accessed' })
    throw "Clipboard sequence changed: STOP launches and report $name."
}

if (-not $WorkerDesktop) {
    $PortableExe = (Resolve-Path -LiteralPath $PortableExe).Path
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    Assert-Contract (-not (Test-Path -LiteralPath $OutputDirectory)) 'OutputDirectory must not already exist.'
    Assert-Contract (-not $PortableExe.Contains('\zig-out\')) 'Use an already staged portable copy, never zig-out.'
    Assert-Contract ((Get-FileHash -LiteralPath $PortableExe).Hash -eq $ExpectedExeSha256) 'Measurement exe SHA-256 mismatch.'
    $stage = Split-Path -Parent $PortableExe
    Assert-Contract (Test-Path -LiteralPath (Join-Path $stage 'noctty.portable') -PathType Leaf) 'Portable marker missing.'
    foreach ($name in 'conpty.dll', 'OpenConsole.exe') {
        Assert-Contract (Test-Path -LiteralPath (Join-Path $stage $name) -PathType Leaf) "Stage is missing $name"
    }
    # A build identity check, not a substitute for the caller's measurement-patch verification.
    $binary = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($PortableExe))
    Assert-Contract ($binary.Contains("io.github.amanthanvi.noctty.measure`0")) 'Measurement AUMID literal missing.'
    Assert-Contract (-not $binary.Contains("io.github.amanthanvi.noctty`0")) `
        'Product AUMID literal remains (check the measurement toast AUMID as well).'
    $binary = $null
    Assert-Contract (-not $OutputDirectory.StartsWith($stage.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) `
        'OutputDirectory must be outside the source stage.'
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
    $before = Get-GuardSnapshot
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness (Split-Path -Leaf $PSCommandPath)
    $historyFailure = $null
    $script:clipboardBase = $before.clipboard
    Write-Json (Join-Path $OutputDirectory 'guard-before.json') $before
    $savedLocal = $env:LOCALAPPDATA
    $savedRoam = $env:APPDATA
    $desktopHandle = [IntPtr]::Zero
    $job = [IntPtr]::Zero
    $worker = $null
    $failure = $null
    $workerCode = $null
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
        $copy = Join-Path $OutputDirectory 'portable'
        [void](New-Item -ItemType Directory -Path $copy)
        # Copy only a staged package; reject reparse points instead of following external data.
        Assert-Contract (@(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }).Count -eq 0) 'Source stage contains a reparse point.'
        Get-ChildItem -LiteralPath $stage -Force | Copy-Item -Destination $copy -Recurse
        $exe = Join-Path $copy (Split-Path -Leaf $PortableExe)
        Assert-Contract ((Get-FileHash -LiteralPath $exe).Hash -eq $ExpectedExeSha256) 'Copied exe hash mismatch.'
        $env:LOCALAPPDATA = Join-Path $OutputDirectory 'local'
        $env:APPDATA = Join-Path $OutputDirectory 'roam'
        [void](New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:APPDATA)
        $desktopName = 'set91-' + [guid]::NewGuid().ToString('N')
        $desktopHandle = [Set91.Native]::CreateDesktopW($desktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
        Assert-Contract ($desktopHandle -ne [IntPtr]::Zero) 'CreateDesktop failed.'
        $job = [Set91.Native]::CreateJob()
        $workerArgs = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Run',
            '-PortableExe', $exe, '-ExpectedExeSha256', $ExpectedExeSha256,
            '-OutputDirectory', $OutputDirectory, '-WorkerDesktop', $desktopName,
            '-ColdOpenCount', "$ColdOpenCount", '-ReloadCount', "$ReloadCount", '-Renderer', $Renderer)
        if ($RequireTrace) { $workerArgs += '-RequireTrace' }
        if ($RequireComboTrace) { $workerArgs += '-RequireComboTrace' }
        if ($RawPostedF9) { $workerArgs += '-RawPostedF9' }
        Assert-ClipboardGuard
        $worker = [Set91.Native]::Launch((Join-Path $PSHOME 'pwsh.exe'), $workerArgs, $desktopName, $OutputDirectory, $job)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $budgetSeconds = 1200 + 150 * ($ColdOpenCount + 2 * $ReloadCount)
        $progressToken = ''
        $lastProgressSeconds = 0.0
        $nextProgressCheck = 0.0
        while ([Set91.Native]::WaitForSingleObject($worker.Handle, 100) -ne 0) {
            Assert-ClipboardGuard
            if ($watch.Elapsed.TotalSeconds -ge $nextProgressCheck) {
                $latestReceipt = Get-ChildItem -LiteralPath $OutputDirectory -Filter 'attempt-*.json' -File |
                    Sort-Object LastWriteTimeUtc, Name -Descending | Select-Object -First 1
                $token = if ($latestReceipt) {
                    '{0}:{1}:{2}' -f $latestReceipt.Name, $latestReceipt.LastWriteTimeUtc.Ticks, $latestReceipt.Length
                } else { '' }
                $progress = Get-WorkerProgressState $token $progressToken $watch.Elapsed.TotalSeconds $lastProgressSeconds
                $progressToken = $progress.token
                $lastProgressSeconds = $progress.lastProgressSeconds
                $nextProgressCheck = $watch.Elapsed.TotalSeconds + 1
                if ($progress.stalled) {
                    Write-Json (Join-Path $OutputDirectory 'worker-timeout.json') ([ordered]@{
                        stage = 'worker-progress-timeout'; workerPid = $worker.Pid; exitCode = $worker.ExitCode()
                        elapsedSeconds = $watch.Elapsed.TotalSeconds; noProgressSeconds = $progress.idleSeconds
                        progressLimitSeconds = 300; latestReceipt = $(if ($latestReceipt) { $latestReceipt.Name } else { $null }) })
                    throw 'SET91 worker made no receipt progress for 300 seconds; stop owned job and retain diagnostics.'
                }
            }
            if ($watch.Elapsed.TotalSeconds -gt $budgetSeconds) {
                Write-Json (Join-Path $OutputDirectory 'worker-timeout.json') ([ordered]@{
                    stage = 'worker-deadline'; workerPid = $worker.Pid; exitCode = $worker.ExitCode()
                    elapsedSeconds = $watch.Elapsed.TotalSeconds; budgetSeconds = $budgetSeconds })
                throw 'SET91 worker timed out; last attempt receipts retained.'
            }
        }
        $workerCode = $worker.ExitCode()
    }
    catch { $failure = $_.Exception.Message }
    finally {
        # Kill the owned worker tree before taking the final real-profile snapshot.
        try {
            if ($job -ne [IntPtr]::Zero -and -not [Set91.Native]::CloseHandle($job)) { throw 'Owned job close failed.' }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
        try { if ($worker) { $worker.Dispose() } } catch { $cleanupErrors.Add($_.Exception.Message) }
        try {
            if ($desktopHandle -ne [IntPtr]::Zero -and -not [Set91.Native]::CloseDesktop($desktopHandle)) { throw 'Owned desktop close failed.' }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
        $env:LOCALAPPDATA = $savedLocal
        $env:APPDATA = $savedRoam
        $guardPass = $false
        $newDestinations = @()
        $after = $null
        try {
        $after = Get-GuardSnapshot
        Write-Json (Join-Path $OutputDirectory 'guard-after.json') $after
        # Other apps may refresh existing jump lists while the maintainer uses
        # this shared host. Portable builds must create no destination, and the
        # real noctty destination must stay unchanged (lead's D12/#417 contract).
        $beforeNames = @($before.destinations | ForEach-Object { $_.name })
        $newDestinations = @($after.destinations | Where-Object { $_.name -notin $beforeNames })
        $realBefore = @($before.destinations | Where-Object name -eq 'c2214d6ebc43ff3f.customDestinations-ms')
        $realAfter = @($after.destinations | Where-Object name -eq 'c2214d6ebc43ff3f.customDestinations-ms')
        $clipboardPass = $before.clipboard -eq $after.clipboard
        $guardPass = $clipboardPass -and $newDestinations.Count -eq 0 -and
            ($before.files | ConvertTo-Json -Depth 8 -Compress) -ceq ($after.files | ConvertTo-Json -Depth 8 -Compress) -and
            ($realBefore | ConvertTo-Json -Depth 8 -Compress) -ceq ($realAfter | ConvertTo-Json -Depth 8 -Compress)
        } catch { $cleanupErrors.Add('Final guard snapshot: ' + $_.Exception.Message) }
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure = $_; $cleanupErrors.Add($_.Exception.Message) }
        Write-Json (Join-Path $OutputDirectory 'summary.json') ([ordered]@{
            pass = ($null -eq $failure -and $workerCode -eq 0 -and $guardPass -and $cleanupErrors.Count -eq 0)
            workerExit = $workerCode; guardPass = $guardPass; error = $failure
            cleanupErrors = @($cleanupErrors.ToArray())
            openMode = $(if ($RawPostedF9) { 'raw-posted-f9' } else { 'host-command-palette' }); requireTrace = [bool]$RequireTrace
            clipboardBefore = $before.clipboard; clipboardAfter = $(if ($after) { $after.clipboard } else { $null })
            executableSha256 = $ExpectedExeSha256; renderer = $Renderer
            newDestinations = $newDestinations; coldRequested = $ColdOpenCount; reloadRequested = $ReloadCount
        })
    }
    if ($historyFailure) { throw $historyFailure }
    Assert-Contract ($cleanupErrors.Count -eq 0) 'Cleanup or final guard receipt failed; inspect summary.json. Stop launches.'
    Assert-Contract $guardPass 'Real startup/history, shell destination metadata or clipboard sequence changed; stop launches and inspect guard artifacts.'
    Assert-Contract ($null -eq $failure) "Runner failed: $failure"
    Assert-Contract ($workerCode -eq 0) 'SET91 regression failed; inspect cases.json, per-control JSON and clipboard-activity.jsonl.'
    if ($ColdOpenCount -gt 0 -or $ReloadCount -gt 0) {
        "SETOPEN cohort PASS ($ColdOpenCount cold, $ReloadCount fresh-process reloads; guard metadata unchanged)"
    } else { 'SET91 regression PASS (17 controls, 29 operation cases; guard metadata unchanged)' }
    return
}

# Worker mode is reached only by explicit private-desktop CreateProcess above.
[Set91.Native]::AssertDesktop([IntPtr]::Zero, $WorkerDesktop)
[void][Set91.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
Assert-Contract ((Get-FileHash -LiteralPath $PortableExe).Hash -eq $ExpectedExeSha256) 'Worker exe identity mismatch.'
Assert-Contract ($env:LOCALAPPDATA -eq (Join-Path $OutputDirectory 'local')) 'Worker LOCALAPPDATA mismatch.'
Assert-Contract ($env:APPDATA -eq (Join-Path $OutputDirectory 'roam')) 'Worker APPDATA mismatch.'
$fixture = Split-Path -Parent $PortableExe
$paletteTitle = 'SETOPENSettingsOnly' + [guid]::NewGuid().ToString('N')
$config = Join-Path $fixture 'config.ghostty'
$script:clipboardBase = (Get-Content -LiteralPath (Join-Path $OutputDirectory 'guard-before.json') -Raw | ConvertFrom-Json).clipboard
Assert-ClipboardGuard
$startupPath = Join-Path $fixture 'startup-attempts.json'
$attempt = $null
$attempts = [Collections.Generic.List[object]]::new()
$attemptClock = [Diagnostics.Stopwatch]::StartNew()
$openClock = $null
$surface = [IntPtr]::Zero
$process = $null
$settings = [IntPtr]::Zero
$hostWindow = [IntPtr]::Zero
$cleanupFailed = $false
$clippedChecks = 0
$results = [Collections.Generic.List[object]]::new()
$cases = @(
    @(201, 405, 'ComboBox', 'Window theme', 'window-theme'),
    @(201, 409, 'ComboBox', 'Cursor style', 'cursor-style'),
    @(201, 411, 'ComboBox', 'Window padding balance', 'window-padding-balance'),
    @(201, 410, 'CheckBox', 'Background blur (not supported on Windows)', 'background-blur'),
    @(202, 403, 'ComboBox', 'Close confirmation', 'confirm-close-surface'),
    @(202, 404, 'ComboBox', 'Copy on select', 'copy-on-select'),
    @(202, 407, 'CheckBox', 'Clipboard trimming', 'clipboard-trim-trailing-spaces'),
    @(203, 406, 'ComboBox', 'Shell integration', 'shell-integration'),
    @(206, 422, 'ComboBox', 'OSC 52 clipboard read requests', 'clipboard-read'),
    @(206, 423, 'ComboBox', 'OSC 52 clipboard write requests', 'clipboard-write'),
    @(206, 424, 'ComboBox', 'Clickable URL opening', 'link-url'),
    @(206, 425, 'ComboBox', 'Link preview popups (not supported on Windows)', 'link-previews'),
    @(206, 417, 'CheckBox', 'Terminal notifications', 'desktop-notifications'),
    @(206, 418, 'CheckBox', 'Clipboard-copy notification', 'app-notifications'),
    @(206, 419, 'CheckBox', 'Config-reload notification', 'app-notifications'),
    @(207, 420, 'ComboBox', 'Auto-update mode', 'auto-update'),
    @(207, 421, 'ComboBox', 'Auto-update channel', 'auto-update-channel')
)
function Start-Fixture {
    Assert-ClipboardGuard
    Assert-Contract (-not $script:cleanupFailed -and $null -eq $script:process) 'Previous fixture has not cleanly exited; stop launches.'
    $script:hostWindow = [IntPtr]::Zero
    $script:surface = [IntPtr]::Zero
    $script:settings = [IntPtr]::Zero
    $script:openClock = $null
    $class = 'noctty-test-set91-' + [guid]::NewGuid().ToString('N')
    $tracePath = Join-Path $OutputDirectory ('settings-open-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $comboTracePath = Join-Path $OutputDirectory ('settings-combo-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $script:attemptClock.Restart()
    $script:attempt = [ordered]@{ index = $attempts.Count + 1; pid = 0
        desktop = $WorkerDesktop; traceFile = [IO.Path]::GetFileName($tracePath)
        comboTraceFile = [IO.Path]::GetFileName($comboTracePath); previousStartedAt = $null
        stage = 'baseline'; stages = [Collections.Generic.List[object]]::new(); f9 = @()
        elapsedMilliseconds = 0; trace = $null; cleanup = $null; startup = $null }
    $attempts.Add($script:attempt)
    # A malformed baseline cannot be treated as an absent ledger: that could accept stale ready state.
    $script:baseline = $null
    [void](Wait-For {
        $script:baseline = Read-StartupAttempt -Path $startupPath
        $script:baseline.stage -in 'missing','empty','observed'
    } 'startup-baseline')
    if ($baseline.latest) { $script:attempt.previousStartedAt = $baseline.latest.started_at_unix_ms }
    Add-Stage 'baseline-captured' $baseline
    Assert-Contract (-not [IO.File]::Exists($tracePath)) 'Trace path must be NEW.'
    Assert-Contract (-not [IO.File]::Exists($comboTracePath)) 'Combo trace path must be NEW.'
    Assert-ClipboardGuard
    $savedTrace = [Environment]::GetEnvironmentVariable('NOCTTY_SETTINGS_OPEN_TRACE', 'Process')
    $savedComboTrace = [Environment]::GetEnvironmentVariable('NOCTTY_SETTINGS_COMBO_TRACE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('NOCTTY_SETTINGS_OPEN_TRACE', $tracePath, 'Process')
        [Environment]::SetEnvironmentVariable('NOCTTY_SETTINGS_COMBO_TRACE', $comboTracePath, 'Process')
        Add-Stage 'launch-requested' $null
        $script:process = [Set91.Native]::Launch($PortableExe,
            @('--single-instance=false', "--class=$class", '--command=cmd.exe /d /q'),
            $WorkerDesktop, $fixture, [IntPtr]::Zero)
    } finally {
        [Environment]::SetEnvironmentVariable('NOCTTY_SETTINGS_OPEN_TRACE', $savedTrace, 'Process')
        [Environment]::SetEnvironmentVariable('NOCTTY_SETTINGS_COMBO_TRACE', $savedComboTrace, 'Process')
    }
    $script:attempt.pid = $process.Pid
    Add-Stage 'launched' ([ordered]@{ pid = $process.Pid; priorityClass = 'BelowNormal'; exitCode = $process.ExitCode()
        waitResult = [Set91.Native]::WaitForSingleObject($process.Handle, 0) })
    [void](Wait-For {
        $script:attempt.startup = Get-NewReadyAttempt -State (Read-StartupAttempt -Path $startupPath) `
            -PreviousStartedAt $script:attempt.previousStartedAt
        if ([Set91.Native]::WaitForSingleObject($process.Handle, 0) -eq 0) {
            Save-Diagnostics 'startup-ready' 'process-exited-before-ready'
            throw 'Fixture exited before startup readiness.'
        }
        $script:attempt.startup.ready
    } 'startup-ready' 30)
    $script:hostWindow = Wait-For { [Set91.Native]::Top($process.Pid, 'noctty.win32.host') } 'host window' 30
    [Set91.Native]::AssertDesktop($hostWindow, $WorkerDesktop)
    $script:surface = Wait-For { [Set91.Native]::Child($hostWindow, -1, 'noctty.win32') } 'terminal surface'
    [Set91.Native]::AssertDesktop($surface, $WorkerDesktop)
    $script:attempt.host = [Set91.Native]::Window($hostWindow)
    $script:attempt.surface = [Set91.Native]::Window($surface)
    Assert-Contract ($attempt.host.Pid -eq $process.Pid -and $attempt.surface.Pid -eq $process.Pid) 'Fixture window owner mismatch.'
    Assert-ClipboardGuard
    $script:openClock = [Diagnostics.Stopwatch]::StartNew()
    if ($RawPostedF9) {
    # Raw reproduction: exactly one pair, no retries, focus changes or keyboard-state mutation.
    foreach ($stroke in @(@(0x100, 0x00430001L), @(0x101, 0xC0430001L))) {
        $receipt = [Set91.Native]::Message($surface, $stroke[0], 0x78, $stroke[1], $false)
        $script:attempt.f9 += $receipt
        Add-Stage 'f9-post' $receipt
        if (-not $receipt.Success) { Save-Diagnostics 'f9-post' 'PostMessage-failed'; throw 'F9 PostMessage failed.' }
    }
    } else {
        Open-SettingsCommand
    }
    $script:settings = Wait-For { [Set91.Native]::Top($process.Pid, 'noctty.win32.settings') } 'Settings window'
    $script:openClock.Stop()
    $script:attempt.openElapsedMilliseconds = $script:openClock.Elapsed.TotalMilliseconds
    [Set91.Native]::AssertDesktop($settings, $WorkerDesktop)
    $script:attempt.settingsWindow = [Set91.Native]::Window($settings)
    Assert-Contract ($attempt.settingsWindow.Pid -eq $process.Pid) 'Settings owner mismatch.'
    Add-Stage 'settings-visible' $attempt.settingsWindow
    if ($RequireTrace) {
        [void](Wait-For {
            $trace = Get-TraceSummary $tracePath
            $expectedFirst = if ($RawPostedF9) { @('f9_keydown','f9_before_core_initialized') } else { @('open_config_action') }
            $trace.exists -and $trace.readable -and -not $trace.pendingFinalLine -and
                $trace.invalidRows -eq 0 -and $trace.records.Count -gt 0 -and
                $trace.records[0].stage -in $expectedFirst -and $trace.tags.ContainsKey('open_config_action') -and
                $trace.tags.ContainsKey('settings_open_enter') -and $trace.tags.ContainsKey('settings_open_ok') -and
                -not $trace.tags.ContainsKey('settings_open_error')
        } 'product-trace')
    }
    Assert-Contract ([Set91.Native]::SetWindowPos($settings, [IntPtr]::Zero, 0, 0, 1200, 800, 0x16)) `
        'Could not size Settings for viewport regression coverage.'
    Start-Sleep -Milliseconds 300
}
function Save-CommandReceipt([string] $Stage, $Receipt) {
    $script:attempt.command += $Receipt
    Add-Stage $Stage $Receipt
    if (-not $Receipt.Success) {
        $script:cleanupFailed = $true
        Save-Diagnostics $Stage 'command-send-failed-or-timeout'
        throw 'Settings command failed; stop launches and inspect receipt.'
    }
}
function Open-SettingsCommand {
    # Existing host command -> configured palette action. No keyboard messages/state or IPC.
    $script:attempt.command = @()
    [Set91.Native]::AssertDesktop([IntPtr]::Zero, $WorkerDesktop)
    [Set91.Native]::AssertDesktop($hostWindow, $WorkerDesktop)
    $hostIdentity = [Set91.Native]::Window($hostWindow)
    Assert-Contract ($hostIdentity.Exists -and $hostIdentity.Pid -eq $process.Pid -and
        $hostIdentity.Class -eq 'noctty.win32.host' -and $hostIdentity.Desktop -eq $WorkerDesktop -and
        [Set91.Native]::WaitForSingleObject($process.Handle, 0) -ne 0) 'Settings command host identity mismatch.'
    Assert-ClipboardGuard
    Add-Stage 'palette-open-requested' $hostIdentity
    Save-CommandReceipt 'palette-open-command' ([Set91.Native]::CommandMessage($hostWindow, 0x111, 1901, 0))
    [void](Wait-For {
        $editWindow = [Set91.Native]::Child($hostWindow, 2002, '')
        $editWindow -ne [IntPtr]::Zero -and [Set91.Native]::IsWindowVisible($editWindow)
    } 'palette-query-visible')
    $edit = Ctl $hostWindow 2002
    $label = Ctl $hostWindow 2001
    $hint = Ctl $hostWindow 2005
    $accept = Ctl $hostWindow 2003
    Assert-Contract (([Set91.Native]::Window($edit)).Class -eq 'Edit' -and
        ([Set91.Native]::Window($label)).Class -eq 'Static' -and
        ([Set91.Native]::Window($hint)).Class -eq 'Static' -and
        ([Set91.Native]::Window($accept)).Class -eq 'Button') 'Palette control class mismatch.'
    $script:attempt.paletteControls = @([Set91.Native]::Window($edit), [Set91.Native]::Window($label),
        [Set91.Native]::Window($hint), [Set91.Native]::Window($accept))
    # Restrict to actions and query our unique configured title. A missing row cannot parse as an action.
    $query = '> ' + $paletteTitle
    Assert-ClipboardGuard
    Save-CommandReceipt 'palette-query-set' ([Set91.Native]::SetFixtureQuery($edit, $query))
    [void](Wait-For {
        try {
        $queryMatches = [Set91.Native]::FixtureControlText($edit) -ceq $query
        $labelText = [Set91.Native]::FixtureControlText($label)
        $singleMatch = $labelText -ceq 'Command 1'
        $feedback = [Set91.Native]::FixtureControlText($hint)
        $selected = $feedback.StartsWith($paletteTitle + ' — ', [StringComparison]::Ordinal) -or
            $feedback.StartsWith($paletteTitle + '. Enter activates;', [StringComparison]::Ordinal)
        $script:attempt.paletteSelection = [ordered]@{ queryMatches = $queryMatches; singleMatch = $singleMatch
            selectedFixtureTitle = $selected; label = $labelText; feedback = $feedback
            acceptVisible = [Set91.Native]::IsWindowVisible($accept); acceptEnabled = [Set91.Native]::IsWindowEnabled($accept) }
        $queryMatches -and $singleMatch -and $selected -and $feedback.Contains('Enter activates; Escape closes.') -and
            [Set91.Native]::IsWindowEnabled($accept)
        } catch { Save-Diagnostics 'palette-selection-readback' 'bounded-control-read-failed'; throw }
    } 'palette-exact-action-selected')
    Add-Stage 'palette-action-verified' ([ordered]@{ queryMatches = $true; matchCount = 1; selectedConfiguredOpenConfig = $true })
    Assert-ClipboardGuard
    # Palette mode hides this generic accept button. Its existing, identity-checked
    # WM_COMMAND handler still submits the verified selected action without keys.
    Save-CommandReceipt 'palette-accept-command' ([Set91.Native]::CommandMessage($hostWindow, 0x111, 2003, $accept.ToInt64()))
}
function Stop-Fixture {
    if (-not $script:process) { return }
    $closeError = $null
    try {
        if ([Set91.Native]::IsWindow($settings)) {
            [void][Set91.Native]::Send($settings, 0x10, 0, 0)
            $discard = [Set91.Native]::Child($settings, 306, '')
            if ($discard -ne [IntPtr]::Zero -and [Set91.Native]::IsWindowVisible($discard)) { Click $discard }
        }
        if ([Set91.Native]::IsWindow($hostWindow)) {
            [void][Set91.Native]::PostMessageW($hostWindow, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
            [void](Wait-For {
                if ([Set91.Native]::WaitForSingleObject($process.Handle, 0) -eq 0) { return $true }
                $candidate = [Set91.Native]::Child($hostWindow, 2003, '')
                $candidate -ne [IntPtr]::Zero -and [Set91.Native]::IsWindowVisible($candidate) -and
                    [Set91.Native]::IsCloseButton($candidate)
            } 'fixture close or confirmation')
            # The Close confirmation case can have saved true/always. Accept only
            # this exact Close button after our WM_CLOSE, never another prompt.
            $accept = [Set91.Native]::Child($hostWindow, 2003, '')
            if ($accept -ne [IntPtr]::Zero -and [Set91.Native]::IsWindowVisible($accept) -and
                [Set91.Native]::IsCloseButton($accept)) {
                [Set91.Native]::AssertDesktop($accept, $WorkerDesktop)
                Click $accept
            }
        }
        if ([Set91.Native]::WaitForSingleObject($process.Handle, 5000) -ne 0) {
            throw 'Fixture required forced termination; stop launches to avoid recovery-state contamination.'
        }
        Assert-Contract ($process.ExitCode() -eq 0 -and -not [Set91.Native]::IsWindow($hostWindow)) 'Fixture exit was not clean.'
        Add-Stage 'exited' ([ordered]@{ pid = $process.Pid; exitCode = $process.ExitCode(); hostExists = [Set91.Native]::IsWindow($hostWindow) })
    }
    catch {
        $closeError = $_.Exception.Message
        $script:cleanupFailed = $true
        Save-Diagnostics 'cleanup' $closeError
    }
    finally {
        $owned = $script:process
        try { $owned.Dispose() }
        catch { $script:cleanupFailed = $true; $closeError = 'Owned handle cleanup failed: ' + $_.Exception.Message }
        finally {
            $script:attempt.cleanup = [ordered]@{ error = $closeError; finalExitCode = $owned.FinalExitCode
                terminated = $owned.WasTerminated; handleClosed = $owned.Handle -eq [IntPtr]::Zero }
            Save-Attempt -UpdateIndex
            if ($owned.Handle -eq [IntPtr]::Zero) { $script:process = $null }
        }
    }
    if ($closeError) { throw $closeError }
}
function Select-Case($Case, [string] $Phase) {
    Click (Ctl $settings $Case[0])
    $hwnd = Ctl $settings $Case[1]
    # Focus scrolling is intentionally avoided; scroll the viewport with posted messages.
    $viewport = [Set91.Native]::Child($settings, -1, 'noctty.win32.settings.viewport')
    Assert-Contract ($viewport -ne [IntPtr]::Zero) 'Missing Settings viewport.'
    if ($viewport -ne [IntPtr]::Zero) {
        [Set91.Native]::AssertDesktop($viewport, $WorkerDesktop)
        [void][Set91.Native]::Send($viewport, 0x115, 6, 0)
        if ([Set91.Native]::FullyClipped($hwnd, $viewport)) {
            $clipped = Probe-Control $Case $hwnd "$Phase-clipped" $false
            Assert-Contract ([bool]$clipped.offscreen) 'Fully clipped field incorrectly reports UIA IsOffscreen=false.'
            $script:clippedChecks++
        }
        for ($step = 0; $step -lt 100 -and [Set91.Native]::FullyClipped($hwnd, $viewport); $step++) {
            [void][Set91.Native]::Send($viewport, 0x115, 1, 0)
        }
        Assert-Contract (-not [Set91.Native]::FullyClipped($hwnd, $viewport)) 'Could not scroll field into viewport.'
    }
    return $hwnd
}
function Probe-Control($Case, [IntPtr] $Hwnd, [string] $Phase, [bool] $ExerciseControl) {
    $path = Join-Path $OutputDirectory "control-$($Case[1])-$Phase.json"
    $clientArgs = @('-NoProfile', '-NonInteractive', '-File', $client, '-Hwnd', $Hwnd.ToInt64().ToString(),
        '-Desktop', $WorkerDesktop, '-Kind', $Case[2], '-ExpectedName', $Case[3], '-OutputPath', $path)
    if ($ExerciseControl) { $clientArgs += '-Exercise' }
    if ($Phase.EndsWith('-selection')) { $clientArgs += '-UseSelectionItem' }
    Assert-ClipboardGuard
    $probe = [Set91.Native]::Launch((Join-Path $PSHOME 'pwsh.exe'), $clientArgs, $WorkerDesktop, $OutputDirectory, [IntPtr]::Zero)
    try {
        if ([Set91.Native]::WaitForSingleObject($probe.Handle, 45000) -ne 0) {
            Save-Diagnostics 'uia-client' 'UIA-client-timeout'
            throw 'UIA client timed out.'
        }
        Assert-Contract (Test-Path -LiteralPath $path) 'UIA client produced no result.'
        $observed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($Case[2] -eq 'ComboBox' -and $ExerciseControl) {
            $nativePath = Join-Path $OutputDirectory $script:attempt.comboTraceFile
            $messages = [Collections.Generic.List[object]]::new()
            $malformedLines = 0
            $pendingFinalLine = $false
            $readError = $null
            if (Test-Path -LiteralPath $nativePath) {
                try {
                    # Match the open-trace reader: the product retains a writer.
                    # Snapshot only the bounded length seen at open, not future appends.
                    $stream = [IO.FileStream]::new($nativePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    try {
                        Assert-Contract ($stream.Length -le 192KB) 'Combo trace exceeds its record bound.'
                        $buffer = [byte[]]::new([int]$stream.Length)
                        $read = 0
                        while ($read -lt $buffer.Length) {
                            $count = $stream.Read($buffer, $read, $buffer.Length - $read)
                            if ($count -eq 0) { break }
                            $read += $count
                        }
                        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                    } finally { $stream.Dispose() }
                    $pendingFinalLine = $text.Length -gt 0 -and -not $text.EndsWith("`n")
                    $lines = $text.Split("`n")
                    for ($i = 0; $i -lt $lines.Length - 1; $i++) {
                        try {
                            $entry = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
                            if ($entry.control_id -eq $Case[1]) { $messages.Add($entry) }
                        } catch { $malformedLines++ }
                    }
                } catch { $readError = '{0}:0x{1:X8}' -f $_.Exception.GetType().Name, $_.Exception.HResult }
            }
            $observed | Add-Member -NotePropertyName nativeTraceFile -NotePropertyValue $script:attempt.comboTraceFile
            $observed | Add-Member -NotePropertyName nativeDropdownMessages -NotePropertyValue @($messages.ToArray())
            $observed | Add-Member -NotePropertyName nativeTraceMalformedLines -NotePropertyValue $malformedLines
            $observed | Add-Member -NotePropertyName nativeTracePendingFinalLine -NotePropertyValue $pendingFinalLine
            $observed | Add-Member -NotePropertyName nativeTraceReadError -NotePropertyValue $readError
            Write-Json $path $observed
            if ($RequireComboTrace -and $observed.pass) {
                Assert-Contract (Test-Path -LiteralPath $nativePath) 'Required native combo trace is missing.'
                Assert-Contract ($null -eq $readError) 'Required native combo trace is unreadable.'
            }
            if ($RequireComboTrace -and $observed.pass -and $observed.enabled) {
                $expansions = @($observed.expansions)
                Assert-Contract ($expansions.Count -eq 2) 'Successful combo operation must record both expansions.'
                foreach ($expansion in $expansions) {
                    # Each Expand has its own clock interval; a complete first
                    # pair cannot stand in for a missing second expansion.
                    $inAttempt = @($messages | Where-Object {
                        $_.tick_ms -ge $expansion.before.tick_ms -and $_.tick_ms -le $expansion.returnTickMs
                    })
                    $received = @($inAttempt | Where-Object { $_.stage -eq 'show_received' -and $_.show })
                    $returned = @($inAttempt | Where-Object { $_.stage -eq 'show_returned' -and $_.show })
                    Assert-Contract ($received.Count -eq 1 -and $returned.Count -eq 1 -and
                        $received[0].tick_ms -le $returned[0].tick_ms -and
                        [Array]::IndexOf($inAttempt, $received[0]) -lt [Array]::IndexOf($inAttempt, $returned[0])) 'Successful combo expansion has no complete native dropdown trace in its interval.'
                }
            }
        }
        Assert-Contract (($probe.ExitCode() -eq 0) -eq [bool]$observed.pass) 'Client exit/result mismatch.'
        return $observed
    }
    finally { $probe.Dispose() }
}
function Write-Seed([string] $Notifications = 'no-clipboard-copy,no-config-reload', [bool] $Trim = $false) {
    Assert-ClipboardGuard
    Assert-Contract ($null -eq $script:process -and -not $cleanupFailed) 'Cannot seed a live or unclean fixture.'
    $seed = @('# SET91 unrelated sentinel must survive byte-for-byte', 'font-size = 12',
        'command = cmd.exe /d /q', "renderer = $Renderer", 'window-save-state = never',
        'confirm-close-surface = false', 'auto-update = off', 'auto-update-channel = tip',
        'desktop-notifications = false', "app-notifications = $Notifications",
        'copy-on-select = false', 'clipboard-read = deny', 'clipboard-write = deny',
        'windows-job-object-kill-on-close = true', 'keybind = f9=open_config',
        'command-palette-entry =', "command-palette-entry = title:$paletteTitle,action:open_config",
        ('clipboard-trim-trailing-spaces = ' + $Trim.ToString().ToLowerInvariant())) -join "`n"
    [IO.File]::WriteAllText($config, $seed + "`n", [Text.UTF8Encoding]::new($false))
}
function Assert-Sentinel {
    $saved = [IO.File]::ReadAllText($config)
    Assert-Contract ($saved.Contains("# SET91 unrelated sentinel must survive byte-for-byte`nfont-size = 12`n")) 'Save damaged unrelated sentinel.'
    return $saved
}
function Invoke-CohortCase([string] $Kind, [int] $Index) {
    $record = [ordered]@{ id = "$Kind-$Index"; kind = $Kind; pass = $false; attemptIndices = @() }
    try {
        $initial = ($Index % 2) -eq 0
        Write-Seed -Trim $initial
        Start-Fixture
        $record.attemptIndices += $attempt.index
        if ($Kind -eq 'reload') {
            Click (Ctl $settings 202)
            $trim = Ctl $settings 407
            $save = Ctl $settings 301
            Assert-Contract ([Set91.Native]::Send($trim, 0xF0, 0, 0) -eq [int]$initial) 'Seed trim checkbox differs.'
            Assert-Contract (-not [Set91.Native]::IsWindowEnabled($save)) 'Reload fixture starts dirty.'
            $beforeHash = (Get-FileHash -LiteralPath $config).Hash
            Click $trim
            Assert-Contract ([Set91.Native]::Send($trim, 0xF0, 0, 0) -eq [int](-not $initial)) 'Trim checkbox did not toggle.'
            Assert-Contract ([Set91.Native]::IsWindowEnabled($save)) 'Trim click did not dirty config.'
            Click $save
            [void](Wait-For { -not [Set91.Native]::IsWindowEnabled($save) } 'cohort-save')
            $saved = Assert-Sentinel
            $expected = (-not $initial).ToString().ToLowerInvariant()
            Assert-Contract ($saved -match "(?m)^clipboard-trim-trailing-spaces\s*=\s*$expected\s*$") 'Saved trim config differs.'
            $record.savedSha256 = (Get-FileHash -LiteralPath $config).Hash
            Assert-Contract ($record.savedSha256 -ne $beforeHash) 'Save did not change config.'
            Stop-Fixture
            Start-Fixture
            $record.attemptIndices += $attempt.index
            Click (Ctl $settings 202)
            Assert-Contract ([Set91.Native]::Send((Ctl $settings 407), 0xF0, 0, 0) -eq [int](-not $initial)) 'Fresh-process trim state differs.'
            [void](Assert-Sentinel)
            Assert-Contract ((Get-FileHash -LiteralPath $config).Hash -eq $record.savedSha256) 'Fresh-process load changed config.'
        }
        Stop-Fixture
        $record.pass = $true
    }
    catch {
        $record.error = $_.Exception.Message
        Save-Diagnostics 'cohort-case' $record.error
        throw
    }
    finally {
        try { Stop-Fixture } catch { $record.pass = $false; $record.cleanupError = $_.Exception.Message; throw }
        finally {
            $results.Add($record)
            Write-Json (Join-Path $OutputDirectory 'cases.json') @($results.ToArray())
        }
    }
}
$cohortMode = $ColdOpenCount -gt 0 -or $ReloadCount -gt 0
try {
    if ($cohortMode) {
        for ($i = 1; $i -le $ColdOpenCount; $i++) { Invoke-CohortCase 'cold' $i }
        for ($i = 1; $i -le $ReloadCount; $i++) { Invoke-CohortCase 'reload' $i }
    } else {
    foreach ($selectionMode in @($false, $true)) {
    foreach ($case in $cases) {
        if ($selectionMode -and $case[2] -ne 'ComboBox') { continue }
        $phase = if ($selectionMode) { 'selection' } else { 'value' }
        $record = [ordered]@{ id = $case[1]; kind = $case[2]; mode = $phase; pass = $false }
        try {
            # No PowerShell shell/profile or history. The process receives no typed commands.
            # Start the config-reload checkbox ON so its tested toggle turns notifications OFF
            # before Save; Settings save otherwise invokes a system toast even on a hidden desktop.
            $notifications = if ($case[1] -eq 419) { 'no-clipboard-copy,config-reload' } else { 'no-clipboard-copy,no-config-reload' }
            Write-Seed -Notifications $notifications
            Start-Fixture
            $hwnd = Select-Case $case "exercise-$phase"
            $save = Ctl $settings 301
            Assert-Contract (-not [Set91.Native]::IsWindowEnabled($save)) 'Fixture is already dirty.'
            $beforeHash = (Get-FileHash -LiteralPath $config).Hash
            $observed = Probe-Control $case $hwnd "exercise-$phase" $true
            $record.probe = $observed
            Assert-Contract $observed.pass 'UIA pattern/operation/name contract failed.'
            Assert-Contract (-not $observed.offscreen) 'Visible exercised field incorrectly reports UIA IsOffscreen=true.'
            $disabled = $case[1] -in 410, 425
            Assert-Contract ([bool]$observed.enabled -eq (-not $disabled)) 'Unexpected enabled state.'
            Assert-Contract ((Get-FileHash -LiteralPath $config).Hash -eq $beforeHash) 'UIA operation wrote config before Save.'
            if ($disabled) {
                Assert-Contract $observed.disabledRejected 'Unsupported field operation was not rejected.'
                Assert-Contract (-not [Set91.Native]::IsWindowEnabled($save)) 'Disabled operation dirtied pending config.'
                $record.disabledRejected = $true
            }
            else {
                Assert-Contract ([Set91.Native]::IsWindowEnabled($save)) 'UIA changed native state without pending config.'
                [void][Set91.Native]::Send($settings, 0x10, 0, 0)
                $keep = Ctl $settings 2
                Assert-Contract ([Set91.Native]::IsWindowVisible($keep)) 'Pending config did not produce dirty-close confirmation.'
                $record.pendingDirty = $true
                Click $keep
                Click $save
                [void](Wait-For { -not [Set91.Native]::IsWindowEnabled($save) } 'Save to commit pending config')
                $saved = [IO.File]::ReadAllText($config)
                Assert-Contract ($saved.Contains("# SET91 unrelated sentinel must survive byte-for-byte`nfont-size = 12`n")) 'Save damaged unrelated sentinel.'
                Assert-Contract ((Get-FileHash -LiteralPath $config).Hash -ne $beforeHash) 'Save did not change the portable config.'
                Assert-Contract ($saved -match ('(?m)^' + [regex]::Escape($case[4]) + '\s*=')) 'Save did not write the exercised config key.'
                $record.savedSha256 = (Get-FileHash -LiteralPath $config).Hash
                # A fresh app loads disk; reopening in the same app would only prove its cache.
                Stop-Fixture
                Start-Fixture
                $reopened = Probe-Control $case (Select-Case $case "reload-$phase") "reload-$phase" $false
                $record.reload = $reopened
                Assert-Contract ($reopened.pass -and $reopened.before -ceq $observed.after) 'Saved UIA state did not roundtrip through a fresh process.'
                $record.saveRoundtrip = $true
            }
            $record.pass = $true
        }
        catch { $record.error = $_.Exception.Message; Save-Diagnostics 'uia-case' $record.error }
        finally {
            try { Stop-Fixture } catch { $record.pass = $false; $record.cleanupError = $_.Exception.Message }
            $results.Add($record)
            Write-Json (Join-Path $OutputDirectory 'cases.json') @($results.ToArray())
        }
        Assert-ClipboardGuard
        Assert-Contract (-not $cleanupFailed) 'Cleanup failed; stop batch and inspect the retained fixture.'
    }
    }
    }
}
finally {
    try { Stop-Fixture }
    finally {
        Write-Json (Join-Path $OutputDirectory 'coverage.json') ([ordered]@{
            mode = $(if ($cohortMode) { 'cohort' } else { 'uia' })
            expectedControls = $(if ($cohortMode) { 0 } else { $cases.Count })
            expectedCases = $(if ($cohortMode) { $ColdOpenCount + $ReloadCount } else { $cases.Count + 12 })
            completedControls = @($results | ForEach-Object { $_.id } | Sort-Object -Unique).Count
            completedCases = $results.Count; passedCases = @($results | Where-Object { $_.pass }).Count
            clippedFieldChecks = $clippedChecks; launches = $attempts.Count
        })
    }
}
Assert-Contract (@($results | Where-Object { -not $_.pass }).Count -eq 0) 'One or more SET91 cases failed.'
if (-not $cohortMode) {
    Assert-Contract ($results.Count -eq 29) 'Default UIA case coverage is incomplete.'
    Assert-Contract ($clippedChecks -gt 0) 'No fully clipped field was observed; clipping coverage is missing.'
} else {
    Assert-Contract ($results.Count -eq $ColdOpenCount + $ReloadCount) 'Cohort coverage is incomplete.'
}
