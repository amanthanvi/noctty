// Focused Win32 support for cli-com-forwarder.ps1. No product code is compiled.
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class ComCliNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved, desktop, title;
        public int x,y,cx,cy,charsX,charsY,fill,flags;
        public short show,reservedBytes; public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process,thread; public uint pid,tid; }
    [StructLayout(LayoutKind.Sequential)] struct Security { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public long processTime,jobTime; public uint flags; public UIntPtr minimum,maximum;
        public uint active; public UIntPtr affinity; public uint priority,scheduling;
        public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes;
        public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    [StructLayout(LayoutKind.Sequential)] struct JobAccounting {
        public long userTime,kernelTime,periodUserTime,periodKernelTime;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    const int CaptureLimit = 1 << 20;
    public sealed class Child : IDisposable {
        public IntPtr Handle, Job; public uint Pid; public long Created;
        public string Image; public IntPtr OutputRead;
        public Task<string> Output, Error;
        public bool Exited { get { return WaitForSingleObject(Handle,0)==0; } }
        public uint ExitCode { get { uint code; Check(GetExitCodeProcess(Handle,out code)); return code; } }
        public bool Wait(int ms) { return WaitForSingleObject(Handle,(uint)ms)==0; }
        // Bounded reads: a drain that never reaches EOF (a descendant kept the
        // pipe) fails the case instead of hanging the harness.
        public string ReadOutput(int ms) { return Await(Output,ms,"stdout"); }
        public string ReadError(int ms) { return Await(Error,ms,"stderr"); }
        public bool OutputClosed(int ms) { return Output!=null && Output.Wait(ms); }
        public bool ErrorClosed(int ms) { return Error!=null && Error.Wait(ms); }
        static string Await(Task<string> task,int ms,string name) {
            if(task==null) return "";
            if(!task.Wait(ms)) throw new TimeoutException("Timed out draining "+name);
            return task.Result;
        }
        public void Dispose() {
            if(Handle==IntPtr.Zero) return;
            Verify(this);
            if(!Exited) { Check(TerminateProcess(Handle,0xD20)); Wait(5000); }
            // KILL_ON_JOB_CLOSE reaps whatever the case left behind; cases assert
            // ActiveProcesses==0 before this point so the reaping hides nothing.
            if(Job!=IntPtr.Zero) { CloseHandle(Job); Job=IntPtr.Zero; }
            if(OutputRead!=IntPtr.Zero) CloseHandle(OutputRead);
            CloseHandle(Handle); Handle=IntPtr.Zero;
        }
    }
    delegate bool EnumWindow(IntPtr window,IntPtr parameter);
    delegate bool ControlHandler(uint kind);
    static readonly ControlHandler Control = kind => kind==0;
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,ref Security sa,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security sa,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool PeekNamedPipe(IntPtr pipe,IntPtr buffer,uint size,IntPtr read,out uint available,IntPtr left);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr h,out long created,out long exited,out long kernel,out long user);
    [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageNameW(IntPtr h,uint flags,StringBuilder image,ref uint length);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint exit);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes,IntPtr name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref JobLimits limits,int size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref uint limits,int size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out JobAccounting info,int size,IntPtr returned);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out int result);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetConsoleCtrlHandler(ControlHandler handler,bool add);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GenerateConsoleCtrlEvent(uint kind,uint group);
    [DllImport("ntdll.dll")] static extern IntPtr RtlGetCurrentPeb();
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList([Out] uint[] processes,uint count);
    [DllImport("kernel32.dll",SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ReadConsoleOutputCharacterW(IntPtr h,[Out] char[] text,uint count,uint coordinate,out uint read);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenDesktopW(string name,uint flags,bool inherit,uint access);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateDesktopW(string name,IntPtr device,IntPtr mode,uint flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll",SetLastError=true)] static extern bool EnumDesktopWindows(IntPtr desktop,EnumWindow callback,IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumWindow callback,IntPtr parameter);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint message,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint message,IntPtr w,IntPtr l);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenThread(uint access,bool inherit,uint tid);
    [DllImport("kernel32.dll")] static extern uint GetProcessIdOfThread(IntPtr thread);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder name,uint bytes,out uint needed);
    [DllImport("advapi32.dll",SetLastError=true)] static extern IntPtr OpenThreadWaitChainSession(uint flags,IntPtr callback);
    [DllImport("advapi32.dll")] static extern void CloseThreadWaitChainSession(IntPtr session);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetThreadWaitChain(IntPtr session,UIntPtr context,uint flags,uint tid,ref uint count,IntPtr nodes,out bool cycle);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr thread,out IntPtr description);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    static Security Inheritable() { return new Security { length=Marshal.SizeOf(typeof(Security)),inherit=1 }; }
    public static string Quote(string value) {
        var result=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='"') { result.Append('\\',slashes*2+1).Append(c); slashes=0; continue; }
            result.Append('\\',slashes).Append(c); slashes=0;
        }
        return result.Append('\\',slashes*2).Append('"').ToString();
    }
    static string ObjectName(IntPtr handle) {
        var name=new StringBuilder(256); uint needed;
        Check(GetUserObjectInformationW(handle,2,name,512,out needed)); return name.ToString();
    }
    // The only desktop this harness uses: a new, uniquely named desktop on the
    // current window station. It is never switched to, so it is never visible,
    // and its handle is inheritable so a driver started with an explicit
    // lpDesktop can open it. Every child names it through lpDesktop.
    public static IntPtr HiddenDesktop(string name) {
        if(!name.StartsWith("noctty-pkg74-",StringComparison.Ordinal)) throw new Exception("Unexpected hidden desktop name");
        if(ObjectName(GetProcessWindowStation())!="WinSta0") throw new Exception("Controller is not on WinSta0");
        var pointer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Security)));
        try {
            Marshal.StructureToPtr(Inheritable(),pointer,false);
            var desktop=CreateDesktopW(name,IntPtr.Zero,IntPtr.Zero,0,0xF01FF,pointer);
            if(desktop==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Create hidden desktop failed");
            return desktop;
        } finally { Marshal.FreeHGlobal(pointer); }
    }
    public static IntPtr DriverDesktop(string desktop) {
        if(!desktop.StartsWith("noctty-pkg74-",StringComparison.Ordinal)) throw new Exception("Unexpected hidden desktop name");
        if(ObjectName(GetProcessWindowStation())!="WinSta0" || ObjectName(GetThreadDesktop(GetCurrentThreadId()))!=desktop) throw new Exception("Driver station/desktop mismatch");
        var input=OpenInputDesktop(0,false,1);
        if(input!=IntPtr.Zero) {
            try { if(ObjectName(input)==desktop) throw new Exception("Hidden desktop is the input desktop"); }
            finally { CloseDesktop(input); }
        } else if(Marshal.GetLastWin32Error()!=5) throw new Win32Exception(); // access denied: a secure desktop is input, so ours is not
        var handle=OpenDesktopW(desktop,0,false,0x41);
        if(handle==IntPtr.Zero) throw new Win32Exception(); return handle;
    }
    static IntPtr FileHandle(string path,bool input) {
        var sa=Inheritable();
        bool device=path=="NUL" || path=="CONOUT$" || path=="CONIN$";
        var h=CreateFileW(path,input?0x80000000u:0x40000000u,7,ref sa,(input || device)?3u:2u,0x80,IntPtr.Zero);
        if(h==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Capture open failed: "+Path.GetFileName(path));
        return h;
    }
    // Keeps at most 1 MiB and keeps reading (discarding) so a noisy child is
    // never blocked, then fails the read if the cap was exceeded.
    static Task<string> Drain(IntPtr handle) {
        return Task.Run(()=> {
            using(var stream=new FileStream(new SafeFileHandle(handle,true),FileAccess.Read,4096,false))
            using(var kept=new MemoryStream()) {
                var buffer=new byte[4096]; int read; bool over=false;
                while((read=stream.Read(buffer,0,buffer.Length))>0) {
                    if(kept.Length+read<=CaptureLimit) kept.Write(buffer,0,read); else over=true;
                }
                if(over) throw new InvalidDataException("Captured output exceeded 1 MiB");
                return new UTF8Encoding(false,true).GetString(kept.ToArray());
            }
        });
    }
    // Capture-file read with the same cap.
    public static string ReadCapture(string path) {
        if(!File.Exists(path)) return "";
        if(new FileInfo(path).Length>CaptureLimit) throw new InvalidDataException("Captured file exceeded 1 MiB: "+Path.GetFileName(path));
        using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var reader=new StreamReader(stream,new UTF8Encoding(false,true))) return reader.ReadToEnd();
    }
    // mode: files, pipes, blocked (undrained stdout pipe), console, or none.
    // flags always include CREATE_SUSPENDED; console callers deliberately inherit
    // the CREATE_NO_WINDOW driver's private console. Never create a visible one.
    // show is the launcher's wShowWindow (0 SW_HIDE, 1 SW_SHOWNORMAL).
    // rawCommandLine passes the supplied text in a non-null mutable buffer,
    // without adding argv[0]. Windows substitutes argv[0] for both NULL and an
    // empty buffer; a whitespace-only buffer reaches the wrapper unchanged.
    public static Child Launch(string image,string raw,string cwd,string desktop,string mode,string input,string output,string error,uint flags) {
        return Launch(image,raw,cwd,desktop,mode,input,output,error,flags,0,false);
    }
    public static Child Launch(string image,string raw,string cwd,string desktop,string mode,string input,string output,string error,uint flags,int show,bool rawCommandLine) {
        if(String.IsNullOrEmpty(desktop) || !desktop.StartsWith("WinSta0\\noctty-pkg74-",StringComparison.Ordinal)) throw new Exception("An explicit isolated hidden desktop is required");
        IntPtr stdin=IntPtr.Zero,stdout=IntPtr.Zero,stderr=IntPtr.Zero,outRead=IntPtr.Zero,errRead=IntPtr.Zero;
        var pi=new ProcessInfo(); bool created=false; IntPtr job=IntPtr.Zero;
        try {
            var si=new Startup { cb=Marshal.SizeOf(typeof(Startup)),desktop=desktop,flags=1,show=(short)show };
            if(mode=="none") { si.flags|=0x100; si.input=new IntPtr(-1); si.output=new IntPtr(-1); si.error=new IntPtr(-1); }
            else {
                stdin=FileHandle(String.IsNullOrEmpty(input)?"NUL":input,true);
                if(mode=="pipes" || mode=="blocked" || mode=="restricted") {
                    var sa=Inheritable(); Check(CreatePipe(out outRead,out stdout,ref sa,4096)); Check(SetHandleInformation(outRead,1,0));
                    Check(CreatePipe(out errRead,out stderr,ref sa,4096)); Check(SetHandleInformation(errRead,1,0));
                } else if(mode=="console") {
                    stdout=FileHandle("CONOUT$",false); stderr=FileHandle("CONOUT$",false);
                } else { stdout=FileHandle(output,false); stderr=FileHandle(error,false); }
                si.flags|=0x100; si.input=stdin; si.output=stdout; si.error=stderr;
            }
            var command=new StringBuilder(rawCommandLine?raw:Quote(image)+" "+raw);
            if(!CreateProcessW(image,command,IntPtr.Zero,IntPtr.Zero,mode!="none",flags|4,IntPtr.Zero,cwd,ref si,out pi)) throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateProcessW failed: "+Path.GetFileName(image));
            created=true;
            job=CreateJobObjectW(IntPtr.Zero,IntPtr.Zero); Check(job!=IntPtr.Zero);
            var limits=new JobLimits { flags=0x2000 }; // KILL_ON_JOB_CLOSE, owned descendants only
            Check(SetInformationJobObject(job,9,ref limits,Marshal.SizeOf(typeof(JobLimits))));
            if(mode=="restricted") {
                // READCLIPBOARD exercises documented job-nesting restrictions;
                // the probe never reads or writes any clipboard.
                uint uiLimits=2; Check(SetInformationJobObject(job,4,ref uiLimits,sizeof(uint)));
            }
            Check(AssignProcessToJobObject(job,pi.process));
            long born,exited,kernel,user; Check(GetProcessTimes(pi.process,out born,out exited,out kernel,out user));
            var child=new Child { Handle=pi.process,Job=job,Pid=pi.pid,Created=born,Image=Path.GetFullPath(image) };
            Verify(child);
            if(mode=="pipes" || mode=="restricted") { child.Output=Drain(outRead); outRead=IntPtr.Zero; }
            if(mode=="blocked") { child.OutputRead=outRead; outRead=IntPtr.Zero; }
            if(errRead!=IntPtr.Zero) { child.Error=Drain(errRead); errRead=IntPtr.Zero; }
            if(ResumeThread(pi.thread)==0xFFFFFFFF) throw new Win32Exception();
            job=IntPtr.Zero; return child;
        } catch { if(created) { TerminateProcess(pi.process,0xD20); CloseHandle(pi.process); } throw; }
        finally {
            if(job!=IntPtr.Zero) CloseHandle(job);
            if(pi.thread!=IntPtr.Zero) CloseHandle(pi.thread);
            foreach(var h in new[]{stdin,stdout,stderr,outRead,errRead}) if(h!=IntPtr.Zero) CloseHandle(h);
        }
    }
    public static void Verify(Child child) {
        long born,exit,kernel,user; Check(GetProcessTimes(child.Handle,out born,out exit,out kernel,out user));
        if(GetProcessId(child.Handle)!=child.Pid || born!=child.Created) throw new Exception("Owned process identity mismatch");
        if(!child.Exited) {
            var image=new StringBuilder(32768); uint size=(uint)image.Capacity;
            Check(QueryFullProcessImageNameW(child.Handle,0,image,ref size));
            if(!String.Equals(Path.GetFullPath(image.ToString()),child.Image,StringComparison.OrdinalIgnoreCase)) throw new Exception("Owned image identity mismatch");
        }
    }
    // True when the live process pid is in the launched child's kill-on-close
    // job (the child itself and everything it started without breaking away).
    public static bool InJob(Child owner,uint pid) {
        if(owner==null || owner.Job==IntPtr.Zero) throw new Exception("Owner has no job");
        var h=OpenProcess(0x101000,false,pid); // QUERY_LIMITED_INFORMATION | SYNCHRONIZE
        if(h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"OpenProcess failed for pid "+pid);
        try {
            if(WaitForSingleObject(h,0)==0) throw new Exception("Process "+pid+" exited during the job check");
            int inJob; Check(IsProcessInJob(h,owner.Job,out inJob)); return inJob!=0;
        } finally { CloseHandle(h); }
    }
    public static void AssertOwned(Child owner,uint pid) {
        if(!InJob(owner,pid)) throw new Exception("Process "+pid+" is not in the launched child's job");
    }
    public static uint ActiveProcesses(Child owner) {
        if(owner.Job==IntPtr.Zero) throw new Exception("Owner has no job");
        JobAccounting info; Check(QueryInformationJobObject(owner.Job,1,out info,Marshal.SizeOf(typeof(JobAccounting)),IntPtr.Zero));
        return info.activeProcesses;
    }
    public static void TerminateOwned(Child child,uint code) {
        Verify(child);
        if(child.Exited) throw new Exception("Owned process already exited before termination probe");
        Check(TerminateProcess(child.Handle,code));
    }
    public static uint Buffered(Child child) { uint available; Check(PeekNamedPipe(child.OutputRead,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero)); return available; }
    // Every process on the driver's private console must be this driver or in
    // the launched child's job (the wrapper, the GUI-subsystem action child and
    // any grandchild it started). Anything else would receive the event too.
    public static void CtrlC(Child child) {
        Verify(child); var processes=new uint[256]; var count=GetConsoleProcessList(processes,256);
        if(count==0 || count>256) throw new Exception("Console process list is unavailable or too large");
        uint self=GetCurrentProcessId(); bool found=false;
        for(int i=0;i<count;i++) {
            if(processes[i]==self) continue;
            if(!InJob(child,processes[i])) throw new Exception("Foreign process "+processes[i]+" is attached to the driver's console");
            if(processes[i]==child.Pid) found=true;
        }
        if(!found) throw new Exception("CLI is not attached to the driver's console");
        Check(SetConsoleCtrlHandler(Control,true));
        // CTRL_C_EVENT is sent to this private console, never via GUI input.
        Check(GenerateConsoleCtrlEvent(0,0));
    }
    public static bool HasConsole() { return GetConsoleProcessList(new uint[1],1)!=0; }
    // The inheritable Ctrl+C-ignore attribute (SetConsoleCtrlHandler(NULL,TRUE),
    // CREATE_NEW_PROCESS_GROUP, cmd's `start /b`) passes to every child, so a
    // CTRL_C_EVENT would reach no process of the CLI under test. A real handler
    // is not inherited. Only this read-only oracle touches the PEB (the same
    // ConsoleFlags bit 0 the product's own unit test reads); the reset is the
    // documented call.
    public static bool CtrlCIgnored() {
        IntPtr parameters=Marshal.ReadIntPtr(RtlGetCurrentPeb(),4*IntPtr.Size);
        return (Marshal.ReadInt32(parameters,16+IntPtr.Size)&1)!=0;
    }
    public static void EnableCtrlC() { Check(SetConsoleCtrlHandler(null,false)); }
    public static string ConsoleText() {
        var h=FileHandle("CONOUT$",true);
        try { var text=new char[32768]; uint read; Check(ReadConsoleOutputCharacterW(h,text,(uint)text.Length,0,out read)); return new string(text,0,(int)read); }
        finally { CloseHandle(h); }
    }
    public static IntPtr[] Windows(IntPtr desktop,string className) {
        var windows=new List<IntPtr>();
        bool ok=EnumDesktopWindows(desktop,(h,p)=> { var name=new StringBuilder(256); GetClassNameW(h,name,256); if(name.ToString()==className) windows.Add(h); return true; },IntPtr.Zero);
        int error=Marshal.GetLastWin32Error();
        if(!ok && error!=0) throw new Win32Exception(error,"EnumDesktopWindows failed");
        return windows.ToArray();
    }
    public static string Title(IntPtr window) { var name=new StringBuilder(1024); GetWindowTextW(window,name,1024); return name.ToString(); }
    public static uint WindowPid(IntPtr window) { uint pid; GetWindowThreadProcessId(window,out pid); return pid; }
    // Failure-only, bounded metadata. Never capture titles, object names,
    // command lines, environment or process memory from a hung GUI.
    public static object CloseDiagnostics(Child child,IntPtr desktop,IntPtr window) {
        Verify(child);
        var windows=new List<object>();
        EnumWindow record=(h,p)=> {
            uint pid; uint tid=GetWindowThreadProcessId(h,out pid);
            if(pid==child.Pid && windows.Count<128) {
                var name=new StringBuilder(256); GetClassNameW(h,name,256);
                windows.Add(new {Hwnd=h.ToInt64(),Tid=tid,Class=name.ToString(),Visible=IsWindowVisible(h)});
            }
            return true;
        };
        EnumDesktopWindows(desktop,record,IntPtr.Zero);
        if(IsWindow(window)) EnumChildWindows(window,record,IntPtr.Zero);
        UIntPtr response;
        bool exists=IsWindow(window);
        bool? responsive=exists?(bool?)(SendMessageTimeoutW(window,0,IntPtr.Zero,IntPtr.Zero,2,250,out response)!=IntPtr.Zero):null;
        int responseError=responsive==false?Marshal.GetLastWin32Error():0;
        return new {Pid=child.Pid,Exited=child.Exited,HostExists=exists,HostVisible=IsWindowVisible(window),Responsive=responsive,ResponseError=responseError,Windows=windows};
    }
    // Hold a separate process handle until the worker finishes, even when the
    // caller times out and cleans up its Child. Synchronous WCT has no deadline.
    public static object CloseWaitChains(Child child,int timeoutMs) {
        Verify(child);
        var process=System.Diagnostics.Process.GetProcessById((int)child.Pid);
        try { var handle=process.Handle; }
        catch { process.Dispose(); throw; }
        var capture=new WaitChainCapture();
        var cancel=new CancellationTokenSource();
        var task=Task.Run(()=> {
            using(process) {
                try { CollectWaitChains(process,capture,cancel.Token,Math.Max(1,timeoutMs-1000)); }
                catch(Exception error) { capture.ErrorType=error.GetType().FullName; }
            }
        });
        bool finished=task.Wait(timeoutMs);
        if(!finished) cancel.Cancel();
        return new {TimedOut=!finished,Snapshot=capture.Snapshot()};
    }
    // The name the product gave the thread (SetThreadDescription, a source
    // literal such as "font-prefetch"), null when unset. Printable ASCII
    // only, at most 64 characters.
    static string ThreadName(IntPtr thread) {
        IntPtr text;
        if(GetThreadDescription(thread,out text)<0) return null;
        try {
            var raw=Marshal.PtrToStringUni(text);
            if(String.IsNullOrEmpty(raw)) return null;
            var name=new StringBuilder();
            foreach(char c in raw) { if(name.Length==64) break; name.Append(c>=' ' && c<='~'?c:'?'); }
            return name.ToString();
        } finally { LocalFree(text); }
    }
    sealed class WaitChainCapture {
        public readonly ConcurrentQueue<object> Chains=new ConcurrentQueue<object>();
        public volatile int SessionError,CurrentTid,TotalThreads;
        public volatile bool Truncated;
        public string ErrorType;
        public object Snapshot() { return new {SessionError,CurrentTid,TotalThreads,Truncated,ErrorType,WaitChains=Chains.ToArray()}; }
    }
    static void CollectWaitChains(System.Diagnostics.Process process,WaitChainCapture capture,CancellationToken cancel,int timeoutMs) {
        var clock=System.Diagnostics.Stopwatch.StartNew();
        var session=OpenThreadWaitChainSession(0,IntPtr.Zero);
        capture.SessionError=session==IntPtr.Zero?Marshal.GetLastWin32Error():0;
        // WAITCHAIN_NODE_INFO is two DWORD enums plus a union whose largest
        // member is WCHAR[128], LARGE_INTEGER, BOOL (272 bytes, align 8).
        IntPtr nodes=Marshal.AllocHGlobal(280*16);
        try {
            if(session!=IntPtr.Zero && !process.HasExited) {
                int sampled=0;
                var threads=process.Threads;
                capture.TotalThreads=threads.Count;
                foreach(System.Diagnostics.ProcessThread thread in threads) {
                    if(sampled++==64 || clock.ElapsedMilliseconds>=timeoutMs || cancel.IsCancellationRequested || process.HasExited) { capture.Truncated=true; break; }
                    IntPtr pinnedThread=IntPtr.Zero;
                    try {
                        capture.CurrentTid=thread.Id;
                        // Keep this TID from being recycled during a slow WCT call.
                        pinnedThread=OpenThread(0x0800,false,(uint)thread.Id);
                        Check(pinnedThread!=IntPtr.Zero);
                        if(GetProcessIdOfThread(pinnedThread)!=(uint)process.Id) throw new InvalidOperationException("Thread owner changed");
                        uint count=16; bool cycle;
                        // Out-of-process and critical-section waits. COM callbacks
                        // are not registered, so this does not claim COM coverage.
                        bool ok=GetThreadWaitChain(session,UIntPtr.Zero,5,(uint)thread.Id,ref count,nodes,out cycle);
                        int error=ok?0:Marshal.GetLastWin32Error();
                        var entries=new List<object>();
                        if(ok || error==234) for(int i=0;i<Math.Min(count,16);i++) {
                            IntPtr node=IntPtr.Add(nodes,i*280); int type=Marshal.ReadInt32(node);
                            entries.Add(new {Type=type,Status=Marshal.ReadInt32(node,4),Pid=type==8?Marshal.ReadInt32(node,8):0,Tid=type==8?Marshal.ReadInt32(node,12):0,WaitTime=type==8?Marshal.ReadInt32(node,16):0,ContextSwitches=type==8?Marshal.ReadInt32(node,20):0});
                        }
                        var entry=new Dictionary<string,object> { {"Tid",thread.Id},{"Name",ThreadName(pinnedThread)},{"Ok",ok},{"Error",error},{"Cycle",cycle},{"Nodes",entries} };
                        try {
                            var state=thread.ThreadState;
                            entry["SnapshotState"]=state.ToString();
                            entry["SnapshotWaitReason"]=state==System.Diagnostics.ThreadState.Wait?thread.WaitReason.ToString():null;
                            entry["CpuMs"]=thread.TotalProcessorTime.TotalMilliseconds;
                        } catch(Exception error2) { entry["SchedulingErrorType"]=error2.GetType().FullName; }
                        capture.Chains.Enqueue(entry);
                    } catch(Exception error) { capture.Chains.Enqueue(new {Tid=thread.Id,ErrorType=error.GetType().FullName}); }
                    finally { if(pinnedThread!=IntPtr.Zero) CloseHandle(pinnedThread); }
                }
                capture.CurrentTid=0;
            }
        } finally { Marshal.FreeHGlobal(nodes); if(session!=IntPtr.Zero) CloseThreadWaitChainSession(session); }
    }
    // The window's process must also be in the launched child's job.
    public static Child WindowProcess(IntPtr window,string image,Child owner) {
        var pid=WindowPid(window); AssertOwned(owner,pid);
        return OwnedProcess(pid,image);
    }
    public static Child OwnedProcess(uint pid,string image) {
        var h=OpenProcess(0x101001,false,pid); if(h==IntPtr.Zero) throw new Win32Exception();
        try {
            long born,exit,kernel,user; Check(GetProcessTimes(h,out born,out exit,out kernel,out user));
            var child=new Child { Handle=h,Pid=pid,Created=born,Image=Path.GetFullPath(image) }; Verify(child); return child;
        } catch { CloseHandle(h); throw; }
    }
    public static Child OwnedProcess(uint pid,string image,Child owner) {
        AssertOwned(owner,pid);
        return OwnedProcess(pid,image);
    }
}
