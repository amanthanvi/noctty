// MEASUREMENT ONLY (pacing-stall2): stall watchdog core, loaded by watchdog.ps1.
// Pings one window on a private desktop with WM_NULL every PeriodMs through
// SendMessageTimeoutW(SMTO_ABORTIFHUNG, SmtoMs) from a thread attached to that
// desktop, and pings a control window owned by this process (its own thread,
// base priority 6 like a BelowNormal UI thread) right before. Logs QPC-stamped
// lines: slow and missed replies, unanswered streaks (stalls), its own wake
// lateness, whole-machine busy %, the top 5 processes by CPU (image name and
// PID only), and the target's thread states (state, wait reason, CPU, context
// switches; no stacks, no memory reads). On the first streak that reaches
// StallMs it runs cdb -pv (noninvasive) on the exact target PID after
// re-checking its identity, then a second cdb 500 ms after the first exits.
// Never sends input, never kills anything, never reads the clipboard (it logs
// GetClipboardSequenceNumber only).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace W14Stall {
public static class N {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder value, int length, out int needed);
    [DllImport("user32.dll")] public static extern bool EnumDesktopWindows(IntPtr d, EnumProc p, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder b, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("ntdll.dll")] public static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll")] public static extern bool GetProcessTimes(IntPtr p, out long c, out long e, out long k, out long u);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr p, out uint code);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x, y, cx, cy, charsX, charsY, fill, flags; public short show, reservedBytes;
        public IntPtr reservedPointer, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct WNDCLASSEX {
        public uint cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra;
        public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] public static extern bool PostThreadMessageW(uint tid, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string n);

    public static string ClassOf(IntPtr h) { var b = new StringBuilder(256); GetClassNameW(h, b, 256); return b.ToString(); }
    public static long Qpc() { return Stopwatch.GetTimestamp(); }
    public static double Ms(long d) { return d * 1000.0 / Stopwatch.Frequency; }
    public static string ThreadDesktopName() {
        var s = new StringBuilder(256); int need;
        return GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), 2, s, s.Capacity * 2, out need) ? s.ToString() : "?";
    }
    // Image path and creation time of an exact PID (PROCESS_QUERY_LIMITED_INFORMATION), or false.
    public static bool Identity(uint pid, out string image, out long created) {
        image = null; created = 0;
        IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return false;
        try {
            var sb = new StringBuilder(1024); int n = sb.Capacity;
            if (!QueryFullProcessImageNameW(h, 0, sb, ref n)) return false;
            image = sb.ToString();
            long e, k, u; if (!GetProcessTimes(h, out created, out e, out k, out u)) return false;
            uint code; if (GetExitCodeProcess(h, out code) && code != 259) return false; // exited
            return true;
        } finally { CloseHandle(h); }
    }
}

public sealed class Thr { public uint Tid; public long Cpu; public long Create; public uint Cs; public uint State; public uint Wait; public int Prio; public int BasePrio; }
public sealed class Proc { public uint Pid; public uint Ppid; public long Create; public long Cpu; public string Name; public List<Thr> Threads; }

// One NtQuerySystemInformation(SystemProcessInformation) snapshot (x64 layout).
public sealed class Snap {
    public long Qpc; public Dictionary<uint, Proc> P = new Dictionary<uint, Proc>();
    static IntPtr buf = IntPtr.Zero; static int len = 0;
    public static Snap Take(uint threadsOf) {
        var s = new Snap();
        for (int tries = 0; ; tries++) {
            if (buf == IntPtr.Zero) { len = 4 << 20; buf = Marshal.AllocHGlobal(len); }
            int ret; int st = N.NtQuerySystemInformation(5, buf, len, out ret);
            if (st == unchecked((int)0xC0000004) && tries < 6) { Marshal.FreeHGlobal(buf); len = Math.Max(len * 2, ret + (1 << 20)); buf = Marshal.AllocHGlobal(len); continue; }
            if (st != 0) throw new Exception("NtQuerySystemInformation 0x" + st.ToString("X"));
            break;
        }
        s.Qpc = N.Qpc();
        long off = 0;
        while (true) {
            IntPtr e = new IntPtr(buf.ToInt64() + off);
            uint next = (uint)Marshal.ReadInt32(e, 0);
            int nth = Marshal.ReadInt32(e, 4);
            var p = new Proc();
            p.Create = Marshal.ReadInt64(e, 0x20);
            p.Cpu = Marshal.ReadInt64(e, 0x28) + Marshal.ReadInt64(e, 0x30);
            int nlen = (ushort)Marshal.ReadInt16(e, 0x38);
            IntPtr nb = Marshal.ReadIntPtr(e, 0x40);
            p.Name = (nb == IntPtr.Zero || nlen == 0) ? "Idle" : Marshal.PtrToStringUni(nb, nlen / 2);
            p.Pid = (uint)Marshal.ReadIntPtr(e, 0x50).ToInt64();
            p.Ppid = (uint)Marshal.ReadIntPtr(e, 0x58).ToInt64();
            if (threadsOf != 0 && p.Pid == threadsOf) {
                p.Threads = new List<Thr>();
                for (int i = 0; i < nth; i++) {
                    IntPtr t = new IntPtr(e.ToInt64() + 0x100 + i * 0x50);
                    var th = new Thr();
                    th.Cpu = Marshal.ReadInt64(t, 0) + Marshal.ReadInt64(t, 8);
                    th.Create = Marshal.ReadInt64(t, 0x10);
                    th.Tid = (uint)Marshal.ReadIntPtr(t, 0x30).ToInt64();
                    th.Prio = Marshal.ReadInt32(t, 0x38);
                    th.BasePrio = Marshal.ReadInt32(t, 0x3C);
                    th.Cs = (uint)Marshal.ReadInt32(t, 0x40);
                    th.State = (uint)Marshal.ReadInt32(t, 0x44);
                    th.Wait = (uint)Marshal.ReadInt32(t, 0x48);
                    p.Threads.Add(th);
                }
            }
            s.P[p.Pid] = p;
            if (next == 0) break;
            off += next;
        }
        return s;
    }
    static readonly string[] States = { "Init", "Ready", "Running", "Standby", "Term", "Wait", "Trans", "DefReady", "GateWait", "WaitSwap" };
    static readonly Dictionary<uint, string> Reasons = new Dictionary<uint, string> {
        {0,"Executive"},{4,"DelayExec"},{5,"Suspended"},{6,"UserReq"},{7,"WrExecutive"},{11,"WrDelayExec"},{12,"WrSuspended"},
        {13,"WrUserReq"},{15,"WrQueue"},{16,"WrLpcRecv"},{17,"WrLpcReply"},{21,"WrKeyedEvent"},{27,"WrResource"},{28,"WrPushLock"},
        {29,"WrMutex"},{30,"WrQuantumEnd"},{31,"WrDispatchInt"},{32,"WrPreempted"},{33,"WrYield"},{34,"WrFastMutex"},{35,"WrGuardedMutex"},
        {37,"WrAlertByTid"},{38,"WrDeferredPreempt"},{39,"WrPhysicalFault"} };
    public static string StateOf(Thr t) {
        string s = t.State < States.Length ? States[t.State] : ("S" + t.State);
        if (t.State == 5) { string r; s += "/" + (Reasons.TryGetValue(t.Wait, out r) ? r : ("W" + t.Wait)); }
        return s;
    }
    // Top n processes by CPU between a and b, as name:pid=cores (no command lines).
    public static string Top(Snap a, Snap b, int n, out double targetCores, uint target) {
        targetCores = 0;
        double dt = (b.Qpc - a.Qpc) / (double)Stopwatch.Frequency;
        var list = new List<KeyValuePair<double, Proc>>();
        if (dt <= 0) return "";
        foreach (var kv in b.P) {
            if (kv.Key == 0) continue;
            Proc pa; long d = kv.Value.Cpu;
            if (a.P.TryGetValue(kv.Key, out pa) && pa.Create == kv.Value.Create) d -= pa.Cpu;
            double cores = d / 1e7 / dt;
            if (kv.Key == target) targetCores = cores;
            if (cores > 0.0) list.Add(new KeyValuePair<double, Proc>(cores, kv.Value));
        }
        list.Sort((x, y) => y.Key.CompareTo(x.Key));
        var sb = new StringBuilder();
        for (int i = 0; i < Math.Min(n, list.Count); i++) sb.Append(list[i].Value.Name).Append(':').Append(list[i].Value.Pid).Append('=').Append(list[i].Key.ToString("0.00")).Append(' ');
        return sb.ToString().TrimEnd();
    }
    public static string UiOnly(Snap a, Snap b, uint pid, uint uiTid) {
        string t = Threads(a, b, pid, uiTid, false);
        int i = t.IndexOf("] ");
        return (i >= 0 ? t.Substring(0, i + 1) : t).Replace(' ', ',');
    }
    // Target's thread states: the UI thread first, then any thread that ran or is Ready/Running.
    public static string Threads(Snap a, Snap b, uint pid, uint uiTid, bool all) {
        Proc pb; if (!b.P.TryGetValue(pid, out pb) || pb.Threads == null) return "gone";
        Proc pa; a.P.TryGetValue(pid, out pa);
        var prev = new Dictionary<uint, Thr>();
        if (pa != null && pa.Threads != null) foreach (var t in pa.Threads) prev[t.Tid] = t;
        double dt = (b.Qpc - a.Qpc) / (double)Stopwatch.Frequency;
        var sb = new StringBuilder();
        Action<Thr, string> one = (t, tag) => {
            Thr o; long dc = 0; long ds = 0;
            if (prev.TryGetValue(t.Tid, out o) && o.Create == t.Create) { dc = t.Cpu - o.Cpu; ds = (long)t.Cs - o.Cs; }
            sb.Append(tag).Append(t.Tid).Append('[').Append(StateOf(t)).Append(" p").Append(t.Prio).Append('/').Append(t.BasePrio)
              .Append(" cpu").Append((dc / 1e4).ToString("0.0")).Append("ms cs+").Append(ds).Append("] ");
        };
        foreach (var t in pb.Threads) if (t.Tid == uiTid) one(t, "UI:");
        foreach (var t in pb.Threads) {
            if (t.Tid == uiTid) continue;
            Thr o; bool ran = prev.TryGetValue(t.Tid, out o) && o.Create == t.Create && (t.Cpu != o.Cpu || t.Cs != o.Cs);
            if (all || ran || t.State == 1 || t.State == 2 || t.State == 7) one(t, "");
        }
        return sb.ToString().TrimEnd();
    }
}

public sealed class Watch {
    public string LogPath, OutDir, Desktop, ClassPrefix, CdbPath, SymPath, StopFile, ReadyFile;
    public uint TargetPid; public long TargetCreate; public string TargetImage;
    public int PeriodMs = 100, SmtoMs = 250, SlowMs = 100, StallMs = 1000, FindSeconds = 60;
    public int ForceStacksAtMs = -1; // validation only: take stacks this long after the window is found
    StreamWriter w; readonly object lk = new object();
    IntPtr hdesk = IntPtr.Zero, ctlHwnd = IntPtr.Zero; uint ctlTid = 0; volatile bool ctlReady = false;
    N.WndProc ctlProc; // keep alive
    Thread cdbThread;
    public List<string> Events = new List<string>();

    public void Log(string kind, string msg) {
        long q = N.Qpc();
        string line = q + " " + DateTime.Now.ToString("HH:mm:ss.fff") + " " + kind + " " + msg;
        lock (lk) { w.WriteLine(line); w.Flush(); }
    }

    static string BusyPct(long[] a, long[] b) { double idle = b[0] - a[0], total = (b[1] - a[1]) + (b[2] - a[2]); return (total <= 0 ? 0 : 100.0 * (1 - idle / total)).ToString("0"); }
    static long[] SysTimes() { long i, k, u; N.GetSystemTimes(out i, out k, out u); return new long[] { i, k, u }; }

    void ControlThread() {
        try {
            if (!N.SetThreadDesktop(hdesk)) { Log("CTL", "SetThreadDesktop failed err=" + Marshal.GetLastWin32Error()); return; }
            ctlTid = N.GetCurrentThreadId();
            ctlProc = (h, m, wp, lp) => N.DefWindowProcW(h, m, wp, lp);
            var wc = new N.WNDCLASSEX(); wc.cbSize = (uint)Marshal.SizeOf(typeof(N.WNDCLASSEX));
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(ctlProc); wc.hInstance = N.GetModuleHandleW(null);
            wc.lpszClassName = "w14.stall2.control." + System.Diagnostics.Process.GetCurrentProcess().Id;
            if (N.RegisterClassExW(ref wc) == 0) { Log("CTL", "RegisterClassEx failed err=" + Marshal.GetLastWin32Error()); return; }
            ctlHwnd = N.CreateWindowExW(0, wc.lpszClassName, "", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, wc.hInstance, IntPtr.Zero);
            if (ctlHwnd == IntPtr.Zero) { Log("CTL", "CreateWindowEx failed err=" + Marshal.GetLastWin32Error()); return; }
            Log("CTL", "control window ready tid=" + ctlTid + " desktop=" + N.ThreadDesktopName() + " thread_priority=" + Thread.CurrentThread.Priority);
            ctlReady = true;
            N.MSG m;
            while (N.GetMessageW(out m, IntPtr.Zero, 0, 0) > 0) N.DispatchMessageW(ref m);
            N.DestroyWindow(ctlHwnd);
        } catch (Exception e) { Log("CTL", "error " + e.GetType().Name + ": " + e.Message); }
    }

    IntPtr FindWindow(out string cls) {
        IntPtr found = IntPtr.Zero; string fc = null;
        N.EnumDesktopWindows(hdesk, (h, l) => {
            uint pid; N.GetWindowThreadProcessId(h, out pid);
            if (pid == TargetPid) { string c = N.ClassOf(h); if (c.StartsWith(ClassPrefix, StringComparison.Ordinal)) { found = h; fc = c; return false; } }
            return true;
        }, IntPtr.Zero);
        cls = fc; return found;
    }

    bool StillTarget() {
        string img; long cr;
        return N.Identity(TargetPid, out img, out cr) && cr == TargetCreate && string.Equals(img, TargetImage, StringComparison.OrdinalIgnoreCase);
    }

    void RunCdb(int seq, string why) {
        if (!StillTarget()) { Log("CDB", "seq=" + seq + " skipped: pid " + TargetPid + " no longer the checked target (exited or changed)"); return; }
        string logf = Path.Combine(OutDir, "stacks-" + seq + "-pid" + TargetPid + ".log");
        string cmd = "\"" + CdbPath + "\" -pv -p " + TargetPid + " -y \"" + SymPath + "\" -logo \"" + logf + "\" -c \"~*kn 40; qd\"";
        var si = new N.Startup(); si.cb = Marshal.SizeOf(typeof(N.Startup)); si.desktop = "WinSta0\\" + Desktop;
        N.ProcessInfo pi;
        long q0 = N.Qpc();
        if (!N.CreateProcessW(CdbPath, new StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, OutDir, ref si, out pi)) {
            Log("CDB", "seq=" + seq + " CreateProcess failed err=" + Marshal.GetLastWin32Error()); return;
        }
        Log("CDB_START", "seq=" + seq + " why=" + why + " cdb_pid=" + pi.pid + " target=" + TargetPid + " start_qpc=" + q0 + " log=" + logf);
        uint r = N.WaitForSingleObject(pi.process, 90000);
        uint code = 0; N.GetExitCodeProcess(pi.process, out code);
        long q1 = N.Qpc();
        Log("CDB_END", "seq=" + seq + " cdb_pid=" + pi.pid + " wait=" + (r == 0 ? "exited" : "timeout(left running; noninvasive)") + " exit=" + code + " ms=" + N.Ms(q1 - q0).ToString("0") + " start_qpc=" + q0 + " end_qpc=" + q1);
        lock (lk) Events.Add("cdb seq=" + seq + " ms=" + N.Ms(q1 - q0).ToString("0") + " log=" + logf);
        N.CloseHandle(pi.thread); N.CloseHandle(pi.process);
    }

    void StartStacks(string why) {
        cdbThread = new Thread(() => {
            try { RunCdb(1, why); Thread.Sleep(500); RunCdb(2, why + "+500ms"); }
            catch (Exception e) { Log("CDB", "error " + e.GetType().Name + ": " + e.Message); }
        });
        cdbThread.IsBackground = false; cdbThread.Priority = ThreadPriority.AboveNormal; cdbThread.Start();
    }

    public int Run() {
        Directory.CreateDirectory(OutDir);
        w = new StreamWriter(LogPath, true, new UTF8Encoding(false));
        int rc = 0;
        try { rc = RunInner(); }
        catch (Exception e) { Log("ERROR", e.GetType().Name + ": " + e.Message); rc = 3; }
        finally {
            if (cdbThread != null) cdbThread.Join(200000);
            if (ctlTid != 0) N.PostThreadMessageW(ctlTid, 0x12, IntPtr.Zero, IntPtr.Zero);
            Log("EXIT", "rc=" + rc + " clipboard_seq=" + N.GetClipboardSequenceNumber());
            w.Dispose();
        }
        return rc;
    }

    int RunInner() {
        Log("START", "watchdog pid=" + System.Diagnostics.Process.GetCurrentProcess().Id + " target=" + TargetPid + " desktop=" + Desktop + " period_ms=" + PeriodMs + " smto_ms=" + SmtoMs + " slow_ms=" + SlowMs + " stall_ms=" + StallMs + " qpc_freq=" + Stopwatch.Frequency + " clipboard_seq=" + N.GetClipboardSequenceNumber() + " cpus=" + Environment.ProcessorCount);
        hdesk = N.OpenDesktopW(Desktop, 0, false, 0x10000000);
        if (hdesk == IntPtr.Zero) { Log("ERROR", "OpenDesktop failed err=" + Marshal.GetLastWin32Error()); return 2; }
        var ctl = new Thread(ControlThread); ctl.IsBackground = true; ctl.Priority = ThreadPriority.Lowest; ctl.Start();
        int rc = 0;
        var pinger = new Thread(() => { try { rc = PingLoop(); } catch (Exception e) { Log("ERROR", "pinger " + e.GetType().Name + ": " + e.Message); rc = 3; } });
        pinger.Priority = ThreadPriority.Highest; pinger.Start(); pinger.Join();
        return rc;
    }

    int PingLoop() {
        if (!N.SetThreadDesktop(hdesk)) { Log("ERROR", "pinger SetThreadDesktop failed err=" + Marshal.GetLastWin32Error()); return 2; }
        Log("DESK", "pinger attached desktop=" + N.ThreadDesktopName() + " thread_priority=" + Thread.CurrentThread.Priority);
        IntPtr hproc = N.OpenProcess(0x00100000 | 0x1000, false, TargetPid); // SYNCHRONIZE | QUERY_LIMITED
        if (hproc == IntPtr.Zero) { Log("ERROR", "OpenProcess(target) failed err=" + Marshal.GetLastWin32Error()); return 2; }
        IntPtr h = IntPtr.Zero; string cls = null;
        long findDeadline = N.Qpc() + (long)FindSeconds * Stopwatch.Frequency;
        while (h == IntPtr.Zero) {
            if (N.WaitForSingleObject(hproc, 0) == 0) { Log("ERROR", "target exited before its window appeared"); return 2; }
            if (N.Qpc() > findDeadline) { Log("ERROR", "window with class prefix " + ClassPrefix + " not found"); return 2; }
            h = FindWindow(out cls);
            if (h == IntPtr.Zero) Thread.Sleep(50);
        }
        uint wpid; uint uiTid = N.GetWindowThreadProcessId(h, out wpid);
        Log("WINDOW", "hwnd=0x" + h.ToInt64().ToString("X") + " class=" + cls + " pid=" + wpid + " ui_tid=" + uiTid);
        for (int i = 0; i < 100 && !ctlReady; i++) Thread.Sleep(20);
        long f = Stopwatch.Frequency, period = (long)PeriodMs * f / 1000;
        long streakStart = 0; int streakFails = 0; double streakMaxCtl = 0, streakMaxLate = 0;
        bool triggered = false; int okCount = 0, missCount = 0, slowCount = 0, stalls = 0, ctlSlow = 0, lates = 0;
        double maxStall = 0, maxOk = 0, maxCtl = 0, maxLate = 0;
        long[] st0 = SysTimes(), stWin = st0;
        Snap snapPrev = Snap.Take(TargetPid), snapWin = snapPrev;
        long forceAt = ForceStacksAtMs >= 0 ? N.Qpc() + (long)ForceStacksAtMs * f / 1000 : long.MaxValue;
        long due = N.Qpc(); int tick = 0; double winMaxPing = 0, winMaxCtl = 0; bool readyWritten = false;
        while (true) {
            due += period;
            long now = N.Qpc();
            if (due > now) {
                while (true) { long left = due - N.Qpc(); if (left <= 0) break; int ms = (int)(left * 1000 / f); if (ms >= 2) Thread.Sleep(ms - 1); else Thread.Sleep(0); }
                double late = N.Ms(N.Qpc() - due);
                if (late > maxLate) maxLate = late;
                if (late > 50) { lates++; Log("LATE", "watchdog woke " + late.ToString("0") + " ms after its due time"); if (streakStart != 0 && late > streakMaxLate) streakMaxLate = late; }
            } else due = now; // a slow ping already used the period
            tick++;
            if (N.WaitForSingleObject(hproc, 0) == 0) { Log("TARGET_EXIT", "target process exited"); break; }
            if ((tick % 5) == 0 && !string.IsNullOrEmpty(StopFile) && File.Exists(StopFile)) { Log("STOP", "stop file seen"); break; }
            if (!N.IsWindow(h)) { Log("TARGET_EXIT", "window destroyed"); break; }
            long[] st = SysTimes(); string busyTick = BusyPct(st0, st); st0 = st;
            IntPtr res;
            double cel = -1;
            if (ctlHwnd != IntPtr.Zero) {
                long c0 = N.Qpc(); IntPtr cr = N.SendMessageTimeoutW(ctlHwnd, 0, IntPtr.Zero, IntPtr.Zero, 2, (uint)SmtoMs, out res);
                cel = N.Ms(N.Qpc() - c0); if (cr == IntPtr.Zero) cel = -cel;
                double ca = Math.Abs(cel); if (ca > maxCtl) maxCtl = ca; if (ca > winMaxCtl) winMaxCtl = ca;
                if (ca > SlowMs) { ctlSlow++; Log("CTL_SLOW", "control ping " + (cel < 0 ? "MISSED" : "ok") + " el=" + ca.ToString("0") + " busy_tick=" + busyTick); }
                if (streakStart != 0 && ca > streakMaxCtl) streakMaxCtl = ca;
            }
            long s0 = N.Qpc(); IntPtr r = N.SendMessageTimeoutW(h, 0, IntPtr.Zero, IntPtr.Zero, 2, (uint)SmtoMs, out res);
            int err = r == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
            long s1 = N.Qpc(); double el = N.Ms(s1 - s0);
            if (el > winMaxPing) winMaxPing = el;
            if (r != IntPtr.Zero) {
                okCount++;
                if (el > maxOk) maxOk = el;
                if (streakStart != 0) {
                    double dur = N.Ms(s1 - streakStart); stalls++; if (dur > maxStall) maxStall = dur;
                    Snap sn = Snap.Take(TargetPid); double tc; string top = Snap.Top(snapPrev, sn, 5, out tc, TargetPid);
                    Log("STALL_END", "unanswered_ms=" + dur.ToString("0") + " first_send_qpc=" + streakStart + " reply_qpc=" + s1 + " misses=" + streakFails + " max_ctl_ms=" + streakMaxCtl.ToString("0") + " max_watchdog_late_ms=" + streakMaxLate.ToString("0") + " last_ping_ms=" + el.ToString("0") + " | threads " + Snap.Threads(snapPrev, sn, TargetPid, uiTid, false) + " | top5 " + top);
                    lock (lk) Events.Add("stall " + dur.ToString("0") + "ms misses=" + streakFails + " first_send_qpc=" + streakStart);
                    snapPrev = sn; streakStart = 0; streakFails = 0; streakMaxCtl = 0; streakMaxLate = 0;
                } else if (el > SlowMs) {
                    slowCount++;
                    Snap sn = Snap.Take(TargetPid); double tc; string top = Snap.Top(snapPrev, sn, 5, out tc, TargetPid);
                    Log("SLOW", "reply_ms=" + el.ToString("0") + " send_qpc=" + s0 + " ctl_ms=" + cel.ToString("0") + " busy_tick=" + busyTick + " | threads " + Snap.Threads(snapPrev, sn, TargetPid, uiTid, false) + " | top5 " + top);
                    snapPrev = sn;
                }
                if (!readyWritten && okCount >= 10 && !string.IsNullOrEmpty(ReadyFile)) { File.WriteAllText(ReadyFile, "ready"); readyWritten = true; Log("READY", "10 replies seen; ready file written"); }
            } else {
                missCount++; streakFails++;
                if (streakStart == 0) { streakStart = s0; }
                Snap sn = Snap.Take(TargetPid); double tc; string top = Snap.Top(snapPrev, sn, 5, out tc, TargetPid);
                Log("MISS", "el=" + el.ToString("0") + " err=" + err + " send_qpc=" + s0 + " unanswered_ms=" + N.Ms(s1 - streakStart).ToString("0") + " ctl_ms=" + cel.ToString("0") + " busy_tick=" + busyTick + " hung=" + N.IsHungAppWindow(h) + " | threads " + Snap.Threads(snapPrev, sn, TargetPid, uiTid, streakFails == 1) + " | top5 " + top);
                snapPrev = sn;
                if (!triggered && N.Ms(N.Qpc() - streakStart) >= StallMs) {
                    triggered = true;
                    Log("TRIGGER", "unanswered for " + N.Ms(N.Qpc() - streakStart).ToString("0") + " ms (first send qpc " + streakStart + "); taking stacks");
                    lock (lk) Events.Add("trigger first_send_qpc=" + streakStart);
                    StartStacks("stall");
                }
            }
            if (!triggered && N.Qpc() >= forceAt) { triggered = true; Log("TRIGGER", "forced validation stacks (not a stall)"); StartStacks("forced"); }
            if ((tick % 5) == 0) {
                long[] stw = SysTimes(); string busyWin = BusyPct(stWin, stw); stWin = stw;
                Snap sn = Snap.Take(TargetPid); double tc; string top = Snap.Top(snapWin, sn, 5, out tc, TargetPid);
                Log("L", "busy=" + busyWin + " max_ping_ms=" + winMaxPing.ToString("0.0") + " max_ctl_ms=" + winMaxCtl.ToString("0.0") + " target_cores=" + tc.ToString("0.00") + " ui=" + Snap.UiOnly(snapWin, sn, TargetPid, uiTid) + " | top5 " + top);
                snapWin = sn; if (streakStart == 0) snapPrev = sn;
                winMaxPing = 0; winMaxCtl = 0;
            }
        }
        if (streakStart != 0) Log("STALL_OPEN", "stall still open at exit: unanswered_ms=" + N.Ms(N.Qpc() - streakStart).ToString("0") + " misses=" + streakFails);
        Log("SUMMARY", "ok=" + okCount + " miss=" + missCount + " slow_gt" + SlowMs + "=" + slowCount + " stalls=" + stalls + " max_stall_ms=" + maxStall.ToString("0") + " max_ok_reply_ms=" + maxOk.ToString("0.0") + " ctl_slow=" + ctlSlow + " max_ctl_ms=" + maxCtl.ToString("0.0") + " watchdog_late_gt50=" + lates + " max_watchdog_late_ms=" + maxLate.ToString("0") + " triggered=" + triggered);
        N.CloseHandle(hproc);
        return 0;
    }
}
}
