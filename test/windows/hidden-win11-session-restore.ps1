#requires -Version 7.0
<#
Portable, hidden-desktop integration regression for session-file compatibility
and restore placement (PKG-44), and for what the saved session holds once its
last window has gone (#497): -Scenario restore, last-window, or all (the
default). Run with -Bin <source bin directory> -Run <new
evidence directory>. The run directory must not already exist. Every file the
app reads or writes is a sample this script creates beside a portable copy of
the app: the real %LOCALAPPDATA%\koreterm is never written or deleted, and only
the hash and time of its startup state file are read, before and after. Never switches desktops,
injects real input or registers a global hotkey (the last-window cases press
in-app keybinds with key messages sent to the pane, one case sends an arrow, one only Shift, and one clicks
the pane), and nothing it does can copy (the
clipboard belongs to the window station, not the desktop); the clipboard sequence number is logged
before and after and a change fails the run. Optional
ExpectedStartupHash/ExpectedStartupModified pin an adopted baseline.
DriverTimeoutSeconds bounds the hidden driver and its owned process job.
Results contain only window geometry, process IDs, file hashes and assertions.
It exits 1 when a check fails, so it can be run against a build that still has
the problems to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateSet('all','restore','last-window')] [string] $Scenario = 'all',
    # Last-window cases to run, comma-separated (all of them when empty).
    [string] $Cases = '',
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 600,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Sr {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    public class State { public Rect Rect; public uint Dpi; public bool Visible,Iconic,Zoomed; }
    [StructLayout(LayoutKind.Sequential)] struct MonInfo { public int cb; public Rect monitor, work; public uint flags; }
    delegate bool EnumMonitor(IntPtr m, IntPtr dc, ref Rect r, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumMonitor cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr m, ref MonInfo info);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action,uint param,out Rect value,uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static Rect PrimaryWork() {
        Rect r; if(!SystemParametersInfoW(0x30,0,out r,0)) throw new Exception("SPI_GETWORKAREA failed"); return r;
    }
    // The work area of every monitor, in the physical pixels the app uses.
    public static Rect[] Works() {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            var list=new List<Rect>();
            EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr m,IntPtr dc,ref Rect r,IntPtr p)=> {
                var info=new MonInfo { cb=Marshal.SizeOf<MonInfo>() };
                if(GetMonitorInfoW(m,ref info)) list.Add(info.work);
                return true;
            },IntPtr.Zero);
            return list.ToArray();
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static State Read(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r;
            if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed");
            return new State { Rect=r,Dpi=GetDpiForWindow(h),Visible=IsWindowVisible(h),Iconic=IsIconic(h),Zoomed=IsZoomed(h) };
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static void Move(IntPtr h,int x,int y,int w,int ht) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { if(!SetWindowPos(h,IntPtr.Zero,x,y,w,ht,0x14)) throw new Exception("SetWindowPos failed"); }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr h; public uint m; public IntPtr w,l; public uint t; public int x,y; }
    [DllImport("user32.dll")] static extern bool PeekMessageW(out Msg m,IntPtr h,uint min,uint max,uint remove);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from,uint to,bool attach);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
    static void Send(IntPtr h,uint m,int key,long l) {
        IntPtr result;
        if(SendMessageTimeoutW(h,m,new IntPtr(key),new IntPtr(l),0,20000,out result)==IntPtr.Zero && Marshal.GetLastWin32Error()==1460)
            throw new Exception("Key not handled within 20 s");
    }
    // A key-down and key-up for a pane (or a host with no tab), which runs the
    // in-app keybind for that key. A keybind is not a global hotkey, so nothing
    // is registered, and an F-key types no text. koreterm reads the modifiers
    // from its thread's keyboard state, which a private desktop never updates,
    // so they are cleared there: this thread joins that input queue, and the
    // key is sent rather than posted so koreterm handles it before the queues
    // part. The user's keyboard is another queue and is not touched.
    public static void Key(IntPtr h,int key) {
        uint pid; uint target=GetWindowThreadProcessId(h,out pid); uint me=GetCurrentThreadId();
        Msg queue; PeekMessageW(out queue,IntPtr.Zero,0,0,0); // Give this thread an input queue.
        if(target==0 || !AttachThreadInput(me,target,true)) throw new Exception("AttachThreadInput failed");
        try {
            if(!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed");
            Send(h,0x100,key,1);
            // The keybind may have closed the window the key went to.
            if(IsWindow(h)) Send(h,0x101,key,0xC0000001L);
        } finally { AttachThreadInput(me,target,false); }
    }
    // A left click at (8,8) in a pane, sent as the keys are, with the
    // modifiers cleared. Copy-on-select is off in the case that uses it, and
    // a click that does not move selects nothing.
    public static void Click(IntPtr h) {
        uint pid; uint target=GetWindowThreadProcessId(h,out pid); uint me=GetCurrentThreadId();
        Msg queue; PeekMessageW(out queue,IntPtr.Zero,0,0,0);
        if(target==0 || !AttachThreadInput(me,target,true)) throw new Exception("AttachThreadInput failed");
        try {
            if(!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed");
            long at=(8<<16)|8;
            Send(h,0x201,1,at);
            if(IsWindow(h)) Send(h,0x202,0,at);
        } finally { AttachThreadInput(me,target,false); }
    }
}
'@
if (-not $Driver) {
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'koreterm.exe'))) { throw 'Source Bin must contain koreterm.exe.' }
    $before = Startup-Fingerprint
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-session-restore.ps1'
    $clipboardBefore = [HiddenLocal]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'koreterm-sr-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero
    try {
        $job=[HiddenLocal]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -DesktopName "{4}" -Scenario {5} -Cases "{6}" -Driver' -f $pwsh,$PSCommandPath,(Join-Path $Run 'source\bin'),$Run,$desktopName,$Scenario,$Cases
        $pi=[HiddenLocal]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([HiddenLocal]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$code=0; [void][HiddenLocal]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[HiddenLocal]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $clipboardAfter=[HiddenLocal]::GetClipboardSequenceNumber()
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyFailure=$null
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }
        @{ Before=$before; After=$after; Unchanged=$unchanged; HistoryUnchanged=($null -eq $historyFailure); OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount; ClipboardSequenceBefore=$clipboardBefore; ClipboardSequenceAfter=$clipboardAfter } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if ($historyFailure) { throw $historyFailure }
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($clipboardBefore -ne $clipboardAfter) { throw "Clipboard sequence number changed ($clipboardBefore -> $clipboardAfter); stop launches and report it." }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden session restore: PASS'
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Sr]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
# Every case runs with single instance off and a class of its own, so no copy
# can reach a koreterm already running on this machine.
$runClass='koreterm-test-sr-' + [guid]::NewGuid().ToString('N').Substring(0,8)
function Inside-AWork($r,$works) {
    foreach($w in $works) { if($r.Left -ge $w.Left -and $r.Top -ge $w.Top -and $r.Right -le $w.Right -and $r.Bottom -le $w.Bottom) { return $true } }
    return $false
}
function Sample([string]$Name,$h) { $s=[Sr]::Read($h); $script:samples.Add(@{Name=$Name; State=$s}); return $s }
function Siblings([string]$Dir,[string]$Pattern) { return @(Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction SilentlyContinue | ForEach-Object Name) }

# A sample session this script writes itself: one window of one tab and one
# pane, with fields a later build might add at every level.
function Session-Json($x,$y,$w,$h,[string]$State,[string]$Cwd,[bool]$Extra) {
    $pane = @{ cwd=$Cwd }
    $window = @{ selected_tab=0; tabs=@(@{ selected_leaf=0; layout=@{ root=0; nodes=@(@{ pane=$pane }) } }) }
    if($null -ne $x) { $window.x=$x; $window.y=$y; $window.width=$w; $window.height=$h; $window.state=$State }
    $doc = @{ schema_version=1; windows=@($window) }
    if($Extra) {
        $doc.added_later=@{ generation=7 }
        $window.monitor='\\.\DISPLAY9'
        $window.tabs[0].pinned=$true
        $window.tabs[0].layout.hint='grid'
        $pane.env=@{ A='b' }
    }
    return ($doc | ConvertTo-Json -Depth 12 -Compress)
}

function New-Case([string]$Name,[hashtable]$Files,[string[]]$Extra=@()) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    foreach($relative in $Files.Keys) {
        $target=Join-Path $dir $relative
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target))
        Set-Content -LiteralPath $target -Value $Files[$relative] -NoNewline -Encoding utf8NoBOM
    }
    $config=Join-Path $dir 'session.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false','window-save-state = always','confirm-close-surface = false') + $Extra | Set-Content -LiteralPath $config
    return @{ Name=$Name; Dir=$dir; Config=$config }
}
function Start-Case($case,[switch]$NoLedgerWait) {
    $exe=Join-Path $case.Dir 'koreterm.exe'
    # An explicit lpDesktop: a child that a private-desktop driver starts with a null desktop can
    # land on the interactive desktop. The Process object holds its own handle before the launch
    # handles close, so it stays this launch's process.
    $pi=[HiddenLocal]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,$case.Config,$runClass),$case.Dir,"WinSta0\$DesktopName")
    try { $p=[Diagnostics.Process]::GetProcessById($pi.pid); [void]$p.Handle }
    finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
    $script:processes.Add(@{Case=$case.Name;Pid=$p.Id;StartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.ProcessName})
    $case.Process=$p
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    do {
        $hosts=@([HiddenLocal]::Hosts($p.Id))
        if($hosts.Count -and [HiddenLocal]::WindowDesktop($hosts[0]) -ne $DesktopName) { Stop-Case $case; throw "Case $($case.Name) window is not on the private desktop." }
        $ready=$NoLedgerWait.IsPresent
        $ledger=Join-Path $case.Dir 'startup-attempts.json'
        if(-not $ready -and (Test-Path -LiteralPath $ledger)) {
            try {
                $attempts=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts
                $ready=$attempts.Count -gt 0 -and $attempts[-1].phase -eq 'ready' -and $null -ne $attempts[-1].ready_at_unix_ms
            } catch { } # A concurrent ledger write may be incomplete; retry within the deadline.
        }
        if($ready -and $hosts.Count -and @([HiddenLocal]::Surfaces($hosts[0])).Count -gt 0) {
            Start-Sleep -Milliseconds 600
            $case.Host=$hosts[0]
            return $case
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline -and -not $p.HasExited)
    # The startup failure is the finding; a cleanup error must not hide it.
    $cleanup=$null
    try { Stop-Case $case } catch { $cleanup=$_.Exception.Message }
    throw "Window startup failed for case $($case.Name).$(if($cleanup){" Cleanup: $cleanup"})"
}
function Stop-Case($case) {
    foreach($h in [HiddenLocal]::Hosts($case.Process.Id)) { [void][Sr]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if(-not $case.Process.WaitForExit(8000)) {
        $p=Get-Process -Id $case.Process.Id -ErrorAction SilentlyContinue
        if(-not $p) { return }   # It exited between the wait and the lookup.
        if($p.StartTime -eq $case.Process.StartTime -and $p.Path -eq $case.Process.Path) { Stop-Process -Id $p.Id -Force }
        else { throw 'Exact process identity changed during cleanup.' }
    }
}

# #497 (last-window): every way the session's last window can go. Keys are
# F-keys bound to the actions, sent to a pane with the modifiers cleared
# ([Sr]::Key), so no chord is needed.
$lastWindowConfig=@('keybind = f2=new_window','keybind = f3=close_all_windows','keybind = f4=new_tab','keybind = f5=close_tab:this',
    'keybind = f6=close_surface','keybind = f7=quit','keybind = f8=toggle_quick_terminal','keybind = f9=undo',
    'keybind = f11=new_split:right','keybind = f12=previous_tab',
    'quick-terminal-screen = main','quick-terminal-autohide = false','quick-terminal-animation-duration = 0','quick-terminal-size = 25%')
$Vk=@{ NewWindow=0x71; CloseAll=0x72; NewTab=0x73; CloseTab=0x74; CloseSurface=0x75; Quit=0x76; QuickTerminal=0x77; Undo=0x78; NewSplit=0x7A; PreviousTab=0x7B; Down=0x28; Shift=0x10 }
# The pane that is on screen in `$h`, or any pane when none is.
function Pane($h) {
    $all=@([HiddenLocal]::Surfaces($h)); $shown=@($all|Where-Object {([Sr]::Read($_)).Visible})
    if($shown.Count) { return $shown[0] }
    if($all.Count) { return $all[0] }
    throw 'Host has no pane.'
}
function Press($h,[int]$Key,[int]$SettleMs=700) { [Sr]::Key($h,$Key); if($SettleMs) { Start-Sleep -Milliseconds $SettleMs } }
function New-Hosts($case,$known) { return @([HiddenLocal]::Hosts($case.Process.Id)|Where-Object {$known -notcontains $_ -and @([HiddenLocal]::Surfaces($_)).Count -gt 0}) }
function Post-Close($h) { if(-not [Sr]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'WM_CLOSE post failed.' } }
# Seeds a one-window session at a known rect, restores it, moves the window
# whose state the file must end up holding, ends the session the way `$End`
# names, and reads the file once the process has exited by itself. The move
# comes after the last structural change has had its one-second checkpoint,
# and a move saves nothing by itself, so the moved rect can only reach the
# file through the save as the session ends. The process is never closed by
# the harness before the file is read: a harness WM_CLOSE would save it.
# -SetAside: the restored pane's program ends before any key reached it, so
# the restore failed and the saved session must be moved aside, not saved
# back (it would open and close again at every launch).
function Last-Window([string]$Name,[string]$End,[int]$Tabs=1,[string[]]$Extra=@(),[switch]$SetAside) {
    $seedX=$work.Left+180; $seedY=$work.Top+140
    $case=New-Case $Name @{ 'session-state.json'=(Session-Json $seedX $seedY 900 600 'normal' (Join-Path $Run "$Name\bin") $false) } ($lastWindowConfig + $Extra)
    $path=Join-Path $case.Dir 'session-state.json'
    $case=Start-Case $case
    $exited=$false; $moved=$null
    try {
        $main=$case.Host; $target=$main; $qt=$null
        switch($End) {
            { $_ -in 'quick-terminal-quit','quick-terminal-close' } {
                Press (Pane $main) $Vk.QuickTerminal 1500
                $found=@(New-Hosts $case @($main))
                if($found.Count -ne 1) { throw "$($Name): quick terminal absent." }
                $qt=$found[0]
            }
            'first-of-two-windows' {
                Press (Pane $main) $Vk.NewWindow 2500
                $found=@(New-Hosts $case @($main))
                if($found.Count -ne 1) { throw "$($Name): new window absent." }
                $target=$found[0]
            }
            'undo-host-close' {
                Press (Pane $main) $Vk.NewWindow 2500
                $found=@(New-Hosts $case @($main))
                if($found.Count -ne 1) { throw "$($Name): new window absent." }
                $target=$found[0]
                # The first window's only tab goes into undo history: an
                # empty window kept for undo, which is not a session window.
                Press (Pane $main) $Vk.CloseTab 1500
            }
            { $_ -in 'close-window-two-tabs','quit-two-tabs','close-all-windows-two-tabs' } { Press (Pane $main) $Vk.NewTab 1500 }
            'quit-split-in-hidden-tab' {
                Press (Pane $main) $Vk.NewTab 1500
                Press (Pane $main) $Vk.NewSplit 1500
                Press (Pane $main) $Vk.PreviousTab 1500
                # Three panes with one on screen: the first tab is in front
                # and the split tab is behind it. If a key did nothing, this
                # would be the plain two-tab case, which fails on main too.
                $panes=@([HiddenLocal]::Surfaces($main)); $shown=@($panes|Where-Object {([Sr]::Read($_)).Visible})
                $reached=$panes.Count -eq 3 -and $shown.Count -eq 1
                Check "${Name}: a split tab behind the one on screen before the quit" $reached '3 panes, 1 on screen' "$($panes.Count) panes, $($shown.Count) on screen"
                if(-not $reached) { return }
            }
            'undo-then-close' {
                Press (Pane $main) $Vk.CloseTab 800
                Press $main $Vk.Undo 0    # sent to the empty host, which routes it
                if(-not (Wait-Until { @([HiddenLocal]::Surfaces($main)|Where-Object {([Sr]::Read($_)).Visible}).Count -eq 1 } 5)) { throw "$($Name): undo did not bring the tab back." }
                Start-Sleep -Milliseconds 1500
            }
        }
        [Sr]::Move($target,$work.Left+260,$work.Top+210,820,580); Start-Sleep -Milliseconds 500
        $moved=Sample "$Name-moved" $target
        switch($End) {
            'close-tab' { Press (Pane $main) $Vk.CloseTab 0 }
            'close-surface' { Press (Pane $main) $Vk.CloseSurface 0 }
            { $_ -in 'quit','quit-two-tabs','quit-split-in-hidden-tab' } { Press (Pane $main) $Vk.Quit 0 }
            { $_ -in 'close-all-windows','close-all-windows-two-tabs' } { Press (Pane $main) $Vk.CloseAll 0 }
            'shell-exit' {
                # The configured command exits by itself. A key while it runs
                # uses the restored session.
                if(-not $SetAside) { Press (Pane $main) $Vk.Down 0 }
            }
            'shell-exit-clicked' {
                # The same with a click instead of a key.
                [Sr]::Click((Pane $main))
            }
            'shell-exit-modifier' {
                # Only Shift, pressed and released while the program runs:
                # a modifier alone is not input for it.
                Press (Pane $main) $Vk.Shift 0
            }
            'quick-terminal-quit' {
                Post-Close $main
                if(-not (Wait-Until { -not [Sr]::Alive($main) } 8)) { throw "$($Name): window did not close." }
                Press (Pane $qt) $Vk.Quit 0
            }
            'first-of-two-windows' {
                Post-Close $main
                if(-not (Wait-Until { -not [Sr]::Alive($main) } 8)) { throw "$($Name): the first window did not close." }
                Post-Close $target
            }
            'quick-terminal-close' {
                Post-Close $main
                if(-not (Wait-Until { -not [Sr]::Alive($main) } 8)) { throw "$($Name): window did not close." }
                Post-Close $qt
            }
            { $_ -in 'undo-host-close','undo-then-close','close-window-two-tabs' } { Post-Close $target }
            default { throw "Unknown ending $End." }
        }
        $exited=$case.Process.WaitForExit(30000)
    } finally {
        # Only this launch's own process, through the handle its Process
        # object holds; never by name. Killing saves nothing.
        if(-not $case.Process.HasExited) { $case.Process.Kill(); [void]$case.Process.WaitForExit(5000) }
    }
    Check "${Name}: the process ended by itself" $exited $true $exited
    if($SetAside) {
        $aside="$path.restore-ended"
        $left=Test-Path -LiteralPath $path; $moved_aside=Test-Path -LiteralPath $aside
        $breaker=@(Get-ChildItem -LiteralPath $case.Dir -Filter 'session-state.json.restore-failed*' -File).Count
        Check "${Name}: nothing is saved back" (-not $left) 'absent' $(if($left){'present'}else{'absent'})
        Check "${Name}: the saved session was moved aside" $moved_aside 'present' $(if($moved_aside){'present'}else{'absent'})
        Check "${Name}: the crash breaker's slots are left free" ($breaker -eq 0) 0 $breaker
        if($moved_aside) {
            $held=@((Get-Content -LiteralPath $aside -Raw | ConvertFrom-Json).windows)
            Check "${Name}: the moved session still holds its window" ($held.Count -eq 1) 1 $held.Count
        }
        return
    }
    $kept=Test-Path -LiteralPath $path
    Check "${Name}: the saved session is still there" $kept 'present' $(if($kept){'present'}else{'deleted'})
    if(-not $kept -or -not $moved) { return }
    $saved=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $windows=@($saved.windows)
    Check "${Name}: it holds one window" ($windows.Count -eq 1) 1 $windows.Count
    if($windows.Count -ne 1) { return }
    $w=$windows[0]
    Check "${Name}: with the tabs it had as it went" (@($w.tabs).Count -eq $Tabs) $Tabs @($w.tabs).Count
    if($End -eq 'quit-split-in-hidden-tab' -and @($w.tabs).Count -eq 2) {
        $splitPanes=@($w.tabs[1].layout.nodes | Where-Object { $_.PSObject.Properties.Name -contains 'pane' }).Count
        Check "${Name}: with the first tab in front" ($w.selected_tab -eq 0) 0 $w.selected_tab
        Check "${Name}: and both panes of the split tab behind it" ($splitPanes -eq 2) 2 $splitPanes
    }
    $savedRect=[pscustomobject]@{Left=$w.x;Top=$w.y;Right=$w.x+$w.width;Bottom=$w.y+$w.height}
    Check "${Name}: at the rect it had as it went" ($null -ne $w.x -and (Rect-Same $savedRect $moved.Rect)) (Rect-Array $moved.Rect) (Rect-Array $savedRect)
}

try {
    $work=[Sr]::PrimaryWork()
    $works=@([Sr]::Works())
    $script:samples.Add(@{Name='work-areas'; State=@($works | ForEach-Object { ,(Rect-Array $_) })})

    if($Scenario -in 'all','last-window') {
        $endings=@(
            # The reporter's case first: close_tab:this on the last tab, with
            # the default undo-timeout (the window and process go when it runs out).
            @{ Name='close-tab' },
            @{ Name='close-surface' },
            # The restored pane's shell exits by itself after a key: saved.
            @{ Name='shell-exit'; Extra=@('command = cmd.exe /d /c ping -n 12 127.0.0.1 >nul') },
            # The same with a click: saved.
            @{ Name='shell-exit-clicked'; Extra=@('command = cmd.exe /d /c ping -n 12 127.0.0.1 >nul','copy-on-select = false') },
            # The same with no key: that restore failed, and is moved aside.
            @{ Name='shell-exit-untouched'; End='shell-exit'; SetAside=$true; Extra=@('command = cmd.exe /d /c ping -n 12 127.0.0.1 >nul') },
            # The same with only Shift pressed and released: still unused.
            @{ Name='shell-exit-modifier'; SetAside=$true; Extra=@('command = cmd.exe /d /c ping -n 12 127.0.0.1 >nul') },
            @{ Name='quit' },
            @{ Name='close-all-windows' },
            # With a second tab, and with a split in a tab behind the front
            # one: a quit used to tear down only the panes up to the first
            # tab's button and leave the process running with no window.
            @{ Name='quit-two-tabs'; Tabs=2 },
            @{ Name='close-all-windows-two-tabs'; Tabs=2 },
            @{ Name='quit-split-in-hidden-tab'; Tabs=2 },
            # A quick terminal is never a session window: the last real window
            # closes while one is open, then a quit from it, or its own close.
            @{ Name='quick-terminal-quit' },
            @{ Name='quick-terminal-close' },
            # The first of two windows closes (its tab is not the shell model's
            # last), then the other one, which the session keeps.
            @{ Name='first-of-two-windows' },
            # Nor is a window kept empty for undo after its last tab closed.
            @{ Name='undo-host-close' },
            # An undo brings the session back, so the next close saves it again.
            @{ Name='undo-then-close' },
            # The window's own close saves both tabs; closing its panes one by
            # one after that must not save the last one alone over it.
            @{ Name='close-window-two-tabs'; Tabs=2 }
        )
        $only=@($Cases -split ',' | Where-Object { $_ })
        # A name no case has fails the run: a typo must not pass by running nothing.
        $known=@($endings | ForEach-Object { $_.Name })
        foreach($name in $only) {
            if($known -notcontains $name) { $script:checks.Add(@{Name="${name}: a last-window case by that name"; Passed=$false; Error="No last-window case is named '$name'."}) }
        }
        foreach($ending in $endings) {
            if($only.Count -and $only -notcontains $ending.Name) { continue }
            # One case failing to run is that case's failure, not the others'.
            $tabs=if($ending.Tabs){$ending.Tabs}else{1}
            $end=if($ending.End){$ending.End}else{$ending.Name}
            try { Last-Window $ending.Name $end $tabs @($ending.Extra | Where-Object { $_ }) -SetAside:([bool]$ending.SetAside) }
            catch { $script:checks.Add(@{Name="$($ending.Name): case ran"; Passed=$false; Error=$_.Exception.Message}) }
        }
    }

    if($Scenario -in 'all','restore') {
    # G037: a session a newer build wrote is left exactly as it was.
    $newerSession='{"schema_version":2,"windows":[{"layout_v2":{"zones":[1,2]}}],"future":true}'
    $case=New-Case 'newer-session' @{ 'session-state.json'=$newerSession }
    $path=Join-Path $case.Dir 'session-state.json'
    $hashBefore=Hash-Of $path
    $case=Start-Case $case
    try { [void](Sample 'newer-session-window' $case.Host) } finally { Stop-Case $case }
    Check 'newer-schema session untouched by a launch and a close' ((Hash-Of $path) -eq $hashBefore) $hashBefore (Hash-Of $path)
    Check 'newer-schema session not quarantined' ((Siblings $case.Dir 'session-state.json.corrupt*').Count -eq 0) 0 (Siblings $case.Dir 'session-state.json.corrupt*')

    # G037: a field this build does not know does not lose the session.
    $cwd=(Join-Path $Run 'added-field\bin')
    $savedX=$work.Left+200; $savedY=$work.Top+150
    $case=New-Case 'added-field' @{ 'session-state.json'=(Session-Json $savedX $savedY 900 600 'normal' $cwd $true) }
    $case=Start-Case $case
    try {
        $state=Sample 'added-field-restored' $case.Host
        Check 'session with added fields restored at its saved rect' (Rect-Same $state.Rect ([pscustomobject]@{Left=$savedX;Top=$savedY;Right=$savedX+900;Bottom=$savedY+600})) @($savedX,$savedY,($savedX+900),($savedY+600)) (Rect-Array $state.Rect)
        Check 'session with added fields not quarantined' ((Siblings $case.Dir 'session-state.json.corrupt*').Count -eq 0) 0 (Siblings $case.Dir 'session-state.json.corrupt*')

        # F044: maximized, the file records the rect it un-maximizes to, in
        # screen coordinates, and that it restores to maximized.
        $moveX=$work.Left+260; $moveY=$work.Top+210
        [Sr]::Move($case.Host,$moveX,$moveY,800,560); Start-Sleep -Milliseconds 400
        $normal=Sample 'added-field-moved' $case.Host
        [void][Sr]::ShowWindow($case.Host,3)   # SW_MAXIMIZE
        Start-Sleep -Milliseconds 600
        Check 'window maximized' ([Sr]::Read($case.Host)).Zoomed $true ([Sr]::Read($case.Host)).Zoomed
    } finally { Stop-Case $case }
    $saved=Get-Content -LiteralPath (Join-Path $case.Dir 'session-state.json') -Raw | ConvertFrom-Json
    $w=$saved.windows[0]
    Check 'saved normal rect of a maximized window is its screen rect' ($null -ne $w.x -and (Rect-Same ([pscustomobject]@{Left=$w.x;Top=$w.y;Right=$w.x+$w.width;Bottom=$w.y+$w.height}) $normal.Rect)) (Rect-Array $normal.Rect) @($w.x,$w.y,($w.x+$w.width),($w.y+$w.height))
    Check 'saved state is maximized' ($w.state -eq 'maximized') 'maximized' $w.state
    Check 'saved file carries the current schema only' ($saved.schema_version -eq 1 -and $null -eq $saved.added_later) 1 $saved.schema_version

    # F044: a window saved where no monitor is comes back on one.
    $case=New-Case 'missing-monitor' @{ 'session-state.json'=(Session-Json 30000 30000 700 500 'normal' (Join-Path $Run 'missing-monitor\bin') $false) }
    $case=Start-Case $case
    try {
        $state=Sample 'missing-monitor-restored' $case.Host
        Check 'window saved on a missing monitor is inside a work area' (Inside-AWork $state.Rect $works) 'inside a work area' (Rect-Array $state.Rect)
        Check 'window saved on a missing monitor keeps its size, whatever the DPI of the monitor it lands on' ((($state.Rect.Right-$state.Rect.Left) -eq 700) -and (($state.Rect.Bottom-$state.Rect.Top) -eq 500)) @(700,500) @(($state.Rect.Right-$state.Rect.Left),($state.Rect.Bottom-$state.Rect.Top))
    } finally { Stop-Case $case }

    # F044: a window saved on a monitor other than the one the host is created
    # on (the primary) comes back at exactly its saved rect, not rescaled by
    # the DPI difference between the two.
    $others=@($works | Where-Object { $_.Left -ne $work.Left -or $_.Top -ne $work.Top })
    if($others.Count -gt 0) {
        $other=$others[0]; $ox=$other.Left+100; $oy=$other.Top+100
        $case=New-Case 'other-monitor' @{ 'session-state.json'=(Session-Json $ox $oy 900 600 'normal' (Join-Path $Run 'other-monitor\bin') $false) }
        $case=Start-Case $case
        try {
            $state=Sample 'other-monitor-restored' $case.Host
            Check 'window saved on another monitor comes back at its saved rect' (Rect-Same $state.Rect ([pscustomobject]@{Left=$ox;Top=$oy;Right=$ox+900;Bottom=$oy+600})) @($ox,$oy,($ox+900),($oy+600)) (Rect-Array $state.Rect)
        } finally { Stop-Case $case }
    }

    $case=New-Case 'missing-monitor-maximized' @{ 'session-state.json'=(Session-Json (-30000) (-30000) 700 500 'maximized' (Join-Path $Run 'missing-monitor-maximized\bin') $false) }
    $case=Start-Case $case
    try {
        $state=Sample 'missing-monitor-maximized-restored' $case.Host
        Check 'window saved maximized is maximized' $state.Zoomed $true $state.Zoomed
        [void][Sr]::ShowWindow($case.Host,9)   # SW_RESTORE
        Start-Sleep -Milliseconds 600
        $normal=Sample 'missing-monitor-maximized-unmaximized' $case.Host
        Check 'un-maximizing goes to a rect inside a work area' ((-not $normal.Zoomed) -and (Inside-AWork $normal.Rect $works)) 'normal, inside a work area' @{Zoomed=$normal.Zoomed; Rect=(Rect-Array $normal.Rect)}
    } finally { Stop-Case $case }

    # F044: Windows caps what it is given (a left edge to 16 bits, a width to the
    # largest window), so a rect that spans every monitor as saved can be off
    # all of them once placed. It must be judged on what the window ends up as.
    $case=New-Case 'extreme-rect' @{ 'session-state.json'=(Session-Json (-2000000000) ($work.Top+50) 2100000000 480 'normal' (Join-Path $Run 'extreme-rect\bin') $false) }
    $case=Start-Case $case
    try {
        $state=Sample 'extreme-rect-restored' $case.Host
        Check 'window saved with an extreme rect ends up on a monitor' (Inside-AWork $state.Rect $works) 'inside a work area' (Rect-Array $state.Rect)
    } finally { Stop-Case $case }

    # G037: a recovery ledger a newer build wrote is not counted and not replaced.
    $newerLedger='{"schema_version":2,"attempts":[{"started_at_unix_ms":100,"phase":"init"}],"future":1}'
    $case=New-Case 'newer-ledger' @{ 'startup-attempts.json'=$newerLedger }
    $ledger=Join-Path $case.Dir 'startup-attempts.json'
    $hashBefore=Hash-Of $ledger
    $case=Start-Case $case -NoLedgerWait
    try { [void](Sample 'newer-ledger-window' $case.Host) } finally { Stop-Case $case }
    Check 'newer-schema ledger untouched by a launch and a close' ((Hash-Of $ledger) -eq $hashBefore) $hashBefore (Hash-Of $ledger)

    # G037: the shell integration script a newer build installed is kept, and
    # one an older build left is replaced. Ordered by the revision it declares.
    $newerScript="# koreterm-integration-revision: 9999`n# installed by a newer build`n"
    $case=New-Case 'script-newer' @{ 'shell-integration\powershell\integration.ps1'=$newerScript }
    $script=Join-Path $case.Dir 'shell-integration\powershell\integration.ps1'
    $case=Start-Case $case
    try { } finally { Stop-Case $case }
    Check 'integration.ps1 from a newer build kept' ((Get-Content -LiteralPath $script -Raw) -eq $newerScript) $newerScript ((Get-Content -LiteralPath $script -Raw).Length)
    Check 'no temporary integration copy left behind' ((Siblings (Split-Path -Parent $script) '*.tmp').Count -eq 0) 0 (Siblings (Split-Path -Parent $script) '*.tmp')

    $case=New-Case 'script-older' @{ 'shell-integration\powershell\integration.ps1'="# koreterm-integration-revision: 0`n# installed by an older build`n" }
    $script=Join-Path $case.Dir 'shell-integration\powershell\integration.ps1'
    $case=Start-Case $case
    try { } finally { Stop-Case $case }
    Check 'integration.ps1 from an older build replaced' ((Get-Item -LiteralPath $script).Length -gt 1000) 'embedded script' (Get-Item -LiteralPath $script).Length
    }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Win32 window state on a never-switched desktop with sample session files written by this script, in-app keybinds, one arrow and one Shift pressed with key messages sent to the pane, and one click sent to a pane; real pointer and keyboard input, typed shell input, an update install, a top or left taskbar and a removed monitor are not exercised (a missing monitor is a rect where none is).'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'session-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){ $failed | ForEach-Object { Write-Host ("FAIL: " + $_.Name) }; exit 1 }
