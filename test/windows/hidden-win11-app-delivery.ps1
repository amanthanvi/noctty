#requires -Version 7.0
<#
Portable integration smoke for App HWND delivery on a private desktop.
Run with -Bin <built bin directory> -Run <new evidence directory>.
No builds, desktop switching, foreground activation, injected input, clipboard,
PowerShell profiles, or real shell history. All child processes belong to a job.
The terminal runs cmd.exe, and the real PSReadLine history files' size and time are
checked before and after (metadata only).
The adopted real startup-state hash is checked before and after the run; supply
ExpectedStartupModified to pin its exact UTC timestamp as well.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [ValidateRange(15,600)] [int] $DriverTimeoutSeconds = 90,
    [string] $ExpectedStartupHash = '7b4f9aa31731df822e3ec13f8381e76dc759455abbf8bb458f74e10bf5e2bb9c',
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')
Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class AppDeliverySmoke {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct GuiInfo {
        public uint size,flags;
        public IntPtr active,focus,capture,menuOwner,moveSize,caret;
        public Rect caretRect;
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags;
        public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct NativeProcessInfo {
        public IntPtr process,thread; public int pid,tid;
    }
    public sealed class ProcessInfo {
        public IntPtr process,thread; public int pid,tid;
        public long created; public string executable,stdoutPath,stderrPath;
    }
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
        public int length; public IntPtr descriptor; public int inherit;
    }
    public delegate bool EnumWindow(IntPtr h,IntPtr p);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr h,int index,StringBuilder value,uint bytes,out uint needed);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h,EnumWindow cb,IntPtr p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent,IntPtr after,string cls,string title);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid,ref GuiInfo info);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out NativeProcessInfo pi);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,ref SecurityAttributes sa,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr h);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr h,uint flags,StringBuilder path,ref uint length);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h,out long created,out long exited,out long kernel,out long user);
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,s.Capacity); return s.ToString(); }
    public static string Title(IntPtr h) { var s=new StringBuilder(512); GetWindowTextW(h,s,s.Capacity); return s.ToString(); }
    static string DesktopNameOf(IntPtr desktop) {
        var name=new StringBuilder(256); uint needed;
        if(desktop==IntPtr.Zero || !GetUserObjectInformationW(desktop,2,name,(uint)(name.Capacity*2),out needed)) throw new Exception("Desktop identity inspection failed");
        return name.ToString();
    }
    public static bool IsPrivateDesktop(string expected) {
        var input=OpenInputDesktop(0,false,1); // DESKTOP_READOBJECTS
        if(input==IntPtr.Zero) throw new Exception("Input desktop inspection failed");
        try {
            return !String.IsNullOrEmpty(expected) && expected.StartsWith("koreterm-pkg19-",StringComparison.Ordinal) &&
                DesktopNameOf(GetThreadDesktop(GetCurrentThreadId()))==expected && DesktopNameOf(input)!=expected;
        } finally { CloseDesktop(input); }
    }
    public static IntPtr[] Hosts(int pid) {
        var result=new List<IntPtr>();
        EnumWindows((h,p)=>{ int owner; GetWindowThreadProcessId(h,out owner);
            if(owner==pid && Class(h)=="koreterm.win32.host") result.Add(h); return true; },IntPtr.Zero);
        return result.ToArray();
    }
    public static IntPtr Surface(IntPtr host) {
        IntPtr result=IntPtr.Zero;
        EnumChildWindows(host,(h,p)=>{ if(Class(h)=="koreterm.win32") result=h; return true; },IntPtr.Zero);
        return result;
    }
    public static IntPtr AppWindow(int pid) {
        var h=IntPtr.Zero;
        while((h=FindWindowExW(new IntPtr(-3),h,"koreterm.win32.app",null))!=IntPtr.Zero) {
            int owner; GetWindowThreadProcessId(h,out owner); if(owner==pid) return h;
        }
        return IntPtr.Zero;
    }
    public static uint MenuFlags(IntPtr host) {
        int pid; var tid=GetWindowThreadProcessId(host,out pid);
        var info=new GuiInfo { size=(uint)Marshal.SizeOf<GuiInfo>() };
        if(tid==0 || !GetGUIThreadInfo(tid,ref info)) throw new Exception("GUI thread inspection failed");
        return info.flags;
    }
    static string Quote(string value) {
        var result=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='\"') { result.Append('\\',slashes*2+1).Append(c); slashes=0; continue; }
            result.Append('\\',slashes).Append(c); slashes=0;
        }
        return result.Append('\\',slashes*2).Append('"').ToString();
    }
    static IntPtr CaptureFile(string path,bool input) {
        var sa=new SecurityAttributes { length=Marshal.SizeOf<SecurityAttributes>(),inherit=1 };
        var handle=CreateFileW(path,input?0x80000000u:0x40000000u,7,ref sa,input?3u:1u,0x80,IntPtr.Zero);
        if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }
    public static ProcessInfo Launch(string app,string[] args,string cwd,string desktop,IntPtr job,string stdoutPath,string stderrPath) {
        var command=new StringBuilder(Quote(app)); foreach(var arg in args) command.Append(' ').Append(Quote(arg));
        var input=IntPtr.Zero; var output=IntPtr.Zero; var error=IntPtr.Zero;
        var native=new NativeProcessInfo(); bool createdProcess=false;
        // CREATE_NO_WINDOW | CREATE_SUSPENDED: assign job before child code runs.
        // Driver children inherit its job; they never request breakaway. Verify
        // executable + PID + creation time while suspended, before a fast CLI
        // can exit and QueryFullProcessImageName becomes unavailable.
        try {
            input=CaptureFile("NUL",true); output=CaptureFile(stdoutPath,false); error=CaptureFile(stderrPath,false);
            var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=0x101,show=0,input=input,output=output,error=error };
            if(!CreateProcessW(app,command,IntPtr.Zero,IntPtr.Zero,true,0x08000004,IntPtr.Zero,cwd,ref si,out native)) throw new Win32Exception(Marshal.GetLastWin32Error());
            createdProcess=true;
            var path=new StringBuilder(32768); uint size=(uint)path.Capacity;
            long created,exited,kernel,user;
            if(GetProcessId(native.process)!=(uint)native.pid || !QueryFullProcessImageNameW(native.process,0,path,ref size) ||
                !String.Equals(System.IO.Path.GetFullPath(path.ToString()),System.IO.Path.GetFullPath(app),StringComparison.OrdinalIgnoreCase) ||
                !GetProcessTimes(native.process,out created,out exited,out kernel,out user)) throw new Exception("Suspended process identity check failed");
            var pi=new ProcessInfo { process=native.process,thread=native.thread,pid=native.pid,tid=native.tid,
                created=created,executable=System.IO.Path.GetFullPath(app),stdoutPath=stdoutPath,stderrPath=stderrPath };
            if((job!=IntPtr.Zero && !AssignProcessToJobObject(job,pi.process)) || ResumeThread(pi.thread)==0xFFFFFFFF) throw new Exception("Assign/resume owned process failed");
            return pi;
        } catch {
            if(createdProcess) { TerminateProcess(native.process,1); CloseHandle(native.thread); CloseHandle(native.process); }
            throw;
        } finally {
            if(input!=IntPtr.Zero) CloseHandle(input);
            if(output!=IntPtr.Zero) CloseHandle(output);
            if(error!=IntPtr.Zero) CloseHandle(error);
        }
    }
    public static string Verify(ProcessInfo pi,string executable) {
        long created,exited,kernel,user;
        // The retained native process handle cannot identify a reused PID.
        // Path was verified before resume; creation time remains queryable
        // after exit, unlike image-name lookup on some Windows builds.
        if(GetProcessId(pi.process)!=(uint)pi.pid ||
            !String.Equals(pi.executable,System.IO.Path.GetFullPath(executable),StringComparison.OrdinalIgnoreCase) ||
            !GetProcessTimes(pi.process,out created,out exited,out kernel,out user) || created!=pi.created) throw new Exception("Exact owned process identity check failed");
        return DateTime.FromFileTimeUtc(created).ToString("o");
    }
    public static void CloseProcess(ProcessInfo pi) { CloseHandle(pi.thread); CloseHandle(pi.process); }
}
'@
function Capture-Summary([string]$Path){
    $stream=$null;$reader=$null
    try {
        $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $bytes=$stream.Length
        $reader=[IO.StreamReader]::new($stream)
        $buffer=[char[]]::new(65536);$count=$reader.ReadBlock($buffer,0,$buffer.Length)
        $text=[string]::new($buffer,0,$count)
        $categories=[Collections.Generic.List[string]]::new()
        foreach($rule in @(
            @('Panic','(?i)panic|unhandled exception'),
            @('Configuration','(?i)invalid config|configuration error|unknown.*config|config.*(?:error|diagnostic)'),
            @('Initialization','(?i)app init(?:ialization)?.*fail|error initializing|failed to.*init|error starting IO thread'),
            @('MissingFile','(?i)FileNotFound|file not found|path not found'),
            @('AccessDenied','(?i)AccessDenied|PermissionDenied|access is denied'),
            @('Renderer','(?i)(?:renderer|OpenGL|WGL|EGL).*fail'),
            @('Invariant','(?i)invariant failed')
        )){if($text -match $rule[1]){$categories.Add($rule[0])}}
        # Emit only fixed categories and identifier-shaped error names; never
        # emit a matching line, child command line, environment, or bulk log.
        $errors=@([regex]::Matches($text,'\berror\.[A-Za-z][A-Za-z0-9_]*\b')|ForEach-Object Value|Select-Object -Unique -First 12)
        return @{Bytes=$bytes;ScannedCharacters=$count;Truncated=($bytes -gt 65536);Categories=@($categories);ErrorNames=$errors}
    } catch {return @{Readable=$false;Categories=@('CaptureUnavailable')}}
    finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}
function Process-Observation($Info){
    $wait=[HiddenLocal]::WaitForSingleObject($Info.process,0)
    [uint32]$code=0
    $available=[HiddenLocal]::GetExitCodeProcess($Info.process,[ref]$code)
    return @{Pid=$Info.pid;Exited=($wait -eq 0);WaitResult=$wait;ExitCodeAvailable=$available;ExitCode=if($available){$code}else{$null};Stdout=(Capture-Summary $Info.stdoutPath);Stderr=(Capture-Summary $Info.stderrPath)}
}
if(-not $Driver) {
    $Bin=(Resolve-Path -LiteralPath $Bin).Path
    $Run=[IO.Path]::GetFullPath($Run)
    if(Test-Path -LiteralPath $Run){throw 'Run directory must be new.'}
    if(-not(Test-Path -LiteralPath (Join-Path $Bin 'koreterm.exe'))){throw 'Bin must contain koreterm.exe.'}
    $before=Startup-Fingerprint
    $historyGuard=Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-app-delivery.ps1'
    if(($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)){throw 'Real startup state differs from adopted baseline; no launches performed.'}
    [void](New-Item -ItemType Directory -Path $Run)
    $portableBin=Join-Path $Run 'portable\bin'
    [void](New-Item -ItemType Directory -Path $portableBin)
    Get-ChildItem -LiteralPath $Bin -File | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination $portableBin}
    $share=Join-Path (Split-Path -Parent $Bin) 'share'
    if(Test-Path -LiteralPath $share){Copy-Item -LiteralPath $share -Destination (Join-Path $Run 'portable\share') -Recurse}
    Set-Content -LiteralPath (Join-Path $portableBin 'koreterm.portable') -Value '' -NoNewline
    foreach($name in @('localappdata','appdata')){[void](New-Item -ItemType Directory -Path (Join-Path $Run $name))}
    $desktopName='koreterm-pkg19-'+[guid]::NewGuid().ToString('N')
    $desktop=[HiddenLocal]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if($desktop -eq [IntPtr]::Zero){throw 'CreateDesktop failed.'}
    $oldLocal=$env:LOCALAPPDATA;$oldRoaming=$env:APPDATA
    $driverInfo=$null;$job=[IntPtr]::Zero;$driverExe=$null;$code=1
    try {
        $job=[HiddenLocal]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata';$env:APPDATA=Join-Path $Run 'appdata'
        $driverExe=(Get-Command pwsh.exe -CommandType Application).Source
        $driverArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Bin',$portableBin,'-Run',$Run,'-Driver','-DesktopName',$desktopName)
        $driverInfo=[AppDeliverySmoke]::Launch($driverExe,$driverArgs,$Run,"WinSta0\$desktopName",$job,(Join-Path $Run 'driver.stdout.log'),(Join-Path $Run 'driver.stderr.log'))
        $started=[AppDeliverySmoke]::Verify($driverInfo,$driverExe)
        @{Pid=$driverInfo.pid;StartTimeUtc=$started;Executable='pwsh.exe';Desktop=$desktopName} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'driver-identity.json')
        Write-Host "Focused App delivery driver PID=$($driverInfo.pid). Results: $Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while([HiddenLocal]::WaitForSingleObject($driverInfo.process,1000) -eq 258){
            if([datetime]::UtcNow -ge $deadline){throw 'Hidden driver timed out; its owned job will be cleaned up.'}
        }
        [uint32]$exitCode=1
        if(-not[HiddenLocal]::GetExitCodeProcess($driverInfo.process,[ref]$exitCode)){throw 'Driver exit inspection failed.'}
        $code=$exitCode
    } finally {
        $env:LOCALAPPDATA=$oldLocal;$env:APPDATA=$oldRoaming
        $cleanupError=$null;$identityError=$null;$ownedProcesses=0
        try { if($driverInfo){[void][AppDeliverySmoke]::Verify($driverInfo,$driverExe)} } catch {$identityError=$_}
        $driverObservation=if($driverInfo){Process-Observation $driverInfo}else{$null}
        if($job -ne [IntPtr]::Zero){try{$ownedProcesses=[HiddenLocal]::StopOwnedJob($job)}catch{$cleanupError=$_}}
        if($driverInfo){[AppDeliverySmoke]::CloseProcess($driverInfo)}
        [void][AppDeliverySmoke]::CloseDesktop($desktop)
        $after=Startup-Fingerprint
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyFailure=$null
        try{Assert-WindowsHarnessHistoryGuard -Guard $historyGuard}catch{$historyFailure=$_}
        @{Before=$before;After=$after;Unchanged=$unchanged;HistoryUnchanged=($null -eq $historyFailure);DriverIdentityVerified=($null -eq $identityError);OwnedJobCleanedUp=($null -eq $cleanupError);OwnedProcessCount=$ownedProcesses;Driver=$driverObservation} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if($historyFailure){throw $historyFailure}
        if(-not $unchanged){throw 'Real startup state changed; stop launches.'}
        if($cleanupError){throw $cleanupError}
        if($identityError){throw $identityError}
    }
    if($code -ne 0){throw "Hidden App delivery smoke failed with exit $code; inspect app-delivery-results.json."}
    Write-Host "Focused App delivery smoke: PASS. Results: $(Join-Path $Run 'app-delivery-results.json')"
    exit
}

# Driver runs only on the newly created desktop. Every launch inherits its job.
$Bin=(Resolve-Path -LiteralPath $Bin).Path
$Run=[IO.Path]::GetFullPath($Run)
if(-not(Test-Path -LiteralPath (Join-Path $Bin 'koreterm.portable')) -or $env:LOCALAPPDATA -ne (Join-Path $Run 'localappdata') -or $env:APPDATA -ne (Join-Path $Run 'appdata') -or -not[AppDeliverySmoke]::IsPrivateDesktop($DesktopName)){throw 'Driver isolation contract is absent.'}
$exe=Join-Path $Bin 'koreterm.exe'
$checks=[Collections.Generic.List[object]]::new()
$samples=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.List[object]]::new()
function Assert-Check([string]$Name,[bool]$Passed,$Actual){
    $checks.Add(@{Name=$Name;Passed=$Passed;Actual=$Actual})
    if(-not $Passed){throw "Assertion failed: $Name"}
}
function Wait-Until([scriptblock]$Condition,[int]$Seconds=15){
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    do {if(& $Condition){return $true};Start-Sleep -Milliseconds 25}while([datetime]::UtcNow -lt $deadline)
    return $false
}
function Launch-Owned([string[]]$Arguments){
    $number=$owned.Count+1
    $info=[AppDeliverySmoke]::Launch($exe,$Arguments,$Bin,"WinSta0\$DesktopName",[IntPtr]::Zero,(Join-Path $Run "process-$number.stdout.log"),(Join-Path $Run "process-$number.stderr.log"))
    $started=[AppDeliverySmoke]::Verify($info,$exe)
    $owned.Add(@{Info=$info;Pid=$info.pid;StartTimeUtc=$started;Executable='koreterm.exe'})
    return $info
}
$runtime=$null;$hostWindow=[IntPtr]::Zero
try {
    $instanceClass='koreterm-pkg19-'+[guid]::NewGuid().ToString('N')
    $gate=Join-Path $Run 'allow-title.txt'
    $batch=Join-Path $Run 'title-driver.cmd'
    @('@echo off','title PKG19-before',':wait',"if exist `"$gate`" goto deliver",'ping.exe -n 2 127.0.0.1 >nul','goto wait',':deliver','ping.exe -n 2 127.0.0.1 >nul','title PKG19-during-menu',':hold','ping.exe -n 30 127.0.0.1 >nul','goto hold') | Set-Content -LiteralPath $batch -Encoding ascii
    $config=Join-Path $Bin 'app-delivery.ghostty'
    @("command = cmd.exe /d /q /k `"$batch`"",'shell-integration = none','single-instance = true','initial-window = false','quit-after-last-window-closed-delay = 5s','window-save-state = never','confirm-close-surface = false','auto-update = off',"class = $instanceClass") | Set-Content -LiteralPath $config -Encoding utf8
    $runtime=Launch-Owned @('--config-default-files=false',"--config-file=$config","--class=$instanceClass")
    $ready=Wait-Until {[AppDeliverySmoke]::AppWindow($runtime.pid) -ne [IntPtr]::Zero}
    Assert-Check 'headless App message-only HWND exists' $ready $ready
    $hosts=@([AppDeliverySmoke]::Hosts($runtime.pid))
    Assert-Check 'headless launch has no host HWND' ($hosts.Count -eq 0) $hosts.Count
    Assert-Check 'headless app remains running' ([HiddenLocal]::WaitForSingleObject($runtime.process,0) -eq 258) $runtime.pid

    $forward=Launch-Owned @('+new-window',"--class=$instanceClass",'--timeout=10000')
    Assert-Check 'forwarding CLI exits within deadline' ([HiddenLocal]::WaitForSingleObject($forward.process,15000) -eq 0) $forward.pid
    [uint32]$forwardCode=1
    if(-not[HiddenLocal]::GetExitCodeProcess($forward.process,[ref]$forwardCode)){throw 'Forwarder exit inspection failed.'}
    Assert-Check 'forwarded new-window accepted' ($forwardCode -eq 0) $forwardCode
    $ready=Wait-Until {
        $windows=@([AppDeliverySmoke]::Hosts($runtime.pid))
        $windows.Count -eq 1 -and [AppDeliverySmoke]::Surface($windows[0]) -ne [IntPtr]::Zero
    }
    Assert-Check 'forwarding creates terminal in existing headless PID' $ready $runtime.pid
    $hostWindow=([AppDeliverySmoke]::Hosts($runtime.pid))[0]
    $ready=Wait-Until {[AppDeliverySmoke]::Title($hostWindow) -like '*PKG19-before*'}
    Assert-Check 'configured cmd initial title observed' $ready ([AppDeliverySmoke]::Title($hostWindow))
    # SC_KEYMENU + space opens this host's native caption menu, with no
    # foreground request, keyboard injection, or external-thread SendMessage.
    Assert-Check 'caption-menu request posted' ([AppDeliverySmoke]::PostMessageW($hostWindow,0x0112,[IntPtr]0xF100,[IntPtr]0x20)) $true
    $menuOpen=Wait-Until {([AppDeliverySmoke]::MenuFlags($hostWindow) -band 4) -ne 0} 5
    Assert-Check 'native GUI_INMENUMODE observed' $menuOpen $menuOpen
    Set-Content -LiteralPath $gate -Value 'deliver' -NoNewline
    $delivered=$false;$escaped=$false
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    do {
        $flags=[AppDeliverySmoke]::MenuFlags($hostWindow)
        $title=[AppDeliverySmoke]::Title($hostWindow)
        if(($flags -band 4) -eq 0){$escaped=$true;break}
        if($title -like '*PKG19-during-menu*'){$delivered=$true;break}
        Start-Sleep -Milliseconds 25
    }while([datetime]::UtcNow -lt $deadline)
    $samples.Add(@{Title=$title;GuiFlags=$flags;MenuStillOpen=(($flags -band 4) -ne 0)})
    Assert-Check 'cmd title applied before caption menu exits' ($delivered -and -not $escaped) @{Title=$title;GuiFlags=$flags}
    Assert-Check 'cancel menu request posted' ([AppDeliverySmoke]::PostMessageW($hostWindow,0x001F,[IntPtr]::Zero,[IntPtr]::Zero)) $true
    $closed=Wait-Until {([AppDeliverySmoke]::MenuFlags($hostWindow) -band 4) -eq 0} 5
    Assert-Check 'caption menu exits after cancellation' $closed $closed
    Assert-Check 'window close request posted' ([AppDeliverySmoke]::PostMessageW($hostWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)) $true
    Assert-Check 'runtime exits after last window closes' ([HiddenLocal]::WaitForSingleObject($runtime.process,10000) -eq 0) $runtime.pid
    [uint32]$runtimeCode=1
    if(-not[HiddenLocal]::GetExitCodeProcess($runtime.process,[ref]$runtimeCode)){throw 'Runtime exit inspection failed.'}
    Assert-Check 'runtime shutdown exits successfully' ($runtimeCode -eq 0) $runtimeCode
    Assert-Check 'terminal host destroyed' (-not[AppDeliverySmoke]::IsWindow($hostWindow)) $hostWindow.ToInt64()
} catch {
    $checks.Add(@{Name='Harness execution';Passed=$false;Error=$_.Exception.Message})
} finally {
    # The outer owned job is the final bound, including timed-out cmd/ping.
    if($hostWindow -ne [IntPtr]::Zero -and [AppDeliverySmoke]::IsWindow($hostWindow)){
        [void][AppDeliverySmoke]::PostMessageW($hostWindow,0x001F,[IntPtr]::Zero,[IntPtr]::Zero)
        [void][AppDeliverySmoke]::PostMessageW($hostWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
    }
    $identities=@()
    foreach($record in $owned){
        try{[void][AppDeliverySmoke]::Verify($record.Info,$exe)}catch{$checks.Add(@{Name='Exact owned process identity';Passed=$false;Pid=$record.Pid})}
        $identities+=@{Pid=$record.Pid;StartTimeUtc=$record.StartTimeUtc;Executable=$record.Executable;Observation=(Process-Observation $record.Info)}
        [AppDeliverySmoke]::CloseProcess($record.Info)
    }
    @{Checks=$checks;Samples=$samples;Processes=$identities;Limit='Headless forwarding, native caption menu and console title delivery only; renderer appearance, real input, updater networking, toast activation and UIA are covered separately.'} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Run 'app-delivery-results.json')
}
if(@($checks | Where-Object {-not $_.Passed}).Count){exit 1}
