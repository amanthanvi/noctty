#requires -Version 7.0
<#
Portable, hidden-desktop integration regression for the state a new window
starts in: `maximize` and `fullscreen` (#496), and the window keys a
`+new-window` forward sets over the state the new window copies from the
running one (position, size, decorations, opacity), and which running window
that is (the one active last). Run with -Bin <source bin
directory> -Run <new evidence directory>. The run directory must not already
exist. Every file the app reads or writes is a sample this script creates
beside a portable copy of the app: the real %LOCALAPPDATA%\noctty is never
written, and only the hash and time of its startup state file are read,
before and after. Never switches desktops, injects real input or registers a
global hotkey: the only keys are posted F11 (`toggle_fullscreen`), F12
(`toggle_quick_terminal`), F8 (`open_config`, which opens Settings and saves
nothing) and F9 (`close_tab:this`) messages, the last three bound in the
case's config, and nothing it does can copy. The clipboard sequence number is logged before and after and a
change fails the run. Every launch uses `--single-instance=false` and a class
of its own, except the three forwarding cases, each a pair of copies sharing a
class no other process uses. Results contain only window geometry, window
state, process IDs and assertions. It exits 1 when a check fails, so it can be
run against a build that still has the problem to show what fails; the saved
maximized session, the plain normal window, and the running window's caption
buttons and the plain forwarded copy of it are the positive controls that pass
on either.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 600,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Ws {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Placement { public int length, flags, showCmd; public Point min, max; public Rect normal; }
    [StructLayout(LayoutKind.Sequential)] struct MonInfo { public int cb; public Rect monitor, work; public uint flags; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public class State { public Rect Rect, Client, Normal, Monitor, Work; public int ShowCmd; public uint Dpi; public bool Visible,Iconic,Zoomed,Popup,Caption; }
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref Placement p);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr m, ref MonInfo info);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h,out uint key,out byte alpha,out uint flags);
    // What WM_NCHITTEST answers at screen point (x, y), physical pixels.
    public static int HitTest(IntPtr h,int x,int y) {
        IntPtr result; long point=((long)(y & 0xFFFF) << 16) | (long)(x & 0xFFFF);
        if(SendMessageTimeoutW(h,0x84,IntPtr.Zero,new IntPtr(point),0x2,5000,out result)==IntPtr.Zero) throw new Exception("WM_NCHITTEST timed out");
        return result.ToInt32();
    }
    // The layered alpha of a host, or -1 when it is not layered with LWA_ALPHA.
    public static int Alpha(IntPtr h) {
        if((GetWindowLongPtr(h,-20).ToInt64() & 0x00080000L)==0) return -1;
        uint key,flags; byte alpha;
        if(!GetLayeredWindowAttributes(h,out key,out alpha,out flags) || (flags & 0x2)==0) return -1;
        return alpha;
    }
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    delegate bool EnumProc(IntPtr h,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f,IntPtr p);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h,out int pid);
    [StructLayout(LayoutKind.Sequential)] struct GuiInfo { public int cb,flags; public IntPtr active,focus,capture,menuOwner,moveSize,caret; public Rect caretRect; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(int tid,ref GuiInfo info);
    // The active window of the thread that owns `h`.
    public static IntPtr ActiveOf(IntPtr h) {
        int pid; var info=new GuiInfo { cb=Marshal.SizeOf<GuiInfo>() };
        if(!GetGUIThreadInfo(GetWindowThreadProcessId(h,out pid),ref info)) throw new Exception("GetGUIThreadInfo failed");
        return info.active;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    // The top-level windows of class `cls` that process `pid` has on this desktop.
    public static IntPtr[] TopLevel(int pid,string cls) {
        var list=new System.Collections.Generic.List<IntPtr>();
        EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id); var s=new StringBuilder(128); GetClassNameW(h,s,128);
            if(id==pid && s.ToString()==cls) list.Add(h); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static State Read(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            var s=new State();
            if(!GetWindowRect(h,out s.Rect) || !GetClientRect(h,out s.Client)) throw new Exception("Window measurement failed");
            var p=new Placement { length=Marshal.SizeOf<Placement>() };
            if(!GetWindowPlacement(h,ref p)) throw new Exception("GetWindowPlacement failed");
            var info=new MonInfo { cb=Marshal.SizeOf<MonInfo>() };
            if(!GetMonitorInfoW(MonitorFromWindow(h,2),ref info)) throw new Exception("GetMonitorInfo failed");
            // The normal rect is in workspace coordinates; report it in screen coordinates.
            int dx=info.work.Left-info.monitor.Left, dy=info.work.Top-info.monitor.Top;
            s.Normal=new Rect { Left=p.normal.Left+dx, Top=p.normal.Top+dy, Right=p.normal.Right+dx, Bottom=p.normal.Bottom+dy };
            s.ShowCmd=p.showCmd; s.Monitor=info.monitor; s.Work=info.work;
            long style=GetWindowLongPtr(h,-16).ToInt64();
            s.Popup=(style & 0x80000000L)!=0; s.Caption=(style & 0x00C00000L)==0x00C00000L;
            s.Dpi=GetDpiForWindow(h); s.Visible=IsWindowVisible(h); s.Iconic=IsIconic(h); s.Zoomed=IsZoomed(h);
            return s;
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    // A key-down and key-up posted straight to a pane. A keybind is not a
    // global hotkey, so nothing is registered.
    public static void Key(IntPtr surface,int key) {
        if(!PostMessageW(surface,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(surface,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    // Starts a process on the named desktop with no console window. `show`
    // null leaves STARTF_USESHOWWINDOW clear, so the app's first ShowWindow is
    // its own; a value is what a shortcut or `start /min` hands it.
    public static ProcessInfo Spawn(string app,string command,string cwd,string desktop,int show) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=show<0?0:1,show=(short)(show<0?0:show) }; ProcessInfo pi;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08000000,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        return pi;
    }
}
'@
if (-not $Driver) {
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
        -DesktopPrefix 'noctty-ws-' -Label 'Hidden window start' -PassDesktopName -GuardClipboard
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Ws]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$runId=[guid]::NewGuid().ToString('N').Substring(0,12)
function Sample([string]$Name,$h) { $s=[Ws]::Read($h); $script:samples.Add(@{Name=$Name; State=$s}); return $s }
function Size($r) { return @(($r.Right-$r.Left),($r.Bottom-$r.Top)) }
function Pane($h) {
    $all=@([HiddenLocal]::Surfaces($h)); $shown=@($all|Where-Object {[Ws]::Read($_).Visible})
    if($shown.Count) { return $shown[0] }
    if($all.Count) { return $all[0] }
    throw 'Host has no pane.'
}
function Press($pane,[int]$Key,[int]$SettleMs=900) { [Ws]::Key($pane,$Key); Start-Sleep -Milliseconds $SettleMs }
# A portable copy with its own config. `-Class` is shared only by the
# forwarding case's two copies.
function New-Case([string]$Name,[string[]]$Lines,[hashtable]$Files=@{},[string]$Class) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    foreach($relative in $Files.Keys) { Set-Content -LiteralPath (Join-Path $dir $relative) -Value $Files[$relative] -NoNewline -Encoding utf8NoBOM }
    $config=Join-Path $dir 'window-start.ghostty'
    $single=if($Class){'single-instance = true'}else{'single-instance = false'}
    $class=if($Class){$Class}else{"noctty-test-issue496-$runId-$Name"}
    # `command` pins cmd.exe, so no PowerShell starts and no shell history can be written.
    @('command = cmd.exe /d /k','shell-integration = none',$single,"class = $class",'confirm-close-surface = false','auto-update = off',
      'window-position-x = 120','window-position-y = 90','window-width = 90','window-height = 26') + $Lines | Set-Content -LiteralPath $config
    return @{ Name=$Name; Dir=$dir; Config=$config; Exe=(Join-Path $dir 'noctty.exe') }
}
function Spawn-Owned($case,[string]$Arguments,[int]$Show=-1,[switch]$Action) {
    # A CLI action has to come first on the command line.
    $line=if($Action){'"{0}" {1}' -f $case.Exe,$Arguments}else{'"{0}" --config-default-files=false --config-file="{1}" {2}' -f $case.Exe,$case.Config,$Arguments}
    $pi=[Ws]::Spawn($case.Exe,$line,$case.Dir,"WinSta0\$DesktopName",$Show)
    try { $p=[Diagnostics.Process]::GetProcessById($pi.pid); [void]$p.Handle }
    finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
    $script:processes.Add(@{Case=$case.Name;Pid=$p.Id;StartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.ProcessName})
    return $p
}
function Hosts-With-Pane($p) { return @([HiddenLocal]::Hosts($p.Id)|Where-Object {@([HiddenLocal]::Surfaces($_)).Count -gt 0}) }
function Start-Case($case,[string]$Arguments='',[int]$Show=-1,[int]$SettleMs=1200) {
    $p=Spawn-Owned $case $Arguments $Show
    $case.Process=$p
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    do {
        $hosts=@(Hosts-With-Pane $p)
        if($hosts.Count -and [HiddenLocal]::WindowDesktop($hosts[0]) -ne $DesktopName) { Stop-Case $case; throw "Case $($case.Name) window is not on the private desktop." }
        if($hosts.Count) { Start-Sleep -Milliseconds $SettleMs; $case.Host=$hosts[0]; return $case }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline -and -not $p.HasExited)
    $cleanup=$null
    try { Stop-Case $case } catch { $cleanup=$_.Exception.Message }
    throw "Window startup failed for case $($case.Name).$(if($cleanup){" Cleanup: $cleanup"})"
}
function Stop-Process-Exact($p,[int]$WaitMs=8000) {
    if($p.WaitForExit($WaitMs)) { return }
    $live=Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if(-not $live) { return }
    if($live.StartTime -eq $p.StartTime -and $live.Path -eq $p.Path) { Stop-Process -Id $live.Id -Force }
    else { throw 'Exact process identity changed during cleanup.' }
}
function Stop-Case($case) {
    foreach($h in [HiddenLocal]::Hosts($case.Process.Id)) { [void][Ws]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    Stop-Process-Exact $case.Process
}
function Session-Json($r,[string]$State) {
    $window=@{ selected_tab=0; tabs=@(@{ selected_leaf=0; layout=@{ root=0; nodes=@(@{ pane=@{} }) } }); x=$r.Left; y=$r.Top; width=($r.Right-$r.Left); height=($r.Bottom-$r.Top); state=$State }
    return (@{ schema_version=1; windows=@($window) } | ConvertTo-Json -Depth 12 -Compress)
}

try {
    # The plain window every other case is compared with: its normal rect is
    # `window-position-*` with `window-width`/`window-height`.
    $case=Start-Case (New-Case 'normal' @('window-save-state = never'))
    try { $normal=Sample 'normal' $case.Host } finally { Stop-Case $case }
    Check 'control: a plain window starts normal' (-not $normal.Zoomed -and -not $normal.Popup -and $normal.Visible) 'normal, framed, visible' @{Zoomed=$normal.Zoomed; Popup=$normal.Popup; Visible=$normal.Visible}

    # `maximize = true`: maximized from the start, over the configured rect.
    $case=Start-Case (New-Case 'maximize' @('window-save-state = never','maximize = true'))
    try {
        $s=Sample 'maximize' $case.Host
        Check 'maximize: the first window starts maximized' ($s.Zoomed -and $s.ShowCmd -eq 3) 'zoomed, showCmd 3' @{Zoomed=$s.Zoomed; ShowCmd=$s.ShowCmd}
        Check 'maximize: its normal rect is the configured one' (Rect-Same $s.Normal $normal.Rect) (Rect-Array $normal.Rect) (Rect-Array $s.Normal)
        [void][Ws]::ShowWindow($case.Host,9); Start-Sleep -Milliseconds 800   # SW_RESTORE
        $r=Sample 'maximize-restored' $case.Host
        Check 'maximize: un-maximized, it has the configured client size' (-not $r.Zoomed -and ((Size $r.Client) -join 'x') -eq ((Size $normal.Client) -join 'x')) (Size $normal.Client) (Size $r.Client)
    } finally { Stop-Case $case }

    # `fullscreen = true`: on the monitor without a frame from the start, and
    # back to the configured window on F11.
    $case=Start-Case (New-Case 'fullscreen' @('window-save-state = never','fullscreen = true'))
    try {
        $s=Sample 'fullscreen' $case.Host
        Check 'fullscreen: the first window starts fullscreen' ($s.Popup -and -not $s.Caption -and (Rect-Same $s.Rect $s.Monitor 0) -and -not $s.Zoomed) 'popup at the monitor rect, not zoomed' @{Popup=$s.Popup; Rect=(Rect-Array $s.Rect); Monitor=(Rect-Array $s.Monitor); Zoomed=$s.Zoomed}
        Press (Pane $case.Host) 0x7A 1200      # F11: toggle_fullscreen
        $r=Sample 'fullscreen-left' $case.Host
        Check 'fullscreen: leaving it gives the configured window' (-not $r.Popup -and $r.Caption -and -not $r.Zoomed -and (Rect-Same $r.Rect $normal.Rect)) (Rect-Array $normal.Rect) @{Rect=(Rect-Array $r.Rect); Zoomed=$r.Zoomed; Popup=$r.Popup}
    } finally { Stop-Case $case }

    # Both: fullscreen first, and maximized when it leaves.
    $case=Start-Case (New-Case 'both' @('window-save-state = never','maximize = true','fullscreen = true'))
    try {
        $s=Sample 'both' $case.Host
        Check 'both: the first window starts fullscreen, not as a maximized popup' ($s.Popup -and (Rect-Same $s.Rect $s.Monitor 0) -and -not $s.Zoomed) 'popup at the monitor rect, not zoomed' @{Popup=$s.Popup; Rect=(Rect-Array $s.Rect); Zoomed=$s.Zoomed}
        Press (Pane $case.Host) 0x7A 1200
        $r=Sample 'both-left' $case.Host
        Check 'both: leaving fullscreen lands maximized over the configured rect' ($r.Zoomed -and -not $r.Popup -and (Rect-Same $r.Normal $normal.Rect)) (Rect-Array $normal.Rect) @{Zoomed=$r.Zoomed; Normal=(Rect-Array $r.Normal)}
    } finally { Stop-Case $case }

    # Forwarded: a second launch with `--maximize`, and `+new-window
    # --fullscreen=true`, into a running noctty whose window is normal.
    $class="noctty-test-issue496-$runId-fwd"
    $primary=Start-Case (New-Case 'forward-primary' @('window-save-state = never') -Class $class)
    $second=New-Case 'forward-second' @('window-save-state = never') -Class $class
    try {
        $first=$primary.Host
        $p=Spawn-Owned $second '--maximize'
        Stop-Process-Exact $p 15000
        $ok=Wait-Until { @(Hosts-With-Pane $primary.Process).Count -eq 2 } 15
        Check 'forwarded launch opened a window in the running noctty' $ok 2 @(Hosts-With-Pane $primary.Process).Count
        Start-Sleep -Milliseconds 1200
        $made=@(Hosts-With-Pane $primary.Process|Where-Object {$_ -ne $first})
        if($made.Count -eq 1) {
            $s=Sample 'forward-maximize' $made[0]
            Check 'forwarded --maximize: the new window is maximized' $s.Zoomed $true $s.Zoomed
        }
        $p=Spawn-Owned $second "+new-window --class=$class --timeout=10000 --fullscreen=true" -Action
        Stop-Process-Exact $p 15000
        Check 'forwarded +new-window exits 0' ($p.ExitCode -eq 0) 0 $p.ExitCode
        $ok=Wait-Until { @(Hosts-With-Pane $primary.Process).Count -eq 3 } 15
        Check 'forwarded +new-window opened a window' $ok 3 @(Hosts-With-Pane $primary.Process).Count
        Start-Sleep -Milliseconds 1200
        $made=@(Hosts-With-Pane $primary.Process|Where-Object {$_ -ne $first -and $made -notcontains $_})
        if($made.Count -eq 1) {
            $s=Sample 'forward-fullscreen' $made[0]
            Check 'forwarded --fullscreen=true: the new window is fullscreen on its monitor' ($s.Popup -and (Rect-Same $s.Rect $s.Monitor 0)) (Rect-Array $s.Monitor) @{Popup=$s.Popup; Rect=(Rect-Array $s.Rect)}
        }
        $f=Sample 'forward-source-after' $first
        Check 'forwarding left the running window normal' (-not $f.Zoomed -and -not $f.Popup) 'normal' @{Zoomed=$f.Zoomed; Popup=$f.Popup}
    } finally { Stop-Case $primary }

    # Forwarded window keys: a new window copies the running window's size
    # (cascaded), decorations and opacity, and what the forwarded argv sets
    # wins over that copy. The reference is a first window whose config has
    # the forwarded size. The hit test where the close button is tells a
    # decorated window (HTCLOSE) from an undecorated one, whose tab strip is
    # there (HTCAPTION): on Windows 11 both keep the frame, so their style is
    # the same.
    $case=Start-Case (New-Case 'keys-reference' @('window-save-state = never','window-width = 60','window-height = 20'))
    try { $reference=Sample 'keys-reference' $case.Host } finally { Stop-Case $case }
    function Close-Button($h,$s) { return [Ws]::HitTest($h,$s.Rect.Right-30,$s.Rect.Top+20) }
    $class="noctty-test-issue496-$runId-keys"
    $primary=Start-Case (New-Case 'keys-primary' @('window-save-state = never','quit-after-last-window-closed = false') -Class $class)
    $second=New-Case 'keys-second' @('window-save-state = never') -Class $class
    function Forward([string]$Name,[string]$Arguments) {
        $before=@(Hosts-With-Pane $primary.Process)
        $p=Spawn-Owned $second "+new-window --class=$class --timeout=10000 $Arguments" -Action
        Stop-Process-Exact $p 15000
        $ok=Wait-Until { @(Hosts-With-Pane $primary.Process).Count -eq $before.Count+1 } 15
        Check "${Name}: +new-window opened a window in the running noctty" ($p.ExitCode -eq 0 -and $ok) 'exit 0, one more window' @{ExitCode=$p.ExitCode; Windows=@(Hosts-With-Pane $primary.Process).Count}
        Start-Sleep -Milliseconds 1200
        $made=@(Hosts-With-Pane $primary.Process|Where-Object {$before -notcontains $_})
        if($made.Count -ne 1) { return $null }
        return $made[0]
    }
    function Close-Window($h) {
        [void][Ws]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
        [void](Wait-Until { -not [Ws]::Alive($h) } 10)
    }
    try {
        $first=$primary.Host
        $f=Sample 'keys-primary' $first
        $hit=Close-Button $first $f
        Check 'control: the running window has caption buttons and is opaque' ($hit -eq 20 -and [Ws]::Alpha($first) -eq -1) 'HTCLOSE, not layered' @{HitTest=$hit; Alpha=[Ws]::Alpha($first)}
        # Nothing forwarded but the class: the copy, at the configured place.
        $h=Forward 'keys-plain' ''
        if($h) {
            $s=Sample 'keys-plain' $h; $hit=Close-Button $h $s
            Check 'control: a plain forwarded window copies the running one' ((Rect-Same $s.Rect $f.Rect) -and $hit -eq 20 -and [Ws]::Alpha($h) -eq -1) (Rect-Array $f.Rect) @{Rect=(Rect-Array $s.Rect); HitTest=$hit; Alpha=[Ws]::Alpha($h)}
            Close-Window $h
        }
        $h=Forward 'keys-position' '--window-position-x=400 --window-position-y=300'
        if($h) {
            $s=Sample 'keys-position' $h
            $want=[pscustomobject]@{ Left=400; Top=300; Right=400+($f.Rect.Right-$f.Rect.Left); Bottom=300+($f.Rect.Bottom-$f.Rect.Top) }
            Check 'forwarded --window-position-*: placed there, at the copied size' (Rect-Same $s.Rect $want 0) (Rect-Array $want) (Rect-Array $s.Rect)
            Close-Window $h
        }
        $h=Forward 'keys-size' '--window-width=60 --window-height=20'
        if($h) {
            $s=Sample 'keys-size' $h
            Check 'forwarded --window-width/height: the size it asked for' (((Size $s.Client) -join 'x') -eq ((Size $reference.Client) -join 'x')) (Size $reference.Client) (Size $s.Client)
            Close-Window $h
        }
        # Placed and sized by the arguments, it is where they say at the size
        # they ask for: core init sized it there, and the copy takes neither.
        $h=Forward 'keys-position-size' '--window-position-x=400 --window-position-y=300 --window-width=60 --window-height=20'
        if($h) {
            $s=Sample 'keys-position-size' $h
            Check 'forwarded position and size: placed there, at the size it asked for' ($s.Rect.Left -eq 400 -and $s.Rect.Top -eq 300 -and ((Size $s.Client) -join 'x') -eq ((Size $reference.Client) -join 'x')) @{Left=400; Top=300; Client=(Size $reference.Client)} @{Left=$s.Rect.Left; Top=$s.Rect.Top; Client=(Size $s.Client)}
            Close-Window $h
        }
        $h=Forward 'keys-decoration' '--window-decoration=none'
        if($h) {
            $s=Sample 'keys-decoration' $h; $hit=Close-Button $h $s
            Check 'forwarded --window-decoration=none: no caption buttons, the tab strip is there' ($hit -eq 2) 'HTCAPTION' $hit
            Close-Window $h
        }
        $h=Forward 'keys-opacity' '--background-opacity=0.6'
        if($h) {
            $alpha=[Ws]::Alpha($h)
            Check 'forwarded --background-opacity: the window is translucent' ($alpha -gt 0 -and $alpha -lt 255) '0 < alpha < 255' $alpha
            Close-Window $h
        }
        # With no window open there is nothing to copy.
        Close-Window $first
        Check 'quit-after-last-window-closed = false: the instance kept running' (-not $primary.Process.HasExited -and @(Hosts-With-Pane $primary.Process).Count -eq 0) 'running, no window' @{Exited=$primary.Process.HasExited; Windows=@(Hosts-With-Pane $primary.Process).Count}
        $h=Forward 'keys-none-open' '--window-position-x=400 --window-position-y=300 --window-width=60 --window-height=20 --window-decoration=none'
        if($h) {
            $s=Sample 'keys-none-open' $h; $hit=Close-Button $h $s
            Check 'no window open: the forwarded place, size and decorations' ($s.Rect.Left -eq 400 -and $s.Rect.Top -eq 300 -and ((Size $s.Client) -join 'x') -eq ((Size $reference.Client) -join 'x') -and $hit -eq 2) @{Left=400; Top=300; Client=(Size $reference.Client); HitTest='HTCAPTION'} @{Left=$s.Rect.Left; Top=$s.Rect.Top; Client=(Size $s.Client); HitTest=$hit}
        }
    } finally { Stop-Case $primary }

    # Which window a forward copies: the one active last, never one whose
    # only tab was closed and is kept, empty, for undo. Before, it was the
    # first in the instance's window list: a forward copied the first
    # window, and with that one kept empty it copied nothing and opened as a
    # first window does. No configured position (an empty value resets it),
    # so a plain forward is one cascade step off the window it copies.
    $class="noctty-test-fwdsource-$runId"
    $primary=Start-Case (New-Case 'source-primary' @('window-position-x =','window-position-y =','window-save-state = never','undo-timeout = 60s','keybind = f9=close_tab:this') -Class $class)
    $second=New-Case 'source-second' @('window-save-state = never') -Class $class
    # One step off the window `s` describes, as `cascadeStep` (MulDiv,
    # rounded) and `fitRectInWork` place it.
    function Cascaded($s) {
        $step=[int][math]::Round(32*[math]::Max($s.Dpi,96)/96.0,[MidpointRounding]::AwayFromZero)
        $w=[math]::Min($s.Rect.Right-$s.Rect.Left,$s.Work.Right-$s.Work.Left); $h=[math]::Min($s.Rect.Bottom-$s.Rect.Top,$s.Work.Bottom-$s.Work.Top)
        $l=[math]::Max($s.Work.Left,[math]::Min($s.Rect.Left+$step,$s.Work.Right-$w)); $t=[math]::Max($s.Work.Top,[math]::Min($s.Rect.Top+$step,$s.Work.Bottom-$h))
        return [pscustomobject]@{ Left=$l; Top=$t; Right=$l+$w; Bottom=$t+$h }
    }
    function Copied([string]$Name,$source,$h) {
        $s=Sample $Name $h; $want=Cascaded $source
        Check "${Name}: one step off the window active last" (Rect-Same $s.Rect $want 0) (Rect-Array $want) (Rect-Array $s.Rect)
    }
    try {
        $first=$primary.Host
        [void](Forward 'source-b' '--window-position-x=400 --window-position-y=300')
        $c=Forward 'source-c' '--window-position-x=240 --window-position-y=200'
        if($c) {
            $active=[Ws]::ActiveOf($c)
            Check 'control: the newest window is the active one' ($active -eq $c) $c.ToInt64() $active.ToInt64()
            $last=Forward 'source-plain' ''
            if($last) {
                Copied 'source-plain' (Sample 'source-c' $c) $last
                # The first window's only tab closed: it stays, empty, first
                # in the list, and active, as the target of undo's keys.
                Press (Pane $first) 0x78 1200        # F9: close_tab:this
                $panes=@([HiddenLocal]::Surfaces($first)|Where-Object {[Ws]::Read($_).Visible})
                Check 'control: the first window is kept, with no pane shown, and active' ([Ws]::Alive($first) -and $panes.Count -eq 0 -and [Ws]::ActiveOf($first) -eq $first) 'alive, no pane, active' @{Alive=[Ws]::Alive($first); Panes=$panes.Count; Active=[Ws]::ActiveOf($first).ToInt64(); First=$first.ToInt64()}
                $h=Forward 'source-empty-first' ''
                if($h) { Copied 'source-empty-first' (Sample 'source-last' $last) $h }
            }
        }
    } finally { Stop-Case $primary }

    # Session restore: a saved normal window with `maximize = true` is
    # maximized over its saved rect; a saved maximized one is maximized either
    # way (the positive control: it passes before the fix).
    $saved=[pscustomobject]@{ Left=$normal.Work.Left+200; Top=$normal.Work.Top+150; Right=$normal.Work.Left+1100; Bottom=$normal.Work.Top+750 }
    $case=Start-Case (New-Case 'restore-maximized' @('window-save-state = always') @{ 'session-state.json'=(Session-Json $saved 'maximized') })
    try { $s=Sample 'restore-maximized' $case.Host } finally { Stop-Case $case }
    Check 'control: a saved maximized window comes back maximized' ($s.Zoomed -and (Rect-Same $s.Normal $saved)) (Rect-Array $saved) @{Zoomed=$s.Zoomed; Normal=(Rect-Array $s.Normal)}
    $case=Start-Case (New-Case 'restore-normal' @('window-save-state = always') @{ 'session-state.json'=(Session-Json $saved 'normal') })
    try { $s=Sample 'restore-normal' $case.Host } finally { Stop-Case $case }
    Check 'control: a saved normal window comes back normal at its rect' (-not $s.Zoomed -and (Rect-Same $s.Rect $saved)) (Rect-Array $saved) @{Zoomed=$s.Zoomed; Rect=(Rect-Array $s.Rect)}
    $case=Start-Case (New-Case 'restore-normal-maximize' @('window-save-state = always','maximize = true') @{ 'session-state.json'=(Session-Json $saved 'normal') })
    try { $s=Sample 'restore-normal-maximize' $case.Host } finally { Stop-Case $case }
    Check 'restore with maximize: maximized over the saved rect' ($s.Zoomed -and (Rect-Same $s.Normal $saved)) (Rect-Array $saved) @{Zoomed=$s.Zoomed; Normal=(Rect-Array $s.Normal)}

    # The session has no fullscreen state, so a fullscreen window is saved as
    # the window leaving fullscreen gives back. It was saved as a normal
    # window over its whole monitor, and with `fullscreen = true` every later
    # launch then left fullscreen to that.
    function Saved-Window($case) {
        $file=Join-Path $case.Dir 'session-state.json'
        if(-not (Test-Path -LiteralPath $file)) { return $null }
        $w=(Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).windows[0]
        $script:samples.Add(@{Name="saved-$($case.Name)"; State=@{x=$w.x;y=$w.y;width=$w.width;height=$w.height;state=$w.state}})
        return $w
    }
    function Saved-Rect($w) { return [pscustomobject]@{ Left=$w.x; Top=$w.y; Right=($w.x+$w.width); Bottom=($w.y+$w.height) } }
    $case=Start-Case (New-Case 'save-fullscreen' @('window-save-state = always','fullscreen = true'))
    try { [void](Sample 'save-fullscreen' $case.Host) } finally { Stop-Case $case }
    $w=Saved-Window $case
    $actual=if($w){@{State=$w.state; Rect=(Rect-Array (Saved-Rect $w))}}else{'no saved window'}
    Check 'save, fullscreen = true: saved as the configured window' ($w -and $w.state -eq 'normal' -and (Rect-Same (Saved-Rect $w) $normal.Rect)) (Rect-Array $normal.Rect) $actual
    if($w) {
        $json=Get-Content -LiteralPath (Join-Path $case.Dir 'session-state.json') -Raw
        $case=Start-Case (New-Case 'save-fullscreen-again' @('window-save-state = always','fullscreen = true') @{ 'session-state.json'=$json })
        try {
            $s=Sample 'save-fullscreen-again' $case.Host
            Check 'save, fullscreen = true, next launch: fullscreen' ($s.Popup -and (Rect-Same $s.Rect $s.Monitor 0)) (Rect-Array $s.Monitor) @{Popup=$s.Popup; Rect=(Rect-Array $s.Rect)}
            Press (Pane $case.Host) 0x7A 1200      # F11: toggle_fullscreen
            $r=Sample 'save-fullscreen-again-left' $case.Host
            Check 'save, fullscreen = true, next launch: leaves it to the configured window' (-not $r.Popup -and -not $r.Zoomed -and (Rect-Same $r.Rect $normal.Rect)) (Rect-Array $normal.Rect) @{Popup=$r.Popup; Zoomed=$r.Zoomed; Rect=(Rect-Array $r.Rect)}
        } finally { Stop-Case $case }
    }
    # F11 on a maximized window: saved maximized over its normal rect.
    $case=Start-Case (New-Case 'save-f11-maximized' @('window-save-state = always'))
    try {
        [void][Ws]::ShowWindow($case.Host,3); Start-Sleep -Milliseconds 800   # SW_MAXIMIZE
        Press (Pane $case.Host) 0x7A 1200      # F11: toggle_fullscreen
        $s=Sample 'save-f11-maximized' $case.Host
        Check 'save, F11 from maximized: the window is fullscreen' ($s.Popup -and (Rect-Same $s.Rect $s.Monitor 0)) (Rect-Array $s.Monitor) @{Popup=$s.Popup; Rect=(Rect-Array $s.Rect)}
    } finally { Stop-Case $case }
    $w=Saved-Window $case
    $actual=if($w){@{State=$w.state; Rect=(Rect-Array (Saved-Rect $w))}}else{'no saved window'}
    Check 'save, F11 from maximized: saved maximized over its normal rect' ($w -and $w.state -eq 'maximized' -and (Rect-Same (Saved-Rect $w) $normal.Rect)) (Rect-Array $normal.Rect) $actual

    # Not the quick terminal: with `maximize = true` it keeps its strip.
    $case=Start-Case (New-Case 'quick-terminal' @('window-save-state = never','maximize = true','keybind = f12=toggle_quick_terminal','quick-terminal-screen = main','quick-terminal-autohide = false','quick-terminal-animation-duration = 0','quick-terminal-size = 25%'))
    try {
        $main=$case.Host
        Press (Pane $main) 0x7B 1800           # F12: toggle_quick_terminal
        $qt=@(Hosts-With-Pane $case.Process|Where-Object {$_ -ne $main})
        Check 'quick terminal opened' ($qt.Count -eq 1) 1 $qt.Count
        if($qt.Count -eq 1) {
            $s=Sample 'quick-terminal' $qt[0]
            Check 'quick terminal with maximize: not maximized, not fullscreen, its strip' (-not $s.Zoomed -and ($s.Rect.Bottom-$s.Rect.Top) -lt ($s.Monitor.Bottom-$s.Monitor.Top)/2) 'a strip' @{Zoomed=$s.Zoomed; Rect=(Rect-Array $s.Rect)}
        }
    } finally { Stop-Case $case }

    # What a launcher's STARTUPINFO does to the first show. A shortcut set to
    # Normal passes STARTF_USESHOWWINDOW with SW_SHOWNORMAL, and Windows can
    # replace an app's first ShowWindow with it.
    $case=Start-Case (New-Case 'startupinfo-normal' @('window-save-state = never','maximize = true')) -Show 1
    try { $s=Sample 'startupinfo-normal' $case.Host } finally { Stop-Case $case }
    Check 'maximize, launched with SW_SHOWNORMAL in STARTUPINFO: maximized' $s.Zoomed $true @{Zoomed=$s.Zoomed; Visible=$s.Visible; Iconic=$s.Iconic}
    # Recorded, not asserted: a minimized launch (SW_SHOWMINNOACTIVE) with
    # `maximize`, and a maximized shortcut with neither setting.
    foreach($show in @(
        @{N='startupinfo-minimized-maximize'; V=7; Lines=@('window-save-state = never','maximize = true')},
        @{N='startupinfo-maximized-shortcut'; V=3; Lines=@('window-save-state = never')})) {
        $case=Start-Case (New-Case $show.N $show.Lines) -Show $show.V
        try { [void](Sample $show.N $case.Host) } finally { Stop-Case $case }
    }

    # The launcher's show command goes to the first framed window the app
    # shows, and a window that starts fullscreen is a popup by then. It has
    # to take the command before that, or the next framed window takes it:
    # Settings opened minimized, or maximized from a maximized shortcut.
    foreach($show in @(
        @{N='startupinfo-minimized-fullscreen'; V=7},
        @{N='startupinfo-maximized-fullscreen'; V=3})) {
        $case=Start-Case (New-Case $show.N @('window-save-state = never','fullscreen = true','keybind = f8=open_config')) -Show $show.V
        try {
            $s=Sample $show.N $case.Host
            Check "$($show.N): the first window starts fullscreen" ($s.Popup -and -not $s.Iconic -and (Rect-Same $s.Rect $s.Monitor 0)) (Rect-Array $s.Monitor) @{Popup=$s.Popup; Iconic=$s.Iconic; Rect=(Rect-Array $s.Rect)}
            Press (Pane $case.Host) 0x77 300       # F8: open_config
            $ok=Wait-Until { @([Ws]::TopLevel($case.Process.Id,'noctty.win32.settings')|Where-Object {[Ws]::Read($_).Visible}).Count -gt 0 } 15
            Check "$($show.N): Settings opened" $ok $true $ok
            $settings=@([Ws]::TopLevel($case.Process.Id,'noctty.win32.settings'))
            if($settings.Count) {
                Start-Sleep -Milliseconds 600
                $t=Sample "$($show.N)-settings" $settings[0]
                Check "$($show.N): Settings opens as a normal window" ($t.Visible -and -not $t.Iconic -and -not $t.Zoomed) 'visible, not minimized, not maximized' @{Visible=$t.Visible; Iconic=$t.Iconic; Zoomed=$t.Zoomed}
                foreach($h in $settings) { [void][Ws]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
                Start-Sleep -Milliseconds 600
            }
        } finally { Stop-Case $case }
    }

    # A minimized launch that restores a session: Windows minimizes the
    # restored window's first show, before it has its saved rect. Restore
    # activates it, and it has to come back at that rect, maximized or
    # fullscreen as the session and the settings say.
    foreach($show in @(
        @{N='startupinfo-minimized-restore-normal'; State='normal'; Lines=@()},
        @{N='startupinfo-minimized-restore-maximized'; State='maximized'; Lines=@()},
        @{N='startupinfo-minimized-restore-maximize'; State='normal'; Lines=@('maximize = true')},
        @{N='startupinfo-minimized-restore-fullscreen'; State='normal'; Lines=@('fullscreen = true')})) {
        $case=Start-Case (New-Case $show.N (@('window-save-state = always') + $show.Lines) @{ 'session-state.json'=(Session-Json $saved $show.State) }) -Show 7
        try {
            $s=Sample $show.N $case.Host
            $actual=@{Iconic=$s.Iconic; Zoomed=$s.Zoomed; Popup=$s.Popup; Rect=(Rect-Array $s.Rect); Normal=(Rect-Array $s.Normal)}
            switch($show.N) {
                'startupinfo-minimized-restore-normal' {
                    Check 'minimized launch, saved normal: back at its saved rect' (-not $s.Iconic -and -not $s.Zoomed -and (Rect-Same $s.Rect $saved)) (Rect-Array $saved) $actual
                }
                'startupinfo-minimized-restore-fullscreen' {
                    Check 'minimized launch, saved normal, fullscreen: fullscreen on its monitor' (-not $s.Iconic -and $s.Popup -and (Rect-Same $s.Rect $s.Monitor 0)) (Rect-Array $s.Monitor) $actual
                    Press (Pane $case.Host) 0x7A 1200      # F11: toggle_fullscreen
                    $r=Sample "$($show.N)-left" $case.Host
                    Check 'minimized launch, saved normal, fullscreen: leaves it to the saved rect' (-not $r.Popup -and $r.Caption -and -not $r.Zoomed -and (Rect-Same $r.Rect $saved)) (Rect-Array $saved) @{Popup=$r.Popup; Zoomed=$r.Zoomed; Rect=(Rect-Array $r.Rect)}
                }
                default {
                    Check "minimized launch, $($show.N -replace '^startupinfo-minimized-restore-',''): maximized over the saved rect" (-not $s.Iconic -and $s.Zoomed -and (Rect-Same $s.Normal $saved)) (Rect-Array $saved) $actual
                }
            }
        } finally { Stop-Case $case }
    }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Win32 window state on a never-switched desktop; posted F11/F12 keys; real input, the shell, Snap, a visible composition and Windows 10 are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'window-start-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){exit 1}
