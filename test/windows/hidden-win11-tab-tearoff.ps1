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
    // A key as a posted WM_KEYDOWN/WM_KEYUP pair (a posted triple types it twice).
    public static void Key(IntPtr h,int key) {
        if(!PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1))) throw new Exception("Key-down post failed");
        if(!PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L))) throw new Exception("Key-up post failed");
    }
}
'@
if (-not $Driver) {
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
        -DesktopPrefix 'noctty-tearoff-' -Label 'Hidden tab tear-off' -PassDesktopName -GuardClipboard `
        -DriverArguments @("-Renderer $Renderer")
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][Tt]::SetThreadDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$desktopPath="WinSta0\$DesktopName"
$runClass='noctty-test-tearoff-' + [guid]::NewGuid().ToString('N').Substring(0,8)
# Tab buttons are 1000 + their index (src/apprt/win32/host.zig).
$TabButton=1000
$WM_MOUSEMOVE=0x200; $WM_LBUTTONDOWN=0x201; $WM_LBUTTONUP=0x202
$VK_F6=0x75; $VK_F7=0x76; $VK_F9=0x78; $VK_ESCAPE=0x1B

function Launch-Case([string]$Name,[string]$RendererName) {
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
      "command = direct:$cmd /d /k echo TEAROFF-%RANDOM%-%RANDOM%",
      "renderer = $RendererName",
      'keybind = f6=new_tab','keybind = f7=move_tab_to_new_window','keybind = f9=close_surface') | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    $pi=[HiddenLocal]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false --window-save-state=never --class={2}' -f $exe,$config,$runClass),$dir,$desktopPath)
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
            [void][Tt]::ShowWindow($hosts[0],4)
            [void][Tt]::SetWindowPos($hosts[0],[IntPtr]::Zero,40,40,900,600,0x14)
            Start-Sleep -Milliseconds 1500
            return @{Pi=$pi; Pid=$pi.pid; Dir=$dir}
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
    [void][HiddenLocal]::CloseHandle($case.Pi.thread); [void][HiddenLocal]::CloseHandle($case.Pi.process)
}
# The cmd.exe processes under the case's noctty process: PIDs only.
function Shell-Pids($case) {
    $all=@(Get-CimInstance Win32_Process -OperationTimeoutSec 5 | Select-Object ProcessId, ParentProcessId, Name)
    $byParent=@{}
    foreach($p in $all) { $k=[int]$p.ParentProcessId; if(-not $byParent.ContainsKey($k)) { $byParent[$k]=[Collections.Generic.List[object]]::new() }; $byParent[$k].Add($p) }
    $found=[Collections.Generic.List[int]]::new(); $queue=[Collections.Generic.Queue[int]]::new(); $queue.Enqueue([int]$case.Pid)
    $seen=[Collections.Generic.HashSet[int]]::new(); [void]$seen.Add([int]$case.Pid)
    while($queue.Count) {
        $parent=$queue.Dequeue()
        if(-not $byParent.ContainsKey($parent)) { continue }
        foreach($child in $byParent[$parent]) {
            $id=[int]$child.ProcessId
            if(-not $seen.Add($id)) { continue }
            if($child.Name -ieq 'cmd.exe') { $found.Add($id) }
            $queue.Enqueue($id)
        }
    }
    return @($found | Sort-Object)
}
# The terminal's text through its UIA TextPattern, and the marker in it.
function Marker([IntPtr]$Pane) {
    $element=[System.Windows.Automation.AutomationElement]::FromHandle($Pane)
    $pattern=$null
    if(-not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$pattern)) { return $null }
    $text=$pattern.DocumentRange.GetText(-1)
    $m=[regex]::Match($text,'TEAROFF-\d+-\d+')
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
    $origin=[Tt]::RectOf($button)
    [Tt]::Mouse($button,$WM_MOUSEMOVE,20,10,0)
    [Tt]::Mouse($button,$WM_LBUTTONDOWN,20,10,1)
    [Tt]::Mouse($button,$WM_MOUSEMOVE,40,40,1)
    [Tt]::Mouse($button,$WM_MOUSEMOVE,$X-$origin.Left,$Y-$origin.Top,1)
    Start-Sleep -Milliseconds 300
    if($Escape) { [Tt]::Key($EscapeTo,$VK_ESCAPE); Start-Sleep -Milliseconds 200 }
    [Tt]::Mouse($button,$WM_LBUTTONUP,$X-$origin.Left,$Y-$origin.Top,0)
}
function Same-Set($a,$b) { return (@($a) -join ',') -eq (@($b) -join ',') }

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
        Check "${RendererName} action: the moved shell's output is still there" ((Marker $p2) -eq $m2) 'same marker' $null

        # 2. A drag out of the window, to the right of it: a new window there.
        $p3=New-Pane $case $p1
        $m3=Wait-Marker $p3
        [void](Wait-Until { (Shell-Pids $case).Count -gt $pids.Count } 10)
        Start-Sleep -Milliseconds 500
        $pids=Shell-Pids $case
        $r1=[Tt]::RectOf($h1)
        $dropX=$r1.Right+120; $dropY=$r1.Top+80
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
        Check "${RendererName} drag: the moved shell's output is still there" ((Marker $p3) -eq $m3) 'same marker' $null

        # 3. Esc during a drag: nothing moves.
        $p4=New-Pane $case $p1
        $m4=Wait-Marker $p4
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
        Check "${RendererName} drop: the moved shell's output is still there" ((Marker $p4) -eq $m4) 'same marker' $null
        Check "${RendererName}: every moved shell kept its output" ((Marker $p1) -eq $m1 -and (Marker $p2) -eq $m2 -and (Marker $p3) -eq $m3) 'same markers' $null

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

try {
    $renderers=if($Renderer -eq 'both') { @('opengl','d3d11') } else { @($Renderer) }
    foreach($name in $renderers) { Measure-Case $name }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Posted window messages on a never-switched desktop; real pointer and keyboard input, the system window move, the clipboard and visual composition (a D3D11 present) are not exercised.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'tab-tearoff-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
$passed=@($script:checks|Where-Object {$_.Passed})
Write-Host ("checks passed {0}/{1}" -f $passed.Count,$script:checks.Count)
if($failed.Count){ $failed | ForEach-Object { Write-Host ("FAIL: " + $_.Name) }; exit 1 }
