#requires -Version 7.0
<#
TABGAP geometry, procedure-hit and offscreen GDI paint measurements. Uses an
isolated measurement-AUMID ReleaseFast bin, never switches desktops or injects
input. A hidden desktop cannot prove real pointer routing or composed output.
Keep every run, including failures. -ExpectFlush checks the changed behavior;
without it the same checks characterize the baseline geometry.

Build the committed revision from a clean checkout (the helper archives HEAD,
patches the measurement identity in an isolated tree and validates provenance):
  . .\scripts\interactive-win11-measure-lib.ps1
  Invoke-InteractiveWin11MeasureBuild -RepoRoot $PWD.Path -Optimize ReleaseFast
  $measureBin = Split-Path (Get-InteractiveWin11MeasureExePath -RepoRoot $PWD.Path)
  .\test\windows\hidden-win11-tabgap.ps1 -Bin $measureBin `
      -Run .\.tabgap-evidence\measure-r2-<new-run-name> -ExpectFlush
Keep the run directory new and preserve failed runs. Builds use the normal
shell; only this harness's driver and app copies run on the private desktop.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bin,
    [Parameter(Mandatory)][string]$Run,
    [switch]$Driver,
    [string]$DesktopName,
    [switch]$ExpectFlush,
    [int]$DriverTimeoutSeconds=300
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
# Reuse the executable-byte identity check, including its HiddenWin helper.
# Dot-sourcing only defines helpers; the hosted launcher is never invoked.
. (Join-Path $PSScriptRoot 'hidden-win11-lib.ps1')
Assert-MeasureAumid (Join-Path $Bin 'noctty.exe')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;

public static class TabGap {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; public Point(int x,int y){X=x;Y=y;} }
 [StructLayout(LayoutKind.Sequential)] public struct Placement { public int length,flags,show; public Point min,max; public Rect normal; }
 [StructLayout(LayoutKind.Sequential)] struct GUI { public int size,flags; public IntPtr active,focus,capture,menuOwner,moveSize,caret; public Rect caretRect; }
 [StructLayout(LayoutKind.Sequential)] struct MI { public int size; public Rect full,work; public uint flags; }
 public class Monitor { public Rect Full,Work; public uint Dpi; }
 public class Child { public long Hwnd; public int Id; public string Class; public Rect Rect; }
 public class State { public Rect Window,Client; public Point Origin; public Placement Placement; public uint Dpi; public bool Zoomed; public Child[] Children; }
 public class Hit { public int Y,Code,HostCode; public long Target,WindowFromPoint; public string Chain; }
 public class CaptionRun { public int Left,Right,Y; public int X { get { return Left+(Right-Left)/2; } } }
 public delegate bool EnumWindow(IntPtr h,IntPtr p);
 delegate bool EnumMonitor(IntPtr h,IntPtr dc,ref Rect r,IntPtr p);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc,IntPtr clip,EnumMonitor cb,IntPtr p);
 [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr h,ref MI i);
 [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr h,int kind,out uint x,out uint y);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h,ref Placement p);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow cb,IntPtr p);
 [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr ReadTextTimeout(IntPtr h,uint m,IntPtr chars,[Out] StringBuilder text,uint flags,uint ms,out IntPtr result);
 // Use WM_GETTEXT for cross-process control text; Windows marshals its
 // writable UTF-16 buffer, and both the capacity and wait are bounded.
 public static bool MarkedActive(IntPtr h){var s=new StringBuilder(1024);IntPtr count;if(ReadTextTimeout(h,0xD,new IntPtr(s.Capacity),s,3,2000,out count)==IntPtr.Zero)throw new Exception("Tab WM_GETTEXT failed or timed out");return s.ToString().StartsWith("* ",StringComparison.Ordinal);}
 [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h,uint kind);
 [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int show);
 [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int ht,uint flags);
 [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread,ref GUI info);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from,uint to,bool attach);
 [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
 [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
 public static int MenuFlags(IntPtr host){return MenuInfo(host).flags;}
 static GUI MenuInfo(IntPtr host){uint pid;var tid=GetWindowThreadProcessId(host,out pid);var i=new GUI{size=Marshal.SizeOf<GUI>()};if(!GetGUIThreadInfo(tid,ref i))throw new Exception("Menu state unavailable");return i;}
 public static long MenuOwner(IntPtr host){return MenuInfo(host).menuOwner.ToInt64();}
 static string ClassOf(IntPtr h){var s=new StringBuilder(128);GetClassNameW(h,s,128);return s.ToString();}
 public static Monitor[] Monitors(){var list=new List<Monitor>();EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr h,IntPtr dc,ref Rect r,IntPtr p)=>{var i=new MI{size=Marshal.SizeOf<MI>()};uint x,y;if(!GetMonitorInfoW(h,ref i)||GetDpiForMonitor(h,0,out x,out y)!=0)throw new Exception("Monitor read failed");list.Add(new Monitor{Full=i.full,Work=i.work,Dpi=x});return true;},IntPtr.Zero);return list.ToArray();}
 public static State Read(IntPtr h){Rect w,c;var o=new Point();var p=new Placement{length=Marshal.SizeOf<Placement>()};if(!GetWindowRect(h,out w)||!GetClientRect(h,out c)||!ClientToScreen(h,ref o)||!GetWindowPlacement(h,ref p))throw new Exception("Geometry read failed");var list=new List<Child>();EnumChildWindows(h,(a,b)=>{if(IsWindowVisible(a)){Rect r;GetWindowRect(a,out r);r.Left-=o.X;r.Right-=o.X;r.Top-=o.Y;r.Bottom-=o.Y;list.Add(new Child{Hwnd=a.ToInt64(),Id=GetDlgCtrlID(a),Class=ClassOf(a),Rect=r});}return true;},IntPtr.Zero);return new State{Window=w,Client=c,Origin=o,Placement=p,Dpi=GetDpiForWindow(h),Zoomed=IsZoomed(h),Children=list.ToArray()};}
 public static void Move(IntPtr h,int x,int y){if(!SetWindowPos(h,IntPtr.Zero,x,y,900,600,0x14))throw new Exception("Move failed");}
 public static IntPtr Pos(int x,int y){return new IntPtr(unchecked((int)(((uint)(y&65535)<<16)|(uint)(x&65535))));}
 public static int HitCode(IntPtr h,int x,int y){IntPtr r;if(SendMessageTimeoutW(h,0x84,IntPtr.Zero,Pos(x,y),2,1000,out r)==IntPtr.Zero)throw new Exception("Hit test timeout");return r.ToInt32();}
 // Enumerate immediate children in z order. A transparent STATIC must permit
 // siblings below it, rather than skipping straight to the parent caption.
 static IntPtr Resolve(IntPtr h,int x,int y,List<string> chain,out int code){for(var c=GetWindow(h,5);c!=IntPtr.Zero;c=GetWindow(c,2)){Rect r;if(!IsWindowVisible(c)||!GetWindowRect(c,out r)||x<r.Left||x>=r.Right||y<r.Top||y>=r.Bottom)continue;int childCode;var target=Resolve(c,x,y,chain,out childCode);if(childCode!=-1){code=childCode;return target;}}code=HitCode(h,x,y);chain.Add(h.ToInt64()+":"+GetDlgCtrlID(h)+":"+code);return h;}
 public static Hit[] Scan(IntPtr h,int localX,int height){var s=Read(h);var list=new List<Hit>();for(int y=0;y<=height;y++){var chain=new List<string>();int code;int x=s.Origin.X+localX,sy=s.Origin.Y+y;var target=Resolve(h,x,sy,chain,out code);list.Add(new Hit{Y=y,Code=code,HostCode=HitCode(h,x,sy),Target=target.ToInt64(),WindowFromPoint=WindowFromPoint(new Point(x,sy)).ToInt64(),Chain=string.Join(",",chain)});}return list.ToArray();}
 // Find actual empty caption space instead of guessing from tab widths:
 // an action button may immediately follow the tabs on a narrow window.
 // Both independent target oracles must identify the host for every pixel
 // in the run. Right is exclusive; X is its interior midpoint.
 public static CaptionRun WidestCaptionRun(IntPtr h,int localY){
  var s=Read(h);if(localY<0||localY>=s.Client.Bottom)throw new Exception("Caption scan row outside client");
  CaptionRun best=null;int start=-1,sy=s.Origin.Y+localY;
  for(int x=s.Client.Left;x<=s.Client.Right;x++){
   bool caption=false;
   if(x<s.Client.Right){int code;var chain=new List<string>();int sx=s.Origin.X+x;var target=Resolve(h,sx,sy,chain,out code);caption=code==2&&target==h&&WindowFromPoint(new Point(sx,sy))==h;}
   if(caption){if(start<0)start=x;}
   else if(start>=0){if(best==null||x-start>best.Right-best.Left)best=new CaptionRun{Left=start,Right=x,Y=localY};start=-1;}
  }
  return best;
 }
 [StructLayout(LayoutKind.Sequential)] struct BitmapInfo { public uint size; public int width,height; public ushort planes,bpp; public uint compression,imageSize; public int xppm,yppm; public uint used,important; }
 [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
 [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc,ref BitmapInfo info,uint usage,out IntPtr bits,IntPtr section,uint offset);
 [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
 [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
 [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
 public static string[][] Paint(IntPtr h,string path,int[] localXs,int rows){var s=Read(h);int w=s.Window.Right-s.Window.Left,ht=s.Window.Bottom-s.Window.Top;var info=new BitmapInfo{size=40,width=w,height=-ht,planes=1,bpp=32};var dc=CreateCompatibleDC(IntPtr.Zero);IntPtr bits;var bitmap=CreateDIBSection(dc,ref info,0,out bits,IntPtr.Zero,0);if(dc==IntPtr.Zero||bitmap==IntPtr.Zero)throw new Exception("Capture allocation failed");var old=SelectObject(dc,bitmap);try{var data=new byte[w*ht*4];for(int i=0;i<data.Length;i+=4){data[i]=255;data[i+2]=255;}Marshal.Copy(data,0,bits,data.Length);bool ok=PrintWindow(h,dc,2);Marshal.Copy(bits,data,0,data.Length);using(var f=new BinaryWriter(File.Create(path))){f.Write((ushort)0x4D42);f.Write(54+data.Length);f.Write(0);f.Write(54);f.Write(40);f.Write(w);f.Write(-ht);f.Write((ushort)1);f.Write((ushort)32);f.Write(0);f.Write(data.Length);f.Write(0);f.Write(0);f.Write(0);f.Write(0);f.Write(data);}if(!ok)throw new Exception("PrintWindow failed");var colors=new string[localXs.Length][];for(int c=0;c<localXs.Length;c++){colors[c]=new string[rows];for(int y=0;y<rows;y++){int i=((s.Origin.Y-s.Window.Top+y)*w+s.Origin.X-s.Window.Left+localXs[c])*4;if(i<0||i+2>=data.Length)throw new Exception("Paint sample outside bitmap");colors[c][y]=data[i+2].ToString("X2")+data[i+1].ToString("X2")+data[i].ToString("X2");}}return colors;}finally{SelectObject(dc,old);DeleteObject(bitmap);DeleteDC(dc);}}
 // Only the owned private-desktop input queues are attached. Synchronous
 // key messages finish before the saved state is restored and detached.
 public static void Key(IntPtr surface,int vk){uint pid;uint target=GetWindowThreadProcessId(surface,out pid),current=GetCurrentThreadId();if(!AttachThreadInput(current,target,true))throw new Exception("Private input attach failed");var saved=new byte[256];bool have=false;try{if(!GetKeyboardState(saved))throw new Exception("Private keyboard read failed");have=true;if(!SetKeyboardState(new byte[256]))throw new Exception("Private keyboard reset failed");IntPtr result;if(SendMessageTimeoutW(surface,0x100,new IntPtr(vk),new IntPtr(1),2,2000,out result)==IntPtr.Zero||SendMessageTimeoutW(surface,0x101,new IntPtr(vk),new IntPtr(0xC0000001L),2,2000,out result)==IntPtr.Zero)throw new Exception("Private key timeout");}finally{bool restored=!have||SetKeyboardState(saved);bool detached=AttachThreadInput(current,target,false);if(!restored||!detached)throw new Exception("Private input restore/detach failed");}}
 public static void Fullscreen(IntPtr host){var s=Read(host);foreach(var c in s.Children)if(c.Class=="noctty.win32"){Key(new IntPtr(c.Hwnd),122);return;}throw new Exception("Surface absent");}
}
'@
if(-not $Driver){
    . (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-state-guard.ps1')
    $guardDir=[IO.Path]::GetFullPath("$Run-guard")
    if(Test-Path -LiteralPath $guardDir){throw 'State guard evidence directory must be new.'}
    [void](New-Item -ItemType Directory -Path $guardDir)
    $guard=Start-InteractiveWin11StateGuard -Harness TABGAP -ReceiptDirectory $guardDir
    try{Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds -DesktopPrefix 'noctty-tabgap-' -Label 'TABGAP measurement' -PassDesktopName -GuardClipboard -RunFiles @{'harness-used.ps1'=[IO.File]::ReadAllText($PSCommandPath)} -DriverArguments $(if($ExpectFlush){@('-ExpectFlush')}else{@()})}
    finally{Assert-InteractiveWin11StateGuard -Guard $guard}
    exit
}
[void][TabGap]::SetThreadDpiAwarenessContext([IntPtr](-4))
$script:checks=[Collections.Generic.List[object]]::new()
$script:samples=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
function Launch-Case([string]$Name,[string]$Decoration,$Monitor,[bool]$AddTab=$true){
    $root=Join-Path $Run $Name; $dir=Join-Path $root 'bin'; Copy-Portable $Bin $dir
    foreach($n in @('localappdata','appdata')){[void](New-Item -ItemType Directory -Path (Join-Path $root $n))}
    $config=Join-Path $dir 'tabgap.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false',"class = noctty-test-tabgap-$([guid]::NewGuid().ToString('N'))",'window-save-state = never','confirm-close-surface = false','window-show-tab-bar = always',"window-decoration = $Decoration",'clipboard-read = deny','clipboard-write = deny','copy-on-select = false','keybind = f11=toggle_fullscreen','keybind = f10=toggle_quick_terminal','quick-terminal-autohide = false','quick-terminal-animation-duration = 0','quick-terminal-keyboard-interactivity = on-demand') | Set-Content -LiteralPath $config
    $exe=Join-Path $dir 'noctty.exe'; $oldLocal=$env:LOCALAPPDATA;$oldRoaming=$env:APPDATA
    try{
        $env:LOCALAPPDATA=Join-Path $root 'localappdata';$env:APPDATA=Join-Path $root 'appdata'
        $pi=[HiddenLocal]::Spawn($exe,('"{0}" --config-file="{1}" --single-instance=false' -f $exe,$config),$dir,"WinSta0\$DesktopName")
        try{$p=[Diagnostics.Process]::GetProcessById($pi.pid);[void]$p.Handle}finally{[void][HiddenLocal]::CloseHandle($pi.thread);[void][HiddenLocal]::CloseHandle($pi.process)}
    }finally{$env:LOCALAPPDATA=$oldLocal;$env:APPDATA=$oldRoaming}
    $script:processes.Add(@{Pid=$p.Id;StartTime=$p.StartTime.ToUniversalTime().ToString('o');Executable=$p.ProcessName})
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    do{$hosts=@([HiddenLocal]::Hosts($p.Id));if($hosts.Count){$h=$hosts[0];if([HiddenLocal]::WindowDesktop($h) -ne $DesktopName){throw 'App escaped private desktop'};[void][TabGap]::ShowWindow($h,4);$s=[TabGap]::Read($h);if(@($s.Children|Where-Object Id -eq 1000).Count){break}};Start-Sleep -Milliseconds 100}while([datetime]::UtcNow -lt $deadline -and -not $p.HasExited)
    if(-not $h){throw 'Host did not start'}
    [void][TabGap]::ShowWindow($h,4);Start-Sleep -Milliseconds 1200
    [TabGap]::Move($h,($Monitor.Work.Left+100),($Monitor.Work.Top+100));Start-Sleep -Milliseconds 600
    [TabGap]::Move($h,($Monitor.Work.Left+100),($Monitor.Work.Top+100));Start-Sleep -Milliseconds 600
    if($AddTab){[void][TabGap]::PostMessageW($h,0x111,[IntPtr]1904,[IntPtr]::Zero);Start-Sleep -Milliseconds 1500}
    return @{Process=$p;Host=$h;Root=$root}
}
function Close-Case($Case){
    if(-not $Case){return};$p=$Case.Process
    if(-not $p.HasExited){foreach($h in [HiddenLocal]::Hosts($p.Id)){[void][TabGap]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero)}
        if(-not $p.WaitForExit(5000)){$fresh=Get-Process -Id $p.Id;if($fresh.StartTime -ne $p.StartTime -or $fresh.Path -ne $p.Path){throw 'Cleanup identity mismatch'};Stop-Process -Id $p.Id -Force;$p.WaitForExit()}}
}
function Wait-Restored($Case,$Expected,[string]$Name){
    $watch=[Diagnostics.Stopwatch]::StartNew();$frames=[Collections.Generic.List[object]]::new();$stable=0
    do{
        $state=[TabGap]::Read($Case.Host)
        $matches=-not $state.Zoomed -and (Rect-Same $state.Window $Expected.Window 0) -and (Rect-Same $state.Client $Expected.Client 0) -and $state.Origin.X -eq $Expected.Origin.X -and $state.Origin.Y -eq $Expected.Origin.Y
        $stable=if($matches){$stable+1}else{0}
        $frames.Add(@{ElapsedMs=$watch.ElapsedMilliseconds;Zoomed=$state.Zoomed;Window=$state.Window;Client=$state.Client;Origin=$state.Origin;Normal=$state.Placement.normal;Matches=$matches})
        if($stable -ge 3){break};Start-Sleep -Milliseconds 50
    }while($watch.ElapsedMilliseconds -lt 5000)
    $script:samples.Add(@{Name=$Name;Frames=$frames;Completed=($stable -ge 3)})
    return $stable -ge 3
}
function Sample([string]$Name,$Case,[string]$StateName,[string]$Decoration){
    $h=$Case.Host;$s=[TabGap]::Read($h);$tabs=@($s.Children|Where-Object {$_.Id -ge 1000 -and $_.Id -lt 1100 -and $_.Class -eq 'Button'}|Sort-Object Id)
    if($tabs.Count -lt 2){throw "Expected two visible tabs, found $($tabs.Count)"}
    $height=[int][Math]::Floor($(if($Decoration -eq 'auto'){40}else{32})*$s.Dpi/96)
    $columns=[ordered]@{first=10;tab0=[int](($tabs[0].Rect.Left+$tabs[0].Rect.Right)/2);tab1=[int](($tabs[1].Rect.Left+$tabs[1].Rect.Right)/2);empty=[int](($tabs[-1].Rect.Right+$s.Client.Right-$(if($Decoration -eq 'auto'){[int](138*$s.Dpi/96)}else{0}))/2)}
    foreach($action in @($s.Children|Where-Object {$_.Id -in @(1904,1911)})){$columns["action-$($action.Id)"]=[int](($action.Rect.Left+$action.Rect.Right)/2)}
    $scans=[ordered]@{};foreach($c in $columns.GetEnumerator()){$scans[$c.Key]=[TabGap]::Scan($h,$c.Value,$height)}
    $paintKeys=@('tab0','tab1','empty')
    $paint=[TabGap]::Paint($h,(Join-Path $Case.Root "$Name.bmp"),[int[]]@($paintKeys|ForEach-Object {$columns[$_]}),($height+1))
    $pixelsByColumn=[ordered]@{};for($i=0;$i -lt $paintKeys.Count;$i++){$pixelsByColumn[$paintKeys[$i]]=$paint[$i]}
    $pixels=$pixelsByColumn.tab1
    $active=@($tabs|Where-Object {[TabGap]::MarkedActive([IntPtr]$_.Hwnd)})
    Check "$Name exactly one tab selected" ($active.Count -eq 1) 1 $active.Count
    $sample=@{Name=$Name;StateName=$StateName;Geometry=$s;Columns=$columns;Scans=$scans;PixelsTab1=$pixels;PixelsByColumn=$pixelsByColumn;ActiveTab=@($active|ForEach-Object Id)};$script:samples.Add($sample)
    $script:samples|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $Run 'samples.json')
    $expected=if($ExpectFlush -and $StateName -in @('maximized','fullscreen')){0}else{[int][Math]::Floor(3*$s.Dpi/96)}
    Check "$Name tab top" ($tabs[0].Rect.Top -eq $expected -and $tabs[1].Rect.Top -eq $expected) $expected @($tabs|ForEach-Object {$_.Rect.Top})
    $expectedBottom=[int][Math]::Floor(3*$s.Dpi/96)+$height-[int][Math]::Floor(6*$s.Dpi/96)
    Check "$Name tab bottom" ($tabs[0].Rect.Bottom -eq $expectedBottom -and $tabs[1].Rect.Bottom -eq $expectedBottom) $expectedBottom @($tabs|ForEach-Object {$_.Rect.Bottom})
    $panes=@($s.Children|Where-Object Class -eq 'noctty.win32')
    Check "$Name pane band" (@($panes|Where-Object {$_.Rect.Top -ne $height}).Count -eq 0 -and $panes.Count -gt 0) $height @($panes|ForEach-Object {$_.Rect.Top})
    if($ExpectFlush){Check "$Name first-tab strip has no sysmenu target" (@($scans.first|Where-Object Code -eq 3).Count -eq 0) 0 @($scans.first|Where-Object Code -eq 3).Count}
    if($StateName -eq 'maximized'){
        $top=$scans.tab1[0]
        Check "$Name tab top procedure" ($top.Code -eq $(if($ExpectFlush){1}else{2}) -and $top.Target -eq $(if($ExpectFlush){$tabs[1].Hwnd}else{$h.ToInt64()})) $(if($ExpectFlush){'tab HTCLIENT'}else{'host HTCAPTION'}) @($top.Code,$top.Target)
        Check "$Name empty caption" ($scans.empty[0].Code -eq 2 -and $scans.empty[0].Target -eq $h.ToInt64()) 'host HTCAPTION' @($scans.empty[0].Code,$scans.empty[0].Target)
        Check "$Name no top resize" (@($scans.Values|ForEach-Object {$_}|Where-Object {$_.Code -in @(12,13,14)}).Count -eq 0) 0 @($scans.Values|ForEach-Object {$_}|Where-Object {$_.Code -in @(12,13,14)}).Count
    }elseif($StateName -in @('restored','restored-again')){Check "$Name restored top resize" ($scans.tab1[0].Code -eq 12) 12 $scans.tab1[0].Code}
    if($ExpectFlush -and $StateName -in @('maximized','fullscreen')){
        Check "$Name painted top differs from restored background" ($pixels[0] -ne $script:restoredBackground) 'tab border rather than parent background' @($pixels[0],$script:restoredBackground)
        Check "$Name paint positive control" ($pixels[0] -ne 'FF00FF' -and $pixels[0] -ne $pixels[2]) 'top border differs from fill' @($pixels[0],$pixels[2])
        $belowStrip=[int][Math]::Floor(4*$s.Dpi/96)
        foreach($key in $paintKeys){Check "$Name $key row0 capture positive control" ($pixelsByColumn[$key][0] -ne 'FF00FF') 'painted pixel' $pixelsByColumn[$key][0]}
        foreach($key in @('tab0','tab1')){
            Check "$Name $key row0 border reaches edge" ($pixelsByColumn[$key][0] -ne $pixelsByColumn[$key][2] -and $pixelsByColumn[$key][0] -ne $pixelsByColumn.empty[0]) 'border differs from tab fill and empty chrome' @($pixelsByColumn[$key][0],$pixelsByColumn[$key][2],$pixelsByColumn.empty[0])
        }
        Check "$Name empty row0 has no accent strip" ($pixelsByColumn.empty[0] -eq $pixelsByColumn.empty[$belowStrip]) $pixelsByColumn.empty[$belowStrip] $pixelsByColumn.empty[0]
        if($Decoration -eq 'none'){
            Check "$Name old accent removed from empty row0" ($pixelsByColumn.empty[0] -ne $script:restoredBackground) 'empty chrome differs from restored accent' @($pixelsByColumn.empty[0],$script:restoredBackground)
        }
    }else{
        Check "$Name restored row0 uniform across tab and empty columns" ($pixelsByColumn.tab0[0] -eq $pixelsByColumn.tab1[0] -and $pixelsByColumn.tab1[0] -eq $pixelsByColumn.empty[0]) $pixelsByColumn.empty[0] @($pixelsByColumn.tab0[0],$pixelsByColumn.tab1[0])
        if($StateName -eq 'restored'){$script:restoredBackground=$pixels[0]}
        if($Decoration -eq 'none'){
            $belowStrip=[int][Math]::Floor(4*$s.Dpi/96)
            Check "$Name restored accent positive control" ($pixelsByColumn.empty[0] -ne $pixelsByColumn.empty[$belowStrip]) 'accent differs from empty chrome below it' @($pixelsByColumn.empty[0],$pixelsByColumn.empty[$belowStrip])
        }
    }
    return $sample
}
function Test-WindowMenus([string]$Name,$Case){
    $h=$Case.Host;$s=[TabGap]::Read($h)
    $pane=@($s.Children|Where-Object Class -eq 'noctty.win32')[0]
    if(-not $pane){throw 'Menu probe needs a visible pane.'}
    $row=[int][Math]::Floor(20*$s.Dpi/96)
    $captionRun=[TabGap]::WidestCaptionRun($h,$row)
    if(-not $captionRun){
        Check "$Name caption menu point" $false 'measured host HTCAPTION run with host WindowFromPoint' 'no matching run'
        return
    }
    $x=$captionRun.X
    $caption=[TabGap]::Scan($h,$x,$row)[$row]
    $captionMatches=$caption.Code -eq 2 -and $caption.Target -eq $h.ToInt64() -and $caption.WindowFromPoint -eq $h.ToInt64()
    $script:samples.Add(@{Name="$Name-caption-menu-point";Run=$captionRun;Hit=$caption})
    Check "$Name caption menu point" $captionMatches 'host HTCAPTION and host WindowFromPoint' @($caption.Code,$caption.Target,$caption.WindowFromPoint)
    foreach($route in @('AltSpaceSysChar','SC_KEYMENU','captionRightClick')){
        # WM_SYSCHAR is the native Alt+Space character path. This exercises
        # DefWindowProc and Surface.hasWindowMenu, without physical Alt input.
        if($route -eq 'AltSpaceSysChar'){
            [void][TabGap]::PostMessageW([IntPtr]$pane.Hwnd,0x106,[IntPtr]0x20,[IntPtr]0x20390001)
        }elseif($route -eq 'SC_KEYMENU'){
            [void][TabGap]::PostMessageW($h,0x112,[IntPtr]0xF100,[IntPtr]0x20)
        }else{
            if(-not $captionMatches){continue}
            $pos=[TabGap]::Pos(($s.Origin.X+$x),($s.Origin.Y+$row))
            [void][TabGap]::PostMessageW($h,0xA4,[IntPtr]2,$pos)
            [void][TabGap]::PostMessageW($h,0xA5,[IntPtr]2,$pos)
        }
        $opened=Wait-Until {([TabGap]::MenuFlags($h) -band 4) -ne 0 -and [TabGap]::MenuOwner($h) -eq $h.ToInt64()} 3
        $script:samples.Add(@{Name="$Name-$route";Opened=$opened;Flags=[TabGap]::MenuFlags($h);Owner=[TabGap]::MenuOwner($h);ExpectedOwner=$h.ToInt64()})
        Check "$Name $route opens own native menu" $opened $true $opened
        [void][TabGap]::PostMessageW($h,0x1F,[IntPtr]::Zero,[IntPtr]::Zero)
        $dismissed=Wait-Until {([TabGap]::MenuFlags($h) -band 4) -eq 0} 3
        Check "$Name $route native menu dismissed" $dismissed $true $dismissed
        if(-not $dismissed){throw 'Native menu did not leave menu mode; refusing another probe.'}
    }
}
function Test-SingleTabCloseTop([string]$Name,[string]$Decoration,$Monitor){
    $case=$null
    try{
        $case=Launch-Case "$Name-single-top-close" $Decoration $Monitor $false
        [void][TabGap]::ShowWindow($case.Host,3);Start-Sleep -Milliseconds 650
        $s=[TabGap]::Read($case.Host)
        $script:samples.Add(@{Name="$Name-single-close-top-initial";Geometry=$s})
        Check "$Name close-zone measured DPI" ($s.Dpi -eq $Monitor.Dpi) $Monitor.Dpi $s.Dpi
        $tabs=@($s.Children|Where-Object {$_.Id -ge 1000 -and $_.Id -lt 1100 -and $_.Class -eq 'Button'})
        Check "$Name close-zone single tab maximized" ($s.Zoomed -and $tabs.Count -eq 1 -and $tabs[0].Rect.Top -eq 0) 'one flush maximized tab' @($s.Zoomed,$tabs.Count,$tabs[0].Rect.Top)
        if(-not $s.Zoomed -or $tabs.Count -ne 1 -or $tabs[0].Rect.Top -ne 0){return}
        $tab=$tabs[0];$target=[IntPtr]$tab.Hwnd
        # The midpoint of the existing 22 DIP close zone. Probe every row
        # introduced above the old 3 DIP inset, including row zero.
        $x=$tab.Rect.Right-[int][Math]::Floor(11*$s.Dpi/96)
        $inset=[int][Math]::Floor(3*$s.Dpi/96)
        for($y=0;$y -lt $inset;$y++){
            $hit=[TabGap]::Scan($case.Host,$x,$y)[$y]
            Check "$Name close-zone row $y routes to single tab" ($hit.Code -eq 1 -and $hit.Target -eq $tab.Hwnd -and $hit.WindowFromPoint -eq $tab.Hwnd) 'tab HTCLIENT' @($hit.Code,$hit.Target,$hit.WindowFromPoint)
            if($hit.Code -ne 1 -or $hit.Target -ne $tab.Hwnd){return}
            $pos=[TabGap]::Pos(($x-$tab.Rect.Left),$y)
            foreach($message in @(0x201,0x202)){
                [void][TabGap]::PostMessageW($target,$message,$(if($message -eq 0x201){[IntPtr]1}else{[IntPtr]::Zero}),$pos)
                Start-Sleep -Milliseconds 650
                $alive=[TabGap]::IsWindow($case.Host) -and -not $case.Process.HasExited
                $selected=$alive -and [TabGap]::IsWindow($target) -and [TabGap]::MarkedActive($target)
                $tabCount=if($alive){@(([TabGap]::Read($case.Host)).Children|Where-Object {$_.Id -ge 1000 -and $_.Id -lt 1100 -and $_.Class -eq 'Button'}).Count}else{0}
                $phase=if($message -eq 0x201){'down'}else{'up'}
                $script:samples.Add(@{Name="$Name-single-close-top-$y-$phase";Row=$y;Phase=$phase;HostAlive=$alive;Selected=$selected;TabCount=$tabCount;Hit=$hit})
                Check "$Name close-zone row $y $phase preserves selected single tab" ($alive -and $selected -and $tabCount -eq 1) @($true,$true,1) @($alive,$selected,$tabCount)
                if(-not $alive -or -not $selected -or $tabCount -ne 1){return}
            }
        }
    }finally{Close-Case $case}
}
function Test-QuickTerminal([string]$Name,$Monitor){
    $case=$null
    try{
        $case=Launch-Case "$Name-quick" 'auto' $Monitor $false
        $pane=@(([TabGap]::Read($case.Host)).Children|Where-Object Class -eq 'noctty.win32')[0]
        [TabGap]::Key([IntPtr]$pane.Hwnd,121)
        $opened=Wait-Until {@([HiddenLocal]::Hosts($case.Process.Id)|Where-Object {$_ -ne $case.Host}).Count -eq 1} 10
        Check "$Name quick terminal opens" $opened $true $opened
        if(-not $opened){return}
        $qt=@([HiddenLocal]::Hosts($case.Process.Id)|Where-Object {$_ -ne $case.Host})[0]
        if([HiddenLocal]::WindowDesktop($qt) -ne $DesktopName){throw 'Quick terminal escaped private desktop.'}
        Start-Sleep -Milliseconds 1000
        [TabGap]::Move($qt,($Monitor.Work.Left+100),($Monitor.Work.Top+100));Start-Sleep -Milliseconds 650
        [TabGap]::Move($qt,($Monitor.Work.Left+100),($Monitor.Work.Top+100));Start-Sleep -Milliseconds 650
        $qtCase=@{Process=$case.Process;Host=$qt;Root=$case.Root}
        foreach($state in @('restored','maximized')){
            if($state -eq 'maximized'){[void][TabGap]::ShowWindow($qt,3);Start-Sleep -Milliseconds 650}
            $s=[TabGap]::Read($qt);$rows=[TabGap]::Scan($qt,10,[int](40*$s.Dpi/96))
            $script:samples.Add(@{Name="$Name-quick-$state";Geometry=$s;FirstColumn=$rows})
            Check "$Name quick $state measured DPI" ($s.Dpi -eq $Monitor.Dpi) $Monitor.Dpi $s.Dpi
            Check "$Name quick $state zoom readback" ($s.Zoomed -eq ($state -eq 'maximized')) ($state -eq 'maximized') $s.Zoomed
            Check "$Name quick $state no sysmenu target" (@($rows|Where-Object {$_.Code -eq 3 -or $_.HostCode -eq 3}).Count -eq 0) 0 @($rows|Where-Object {$_.Code -eq 3 -or $_.HostCode -eq 3}).Count
            Test-WindowMenus "$Name-quick-$state" $qtCase
        }
    }finally{Close-Case $case}
}
try{
    $monitors=@([TabGap]::Monitors());$monitors|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $Run 'monitors.json')
    foreach($dpi in @(96,144)){if(-not @($monitors|Where-Object Dpi -eq $dpi).Count){$script:samples.Add(@{SkippedDpi=$dpi;Reason='No physical monitor offers this DPI'})}}
    foreach($m in @($monitors|Group-Object Dpi|ForEach-Object {$_.Group[0]})){foreach($decoration in @('auto','none')){
        $name="$($m.Dpi)-$decoration";$case=$null
        try{
            $case=Launch-Case $name $decoration $m
            $before=Sample "$name-restored" $case 'restored' $decoration
            [void][TabGap]::ShowWindow($case.Host,3);Start-Sleep -Milliseconds 650
            $max=Sample "$name-maximized" $case 'maximized' $decoration
            Check "$name maximized readback" $max.Geometry.Zoomed $true $max.Geometry.Zoomed
            if($ExpectFlush){
                $tab1=@($max.Geometry.Children|Where-Object Id -eq 1001)[0]
                $bottom=$tab1.Rect.Bottom
                $lastChrome=$max.PixelsTab1.Count-2
                $restoredTail=($before.PixelsTab1[$bottom..$lastChrome]) -join ','
                $maximizedTail=($max.PixelsTab1[$bottom..$lastChrome]) -join ','
                Check "$name underline and separator pixels preserved" ($restoredTail -eq $maximizedTail) $restoredTail $maximizedTail
                # A routed post proves the actual tab procedure accepts the new
                # top row. No mouse state or real input is changed. The midpoint
                # is outside the tab's rightmost 22 DIP close zone.
                $tab0=@($max.Geometry.Children|Where-Object Id -eq 1000)[0]
                $x=[int](($tab0.Rect.Left+$tab0.Rect.Right)/2)
                $routed=[TabGap]::Scan($case.Host,$x,0)[0]
                $target=[IntPtr]$tab0.Hwnd
                $beforeMarker=[TabGap]::MarkedActive($target)
                Check "$name actual WindowFromPoint top target" ($routed.WindowFromPoint -eq $tab0.Hwnd -and $routed.Target -eq $tab0.Hwnd -and $routed.Code -eq 1) 'first tab HTCLIENT' @($routed.WindowFromPoint,$routed.Target,$routed.Code)
                if($routed.WindowFromPoint -eq $tab0.Hwnd -and $routed.Target -eq $tab0.Hwnd -and $routed.Code -eq 1){
                    $pos=[TabGap]::Pos(($x-$tab0.Rect.Left),0)
                    [void][TabGap]::PostMessageW($target,0x201,[IntPtr]1,$pos)
                    [void][TabGap]::PostMessageW($target,0x202,[IntPtr]::Zero,$pos)
                    $selected=Wait-Until {[TabGap]::MarkedActive($target)} 3
                    Check "$name routed top post selects inactive tab" (-not $beforeMarker -and $selected) @($false,$true) @($beforeMarker,$selected)
                }
                $empty=$max.Scans.empty[0]
                if($empty.Code -eq 2 -and $empty.Target -eq $case.Host.ToInt64()){
                    [void][TabGap]::PostMessageW($case.Host,0xA3,[IntPtr]2,[TabGap]::Pos(($max.Geometry.Origin.X+$max.Columns.empty),$max.Geometry.Origin.Y))
                    # The zoom bit clears before the asynchronous NC restore
                    # finishes moving the window. Wait for its original physical
                    # rectangle too before issuing a second state transition.
                    $restored=Wait-Restored $case $before.Geometry "$name-caption-restore-timeline"
                    Check "$name empty-caption doubleclick restores" $restored $true $restored
                    if(-not $restored){throw 'Caption doubleclick did not finish restoring its original rectangle.'}
                    [void][TabGap]::ShowWindow($case.Host,3);Start-Sleep -Milliseconds 650
                    $remax=Sample "$name-remmaximized" $case 'maximized' $decoration
                    Check "$name remaximize after doubleclick" $remax.Geometry.Zoomed $true $remax.Geometry.Zoomed
                }
            }
            [void][TabGap]::ShowWindow($case.Host,9)
            $cycleRestored=Wait-Restored $case $before.Geometry "$name-showwindow-restore-timeline"
            Check "$name ShowWindow restore finishes" $cycleRestored $true $cycleRestored
            if(-not $cycleRestored){throw 'ShowWindow did not finish restoring its original outer/client geometry.'}
            $after=Sample "$name-restored-again" $case 'restored-again' $decoration
            Check "$name restored geometry cycle" (((Rect-Array $before.Geometry.Window) -join ',') -eq ((Rect-Array $after.Geometry.Window) -join ',')) (Rect-Array $before.Geometry.Window) (Rect-Array $after.Geometry.Window)
            [TabGap]::Fullscreen($case.Host);Start-Sleep -Milliseconds 650
            $full=Sample "$name-fullscreen" $case 'fullscreen' $decoration
            Check "$name fullscreen readback" (((Rect-Array $full.Geometry.Window) -join ',') -eq ((Rect-Array $m.Full) -join ',')) (Rect-Array $m.Full) (Rect-Array $full.Geometry.Window)
            [TabGap]::Fullscreen($case.Host);Start-Sleep -Milliseconds 650
            Test-WindowMenus $name $case
            # Positive control: post the host's own measured sysmenu hit code,
            # only when the effective target really is the host and HTSYSMENU.
            $probe=@($before.Scans.first|Where-Object {$_.Code -eq 3 -and $_.Target -eq $case.Host.ToInt64()})|Select-Object -First 1
            if($probe){$origin=([TabGap]::Read($case.Host)).Origin;[void][TabGap]::PostMessageW($case.Host,0xA3,[IntPtr]3,[TabGap]::Pos(($origin.X+10),($origin.Y+$probe.Y)));Start-Sleep -Milliseconds 800;$script:samples.Add(@{Name="$name-sysmenu-doubleclick";Row=$probe.Y;HostAlive=[TabGap]::IsWindow($case.Host);ProcessExited=$case.Process.HasExited})}
        }finally{Close-Case $case}
        if($decoration -eq 'auto'){
            $probeCase=$null
            try{
                $probeCase=Launch-Case "$name-max-sysmenu" $decoration $m
                [void][TabGap]::ShowWindow($probeCase.Host,3);Start-Sleep -Milliseconds 650
                $s=[TabGap]::Read($probeCase.Host);$rows=[TabGap]::Scan($probeCase.Host,10,[int](40*$s.Dpi/96))
                $probe=@($rows|Where-Object {$_.Code -eq 3 -and $_.Target -eq $probeCase.Host.ToInt64()})|Select-Object -First 1
                if($probe){[void][TabGap]::PostMessageW($probeCase.Host,0xA3,[IntPtr]3,[TabGap]::Pos(($s.Origin.X+10),($s.Origin.Y+$probe.Y)));Start-Sleep -Milliseconds 800}
                $script:samples.Add(@{Name="$name-maximized-sysmenu-doubleclick";Rows=$rows;Posted=($null -ne $probe);PostedRow=$probe.Y;HostAlive=[TabGap]::IsWindow($probeCase.Host);ProcessExited=$probeCase.Process.HasExited})
            }finally{Close-Case $probeCase}
        }
        if($ExpectFlush){
            Test-SingleTabCloseTop $name $decoration $m
            if($decoration -eq 'auto'){Test-QuickTerminal $name $m}
        }
    }}
}catch{$script:checks.Add(@{Name='Harness execution';Passed=$false;Error=$_.Exception.Message;Location=$_.InvocationInfo.ScriptLineNumber})}
finally{@{Checks=$script:checks;Samples=$script:samples;Processes=$script:processes;Limit='Never-switched WinSta0 private desktop; no real input, clipboard operations or composed-pixel acceptance. WindowFromPoint recorded separately from modeled recursive procedure chain. PrintWindow re-renders children and cannot prove displayed occlusion or stale pixels.'}|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $Run 'tabgap-results.json')}
if(@($script:checks|Where-Object {-not $_.Passed}).Count){exit 1}
