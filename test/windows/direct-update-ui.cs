// Only controls belonging to the isolated copy are inspected or driven.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class DirectUpdateUi {
    delegate bool EnumWindow(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hwnd, EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int capacity);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr w, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int process);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint current, uint target, bool attach);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] keys);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll")] static extern uint SetErrorMode(uint mode);
    public static IntPtr CreateSentinel() {
        var hwnd = CreateWindowExW(0x08000080, "STATIC", "", 0x80000000, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new Exception("Driver sentinel creation failed");
        return hwnd;
    }
    public static void CloseSentinel(IntPtr hwnd) {
        if (hwnd != IntPtr.Zero && !DestroyWindow(hwnd)) throw new Exception("Driver sentinel destruction failed");
    }
    public sealed class WindowFact {
        public string ClassName;
        public int ControlId;
        public bool Visible;
        public string GraphicsDialogText;
    }
    static string ClassName(IntPtr hwnd) {
        var name = new StringBuilder(128); GetClassNameW(hwnd, name, name.Capacity); return name.ToString();
    }
    public static WindowFact[] StartupFacts(int ownedProcess) {
        var facts = new List<WindowFact>();
        EnumWindows((hwnd, unused) => {
            int owner; GetWindowThreadProcessId(hwnd, out owner);
            if (owner != ownedProcess) return true;
            string cls = ClassName(hwnd);
            facts.Add(new WindowFact { ClassName=cls, ControlId=GetDlgCtrlID(hwnd), Visible=IsWindowVisible(hwnd) });
            EnumChildWindows(hwnd, (child, parameter) => {
                var fact = new WindowFact { ClassName=ClassName(child), ControlId=GetDlgCtrlID(child), Visible=IsWindowVisible(child) };
                // Only fixed startup-graphics messages of our own app may be read.
                // Never read a terminal, command, directory or unrelated window title.
                if (cls == "#32770" && fact.ClassName == "Static") {
                    string text = Text(child);
                    if (text.IndexOf("OpenGL", StringComparison.OrdinalIgnoreCase) >= 0)
                        fact.GraphicsDialogText = text;
                }
                facts.Add(fact); return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return facts.ToArray();
    }
    public static IntPtr Child(IntPtr parent, int id) {
        IntPtr result = IntPtr.Zero;
        EnumChildWindows(parent, (hwnd, unused) => {
            if (GetDlgCtrlID(hwnd) == id) { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    public static string Text(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return "";
        var text = new StringBuilder(2048); IntPtr length;
        if (SendMessageTimeoutW(hwnd, 0x000D, new IntPtr(text.Capacity), text, 2, 3000, out length) == IntPtr.Zero)
            throw new Exception("Owned control text read failed");
        return text.ToString();
    }
    public static void Click(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd)) throw new Exception("Owned button is not visible");
        if (!PostMessageW(GetParent(hwnd), 0x0111, new IntPtr(GetDlgCtrlID(hwnd)), hwnd))
            throw new Exception("Owned button notification failed");
    }
    public static void CheckKey(IntPtr pane) {
        int process; uint target = GetWindowThreadProcessId(pane, out process), current = GetCurrentThreadId();
        if (target == 0 || !AttachThreadInput(current, target, true)) throw new Exception("Owned input queue attach failed");
        try {
            if (!SetKeyboardState(new byte[256])) throw new Exception("Owned keyboard pin failed");
            // Posted pair: TranslateMessage supplies characters. No real input.
            if (!PostMessageW(pane, 0x0100, new IntPtr(0x76), new IntPtr(1)) ||
                !PostMessageW(pane, 0x0101, new IntPtr(0x76), new IntPtr(unchecked((int)0xC0000001))))
                throw new Exception("Owned check key post failed");
        } finally { if (!AttachThreadInput(current, target, false)) throw new Exception("Owned input queue detach failed"); }
    }
    public static int StubLoadError(string path) {
        uint previous = SetErrorMode(0x8003);
        try {
            IntPtr module = LoadLibraryExW(path, IntPtr.Zero, 0x00000100 | 0x00000800);
            int error = Marshal.GetLastWin32Error();
            if (module != IntPtr.Zero) { FreeLibrary(module); return 0; }
            return error;
        } finally { SetErrorMode(previous); }
    }
}
