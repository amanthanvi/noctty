#requires -Version 7.0
<#
Portable, hidden-desktop check of tab tear-off: `move_tab_to_new_window`, a
tab dragged out of its window, Esc during a drag, and a tab dragged onto
another window's tab strip, on the OpenGL and the Direct3D 11 backends. For
each move it checks that the tab's pane window (HWND) now belongs to the
window the tab went to, that no shell process was started or ended by the
move (the set of cmd.exe PIDs under the noctty process is unchanged) and that
the text each shell printed before the move is still in its terminal (read
through the terminal's UIA TextPattern). Closing a pane at the end is the
positive control: its shell's PID leaves the set.

Run with -Bin <source bin directory> -Run <new evidence directory>. The run
directory must not already exist. Every case is a portable copy on a private
desktop, with LOCALAPPDATA and APPDATA redirected (Invoke-LocalHiddenDriver),
`window-save-state = never` and the command pinned to cmd.exe, which keeps no
PSReadLine history. Never switches desktops, injects real input or touches
the clipboard: every action is a posted window message, and the clipboard
sequence number is checked before and after. A posted-message pass is not a
real-input pass: the system's window move (the only tab's drag) and real
pointer capture are not exercised. Results hold control geometry, PIDs,
counts and assertions only; the marker text is compared, not stored.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateSet('both','opengl','d3d11')] [string] $Renderer = 'both',
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 400,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Tt {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref Point p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h,IntPtr dc);
    [DllImport("gdi32.dll")] static extern int GetPixelFormat(IntPtr dc);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    public delegate bool EnumMonitor(IntPtr m, IntPtr dc, ref Rect r, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumMonitor cb, IntPtr p);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr m,int type,out uint x,out uint y);
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int cbSize; public Rect monitor, work; public uint flags; }
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr m, ref MonitorInfo info);
    // The pixel format of a pane's window: set by OpenGL (`SetPixelFormat`),
    // which a window keeps for good, and never by Direct3D 11.
    public static int PixelFormat(IntPtr h) {
        var dc=GetDC(h); if(dc==IntPtr.Zero) return -1;
        try { return GetPixelFormat(dc); } finally { ReleaseDC(h,dc); }
    }
    public static uint Dpi(IntPtr h) { return GetDpiForWindow(h); }
    // Every monitor: its rect (physical), DPI and work area.
    public static System.Collections.Generic.List<int[]> Monitors() {
        var list=new System.Collections.Generic.List<int[]>();
        EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr m,IntPtr dc,ref Rect r,IntPtr p)=> {
            uint x,y; GetDpiForMonitor(m,0,out x,out y);
            var info=new MonitorInfo(); info.cbSize=Marshal.SizeOf<MonitorInfo>(); GetMonitorInfoW(m,ref info);
            list.Add(new int[]{r.Left,r.Top,r.Right,r.Bottom,(int)x,info.work.Left,info.work.Top,info.work.Right,info.work.Bottom}); return true; },IntPtr.Zero);
        return list;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
    // Starts a process on the named desktop with no console window, its
    // stdout and stderr appended to `log` (STARTF_USESTDHANDLES with an
    // inheritable handle: the 2026-10-19 #497 entry in app-lifecycle.md,
    // trap 4).
    public static ProcessInfo SpawnLogged(string app,string command,string cwd,string desktop,string log) {
        var file=new System.IO.FileStream(log,System.IO.FileMode.Create,System.IO.FileAccess.Write,System.IO.FileShare.ReadWrite);
        var handle=file.SafeFileHandle.DangerousGetHandle();
        if(!SetHandleInformation(handle,1,1)) throw new Exception("SetHandleInformation failed");
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=0x101,show=0,output=handle,error=handle,input=IntPtr.Zero }; ProcessInfo pi;
        try {
            if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,true,0x08000000,IntPtr.Zero,cwd,ref si,out pi))
                throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        } finally { file.Dispose(); }
        return pi;
    }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
    // The pseudo consoles' windows `owner` owns (ConPTY's `PseudoConsoleWindow`,
    // owned through `ConptyReparentPseudoConsole`).
    public static int OwnedConsoles(IntPtr owner) {
        int n=0;
        EnumWindows((h,p)=> {
            var s=new StringBuilder(64); GetClassNameW(h,s,64);
            if(s.ToString()=="PseudoConsoleWindow" && GetWindow(h,4)==owner) n++;
            return true; },IntPtr.Zero);
        return n;
    }
    public static string Text(IntPtr h) { var sb=new StringBuilder(256); SendMessageW(h,0x0D,new IntPtr(256),sb); return sb.ToString(); }
    public static IntPtr Child(IntPtr host,int id) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(c,p)=> { if(GetDlgCtrlID(c)==id) { found=c; return false; } return true; },IntPtr.Zero);
        return found;
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static Rect RectOf(IntPtr h) { Rect r; if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed"); return r; }
    // The client area of `h` in screen coordinates.
    public static Rect ClientOnScreen(IntPtr h) {
        Rect c; if(!GetClientRect(h,out c)) throw new Exception("Client measurement failed");
        var o=new Point(); if(!ClientToScreen(h,ref o)) throw new Exception("ClientToScreen failed");
        return new Rect { Left=o.X, Top=o.Y, Right=o.X+c.Right, Bottom=o.Y+c.Bottom };
    }
    static IntPtr Pos(int x,int y) { return new IntPtr(((y&0xFFFF)<<16)|(x&0xFFFF)); }
    public static void Mouse(IntPtr h,uint msg,int x,int y,int buttons) {
        if(!PostMessageW(h,msg,new IntPtr(buttons),Pos(x,y))) throw new Exception("Mouse post failed");
    }
    public static IntPtr Owner(IntPtr h) { return GetWindow(h,4); }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint a,uint b,bool attach);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint tid);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyExW(uint code,uint type,IntPtr hkl);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ToUnicodeEx(uint vk,uint scan,byte[] state,StringBuilder buf,int n,uint flags,IntPtr hkl);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
    // When each posted key or drag ran (GetTickCount64 at its start and end),
    // set against the real keyboard's samples (modifier-sampler.c).
    public static System.Collections.Generic.List<ulong[]> Windows=new System.Collections.Generic.List<ulong[]>();
    public static void Ran(ulong start) { Windows.Add(new ulong[]{start,GetTickCount64()}); }
    // The sampler's rows (`tick,held,active`; `done,n` skipped) against the
    // posted keys' and drags' spans: the spans sorted and merged (a drag's
    // Esc key runs inside its drag), the rows sorted by tick, one sweep over
    // both. Returns the held and inactive samples inside a span; the ticks
    // of the held ones go to `heldTicks`.
    public static long[] Correlate(string[] rows,System.Collections.Generic.List<ulong> heldTicks) {
        var spans=new System.Collections.Generic.List<ulong[]>();
        foreach(var w in System.Linq.Enumerable.OrderBy(Windows,x=>x[0])) {
            if(spans.Count>0 && w[0]<=spans[spans.Count-1][1]) { if(w[1]>spans[spans.Count-1][1]) spans[spans.Count-1][1]=w[1]; }
            else spans.Add(new ulong[]{w[0],w[1]});
        }
        var samples=new System.Collections.Generic.List<ulong[]>();
        foreach(var row in rows) {
            var f=row.Split(',');
            if(f.Length!=3) continue;
            samples.Add(new ulong[]{ulong.Parse(f[0]),ulong.Parse(f[1]),ulong.Parse(f[2])});
        }
        samples.Sort((a,b)=>a[0].CompareTo(b[0]));
        long held=0, inactive=0; int at=0;
        foreach(var s in samples) {
            while(at<spans.Count && spans[at][1]<s[0]) at++;
            if(at==spans.Count) break;
            if(spans[at][0]>s[0]) continue;
            if(s[1]==1) { held++; heldTicks.Add(s[0]); }
            if(s[2]==0) inactive++;
        }
        return new long[]{held,inactive};
    }
    // Clears the keyboard state `h`'s thread reads (GetKeyState and
    // GetKeyboardState: a modifier down there turns a posted key into a
    // chord) and Caps Lock. Attaching resets that state by itself
    // (AttachThreadInput's documentation), which is the point here; for the
    // same reason a read after attaching shows nothing of what the thread
    // had, so nothing is read. A hidden desktop keeps out the user's keys,
    // not their modifiers (input.md, 2026-10-11 Win32 input mode, trap 11).
    public static void Neutralize(IntPtr h) {
        uint pid; uint tid=GetWindowThreadProcessId(h,out pid); uint me=GetCurrentThreadId();
        if(tid==0) throw new Exception("No window thread");
        if(!AttachThreadInput(me,tid,true)) throw new Exception("AttachThreadInput failed: "+Marshal.GetLastWin32Error());
        try {
            if(!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed");
        } finally { AttachThreadInput(me,tid,false); }
    }
    // A key as a posted WM_KEYDOWN/WM_KEYUP pair (a posted triple types it
    // twice), with the app's keyboard state cleared first; its window of
    // time lasts until the app is idle after it.
    public static void Key(IntPtr h,int key) {
        var start=GetTickCount64();
        uint pid; GetWindowThreadProcessId(h,out pid);
        Neutralize(h);
        if(!PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
        try { using(var p=System.Diagnostics.Process.GetProcessById((int)pid)) { p.WaitForInputIdle(2000); } } catch(Exception) { System.Threading.Thread.Sleep(300); }
        System.Threading.Thread.Sleep(50);
        Ran(start);
    }
    // What `vk` types with no modifier in the layout of `h`'s thread, or null.
    public static string Typed(IntPtr h,int vk) {
        uint pid; uint tid=GetWindowThreadProcessId(h,out pid); var hkl=GetKeyboardLayout(tid);
        var sb=new StringBuilder(8);
        int n=ToUnicodeEx((uint)vk,MapVirtualKeyExW((uint)vk,0,hkl),new byte[256],sb,8,4,hkl);
        return n>0 ? sb.ToString(0,n) : null;
    }
}
'@
if (-not $Driver) {
    try {
        Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
            -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
            -DesktopPrefix 'noctty-tearoff-' -Label 'Hidden tab tear-off' -PassDesktopName -GuardClipboard `
            -DriverArguments @("-Renderer $Renderer")
    } finally {
        # The driver's job has stopped by now, every console helper with it:
        # a dump a helper that would not exit left (its marker text) goes.
        $evidence=[IO.Path]::GetFullPath($Run)
        if(Test-Path -LiteralPath $evidence) {
            Get-ChildItem -LiteralPath $evidence -Filter 'attach-*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Tt]::SetThreadDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
# Cases that could not run here: reported, never counted as passes.
$script:skips=[Collections.Generic.List[string]]::new()
# What the run could not measure: reported, never counted as passes.
$script:unverified=[Collections.Generic.List[string]]::new()
$script:sampler=$null
$script:processes=[Collections.Generic.List[object]]::new()
# Each launch's process handle, kept until the final check (a PID may be
# reused once its process is gone).
$script:launches=[Collections.Generic.List[IntPtr]]::new()
$desktopPath="WinSta0\$DesktopName"
$runClass='noctty-test-tearoff-' + [guid]::NewGuid().ToString('N').Substring(0,8)
# Tab buttons are 1000 + their index (src/apprt/win32/host.zig).
$TabButton=1000
$WM_MOUSEMOVE=0x200; $WM_LBUTTONDOWN=0x201; $WM_LBUTTONUP=0x202
$VK_F6=0x75; $VK_F7=0x76; $VK_F9=0x78; $VK_ESCAPE=0x1B

function Launch-Case([string]$Name,[string]$RendererName,[string[]]$Extra=@()) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    $config=Join-Path $dir 'case.ghostty'
    # cmd.exe, which keeps no PSReadLine history, prints a marker of its own
    # (`%RANDOM%`, which cmd expands) for the move to keep. `direct:` with the
    # System32 path: a shell string runs under Exec's outer `cmd /c`, whose
    # AutoRun hooks an inner /D does not turn off (test-harnesses.md).
    $cmd=Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    @("working-directory = $dir",'single-instance = false','window-save-state = never',
      'copy-on-select = false','clipboard-read = deny','clipboard-write = deny',
      'confirm-close-surface = false','shell-integration = none',
      "command = direct:$cmd /d /k echo TEAROFF-%RANDOM%-%RANDOM%-%RANDOM%",
      "renderer = $RendererName",
      'keybind = f6=new_tab','keybind = f7=move_tab_to_new_window','keybind = f9=close_surface') + $Extra | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    $log=Join-Path (Split-Path -Parent $dir) 'case.log'
    # The backend proof reads the log from stderr: pin the destination for
    # the child (GHOSTTY_LOG), put the caller's back after, print neither.
    $hadLog=Test-Path Env:GHOSTTY_LOG; $oldLog=$env:GHOSTTY_LOG
    $env:GHOSTTY_LOG='stderr'
    try {
        $pi=[Tt]::SpawnLogged($exe,('"{0}" --config-file="{1}" --single-instance=false --window-save-state=never --class={2}' -f $exe,$config,$runClass),$dir,$desktopPath,$log)
    } finally {
        if($hadLog) { $env:GHOSTTY_LOG=$oldLog } else { Remove-Item Env:GHOSTTY_LOG -ErrorAction SilentlyContinue }
    }
    $script:processes.Add(@{Case=$Name;Pid=$pi.pid}); $script:launches.Add($pi.process)
    $deadline=[datetime]::UtcNow.AddSeconds(25)
    do {
        $hosts=@([HiddenLocal]::Hosts($pi.pid))
        $ready=$false
        $ledger=Join-Path $dir 'startup-attempts.json'
        if(Test-Path -LiteralPath $ledger) {
            try {
                $attempts=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready=$attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if($ready -and $hosts.Count -and @([HiddenLocal]::Surfaces($hosts[0])).Count -gt 0) {
            [void][Tt]::ShowWindow($hosts[0],4)
            [void][Tt]::SetWindowPos($hosts[0],[IntPtr]::Zero,40,40,900,600,0x14)
            Start-Sleep -Milliseconds 1500
            return @{Pi=$pi; Pid=$pi.pid; Dir=$dir; Log=$log}
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline)
    Close-Case @{Pi=$pi; Pid=$pi.pid}
    throw "Window startup failed for case $Name."
}
function Close-Case($case) {
    foreach($h in [HiddenLocal]::Hosts($case.Pid)) { [void][Tt]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if([HiddenLocal]::WaitForSingleObject($case.Pi.process,5000) -eq 258) {
        # The handle is this launch's own process: no name or pattern match.
        [void][HiddenLocal]::TerminateProcess($case.Pi.process,1)
        [void][HiddenLocal]::WaitForSingleObject($case.Pi.process,5000)
    }
    # The process handle stays open for the final check.
    [void][HiddenLocal]::CloseHandle($case.Pi.thread)
}
# The cmd.exe processes under the case's noctty process: PIDs only. A child
# counts only if it started after its parent: a process whose parent's PID
# was reused names the new owner of that PID (the root's PID is held by its
# open handle, so it is the case's).
function Shell-Pids($case) {
    $all=@(Get-CimInstance Win32_Process -OperationTimeoutSec 5 | Select-Object ProcessId, ParentProcessId, Name, CreationDate)
    $byParent=@{}; $created=@{}
    foreach($p in $all) { $created[[int]$p.ProcessId]=$p.CreationDate }
    foreach($p in $all) { $k=[int]$p.ParentProcessId; if(-not $byParent.ContainsKey($k)) { $byParent[$k]=[Collections.Generic.List[object]]::new() }; $byParent[$k].Add($p) }
    $found=[Collections.Generic.List[int]]::new(); $queue=[Collections.Generic.Queue[int]]::new(); $queue.Enqueue([int]$case.Pid)
    $seen=[Collections.Generic.HashSet[int]]::new(); [void]$seen.Add([int]$case.Pid)
    while($queue.Count) {
        $parent=$queue.Dequeue()
        if(-not $byParent.ContainsKey($parent)) { continue }
        foreach($child in $byParent[$parent]) {
            $id=[int]$child.ProcessId
            if($null -eq $child.CreationDate -or $null -eq $created[$parent] -or $child.CreationDate -lt $created[$parent]) { continue }
            if(-not $seen.Add($id)) { continue }
            if($child.Name -ieq 'cmd.exe') { $found.Add($id); $script:shellParents[$id]=[int]$child.ParentProcessId }
            $queue.Enqueue($id)
        }
    }
    return @($found | Sort-Object)
}
$script:shellParents=@{}
# No outer `cmd /c` wrapper (whose AutoRun hooks an inner /D would not stop):
# every shell's parent is the noctty process itself.
function Shells-Direct($case) {
    $pids=Shell-Pids $case
    foreach($id in $pids) { if($script:shellParents[$id] -ne [int]$case.Pid) { return $false } }
    return $pids.Count -gt 0
}
# The backend each pane draws with, from what the process and the pane's
# window show: OpenGL sets a pixel format on the pane's window and loads
# opengl32.dll; Direct3D 11 does neither (OpenGL32 is loaded lazily, the
# 2026-10-17 entry in renderer.md) and loads d3d11.dll. A fallback from one
# to the other shows as the other's marks.
function Loaded($case,[string]$Module) {
    $p=[Diagnostics.Process]::GetProcessById([int]$case.Pid)
    try { return @($p.Modules | Where-Object { $_.ModuleName -ieq $Module }).Count -gt 0 } finally { $p.Dispose() }
}
# How many renderer log lines of each kind the case wrote
# (src/renderer/Windows.zig): a Direct3D 11 pane's start, and every startup
# or draw-time fallback between the backends.
function Renderer-Lines($case) {
    $text=''
    try {
        $fs=[IO.FileStream]::new($case.Log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try { $text=[IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
    } catch { }
    $lines=@($text -split "`r?`n")
    return @{
        Lines=$lines.Count
        D3D11Started=@($lines | Where-Object { $_ -match 'D3D11 beta: hardware renderer active|D3D11 WARP \(software\)' }).Count
        Fallbacks=@($lines | Where-Object { $_ -match 'OpenGL: switched from D3D11|OpenGL could not start, so noctty switched|OpenGL startup failed|d3d11(-warp)? startup failed|OpenGL: D3D11 (startup failed|beta does not support)|trying OpenGL on next draw|D3D11 does not support terminal images' }).Count
    }
}
# opengl32.dll is loaded only by OpenGL (lazily: the 2026-10-17 entry in
# renderer.md); d3d11.dll is loaded in both modes, so it proves nothing.
function Backend-Holds($case,[string]$RendererName,[int]$Panes) {
    $gl=Loaded $case 'opengl32.dll'
    $r=Renderer-Lines $case
    $evidence=@{ OpenGL32=$gl; D3D11Started=$r.D3D11Started; Fallbacks=$r.Fallbacks; LogLines=$r.Lines; Panes=$Panes }
    if($RendererName -eq 'opengl') {
        $evidence.Holds=($r.Lines -gt 1 -and $gl -and $r.D3D11Started -eq 0 -and $r.Fallbacks -eq 0)
    } else {
        $evidence.Holds=($r.Lines -gt 1 -and -not $gl -and $r.D3D11Started -ge $Panes -and $r.Fallbacks -eq 0)
    }
    return $evidence
}
function Check-Backend($case,[string]$RendererName,[string]$When,[IntPtr[]]$Panes) {
    $b=Backend-Holds $case $RendererName $Panes.Count
    Check "${RendererName} ${When}: every pane still draws with $RendererName (no fallback)" $b.Holds $RendererName $b
}
# The terminal's text through its UIA TextPattern, and the marker in it.
function Marker([IntPtr]$Pane) {
    $element=[System.Windows.Automation.AutomationElement]::FromHandle($Pane)
    $pattern=$null
    if(-not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$pattern)) { return $null }
    $text=$pattern.DocumentRange.GetText(-1)
    $m=[regex]::Match($text,'TEAROFF-\d+-\d+-\d+')
    if($m.Success) { return $m.Value } else { return $null }
}
function Wait-Marker([IntPtr]$Pane) {
    $value=$null
    [void](Wait-Until { $script:found=Marker $Pane; $null -ne $script:found } 10)
    return $script:found
}
function Hosts($case) { return @([HiddenLocal]::Hosts($case.Pid)) }
function Panes([IntPtr]$h) { return @([HiddenLocal]::Surfaces($h)) }
function HostOf($case,[IntPtr]$Pane) {
    foreach($h in Hosts $case) { if((Panes $h) -contains $Pane) { return $h } }
    return [IntPtr]::Zero
}
function New-Pane($case,[IntPtr]$From) {
    $before=@(foreach($h in Hosts $case) { Panes $h })
    [Tt]::Key($From,$VK_F6)
    [void](Wait-Until { @(foreach($h in Hosts $case) { Panes $h }).Count -gt $before.Count } 10)
    $after=@(foreach($h in Hosts $case) { Panes $h })
    $new=@($after | Where-Object { $before -notcontains $_ })
    if($new.Count -ne 1) { throw 'new_tab made no pane.' }
    return $new[0]
}
# A drag of the tab button `index` of `host` from (20, 10) to screen point (x, y), posted.
function Drag($h,[int]$Index,[int]$X,[int]$Y,[switch]$Escape,[IntPtr]$EscapeTo) {
    $button=[Tt]::Child($h,$TabButton+$Index)
    if($button -eq [IntPtr]::Zero) { throw "No tab button $Index." }
    # No modifier down for the drag either (a Ctrl or Shift drag is not one).
    $started=[Tt]::GetTickCount64()
    [Tt]::Neutralize($button)
    $origin=[Tt]::RectOf($button)
    [Tt]::Mouse($button,$WM_MOUSEMOVE,20,10,0)
    [Tt]::Mouse($button,$WM_LBUTTONDOWN,20,10,1)
    [Tt]::Mouse($button,$WM_MOUSEMOVE,40,40,1)
    [Tt]::Mouse($button,$WM_MOUSEMOVE,$X-$origin.Left,$Y-$origin.Top,1)
    Start-Sleep -Milliseconds 300
    if($Escape) { [Tt]::Key($EscapeTo,$VK_ESCAPE); Start-Sleep -Milliseconds 200 }
    [Tt]::Mouse($button,$WM_LBUTTONUP,$X-$origin.Left,$Y-$origin.Top,0)
    Start-Sleep -Milliseconds 100
    [Tt]::Ran($started)
}
function Same-Set($a,$b) { return (@($a) -join ',') -eq (@($b) -join ',') }
# Each window owns the pseudo console of each of its panes: a moved pane's
# console window follows it (`Pty.reparentPseudoConsole`). Per pane: a helper
# attaches to each shell's console and reads its window handle and its rows
# (console-attach-info.c); the shell whose rows hold a pane's marker is that
# pane's, and its console window's owner must be the pane's window. The rows
# are compared here and their file deleted, never kept.
function Pane-Consoles($case) {
    $byMarker=@{}
    foreach($id in Shell-Pids $case) {
        $out=Join-Path $Run ('attach-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
        $pi=[Tt]::SpawnLogged($script:attachExe,('"{0}" {1} "{2}" window-dump' -f $script:attachExe,$id,$out),$Run,$desktopPath,"$out.log")
        $exited=$false
        try {
            $done=[HiddenLocal]::WaitForSingleObject($pi.process,10000) -eq 0
            $exited=$done
            if(-not $done) {
                # Past its time: ended through its own handle, never by name,
                # and gone before its dump is deleted, so it cannot write the
                # file again after.
                [void][HiddenLocal]::TerminateProcess($pi.process,1)
                $exited=[HiddenLocal]::WaitForSingleObject($pi.process,5000) -eq 0
            }
        } finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
        # One that would not exit could write its dump again: the outer run
        # deletes it once the driver's job has stopped (the `-not $Driver`
        # branch above).
        if(-not $exited) { throw "Console helper $($pi.pid) did not exit." }
        try {
            $lines=if($done -and (Test-Path -LiteralPath $out)) { @(Get-Content -LiteralPath $out) } else { @() }
        } finally { Remove-Item -LiteralPath $out,"$out.log" -ErrorAction SilentlyContinue }
        if($lines.Count -lt 2) { continue }
        $m=[regex]::Match((@($lines | Select-Object -Skip 2) -join "`n"),'TEAROFF-\d+-\d+-\d+')
        if(-not $m.Success) { continue }
        # A marker two consoles show maps to neither: their panes are then
        # not found, never folded into one entry.
        if($byMarker.ContainsKey($m.Value)) { $byMarker[$m.Value]=[IntPtr]::Zero } else { $byMarker[$m.Value]=[IntPtr][long]$lines[1] }
    }
    $rows=@(foreach($owner in Hosts $case) {
        foreach($p in Panes $owner) {
            $marker=Marker $p
            $console=if($null -ne $marker -and $byMarker.ContainsKey($marker)) { $byMarker[$marker] } else { [IntPtr]::Zero }
            @{ Pane=[long]$p; Window=[long]$owner; Found=($console -ne [IntPtr]::Zero); Owned=($console -ne [IntPtr]::Zero -and [Tt]::Owner($console) -eq $owner) }
        }
    })
    return @{ Holds=($rows.Count -gt 0 -and @($rows | Where-Object { -not $_.Owned }).Count -eq 0); Rows=$rows }
}
function Consoles-Follow($case) {
    $counts=@(foreach($h in Hosts $case) { @{ Owned=[Tt]::OwnedConsoles($h); Panes=(Panes $h).Count } })
    $each=Pane-Consoles $case
    return @{ Holds=($each.Holds -and @($counts | Where-Object { $_.Owned -ne $_.Panes }).Count -eq 0); Counts=$counts; Panes=$each.Rows }
}
# The work area of the monitor under the middle of `h`: left, top, right, bottom.
function Work-Area([IntPtr]$h) {
    $r=[Tt]::RectOf($h); $x=[int](($r.Left+$r.Right)/2); $y=[int](($r.Top+$r.Bottom)/2)
    foreach($m in [Tt]::Monitors()) { if($m[0] -le $x -and $x -lt $m[2] -and $m[1] -le $y -and $y -lt $m[3]) { return @($m[5],$m[6],$m[7],$m[8]) } }
    $m=@([Tt]::Monitors())[0]; return @($m[5],$m[6],$m[7],$m[8])
}

function Measure-Case([string]$RendererName) {
    $case=Launch-Case "tearoff-$RendererName" $RendererName
    $sample=@{ Renderer=$RendererName }
    try {
        $h1=(Hosts $case)[0]
        $p1=(Panes $h1)[0]
        $p2=New-Pane $case $p1
        $m1=Wait-Marker $p1; $m2=Wait-Marker $p2
        Check "${RendererName}: each shell printed its marker" ($null -ne $m1 -and $null -ne $m2 -and $m1 -ne $m2) 'two markers' @{One=($null -ne $m1);Two=($null -ne $m2)}
        # Compare PID sets, never a count per pane: a shell may start helpers.
        [void](Wait-Until { (Shell-Pids $case).Count -ge 2 } 10)
        Start-Sleep -Milliseconds 500
        $pids=Shell-Pids $case
        Check "${RendererName}: the shells run" ($pids.Count -ge 2) '>= 2' $pids.Count
        $owners=Consoles-Follow $case
        Check "${RendererName}: the window owns its panes' console windows (the control)" ($owners.Holds -and $owners.Counts[0].Owned -eq 2 -and @($owners.Panes | Where-Object { $_.Found }).Count -eq 2) 'owned = panes = 2, each found' $owners
        Check "${RendererName}: the shells run with no outer cmd wrapper" (Shells-Direct $case) 'parent is noctty' $null
        Check-Backend $case $RendererName 'before the moves' @($p1,$p2)

        # 1. move_tab_to_new_window from the keyboard.
        [Tt]::Key($p2,$VK_F7)
        # The new window exists before the tab is in it: wait for the pane.
        $moved=Wait-Until { $o=HostOf $case $p2; $o -ne [IntPtr]::Zero -and $o -ne $h1 } 10
        Start-Sleep -Milliseconds 300
        $h2=HostOf $case $p2
        Check "${RendererName} action: a second window opens" $moved 2 (Hosts $case).Count
        Check "${RendererName} action: the tab's pane window is now the new window's" ($h2 -ne [IntPtr]::Zero -and $h2 -ne $h1 -and [Tt]::GetParent($p2) -eq $h2) 'child of the new window' $null
        Check "${RendererName} action: the window it left keeps its other tab" ((Panes $h1).Count -eq 1 -and (Panes $h1)[0] -eq $p1) 1 (Panes $h1).Count
        Check "${RendererName} action: the new window and the moved pane show" ($h2 -ne [IntPtr]::Zero -and [Tt]::Visible($h2) -and [Tt]::Visible($p2)) $true $null
        $after=Shell-Pids $case
        Check "${RendererName} action: no shell started or ended" (Same-Set $pids $after) ($pids -join ',') ($after -join ',')
        Check "${RendererName} action: the moved shell's output is still there" ($null -ne $m2 -and (Marker $p2) -eq $m2) 'same, non-null marker' $null
        Check-Backend $case $RendererName 'after the action' @($p1,$p2)
        $owners=Consoles-Follow $case
        Check "${RendererName} action: each window owns its panes' console windows" $owners.Holds 'each pane''s console owned by its window' $owners

        # 2. A drag out of the window, to the right of it: a new window there.
        $p3=New-Pane $case $p1
        $m3=Wait-Marker $p3
        Check "${RendererName} drag: the dragged shell printed its marker first" ($null -ne $m3) 'a marker' $null
        [void](Wait-Until { (Shell-Pids $case).Count -gt $pids.Count } 10)
        Start-Sleep -Milliseconds 500
        $pids=Shell-Pids $case
        # The drop lands on screen, to the right of the window: narrowed
        # first when the monitor leaves no room (a new window is held to the
        # work area, and would then not be under a drop past it).
        $r1=[Tt]::RectOf($h1); $work=Work-Area $h1
        if($r1.Right+120+300 -gt $work[2]) {
            [void][Tt]::SetWindowPos($h1,[IntPtr]::Zero,$work[0]+20,$r1.Top,[Math]::Max(420,$work[2]-$work[0]-460),$r1.Bottom-$r1.Top,0x14)
            Start-Sleep -Milliseconds 500
            $r1=[Tt]::RectOf($h1)
        }
        $dropX=$r1.Right+120; $dropY=$r1.Top+80
        $sample.WorkArea=$work
        Check "${RendererName} drag: the drop point is on screen, past the window" ($dropX -lt $work[2] -and $dropY -lt $work[3]) @($work[2],$work[3]) @($dropX,$dropY)
        Drag $h1 1 $dropX $dropY
        $torn=Wait-Until { $o=HostOf $case $p3; $o -ne [IntPtr]::Zero -and $o -ne $h1 } 10
        Start-Sleep -Milliseconds 300
        $h3=HostOf $case $p3
        Check "${RendererName} drag: a third window opens" $torn 3 (Hosts $case).Count
        Check "${RendererName} drag: the dragged tab's pane is the new window's" ($h3 -ne [IntPtr]::Zero -and $h3 -ne $h1 -and $h3 -ne $h2 -and [Tt]::GetParent($p3) -eq $h3) 'child of the new window' $null
        if($h3 -ne [IntPtr]::Zero) {
            $r3=[Tt]::RectOf($h3)
            $sample.DropPoint=@($dropX,$dropY); $sample.TornRect=@($r3.Left,$r3.Top,$r3.Right,$r3.Bottom)
            Check "${RendererName} drag: the new window is under the drop point" ($r3.Left -le $dropX -and $dropX -lt $r3.Right -and $r3.Top -le $dropY -and $dropY -lt $r3.Bottom) @($dropX,$dropY) $sample.TornRect
        }
        $after=Shell-Pids $case
        Check "${RendererName} drag: no shell started or ended" (Same-Set $pids $after) ($pids -join ',') ($after -join ',')
        Check "${RendererName} drag: the moved shell's output is still there" ($null -ne $m3 -and (Marker $p3) -eq $m3) 'same, non-null marker' $null
        Check-Backend $case $RendererName 'after the drag' @($p1,$p2,$p3)
        $owners=Consoles-Follow $case
        Check "${RendererName} drag: each window owns its panes' console windows" $owners.Holds 'each pane''s console owned by its window' $owners

        # 3. Esc during a drag: nothing moves.
        $p4=New-Pane $case $p1
        $m4=Wait-Marker $p4
        Check "${RendererName} drop: the dropped shell printed its marker first" ($null -ne $m4) 'a marker' $null
        [void](Wait-Until { (Shell-Pids $case).Count -gt $pids.Count } 10)
        Start-Sleep -Milliseconds 500
        $pids=Shell-Pids $case
        Drag $h1 1 $dropX ($dropY+200) -Escape -EscapeTo $p4
        Start-Sleep -Milliseconds 800
        Check "${RendererName} Esc: no window opens" ((Hosts $case).Count -eq 3) 3 (Hosts $case).Count
        Check "${RendererName} Esc: the tab stays" ((HostOf $case $p4) -eq $h1 -and (Panes $h1).Count -eq 2) 'two panes in the first window' (Panes $h1).Count

        # 4. A drag onto another window's tab strip: the tab moves there.
        # The windows side by side, so neither covers the other's strip.
        [void][Tt]::SetWindowPos($h3,[IntPtr]::Zero,$r1.Right+60,$r1.Top,700,500,0x14)
        # The action's window, out of the way of both strips.
        [void][Tt]::SetWindowPos($h2,[IntPtr]::Zero,$r1.Left,$r1.Bottom+60,600,400,0x14)
        Start-Sleep -Milliseconds 500
        $c3=[Tt]::ClientOnScreen($h3)
        $stripX=$c3.Left+12; $stripY=$c3.Top+12
        Drag $h1 1 $stripX $stripY
        $joined=Wait-Until { (HostOf $case $p4) -eq $h3 } 10
        Check "${RendererName} drop: the tab joins the other window" $joined 'in the third window' $null
        Check "${RendererName} drop: no window opened or closed" ((Hosts $case).Count -eq 3) 3 (Hosts $case).Count
        Check "${RendererName} drop: the target window has both tabs, the source one" ((Panes $h3).Count -eq 2 -and (Panes $h1).Count -eq 1) '2 and 1' @{Target=(Panes $h3).Count;Source=(Panes $h1).Count}
        $after=Shell-Pids $case
        Check "${RendererName} drop: no shell started or ended" (Same-Set $pids $after) ($pids -join ',') ($after -join ',')
        Check "${RendererName} drop: the moved shell's output is still there" ($null -ne $m4 -and (Marker $p4) -eq $m4) 'same, non-null marker' $null
        # cmd's `%RANDOM%` gives no guarantee: each pane's marker is checked
        # to be its own, since the console owner map keys on it.
        Check "${RendererName}: every pane's marker is its own" (@($m1,$m2,$m3,$m4 | Where-Object { $null -ne $_ } | Sort-Object -Unique).Count -eq 4) 4 @($m1,$m2,$m3,$m4 | Where-Object { $null -ne $_ } | Sort-Object -Unique).Count
        Check "${RendererName}: every moved shell kept its output" ($null -ne $m1 -and $null -ne $m2 -and $null -ne $m3 -and $null -ne $m4 -and (Marker $p1) -eq $m1 -and (Marker $p2) -eq $m2 -and (Marker $p3) -eq $m3 -and (Marker $p4) -eq $m4) 'same, non-null markers' $null
        Check-Backend $case $RendererName 'after the drop' @($p1,$p2,$p3,$p4)
        $owners=Consoles-Follow $case
        Check "${RendererName} drop: each window owns its panes' console windows" $owners.Holds 'each pane''s console owned by its window' $owners

        # Positive control: closing a pane ends its shell, which the PID set
        # shows, so an unchanged set above is a measurement.
        $before=Shell-Pids $case
        [Tt]::Key($p4,$VK_F9)
        $ended=Wait-Until { (Shell-Pids $case).Count -lt $before.Count } 10
        Check "${RendererName} control: closing a pane ends its shell" $ended ("< " + $before.Count) (Shell-Pids $case).Count
        Check "${RendererName}: the process is still running" ([HiddenLocal]::WaitForSingleObject($case.Pi.process,0) -eq 258) $true $null
        $sample.ShellCount=(Shell-Pids $case).Count
    } finally {
        $script:samples.Add($sample)
        Close-Case $case
    }
}

# A pane whose search bar is open moves to a new window, the window it left
# closes, and the search box still takes typing: its controls named the old
# window and read it after it was freed (council round 1, 0xC0000005).
function Measure-Search([string]$RendererName) {
    $case=Launch-Case "search-$RendererName" $RendererName @('keybind = f8=start_search')
    try {
        $h1=(Hosts $case)[0]
        $p1=(Panes $h1)[0]
        $p2=New-Pane $case $p1
        [void](Wait-Marker $p2)
        [Tt]::Key($p2,0x77)   # F8: start_search
        $opened=Wait-Until { $e=[Tt]::Child($h1,2101); $e -ne [IntPtr]::Zero -and [Tt]::Visible($e) } 5
        Check "${RendererName} search: the search bar opens" $opened 'shown' $null
        $edit=[Tt]::Child($h1,2101)
        [Tt]::Key($p2,$VK_F7)
        $moved=Wait-Until { $o=HostOf $case $p2; $o -ne [IntPtr]::Zero -and $o -ne $h1 } 10
        Check "${RendererName} search: the tab with the search bar moves" $moved 'a new window' $null
        $h2=HostOf $case $p2
        Check "${RendererName} search: the search box went with it" ($edit -ne [IntPtr]::Zero -and [Tt]::GetParent($edit) -eq $h2) 'child of the new window' $null
        [void][Tt]::PostMessageW($h1,0x10,[IntPtr]::Zero,[IntPtr]::Zero)   # WM_CLOSE: the old window goes
        $closed=Wait-Until { -not [Tt]::Alive($h1) } 10
        Check "${RendererName} search: the window it left closes" $closed 'closed' $null
        Start-Sleep -Milliseconds 500
        # What the X key types in the app's own layout (not always `x`).
        $expect=[Tt]::Typed($edit,0x58)
        [Tt]::Key($edit,0x58)   # X, typed into the moved search box
        Start-Sleep -Milliseconds 800
        $alive=[HiddenLocal]::WaitForSingleObject($case.Pi.process,0) -eq 258
        Check "${RendererName} search: the process stays up as the moved search box is typed into" $alive 'running' $null
        if($null -eq $expect) {
            $script:skips.Add("${RendererName} search: the X key types nothing by itself in this layout")
        } else {
            $typed=$alive -and ([Tt]::Text($edit)).Contains($expect)
            Check "${RendererName} search: the moved search box takes the typing" $typed 'the layout''s character for X' $null
        }
    } finally { Close-Case $case }
}

# A tab torn off onto a monitor of another DPI keeps the size its source has
# there, with `window-width`/`window-height` set, which make the core ask for
# its window's size again when the pane's font changes with the DPI
# (`recomputeInitialSize`). The source is resized by hand first, so its size
# is not the configured one either.
# `Direction` 'down' tears off from the highest-DPI monitor onto a lower one,
# 'up' from a lower one onto the highest.
function Measure-CrossDpi([string]$RendererName,[ValidateSet('down','up')][string]$Direction) {
    $monitors=@([Tt]::Monitors() | Where-Object { $_[4] -gt 0 })
    $high=@($monitors | Sort-Object { -$_[4] })[0]
    $low=@($monitors | Where-Object { $_[4] -lt $high[4] } | Select-Object -First 1)
    if(-not $low.Count) {
        $script:skips.Add("${RendererName} cross-DPI ${Direction}: no monitor of another DPI")
        return
    }
    $low=$low[0]
    $from=if($Direction -eq 'down') { $high } else { $low }
    $m=if($Direction -eq 'down') { $low } else { $high }
    $case=Launch-Case "crossdpi-$Direction-$RendererName" $RendererName @('window-width = 90','window-height = 26')
    $sample=@{ Renderer=$RendererName; Case='cross-dpi'; Direction=$Direction }
    try {
        $h1=(Hosts $case)[0]
        $p1=(Panes $h1)[0]
        $p2=New-Pane $case $p1
        [void](Wait-Marker $p2)
        # Resized by hand, on the monitor it tears off from: twice, since the
        # first move onto another DPI takes Windows' rescaled suggestion.
        $w=if($from[4] -ge 144) { 1500 } else { 1000 }; $ht=if($from[4] -ge 144) { 950 } else { 640 }
        foreach($i in 1..2) { [void][Tt]::SetWindowPos($h1,[IntPtr]::Zero,$from[5]+60,$from[6]+60,$w,$ht,0x14); Start-Sleep -Milliseconds 600 }
        $sourceDpi=[int][Tt]::Dpi($h1)
        $sample.SourceDpi=$sourceDpi; $sample.Monitors=@($monitors | ForEach-Object { ,@($_) })
        $r1=[Tt]::RectOf($h1)
        $dropX=$m[0]+200; $dropY=$m[1]+160
        Drag $h1 1 $dropX $dropY
        $torn=Wait-Until { $o=HostOf $case $p2; $o -ne [IntPtr]::Zero -and $o -ne $h1 } 10
        Check "${RendererName} cross-DPI ${Direction}: the tab tears off onto the other monitor" $torn 'a new window' $null
        if(-not $torn) { return }
        $h2=HostOf $case $p2
        Start-Sleep -Milliseconds 1500
        $r2=[Tt]::RectOf($h2)
        $targetDpi=[int][Tt]::Dpi($h2)
        $ew=[int][Math]::Round(($r1.Right-$r1.Left)*$targetDpi/$sourceDpi); $eh=[int][Math]::Round(($r1.Bottom-$r1.Top)*$targetDpi/$sourceDpi)
        # Held to the work area there, as `placeTearOff` holds it.
        $ew=[Math]::Min($ew,$m[7]-$m[5]); $eh=[Math]::Min($eh,$m[8]-$m[6])
        $w=$r2.Right-$r2.Left; $hgt=$r2.Bottom-$r2.Top
        $sample.TargetDpi=$targetDpi; $sample.SourceRect=@($r1.Left,$r1.Top,$r1.Right,$r1.Bottom); $sample.TornRect=@($r2.Left,$r2.Top,$r2.Right,$r2.Bottom); $sample.Expected=@($ew,$eh)
        Check "${RendererName} cross-DPI ${Direction}: the new window is on a monitor of another DPI" ($targetDpi -ne $sourceDpi) "not $sourceDpi" $targetDpi
        Check "${RendererName} cross-DPI ${Direction}: it keeps its source's size there, not the configured grid's" ([Math]::Abs($w-$ew) -le 2 -and [Math]::Abs($hgt-$eh) -le 2) @($ew,$eh) @($w,$hgt)
        # Under the pointer, within the top band of the new window (its tab).
        $band=[int][Math]::Round(80*$targetDpi/96)
        Check "${RendererName} cross-DPI ${Direction}: the pointer is on the new window's tab row" ($r2.Left -le $dropX -and $dropX -lt $r2.Right -and $r2.Top -le $dropY -and $dropY -lt ($r2.Top+$band)) @($dropX,$dropY) @($r2.Left,$r2.Top,$r2.Right,$r2.Bottom)
        Start-Sleep -Milliseconds 1000
        $r3=[Tt]::RectOf($h2)
        Check "${RendererName} cross-DPI ${Direction}: and keeps it a moment later" (($r3.Right-$r3.Left) -eq $w -and ($r3.Bottom-$r3.Top) -eq $hgt) @($w,$hgt) @(($r3.Right-$r3.Left),($r3.Bottom-$r3.Top))
        Check-Backend $case $RendererName 'after the cross-DPI tear-off' @($p1,$p2)
    } finally {
        $script:samples.Add($sample)
        Close-Case $case
    }
}

try {
    # The console helper and the real keyboard's sampler, built here once
    # (dev-windows.cmd; no console of their own, CREATE_NO_WINDOW).
    $root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:attachExe=Join-Path $Run 'console-attach-info.exe'
    $samplerExe=Join-Path $Run 'modifier-sampler.exe'
    $compile=Join-Path $Run 'helpers.cmd'
    $lines=@('@echo off')
    foreach($helper in @(@('console-attach-info',$script:attachExe),@('modifier-sampler',$samplerExe))) {
        $lines+=('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" || exit /b 1' -f
            (Join-Path $root 'scripts\dev-windows.cmd'),(Join-Path $PSScriptRoot ($helper[0] + '.c')),$helper[1],(Join-Path $Run ($helper[0] + '.obj')))
    }
    $lines+='exit /b 0'
    $lines | Set-Content -LiteralPath $compile -Encoding ascii
    $cp=[Tt]::SpawnLogged($env:ComSpec,('"{0}" /d /c ""{1}""' -f $env:ComSpec,$compile),$Run,$desktopPath,(Join-Path $Run 'helpers.compile.log'))
    try {
        if([HiddenLocal]::WaitForSingleObject($cp.process,240000) -ne 0) { throw 'Helper compile timed out.' }
        [uint32]$code=1; [void][HiddenLocal]::GetExitCodeProcess($cp.process,[ref]$code)
    } finally { [void][HiddenLocal]::CloseHandle($cp.thread); [void][HiddenLocal]::CloseHandle($cp.process) }
    if($code -ne 0 -or -not (Test-Path -LiteralPath $script:attachExe) -or -not (Test-Path -LiteralPath $samplerExe)) { throw 'Helper compile failed.' }
    # The sampler runs on the user's desktop, the one whose keyboard
    # GetAsyncKeyState reads (it reads 0 from this one): no window, no
    # foreground, only whether a modifier is down.
    $samplerOut=Join-Path $Run 'modifier-samples.txt'; $samplerStop=Join-Path $Run 'modifier-sampler.stop'
    $script:sampler=[Tt]::SpawnLogged($samplerExe,('"{0}" "{1}" "{2}"' -f $samplerExe,$samplerOut,$samplerStop),$Run,'WinSta0\Default',(Join-Path $Run 'modifier-sampler.log'))
    $script:launches.Add($script:sampler.process); [void][HiddenLocal]::CloseHandle($script:sampler.thread)
    $renderers=if($Renderer -eq 'both') { @('opengl','d3d11') } else { @($Renderer) }
    foreach($name in $renderers) { Measure-Case $name }
    foreach($name in $renderers) { Measure-CrossDpi $name 'down'; Measure-CrossDpi $name 'up' }
    foreach($name in $renderers) { Measure-Search $name }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    # The real keyboard against the posted keys and drags. A modifier held
    # there while one ran means the run was interfered with, never that it
    # passed (input.md, 2026-10-11, trap 11). Nothing held is not a pass
    # either: nothing here can hold a real key to show the sampler would see
    # one.
    $keyboard=@{ Windows=[Tt]::Windows.Count }
    if($script:sampler) {
        New-Item -ItemType File -Path $samplerStop -Force | Out-Null
        if([HiddenLocal]::WaitForSingleObject($script:sampler.process,5000) -ne 0) {
            [void][HiddenLocal]::TerminateProcess($script:sampler.process,1)
            [void][HiddenLocal]::WaitForSingleObject($script:sampler.process,5000)
        }
        $rows=if(Test-Path -LiteralPath $samplerOut) { @(Get-Content -LiteralPath $samplerOut) } else { @() }
        $finished=@($rows | Where-Object { $_ -like 'done,*' }).Count -eq 1
        foreach($row in $rows) { if($row -like 'done,*') { $keyboard.Samples=[long]($row -split ',')[1] } }
        $heldTicks=[Collections.Generic.List[uint64]]::new()
        $correlated=[Tt]::Correlate([string[]]$rows,$heldTicks)
        $held=$correlated[0]; $inactive=$correlated[1]
        $keyboard.HeldInWindows=$held; $keyboard.InactiveInWindows=$inactive; $keyboard.Finished=$finished
        $keyboard.HeldTicks=@($heldTicks); $keyboard.Recorded=$rows.Count
        if($held -gt 0) {
            Check 'INTERFERED: a modifier was held at the real keyboard while a posted key or drag ran' $false 0 $keyboard
        } elseif(-not $finished) {
            $script:unverified.Add('real keyboard: the sampler did not finish, so it is not known whether a modifier was held')
        } elseif($inactive -gt 0) {
            $script:unverified.Add("real keyboard: INCONCLUSIVE, the user's desktop was not the input desktop for $inactive samples while posted keys ran (locked, or another desktop)")
        } else {
            $script:unverified.Add("real keyboard: no modifier seen down during $($keyboard.Windows) posted keys and drags ($($keyboard.Samples) samples on the input desktop), with no positive control")
        }
    } else {
        $script:unverified.Add('real keyboard: not sampled (the run stopped before the sampler started)')
    }
    $script:unverified.Add('the app thread''s keyboard state while it handled each posted key: not read (attaching to the thread resets it), so a latched modifier shows only through a binding that did not run')
    # Through each launch's own handle, never a PID lookup.
    $remaining=@($script:launches | Where-Object { [HiddenLocal]::WaitForSingleObject($_,0) -ne 0 })
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    foreach($handle in $script:launches) { [void][HiddenLocal]::CloseHandle($handle) }
    @{Checks=$script:checks; Skipped=$script:skips; Unverified=$script:unverified; Keyboard=$keyboard; Samples=$script:samples; Processes=$script:processes; Limit='Posted window messages on a never-switched desktop; real pointer and keyboard input, the system window move, the clipboard and visual composition (a D3D11 present) are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'tab-tearoff-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
$passed=@($script:checks|Where-Object {$_.Passed})
Write-Host ("checks passed {0}/{1}" -f $passed.Count,$script:checks.Count)
$script:skips | ForEach-Object { Write-Host ("SKIPPED: " + $_) }
$script:unverified | ForEach-Object { Write-Host ("UNVERIFIED: " + $_) }
if($failed.Count){ $failed | ForEach-Object { Write-Host ("FAIL: " + $_.Name) }; exit 1 }
