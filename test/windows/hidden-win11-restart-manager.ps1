#requires -Version 7.0
<#
Portable, hidden-desktop measurement of how noctty answers an installer's
Restart Manager close (WM_QUERYENDSESSION / WM_ENDSESSION with
ENDSESSION_CLOSEAPP), the way Inno Setup asks for it: RmStartSession,
RmRegisterResources on the files Setup replaces, RmGetList, RmShutdown without
the force flag, RmEndSession. Run with -Bin <source bin directory> -Run <new
evidence directory>; -Cases picks cases (comma-separated, all by default). The
run directory must not already exist.

Cases (each its own portable copy, restoring a seeded session of two windows:
the first with two tabs, the second of them split, the second with one tab):
  idle-two-windows  nothing running: RmShutdown returns 0, noctty exits 0 and
                    the saved session still holds both windows, tabs and split.
  busy-always       confirm-close-surface = always, and
  busy-ping         `ping -t localhost` in every pane with the default
                    confirm-close-surface: RmShutdown returns
                    ERROR_FAIL_SHUTDOWN (351) at once, noctty keeps running,
                    shows no prompt, keeps the foreground where it was, and the
                    saved session is the one written at the query.
  settings-dirty    Settings open with an unsaved font size: declined, and the
                    edit is still there.
  cancel            an accepted query (sent to every window) and then
                    WM_ENDSESSION(FALSE): every window stays, the session lock
                    stays held, and a later save still writes the file. A
                    Restart Manager close then still succeeds.
  signout           WM_QUERYENDSESSION and WM_ENDSESSION(TRUE) without
                    ENDSESSION_CLOSEAPP, as a sign-out sends them: noctty saves,
                    latches (a later checkpoint writes nothing) and does not
                    quit by itself (Windows ends the process).

Cases with no terminal window (no seeded session is restored), which only the
hidden lifecycle window (class noctty.win32.lifecycle) lets Restart Manager
ask:
  headless          initial-window = false and quit-after-last-window-closed =
                    false: Restart Manager lists the process as RmOtherWindow
                    (2), RmShutdown returns 0 and noctty exits 0. The lifecycle
                    window is a top-level window that is never visible and is
                    not among UI Automation's top-level elements.
  settings-only-clean, settings-only-dirty
                    Settings opened from a window that is then closed
                    (quit-after-last-window-closed = false): clean, it closes
                    and exits 0; with an unsaved font size, declined, and the
                    edit is still there.
  embedding-idle    an idle `-Embedding` default-terminal server, asked within
                    its 5 s idle timeout: RmShutdown returns 0 and it exits.
                    It changes no registration and the default terminal is not
                    touched, but for that second it publishes the real handoff
                    class object in the session's live COM class table (the
                    measurement AUMID does not isolate it). So the case is
                    refused, before anything starts, while HKCU
                    Console\%%Startup DelegationTerminal selects noctty: a
                    console started then could be handed to this copy.

Safety. Only this run's portable copies are registered with Restart Manager:
their noctty.exe and DLLs, never OpenConsole.exe (an RmUnknownApp that fails
every non-forced shutdown). Leaving it out models the registration set the
planned installer exclusion (RMCLOSE-4) produces; today Setup still registers
it. Before
RmShutdown the script checks that Restart Manager lists exactly the copy it
started (PID and start time, read fresh) and aborts otherwise. It never calls
RmShutdown with the force flag, RmRestart (which starts on the visible
desktop) or anything that copies, and never switches desktops or injects
input: keys are messages sent to this run's own windows, with the modifier
state of their own private input queue cleared first. Every process runs
on a new private desktop inside an owned kill-on-close job, with LOCALAPPDATA
and APPDATA redirected, single instance off and a class of its own. The real
startup-attempts.json is fingerprinted, the PowerShell history guard runs and
the clipboard sequence number is compared before and after. Only exact PIDs
this script started are ended. Results hold window counts, process IDs, file
times and assertions. It exits 1 when a check fails, so it can be run against
a build that still has the problems to show what fails.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $DesktopName,
    [string] $Cases = '',
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 900,
    [string] $ExpectedStartupHash,
    [string] $ExpectedStartupModified
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-local-lib.ps1')

# The -Embedding case publishes the real handoff class object (CLSID below) in
# the session's class table, which neither the private desktop nor the
# measurement AUMID isolates. While the user's console delegation selects
# noctty, a console they start could be handed to this hidden copy, so the
# case is refused (as hidden-win11-embedding-idle.ps1 refuses it). Only that
# one value is read, and an unreadable key fails closed.
function Assert-RmEmbeddingDelegationSafe {
    try { $selection=Get-ItemProperty -LiteralPath 'HKCU:\Console\%%Startup' -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return }
    $terminal=[guid]::Empty
    if([guid]::TryParse([string]$selection.DelegationTerminal,[ref]$terminal) -and
        $terminal -eq [guid]'33368C6F-D328-410C-B225-26DC9F12C728') {
        throw 'embedding-idle refused: noctty is the selected delegated terminal, and the measurement AUMID does not isolate the real COM handoff class. Run the other cases with -Cases, or use a machine whose console delegation does not select noctty.'
    }
}
$requestedCases=if($Cases) { @($Cases -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @('embedding-idle') }
if($requestedCases -contains 'embedding-idle') { Assert-RmEmbeddingDelegationSafe }
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class Rm {
    [StructLayout(LayoutKind.Sequential)] public struct UniqueProcess { public int Pid; public uint StartLow, StartHigh; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct ProcessInfo {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string ServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmStartSession(out uint h, int flags, StringBuilder key);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] public static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nSvc, string[] svcs);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In, Out] ProcessInfo[] info, out uint reasons);
    [DllImport("rstrtmgr.dll")] static extern int RmShutdown(uint h, uint flags, IntPtr status);
    [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint h);
    public static ProcessInfo[] List(uint h, out int err) {
        uint needed=0, count=0, reasons; var list=new ProcessInfo[0];
        err=RmGetList(h,out needed,ref count,null,out reasons);
        if(err==234) { list=new ProcessInfo[needed]; count=needed; err=RmGetList(h,out needed,ref count,list,out reasons); }
        if(count<list.Length) Array.Resize(ref list,(int)count);
        return list;
    }
    public static DateTime StartTime(ProcessInfo info) {
        return DateTime.FromFileTimeUtc(((long)info.Process.StartHigh<<32)|info.Process.StartLow);
    }
    public class Sample { public long Ms; public int Hosts; public bool Alive, Prompt, LifecycleShown; public IntPtr Foreground; }
    // RmShutdown, without the force flag, on a thread of this process (so on
    // this desktop), sampling the copy's windows every 50 ms until it returns.
    public static int Shutdown(uint h, int pid, IntPtr process, List<Sample> timeline, out long elapsed) {
        int result=-1; var t=new Thread(()=> { result=RmShutdown(h,0,IntPtr.Zero); });
        var sw=System.Diagnostics.Stopwatch.StartNew(); t.Start();
        while(!t.Join(50)) timeline.Add(Take(sw.ElapsedMilliseconds,pid,process));
        elapsed=sw.ElapsedMilliseconds;
        timeline.Add(Take(elapsed,pid,process));
        return result;
    }
    public static Sample Take(long ms, int pid, IntPtr process) {
        var hosts=Windows(pid,"noctty.win32.host"); bool prompt=false, shown=false;
        foreach(var host in hosts) if(PromptShown(host)) prompt=true;
        foreach(var w in Windows(pid,"noctty.win32.lifecycle")) if(IsWindowVisible(w)) shown=true;
        return new Sample { Ms=ms, Hosts=hosts.Length, Alive=WaitForSingleObject(process,0)==258, Prompt=prompt, LifecycleShown=shown, Foreground=GetForegroundWindow() };
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent,IntPtr after,string cls,string title);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h,uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr h,int index);
    // The app's message-only window (under HWND_MESSAGE), which EnumWindows
    // does not list.
    public static IntPtr MessageWindow(int pid) {
        var h=IntPtr.Zero;
        while((h=FindWindowExW(new IntPtr(-3),h,"noctty.win32.app",null))!=IntPtr.Zero) { int id; GetWindowThreadProcessId(h,out id); if(id==pid) return h; }
        return IntPtr.Zero;
    }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static bool TopLevel(IntPtr h) { return GetAncestor(h,1)==GetDesktopWindow(); }
    public static long ExStyle(IntPtr h) { return GetWindowLongPtrW(h,-20).ToInt64(); }
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint ms);
    delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint ms,out IntPtr result);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,string l);
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Windows(int pid, string cls) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)==cls) list.Add(h); return true; },IntPtr.Zero);
        return list.ToArray();
    }
    public static IntPtr Child(IntPtr parent,int id) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(parent,(c,p)=> { if(GetDlgCtrlID(c)==id) { found=c; return false; } return true; },IntPtr.Zero);
        return found;
    }
    // The close prompt's accept button (control 2003) is shown.
    public static bool PromptShown(IntPtr host) { var a=Child(host,2003); return a!=IntPtr.Zero && IsWindowVisible(a); }
    // A message sent and answered within 5 s; null when it was not.
    public static long? Send(IntPtr h,uint m,long w,long l) {
        IntPtr result;
        if(SendMessageTimeoutW(h,m,new IntPtr(w),new IntPtr(l),0x2,5000,out result)==IntPtr.Zero) return null;
        return result.ToInt64();
    }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr h; public uint m; public IntPtr w,l; public uint t; public int x,y; }
    [DllImport("user32.dll")] static extern bool PeekMessageW(out Msg m,IntPtr h,uint min,uint max,uint remove);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from,uint to,bool attach);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    static void SendKey(IntPtr h,uint m,int key,long l) {
        IntPtr result;
        if(SendMessageTimeoutW(h,m,new IntPtr(key),new IntPtr(l),0,20000,out result)==IntPtr.Zero && Marshal.GetLastWin32Error()==1460)
            throw new Exception("Key not handled within 20 s");
    }
    // A key-down and key-up for a pane, which runs the in-app keybind for
    // that key (as hidden-win11-session-restore.ps1 does). noctty reads the
    // modifiers from its thread's keyboard state, which a posted key does not
    // update and a private desktop can leave stale (a plain F9 arrived as
    // Shift+F9 on 10-18), so they are cleared there: this thread joins that
    // input queue and the key is sent, not posted, so noctty handles it
    // before the queues part. The user's keyboard is another queue.
    public static void Key(IntPtr h,int key) {
        int pid; uint target=(uint)GetWindowThreadProcessId(h,out pid); uint me=GetCurrentThreadId();
        Msg queue; PeekMessageW(out queue,IntPtr.Zero,0,0,0); // Give this thread an input queue.
        if(target==0 || !AttachThreadInput(me,target,true)) throw new Exception("AttachThreadInput failed");
        try {
            if(!SetKeyboardState(new byte[256])) throw new Exception("SetKeyboardState failed");
            SendKey(h,0x100,key,1);
            if(IsWindow(h)) SendKey(h,0x101,key,0xC0000001L);
        } finally { AttachThreadInput(me,target,false); }
    }
    public static string Text(IntPtr h) { var sb=new StringBuilder(512); SendMessageW(h,0x0D,new IntPtr(512),sb); return sb.ToString(); }
    public static void SetText(IntPtr h,string text) { SendMessageW(h,0x0C,IntPtr.Zero,text); }
}
'@
if (-not $Driver) {
    Invoke-LocalHiddenDriver -Script $PSCommandPath -Bin $Bin -Run $Run -TimeoutSeconds $DriverTimeoutSeconds `
        -ExpectedStartupHash $ExpectedStartupHash -ExpectedStartupModified $ExpectedStartupModified `
        -DesktopPrefix 'noctty-rm-' -Label 'Hidden Restart Manager close' -PassDesktopName -GuardClipboard `
        -DriverArguments @("-Cases `"$Cases`"")
    exit
}

# This branch executes only on the newly created desktop; children inherit it.
# Its output is not shown, so an error that stops it is kept in the run.
# (A trap covers the whole script, the outer half included.)
trap { if($Driver) { Set-Content -LiteralPath (Join-Path $Run 'driver-error.txt') -Value ($_ | Out-String) }; break }
$script:checks=[Collections.Generic.List[object]]::new()
$script:processes=[Collections.Generic.List[object]]::new()
$results=[ordered]@{ Cases=[ordered]@{} }
$runClass='noctty-test-rm-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$closeApp=1
$Msg=@{ Close=0x10; QueryEndSession=0x11; EndSession=0x16; DisplayChange=0x7E }

# Two windows: the first with two tabs, the second of them split in two; the
# second with one tab.
function Session-Json([string]$Cwd) {
    $pane=@{ pane=@{ cwd=$Cwd } }
    $single=@{ selected_leaf=0; layout=@{ root=0; nodes=@($pane) } }
    $split=@{ selected_leaf=1; layout=@{ root=0; nodes=@(@{ split=@{ axis='horizontal'; ratio=0.5; first=1; second=2 } },$pane,$pane) } }
    $w1=@{ selected_tab=0; x=100; y=100; width=900; height=600; state='normal'; tabs=@($single,$split) }
    $w2=@{ selected_tab=0; x=300; y=200; width=900; height=600; state='normal'; tabs=@($single) }
    return (@{ schema_version=1; windows=@($w1,$w2) } | ConvertTo-Json -Depth 12 -Compress)
}
# The saved session's windows, each as the pane count of each of its tabs:
# '[1,2] [1]' is the seeded session.
function Session-Shape([string]$Path) {
    if(-not (Test-Path -LiteralPath $Path)) { return 'missing' }
    $doc=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $windows=foreach($w in @($doc.windows)) {
        $tabs=foreach($t in @($w.tabs)) { @(@($t.layout.nodes) | Where-Object { $null -ne $_.pane }).Count }
        '[' + (@($tabs) -join ',') + ']'
    }
    return (@($windows) -join ' ')
}
$seededShape='[1,2] [1]'
function Mtime([string]$Path) { if(Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).LastWriteTimeUtc } return $null }

# -HostCount: the terminal windows the case opens with (the seeded session's 2
# unless the config says otherwise). -Embedding starts the copy as a
# default-terminal server, which writes no startup ledger and opens nothing.
function Start-Case([string]$Name,[string[]]$Config,[int]$HostCount=2,[switch]$Embedding) {
    $dir=Join-Path $Run "$Name\bin"; Copy-Portable $Bin $dir
    Set-Content -LiteralPath (Join-Path $dir 'session-state.json') -Value (Session-Json $dir) -NoNewline -Encoding utf8NoBOM
    $cfg=Join-Path $dir 'case.ghostty'
    (@('command = cmd.exe /d /k','single-instance = false','window-save-state = always',
       'copy-on-select = false','clipboard-read = deny','clipboard-write = deny') + $Config) | Set-Content -LiteralPath $cfg
    $exe=Join-Path $dir 'noctty.exe'
    $line='"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,$cfg,$runClass
    if($Embedding) { $line+=' -Embedding' }
    $pi=[HiddenLocal]::Spawn($exe,$line,$dir,"WinSta0\$DesktopName")
    try { $p=[Diagnostics.Process]::GetProcessById($pi.pid); [void]$p.Handle }
    finally { [void][HiddenLocal]::CloseHandle($pi.thread); [void][HiddenLocal]::CloseHandle($pi.process) }
    $script:processes.Add(@{ Case=$Name; Pid=$p.Id; StartTime=$p.StartTime.ToUniversalTime().ToString('o') })
    $case=@{ Name=$Name; Dir=$dir; Process=$p; State=(Join-Path $dir 'session-state.json'); Started=[Diagnostics.Stopwatch]::StartNew() }
    $ok=Wait-Until {
        # The server is up once its message window exists (it registers its
        # class object right after).
        if($Embedding) { return [Rm]::MessageWindow($p.Id) -ne [IntPtr]::Zero }
        $ready=$false
        $ledger=Join-Path $dir 'startup-attempts.json'
        if(Test-Path -LiteralPath $ledger) {
            try { $a=(Get-Content -LiteralPath $ledger -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts; $ready=$a.Count -gt 0 -and $a[-1].phase -eq 'ready' } catch { }
        }
        $ready -and @([HiddenLocal]::Hosts($p.Id)).Count -ge $HostCount
    } 30
    $hosts=@([HiddenLocal]::Hosts($p.Id))
    if(-not $ok) { Stop-Case $case; throw "Case ${Name}: noctty did not start as expected (hosts $($hosts.Count))." }
    $owned=@($hosts) + @([Rm]::Windows($p.Id,'noctty.win32.lifecycle')) + @([Rm]::MessageWindow($p.Id) | Where-Object { $_ -ne [IntPtr]::Zero })
    foreach($h in $owned) { if([HiddenLocal]::WindowDesktop($h) -ne $DesktopName) { Stop-Case $case; throw "Case ${Name}: a window is not on the private desktop." } }
    $case.Hosts=$hosts
    if($Embedding) { Start-Sleep -Milliseconds 300 }
    elseif($HostCount -gt 0) { Start-Sleep -Seconds 5 } # The shells print their first prompts.
    else { Start-Sleep -Milliseconds 500 }
    return $case
}
# The lifecycle windows the copy has, and whether each is hidden, top-level
# (a child of the desktop, not of HWND_MESSAGE) and a tool window.
function Lifecycle-State($case) {
    return @(@([Rm]::Windows($case.Process.Id,'noctty.win32.lifecycle')) | ForEach-Object {
        @{ Visible=[Rm]::Visible($_); TopLevel=[Rm]::TopLevel($_); ToolWindow=(([Rm]::ExStyle($_) -band 0x80) -ne 0) }
    })
}
# How many of UI Automation's top-level elements (the desktop root's
# children) belong to the copy.
function Uia-TopLevel([int]$ProcessId) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$ProcessId)
    return @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition)).Count
}
# Opens Settings from the case's only window (F8 is bound to open_config),
# optionally types an unsaved font size, then closes that window, leaving
# Settings as the copy's only visible window.
function Settings-Only($case,[bool]$Dirty) {
    $out=[ordered]@{}
    [Rm]::Key((Pane $case.Hosts[0]),0x77)
    $ok=Wait-Until { @([Rm]::Windows($case.Process.Id,'noctty.win32.settings')).Count -gt 0 -and [Rm]::Child(@([Rm]::Windows($case.Process.Id,'noctty.win32.settings'))[0],402) -ne [IntPtr]::Zero } 15
    if(-not $ok) { throw "$($case.Name): Settings did not open." }
    $out.Settings=@([Rm]::Windows($case.Process.Id,'noctty.win32.settings'))[0]
    $edit=[Rm]::Child($out.Settings,402)
    if($Dirty) {
        $original=[Rm]::Text($edit)
        $out.Typed=if($original -eq '17') { '18' } else { '17' }
        [Rm]::SetText($edit,$out.Typed)
        Start-Sleep -Milliseconds 800
    }
    [void][Rm]::Send($case.Hosts[0],$Msg.Close,0,0)
    if(-not (Wait-Until { @([HiddenLocal]::Hosts($case.Process.Id)).Count -eq 0 } 10)) { throw "$($case.Name): the terminal window did not close." }
    Start-Sleep -Milliseconds 500
    return $out
}
# Ends the case's own process if it is still running: the exact PID, with its
# start time and image checked again first. The owned job is the backstop.
function Stop-Case($case) {
    $p=$case.Process
    if($p.HasExited) { return }
    $q=Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if(-not $q) { return }
    if($q.StartTime -ne $p.StartTime -or $q.Path -ne $p.Path) { throw 'Exact process identity changed during cleanup.' }
    $p.Kill(); [void]$p.WaitForExit(5000)
}
function Pane($h) {
    $all=@([HiddenLocal]::Surfaces($h))
    if(-not $all.Count) { throw 'Host has no pane.' }
    return $all[0]
}
# Asks Restart Manager to close the copy, as Setup does, and records what
# happens until it returns.
function Rm-Close($case) {
    $p=$case.Process
    $out=[ordered]@{}
    $key=[Text.StringBuilder]::new(64); [uint32]$h=0
    $err=[Rm]::RmStartSession([ref]$h,0,$key); if($err) { throw "RmStartSession failed: $err" }
    try {
        $files=@(Get-ChildItem -LiteralPath $case.Dir -File | Where-Object { $_.Extension -in '.exe','.dll' -and $_.Name -ne 'OpenConsole.exe' } | ForEach-Object FullName)
        $out.Registered=@($files | ForEach-Object { Split-Path -Leaf $_ })
        $err=[Rm]::RmRegisterResources($h,[uint32]$files.Count,[string[]]$files,0,[IntPtr]::Zero,0,$null); if($err) { throw "RmRegisterResources failed: $err" }
        [int]$listErr=0
        $listed=@([Rm]::List($h,[ref]$listErr))
        if($listErr) { throw "RmGetList failed: $listErr" }
        $out.Listed=@($listed | ForEach-Object { @{ Pid=$_.Process.Pid; Type=$_.ApplicationType; Restartable=$_.Restartable } })
        # Only the copy this case started, read fresh, may be closed.
        $fresh=Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        $mine=$listed.Count -eq 1 -and $null -ne $fresh -and -not $p.HasExited -and $listed[0].Process.Pid -eq $p.Id -and
            $fresh.Path -eq $p.Path -and [Math]::Abs(([Rm]::StartTime($listed[0]) - $fresh.StartTime.ToUniversalTime()).TotalMilliseconds) -lt 1000
        if(-not $mine) { throw "Restart Manager lists something other than this case's copy ($(@($listed | ForEach-Object { $_.Process.Pid }) -join ',')); not shutting down." }
        $timeline=[Collections.Generic.List[Rm+Sample]]::new(); [long]$elapsed=0
        $out.ForegroundBefore=[Rm]::GetForegroundWindow().ToInt64()
        $out.Result=[Rm]::Shutdown($h,$p.Id,$p.Handle,$timeline,[ref]$elapsed)
        $out.Ms=$elapsed
        $out.PromptSeen=@($timeline | Where-Object Prompt).Count -gt 0
        $out.ForegroundChanged=@($timeline | Where-Object { $_.Foreground.ToInt64() -ne $out.ForegroundBefore }).Count -gt 0
        $changes=@(); $last=$null
        foreach($s in $timeline) { $k="$($s.Hosts)/$($s.Alive)/$($s.Prompt)/$($s.LifecycleShown)"; if($k -ne $last) { $changes+=@{ Ms=$s.Ms; Hosts=$s.Hosts; Alive=$s.Alive; Prompt=$s.Prompt; LifecycleShown=$s.LifecycleShown }; $last=$k } }
        $out.Timeline=$changes
    } finally { [void][Rm]::RmEndSession($h) }
    return $out
}
# The session lock (session-state.json.lock) is held by the copy.
function Lock-Held([string]$State) {
    try {
        $stream=[IO.File]::Open("$State.lock",[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    } catch [IO.FileNotFoundException] { return $false } catch [IO.IOException] { return $true }
    try { $stream.Lock(0,1); $stream.Unlock(0,1); return $false } catch [IO.IOException] { return $true } finally { $stream.Dispose() }
}
function Send-All($case,[uint32]$Message,[long]$W,[long]$L) {
    return @(@([HiddenLocal]::Hosts($case.Process.Id)) | ForEach-Object { [Rm]::Send($_,$Message,$W,$L) })
}

$all=@('idle-two-windows','busy-always','busy-ping','settings-dirty','cancel','signout','headless','settings-only-clean','settings-only-dirty','embedding-idle')
$selected=if($Cases) { @($Cases -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $all }
foreach($name in $selected) { if($all -notcontains $name) { throw "Unknown case $name." } }

foreach($name in $selected) {
    $r=[ordered]@{}
    switch($name) {
        'idle-two-windows' {
            $case=Start-Case $name @()
            try {
                $r.ShapeBefore=Session-Shape $case.State
                $r.Rm=Rm-Close $case
                $exited=$case.Process.WaitForExit(10000)
                $r.Exited=$exited; if($exited) { $r.ExitCode=$case.Process.ExitCode }
                $r.ShapeAfter=Session-Shape $case.State
                Check "${name}: RmShutdown succeeds" ($r.Rm.Result -eq 0) 0 $r.Rm.Result
                Check "${name}: noctty exits 0" ($exited -and $r.ExitCode -eq 0) 'exit 0' $(if($exited){$r.ExitCode}else{'running'})
                Check "${name}: no prompt" (-not $r.Rm.PromptSeen) $false $r.Rm.PromptSeen
                Check "${name}: the saved session keeps both windows, their tabs and the split" ($r.ShapeAfter -eq $seededShape) $seededShape $r.ShapeAfter
                $r.LockFreeAfter=-not (Lock-Held $case.State)
                Check "${name}: the session lock is free once it has exited" $r.LockFreeAfter $true $r.LockFreeAfter
            } finally { Stop-Case $case }
        }
        { $_ -in 'busy-always','busy-ping' } {
            $config=if($name -eq 'busy-always') { @('confirm-close-surface = always') } else { @('command = cmd.exe /d /k ping -t localhost') }
            $case=Start-Case $name $config
            try {
                $before=Mtime $case.State
                $r.Rm=Rm-Close $case
                Start-Sleep -Milliseconds 1500
                $after=Mtime $case.State
                $r.SessionRewritten=($null -ne $after -and $after -gt $before)
                $r.ShapeAfter=Session-Shape $case.State
                $r.Alive=-not $case.Process.HasExited
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                $r.PromptAfter=@(@([HiddenLocal]::Hosts($case.Process.Id)) | Where-Object { [Rm]::PromptShown($_) }).Count -gt 0
                Check "${name}: declined (ERROR_FAIL_SHUTDOWN)" ($r.Rm.Result -eq 351) 351 $r.Rm.Result
                Check "${name}: declined at once" ($r.Rm.Ms -lt 2000) '< 2000 ms' $r.Rm.Ms
                Check "${name}: noctty keeps running with both windows" ($r.Alive -and $r.Hosts -eq 2) 'alive, 2 windows' "alive=$($r.Alive), $($r.Hosts) windows"
                Check "${name}: no prompt, during or after" (-not $r.Rm.PromptSeen -and -not $r.PromptAfter) $false "$($r.Rm.PromptSeen)/$($r.PromptAfter)"
                Check "${name}: the foreground stays where it was" (-not $r.Rm.ForegroundChanged) $false $r.Rm.ForegroundChanged
                Check "${name}: the query wrote the session as it was" ($r.SessionRewritten -and $r.ShapeAfter -eq $seededShape) "rewritten, $seededShape" "$($r.SessionRewritten), $($r.ShapeAfter)"
            } finally { Stop-Case $case }
        }
        'settings-dirty' {
            $case=Start-Case $name @('keybind = f8=open_config')
            try {
                [Rm]::Key((Pane $case.Hosts[0]),0x77)
                $ok=Wait-Until { @([Rm]::Windows($case.Process.Id,'noctty.win32.settings')).Count -gt 0 -and [Rm]::Child(@([Rm]::Windows($case.Process.Id,'noctty.win32.settings'))[0],402) -ne [IntPtr]::Zero } 15
                if(-not $ok) { throw "${name}: Settings did not open." }
                $settings=@([Rm]::Windows($case.Process.Id,'noctty.win32.settings'))[0]
                $edit=[Rm]::Child($settings,402)
                $original=[Rm]::Text($edit)
                $typed=if($original -eq '17') { '18' } else { '17' }
                [Rm]::SetText($edit,$typed)
                Start-Sleep -Milliseconds 800
                $r.Rm=Rm-Close $case
                Start-Sleep -Milliseconds 800
                $r.Alive=-not $case.Process.HasExited
                $r.SettingsOpen=@([Rm]::Windows($case.Process.Id,'noctty.win32.settings')).Count -eq 1
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                $r.EditKept=$r.SettingsOpen -and ([Rm]::Text([Rm]::Child($settings,402)) -eq $typed)
                Check "${name}: declined" ($r.Rm.Result -eq 351) 351 $r.Rm.Result
                Check "${name}: declined at once" ($r.Rm.Ms -lt 2000) '< 2000 ms' $r.Rm.Ms
                Check "${name}: noctty, both windows and Settings stay open" ($r.Alive -and $r.Hosts -eq 2 -and $r.SettingsOpen) 'alive, 2 windows, Settings' "alive=$($r.Alive), $($r.Hosts) windows, Settings=$($r.SettingsOpen)"
                Check "${name}: the unsaved edit survives" $r.EditKept $typed $r.EditKept
            } finally { Stop-Case $case }
        }
        'cancel' {
            $case=Start-Case $name @()
            try {
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 $closeApp)
                $queried=Mtime $case.State
                $r.Ends=@(Send-All $case $Msg.EndSession 0 $closeApp)
                Start-Sleep -Milliseconds 1500
                $r.Alive=-not $case.Process.HasExited
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                $r.LockHeld=Lock-Held $case.State
                # A later save: the display-change checkpoint, past its one-second throttle.
                [void](Send-All $case $Msg.DisplayChange 32 0)
                $saved=Wait-Until { $m=Mtime $case.State; $null -ne $m -and $m -gt $queried } 5
                $r.LaterSave=$saved
                Check "${name}: every window agrees to the query" (@($r.Queries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.Queries.Count -eq 2) '1,1' ($r.Queries -join ',')
                Check "${name}: every window stays after WM_ENDSESSION(FALSE)" ($r.Alive -and $r.Hosts -eq 2) 'alive, 2 windows' "alive=$($r.Alive), $($r.Hosts) windows"
                Check "${name}: the session lock stays held" $r.LockHeld $true $r.LockHeld
                Check "${name}: later saves still write" $saved $true $saved
                # Still closes for the next request.
                $r.Rm=Rm-Close $case
                $exited=$case.Process.WaitForExit(10000)
                $r.ShapeAfter=Session-Shape $case.State
                Check "${name}: a later Restart Manager close still succeeds" ($r.Rm.Result -eq 0 -and $exited) '0, exited' "$($r.Rm.Result), exited=$exited"
                Check "${name}: and keeps the session" ($r.ShapeAfter -eq $seededShape) $seededShape $r.ShapeAfter
            } finally { Stop-Case $case }
        }
        'signout' {
            $case=Start-Case $name @()
            try {
                Start-Sleep -Milliseconds 1200
                $before=Mtime $case.State
                $r.Queries=@(Send-All $case $Msg.QueryEndSession 0 0)
                $r.Ends=@(Send-All $case $Msg.EndSession 1 0)
                $ended=Mtime $case.State
                $r.Saved=$null -ne $ended -and $ended -gt $before
                $r.ShapeAfter=Session-Shape $case.State
                Start-Sleep -Milliseconds 1500
                [void](Send-All $case $Msg.DisplayChange 32 0)
                Start-Sleep -Milliseconds 1500
                $r.LatchedAfter=(Mtime $case.State) -eq $ended
                $r.Alive=-not $case.Process.HasExited
                $r.Hosts=@([HiddenLocal]::Hosts($case.Process.Id)).Count
                Check "${name}: every window agrees" (@($r.Queries | Where-Object { $_ -ne 1 }).Count -eq 0 -and $r.Queries.Count -eq 2) '1,1' ($r.Queries -join ',')
                Check "${name}: the session is saved as it ends" ($r.Saved -and $r.ShapeAfter -eq $seededShape) "saved, $seededShape" "$($r.Saved), $($r.ShapeAfter)"
                Check "${name}: and latched: a later checkpoint writes nothing" $r.LatchedAfter $true $r.LatchedAfter
                Check "${name}: noctty does not quit by itself" ($r.Alive -and $r.Hosts -eq 2) 'alive, 2 windows' "alive=$($r.Alive), $($r.Hosts) windows"
            } finally { Stop-Case $case }
        }
        'headless' {
            $case=Start-Case $name @('initial-window = false','quit-after-last-window-closed = false') 0
            try {
                $r.Lifecycle=Lifecycle-State $case
                $r.UiaTopLevel=Uia-TopLevel $case.Process.Id
                $r.Rm=Rm-Close $case
                $exited=$case.Process.WaitForExit(10000)
                $r.Exited=$exited; if($exited) { $r.ExitCode=$case.Process.ExitCode }
                $type=@($r.Rm.Listed)[0].Type
                $l=@($r.Lifecycle)
                Check "${name}: one lifecycle window, top-level, hidden, a tool window" ($l.Count -eq 1 -and $l[0].TopLevel -and -not $l[0].Visible -and $l[0].ToolWindow) '1, top-level, hidden, tool' (($l | ForEach-Object { "top=$($_.TopLevel) visible=$($_.Visible) tool=$($_.ToolWindow)" }) -join '; ')
                Check "${name}: not among UI Automation's top-level elements" ($r.UiaTopLevel -eq 0) 0 $r.UiaTopLevel
                Check "${name}: listed as RmOtherWindow" ($type -eq 2) 2 $type
                Check "${name}: RmShutdown succeeds" ($r.Rm.Result -eq 0) 0 $r.Rm.Result
                Check "${name}: noctty exits 0" ($exited -and $r.ExitCode -eq 0) 'exit 0' $(if($exited){$r.ExitCode}else{'running'})
                Check "${name}: the lifecycle window never shows" (@($r.Rm.Timeline | Where-Object { $_.LifecycleShown }).Count -eq 0) $false 'see Timeline'
            } finally { Stop-Case $case }
        }
        { $_ -in 'settings-only-clean','settings-only-dirty' } {
            $dirty=$name -eq 'settings-only-dirty'
            $case=Start-Case $name @('window-save-state = never','quit-after-last-window-closed = false','keybind = f8=open_config') 1
            try {
                $s=Settings-Only $case $dirty
                # A positive control for the headless case's UI Automation
                # check: Settings is one of its top-level elements.
                $r.UiaTopLevel=Uia-TopLevel $case.Process.Id
                $r.Lifecycle=Lifecycle-State $case
                $r.Rm=Rm-Close $case
                if($dirty) {
                    Start-Sleep -Milliseconds 800
                    $r.Alive=-not $case.Process.HasExited
                    $r.SettingsOpen=@([Rm]::Windows($case.Process.Id,'noctty.win32.settings')).Count -eq 1
                    $r.EditKept=$r.SettingsOpen -and ([Rm]::Text([Rm]::Child($s.Settings,402)) -eq $s.Typed)
                    Check "${name}: declined" ($r.Rm.Result -eq 351) 351 $r.Rm.Result
                    Check "${name}: declined at once" ($r.Rm.Ms -lt 2000) '< 2000 ms' $r.Rm.Ms
                    Check "${name}: noctty and Settings stay open" ($r.Alive -and $r.SettingsOpen) 'alive, Settings' "alive=$($r.Alive), Settings=$($r.SettingsOpen)"
                    Check "${name}: the unsaved edit survives" $r.EditKept $s.Typed $r.EditKept
                } else {
                    $exited=$case.Process.WaitForExit(10000)
                    $r.Exited=$exited; if($exited) { $r.ExitCode=$case.Process.ExitCode }
                    Check "${name}: RmShutdown succeeds" ($r.Rm.Result -eq 0) 0 $r.Rm.Result
                    Check "${name}: noctty exits 0" ($exited -and $r.ExitCode -eq 0) 'exit 0' $(if($exited){$r.ExitCode}else{'running'})
                    Check "${name}: Settings is one of UI Automation's top-level elements" ($r.UiaTopLevel -ge 1) '>= 1' $r.UiaTopLevel
                }
                Check "${name}: the lifecycle window never shows" (@($r.Rm.Timeline | Where-Object { $_.LifecycleShown }).Count -eq 0 -and @($r.Lifecycle | Where-Object { $_.Visible }).Count -eq 0) $false 'see Timeline'
            } finally { Stop-Case $case }
        }
        'embedding-idle' {
            Assert-RmEmbeddingDelegationSafe
            $case=Start-Case $name @() 0 -Embedding
            try {
                $r.Lifecycle=Lifecycle-State $case
                $r.Rm=Rm-Close $case
                # Asked, and gone, well inside the server's own 5 s idle
                # timeout (which main's server exits on), so the exit is the
                # close's doing.
                $r.AskedAtMs=$case.Started.ElapsedMilliseconds
                [void]$case.Process.WaitForExit(1500)
                $r.ExitedByMs=if($case.Process.HasExited) { $case.Started.ElapsedMilliseconds } else { $null }
                $exited=$case.Process.WaitForExit(10000)
                $r.Exited=$exited; if($exited) { $r.ExitCode=$case.Process.ExitCode }
                $type=@($r.Rm.Listed)[0].Type
                Check "${name}: asked before its idle timeout" ($r.AskedAtMs -lt 3000) '< 3000 ms after start' $r.AskedAtMs
                Check "${name}: listed as RmOtherWindow" ($type -eq 2) 2 $type
                Check "${name}: RmShutdown succeeds" ($r.Rm.Result -eq 0) 0 $r.Rm.Result
                Check "${name}: the server exits 0 on the request, before its idle timeout" ($null -ne $r.ExitedByMs -and $r.ExitedByMs -lt 4500 -and $r.ExitCode -eq 0) 'exit 0, < 4500 ms after start' "exited by $($r.ExitedByMs) ms, code $($r.ExitCode)"
                Check "${name}: the lifecycle window never shows" (@($r.Rm.Timeline | Where-Object { $_.LifecycleShown }).Count -eq 0 -and @($r.Lifecycle | Where-Object { $_.Visible }).Count -eq 0) $false 'see Timeline'
            } finally { Stop-Case $case }
        }
    }
    $results.Cases[$name]=$r
}

$results.Processes=$script:processes
$results.Checks=$script:checks
$results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Run 'restart-manager-results.json')
$failed=@($script:checks | Where-Object { -not $_.Passed })
foreach($c in $script:checks) { Write-Host ("{0} {1} (expected {2}, actual {3})" -f $(if($c.Passed){'PASS'}else{'FAIL'}),$c.Name,$c.Expected,$c.Actual) }
if($failed.Count) { exit 1 }
exit 0
