// Only controls belonging to the isolated copy are inspected or driven.
using System;
using System.Collections.Generic;
using System.IO;
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
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hwnd, ref Point point);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr hwnd, IntPtr rect, IntPtr region, uint flags);
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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder path, uint capacity, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetDiskFreeSpaceExW(string path, out ulong available, out ulong total, out ulong free);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static string ExistingRunDirectory(string path) {
        string ancestor = Path.GetFullPath(path);
        while (true) {
            try {
                if ((File.GetAttributes(ancestor) & FileAttributes.Directory) == 0)
                    throw new IOException("Run ancestor is not a directory");
                break;
            } catch (FileNotFoundException) {
            } catch (DirectoryNotFoundException) {
            }
            ancestor = Path.GetDirectoryName(ancestor);
            if (String.IsNullOrEmpty(ancestor)) throw new IOException("Run has no existing ancestor");
        }
        // Follow reparse points. Query the resolved handle, not its drive letter.
        IntPtr handle = CreateFileW(ancestor, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new IOException("Run ancestor open failed");
        try {
            var resolved = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
            if (length == 0 || length >= resolved.Capacity) throw new IOException("Run ancestor resolution failed");
            return resolved.ToString().TrimEnd('\\') + "\\";
        } finally { CloseHandle(handle); }
    }
    public static ulong AvailableRunSpace(string path) {
        ulong available, total, free;
        if (!GetDiskFreeSpaceExW(ExistingRunDirectory(path), out available, out total, out free))
            throw new IOException("Run volume space query failed");
        return available;
    }
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
    public sealed class LegacyInstallFact {
        public string TargetClass;
        public uint Dpi;
        public int X, Y, PaneTop;
    }
    static int Scale(int value, uint dpi) { return dpi <= 96 ? value : checked(value * (int)dpi) / 96; }
    public static LegacyInstallFact LegacyInstall(IntPtr host, IntPtr pane, int ownedProcess) {
        int hostPid, panePid;
        GetWindowThreadProcessId(host, out hostPid); GetWindowThreadProcessId(pane, out panePid);
        if (hostPid != ownedProcess || panePid != ownedProcess || ClassName(host) != "noctty.win32.host" ||
            ClassName(pane) != "noctty.win32" || GetParent(pane) != host || !IsWindowVisible(pane))
            throw new Exception("Owned legacy host identity mismatch");
        IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        if (previous == IntPtr.Zero) throw new Exception("Owned legacy DPI context failed");
        try {
            Rect client, surface;
            if (!GetClientRect(host, out client) || !GetWindowRect(pane, out surface))
                throw new Exception("Owned legacy geometry failed");
            var origin = new Point { X=surface.Left, Y=surface.Top };
            if (!ScreenToClient(host, ref origin)) throw new Exception("Owned legacy coordinate mapping failed");
            uint dpi = GetDpiForWindow(host);
            if (dpi == 0) throw new Exception("Owned legacy DPI read failed");
            // v1.3.125 win32.zig paintChrome: pane top == bands.content_top.
            // Match its truncating Host.scaled and center of the staged Install rect.
            int x = client.Right - Scale(16, dpi) - Scale(72, dpi) - Scale(8, dpi) - Scale(86, dpi) / 2;
            int y = origin.Y + Scale(2, dpi) - Scale(4, dpi) + Scale(22, dpi) / 2;
            if (x < 0 || x >= client.Right || y < 0 || y >= client.Bottom || x > 32767 || y > 32767)
                throw new Exception("Owned legacy hit point is outside client bounds");
            // Populate the source-defined hit rect even on the uncomposed desktop.
            // RDW_INVALIDATE | RDW_UPDATENOW | RDW_NOCHILDREN: host only.
            if (!RedrawWindow(host, IntPtr.Zero, IntPtr.Zero, 0x0141))
                throw new Exception("Owned legacy host paint failed");
            var position = new IntPtr((y << 16) | (x & 0xffff));
            if (!PostMessageW(host, 0x0201, new IntPtr(1), position) ||
                !PostMessageW(host, 0x0202, IntPtr.Zero, position))
                throw new Exception("Owned legacy Install post failed");
            return new LegacyInstallFact { TargetClass=ClassName(host), Dpi=dpi, X=x, Y=y, PaneTop=origin.Y };
        } finally { SetThreadDpiAwarenessContext(previous); }
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
