#requires -Version 7.0
<#
Portable, hidden-desktop measurement of closing the ONLY tab of a window
(TABX): the close button on the tab, and the keyboard close of the same tab
(a key bound to close_tab:this, which is what Ctrl+Shift+W runs). For each
case it records, from the action on, whether the host window stays up, whether
its tab button is still shown, whether a confirm prompt opened, and when the
process exited. Run with -Bin <source bin directory> -Run <new evidence
directory>. The run directory must not already exist.

Never switches desktops, injects real input or touches the clipboard: every
action is a posted window message. Nothing here copies, and the
configuration denies clipboard reads and writes and copy-on-select besides.
GetClipboardSequenceNumber (a counter, it reads no contents) is recorded
before and after, and the run fails when it moved. Optional
ExpectedStartupHash/ExpectedStartupModified pin an adopted baseline of the
real startup-attempts.json; either way it is fingerprinted before and after.
DriverTimeoutSeconds bounds the hidden driver and its owned process job.
Results contain only control geometry, label text, process IDs and
assertions. It exits 1 when a check fails, so it can be run against a build
that still has the problem to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateSet('full','close-x')] [string] $Scenario = 'full',
    # Extra configuration lines for every case, separated by ';'.
    [string] $ExtraConfig = '',
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 300,
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
public static class Ds {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiThreadInfo {
        public int cbSize, flags; public IntPtr active, focus, capture, menuOwner, moveSize, caret; public Rect caretRect;
    }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(int thread,ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(int from,int to,bool attach);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("kernel32.dll")] static extern int GetCurrentThreadId();
    // The first child of `host` with the control ID, in the order Windows
    // enumerates them, or zero.
    public static IntPtr Child(IntPtr host,int id) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(c,p)=> { if(GetDlgCtrlID(c)==id) { found=c; return false; } return true; },IntPtr.Zero);
        return found;
    }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static uint Dpi(IntPtr h) { return GetDpiForWindow(h); }
    public static Rect RectOf(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; if(!GetWindowRect(h,out r)) throw new Exception("Window measurement failed"); return r; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    public static int ClientWidth(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; if(!GetClientRect(h,out r)) throw new Exception("Client measurement failed"); return r.Right-r.Left; }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    // Resizes `host` so its client area is `clientWidth` wide, keeping its position.
    public static void SetClientWidth(IntPtr host,int clientWidth) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect w; Rect c; GetWindowRect(host,out w); GetClientRect(host,out c);
            int frame=(w.Right-w.Left)-(c.Right-c.Left);
            if(!SetWindowPos(host,IntPtr.Zero,w.Left,w.Top,clientWidth+frame,w.Bottom-w.Top,0x14)) throw new Exception("SetWindowPos failed");
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static string Text(IntPtr h) {
        var sb=new StringBuilder(512); SendMessageW(h,0x0D,new IntPtr(512),sb); return sb.ToString();
    }
    public static void SetText(IntPtr h,string text) { SendMessageW(h,0x0C,IntPtr.Zero,text); }
    public static void Click(IntPtr h) { if(!PostMessageW(h,0xF5,IntPtr.Zero,IntPtr.Zero)) throw new Exception("BM_CLICK post failed"); }
    public static void Key(IntPtr h,int key) {
        if(!PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
    // A left click at client point (x, y) of `h`, as three posted messages.
    public static void LeftClick(IntPtr h,int x,int y) {
        var pos=new IntPtr(((y&0xFFFF)<<16)|(x&0xFFFF));
        if(!PostMessageW(h,0x200,IntPtr.Zero,pos)) throw new Exception("Mouse-move post failed");
        if(!PostMessageW(h,0x201,new IntPtr(1),pos)) throw new Exception("Button-down post failed");
        if(!PostMessageW(h,0x202,IntPtr.Zero,pos)) throw new Exception("Button-up post failed");
    }
    public static void Chars(IntPtr h,string text) {
        foreach(char ch in text) if(!PostMessageW(h,0x102,new IntPtr(ch),new IntPtr(1))) throw new Exception("Char post failed");
    }
    // The window with the keyboard focus in the UI thread that owns `h`.
    public static IntPtr FocusOf(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid);
        var info=new GuiThreadInfo(); info.cbSize=Marshal.SizeOf<GuiThreadInfo>();
        if(!GetGUIThreadInfo(tid,ref info)) throw new Exception("GetGUIThreadInfo failed");
        return info.focus;
    }
    // Moves the keyboard focus of the UI thread that owns `h` to `h` without
    // injecting input: this thread joins that thread's input queue for the call.
    public static void FocusOn(IntPtr h) {
        int pid; int tid=GetWindowThreadProcessId(h,out pid); int me=GetCurrentThreadId();
        if(!AttachThreadInput(me,tid,true)) throw new Exception("AttachThreadInput failed");
        try { SetFocus(h); } finally { AttachThreadInput(me,tid,false); }
    }
}
'@
if (-not $Driver) {
    # ExtraConfig goes in a file to keep arbitrary quotes and backslashes out of the driver's command line.
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
        -DesktopPrefix 'noctty-tabx-' -Label 'Hidden single-tab close' -PassDesktopName -GuardClipboard `
        -DriverArguments @("-Scenario $Scenario") -RunFiles @{ 'extra-config.txt' = $ExtraConfig }
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
$ExtraConfig = [IO.File]::ReadAllText((Join-Path $Run 'extra-config.txt'))
[void][Ds]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$desktopPath="WinSta0\$DesktopName"
$runClass='noctty-test-tabx-' + [guid]::NewGuid().ToString('N').Substring(0,8)
# Control IDs (src/apprt/win32/host.zig, src/apprt/win32/overlay_session.zig):
# the tab buttons are 1000 + index, the confirm prompt's Allow button is 2003.
$Id=@{ Tab0=1000; Accept=2003 }
function Pane($h) {
    $all=@([HiddenLocal]::Surfaces($h)); $shown=@($all|Where-Object {[Ds]::Visible($_)})
    if($shown.Count) { return $shown[0] }
    if($all.Count) { return $all[0] }
    throw 'Host has no pane.'
}
function Launch-Case([string]$Name,[string[]]$Extra) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    $config=Join-Path $dir 'case.ghostty'
    # F5 runs what Ctrl+Shift+W runs by default (close_tab:this). A posted
    # Ctrl is invisible to GetKeyboardState, so the key is bound plain.
    @("working-directory = $dir",'single-instance = false','window-save-state = never',
      'copy-on-select = false','clipboard-read = deny','clipboard-write = deny',
      'keybind = f5=close_tab:this') + $Extra + @($ExtraConfig -split ';' | Where-Object { $_.Trim() }) | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    $pi=[HiddenLocal]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,$config,$runClass),$dir,$desktopPath)
    $script:processes.Add(@{Case=$Name;Pid=$pi.pid})
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
            [void][Ds]::ShowWindow($hosts[0],4)
            Start-Sleep -Milliseconds 1500
            return @{Pi=$pi; Pid=$pi.pid; Host=$hosts[0]}
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline)
    Close-Case @{Pi=$pi; Pid=$pi.pid}
    throw "Window startup failed for case $Name."
}
function Close-Case($case) {
    foreach($h in [HiddenLocal]::Hosts($case.Pid)) { [void][Ds]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if([HiddenLocal]::WaitForSingleObject($case.Pi.process,5000) -eq 258) {
        # The handle is this launch's own process: no name or pattern match.
        [void][HiddenLocal]::TerminateProcess($case.Pi.process,1)
        [void][HiddenLocal]::WaitForSingleObject($case.Pi.process,5000)
    }
    [void][HiddenLocal]::CloseHandle($case.Pi.thread); [void][HiddenLocal]::CloseHandle($case.Pi.process)
}
function Scaled([int]$base,[uint32]$dpi) { if($dpi -le 96){return $base}; return [int][Math]::Truncate($base*$dpi/96.0) }

# Does the close zone of the tab button draw a x? Counted by the pixels the
# zone is hit-tested at, not by looking: the hit test is what a click reaches.
# Performs `Action` ('x' or 'key') and samples the window for `Seconds`.
function Measure-Close($case,[string]$Action,[int]$Seconds=10) {
    $h=$case.Host; $dpi=[Ds]::Dpi($h)
    $tab=[Ds]::Child($h,$Id.Tab0)
    $tabShown=$tab -ne [IntPtr]::Zero -and [Ds]::Visible($tab)
    $tabRect=if($tabShown){[Ds]::RectOf($tab)}else{$null}
    $started=[datetime]::UtcNow
    if($Action -eq 'x') {
        if(-not $tabShown) { throw 'No tab button to click.' }
        $w=$tabRect.Right-$tabRect.Left; $ht=$tabRect.Bottom-$tabRect.Top
        [Ds]::LeftClick($tab,$w-(Scaled 12 $dpi),[int]($ht/2))
    } else {
        [Ds]::Key((Pane $h),0x74)        # F5: close_tab:this
    }
    $timeline=[Collections.Generic.List[object]]::new()
    $exitCode=$null; $exitedAt=$null; $hostGoneAt=$null; $promptAt=$null; $tabGoneAt=$null
    do {
        $ms=[int]([datetime]::UtcNow-$started).TotalMilliseconds
        $alive=[Ds]::Alive($h)
        $vis=$alive -and [Ds]::Visible($h)
        $t=if($alive){[Ds]::Child($h,$Id.Tab0)}else{[IntPtr]::Zero}
        $tv=$t -ne [IntPtr]::Zero -and [Ds]::Visible($t)
        $a=if($alive){[Ds]::Child($h,$Id.Accept)}else{[IntPtr]::Zero}
        $av=$a -ne [IntPtr]::Zero -and [Ds]::Visible($a)
        $exited=[HiddenLocal]::WaitForSingleObject($case.Pi.process,0) -ne 258
        if($av -and $null -eq $promptAt) { $promptAt=$ms }
        if(-not $tv -and $null -eq $tabGoneAt) { $tabGoneAt=$ms }
        if(-not $alive -and $null -eq $hostGoneAt) { $hostGoneAt=$ms }
        if($exited -and $null -eq $exitedAt) { $exitedAt=$ms; [uint32]$code=0; [void][HiddenLocal]::GetExitCodeProcess($case.Pi.process,[ref]$code); $exitCode=$code }
        $timeline.Add(@{Ms=$ms;HostAlive=$alive;HostVisible=$vis;TabShown=$tv;PromptShown=$av;ProcessExited=$exited})
        if($exited) { break }
        Start-Sleep -Milliseconds 100
    } while($ms -lt ($Seconds*1000))
    # Collapse the timeline to its changes.
    $changes=[Collections.Generic.List[object]]::new(); $prev=$null
    foreach($s in $timeline) {
        $key="$($s.HostAlive)|$($s.HostVisible)|$($s.TabShown)|$($s.PromptShown)|$($s.ProcessExited)"
        if($key -ne $prev) { $changes.Add($s); $prev=$key }
    }
    return @{ Action=$Action; TabShownBefore=$tabShown; Dpi=$dpi; TabPromptMs=$promptAt; TabGoneMs=$tabGoneAt; HostGoneMs=$hostGoneAt; ProcessExitedMs=$exitedAt; ExitCode=$exitCode; LastMs=$ms; Changes=$changes }
}


$busy=@('command = cmd.exe /d /c ping -n 3600 127.0.0.1 >nul','shell-integration = none')
$idle=@('command = cmd.exe','shell-integration = detect')
function Add-Sample($result,[string]$Name) { $result.Name=$Name; $script:samples.Add($result) }
function Prompt-Shown($h) { $a=[Ds]::Child($h,$Id.Accept); return $a -ne [IntPtr]::Zero -and [Ds]::Visible($a) }
function Press-Prompt($h,[int]$Control) { [Ds]::Click([Ds]::Child($h,$Control)) }
# How long the host stayed up with its tab button gone, in ms; 0 when the tab
# button went with the window.
function Empty-Frame-Ms($r) {
    if($null -eq $r.TabGoneMs) { return 0 }
    $end=if($null -ne $r.HostGoneMs){$r.HostGoneMs}else{$r.LastMs}
    return [Math]::Max(0,$end-$r.TabGoneMs)
}
try {
    # With nothing running the X closes the window at once: no prompt, and no
    # empty frame left on screen for the undo window.
    $case=Launch-Case 'idle-x' ($idle + 'confirm-close-surface = true')
    try {
        $r=Measure-Close $case 'x'; Add-Sample $r 'idle-x'
        Check 'idle X: the only tab has an X to click' $r.TabShownBefore $true $r.TabShownBefore
        Check 'idle X: no prompt for an idle shell' ($null -eq $r.TabPromptMs) $null $r.TabPromptMs
        Check 'idle X: the window closes within 3 s' ($null -ne $r.HostGoneMs -and $r.HostGoneMs -lt 3000) '< 3000' $r.HostGoneMs
        Check 'idle X: no empty window stays on screen' ((Empty-Frame-Ms $r) -lt 1000) '< 1000' (Empty-Frame-Ms $r)
        Check 'idle X: the process exits cleanly' ($null -ne $r.ProcessExitedMs -and $r.ProcessExitedMs -lt 3000 -and $r.ExitCode -eq 0) 'exit 0 in < 3000 ms' @{Ms=$r.ProcessExitedMs;Code=$r.ExitCode}
    } finally { Close-Case $case }

    # With a process running it asks once, for the window; Cancel keeps
    # everything, Close ends the process and the window.
    $case=Launch-Case 'busy-x' ($busy + 'confirm-close-surface = true')
    try {
        $h=$case.Host
        $r=Measure-Close $case 'x' 3; Add-Sample $r 'busy-x'
        Check 'busy X: it asks first' ($null -ne $r.TabPromptMs -and $r.TabPromptMs -lt 2000) '< 2000' $r.TabPromptMs
        Check 'busy X: nothing closes while it asks' ($null -eq $r.HostGoneMs -and $null -eq $r.ProcessExitedMs -and $null -eq $r.TabGoneMs) 'nothing' @{Host=$r.HostGoneMs;Process=$r.ProcessExitedMs;Tab=$r.TabGoneMs}
        Press-Prompt $h 2004                           # Cancel
        $gone=Wait-Until { -not (Prompt-Shown $h) } 4
        Check 'busy X: Cancel dismisses the prompt' $gone $true $gone
        Start-Sleep -Milliseconds 500
        $tab=[Ds]::Child($h,$Id.Tab0)
        Check 'busy X: Cancel keeps the tab, the window and the process' ([Ds]::Alive($h) -and $tab -ne [IntPtr]::Zero -and [Ds]::Visible($tab) -and [HiddenLocal]::WaitForSingleObject($case.Pi.process,0) -eq 258) $true $null
        $r2=Measure-Close $case 'x' 3                  # ask again, then accept
        Check 'busy X: the X asks again' ($null -ne $r2.TabPromptMs) 'prompt' $r2.TabPromptMs
        Press-Prompt $h 2003                           # Close
        $closed=Wait-Until { -not [Ds]::Alive($h) -and [HiddenLocal]::WaitForSingleObject($case.Pi.process,0) -ne 258 } 8
        [uint32]$busyCode=0xFFFF; [void][HiddenLocal]::GetExitCodeProcess($case.Pi.process,[ref]$busyCode)
        Check 'busy X: Close ends the window and the process, cleanly' ($closed -and $busyCode -eq 0) 'window gone, exit 0' @{Closed=$closed;Code=$busyCode}
    } finally { Close-Case $case }

    if($Scenario -eq 'full') {
    # The keyboard path is unchanged: the tab goes, the window waits out the
    # undo window, and a running process is not asked about while undo is on.
    $case=Launch-Case 'busy-key' ($busy + 'confirm-close-surface = true')
    try {
        $r=Measure-Close $case 'key'; Add-Sample $r 'busy-key'
        Check 'busy key: no prompt while undo is on' ($null -eq $r.TabPromptMs) $null $r.TabPromptMs
        Check 'busy key: the window waits for undo before it goes' ($null -ne $r.HostGoneMs -and $r.HostGoneMs -gt 4000) '> 4000' $r.HostGoneMs
    } finally { Close-Case $case }
    $case=Launch-Case 'busy-undo-off-key' ($busy + 'confirm-close-surface = true' + 'undo-timeout = 0s')
    try {
        $r=Measure-Close $case 'key' 3; Add-Sample $r 'busy-undo-off-key'
        Check 'busy key, undo off: it asks' ($null -ne $r.TabPromptMs) 'prompt' $r.TabPromptMs
    } finally { Close-Case $case }
    }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Posted window messages on a never-switched desktop; real pointer and keyboard input, the clipboard and visual composition are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'single-tab-close-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){ $failed | ForEach-Object { Write-Host ("FAIL: " + $_.Name) }; exit 1 }
