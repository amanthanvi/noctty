// Used only by an owned helper on a disposable hosted runner. Every clipboard
// operation follows an identity check of a newly created, unnamed station.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class DirectUpdateClipboardControl {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowStationW(string name, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll")] static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder name, int size, out int needed);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll")] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);
    public sealed class Fact {
        public bool Supported, IsolatedStation, SequenceAdvanced;
        public uint Before, After;
        public string FailedApi;
    }
    static void RequirePrivate(IntPtr station) {
        var name=new StringBuilder(256); int needed;
        if (station == IntPtr.Zero || GetProcessWindowStation() != station ||
            !GetUserObjectInformationW(station, 2, name, 512, out needed) ||
            name.Length == 0 || String.Equals(name.ToString(), "WinSta0", StringComparison.OrdinalIgnoreCase))
            throw new Exception("Private station identity check failed");
    }
    public static Fact Run() {
        // PowerShell's calling thread can already own hidden windows, which
        // makes SetThreadDesktop fail. The control owns a fresh windowless thread.
        Fact result=null;
        var thread=new System.Threading.Thread(() => { result=RunOnFreshThread(); });
        thread.Start(); thread.Join();
        return result;
    }
    static Fact RunOnFreshThread() {
        var fact=new Fact(); string stage="CreateWindowStationW";
        IntPtr oldStation=GetProcessWindowStation(), oldDesktop=GetThreadDesktop(GetCurrentThreadId());
        IntPtr station=IntPtr.Zero, desktop=IntPtr.Zero, window=IntPtr.Zero, memory=IntPtr.Zero;
        bool opened=false, switched=false, threadSwitched=false;
        try {
            station=CreateWindowStationW(null,0,0x000F037F,IntPtr.Zero);
            if(station==IntPtr.Zero) throw new Win32Exception();
            stage="SetProcessWindowStation";
            if(!SetProcessWindowStation(station)) throw new Win32Exception();
            switched=true; RequirePrivate(station); fact.IsolatedStation=true;
            stage="CreateDesktopW"; desktop=CreateDesktopW("fixture",IntPtr.Zero,IntPtr.Zero,0,0x10000000,IntPtr.Zero);
            if(desktop==IntPtr.Zero) throw new Win32Exception();
            stage="SetThreadDesktop"; if(!SetThreadDesktop(desktop)) throw new Win32Exception();
            threadSwitched=true;
            stage="CreateWindowExW";
            window=CreateWindowExW(0x08000080,"STATIC","",0x80000000,0,0,1,1,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            if(window==IntPtr.Zero) throw new Win32Exception();
            // Prepare memory before emptying even this isolated clipboard.
            stage="GlobalAlloc"; memory=GlobalAlloc(0x42,new UIntPtr(8));
            if(memory==IntPtr.Zero) throw new Win32Exception();
            IntPtr bytes=GlobalLock(memory); if(bytes==IntPtr.Zero) throw new Win32Exception();
            Marshal.Copy(new byte[]{87,0,49,0,48,0,0,0},0,bytes,8); GlobalUnlock(memory);
            RequirePrivate(station); fact.Before=GetClipboardSequenceNumber();
            stage="OpenClipboard"; RequirePrivate(station); if(!OpenClipboard(window)) throw new Win32Exception();
            opened=true;
            stage="EmptyClipboard"; RequirePrivate(station); if(!EmptyClipboard()) throw new Win32Exception();
            stage="SetClipboardData"; RequirePrivate(station); if(SetClipboardData(13,memory)==IntPtr.Zero) throw new Win32Exception();
            memory=IntPtr.Zero; RequirePrivate(station); CloseClipboard(); opened=false;
            RequirePrivate(station); fact.After=GetClipboardSequenceNumber();
            fact.SequenceAdvanced=fact.After!=fact.Before; fact.Supported=fact.SequenceAdvanced;
            if(!fact.Supported) fact.FailedApi="GetClipboardSequenceNumber";
        } catch { fact.FailedApi=stage; }
        finally {
            if(opened) { RequirePrivate(station); CloseClipboard(); }
            if(memory!=IntPtr.Zero) GlobalFree(memory);
            if(window!=IntPtr.Zero) DestroyWindow(window);
            if(switched) SetProcessWindowStation(oldStation);
            if(threadSwitched) SetThreadDesktop(oldDesktop);
            if(desktop!=IntPtr.Zero) CloseDesktop(desktop);
            if(station!=IntPtr.Zero) CloseWindowStation(station);
        }
        return fact;
    }
}
