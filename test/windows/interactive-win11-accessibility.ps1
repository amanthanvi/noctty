[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [switch] $ThemeDiagnosticOnly,
    [switch] $ColdDiagnosticOnly,
    [int] $TimeoutSeconds = 20,
    [int] $IdleSoakSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
if ($IdleSoakSeconds -lt 0) { throw 'IdleSoakSeconds must be non-negative.' }
if ($ThemeDiagnosticOnly -and $ColdDiagnosticOnly) {
    throw 'ThemeDiagnosticOnly and ColdDiagnosticOnly are mutually exclusive.'
}
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

function Get-AccessibilityExceptionHResults {
    param([Parameter(Mandatory)][Exception] $Exception)

    $results = [System.Collections.Generic.List[int]]::new()
    $cursor = $Exception
    for ($depth = 0; $null -ne $cursor -and $depth -lt 16; $depth++) {
        $results.Add([int]$cursor.HResult)
        $cursor = $cursor.InnerException
    }
    return $results.ToArray()
}

function Test-AccessibilityTransientHResult {
    param([Parameter(Mandatory)][int] $HResult)

    return $HResult -eq 0x80010001 -or
        $HResult -eq 0x8001010A -or
        $HResult -eq 0x80040201
}

foreach ($knownTransient in @([int]0x80010001, [int]0x8001010A, [int]0x80040201)) {
    if (-not (Test-AccessibilityTransientHResult -HResult $knownTransient)) {
        throw ('Accessibility transient HRESULT classifier rejected 0x{0:X8}.' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($knownTransient), 0))
    }
}
if (Test-AccessibilityTransientHResult -HResult 0) {
    throw 'Accessibility transient HRESULT classifier accepted an unknown result.'
}

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_ACCESSIBILITY_BOOTSTRAPPED) {
    $forwarded = @('-TimeoutSeconds', $TimeoutSeconds.ToString(), '-IdleSoakSeconds', $IdleSoakSeconds.ToString())
    if ($Rebuild) { $forwarded += '-Rebuild' }
    if ($ResetState) { $forwarded += '-ResetState' }
    if ($ThemeDiagnosticOnly) { $forwarded += '-ThemeDiagnosticOnly' }
    if ($ColdDiagnosticOnly) { $forwarded += '-ColdDiagnosticOnly' }
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
    private static int lastSendInputRequested;
    private static int lastSendInputReturned;
    public static int LastSendInputRequested { get { return Volatile.Read(ref lastSendInputRequested); } }
    public static int LastSendInputReturned { get { return Volatile.Read(ref lastSendInputReturned); } }
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
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll")]
    public static extern uint GetSysColor(int index);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out uint value, uint size);
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
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr SendMessageTimeoutW(
        IntPtr hwnd,
        uint message,
        UIntPtr wParam,
        IntPtr lParam,
        uint flags,
        uint timeout,
        out UIntPtr result);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("gdi32.dll")]
    public static extern uint GetPixel(IntPtr hdc, int x, int y);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    private const uint INPUT_KEYBOARD = 1;
    private const uint INPUT_MOUSE = 0;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;
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
    private static int automationFocusChangedCount;
    private static readonly object automationFocusChangedSync = new object();
    private static readonly List<object> automationFocusChangedSenders = new List<object>();
    private static int notificationCount;
    private static readonly object notificationSync = new object();
    private static string notificationKind = "";
    private static string notificationDisplayString = "";
    private static int notificationProcessing;
    private static string notificationActivityId = "";
    private static readonly List<object[]> notificationHistory = new List<object[]>();
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
            RecordNotification(
                NotificationKindName(kind),
                processing,
                displayString ?? "",
                activityId ?? "");
            return 0;
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int ElementFromHandleDelegate(IntPtr self, IntPtr hwnd, out IntPtr element);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetCurrentPropertyValueDelegate(
        IntPtr self,
        int propertyId,
        [MarshalAs(UnmanagedType.Struct)] out object value);
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
    public static void OnAutomationFocusChanged(object sender, EventArgs args) {
        lock (automationFocusChangedSync) {
            automationFocusChangedSenders.Add(sender);
            automationFocusChangedCount++;
        }
    }
    public static void ResetAutomationFocusChangedCount() {
        lock (automationFocusChangedSync) {
            automationFocusChangedSenders.Clear();
            automationFocusChangedCount = 0;
        }
    }
    public static int AutomationFocusChangedCount {
        get {
            lock (automationFocusChangedSync) {
                return automationFocusChangedCount;
            }
        }
    }
    public static object[] AutomationFocusChangedSenders {
        get {
            lock (automationFocusChangedSync) {
                return automationFocusChangedSenders.ToArray();
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
    private static void RecordNotification(
        string kind,
        int processing,
        string displayString,
        string activityId) {
        lock (notificationSync) {
            notificationKind = kind ?? "";
            notificationProcessing = processing;
            notificationDisplayString = displayString ?? "";
            notificationActivityId = activityId ?? "";
            if (notificationHistory.Count == 256) notificationHistory.RemoveAt(0);
            notificationHistory.Add(new object[] {
                notificationKind,
                notificationDisplayString,
                notificationProcessing,
                notificationActivityId
            });
            Interlocked.Increment(ref notificationCount);
        }
    }
    public static void ResetNotificationCount() {
        lock (notificationSync) {
            notificationKind = "";
            notificationProcessing = 0;
            notificationDisplayString = "";
            notificationActivityId = "";
            notificationHistory.Clear();
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
                return new object[] {
                    notificationCount,
                    notificationKind,
                    notificationDisplayString,
                    notificationProcessing,
                    notificationActivityId
                };
            }
        }
    }
    private static T VtableDelegate<T>(IntPtr instance, int slot) where T : class {
        IntPtr vtable = Marshal.ReadIntPtr(instance);
        IntPtr function = Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(function, typeof(T));
    }
    public static int GetCurrentIntProperty(IntPtr hwnd, int propertyId) {
        if (hwnd == IntPtr.Zero) throw new ArgumentException("Element HWND is null.", "hwnd");
        Guid classId = new Guid("E22AD333-B25F-460C-83D0-0581107395C9");
        Guid interfaceId = new Guid("25F700C8-D816-4057-A9DC-3CBDEE77E256");
        IntPtr automation = IntPtr.Zero;
        IntPtr element = IntPtr.Zero;
        int hr = CoCreateInstance(ref classId, IntPtr.Zero, 1, ref interfaceId, out automation);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        try {
            ElementFromHandleDelegate elementFromHandle = VtableDelegate<ElementFromHandleDelegate>(automation, 6);
            hr = elementFromHandle(automation, hwnd, out element);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            GetCurrentPropertyValueDelegate getProperty =
                VtableDelegate<GetCurrentPropertyValueDelegate>(element, 10);
            object value;
            hr = getProperty(element, propertyId, out value);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            return Convert.ToInt32(value);
        }
        finally {
            if (element != IntPtr.Zero) Marshal.Release(element);
            if (automation != IntPtr.Zero) Marshal.Release(automation);
        }
    }
    public static object[][] NotificationHistorySnapshot {
        get {
            lock (notificationSync) {
                return notificationHistory.ToArray();
            }
        }
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
        int requested = inputs.Length;
        int returned = unchecked((int)SendInput((uint)requested, inputs, Marshal.SizeOf(typeof(INPUT))));
        Volatile.Write(ref lastSendInputRequested, requested);
        Volatile.Write(ref lastSendInputReturned, returned);
        return returned == requested;
    }
    public static bool SendUnicodeText(string text) {
        System.Collections.Generic.List<INPUT> inputs = new System.Collections.Generic.List<INPUT>();
        foreach (char value in text) {
            inputs.Add(Key(0, value, KEYEVENTF_UNICODE));
            inputs.Add(Key(0, value, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
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
    public static IntPtr[] TerminalChildren(IntPtr parent) {
        System.Collections.Generic.List<IntPtr> children = new System.Collections.Generic.List<IntPtr>();
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            StringBuilder name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (name.ToString() == "winghostty.win32") children.Add(hwnd);
            return true;
        };
        EnumChildWindows(parent, callback, IntPtr.Zero);
        return children.ToArray();
    }
    public static IntPtr[] VisibleChildrenByClass(IntPtr parent, string expectedClass) {
        System.Collections.Generic.List<IntPtr> children = new System.Collections.Generic.List<IntPtr>();
        EnumProc callback = delegate(IntPtr hwnd, IntPtr data) {
            StringBuilder name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (IsWindowVisible(hwnd) && name.ToString() == expectedClass) children.Add(hwnd);
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
    public static uint WindowStyle(IntPtr hwnd) {
        return unchecked((uint)GetWindowLongPtrW(hwnd, -16).ToInt64());
    }
    public static RECT ClientRectOnScreen(IntPtr hwnd) {
        RECT rect;
        if (!GetClientRect(hwnd, out rect)) throw new System.ComponentModel.Win32Exception();
        POINT topLeft = new POINT();
        topLeft.x = rect.left;
        topLeft.y = rect.top;
        POINT bottomRight = new POINT();
        bottomRight.x = rect.right;
        bottomRight.y = rect.bottom;
        if (!ClientToScreen(hwnd, ref topLeft) || !ClientToScreen(hwnd, ref bottomRight)) {
            throw new System.ComponentModel.Win32Exception();
        }
        rect.left = topLeft.x;
        rect.top = topLeft.y;
        rect.right = bottomRight.x;
        rect.bottom = bottomRight.y;
        return rect;
    }
    public static bool TrySampleWindowClientPixel(IntPtr hwnd, int x, int y, out uint color) {
        color = 0xFFFFFFFF;
        IntPtr hdc = GetDC(hwnd);
        if (hdc == IntPtr.Zero) return false;
        try {
            color = GetPixel(hdc, x, y);
        }
        finally {
            ReleaseDC(hwnd, hdc);
        }
        return color != 0xFFFFFFFF;
    }
    public static uint SampleClientPixel(IntPtr hwnd, int x, int y) {
        uint color;
        if (TrySampleWindowClientPixel(hwnd, x, y, out color)) return color;

        POINT point = new POINT();
        point.x = x;
        point.y = y;
        if (!ClientToScreen(hwnd, ref point)) throw new System.ComponentModel.Win32Exception();
        IntPtr screen = GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            color = GetPixel(screen, point.x, point.y);
            if (color == 0xFFFFFFFF) {
                throw new InvalidOperationException(
                    "GetPixel returned CLR_INVALID for both window and screen DCs.");
            }
            return color;
        }
        finally {
            ReleaseDC(IntPtr.Zero, screen);
        }
    }
    public static uint GetDwmUInt(IntPtr hwnd, uint attribute) {
        uint value;
        int hr = DwmGetWindowAttribute(hwnd, attribute, out value, sizeof(uint));
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        return value;
    }
    public static bool TryGetDwmUInt(IntPtr hwnd, uint attribute, out uint value, out int hresult) {
        hresult = DwmGetWindowAttribute(hwnd, attribute, out value, sizeof(uint));
        return hresult >= 0;
    }
    public static bool IsWindowResponsive(IntPtr hwnd, uint timeoutMs) {
        if (!IsWindow(hwnd)) return false;
        UIntPtr result;
        return SendMessageTimeoutW(
            hwnd,
            0,
            UIntPtr.Zero,
            IntPtr.Zero,
            0x0002,
            timeoutMs,
            out result) != IntPtr.Zero;
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

function Assert-AccessibilityInputOwner(
    [System.Diagnostics.Process] $Process,
    [string] $Description,
    [IntPtr] $ExpectedFocusedHwnd = [IntPtr]::Zero
) {
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
            $focusedOwner -eq [uint32]$Process.Id -and
            ($ExpectedFocusedHwnd -eq [IntPtr]::Zero -or $focusedHwnd -eq $ExpectedFocusedHwnd)) {
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
        $focusedOwner -eq [uint32]$Process.Id -and
        ($ExpectedFocusedHwnd -eq [IntPtr]::Zero -or $focusedHwnd -eq $ExpectedFocusedHwnd)) {
        return
    }

    throw "winghostty does not own expected foreground keyboard focus before $Description (attempts=$attempts/$maxAttempts foreground_hwnd=$foregroundHwnd foreground_owner=$foregroundOwner focused_hwnd=$focusedHwnd focused_owner=$focusedOwner expected_process=$($Process.Id) expected_focused_hwnd=$ExpectedFocusedHwnd)."
}

function Send-AccessibilityChord(
    [uint16[]] $Keys,
    [string] $Description,
    [System.Diagnostics.Process] $Process,
    [IntPtr] $ExpectedFocusedHwnd = [IntPtr]::Zero
) {
    Assert-AccessibilityInputOwner -Process $Process -Description $Description -ExpectedFocusedHwnd $ExpectedFocusedHwnd
    if (-not [WinghosttyAccessibilityNative]::SendChord($Keys)) {
        throw "SendInput failed for ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Start-Sleep -Milliseconds 150
    Assert-AccessibilityInputOwner -Process $Process -Description "post-$Description" -ExpectedFocusedHwnd $ExpectedFocusedHwnd
}

function Get-AccessibilityClientPixelGrid {
    param(
        [Parameter(Mandatory)][IntPtr] $Hwnd,
        [Parameter(Mandatory)][int] $MinX,
        [Parameter(Mandatory)][int] $MaxX,
        [Parameter(Mandatory)][int] $MinY,
        [Parameter(Mandatory)][int] $MaxY,
        [int] $Step = 16
    )

    $grid = [ordered]@{}
    for ($y = $MinY; $y -le $MaxY; $y += $Step) {
        for ($x = $MinX; $x -le $MaxX; $x += $Step) {
            [uint32]$color = 0
            if ([WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                $Hwnd,
                $x,
                $y,
                [ref]$color
            )) {
                $grid["$x,$y"] = [ordered]@{ x = $x; y = $y; color = $color }
            }
        }
    }
    return $grid
}

function Find-AccessibilityClientPixel {
    param(
        [Parameter(Mandatory)][IntPtr] $Hwnd,
        [Parameter(Mandatory)][System.Collections.IDictionary] $OriginalGrid,
        [Parameter(Mandatory)][uint32] $TargetColor
    )

    foreach ($entry in $OriginalGrid.Values) {
        [uint32]$color = 0
        if ([WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
            $Hwnd,
            [int]$entry.x,
            [int]$entry.y,
            [ref]$color
        ) -and $color -eq $TargetColor) {
            return [ordered]@{
                x = [int]$entry.x
                y = [int]$entry.y
                original_color = [uint32]$entry.color
                color = $color
            }
        }
    }
    return $null
}

function New-AccessibilityTempCmdLauncher(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $Description
) {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        throw "TEMP is unavailable for $Description launcher."
    }
    foreach ($line in $Lines) {
        if ($null -eq $line -or $line.Contains("`r") -or $line.Contains("`n")) {
            throw "$Description launcher lines must be non-null single lines."
        }
    }

    $name = "wgh$([Guid]::NewGuid().ToString('N').Substring(0, 8)).cmd"
    $path = Join-Path $env:TEMP $name
    $command = "%TEMP%\$name"
    $expanded = [System.Environment]::ExpandEnvironmentVariables($command)
    if ($command -notmatch '^%TEMP%\\wgh[0-9a-f]{8}\.cmd$' -or
        -not [string]::Equals(
            $expanded,
            $path,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Description launcher path mismatch: command='$command' expanded='$expanded' expected='$path'."
    }

    try {
        [System.IO.File]::WriteAllText(
            $path,
            (@('@echo off') + $Lines) -join "`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        try { [System.IO.File]::Delete($path) } catch {}
        throw
    }
    return [pscustomobject][ordered]@{
        path = $path
        command = $command
        command_length = $command.Length
    }
}

function Send-AccessibilityOutputMarker(
    [System.Diagnostics.Process] $Process,
    $TextPattern,
    [string] $Marker,
    [string] $Description,
    [IntPtr] $ExpectedFocusedHwnd = [IntPtr]::Zero
) {
    if ($Marker -notmatch '^[A-Za-z0-9_]{12,}$') {
        throw "Output marker for $Description must be at least 12 command-safe alphanumeric/underscore characters."
    }
    $launcher = New-AccessibilityTempCmdLauncher `
        -Lines @("@echo $Marker") `
        -Description $Description
    $command = $launcher.command

    try {
        if ($command.Contains($Marker)) {
            throw "Output marker command for $Description contains its literal marker."
        }
        Assert-AccessibilityInputOwner -Process $Process -Description "$Description text" -ExpectedFocusedHwnd $ExpectedFocusedHwnd
        if (-not [WinghosttyAccessibilityNative]::SendUnicodeText($command)) {
            throw "SendInput failed for ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $sendInputRequested = [WinghosttyAccessibilityNative]::LastSendInputRequested
        $sendInputReturned = [WinghosttyAccessibilityNative]::LastSendInputReturned
        $commandEchoEvidence = Wait-AccessibilityTerminalCommandEcho `
            -Process $Process `
            -TextPattern $TextPattern `
            -Command $command `
            -Description $Description `
            -ExpectedFocusedHwnd $ExpectedFocusedHwnd `
            -SendInputRequested $sendInputRequested `
            -SendInputReturned $sendInputReturned
        $preEnterText = $TextPattern.DocumentRange.GetText(-1)
        if ($preEnterText.Contains($Marker)) {
            throw "Terminal exposed output marker for $Description before Enter."
        }
        $preEnterForegroundBefore = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        $preEnterFocusBefore =
            [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
        $preEnterRecoveryCount = if (
            $preEnterForegroundBefore -ne $Process.MainWindowHandle -or
            $preEnterFocusBefore -ne $ExpectedFocusedHwnd
        ) { 1 } else { 0 }
        Assert-AccessibilityInputOwner `
            -Process $Process `
            -Description "$Description pre-Enter" `
            -ExpectedFocusedHwnd $ExpectedFocusedHwnd
        $preEnterForegroundAfter = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        $preEnterFocusAfter =
            [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
        Send-AccessibilityChord -Keys @([uint16]0x0D) -Description "$Description Enter" -Process $Process -ExpectedFocusedHwnd $ExpectedFocusedHwnd
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "$Description launcher output" -Condition {
            $script:outputMarkerLauncherText = $TextPattern.DocumentRange.GetText(-1)
            return $script:outputMarkerLauncherText.Contains($Marker)
        }
        return [pscustomobject][ordered]@{
            short_command = $command
            short_command_length = $launcher.command_length
            send_input_requested = $sendInputRequested
            send_input_returned = $sendInputReturned
            command_echo = $commandEchoEvidence
            pre_enter_foreground_before = $preEnterForegroundBefore.ToInt64()
            pre_enter_focus_before = $preEnterFocusBefore.ToInt64()
            pre_enter_recovery_count = $preEnterRecoveryCount
            pre_enter_foreground_after = $preEnterForegroundAfter.ToInt64()
            pre_enter_focus_after = $preEnterFocusAfter.ToInt64()
            marker_visible_before_launcher_cleanup = $true
        }
    }
    finally {
        try { [System.IO.File]::Delete($launcher.path) } catch {}
    }
}

function Get-AccessibilityOutputNotificationDiagnostic(
    [object[]] $RawNotificationHistory,
    [string] $Marker,
    [int] $FocusMismatchPolls = 0,
    [int] $FocusRecoveryCount = 0,
    [long[]] $StolenForegroundHwnds = @(),
    [long] $LastForegroundHwnd = 0,
    [long] $LastFocusedHwnd = 0
) {
    $rawHistory = @($RawNotificationHistory)
    $matchingHistory = @(
        $rawHistory | Where-Object {
            $_ -is [System.Array] -and
            $_.Count -ge 4 -and
            [string]$_[0] -eq 'ActionCompleted' -and
            [int]$_[2] -eq 2 -and
            [string]$_[3] -eq 'TerminalTextOutput'
        }
    )
    $notificationText = (
        $matchingHistory | ForEach-Object { [string]$_[1] }
    ) -join ''
    return [pscustomobject][ordered]@{
        raw_notification_history = $rawHistory
        notification_history = $matchingHistory
        notification_text = $notificationText
        matched = $matchingHistory.Count -gt 0 -and
            $notificationText.Contains($Marker)
        history = $matchingHistory
        text = $notificationText
        count = $matchingHistory.Count
        focus_mismatch_polls = $FocusMismatchPolls
        focus_recovery_count = $FocusRecoveryCount
        stolen_foreground_hwnds = @($StolenForegroundHwnds)
        last_foreground_hwnd = $LastForegroundHwnd
        last_focused_hwnd = $LastFocusedHwnd
    }
}

function Wait-AccessibilityOwnedOutputNotification(
    [System.Diagnostics.Process] $Process,
    [IntPtr] $ExpectedFocusedHwnd,
    [string] $Marker,
    [string] $Description,
    $Diagnostic = $null
) {
    if ($null -ne $Diagnostic -and
        $Diagnostic -isnot [System.Management.Automation.PSReference]) {
        throw 'Diagnostic must be a [ref] value when supplied.'
    }
    $state = [ordered]@{
        focus_mismatch_polls = 0
        focus_recovery_count = 0
        stolen_foreground_hwnds = [System.Collections.Generic.List[long]]::new()
        last_foreground_hwnd = 0
        last_focused_hwnd = 0
    }
    $diagnosticValue = Get-AccessibilityOutputNotificationDiagnostic `
        -RawNotificationHistory @() `
        -Marker $Marker
    $diagnosticState = [ref] $diagnosticValue
    if ($null -ne $Diagnostic) {
        $Diagnostic.Value = $diagnosticState.Value
    }
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description $Description -Condition {
            $foregroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
            $focusedHwnd =
                [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
            $state.last_foreground_hwnd = $foregroundHwnd.ToInt64()
            $state.last_focused_hwnd = $focusedHwnd.ToInt64()
            $focusMismatch = $foregroundHwnd -ne $Process.MainWindowHandle -or
                $focusedHwnd -ne $ExpectedFocusedHwnd
            if ($focusMismatch) {
                $state.focus_mismatch_polls++
                if ($foregroundHwnd -ne $Process.MainWindowHandle -and
                    -not $state.stolen_foreground_hwnds.Contains(
                        $foregroundHwnd.ToInt64()
                    )) {
                    [void] $state.stolen_foreground_hwnds.Add(
                        $foregroundHwnd.ToInt64()
                    )
                }
                $state.focus_recovery_count++
            }
            $rawHistory = @(
                [WinghosttyAccessibilityNative]::NotificationHistorySnapshot
            )
            $diagnosticState.Value =
                Get-AccessibilityOutputNotificationDiagnostic `
                    -RawNotificationHistory $rawHistory `
                    -Marker $Marker `
                    -FocusMismatchPolls $state.focus_mismatch_polls `
                    -FocusRecoveryCount $state.focus_recovery_count `
                    -StolenForegroundHwnds @($state.stolen_foreground_hwnds) `
                    -LastForegroundHwnd $state.last_foreground_hwnd `
                    -LastFocusedHwnd $state.last_focused_hwnd
            if ($null -ne $Diagnostic) {
                $Diagnostic.Value = $diagnosticState.Value
            }
            if ($focusMismatch) {
                Assert-AccessibilityInputOwner `
                    -Process $Process `
                    -Description "$Description owner recovery" `
                    -ExpectedFocusedHwnd $ExpectedFocusedHwnd
                return $false
            }
            return $diagnosticState.Value.matched
        }
    }
    catch {
        $rawHistory = @(
            [WinghosttyAccessibilityNative]::NotificationHistorySnapshot
        )
        $diagnosticState.Value =
            Get-AccessibilityOutputNotificationDiagnostic `
                -RawNotificationHistory $rawHistory `
                -Marker $Marker `
                -FocusMismatchPolls $state.focus_mismatch_polls `
                -FocusRecoveryCount $state.focus_recovery_count `
                -StolenForegroundHwnds @($state.stolen_foreground_hwnds) `
                -LastForegroundHwnd $state.last_foreground_hwnd `
                -LastFocusedHwnd $state.last_focused_hwnd
        if ($null -ne $Diagnostic) {
            $Diagnostic.Value = $diagnosticState.Value
        }
        throw "$($_.Exception.Message) Diagnostic=$($diagnosticState.Value | ConvertTo-Json -Depth 5 -Compress)"
    }
    return $diagnosticState.Value
}

function Invoke-AccessibilityColdFirstReadProof(
    [System.Diagnostics.Process] $Process,
    $TextPattern,
    [string] $Marker,
    [string] $Description,
    [IntPtr] $ExpectedFocusedHwnd,
    [string] $HelperDirectory,
    [switch] $NotificationCaptureActive
) {
    if ($Marker -notmatch '^[A-Za-z0-9_]{12,}$') {
        throw "Cold output marker for $Description must be at least 12 command-safe alphanumeric/underscore characters."
    }
    $token = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $helperPath = Join-Path $HelperDirectory "cold-output-$token.ps1"
    $readyPath = Join-Path $HelperDirectory "cold-output-$token.ready"
    $triggerPath = Join-Path $HelperDirectory "cold-output-$token.trigger"
    $ackPath = Join-Path $HelperDirectory "cold-output-$token.ack"
    $readyLiteral = $readyPath.Replace("'", "''")
    $triggerLiteral = $triggerPath.Replace("'", "''")
    $ackLiteral = $ackPath.Replace("'", "''")
    $markerLiteral = $Marker.Replace("'", "''")
    $helperText = @(
        '$ErrorActionPreference = ''Stop'''
        "[System.IO.File]::WriteAllText('$readyLiteral', 'ready')"
        '$deadline = [DateTime]::UtcNow.AddSeconds(15)'
        "while (-not [System.IO.File]::Exists('$triggerLiteral')) {"
        "    if ([DateTime]::UtcNow -ge `$deadline) { throw 'cold output trigger timeout' }"
        '    Start-Sleep -Milliseconds 25'
        '}'
        "[Console]::Out.WriteLine('$markerLiteral')"
        '[Console]::Out.Flush()'
        "[System.IO.File]::WriteAllText('$ackLiteral', 'ack')"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText(
        $helperPath,
        $helperText,
        [System.Text.UTF8Encoding]::new($false)
    )

    $launcherPath = $null
    $captureCreated = $false
    try {
        $helperInvocation =
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
            $helperPath.Replace('"', '""') +
            '"'
        $launcher = New-AccessibilityTempCmdLauncher `
            -Lines @($helperInvocation) `
            -Description $Description
        $launcherPath = $launcher.path
        $command = $launcher.command
        if ($command.Contains($Marker)) {
            throw "Cold output helper command for $Description contains its literal marker."
        }
        [WinghosttyAccessibilityNative]::ResetNotificationCount()
        if (-not $NotificationCaptureActive) {
            [WinghosttyAccessibilityNative]::StartNotificationCapture($ExpectedFocusedHwnd)
            $captureCreated = $true
        }

        Assert-AccessibilityInputOwner -Process $Process -Description "$Description text" -ExpectedFocusedHwnd $ExpectedFocusedHwnd
        if (-not [WinghosttyAccessibilityNative]::SendUnicodeText($command)) {
            throw "SendInput failed for ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $sendInputRequested = [WinghosttyAccessibilityNative]::LastSendInputRequested
        $sendInputReturned = [WinghosttyAccessibilityNative]::LastSendInputReturned
        $echoEvidence = Wait-AccessibilityTerminalCommandEcho `
            -Process $Process `
            -TextPattern $TextPattern `
            -Command $command `
            -Description $Description `
            -ExpectedFocusedHwnd $ExpectedFocusedHwnd `
            -SendInputRequested $sendInputRequested `
            -SendInputReturned $sendInputReturned
        Assert-AccessibilityInputOwner -Process $Process -Description "$Description pre-Enter" -ExpectedFocusedHwnd $ExpectedFocusedHwnd
        Send-AccessibilityChord -Keys @([uint16]0x0D) -Description "$Description Enter" -Process $Process -ExpectedFocusedHwnd $ExpectedFocusedHwnd

        # From ready-file observation through the final read, readiness and
        # output completion are proved without querying TextPattern.
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "$Description helper ready file" -Condition {
            return [System.IO.File]::Exists($readyPath)
        }
        $queryInactivityMilliseconds = 1200
        Start-Sleep -Milliseconds $queryInactivityMilliseconds
        $postExpiryTextPatternReadsBeforeFinal = 0
        $preTriggerForegroundBefore = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        $preTriggerFocusBefore =
            [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
        $preTriggerRecoveryCount = if (
            $preTriggerForegroundBefore -ne $Process.MainWindowHandle -or
            $preTriggerFocusBefore -ne $ExpectedFocusedHwnd
        ) { 1 } else { 0 }
        Assert-AccessibilityInputOwner `
            -Process $Process `
            -Description "$Description pre-trigger owner" `
            -ExpectedFocusedHwnd $ExpectedFocusedHwnd
        $preTriggerForegroundAfter = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        $preTriggerFocusAfter =
            [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
        [WinghosttyAccessibilityNative]::ResetNotificationCount()
        [System.IO.File]::WriteAllText($triggerPath, 'trigger')
        $coldNotificationDiagnostic = $null
        try {
            $coldOutputNotification = Wait-AccessibilityOwnedOutputNotification `
                -Process $Process `
                -ExpectedFocusedHwnd $ExpectedFocusedHwnd `
                -Marker $Marker `
                -Description "$Description direct output notification" `
                -Diagnostic ([ref] $coldNotificationDiagnostic)
        }
        catch {
            $diagnostic = [ordered]@{
                ready_exists = [System.IO.File]::Exists($readyPath)
                trigger_exists = [System.IO.File]::Exists($triggerPath)
                ack_exists = [System.IO.File]::Exists($ackPath)
                notification_count = [WinghosttyAccessibilityNative]::NotificationCount
                raw_notification_history =
                    $coldNotificationDiagnostic.raw_notification_history
                notification_history =
                    $coldNotificationDiagnostic.notification_history
                notification_text = $coldNotificationDiagnostic.notification_text
                foreground_hwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow().ToInt64()
                focused_hwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor(
                    $Process.MainWindowHandle
                ).ToInt64()
                expected_focused_hwnd = $ExpectedFocusedHwnd.ToInt64()
                capture_reused = [bool]$NotificationCaptureActive
                pre_trigger_foreground_before = $preTriggerForegroundBefore.ToInt64()
                pre_trigger_focus_before = $preTriggerFocusBefore.ToInt64()
                pre_trigger_recovery_count = $preTriggerRecoveryCount
                pre_trigger_foreground_after = $preTriggerForegroundAfter.ToInt64()
                pre_trigger_focus_after = $preTriggerFocusAfter.ToInt64()
                notification_focus_mismatch_count = $coldNotificationDiagnostic.focus_mismatch_polls
                notification_focus_recovery_count = $coldNotificationDiagnostic.focus_recovery_count
                notification_stolen_foreground_hwnds =
                    $coldNotificationDiagnostic.stolen_foreground_hwnds
                command_echo = $echoEvidence
            }
            throw "$($_.Exception.Message) Diagnostic=$($diagnostic | ConvertTo-Json -Depth 6 -Compress)"
        }

        $finalTextPatternReads = 1
        $finalText = $TextPattern.DocumentRange.GetText(-1)
        if (-not $finalText.Contains($Marker)) {
            throw "Cold first TextPattern read did not contain $Description marker (text='$($finalText.Replace("`r", '\r').Replace("`n", '\n'))')."
        }

        return [pscustomobject][ordered]@{
            marker = $Marker
            marker_visible = $true
            short_command = $command
            short_command_length = $launcher.command_length
            send_input_requested = $sendInputRequested
            send_input_returned = $sendInputReturned
            command_echo = $echoEvidence
            ready_observed_without_uia = $true
            query_inactivity_milliseconds = $queryInactivityMilliseconds
            notification_history_cleared_before_trigger = $true
            notification_capture_reused = [bool]$NotificationCaptureActive
            output_ack_observed = [System.IO.File]::Exists($ackPath)
            pre_trigger_foreground_before = $preTriggerForegroundBefore.ToInt64()
            pre_trigger_focus_before = $preTriggerFocusBefore.ToInt64()
            pre_trigger_recovery_count = $preTriggerRecoveryCount
            pre_trigger_foreground_after = $preTriggerForegroundAfter.ToInt64()
            pre_trigger_focus_after = $preTriggerFocusAfter.ToInt64()
            notification_focus_mismatch_count = $coldOutputNotification.focus_mismatch_polls
            notification_focus_recovery_count = $coldOutputNotification.focus_recovery_count
            notification_stolen_foreground_hwnds =
                $coldOutputNotification.stolen_foreground_hwnds
            output_raw_notification_history =
                $coldOutputNotification.raw_notification_history
            output_notification_history =
                $coldOutputNotification.notification_history
            output_notification_count = $coldOutputNotification.count
            output_notification_text = $coldOutputNotification.text
            post_expiry_text_pattern_reads_before_final = $postExpiryTextPatternReadsBeforeFinal
            final_text_pattern_reads = $finalTextPatternReads
            final_text_length = $finalText.Length
            final_text_tail = $finalText.Substring(
                [Math]::Max(0, $finalText.Length - 160)
            ).Replace("`r", '\r').Replace("`n", '\n')
        }
    }
    finally {
        if ($captureCreated) {
            [WinghosttyAccessibilityNative]::StopNotificationCapture()
        }
        if ([System.IO.File]::Exists($readyPath) -and
            -not [System.IO.File]::Exists($triggerPath)) {
            [System.IO.File]::WriteAllText($triggerPath, 'cleanup')
        }
        foreach ($path in @($launcherPath, $helperPath, $readyPath, $triggerPath, $ackPath)) {
            if ($null -eq $path) { continue }
            try { [System.IO.File]::Delete($path) } catch {}
        }
    }
}

function Invoke-AccessibilityInactiveTabFirstReadProof(
    [System.Diagnostics.Process] $Process,
    [IntPtr] $TabAHwnd,
    [string] $HelperDirectory
) {
    # Background output belongs in the retained terminal snapshot but must not
    # be spoken from an inactive tab. Acquire tab B's provider while active,
    # emit only after switching to A, then make one first read after returning.
    $inactiveTabMarker = "whi$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $inactiveToken = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $inactiveHelperPath = Join-Path $HelperDirectory "inactive-output-$inactiveToken.ps1"
    $inactiveReadyPath = Join-Path $HelperDirectory "inactive-output-$inactiveToken.ready"
    $inactiveTriggerPath = Join-Path $HelperDirectory "inactive-output-$inactiveToken.trigger"
    $inactiveAckPath = Join-Path $HelperDirectory "inactive-output-$inactiveToken.ack"
    $inactiveLauncherPath = $null
    $inactiveCaptureStarted = $false
    $inactiveTabEvidence = $null
    try {
        Send-AccessibilityChord `
            -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x54) `
            -Description 'inactive-output new tab B' `
            -Process $Process
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'inactive-output tab B creation' -Condition {
            $script:inactiveAllTerminals = @(
                [WinghosttyAccessibilityNative]::TerminalChildren($Process.MainWindowHandle)
            )
            $script:inactiveVisibleTerminals = @(
                [WinghosttyAccessibilityNative]::VisibleTerminalChildren($Process.MainWindowHandle)
            )
            return $script:inactiveAllTerminals.Count -eq 2 -and
                $script:inactiveVisibleTerminals.Count -eq 1 -and
                $script:inactiveVisibleTerminals[0] -ne $TabAHwnd
        }
        $inactiveTabHwnd = @(
            $script:inactiveAllTerminals | Where-Object { $_ -ne $TabAHwnd }
        )[0]
        $inactiveTabDocument =
            [System.Windows.Automation.AutomationElement]::FromHandle($inactiveTabHwnd)
        $inactiveTabTextPattern = $null
        if ($null -eq $inactiveTabDocument -or -not $inactiveTabDocument.TryGetCurrentPattern(
            [System.Windows.Automation.TextPattern]::Pattern,
            [ref]$inactiveTabTextPattern
        )) {
            throw 'Inactive-output tab B does not expose TextPattern.'
        }

        $inactiveReadyLiteral = $inactiveReadyPath.Replace("'", "''")
        $inactiveTriggerLiteral = $inactiveTriggerPath.Replace("'", "''")
        $inactiveAckLiteral = $inactiveAckPath.Replace("'", "''")
        $inactiveMarkerLiteral = $inactiveTabMarker.Replace("'", "''")
        $inactiveHelperText = @(
            '$ErrorActionPreference = ''Stop'''
            "[System.IO.File]::WriteAllText('$inactiveReadyLiteral', 'ready')"
            '$deadline = [DateTime]::UtcNow.AddSeconds(15)'
            "while (-not [System.IO.File]::Exists('$inactiveTriggerLiteral')) {"
            "    if ([DateTime]::UtcNow -ge `$deadline) { throw 'inactive output trigger timeout' }"
            '    Start-Sleep -Milliseconds 25'
            '}'
            "[Console]::Out.WriteLine('$inactiveMarkerLiteral')"
            '[Console]::Out.Flush()'
            'Start-Sleep -Milliseconds 250'
            "[System.IO.File]::WriteAllText('$inactiveAckLiteral', 'ack')"
        ) -join "`r`n"
        [System.IO.File]::WriteAllText(
            $inactiveHelperPath,
            $inactiveHelperText,
            [System.Text.UTF8Encoding]::new($false)
        )
        $inactiveHelperInvocation =
            'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' +
            $inactiveHelperPath.Replace('"', '""') +
            '"'
        $inactiveLauncher = New-AccessibilityTempCmdLauncher `
            -Lines @($inactiveHelperInvocation) `
            -Description 'inactive-output helper command'
        $inactiveLauncherPath = $inactiveLauncher.path
        $inactiveCommand = $inactiveLauncher.command
        if ($inactiveCommand.Contains($inactiveTabMarker)) {
            throw 'Inactive-output typed command contains its literal marker.'
        }
        Assert-AccessibilityInputOwner `
            -Process $Process `
            -Description 'inactive-output helper command' `
            -ExpectedFocusedHwnd $inactiveTabHwnd
        if (-not [WinghosttyAccessibilityNative]::SendUnicodeText($inactiveCommand)) {
            throw "SendInput failed for inactive-output helper command: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $inactiveSendInputRequested =
            [WinghosttyAccessibilityNative]::LastSendInputRequested
        $inactiveSendInputReturned =
            [WinghosttyAccessibilityNative]::LastSendInputReturned
        $inactiveEchoEvidence = Wait-AccessibilityTerminalCommandEcho `
            -Process $Process `
            -TextPattern $inactiveTabTextPattern `
            -Command $inactiveCommand `
            -Description 'inactive-output helper command' `
            -ExpectedFocusedHwnd $inactiveTabHwnd `
            -SendInputRequested $inactiveSendInputRequested `
            -SendInputReturned $inactiveSendInputReturned
        Send-AccessibilityChord `
            -Keys @([uint16]0x0D) `
            -Description 'inactive-output helper Enter' `
            -Process $Process `
            -ExpectedFocusedHwnd $inactiveTabHwnd
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'inactive-output helper ready' -Condition {
            return [System.IO.File]::Exists($inactiveReadyPath)
        }

        [WinghosttyAccessibilityNative]::ResetNotificationCount()
        [WinghosttyAccessibilityNative]::StartNotificationCapture($inactiveTabHwnd)
        $inactiveCaptureStarted = $true
        Send-AccessibilityChord `
            -Keys @([uint16]0x11, [uint16]0x21) `
            -Description 'inactive-output switch to tab A' `
            -Process $Process
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'inactive-output tab A focus' -Condition {
            $script:inactiveTabAVisible = @(
                [WinghosttyAccessibilityNative]::VisibleTerminalChildren($Process.MainWindowHandle)
            )
            return $script:inactiveTabAVisible.Count -eq 1 -and
                $script:inactiveTabAVisible[0] -eq $TabAHwnd -and
                [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle) -eq
                    $TabAHwnd
        }
        [WinghosttyAccessibilityNative]::ResetNotificationCount()
        $inactivePostSwitchTextPatternReads = 0
        [System.IO.File]::WriteAllText($inactiveTriggerPath, 'trigger')
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'inactive-output external ack' -Condition {
            return [System.IO.File]::Exists($inactiveAckPath)
        }
        $inactiveQuietIntervalMilliseconds = 750
        $inactiveQuietPollMilliseconds = 50
        $inactiveQuietPollCount = 0
        $inactiveQuietLivenessPollCount = 0
        $inactiveQuietStarted = [DateTime]::UtcNow
        $inactiveQuietDeadline =
            $inactiveQuietStarted.AddMilliseconds($inactiveQuietIntervalMilliseconds)
        $inactiveNotificationDiagnostic = $null
        do {
            $Process.Refresh()
            if ($Process.HasExited -or
                -not [WinghosttyAccessibilityNative]::IsWindowResponsive(
                    $Process.MainWindowHandle,
                    250
                )) {
                throw "Inactive-output app/UI thread became unresponsive during quiet proof after $inactiveQuietLivenessPollCount successful liveness polls."
            }
            $inactiveQuietLivenessPollCount++
            $inactiveNotificationDiagnostic =
                Get-AccessibilityOutputNotificationDiagnostic `
                    -RawNotificationHistory @(
                        [WinghosttyAccessibilityNative]::NotificationHistorySnapshot
                    ) `
                    -Marker $inactiveTabMarker
            if ($inactiveNotificationDiagnostic.matched) {
                throw "Inactive tab B emitted a marker speech notification during quiet proof. Diagnostic=$($inactiveNotificationDiagnostic | ConvertTo-Json -Depth 5 -Compress)"
            }
            if ([WinghosttyAccessibilityNative]::FocusedWindowFor(
                $Process.MainWindowHandle
            ) -ne $TabAHwnd) {
                throw 'Inactive-output tab A lost focus during quiet proof.'
            }
            $inactiveQuietPollCount++
            if ([DateTime]::UtcNow -lt $inactiveQuietDeadline) {
                Start-Sleep -Milliseconds $inactiveQuietPollMilliseconds
            }
        } while ([DateTime]::UtcNow -lt $inactiveQuietDeadline)
        $inactiveQuietElapsedMilliseconds =
            [int]([DateTime]::UtcNow - $inactiveQuietStarted).TotalMilliseconds
        if ($inactiveQuietPollCount -lt 2 -or
            $inactiveQuietLivenessPollCount -ne $inactiveQuietPollCount -or
            $inactivePostSwitchTextPatternReads -ne 0) {
            throw "Inactive-output quiet proof was incomplete: polls=$inactiveQuietPollCount liveness=$inactiveQuietLivenessPollCount text_reads=$inactivePostSwitchTextPatternReads."
        }
        $inactiveFinalNotificationDiagnostic =
            Get-AccessibilityOutputNotificationDiagnostic `
                -RawNotificationHistory @(
                    [WinghosttyAccessibilityNative]::NotificationHistorySnapshot
                ) `
                -Marker $inactiveTabMarker
        if ($inactiveFinalNotificationDiagnostic.matched) {
            throw "Inactive tab B emitted a marker speech notification at the capture boundary. Diagnostic=$($inactiveFinalNotificationDiagnostic | ConvertTo-Json -Depth 5 -Compress)"
        }
        [WinghosttyAccessibilityNative]::StopNotificationCapture()
        $inactiveCaptureStarted = $false
        $inactiveNotificationDiagnostic = $inactiveFinalNotificationDiagnostic
        $inactiveRawNotificationHistory =
            @($inactiveNotificationDiagnostic.raw_notification_history)
        $inactiveNotificationHistory =
            @($inactiveNotificationDiagnostic.notification_history)

        Send-AccessibilityChord `
            -Keys @([uint16]0x11, [uint16]0x22) `
            -Description 'inactive-output return to tab B' `
            -Process $Process
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'inactive-output tab B refocus' -Condition {
            $script:inactiveTabBVisible = @(
                [WinghosttyAccessibilityNative]::VisibleTerminalChildren($Process.MainWindowHandle)
            )
            return $script:inactiveTabBVisible.Count -eq 1 -and
                $script:inactiveTabBVisible[0] -eq $inactiveTabHwnd -and
                [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle) -eq
                    $inactiveTabHwnd
        }
        $inactiveFirstReadCount = 1
        $inactiveFirstText = $inactiveTabTextPattern.DocumentRange.GetText(-1)
        if (-not $inactiveFirstText.Contains($inactiveTabMarker)) {
            throw "Inactive tab B first refocused TextPattern read missed its marker (text='$($inactiveFirstText.Replace("`r", '\r').Replace("`n", '\n'))')."
        }
        $inactiveTabEvidence = [ordered]@{
            marker = $inactiveTabMarker
            tab_a_hwnd = $TabAHwnd.ToInt64()
            tab_b_hwnd = $inactiveTabHwnd.ToInt64()
            command_echo = $inactiveEchoEvidence
            short_command = $inactiveCommand
            short_command_length = $inactiveLauncher.command_length
            send_input_requested = $inactiveSendInputRequested
            send_input_returned = $inactiveSendInputReturned
            post_switch_text_pattern_reads_before_final = $inactivePostSwitchTextPatternReads
            first_refocused_text_pattern_reads = $inactiveFirstReadCount
            first_refocused_text_contains_marker = $true
            inactive_raw_notification_count = $inactiveRawNotificationHistory.Count
            inactive_notification_count = $inactiveNotificationHistory.Count
            inactive_notification_contains_marker = $false
            ack_observed = $true
            quiet_interval_milliseconds = $inactiveQuietIntervalMilliseconds
            quiet_elapsed_milliseconds = $inactiveQuietElapsedMilliseconds
            quiet_poll_count = $inactiveQuietPollCount
            quiet_liveness_poll_count = $inactiveQuietLivenessPollCount
            quiet_text_pattern_reads = $inactivePostSwitchTextPatternReads
            final_capture_snapshot_rejected_marker = $true
        }

        Send-AccessibilityChord `
            -Keys @([uint16]0x11, [uint16]0x10, [uint16]0x57) `
            -Description 'inactive-output close tab B' `
            -Process $Process
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'inactive-output tab A restoration' -Condition {
            $script:inactiveRestoredAll = @(
                [WinghosttyAccessibilityNative]::TerminalChildren($Process.MainWindowHandle)
            )
            $script:inactiveRestoredVisible = @(
                [WinghosttyAccessibilityNative]::VisibleTerminalChildren($Process.MainWindowHandle)
            )
            return $script:inactiveRestoredAll.Count -eq 1 -and
                $script:inactiveRestoredVisible.Count -eq 1 -and
                $script:inactiveRestoredVisible[0] -eq $TabAHwnd -and
                [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle) -eq
                    $TabAHwnd
        }
    }
    finally {
        if ($inactiveCaptureStarted) {
            [WinghosttyAccessibilityNative]::StopNotificationCapture()
        }
        if ([System.IO.File]::Exists($inactiveReadyPath) -and
            -not [System.IO.File]::Exists($inactiveTriggerPath)) {
            [System.IO.File]::WriteAllText($inactiveTriggerPath, 'cleanup')
        }
        foreach ($path in @(
            $inactiveLauncherPath,
            $inactiveHelperPath,
            $inactiveReadyPath,
            $inactiveTriggerPath,
            $inactiveAckPath
        )) {
            if ($null -eq $path) { continue }
            try { [System.IO.File]::Delete($path) } catch {}
        }
    }
    return $inactiveTabEvidence
}

function Wait-AccessibilityTerminalCommandEcho(
    [System.Diagnostics.Process] $Process,
    $TextPattern,
    [string] $Command,
    [string] $Description,
    [IntPtr] $ExpectedFocusedHwnd,
    [int] $SendInputRequested,
    [int] $SendInputReturned,
    [string] $InputTransport = 'send-input'
) {
    $commandTail = $Command.Substring([Math]::Max(0, $Command.Length - 24))
    $diagnostic = [ordered]@{
        command_length = $Command.Length
        command_tail = $commandTail
        input_transport = $InputTransport
        send_input_requested = $SendInputRequested
        send_input_returned = $SendInputReturned
        polls = 0
        focus_mismatch_polls = 0
        focus_recovery_count = 0
        stolen_foreground_hwnds = [System.Collections.Generic.List[long]]::new()
        text_reads = 0
        transient_errors = 0
        provider_reacquires = 0
        max_text_length = 0
        longest_command_prefix = 0
        longest_command_suffix = 0
        last_foreground_hwnd = 0
        last_focused_hwnd = 0
        last_text_tail = ''
        full_echo_observed = $false
    }
    $effectiveDeadline = [DateTime]::UtcNow.AddSeconds(5)
    if ($null -ne $script:accessibilityOverallDeadline -and
        $script:accessibilityOverallDeadline -lt $effectiveDeadline) {
        $effectiveDeadline = $script:accessibilityOverallDeadline
    }
    do {
        $diagnostic.polls++
        $foregroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
        $focusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
        $diagnostic.last_foreground_hwnd = $foregroundHwnd.ToInt64()
        $diagnostic.last_focused_hwnd = $focusedHwnd.ToInt64()
        if ($foregroundHwnd -ne $Process.MainWindowHandle -or
            $focusedHwnd -ne $ExpectedFocusedHwnd) {
            $diagnostic.focus_mismatch_polls++
            if ($foregroundHwnd -ne $Process.MainWindowHandle -and
                -not $diagnostic.stolen_foreground_hwnds.Contains($foregroundHwnd.ToInt64())) {
                [void] $diagnostic.stolen_foreground_hwnds.Add(
                    $foregroundHwnd.ToInt64()
                )
            }
            $diagnostic.focus_recovery_count++
            [void][WinghosttyAccessibilityNative]::ForceForeground($Process.MainWindowHandle)
            $recoveredForegroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
            $recoveredFocusedHwnd =
                [WinghosttyAccessibilityNative]::FocusedWindowFor($Process.MainWindowHandle)
            if ($recoveredForegroundHwnd -eq $Process.MainWindowHandle -and
                $recoveredFocusedHwnd -ne $ExpectedFocusedHwnd) {
                $recoveredDocument =
                    [System.Windows.Automation.AutomationElement]::FromHandle($ExpectedFocusedHwnd)
                if ($null -ne $recoveredDocument) {
                    $recoveredDocument.SetFocus()
                }
            }
            Start-Sleep -Milliseconds 100
            continue
        }
        try {
            $script:terminalCommandEchoText = $TextPattern.DocumentRange.GetText(-1)
        }
        catch {
            $transient = $false
            foreach ($hresult in (Get-AccessibilityExceptionHResults -Exception $_.Exception)) {
                if (Test-AccessibilityTransientHResult -HResult $hresult) {
                    $transient = $true
                    break
                }
            }
            if (-not $transient) { throw }
            $diagnostic.transient_errors++
            $currentDocument =
                [System.Windows.Automation.AutomationElement]::FromHandle($ExpectedFocusedHwnd)
            $currentPattern = $null
            if ($null -eq $currentDocument -or -not $currentDocument.TryGetCurrentPattern(
                [System.Windows.Automation.TextPattern]::Pattern,
                [ref]$currentPattern
            )) {
                Start-Sleep -Milliseconds 100
                continue
            }
            $TextPattern = $currentPattern
            $diagnostic.provider_reacquires++
            Start-Sleep -Milliseconds 100
            continue
        }
        $diagnostic.text_reads++
        $text = $script:terminalCommandEchoText
        $diagnostic.max_text_length = [Math]::Max($diagnostic.max_text_length, $text.Length)
        $tailLength = [Math]::Min(160, $text.Length)
        $diagnostic.last_text_tail = $text.Substring($text.Length - $tailLength).
            Replace("`r", '\r').Replace("`n", '\n')
        $normalizedText = $text.Replace("`r", '').Replace("`n", '')
        for ($length = $Command.Length; $length -gt $diagnostic.longest_command_prefix; $length--) {
            if ($normalizedText.Contains($Command.Substring(0, $length))) {
                $diagnostic.longest_command_prefix = $length
                break
            }
        }
        for ($length = $Command.Length; $length -gt $diagnostic.longest_command_suffix; $length--) {
            if ($normalizedText.Contains($Command.Substring($Command.Length - $length))) {
                $diagnostic.longest_command_suffix = $length
                break
            }
        }
        if ($normalizedText.Contains($Command)) {
            $diagnostic.full_echo_observed = $true
            return [pscustomobject]$diagnostic
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $effectiveDeadline)

    throw "Timed out waiting for $Description full command echo. Diagnostic=$($diagnostic | ConvertTo-Json -Compress)"
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

function Wait-AccessibilityWindowElement(
    [Parameter(Mandatory)][IntPtr] $Hwnd,
    [Parameter(Mandatory)][string] $Description
) {
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "$Description UIA Window root" -Condition {
        try {
            $script:accessibilityWindowElementProbe =
                [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
            return $null -ne $script:accessibilityWindowElementProbe -and
                $script:accessibilityWindowElementProbe.Current.ControlType -eq
                    [System.Windows.Automation.ControlType]::Window
        }
        catch {
            foreach ($hresult in (Get-AccessibilityExceptionHResults -Exception $_.Exception)) {
                if (Test-AccessibilityTransientHResult -HResult $hresult) {
                    $script:accessibilityWindowElementProbe = $null
                    return $false
                }
            }
            throw
        }
    }
    return $script:accessibilityWindowElementProbe
}

function Wait-AccessibilitySettingsProbe(
    [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
    [Parameter(Mandatory)][string] $Description
) {
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "$Description HWND and UIA Window root" -Condition {
            $script:settingsProbeWindows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                [uint32]$Process.Id,
                'winghostty.win32.settings'
            ))
            if ($script:settingsProbeWindows.Count -ne 1) { return $false }
            $script:settingsProbeHwnd = $script:settingsProbeWindows[0]
            try {
                $script:settingsProbeElement =
                    [System.Windows.Automation.AutomationElement]::FromHandle($script:settingsProbeHwnd)
                return $null -ne $script:settingsProbeElement -and
                    $script:settingsProbeElement.Current.ControlType -eq
                        [System.Windows.Automation.ControlType]::Window
            }
            catch {
                foreach ($hresult in (Get-AccessibilityExceptionHResults -Exception $_.Exception)) {
                    if (Test-AccessibilityTransientHResult -HResult $hresult) { return $false }
                }
                throw
            }
        }
    }
    catch {
        $probeAlive = if ($null -eq $script:settingsProbeHwnd) {
            $false
        } else {
            [WinghosttyAccessibilityNative]::IsWindow($script:settingsProbeHwnd)
        }
        $probeType = if ($null -eq $script:settingsProbeElement) {
            '<none>'
        } else {
            try { $script:settingsProbeElement.Current.ControlType.ProgrammaticName } catch { '<unavailable>' }
        }
        throw "$($_.Exception.Message) count=$(@($script:settingsProbeWindows).Count) hwnd=$($script:settingsProbeHwnd) alive=$probeAlive root_type=$probeType."
    }
    return [pscustomobject]@{
        Hwnd = $script:settingsProbeHwnd
        Element = $script:settingsProbeElement
    }
}

function Open-AccessibilitySettingsProbe {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)][string] $Description
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $sectionNames = @('Appearance', 'Terminal', 'Shell', 'Privacy', 'Updates', 'Keybindings', 'Advanced')
    $sentForCurrentNoWindowState = $false
    $lastWindows = @()
    $lastHwnd = [IntPtr]::Zero
    $lastRootType = '<none>'
    $lastSectionCount = 0
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            throw "$Description process exited while opening Settings."
        }
        $lastWindows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$Process.Id,
            'winghostty.win32.settings'
        ))
        if ($lastWindows.Count -gt 0) {
            $sentForCurrentNoWindowState = $false
            if ($lastWindows.Count -eq 1) {
                $lastHwnd = $lastWindows[0]
                $element = $null
                try {
                    if ([WinghosttyAccessibilityNative]::IsWindow($lastHwnd)) {
                        $element =
                            [System.Windows.Automation.AutomationElement]::FromHandle($lastHwnd)
                    }
                    if ($null -ne $element) {
                        $lastRootType = $element.Current.ControlType.ProgrammaticName
                        if ($element.Current.ControlType -eq
                            [System.Windows.Automation.ControlType]::Window) {
                            $descendants = @($element.FindAll(
                                [System.Windows.Automation.TreeScope]::Descendants,
                                [System.Windows.Automation.Condition]::TrueCondition
                            ) | ForEach-Object { $_ })
                            $sections = @($descendants | Where-Object {
                                $_.Current.ControlType -eq
                                    [System.Windows.Automation.ControlType]::RadioButton -and
                                $sectionNames -contains $_.Current.Name
                            })
                            $observedSectionNames = @($sections | ForEach-Object { $_.Current.Name })
                            $lastSectionCount = $sections.Count
                            $stableWindows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                                [uint32]$Process.Id,
                                'winghostty.win32.settings'
                            ))
                            if ($sections.Count -eq $sectionNames.Count -and
                                @($sectionNames | Where-Object {
                                    $observedSectionNames -notcontains $_
                                }).Count -eq 0 -and
                                $stableWindows.Count -eq 1 -and
                                $stableWindows[0] -eq $lastHwnd -and
                                [WinghosttyAccessibilityNative]::IsWindow($lastHwnd)) {
                                return [pscustomobject]@{
                                    Hwnd = $lastHwnd
                                    Element = $element
                                }
                            }
                        }
                    }
                }
                catch {
                    $transient = $false
                    foreach ($hresult in (Get-AccessibilityExceptionHResults -Exception $_.Exception)) {
                        if (Test-AccessibilityTransientHResult -HResult $hresult) {
                            $transient = $true
                            break
                        }
                    }
                    if (-not $transient -and [WinghosttyAccessibilityNative]::IsWindow($lastHwnd)) {
                        throw
                    }
                }
            }
        }
        elseif (-not $sentForCurrentNoWindowState) {
            [void][WinghosttyAccessibilityNative]::ForceForeground($Process.MainWindowHandle)
            $terminalHwnds = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren(
                $Process.MainWindowHandle
            ))
            $focusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor(
                $Process.MainWindowHandle
            )
            $terminalHwnd = if ($terminalHwnds -contains $focusedHwnd) {
                $focusedHwnd
            } elseif ($terminalHwnds.Count -gt 0) {
                $terminalHwnds[0]
            } else {
                [IntPtr]::Zero
            }
            if ($terminalHwnd -ne [IntPtr]::Zero) {
                if ($focusedHwnd -ne $terminalHwnd) {
                    $terminalElement =
                        [System.Windows.Automation.AutomationElement]::FromHandle($terminalHwnd)
                    if ($null -ne $terminalElement) { $terminalElement.SetFocus() }
                }
                if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -eq
                        $Process.MainWindowHandle -and
                    [WinghosttyAccessibilityNative]::FocusedWindowFor(
                        $Process.MainWindowHandle
                    ) -eq $terminalHwnd) {
                    if (-not [WinghosttyAccessibilityNative]::SendChord(
                        @([uint16]0x11, [uint16]0xBC)
                    )) {
                        throw "SendInput failed while opening ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
                    }
                    $sentForCurrentNoWindowState = $true
                }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $alive = if ($lastHwnd -eq [IntPtr]::Zero) {
        $false
    } else {
        [WinghosttyAccessibilityNative]::IsWindow($lastHwnd)
    }
    throw "Timed out opening $Description with one stable Settings HWND/UIA root/section set. count=$($lastWindows.Count) hwnd=$lastHwnd alive=$alive root_type=$lastRootType sections=$lastSectionCount chord_sent_for_zero_state=$sentForCurrentNoWindowState."
}

function Get-AccessibilityScrollbackProbe {
    param(
        [Parameter(Mandatory)] $SettingsProbe,
        [Parameter(Mandatory)][string] $Description
    )

    $elements = @($SettingsProbe.Element.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $terminal = @($elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and
        $_.Current.Name -eq 'Terminal'
    }) | Select-Object -First 1
    $terminalSelection = $null
    if ($null -eq $terminal -or -not $terminal.TryGetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [ref]$terminalSelection
    )) {
        throw "$Description cannot select the Terminal settings section."
    }
    $terminalSelection.Select()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description "$Description Terminal section" -Condition {
        return $terminalSelection.Current.IsSelected
    }
    $elements = @($SettingsProbe.Element.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $edit = @($elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
        $_.Current.Name -eq 'Scrollback limit'
    }) | Select-Object -First 1
    $value = $null
    if ($null -eq $edit -or -not $edit.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref]$value
    )) {
        throw "$Description exposes no Scrollback limit ValuePattern."
    }
    $save = @($elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
        $_.Current.Name -eq 'Save'
    }) | Select-Object -First 1
    if ($null -eq $save) { throw "$Description exposes no Save button." }
    return [pscustomobject]@{ Edit = $edit; Value = $value; Save = $save }
}

function Get-AccessibilityThemeProbe {
    param(
        [Parameter(Mandatory)] $SettingsProbe,
        [Parameter(Mandatory)][string] $Description
    )

    $elements = @($SettingsProbe.Element.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $appearance = @($elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and
        $_.Current.Name -eq 'Appearance'
    }) | Select-Object -First 1
    $appearanceSelection = $null
    if ($null -eq $appearance -or -not $appearance.TryGetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [ref]$appearanceSelection
    )) {
        throw "$Description cannot select the Appearance settings section."
    }
    $appearanceSelection.Select()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description "$Description Appearance section" -Condition {
        return $appearanceSelection.Current.IsSelected
    }
    $elements = @($SettingsProbe.Element.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $combo = @($elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox -and
        $_.Current.Name -eq 'Window theme'
    }) | Select-Object -First 1
    $save = @($elements | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
        $_.Current.Name -eq 'Save'
    }) | Select-Object -First 1
    if ($null -eq $combo -or $null -eq $save) {
        throw "$Description exposes no Window theme combo and Save button."
    }
    $hwnd = [IntPtr]$combo.Current.NativeWindowHandle
    $index = [WinghosttyAccessibilityNative]::SendMessageW(
        $hwnd,
        0x0147,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    ).ToInt64()
    return [pscustomobject]@{
        Combo = $combo
        Hwnd = $hwnd
        Index = $index
        Save = $save
    }
}

function Set-AccessibilityThemeIndex {
    param(
        [Parameter(Mandatory)] $SettingsProbe,
        [Parameter(Mandatory)] $ThemeProbe,
        [Parameter(Mandatory)][int] $Index,
        [Parameter(Mandatory)][string] $Description
    )

    [void][WinghosttyAccessibilityNative]::SendMessageW(
        $ThemeProbe.Hwnd,
        0x014E,
        [UIntPtr]::new([uint32]$Index),
        [IntPtr]::Zero
    )
    [void][WinghosttyAccessibilityNative]::SendMessageW(
        $SettingsProbe.Hwnd,
        0x0111,
        [UIntPtr]::new(0x00010195),
        $ThemeProbe.Hwnd
    )
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description $Description -Condition {
        return [WinghosttyAccessibilityNative]::SendMessageW(
            $ThemeProbe.Hwnd,
            0x0147,
            [UIntPtr]::Zero,
            [IntPtr]::Zero
        ).ToInt64() -eq $Index
    }
}

function Get-AccessibilityDwmUInt {
    param(
        [Parameter(Mandatory)][IntPtr] $Hwnd,
        [Parameter(Mandatory)][uint32] $Attribute,
        [Parameter(Mandatory)][string] $Description
    )

    [uint32]$value = 0
    [int]$hresult = 0
    if (-not [WinghosttyAccessibilityNative]::TryGetDwmUInt(
        $Hwnd,
        $Attribute,
        [ref]$value,
        [ref]$hresult
    )) {
        $unsignedHresult = [BitConverter]::ToUInt32(
            [BitConverter]::GetBytes($hresult),
            0
        )
        throw "$Description DWM attribute $Attribute is unavailable (HRESULT=0x$($unsignedHresult.ToString('X8')))."
    }
    return $value
}

function Invoke-AccessibilityHighContrastProof(
    [Parameter(Mandatory)][System.Diagnostics.Process] $Process,
    [Parameter(Mandatory)][string] $DiagnosticDirectory
) {
    function Get-HighContrastState {
        $value = [WinghosttyAccessibilityNative+HIGHCONTRAST]::new()
        $value.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($value)
        if (-not [WinghosttyAccessibilityNative]::SystemParametersInfo(
            0x42,
            $value.cbSize,
            [ref]$value,
            0
        )) {
            throw "SPI_GETHIGHCONTRAST failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $scheme = if ($value.lpszDefaultScheme -eq [IntPtr]::Zero) {
            $null
        } else {
            [Runtime.InteropServices.Marshal]::PtrToStringUni($value.lpszDefaultScheme)
        }
        return [pscustomobject]@{ flags = [uint32]$value.dwFlags; scheme = $scheme }
    }

    function Set-HighContrastState {
        param([Parameter(Mandatory)] $State)

        $schemePointer = [IntPtr]::Zero
        try {
            if ($null -ne $State.scheme) {
                $schemePointer = [Runtime.InteropServices.Marshal]::StringToHGlobalUni(
                    [string]$State.scheme
                )
            }
            $value = [WinghosttyAccessibilityNative+HIGHCONTRAST]::new()
            $value.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($value)
            $value.dwFlags = [uint32]$State.flags
            $value.lpszDefaultScheme = $schemePointer
            if (-not [WinghosttyAccessibilityNative]::SystemParametersInfo(
                0x43,
                $value.cbSize,
                [ref]$value,
                2
            )) {
                throw "SPI_SETHIGHCONTRAST failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        }
        finally {
            if ($schemePointer -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($schemePointer)
            }
        }
    }

    function Get-DwmProbe {
        param([Parameter(Mandatory)][IntPtr] $Hwnd)

        if (-not [WinghosttyAccessibilityNative]::IsWindow($Hwnd)) {
            throw "DWM probe HWND is no longer alive: $Hwnd."
        }
        $probe = [ordered]@{}
        foreach ($entry in @(
            @{ Name = 'immersive_dark_20'; Attribute = 20; Expected = 0 },
            @{ Name = 'immersive_dark_19'; Attribute = 19; Expected = 0 },
            @{ Name = 'caption_color'; Attribute = 35; Expected = [uint32]::MaxValue },
            @{ Name = 'text_color'; Attribute = 36; Expected = [uint32]::MaxValue },
            @{ Name = 'backdrop_type'; Attribute = 38; Expected = 1 }
        )) {
            [uint32]$value = 0
            [int]$hresult = 0
            $supported = [WinghosttyAccessibilityNative]::TryGetDwmUInt(
                $Hwnd,
                [uint32]$entry.Attribute,
                [ref]$value,
                [ref]$hresult
            )
            $probe[$entry.Name] = [ordered]@{
                attribute = $entry.Attribute
                supported = $supported
                hresult = ('0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($hresult), 0))
                value = if ($supported) { $value } else { $null }
                expected_high_contrast = $entry.Expected
            }
        }
        return $probe
    }

    function Get-DwmHighContrastResetDiagnostic {
        param(
            [Parameter(Mandatory)] $Before,
            [Parameter(Mandatory)] $During
        )

        $failures = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @(
            'immersive_dark_20',
            'immersive_dark_19',
            'caption_color',
            'text_color',
            'backdrop_type'
        )) {
            $beforeValue = $Before[$name]
            $duringValue = $During[$name]
            if ($beforeValue.supported -and -not $duringValue.supported) {
                [void] $failures.Add(
                    "DWM attribute $($duringValue.attribute) became unreadable under High Contrast ($($duringValue.hresult))."
                )
            }
            if ($duringValue.supported -and
                [uint32]$duringValue.value -ne [uint32]$duringValue.expected_high_contrast) {
                [void] $failures.Add(
                    "DWM attribute $($duringValue.attribute) High Contrast reset mismatch: actual=0x$(([uint32]$duringValue.value).ToString('X8')) expected=0x$(([uint32]$duringValue.expected_high_contrast).ToString('X8'))."
                )
            }
            if (-not $beforeValue.supported -and -not $duringValue.supported -and
                $beforeValue.hresult -ne $duringValue.hresult) {
                [void] $failures.Add(
                    "DWM attribute $($duringValue.attribute) unsupported result changed across High Contrast: before=$($beforeValue.hresult) during=$($duringValue.hresult)."
                )
            }
        }
        if (-not $During.immersive_dark_20.supported -and
            -not $During.immersive_dark_19.supported -and
            ($During.immersive_dark_20.hresult -ne '0x80070057' -or
                $During.immersive_dark_19.hresult -ne '0x80070057')) {
            [void] $failures.Add(
                'Both immersive-dark DWM reads are unavailable without the expected E_INVALIDARG capability result.'
            )
        }
        return [pscustomobject][ordered]@{
            exact = $failures.Count -eq 0
            failures = @($failures)
        }
    }

    function Get-DwmExactDiagnostic {
        param(
            [Parameter(Mandatory)] $Expected,
            [Parameter(Mandatory)] $Actual
        )

        $attributes = [ordered]@{}
        $exact = $true
        foreach ($name in @(
            'immersive_dark_20',
            'immersive_dark_19',
            'caption_color',
            'text_color',
            'backdrop_type'
        )) {
            $expectedValue = $Expected[$name]
            $actualValue = $Actual[$name]
            $supportedExact = [bool]$expectedValue.supported -eq
                [bool]$actualValue.supported
            $hresultExact = [string]$expectedValue.hresult -ceq
                [string]$actualValue.hresult
            $valueExact = if ($expectedValue.supported -and $actualValue.supported) {
                [uint32]$expectedValue.value -eq [uint32]$actualValue.value
            } else {
                $true
            }
            $attributeExact = $supportedExact -and $hresultExact -and $valueExact
            $attributes[$name] = [ordered]@{
                exact = $attributeExact
                supported_exact = $supportedExact
                hresult_exact = $hresultExact
                value_exact = $valueExact
                expected = $expectedValue
                actual = $actualValue
            }
            $exact = $exact -and $attributeExact
        }
        return [ordered]@{
            exact = $exact
            attributes = $attributes
        }
    }

    function Get-SettingsProbeDiagnostic {
        param([Parameter(Mandatory)] $Probe)

        $diagnostic = [ordered]@{
            top_level_count_exact = $false
            original_hwnd_exact = $false
            hwnd_alive = [WinghosttyAccessibilityNative]::IsWindow($Probe.Hwnd)
            uia_window_root = $false
            section_count_exact = $false
            section_names_exact = $false
            observed_section_names = @()
            stable = $false
            error = $null
        }
        try {
            $windows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                [uint32]$Process.Id,
                'winghostty.win32.settings'
            ))
            $diagnostic.top_level_hwnds = @($windows | ForEach-Object { $_.ToInt64() })
            $diagnostic.top_level_count_exact = $windows.Count -eq 1
            $diagnostic.original_hwnd_exact = $windows.Count -eq 1 -and
                $windows[0] -eq $Probe.Hwnd
            if (-not $diagnostic.original_hwnd_exact -or -not $diagnostic.hwnd_alive) {
                return $diagnostic
            }
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($Probe.Hwnd)
            $diagnostic.uia_window_root = $null -ne $root -and
                $root.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window
            if (-not $diagnostic.uia_window_root) { return $diagnostic }
            $sectionNames = @(
                'Appearance',
                'Terminal',
                'Shell',
                'Privacy',
                'Updates',
                'Keybindings',
                'Advanced'
            )
            $sections = @($root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            ) | Where-Object {
                $_.Current.ControlType -eq
                    [System.Windows.Automation.ControlType]::RadioButton -and
                $sectionNames -contains $_.Current.Name
            })
            $observedNames = @($sections | ForEach-Object { $_.Current.Name })
            $diagnostic.observed_section_names = $observedNames
            $diagnostic.section_count_exact = $sections.Count -eq $sectionNames.Count
            $diagnostic.section_names_exact =
                @($sectionNames | Where-Object { $observedNames -notcontains $_ }).Count -eq 0
            $diagnostic.stable = $diagnostic.top_level_count_exact -and
                $diagnostic.original_hwnd_exact -and
                $diagnostic.hwnd_alive -and
                $diagnostic.uia_window_root -and
                $diagnostic.section_count_exact -and
                $diagnostic.section_names_exact
            return $diagnostic
        }
        catch {
            $diagnostic.error = $_.Exception.Message
            $diagnostic.hwnd_alive =
                [WinghosttyAccessibilityNative]::IsWindow($Probe.Hwnd)
            return $diagnostic
        }
    }

    function Get-SettingsSemanticSnapshots {
        param([Parameter(Mandatory)][IntPtr] $SettingsHwnd)

        $targets = @(
            @($SettingsHwnd) + @([WinghosttyAccessibilityNative]::VisibleChildrenByClass(
                $SettingsHwnd,
                'Static'
            ))
        )
        $snapshots = [System.Collections.Generic.List[object]]::new()
        foreach ($targetHwnd in $targets) {
            $targetClass = [WinghosttyAccessibilityNative]::WindowClass($targetHwnd)
            if ($targetClass -ne 'Static' -and $targetHwnd -ne $SettingsHwnd) { continue }
            $targetRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen($targetHwnd)
            $width = $targetRect.right - $targetRect.left
            $height = $targetRect.bottom - $targetRect.top
            if ($width -le 8 -or $height -le 8) { continue }
            foreach ($yOrdinal in 1..5) {
                $y = [Math]::Min($height - 5, [Math]::Max(4, [int]($height * $yOrdinal / 6)))
                foreach ($xOrdinal in 1..5) {
                    $x = [Math]::Min($width - 5, [Math]::Max(4, [int]($width * $xOrdinal / 6)))
                    [uint32]$color = 0
                    if (-not [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                        $targetHwnd,
                        $x,
                        $y,
                        [ref]$color
                    )) {
                        continue
                    }
                    $screenPoint = [WinghosttyAccessibilityNative+POINT]::new()
                    $screenPoint.x = $targetRect.left + $x
                    $screenPoint.y = $targetRect.top + $y
                    if ([WinghosttyAccessibilityNative]::WindowFromPoint($screenPoint) -ne
                        $targetHwnd) {
                        continue
                    }
                    $snapshots.Add([pscustomobject]@{
                        hwnd = $targetHwnd
                        class_name = $targetClass
                        client_x = $x
                        client_y = $y
                        screen_x = $screenPoint.x
                        screen_y = $screenPoint.y
                        baseline_color = $color
                    })
                }
            }
        }
        return @($snapshots)
    }

    function Get-SettingsSemanticPixelDiagnostic {
        param(
            [Parameter(Mandatory)] $Pixel,
            [Parameter(Mandatory)][uint32] $ExpectedColor
        )

        $diagnostic = [ordered]@{
            hwnd = $Pixel.hwnd.ToInt64()
            hwnd_alive = [WinghosttyAccessibilityNative]::IsWindow($Pixel.hwnd)
            expected_class = $Pixel.class_name
            actual_class = $null
            class_exact = $false
            client_x = [int]$Pixel.client_x
            client_y = [int]$Pixel.client_y
            client_coordinate_in_bounds = $false
            baseline_screen_x = [int]$Pixel.screen_x
            baseline_screen_y = [int]$Pixel.screen_y
            current_screen_x = $null
            current_screen_y = $null
            client_rect = $null
            window_from_point_hwnd = 0
            window_from_point_exact = $false
            expected_color = [uint32]$ExpectedColor
            actual_color = $null
            color_sample_valid = $false
            color_exact = $false
            exact = $false
            error = $null
        }
        if (-not $diagnostic.hwnd_alive) { return $diagnostic }
        try {
            $diagnostic.actual_class =
                [WinghosttyAccessibilityNative]::WindowClass($Pixel.hwnd)
            $diagnostic.class_exact =
                $diagnostic.actual_class -ceq $Pixel.class_name
            $rect = [WinghosttyAccessibilityNative]::ClientRectOnScreen($Pixel.hwnd)
            $diagnostic.client_rect = [ordered]@{
                left = $rect.left
                top = $rect.top
                right = $rect.right
                bottom = $rect.bottom
            }
            $width = $rect.right - $rect.left
            $height = $rect.bottom - $rect.top
            $diagnostic.client_coordinate_in_bounds =
                $Pixel.client_x -ge 0 -and $Pixel.client_x -lt $width -and
                $Pixel.client_y -ge 0 -and $Pixel.client_y -lt $height
            $point = [WinghosttyAccessibilityNative+POINT]::new()
            $point.x = $rect.left + [int]$Pixel.client_x
            $point.y = $rect.top + [int]$Pixel.client_y
            $diagnostic.current_screen_x = $point.x
            $diagnostic.current_screen_y = $point.y
            $hitHwnd = [WinghosttyAccessibilityNative]::WindowFromPoint($point)
            $diagnostic.window_from_point_hwnd = $hitHwnd.ToInt64()
            $diagnostic.window_from_point_exact = $hitHwnd -eq $Pixel.hwnd
            [uint32]$color = 0
            $diagnostic.color_sample_valid =
                [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                    $Pixel.hwnd,
                    [int]$Pixel.client_x,
                    [int]$Pixel.client_y,
                    [ref]$color
                )
            if ($diagnostic.color_sample_valid) {
                $diagnostic.actual_color = $color
                $diagnostic.color_exact = $color -eq $ExpectedColor
            }
            $diagnostic.exact = $diagnostic.hwnd_alive -and
                $diagnostic.class_exact -and
                $diagnostic.client_coordinate_in_bounds -and
                $diagnostic.window_from_point_exact -and
                $diagnostic.color_sample_valid -and
                $diagnostic.color_exact
            return $diagnostic
        }
        catch {
            $diagnostic.error = $_.Exception.Message
            return $diagnostic
        }
    }

    function Write-HighContrastRestoreDiagnostic {
        param(
            [Parameter(Mandatory)] $Diagnostic,
            [Parameter(Mandatory)][string] $Path
        )

        $json = $Diagnostic | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText(
            $Path,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    $before = [WinghosttyAccessibilityNative+HIGHCONTRAST]::new()
    $before.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($before)
    if (-not [WinghosttyAccessibilityNative]::SystemParametersInfo(
        0x42,
        $before.cbSize,
        [ref]$before,
        0
    )) {
        throw "SPI_GETHIGHCONTRAST targeted preflight failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $beforeScheme = if ($before.lpszDefaultScheme -eq [IntPtr]::Zero) {
        $null
    } else {
        [Runtime.InteropServices.Marshal]::PtrToStringUni($before.lpszDefaultScheme)
    }
    $beforeState = [pscustomobject]@{
        flags = [uint32]$before.dwFlags
        scheme = $beforeScheme
    }
    $hostWindows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
        [uint32]$Process.Id,
        'winghostty.win32.host'
    ))
    if ($hostWindows.Count -ne 1) {
        throw "High Contrast proof requires one native host HWND; found $($hostWindows.Count)."
    }
    $hostHwnd = $hostWindows[0]
    $settings = Open-AccessibilitySettingsProbe `
        -Process $Process `
        -Description 'High Contrast baseline Settings'
    $settingsHwnd = $settings.Hwnd
    $beforeHostDwm = Get-DwmProbe -Hwnd $hostHwnd
    $beforeSettingsDwm = Get-DwmProbe -Hwnd $settingsHwnd
    $semanticSnapshots = @(Get-SettingsSemanticSnapshots -SettingsHwnd $settingsHwnd)
    if ($semanticSnapshots.Count -eq 0) {
        throw 'High Contrast baseline Settings exposed no stable Static/parent semantic snapshots.'
    }
    $recoveryPath = Join-Path (
        [System.IO.Path]::GetTempPath()
    ) ("winghostty-high-contrast-recovery-$PID-$([Guid]::NewGuid().ToString('N')).json")
    $restoreDiagnosticPath = Join-Path `
        $DiagnosticDirectory `
        'high-contrast-restore-diagnostic.json'
    $beforeState | ConvertTo-Json | Set-Content -LiteralPath $recoveryPath -Encoding utf8
    if (-not [System.IO.File]::Exists($recoveryPath)) {
        throw 'High Contrast recovery snapshot was not persisted.'
    }
    $result = [ordered]@{ restored = $false }
    $toggleAttempted = $false
    $semanticPixel = $null
    $semanticHitCount = 0
    $changedSemanticHitCount = 0
    try {
        $toggleAttempted = $true
        Set-HighContrastState -State ([pscustomobject]@{
            flags = [uint32]($beforeState.flags -bor 1)
            scheme = $beforeState.scheme
        })
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'targeted High Contrast activation' -Condition {
            $script:targetedHcActive = Get-HighContrastState
            return [bool]($script:targetedHcActive.flags -band 1)
        }
        $script:duringDwm = $null
        try {
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'host High Contrast DWM convergence' -Condition {
                $Process.Refresh()
                $currentHostWindows = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                    [uint32]$Process.Id,
                    'winghostty.win32.host'
                ))
                if ($Process.HasExited -or $currentHostWindows.Count -ne 1 -or
                    $currentHostWindows[0] -ne $hostHwnd -or
                    -not [WinghosttyAccessibilityNative]::IsWindow($hostHwnd)) {
                    return $false
                }
                $script:duringDwm = Get-DwmProbe -Hwnd $hostHwnd
                return (Get-DwmHighContrastResetDiagnostic `
                    -Before $beforeHostDwm `
                    -During $script:duringDwm).exact
            }
        }
        catch {
            $finalDwm = if ($null -eq $script:duringDwm) {
                '<unavailable>'
            } else {
                $script:duringDwm | ConvertTo-Json -Depth 4 -Compress
            }
            throw "Host High Contrast DWM state did not converge on stable HWND $hostHwnd. final=$finalDwm. $($_.Exception.Message)"
        }
        $duringDwm = $script:duringDwm
        $dwmResetDiagnostic = Get-DwmHighContrastResetDiagnostic `
            -Before $beforeHostDwm `
            -During $duringDwm
        if (-not $dwmResetDiagnostic.exact) {
            throw ($dwmResetDiagnostic.failures -join ' ')
        }
        $buttonFace = [WinghosttyAccessibilityNative]::GetSysColor(15)
        $script:semanticHitCount = 0
        $script:changedSemanticHitCount = 0
        $script:semanticPixel = $null
        try {
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'same Settings HWND High Contrast semantic system-role pixel' -Condition {
                if (-not (Get-SettingsProbeDiagnostic -Probe $settings).stable) {
                    return $false
                }
                $hits = @($semanticSnapshots | Where-Object {
                    (Get-SettingsSemanticPixelDiagnostic `
                        -Pixel $_ `
                        -ExpectedColor $buttonFace).exact
                })
                $changedHits = @($hits | Where-Object {
                    [uint32]$_.baseline_color -ne $buttonFace
                })
                $script:semanticHitCount = $hits.Count
                $script:changedSemanticHitCount = $changedHits.Count
                $script:semanticPixel = if ($changedHits.Count -gt 0) {
                    $changedHits[0]
                } elseif ($hits.Count -gt 0) {
                    $hits[0]
                } else {
                    $null
                }
                return $null -ne $script:semanticPixel
            }
        }
        catch {
            throw "High Contrast semantic pixel selection failed: candidates=$($semanticSnapshots.Count) hits=$($script:semanticHitCount) changed_hits=$($script:changedSemanticHitCount). $($_.Exception.Message)"
        }
        $semanticPixel = $script:semanticPixel
        $semanticHitCount = $script:semanticHitCount
        $changedSemanticHitCount = $script:changedSemanticHitCount
        $result = [ordered]@{
            os_build = [Environment]::OSVersion.Version.Build
            host_hwnd = $hostHwnd.ToInt64()
            settings_hwnd = $settingsHwnd.ToInt64()
            dwm_before = $beforeHostDwm
            settings_dwm_before = $beforeSettingsDwm
            dwm_high_contrast = $duringDwm
            settings_system_color = $buttonFace
            settings_sample_hwnd = $semanticPixel.hwnd.ToInt64()
            settings_sample_class = $semanticPixel.class_name
            settings_sample_x = $semanticPixel.client_x
            settings_sample_y = $semanticPixel.client_y
            settings_sample_screen_x = $semanticPixel.screen_x
            settings_sample_screen_y = $semanticPixel.screen_y
            settings_semantic_candidate_count = $semanticSnapshots.Count
            settings_semantic_hit_count = $semanticHitCount
            settings_changed_semantic_hit_count = $changedSemanticHitCount
            settings_normal_color = $semanticPixel.baseline_color
            restore_diagnostic_path = $restoreDiagnosticPath
            restored = $false
        }
    }
    finally {
        try {
            Set-HighContrastState -State $beforeState
            $verifyState = Get-HighContrastState
            if ($verifyState.flags -ne $beforeState.flags -or
                $verifyState.scheme -cne $beforeState.scheme) {
                $stateDiagnostic = [ordered]@{
                    captured_utc = [DateTime]::UtcNow.ToString('o')
                    phase = 'exact-spi-restore'
                    recovery_path = $recoveryPath
                    expected_state = $beforeState
                    actual_state = $verifyState
                    exact_spi_state = $false
                }
                Write-HighContrastRestoreDiagnostic `
                    -Diagnostic $stateDiagnostic `
                    -Path $restoreDiagnosticPath
                throw "Targeted High Contrast state was not restored exactly. diagnostic=$restoreDiagnosticPath recovery=$recoveryPath"
            }
            if ($toggleAttempted -and $null -ne $semanticPixel) {
                $compoundRestoreDeadline = [DateTime]::UtcNow.AddSeconds(10)
                $script:hcRestorePollCount = 0
                $script:hcRestoreDiagnostic = $null
                try {
                    Wait-AccessibilityCondition -Deadline $compoundRestoreDeadline -Description 'compound post-High Contrast app reversal' -Condition {
                        $script:hcRestorePollCount++
                        $Process.Refresh()
                        $currentHostWindows = @(
                            [WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                                [uint32]$Process.Id,
                                'winghostty.win32.host'
                            )
                        )
                        $hostCountExact = $currentHostWindows.Count -eq 1
                        $hostOriginalExact = $hostCountExact -and
                            $currentHostWindows[0] -eq $hostHwnd
                        $hostAlive = [WinghosttyAccessibilityNative]::IsWindow($hostHwnd)
                        $hostDwm = $null
                        $hostDwmError = $null
                        $hostDwmExact = $false
                        $hostDwmDiagnostic = $null
                        if ($hostAlive) {
                            try {
                                $hostDwm = Get-DwmProbe -Hwnd $hostHwnd
                                $hostDwmDiagnostic = Get-DwmExactDiagnostic `
                                    -Expected $beforeHostDwm `
                                    -Actual $hostDwm
                                $hostDwmExact = [bool]$hostDwmDiagnostic.exact
                            }
                            catch {
                                $hostDwmError = $_.Exception.Message
                            }
                        }

                        $settingsDiagnostic =
                            Get-SettingsProbeDiagnostic -Probe $settings
                        $settingsDwm = $null
                        $settingsDwmError = $null
                        $settingsDwmExact = $false
                        $settingsDwmDiagnostic = $null
                        if ($settingsDiagnostic.hwnd_alive) {
                            try {
                                $settingsDwm = Get-DwmProbe -Hwnd $settingsHwnd
                                $settingsDwmDiagnostic = Get-DwmExactDiagnostic `
                                    -Expected $beforeSettingsDwm `
                                    -Actual $settingsDwm
                                $settingsDwmExact =
                                    [bool]$settingsDwmDiagnostic.exact
                            }
                            catch {
                                $settingsDwmError = $_.Exception.Message
                            }
                        }

                        $semanticDiagnostic =
                            Get-SettingsSemanticPixelDiagnostic `
                                -Pixel $semanticPixel `
                                -ExpectedColor (
                                    [uint32]$semanticPixel.baseline_color
                                )
                        $foregroundHwnd =
                            [WinghosttyAccessibilityNative]::GetForegroundWindow()
                        $hostFocusedHwnd = if ($hostAlive) {
                            [WinghosttyAccessibilityNative]::FocusedWindowFor($hostHwnd)
                        } else {
                            [IntPtr]::Zero
                        }
                        $settingsFocusedHwnd = if ($settingsDiagnostic.hwnd_alive) {
                            [WinghosttyAccessibilityNative]::FocusedWindowFor(
                                $settingsHwnd
                            )
                        } else {
                            [IntPtr]::Zero
                        }
                        $compoundExact = -not $Process.HasExited -and
                            $hostCountExact -and
                            $hostOriginalExact -and
                            $hostAlive -and
                            $settingsDiagnostic.stable -and
                            $hostDwmExact -and
                            $settingsDwmExact -and
                            $semanticDiagnostic.exact
                        $script:hcRestoreDiagnostic = [ordered]@{
                            captured_utc = [DateTime]::UtcNow.ToString('o')
                            phase = 'compound-app-restore'
                            poll = $script:hcRestorePollCount
                            timed_out = $false
                            deadline_utc = $compoundRestoreDeadline.ToString('o')
                            budget_seconds = 10
                            recovery_path = $recoveryPath
                            diagnostic_path = $restoreDiagnosticPath
                            process_alive = -not $Process.HasExited
                            exact_spi_state = $true
                            host = [ordered]@{
                                expected_hwnd = $hostHwnd.ToInt64()
                                top_level_hwnds = @(
                                    $currentHostWindows |
                                        ForEach-Object { $_.ToInt64() }
                                )
                                top_level_count_exact = $hostCountExact
                                original_hwnd_exact = $hostOriginalExact
                                hwnd_alive = $hostAlive
                                dwm_exact = $hostDwmExact
                                dwm_error = $hostDwmError
                                dwm_actual = $hostDwm
                                dwm = $hostDwmDiagnostic
                            }
                            settings = $settingsDiagnostic
                            settings_dwm_exact = $settingsDwmExact
                            settings_dwm_error = $settingsDwmError
                            settings_dwm_actual = $settingsDwm
                            settings_dwm = $settingsDwmDiagnostic
                            semantic_pixel = $semanticDiagnostic
                            foreground_hwnd = $foregroundHwnd.ToInt64()
                            host_focused_hwnd = $hostFocusedHwnd.ToInt64()
                            settings_focused_hwnd =
                                $settingsFocusedHwnd.ToInt64()
                            compound_exact = $compoundExact
                        }
                        Write-HighContrastRestoreDiagnostic `
                            -Diagnostic $script:hcRestoreDiagnostic `
                            -Path $restoreDiagnosticPath
                        return $compoundExact
                    }
                    $compoundRestoreCompleted = $true
                }
                catch {
                    if ($null -ne $script:hcRestoreDiagnostic) {
                        $script:hcRestoreDiagnostic.timed_out = $true
                        $script:hcRestoreDiagnostic.timeout_error =
                            $_.Exception.Message
                        $script:hcRestoreDiagnostic.captured_utc =
                            [DateTime]::UtcNow.ToString('o')
                        Write-HighContrastRestoreDiagnostic `
                            -Diagnostic $script:hcRestoreDiagnostic `
                            -Path $restoreDiagnosticPath
                    }
                    $finalRestore = if ($null -eq $script:hcRestoreDiagnostic) {
                        '<unavailable>'
                    } else {
                        $script:hcRestoreDiagnostic |
                            ConvertTo-Json -Depth 12 -Compress
                    }
                    throw "Compound High Contrast app reversal failed. diagnostic=$restoreDiagnosticPath recovery=$recoveryPath final=$finalRestore. $($_.Exception.Message)"
                }
                $result['dwm_restored'] =
                    $script:hcRestoreDiagnostic.host.dwm_actual
                $result['settings_dwm_restored'] =
                    $script:hcRestoreDiagnostic.settings_dwm_actual
                $result['settings_reversed_color'] =
                    [uint32]$script:hcRestoreDiagnostic.semantic_pixel.actual_color
            }
            else {
                $compoundRestoreCompleted = $false
                $unavailableDiagnostic = [ordered]@{
                    captured_utc = [DateTime]::UtcNow.ToString('o')
                    phase = 'compound-app-restore-unavailable'
                    recovery_path = $recoveryPath
                    diagnostic_path = $restoreDiagnosticPath
                    exact_spi_state = $true
                    toggle_attempted = $toggleAttempted
                    semantic_pixel_available = $null -ne $semanticPixel
                    compound_exact = $false
                }
                Write-HighContrastRestoreDiagnostic `
                    -Diagnostic $unavailableDiagnostic `
                    -Path $restoreDiagnosticPath
            }
            if ($compoundRestoreCompleted) {
                $result.restored = $true
                [System.IO.File]::Delete($recoveryPath)
                if ([System.IO.File]::Exists($recoveryPath)) {
                    throw "High Contrast recovery snapshot could not be deleted after verified compound restore: $recoveryPath"
                }
            }
        }
        finally {
            [void][WinghosttyAccessibilityNative]::PostMessageW(
                $settingsHwnd,
                0x0010,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            )
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'same Settings HWND close after High Contrast proof' -Condition {
                return -not [WinghosttyAccessibilityNative]::IsWindow($settingsHwnd)
            }
        }
    }
    return $result
}

function Invoke-AccessibilitySettingsCloseAction {
    param(
        [Parameter(Mandatory)] $SettingsProbe,
        [Parameter(Mandatory)][string] $ActionName,
        [Parameter(Mandatory)][string] $Description
    )

    if (-not [WinghosttyAccessibilityNative]::ForceForeground($SettingsProbe.Hwnd)) {
        throw "Unable to foreground $Description before its dirty-close request."
    }
    if (-not [WinghosttyAccessibilityNative]::PostMessageW(
        $SettingsProbe.Hwnd,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )) {
        throw "PostMessageW failed while closing ${Description}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "$Description inline dirty-close action" -Condition {
        $script:settingsCloseAction = @($SettingsProbe.Element.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ) | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
            $_.Current.Name -eq $ActionName -and
            -not $_.Current.IsOffscreen
        }) | Select-Object -First 1
        return $null -ne $script:settingsCloseAction -and $script:settingsCloseAction.Current.IsEnabled
    }
    $invoke = $null
    if (-not $script:settingsCloseAction.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$invoke
    )) {
        throw "$Description action '$ActionName' exposes no InvokePattern."
    }
    $invoke.Invoke()
}

function Restore-AccessibilityConfigBaseline {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][bool] $Existed,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][byte[]] $Bytes
    )

    if (-not $Existed) {
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
        if ([System.IO.File]::Exists($Path)) { throw "Failed to restore absent config baseline at '$Path'." }
        return
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.config-restore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.config-restore-' + [Guid]::NewGuid().ToString('N') + '.bak')
    try {
        if ($null -eq $Bytes) {
            [System.IO.File]::WriteAllBytes($temporary, [byte[]]::new(0))
        } else {
            [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        }
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporary, $Path, $backup)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        if ([System.IO.File]::Exists($backup)) { [System.IO.File]::Delete($backup) }
    }
    $restored = [System.IO.File]::ReadAllBytes($Path)
    $expectedBase64 = if ($null -eq $Bytes) { '' } else { [Convert]::ToBase64String($Bytes) }
    if ([Convert]::ToBase64String($restored) -cne $expectedBase64) {
        throw "Config baseline bytes were not restored exactly at '$Path'."
    }
}

function Start-AccessibilityProcessWithEnvironment {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][object[]] $ArgumentList,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][System.Collections.IDictionary] $EnvironmentVariables,
        [Parameter(Mandatory)][string] $RedirectStandardOutput,
        [Parameter(Mandatory)][string] $RedirectStandardError
    )

    $baseline = [ordered]@{}
    foreach ($entry in $EnvironmentVariables.GetEnumerator()) {
        $name = [string]$entry.Key
        $baseline[$name] = [System.Environment]::GetEnvironmentVariable(
            $name,
            [System.EnvironmentVariableTarget]::Process
        )
        [System.Environment]::SetEnvironmentVariable(
            $name,
            [string]$entry.Value,
            [System.EnvironmentVariableTarget]::Process
        )
    }
    try {
        return Start-Process `
            -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $RedirectStandardOutput `
            -RedirectStandardError $RedirectStandardError `
            -PassThru
    }
    finally {
        foreach ($entry in $baseline.GetEnumerator()) {
            [System.Environment]::SetEnvironmentVariable(
                [string]$entry.Key,
                $entry.Value,
                [System.EnvironmentVariableTarget]::Process
            )
        }
    }
}

function Test-AccessibilityAncestor($Ancestor, $Descendant) {
    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $candidate = $walker.GetParent($Descendant)
    while ($null -ne $candidate) {
        if ([System.Windows.Automation.Automation]::Compare($Ancestor, $candidate)) { return $true }
        $candidate = $walker.GetParent($candidate)
    }
    return $false
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
$themePreviewConfigPath = Join-Path $layout.LocalAppData 'winghostty\config.ghostty'
$themePreviewConfigDirectory = Split-Path -Parent $themePreviewConfigPath
[void][System.IO.Directory]::CreateDirectory($themePreviewConfigDirectory)
$themePreviewConfigText = if (Test-Path -LiteralPath $themePreviewConfigPath) {
    Get-Content -LiteralPath $themePreviewConfigPath -Raw
}
else {
    ''
}
$themePreviewConfigText = [regex]::Replace(
    $themePreviewConfigText,
    '(?m)^[ \t]*window-theme[ \t]*=.*(?:\r?\n|$)',
    ''
)
if ($themePreviewConfigText.Length -ne 0 -and -not $themePreviewConfigText.EndsWith("`n")) {
    $themePreviewConfigText += "`r`n"
}
$themePreviewConfigText += "window-theme = system`r`n"
$themePreviewUtf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($themePreviewConfigPath, $themePreviewConfigText, $themePreviewUtf8)
[byte[]]$themePreviewConfigBaselineBytes = [System.IO.File]::ReadAllBytes($themePreviewConfigPath)
$document = $null
$textChangedHandler = $null
$textChangedRegistered = $false
$terminalNotificationCaptureStarted = $false
$paletteSelectionHandler = $null
$paletteSelectionRegistered = $false
$settingsFocusHandler = $null
$settingsFocusRegistered = $false
$paletteNotificationRegistered = $false
$editTextChangedHandler = $null
$editTextSelectionChangedHandler = $null
$editValueChangedHandler = $null
$editEventElement = $null
$editEventsRegistered = $false
$relaunchProcess = $null
$ownerProbeProcess = $null
$saveProbeProcess = $null
$saveVerifyProcess = $null
$settingsPersistenceLayout = Get-InteractiveWin11SandboxLayout `
    -RepoRoot $repoRoot `
    -SandboxName "accessibility-save-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
New-InteractiveWin11Sandbox -Layout $settingsPersistenceLayout
$settingsProbeEnvironment = Get-InteractiveWin11Environment -Layout $settingsPersistenceLayout
$sandboxConfigPath = Join-Path $settingsPersistenceLayout.LocalAppData 'winghostty\config.ghostty'
$settingsConfigBaselineCaptured = $false
$settingsConfigBaselineExisted = $false
[byte[]]$settingsConfigBaselineBytes = @()
$settingsConfigBaselineRestored = $false
$marker = "WINGHOSTTY_UIA_$([Guid]::NewGuid().ToString('N'))"
$terminalText = ''
$terminalLineText = ''
$terminalRectCount = 0
$queryOnlyMarker = "whq$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
$queryOnlyRangeRefreshed = $false
$coldQueryMarker = "whc$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
$coldQueryPostEchoRangeFresh = $false
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
$inactiveTabEvidence = $null
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
    if ($ThemeDiagnosticOnly) {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'theme diagnostic terminal Text element' -Condition {
            $script:themeDiagnosticDocuments = @($root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text
                )
            ) | Where-Object {
                $_.Current.ProcessId -eq $process.Id -and
                $_.Current.LocalizedControlType -eq 'terminal'
            })
            return $script:themeDiagnosticDocuments.Count -gt 0
        }
        $themeDiagnosticDocument = $script:themeDiagnosticDocuments[0]
        $themeDiagnosticTerminalHwnd = [IntPtr]$themeDiagnosticDocument.Current.NativeWindowHandle
        [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
        $themeDiagnosticDocument.SetFocus()
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'theme diagnostic terminal focus' -Condition {
            return [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle) -eq
                $themeDiagnosticTerminalHwnd
        }
        Assert-AccessibilityInputOwner `
            -Process $process `
            -Description 'theme diagnostic Settings open' `
            -ExpectedFocusedHwnd $themeDiagnosticTerminalHwnd
        if (-not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x11, [uint16]0xBC))) {
            throw "SendInput failed while opening theme diagnostic Settings: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $themeDiagnosticProbe = Wait-AccessibilitySettingsProbe `
            -Process $process `
            -Description 'theme diagnostic Settings'
        $themeDiagnosticHwnd = $themeDiagnosticProbe.Hwnd
        $themeDiagnosticElement = $themeDiagnosticProbe.Element
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'theme diagnostic Window theme combo' -Condition {
            $script:themeDiagnosticElements = @($themeDiagnosticElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            ) | ForEach-Object { $_ })
            $script:themeDiagnosticCombo = @($script:themeDiagnosticElements | Where-Object {
                $_.Current.Name -eq 'Window theme' -and
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox
            }) | Select-Object -First 1
            return $null -ne $script:themeDiagnosticCombo
        }
        $themeDiagnosticComboHwnd = [IntPtr]$script:themeDiagnosticCombo.Current.NativeWindowHandle
        $themeDiagnosticInitialIndex = [WinghosttyAccessibilityNative]::SendMessageW(
            $themeDiagnosticComboHwnd,
            0x0147,
            [UIntPtr]::Zero,
            [IntPtr]::Zero
        ).ToInt64()
        if ($themeDiagnosticInitialIndex -ne 1) {
            throw "Theme diagnostic expected seeded System index 1; found $themeDiagnosticInitialIndex."
        }
        $themeDiagnosticSettingsRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen($themeDiagnosticHwnd)
        $themeDiagnosticHostRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen($process.MainWindowHandle)
        $themeDiagnosticSettingsGrid = Get-AccessibilityClientPixelGrid `
            -Hwnd $themeDiagnosticHwnd -MinX 24 `
            -MaxX ([Math]::Max(24, ($themeDiagnosticSettingsRect.right - $themeDiagnosticSettingsRect.left) - 24)) `
            -MinY 24 -MaxY ([Math]::Max(24, ($themeDiagnosticSettingsRect.bottom - $themeDiagnosticSettingsRect.top) - 24)) -Step 16
        $themeDiagnosticHostGrid = Get-AccessibilityClientPixelGrid `
            -Hwnd $process.MainWindowHandle -MinX 24 `
            -MaxX ([Math]::Max(24, ($themeDiagnosticHostRect.right - $themeDiagnosticHostRect.left) - 24)) `
            -MinY 8 -MaxY ([Math]::Max(8, [Math]::Min(48, ($themeDiagnosticHostRect.bottom - $themeDiagnosticHostRect.top) - 8))) -Step 8
        foreach ($target in @(
            @{ Index = 3; Name = 'Dark'; Color = [uint32]0x00202020 },
            @{ Index = 2; Name = 'Light'; Color = [uint32]0x00F3F3F3 }
        )) {
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $themeDiagnosticComboHwnd,
                0x014E,
                [UIntPtr]::new([uint64]$target.Index),
                [IntPtr]::Zero
            )
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $themeDiagnosticHwnd,
                0x0111,
                [UIntPtr]::new(0x00010195),
                $themeDiagnosticComboHwnd
            )
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "theme diagnostic $($target.Name) pixels" -Condition {
                $script:themeDiagnosticIndex = [WinghosttyAccessibilityNative]::SendMessageW(
                    $themeDiagnosticComboHwnd,
                    0x0147,
                    [UIntPtr]::Zero,
                    [IntPtr]::Zero
                ).ToInt64()
                $script:themeDiagnosticSettingsPixel = Find-AccessibilityClientPixel `
                    -Hwnd $themeDiagnosticHwnd -OriginalGrid $themeDiagnosticSettingsGrid -TargetColor $target.Color
                $script:themeDiagnosticHostPixel = Find-AccessibilityClientPixel `
                    -Hwnd $process.MainWindowHandle -OriginalGrid $themeDiagnosticHostGrid -TargetColor $target.Color
                return $script:themeDiagnosticIndex -eq $target.Index -and
                    $null -ne $script:themeDiagnosticSettingsPixel -and
                    $null -ne $script:themeDiagnosticHostPixel
            }
        }
        $themeDiagnosticLightSettingsColor = $script:themeDiagnosticSettingsPixel.color
        $themeDiagnosticLightHostColor = $script:themeDiagnosticHostPixel.color
        [void][WinghosttyAccessibilityNative]::SendMessageW(
            $themeDiagnosticComboHwnd,
            0x014E,
            [UIntPtr]::new(1),
            [IntPtr]::Zero
        )
        [void][WinghosttyAccessibilityNative]::SendMessageW(
            $themeDiagnosticHwnd,
            0x0111,
            [UIntPtr]::new(0x00010195),
            $themeDiagnosticComboHwnd
        )
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'theme diagnostic System revert' -Condition {
            return [WinghosttyAccessibilityNative]::SendMessageW(
                $themeDiagnosticComboHwnd,
                0x0147,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            ).ToInt64() -eq 1
        }
        [void][WinghosttyAccessibilityNative]::PostMessageW(
            $themeDiagnosticHwnd,
            0x0010,
            [UIntPtr]::Zero,
            [IntPtr]::Zero
        )
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'theme diagnostic Settings close' -Condition {
            return -not [WinghosttyAccessibilityNative]::IsWindow($themeDiagnosticHwnd)
        }
        [byte[]]$themeDiagnosticConfigBytes = [System.IO.File]::ReadAllBytes($themePreviewConfigPath)
        if ([Convert]::ToBase64String($themePreviewConfigBaselineBytes) -ne
            [Convert]::ToBase64String($themeDiagnosticConfigBytes)) {
            throw 'Targeted theme preview changed config.ghostty bytes.'
        }
        [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
        $themeDiagnosticDocument.SetFocus()
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'theme diagnostic pre-HC terminal focus' -Condition {
            return [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle) -eq
                $themeDiagnosticTerminalHwnd
        }
        $themeDiagnosticHighContrast = Invoke-AccessibilityHighContrastProof `
            -Process $process `
            -DiagnosticDirectory $layout.Logs
        $evidence = [ordered]@{
            schema_version = 1
            outcome = 'pass'
            mode = 'theme-diagnostic'
            system_index = $themeDiagnosticInitialIndex
            final_index = 1
            settings_hwnd_closed = -not [WinghosttyAccessibilityNative]::IsWindow($themeDiagnosticHwnd)
            host_hwnd_alive = [WinghosttyAccessibilityNative]::IsWindow($process.MainWindowHandle)
            exact_light_settings_color = $themeDiagnosticLightSettingsColor
            exact_light_host_color = $themeDiagnosticLightHostColor
            config_bytes_unchanged = $true
            high_contrast = $themeDiagnosticHighContrast
            provenance = [ordered]@{
                source_commit = $sourceCommit
                executable_path = $resolvedExe
                executable_sha256 = $binaryHash
                validation_started_utc = $validationStartedAt.ToString('o')
            }
        }
    }
    elseif ($ColdDiagnosticOnly) {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'cold diagnostic terminal Text element' -Condition {
            $script:coldDiagnosticDocuments = @($root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text
                )
            ) | Where-Object {
                $_.Current.ProcessId -eq $process.Id -and
                $_.Current.LocalizedControlType -eq 'terminal'
            })
            return $script:coldDiagnosticDocuments.Count -gt 0
        }
        $document = $script:coldDiagnosticDocuments[0]
        $coldDiagnosticTerminalHwnd = [IntPtr]$document.Current.NativeWindowHandle
        $coldDiagnosticTextPattern = $null
        if (-not $document.TryGetCurrentPattern(
            [System.Windows.Automation.TextPattern]::Pattern,
            [ref]$coldDiagnosticTextPattern
        )) {
            throw 'Cold diagnostic terminal Text element does not expose TextPattern.'
        }
        [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
        $document.SetFocus()
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'cold diagnostic terminal focus' -Condition {
            return [WinghosttyAccessibilityNative]::GetForegroundWindow() -eq $process.MainWindowHandle -and
                [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle) -eq
                    $coldDiagnosticTerminalHwnd
        }

        # Exercise the same continuous native notification subscription as the
        # full flow: prove one warm notification, retain that exact handler and
        # provider, then reset only its local history for the true-cold marker.
        [WinghosttyAccessibilityNative]::ResetNotificationCount()
        [WinghosttyAccessibilityNative]::StartNotificationCapture($coldDiagnosticTerminalHwnd)
        $terminalNotificationCaptureStarted = $true
        $coldDiagnosticWarmMarker = "whw$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
        $coldDiagnosticWarmInput = Send-AccessibilityOutputMarker `
            -Process $process `
            -TextPattern $coldDiagnosticTextPattern `
            -Marker $coldDiagnosticWarmMarker `
            -Description 'cold diagnostic warm notification marker' `
            -ExpectedFocusedHwnd $coldDiagnosticTerminalHwnd
        $coldDiagnosticWarmNotification =
            Wait-AccessibilityOwnedOutputNotification `
                -Process $process `
                -ExpectedFocusedHwnd $coldDiagnosticTerminalHwnd `
                -Marker $coldDiagnosticWarmMarker `
                -Description 'cold diagnostic warm output notification'
        $script:coldDiagnosticWarmHistory =
            @($coldDiagnosticWarmNotification.history)

        $coldDiagnosticProof = Invoke-AccessibilityColdFirstReadProof `
            -Process $process `
            -TextPattern $coldDiagnosticTextPattern `
            -Marker $coldQueryMarker `
            -Description 'cold diagnostic first-read TextPattern marker' `
            -ExpectedFocusedHwnd $coldDiagnosticTerminalHwnd `
            -HelperDirectory $layout.Logs `
            -NotificationCaptureActive
        [WinghosttyAccessibilityNative]::StopNotificationCapture()
        $terminalNotificationCaptureStarted = $false
        $coldDiagnosticInactiveTabProof =
            Invoke-AccessibilityInactiveTabFirstReadProof `
                -Process $process `
                -TabAHwnd $coldDiagnosticTerminalHwnd `
                -HelperDirectory $layout.Logs
        $evidence = [ordered]@{
            schema_version = 1
            outcome = 'pass'
            mode = 'cold-diagnostic'
            marker = $coldQueryMarker
            marker_visible = $true
            terminal_hwnd = $coldDiagnosticTerminalHwnd.ToInt64()
            warm_notification_marker = $coldDiagnosticWarmMarker
            warm_notification_count = $script:coldDiagnosticWarmHistory.Count
            warm_input = $coldDiagnosticWarmInput
            warm_notification = $coldDiagnosticWarmNotification
            cold_first_read = $coldDiagnosticProof
            inactive_tab = $coldDiagnosticInactiveTabProof
            provenance = [ordered]@{
                source_commit = $sourceCommit
                executable_path = $resolvedExe
                executable_sha256 = $binaryHash
                validation_started_utc = $validationStartedAt.ToString('o')
            }
        }
    }
    else {
    $documents = @($elements | Where-Object {
        $_.Current.ProcessId -eq $process.Id -and
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
        $_.Current.LocalizedControlType -eq 'terminal'
    })
    if ($documents.Count -eq 0) {
        throw 'UIA tree contains no terminal Text element.'
    }
    $document = $documents[0]
    $textPattern = $null
    if (-not $document.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $textPattern
    )) {
        throw 'Terminal Text element does not expose the UIA Text pattern.'
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
    [WinghosttyAccessibilityNative]::ResetNotificationCount()
    [WinghosttyAccessibilityNative]::StartNotificationCapture($focusedHwnd)
    $terminalNotificationCaptureStarted = $true
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
    $terminalWarmInput = Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $marker -Description 'terminal marker' -ExpectedFocusedHwnd $focusedHwnd
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
    $terminalWarmNotification = Wait-AccessibilityOwnedOutputNotification `
        -Process $process `
        -ExpectedFocusedHwnd $focusedHwnd `
        -Marker $marker `
        -Description 'terminal marker output notification'
    $script:terminalOutputHistory = @($terminalWarmNotification.history)
    $script:terminalOutputSpoken = $terminalWarmNotification.text
    $oversizedTerminalOutput = @($script:terminalOutputHistory | Where-Object {
        ([System.Text.Encoding]::UTF8.GetByteCount([string]$_[1])) -gt 1000
    })
    if ($oversizedTerminalOutput.Count -ne 0) {
        throw "Terminal output notification exceeded the 1000-byte speech chunk ceiling."
    }
    $terminalOutputNotification = @(
        $script:terminalOutputHistory.Count,
        'ActionCompleted',
        $script:terminalOutputSpoken,
        2,
        'TerminalTextOutput'
    )
    if ($terminalOutputNotification[1] -ne 'ActionCompleted' -or
        [string]::IsNullOrWhiteSpace([string]$terminalOutputNotification[2]) -or
        -not ([string]$terminalOutputNotification[2]).Contains($marker) -or
        $terminalOutputNotification[3] -ne 2 -or
        $terminalOutputNotification[4] -ne 'TerminalTextOutput') {
        throw "Terminal output notification metadata mismatch: count=$($terminalOutputNotification[0]) kind='$($terminalOutputNotification[1])' display='$($terminalOutputNotification[2])' processing=$($terminalOutputNotification[3]) activity='$($terminalOutputNotification[4])'."
    }

    $liveSettingValue = [WinghosttyAccessibilityNative]::GetCurrentIntProperty(
        $focusedHwnd,
        30135
    )
    if ($liveSettingValue -ne 1) {
        throw "Terminal live setting is '$liveSettingValue'; expected Polite (1)."
    }
    $liveSetting = 'Polite'

    $supportedTextSelection = $textPattern.SupportedTextSelection
    if ($supportedTextSelection -ne [System.Windows.Automation.SupportedTextSelection]::None) {
        throw "Terminal TextPattern advertises '$supportedTextSelection'; expected None."
    }
    # Compatibility path for legacy clients. TextPattern2.GetCaretRange is
    # canonical; this range remains readable but is not a mutable selection.
    $selection = @($textPattern.GetSelection())
    if ($selection.Count -ne 1) {
        throw "Terminal TextPattern returned $($selection.Count) legacy selection ranges; expected one caret."
    }
    if ($selection[0].CompareEndpoints(
        [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start,
        $selection[0],
        [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End
    ) -ne 0) {
        throw 'Terminal legacy selection is not a degenerate caret range.'
    }
    $selectionLine = $selection[0].Clone()
    $selectionLine.ExpandToEnclosingUnit([System.Windows.Automation.Text.TextUnit]::Line)
    $selectionLineText = $selectionLine.GetText(-1)
    if ([string]::IsNullOrWhiteSpace($selectionLineText)) {
        throw 'Terminal legacy caret could not expand/read its current line.'
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
    # TextPattern after this client's text event handler is removed. This does
    # not imply that the process-global UiaClientsAreListening signal is false.
    # Each DocumentRange remains an intentionally immutable snapshot.
    $queryOnlyPreviousRange = $textPattern.DocumentRange
    [System.Windows.Automation.Automation]::RemoveAutomationEventHandler(
        [System.Windows.Automation.TextPattern]::TextChangedEvent,
        $document,
        $textChangedHandler
    )
    $textChangedRegistered = $false
    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    [void](Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $queryOnlyMarker -Description 'query-only TextPattern marker' -ExpectedFocusedHwnd $focusedHwnd)
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'already-acquired query-only TextPattern refresh' -Condition {
            $script:queryOnlyTextProbe = $textPattern.DocumentRange.GetText(-1)
            return $script:queryOnlyTextProbe.Contains($queryOnlyMarker)
        }
    }
    catch {
        $queryProbe = if ($null -eq $script:queryOnlyTextProbe) { '<null>' } else { $script:queryOnlyTextProbe.Replace("`r", '\r').Replace("`n", '\n') }
        throw "$($_.Exception.Message) Last query-only TextPattern text='$queryProbe'."
    }
    if ($queryOnlyPreviousRange.GetText(-1).Contains($queryOnlyMarker)) {
        throw 'Previously acquired terminal DocumentRange mutated after query-only output.'
    }
    if ([WinghosttyAccessibilityNative]::TextChangedCount -ne 0) {
        throw "TextChanged callback ran after listener removal during query-only validation."
    }
    $queryOnlyRangeRefreshed = $true

    # Type and echo-gate the helper while UIA is hot. After its ready file, the
    # proof waits out query activity and uses only direct notification history
    # until one final DocumentRange read.
    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    $coldQueryProof = Invoke-AccessibilityColdFirstReadProof `
        -Process $process `
        -TextPattern $textPattern `
        -Marker $coldQueryMarker `
        -Description 'cold first-read TextPattern marker' `
        -ExpectedFocusedHwnd $focusedHwnd `
        -HelperDirectory $layout.Logs `
        -NotificationCaptureActive
    [WinghosttyAccessibilityNative]::StopNotificationCapture()
    $terminalNotificationCaptureStarted = $false
    if ([WinghosttyAccessibilityNative]::TextChangedCount -ne 0) {
        throw 'TextChanged callback ran during cold-query validation after listener removal.'
    }
    $coldQueryPostEchoRangeFresh = $true

    $inactiveTabEvidence = Invoke-AccessibilityInactiveTabFirstReadProof `
        -Process $process `
        -TabAHwnd $focusedHwnd `
        -HelperDirectory $layout.Logs

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
    $script:palette = $palette
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
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'command palette query global UIA focus' -Condition {
        if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -ne $process.MainWindowHandle) {
            $paletteNativeFocus = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
            $paletteNativeFocusElement = if ($paletteNativeFocus -ne [IntPtr]::Zero) {
                [System.Windows.Automation.AutomationElement]::FromHandle($paletteNativeFocus)
            } else {
                $null
            }
            if ($null -eq $paletteNativeFocusElement -or
                $paletteNativeFocusElement.Current.ControlType -ne [System.Windows.Automation.ControlType]::Edit -or
                $paletteNativeFocusElement.Current.Name -ne 'Command palette query') {
                throw "Command palette query lost native focus before foreground recovery (focused=$paletteNativeFocus)."
            }
            [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
            return $false
        }
        $script:paletteFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
        return $null -ne $script:paletteFocused -and
            $script:paletteFocused.Current.ProcessId -eq $process.Id -and
            $script:paletteFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
            $script:paletteFocused.Current.Name -eq 'Command palette query'
    }
    $paletteFocused = $script:paletteFocused
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
    $paletteQueryHwnd = [IntPtr]$paletteFocused.Current.NativeWindowHandle
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
            [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start,
            $paletteInitialQuerySelection[0],
            [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End
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
    if (-not [WinghosttyAccessibilityNative]::SendUnicodeText($paletteUnavailableQuery)) {
        throw "SendInput failed for command palette unavailable query: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $script:paletteUnavailableLastTransient = $null
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette unavailable no-match notification' -Condition {
            try {
                if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -ne $process.MainWindowHandle) {
                    $paletteNativeFocusBeforeRecovery = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
                    if ($paletteNativeFocusBeforeRecovery -ne $paletteQueryHwnd) {
                        throw "Command palette query lost native focus before foreground recovery (focused=$paletteNativeFocusBeforeRecovery expected=$paletteQueryHwnd)."
                    }
                    [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
                    return $false
                }
                if ($null -eq $script:palette) {
                    $script:palette = @($root.FindAll(
                        [System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.PropertyCondition]::new(
                            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                            [System.Windows.Automation.ControlType]::List
                        )
                    ) | Where-Object { $_.Current.ProcessId -eq $process.Id }) | Select-Object -First 1
                    if ($null -eq $script:palette) {
                        # Zero matches intentionally hides the palette List
                        # HWND, so it disappears from the control view after
                        # UIA invalidates the previously cached fragment. The
                        # no-match state is still valid when the live query
                        # Edit owns focus and the fresh notification arrived.
                        $script:paletteUnavailableItems = @()
                        $script:paletteUnavailableFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
                        $queryStillFocused = $null -ne $script:paletteUnavailableFocused -and
                            $script:paletteUnavailableFocused.Current.ProcessId -eq $process.Id -and
                            $script:paletteUnavailableFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
                            $script:paletteUnavailableFocused.Current.Name -eq 'Command palette query' -and
                            $script:paletteUnavailableFocused.Current.HasKeyboardFocus
                        $uiaFocusSummary = if ($null -eq $script:paletteUnavailableFocused) {
                            '<none>'
                        } else {
                            "type=$($script:paletteUnavailableFocused.Current.ControlType.ProgrammaticName) name='$($script:paletteUnavailableFocused.Current.Name)' hwnd=$($script:paletteUnavailableFocused.Current.NativeWindowHandle) has_focus=$($script:paletteUnavailableFocused.Current.HasKeyboardFocus)"
                        }
                        $win32FocusHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
                        if ($queryStillFocused -and
                            [WinghosttyAccessibilityNative]::NotificationCount -gt 0 -and
                            -not [WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd)) {
                            return $true
                        }
                        $script:paletteUnavailableLastTransient = "list=absent query_focused=$queryStillFocused uia_focus=[$uiaFocusSummary] win32_focus=$win32FocusHwnd notification_count=$([WinghosttyAccessibilityNative]::NotificationCount) native_visible=$([WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd))"
                        return $false
                    }
                }
                $script:paletteUnavailableItems = @($script:palette.FindAll(
                    [System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::ListItem
                    )
                ) | ForEach-Object { $_ })
                $script:paletteUnavailableFocused = [System.Windows.Automation.AutomationElement]::FocusedElement
                $queryStillFocused = $null -ne $script:paletteUnavailableFocused -and
                    $script:paletteUnavailableFocused.Current.ProcessId -eq $process.Id -and
                    $script:paletteUnavailableFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
                    $script:paletteUnavailableFocused.Current.Name -eq 'Command palette query' -and
                    $script:paletteUnavailableFocused.Current.HasKeyboardFocus
                $uiaFocusSummary = if ($null -eq $script:paletteUnavailableFocused) {
                    '<none>'
                } else {
                    "type=$($script:paletteUnavailableFocused.Current.ControlType.ProgrammaticName) name='$($script:paletteUnavailableFocused.Current.Name)' hwnd=$($script:paletteUnavailableFocused.Current.NativeWindowHandle) has_focus=$($script:paletteUnavailableFocused.Current.HasKeyboardFocus)"
                }
                $win32FocusHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
                $script:paletteUnavailableLastTransient = "items=$($script:paletteUnavailableItems.Count) query_focused=$queryStillFocused uia_focus=[$uiaFocusSummary] win32_focus=$win32FocusHwnd notification_count=$([WinghosttyAccessibilityNative]::NotificationCount) native_visible=$([WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd))"
            }
            catch {
                $hresults = @(Get-AccessibilityExceptionHResults -Exception $_.Exception)
                $hresultChain = ($hresults | ForEach-Object {
                    '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$_), 0)
                }) -join ' -> '
                $script:paletteUnavailableLastTransient = ('HRESULT chain {0}: {1}' -f $hresultChain, $_.Exception.Message)
                $transientHresult = $hresults | Where-Object {
                    Test-AccessibilityTransientHResult -HResult $_
                } | Select-Object -First 1
                if ($null -eq $transientHresult) {
                    throw
                }
                if ($transientHresult -eq 0x80010001 -or $transientHresult -eq 0x8001010A) {
                    return $false
                }
                if ($transientHresult -eq 0x80040201) {
                    $script:palette = $null
                    return $false
                }
            }
            return $script:paletteUnavailableItems.Count -eq 0 -and
                $queryStillFocused -and
                [WinghosttyAccessibilityNative]::NotificationCount -gt 0 -and
                -not [WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd)
        }
    }
    catch {
        throw "$($_.Exception.Message) Last transient UIA error: $($script:paletteUnavailableLastTransient)."
    }
    $unavailableNotification = Get-ExactAccessibilityNotification `
        -Description 'No-match notification' `
        -ExpectedKind 'Other' `
        -ExpectedDisplayString 'No matches'
    $paletteUnavailableNotificationCount = $unavailableNotification.Count
    $paletteUnavailableNotificationKind = $unavailableNotification.Kind
    $paletteUnavailableNotificationDisplayString = $unavailableNotification.DisplayString
    if ([WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd)) {
        throw 'Zero-result command palette left its native List HWND visible over terminal content.'
    }

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

    $paletteQueryValuePattern.SetValue('Accessibility')
    $script:paletteRecoveryLastTransient = $null
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'command palette native List recovery after zero matches' -Condition {
            try {
                if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -ne $process.MainWindowHandle) {
                    $paletteNativeFocusBeforeRecovery = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
                    if ($paletteNativeFocusBeforeRecovery -ne $paletteQueryHwnd) {
                        throw "Recovered command palette query lost native focus before foreground recovery (focused=$paletteNativeFocusBeforeRecovery expected=$paletteQueryHwnd)."
                    }
                    [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
                    return $false
                }
                $script:paletteRecovered = @($root.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::List
                    )
                ) | Where-Object { $_.Current.ProcessId -eq $process.Id }) | Select-Object -First 1
                if ($null -eq $script:paletteRecovered) { return $false }
                $script:paletteRecoveredItems = @($script:paletteRecovered.FindAll(
                    [System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::ListItem
                    )
                ) | ForEach-Object { $_ })
                $script:paletteRecoveredFocus = [System.Windows.Automation.AutomationElement]::FocusedElement
                $recoveredFocusSummary = if ($null -eq $script:paletteRecoveredFocus) {
                    '<none>'
                }
                else {
                    "$($script:paletteRecoveredFocus.Current.Name):$($script:paletteRecoveredFocus.Current.ControlType.ProgrammaticName):pid=$($script:paletteRecoveredFocus.Current.ProcessId)"
                }
                $script:paletteRecoveryLastTransient = "native_visible=$([WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd)) items=$($script:paletteRecoveredItems.Count) focus=$recoveredFocusSummary"
                return [WinghosttyAccessibilityNative]::IsWindowVisible($paletteNativeHwnd) -and
                    $script:paletteRecoveredItems.Count -gt 0 -and
                    $null -ne $script:paletteRecoveredFocus -and
                    $script:paletteRecoveredFocus.Current.ProcessId -eq $process.Id -and
                    $script:paletteRecoveredFocus.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
                    $script:paletteRecoveredFocus.Current.Name -eq 'Command palette query' -and
                    $script:paletteRecoveredFocus.Current.HasKeyboardFocus
            }
            catch {
                $hresults = @(Get-AccessibilityExceptionHResults -Exception $_.Exception)
                $script:paletteRecoveryLastTransient = (($hresults | ForEach-Object {
                    '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$_), 0)
                }) -join ' -> ') + ": $($_.Exception.Message)"
                $transientHresult = $hresults | Where-Object {
                    Test-AccessibilityTransientHResult -HResult $_
                } | Select-Object -First 1
                if ($null -eq $transientHresult) { throw }
                if ($transientHresult -eq 0x80040201) {
                    $script:paletteRecovered = $null
                }
                return $false
            }
        }
    }
    catch {
        throw "$($_.Exception.Message) Last transient UIA recovery error: $($script:paletteRecoveryLastTransient)."
    }
    $paletteRecoveredSelectionPattern = $null
    if (-not $script:paletteRecovered.TryGetCurrentPattern(
        [System.Windows.Automation.SelectionPattern]::Pattern,
        [ref]$paletteRecoveredSelectionPattern
    )) {
        throw 'Recovered command palette List does not expose SelectionPattern.'
    }
    $paletteRecoveredSelection = @($paletteRecoveredSelectionPattern.Current.GetSelection())
    if ($paletteRecoveredSelection.Count -ne 1 -or
        $paletteRecoveredSelection[0].Current.Name -notmatch 'Accessibility') {
        throw 'Recovered command palette List does not expose its selected Accessibility row.'
    }

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
            $script:paletteDismissFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
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
            $script:paletteToggleFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
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
        if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -ne $process.MainWindowHandle) {
            $searchNativeFocusBeforeRecovery = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
            if ($searchNativeFocusBeforeRecovery -ne $searchNativeHwnd) {
                throw "Docked search query lost native focus before foreground recovery (focused=$searchNativeFocusBeforeRecovery expected=$searchNativeHwnd)."
            }
            [void][WinghosttyAccessibilityNative]::ForceForeground($process.MainWindowHandle)
            return $false
        }
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
            [System.Windows.Automation.Text.TextPatternRangeEndpoint]::Start,
            $searchInitialSelection[0],
            [System.Windows.Automation.Text.TextPatternRangeEndpoint]::End
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
            $script:searchDismissFocused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
            $script:searchDismissTerminalHwnds -contains $script:searchDismissFocusedHwnd
    }
    $hiddenSearchElement = [System.Windows.Automation.AutomationElement]::FromHandle($searchNativeHwnd)
    if ($null -eq $hiddenSearchElement -or
        $hiddenSearchElement.Current.ControlType -ne [System.Windows.Automation.ControlType]::Edit -or
        -not $hiddenSearchElement.Current.IsOffscreen) {
        throw 'Hidden docked search Edit did not remain an offscreen UIA Edit after dismissal.'
    }

    $settingsCycles = @()
    $themePreviewEvidence = $null
    $themeHighContrast = [WinghosttyAccessibilityNative+HIGHCONTRAST]::new()
    $themeHighContrast.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($themeHighContrast)
    if (-not [WinghosttyAccessibilityNative]::SystemParametersInfo(
        0x42,
        $themeHighContrast.cbSize,
        [ref]$themeHighContrast,
        0
    )) {
        throw "SPI_GETHIGHCONTRAST failed before theme preview: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $themeHighContrastActive = [bool]($themeHighContrast.dwFlags -band 1)
    for ($settingsCycle = 1; $settingsCycle -le 2; $settingsCycle++) {
        $settingsClosedByThemeDiscard = $false
        Assert-AccessibilityInputOwner -Process $process -Description "settings lifecycle open $settingsCycle"
        $settingsOpenFocusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
        $settingsOpenTerminalHwnds = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren($process.MainWindowHandle))
        if ($settingsOpenTerminalHwnds -notcontains $settingsOpenFocusedHwnd) {
            throw "Settings cycle $settingsCycle did not start from a focused terminal child (focused=$settingsOpenFocusedHwnd visible_terminals=$($settingsOpenTerminalHwnds -join ', '))."
        }
        if (-not [WinghosttyAccessibilityNative]::SendChord(@([uint16]0x11, [uint16]0xBC))) {
            throw "SendInput failed while opening settings cycle ${settingsCycle}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        try {
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "settings HWND cycle $settingsCycle" -Condition {
                $script:settingsWindowsProbe = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
                    [uint32]$process.Id,
                    'winghostty.win32.settings'
                ))
                return $script:settingsWindowsProbe.Count -eq 1
            }
        }
        catch {
            $settingsOpenForegroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
            [uint32]$settingsOpenForegroundOwner = 0
            if ($settingsOpenForegroundHwnd -ne [IntPtr]::Zero) {
                [void][WinghosttyAccessibilityNative]::GetWindowThreadProcessId($settingsOpenForegroundHwnd, [ref]$settingsOpenForegroundOwner)
            }
            $settingsOpenFocusedAfterHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle)
            throw "Settings cycle $settingsCycle did not create its HWND: initial_focused=$settingsOpenFocusedHwnd; focused_after=$settingsOpenFocusedAfterHwnd; foreground=$settingsOpenForegroundHwnd owner=$settingsOpenForegroundOwner; visible_terminals=$($settingsOpenTerminalHwnds -join ', '). $($_.Exception.Message)"
        }
        $settingsHwnd = $script:settingsWindowsProbe[0]
        $settingsRect = [WinghosttyAccessibilityNative]::WindowRect($settingsHwnd)
        if ($settingsRect.right -le $settingsRect.left -or $settingsRect.bottom -le $settingsRect.top) {
            throw "Settings cycle $settingsCycle has empty native bounds."
        }
        $settingsElement = Wait-AccessibilityWindowElement `
            -Hwnd $settingsHwnd `
            -Description "Settings cycle $settingsCycle"
        if ($settingsElement.Current.Name -ne 'winghostty settings') {
            throw "Settings cycle $settingsCycle root name is '$($settingsElement.Current.Name)'; expected 'winghostty settings'."
        }
        $settingsClientRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen($settingsHwnd)
        $settingsSectionNames = @('Appearance', 'Terminal', 'Shell', 'Privacy', 'Updates', 'Keybindings', 'Advanced')
        $settingsExpectedControls = [ordered]@{
            Appearance = @(
                @{ Name = 'Font family fallbacks'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Font size'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Terminal theme'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Background opacity'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Window theme'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Cursor style'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Window padding X'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Window padding Y'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Window padding balance'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Background blur'; Type = [System.Windows.Automation.ControlType]::CheckBox },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
            Terminal = @(
                @{ Name = 'Scrollback limit'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Close confirmation'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Copy on select'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Clipboard trimming'; Type = [System.Windows.Automation.ControlType]::CheckBox },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
            Shell = @(
                @{ Name = 'Default command'; Type = [System.Windows.Automation.ControlType]::Edit },
                @{ Name = 'Shell integration'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
            Privacy = @(
                @{ Name = 'OSC 52 clipboard read requests'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'OSC 52 clipboard write requests'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Clickable URL opening'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Link preview popups'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Terminal notifications'; Type = [System.Windows.Automation.ControlType]::CheckBox },
                @{ Name = 'Clipboard-copy notification'; Type = [System.Windows.Automation.ControlType]::CheckBox },
                @{ Name = 'Config-reload notification'; Type = [System.Windows.Automation.ControlType]::CheckBox },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
            Updates = @(
                @{ Name = 'Auto-update mode'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Auto-update channel'; Type = [System.Windows.Automation.ControlType]::ComboBox },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
            Keybindings = @(
                @{ Name = 'Keybind configuration'; Type = [System.Windows.Automation.ControlType]::Button },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
            Advanced = @(
                @{ Name = 'Full config editor'; Type = [System.Windows.Automation.ControlType]::Button },
                @{ Name = 'Save'; Type = [System.Windows.Automation.ControlType]::Button }
            )
        }
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description "Settings cycle $settingsCycle section UIA tree" -Condition {
            $script:settingsElementsProbe = @($settingsElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            ) | ForEach-Object { $_ })
            $script:settingsSectionButtonsProbe = @($script:settingsElementsProbe | Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and
                $settingsSectionNames -contains $_.Current.Name
            })
            return $script:settingsSectionButtonsProbe.Count -eq $settingsSectionNames.Count
        }
        $settingsElements = @($script:settingsElementsProbe)
        if ($settingsCycle -eq 2 -and $null -ne $themePreviewEvidence) {
            if ($themePreviewEvidence.skipped) {
                $themePreviewEvidence.rollback_verified = $false
            }
            else {
                $restoredWindowTheme = @($settingsElements | Where-Object {
                    $_.Current.Name -eq 'Window theme' -and
                    $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox
                }) | Select-Object -First 1
                if ($null -eq $restoredWindowTheme) {
                    throw 'Reopened Settings exposes no Window theme combo for discard verification.'
                }
                $restoredThemeHwnd = [IntPtr]$restoredWindowTheme.Current.NativeWindowHandle
                Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Settings theme preview rollback on reopen' -Condition {
                    $script:restoredIndex = [WinghosttyAccessibilityNative]::SendMessageW(
                        $restoredThemeHwnd,
                        0x0147,
                        [UIntPtr]::Zero,
                        [IntPtr]::Zero
                    ).ToInt64()
                    [uint32]$restoredSettingsColorProbe = 0
                    [uint32]$restoredHostColorProbe = 0
                    $restoredSettingsPixelValid = [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                        $settingsHwnd,
                        $themePreviewEvidence.settings_sample_x,
                        $themePreviewEvidence.settings_sample_y,
                        [ref]$restoredSettingsColorProbe
                    )
                    $restoredHostPixelValid = [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                        $process.MainWindowHandle,
                        $themePreviewEvidence.host_sample_x,
                        $themePreviewEvidence.host_sample_y,
                        [ref]$restoredHostColorProbe
                    )
                    $script:restoredSettingsColor = $restoredSettingsColorProbe
                    $script:restoredHostColor = $restoredHostColorProbe
                    return $restoredSettingsPixelValid -and $restoredHostPixelValid -and
                        $script:restoredIndex -eq $themePreviewEvidence.original_index -and
                        $script:restoredSettingsColor -eq $themePreviewEvidence.original_settings_color -and
                        $script:restoredHostColor -eq $themePreviewEvidence.original_host_color
                }
                $themePreviewEvidence.restored_settings_color = $script:restoredSettingsColor
                $themePreviewEvidence.restored_host_color = $script:restoredHostColor
                $themePreviewEvidence.restored_index = $script:restoredIndex
                [byte[]]$themePreviewConfigRestoredBytes = [System.IO.File]::ReadAllBytes(
                    $themePreviewConfigPath
                )
                if ([Convert]::ToBase64String($themePreviewConfigBaselineBytes) -ne
                    [Convert]::ToBase64String($themePreviewConfigRestoredBytes)) {
                    throw 'Discarded Settings theme preview changed config.ghostty bytes.'
                }
                $themePreviewEvidence.config_bytes_unchanged = $true
                $themePreviewEvidence.rollback_verified = $true
            }
        }
        $sectionButtons = @($settingsElements | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and
            $settingsSectionNames -contains $_.Current.Name
        })
        $observedSectionNames = @($sectionButtons | ForEach-Object { $_.Current.Name } | Sort-Object -Unique)
        if ($sectionButtons.Count -ne $settingsSectionNames.Count -or
            @($settingsSectionNames | Where-Object { $observedSectionNames -notcontains $_ }).Count -ne 0) {
            $sectionDiagnostics = @($settingsElements | Where-Object {
                $settingsSectionNames -contains $_.Current.Name
            } | ForEach-Object {
                $sectionHwnd = [IntPtr]$_.Current.NativeWindowHandle
                "$($_.Current.Name):$($_.Current.ControlType.ProgrammaticName):class=$([WinghosttyAccessibilityNative]::WindowClass($sectionHwnd)):style=0x$([WinghosttyAccessibilityNative]::WindowStyle($sectionHwnd).ToString('X')):offscreen=$($_.Current.IsOffscreen)"
            })
            throw "Settings cycle $settingsCycle section buttons were '$($observedSectionNames -join ', ')'; expected all seven named sections. Matching elements: $($sectionDiagnostics -join '; ')"
        }

        $settingsSectionEvidence = @()
        $settingsNamedTextTotal = 0
        $settingsLabelOverlapComparisons = 0
        $settingsOverlapComparisons = 0
        $settingsControlOverlapComparisons = 0
        $settingsContainmentChecks = 0
        $settingsSharedSectionContainer = $null
        foreach ($sectionName in $settingsSectionNames) {
            $sectionButton = @($sectionButtons | Where-Object { $_.Current.Name -eq $sectionName })[0]
            $sectionSelection = $null
            if (-not $sectionButton.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$sectionSelection
            )) {
                throw "Settings section '$sectionName' exposes no SelectionItemPattern."
            }
            $sectionContainer = $sectionSelection.Current.SelectionContainer
            $containerSelection = $null
            if ($null -eq $sectionContainer -or
                -not $sectionContainer.TryGetCurrentPattern(
                    [System.Windows.Automation.SelectionPattern]::Pattern,
                    [ref]$containerSelection
                )) {
                throw "Settings section '$sectionName' exposes no SelectionPattern container."
            }
            if ($containerSelection.Current.CanSelectMultiple -or
                -not $containerSelection.Current.IsSelectionRequired) {
                throw "Settings section '$sectionName' exposes invalid single-selection container semantics."
            }
            if ($null -eq $settingsSharedSectionContainer) {
                $settingsSharedSectionContainer = $sectionContainer
            }
            elseif (-not [System.Windows.Automation.Automation]::Compare(
                $settingsSharedSectionContainer,
                $sectionContainer
            )) {
                throw "Settings section '$sectionName' exposes a different SelectionPattern container."
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
                return $script:settingsSelectedSectionNames.Count -eq 1 -and
                    $script:settingsSelectedSectionNames[0] -eq $sectionName
            }
            $containerSelectedItems = @($containerSelection.Current.GetSelection())
            if ($containerSelectedItems.Count -ne 1 -or
                -not [System.Windows.Automation.Automation]::Compare($containerSelectedItems[0], $sectionButton)) {
                throw "Settings section '$sectionName' container returned $($containerSelectedItems.Count) inconsistent selected items."
            }
            $settingsSectionHeaders = @($settingsElement.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            ) | Where-Object {
                $_.Current.Name -eq $sectionName -and
                -not $_.Current.IsOffscreen -and
                $_.Current.BoundingRectangle.Width -gt 0 -and
                $_.Current.BoundingRectangle.Height -gt 0
            })
            if (@($settingsSectionHeaders | Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text
            }).Count -lt 1) {
                $headerRoles = @($settingsSectionHeaders | ForEach-Object {
                    "$($_.Current.ControlType.ProgrammaticName):class=$([WinghosttyAccessibilityNative]::WindowClass([IntPtr]$_.Current.NativeWindowHandle))"
                })
                throw "Settings section '$sectionName' header roles were '$($headerRoles -join ', ')'; expected a visible UIA Text header."
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
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button
            })
            $unnamedSettingsControls = @($interactiveSettingsControls | Where-Object {
                [string]::IsNullOrWhiteSpace($_.Current.Name)
            })
            if ($unnamedSettingsControls.Count -ne 0) {
                throw "Settings section '$sectionName' exposes $($unnamedSettingsControls.Count) unnamed visible content controls."
            }
            $expectedControls = @($settingsExpectedControls[$sectionName])
            foreach ($expectedControl in $expectedControls) {
                $controlMatches = @($interactiveSettingsControls | Where-Object {
                    $_.Current.Name -eq $expectedControl.Name -and
                    $_.Current.ControlType -eq $expectedControl.Type
                })
                if ($controlMatches.Count -ne 1) {
                    throw "Settings section '$sectionName' exposes $($controlMatches.Count) '$($expectedControl.Name)' $($expectedControl.Type.ProgrammaticName) controls; expected exactly one."
                }
            }
            if ($interactiveSettingsControls.Count -ne $expectedControls.Count) {
                $observedControls = @($interactiveSettingsControls | ForEach-Object {
                    "$($_.Current.Name):$($_.Current.ControlType.ProgrammaticName)"
                })
                throw "Settings section '$sectionName' exposes $($interactiveSettingsControls.Count) visible content controls; expected $($expectedControls.Count). Observed: $($observedControls -join ', ')."
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
            $settingsLayoutControls = @($sectionButtons) + @($interactiveSettingsControls)
            $containedElements = @($namedSettingsText) + @($settingsLayoutControls)
            foreach ($containedElement in $containedElements) {
                $bounds = $containedElement.Current.BoundingRectangle
                $settingsContainmentChecks++
                if ($bounds.Left -lt ($settingsClientRect.left - 3) -or
                    $bounds.Top -lt ($settingsClientRect.top - 3) -or
                    $bounds.Right -gt ($settingsClientRect.right + 3) -or
                    $bounds.Bottom -gt ($settingsClientRect.bottom + 3)) {
                    throw "Settings section '$sectionName' element '$($containedElement.Current.Name)' ($($containedElement.Current.ControlType.ProgrammaticName)) escapes the client bounds: element=$bounds client=[$($settingsClientRect.left),$($settingsClientRect.top),$($settingsClientRect.right),$($settingsClientRect.bottom)]."
                }
            }
            for ($leftControlIndex = 0; $leftControlIndex -lt $settingsLayoutControls.Count; $leftControlIndex++) {
                $leftControl = $settingsLayoutControls[$leftControlIndex]
                $leftControlBounds = $leftControl.Current.BoundingRectangle
                for ($rightControlIndex = $leftControlIndex + 1; $rightControlIndex -lt $settingsLayoutControls.Count; $rightControlIndex++) {
                    $rightControl = $settingsLayoutControls[$rightControlIndex]
                    if ((Test-AccessibilityAncestor -Ancestor $leftControl -Descendant $rightControl) -or
                        (Test-AccessibilityAncestor -Ancestor $rightControl -Descendant $leftControl)) {
                        continue
                    }
                    $rightControlBounds = $rightControl.Current.BoundingRectangle
                    $overlapWidth = [Math]::Min($leftControlBounds.Right, $rightControlBounds.Right) - [Math]::Max($leftControlBounds.Left, $rightControlBounds.Left)
                    $overlapHeight = [Math]::Min($leftControlBounds.Bottom, $rightControlBounds.Bottom) - [Math]::Max($leftControlBounds.Top, $rightControlBounds.Top)
                    $settingsControlOverlapComparisons++
                    if ($overlapWidth -gt 2 -and $overlapHeight -gt 2) {
                        throw "Settings section '$sectionName' has overlapping controls '$($leftControl.Current.Name)' and '$($rightControl.Current.Name)' (${overlapWidth}x${overlapHeight}px)."
                    }
                }
            }
            $settingsNamedTextTotal += $namedSettingsText.Count
            $settingsSectionEvidence += [ordered]@{
                name = $sectionName
                selected = $true
                visible_named_text = $namedSettingsText.Count
                visible_content_controls = $interactiveSettingsControls.Count
            }
        }
        $selectedBeforeFocus = @($sectionButtons | Where-Object {
            $candidateSelection = $null
            $_.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$candidateSelection
            ) -and $candidateSelection.Current.IsSelected
        } | ForEach-Object { $_.Current.Name })
        if ($selectedBeforeFocus.Count -ne 1) {
            throw "Settings cycle $settingsCycle has no unique section before focus probe."
        }
        $focusSection = @($sectionButtons | Where-Object {
            $_.Current.Name -ne $selectedBeforeFocus[0]
        })[0]
        $focusSectionHwnd = [IntPtr]$focusSection.Current.NativeWindowHandle
        $focusSectionSelection = $null
        if (-not $focusSection.TryGetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern,
            [ref]$focusSectionSelection
        )) {
            throw "Settings focus probe section '$($focusSection.Current.Name)' exposes no SelectionItemPattern."
        }
        try {
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings section focus and selection ownership' -Condition {
                if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -ne $settingsHwnd) {
                    [void][WinghosttyAccessibilityNative]::ForceForeground($settingsHwnd)
                    return $false
                }
                $focusSection.SetFocus()
                $focusSectionSelection.Select()
                $script:settingsFocusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
                $script:settingsSelectedAfterFocus = @($sectionButtons | Where-Object {
                    $candidateSelection = $null
                    $_.TryGetCurrentPattern(
                        [System.Windows.Automation.SelectionItemPattern]::Pattern,
                        [ref]$candidateSelection
                    ) -and $candidateSelection.Current.IsSelected
                } | ForEach-Object { $_.Current.Name })
                $script:settingsFocusedSectionHeaders = @($settingsElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::Text
                    )
                ) | Where-Object {
                    $_.Current.Name -eq $focusSection.Current.Name -and -not $_.Current.IsOffscreen
                })
                return $null -ne $script:settingsFocusedElement -and
                    [System.Windows.Automation.Automation]::Compare($script:settingsFocusedElement, $focusSection) -and
                    [WinghosttyAccessibilityNative]::FocusedWindowFor($settingsHwnd) -eq $focusSectionHwnd -and
                    $script:settingsSelectedAfterFocus.Count -eq 1 -and
                    $script:settingsSelectedAfterFocus[0] -eq $focusSection.Current.Name -and
                    $script:settingsFocusedSectionHeaders.Count -ge 1
            }
        }
        catch {
            $focusedSummary = if ($null -eq $script:settingsFocusedElement) {
                '<none>'
            }
            else {
                "$($script:settingsFocusedElement.Current.Name):$($script:settingsFocusedElement.Current.ControlType.ProgrammaticName):hwnd=$($script:settingsFocusedElement.Current.NativeWindowHandle)"
            }
            $nativeFocusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($settingsHwnd)
            $selectedSummary = @($script:settingsSelectedAfterFocus) -join ', '
            $headerSummary = @($script:settingsFocusedSectionHeaders | ForEach-Object {
                "$($_.Current.Name):offscreen=$($_.Current.IsOffscreen)"
            }) -join ', '
            throw "Settings focus/selection probe failed for '$($focusSection.Current.Name)': focused=$focusedSummary; native_focused_hwnd=$nativeFocusedHwnd; expected_hwnd=$focusSectionHwnd; selected=$selectedSummary; headers=$headerSummary. $($_.Exception.Message)"
        }
        if ($settingsCycle -eq 1 -and $themeHighContrastActive) {
            $themePreviewEvidence = [ordered]@{
                skipped = $true
                skip_reason = 'High Contrast active; explicit app-theme pixel preview is intentionally bypassed'
                rollback_verified = $false
            }
        }
        elseif ($settingsCycle -eq 1) {
            $appearanceButton = @($sectionButtons | Where-Object { $_.Current.Name -eq 'Appearance' })[0]
            $appearanceSelection = $null
            if (-not $appearanceButton.TryGetCurrentPattern(
                [System.Windows.Automation.SelectionItemPattern]::Pattern,
                [ref]$appearanceSelection
            )) {
                throw 'Settings Appearance section exposes no SelectionItemPattern for theme preview.'
            }
            $appearanceSelection.Select()
            $windowTheme = @($settingsElements | Where-Object {
                $_.Current.Name -eq 'Window theme' -and
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox
            }) | Select-Object -First 1
            if ($null -eq $windowTheme) { throw 'Settings exposes no Window theme combo.' }
            $windowThemeHwnd = [IntPtr]$windowTheme.Current.NativeWindowHandle
            $originalThemeIndex = [WinghosttyAccessibilityNative]::SendMessageW(
                $windowThemeHwnd,
                0x0147,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            ).ToInt64()
            if ($originalThemeIndex -ne 1) {
                throw "Seeded window-theme=system resolved to Settings index $originalThemeIndex instead of 1."
            }
            $settingsClientWidth = $settingsClientRect.right - $settingsClientRect.left
            $settingsClientHeight = $settingsClientRect.bottom - $settingsClientRect.top
            $hostClientRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen(
                $process.MainWindowHandle
            )
            $hostClientWidth = $hostClientRect.right - $hostClientRect.left
            $hostClientHeight = $hostClientRect.bottom - $hostClientRect.top
            $originalSettingsGrid = Get-AccessibilityClientPixelGrid `
                -Hwnd $settingsHwnd `
                -MinX 24 `
                -MaxX ([Math]::Max(24, $settingsClientWidth - 24)) `
                -MinY 24 `
                -MaxY ([Math]::Max(24, $settingsClientHeight - 24)) `
                -Step 16
            $originalHostGrid = Get-AccessibilityClientPixelGrid `
                -Hwnd $process.MainWindowHandle `
                -MinX 24 `
                -MaxX ([Math]::Max(24, $hostClientWidth - 24)) `
                -MinY 8 `
                -MaxY ([Math]::Max(8, [Math]::Min(48, $hostClientHeight - 8))) `
                -Step 8
            if ($originalSettingsGrid.Count -eq 0 -or $originalHostGrid.Count -eq 0) {
                throw "Theme preview could not sample initial Settings/host client grids (settings=$($originalSettingsGrid.Count), host=$($originalHostGrid.Count))."
            }
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $windowThemeHwnd,
                0x014E,
                [UIntPtr]::new(3),
                [IntPtr]::Zero
            )
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $settingsHwnd,
                0x0111,
                [UIntPtr]::new(0x00010195),
                $windowThemeHwnd
            )
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Settings and host System-to-Dark preview pixels' -Condition {
                $script:systemDarkIndex = [WinghosttyAccessibilityNative]::SendMessageW(
                    $windowThemeHwnd,
                    0x0147,
                    [UIntPtr]::Zero,
                    [IntPtr]::Zero
                ).ToInt64()
                $script:systemDarkSettingsPixel = Find-AccessibilityClientPixel `
                    -Hwnd $settingsHwnd `
                    -OriginalGrid $originalSettingsGrid `
                    -TargetColor ([uint32]0x00202020)
                $script:systemDarkHostPixel = Find-AccessibilityClientPixel `
                    -Hwnd $process.MainWindowHandle `
                    -OriginalGrid $originalHostGrid `
                    -TargetColor ([uint32]0x00202020)
                return $script:systemDarkIndex -eq 3 -and
                    $null -ne $script:systemDarkSettingsPixel -and
                    $null -ne $script:systemDarkHostPixel
            }
            $systemSettingsColor = $script:systemDarkSettingsPixel.original_color
            $systemHostColor = $script:systemDarkHostPixel.original_color
            $systemAlreadyResolvedDark = (
                $systemSettingsColor -eq [uint32]0x00202020 -and
                $systemHostColor -eq [uint32]0x00202020
            )
            $systemToDarkVisualTransition = -not $systemAlreadyResolvedDark
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $windowThemeHwnd,
                0x014E,
                [UIntPtr]::new(2),
                [IntPtr]::Zero
            )
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $settingsHwnd,
                0x0111,
                [UIntPtr]::new(0x00010195),
                $windowThemeHwnd
            )
            try {
                Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Settings and host forced-Light preview pixels' -Condition {
                    $script:lightSettingsPixel = Find-AccessibilityClientPixel `
                        -Hwnd $settingsHwnd `
                        -OriginalGrid $originalSettingsGrid `
                        -TargetColor ([uint32]0x00F3F3F3)
                    $script:lightHostPixel = Find-AccessibilityClientPixel `
                        -Hwnd $process.MainWindowHandle `
                        -OriginalGrid $originalHostGrid `
                        -TargetColor ([uint32]0x00F3F3F3)
                    return $null -ne $script:lightSettingsPixel -and
                        $null -ne $script:lightHostPixel
                }
            }
            catch {
                $lightDiagnosticIndex = [WinghosttyAccessibilityNative]::SendMessageW(
                    $windowThemeHwnd,
                    0x0147,
                    [UIntPtr]::Zero,
                    [IntPtr]::Zero
                ).ToInt64()
                $lightSettingsColors = @(Get-AccessibilityClientPixelGrid `
                    -Hwnd $settingsHwnd -MinX 24 -MaxX ([Math]::Max(24, $settingsClientWidth - 24)) `
                    -MinY 24 -MaxY ([Math]::Max(24, $settingsClientHeight - 24)) -Step 16 |
                    ForEach-Object { $_.Values } | ForEach-Object { $_.color } |
                    Group-Object | Sort-Object Count -Descending | Select-Object -First 8 |
                    ForEach-Object { "$($_.Name):$($_.Count)" })
                $lightHostColors = @(Get-AccessibilityClientPixelGrid `
                    -Hwnd $process.MainWindowHandle -MinX 24 -MaxX ([Math]::Max(24, $hostClientWidth - 24)) `
                    -MinY 8 -MaxY ([Math]::Max(8, [Math]::Min(48, $hostClientHeight - 8))) -Step 8 |
                    ForEach-Object { $_.Values } | ForEach-Object { $_.color } |
                    Group-Object | Sort-Object Count -Descending | Select-Object -First 8 |
                    ForEach-Object { "$($_.Name):$($_.Count)" })
                throw "$($_.Exception.Message) settings_alive=$([WinghosttyAccessibilityNative]::IsWindow($settingsHwnd)) host_alive=$([WinghosttyAccessibilityNative]::IsWindow($process.MainWindowHandle)) combo_index=$lightDiagnosticIndex settings_colors=$($lightSettingsColors -join ',') host_colors=$($lightHostColors -join ',')."
            }
            $settingsSampleX = $script:lightSettingsPixel.x
            $settingsSampleY = $script:lightSettingsPixel.y
            $hostSampleX = $script:lightHostPixel.x
            $hostSampleY = $script:lightHostPixel.y
            $originalSettingsColor = $script:lightSettingsPixel.original_color
            $originalHostColor = $script:lightHostPixel.original_color
            $script:lightSettingsColor = $script:lightSettingsPixel.color
            $script:lightHostColor = $script:lightHostPixel.color
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $windowThemeHwnd,
                0x014E,
                [UIntPtr]::new(3),
                [IntPtr]::Zero
            )
            [void][WinghosttyAccessibilityNative]::SendMessageW(
                $settingsHwnd,
                0x0111,
                [UIntPtr]::new(0x00010195),
                $windowThemeHwnd
            )
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Settings and host Light-to-Dark preview pixels' -Condition {
                [uint32]$darkSettingsColorProbe = 0
                [uint32]$darkHostColorProbe = 0
                $darkSettingsPixelValid = [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                    $settingsHwnd,
                    $settingsSampleX,
                    $settingsSampleY,
                    [ref]$darkSettingsColorProbe
                )
                $darkHostPixelValid = [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                    $process.MainWindowHandle,
                    $hostSampleX,
                    $hostSampleY,
                    [ref]$darkHostColorProbe
                )
                $script:darkSettingsColor = $darkSettingsColorProbe
                $script:darkHostColor = $darkHostColorProbe
                return $darkSettingsPixelValid -and $darkHostPixelValid -and
                    $script:darkSettingsColor -eq [uint32]0x00202020 -and
                    $script:darkHostColor -eq [uint32]0x00202020 -and
                    $script:darkSettingsColor -ne $script:lightSettingsColor -and
                    $script:darkHostColor -ne $script:lightHostColor
            }
            $themePreviewEvidence = [ordered]@{
                skipped = $false
                original_index = $originalThemeIndex
                light_index = 2
                dark_index = 3
                original_settings_color = $originalSettingsColor
                settings_sample_x = $settingsSampleX
                settings_sample_y = $settingsSampleY
                light_settings_color = $script:lightSettingsColor
                dark_settings_color = $script:darkSettingsColor
                original_host_color = $originalHostColor
                host_sample_x = $hostSampleX
                host_sample_y = $hostSampleY
                light_host_color = $script:lightHostColor
                dark_host_color = $script:darkHostColor
                system_to_dark_covered = $true
                system_to_dark_selected_index = $script:systemDarkIndex
                system_settings_color = $systemSettingsColor
                system_settings_sample_x = $script:systemDarkSettingsPixel.x
                system_settings_sample_y = $script:systemDarkSettingsPixel.y
                system_dark_settings_color = $script:systemDarkSettingsPixel.color
                system_host_color = $systemHostColor
                system_host_sample_x = $script:systemDarkHostPixel.x
                system_host_sample_y = $script:systemDarkHostPixel.y
                system_dark_host_color = $script:systemDarkHostPixel.color
                system_already_resolved_dark = $systemAlreadyResolvedDark
                system_to_dark_visual_transition = $systemToDarkVisualTransition
                system_to_dark_visual_transition_status = if ($systemAlreadyResolvedDark) {
                    'not applicable: System already resolved exact Dark'
                } else {
                    'observed'
                }
                light_settings_expected = [uint32]0x00F3F3F3
                dark_settings_expected = [uint32]0x00202020
                restored_index = $null
                restored_settings_color = $null
                restored_host_color = $null
                config_bytes_unchanged = $false
                rollback_verified = $false
            }
            [void](Invoke-InteractiveWin11Message `
                -Hwnd $settingsHwnd `
                -Message 0x0010 `
                -WParam ([UIntPtr]::Zero) `
                -LParam ([IntPtr]::Zero) `
                -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
                -Process $process `
                -Description 'close Settings with Dark preview pending')
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'Settings Dark preview discard action' -Condition {
                $script:themeDiscardButton = @($settingsElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition
                ) | Where-Object {
                    $_.Current.Name -eq 'Discard changes' -and -not $_.Current.IsOffscreen
                }) | Select-Object -First 1
                return $null -ne $script:themeDiscardButton
            }
            $discardInvoke = $null
            if (-not $script:themeDiscardButton.TryGetCurrentPattern(
                [System.Windows.Automation.InvokePattern]::Pattern,
                [ref]$discardInvoke
            )) {
                throw 'Settings Dark preview discard action exposes no InvokePattern.'
            }
            $discardInvoke.Invoke()
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'Settings Dark preview discard close' -Condition {
                return -not [WinghosttyAccessibilityNative]::IsWindow($settingsHwnd)
            }
            Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'host pixel restore after Dark preview discard' -Condition {
                [uint32]$discardHostColorProbe = 0
                return [WinghosttyAccessibilityNative]::TrySampleWindowClientPixel(
                    $process.MainWindowHandle,
                    $hostSampleX,
                    $hostSampleY,
                    [ref]$discardHostColorProbe
                ) -and $discardHostColorProbe -eq $originalHostColor
            }
            $settingsClosedByThemeDiscard = $true
        }
        $settingsCycles += [ordered]@{
            cycle = $settingsCycle
            hwnd = $settingsHwnd.ToInt64()
            name = $settingsElement.Current.Name
            named_visible_text_labels = $settingsNamedTextTotal
            label_overlap_comparisons = $settingsLabelOverlapComparisons
            label_control_overlap_comparisons = $settingsOverlapComparisons
            control_overlap_comparisons = $settingsControlOverlapComparisons
            client_containment_checks = $settingsContainmentChecks
            focus_selected_section = $focusSection.Current.Name
            sections = $settingsSectionEvidence
            bounds = [ordered]@{
                left = $settingsRect.left
                top = $settingsRect.top
                width = $settingsRect.right - $settingsRect.left
                height = $settingsRect.bottom - $settingsRect.top
            }
        }
        if (-not $settingsClosedByThemeDiscard) {
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
    }
    $settingsLifecycle = [ordered]@{
        cycles = $settingsCycles
        reopened = $true
        theme_preview = $themePreviewEvidence
    }

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
    $ownerSettingsElement = Wait-AccessibilityWindowElement `
        -Hwnd $ownerSettingsHwnd `
        -Description 'Settings owner probe'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings owner probe Terminal UIA section' -Condition {
        $script:ownerSettingsElements = @($ownerSettingsElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ) | ForEach-Object { $_ })
        $script:ownerTerminalSection = @($script:ownerSettingsElements | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and
            $_.Current.Name -eq 'Terminal'
        }) | Select-Object -First 1
        return $null -ne $script:ownerTerminalSection
    }
    $ownerSettingsElements = @($script:ownerSettingsElements)
    $ownerTerminalSection = $script:ownerTerminalSection
    $ownerTerminalSelection = $null
    if (-not $ownerTerminalSection.TryGetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern,
        [ref]$ownerTerminalSelection
    )) {
        throw 'Settings owner probe Terminal section has no SelectionItemPattern.'
    }
    $ownerTerminalSelection.Select()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings owner probe Terminal section' -Condition {
        return $ownerTerminalSelection.Current.IsSelected
    }
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
        if ([WinghosttyAccessibilityNative]::GetForegroundWindow() -ne $ownerSettingsHwnd) {
            $saveNativeFocusBeforeRecovery = [WinghosttyAccessibilityNative]::FocusedWindowFor($ownerSettingsHwnd)
            if ($saveNativeFocusBeforeRecovery -ne $ownerSaveHwnd) {
                throw "Settings Save lost native focus before foreground recovery (focused=$saveNativeFocusBeforeRecovery expected=$ownerSaveHwnd)."
            }
            [void][WinghosttyAccessibilityNative]::ForceForeground($ownerSettingsHwnd)
            return $false
        }
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

    [WinghosttyAccessibilityNative]::ResetAutomationFocusChangedCount()
    $settingsFocusHandler = [Delegate]::CreateDelegate(
        [System.Windows.Automation.AutomationFocusChangedEventHandler],
        [WinghosttyAccessibilityNative].GetMethod('OnAutomationFocusChanged')
    )
    [System.Windows.Automation.Automation]::AddAutomationFocusChangedEventHandler($settingsFocusHandler)
    $settingsFocusRegistered = $true
    if (-not [WinghosttyAccessibilityNative]::ForceForeground($ownerSettingsHwnd)) {
        throw 'Unable to foreground surviving Settings before its dirty-close request.'
    }
    if (-not [WinghosttyAccessibilityNative]::PostMessageW(
        $ownerSettingsHwnd,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )) {
        throw "PostMessageW failed while explicitly closing surviving settings: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings inline dirty-close prompt' -Condition {
        $modalDialogs = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$ownerProbeProcess.Id,
            '#32770'
        ))
        if ($modalDialogs.Count -ne 0) {
            throw 'Settings dirty close opened a modal #32770 dialog instead of its inline confirmation surface.'
        }
        if (-not [WinghosttyAccessibilityNative]::IsWindow($ownerSettingsHwnd)) {
            throw 'Settings dirty close destroyed the window before confirmation.'
        }
        $script:ownerClosePromptElements = @($ownerSettingsElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ) | ForEach-Object { $_ })
        $script:ownerClosePromptText = @($script:ownerClosePromptElements | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and
            $_.Current.Name -eq 'Save changes before closing?' -and
            -not $_.Current.IsOffscreen
        }) | Select-Object -First 1
        $script:ownerClosePromptButtons = @($script:ownerClosePromptElements | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
            $_.Current.Name -in @('Save and close', 'Discard changes', 'Keep editing') -and
            -not $_.Current.IsOffscreen
        })
        return $null -ne $script:ownerClosePromptText -and $script:ownerClosePromptButtons.Count -eq 3
    }
    $ownerKeepEditingButton = @($script:ownerClosePromptButtons | Where-Object { $_.Current.Name -eq 'Keep editing' }) | Select-Object -First 1
    $ownerDiscardButton = @($script:ownerClosePromptButtons | Where-Object { $_.Current.Name -eq 'Discard changes' }) | Select-Object -First 1
    $ownerSaveAndCloseButton = @($script:ownerClosePromptButtons | Where-Object { $_.Current.Name -eq 'Save and close' }) | Select-Object -First 1
    $ownerKeepEditingHwnd = [IntPtr]$ownerKeepEditingButton.Current.NativeWindowHandle
    foreach ($closePromptButton in @($ownerSaveAndCloseButton, $ownerDiscardButton, $ownerKeepEditingButton)) {
        if ($null -eq $closePromptButton -or -not $closePromptButton.Current.IsEnabled) {
            throw 'Settings inline dirty-close prompt has a missing or disabled action.'
        }
        $closePromptInvoke = $null
        if (-not $closePromptButton.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern,
            [ref]$closePromptInvoke
        )) {
            throw "Settings inline dirty-close action '$($closePromptButton.Current.Name)' has no InvokePattern."
        }
    }
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings conservative dirty-close focus' -Condition {
            $script:ownerClosePromptFocusedElement = [System.Windows.Automation.AutomationElement]::FocusedElement
            $script:ownerClosePromptFocusEvent = @([WinghosttyAccessibilityNative]::AutomationFocusChangedSenders | Where-Object {
                $_ -is [System.Windows.Automation.AutomationElement] -and
                [System.Windows.Automation.Automation]::Compare($_, $ownerKeepEditingButton)
            }) | Select-Object -First 1
            return [WinghosttyAccessibilityNative]::GetForegroundWindow() -eq $ownerSettingsHwnd -and
                [WinghosttyAccessibilityNative]::FocusedWindowFor($ownerSettingsHwnd) -eq $ownerKeepEditingHwnd -and
                $ownerKeepEditingButton.Current.HasKeyboardFocus -and
                $null -ne $script:ownerClosePromptFocusEvent
        }
    }
    catch {
        $focusDiagnostic = [System.Windows.Automation.AutomationElement]::FocusedElement
        $focusDiagnosticName = if ($null -ne $focusDiagnostic) { $focusDiagnostic.Current.Name } else { '<none>' }
        $focusDiagnosticHwnd = if ($null -ne $focusDiagnostic) { $focusDiagnostic.Current.NativeWindowHandle } else { 0 }
        throw "Settings conservative dirty-close focus mismatch: foreground=$([WinghosttyAccessibilityNative]::GetForegroundWindow()); expected_foreground=$ownerSettingsHwnd; native_focus=$([WinghosttyAccessibilityNative]::FocusedWindowFor($ownerSettingsHwnd)); expected_native_focus=$ownerKeepEditingHwnd; target_has_uia_focus=$($ownerKeepEditingButton.Current.HasKeyboardFocus); exact_focus_events=$(@([WinghosttyAccessibilityNative]::AutomationFocusChangedSenders | Where-Object { $_ -is [System.Windows.Automation.AutomationElement] -and [System.Windows.Automation.Automation]::Compare($_, $ownerKeepEditingButton) }).Count); global_uia_focus_hwnd=$focusDiagnosticHwnd; global_uia_focus_name='$focusDiagnosticName'. $($_.Exception.Message)"
    }
    [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($settingsFocusHandler)
    $settingsFocusRegistered = $false
    $keepEditingInvoke = $null
    if (-not $ownerKeepEditingButton.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$keepEditingInvoke
    )) {
        throw "Settings inline dirty-close action 'Keep editing' lost InvokePattern."
    }
    $keepEditingInvoke.Invoke()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings keep-editing draft preservation' -Condition {
        $visibleCloseActions = @($ownerSettingsElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ) | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
            $_.Current.Name -in @('Save and close', 'Discard changes', 'Keep editing') -and
            -not $_.Current.IsOffscreen
        })
        return $visibleCloseActions.Count -eq 0 -and
            $scrollbackValuePattern.Current.Value -eq $draftScrollbackText -and
            $ownerSaveButton.Current.IsEnabled
    }
    if (-not [WinghosttyAccessibilityNative]::PostMessageW(
        $ownerSettingsHwnd,
        0x0010,
        [UIntPtr]::Zero,
        [IntPtr]::Zero
    )) {
        throw "PostMessageW failed while reopening the inline settings close prompt: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings inline dirty-close prompt reopens' -Condition {
        $script:ownerClosePromptButtons = @($ownerSettingsElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        ) | Where-Object {
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
            $_.Current.Name -in @('Save and close', 'Discard changes', 'Keep editing') -and
            -not $_.Current.IsOffscreen
        })
        return $script:ownerClosePromptButtons.Count -eq 3
    }
    $ownerDiscardButton = @($script:ownerClosePromptButtons | Where-Object { $_.Current.Name -eq 'Discard changes' }) | Select-Object -First 1
    $discardInvoke = $null
    if ($null -eq $ownerDiscardButton -or -not $ownerDiscardButton.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$discardInvoke
    )) {
        throw "Settings inline dirty-close action 'Discard changes' has no InvokePattern."
    }
    $discardInvoke.Invoke()
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'settings owner probe clean exit' -Condition {
            $ownerProbeProcess.Refresh()
            return $ownerProbeProcess.HasExited
        }
    }
    catch {
        $ownerProbeProcess.Refresh()
        $ownerSettingsAfterDiscard = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$ownerProbeProcess.Id,
            'winghostty.win32.settings'
        ))
        $ownerHostsAfterDiscard = @([WinghosttyAccessibilityNative]::TopLevelWindowsForProcess(
            [uint32]$ownerProbeProcess.Id,
            'winghostty.win32.host'
        ))
        throw "Settings owner probe did not exit after Discard: exited=$($ownerProbeProcess.HasExited); settings_windows=$($ownerSettingsAfterDiscard -join ', '); host_windows=$($ownerHostsAfterDiscard -join ', '); settings_hwnd_alive=$([WinghosttyAccessibilityNative]::IsWindow($ownerSettingsHwnd)); settings_hwnd_visible=$([WinghosttyAccessibilityNative]::IsWindowVisible($ownerSettingsHwnd).ToString()). $($_.Exception.Message)"
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
        inline_close_prompt = $true
        no_modal_close_dialog = $true
        keep_editing_default_focus = $true
        keep_editing_preserved_dirty_draft = $true
        explicitly_discarded = $true
        exit_code = $ownerProbeExitCode
    }

    # Exercise the third inline outcome end-to-end. Persist through the UIA
    # Invoke provider, terminate the writer, and prove a new process in the
    # same isolated sandbox observes the value before restoring the baseline.
    $settingsConfigBaselineExisted = [System.IO.File]::Exists($sandboxConfigPath)
    $settingsConfigBaselineBytes = if ($settingsConfigBaselineExisted) {
        [System.IO.File]::ReadAllBytes($sandboxConfigPath)
    } else {
        [byte[]]@()
    }
    $settingsConfigBaselineCaptured = $true
    $saveProbeClass = "winghostty-accessibility-settings-save-$([Guid]::NewGuid().ToString('N'))"
    $saveProbeArguments = @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=$saveProbeClass"
    )
    $saveProbeProcess = Start-AccessibilityProcessWithEnvironment `
        -FilePath $exe `
        -ArgumentList $saveProbeArguments `
        -WorkingDirectory $repoRoot `
        -EnvironmentVariables $settingsProbeEnvironment `
        -RedirectStandardOutput (Join-Path $layout.Logs 'interactive-win11-accessibility-settings-save-stdout.log') `
        -RedirectStandardError (Join-Path $layout.Logs 'interactive-win11-accessibility-settings-save-stderr.log')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -Description 'settings save probe main HWND' -Condition {
        $saveProbeProcess.Refresh()
        return -not $saveProbeProcess.HasExited -and $saveProbeProcess.MainWindowHandle -ne [IntPtr]::Zero
    }
    $saveProbe = Open-AccessibilitySettingsProbe -Process $saveProbeProcess -Description 'settings save probe'
    $saveScrollback = Get-AccessibilityScrollbackProbe -SettingsProbe $saveProbe -Description 'settings save probe'
    $saveTheme = Get-AccessibilityThemeProbe -SettingsProbe $saveProbe -Description 'settings save probe'
    $settingsPersistenceOriginalThemeIndex = [int]$saveTheme.Index
    if ($settingsPersistenceOriginalThemeIndex -lt 0 -or
        $settingsPersistenceOriginalThemeIndex -gt 4) {
        throw "Settings persistence sandbox exposed invalid Window theme index $settingsPersistenceOriginalThemeIndex."
    }
    [uint64]$settingsPersistenceOriginalScrollback = 0
    if (-not [uint64]::TryParse(
        $saveScrollback.Value.Current.Value,
        [ref]$settingsPersistenceOriginalScrollback
    )) {
        throw "Settings persistence sandbox exposed a nonnumeric scrollback baseline: $($saveScrollback.Value.Current.Value)."
    }
    $settingsPersistenceOriginalScrollbackText = $settingsPersistenceOriginalScrollback.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $settingsPersistenceDraft = if ($settingsPersistenceOriginalScrollback -lt [uint64]::MaxValue) {
        $settingsPersistenceOriginalScrollback + 1
    } else {
        $settingsPersistenceOriginalScrollback - 1
    }
    $settingsPersistenceDraftText = $settingsPersistenceDraft.ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
    $saveScrollback.Value.SetValue($settingsPersistenceDraftText)
    Set-AccessibilityThemeIndex `
        -SettingsProbe $saveProbe `
        -ThemeProbe $saveTheme `
        -Index 3 `
        -Description 'settings save probe Dark selection'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings save probe dirty draft' -Condition {
        return $saveScrollback.Value.Current.Value -eq $settingsPersistenceDraftText -and
            [WinghosttyAccessibilityNative]::SendMessageW(
                $saveTheme.Hwnd,
                0x0147,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            ).ToInt64() -eq 3 -and
            $saveScrollback.Save.Current.IsEnabled
    }
    Invoke-AccessibilitySettingsCloseAction `
        -SettingsProbe $saveProbe `
        -ActionName 'Save and close' `
        -Description 'settings save probe'
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -Description 'settings save-and-close completion' -Condition {
        return -not [WinghosttyAccessibilityNative]::IsWindow($saveProbe.Hwnd)
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings persisted config bytes' -Condition {
        if (-not (Test-Path -LiteralPath $sandboxConfigPath -PathType Leaf)) { return $false }
        $persistedConfig = Get-Content -LiteralPath $sandboxConfigPath -Raw
        return $persistedConfig -match "(?m)^scrollback-limit\s*=\s*$([regex]::Escape($settingsPersistenceDraftText))\s*$" -and
            $persistedConfig -match '(?m)^window-theme\s*=\s*dark\s*$'
    }
    Stop-InteractiveWin11Process -Process $saveProbeProcess -Contained
    $saveProbeProcess = $null

    $saveVerifyClass = "winghostty-accessibility-settings-save-verify-$([Guid]::NewGuid().ToString('N'))"
    $saveVerifyArguments = @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=$saveVerifyClass"
    )
    $saveVerifyProcess = Start-AccessibilityProcessWithEnvironment `
        -FilePath $exe `
        -ArgumentList $saveVerifyArguments `
        -WorkingDirectory $repoRoot `
        -EnvironmentVariables $settingsProbeEnvironment `
        -RedirectStandardOutput (Join-Path $layout.Logs 'interactive-win11-accessibility-settings-save-verify-stdout.log') `
        -RedirectStandardError (Join-Path $layout.Logs 'interactive-win11-accessibility-settings-save-verify-stderr.log')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds($TimeoutSeconds)) -Description 'settings persistence verifier main HWND' -Condition {
        $saveVerifyProcess.Refresh()
        return -not $saveVerifyProcess.HasExited -and $saveVerifyProcess.MainWindowHandle -ne [IntPtr]::Zero
    }
    $saveVerifyProbe = Open-AccessibilitySettingsProbe -Process $saveVerifyProcess -Description 'settings persistence verifier'
    $verifyScrollback = Get-AccessibilityScrollbackProbe -SettingsProbe $saveVerifyProbe -Description 'settings persistence verifier'
    $verifyTheme = Get-AccessibilityThemeProbe -SettingsProbe $saveVerifyProbe -Description 'settings persistence verifier'
    if ($verifyScrollback.Value.Current.Value -ne $settingsPersistenceDraftText) {
        throw "Save and close did not survive a same-sandbox process relaunch; expected=$settingsPersistenceDraftText actual=$($verifyScrollback.Value.Current.Value)."
    }
    if ($verifyTheme.Index -ne 3) {
        throw "Saved Dark theme did not survive a same-sandbox process relaunch; expected index 3, actual=$($verifyTheme.Index)."
    }

    $verifySettingsRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen(
        $saveVerifyProbe.Hwnd
    )
    $verifyHostRect = [WinghosttyAccessibilityNative]::ClientRectOnScreen(
        $saveVerifyProcess.MainWindowHandle
    )
    $verifySettingsGrid = Get-AccessibilityClientPixelGrid `
        -Hwnd $saveVerifyProbe.Hwnd `
        -MinX 24 `
        -MaxX ([Math]::Max(24, ($verifySettingsRect.right - $verifySettingsRect.left) - 24)) `
        -MinY 24 `
        -MaxY ([Math]::Max(24, ($verifySettingsRect.bottom - $verifySettingsRect.top) - 24)) `
        -Step 16
    $verifyHostGrid = Get-AccessibilityClientPixelGrid `
        -Hwnd $saveVerifyProcess.MainWindowHandle `
        -MinX 24 `
        -MaxX ([Math]::Max(24, ($verifyHostRect.right - $verifyHostRect.left) - 24)) `
        -MinY 8 `
        -MaxY ([Math]::Max(8, [Math]::Min(48, ($verifyHostRect.bottom - $verifyHostRect.top) - 8))) `
        -Step 8
    $verifySettingsDarkPixel = @($verifySettingsGrid.Values | Where-Object {
        [uint32]$_.color -eq [uint32]0x00202020
    }) | Select-Object -First 1
    $verifyHostDarkPixel = @($verifyHostGrid.Values | Where-Object {
        [uint32]$_.color -eq [uint32]0x00202020
    }) | Select-Object -First 1
    if ($null -eq $verifySettingsDarkPixel -or $null -eq $verifyHostDarkPixel) {
        throw "Fresh Dark process exposes no exact 0x00202020 Settings/host pixels (settings=$($verifySettingsGrid.Count), host=$($verifyHostGrid.Count))."
    }
    $verifyHostDwmDark = Get-AccessibilityDwmUInt `
        -Hwnd $saveVerifyProcess.MainWindowHandle `
        -Attribute 20 `
        -Description 'fresh Dark host'
    $verifySettingsDwmDark = Get-AccessibilityDwmUInt `
        -Hwnd $saveVerifyProbe.Hwnd `
        -Attribute 20 `
        -Description 'fresh Dark Settings'
    $verifyHostBackdrop = Get-AccessibilityDwmUInt `
        -Hwnd $saveVerifyProcess.MainWindowHandle `
        -Attribute 38 `
        -Description 'fresh Dark host'
    $verifySettingsBackdrop = Get-AccessibilityDwmUInt `
        -Hwnd $saveVerifyProbe.Hwnd `
        -Attribute 38 `
        -Description 'fresh Dark Settings'
    if ($verifyHostDwmDark -ne 1 -or
        $verifySettingsDwmDark -ne 1 -or
        $verifyHostBackdrop -ne 1 -or
        $verifySettingsBackdrop -ne 1) {
        throw "Fresh Dark DWM state mismatch: host_dark=$verifyHostDwmDark settings_dark=$verifySettingsDwmDark host_backdrop=$verifyHostBackdrop settings_backdrop=$verifySettingsBackdrop."
    }

    $verifyScrollback.Value.SetValue($settingsPersistenceOriginalScrollbackText)
    Set-AccessibilityThemeIndex `
        -SettingsProbe $saveVerifyProbe `
        -ThemeProbe $verifyTheme `
        -Index $settingsPersistenceOriginalThemeIndex `
        -Description 'settings persistence original theme restore'
    $restoreInvoke = $null
    if (-not $verifyScrollback.Save.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$restoreInvoke
    )) {
        throw 'Settings persistence verifier Save button exposes no InvokePattern.'
    }
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'settings persistence restore draft' -Condition {
        return $verifyScrollback.Save.Current.IsEnabled
    }
    $restoreInvoke.Invoke()
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'settings persistence baseline restoration' -Condition {
        if ($verifyScrollback.Save.Current.IsEnabled) { return $false }
        return (Get-Content -LiteralPath $sandboxConfigPath -Raw) -match "(?m)^scrollback-limit\s*=\s*$([regex]::Escape($settingsPersistenceOriginalScrollbackText))\s*$"
    }
    $restoredAssignments = [regex]::Matches(
        (Get-Content -LiteralPath $sandboxConfigPath -Raw),
        '(?m)^scrollback-limit\s*=\s*(?<value>\d+)\s*$'
    )
    if ($restoredAssignments.Count -ne 1 -or
        $restoredAssignments[0].Groups['value'].Value -cne $settingsPersistenceOriginalScrollbackText) {
        throw "Settings persistence restore left ambiguous scrollback assignments (count=$($restoredAssignments.Count))."
    }
    $settingsThemeNames = @('auto', 'system', 'light', 'dark', 'ghostty')
    $restoredThemeAssignments = [regex]::Matches(
        (Get-Content -LiteralPath $sandboxConfigPath -Raw),
        '(?m)^window-theme\s*=\s*(?<value>\S+)\s*$'
    )
    if ($restoredThemeAssignments.Count -ne 1 -or
        $restoredThemeAssignments[0].Groups['value'].Value -cne
            $settingsThemeNames[$settingsPersistenceOriginalThemeIndex]) {
        throw "Settings persistence restore left ambiguous Window theme assignments (count=$($restoredThemeAssignments.Count))."
    }
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $saveVerifyProbe.Hwnd `
        -Message 0x0010 `
        -WParam ([UIntPtr]::Zero) `
        -LParam ([IntPtr]::Zero) `
        -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
        -Process $saveVerifyProcess `
        -Description 'close restored settings persistence verifier')
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'restored settings verifier destruction' -Condition {
        return -not [WinghosttyAccessibilityNative]::IsWindow($saveVerifyProbe.Hwnd)
    }
    Stop-InteractiveWin11Process -Process $saveVerifyProcess -Contained
    $saveVerifyProcess = $null
    Restore-AccessibilityConfigBaseline `
        -Path $sandboxConfigPath `
        -Existed $settingsConfigBaselineExisted `
        -Bytes $settingsConfigBaselineBytes
    $settingsConfigBaselineRestored = $true
    $settingsOwnerLifecycle['save_and_close_invoked'] = $true
    $settingsOwnerLifecycle['persisted_after_process_relaunch'] = $true
    $settingsOwnerLifecycle['original_value_restored'] = $true
    $settingsOwnerLifecycle['persistence_original_value'] = $settingsPersistenceOriginalScrollbackText
    $settingsOwnerLifecycle['persistence_dirty_value'] = $settingsPersistenceDraftText
    $settingsOwnerLifecycle['persistence_theme_original_index'] = $settingsPersistenceOriginalThemeIndex
    $settingsOwnerLifecycle['persistence_theme_saved_index'] = 3
    $settingsOwnerLifecycle['persistence_theme_config_dark'] = $true
    $settingsOwnerLifecycle['persistence_theme_fresh_process_index'] = [int]$verifyTheme.Index
    $settingsOwnerLifecycle['persistence_theme_dark_settings_pixel'] = $verifySettingsDarkPixel
    $settingsOwnerLifecycle['persistence_theme_dark_host_pixel'] = $verifyHostDarkPixel
    $settingsOwnerLifecycle['persistence_theme_host_dwm_dark'] = $verifyHostDwmDark
    $settingsOwnerLifecycle['persistence_theme_settings_dwm_dark'] = $verifySettingsDwmDark
    $settingsOwnerLifecycle['persistence_theme_host_backdrop'] = $verifyHostBackdrop
    $settingsOwnerLifecycle['persistence_theme_settings_backdrop'] = $verifySettingsBackdrop
    $settingsOwnerLifecycle['persistence_theme_restored'] = $true

    Send-AccessibilityChord -Keys @([uint16]0x12, [uint16]0x25) -Description 'Alt+Left before sustained output' -Process $process
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'left pane focus before sustained output' -Condition {
        return [WinghosttyAccessibilityNative]::FocusedWindowFor($process.MainWindowHandle) -eq $leftPane.Hwnd
    }
    $stressLineCount = 150
    $stressPrefix = "whs$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $stressFirstMarker = "${stressPrefix}_1"
    $stressFinalMarker = "${stressPrefix}_150"
    $stressResponsiveMarker = "${stressPrefix}responsive"
    $stressCommand = "cmd.exe /d /c `"for /L %i in (1,1,$stressLineCount) do @echo ${stressPrefix}_%i`""
    if ($stressCommand.Contains($stressFirstMarker) -or $stressCommand.Contains($stressFinalMarker)) {
        throw 'Sustained-output command contains a literal boundary marker before execution.'
    }
    [WinghosttyAccessibilityNative]::ResetTextChangedCount()
    $process.Refresh()
    $stressBaselineHandles = $process.HandleCount
    $stressBaselineThreads = $process.Threads.Count
    $stressBaselinePrivateBytes = $process.PrivateMemorySize64
    $stressStartedAt = [DateTime]::UtcNow
    Assert-AccessibilityInputOwner -Process $process -Description 'sustained output command' -ExpectedFocusedHwnd $leftPane.Hwnd
    if (-not [WinghosttyAccessibilityNative]::SendUnicodeText($stressCommand)) {
        throw "SendInput failed for sustained output command: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    Send-AccessibilityChord -Keys @([uint16]0x0D) -Description 'sustained output Enter' -Process $process -ExpectedFocusedHwnd $leftPane.Hwnd
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(15)) -Description 'sustained output first and final markers through one fresh TextPattern range' -Condition {
            $script:stressFirstMarkerVisible = $false
            $script:stressFinalMarkerVisible = $false
            $script:stressCandidateDiagnostics = @()
            $candidateIndex = 0
            foreach ($candidateDocument in $documents) {
                $candidatePattern = $null
                if (-not $candidateDocument.TryGetCurrentPattern(
                    [System.Windows.Automation.TextPattern]::Pattern,
                    [ref]$candidatePattern
                )) {
                    $script:stressCandidateDiagnostics += "${candidateIndex}:no-text-pattern"
                    $candidateIndex++
                    continue
                }
                $candidateRange = $candidatePattern.DocumentRange
                $candidateText = $candidateRange.GetText(-1)
                $hasFirst = $candidateText.Contains($stressFirstMarker)
                $hasFinal = $candidateText.Contains($stressFinalMarker)
                $script:stressCandidateDiagnostics += "${candidateIndex}:len=$($candidateText.Length),first=$hasFirst,final=$hasFinal"
                $candidateIndex++
                if ($hasFirst -and $hasFinal) {
                    $script:stressFirstMarkerVisible = $true
                    $script:stressFinalMarkerVisible = $true
                    break
                }
            }
            return $script:stressFinalMarkerVisible
        }
    }
    catch {
        throw "$($_.Exception.Message) Documents: $($script:stressCandidateDiagnostics -join '; ')."
    }
    $stressDurationMs = [Math]::Round(([DateTime]::UtcNow - $stressStartedAt).TotalMilliseconds)
    $stressEventCount = [WinghosttyAccessibilityNative]::TextChangedCount
    if ($stressEventCount -lt 1 -or $stressEventCount -gt 300) {
        throw "Sustained output emitted $stressEventCount TextChanged events; expected 1..300 for $stressLineCount lines."
    }
    [void](Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $stressResponsiveMarker -Description 'post-stress responsiveness marker' -ExpectedFocusedHwnd $leftPane.Hwnd)
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
    # Settings is an independent WS_EX_APPWINDOW. Process.Refresh() can make
    # MainWindowHandle follow it while it owns the foreground, so retain the
    # terminal host that must receive the midpoint and close-time focus restore.
    $idleTerminalHostHwnd = $process.MainWindowHandle
    if ($idleTerminalHostHwnd -eq [IntPtr]::Zero -or
        -not [WinghosttyAccessibilityNative]::IsWindow($idleTerminalHostHwnd)) {
        throw 'Terminal host HWND was unavailable before the settings idle soak.'
    }
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
                -not [WinghosttyAccessibilityNative]::ForceForeground($idleTerminalHostHwnd)) {
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
    try {
        Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(5)) -Description 'settings destruction and terminal focus restoration after idle soak' -Condition {
            $script:idleRestoreForegroundHwnd = [WinghosttyAccessibilityNative]::GetForegroundWindow()
            $script:idleRestoreFocusedHwnd = [WinghosttyAccessibilityNative]::FocusedWindowFor($idleTerminalHostHwnd)
            return -not [WinghosttyAccessibilityNative]::IsWindow($idleSettingsHwnd) -and
                $script:idleRestoreForegroundHwnd -eq $idleTerminalHostHwnd -and
                $script:idleRestoreFocusedHwnd -eq $leftPane.Hwnd
        }
    }
    catch {
        $idleRestoreTerminals = @([WinghosttyAccessibilityNative]::VisibleTerminalChildren($idleTerminalHostHwnd))
        throw "Idle Settings close focus restoration failed: settings_alive=$([WinghosttyAccessibilityNative]::IsWindow($idleSettingsHwnd)); foreground=$($script:idleRestoreForegroundHwnd); expected_host=$idleTerminalHostHwnd; focused=$($script:idleRestoreFocusedHwnd); expected_pane=$($leftPane.Hwnd); visible_terminals=$($idleRestoreTerminals -join ', '). $($_.Exception.Message)"
    }

    $idleMarker = "whi$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    [void](Send-AccessibilityOutputMarker -Process $process -TextPattern $textPattern -Marker $idleMarker -Description 'post-idle liveness marker' -ExpectedFocusedHwnd $leftPane.Hwnd)
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
    $hcTransitionEvidence = Invoke-AccessibilityHighContrastProof `
        -Process $process `
        -DiagnosticDirectory $layout.Logs

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
        high_contrast_transition = $hcTransitionEvidence
        focused = $focused.Current.Name
        terminal = [ordered]@{
            marker = $marker
            marker_visible = $terminalText.Contains($marker)
            line_text = $terminalLineText
            text_changed_events = $textChangedCount
            rectangle_count = $terminalRectCount
            selection_range_count = $selection.Count
            supported_text_selection = $supportedTextSelection.ToString()
            selection_is_degenerate = $true
            selection_line_text = $selectionLineText
            live_setting = $liveSetting.ToString()
            output_notification_count = $terminalOutputNotification[0]
            output_notification_kind = $terminalOutputNotification[1]
            output_notification_display_string = $terminalOutputNotification[2]
            output_notification_processing = $terminalOutputNotification[3]
            output_notification_activity_id = $terminalOutputNotification[4]
            warm_input = $terminalWarmInput
            warm_notification = $terminalWarmNotification
            query_only_marker = $queryOnlyMarker
            query_only_acquired_text_pattern_refreshed = $queryOnlyRangeRefreshed
            cold_query_marker = $coldQueryMarker
            cold_query_command_echo = $coldQueryProof.command_echo
            cold_query_first_read = $coldQueryProof
            cold_query_post_echo_document_range_fresh = $coldQueryPostEchoRangeFresh
            inactive_tab = $inactiveTabEvidence
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
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'relaunch terminal Text element' -Condition {
        $script:relaunchDocumentsProbe = @($relaunchRoot.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text
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
        throw 'Relaunched terminal Text element does not expose TextPattern.'
    }
    Assert-AccessibilityInputOwner -Process $relaunchProcess -Description 'relaunch liveness text'
    $relaunchMarker = "whr$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
    $relaunchDocumentHwnd = [IntPtr]$relaunchDocuments[0].Current.NativeWindowHandle
    [void](Send-AccessibilityOutputMarker -Process $relaunchProcess -TextPattern $relaunchTextPattern -Marker $relaunchMarker -Description 'relaunch liveness marker' -ExpectedFocusedHwnd $relaunchDocumentHwnd)
    Wait-AccessibilityCondition -Deadline ([DateTime]::UtcNow.AddSeconds(8)) -Description 'relaunch marker through TextPattern' -Condition {
        return $relaunchTextPattern.DocumentRange.GetText(-1).Contains($relaunchMarker)
    }
    $evidence['relaunch'] = [ordered]@{ marker = $relaunchMarker; visible = $true; process_id = $relaunchProcess.Id }
    }
}
catch {
    $runFailure = $_
}
finally {
    if ($settingsFocusRegistered -and $null -ne $settingsFocusHandler) {
        try {
            [System.Windows.Automation.Automation]::RemoveAutomationFocusChangedEventHandler($settingsFocusHandler)
        }
        catch {
            $cleanupFailures.Add("failed to remove Settings focus handler: $($_.Exception.Message)")
        }
    }
    if ($editEventsRegistered) {
        try {
            Stop-AccessibilityEditEventCapture
        }
        catch {
            $cleanupFailures.Add("failed to remove Edit UIA handlers: $($_.Exception.Message)")
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
            $cleanupFailures.Add("failed to remove palette SelectionItem handler: $($_.Exception.Message)")
        }
    }
    if ($paletteNotificationRegistered) {
        try {
            [WinghosttyAccessibilityNative]::StopNotificationCapture()
        }
        catch {
            $cleanupFailures.Add("failed to remove palette Notification handler: $($_.Exception.Message)")
        }
    }
    if ($terminalNotificationCaptureStarted) {
        try {
            [WinghosttyAccessibilityNative]::StopNotificationCapture()
            $terminalNotificationCaptureStarted = $false
        }
        catch {
            $cleanupFailures.Add("failed to remove terminal Notification handler: $($_.Exception.Message)")
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
            $cleanupFailures.Add("failed to remove terminal TextChanged handler: $($_.Exception.Message)")
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
    if ($null -ne $saveProbeProcess) {
        try { Stop-InteractiveWin11Process -Process $saveProbeProcess -Contained }
        catch { $cleanupFailures.Add("settings save probe cleanup failed: $($_.Exception.Message)") }
    }
    if ($null -ne $saveVerifyProcess) {
        try { Stop-InteractiveWin11Process -Process $saveVerifyProcess -Contained }
        catch { $cleanupFailures.Add("settings persistence verifier cleanup failed: $($_.Exception.Message)") }
    }
    if ($settingsConfigBaselineCaptured -and -not $settingsConfigBaselineRestored) {
        try {
            Restore-AccessibilityConfigBaseline `
                -Path $sandboxConfigPath `
                -Existed $settingsConfigBaselineExisted `
                -Bytes $settingsConfigBaselineBytes
            $settingsConfigBaselineRestored = $true
        }
        catch {
            $cleanupFailures.Add("settings config baseline cleanup failed: $($_.Exception.Message)")
        }
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
if ($null -ne $runFailure) {
    $failureLocation = if ($runFailure.InvocationInfo.ScriptLineNumber -gt 0) {
        " at line $($runFailure.InvocationInfo.ScriptLineNumber)"
    } else {
        ''
    }
    $failureMessages.Add("$($runFailure.Exception.Message)$failureLocation")
}
foreach ($cleanupFailure in $cleanupFailures) { $failureMessages.Add($cleanupFailure) }
if ($failureMessages.Count -gt 0) {
    throw "Accessibility validation failed: $($failureMessages -join ' | ')"
}

Write-Host "interactive Win11 accessibility: PASS ($artifact)"
