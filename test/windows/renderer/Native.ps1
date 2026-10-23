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
 [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cb; public RECT monitor,work; public uint flags; }
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
 [DllImport("user32")] public static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32")] public static extern bool GetMonitorInfoW(IntPtr m,ref MONITORINFO mi);
 [DllImport("user32")] public static extern bool ShowWindow(IntPtr h,int cmd);
 [DllImport("user32")] public static extern bool GetClientRect(IntPtr h,out RECT r);
 [DllImport("user32")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
 [DllImport("user32")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32")] public static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint f,uint timeout,out IntPtr result);
 public static string ClassOf(IntPtr h) { var b=new StringBuilder(256); GetClassNameW(h,b,256); return b.ToString(); }
 public static string DesktopName() {var b=new StringBuilder(256);uint needed;if(!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),2,b,512,out needed))throw new Exception("Cannot verify thread desktop");return b.ToString();}
 public static string WindowDesktop(IntPtr h) { int pid;uint tid=GetWindowThreadProcessId(h,out pid);var b=new StringBuilder(256);uint needed;if(tid==0 || !GetUserObjectInformationW(GetThreadDesktop(tid),2,b,512,out needed))throw new Exception("Cannot verify window desktop");return b.ToString(); }
 public static IntPtr ChildOfId(IntPtr parent,int id) {IntPtr found=IntPtr.Zero;EnumChildWindows(parent,(h,l)=>{if(GetDlgCtrlID(h)==id){found=h;return false;}return true;},IntPtr.Zero);return found;}
 [DllImport("user32")] static extern int GetDlgCtrlID(IntPtr h);
 // Explicit lpDesktop is required: a null desktop from a private-desktop
 // driver can put its child on the interactive desktop.
 [DllImport("kernel32",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
 public static PI Launch(string exe,string cwd,string desktop,System.Collections.IDictionary overrides,string stderrPath) {
  var values=new System.Collections.Generic.SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
  foreach(System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) values[(string)e.Key]=(string)e.Value;
  foreach(System.Collections.DictionaryEntry e in overrides) values[e.Key.ToString()]=e.Value.ToString();
  var block=new StringBuilder();foreach(var pair in values)block.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');block.Append('\0');
  IntPtr env=Marshal.StringToHGlobalUni(block.ToString());
  var si=new SI {cb=Marshal.SizeOf<SI>(),desktop="WinSta0\\"+desktop,flags=0x101,show=0};PI pi;
  try {
   using(var log=new FileStream(stderrPath,FileMode.Create,FileAccess.Write,FileShare.ReadWrite)) {
    si.stdout=si.stderr=log.SafeFileHandle.DangerousGetHandle();
    if(!SetHandleInformation(si.stderr,1,1))throw new Exception("Cannot inherit renderer log handle");
    if(!CreateProcessW(exe,new StringBuilder("\""+exe+"\" --single-instance=false"),IntPtr.Zero,IntPtr.Zero,true,0x08000400,env,cwd,ref si,out pi))throw new Exception("Renderer CreateProcess failed: "+Marshal.GetLastWin32Error());
    return pi;
   }
  } finally {Marshal.FreeHGlobal(env);}
 }
 public static IntPtr Host(int pid) { IntPtr found=IntPtr.Zero; EnumWindows((h,l)=>{int p;GetWindowThreadProcessId(h,out p);if(p==pid && ClassOf(h)=="noctty.win32.host") found=h;return true;},IntPtr.Zero);return found; }
 public static IntPtr Surface(IntPtr host) { IntPtr found=IntPtr.Zero; EnumChildWindows(host,(h,l)=>{if(ClassOf(h)=="noctty.win32" && IsWindowVisible(h)) {found=h;return false;}return true;},IntPtr.Zero);return found; }
 public static IntPtr[] Surfaces(IntPtr host,bool visibleOnly) { var found=new List<IntPtr>();EnumChildWindows(host,(h,l)=>{if(ClassOf(h)=="noctty.win32" && (!visibleOnly || IsWindowVisible(h))) found.Add(h);return true;},IntPtr.Zero);return found.ToArray(); }
 public static bool Action(IntPtr surf,int action) { IntPtr result;return SendMessageTimeoutW(surf,0x8056,(IntPtr)action,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool Scale(IntPtr surf,int dpi) { IntPtr result;return SendMessageTimeoutW(surf,0x8057,(IntPtr)dpi,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool LoseDevice(IntPtr surf) { IntPtr result;return SendMessageTimeoutW(surf,0x8050,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool RetryHardware(IntPtr surf) { IntPtr result;return SendMessageTimeoutW(surf,0x8058,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static bool Replay(IntPtr surf) { IntPtr result;return SendMessageTimeoutW(surf,0x8051,IntPtr.Zero,IntPtr.Zero,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 public static RECT WorkArea(IntPtr h) { var mi=new MONITORINFO();mi.cb=Marshal.SizeOf(typeof(MONITORINFO));if(!GetMonitorInfoW(MonitorFromWindow(h,2),ref mi))throw new Exception("Cannot read the monitor work area");return mi.work; }
 public static bool Resize(IntPtr host,int w,int h) { return SetWindowPos(host,IntPtr.Zero,0,0,w,h,0x16); }
 public static void Readback(string bmp,string png) {using(var image=new Bitmap(bmp)){image.Save(png,ImageFormat.Png);} }
 public static bool Capture(IntPtr h,string path) { RECT r;GetClientRect(h,out r); using(var b=new Bitmap(Math.Max(1,r.r),Math.Max(1,r.b),PixelFormat.Format32bppArgb)) { bool ok;using(var g=Graphics.FromImage(b)){g.Clear(Color.Magenta);IntPtr dc=g.GetHdc();try{IntPtr result;ok=SendMessageTimeoutW(h,0x0318,dc,(IntPtr)4,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero;}finally{g.ReleaseHdc(dc);}}b.Save(path,ImageFormat.Png);return ok;} }
 public static string PixelStats(string path) { using(var b=new Bitmap(path)){var c=new HashSet<int>();long nonblack=0;for(int y=0;y<b.Height;y++)for(int x=0;x<b.Width;x++){int p=b.GetPixel(x,y).ToArgb()&0xffffff;c.Add(p);if(p!=0)nonblack++;}return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"width\":{0},\"height\":{1},\"colors\":{2},\"nonblack\":{3}}}",b.Width,b.Height,c.Count,nonblack);} }
 // Shows IME composition fixture `fixture` (0 clears) with its caret at UTF-16
 // unit `cursor` (-1 for none) through the test-tools hook, past the IMM read.
 public static bool Preedit(IntPtr surf,int fixture,int cursor) { IntPtr result;return SendMessageTimeoutW(surf,0x8059,(IntPtr)fixture,(IntPtr)cursor,2,5000,out result)!=IntPtr.Zero && result!=IntPtr.Zero; }
 // Counts the pixels of `a` and `b` that differ by more than `tolerance` in
 // any channel, and their bounding box.
 public static string DiffBox(string a,string b,int tolerance) {using(var x=new Bitmap(a))using(var y=new Bitmap(b)){if(x.Size!=y.Size)throw new Exception("Image dimensions differ");long count=0;int x0=-1,y0=-1,x1=-1,y1=-1;for(int j=0;j<x.Height;j++)for(int i=0;i<x.Width;i++){var p=x.GetPixel(i,j);var q=y.GetPixel(i,j);if(Math.Max(Math.Abs(p.R-q.R),Math.Max(Math.Abs(p.G-q.G),Math.Abs(p.B-q.B)))<=tolerance)continue;count++;if(x0<0||i<x0)x0=i;if(y0<0||j<y0)y0=j;if(i>x1)x1=i;if(j>y1)y1=j;}return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"count\":{0},\"x0\":{1},\"y0\":{2},\"x1\":{3},\"y1\":{4}}}",count,x0,y0,x1,y1);} }
 // Counts the pixels within `tolerance` of one colour and their bounding box.
 public static string ColorBox(string path,int r,int g,int b,int tolerance) {using(var image=new Bitmap(path)){long count=0;int x0=-1,y0=-1,x1=-1,y1=-1;for(int y=0;y<image.Height;y++)for(int x=0;x<image.Width;x++){var p=image.GetPixel(x,y);if(Math.Abs(p.R-r)>tolerance||Math.Abs(p.G-g)>tolerance||Math.Abs(p.B-b)>tolerance)continue;count++;if(x0<0||x<x0)x0=x;if(y0<0||y<y0)y0=y;if(x>x1)x1=x;if(y>y1)y1=y;}return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"count\":{0},\"x0\":{1},\"y0\":{2},\"x1\":{3},\"y1\":{4},\"width\":{5}}}",count,x0,y0,x1,y1,image.Width);} }
 // The runs of consecutive rows in `y0..y1` on which every pixel of columns
 // `x0..x1` differs from the background (r,g,b) by more than `threshold` in
 // some channel, as {y0,y1} bands. An underline spans the full width of
 // its cells; a glyph stroke stops at the glyph's side bearings.
 public static string LitBands(string path,int x0,int x1,int y0,int y1,int r,int g,int b,int threshold) {using(var image=new Bitmap(path)){if(x0<0||y0<0||x1>=image.Width||y1>=image.Height||x0>x1||y0>y1)throw new Exception("Band rect outside the image");var bands=new List<string>();int start=-1;for(int y=y0;y<=y1+1;y++){bool lit=y<=y1;for(int x=x0;lit&&x<=x1;x++){var p=image.GetPixel(x,y);if(Math.Max(Math.Abs(p.R-r),Math.Max(Math.Abs(p.G-g),Math.Abs(p.B-b)))<=threshold)lit=false;}if(lit&&start<0)start=y;else if(!lit&&start>=0){bands.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"y0\":{0},\"y1\":{1}}}",start,y-1));start=-1;}}return "{\"bands\":["+string.Join(",",bands)+"]}";} }
 public static int Left(IntPtr h) { RECT r; if(!GetWindowRect(h,out r))throw new Exception("Cannot read a pane rect"); return r.l; }
 // Checks `dimmed` against `undimmed` blended toward the fill in sRGB (gamma)
 // space, round((u*(255-a) + f*a)/255) per channel. Pixels off by more than
 // `tolerance` are mismatches; their bounding box shows whether they are only
 // the cursor cell, whose shape follows keyboard focus. `changed` counts the
 // pixels the dim moved at all (the positive control).
 public static string BlendCheck(string dimmed,string undimmed,int fr,int fg,int fb,int alpha,int tolerance) {using(var d=new Bitmap(dimmed))using(var u=new Bitmap(undimmed)){if(d.Size!=u.Size)throw new Exception("Image dimensions differ");int[] f={fr,fg,fb};long mismatches=0,changed=0,exact=0,off1=0,off2=0;int maxDelta=0,x0=int.MaxValue,y0=int.MaxValue,x1=-1,y1=-1;var freq=new Dictionary<int,long>();int brightest=-1,brightestSum=-1,brightestDim=0;var firstDim=new Dictionary<int,int>();for(int y=0;y<d.Height;y++)for(int x=0;x<d.Width;x++){var p=d.GetPixel(x,y);var q=u.GetPixel(x,y);int[] dv={p.R,p.G,p.B};int[] uv={q.R,q.G,q.B};int delta=0;for(int c=0;c<3;c++){int e=(int)Math.Floor((uv[c]*(255-alpha)+f[c]*alpha)/255.0+0.5);delta=Math.Max(delta,Math.Abs(dv[c]-e));}int key=q.ToArgb()&0xffffff;long n;freq.TryGetValue(key,out n);freq[key]=n+1;if(!firstDim.ContainsKey(key))firstDim[key]=p.ToArgb()&0xffffff;int sum=q.R+q.G+q.B;if(sum>brightestSum){brightestSum=sum;brightest=key;brightestDim=p.ToArgb()&0xffffff;}if((p.ToArgb()&0xffffff)!=key)changed++;if(delta==0)exact++;else if(delta==1)off1++;else if(delta<=tolerance)off2++;if(delta>tolerance){mismatches++;x0=Math.Min(x0,x);y0=Math.Min(y0,y);x1=Math.Max(x1,x);y1=Math.Max(y1,y);}else maxDelta=Math.Max(maxDelta,delta);}int common=-1;long best=-1;foreach(var kv in freq)if(kv.Value>best){best=kv.Value;common=kv.Key;}Func<int,string> hex=v=>"#"+v.ToString("x6");return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"pixels\":{0},\"changed\":{1},\"exact\":{2},\"off1\":{3},\"offWithinTolerance\":{4},\"mismatches\":{5},\"maxDeltaWithinTolerance\":{6},\"bboxWidth\":{7},\"bboxHeight\":{8},\"commonUndimmed\":\"{9}\",\"commonDimmed\":\"{10}\",\"brightestUndimmed\":\"{11}\",\"brightestDimmed\":\"{12}\",\"alpha\":{13}}}",(long)d.Width*d.Height,changed,exact,off1,off2,mismatches,maxDelta,x1<0?0:x1-x0+1,y1<0?0:y1-y0+1,hex(common),hex(firstDim[common]),hex(brightest),hex(brightestDim),alpha);} }
 public static string Diff(string a,string b,string output) {using(var x=new Bitmap(a))using(var y=new Bitmap(b)){if(x.Size!=y.Size)throw new Exception("Image dimensions differ");long changed=0,over2=0,totalDelta=0;int maxDelta=0;using(var d=new Bitmap(x.Width,x.Height)){for(int j=0;j<x.Height;j++)for(int i=0;i<x.Width;i++){var p=x.GetPixel(i,j);var q=y.GetPixel(i,j);int delta=Math.Max(Math.Abs(p.R-q.R),Math.Max(Math.Abs(p.G-q.G),Math.Abs(p.B-q.B)));if(delta>0)changed++;if(delta>2)over2++;totalDelta+=delta;maxDelta=Math.Max(maxDelta,delta);d.SetPixel(i,j,delta>0?Color.FromArgb(255,Math.Min(255,delta*4),0,0):Color.Black);}d.Save(output,ImageFormat.Png);}return string.Format(System.Globalization.CultureInfo.InvariantCulture,"{{\"pixels\":{0},\"different\":{1},\"over2\":{2},\"maxChannelDelta\":{3},\"meanMaxChannelDelta\":{4}}}",(long)x.Width*x.Height,changed,over2,maxDelta,(double)totalDelta/(x.Width*x.Height));} }
}
'@
}
