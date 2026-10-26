using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Tl {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    public delegate bool MonitorEnum(IntPtr m, IntPtr dc, ref Rect r, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref Pt p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnum cb, IntPtr p);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(int tid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder info, int len, out int needed);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a,string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job,int type,ref JobLimits limits,uint size);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll")] static extern bool QueryInformationJobObject(IntPtr job,int type,out JobAccounting accounting,uint size,IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime,kernelTime,periodUserTime,periodKernelTime;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long processTime,jobTime; public uint flags;
        public UIntPtr minWorking,maxWorking; public uint activeProcesses;
        public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits basic; public IoCounters io;
        public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    public static IntPtr CreateOwnedJob() {
        var job=CreateJobObjectW(IntPtr.Zero,null);
        if(job==IntPtr.Zero) throw new Exception("CreateJobObject failed");
        var limits=new JobLimits(); limits.basic.flags=0x2000;
        if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<JobLimits>())) { CloseHandle(job); throw new Exception("SetInformationJobObject failed"); }
        return job;
    }
    public static uint StopOwnedJob(IntPtr job) {
        try {
            if(!TerminateJobObject(job,1)) throw new Exception("Terminate owned job failed");
            var deadline=DateTime.UtcNow.AddSeconds(5);
            do {
                JobAccounting a;
                if(!QueryInformationJobObject(job,1,out a,(uint)Marshal.SizeOf<JobAccounting>(),IntPtr.Zero)) throw new Exception("Query owned job failed");
                if(a.activeProcesses==0) return a.totalProcesses;
                System.Threading.Thread.Sleep(10);
            } while(DateTime.UtcNow<deadline);
            throw new Exception("Owned job cleanup exceeded five seconds");
        } finally { CloseHandle(job); }
    }
    // Start a process suspended on an explicit desktop, inside `job` when given, then resume it.
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,uint flags) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop }; ProcessInfo pi;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags|0x4,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if((job!=IntPtr.Zero && !AssignProcessToJobObject(job,pi.process))||ResumeThread(pi.thread)==0xFFFFFFFF) {
            TerminateProcess(pi.process,1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume failed");
        }
        return pi;
    }
    public static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") list.Add(h); return true; },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr[] Menus() {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { if(Class(h)=="#32768" && IsWindowVisible(h)) list.Add(h); return true; },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr Surface(IntPtr h) { IntPtr found=IntPtr.Zero;
        EnumChildWindows(h,(c,p)=> { if(Class(c)=="noctty.win32" && IsWindowVisible(c)) found=c; return true; },IntPtr.Zero); return found; }
    public static int SurfaceCount(IntPtr h) { int n=0;
        EnumChildWindows(h,(c,p)=> { if(Class(c)=="noctty.win32" && IsWindowVisible(c)) n++; return true; },IntPtr.Zero); return n; }
    public static IntPtr Child(IntPtr h, int id) { IntPtr found=IntPtr.Zero;
        EnumChildWindows(h,(c,p)=> { if(GetDlgCtrlID(c)==id && found==IntPtr.Zero) found=c; return true; },IntPtr.Zero); return found; }
    public static string Children(IntPtr host) {
        var sb=new StringBuilder(); Pt o=new Pt(); ClientToScreen(host,ref o);
        EnumChildWindows(host,(c,p)=> { if(!IsWindowVisible(c)) return true; Rect r; GetWindowRect(c,out r);
            sb.AppendFormat("{0}#{1}({2},{3})-({4},{5}) ", Class(c), GetDlgCtrlID(c), r.Left-o.X, r.Top-o.Y, r.Right-o.X, r.Bottom-o.Y); return true; },IntPtr.Zero);
        return sb.ToString();
    }
    public static string DesktopOf(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid); IntPtr d=GetThreadDesktop(tid);
        var s=new StringBuilder(256); int n; return GetUserObjectInformationW(d,2,s,512,out n) ? s.ToString() : "?";
    }
    public static string Monitors() {
        var sb=new StringBuilder();
        EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr m, IntPtr dc, ref Rect r, IntPtr p)=> { uint x,y; GetDpiForMonitor(m,0,out x,out y);
            sb.AppendFormat("({0},{1})-({2},{3})@{4};", r.Left,r.Top,r.Right,r.Bottom,x); return true; },IntPtr.Zero);
        return sb.ToString();
    }
    public static void Key(IntPtr target,int key) {
        if(!PostMessageW(target,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(target,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    public static void Move(IntPtr target,int x,int y) { PostMessageW(target,0x200,IntPtr.Zero,new IntPtr((y<<16)|(x&0xFFFF))); }
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint c);
    [DllImport("user32.dll")] static extern int FillRect(IntPtr dc, ref Rect r, IntPtr b);
    [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);
    [StructLayout(LayoutKind.Sequential)] struct BitmapInfoHeader { public int size,width,height; public short planes,bitCount; public int compression,sizeImage,xppm,yppm,clrUsed,clrImportant; }
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BitmapInfoHeader bi, uint usage);
    public class Shot { public int W,H; public byte[] Bgra; public bool Ok; }
    // Window-rect-sized capture through PrintWindow over a magenta fill.
    public static Shot Capture(IntPtr w, uint flags) {
        Rect r; if(!GetWindowRect(w,out r)) throw new Exception("GetWindowRect failed");
        int cw=Math.Max(1,r.Right-r.Left), ch=Math.Max(1,r.Bottom-r.Top);
        IntPtr screen=GetDC(IntPtr.Zero); IntPtr dc=CreateCompatibleDC(screen); IntPtr bmp=CreateCompatibleBitmap(screen,cw,ch);
        IntPtr old=SelectObject(dc,bmp);
        try {
            var all=new Rect{Left=0,Top=0,Right=cw,Bottom=ch}; var brush=CreateSolidBrush(0x00FF00FF); FillRect(dc,ref all,brush); DeleteObject(brush);
            bool ok=PrintWindow(w,dc,flags);
            var bi=new BitmapInfoHeader{ size=Marshal.SizeOf<BitmapInfoHeader>(), width=cw, height=-ch, planes=1, bitCount=32 };
            var bits=new byte[cw*ch*4];
            SelectObject(dc,old); old=IntPtr.Zero;
            if(GetDIBits(dc,bmp,0,(uint)ch,bits,ref bi,0)==0) throw new Exception("GetDIBits failed");
            return new Shot{ W=cw, H=ch, Bgra=bits, Ok=ok };
        } finally { if(old!=IntPtr.Zero) SelectObject(dc,old); DeleteObject(bmp); DeleteDC(dc); ReleaseDC(IntPtr.Zero,screen); }
    }
    // Client-sized copy through the window's own DC (what it last painted).
    public static Shot Blt(IntPtr w) {
        Rect r; if(!GetClientRect(w,out r)) throw new Exception("GetClientRect failed");
        int cw=Math.Max(1,r.Right-r.Left), ch=Math.Max(1,r.Bottom-r.Top);
        IntPtr src=GetDC(w); IntPtr dc=CreateCompatibleDC(src); IntPtr bmp=CreateCompatibleBitmap(src,cw,ch);
        IntPtr old=SelectObject(dc,bmp);
        try {
            bool ok=BitBlt(dc,0,0,cw,ch,src,0,0,0x00CC0020);
            var bi=new BitmapInfoHeader{ size=Marshal.SizeOf<BitmapInfoHeader>(), width=cw, height=-ch, planes=1, bitCount=32 };
            var bits=new byte[cw*ch*4];
            SelectObject(dc,old); old=IntPtr.Zero;
            if(GetDIBits(dc,bmp,0,(uint)ch,bits,ref bi,0)==0) throw new Exception("GetDIBits failed");
            return new Shot{ W=cw, H=ch, Bgra=bits, Ok=ok };
        } finally { if(old!=IntPtr.Zero) SelectObject(dc,old); DeleteObject(bmp); DeleteDC(dc); ReleaseDC(w,src); }
    }
    public static void SaveBmp(Shot s, string path) {
        using(var f=new System.IO.FileStream(path,System.IO.FileMode.Create)) using(var bw=new System.IO.BinaryWriter(f)) {
            int stride=s.W*4, size=stride*s.H;
            bw.Write((byte)'B'); bw.Write((byte)'M'); bw.Write(54+size); bw.Write(0); bw.Write(54);
            bw.Write(40); bw.Write(s.W); bw.Write(-s.H); bw.Write((short)1); bw.Write((short)32); bw.Write(0); bw.Write(size); bw.Write(2835); bw.Write(2835); bw.Write(0); bw.Write(0);
            bw.Write(s.Bgra);
        }
    }
}
