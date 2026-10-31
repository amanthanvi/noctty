// MEASUREMENT ONLY (pacing-stall2): injected CPU load and its positive control.
// Compiled by build-load.ps1 (Windows PowerShell 5.1 Add-Type -OutputAssembly,
// .NET Framework, C# 5) into pacing-stall2\bin\CpuLoad-<hash>.exe.
//
//   CpuLoad.exe load <burstLog> <stopFile> <maxSeconds> [busyMs=2000] [idleMs=4000]
//     One spinning thread per logical processor, fixed schedule from t0 (start
//     + 100 ms): burst n spins over [t0 + n*(busy+idle), +busy), then sleeps.
//     The process should be started at BELOW_NORMAL_PRIORITY_CLASS (it also sets
//     it). Each burst's scheduled and observed QPC start/end go to <burstLog>,
//     one line per burst, flushed as written. Stops at <stopFile> or maxSeconds.
//   CpuLoad.exe counter <outFile> <seconds>
//     One busy thread counting loop iterations per 10 ms QPC bucket (meant to be
//     started at IDLE_PRIORITY_CLASS). Writes "bucket_start_qpc count" lines.
//   CpuLoad.exe control <outDir> <seconds>
//     Positive control: on a private desktop, starts this exe as `load`
//     (BELOW_NORMAL) and `counter` (IDLE), each with lpDesktop set, and from
//     this Normal-class process times SendMessageTimeoutW(WM_NULL) round trips
//     every 20 ms to a never-shown window owned by its own Normal thread on that
//     desktop. Writes smto.txt, load\bursts.txt, counter.txt, control.log.
// Never touches the clipboard, never sends input, never shows a window, logs no
// command lines or environment.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class CpuLoad {
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint p);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern uint GetPriorityClass(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool SetPriorityClass(IntPtr h, uint c);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title; public int x, y, xs, ys, xc, yc, fill, flags; public short show, r2; public IntPtr r3, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref Startup si, out ProcessInfo pi);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr mode, uint flags, uint access, IntPtr sa);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr h);
    public delegate IntPtr WndProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct WNDCLASSEX {
        public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground; public string lpszMenuName, lpszClassName; public IntPtr hIconSm;
    }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint tid, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr res);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string n);

    static long Qpc() { return Stopwatch.GetTimestamp(); }
    static double Ms(long d) { return d * 1000.0 / Stopwatch.Frequency; }

    public static int Main(string[] a) {
        try {
            if (a.Length >= 4 && a[0] == "load") return Load(a[1], a[2], int.Parse(a[3]), a.Length > 4 ? int.Parse(a[4]) : 2000, a.Length > 5 ? int.Parse(a[5]) : 4000, a.Length > 6 ? int.Parse(a[6]) : 1);
            if (a.Length >= 3 && a[0] == "counter") return Counter(a[1], int.Parse(a[2]));
            if (a.Length >= 3 && a[0] == "control") return Control(a[1], int.Parse(a[2]), a.Length > 3 ? int.Parse(a[3]) : 1);
            Console.Error.WriteLine("usage: load <log> <stop> <maxSeconds> [busyMs idleMs] | counter <out> <seconds> | control <outDir> <seconds>");
            return 2;
        } catch (Exception e) { Console.Error.WriteLine("error " + e.GetType().Name + ": " + e.Message); return 1; }
    }

    // ---- load ----
    static volatile bool stop = false;
    static int Load(string logPath, string stopFile, int maxSeconds, int busyMs, int idleMs, int perLp) {
        timeBeginPeriod(1);
        SetPriorityClass(GetCurrentProcess(), 0x4000);
        uint cls = GetPriorityClass(GetCurrentProcess());
        int n = Environment.ProcessorCount * Math.Max(1, perLp);
        long f = Stopwatch.Frequency;
        long busy = busyMs * f / 1000, period = (long)(busyMs + idleMs) * f / 1000;
        long t0 = Qpc() + f / 10;
        long hardEnd = t0 + (long)maxSeconds * f;
        int maxBursts = (int)((hardEnd - t0) / Math.Max(1L, period)) + 2;
        var first = new long[n, maxBursts]; var last = new long[n, maxBursts];
        var sw = new StreamWriter(logPath, false, new UTF8Encoding(false)); sw.AutoFlush = true;
        sw.WriteLine("START pid=" + Process.GetCurrentProcess().Id + " priority_class=0x" + cls.ToString("X") + " threads=" + n + " qpc_freq=" + f + " t0=" + t0 + " busy_ms=" + busyMs + " idle_ms=" + idleMs + " max_s=" + maxSeconds);
        var threads = new Thread[n];
        for (int i = 0; i < n; i++) {
            int idx = i;
            threads[i] = new Thread(delegate () {
                for (int b = 0; b < maxBursts && !stop; b++) {
                    long s = t0 + b * period, e = s + busy;
                    if (s >= hardEnd) { stop = true; break; }
                    for (;;) { long left = s - Qpc(); if (left <= 0 || stop) break; long ms = left * 1000 / f; if (ms >= 2) Thread.Sleep((int)Math.Min(ms - 1, 50)); else Thread.SpinWait(20); }
                    if (stop) break;
                    first[idx, b] = Qpc(); long x = 0, now = first[idx, b];
                    while (now < e && !stop) { x++; now = Qpc(); }
                    last[idx, b] = now;
                }
            });
            threads[i].IsBackground = true; threads[i].Priority = ThreadPriority.Normal; threads[i].Start();
        }
        int written = 0;
        while (true) {
            Thread.Sleep(20);
            long now = Qpc();
            if (now >= hardEnd || File.Exists(stopFile)) { stop = true; }
            // write every burst whose scheduled end is 30 ms past (or all, at stop)
            while (written < maxBursts) {
                long s = t0 + written * period, e = s + busy;
                if (!stop && now < e + f * 3 / 100) break;
                if (s >= now && stop) break;
                if (stop) foreach (var th in threads) th.Join(200);
                long fmin = long.MaxValue, fmax = 0, lmin = long.MaxValue, lmax = 0; int ran = 0;
                for (int i = 0; i < n; i++) {
                    if (first[i, written] == 0) continue; ran++;
                    fmin = Math.Min(fmin, first[i, written]); fmax = Math.Max(fmax, first[i, written]);
                    if (last[i, written] != 0) { lmin = Math.Min(lmin, last[i, written]); lmax = Math.Max(lmax, last[i, written]); }
                }
                if (ran == 0) { written++; continue; }
                if (lmin == long.MaxValue) lmin = 0;
                bool partial = lmax < e - f / 1000;
                sw.WriteLine("BURST " + written + " sched_start=" + s + " sched_end=" + e + " first_start_min=" + fmin + " first_start_max=" + fmax +
                    " last_end_min=" + lmin + " last_end_max=" + lmax + " threads_ran=" + ran + (partial ? " partial=1" : "") +
                    " start_late_max_ms=" + Ms(fmax - s).ToString("0.00") + " end_spread_ms=" + Ms(lmax - lmin).ToString("0.00"));
                written++;
            }
            if (stop) break;
        }
        foreach (var th in threads) th.Join(500);
        sw.WriteLine("END qpc=" + Qpc() + " bursts=" + written + (File.Exists(stopFile) ? " reason=stopfile" : " reason=max_seconds"));
        sw.Close();
        return 0;
    }

    // ---- counter ----
    static int Counter(string outPath, int seconds) {
        long f = Stopwatch.Frequency, bucket = f / 100, t0 = Qpc(), end = t0 + seconds * f;
        int nb = (int)((end - t0) / bucket) + 1;
        var counts = new long[nb];
        uint cls = GetPriorityClass(GetCurrentProcess());
        long now = t0;
        while (now < end) { now = Qpc(); long k = (now - t0) / bucket; if (k < nb) counts[k]++; }
        using (var sw = new StreamWriter(outPath, false, new UTF8Encoding(false))) {
            sw.WriteLine("START pid=" + Process.GetCurrentProcess().Id + " priority_class=0x" + cls.ToString("X") + " thread_priority=" + Thread.CurrentThread.Priority + " qpc_freq=" + f + " t0=" + t0 + " bucket_qpc=" + bucket);
            for (int i = 0; i < nb; i++) sw.WriteLine((t0 + i * bucket) + " " + counts[i]);
        }
        return 0;
    }

    // ---- control ----
    static IntPtr ctlHwnd = IntPtr.Zero; static uint ctlTid = 0; static volatile bool ctlReady = false; static WndProc ctlProc; static string ctlErr = "";
    static ProcessInfo Start(string exe, string args, string desktop, uint cls) {
        var s = new Startup(); s.cb = Marshal.SizeOf(typeof(Startup)); s.desktop = desktop; s.flags = 1; s.show = 0; ProcessInfo p;
        if (!CreateProcessW(exe, new StringBuilder("\"" + exe + "\" " + args), IntPtr.Zero, IntPtr.Zero, false, cls | 0x08000000, IntPtr.Zero, null, ref s, out p))
            throw new Exception("CreateProcess failed " + Marshal.GetLastWin32Error());
        return p;
    }
    static int Control(string outDir, int seconds, int perLp) {
        Directory.CreateDirectory(outDir); Directory.CreateDirectory(Path.Combine(outDir, "load"));
        var log = new StreamWriter(Path.Combine(outDir, "control.log"), false, new UTF8Encoding(false)); log.AutoFlush = true;
        timeBeginPeriod(1);
        string deskName = "w14-loadctl-" + Guid.NewGuid().ToString("N");
        IntPtr desk = CreateDesktopW(deskName, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
        if (desk == IntPtr.Zero) throw new Exception("CreateDesktop failed " + Marshal.GetLastWin32Error());
        string desktop = "WinSta0\\" + deskName;
        log.WriteLine("control pid=" + Process.GetCurrentProcess().Id + " priority_class=0x" + GetPriorityClass(GetCurrentProcess()).ToString("X") + " desktop=" + deskName + " cpus=" + Environment.ProcessorCount);
        // never-shown window on the private desktop, owned by a Normal thread of this Normal-class process
        var wt = new Thread(delegate () {
            try {
                if (!SetThreadDesktop(desk)) { ctlErr = "SetThreadDesktop " + Marshal.GetLastWin32Error(); return; }
                ctlTid = GetCurrentThreadId();
                ctlProc = (h, msg, w, l) => DefWindowProcW(h, msg, w, l);
                var wc = new WNDCLASSEX(); wc.cbSize = Marshal.SizeOf(typeof(WNDCLASSEX)); wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(ctlProc);
                wc.hInstance = GetModuleHandleW(null); wc.lpszClassName = "w14.loadctl." + Process.GetCurrentProcess().Id;
                if (RegisterClassExW(ref wc) == 0) { ctlErr = "RegisterClassEx " + Marshal.GetLastWin32Error(); return; }
                ctlHwnd = CreateWindowExW(0, wc.lpszClassName, "", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
                if (ctlHwnd == IntPtr.Zero) { ctlErr = "CreateWindowEx " + Marshal.GetLastWin32Error(); return; }
                ctlReady = true;
                MSG m; while (GetMessageW(out m, IntPtr.Zero, 0, 0) > 0) DispatchMessageW(ref m);
                DestroyWindow(ctlHwnd);
            } catch (Exception e) { ctlErr = e.Message; }
        });
        wt.IsBackground = true; wt.Priority = ThreadPriority.Normal; wt.Start();
        for (int i = 0; i < 100 && !ctlReady && ctlErr == ""; i++) Thread.Sleep(20);
        if (!ctlReady) throw new Exception("control window failed: " + ctlErr);
        log.WriteLine("window thread tid=" + ctlTid + " priority=Normal (base 8 in a Normal-class process)");
        string exe = Process.GetCurrentProcess().MainModule.FileName;
        string stopFile = Path.Combine(outDir, "load", "stop");
        var counter = Start(exe, "counter \"" + Path.Combine(outDir, "counter.txt") + "\" " + (seconds + 2), desktop, 0x40);
        log.WriteLine("counter pid=" + counter.pid + " class=IDLE(0x40) lpDesktop=" + deskName + " observed_class=0x" + GetPriorityClass(counter.process).ToString("X"));
        Thread.Sleep(1000); // a second of counter baseline before the load
        var load = Start(exe, "load \"" + Path.Combine(outDir, "load", "bursts.txt") + "\" \"" + stopFile + "\" " + (seconds + 5) + " 2000 4000 " + perLp, desktop, 0x4000);
        log.WriteLine("load pid=" + load.pid + " class=BELOW_NORMAL(0x4000) lpDesktop=" + deskName + " observed_class=0x" + GetPriorityClass(load.process).ToString("X"));
        Thread.CurrentThread.Priority = ThreadPriority.Normal;
        var smto = new StreamWriter(Path.Combine(outDir, "smto.txt"), false, new UTF8Encoding(false));
        smto.WriteLine("send_qpc rtt_ms ok");
        long f = Stopwatch.Frequency, endAt = Qpc() + (long)seconds * f;
        while (Qpc() < endAt) {
            IntPtr r; long s0 = Qpc();
            IntPtr ok = SendMessageTimeoutW(ctlHwnd, 0, IntPtr.Zero, IntPtr.Zero, 0, 2000, out r);
            long s1 = Qpc();
            smto.WriteLine(s0 + " " + Ms(s1 - s0).ToString("0.000") + " " + (ok != IntPtr.Zero ? 1 : 0));
            Thread.Sleep(20);
        }
        smto.Close();
        File.WriteAllText(stopFile, "stop");
        bool loadExited = WaitForSingleObject(load.process, 5000) == 0;
        if (!loadExited) { TerminateProcess(load.process, 1); log.WriteLine("load did not exit on stop file; terminated its exact handle pid=" + load.pid); }
        bool counterExited = WaitForSingleObject(counter.process, 15000) == 0;
        if (!counterExited) { TerminateProcess(counter.process, 1); log.WriteLine("counter did not exit; terminated its exact handle pid=" + counter.pid); }
        log.WriteLine("load exited=" + loadExited + " counter exited=" + counterExited);
        CloseHandle(load.process); CloseHandle(load.thread); CloseHandle(counter.process); CloseHandle(counter.thread);
        PostThreadMessageW(ctlTid, 0x12, IntPtr.Zero, IntPtr.Zero); wt.Join(1000);
        CloseDesktop(desk);
        log.WriteLine("done");
        log.Close();
        return 0;
    }
}
