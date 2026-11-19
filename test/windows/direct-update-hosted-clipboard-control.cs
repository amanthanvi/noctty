// Intentional fixture write after noctty has exited, ONLY on a disposable hosted
// runner. Never reads clipboard data and never runs on a developer machine.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class DirectUpdateHostedClipboardControl {
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder name, int size, out int needed);
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
    public sealed class Fact { public bool Supported, HostedWinSta0; public uint Before, After; public string FailedApi; }
    static string ObjectName(IntPtr handle) {
        var name=new StringBuilder(256); int needed;
        if(handle==IntPtr.Zero || !GetUserObjectInformationW(handle,2,name,512,out needed)) throw new Win32Exception();
        return name.ToString();
    }
    static void RequireHostedWinSta0() {
        if(!String.Equals(Environment.GetEnvironmentVariable("GITHUB_ACTIONS"),"true",StringComparison.Ordinal) ||
            !String.Equals(Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT"),"github-hosted",StringComparison.Ordinal))
            throw new Exception("Hosted-only clipboard control");
        string desktop=ObjectName(GetThreadDesktop(GetCurrentThreadId())); Guid id;
        if(!String.Equals(ObjectName(GetProcessWindowStation()),"WinSta0",StringComparison.OrdinalIgnoreCase) ||
            !desktop.StartsWith("noctty-hw-",StringComparison.Ordinal) || !Guid.TryParseExact(desktop.Substring(10),"N",out id))
            throw new Exception("Hosted private desktop identity check failed");
    }
    public static Fact Run() {
        var fact=new Fact(); string stage="HostedGate";
        IntPtr window=IntPtr.Zero, memory=IntPtr.Zero; bool opened=false;
        try {
            RequireHostedWinSta0(); fact.HostedWinSta0=true;
            stage="CreateWindowExW";
            window=CreateWindowExW(0x08000080,"STATIC","",0x80000000,0,0,1,1,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
            if(window==IntPtr.Zero) throw new Win32Exception();
            stage="GlobalAlloc"; memory=GlobalAlloc(0x42,new UIntPtr(8));
            if(memory==IntPtr.Zero) throw new Win32Exception();
            IntPtr bytes=GlobalLock(memory); if(bytes==IntPtr.Zero) throw new Win32Exception();
            Marshal.Copy(new byte[]{87,0,49,0,48,0,0,0},0,bytes,8); GlobalUnlock(memory);
            RequireHostedWinSta0(); fact.Before=GetClipboardSequenceNumber();
            stage="OpenClipboard"; RequireHostedWinSta0(); if(!OpenClipboard(window)) throw new Win32Exception(); opened=true;
            stage="EmptyClipboard"; RequireHostedWinSta0(); if(!EmptyClipboard()) throw new Win32Exception();
            stage="SetClipboardData"; RequireHostedWinSta0(); if(SetClipboardData(13,memory)==IntPtr.Zero) throw new Win32Exception();
            memory=IntPtr.Zero; RequireHostedWinSta0(); CloseClipboard(); opened=false;
            RequireHostedWinSta0(); fact.After=GetClipboardSequenceNumber();
            fact.Supported=fact.After!=fact.Before;
            if(!fact.Supported) fact.FailedApi="GetClipboardSequenceNumber";
        }catch{fact.FailedApi=stage;}
        finally {
            if(opened){RequireHostedWinSta0();CloseClipboard();}
            if(memory!=IntPtr.Zero) GlobalFree(memory);
            if(window!=IntPtr.Zero) DestroyWindow(window);
        }
        return fact;
    }
}
