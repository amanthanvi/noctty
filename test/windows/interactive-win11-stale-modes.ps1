[CmdletBinding()]
param(
    [string] $ExePath,
    [string] $RunRoot,
    [ValidateSet('cmd', 'pwsh')] [string[]] $Shells = @('cmd', 'pwsh'),
    [ValidateSet('All', 'Modes', 'Paste')] [string] $Scenario = 'Modes',
    [int] $TimeoutSeconds = 30,
    [switch] $ExerciseParentTimeout,
    [switch] $Worker
)

# PKG-16 runtime checks. Never launches the supplied executable in place.
# Each case owns a portable copy, redirected AppData, and a hidden desktop.
# Paste additionally requires its own windowstation: clipboard is shared
# between a station's desktops. Modes alone never access the clipboard.
# PowerShell loads the copied integration manually so history is redirected
# before the first interactive prompt. This does not test auto-injection.
# Marker files prove commands ran; input echo alone is not an oracle.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ExePath) { $ExePath = Join-Path $repoRoot 'zig-out\bin\noctty.exe' }
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot ('.zig-cache\pkg16\stale-modes-' + [guid]::NewGuid().ToString('N')) }
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
if ($ExerciseParentTimeout -and $Scenario -ne 'Modes') { throw 'Timeout exercise requires -Scenario Modes.' }

function Get-Fingerprint([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.Ticks):$($item.Length):$((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)"
}

if (-not ('StaleModesNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StaleModesNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SI {
        public int cb; public string reserved, desktop, title;
        public int x,y,xsize,ysize,xchars,ychars,fill,flags;
        public short show, cbReserved; public IntPtr reserved2, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process, thread; public int pid, tid; }
    public delegate bool EnumProc(IntPtr hwnd, IntPtr arg);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr security);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateWindowStationW(string name, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll")] public static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateProcessW(string application, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref SI startup, out PI info);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObjectW(IntPtr security, string name);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr data, uint size, out uint returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool member);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    public static int[] JobPids(IntPtr job) {
        // This harness has few children. MORE_DATA fails closed rather than
        // truncating an unexpectedly large process list.
        int size=8+IntPtr.Size*256; IntPtr buffer=Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if(!QueryInformationJobObject(job,3,buffer,(uint)size,out returned)) throw new Exception("Query owned job failed: "+Marshal.GetLastWin32Error());
            int count=Marshal.ReadInt32(buffer,4); var ids=new int[count];
            for(int i=0;i<count;i++) ids[i]=(int)Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size);
            return ids;
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static int[] ReapOwnedJob(IntPtr job) {
        var stopped=new List<int>();
        for(int round=0;round<8;round++) {
            int[] ids=JobPids(job); if(ids.Length==0) return stopped.ToArray();
            foreach(int id in ids) {
                // Hold the exact process handle and freshly verify membership
                // before terminating. A reused PID outside our job is skipped.
                IntPtr handle=OpenProcess(0x00101001,false,id);
                if(handle==IntPtr.Zero) continue;
                try {
                    bool member;
                    if(!IsProcessInJob(handle,job,out member)) throw new Exception("Owned job membership query failed");
                    if(!member) continue;
                    uint code;
                    if(!GetExitCodeProcess(handle,out code)) throw new Exception("Owned process query failed");
                    if(code!=259) continue;
                    if(!TerminateProcess(handle,1)) {
                        if(!GetExitCodeProcess(handle,out code) || code==259) throw new Exception("Owned process termination failed");
                    } else stopped.Add(id);
                    if(WaitForSingleObject(handle,10000)!=0) throw new Exception("Owned process did not exit");
                } finally { CloseHandle(handle); }
            }
        }
        if(JobPids(job).Length!=0) throw new Exception("Owned job still has processes after cleanup");
        return stopped.ToArray();
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr arg);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] public static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint flags, UIntPtr size);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr memory);
    public static string ClassOf(IntPtr hwnd) { var s=new StringBuilder(256); GetClassNameW(hwnd,s,256); return s.ToString(); }
    public static IntPtr Host(int pid) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,a)=> { int p; GetWindowThreadProcessId(h,out p); if(p==pid && ClassOf(h)=="noctty.win32.host") found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static IntPtr Surface(IntPtr host) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(host,(h,a)=> { if(ClassOf(h)=="noctty.win32") found=h; return true; },IntPtr.Zero);
        return found;
    }
    public static void Send(IntPtr hwnd,uint msg,int value,long bits) {
        UIntPtr result;
        if(SendMessageTimeoutW(hwnd,msg,(UIntPtr)(uint)value,(IntPtr)bits,2,5000,out result)==IntPtr.Zero)
            throw new Exception("SendMessageTimeout failed: "+Marshal.GetLastWin32Error());
    }
    public static void Key(IntPtr hwnd,int vk,int ch,bool ctrl) {
        KeyInternal(hwnd,vk,ch,ctrl,false);
    }
    public static void Character(IntPtr hwnd,char ch) {
        short mapped=VkKeyScanW(ch);
        if(mapped==-1) throw new Exception("Unmappable fixture character");
        KeyInternal(hwnd,mapped&255,ch,false,(mapped&256)!=0);
    }
    static void KeyInternal(IntPtr hwnd,int vk,int ch,bool ctrl,bool shift) {
        // Share the hidden GUI thread's input queue only during the key. This
        // supplies GetKeyboardState with Ctrl for a real Ctrl+C key event;
        // restore the exact old state and detach in every exit path.
        int pid; uint target=GetWindowThreadProcessId(hwnd,out pid), me=GetCurrentThreadId();
        bool attached=AttachThreadInput(me,target,true);
        if(!attached) throw new Exception("AttachThreadInput failed");
        byte[] old=new byte[256]; GetKeyboardState(old);
        try {
            byte[] state=(byte[])old.Clone();
            foreach(int k in new int[]{16,17,18,160,161,162,163,164,165}) state[k]=0;
            if(ctrl) { state[17]=128; state[162]=128; }
            if(shift) { state[16]=128; state[160]=128; }
            if(!SetKeyboardState(state)) throw new Exception("SetKeyboardState failed");
            long bits=1 | ((long)MapVirtualKeyW((uint)vk,0)<<16);
            Send(hwnd,0x100,vk,bits);
            if(ch!=0) Send(hwnd,0x102,ch,bits);
            Send(hwnd,0x101,vk,bits|0xC0000000L);
        } finally { SetKeyboardState(old); AttachThreadInput(me,target,false); }
    }
    public static void Clipboard(IntPtr owner,string text) {
        byte[] bytes=Encoding.Unicode.GetBytes(text+"\0");
        IntPtr memory=GlobalAlloc(2,(UIntPtr)bytes.Length);
        if(memory==IntPtr.Zero) throw new Exception("GlobalAlloc failed");
        bool transferred=false;
        try {
            IntPtr ptr=GlobalLock(memory); if(ptr==IntPtr.Zero) throw new Exception("GlobalLock failed");
            Marshal.Copy(bytes,0,ptr,bytes.Length); GlobalUnlock(memory);
            if(!OpenClipboard(owner)) throw new Exception("OpenClipboard failed");
            try { if(!EmptyClipboard() || SetClipboardData(13,memory)==IntPtr.Zero) throw new Exception("SetClipboardData failed"); transferred=true; }
            finally { CloseClipboard(); }
        } finally { if(!transferred) GlobalFree(memory); }
    }
}
'@
}

function Start-Hidden([string] $Application, [string] $Command, [string] $Directory, [string] $Desktop, [IntPtr] $OwnerJob = [IntPtr]::Zero) {
    $si = [StaleModesNative+SI]::new()
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][StaleModesNative+SI])
    $si.desktop = $Desktop
    $pi = [StaleModesNative+PI]::new()
    $flags = if ($OwnerJob -ne [IntPtr]::Zero) { 0x08004004 } else { 0x08004000 }
    if (-not [StaleModesNative]::CreateProcessW($Application, [Text.StringBuilder]::new($Command),
            [IntPtr]::Zero, [IntPtr]::Zero, $false, $flags, [IntPtr]::Zero, $Directory, [ref]$si, [ref]$pi)) {
        throw "CreateProcessW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        # Assign the suspended driver before its first instruction: every
        # descendant inherits containment even if the worker cannot finalize.
        if ($OwnerJob -ne [IntPtr]::Zero) {
            if (-not [StaleModesNative]::AssignProcessToJobObject($OwnerJob, $pi.process)) {
                [void][StaleModesNative]::TerminateProcess($pi.process, 1)
                throw 'Assigning suspended driver to owned job failed.'
            }
            if ([StaleModesNative]::ResumeThread($pi.thread) -eq [uint32]::MaxValue) {
                [void][StaleModesNative]::TerminateProcess($pi.process, 1)
                throw 'Resuming contained driver failed.'
            }
        }
    }
    finally {
        [void][StaleModesNative]::CloseHandle($pi.thread)
        [void][StaleModesNative]::CloseHandle($pi.process)
    }
    return [Diagnostics.Process]::GetProcessById($pi.pid)
}

function Stop-Owned([Diagnostics.Process] $Process, [string] $ExpectedPath, [datetime] $StartTime) {
    # Re-read the exact PID immediately before termination; reject PID reuse
    # and executable changes. No name/pattern or system-wide tree kill.
    $fresh = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if (-not $fresh) { return }
    if ($fresh.StartTime -ne $StartTime -or $fresh.Path -ne $ExpectedPath) { throw "PID identity changed: $($Process.Id)" }
    $fresh.Kill()
    if (-not $fresh.WaitForExit(10000)) { throw "Owned process $($fresh.Id) did not exit." }
}

if (-not $Worker) {
    $ExePath = (Resolve-Path -LiteralPath $ExePath).Path
    $sourceEvidence = [ordered]@{ path = $ExePath; sha256 = (Get-FileHash -LiteralPath $ExePath).Hash;
        mtimeUtc = (Get-Item -LiteralPath $ExePath).LastWriteTimeUtc.ToString('o') }
    if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be a fresh directory.' }
    $realStartup = Join-Path $env:LOCALAPPDATA 'noctty\startup-attempts.json'
    $startupBefore = Get-Fingerprint $realStartup
    $expectedHash = '7B4F9AA31731DF822E3EC13F8381E76DC759455ABBF8BB458F74E10BF5E2BB9C'
    if ((Get-FileHash -LiteralPath $realStartup).Hash -ne $expectedHash -or
        (Get-Item -LiteralPath $realStartup).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss') -ne '2026-10-10T18:18:34') {
        throw 'Real startup-attempts.json differs from the adopted incident baseline; no launch performed.'
    }
    # GetFolderPath deliberately ignores redirected APPDATA, as PSReadLine does.
    $historyRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $realHistories = @('Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt',
        'Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt') | ForEach-Object { Join-Path $historyRoot $_ }
    $historyBefore = @{}; foreach ($path in $realHistories) { $historyBefore[$path] = Get-Fingerprint $path }
    [void](New-Item -ItemType Directory -Path $RunRoot)
    $RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
    $fixtureSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
class Fixture {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle,uint mode);
    static void Emit(string text) { byte[] b=Encoding.ASCII.GetBytes(text); var s=Console.OpenStandardOutput(); s.Write(b,0,b.Length); s.Flush(); }
    static int Main(string[] a) {
        string action=a[0], marker=a[1]; uint output;
        if(GetConsoleMode(GetStdHandle(-11),out output)) SetConsoleMode(GetStdHandle(-11),output|4);
        if(action=="interrupt") {
            Console.CancelKeyPress+=(s,e)=> { File.WriteAllText(marker+".interrupted","yes"); Environment.Exit(0); };
            File.WriteAllText(marker+".ready",Process.GetCurrentProcess().Id.ToString());
            Thread.Sleep(Timeout.Infinite); return 0;
        }
        if(action=="paste") {
            uint input; IntPtr h=GetStdHandle(-10);
            if(!GetConsoleMode(h,out input) || !SetConsoleMode(h,(input|512)&~(2u|4u))) return 11;
            Emit("\x1b[?2004h"); File.WriteAllText(marker+".ready",Process.GetCurrentProcess().Id.ToString());
            var stream=Console.OpenStandardInput(); var bytes=new MemoryStream();
            string text="";
            while(!text.EndsWith("\x1b[201~")) { int b=stream.ReadByte(); if(b<0) return 12; bytes.WriteByte((byte)b); text=Encoding.UTF8.GetString(bytes.ToArray()); }
            File.WriteAllText(marker+".bytes",BitConverter.ToString(bytes.ToArray()));
            if(!text.StartsWith("\x1b[200~")) return 13;
            text=text.Substring(6,text.Length-12);
            var info=new ProcessStartInfo(Environment.GetEnvironmentVariable("ComSpec"),"/d /q") { UseShellExecute=false, RedirectStandardInput=true, CreateNoWindow=true };
            using(var p=Process.Start(info)) { p.StandardInput.Write(text); p.StandardInput.Close(); p.WaitForExit(); }
            Emit("\x1b[?2004l"); SetConsoleMode(h,input); File.WriteAllText(marker+".done","yes"); return 0;
        }
        // No pop/reset on either exit path: the following shell prompt owns it.
        Emit(a[2]=="31" ? "\x1b[>31u" : "\x1b[>1u\x1b[>4;2m");
        File.WriteAllText(marker+".ready",Process.GetCurrentProcess().Id.ToString());
        if(action=="wait") Thread.Sleep(Timeout.Infinite);
        return 0;
    }
}
'@
    $fixturePath = Join-Path $RunRoot 'mode-fixture.exe'
    $sourcePath = Join-Path $RunRoot 'mode-fixture.cs'
    [IO.File]::WriteAllText($sourcePath, $fixtureSource)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe "/out:$fixturePath" $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Console fixture compilation failed.' }
    $allResults = @()
    try {
        foreach ($shell in $Shells) {
            $caseRoot = Join-Path $RunRoot $shell
            [void](New-Item -ItemType Directory -Path $caseRoot)
            Copy-Item -LiteralPath $ExePath -Destination (Join-Path $caseRoot 'noctty.exe')
            foreach ($name in @('conpty.dll', 'OpenConsole.exe')) {
                $path = Join-Path (Split-Path -Parent $ExePath) $name
                if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $caseRoot }
            }
            # Keep built resources/fonts and integration matched to this executable.
            $share = Join-Path (Split-Path -Parent (Split-Path -Parent $ExePath)) 'share'
            if (-not (Test-Path -LiteralPath $share)) { throw "Build share directory absent: $share" }
            Copy-Item -LiteralPath $share -Destination (Join-Path $caseRoot 'share') -Recurse
            [IO.File]::WriteAllText((Join-Path $caseRoot 'noctty.portable'), '')
            Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $caseRoot 'mode-fixture.exe')
            [void](New-Item -ItemType Directory -Path (Join-Path $caseRoot 'local'), (Join-Path $caseRoot 'roaming'))
            $uniqueName = 'noctty-stale-' + [guid]::NewGuid().ToString('N')
            $stationName = if ($Scenario -eq 'Modes') { 'WinSta0' } else { $uniqueName }
            $desktopLeaf = if ($Scenario -eq 'Modes') { $uniqueName } else { 'hidden' }
            $station = [IntPtr]::Zero
            if ($Scenario -ne 'Modes') {
                $station = [StaleModesNative]::CreateWindowStationW($stationName, 0, 0x10000000, [IntPtr]::Zero)
                if ($station -eq [IntPtr]::Zero) { throw "Private paste windowstation unavailable (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())); run -Scenario Modes for checks without clipboard access." }
            }
            $originalStation = [StaleModesNative]::GetProcessWindowStation()
            $desktop = [IntPtr]::Zero
            try {
                if ($station -ne [IntPtr]::Zero -and -not [StaleModesNative]::SetProcessWindowStation($station)) { throw 'SetProcessWindowStation failed.' }
                $desktop = [StaleModesNative]::CreateDesktopW($desktopLeaf, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
                if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktopW failed.' }
            }
            finally {
                if ($station -ne [IntPtr]::Zero -and -not [StaleModesNative]::SetProcessWindowStation($originalStation)) { throw 'Failed to restore parent windowstation.' }
                if ($desktop -eq [IntPtr]::Zero -and $station -ne [IntPtr]::Zero) { [void][StaleModesNative]::CloseWindowStation($station) }
            }
            $deskName = "$stationName\$desktopLeaf"
            [IO.File]::WriteAllText((Join-Path $caseRoot 'desktop.txt'), $deskName)
            $driver = $null
            $driverHandle = [IntPtr]::Zero
            $ownerJob = [StaleModesNative]::CreateJobObjectW([IntPtr]::Zero, [NullString]::Value)
            if ($ownerJob -eq [IntPtr]::Zero) { throw 'Creating owned driver job failed.' }
            $timedOut = $false
            try {
                $pwsh = (Get-Command pwsh.exe).Source
                $command = '"{0}" -NoProfile -NonInteractive -File "{1}" -Worker -RunRoot "{2}" -Shells {3} -TimeoutSeconds {4} -Scenario {5}' -f $pwsh, $PSCommandPath, $caseRoot, $shell, $TimeoutSeconds, $Scenario
                if ($ExerciseParentTimeout) { $command += ' -ExerciseParentTimeout' }
                $driver = Start-Hidden $pwsh $command $caseRoot $deskName $ownerJob
                $started = $driver.StartTime
                $driverHandle = [StaleModesNative]::OpenProcess(0x00101000, $false, $driver.Id)
                if ($driverHandle -eq [IntPtr]::Zero) { throw 'Opening driver wait/query handle failed.' }
                $driverWaitMilliseconds = ($TimeoutSeconds * 20 + 60) * 1000
                if ($ExerciseParentTimeout) {
                    $armed = Join-Path $caseRoot 'timeout.armed'
                    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds * 4)
                    while (-not (Test-Path -LiteralPath $armed)) {
                        if ($driver.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Worker did not arm timeout exercise.' }
                        Start-Sleep -Milliseconds 50
                    }
                    $driverWaitMilliseconds = 1000
                }
                if (-not $driver.WaitForExit($driverWaitMilliseconds)) {
                    $timedOut = $true
                    Stop-Owned $driver $pwsh $started
                    throw 'Hidden driver timed out.'
                }
                $result = Get-Content -LiteralPath (Join-Path $caseRoot 'result.json') -Raw | ConvertFrom-Json
                $allResults += $result
                # Process.ExitCode can remain null after WaitForExit in the
                # managed desktop harness. Read the native code as well.
                $driverExit = [uint32]259
                if (-not [StaleModesNative]::GetExitCodeProcess($driverHandle, [ref]$driverExit)) { throw 'GetExitCodeProcess failed.' }
                if ($driverExit -ne 0 -or $result.status -ne 'PASS') { throw "Hidden $shell checks failed (exit $driverExit): $($result.error)" }
            }
            finally {
                try {
                    $stopped = @([StaleModesNative]::ReapOwnedJob($ownerJob))
                    [pscustomobject]@{ timedOut = $timedOut; terminatedPids = $stopped; remainingPids = @([StaleModesNative]::JobPids($ownerJob)) } |
                        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $caseRoot 'cleanup.json')
                }
                finally {
                    [void][StaleModesNative]::CloseHandle($ownerJob)
                    if ($driverHandle -ne [IntPtr]::Zero) { [void][StaleModesNative]::CloseHandle($driverHandle) }
                    [void][StaleModesNative]::CloseDesktop($desktop)
                    if ($station -ne [IntPtr]::Zero) { [void][StaleModesNative]::CloseWindowStation($station) }
                    if ((Get-Fingerprint $realStartup) -ne $startupBefore) { throw 'Real startup-attempts.json changed.' }
                    foreach ($path in $realHistories) { if ((Get-Fingerprint $path) -ne $historyBefore[$path]) { throw 'Real PSReadLine history changed.' } }
                }
            }
        }
    }
    finally {
        [pscustomobject]@{ source = $sourceEvidence; scenario = $Scenario; results = $allResults; startup = Get-Fingerprint $realStartup; historyUnchanged = (@($realHistories | Where-Object { (Get-Fingerprint $_) -ne $historyBefore[$_] }).Count -eq 0) } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunRoot 'summary.json')
    }
    Write-Host "stale modes: PASS; evidence=$RunRoot; real startup and history unchanged"
    return
}

# This branch runs inside the hidden desktop. All state lives beside the copy.
$env:LOCALAPPDATA = Join-Path $RunRoot 'local'
$env:APPDATA = Join-Path $RunRoot 'roaming'
$env:GHOSTTY_RESOURCES_DIR = Join-Path $RunRoot 'share\ghostty'
$shell = $Shells[0]
$fixture = Join-Path $RunRoot 'mode-fixture.exe'
$runExe = Join-Path $RunRoot 'noctty.exe'
$checks = [Collections.Generic.List[string]]::new()
$result = [ordered]@{ shell = $shell; status = 'FAIL'; checks = $checks; error = $null }
$app = $null
$hostWindow = [IntPtr]::Zero

function Wait-Marker([string] $Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($app.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for marker $([IO.Path]::GetFileName($Path))" }
        Start-Sleep -Milliseconds 50
    }
}
function Type-Command([string] $Text) {
    foreach ($ch in $Text.ToCharArray()) {
        [StaleModesNative]::Character($surface, $ch)
    }
    [StaleModesNative]::Key($surface, 13, 13, $false)
}
function Invoke-Fixture([string] $Action, [string] $Marker, [string] $Flags = '31') {
    $prefix = if ($shell -eq 'pwsh') { '& ' } else { '' }
    Type-Command ($prefix + '"' + $fixture + '" ' + $Action + ' "' + $Marker + '" ' + $Flags)
}
function Assert-Enter([string] $Marker) {
    if ($shell -eq 'pwsh') { Type-Command ("[IO.File]::WriteAllText('$Marker','yes')") }
    else { Type-Command ('echo yes>"' + $Marker + '"') }
    Wait-Marker $Marker
}
function Wait-Prompt {
    if ($shell -ne 'pwsh') { Start-Sleep -Milliseconds 700; return }
    $path = Join-Path $RunRoot 'prompt.sequence'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if (Test-Path -LiteralPath $path) {
            $value = $null
            # The prompt replaces this tiny marker while we poll. A sharing
            # violation is transient; retain the same bounded deadline.
            try { $value = [IO.File]::ReadAllText($path) }
            catch [IO.IOException] { }
            if ($value -match '^\d+$' -and [int]$value -gt $script:PromptSequence) {
                $script:PromptSequence = [int]$value
                # The marker is written by the user's prompt after the mode
                # resets; allow its queued output to reach the terminal.
                Start-Sleep -Milliseconds 150
                return
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Shell did not return to its prompt.' }
        Start-Sleep -Milliseconds 50
    }
}
$script:PromptSequence = 0
try {
    $config = Join-Path $RunRoot 'config.ghostty'
    $configText = "auto-update = off`nconfirm-close-surface = false`nwindow-save-state = never`nsingle-instance = false`nclipboard-paste-protection = false`nkeybind = ctrl+v=paste_from_clipboard`n"
    if ($shell -eq 'pwsh') {
        $integration = Join-Path $RunRoot 'share\ghostty\shell-integration\powershell\integration.ps1'
        if (-not (Test-Path -LiteralPath $integration)) { throw 'Copied PowerShell integration missing.' }
        $bootstrap = Join-Path $RunRoot 'bootstrap.ps1'
        [IO.File]::WriteAllText($bootstrap, "Import-Module PSReadLine`nSet-PSReadLineOption -HistorySavePath '$RunRoot\history.txt' -HistorySaveStyle SaveNothing`n`$Global:__pkg16_prompt_sequence = 0`nfunction global:prompt { `$Global:__pkg16_prompt_sequence++; [IO.File]::WriteAllText('$RunRoot\prompt.sequence', [string]`$Global:__pkg16_prompt_sequence); 'PKG16> ' }`n. '$integration'`n[IO.File]::WriteAllText('$RunRoot\boot.ready','yes')`n")
        $configText += 'command = direct:"' + (Get-Command pwsh.exe).Source + '" -NoProfile -NoLogo -NoExit -ExecutionPolicy Bypass -File "' + $bootstrap + '"' + "`n"
    }
    else { $configText += "command = direct:cmd.exe /d /q`n" }
    [IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))
    $desktopName = [IO.File]::ReadAllText((Join-Path $RunRoot 'desktop.txt'))
    $app = Start-Hidden $runExe ('"' + $runExe + '" --config-file="' + $config + '"') $RunRoot $desktopName
    $appStart = $app.StartTime
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($hostWindow -eq [IntPtr]::Zero) {
        $hostWindow = [StaleModesNative]::Host($app.Id)
        if ($app.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'No hidden noctty host appeared.' }
        Start-Sleep -Milliseconds 50
    }
    $surface = [StaleModesNative]::Surface($hostWindow)
    if ($surface -eq [IntPtr]::Zero) { throw 'No terminal surface appeared.' }
    if ($shell -eq 'pwsh') { Wait-Marker (Join-Path $RunRoot 'boot.ready') }
    Wait-Prompt
    Assert-Enter (Join-Path $RunRoot 'initial-enter')
    Wait-Prompt
    $checks.Add('initial Enter executes shell command')
    $modeFlags = if ($Scenario -ne 'Paste') { @('31', '1-modifyOtherKeys') } else { @() }
    foreach ($flags in $modeFlags) {
        foreach ($action in @('exit', 'wait')) {
            $marker = Join-Path $RunRoot "$flags-$action"
            Invoke-Fixture $action $marker $flags
            Wait-Marker ($marker + '.ready')
            if ($action -eq 'wait') {
                if ($ExerciseParentTimeout) {
                    [IO.File]::WriteAllText((Join-Path $RunRoot 'timeout.armed'), 'yes')
                    while ($true) { Start-Sleep -Seconds 1 }
                }
                $fixturePid = [int][IO.File]::ReadAllText($marker + '.ready')
                $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$fixturePid" | Select-Object ProcessId, ParentProcessId, Name
                $ancestor = $processInfo.ParentProcessId
                for ($depth = 0; $depth -lt 8 -and $ancestor -ne $app.Id; $depth++) {
                    $parentInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" | Select-Object ProcessId, ParentProcessId
                    if (-not $parentInfo) { break }
                    $ancestor = $parentInfo.ParentProcessId
                }
                if ($processInfo.Name -ne 'mode-fixture.exe' -or $ancestor -ne $app.Id -or $app.HasExited) {
                    throw 'Mode fixture is not a verified child of this portable instance.'
                }
                $owned = Get-Process -Id $fixturePid
                Stop-Owned $owned $fixture $owned.StartTime
            }
            Wait-Prompt
            Assert-Enter ($marker + '.enter')
            Wait-Prompt
            $checks.Add("$flags ${action}: next prompt Enter executes command")
            Invoke-Fixture 'interrupt' ($marker + '.ctrl')
            Wait-Marker ($marker + '.ctrl.ready')
            [StaleModesNative]::Key($surface, 67, 3, $true)
            Wait-Marker ($marker + '.ctrl.interrupted')
            $checks.Add("$flags ${action}: Ctrl+C interrupts native command")
            Wait-Prompt
        }
    }
    if ($shell -eq 'cmd' -and $Scenario -ne 'Modes') {
        $marker = Join-Path $RunRoot 'paste'
        Invoke-Fixture 'paste' $marker
        Wait-Marker ($marker + '.ready')
        Start-Sleep -Milliseconds 200
        $one = Join-Path $RunRoot 'paste-one'; $two = Join-Path $RunRoot 'paste-two'
        # LF-only clipboard input goes through the real paste_from_clipboard
        # keybinding and bracketed writer. The fixture strips only wrappers,
        # then forwards unchanged payload to a nested, isolated cmd.
        $text = 'echo one>"' + $one + '"' + "`n" + 'echo two>"' + $two + '"' + "`nexit`n"
        [StaleModesNative]::Clipboard($hostWindow, $text)
        [StaleModesNative]::Key($surface, 86, 0, $true)
        Wait-Marker ($marker + '.done')
        Wait-Marker $one; Wait-Marker $two
        $bytes = [IO.File]::ReadAllText($marker + '.bytes')
        if ($bytes -notmatch '^1B-5B-32-30-30-7E-' -or $bytes -notmatch '-1B-5B-32-30-31-7E$' -or $bytes -match '(^|-)0A(-|$)' -or $bytes -notmatch '(^|-)0D(-|$)') {
            throw 'Bracketed paste bytes do not contain CR-only separated payload.'
        }
        $checks.Add('LF-only clipboard bracketed paste retains separate cmd commands and sends CR')
    }
    $result.status = 'PASS'
}
catch { $result.error = $_.Exception.Message }
finally {
    if ($app) {
        try {
            if (-not $app.HasExited -and $hostWindow -ne [IntPtr]::Zero) { [StaleModesNative]::Send($hostWindow, 0x10, 0, 0) }
            if (-not $app.WaitForExit(10000)) { Stop-Owned $app $runExe $appStart }
        }
        catch { $result.status = 'FAIL'; $result.error = "Cleanup: $($_.Exception.Message); earlier: $($result.error)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunRoot 'result.json')
}
if ($result.status -ne 'PASS') { exit 1 }
