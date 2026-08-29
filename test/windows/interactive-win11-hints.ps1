[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 25,
    [ValidateSet('Full', 'UnsafePaste')]
    [string] $Scenario = 'Full'
)

$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

if (-not $env:NOCTTY_INTERACTIVE_WIN11_HINTS_BOOTSTRAPPED) {
    $forwarded = @('-TimeoutSeconds', $TimeoutSeconds.ToString(), '-Scenario', $Scenario)
    if ($Rebuild) { $forwarded += '-Rebuild' }
    if ($ResetState) { $forwarded += '-ResetState' }
    $code = 0
    Invoke-InteractiveWin11Bootstrap -RepoRoot $repoRoot -LauncherPath $launcherPath `
        -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_HINTS_BOOTSTRAPPED' `
        -ArgumentList $forwarded -ExitCode ([ref]$code)
    exit $code
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('NocttyHintsNative' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class NocttyHintsNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);

    [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
        public uint cbSize; public uint flags; public IntPtr hwndActive; public IntPtr hwndFocus;
        public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize;
        public IntPtr hwndCaret; public int left; public int top; public int right; public int bottom;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT {
        public uint uMsg; public ushort wParamL; public ushort wParamH;
    }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT {
        public uint type; public INPUTUNION value;
    }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", SetLastError=true)] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll", SetLastError=true)] static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError=true)] static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetClipboardData(uint format, IntPtr memory);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr GetClipboardData(uint format);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GlobalFree(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr reserved);
    [DllImport("ole32.dll")] static extern void OleUninitialize();
    [DllImport("ole32.dll")] static extern int OleGetClipboard(out IntPtr dataObject);
    [DllImport("ole32.dll")] static extern int OleSetClipboard(IntPtr dataObject);
    [DllImport("ole32.dll")] static extern int OleFlushClipboard();

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint GMEM_MOVEABLE = 0x0002;
    const uint CF_UNICODETEXT = 13;
    static bool oleInitialized;

    static string ClassName(IntPtr hwnd) {
        StringBuilder value = new StringBuilder(128);
        GetClassNameW(hwnd, value, value.Capacity);
        return value.ToString();
    }

    static string WindowText(IntPtr hwnd) {
        StringBuilder value = new StringBuilder(256);
        GetWindowTextW(hwnd, value, value.Capacity);
        return value.ToString();
    }

    public static bool ClassNamesEqual(string actual, string expected) {
        return String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
    }

    static string DiagnosticField(string value) {
        return (value ?? "")
            .Replace("\\", "\\\\")
            .Replace("\r", "\\r")
            .Replace("\n", "\\n")
            .Replace("\t", "\\t");
    }

    public static string DescribeDescendants(IntPtr parent) {
        List<string> rows = new List<string>();
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            rows.Add(DescribeWindow(hwnd));
            return true;
        };
        EnumChildWindows(parent, callback, IntPtr.Zero);
        return String.Join(Environment.NewLine, rows.ToArray());
    }

    public static string DescribeWindow(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return "hwnd=0x0\tclass=<none>\ttext=<none>\tvisible=False";
        return String.Format(
            "hwnd=0x{0:X}\tclass={1}\ttext={2}\tvisible={3}",
            hwnd.ToInt64(),
            DiagnosticField(ClassName(hwnd)),
            DiagnosticField(WindowText(hwnd)),
            IsWindowVisible(hwnd));
    }

    public static IntPtr FindTopLevel(uint processId, string className) {
        IntPtr found = IntPtr.Zero;
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner == processId && ClassName(hwnd) == className) {
                found = hwnd;
                return false;
            }
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindDescendant(IntPtr parent, string className, bool visibleOnly) {
        IntPtr found = IntPtr.Zero;
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            if (ClassNamesEqual(ClassName(hwnd), className) && (!visibleOnly || IsWindowVisible(hwnd))) {
                found = hwnd;
                return false;
            }
            return true;
        };
        EnumChildWindows(parent, callback, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindDescendantByText(IntPtr parent, string className, string text, bool visibleOnly) {
        IntPtr found = IntPtr.Zero;
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            if (ClassNamesEqual(ClassName(hwnd), className) && WindowText(hwnd) == text && (!visibleOnly || IsWindowVisible(hwnd))) {
                found = hwnd;
                return false;
            }
            return true;
        };
        EnumChildWindows(parent, callback, IntPtr.Zero);
        return found;
    }

    public static IntPtr FocusedWindowFor(IntPtr hwnd) {
        uint ignored;
        uint thread = GetWindowThreadProcessId(hwnd, out ignored);
        GUITHREADINFO info = new GUITHREADINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        return thread != 0 && GetGUIThreadInfo(thread, ref info) ? info.hwndFocus : IntPtr.Zero;
    }

    static INPUT Key(ushort key, uint flags) {
        INPUT input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.value.ki.wVk = key;
        input.value.ki.dwFlags = flags;
        return input;
    }

    public static bool SendChord(ushort[] keys) {
        INPUT[] inputs = new INPUT[keys.Length * 2];
        for (int i = 0; i < keys.Length; i++) inputs[i] = Key(keys[i], 0);
        for (int i = 0; i < keys.Length; i++) inputs[keys.Length + i] = Key(keys[keys.Length - 1 - i], KEYEVENTF_KEYUP);
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
    }

    public static bool ForceForeground(IntPtr hwnd) {
        SendChord(new ushort[] { 0x12 });
        uint ignored;
        uint targetThread = GetWindowThreadProcessId(hwnd, out ignored);
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out ignored);
        uint currentThread = GetCurrentThreadId();
        bool attachedForeground = foregroundThread != 0 && foregroundThread != currentThread && AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedTarget = targetThread != 0 && targetThread != currentThread && AttachThreadInput(currentThread, targetThread, true);
        try {
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            return GetForegroundWindow() == hwnd;
        }
        finally {
            if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }

    static bool AcquireClipboard() {
        for (int i = 0; i < 40; i++) {
            if (OpenClipboard(IntPtr.Zero)) return true;
            System.Threading.Thread.Sleep(25);
        }
        return false;
    }

    public static void SetClipboardText(string text) {
        if (!AcquireClipboard()) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            if (!EmptyClipboard()) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            char[] chars = (text + "\0").ToCharArray();
            IntPtr memory = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)(chars.Length * 2));
            if (memory == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            bool transferred = false;
            try {
                IntPtr target = GlobalLock(memory);
                if (target == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                try { Marshal.Copy(chars, 0, target, chars.Length); }
                finally { GlobalUnlock(memory); }
                if (SetClipboardData(CF_UNICODETEXT, memory) == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                transferred = true;
            }
            finally {
                if (!transferred) GlobalFree(memory);
            }
        }
        finally { CloseClipboard(); }
    }

    public static string GetClipboardText() {
        if (!AcquireClipboard()) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr memory = GetClipboardData(CF_UNICODETEXT);
            if (memory == IntPtr.Zero) return "";
            IntPtr source = GlobalLock(memory);
            if (source == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try { return Marshal.PtrToStringUni(source) ?? ""; }
            finally { GlobalUnlock(memory); }
        }
        finally { CloseClipboard(); }
    }

    public static IntPtr CaptureClipboard() {
        IntPtr dataObject;
        int hr = OleGetClipboard(out dataObject);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        return dataObject;
    }

    public static void InitializeClipboard() {
        if (oleInitialized) return;
        int hr = OleInitialize(IntPtr.Zero);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        oleInitialized = true;
    }

    public static void ShutdownClipboard() {
        if (!oleInitialized) return;
        OleUninitialize();
        oleInitialized = false;
    }

    public static void RestoreClipboard(IntPtr dataObject) {
        if (dataObject == IntPtr.Zero) {
            if (!AcquireClipboard()) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try {
                if (!EmptyClipboard()) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { CloseClipboard(); }
            return;
        }
        try {
            int hr = 0;
            for (int attempt = 0; attempt < 40; attempt++) {
                hr = OleSetClipboard(dataObject);
                if (hr >= 0) hr = OleFlushClipboard();
                if (hr >= 0) return;
                System.Threading.Thread.Sleep(25);
            }
            Marshal.ThrowExceptionForHR(hr);
        }
        finally { Marshal.Release(dataObject); }
    }
}
'@
}

if (-not [NocttyHintsNative]::ClassNamesEqual('Button', 'BUTTON')) {
    throw 'Win32 class-name matching must be ordinal case-insensitive.'
}

function Wait-HintsUntil {
    param(
        [Parameter(Mandatory)][DateTime] $Deadline,
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory)][scriptblock] $Condition,
        [System.Diagnostics.Process] $Process
    )
    # Callers retain a shared scenario deadline for diagnostic context, but
    # each independent acceptance condition gets the full bounded timeout.
    # Otherwise several successful UIA/clipboard phases can exhaust the one
    # original deadline before a later condition is even evaluated.
    $conditionDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-InteractiveWin11Until -Deadline $conditionDeadline -Description $Description -Condition $Condition -Process $Process
}

function Send-HintsChord {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)][IntPtr] $HostHwnd,
        [Parameter(Mandatory)][UInt16[]] $Keys,
        [Parameter(Mandatory)][string] $Description,
        [IntPtr] $ExpectedFocus = [IntPtr]::Zero
    )
    if (-not [NocttyHintsNative]::ForceForeground($HostHwnd)) {
        throw "Unable to foreground noctty before $Description."
    }
    if ($ExpectedFocus -ne [IntPtr]::Zero -and [NocttyHintsNative]::FocusedWindowFor($HostHwnd) -ne $ExpectedFocus) {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($ExpectedFocus)
        if ($null -ne $element) { $element.SetFocus() }
    }
    if (-not [NocttyHintsNative]::SendChord($Keys)) {
        throw "SendInput failed for ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Start-Sleep -Milliseconds 120
}

function Get-HintsInputEvents {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateRange(1, 100)][int] $MaxAttempts = 12,
        [ValidateRange(0, 1000)][int] $RetryDelayMilliseconds = 15
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $stream = $null
        $reader = $null
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.FileStream]::new(
                $Path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                $share
            )
            $reader = [IO.StreamReader]::new(
                $stream,
                [Text.UTF8Encoding]::new($false, $true),
                $true
            )
            $snapshot = $reader.ReadToEnd()
        }
        catch {
            $ioError = $_.Exception -is [IO.IOException] -or
                $_.Exception.InnerException -is [IO.IOException]
            if (-not $ioError) { throw }
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            if ($attempt -eq $MaxAttempts) { throw }
            if ($RetryDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
            }
            continue
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $stream) { $stream.Dispose() }
        }

        $events = [Collections.Generic.List[object]]::new()
        $lines = [regex]::Split($snapshot, '\r?\n')
        $hasTrailingNewline = $snapshot.EndsWith("`n")
        $completedCount = if ($hasTrailingNewline) { $lines.Count } else { [Math]::Max(0, $lines.Count - 1) }
        for ($lineIndex = 0; $lineIndex -lt $completedCount; $lineIndex++) {
            $line = $lines[$lineIndex]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { [void]$events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) }
            catch {
                throw "Malformed completed hints input JSON at line $($lineIndex + 1): $($_.Exception.Message)"
            }
        }

        if (-not $hasTrailingNewline -and $lines.Count -gt 0) {
            $trailing = $lines[$lines.Count - 1]
            if (-not [string]::IsNullOrWhiteSpace($trailing)) {
                try {
                    [void]$events.Add(($trailing | ConvertFrom-Json -ErrorAction Stop))
                    return @($events)
                }
                catch {
                    if ($attempt -lt $MaxAttempts) {
                        if ($RetryDelayMilliseconds -gt 0) {
                            Start-Sleep -Milliseconds $RetryDelayMilliseconds
                        }
                        continue
                    }
                    # The writer may have been sampled between its JSON bytes
                    # and final newline. Completed prior records remain a valid
                    # snapshot; the next bounded poll will observe the tail.
                    return @($events)
                }
            }
        }
        return @($events)
    }
    return @()
}

function Write-HintsDescendantInventory {
    param(
        [Parameter(Mandatory)][IntPtr] $HostHwnd,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Phase
    )
    @(
        "phase=$Phase"
        ('parent=0x{0:X}' -f $HostHwnd.ToInt64())
        [NocttyHintsNative]::DescribeDescendants($HostHwnd)
    ) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-HintsButtonInvokePattern {
    param(
        [Parameter(Mandatory)][System.Windows.Automation.AutomationElement] $Element,
        [Parameter(Mandatory)][string] $Description
    )
    $actual = $Element.Current.ControlType
    $expected = [System.Windows.Automation.ControlType]::Button
    $pattern = $null
    $invokeAvailable = $Element.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
    )
    if ($actual.Id -ne $expected.Id -or -not $invokeAvailable -or $null -eq $pattern) {
        throw "$Description accessibility mismatch: actual=$($actual.ProgrammaticName) " +
            "id=$($actual.Id) localized='$($Element.Current.LocalizedControlType)' " +
            "expected=$($expected.ProgrammaticName) id=$($expected.Id) " +
            "invoke_available=$invokeAvailable."
    }
    return [System.Windows.Automation.InvokePattern]$pattern
}

function Get-HintsScenarioPlan {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Full', 'UnsafePaste')]
        [string] $Name
    )
    switch ($Name) {
        'Full' {
            return [pscustomobject]@{
                RunMain = $true
                RunUnsafePaste = $true
                SandboxName = 'hints'
                ArtifactName = 'interactive-win11-hints.json'
            }
        }
        'UnsafePaste' {
            return [pscustomobject]@{
                RunMain = $false
                RunUnsafePaste = $true
                SandboxName = 'hints-unsafe-paste'
                ArtifactName = 'interactive-win11-hints-unsafe-paste.json'
            }
        }
    }
}

function Write-HintsQuickSelectFailureDiagnostics {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)][IntPtr] $HostHwnd,
        [Parameter(Mandatory)][IntPtr] $SurfaceHwnd,
        [Parameter(Mandatory)][string] $InputPath,
        [Parameter(Mandatory)][string] $StderrPath,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Phase
    )
    $Process.Refresh()
    $foreground = [NocttyHintsNative]::GetForegroundWindow()
    $focused = [NocttyHintsNative]::FocusedWindowFor($HostHwnd)
    $keyFocusLines = if (Test-Path -LiteralPath $StderrPath) {
        @(Get-Content -LiteralPath $StderrPath | Where-Object {
                $_ -match 'key event binding|toggle_quick_select|mailbox message=.*focus'
            } | Select-Object -Last 40)
    } else { @() }
    @(
        "phase=$Phase"
        "timestamp_utc=$([DateTime]::UtcNow.ToString('o'))"
        'expected_chord=Ctrl+Shift+Space'
        "process_id=$($Process.Id)"
        "process_exited=$($Process.HasExited)"
        "host=$([NocttyHintsNative]::DescribeWindow($HostHwnd))"
        "surface=$([NocttyHintsNative]::DescribeWindow($SurfaceHwnd))"
        "foreground=$([NocttyHintsNative]::DescribeWindow($foreground))"
        "focused=$([NocttyHintsNative]::DescribeWindow($focused))"
        "pty_event_count=$(@(Get-HintsInputEvents -Path $InputPath).Count)"
        'descendants_begin'
        [NocttyHintsNative]::DescribeDescendants($HostHwnd)
        'descendants_end'
        'stderr_key_focus_lines_begin'
        $keyFocusLines
        'stderr_key_focus_lines_end'
    ) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Start-HintsScenario {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Fixture,
        [string[]] $ConfigArgs = @(),
        [Parameter(Mandatory)][string] $UrlTracePath,
        [Parameter(Mandatory)][string] $InputPath,
        [Parameter(Mandatory)][string] $ReadyPath,
        [Parameter(Mandatory)][string] $PayloadPath,
        [Parameter(Mandatory)][string] $StdoutPath,
        [Parameter(Mandatory)][string] $StderrPath,
        [Parameter(Mandatory)][string] $ExePath,
        [Parameter(Mandatory)] $Layout
    )
    $payload = @'
__FIXTURE__
'ready' | Set-Content -LiteralPath '__READY__' -Encoding ASCII
while ($true) {
    $key = [Console]::ReadKey($true)
    [ordered]@{
        char = [int][char]$key.KeyChar
        key = $key.Key.ToString()
        modifiers = $key.Modifiers.ToString()
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath '__INPUT__' -Encoding ASCII
}
'@
    $payload = $payload.Replace('__FIXTURE__', $Fixture).
        Replace('__READY__', $ReadyPath.Replace("'", "''")).
        Replace('__INPUT__', $InputPath.Replace("'", "''"))
    $payload | Set-Content -LiteralPath $PayloadPath -Encoding UTF8
    Remove-Item -LiteralPath $UrlTracePath, $InputPath, $ReadyPath, $StdoutPath, $StderrPath -ErrorAction SilentlyContinue

    $args = @(
        (Get-InteractiveWin11LaunchArguments -Layout $Layout)
        '--config-default-files=false'
        '--confirm-close-surface=false'
    ) + $ConfigArgs + @(
        '-e'
        'powershell.exe'
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $PayloadPath
    )
    $previousTrace = $env:NOCTTY_WIN32_OPEN_URL_TRACE_FILE
    $env:NOCTTY_WIN32_OPEN_URL_TRACE_FILE = $UrlTracePath
    try {
        return Start-Process -FilePath $ExePath -ArgumentList $args -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
    }
    finally {
        if ($null -eq $previousTrace) { Remove-Item Env:NOCTTY_WIN32_OPEN_URL_TRACE_FILE -ErrorAction SilentlyContinue }
        else { $env:NOCTTY_WIN32_OPEN_URL_TRACE_FILE = $previousTrace }
    }
}

$scenarioPlan = Get-HintsScenarioPlan -Name $Scenario
$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot `
    -SandboxName $scenarioPlan.SandboxName -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout
$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
if ($launchAction -eq 'build') { Invoke-InteractiveWin11Build -RepoRoot $repoRoot }
Assert-InteractiveWin11ExeExists -ExePath $exePath

$artifactPath = Join-Path $layout.Logs $scenarioPlan.ArtifactName
Remove-Item -LiteralPath $artifactPath -ErrorAction SilentlyContinue
$clipboardObject = [IntPtr]::Zero
$clipboardInitialized = $false
$clipboardCaptured = $false
$process = $null
$primaryFailure = $null
$evidence = [ordered]@{ scenario = $Scenario }
try {
    [NocttyHintsNative]::InitializeClipboard()
    $clipboardInitialized = $true
    $clipboardObject = [NocttyHintsNative]::CaptureClipboard()
    $clipboardCaptured = $true

    if ($scenarioPlan.RunMain) {
    $url = 'https://example.com/hints?x=1&y=2'
    $inputPath = Join-Path $layout.Temp 'hints-input.jsonl'
    $readyPath = Join-Path $layout.Temp 'hints-ready.txt'
    $urlTracePath = Join-Path $layout.Temp 'hints-url-open.txt'
    $payloadPath = Join-Path $layout.Temp 'hints-payload.ps1'
    $stdoutPath = Join-Path $layout.Logs 'interactive-win11-hints-stdout.log'
    $stderrPath = Join-Path $layout.Logs 'interactive-win11-hints-stderr.log'
    $quickFailurePath = Join-Path $layout.Logs 'interactive-win11-hints-quick-select-failure.log'
    Remove-Item -LiteralPath $quickFailurePath -ErrorAction SilentlyContinue
    $process = Start-HintsScenario -Name 'main' `
        -Fixture "Write-Host '$url'`n[Console]::Write('COPYMODE')" `
        -UrlTracePath $urlTracePath -InputPath $inputPath -ReadyPath $readyPath `
        -PayloadPath $payloadPath -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -ExePath $exePath -Layout $layout
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-HintsUntil -Deadline $deadline -Description 'hints host and payload readiness' -Process $process -Condition {
        $process.Refresh()
        -not $process.HasExited -and
            (Test-Path -LiteralPath $readyPath) -and
            [NocttyHintsNative]::FindTopLevel([uint32]$process.Id, 'noctty.win32.host') -ne [IntPtr]::Zero
    }
    $hostHwnd = [NocttyHintsNative]::FindTopLevel([uint32]$process.Id, 'noctty.win32.host')
    $surfaceHwnd = [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32', $true)
    if ($surfaceHwnd -eq [IntPtr]::Zero) { throw 'Terminal surface HWND was unavailable.' }

    [NocttyHintsNative]::SetClipboardText('clipboard-sentinel')
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x20) -Description 'open quick select'
    try {
        Wait-HintsUntil -Deadline $deadline -Description 'quick-select overlay' -Process $process -Condition {
            [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true) -ne [IntPtr]::Zero
        }
    }
    catch {
        try {
            Write-HintsQuickSelectFailureDiagnostics -Process $process -HostHwnd $hostHwnd `
                -SurfaceHwnd $surfaceHwnd -InputPath $inputPath -StderrPath $stderrPath `
                -Path $quickFailurePath -Phase 'quick-select overlay'
        }
        catch { Write-Warning "Unable to write quick-select failure diagnostics: $_" }
        throw
    }
    $quickHwnd = [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true)
    $quick = [System.Windows.Automation.AutomationElement]::FromHandle($quickHwnd)
    if ($null -eq $quick) { throw 'Quick-select overlay exposes no UIA root.' }
    if ($quick.Current.ControlType -ne [System.Windows.Automation.ControlType]::List) { throw 'Quick-select UIA root is not a List.' }
    if ($quick.Current.Name -ne 'Quick select, 1 target') { throw "Unexpected quick-select name '$($quick.Current.Name)'." }
    if (-not $quick.Current.HasKeyboardFocus) { throw 'Quick-select UIA root does not own keyboard focus.' }
    $quickRootName = $quick.Current.Name
    $quickControlType = $quick.Current.ControlType.ProgrammaticName
    $selectionPattern = [System.Windows.Automation.SelectionPattern]$quick.GetCurrentPattern(
        [System.Windows.Automation.SelectionPattern]::Pattern
    )
    $rows = $quick.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    if ($rows.Count -ne 1) { throw "Expected one accessible quick-select target; found $($rows.Count)." }
    $row = $rows.Item(0)
    if ($row.Current.ControlType -ne [System.Windows.Automation.ControlType]::ListItem) { throw 'Quick-select target is not a ListItem.' }
    $expectedRowName = "Target 1 of 1, label a, $url"
    if ($row.Current.Name -ne $expectedRowName) { throw "Unexpected quick-select target name '$($row.Current.Name)'." }
    $rowControlType = $row.Current.ControlType.ProgrammaticName
    $selectionItem = [System.Windows.Automation.SelectionItemPattern]$row.GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern
    )
    if ($null -eq $selectionPattern -or $null -eq $selectionItem) { throw 'Quick-select accessibility patterns are unavailable.' }

    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $quickHwnd `
        -Keys @([uint16]0x41) -Description 'copy quick-select target'
    Wait-HintsUntil -Deadline $deadline -Description 'quick-select clipboard result' -Process $process -Condition {
        [NocttyHintsNative]::GetClipboardText() -eq $url -and
            [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true) -eq [IntPtr]::Zero
    }
    if (@(Get-HintsInputEvents -Path $inputPath).Count -ne 0) { throw 'Quick-select label input leaked to the PTY.' }

    [NocttyHintsNative]::SetClipboardText('open-sentinel')
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x20) -Description 'reopen quick select'
    try {
        Wait-HintsUntil -Deadline $deadline -Description 'quick-select overlay for open' -Process $process -Condition {
            [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true) -ne [IntPtr]::Zero
        }
    }
    catch {
        try {
            Write-HintsQuickSelectFailureDiagnostics -Process $process -HostHwnd $hostHwnd `
                -SurfaceHwnd $surfaceHwnd -InputPath $inputPath -StderrPath $stderrPath `
                -Path $quickFailurePath -Phase 'quick-select overlay for open'
        }
        catch { Write-Warning "Unable to write quick-select failure diagnostics: $_" }
        throw
    }
    $quickHwnd = [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true)
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $quickHwnd `
        -Keys @([uint16]0x11, [uint16]0x41) -Description 'record quick-select URL open'
    Wait-HintsUntil -Deadline $deadline -Description 'recorded quick-select URL open' -Process $process -Condition {
        (Test-Path -LiteralPath $urlTracePath) -and (Get-Content -LiteralPath $urlTracePath -Raw).Trim() -eq $url
    }
    if ([NocttyHintsNative]::GetClipboardText() -ne 'open-sentinel') { throw 'Ctrl-open unexpectedly changed the clipboard.' }
    if (@(Get-HintsInputEvents -Path $inputPath).Count -ne 0) { throw 'Ctrl-open label input leaked to the PTY.' }

    [NocttyHintsNative]::SetClipboardText('copy-mode-sentinel')
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x58) -Description 'enter copy mode'
    $terminal = [System.Windows.Automation.AutomationElement]::FromHandle($surfaceHwnd)
    $textPattern = [System.Windows.Automation.TextPattern]$terminal.GetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern
    )
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x5A) -Description 'copy-mode catch-all suppression'
    Start-Sleep -Milliseconds 400
    if (@(Get-HintsInputEvents -Path $inputPath).Count -ne 0) { throw 'Copy-mode catch-all key leaked to the PTY.' }
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x47) -Description 'normalize copy-mode selection to viewport home'
    $selectionBeforeRange = $textPattern.GetSelection().GetValue(0)
    $selectionBefore = $selectionBeforeRange.GetText(-1)
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x4C) -Description 'move copy-mode selection right'
    $selectionAfterRange = $textPattern.GetSelection().GetValue(0)
    $selectionAfter = $selectionAfterRange.GetText(-1)
    $startDelta = $selectionBeforeRange.CompareEndpoints(
        [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start,
        $selectionAfterRange,
        [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start
    )
    $endDelta = $selectionBeforeRange.CompareEndpoints(
        [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End,
        $selectionAfterRange,
        [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End
    )
    if ($startDelta -eq 0 -and $endDelta -eq 0) {
        throw "Copy-mode selection endpoints did not move (selection='$selectionAfter')."
    }
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x59) -Description 'copy and exit copy mode'
    Wait-HintsUntil -Deadline $deadline -Description 'copy-mode clipboard result' -Process $process -Condition {
        [NocttyHintsNative]::GetClipboardText() -ne 'copy-mode-sentinel'
    }
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x42) -Description 'prove PTY input after copy-mode exit'
    Wait-HintsUntil -Deadline $deadline -Description 'PTY input after copy-mode exit' -Process $process -Condition {
        @(Get-HintsInputEvents -Path $inputPath).Count -ge 1
    }
    Remove-Item -LiteralPath $inputPath -ErrorAction SilentlyContinue
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x58) -Description 'reenter copy mode for cancel'
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x51) -Description 'cancel copy mode'
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x43) -Description 'prove PTY input after copy-mode cancel'
    Wait-HintsUntil -Deadline $deadline -Description 'PTY input after copy-mode cancel' -Process $process -Condition {
        @(Get-HintsInputEvents -Path $inputPath).Count -ge 1
    }

    $evidence.quick_select = [ordered]@{
        root_name = $quickRootName
        root_control_type = $quickControlType
        root_has_keyboard_focus = $true
        selection_pattern = $true
        row_name = $expectedRowName
        row_control_type = $rowControlType
        selection_item_pattern = $true
        copied_text = $url
        opened_url = (Get-Content -LiteralPath $urlTracePath -Raw).Trim()
        pty_leak_count = 0
    }
    $evidence.copy_mode = [ordered]@{
        selection_before = $selectionBefore
        selection_after = $selectionAfter
        selection_start_delta = $startDelta
        selection_end_delta = $endDelta
        catch_all_suppressed = $true
        copy_exit_restored_pty = $true
        cancel_restored_pty = $true
    }
    Stop-InteractiveWin11Process -Process $process -Contained
    $process = $null
    }

    if ($scenarioPlan.RunUnsafePaste) {
    $unsafeInputPath = Join-Path $layout.Temp 'hints-unsafe-input.jsonl'
    $unsafeReadyPath = Join-Path $layout.Temp 'hints-unsafe-ready.txt'
    $unsafeUrlTracePath = Join-Path $layout.Temp 'hints-unsafe-url-open.txt'
    $unsafePayloadPath = Join-Path $layout.Temp 'hints-unsafe-payload.ps1'
    $unsafeStdoutPath = Join-Path $layout.Logs 'interactive-win11-hints-unsafe-stdout.log'
    $unsafeStderrPath = Join-Path $layout.Logs 'interactive-win11-hints-unsafe-stderr.log'
    $unsafeInventoryPath = Join-Path $layout.Logs 'interactive-win11-hints-unsafe-descendants.log'
    Remove-Item -LiteralPath $unsafeInventoryPath -ErrorAction SilentlyContinue
    # RenderState.string includes blank viewport cells as NUL bytes before each
    # hard line break. Include them so the selected payload still crosses the
    # newline and exercises protected paste.
    $process = Start-HintsScenario -Name 'unsafe-paste' `
        -Fixture "Write-Host 'danger'`nWrite-Host 'next'" `
        -ConfigArgs @('--quick-select-patterns=danger[\x00\r\n]+next') `
        -UrlTracePath $unsafeUrlTracePath -InputPath $unsafeInputPath -ReadyPath $unsafeReadyPath `
        -PayloadPath $unsafePayloadPath -StdoutPath $unsafeStdoutPath -StderrPath $unsafeStderrPath `
        -ExePath $exePath -Layout $layout
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-HintsUntil -Deadline $deadline -Description 'unsafe-paste host and payload readiness' -Process $process -Condition {
        $process.Refresh()
        -not $process.HasExited -and
            (Test-Path -LiteralPath $unsafeReadyPath) -and
            [NocttyHintsNative]::FindTopLevel([uint32]$process.Id, 'noctty.win32.host') -ne [IntPtr]::Zero
    }
    $hostHwnd = [NocttyHintsNative]::FindTopLevel([uint32]$process.Id, 'noctty.win32.host')
    $surfaceHwnd = [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32', $true)
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x20) -Description 'open unsafe-paste quick select'
    Wait-HintsUntil -Deadline $deadline -Description 'unsafe-paste quick-select overlay' -Process $process -Condition {
        [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true) -ne [IntPtr]::Zero
    }
    $quickHwnd = [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true)
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $quickHwnd `
        -Keys @([uint16]0x12, [uint16]0x41) -Description 'request protected quick-select paste'
    $allow = $null
    try {
        Wait-HintsUntil -Deadline $deadline -Description 'protected-paste confirmation' -Process $process -Condition {
            $allowHwnd = [NocttyHintsNative]::FindDescendantByText($hostHwnd, 'BUTTON', 'Allow', $true)
            $script:allow = if ($allowHwnd -ne [IntPtr]::Zero) {
                [System.Windows.Automation.AutomationElement]::FromHandle($allowHwnd)
            } else { $null }
            $null -ne $script:allow
        }
    }
    catch {
        try {
            Write-HintsDescendantInventory -HostHwnd $hostHwnd -Path $unsafeInventoryPath `
                -Phase 'protected-paste confirmation'
        }
        catch { Write-Warning "Unable to write protected-paste descendant inventory: $_" }
        throw
    }
    $allow = $script:allow
    [void](Get-HintsButtonInvokePattern -Element $allow -Description 'Protected-paste Allow control')
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -Keys @([uint16]0x1B) -Description 'cancel protected paste'
    Start-Sleep -Milliseconds 400
    if (@(Get-HintsInputEvents -Path $unsafeInputPath).Count -ne 0) { throw 'Cancelled protected paste reached the PTY.' }

    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $surfaceHwnd `
        -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x20) -Description 'reopen unsafe-paste quick select'
    Wait-HintsUntil -Deadline $deadline -Description 'unsafe-paste quick-select overlay after cancel' -Process $process -Condition {
        [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true) -ne [IntPtr]::Zero
    }
    $quickHwnd = [NocttyHintsNative]::FindDescendant($hostHwnd, 'noctty.win32.quick_select', $true)
    Send-HintsChord -Process $process -HostHwnd $hostHwnd -ExpectedFocus $quickHwnd `
        -Keys @([uint16]0x12, [uint16]0x41) -Description 'request protected quick-select paste again'
    $retryAllow = $null
    try {
        Wait-HintsUntil -Deadline $deadline -Description 'protected-paste confirmation after retry' -Process $process -Condition {
            $retryAllowHwnd = [NocttyHintsNative]::FindDescendantByText($hostHwnd, 'BUTTON', 'Allow', $true)
            $script:retryAllow = if ($retryAllowHwnd -ne [IntPtr]::Zero) {
                [System.Windows.Automation.AutomationElement]::FromHandle($retryAllowHwnd)
            } else { $null }
            $null -ne $script:retryAllow
        }
    }
    catch {
        try {
            Write-HintsDescendantInventory -HostHwnd $hostHwnd -Path $unsafeInventoryPath `
                -Phase 'protected-paste confirmation after retry'
        }
        catch { Write-Warning "Unable to write protected-paste descendant inventory: $_" }
        throw
    }
    $retryAllow = $script:retryAllow
    $retryInvoke = Get-HintsButtonInvokePattern -Element $retryAllow `
        -Description 'Protected-paste Allow control after retry'
    $retryInvoke.Invoke()
    Wait-HintsUntil -Deadline $deadline -Description 'accepted protected paste at PTY' -Process $process -Condition {
        $events = @(Get-HintsInputEvents -Path $unsafeInputPath)
        $events.Count -ge 10 -and @($events | Where-Object { $_.char -eq 13 }).Count -ge 1
    }
    $unsafeEvents = @(Get-HintsInputEvents -Path $unsafeInputPath)
    $evidence.protected_paste = [ordered]@{
        confirmation_name = 'Allow'
        invoke_pattern = $true
        cancel_suppressed_pty = $true
        accepted_key_count = $unsafeEvents.Count
        accepted_contains_carriage_return = @($unsafeEvents | Where-Object { $_.char -eq 13 }).Count -ge 1
    }

    $evidence.processes = [ordered]@{
        final_pid = $process.Id
        stdout = $unsafeStdoutPath
        stderr = $unsafeStderrPath
    }
    }
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artifactPath -Encoding UTF8
    Write-Host "interactive-win11 hints validation: PASS (artifact=$artifactPath)"
}
catch {
    $primaryFailure = $_
    throw
}
finally {
    if ($null -ne $process) { Stop-InteractiveWin11Process -Process $process -Contained }
    try {
        if ($clipboardCaptured) {
            try {
                [NocttyHintsNative]::RestoreClipboard($clipboardObject)
                $clipboardObject = [IntPtr]::Zero
                $clipboardCaptured = $false
            }
            catch {
                if ($null -eq $primaryFailure) { throw }
                Write-Warning "Clipboard restoration also failed: $($_.Exception.Message)"
            }
        }
    }
    finally {
        if ($clipboardInitialized) {
            [NocttyHintsNative]::ShutdownClipboard()
            $clipboardInitialized = $false
        }
    }
}
