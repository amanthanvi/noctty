[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 20,
    [int] $IdleSoakSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
if ($IdleSoakSeconds -lt 0) { throw 'IdleSoakSeconds must be non-negative.' }
$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

function Get-AccessibilitySha256Hex {
    param([Parameter(Mandatory)][string] $Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $digest = $sha256.ComputeHash($stream)
            return ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha256.Dispose()
    }
}

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_ACCESSIBILITY_BOOTSTRAPPED) {
    $forwarded = @('-TimeoutSeconds', $TimeoutSeconds.ToString(), '-IdleSoakSeconds', $IdleSoakSeconds.ToString())
    if ($Rebuild) { $forwarded += '-Rebuild' }
    if ($ResetState) { $forwarded += '-ResetState' }
    $code = 0
    Invoke-InteractiveWin11Bootstrap -RepoRoot $repoRoot -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_ACCESSIBILITY_BOOTSTRAPPED' `
        -ArgumentList $forwarded -ExitCode ([ref]$code)
    exit $code
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('WinghosttyAccessibilityNative' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class WinghosttyAccessibilityNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct POINT {
        public int x; public int y;
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int left; public int top; public int right; public int bottom;
    }
    [StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRAST {
        public uint cbSize; public uint dwFlags; public IntPtr lpszDefaultScheme;
    }
    [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
        public uint cbSize; public uint flags; public IntPtr hwndActive; public IntPtr hwndFocus;
        public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize;
        public IntPtr hwndCaret; public RECT rcCaret;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
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
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern short VkKeyScanW(char value);
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    private const uint INPUT_KEYBOARD = 1;
    private const uint INPUT_MOUSE = 0;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private static int textChangedCount;
    private static int editTextChangedCount;
    private static int textSelectionChangedCount;
    private static int valueChangedCount;
    private static readonly object editEventSync = new object();
    private static readonly List<object> editTextChangedSenders = new List<object>();
    private static readonly List<object> textSelectionChangedSenders = new List<object>();
    private static readonly List<object> valueChangedSenders = new List<object>();
    private static int selectionItemSelectedCount;
    private static readonly object selectionItemSelectedSync = new object();
    private static readonly List<object> selectionItemSelectedSenders = new List<object>();
    private static int notificationCount;
    private static readonly object notificationSync = new object();
    private static string notificationKind = "";
    private static string notificationDisplayString = "";
    private static IntPtr notificationAutomation = IntPtr.Zero;
    private static IntPtr notificationElement = IntPtr.Zero;
    private static IntPtr notificationHandlerInterface = IntPtr.Zero;
    private static NotificationHandler notificationHandler;

    [ComVisible(true)]
    [Guid("C7CB2637-E6C2-4D0C-85DE-4948C02175C7")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationNotificationEventHandler {
        [PreserveSig]
        int HandleNotificationEvent(
            IntPtr sender,
            int notificationKind,
            int notificationProcessing,
            [MarshalAs(UnmanagedType.BStr)] string displayString,
            [MarshalAs(UnmanagedType.BStr)] string activityId);
    }

    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class NotificationHandler : IUIAutomationNotificationEventHandler {
        public int HandleNotificationEvent(
            IntPtr sender,
            int kind,
            int processing,
            string displayString,
            string activityId) {
            RecordNotification(NotificationKindName(kind), displayString ?? "");
            return 0;
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int ElementFromHandleDelegate(IntPtr self, IntPtr hwnd, out IntPtr element);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int AddNotificationEventHandlerDelegate(
        IntPtr self,
        IntPtr element,
        int scope,
        IntPtr cacheRequest,
        IntPtr handler);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int RemoveNotificationEventHandlerDelegate(IntPtr self, IntPtr element, IntPtr handler);

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(
        ref Guid classId,
        IntPtr outer,
        uint context,
        ref Guid interfaceId,
        out IntPtr instance);

    public static void OnTextChanged(object sender, EventArgs args) {
        Interlocked.Increment(ref textChangedCount);
    }
    public static void ResetTextChangedCount() {
        Interlocked.Exchange(ref textChangedCount, 0);
    }
    public static int TextChangedCount {
        get { return Volatile.Read(ref textChangedCount); }
    }
    public static void OnEditTextChanged(object sender, EventArgs args) {
        lock (editEventSync) {
            editTextChangedSenders.Add(sender);
            editTextChangedCount++;
        }
    }
    public static void ResetEditTextChangedCount() {
        lock (editEventSync) {
            editTextChangedSenders.Clear();
            editTextChangedCount = 0;
        }
    }
    public static int EditTextChangedCount {
        get { return Volatile.Read(ref editTextChangedCount); }
    }
    public static object[] EditTextChangedSenders {
        get { lock (editEventSync) { return editTextChangedSenders.ToArray(); } }
    }
    public static void OnTextSelectionChanged(object sender, EventArgs args) {
        lock (editEventSync) {
            textSelectionChangedSenders.Add(sender);
            textSelectionChangedCount++;
        }
    }
    public static void ResetTextSelectionChangedCount() {
        lock (editEventSync) {
            textSelectionChangedSenders.Clear();
            textSelectionChangedCount = 0;
        }
    }
    public static int TextSelectionChangedCount {
        get { return Volatile.Read(ref textSelectionChangedCount); }
    }
    public static object[] TextSelectionChangedSenders {
        get { lock (editEventSync) { return textSelectionChangedSenders.ToArray(); } }
    }
    public static void OnValueChanged(
        object sender,
        EventArgs args) {
        lock (editEventSync) {
            valueChangedSenders.Add(sender);
            valueChangedCount++;
        }
    }
    public static void ResetValueChangedCount() {
        lock (editEventSync) {
            valueChangedSenders.Clear();
            valueChangedCount = 0;
        }
    }
    public static int ValueChangedCount {
        get { return Volatile.Read(ref valueChangedCount); }
    }
    public static object[] ValueChangedSenders {
        get { lock (editEventSync) { return valueChangedSenders.ToArray(); } }
    }
    public static void OnSelectionItemSelected(object sender, EventArgs args) {
        lock (selectionItemSelectedSync) {
            selectionItemSelectedSenders.Add(sender);
            selectionItemSelectedCount++;
        }
    }
    public static void ResetSelectionItemSelectedCount() {
        lock (selectionItemSelectedSync) {
            selectionItemSelectedSenders.Clear();
            selectionItemSelectedCount = 0;
        }
    }
    public static int SelectionItemSelectedCount {
        get {
            lock (selectionItemSelectedSync) {
                return selectionItemSelectedCount;
            }
        }
    }
    public static object[] SelectionItemSelectedSenders {
        get {
            lock (selectionItemSelectedSync) {
                return selectionItemSelectedSenders.ToArray();
            }
        }
    }
    private static string NotificationKindName(int kind) {
        switch (kind) {
            case 0: return "ItemAdded";
            case 1: return "ItemRemoved";
            case 2: return "ActionCompleted";
            case 3: return "ActionAborted";
            case 4: return "Other";
            default: return "Unknown(" + kind.ToString() + ")";
        }
    }
    private static void RecordNotification(string kind, string displayString) {
        lock (notificationSync) {
            notificationKind = kind ?? "";
            notificationDisplayString = displayString ?? "";
            Interlocked.Increment(ref notificationCount);
        }
    }
    public static void ResetNotificationCount() {
        lock (notificationSync) {
            notificationKind = "";
            notificationDisplayString = "";
            Interlocked.Exchange(ref notificationCount, 0);
        }
    }
    public static int NotificationCount {
        get { return Volatile.Read(ref notificationCount); }
    }
    public static string NotificationKind {
        get { lock (notificationSync) { return notificationKind; } }
    }
    public static string NotificationDisplayString {
        get { lock (notificationSync) { return notificationDisplayString; } }
    }
    public static object[] NotificationSnapshot {
        get {
            lock (notificationSync) {
                return new object[] { notificationCount, notificationKind, notificationDisplayString };
            }
        }
    }
    private static T VtableDelegate<T>(IntPtr instance, int slot) where T : class {
        IntPtr vtable = Marshal.ReadIntPtr(instance);
        IntPtr function = Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(function, typeof(T));
    }
    public static void StartNotificationCapture(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) throw new ArgumentException("Palette HWND is null.", "hwnd");
        if (notificationAutomation != IntPtr.Zero) throw new InvalidOperationException("Notification capture is already active.");
        Guid classId = new Guid("E22AD333-B25F-460C-83D0-0581107395C9");
        Guid interfaceId = new Guid("25F700C8-D816-4057-A9DC-3CBDEE77E256");
        IntPtr automation = IntPtr.Zero;
        IntPtr element = IntPtr.Zero;
        IntPtr handlerInterface = IntPtr.Zero;
        NotificationHandler handler = null;
        int hr = CoCreateInstance(ref classId, IntPtr.Zero, 1, ref interfaceId, out automation);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        try {
            ElementFromHandleDelegate elementFromHandle = VtableDelegate<ElementFromHandleDelegate>(automation, 6);
            hr = elementFromHandle(automation, hwnd, out element);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            handler = new NotificationHandler();
            handlerInterface = Marshal.GetComInterfaceForObject(handler, typeof(IUIAutomationNotificationEventHandler));
            AddNotificationEventHandlerDelegate add = VtableDelegate<AddNotificationEventHandlerDelegate>(automation, 68);
            hr = add(automation, element, 1, IntPtr.Zero, handlerInterface);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            notificationAutomation = automation;
            notificationElement = element;
            notificationHandlerInterface = handlerInterface;
            notificationHandler = handler;
            automation = IntPtr.Zero;
            element = IntPtr.Zero;
            handlerInterface = IntPtr.Zero;
        }
        finally {
            if (handlerInterface != IntPtr.Zero) Marshal.Release(handlerInterface);
            if (element != IntPtr.Zero) Marshal.Release(element);
            if (automation != IntPtr.Zero) Marshal.Release(automation);
        }
    }
    public static void StopNotificationCapture() {
        IntPtr automation = notificationAutomation;
        IntPtr element = notificationElement;
        IntPtr handlerInterface = notificationHandlerInterface;
        if (automation == IntPtr.Zero) return;
        if (element == IntPtr.Zero || handlerInterface == IntPtr.Zero || notificationHandler == null) {
            throw new InvalidOperationException("Notification capture state is incomplete.");
        }
        RemoveNotificationEventHandlerDelegate remove = VtableDelegate<RemoveNotificationEventHandlerDelegate>(automation, 69);
        int hr = remove(automation, element, handlerInterface);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        notificationAutomation = IntPtr.Zero;
        notificationElement = IntPtr.Zero;
        notificationHandlerInterface = IntPtr.Zero;
        notificationHandler = null;
        Marshal.Release(handlerInterface);
        Marshal.Release(element);
        Marshal.Release(automation);
    }

    private static INPUT Key(ushort virtualKey, ushort scan, uint flags) {
        INPUT input = new INPUT();
        input.type = INPUT_KEYBOARD;
        input.value.ki.wVk = virtualKey;
        input.value.ki.wScan = scan;
        input.value.ki.dwFlags = flags;
        return input;
    }
    private static INPUT Mouse(uint flags) {
        INPUT input = new INPUT();
        input.type = INPUT_MOUSE;
        input.value.mi.dwFlags = flags;
        return input;
    }
    private static bool Submit(INPUT[] inputs) {
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) == inputs.Length;
    }
    public static bool SendAsciiText(string text) {
        System.Collections.Generic.List<INPUT> inputs = new System.Collections.Generic.List<INPUT>();
        foreach (char value in text) {
            short encoded = VkKeyScanW(value);
            if (encoded == -1) return false;
            ushort virtualKey = (ushort)(encoded & 0xff);
            int modifiers = (encoded >> 8) & 0xff;
            if ((modifiers & 2) != 0) inputs.Add(Key(0x11, 0, 0));
            if ((modifiers & 4) != 0) inputs.Add(Key(0x12, 0, 0));
            if ((modifiers & 1) != 0) inputs.Add(Key(0x10, 0, 0));
            inputs.Add(Key(virtualKey, 0, 0));
            inputs.Add(Key(virtualKey, 0, KEYEVENTF_KEYUP));
            if ((modifiers & 1) != 0) inputs.Add(Key(0x10, 0, KEYEVENTF_KEYUP));
            if ((modifiers & 4) != 0) inputs.Add(Key(0x12, 0, KEYEVENTF_KEYUP));
            if ((modifiers & 2) != 0) inputs.Add(Key(0x11, 0, KEYEVENTF_KEYUP));
        }
        return Submit(inputs.ToArray());
    }
    public static bool SendChord(ushort[] keys) {
        INPUT[] inputs = new INPUT[keys.Length * 2];
        for (int i = 0; i < keys.Length; i++) inputs[i] = Key(keys[i], 0, 0);
        for (int i = 0; i < keys.Length; i++) inputs[keys.Length + i] = Key(keys[keys.Length - 1 - i], 0, KEYEVENTF_KEYUP);
        return Submit(inputs);
    }
    public static bool SendMouseClick() {
        return Submit(new INPUT[] { Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP) });
    }
    public static int VisibleTerminalChildCount(IntPtr parent) {
        int count = 0;
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            StringBuilder name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (IsWindowVisible(hwnd) && name.ToString() == "winghostty.win32") count++;
            return true;
        };
        EnumChildWindows(parent, callback, IntPtr.Zero);
        return count;
    }
    public static IntPtr[] VisibleTerminalChildren(IntPtr parent) {
        System.Collections.Generic.List<IntPtr> children = new System.Collections.Generic.List<IntPtr>();
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            StringBuilder name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (IsWindowVisible(hwnd) && name.ToString() == "winghostty.win32") children.Add(hwnd);
            return true;
        };
        EnumChildWindows(parent, callback, IntPtr.Zero);
        return children.ToArray();
    }
    public static IntPtr[] TopLevelWindowsForProcess(uint expectedProcessId, string expectedClass) {
        System.Collections.Generic.List<IntPtr> windows = new System.Collections.Generic.List<IntPtr>();
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            uint processId;
            GetWindowThreadProcessId(hwnd, out processId);
            if (processId != expectedProcessId || !IsWindowVisible(hwnd)) return true;
            StringBuilder name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (name.ToString() == expectedClass) windows.Add(hwnd);
            return true;
        };
        EnumWindows(callback, IntPtr.Zero);
        return windows.ToArray();
    }
    public static RECT WindowRect(IntPtr hwnd) {
        RECT rect;
        if (!GetWindowRect(hwnd, out rect)) throw new System.ComponentModel.Win32Exception();
        return rect;
    }
    public static IntPtr FocusedWindowFor(IntPtr hwnd) {
        uint processId;
        uint threadId = GetWindowThreadProcessId(hwnd, out processId);
        GUITHREADINFO info = new GUITHREADINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
        return GetGUIThreadInfo(threadId, ref info) ? info.hwndFocus : IntPtr.Zero;
    }
    public static string WindowClass(IntPtr hwnd) {
        StringBuilder value = new StringBuilder(128);
        return GetClassNameW(hwnd, value, value.Capacity) > 0 ? value.ToString() : "<unavailable>";
    }
    public static bool ForceForeground(IntPtr hwnd) {
        // A synthetic Alt press temporarily satisfies the Win32 foreground-lock
        // rules for an interactive test process without stealing focus by
        // clicking an unverified desktop coordinate.
        Submit(new INPUT[] { Key(0x12, 0, 0), Key(0x12, 0, KEYEVENTF_KEYUP) });
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
}
'@
}

function Assert-AccessibilityInputOwner([System.Diagnostics.Process] $Process, [string] $Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $maxAttempts = 30
    $attempts = 0
    $foregroundHwnd = [IntPtr]::Zero
    [uint32] $foregroundOwner = 0
    $focusedHwnd = [IntPtr]::Zero
    [uint32] $focusedOwner = 0

    do {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.MainWindowHandle -eq [IntPtr]::Zero) {
            throw "winghostty is unavailable before $Description."
        }

        $attempts++
        $foregroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        $foregroundOwner = 0
        if ($foregroundHwnd -ne [IntPtr]::Zero) {
            [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($foregroundHwnd, [ref]$foregroundOwner)
        }

        $focusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
        $focusedOwner = 0
        if ($focusedHwnd -ne [IntPtr]::Zero) {
            [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($focusedHwnd, [ref]$focusedOwner)
        }

        if ($foregroundHwnd -eq $Process.MainWindowHandle -and
            $foregroundOwner -eq [uint32]$Process.Id -and
            $focusedHwnd -ne [IntPtr]::Zero -and
            $focusedOwner -eq [uint32]$Process.Id) {
            return
        }

        [void][WinghosttyAccessibilityNative]::ForceForeground($Process.MainWindowHandle)
        if ($attempts -lt $maxAttempts -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
    } while ($attempts -lt $maxAttempts -and [DateTime]::UtcNow -lt $deadline)

    $foregroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
    $foregroundOwner = 0
    if ($foregroundHwnd -ne [IntPtr]::Zero) {
        [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($foregroundHwnd, [ref]$foregroundOwner)
    }
    $focusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
    $focusedOwner = 0
    if ($focusedHwnd -ne [IntPtr]::Zero) {
        [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($focusedHwnd, [ref]$focusedOwner)
    }
    if ($foregroundHwnd -eq $Process.MainWindowHandle -and
        $foregroundOwner -eq [uint32]$Process.Id -and
        $focusedHwnd -ne [IntPtr]::Zero -and
        $focusedOwner -eq [uint32]$Process.Id) {
        return
    }

    throw "winghostty does not own foreground keyboard focus before $Description (attempts=$attempts/$maxAttempts foreground_hwnd=$foregroundHwnd foreground_owner=$foregroundOwner focused_hwnd=$focusedHwnd focused_owner=$focusedOwner expected=$($Process.Id))."
}

function Send-AccessibilityChord([uint16[]] $Keys, [string] $Description, [System.Diagnostics.Process] $Process) {
    Assert-AccessibilityInputOwner -Process $Process -Description $Description
    if (-not [WinghosttyAccessibilityNative]::SendChord($Keys)) {
        throw "SendInput failed for ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Start-Sleep -Milliseconds 150
    Assert-AccessibilityInputOwner -Process $Process -Description "post-$Description"
}

function Send-AccessibilityOutputMarker(
    [System.Diagnostics.Process] $Process,
    $TextPattern,
    [string] $Marker,
    [string] $Description
) {
    if ([string]::IsNullOrEmpty($Marker) -or $Marker.Length -lt 2) {
        throw "Output marker for $Description is too short."
    }
    $split = [int][Math]::Floor($Marker.Length / 2)
    $command = 'cmd.exe /d /c "echo ' + $Marker.Substring(0, $split) + '^' + $Marker.Substring($split) + '"'
    if ($command.Contains($Marker)) {
        throw "Output marker command for $Description contains its literal marker."
    }

    Assert-AccessibilityInputOwner -Process $Process -Description "$Description text"
    if (-not [WinghosttyAccessibilityNative]::SendAsciiText($command)) {
        throw "SendInput failed for ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $preEnterText = $TextPattern.DocumentRange.GetText(-1)
    if ($preEnterText.Contains($Marker)) {
        throw "Terminal exposed output marker for $Description before Enter."
    }
    Send-AccessibilityChord -Keys @([uint16]0x0D) -Description "$Description Enter" -Process $Process
}

function Wait-AccessibilityCondition([scriptblock] $Condition, [DateTime] $Deadline, [string] $Description) {
    $effectiveDeadline = $Deadline
    if ($null -ne $script:accessibilityOverallDeadline -and $script:accessibilityOverallDeadline -lt $effectiveDeadline) {
        $effectiveDeadline = $script:accessibilityOverallDeadline
    }
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $effectiveDeadline)
    throw "Timed out waiting for $Description."
}

function Get-ExactAccessibilityNotification(
    [string] $Description,
    [string] $ExpectedKind,
    [string] $ExpectedDisplayString
) {
    Start-Sleep -Milliseconds 300
    $snapshot = [WinghosttyAccessibilityNative]::NotificationSnapshot
    $count = [int]$snapshot[0]
    $kind = [string]$snapshot[1]
    $displayString = [string]$snapshot[2]
    if ($count -ne 1 -or $kind -ne $ExpectedKind -or $displayString -ne $ExpectedDisplayString) {
        throw "$Description emitted count=$count kind='$kind' display='$displayString'; expected exactly one kind='$ExpectedKind' display='$ExpectedDisplayString'."
    }
    return [pscustomobject]@{
        Count = $count
        Kind = $kind
        DisplayString = $displayString
    }
}

function Start-AccessibilityEditEventCapture([System.Windows.Automation.AutomationElement] $Element) {
    if ($script:editEventsRegistered) { throw 'Edit event capture is already registered.' }
    if ($null -eq $script:editTextChangedHandler) {
        $script:editTextChangedHandler = [Delegate]::CreateDelegate(
            [System.Windows.Automation.AutomationEventHandler],
            [WinghosttyAccessibilityNative].GetMethod('OnEditTextChanged')
        )
        $script:editTextSelectionChangedHandler = [Delegate]::CreateDelegate(
            [System.Windows.Automation.AutomationEventHandler],
            [WinghosttyAccessibilityNative].GetMethod('OnTextSelectionChanged')
        )
        $script:editValueChangedHandler = [Delegate]::CreateDelegate(
            [System.Windows.Automation.AutomationPropertyChangedEventHandler],
            [WinghosttyAccessibilityNative].GetMethod('OnValueChanged')
        )
    }
    [WinghosttyAccessibilityNative]::ResetEditTextChangedCount()
    [WinghosttyAccessibilityNative]::ResetTextSelectionChangedCount()
    [WinghosttyAccessibilityNative]::ResetValueChangedCount()
    [System.Windows.Automation.Automation]::AddAutomationEventHandler(
        [System.Windows.Automation.TextPattern]::TextChangedEvent,
        $Element,
        [System.Windows.Automation.TreeScope]::Element,
        $script:editTextChangedHandler
    )
    try {
        [System.Windows.Automation.Automation]::AddAutomationEventHandler(
            [System.Windows.Automation.TextPattern]::TextSelectionChangedEvent,
            $Element,
            [System.Windows.Automation.TreeScope]::Element,
            $script:editTextSelectionChangedHandler
        )
        try {
            [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler(
                $Element,
                [System.Windows.Automation.TreeScope]::Element,
                $script:editValueChangedHandler,
                @([System.Windows.Automation.ValuePattern]::ValueProperty)
            )
        }
        catch {
            [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
                [System.Windows.Automation.TextPattern]::TextSelectionChangedEvent,
                $Element,
                $script:editTextSelectionChangedHandler
            )
            throw
        }
    }
    catch {
        [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
            [System.Windows.Automation.TextPattern]::TextChangedEvent,
            $Element,
            $script:editTextChangedHandler
        )
        throw
    }
    $script:editEventElement = $Element
    $script:editEventsRegistered = $true
}

function Stop-AccessibilityEditEventCapture {
    if (-not $script:editEventsRegistered) { return }
    $element = $script:editEventElement
    try {
        [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler(
            $element,
            $script:editValueChangedHandler
        )
    }
    finally {
        try {
            [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
                [System.Windows.Automation.TextPattern]::TextSelectionChangedEvent,
                $element,
                $script:editTextSelectionChangedHandler
            )
        }
        finally {
            [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
                [System.Windows.Automation.TextPattern]::TextChangedEvent,
                $element,
                $script:editTextChangedHandler
            )
            $script:editEventElement = $null
            $script:editEventsRegistered = $false
        }
    }
}

function Get-AccessibilityMatchingSenderCount(
    [object[]] $Senders,
    [System.Windows.Automation.AutomationElement] $Element
) {
    $count = 0
    foreach ($sender in @($Senders)) {
        try {
            if ($sender -is [System.Windows.Automation.AutomationElement] -and
                [System.Windows.Automation.Automation]::Compare($sender, $Element)) {
                $count++
            }
        }
        catch {
            # A late event from a disconnected provider is not evidence for
            # the currently captured Edit element.
        }
    }
    return $count
}

$validationStartedAt = [DateTime]::UtcNow
$script:accessibilityOverallDeadline = $validationStartedAt.AddSeconds(
    [Math]::Max(90, ($TimeoutSeconds * 3) + $IdleSoakSeconds + 60)
)
$machineProcesses = @(Get-Process)
$machineThreadCount = (@($machineProcesses | ForEach-Object { try { $_.Threads.Count } catch { 0 } }) | Measure-Object -Sum).Sum
$machineHandleCount = (@($machineProcesses | ForEach-Object { try { $_.HandleCount } catch { 0 } }) | Measure-Object -Sum).Sum
$browserSupportCount = @($machineProcesses | Where-Object ProcessName -eq '1Password-BrowserSupport').Count
$conhostCount = @($machineProcesses | Where-Object ProcessName -eq 'conhost').Count
if ($machineProcesses.Count -gt 1500 -or $machineThreadCount -gt 30000 -or $machineHandleCount -gt 1000000 -or
    $browserSupportCount -gt 256 -or $conhostCount -gt 320) {
    throw "Refusing accessibility evidence under machine pressure (processes=$($machineProcesses.Count), threads=$machineThreadCount, handles=$machineHandleCount, browser_support=$browserSupportCount, conhost=$conhostCount)."
}
$currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$explorerBefore = @(Get-Process explorer -ErrorAction Stop | Where-Object SessionId -eq $currentSessionId)
if ($explorerBefore.Count -ne 1) {
    throw "Expected one Explorer process in interactive session $currentSessionId; found $($explorerBefore.Count)."
}
$explorerBeforeIdentity = "{0}/{1:o}" -f $explorerBefore[0].Id, $explorerBefore[0].StartTime.ToUniversalTime()
$winghosttyBeforeIdentities = @($machineProcesses | Where-Object ProcessName -eq 'winghostty' | ForEach-Object {
    try { "{0}/{1:o}" -f $_.Id, $_.StartTime.ToUniversalTime() } catch { "pid=$($_.Id)/unavailable" }
})

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'accessibility' -ResetState:$ResetState
$layout = $harness.Layout
$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
if ((Get-InteractiveWin11LaunchAction -ExePath $exe -Rebuild:$Rebuild -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot)) -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}
Assert-InteractiveWin11ExeExists -ExePath $exe
$resolvedExe = (Resolve-Path -LiteralPath $exe).Path
$binaryHash = Get-AccessibilitySha256Hex -Path $resolvedExe
$binaryLastWriteUtc = (Get-Item -LiteralPath $resolvedExe).LastWriteTimeUtc
$sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Unable to establish accessibility source commit provenance.'
}
$sourceWorktreeDirty = @(& git -C $repoRoot status --porcelain --untracked-files=no).Count -gt 0
if ($LASTEXITCODE -ne 0) { throw 'Unable to establish accessibility worktree provenance.' }
$stdout = Join-Path $layout.Logs 'interactive-win11-accessibility-stdout.log'
$stderr = Join-Path $layout.Logs 'interactive-win11-accessibility-stderr.log'
$artifact = Join-Path $layout.Logs 'uia-tree.json'
$document = $null
$textChangedHandler = $null
$textChangedRegistered = $false
$paletteSelectionHandler = $null
$paletteSelectionRegistered = $false
$paletteNotificationRegistered = $false
$editTextChangedHandler = $null
$editTextSelectionChangedHandler = $null
$editValueChangedHandler = $null
$editEventElement = $null
$editEventsRegistered = $false
$relaunchProcess = $null
$ownerProbeProcess = $null
$marker = "WINGHOSTTY_UIA_$([Guid]::NewGuid().ToString('N'))"
$terminalText = ''
$terminalLineText = ''
$terminalRectCount = 0
$queryOnlyMarker = "${marker}_QUERY_ONLY"
$queryOnlyRangeRefreshed = $false
$splitBaseline = 0
$splitAfterRight = 0
$splitAfterDown = 0
$focusBeforePaneMove = [IntPtr]::Zero
$focusAfterPaneMove = [IntPtr]::Zero
$paletteInitialSelectedName = ''
$paletteMovedSelectedName = ''
$paletteSelectionEventCount = 0
$paletteHelpNotificationCount = 0
$paletteHelpNotificationKind = ''
$paletteHelpNotificationDisplayString = ''
$paletteUnavailableNotificationCount = 0
$paletteUnavailableNotificationKind = ''
$paletteUnavailableNotificationDisplayString = ''
$paletteActionAbortedNotificationCount = 0
$paletteActionAbortedNotificationKind = ''
$paletteActionAbortedNotificationDisplayString = ''
$paletteEditEvidence = $null
$searchEditEvidence = $null
$paletteUnavailableQuery = "zzzzwinghosttynomatch$([Guid]::NewGuid().ToString('N'))"
$settingsLifecycle = $null
$settingsOwnerLifecycle = $null
$sustainedOutputEvidence = $null
$evidence = $null
$runFailure = $null
$cleanupFailures = [System.Collections.Generic.List[string]]::new()
$process = Start-Process -FilePath $exe -ArgumentList @(Get-InteractiveWin11LaunchArguments -Layout $layout) `
    -WorkingDirectory $repoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw "winghostty exited before UIA query (exit $($process.ExitCode))." }
    } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'winghostty did not expose a main HWND.' }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    if ($null -eq $root) { throw 'UI Automation returned no root element.' }
    [void][WinghosttyAccessibilityNative]::SetForegroundWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 150
    $elements = @($root) + @($root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $nodes = @($elements | Select-Object -First 512 | ForEach-Object {
        [ordered]@{
            name = $_.Current.Name
            control_type = $_.Current.ControlType.ProgrammaticName
            automation_id = $_.Current.AutomationId
            process_id = $_.Current.ProcessId
            enabled = $_.Current.IsEnabled
            keyboard_focusable = $_.Current.IsKeyboardFocusable
            has_keyboard_focus = $_.Current.HasKeyboardFocus
        }
    })
    if ($root.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
        throw "UIA root control type is $($root.Current.ControlType.ProgrammaticName), expected Window."
    }
    $documents = @($elements | Where-Object {
        $_.Current.ProcessId -eq $process.Id -and
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document
    })
    if ($documents.Count -eq 0) {
        throw 'UIA tree contains no terminal Document element.'
    }
    $document = $documents[0]
    $textPattern = $null
    if (-not $document.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $textPattern
    )) {
        throw 'Terminal Document does not expose the UIA Text pattern.'
    }
    $documentFocusError = $null
    try { $document.SetFocus() } catch { $documentFocusError = $_.Exception.Message }
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(3)
    $focusActivationMaxAttempts = 30
    $focusActivationAttempts = 0
    $clickedDocument = $false
    $focusedHwnd = [IntPtr]::Zero
    [uint32] $focusedProcessId = 0
    $lastSetCursorPosError = 0
    $lastGetCursorPosError = 0
    $lastActualCursorX = $null
    $lastActualCursorY = $null
    $lastClickError = 0
    $lastTargetHwnd = [IntPtr]::Zero
    [uint32] $lastTargetOwner = 0
    do {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $focusedProcessId = 0
        if ($focusedHwnd -ne [IntPtr]::Zero) {
            [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($focusedHwnd, [ref]$focusedProcessId)
            if ($focusedProcessId -eq [uint32]$process.Id) { break }
        }

        if ($focusActivationAttempts -ge $focusActivationMaxAttempts) { break }
        $focusActivationAttempts++
        [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
        try { $document.SetFocus() } catch { $documentFocusError = $_.Exception.Message }

        $bounds = $document.Current.BoundingRectangle
        if ($bounds.Width -gt 0 -and $bounds.Height -gt 0) {
            $noMoveNoSizeShow = [uint32](0x0001 -bor 0x0002 -bor 0x0040)
            [void][WinghosttyAccessibilityNative]::SetWindowPos(
                $process.MainWindowHandle,
                [IntPtr](-1),
                0,
                0,
                0,
                0,
                $noMoveNoSizeShow
            )
            try {
                $x = [int][Math]::Round($bounds.Left + ($bounds.Width / 2))
                $y = [int][Math]::Round($bounds.Top + ($bounds.Height / 2))
                $point = [WinghosttyAccessibilityNative+POINT]::new()
                $point.x = $x
                $point.y = $y
                $lastTargetHwnd = [WinghosttyAccessibilityNative]::WindowFromPoint($point)
                $lastTargetOwner = 0
                $targetThreadId = [WinghosttyAccessibilityNative]::GetWindowThreadProcessId(
                    $lastTargetHwnd,
                    [ref] $lastTargetOwner
                )
                if ($lastTargetHwnd -ne [IntPtr]::Zero -and
                    $targetThreadId -ne 0 -and
                    $lastTargetOwner -eq [uint32]$process.Id) {
                    if ([WinghosttyAccessibilityNative]::SetCursorPos($x, $y)) {
                        $lastSetCursorPosError = 0
                        $actualPoint = [WinghosttyAccessibilityNative+POINT]::new()
                        if ([WinghosttyAccessibilityNative]::GetCursorPos([ref]$actualPoint)) {
                            $lastGetCursorPosError = 0
                            $lastActualCursorX = $actualPoint.x
                            $lastActualCursorY = $actualPoint.y
                            # SendInput clicks the actual cursor location, so
                            # verify that exact point immediately before input.
                            if ($actualPoint.x -eq $x -and $actualPoint.y -eq $y) {
                                $verifiedTargetHwnd = [WinghosttyAccessibilityNative]::WindowFromPoint($actualPoint)
                                [uint32] $verifiedTargetOwner = 0
                                $verifiedTargetThreadId = [WinghosttyAccessibilityNative]::GetWindowThreadProcessId(
                                    $verifiedTargetHwnd,
                                    [ref] $verifiedTargetOwner
                                )
                                $lastTargetHwnd = $verifiedTargetHwnd
                                $lastTargetOwner = $verifiedTargetOwner
                                if ($verifiedTargetHwnd -ne [IntPtr]::Zero -and
                                    $verifiedTargetThreadId -ne 0 -and
                                    $verifiedTargetOwner -eq [uint32]$process.Id) {
                                    if ([WinghosttyAccessibilityNative]::SendMouseClick()) {
                                        $clickedDocument = $true
                                        $lastClickError = 0
                                    } else {
                                        $lastClickError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                                    }
                                }
                            }
                        } else {
                            $lastGetCursorPosError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        }
                    } else {
                        $lastSetCursorPosError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    }
                }
            }
            finally {
                [void][WinghosttyAccessibilityNative]::SetWindowPos(
                    $process.MainWindowHandle,
                    [IntPtr](-2),
                    0,
                    0,
                    0,
                    0,
                    $noMoveNoSizeShow
                )
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $focusDeadline)

    # The final activation attempt can succeed at the deadline. Re-query
    # before deciding failure so stale pre-attempt HWND state cannot fail it.
    $focusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
    $focusedProcessId = 0
    if ($focusedHwnd -ne [IntPtr]::Zero) {
        [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($focusedHwnd, [ref]$focusedProcessId)
    }
    if ($focusedHwnd -eq [IntPtr]::Zero -or $focusedProcessId -ne [uint32]$process.Id) {
        $focusedSummary = if ($null -eq $focused) {
            '<none>'
        } else {
            "pid=$($focused.Current.ProcessId) name='$($focused.Current.Name)'"
        }
        $foregroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        [uint32] $foregroundOwner = 0
        if ($foregroundHwnd -ne [IntPtr]::Zero) {
            [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($foregroundHwnd, [ref]$foregroundOwner)
        }
        throw "Keyboard focus did not resolve to a winghostty HWND (attempts=$focusActivationAttempts/$focusActivationMaxAttempts; SetCursorPos Win32 error=$lastSetCursorPosError; GetCursorPos Win32 error=$lastGetCursorPosError actual=($lastActualCursorX,$lastActualCursorY); click Win32 error=$lastClickError; foreground HWND=$foregroundHwnd owner=$foregroundOwner; focused HWND=$focusedHwnd owner=$focusedProcessId; target HWND=$lastTargetHwnd owner=$lastTargetOwner; expected owner=$($process.Id); UIA focused=$focusedSummary; Document.SetFocus error='$documentFocusError'; clicked document=$clickedDocument)."
    }

    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    $textChangedHandler = [Delegate]::CreateDelegate(
        [System.Windows.Automation.AutomationEventHandler],
        [WinghosttyAccessibilityNative].GetMethod('OnTextChanged')
    )
    [System.Windows.Automation.Automation]::AddAutomationEventHandler(
        [System.Windows.Automation.TextPattern]::TextChangedEvent,
        $document,
        [System.Windows.Automation.TreeScope]::Element,
        $textChangedHandler
    )
    $textChangedRegistered = $true

    $textChangedObservationStart = [DateTime]::UtcNow
    Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $marker -Description 'terminal marker'
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'terminal marker through TextPattern' -Condition {
            $script:terminalTextProbe = $textPattern.DocumentRange.GetText(-1)
            return $script:terminalTextProbe.Contains($marker)
        }
    }
    catch {
        $probe = if ($null -eq $script:terminalTextProbe) { '<null>' } else { $script:terminalTextProbe.Replace("`r", '\r').Replace("`n", '\n') }
        throw "$($_.Exception.Message) Last TextPattern text='$probe'; TextChanged events=$([WinghosttyAccessibilityNative]::TextChangedCount)."
    }
    $terminalText = $script:terminalTextProbe
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'terminal TextChanged event' -Condition {
        return [WinghosttyAccessibilityNative]::TextChangedCount -gt 0
    }
    Start-Sleep -Milliseconds 200
    $textChangedCount = [WinghosttyAccessibilityNative]::TextChangedCount
    $textChangedElapsedSeconds = [Math]::Max(0.2, ([DateTime]::UtcNow - $textChangedObservationStart).TotalSeconds)
    $textChangedLimit = [int][Math]::Ceiling($textChangedElapsedSeconds * 25) + 2
    if ($textChangedCount -gt $textChangedLimit) {
        throw "Terminal emitted $textChangedCount TextChanged events in $([Math]::Round($textChangedElapsedSeconds, 2))s; limit=$textChangedLimit."
    }

    $supportedTextSelection = $textPattern.SupportedTextSelection
    if ($supportedTextSelection -ne [System.Windows.Automation.SupportedTextSelection]::None) {
        throw "Terminal TextPattern unexpectedly advertises selection support: $supportedTextSelection."
    }
    $selection = @($textPattern.GetSelection())
    if ($selection.Count -ne 0) {
        throw "Terminal TextPattern returned $($selection.Count) legacy selection ranges despite reporting None."
    }
    $markerRange = $textPattern.DocumentRange.FindText($marker, $true, $false)
    if ($null -eq $markerRange) { throw 'Terminal FindText did not return the visible marker range.' }
    $lineRange = $markerRange.Clone()
    $lineRange.ExpandToEnclosingUnit([System.Windows.Automation.Text.TextUnit]::Line)
    $terminalLineText = $lineRange.GetText(-1)
    if (-not $terminalLineText.Contains($marker)) {
        throw "Terminal marker range did not expand to its containing line (text='$terminalLineText')."
    }
    $previousLineRange = $markerRange.Clone()
    $lineMoveCount = $previousLineRange.Move([System.Windows.Automation.Text.TextUnit]::Line, -1)
    if ($lineMoveCount -ne -1) { throw "Terminal marker range moved $lineMoveCount lines; expected -1." }
    $terminalRects = @($lineRange.GetBoundingRectangles())
    $terminalRectCount = $terminalRects.Count
    if ($terminalRectCount -eq 0 -or @($terminalRects | Where-Object { $_.Width -gt 0 -and $_.Height -gt 0 }).Count -eq 0) {
        throw 'Terminal marker line returned no positive UIA bounding rectangle.'
    }

    # A query-only client must receive fresh text through the same acquired
    # TextPattern even when no UIA text event listener keeps refresh polling
    # alive. Remove the sole listener before producing the marker so this
    # cannot pass through an event-driven pattern reacquisition path. Each
    # DocumentRange remains an intentionally immutable snapshot.
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
        [System.Windows.Automation.TextPattern]::TextChangedEvent,
        $document,
        $textChangedHandler
    )
    $textChangedRegistered = $false
    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $queryOnlyMarker -Description 'query-only TextPattern marker'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'already-acquired query-only TextPattern refresh' -Condition {
        $script:queryOnlyTextProbe = $textPattern.DocumentRange.GetText(-1)
        return $script:queryOnlyTextProbe.Contains($queryOnlyMarker)
    }
    if ([WinghosttyAccessibilityNative]::TextChangedCount -ne 0) {
        throw "TextChanged callback ran after listener removal during query-only validation."
    }
    $queryOnlyRangeRefreshed = $true
    [System.Windows.Automation.Automation]::AddAutomationEventHandler(
        [System.Windows.Automation.TextPattern]::TextChangedEvent,
        $document,
        [System.Windows.Automation.TreeScope]::Element,
        $textChangedHandler
    )
    $textChangedRegistered = $true

    $splitBaseline = [WinghosttyAccessibilityNative]::VisibleTerminalChildCount($process.MainWindowHandle)
    if ($splitBaseline -ne 1) {
        throw "Split validation requires one clean terminal pane; found $splitBaseline. Rerun with -ResetState."
    }
    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x10, [uint16]0xDC) -Description 'Ctrl+Shift+Backslash split right' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Ctrl+Shift+Backslash visible split' -Condition {
        return [WinghosttyAccessibilityNative]::VisibleTerminalChildCount($process.MainWindowHandle) -eq ($splitBaseline + 1)
    }
    $splitAfterRight = [WinghosttyAccessibilityNative]::VisibleTerminalChildCount($process.MainWindowHandle)
    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x45) -Description 'Ctrl+Shift+E split down' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Ctrl+Shift+E visible split' -Condition {
        return [WinghosttyAccessibilityNative]::VisibleTerminalChildCount($process.MainWindowHandle) -eq ($splitBaseline + 2)
    }
    $splitAfterDown = [WinghosttyAccessibilityNative]::VisibleTerminalChildCount($process.MainWindowHandle)

    $paneGeometry = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren($process.MainWindowHandle) | ForEach-Object {
        $paneRect = [WinghosttyAccessibilityNative]::WindowRect($_)
        [pscustomobject]@{
            Hwnd = $_
            CenterX = ($paneRect.left + $paneRect.right) / 2
            CenterY = ($paneRect.top + $paneRect.bottom) / 2
        }
    })
    if ($paneGeometry.Count -ne 3) { throw "Expected three terminal pane HWNDs, found $($paneGeometry.Count)." }
    $leftPane = $paneGeometry | Sort-Object CenterX, CenterY | Select-Object -First 1
    $rightPanes = @($paneGeometry | Where-Object { $_.Hwnd -ne $leftPane.Hwnd } | Sort-Object CenterY)
    if ($rightPanes.Count -ne 2) { throw 'Could not resolve right-side pane geometry.' }
    $rightTopPane = $rightPanes[0]
    $rightBottomPane = $rightPanes[1]
    $focusBeforePaneMove = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
    if ($focusBeforePaneMove -ne $rightBottomPane.Hwnd) {
        throw "Ctrl+Shift+E did not focus the new lower pane (focused=$focusBeforePaneMove expected=$($rightBottomPane.Hwnd))."
    }

    $paneMoves = @(
        @{ Key = [uint16]0x26; Name = 'Alt+Up'; Expected = $rightTopPane.Hwnd },
        @{ Key = [uint16]0x25; Name = 'Alt+Left'; Expected = $leftPane.Hwnd },
        @{ Key = [uint16]0x27; Name = 'Alt+Right'; Expected = $rightTopPane.Hwnd },
        @{ Key = [uint16]0x28; Name = 'Alt+Down'; Expected = $rightBottomPane.Hwnd }
    )
    $paneFocusResults = [ordered]@{}
    foreach ($move in $paneMoves) {
        Send-AccessibilityChord -Keys @([uint16]0x12, $move.Key) -Description "$($move.Name) pane navigation" -Process $process
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description "$($move.Name) exact pane focus" -Condition {
            return [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle) -eq $move.Expected
        }
        $observedFocus = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $paneFocusResults[$move.Name] = [ordered]@{
            expected = $move.Expected.ToInt64()
            observed = $observedFocus.ToInt64()
        }
    }
    $focusAfterPaneMove = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)

    $paletteDeadline = [DateTime]::UtcNow.AddSeconds(5)
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $process.MainWindowHandle `
        -Message 0x0111 `
        -WParam ([UIntPtr]::new([uint64]1901)) `
        -LParam ([IntPtr]::Zero) `
        -Deadline $paletteDeadline `
        -Process $process `
        -Description 'open accessibility command palette')
    $palette = $null
    do {
        Start-Sleep -Milliseconds 100
        $palette = @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::List
            )
        ) | Where-Object { $_.Current.ProcessId -eq $process.Id }) | Select-Object -First 1
    } while ($null -eq $palette -and [DateTime]::UtcNow -lt $paletteDeadline)
    if ($null -eq $palette) { throw 'UIA tree contains no command palette List element.' }
    $paletteName = $palette.Current.Name
    $paletteBounds = $palette.Current.BoundingRectangle
    if ($paletteBounds.Width -le 0 -or $paletteBounds.Height -le 0) { throw 'Command palette List has empty UIA bounds.' }
    $paletteItems = @($palette.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem
        )
    ) | ForEach-Object { $_ })
    if ($paletteItems.Count -eq 0) { throw 'Command palette List exposes no ListItem children.' }
    $selectedItems = @($paletteItems | Where-Object {
        $pattern = $null
        $_.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern) -and $pattern.Current.IsSelected
    })
    if ($selectedItems.Count -ne 1) { throw "Command palette exposes $($selectedItems.Count) selected rows; expected one." }
    $selectionPattern = $null
    if (-not $palette.TryGetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern, [ref]$selectionPattern)) {
        throw 'Command palette List does not expose SelectionPattern.'
    }
    $containerSelection = @($selectionPattern.Current.GetSelection())
    if ($containerSelection.Count -ne 1 -or $containerSelection[0].Current.Name -ne $selectedItems[0].Current.Name) {
        throw "Command palette SelectionPattern returned $($containerSelection.Count) inconsistent rows."
    }
    $paletteInitialSelectedName = $selectedItems[0].Current.Name
    [WinghosttyAccessibilityNative]::ResetSelectionItemSelectedCount()
    [WinghosttyAccessibilityNative]::ResetNotificationCount()
    $paletteSelectionHandler = [Delegate]::CreateDelegate(
        [System.Windows.Automation.AutomationEventHandler],
        [WinghosttyAccessibilityNative].GetMethod('OnSelectionItemSelected')
    )
    [System.Windows.Automation.Automation]::AddAutomationEventHandler(
        [System.Windows.Automation.SelectionItemPattern]::ElementSelectedEvent,
        $root,
        [System.Windows.Automation.TreeScope]::Descendants,
        $paletteSelectionHandler
    )
    $paletteSelectionRegistered = $true
    $paletteNativeHwnd = [IntPtr]$palette.Current.NativeWindowHandle
    [uint32]$paletteNativeHwndOwner = 0
    if ($paletteNativeHwnd -eq [IntPtr]::Zero -or
        [WinghosttyAccessibilityNative]::GetWindowThreadProcessId($paletteNativeHwnd, [ref]$paletteNativeHwndOwner) -eq 0 -or
        $paletteNativeHwndOwner -ne [uint32]$process.Id) {
        throw "Command palette UIA List has invalid native HWND $paletteNativeHwnd (owner=$paletteNativeHwndOwner)."
    }
    [WinghosttyAccessibilityNative]::StartNotificationCapture($paletteNativeHwnd)
    $paletteNotificationRegistered = $true

    Send-AccessibilityChord -Keys @([uint16]0x28) -Description 'command palette selection Down' -Process $process
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette SelectionItem movement event' -Condition {
            $script:paletteItemsAfterMove = @($palette.FindAll(
                [System.Windows.Automation.TreeScope]::Children,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::ListItem
                )
            ) | ForEach-Object { $_ })
            $script:paletteSelectedAfterMove = @($script:paletteItemsAfterMove | Where-Object {
                $candidateSelectionItem = $null
                $_.TryGetCurrentPattern(
                    [System.Windows.Automation.SelectionItemPattern]::Pattern,
                    [ref]$candidateSelectionItem
                ) -and $candidateSelectionItem.Current.IsSelected
            })
            $script:paletteSelectionEventSender = @(
                [WinghosttyAccessibilityNative]::SelectionItemSelectedSenders | Where-Object {
                    $_ -is [System.Windows.Automation.AutomationElement] -and
                    $script:paletteSelectedAfterMove.Count -eq 1 -and
                    [System.Windows.Automation.Automation]::Compare(
                        $_,
                        $script:paletteSelectedAfterMove[0]
                    )
                }
            ) | Select-Object -First 1
            return $script:paletteSelectedAfterMove.Count -eq 1 -and
                $script:paletteSelectedAfterMove[0].Current.Name -ne $paletteInitialSelectedName -and
                $null -ne $script:paletteSelectionEventSender
        }
    }
    catch {
        $selectedAfter = @($script:paletteSelectedAfterMove | ForEach-Object { $_.Current.Name }) -join ', '
        throw "$($_.Exception.Message) Initial='$paletteInitialSelectedName'; selected_after='$selectedAfter'; events=$([WinghosttyAccessibilityNative]::SelectionItemSelectedCount)."
    }
    $selectedItems = $script:paletteSelectedAfterMove
    $paletteItems = $script:paletteItemsAfterMove
    $paletteMovedSelectedName = $selectedItems[0].Current.Name
    $paletteSelectionEventCount = [WinghosttyAccessibilityNative]::SelectionItemSelectedCount
    $containerSelection = @($selectionPattern.Current.GetSelection())
    if ($containerSelection.Count -ne 1 -or $containerSelection[0].Current.Name -ne $paletteMovedSelectedName) {
        throw "Command palette container selection did not advance with its SelectionItem event."
    }
    if ($palette.Current.HasKeyboardFocus -or $selectedItems[0].Current.HasKeyboardFocus) {
        throw 'Command palette list or row fabricates keyboard focus while the query edit owns focus.'
    }
    $paletteFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $paletteFocused -or $paletteFocused.Current.ProcessId -ne $process.Id -or
        $paletteFocused.Current.ControlType -ne [System.Windows.Automation.ControlType]::Edit) {
        $focusedWin32Hwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $focusedWin32Class = [WinghosttyAccessibilityNative]::WindowClass($focusedWin32Hwnd)
        $focusedFromHandle = $null
        $focusedFromHandleError = $null
        if ($focusedWin32Hwnd -ne [IntPtr]::Zero -and [WinghosttyAccessibilityNative]::IsWindow($focusedWin32Hwnd)) {
            try {
                $focusedFromHandle = [System.Windows.Automation.AutomationElement]::FromHandle($focusedWin32Hwnd)
            }
            catch {
                $focusedFromHandleError = $_.Exception.Message
            }
        }
        $focusedFromHandleSummary = if ($null -eq $focusedFromHandle) {
            if ($null -eq $focusedFromHandleError) { '<none>' } else { "<error: $focusedFromHandleError>" }
        } else {
            "hwnd=$($focusedFromHandle.Current.NativeWindowHandle) type=$($focusedFromHandle.Current.ControlType.ProgrammaticName) focus=$($focusedFromHandle.Current.HasKeyboardFocus) name='$($focusedFromHandle.Current.Name)'"
        }
        $paletteEditCandidates = @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit
            )
        ) | ForEach-Object {
            "hwnd=$($_.Current.NativeWindowHandle) focus=$($_.Current.HasKeyboardFocus) name='$($_.Current.Name)'"
        }) -join '; '
        $paletteFocusedSummary = if ($null -eq $paletteFocused) {
            '<none>'
        } else {
            "pid=$($paletteFocused.Current.ProcessId) hwnd=$($paletteFocused.Current.NativeWindowHandle) type=$($paletteFocused.Current.ControlType.ProgrammaticName) name='$($paletteFocused.Current.Name)'"
        }
        throw "Command palette query Edit does not own UIA focus (focused=$paletteFocusedSummary; Win32 focused HWND=$focusedWin32Hwnd class=$focusedWin32Class FromHandle=$focusedFromHandleSummary; Edit candidates=$paletteEditCandidates)."
    }
    if ($paletteFocused.Current.Name -ne 'Command palette query') {
        throw "Command palette query Edit name was '$($paletteFocused.Current.Name)'."
    }
    $paletteFocusedControlType = $paletteFocused.Current.ControlType.ProgrammaticName
    $paletteQueryBounds = $paletteFocused.Current.BoundingRectangle
    if ($paletteQueryBounds.Width -le 0 -or $paletteQueryBounds.Height -le 0 -or $paletteFocused.Current.IsOffscreen) {
        throw 'Command palette query Edit is not visible with positive UIA bounds.'
    }
    $paletteQueryTextPattern = $null
    if (-not $paletteFocused.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref]$paletteQueryTextPattern
    )) {
        throw 'Command palette query Edit does not expose TextPattern.'
    }
    $paletteQueryValuePattern = $null
    if (-not $paletteFocused.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref]$paletteQueryValuePattern
    )) {
        throw 'Command palette query Edit does not expose ValuePattern.'
    }
    if ($paletteQueryTextPattern.SupportedTextSelection -ne [System.Windows.Automation.SupportedTextSelection]::Single) {
        throw "Command palette query Edit reports $($paletteQueryTextPattern.SupportedTextSelection) selection support; expected Single."
    }
    if ($paletteQueryValuePattern.Current.IsReadOnly) {
        throw 'Command palette query Edit reports a read-only ValuePattern.'
    }
    $paletteInitialQuerySelection = @($paletteQueryTextPattern.GetSelection())
    if ($paletteInitialQuerySelection.Count -ne 1 -or
        $paletteInitialQuerySelection[0].CompareEndpoints(
            [System.Windows.Automation.TextPatternRangeEndpoint]::Start,
            $paletteInitialQuerySelection[0],
            [System.Windows.Automation.TextPatternRangeEndpoint]::End
        ) -ne 0) {
        throw 'Command palette query Edit did not expose one degenerate initial caret range.'
    }
    Start-AccessibilityEditEventCapture -Element $paletteFocused
    $selectedBounds = $selectedItems[0].Current.BoundingRectangle
    if ($selectedBounds.Width -le 0 -or $selectedBounds.Height -le 0 -or $selectedItems[0].Current.IsOffscreen) {
        throw 'Selected command palette row is not visible with positive UIA bounds.'
    }
    if ($selectedBounds.Left -lt $paletteBounds.Left -or $selectedBounds.Top -lt $paletteBounds.Top -or
        $selectedBounds.Right -gt $paletteBounds.Right -or $selectedBounds.Bottom -gt $paletteBounds.Bottom) {
        throw 'Selected command palette row bounds escape the List bounds.'
    }

    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x41) -Description 'select command palette query for help outcome' -Process $process
    $paletteQueryValuePattern.SetValue('Accessibility')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Accessibility help palette row' -Condition {
        $script:paletteHelpItems = @($palette.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem
            )
        ) | ForEach-Object { $_ })
        return $script:paletteHelpItems.Count -eq 1 -and
            $script:paletteHelpItems[0].Current.Name -match 'Accessibility'
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'command palette query Text and Value updates' -Condition {
        return $paletteQueryTextPattern.DocumentRange.GetText(-1) -eq 'Accessibility' -and
            $paletteQueryValuePattern.Current.Value -eq 'Accessibility' -and
            (Get-AccessibilityMatchingSenderCount `
                -Senders ([WinghosttyAccessibilityNative]::EditTextChangedSenders) `
                -Element $paletteFocused) -gt 0 -and
            (Get-AccessibilityMatchingSenderCount `
                -Senders ([WinghosttyAccessibilityNative]::ValueChangedSenders) `
                -Element $paletteFocused) -gt 0
    }
    [WinghosttyAccessibilityNative]::ResetTextSelectionChangedCount()
    $paletteQueryTextPattern.DocumentRange.Select()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'command palette TextPattern selection' -Condition {
        $script:paletteQuerySelection = @($paletteQueryTextPattern.GetSelection())
        return $script:paletteQuerySelection.Count -eq 1 -and
            $script:paletteQuerySelection[0].GetText(-1) -eq 'Accessibility' -and
            (Get-AccessibilityMatchingSenderCount `
                -Senders ([WinghosttyAccessibilityNative]::TextSelectionChangedSenders) `
                -Element $paletteFocused) -gt 0
    }
    $paletteEditTextChangedCount = Get-AccessibilityMatchingSenderCount `
        -Senders ([WinghosttyAccessibilityNative]::EditTextChangedSenders) -Element $paletteFocused
    $paletteEditValueChangedCount = Get-AccessibilityMatchingSenderCount `
        -Senders ([WinghosttyAccessibilityNative]::ValueChangedSenders) -Element $paletteFocused
    $paletteEditSelectionChangedCount = Get-AccessibilityMatchingSenderCount `
        -Senders ([WinghosttyAccessibilityNative]::TextSelectionChangedSenders) -Element $paletteFocused
    $paletteEditEvidence = [ordered]@{
        name = $paletteFocused.Current.Name
        text = $paletteQueryTextPattern.DocumentRange.GetText(-1)
        value = $paletteQueryValuePattern.Current.Value
        selected_text = $script:paletteQuerySelection[0].GetText(-1)
        text_changed_events = $paletteEditTextChangedCount
        value_changed_events = $paletteEditValueChangedCount
        selection_changed_events = $paletteEditSelectionChangedCount
    }
    [WinghosttyAccessibilityNative]::ResetNotificationCount()
    Send-AccessibilityChord -Keys @([uint16]0x0D) -Description 'invoke safe Accessibility help palette row' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Accessibility help UIA notification' -Condition {
        return [WinghosttyAccessibilityNative]::NotificationCount -gt 0
    }
    $helpNotification = Get-ExactAccessibilityNotification `
        -Description 'Accessibility help notification' `
        -ExpectedKind 'Other' `
        -ExpectedDisplayString 'Keyboard: Ctrl+Page Up or Page Down changes tabs; Ctrl+Shift+Backslash splits right; Ctrl+Shift+E splits down; Alt+Arrow moves between panes.'
    $paletteHelpNotificationCount = $helpNotification.Count
    $paletteHelpNotificationKind = $helpNotification.Kind
    $paletteHelpNotificationDisplayString = $helpNotification.DisplayString

    [WinghosttyAccessibilityNative]::ResetNotificationCount()
    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x41) -Description 'select command palette query for unavailable outcome' -Process $process
    if (-not [WinghosttyAccessibilityNative]::SendAsciiText($paletteUnavailableQuery)) {
        throw "SendInput failed for command palette unavailable query: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette unavailable no-match notification' -Condition {
        $script:paletteUnavailableItems = @($palette.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem
            )
        ) | ForEach-Object { $_ })
        return $script:paletteUnavailableItems.Count -eq 0 -and
            [WinghosttyAccessibilityNative]::NotificationCount -gt 0
    }
    $unavailableNotification = Get-ExactAccessibilityNotification `
        -Description 'No-match notification' `
        -ExpectedKind 'Other' `
        -ExpectedDisplayString 'No matches'
    $paletteUnavailableNotificationCount = $unavailableNotification.Count
    $paletteUnavailableNotificationKind = $unavailableNotification.Kind
    $paletteUnavailableNotificationDisplayString = $unavailableNotification.DisplayString

    # With zero ranked rows, Enter falls back to parsing the query as a
    # binding action. This deliberately invalid identifier is rejected before
    # mutation and deterministically raises the palette's ActionAborted event.
    [WinghosttyAccessibilityNative]::ResetNotificationCount()
    Send-AccessibilityChord -Keys @([uint16]0x0D) -Description 'invoke safe unknown command abort outcome' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette ActionAborted notification' -Condition {
        return [WinghosttyAccessibilityNative]::NotificationCount -gt 0
    }
    $actionAbortedNotification = Get-ExactAccessibilityNotification `
        -Description 'Unknown-command notification' `
        -ExpectedKind 'ActionAborted' `
        -ExpectedDisplayString 'Unknown command'
    $paletteActionAbortedNotificationCount = $actionAbortedNotification.Count
    $paletteActionAbortedNotificationKind = $actionAbortedNotification.Kind
    $paletteActionAbortedNotificationDisplayString = $actionAbortedNotification.DisplayString

    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
        [System.Windows.Automation.SelectionItemPattern]::ElementSelectedEvent,
        $root,
        $paletteSelectionHandler
    )
    $paletteSelectionRegistered = $false
    [WinghosttyAccessibilityNative]::StopNotificationCapture()
    $paletteNotificationRegistered = $false
    Stop-AccessibilityEditEventCapture
    Send-AccessibilityChord -Keys @([uint16]0x1B) -Description 'Escape dismiss accessibility command palette' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette removal after Escape' -Condition {
        return @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::List
            )
        ) | Where-Object { $_.Current.ProcessId -eq $process.Id }).Count -eq 0
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'terminal focus after palette Escape' -Condition {
        $script:paletteDismissFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $script:paletteDismissFocusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $script:paletteDismissTerminalHwnds = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren($process.MainWindowHandle))
        return $null -ne $script:paletteDismissFocused -and
            $script:paletteDismissFocused.Current.ProcessId -eq $process.Id -and
            $script:paletteDismissFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and
            $script:paletteDismissTerminalHwnds -contains $script:paletteDismissFocusedHwnd
    }

    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x50) -Description 'Ctrl+Shift+P open command palette' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette keyboard open' -Condition {
        return @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::List
            )
        ) | Where-Object { $_.Current.ProcessId -eq $process.Id }).Count -eq 1
    }
    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x50) -Description 'Ctrl+Shift+P close command palette' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette keyboard toggle removal' -Condition {
        return @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::List
            )
        ) | Where-Object { $_.Current.ProcessId -eq $process.Id }).Count -eq 0
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'terminal focus after palette keyboard toggle close' -Condition {
        $script:paletteToggleFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $script:paletteToggleFocusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $script:paletteToggleTerminalHwnds = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren($process.MainWindowHandle))
        return $null -ne $script:paletteToggleFocused -and
            $script:paletteToggleFocused.Current.ProcessId -eq $process.Id -and
            $script:paletteToggleFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and
            $script:paletteToggleTerminalHwnds -contains $script:paletteToggleFocusedHwnd
    }

    Send-AccessibilityChord -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x46) -Description 'Ctrl+Shift+F open docked search' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'docked search query Edit' -Condition {
        $script:searchQueryEdit = @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit
            )
        ) | Where-Object {
            $_.Current.ProcessId -eq $process.Id -and $_.Current.Name -eq 'Search query'
        }) | Select-Object -First 1
        return $null -ne $script:searchQueryEdit
    }
    $searchQueryEdit = $script:searchQueryEdit
    $searchNativeHwnd = [IntPtr]$searchQueryEdit.Current.NativeWindowHandle
    [uint32]$searchNativeOwner = 0
    if ($searchNativeHwnd -eq [IntPtr]::Zero -or
        [WinghosttyAccessibilityNative]::GetWindowThreadProcessId($searchNativeHwnd, [ref]$searchNativeOwner) -eq 0 -or
        $searchNativeOwner -ne [uint32]$process.Id -or
        -not [WinghosttyAccessibilityNative]::IsWindowVisible($searchNativeHwnd)) {
        throw "Docked search query Edit has invalid native HWND $searchNativeHwnd (owner=$searchNativeOwner)."
    }
    $searchBounds = $searchQueryEdit.Current.BoundingRectangle
    if ($searchBounds.Width -le 0 -or $searchBounds.Height -le 0 -or $searchQueryEdit.Current.IsOffscreen) {
        throw 'Docked search query Edit is not visible with positive UIA bounds.'
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'docked search query UIA focus' -Condition {
        $script:searchFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
        return $null -ne $script:searchFocused -and
            [System.Windows.Automation.Automation]::Compare($script:searchFocused, $searchQueryEdit)
    }
    $searchTextPattern = $null
    if (-not $searchQueryEdit.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref]$searchTextPattern
    )) {
        throw 'Docked search query Edit does not expose TextPattern.'
    }
    $searchValuePattern = $null
    if (-not $searchQueryEdit.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref]$searchValuePattern
    )) {
        throw 'Docked search query Edit does not expose ValuePattern.'
    }
    if ($searchTextPattern.SupportedTextSelection -ne [System.Windows.Automation.SupportedTextSelection]::Single -or
        $searchValuePattern.Current.IsReadOnly) {
        throw 'Docked search query Edit does not expose writable single-selection semantics.'
    }
    $searchInitialSelection = @($searchTextPattern.GetSelection())
    if ($searchInitialSelection.Count -ne 1 -or
        $searchInitialSelection[0].CompareEndpoints(
            [System.Windows.Automation.TextPatternRangeEndpoint]::Start,
            $searchInitialSelection[0],
            [System.Windows.Automation.TextPatternRangeEndpoint]::End
        ) -ne 0) {
        throw 'Docked search query Edit did not expose one degenerate initial caret range.'
    }
    Start-AccessibilityEditEventCapture -Element $searchQueryEdit
    $searchValuePattern.SetValue('needle')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'docked search Text and Value updates' -Condition {
        return $searchTextPattern.DocumentRange.GetText(-1) -eq 'needle' -and
            $searchValuePattern.Current.Value -eq 'needle' -and
            (Get-AccessibilityMatchingSenderCount `
                -Senders ([WinghosttyAccessibilityNative]::EditTextChangedSenders) `
                -Element $searchQueryEdit) -gt 0 -and
            (Get-AccessibilityMatchingSenderCount `
                -Senders ([WinghosttyAccessibilityNative]::ValueChangedSenders) `
                -Element $searchQueryEdit) -gt 0
    }
    [WinghosttyAccessibilityNative]::ResetTextSelectionChangedCount()
    $searchTextPattern.DocumentRange.Select()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'docked search TextPattern selection' -Condition {
        $script:searchQuerySelection = @($searchTextPattern.GetSelection())
        return $script:searchQuerySelection.Count -eq 1 -and
            $script:searchQuerySelection[0].GetText(-1) -eq 'needle' -and
            (Get-AccessibilityMatchingSenderCount `
                -Senders ([WinghosttyAccessibilityNative]::TextSelectionChangedSenders) `
                -Element $searchQueryEdit) -gt 0
    }
    $searchEditTextChangedCount = Get-AccessibilityMatchingSenderCount `
        -Senders ([WinghosttyAccessibilityNative]::EditTextChangedSenders) -Element $searchQueryEdit
    $searchEditValueChangedCount = Get-AccessibilityMatchingSenderCount `
        -Senders ([WinghosttyAccessibilityNative]::ValueChangedSenders) -Element $searchQueryEdit
    $searchEditSelectionChangedCount = Get-AccessibilityMatchingSenderCount `
        -Senders ([WinghosttyAccessibilityNative]::TextSelectionChangedSenders) -Element $searchQueryEdit
    $searchEditEvidence = [ordered]@{
        name = $searchQueryEdit.Current.Name
        text = $searchTextPattern.DocumentRange.GetText(-1)
        value = $searchValuePattern.Current.Value
        selected_text = $script:searchQuerySelection[0].GetText(-1)
        text_changed_events = $searchEditTextChangedCount
        value_changed_events = $searchEditValueChangedCount
        selection_changed_events = $searchEditSelectionChangedCount
    }
    Stop-AccessibilityEditEventCapture
    Send-AccessibilityChord -Keys @([uint16]0x1B) -Description 'Escape close docked search' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'docked search hide and terminal focus restoration' -Condition {
        $script:searchDismissFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $script:searchDismissFocusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $script:searchDismissTerminalHwnds = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren($process.MainWindowHandle))
        return -not [WinghosttyAccessibilityNative]::IsWindowVisible($searchNativeHwnd) -and
            $null -ne $script:searchDismissFocused -and
            $script:searchDismissFocused.Current.ProcessId -eq $process.Id -and
            $script:searchDismissFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and
            $script:searchDismissTerminalHwnds -contains $script:searchDismissFocusedHwnd
    }
    $hiddenSearchElement = [System.Windows.Automation.AutomationElement]::FromHandle($searchNativeHwnd)
    if ($null -eq $hiddenSearchElement -or
        $hiddenSearchElement.Current.ControlType -ne [System.Windows.Automation.ControlType]::Edit -or
        -not $hiddenSearchElement.Current.IsOffscreen) {
        throw 'Hidden docked search Edit did not remain an offscreen UIA Edit after dismissal.'
    }

    $settingsCycles = @()
    for ($settingsCycle = 1; $settingsCycle -le 2; $settingsCycle++) {
        Assert-AccessibilityInputOwner -Process $process -Description "settings lifecycle open $settingsCycle"
        if (-not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x11, [uint16]0xBC))) {
            throw "SendInput failed while opening settings cycle ${settingsCycle}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "settings HWND cycle $settingsCycle" -Condition {
            $script:settingsWindowsProbe = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                [uint32]$process.Id,
                'winghostty.win32.settings'
            ))
            return $script:settingsWindowsProbe.Count -eq 1
        }
        $settingsHwnd = $script:settingsWindowsProbe[0]
        $settingsRect = [WinghosttyAccessibilityNative]::WindowRect($settingsHwnd)
        if ($settingsRect.right -le $settingsRect.left -or $settingsRect.bottom -le $settingsRect.top) {
            throw "Settings cycle $settingsCycle has empty native bounds."
        }
        $settingsElement = [System.Windows.Automation.AutomationElement]::FromHandle($settingsHwnd)
        if ($null -eq $settingsElement -or $settingsElement.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
            throw "Settings cycle $settingsCycle exposes no UIA Window root."
        }
        $settingsSectionNames = @('Appearance', 'Terminal', 'Shell', 'Privacy', 'Updates', 'Keybindings', 'Advanced')
        $settingsElements = @($settingsElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ) | ForEach-Object { $_ })
        $sectionButtons = @($settingsElements | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and
            $settingsSectionNames -contains $_.Current.Name
        })
        $observedSectionNames = @($sectionButtons | ForEach-Object { $_.Current.Name } | Sort-Object -Unique)
        if ($sectionButtons.Count -ne $settingsSectionNames.Count -or
            @($settingsSectionNames | Where-Object { $observedSectionNames -notcontains $_ }).Count -ne 0) {
            throw "Settings cycle $settingsCycle section buttons were '$($observedSectionNames -join ', ')'; expected all seven named sections."
        }

        $settingsSectionEvidence = @()
        $settingsNamedTextTotal = 0
        $settingsLabelOverlapComparisons = 0
        $settingsOverlapComparisons = 0
        foreach ($sectionName in $settingsSectionNames) {
            $sectionButton = @($sectionButtons | Where-Object { $_.Current.Name -eq $sectionName })[0]
            $sectionSelection = $null
            if (-not $sectionButton.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$sectionSelection
            )) {
                throw "Settings section '$sectionName' exposes no SelectionItemPattern."
            }
            $sectionSelection.Select()
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description "settings section $sectionName selection" -Condition {
                $script:settingsSelectedSectionNames = @($sectionButtons | Where-Object {
                    $candidateSectionSelection = $null
                    $_.TryGetCurrentPattern(
                        [System.Windows.Automation.SelectionItemPattern]::Pattern,
                        [ref]$candidateSectionSelection
                    ) -and $candidateSectionSelection.Current.IsSelected
                } | ForEach-Object { $_.Current.Name })
                $script:settingsSectionHeaders = @($settingsElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Text
                    )
                ) | Where-Object {
                    $_.Current.Name -eq $sectionName -and
                    -not $_.Current.IsOffscreen -and
                    $_.Current.BoundingRectangle.Width -gt 0 -and
                    $_.Current.BoundingRectangle.Height -gt 0
                })
                return $script:settingsSelectedSectionNames.Count -eq 1 -and
                    $script:settingsSelectedSectionNames[0] -eq $sectionName -and
                    $script:settingsSectionHeaders.Count -ge 1
            }

            $visibleSectionElements = @($settingsElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            ) | Where-Object {
                -not $_.Current.IsOffscreen -and
                $_.Current.BoundingRectangle.Width -gt 0 -and
                $_.Current.BoundingRectangle.Height -gt 0
            })
            $namedSettingsText = @($visibleSectionElements | Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
                -not [string]::IsNullOrWhiteSpace($_.Current.Name)
            })
            if ($namedSettingsText.Count -lt 3) {
                throw "Settings section '$sectionName' exposes only $($namedSettingsText.Count) named, visible UIA text labels."
            }
            if ($sectionName -eq 'Appearance' -and $namedSettingsText.Count -lt 10) {
                throw "Settings Appearance section exposes only $($namedSettingsText.Count) named, visible UIA text labels; expected at least 10."
            }
            for ($leftTextIndex = 0; $leftTextIndex -lt $namedSettingsText.Count; $leftTextIndex++) {
                $leftTextBounds = $namedSettingsText[$leftTextIndex].Current.BoundingRectangle
                for ($rightTextIndex = $leftTextIndex + 1; $rightTextIndex -lt $namedSettingsText.Count; $rightTextIndex++) {
                    $rightTextBounds = $namedSettingsText[$rightTextIndex].Current.BoundingRectangle
                    $overlapWidth = [Math]::Min($leftTextBounds.Right, $rightTextBounds.Right) - [Math]::Max($leftTextBounds.Left, $rightTextBounds.Left)
                    $overlapHeight = [Math]::Min($leftTextBounds.Bottom, $rightTextBounds.Bottom) - [Math]::Max($leftTextBounds.Top, $rightTextBounds.Top)
                    $settingsLabelOverlapComparisons++
                    if ($overlapWidth -gt 2 -and $overlapHeight -gt 2) {
                        throw "Settings section '$sectionName' has overlapping visible labels '$($namedSettingsText[$leftTextIndex].Current.Name)' and '$($namedSettingsText[$rightTextIndex].Current.Name)' (${overlapWidth}x${overlapHeight}px)."
                    }
                }
            }
            $interactiveSettingsControls = @($visibleSectionElements | Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -or
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox -or
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::CheckBox -or
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -or
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button
            })
            if ($interactiveSettingsControls.Count -lt 8) {
                throw "Settings section '$sectionName' exposes only $($interactiveSettingsControls.Count) visible interactive controls; expected seven section buttons plus content/action controls."
            }
            foreach ($labelElement in $namedSettingsText) {
                $labelBounds = $labelElement.Current.BoundingRectangle
                foreach ($controlElement in $interactiveSettingsControls) {
                    $controlBounds = $controlElement.Current.BoundingRectangle
                    $overlapWidth = [Math]::Min($labelBounds.Right, $controlBounds.Right) - [Math]::Max($labelBounds.Left, $controlBounds.Left)
                    $overlapHeight = [Math]::Min($labelBounds.Bottom, $controlBounds.Bottom) - [Math]::Max($labelBounds.Top, $controlBounds.Top)
                    $settingsOverlapComparisons++
                    if ($overlapWidth -gt 2 -and $overlapHeight -gt 2) {
                        throw "Settings section '$sectionName' has overlapping label '$($labelElement.Current.Name)' and $($controlElement.Current.ControlType.ProgrammaticName) '$($controlElement.Current.Name)' (${overlapWidth}x${overlapHeight}px)."
                    }
                }
            }
            $settingsNamedTextTotal += $namedSettingsText.Count
            $settingsSectionEvidence += [ordered]@{
                name = $sectionName
                selected = $true
                visible_named_text = $namedSettingsText.Count
                visible_interactive_controls = $interactiveSettingsControls.Count
            }
        }
        $selectedBeforeFocusOnly = @($sectionButtons | Where-Object {
            $candidateSelection = $null
            $_.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$candidateSelection
            ) -and $candidateSelection.Current.IsSelected
        } | ForEach-Object { $_.Current.Name })
        if ($selectedBeforeFocusOnly.Count -ne 1) {
            throw "Settings cycle $settingsCycle has no unique section before focus-only probe."
        }
        $focusOnlySection = @($sectionButtons | Where-Object {
            $_.Current.Name -ne $selectedBeforeFocusOnly[0]
        })[0]
        $focusOnlySectionHwnd = [IntPtr]$focusOnlySection.Current.NativeWindowHandle
        $focusOnlySection.SetFocus()
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings section focus-only ownership' -Condition {
            $script:settingsFocusOnlyElement = [System.Windows.Automation.AutomationElement]::FocusedElement
            return $null -ne $script:settingsFocusOnlyElement -and
                [System.Windows.Automation.Automation]::Compare($script:settingsFocusOnlyElement, $focusOnlySection) -and
                [WinghosttyAccessibilityNative]::FocusedWindowFor($settingsHwnd) -eq $focusOnlySectionHwnd
        }
        $selectedAfterFocusOnly = @($sectionButtons | Where-Object {
            $candidateSelection = $null
            $_.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$candidateSelection
            ) -and $candidateSelection.Current.IsSelected
        } | ForEach-Object { $_.Current.Name })
        if ($selectedAfterFocusOnly.Count -ne 1 -or $selectedAfterFocusOnly[0] -ne $selectedBeforeFocusOnly[0]) {
            throw "Focusing settings section '$($focusOnlySection.Current.Name)' changed selection from '$($selectedBeforeFocusOnly -join ', ')' to '$($selectedAfterFocusOnly -join ', ')'."
        }
        $settingsCycles += [ordered]@{
            cycle = $settingsCycle
            hwnd = $settingsHwnd.ToInt64()
            name = $settingsElement.Current.Name
            named_visible_text_labels = $settingsNamedTextTotal
            label_overlap_comparisons = $settingsLabelOverlapComparisons
            label_control_overlap_comparisons = $settingsOverlapComparisons
            focus_only_preserved_section = $selectedBeforeFocusOnly[0]
            sections = $settingsSectionEvidence
            bounds = [ordered]@{
                left = $settingsRect.left
                top = $settingsRect.top
                width = $settingsRect.right - $settingsRect.left
                height = $settingsRect.bottom - $settingsRect.top
            }
        }
        [void](Invoke-InteractiveWin11Message `
            -Hwnd $settingsHwnd `
            -Message 0x0010 `
            -WParam ([UIntPtr]::Zero) `
            -LParam ([IntPtr]::Zero) `
            -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
            -Process $process `
            -Description "close settings lifecycle cycle $settingsCycle")
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "settings destruction cycle $settingsCycle" -Condition {
            return @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                [uint32]$process.Id,
                'winghostty.win32.settings'
            )).Count -eq 0
        }
    }
    $settingsLifecycle = [ordered]@{ cycles = $settingsCycles; reopened = $true }

    $ownerProbeStdout = Join-Path $layout.Logs 'interactive-win11-accessibility-settings-owner-stdout.log'
    $ownerProbeStderr = Join-Path $layout.Logs 'interactive-win11-accessibility-settings-owner-stderr.log'
    $ownerProbeClass = "winghostty-accessibility-settings-owner-$([Guid]::NewGuid().ToString('N'))"
    $ownerProbeArguments = @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=$ownerProbeClass"
    )
    $ownerProbeProcess = Start-Process -FilePath $exe -ArgumentList $ownerProbeArguments `
        -WorkingDirectory $repoRoot -RedirectStandardOutput $ownerProbeStdout -RedirectStandardError $ownerProbeStderr -PassThru
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -Description 'settings owner probe main HWND' -Condition {
        $ownerProbeProcess.Refresh()
        return -not $ownerProbeProcess.HasExited -and $ownerProbeProcess.MainWindowHandle -ne [IntPtr]::Zero
    }
    $ownerProbeHost = $ownerProbeProcess.MainWindowHandle
    $ownerProbeHandle = $ownerProbeProcess.Handle
    Assert-AccessibilityInputOwner -Process $ownerProbeProcess -Description 'settings owner probe open'
    if (-not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x11, [uint16]0xBC))) {
        throw "SendInput failed while opening settings owner probe: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings owner probe HWND' -Condition {
        $script:ownerSettingsWindowsProbe = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$ownerProbeProcess.Id,
            'winghostty.win32.settings'
        ))
        return $script:ownerSettingsWindowsProbe.Count -eq 1
    }
    $ownerSettingsHwnd = $script:ownerSettingsWindowsProbe[0]
    $ownerSettingsElement = [System.Windows.Automation.AutomationElement]::FromHandle($ownerSettingsHwnd)
    if ($null -eq $ownerSettingsElement) { throw 'Settings owner probe exposes no UIA root.' }
    $ownerSettingsElements = @($ownerSettingsElement.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $scrollbackEdit = @($ownerSettingsElements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
        $_.Current.Name -eq 'Scrollback limit'
    }) | Select-Object -First 1
    if ($null -eq $scrollbackEdit) { throw 'Settings owner probe cannot find the Scrollback limit Edit.' }
    $scrollbackValuePattern = $null
    if (-not $scrollbackEdit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$scrollbackValuePattern)) {
        throw 'Settings owner probe Scrollback limit Edit has no ValuePattern.'
    }
    [uint64]$originalScrollback = 0
    if (-not [uint64]::TryParse($scrollbackValuePattern.Current.Value, [ref]$originalScrollback)) {
        throw "Settings owner probe has non-numeric Scrollback limit '$($scrollbackValuePattern.Current.Value)'."
    }
    $draftScrollback = if ($originalScrollback -lt [uint64]::MaxValue) { $originalScrollback + 1 } else { $originalScrollback - 1 }
    $draftScrollbackText = $draftScrollback.ToString([Globalization.CultureInfo]::InvariantCulture)
    $scrollbackValuePattern.SetValue($draftScrollbackText)
    $ownerSaveButton = @($ownerSettingsElements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -eq 'Save'
    }) | Select-Object -First 1
    if ($null -eq $ownerSaveButton) { throw 'Settings owner probe cannot find the Save button.' }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings owner probe dirty draft' -Condition {
        return $scrollbackValuePattern.Current.Value -eq $draftScrollbackText -and $ownerSaveButton.Current.IsEnabled
    }
    $ownerSaveButton.SetFocus()
    $ownerSaveHwnd = [IntPtr]$ownerSaveButton.Current.NativeWindowHandle
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings Save focus-only ownership' -Condition {
        $script:ownerSaveFocusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
        return $null -ne $script:ownerSaveFocusedElement -and
            [System.Windows.Automation.Automation]::Compare($script:ownerSaveFocusedElement, $ownerSaveButton) -and
            [WinghosttyAccessibilityNative]::FocusedWindowFor($ownerSettingsHwnd) -eq $ownerSaveHwnd
    }
    if ($scrollbackValuePattern.Current.Value -ne $draftScrollbackText -or -not $ownerSaveButton.Current.IsEnabled) {
        throw 'Focusing the settings Save button unexpectedly committed or discarded the dirty draft.'
    }

    if (-not [WinghosttyAccessibilityNative]::PostMessageW(
        $ownerProbeHost,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )) {
        throw "PostMessageW failed while closing settings owner host: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Start-Sleep -Milliseconds 400
    if ([WinghosttyAccessibilityNative]::IsWindow($ownerProbeHost)) {
        if (-not [WinghosttyAccessibilityNative]::ForceForeground($ownerProbeHost) -or
            -not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x0D))) {
            throw 'Unable to confirm settings owner host close.'
        }
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'settings survival after owner host close' -Condition {
        $ownerProbeProcess.Refresh()
        if ($ownerProbeProcess.HasExited) { throw 'Settings owner probe process exited with its terminal owner.' }
        if (-not [WinghosttyAccessibilityNative]::IsWindow($ownerSettingsHwnd)) {
            throw 'Settings HWND was destroyed with its terminal owner.'
        }
        return -not [WinghosttyAccessibilityNative]::IsWindow($ownerProbeHost)
    }
    $survivingSettingsWindows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
        [uint32]$ownerProbeProcess.Id,
        'winghostty.win32.settings'
    ))
    if ($survivingSettingsWindows.Count -ne 1 -or $survivingSettingsWindows[0] -ne $ownerSettingsHwnd) {
        throw 'Settings owner probe did not preserve the same top-level settings HWND.'
    }
    if ($scrollbackValuePattern.Current.Value -ne $draftScrollbackText -or -not $ownerSaveButton.Current.IsEnabled) {
        throw 'Settings owner probe lost its dirty Scrollback limit draft after owner close.'
    }

    if (-not [WinghosttyAccessibilityNative]::PostMessageW(
        $ownerSettingsHwnd,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )) {
        throw "PostMessageW failed while explicitly closing surviving settings: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings dirty-close dialog' -Condition {
        $script:ownerSettingsDialogsProbe = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$ownerProbeProcess.Id,
            '#32770'
        ))
        return $script:ownerSettingsDialogsProbe.Count -eq 1
    }
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $script:ownerSettingsDialogsProbe[0] `
        -Message 0x0111 `
        -WParam ([UIntPtr]::new([uint64]7)) `
        -LParam ([IntPtr]::Zero) `
        -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
        -Process $ownerProbeProcess `
        -Description 'discard surviving settings dirty draft')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'settings owner probe clean exit' -Condition {
        $ownerProbeProcess.Refresh()
        return $ownerProbeProcess.HasExited
    }
    $ownerProbeExitCode = Get-InteractiveWin11ProcessExitCode -Process $ownerProbeProcess -ProcessHandle $ownerProbeHandle
    if ($ownerProbeExitCode -ne 0) { throw "Settings owner probe exited with code $ownerProbeExitCode." }
    $settingsOwnerLifecycle = [ordered]@{
        process_id = $ownerProbeProcess.Id
        owner_hwnd = $ownerProbeHost.ToInt64()
        settings_hwnd = $ownerSettingsHwnd.ToInt64()
        original_value = $originalScrollback.ToString([Globalization.CultureInfo]::InvariantCulture)
        dirty_value = $draftScrollbackText
        dirty_value_preserved = $true
        save_focus_preserved_dirty_draft = $true
        save_enabled_after_owner_close = $true
        explicitly_discarded = $true
        exit_code = $ownerProbeExitCode
    }

    Send-AccessibilityChord -Keys @([uint16]0x12, [uint16]0x25) -Description 'Alt+Left before sustained output' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'left pane focus before sustained output' -Condition {
        return [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle) -eq $leftPane.Hwnd
    }
    $stressLineCount = 150
    $stressPrefix = "${marker}_STRESS"
    $stressFirstMarker = "${stressPrefix}_FIRST"
    $stressFinalMarker = "${stressPrefix}_150"
    $stressResponsiveMarker = "${stressPrefix}_RESPONSIVE"
    $stressCommand = "cmd.exe /d /c `"echo $stressFirstMarker & for /L %i in (1,1,$stressLineCount) do @echo ${stressPrefix}_%i`""
    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    $process.Refresh()
    $stressBaselineHandles = $process.HandleCount
    $stressBaselineThreads = $process.Threads.Count
    $stressBaselinePrivateBytes = $process.PrivateMemorySize64
    $stressStartedAt = [DateTime]::UtcNow
    Assert-AccessibilityInputOwner -Process $process -Description 'sustained output command'
    if (-not [WinghosttyAccessibilityNative]::SendAsciiText($stressCommand)) {
        throw "SendInput failed for sustained output command: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Send-AccessibilityChord -Keys @([uint16]0x0D) -Description 'sustained output Enter' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(15)) -Description 'sustained output first and final markers through one fresh TextPattern range' -Condition {
        $script:stressFirstMarkerVisible = $false
        $script:stressFinalMarkerVisible = $false
        foreach ($candidateDocument in $documents) {
            $candidatePattern = $null
            if (-not $candidateDocument.TryGetCurrentPattern(
                [System.Windows.Automation.TextPattern]::Pattern,
                [ref]$candidatePattern
            )) { continue }
            $candidateRange = $candidatePattern.DocumentRange
            $candidateText = $candidateRange.GetText(-1)
            if ($candidateText.Contains($stressFirstMarker) -and
                $candidateText.Contains($stressFinalMarker)) {
                $script:stressFirstMarkerVisible = $true
                $script:stressFinalMarkerVisible = $true
                break
            }
        }
        return $script:stressFinalMarkerVisible
    }
    $stressDurationMs = [Math]::Round(([DateTime]::UtcNow - $stressStartedAt).TotalMilliseconds)
    $stressEventCount = [WinghosttyAccessibilityNative]::TextChangedCount
    if ($stressEventCount -lt 1 -or $stressEventCount -gt 300) {
        throw "Sustained output emitted $stressEventCount TextChanged events; expected 1..300 for $stressLineCount lines."
    }
    Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $stressResponsiveMarker -Description 'post-stress responsiveness marker'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'post-stress responsiveness marker through TextPattern' -Condition {
        foreach ($candidateDocument in $documents) {
            $candidatePattern = $null
            if ($candidateDocument.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$candidatePattern) -and
                $candidatePattern.DocumentRange.GetText(-1).Contains($stressResponsiveMarker)) { return $true }
        }
        return $false
    }
    $process.Refresh()
    $stressHandleGrowth = $process.HandleCount - $stressBaselineHandles
    $stressThreadGrowth = $process.Threads.Count - $stressBaselineThreads
    $stressPrivateGrowth = $process.PrivateMemorySize64 - $stressBaselinePrivateBytes
    if ($stressHandleGrowth -gt 64 -or $stressThreadGrowth -gt 8 -or $stressPrivateGrowth -gt 134217728) {
        throw "winghostty resource growth exceeded sustained-output limits (handles=+$stressHandleGrowth, threads=+$stressThreadGrowth, private_bytes=+$stressPrivateGrowth)."
    }
    $sustainedOutputEvidence = [ordered]@{
        line_count = $stressLineCount
        first_marker = $stressFirstMarker
        first_marker_visible = [bool]$script:stressFirstMarkerVisible
        final_marker = $stressFinalMarker
        final_marker_visible = [bool]$script:stressFinalMarkerVisible
        responsive_marker = $stressResponsiveMarker
        responsive_marker_visible = $true
        duration_ms = $stressDurationMs
        text_changed_events = $stressEventCount
        handle_growth = $stressHandleGrowth
        thread_growth = $stressThreadGrowth
        private_bytes_growth = $stressPrivateGrowth
    }

    Assert-AccessibilityInputOwner -Process $process -Description 'settings-open idle soak'
    if (-not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x11, [uint16]0xBC))) {
        throw "SendInput failed while opening settings for idle soak: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings HWND for idle soak' -Condition {
        $script:idleSettingsWindowsProbe = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$process.Id,
            'winghostty.win32.settings'
        ))
        return $script:idleSettingsWindowsProbe.Count -eq 1
    }
    $idleSettingsHwnd = $script:idleSettingsWindowsProbe[0]
    $idleSettingsElement = [System.Windows.Automation.AutomationElement]::FromHandle($idleSettingsHwnd)
    if ($null -eq $idleSettingsElement -or $idleSettingsElement.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
        throw 'Settings idle-soak window exposes no UIA Window root.'
    }
    $idleSettingsName = $idleSettingsElement.Current.Name

    Start-Sleep -Seconds 1
    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    $process.Refresh()
    $idleBaselineHandles = $process.HandleCount
    $idleBaselineThreads = $process.Threads.Count
    $idleBaselinePrivateBytes = $process.PrivateMemorySize64
    $peakHandles = $idleBaselineHandles
    $peakThreads = $idleBaselineThreads
    $peakPrivateBytes = $idleBaselinePrivateBytes
    for ($second = 0; $second -lt $IdleSoakSeconds; $second++) {
        if ([DateTime]::UtcNow -ge $script:accessibilityOverallDeadline) {
            throw "Accessibility validation exceeded its overall deadline during idle soak at ${second}s."
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { throw "winghostty exited during UIA idle soak at ${second}s." }
        if (-not [WinghosttyAccessibilityNative]::IsWindow($idleSettingsHwnd)) {
            throw "Settings window was destroyed during UIA idle soak at ${second}s."
        }
        if ($IdleSoakSeconds -gt 1 -and $second -eq [Math]::Floor($IdleSoakSeconds / 2)) {
            if (-not [WinghosttyAccessibilityNative]::ForceForeground($idleSettingsHwnd) -or
                -not [WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)) {
                throw "Settings/main-window focus round trip failed during UIA idle soak at ${second}s."
            }
        }
        $peakHandles = [Math]::Max($peakHandles, $process.HandleCount)
        $peakThreads = [Math]::Max($peakThreads, $process.Threads.Count)
        $peakPrivateBytes = [Math]::Max($peakPrivateBytes, $process.PrivateMemorySize64)
    }
    $idleEventCount = [WinghosttyAccessibilityNative]::TextChangedCount
    if ($idleEventCount -ne 0) { throw "Terminal emitted $idleEventCount TextChanged events after idle stabilization." }
    $idleHandleGrowth = $peakHandles - $idleBaselineHandles
    $idleThreadGrowth = $peakThreads - $idleBaselineThreads
    $idlePrivateGrowth = $peakPrivateBytes - $idleBaselinePrivateBytes
    if ($idleHandleGrowth -gt 64 -or $idleThreadGrowth -gt 8 -or $idlePrivateGrowth -gt 134217728) {
        throw "winghostty resource growth exceeded idle limits (handles=+$idleHandleGrowth, threads=+$idleThreadGrowth, private_bytes=+$idlePrivateGrowth)."
    }

    $idleMarker = "${marker}_IDLE"
    Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $idleMarker -Description 'post-idle liveness marker'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'post-idle marker through TextPattern' -Condition {
        $script:idleMarkerVisible = $false
        foreach ($candidateDocument in $documents) {
            $candidatePattern = $null
            if ($candidateDocument.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$candidatePattern) -and
                $candidatePattern.DocumentRange.GetText(-1).Contains($idleMarker)) {
                $script:idleMarkerVisible = $true
                break
            }
        }
        return $script:idleMarkerVisible
    }
    if ($idleSettingsElement.Current.Name -ne $idleSettingsName) {
        throw "Settings UIA root changed after idle soak; before='$idleSettingsName', after='$($idleSettingsElement.Current.Name)'."
    }
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $idleSettingsHwnd `
        -Message 0x0010 `
        -WParam ([UIntPtr]::Zero) `
        -LParam ([IntPtr]::Zero) `
        -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
        -Process $process `
        -Description 'close settings after idle soak')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings destruction after idle soak' -Condition {
        return -not [WinghosttyAccessibilityNative]::IsWindow($idleSettingsHwnd)
    }
    $hc = [WinghosttyAccessibilityNative+HIGHCONTRAST]::new()
    $hc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($hc)
    if (-not [WinghosttyAccessibilityNative]::SystemParametersInfo(0x42, $hc.cbSize, [ref]$hc, 0)) {
        throw "SPI_GETHIGHCONTRAST failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $evidence = [ordered]@{
        schema_version = 1
        process_id = $process.Id
        provenance = [ordered]@{
            source_commit = $sourceCommit
            executable_path = $resolvedExe
            executable_sha256 = $binaryHash
            executable_last_write_utc = $binaryLastWriteUtc.ToString('o')
            validation_started_utc = $validationStartedAt.ToString('o')
            source_worktree_dirty = $sourceWorktreeDirty
        }
        high_contrast = [bool]($hc.dwFlags -band 1)
        focused = $focused.Current.Name
        terminal = [ordered]@{
            marker = $marker
            marker_visible = $terminalText.Contains($marker)
            line_text = $terminalLineText
            text_changed_events = $textChangedCount
            rectangle_count = $terminalRectCount
            selection_range_count = $selection.Count
            supported_text_selection = $supportedTextSelection.ToString()
            selection_is_degenerate = $false
            query_only_marker = $queryOnlyMarker
            query_only_acquired_text_pattern_refreshed = $queryOnlyRangeRefreshed
            text_pattern2_client_available = $false
            text_pattern2_client_limitation = 'Windows PowerShell UIAutomationClient 4.0 exposes no TextPattern2 type or registered pattern ID 10024.'
            sustained_output = $sustainedOutputEvidence
            idle_seconds = $IdleSoakSeconds
            idle_text_changed_events = $idleEventCount
            post_idle_marker_visible = [bool]$script:idleMarkerVisible
            peak_handles = $peakHandles
            peak_threads = $peakThreads
            peak_private_bytes = $peakPrivateBytes
            idle_baseline_handles = $idleBaselineHandles
            idle_baseline_threads = $idleBaselineThreads
            idle_baseline_private_bytes = $idleBaselinePrivateBytes
            idle_handle_growth = $idleHandleGrowth
            idle_thread_growth = $idleThreadGrowth
            idle_private_bytes_growth = $idlePrivateGrowth
            settings_open_during_idle = $true
            settings_focus_round_trip = [bool]($IdleSoakSeconds -gt 1)
        }
        splits = [ordered]@{
            baseline = $splitBaseline
            after_ctrl_shift_backslash = $splitAfterRight
            after_ctrl_shift_e = $splitAfterDown
            focus_before_directional_navigation = $focusBeforePaneMove.ToInt64()
            focus_after_directional_navigation = $focusAfterPaneMove.ToInt64()
            exact_focus = $paneFocusResults
        }
        palette = [ordered]@{
            name = $paletteName
            item_count = $paletteItems.Count
            initial_selected_name = $paletteInitialSelectedName
            moved_selected_name = $paletteMovedSelectedName
            selected_name = $paletteMovedSelectedName
            selection_item_selected_events = $paletteSelectionEventCount
            selection_pattern_count = $containerSelection.Count
            help_notification_events = $paletteHelpNotificationCount
            help_notification_kind = $paletteHelpNotificationKind
            help_notification_display_string = $paletteHelpNotificationDisplayString
            unavailable_outcome = 'No matches'
            unavailable_query = $paletteUnavailableQuery
            unavailable_notification_events = $paletteUnavailableNotificationCount
            unavailable_notification_kind = $paletteUnavailableNotificationKind
            unavailable_notification_display_string = $paletteUnavailableNotificationDisplayString
            action_aborted_notification_events = $paletteActionAbortedNotificationCount
            action_aborted_notification_kind = $paletteActionAbortedNotificationKind
            action_aborted_notification_display_string = $paletteActionAbortedNotificationDisplayString
            focused_control_type = $paletteFocusedControlType
            escape_restored_terminal_document = $true
            escape_focused_hwnd = $script:paletteDismissFocusedHwnd.ToInt64()
            keyboard_toggle_restored_terminal_document = $true
            keyboard_toggle_focused_hwnd = $script:paletteToggleFocusedHwnd.ToInt64()
            query_edit = $paletteEditEvidence
            bounds = [ordered]@{ left = $paletteBounds.Left; top = $paletteBounds.Top; width = $paletteBounds.Width; height = $paletteBounds.Height }
            selected_bounds = [ordered]@{ left = $selectedBounds.Left; top = $selectedBounds.Top; width = $selectedBounds.Width; height = $selectedBounds.Height }
        }
        docked_search = [ordered]@{
            edit = $searchEditEvidence
            escape_restored_terminal_document = $true
            escape_focused_hwnd = $script:searchDismissFocusedHwnd.ToInt64()
            native_edit_hidden = $true
            hidden_control_type = $hiddenSearchElement.Current.ControlType.ProgrammaticName
        }
        settings = $settingsLifecycle
        settings_owner_lifecycle = $settingsOwnerLifecycle
        nodes = $nodes
    }

    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
        [System.Windows.Automation.TextPattern]::TextChangedEvent,
        $document,
        $textChangedHandler
    )
    $textChangedRegistered = $false
    $processHandle = $process.Handle
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $process.MainWindowHandle `
        -Message 0x0010 `
        -WParam ([UIntPtr]::Zero) `
        -LParam ([IntPtr]::Zero) `
        -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
        -Process $process `
        -Description 'graceful accessibility close')
    Start-Sleep -Milliseconds 400
    $process.Refresh()
    if (-not $process.HasExited) {
        Assert-AccessibilityInputOwner -Process $process -Description 'confirm graceful accessibility close'
        if (-not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x0D))) {
            throw "SendInput failed while confirming graceful accessibility close: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'graceful winghostty exit' -Condition {
        $process.Refresh()
        return $process.HasExited
    }
    $gracefulExitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
    if ($gracefulExitCode -ne 0) {
        throw "winghostty graceful close returned exit code $gracefulExitCode."
    }
    $evidence['graceful_close'] = [ordered]@{ exited = $true; exit_code = $gracefulExitCode }

    $relaunchStdout = Join-Path $layout.Logs 'interactive-win11-accessibility-relaunch-stdout.log'
    $relaunchStderr = Join-Path $layout.Logs 'interactive-win11-accessibility-relaunch-stderr.log'
    $relaunchProcess = Start-Process -FilePath $exe -ArgumentList @(Get-InteractiveWin11LaunchArguments -Layout $layout) `
        -WorkingDirectory $repoRoot -RedirectStandardOutput $relaunchStdout -RedirectStandardError $relaunchStderr -PassThru
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -Description 'relaunch main HWND' -Condition {
        $relaunchProcess.Refresh()
        return -not $relaunchProcess.HasExited -and $relaunchProcess.MainWindowHandle -ne [IntPtr]::Zero
    }
    $relaunchRoot = [System.Windows.Automation.AutomationElement]::FromHandle($relaunchProcess.MainWindowHandle)
    if ($null -eq $relaunchRoot) { throw 'UI Automation returned no root for relaunched winghostty.' }
    $relaunchDocuments = @()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'relaunch terminal Document' -Condition {
        $script:relaunchDocumentsProbe = @($relaunchRoot.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Document
            )
        ) | ForEach-Object { $_ })
        return $script:relaunchDocumentsProbe.Count -gt 0
    }
    $relaunchDocuments = $script:relaunchDocumentsProbe
    $relaunchTextPattern = $null
    if (-not $relaunchDocuments[0].TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref]$relaunchTextPattern
    )) {
        throw 'Relaunched terminal Document does not expose TextPattern.'
    }
    Assert-AccessibilityInputOwner -Process $relaunchProcess -Description 'relaunch liveness text'
    $relaunchMarker = "${marker}_REOPEN"
    Send-AccessibilityOutputMarker -Process $relaunchProcess -TextPattern $relaunchTextPattern -Marker $relaunchMarker -Description 'relaunch liveness marker'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'relaunch marker through TextPattern' -Condition {
        return $relaunchTextPattern.DocumentRange.GetText(-1).Contains($relaunchMarker)
    }
    $evidence['relaunch'] = [ordered]@{ marker = $relaunchMarker; visible = $true; process_id = $relaunchProcess.Id }
}
catch {
    $runFailure = $_
}
finally {
    if ($editEventsRegistered) {
        try {
            Stop-AccessibilityEditEventCapture
        }
        catch {
            Write-Warning "Failed to remove Edit UIA handlers: $($_.Exception.Message)"
        }
    }
    if ($paletteSelectionRegistered -and $null -ne $paletteSelectionHandler -and $null -ne $root) {
        try {
            [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
                [System.Windows.Automation.SelectionItemPattern]::ElementSelectedEvent,
                $root,
                $paletteSelectionHandler
            )
        }
        catch {
            Write-Warning "Failed to remove palette SelectionItem handler: $($_.Exception.Message)"
        }
    }
    if ($paletteNotificationRegistered) {
        try {
            [WinghosttyAccessibilityNative]::StopNotificationCapture()
        }
        catch {
            Write-Warning "Failed to remove palette Notification handler: $($_.Exception.Message)"
        }
    }
    if ($textChangedRegistered -and $null -ne $textChangedHandler -and $null -ne $document) {
        try {
            [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
                [System.Windows.Automation.TextPattern]::TextChangedEvent,
                $document,
                $textChangedHandler
            )
        }
        catch {
            Write-Warning "Failed to remove terminal TextChanged handler: $($_.Exception.Message)"
        }
    }
    if ($null -ne $relaunchProcess) {
        try { Stop-InteractiveWin11Process -Process $relaunchProcess -Contained }
        catch { $cleanupFailures.Add("relaunch cleanup failed: $($_.Exception.Message)") }
    }
    if ($null -ne $ownerProbeProcess) {
        try { Stop-InteractiveWin11Process -Process $ownerProbeProcess -Contained }
        catch { $cleanupFailures.Add("settings owner probe cleanup failed: $($_.Exception.Message)") }
    }
    try { Stop-InteractiveWin11Process -Process $process -Contained }
    catch { $cleanupFailures.Add("primary cleanup failed: $($_.Exception.Message)") }
}

Start-Sleep -Milliseconds 750
$explorerAfter = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $currentSessionId)
$explorerAfterIdentity = if ($explorerAfter.Count -eq 1) {
    "{0}/{1:o}" -f $explorerAfter[0].Id, $explorerAfter[0].StartTime.ToUniversalTime()
} else {
    "count=$($explorerAfter.Count)"
}
if ($explorerAfter.Count -ne 1 -or $explorerAfterIdentity -ne $explorerBeforeIdentity) {
    $cleanupFailures.Add("Explorer changed during accessibility validation (before=$explorerBeforeIdentity, after=$explorerAfterIdentity).")
}

$machineProcessesAfter = @(Get-Process)
$machineThreadCountAfter = (@($machineProcessesAfter | ForEach-Object { try { $_.Threads.Count } catch { 0 } }) | Measure-Object -Sum).Sum
$machineHandleCountAfter = (@($machineProcessesAfter | ForEach-Object { try { $_.HandleCount } catch { 0 } }) | Measure-Object -Sum).Sum
$winghosttyAfterIdentities = @($machineProcessesAfter | Where-Object ProcessName -eq 'winghostty' | ForEach-Object {
    try { "{0}/{1:o}" -f $_.Id, $_.StartTime.ToUniversalTime() } catch { "pid=$($_.Id)/unavailable" }
})
$unexpectedWinghostty = @($winghosttyAfterIdentities | Where-Object { $_ -notin $winghosttyBeforeIdentities })
$processCountDelta = $machineProcessesAfter.Count - $machineProcesses.Count
$threadCountDelta = $machineThreadCountAfter - $machineThreadCount
$handleCountDelta = $machineHandleCountAfter - $machineHandleCount
$browserSupportCountAfter = @($machineProcessesAfter | Where-Object ProcessName -eq '1Password-BrowserSupport').Count
$conhostCountAfter = @($machineProcessesAfter | Where-Object ProcessName -eq 'conhost').Count
if ($unexpectedWinghostty.Count -gt 0) {
    $cleanupFailures.Add("Accessibility validation leaked winghostty processes: $($unexpectedWinghostty -join ', ').")
}
if ($processCountDelta -gt 100 -or $threadCountDelta -gt 1500 -or $handleCountDelta -gt 50000) {
    $cleanupFailures.Add("Machine resource growth exceeded post-run limits (processes=$processCountDelta, threads=$threadCountDelta, handles=$handleCountDelta).")
}
if ($machineProcessesAfter.Count -gt 1500 -or $machineThreadCountAfter -gt 30000 -or $machineHandleCountAfter -gt 1000000 -or
    $browserSupportCountAfter -gt 256 -or $conhostCountAfter -gt 320) {
    $cleanupFailures.Add("Machine pressure exceeded post-run limits (processes=$($machineProcessesAfter.Count), threads=$machineThreadCountAfter, handles=$machineHandleCountAfter, browser_support=$browserSupportCountAfter, conhost=$conhostCountAfter).")
}

$werQuerySucceeded = $false
$winghosttyWerEvents = @()
try {
    $winghosttyWerEvents = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        StartTime = $validationStartedAt.AddSeconds(-2)
        Id = 1000, 1001
    } -ErrorAction Stop | Where-Object {
        try { $_.Message -match '(?i)\bwinghostty(?:\.exe)?\b' } catch { $false }
    } | ForEach-Object {
        [ordered]@{
            id = $_.Id
            provider = $_.ProviderName
            time_created_utc = $_.TimeCreated.ToUniversalTime().ToString('o')
            record_id = $_.RecordId
        }
    })
    $werQuerySucceeded = $true
}
catch {
    if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
        $werQuerySucceeded = $true
    } else {
        $cleanupFailures.Add("Application Error/WER query failed: $($_.Exception.Message)")
    }
}
if ($winghosttyWerEvents.Count -gt 0) {
    $cleanupFailures.Add("Application Error/WER recorded $($winghosttyWerEvents.Count) winghostty crash event(s).")
}

if ($null -ne $evidence) {
    $evidence['health'] = [ordered]@{
        explorer_before = $explorerBeforeIdentity
        explorer_after = $explorerAfterIdentity
        wer_query_succeeded = $werQuerySucceeded
        winghostty_wer_events = $winghosttyWerEvents
        process_count_delta = $processCountDelta
        thread_count_delta = $threadCountDelta
        handle_count_delta = $handleCountDelta
        final_process_count = $machineProcessesAfter.Count
        final_thread_count = $machineThreadCountAfter
        final_handle_count = $machineHandleCountAfter
        final_browser_support_count = $browserSupportCountAfter
        final_conhost_count = $conhostCountAfter
        unexpected_winghostty_processes = $unexpectedWinghostty
    }
    $evidence['provenance']['validation_completed_utc'] = [DateTime]::UtcNow.ToString('o')
    $evidence['provenance']['duration_ms'] = [Math]::Round(([DateTime]::UtcNow - $validationStartedAt).TotalMilliseconds)
    $evidence['outcome'] = if ($null -eq $runFailure -and $cleanupFailures.Count -eq 0) { 'pass' } else { 'fail' }
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $artifact -Encoding utf8
}

$failureMessages = [System.Collections.Generic.List[string]]::new()
if ($null -ne $runFailure) { $failureMessages.Add($runFailure.Exception.Message) }
foreach ($cleanupFailure in $cleanupFailures) { $failureMessages.Add($cleanupFailure) }
if ($failureMessages.Count -gt 0) {
    throw "Accessibility validation failed: $($failureMessages -join ' | ')"
}

Write-Host "interactive Win11 accessibility: PASS ($artifact)"
