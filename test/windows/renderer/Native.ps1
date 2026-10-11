$ErrorActionPreference = 'Stop'
if (-not ('RendererNative' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing, System.Drawing.Common, System.Drawing.Primitives, System.Collections, System.Runtime.InteropServices, System.Private.Windows.Core, System.Private.Windows.GdiPlus -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
public static class RendererNative {
 public static ushort PeMachine(string path) { using(var s=File.OpenRead(path))using(var r=new BinaryReader(s)){if(s.Length<64 || r.ReadUInt16()!=0x5a4d)throw new Exception("Invalid PE header");s.Position=0x3c;uint offset=r.ReadUInt32();if((ulong)offset+6>(ulong)s.Length)throw new Exception("PE header outside file");s.Position=offset;if(r.ReadUInt32()!=0x4550)throw new Exception("Invalid PE signature");return r.ReadUInt16();} }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI { public int cb; public string reserved,desktop,title; public int x,y,w,h,charsX,charsY,fill,flags; public short show,reserved2; public IntPtr reservedPtr,stdin,stdout,stderr; }
 [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process,thread; public int pid,tid; }
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l,t,r,b; }
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr d,IntPtr m,int f,uint a,IntPtr s);
 [DllImport("user32")] public static extern bool CloseDesktop(IntPtr h);
 [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,int flags,IntPtr env,string cwd,ref SI si,out PI pi);
 [DllImport("kernel32")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
 [DllImport("kernel32")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
 [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32")] public static extern ulong GetTickCount64();
 [DllImport("kernel32")] public static extern uint GetCurrentThreadId();
 [DllImport("user32")] public static extern IntPtr GetThreadDesktop(uint thread);
 [DllImport("user32",CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr obj,int index,StringBuilder value,uint bytes,out uint needed);
 [DllImport("user32")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("user32")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32")] public static extern bool EnumChildWindows(IntPtr parent,EnumProc cb,IntPtr l);
 [DllImport("user32")] public static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
 [DllImport("user32",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32")] public static extern bool ShowWindow(IntPtr h,int cmd);
 [DllImport("user32")] public static extern bool GetClientRect(IntPtr h,out RECT r);
 [DllImport("user32")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
 [DllImport("user32")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32")] public static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint timeout,out IntPtr result);
 public static string ClassOf(IntPtr h) { var b=new StringBuilder(256); GetClassNameW(h,b,256); return b.ToString(); }
 public static string DesktopName() {var b=new StringBuilder(256);uint needed;if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,b,512,out needed))throw new Exception("Cannot verify thread desktop");return b.ToString();}
 public static IntPtr Host(int pid) { IntPtr found=IntPtr.Zero; EnumWindows((h,l)=>{int p;GetWindowThreadProcessId(h,out p);if(p==pid && ClassOf(h)=="noctty.win32.host") found=h;return true;},IntPtr.Zero);return found; }
 public static IntPtr Surface(IntPtr host) { IntPtr found=IntPtr.Zero; EnumChildWindows(host,(h,l)=>{if(ClassOf(h)=="noctty.win32" && IsWindowVisible(h)) {found=h;return false;}return true;},IntPtr.Zero);return found; }
 public static IntPtr[] Surfaces(IntPtr host,bool visibleOnly) { var found=new List<IntPtr>();EnumChildWindows(host,(h,l)=>{if(ClassOf(h)=="noctty.win32" && (!visibleOnly || IsWindowVisible(h))) found.Add(h);return true;},IntPtr.Zero);return found.ToArray(); }
 public static bool Action(IntPtr surf,int action) { IntPtr result;return SendMessageTimeoutW(surf,0x8056,(IntPtr)action,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool Scale(IntPtr surf,int dpi) { IntPtr result;return SendMessageTimeoutW(surf,0x8057,(IntPtr)dpi,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool LoseDevice(IntPtr surf) { IntPtr result;return SendMessageTimeoutW(surf,0x8050,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool RetryHardware(IntPtr surf) { IntPtr result;return SendMessageTimeoutW(surf,0x8058,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool Replay(IntPtr surf) { IntPtr result;return SendMessageTimeoutW(surf,0x8051,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool Resize(IntPtr host,int w,int h) { return SetWindowPos(host,IntPtr.Zero,0,0,w,h,0x16); }
 public static void Readback(string bmp,string png) {using(var image=new Bitmap(bmp)){image.Save(png,ImageFormat.Png);} }
 public static bool Capture(IntPtr h,string path) { RECT r;GetClientRect(h,out r); using(var b=new Bitmap(Math.Max(1,r.r),Math.Max(1,r.b),PixelFormat.Format32bppArgb)) { bool ok;using(var g=Graphics.FromImage(b)){g.Clear(Color.Magenta);IntPtr dc=g.GetHdc();try{IntPtr result;ok=SendMessageTimeoutW(h,0x0318,dc,(IntPtr)4,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero;}finally{g.ReleaseHdc(dc);}}b.Save(path,ImageFormat.Png);return ok;} }
 public static string PixelStats(string path) { using(var b=new Bitmap(path)){var c=new HashSet<int>();long nonblack=0;for(int y=0;y<b.Height;y++)for(int x=0;x<b.Width;x++){int p=b.GetPixel(x,y).ToArgb()&0xffffff;c.Add(p);if(p!=0)nonblack++;}return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"width\":{0},\"height\":{1},\"colors\":{2},\"nonblack\":{3}}}",b.Width,b.Height,c.Count,nonblack);} }
 public static string Diff(string a,string b,string output) {using(var x=new Bitmap(a))using(var y=new Bitmap(b)){if(x.Size!=y.Size)throw new Exception("Image dimensions differ");long changed=0,over2=0,totalDelta=0;int maxDelta=0;using(var d=new Bitmap(x.Width,x.Height)){for(int j=0;j<x.Height;j++)for(int i=0;i<x.Width;i++){var p=x.GetPixel(i,j);var q=y.GetPixel(i,j);int delta=Math.Max(Math.Abs(p.R-q.R),Math.Max(Math.Abs(p.G-q.G),Math.Abs(p.B-q.B)));if(delta>0)changed++;if(delta>2)over2++;totalDelta+=delta;maxDelta=Math.Max(maxDelta,delta);d.SetPixel(i,j,delta>0?Color.FromArgb(255,Math.Min(255,delta*4),0,0):Color.Black);}d.Save(output,ImageFormat.Png);}return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"pixels\":{0},\"different\":{1},\"over2\":{2},\"maxChannelDelta\":{3},\"meanMaxChannelDelta\":{4}}}",(long)x.Width*x.Height,changed,over2,maxDelta,(double)totalDelta/(x.Width*x.Height));} }
}
'@
}
