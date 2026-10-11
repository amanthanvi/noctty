#requires -Version 7.0
<#
Portable, hidden-desktop integration regression for quick-terminal geometry and
fullscreen restore across physical monitors. Run with -Bin <source bin directory>
-Run <new evidence directory>. The run directory must not already exist. Requires
two monitors with different DPI; never switches desktops or injects real input.
Results contain only monitor geometry, process IDs, window state and assertions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver
)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class DpiGeometry {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Placement {
        public int length, flags, showCmd; public Point min,max; public Rect normal;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo {
        public int cb; public Rect full,work; public int flags;
    }
    public class Monitor { public Rect Full,Work; public uint Dpi; public bool Primary; }
    public class State { public Rect Rect,Normal; public uint Dpi; public int Show; public bool Visible,Zoomed; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    public delegate bool EnumMonitor(IntPtr h, IntPtr dc, ref Rect r, IntPtr p);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumMonitor cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr h, ref MonitorInfo i);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr h, int type, out uint x, out uint y);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref Placement p);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action,uint param,out int value,uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct Contrast { public int size,flags; public IntPtr scheme; }
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action,uint param,ref Contrast value,uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr dev,IntPtr mode,int flags,uint access,IntPtr sa);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    public static Monitor[] Monitors() {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { var list=new List<Monitor>();
            EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr h,IntPtr dc,ref Rect r,IntPtr p)=>{
                var i=new MonitorInfo { cb=Marshal.SizeOf<MonitorInfo>() }; uint x,y;
                if(!GetMonitorInfoW(h,ref i)||GetDpiForMonitor(h,0,out x,out y)!=0) throw new Exception("Monitor measurement failed");
                list.Add(new Monitor { Full=i.full,Work=i.work,Dpi=x,Primary=(i.flags&1)!=0 }); return true;
            },IntPtr.Zero); return list.ToArray();
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static bool[] MotionPolicy() {
        int enabled; var contrast=new Contrast { size=Marshal.SizeOf<Contrast>() };
        bool animationQuery=SystemParametersInfoW(0x1042,0,out enabled,0);
        bool contrastQuery=SystemParametersInfoW(0x42,(uint)contrast.size,ref contrast,0);
        return new bool[] { animationQuery,enabled!=0,contrastQuery,(contrast.flags&1)!=0 };
    }
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Hosts(int pid) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)=="noctty.win32.host") list.Add(h); return true;
        },IntPtr.Zero); return list.ToArray();
    }
    public static IntPtr Surface(IntPtr h) { IntPtr found=IntPtr.Zero;
        EnumChildWindows(h,(c,p)=> { if(Class(c)=="noctty.win32") found=c; return true; },IntPtr.Zero); return found;
    }
    public static State Read(IntPtr h) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { Rect r; var p=new Placement { length=Marshal.SizeOf<Placement>() };
            if(!GetWindowRect(h,out r)||!GetWindowPlacement(h,ref p)) throw new Exception("Window measurement failed");
            return new State { Rect=r,Normal=p.normal,Dpi=GetDpiForWindow(h),Show=p.showCmd,Visible=IsWindowVisible(h),Zoomed=IsZoomed(h) };
        } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static void Move(IntPtr h,int x,int y,int w,int ht) {
        var old=SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { if(!SetWindowPos(h,IntPtr.Zero,x,y,w,ht,0x14)) throw new Exception("SetWindowPos failed"); }
        finally { SetThreadDpiAwarenessContext(old); }
    }
    public static void Key(IntPtr host,int key) {
        var h=Surface(host); if(h==IntPtr.Zero) throw new Exception("Terminal child absent");
        PostMessageW(h,0x100,new IntPtr(key),new IntPtr(1));
        PostMessageW(h,0x101,new IntPtr(key),new IntPtr(0xC0000001L));
    }
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,0x08004000,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        return pi;
    }
}
'@
function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); Modified=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o') }
}
function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}
if (-not $Driver) {
    $Bin = (Resolve-Path -LiteralPath $Bin).Path
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'noctty.exe'))) { throw 'Source Bin must contain noctty.exe.' }
    $before = Startup-Fingerprint
    if (-not $before.Exists -or $before.Hash -ne '7b4f9aa31731df822e3ec13f8381e76dc759455abbf8bb458f74e10bf5e2bb9c' -or ([datetime]$before.Modified).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -ne '2026-10-10T18:18:34Z') { throw 'Real startup state differs from adopted baseline; no launches performed.' }
    [void](New-Item -ItemType Directory -Path $Run)
    Copy-Portable $Bin (Join-Path $Run 'source\bin')
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-dpi-' + [guid]::NewGuid().ToString('N')
    $desktop = [DpiGeometry]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null
    try {
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Driver' -f $pwsh,$PSCommandPath,(Join-Path $Run 'source\bin'),$Run
        $pi=[DpiGeometry]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName")
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        while ([DpiGeometry]::WaitForSingleObject($pi.process,1000) -eq 258) { }
        [uint32]$code=0; [void][DpiGeometry]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        if($pi) { [void][DpiGeometry]::CloseHandle($pi.thread); [void][DpiGeometry]::CloseHandle($pi.process) }
        [void][DpiGeometry]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        @{ Before=$before; After=$after; Unchanged=($before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if ($before.Hash -ne $after.Hash -or $before.Modified -ne $after.Modified) { throw 'Real startup state changed; stop launches.' }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden DPI geometry: PASS'
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
[void][DpiGeometry]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
function Rect-Array($r) { return @($r.Left,$r.Top,$r.Right,$r.Bottom) }
function Rect-Equal($a,$b,[int]$Tolerance=2) {
    return [Math]::Abs($a.Left-$b.Left) -le $Tolerance -and [Math]::Abs($a.Top-$b.Top) -le $Tolerance -and [Math]::Abs($a.Right-$b.Right) -le $Tolerance -and [Math]::Abs($a.Bottom-$b.Bottom) -le $Tolerance
}
function New-Rect([int]$x,[int]$y,[int]$w,[int]$h) {
    $r=[DpiGeometry+Rect]::new(); $r.Left=$x; $r.Top=$y; $r.Right=$x+$w; $r.Bottom=$y+$h; return $r
}
function Move-Window($h,$r) { [DpiGeometry]::Move($h,$r.Left,$r.Top,$r.Right-$r.Left,$r.Bottom-$r.Top); Start-Sleep -Milliseconds 400 }
function Sample([string]$Name,$h) { $s=[DpiGeometry]::Read($h); $script:samples.Add(@{Name=$Name; State=$s}); return $s }
function Key($h,[int]$k) { [DpiGeometry]::Key($h,$k); Start-Sleep -Milliseconds 900 }
function Launch-Case([string]$Name,[string]$Extra='') {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    $config=Join-Path $dir 'geometry.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false','window-save-state = never','confirm-close-surface = false','keybind = f11=toggle_fullscreen','keybind = f10=toggle_quick_terminal','quick-terminal-screen = main','quick-terminal-autohide = false','quick-terminal-size = 25%', $Extra) | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'
    $p=Start-Process -FilePath $exe -ArgumentList @("--config-file=`"$config`"") -WorkingDirectory $dir -WindowStyle Hidden -PassThru
    $script:processes.Add(@{Case=$Name;Pid=$p.Id;StartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.ProcessName})
    $deadline=[datetime]::UtcNow.AddSeconds(15)
    do {
        $hosts=@([DpiGeometry]::Hosts($p.Id))
        if($hosts.Count -and [DpiGeometry]::Surface($hosts[0]) -ne [IntPtr]::Zero) {
            [void][DpiGeometry]::ShowWindow($hosts[0],4)
            Start-Sleep -Milliseconds 400
            return @{Process=$p; Host=$hosts[0]}
        }
        Start-Sleep -Milliseconds 100
    } while([datetime]::UtcNow -lt $deadline -and -not $p.HasExited)
    Close-Case @{Process=$p}
    throw "Window startup failed for case $Name."
}
function Close-Case($case) {
    foreach($h in [DpiGeometry]::Hosts($case.Process.Id)) { [void][DpiGeometry]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
    if(-not $case.Process.WaitForExit(5000)) {
        $p=Get-Process -Id $case.Process.Id -ErrorAction Stop
        if($p.StartTime -eq $case.Process.StartTime -and $p.Path -eq $case.Process.Path) { Stop-Process -Id $p.Id -Force }
        else { throw 'Exact process identity changed during cleanup.' }
    }
}
try {
    $monitors=@([DpiGeometry]::Monitors()); $primary=@($monitors|Where-Object Primary)[0]
    $other=@($monitors|Where-Object {$_.Dpi -ne $primary.Dpi} | Sort-Object {$_.Full.Left} -Descending)[0]
    if(-not $other) { throw 'Two different-DPI monitors are required.' }
    $monitors | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Run 'monitors.json')
    $motion=[DpiGeometry]::MotionPolicy()
    @{AnimationQuerySucceeded=$motion[0]; ClientAnimationsEnabled=$motion[1]; ContrastQuerySucceeded=$motion[2]; HighContrast=$motion[3]} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'motion-policy.json')
    $case=Launch-Case 'ordinary-moves'
    try {
        $r=New-Rect ($primary.Work.Left+150) ($primary.Work.Top+150) 900 600
        Move-Window $case.Host $r; Move-Window $case.Host $r
        $initial=Sample 'ordinary-primary' $case.Host
        Move-Window $case.Host (New-Rect ($other.Work.Left+150) ($other.Work.Top+150) 900 600)
        $changed=Sample 'ordinary-secondary' $case.Host
        Check 'ordinary primary-to-secondary DPI' ($changed.Dpi -eq $other.Dpi) $other.Dpi $changed.Dpi
        $width=[int][Math]::Round(900*$other.Dpi/[double]$primary.Dpi)
        Check 'ordinary primary-to-secondary suggested width' ([Math]::Abs(($changed.Rect.Right-$changed.Rect.Left)-$width) -le 3) $width ($changed.Rect.Right-$changed.Rect.Left)
        Move-Window $case.Host (New-Rect ($primary.Work.Left+150) ($primary.Work.Top+150) ($changed.Rect.Right-$changed.Rect.Left) ($changed.Rect.Bottom-$changed.Rect.Top))
        $returned=Sample 'ordinary-primary-return' $case.Host
        Check 'ordinary secondary-to-primary DPI' ($returned.Dpi -eq $primary.Dpi) $primary.Dpi $returned.Dpi
        Check 'ordinary secondary-to-primary suggested width' ([Math]::Abs(($returned.Rect.Right-$returned.Rect.Left)-900) -le 3) 900 ($returned.Rect.Right-$returned.Rect.Left)
    } finally {Close-Case $case}
    $restoreCases=@(
        @{Origin=$primary;Destination=$other;Width=900;Height=600;Label='normal'},
        @{Origin=$other;Destination=$primary;Width=900;Height=600;Label='normal'}
    )
    foreach($target in @($monitors|Where-Object {$_.Dpi -ne $primary.Dpi})) {
        $restoreCases+=@{Origin=$primary;Destination=$target;Width=($primary.Work.Right-$primary.Work.Left-40);Height=[Math]::Min(1200,$primary.Work.Bottom-$primary.Work.Top-40);Label='oversized'}
    }
    foreach($story in $restoreCases) {
        $origin=$story.Origin; $destination=$story.Destination
        foreach($maximized in @($false,$true)) {
            $name="fullscreen-$($origin.Dpi)-$($destination.Dpi)-$($destination.Work.Left)-$($story.Label)-$maximized"; $case=Launch-Case $name
            try {
                $h=$case.Host
                # Start on the chosen monitor, then set a known physical normal rect
                # after Windows has finished its ordinary WM_DPICHANGED suggestion.
                $r=New-Rect ($origin.Work.Left+150) ($origin.Work.Top+150) $story.Width $story.Height
                Move-Window $h $r; Move-Window $h $r; $initial=Sample "$name-initial" $h
                Check "$name ordinary DPI" ($initial.Dpi -eq $origin.Dpi) $origin.Dpi $initial.Dpi
                if($maximized){[void][DpiGeometry]::ShowWindow($h,3); Start-Sleep -Milliseconds 400}
                Key $h 122; $entered=Sample "$name-enter" $h
                Check "$name entered fullscreen" (Rect-Equal $entered.Rect $origin.Full) (Rect-Array $origin.Full) (Rect-Array $entered.Rect)
                Move-Window $h $destination.Full; $moved=Sample "$name-moved" $h
                Check "$name fullscreen destination DPI" ($moved.Dpi -eq $destination.Dpi) $destination.Dpi $moved.Dpi
                Key $h 122; $left=Sample "$name-left" $h
                if($maximized){Check "$name restore maximized" $left.Zoomed $true $left.Zoomed; [void][DpiGeometry]::ShowWindow($h,9); Start-Sleep -Milliseconds 400}
                $restored=Sample "$name-restored" $h
                $scale=$destination.Dpi/[double]$origin.Dpi
                $expectedWidth=[Math]::Min($destination.Work.Right-$destination.Work.Left,[int][Math]::Round($story.Width*$scale))
                $expectedHeight=[Math]::Min($destination.Work.Bottom-$destination.Work.Top,[int][Math]::Round($story.Height*$scale))
                $expectedLeft=[Math]::Max($destination.Work.Left,[Math]::Min($destination.Work.Left+150,$destination.Work.Right-$expectedWidth))
                $expectedTop=[Math]::Max($destination.Work.Top,[Math]::Min($destination.Work.Top+150,$destination.Work.Bottom-$expectedHeight))
                $expected=New-Rect $expectedLeft $expectedTop $expectedWidth $expectedHeight
                Check "$name restore geometry" (Rect-Equal $restored.Rect $expected) (Rect-Array $expected) (Rect-Array $restored.Rect)
                Check "$name restore DPI" ($restored.Dpi -eq $destination.Dpi) $destination.Dpi $restored.Dpi
                # Ordinary reverse move remains subject to the OS DPI suggestion.
                $before=Sample "$name-before-ordinary" $h
                Move-Window $h (New-Rect ($origin.Work.Left+150) ($origin.Work.Top+150) ($before.Rect.Right-$before.Rect.Left) ($before.Rect.Bottom-$before.Rect.Top))
                $ordinary=Sample "$name-ordinary" $h
                Check "$name ordinary reverse DPI" ($ordinary.Dpi -eq $origin.Dpi) $origin.Dpi $ordinary.Dpi
                $ordinaryWidth=[int][Math]::Round(($before.Rect.Right-$before.Rect.Left)*$origin.Dpi/[double]$before.Dpi)
                Check "$name ordinary width scaling" ([Math]::Abs(($ordinary.Rect.Right-$ordinary.Rect.Left)-$ordinaryWidth) -le 3) $ordinaryWidth ($ordinary.Rect.Right-$ordinary.Rect.Left)
            } finally { Close-Case $case }
        }
    }
    foreach($edge in @('top','bottom','left','right')) { foreach($duration in @('0','0.6')) {
        $name="quick-$edge-$duration"; $case=Launch-Case $name "quick-terminal-position = $edge`nquick-terminal-animation-duration = $duration"
        try {
            $h=$case.Host; Key $h 121
            $qt=@([DpiGeometry]::Hosts($case.Process.Id)|Where-Object {$_ -ne $h})[0]
            $deadline=[datetime]::UtcNow.AddSeconds(10)
            while((-not $qt -or [DpiGeometry]::Surface($qt) -eq [IntPtr]::Zero) -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 100
                $qt=@([DpiGeometry]::Hosts($case.Process.Id)|Where-Object {$_ -ne $h})[0]
            }
            if(-not $qt -or [DpiGeometry]::Surface($qt) -eq [IntPtr]::Zero){throw "Quick terminal absent: $name"}
            Start-Sleep -Milliseconds 600
            Move-Window $qt (New-Rect ($other.Work.Left+100) ($other.Work.Top+100) 600 400)
            $prior=Sample "$name-other-monitor" $qt
            Check "$name prior cross-DPI" ($prior.Dpi -eq $other.Dpi) $other.Dpi $prior.Dpi
            Key $h 121
            Check "$name hidden" (-not ([DpiGeometry]::Read($qt)).Visible) $false ([DpiGeometry]::Read($qt)).Visible
            [DpiGeometry]::Key($h,121)
            $frames=[Collections.Generic.List[object]]::new(); $watch=[Diagnostics.Stopwatch]::StartNew()
            while($watch.ElapsedMilliseconds -lt 1000){ $frames.Add([DpiGeometry]::Read($qt)); Start-Sleep -Milliseconds 10 }
            $script:samples.Add(@{Name="$name-animation"; Frames=$frames})
            $wa=$primary.Work; $w=$wa.Right-$wa.Left; $ht=$wa.Bottom-$wa.Top
            $quarterWidth=[int][Math]::Floor($w/4.0+0.5); $quarterHeight=[int][Math]::Floor($ht/4.0+0.5)
            $expected=switch($edge){
                top {New-Rect $wa.Left $wa.Top $w $quarterHeight}
                bottom {New-Rect $wa.Left ($wa.Bottom-$quarterHeight) $w $quarterHeight}
                left {New-Rect $wa.Left $wa.Top $quarterWidth $ht}
                right {New-Rect ($wa.Right-$quarterWidth) $wa.Top $quarterWidth $ht}
            }
            $final=Sample "$name-final" $qt
            Check "$name final geometry" (Rect-Equal $final.Rect $expected) (Rect-Array $expected) (Rect-Array $final.Rect)
            Check "$name final DPI" ($final.Dpi -eq $primary.Dpi) $primary.Dpi $final.Dpi
            if($duration -ne '0'){
                $dpis=@($frames|Where-Object Visible|ForEach-Object Dpi|Select-Object -Unique)
                $unique=@($frames|Where-Object Visible|ForEach-Object {($_.Rect.Left,$_.Rect.Top,$_.Rect.Right,$_.Rect.Bottom) -join ','}|Select-Object -Unique)
                $script:samples.Add(@{Name="$name-motion-coverage"; UniqueVisibleRectangles=$unique.Count; ObservedDpis=$dpis; ClientAnimationsEnabled=$motion[1]; HighContrast=$motion[3]})
                if($motion[0] -and $motion[1] -and $motion[2] -and -not $motion[3]) {
                    Check "$name motion exercised" ($unique.Count -ge 3) 'At least three visible frame rectangles' $unique.Count
                    $wrong=@($frames|Where-Object {$_.Visible -and ([Math]::Abs(($_.Rect.Right-$_.Rect.Left)-($expected.Right-$expected.Left)) -gt 2 -or [Math]::Abs(($_.Rect.Bottom-$_.Rect.Top)-($expected.Bottom-$expected.Top)) -gt 2)})
                    Check "$name tween physical dimensions" ($wrong.Count -eq 0) @(($expected.Right-$expected.Left),($expected.Bottom-$expected.Top)) $wrong.Count
                }
            }
        } finally {Close-Case $case}
    }}
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    $remaining=@($script:processes | Where-Object {Get-Process -Id $_.Pid -ErrorAction SilentlyContinue})
    Check 'owned runtime processes exited' ($remaining.Count -eq 0) 0 $remaining.Count
    @{Checks=$script:checks; Samples=$script:samples; Processes=$script:processes; Limit='Posted unmodified keys and Win32 placement on a never-switched desktop; real pointer, shell snap and visual composition are not exercised. Actual tween frames require enabled Windows client animations; inspect motion-policy.json and motion-coverage samples.'} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'geometry-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count){exit 1}
