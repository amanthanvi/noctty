[CmdletBinding()]
param(
    [string] $ExePath,
    [string] $RunRoot,
    [ValidateNotNullOrEmpty()] [ValidateSet('cmd', 'pwsh')] [string[]] $Shells = @('cmd', 'pwsh'),
    [ValidateSet('All', 'Modes', 'Paste', 'CtrlC')] [string] $Scenario = 'Modes',
    [ValidateSet('Enabled', 'Ignoring', 'Both')] [string] $ParentCtrlC = 'Both',
    [ValidateSet('Default', 'Bundled', 'Inbox', 'Both')] [string] $ConPty = 'Default',
    [int] $TimeoutSeconds = 30,
    [switch] $RequireMeasurementAumid,
    [string] $ExpectedStartupFingerprint,
    [string] $RuntimeReservationOwnerPath,
    [ValidatePattern('^[A-Za-z0-9_.-]+$')] [string] $BlockedRuntimeOwner,
    [switch] $ExerciseParentTimeout,
    [switch] $ExerciseInheritedCtrlCIgnore,
    [switch] $Worker
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-stale-modes.ps1'
try {


# PKG-16 runtime checks. Never launches the supplied executable in place.
# Each case owns a portable copy, redirected AppData, and a hidden desktop.
# Paste additionally requires its own windowstation: clipboard is shared
# between a station's desktops. Modes alone never access the clipboard.
# Paste targets cmd only; All runs both mode checks and the cmd paste check.
# PowerShell loads the copied integration manually so history is redirected
# before the first interactive prompt. This does not test auto-injection.
# Marker files prove commands ran; input echo alone is not an oracle.
# CtrlC is opt-in and independent of the stale-mode/paste checks. Its default
# matrix is cmd/pwsh x enabled/ignoring driver with bundled ConPTY;
# -ConPty Both adds the inbox backend. All eight results survive ordinary
# regression failures; a profile/clipboard guard failure stops the matrix.
# Supply optional campaign guard parameters when running on a shared machine.
# ExpectedStartupFingerprint is 'absent' or UTC mtime ticks:length:uppercase SHA256.
# RuntimeReservationOwnerPath must be absolute so parent and worker check the same file.
# An absent reservation directory means released; an existing one needs a nonempty owner.
# Example (with an isolated measurement build):
# .\test\windows\interactive-win11-stale-modes.ps1 -ExePath <measure-build> `
#     -RunRoot <fresh-directory> -Scenario CtrlC -ConPty Both -RequireMeasurementAumid
# The fixture never calls SetConsoleCtrlHandler: its interrupt must come from
# the shell's inherited state. CtrlC cases clear copy bindings before Ctrl+C.
# Modes/All normalize their controller with NULL,FALSE as in #477;
# -ExerciseInheritedCtrlCIgnore seeds that controller via a new process group.
# CtrlC instead applies its selected Enabled/Ignoring state, without normalization.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ExePath) { $ExePath = Join-Path $repoRoot 'zig-out\bin\koreterm.exe' }
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot ('.zig-cache\pkg16\stale-modes-' + [guid]::NewGuid().ToString('N')) }
if ($TimeoutSeconds -lt 1) { throw 'TimeoutSeconds must be positive.' }
if ($Scenario -eq 'Paste' -and $Shells -contains 'pwsh') { throw 'Paste supports cmd only; use -Shells cmd.' }
if (-not $Worker -and $Scenario -eq 'All' -and $Shells -notcontains 'cmd') { throw 'All requires cmd for its paste check; use -Shells cmd,pwsh.' }
if ($ExerciseParentTimeout -and $Scenario -ne 'Modes') { throw 'Timeout exercise requires -Scenario Modes.' }
if ($ExerciseInheritedCtrlCIgnore -and $Scenario -notin @('Modes', 'All')) { throw 'Inherited Ctrl+C exercise requires -Scenario Modes or All; use ParentCtrlC for Scenario CtrlC.' }
if ($Scenario -ne 'CtrlC' -and ($ConPty -ne 'Default' -or $ParentCtrlC -ne 'Both')) { throw 'ParentCtrlC and ConPty controls require -Scenario CtrlC.' }
if ($Worker -and $Scenario -eq 'CtrlC' -and ($ParentCtrlC -eq 'Both' -or $ConPty -notin @('Bundled', 'Inbox'))) { throw 'Worker requires one explicit parent/backend control.' }
if ([bool]$RuntimeReservationOwnerPath -ne [bool]$BlockedRuntimeOwner) { throw 'RuntimeReservationOwnerPath and BlockedRuntimeOwner must be supplied together.' }
if ($RuntimeReservationOwnerPath -and $RuntimeReservationOwnerPath -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2})') { throw 'RuntimeReservationOwnerPath must be fully qualified.' }

. (Join-Path $PSScriptRoot 'interactive-win11-hidden-desktop-lib.ps1')

function Assert-RuntimeAllowed {
    # Optional shared-machine reservation. Recheck in the worker before input
    # as well as in the parent, since an owner can change between cases.
    if (-not $RuntimeReservationOwnerPath) { return }
    # Removing the reservation directory releases it. While it exists,
    # an absent or empty owner is an acquisition in progress: fail closed.
    if (Test-Path -LiteralPath (Split-Path -Parent $RuntimeReservationOwnerPath)) {
        $ownerText = if (Test-Path -LiteralPath $RuntimeReservationOwnerPath -PathType Leaf) {
            [IO.File]::ReadAllText($RuntimeReservationOwnerPath).Trim()
        } else { '' }
        if (-not $ownerText -or ($ownerText -split '\s+')[0] -eq $BlockedRuntimeOwner) {
            throw 'Runtime deferred while the supplied desktop reservation is active or has no owner.'
        }
    }
}

function Get-AumidRegistrationFingerprint([string] $Id) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\AppUserModelId\' + $Id)
    if (-not $key) { return 'absent' }
    try {
        # Only hashes leave this function; values are never emitted as diagnostics.
        $values = @(foreach ($name in ($key.GetValueNames() | Sort-Object)) {
            $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            [ordered]@{ name = $name; kind = $key.GetValueKind($name).ToString(); value = $value }
        })
        $record = [ordered]@{ values = $values; subkeys = @($key.GetSubKeyNames() | Sort-Object) }
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $record -Depth 8 -Compress))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
        finally { $sha.Dispose() }
    }
    finally { $key.Dispose() }
}

if (-not ('StaleModesNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StaleModesNative {
    [DllImport("ntdll.dll")] static extern IntPtr RtlGetCurrentPeb();
    public static uint IgnoreFlag() {
        // Read-only test oracle: the same PEB/process-parameter prefix used
        // by Zig 0.15.2 on x64/ARM64 (and the natural 32-bit pointer layout).
        IntPtr parameters=Marshal.ReadIntPtr(RtlGetCurrentPeb(),4*IntPtr.Size);
        return unchecked((uint)Marshal.ReadInt32(parameters,16+IntPtr.Size))&1;
    }
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformationW(IntPtr obj, int index, StringBuilder text, int bytes, out int needed);
    static string ObjectName(IntPtr obj) {
        var name=new StringBuilder(256); int needed;
        if(obj==IntPtr.Zero || !GetUserObjectInformationW(obj,2,name,512,out needed)) throw new Exception("Desktop/station identity unavailable");
        return name.ToString();
    }
    public static void VerifyDesktop(string expected, IntPtr window) {
        int pid; uint thread=window==IntPtr.Zero ? GetCurrentThreadId() : GetWindowThreadProcessId(window,out pid);
        VerifyThreadDesktop(expected,thread);
    }
    public static void VerifyThreadDesktop(string expected, uint thread) {
        string actual=ObjectName(GetProcessWindowStation())+"\\"+ObjectName(GetThreadDesktop(thread));
        if(!String.Equals(actual,expected,StringComparison.OrdinalIgnoreCase)) throw new Exception("Unexpected desktop: "+actual);
    }
    public static bool VerifyShellThreadDesktop(string expected, uint thread) {
        // A console-only thread may have no win32k desktop yet. A non-NULL
        // desktop must match; the fixture also records its context in-process.
        IntPtr desktop=GetThreadDesktop(thread);
        if(desktop==IntPtr.Zero) return false;
        string leaf=expected.Substring(expected.IndexOf('\\')+1);
        if(!String.Equals(ObjectName(desktop),leaf,StringComparison.OrdinalIgnoreCase)) throw new Exception("Shell thread left the hidden desktop");
        return true;
    }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateWindowStationW(string name, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] public static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessWindowStation(IntPtr station);
    [DllImport("user32.dll")] public static extern bool CloseWindowStation(IntPtr station);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
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
    // HiddenDesktopNative.Send, for KeyInternal (a separately compiled class cannot call it).
    static void Send(IntPtr hwnd,uint msg,int value,long bits) {
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

if (-not $Worker) {
    $ExePath = (Resolve-Path -LiteralPath $ExePath).Path
    $sourceEvidence = [ordered]@{ path = $ExePath; sha256 = (Get-FileHash -LiteralPath $ExePath).Hash;
        mtimeUtc = (Get-Item -LiteralPath $ExePath).LastWriteTimeUtc.ToString('o') }
    # Identity check only; registration suppression is checked by the
    # before/after AUMID registration guard below.
    if ($RequireMeasurementAumid) {
        # Check both byte alignments: PE data need not align wide literals
        # relative to the beginning of the file. UTF-8 product namespace
        # strings also identify the default class, so they are not an AUMID oracle.
        $binaryBytes = [IO.File]::ReadAllBytes($ExePath)
        $binary = [Text.Encoding]::Unicode.GetString($binaryBytes)
        $oddBinary = if ($binaryBytes.Length -gt 1) { [Text.Encoding]::Unicode.GetString($binaryBytes, 1, $binaryBytes.Length - 1) } else { '' }
        if ((-not $binary.Contains("io.github.amanthanvi.koreterm.measure`0") -and -not $oddBinary.Contains("io.github.amanthanvi.koreterm.measure`0")) -or
            $binary.Contains("io.github.amanthanvi.koreterm`0") -or $oddBinary.Contains("io.github.amanthanvi.koreterm`0")) {
            throw 'Measurement AUMID required, with no product AUMID literal; no launch performed.'
        }
        $binary = $null; $oddBinary = $null; $binaryBytes = $null
    }
    if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be a fresh directory.' }
    $realStartup = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'koreterm\startup-attempts.json'
    $startupBefore = Get-Fingerprint $realStartup
    if ($ExpectedStartupFingerprint -and $startupBefore -ne $ExpectedStartupFingerprint) {
        throw 'Real startup-attempts.json differs from the supplied fingerprint; no launch performed.'
    }
    # Measurement builds promise to suppress registration; ordinary product
    # builds can legitimately create their display-name registration.
    $registrationIds = if ($RequireMeasurementAumid) { @('io.github.amanthanvi.koreterm', 'io.github.amanthanvi.koreterm.measure') } else { @() }
    $registrationsBefore = @{}; foreach ($id in $registrationIds) { $registrationsBefore[$id] = Get-AumidRegistrationFingerprint $id }
    # GetFolderPath deliberately ignores redirected APPDATA, as PSReadLine does.
    $historyRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $realHistories = @('Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt',
        'Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt') | ForEach-Object { Join-Path $historyRoot $_ }
    $realHistories += Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\PSReadLine\ConsoleHost_history.txt'
    $realHistories += Join-Path ([Environment]::GetFolderPath('UserProfile')) '.bash_history'
    $historyBefore = @{}; foreach ($path in $realHistories) { $historyBefore[$path] = Get-HistoryMetadata $path }
    $realDestinations = Join-Path $historyRoot 'Microsoft\Windows\Recent\CustomDestinations\c2214d6ebc43ff3f.customDestinations-ms'
    $destinationsBefore = Get-Fingerprint $realDestinations
    $clipboardBefore = [StaleModesNative]::GetClipboardSequenceNumber()
    $batchStartedUtc = [DateTime]::UtcNow.ToString('o')
    [void](New-Item -ItemType Directory -Path $RunRoot)
    $RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
    $guardOptions = [ordered]@{ requireMeasurementAumid = [bool]$RequireMeasurementAumid;
        expectedStartupFingerprint = $ExpectedStartupFingerprint;
        runtimeReservationOwnerPath = $RuntimeReservationOwnerPath; blockedRuntimeOwner = $BlockedRuntimeOwner }
    [ordered]@{ startedUtc = $batchStartedUtc; startup = $startupBefore; histories = $historyBefore;
        productCustomDestinations = $destinationsBefore; aumidRegistrations = $registrationsBefore; clipboard = $clipboardBefore; guardOptions = $guardOptions } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RunRoot 'guard-before.json')
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
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int info,out UIntPtr value,uint size,out uint returned);
    [DllImport("ntdll.dll")] static extern IntPtr RtlGetCurrentPeb();
    // Test-only read oracles. Natural pointer alignment matches x64/ARM64
    // PEB/RTL_USER_PROCESS_PARAMETERS; production never reads or mutates them.
    [StructLayout(LayoutKind.Sequential)] struct PebHeader {
        public byte inherited,options,debugged,bits;
        public IntPtr mutant,image,loader,parameters;
    }
    [StructLayout(LayoutKind.Sequential)] struct ParametersHeader {
        public uint allocation,size,flags,debug;
        public IntPtr console;
        public uint consoleFlags;
    }
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformationW(IntPtr obj,int index,StringBuilder text,int bytes,out int needed);
    static string ObjectName(IntPtr obj) {
        var text=new StringBuilder(256); int needed;
        if(!GetUserObjectInformationW(obj,2,text,512,out needed)) throw new Exception("Fixture desktop query failed");
        return text.ToString();
    }
    static void Emit(string text) { byte[] b=Encoding.ASCII.GetBytes(text); var s=Console.OpenStandardOutput(); s.Write(b,0,b.Length); s.Flush(); }
    static int Fail(string marker,int code) {
        File.WriteAllText(marker+".error.tmp",code.ToString());
        File.Move(marker+".error.tmp",marker+".error"); return code;
    }
    static int Main(string[] a) {
        string action=a[0], marker=a[1]; uint output;
        if(GetConsoleMode(GetStdHandle(-11),out output)) SetConsoleMode(GetStdHandle(-11),output|4);
        if(action=="interrupt") {
            try {
                // Registering a handler does NOT reset the inherited ignore bit.
                // Never call SetConsoleCtrlHandler(NULL,FALSE) in this fixture.
                Console.CancelKeyPress+=(s,e)=> { File.WriteAllText(marker+".interrupted","yes"); Environment.Exit(0); };
                uint input;
                if(!GetConsoleMode(GetStdHandle(-10),out input)) return Fail(marker,14);
                File.WriteAllText(marker+".input-mode",input.ToString());
                File.WriteAllText(marker+".desktop",ObjectName(GetProcessWindowStation())+"\\"+ObjectName(GetThreadDesktop(GetCurrentThreadId())));
                // ProcessConsoleHostProcess (49) returns the actual console server,
                // with low flag bits. GetConsoleWindow's owner can masquerade as
                // the root client and DLL presence does not rule out fallback.
                UIntPtr server; uint returned;
                if(NtQueryInformationProcess(new IntPtr(-1),49,out server,(uint)UIntPtr.Size,out returned)<0 || returned!=(uint)UIntPtr.Size) return Fail(marker,15);
                int hostPid=checked((int)(server.ToUInt64()&~3UL));
                if(hostPid==0) return Fail(marker,16);
                File.WriteAllText(marker+".host-pid",hostPid.ToString());
                using(var host=Process.GetProcessById(hostPid)) File.WriteAllText(marker+".host-image",host.MainModule.FileName);
                var peb=(PebHeader)Marshal.PtrToStructure(RtlGetCurrentPeb(),typeof(PebHeader));
                var parameters=(ParametersHeader)Marshal.PtrToStructure(peb.parameters,typeof(ParametersHeader));
                File.WriteAllText(marker+".ignore",(parameters.consoleFlags&1).ToString());
                File.WriteAllText(marker+".ready.tmp",Process.GetCurrentProcess().Id.ToString());
                File.Move(marker+".ready.tmp",marker+".ready");
            } catch(Exception) { return Fail(marker,17); }
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
    $sourcePath = Join-Path $RunRoot 'mode-fixture.cs'
    [IO.File]::WriteAllText($sourcePath, $fixtureSource)
    $cases = @()
    foreach ($shell in $Shells) {
        if ($Scenario -eq 'CtrlC') {
            $parents = if ($ParentCtrlC -eq 'Both') { @('Enabled', 'Ignoring') } else { @($ParentCtrlC) }
            $backends = if ($ConPty -eq 'Both') { @('Bundled', 'Inbox') } elseif ($ConPty -eq 'Default') { @('Bundled') } else { @($ConPty) }
            foreach ($backend in $backends) {
                foreach ($control in $parents) { $cases += [pscustomobject]@{ shell = $shell; parent = $control; backend = $backend; name = "$shell-$backend-$control" } }
            }
        }
        else { $cases += [pscustomobject]@{ shell = $shell; parent = 'Both'; backend = 'Default'; name = $shell } }
    }
    $allResults = @()
    try {
        foreach ($case in $cases) {
            Assert-RuntimeAllowed
            $shell = $case.shell
            $caseRoot = Join-Path $RunRoot $case.name
            [void](New-Item -ItemType Directory -Path $caseRoot)
            Copy-Item -LiteralPath $ExePath -Destination (Join-Path $caseRoot 'koreterm.exe')
            if ((Get-FileHash -LiteralPath (Join-Path $caseRoot 'koreterm.exe')).Hash -ne $sourceEvidence.sha256) { throw 'Supplied executable changed while staging the matrix.' }
            foreach ($name in @('conpty.dll', 'OpenConsole.exe')) {
                $path = Join-Path (Split-Path -Parent $ExePath) $name
                if ($case.backend -eq 'Bundled' -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Bundled control requires $name beside the supplied build." }
                if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $caseRoot }
            }
            # Keep built resources/fonts and integration matched to this executable.
            $share = Join-Path (Split-Path -Parent (Split-Path -Parent $ExePath)) 'share'
            if (-not (Test-Path -LiteralPath $share)) { throw "Build share directory absent: $share" }
            Copy-Item -LiteralPath $share -Destination (Join-Path $caseRoot 'share') -Recurse
            [IO.File]::WriteAllText((Join-Path $caseRoot 'koreterm.portable'), '')
            Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $caseRoot 'mode-fixture.cs')
            [void](New-Item -ItemType Directory -Path (Join-Path $caseRoot 'local'), (Join-Path $caseRoot 'roaming'))
            $uniqueName = 'koreterm-stale-' + [guid]::NewGuid().ToString('N')
            $needsClipboard = $Scenario -in @('All', 'Paste')
            $stationName = if ($needsClipboard) { $uniqueName } else { 'WinSta0' }
            $desktopLeaf = if ($needsClipboard) { 'hidden' } else { $uniqueName }
            $station = [IntPtr]::Zero
            if ($needsClipboard) {
                $station = [StaleModesNative]::CreateWindowStationW($stationName, 0, 0x10000000, [IntPtr]::Zero)
                if ($station -eq [IntPtr]::Zero) { throw "Private paste windowstation unavailable (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())); run -Scenario Modes for checks without clipboard access." }
            }
            $originalStation = [StaleModesNative]::GetProcessWindowStation()
            $desktop = [IntPtr]::Zero
            try {
                if ($station -ne [IntPtr]::Zero -and -not [StaleModesNative]::SetProcessWindowStation($station)) { throw 'SetProcessWindowStation failed.' }
                $desktop = [HiddenDesktopNative]::CreateDesktopW($desktopLeaf, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
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
            $ownerJob = [HiddenDesktopNative]::CreateJobObjectW([IntPtr]::Zero, [NullString]::Value)
            if ($ownerJob -eq [IntPtr]::Zero) { throw 'Creating owned driver job failed.' }
            $timedOut = $false
            try {
                $pwsh = (Get-Command pwsh.exe).Source
                $command = '"{0}" -NoProfile -NonInteractive -File "{1}" -Worker -RunRoot "{2}" -Shells {3} -TimeoutSeconds {4} -Scenario {5}' -f $pwsh, $PSCommandPath, $caseRoot, $shell, $TimeoutSeconds, $Scenario
                $command += ' -ParentCtrlC {0} -ConPty {1}' -f $case.parent, $case.backend
                if ($RuntimeReservationOwnerPath) { $command += ' -RuntimeReservationOwnerPath "{0}" -BlockedRuntimeOwner {1}' -f $RuntimeReservationOwnerPath, $BlockedRuntimeOwner }
                if ($ExerciseParentTimeout) { $command += ' -ExerciseParentTimeout' }
                if ($ExerciseInheritedCtrlCIgnore) { $command += ' -ExerciseInheritedCtrlCIgnore' }
                $driverEnvironment = @{ LOCALAPPDATA = Join-Path $caseRoot 'local'; APPDATA = Join-Path $caseRoot 'roaming';
                    GHOSTTY_RESOURCES_DIR = Join-Path $caseRoot 'share\ghostty' }
                $driver = Start-Hidden $pwsh $command $caseRoot $deskName $ownerJob -EnvironmentOverrides $driverEnvironment -NewProcessGroup:$ExerciseInheritedCtrlCIgnore
                $started = $driver.StartTime
                $driverHandle = [HiddenDesktopNative]::OpenProcess(0x00101000, $false, $driver.Id)
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
                if (-not [HiddenDesktopNative]::GetExitCodeProcess($driverHandle, [ref]$driverExit)) { throw 'GetExitCodeProcess failed.' }
                if ($driverExit -ne 0 -or $result.status -ne 'PASS') {
                    if ($Scenario -ne 'CtrlC') { throw "Hidden $shell checks failed (exit $driverExit): $($result.error)" }
                    # Keep the whole focused matrix, including the expected
                    # failing ignoring-parent cases on main, for the lead's A/B.
                    $result.status = 'FAIL'
                }
            }
            finally {
                try {
                    $stopped = $null; $remainingPids = $null
                    $reapFailure = $null; $queryFailure = $null
                    try { $stopped = @([HiddenDesktopNative]::ReapOwnedJob($ownerJob)) }
                    catch { $reapFailure = $_ }
                    try { $remainingPids = @([HiddenDesktopNative]::JobPids($ownerJob)) }
                    catch { $queryFailure = $_ }
                    [pscustomobject]@{ timedOut = $timedOut; terminatedPids = $stopped; remainingPids = $remainingPids;
                        reapError = $(if ($reapFailure) { $reapFailure.Exception.Message } else { $null });
                        queryError = $(if ($queryFailure) { $queryFailure.Exception.Message } else { $null }) } |
                        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $caseRoot 'cleanup.json')
                    if ($queryFailure) { throw $queryFailure }
                    if ($remainingPids.Count -ne 0) { throw 'Owned job is not empty after cleanup.' }
                    if ($reapFailure) { throw $reapFailure }
                }
                finally {
                    [void][HiddenDesktopNative]::CloseHandle($ownerJob)
                    if ($driverHandle -ne [IntPtr]::Zero) { [void][HiddenDesktopNative]::CloseHandle($driverHandle) }
                    [void][HiddenDesktopNative]::CloseDesktop($desktop)
                    if ($station -ne [IntPtr]::Zero) { [void][StaleModesNative]::CloseWindowStation($station) }
                    if ((Get-Fingerprint $realStartup) -ne $startupBefore) { throw 'Real startup-attempts.json changed.' }
                    foreach ($path in $realHistories) { if ((Get-HistoryMetadata $path) -ne $historyBefore[$path]) { throw 'Real PSReadLine history changed.' } }
                    if ((Get-Fingerprint $realDestinations) -ne $destinationsBefore) { throw 'Real product CustomDestinations changed.' }
                    foreach ($id in $registrationIds) { if ((Get-AumidRegistrationFingerprint $id) -ne $registrationsBefore[$id]) { throw 'AUMID registration changed.' } }
                    if ([StaleModesNative]::GetClipboardSequenceNumber() -ne $clipboardBefore) { throw 'Clipboard sequence changed; stop launches and report batch times.' }
                }
            }
        }
    }
    finally {
        $clipboardAfter = [StaleModesNative]::GetClipboardSequenceNumber()
        $guards = [ordered]@{ startedUtc = $batchStartedUtc; endedUtc = [DateTime]::UtcNow.ToString('o');
            startupBefore = $startupBefore; startupAfter = Get-Fingerprint $realStartup;
            productCustomDestinationsBefore = $destinationsBefore; productCustomDestinationsAfter = Get-Fingerprint $realDestinations;
            clipboardBefore = $clipboardBefore; clipboardAfter = $clipboardAfter;
            historiesBefore = $historyBefore; historiesAfter = @{};
            aumidRegistrationsBefore = $registrationsBefore; aumidRegistrationsAfter = @{} }
        foreach ($path in $realHistories) { $guards.historiesAfter[$path] = Get-HistoryMetadata $path }
        foreach ($id in $registrationIds) { $guards.aumidRegistrationsAfter[$id] = Get-AumidRegistrationFingerprint $id }
        $guards | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RunRoot 'guard-after.json')
        [pscustomobject]@{ source = $sourceEvidence; scenario = $Scenario; inheritedCtrlCIgnore = [bool]$ExerciseInheritedCtrlCIgnore; results = $allResults; guards = $guards; guardOptions = $guardOptions;
            historyUnchanged = (@($realHistories | Where-Object { (Get-HistoryMetadata $_) -ne $historyBefore[$_] }).Count -eq 0) } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunRoot 'summary.json')
        if ($guards.startupAfter -ne $startupBefore -or $guards.productCustomDestinationsAfter -ne $destinationsBefore -or
            $clipboardAfter -ne $clipboardBefore -or @($realHistories | Where-Object { $guards.historiesAfter[$_] -ne $historyBefore[$_] }).Count -ne 0) {
            throw 'Real-profile/clipboard guard changed; stop launches and report guard-before.json and guard-after.json.'
        }
        foreach ($id in $registrationIds) { if ($guards.aumidRegistrationsAfter[$id] -ne $registrationsBefore[$id]) { throw 'AUMID registration guard changed; stop launches.' } }
    }
    if (@($allResults | Where-Object status -ne 'PASS').Count -ne 0) { throw "CtrlC regression matrix failed; evidence=$RunRoot" }
    Write-Host "stale modes: PASS; evidence=$RunRoot; real startup and history unchanged"
    return
}

# This branch runs inside the hidden desktop. All state lives beside the copy.
$env:LOCALAPPDATA = Join-Path $RunRoot 'local'
$env:APPDATA = Join-Path $RunRoot 'roaming'
$env:GHOSTTY_RESOURCES_DIR = Join-Path $RunRoot 'share\ghostty'
$shell = $Shells[0]
$fixture = Join-Path $RunRoot 'mode-fixture.exe'
$runExe = Join-Path $RunRoot 'koreterm.exe'
$checks = [Collections.Generic.List[string]]::new()
$result = [ordered]@{ shell = $shell; scenario = $Scenario; parentCtrlC = $ParentCtrlC; conPty = $ConPty;
    inheritedCtrlCIgnore = [bool]$ExerciseInheritedCtrlCIgnore; controllerNormalized = $false;
    ignoreRequested = $null; ignoreApplied = $false; controlCallSucceeded = $false;
    backendObserved = $null; desktopVerified = $false; shellDesktopVerified = $false; fixture = $null;
    status = 'FAIL'; checks = $checks; error = $null }
$app = $null
$hostWindow = [IntPtr]::Zero

function Wait-Marker([string] $Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($Path.EndsWith('.ready', [StringComparison]::OrdinalIgnoreCase)) {
            $errorPath = $Path.Substring(0, $Path.Length - 6) + '.error'
            if (Test-Path -LiteralPath $errorPath) {
                $fixtureError = [int][IO.File]::ReadAllText($errorPath)
                throw "Fixture setup failed with code $fixtureError."
            }
        }
        if ($app.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for marker $([IO.Path]::GetFileName($Path))" }
        Start-Sleep -Milliseconds 50
    }
}
function Type-Command([string] $Text) {
    Assert-RuntimeAllowed
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
function Assert-FixtureContext([string] $Marker) {
    # Read only the fixture PID and desktop/mode markers, never command lines.
    $fixturePid = [int][IO.File]::ReadAllText($Marker + '.ready')
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$fixturePid" | Select-Object ProcessId, ParentProcessId, Name
    if (-not $processInfo) { throw 'Interrupt fixture exited before Ctrl+C.' }
    $ancestor = $processInfo.ParentProcessId
    for ($depth = 0; $depth -lt 8 -and $ancestor -ne $app.Id; $depth++) {
        $parentInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" | Select-Object ProcessId, ParentProcessId
        if (-not $parentInfo) { break }
        $ancestor = $parentInfo.ParentProcessId
    }
    $actualDesktop = [IO.File]::ReadAllText($Marker + '.desktop')
    $inputMode = [uint32][IO.File]::ReadAllText($Marker + '.input-mode')
    $consoleHostPid = [int][IO.File]::ReadAllText($Marker + '.host-pid')
    $consoleHostImage = [IO.File]::ReadAllText($Marker + '.host-image')
    $inheritedIgnore = [uint32][IO.File]::ReadAllText($Marker + '.ignore')
    $expectedHost = if ($ConPty -eq 'Bundled') { Join-Path $RunRoot 'OpenConsole.exe' } else { Join-Path $env:WINDIR 'System32\conhost.exe' }
    $result.fixture = [ordered]@{ pid = $fixturePid; desktop = $actualDesktop; inputMode = $inputMode;
        consoleHostPid = $consoleHostPid; consoleHostImage = $consoleHostImage;
        inheritedIgnore = $inheritedIgnore; hostOracle = 'ProcessConsoleHostProcess';
        interruptObserved = $false; ignoreResetInFixture = $false }
    if ($consoleHostImage -ne $expectedHost -or (Get-Process -Id $consoleHostPid).Path -ne $consoleHostImage) {
        throw 'Console server does not belong to the requested backend executable.'
    }
    $result.backendObserved = $ConPty
    if ($processInfo.Name -ne 'mode-fixture.exe' -or $ancestor -ne $app.Id -or $app.HasExited -or
        (Get-Process -Id $fixturePid).Path -ne $fixture) { throw 'Interrupt fixture is not an owned descendant of this portable instance.' }
    if ($actualDesktop -ne $desktopName) { throw "Interrupt fixture escaped its explicit desktop: $actualDesktop" }
    if (($inputMode -band 1) -eq 0) { throw 'Interrupt fixture lacks ENABLE_PROCESSED_INPUT; Ctrl+C would not test inherited ignore.' }
}
function Assert-ShellDesktop {
    # Verify the console shell before the first keystroke. No title or raw
    # command-line inspection; walk only this app's child identities.
    $expectedName = if ($shell -eq 'cmd') { 'cmd.exe' } else { 'pwsh.exe' }
    $expectedPath = if ($shell -eq 'cmd') { Join-Path $env:WINDIR 'System32\cmd.exe' } else { (Get-Command pwsh.exe).Source }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not $app.HasExited) {
        $pending = @($app.Id)
        for ($depth = 0; $depth -lt 8 -and $pending.Count -ne 0; $depth++) {
            $next = @()
            foreach ($parentPid in $pending) {
                $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentPid" -Property ProcessId, ParentProcessId, Name)
                foreach ($child in $children) {
                    if ($child.Name -eq $expectedName) {
                        $ownedShell = Get-Process -Id $child.ProcessId
                        if ($ownedShell.Path -ne $expectedPath) { throw 'Unexpected shell executable in owned tree.' }
                        $matchedThreads = 0
                        foreach ($thread in $ownedShell.Threads) {
                            if ([StaleModesNative]::VerifyShellThreadDesktop($desktopName, [uint32]$thread.Id)) { $matchedThreads++ }
                        }
                        # A console-only cmd thread may never acquire win32k
                        # state. Preserve that limit; the fixture later makes
                        # an in-process station/desktop check before Ctrl+C.
                        $result.shellDesktopVerified = if ($matchedThreads) { 'matched' } else { 'unavailable' }
                        return
                    }
                    $next += [int]$child.ProcessId
                }
            }
            $pending = $next
        }
        Start-Sleep -Milliseconds 50
    }
    throw 'No owned console shell appeared for desktop verification.'
}
$script:PromptSequence = 0
try {
    $desktopName = [IO.File]::ReadAllText((Join-Path $RunRoot 'desktop.txt'))
    [StaleModesNative]::VerifyDesktop($desktopName, [IntPtr]::Zero)
    if (-not (Test-Path -LiteralPath (Join-Path $RunRoot 'koreterm.portable') -PathType Leaf)) { throw 'Portable marker missing.' }
    # csc is a console helper too. It runs on the driver's explicit desktop,
    # CREATE_NO_WINDOW and BELOW_NORMAL_PRIORITY_CLASS, inside the owned job.
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $sourcePath = Join-Path $RunRoot 'mode-fixture.cs'
    $compilerLog = Join-Path $RunRoot 'compile.log'
    $compilerCommand = '"{0}" /nologo /target:exe /out:"{1}" "{2}"' -f $compiler, $fixture, $sourcePath
    $compilerExit = Start-Hidden $compiler $compilerCommand $RunRoot $desktopName -LogPath $compilerLog
    if ($compilerExit -ne 0 -or -not (Test-Path -LiteralPath $fixture -PathType Leaf)) {
        throw "Console fixture compilation failed (exit $compilerExit); see $compilerLog"
    }
    $config = Join-Path $RunRoot 'config.ghostty'
    $configText = "auto-update = off`nconfirm-close-surface = false`nwindow-save-state = never`nsingle-instance = false`nclipboard-paste-protection = false`nkeybind = ctrl+v=paste_from_clipboard`n"
    $instanceClass = 'koreterm-test-ctrlc-' + [guid]::NewGuid().ToString('N')
    $configText += "class = $instanceClass`n"
    if ($Scenario -eq 'CtrlC') {
        # No selection/copy branch exists for this key, including on main.
        # A fresh surface receives no mouse/selection actions. Clear bindings
        # to exclude clipboard actions while retaining normal key encoding,
        # including ConPTY's win32-input-mode records when negotiated.
        $configText += 'copy-on-select = false' + "`n" + 'keybind = clear' + "`n"
        if ($ConPty -eq 'Inbox') { $env:KORETERM_CONPTY = 'inbox' }
        else { Remove-Item Env:\KORETERM_CONPTY -ErrorAction SilentlyContinue }
    }
    if ($shell -eq 'pwsh') {
        $integration = Join-Path $RunRoot 'share\ghostty\shell-integration\powershell\integration.ps1'
        if (-not (Test-Path -LiteralPath $integration)) { throw 'Copied PowerShell integration missing.' }
        $bootstrap = Join-Path $RunRoot 'bootstrap.ps1'
        [IO.File]::WriteAllText($bootstrap, "try {`nImport-Module PSReadLine -ErrorAction Stop`nSet-PSReadLineOption -HistorySavePath '$RunRoot\history.txt' -HistorySaveStyle SaveNothing -ErrorAction Stop`nif ((Get-PSReadLineOption).HistorySavePath -cne '$RunRoot\history.txt' -or (Get-PSReadLineOption).HistorySaveStyle -ne 'SaveNothing') { exit 1 }`n} catch { exit 1 }`n`$Global:__pkg16_prompt_sequence = 0`nfunction global:prompt { `$Global:__pkg16_prompt_sequence++; [IO.File]::WriteAllText('$RunRoot\prompt.sequence', [string]`$Global:__pkg16_prompt_sequence); 'PKG16> ' }`n. '$integration'`n[IO.File]::WriteAllText('$RunRoot\boot.ready','yes')`n")
        $configText += 'command = direct:"' + (Get-Command pwsh.exe).Source + '" -NoProfile -NoLogo -NoExit -ExecutionPolicy Bypass -File "' + $bootstrap + '"' + "`n"
    }
    else { $configText += "command = direct:cmd.exe /d /q`n" }
    [IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))
    Assert-RuntimeAllowed
    if ($Scenario -eq 'CtrlC') {
        $ignore = $ParentCtrlC -eq 'Ignoring'
        $result.ignoreRequested = $ignore
        # Set the driver's bit immediately before creating koreterm. Setting a
        # managed CancelKeyPress handler here would not provide this control.
        $result.controlCallSucceeded = [StaleModesNative]::SetConsoleCtrlHandler([IntPtr]::Zero, $ignore)
        if (-not $result.controlCallSucceeded) { throw "Driver SetConsoleCtrlHandler failed (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
        $result.ignoreApplied = [bool][StaleModesNative]::IgnoreFlag()
        if ($result.ignoreApplied -ne $ignore) { throw 'Driver ignore state does not match its requested control.' }
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunRoot 'launch-control.json')
    }
    elseif ($Scenario -in @('Modes', 'All')) {
        # #477: start /b or CREATE_NEW_PROCESS_GROUP may seed this driver
        # with an inherited ignore bit. Normalize only Modes/All, leaving
        # the focused CtrlC matrix's explicit Ignoring selection intact.
        $result.ignoreRequested = $false
        $result.controlCallSucceeded = [StaleModesNative]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
        if (-not $result.controlCallSucceeded) { throw "Enabling controller Ctrl+C failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        $result.controllerNormalized = $true
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunRoot 'launch-control.json')
    }
    $app = Start-Hidden $runExe ('"' + $runExe + '" --config-file="' + $config + '" --single-instance=false --class=' + $instanceClass) $RunRoot $desktopName
    $appStart = $app.StartTime
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($hostWindow -eq [IntPtr]::Zero) {
        $hostWindow = [HiddenDesktopNative]::Host($app.Id)
        if ($app.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'No hidden koreterm host appeared.' }
        Start-Sleep -Milliseconds 50
    }
    $surface = [HiddenDesktopNative]::Surface($hostWindow)
    if ($surface -eq [IntPtr]::Zero) { throw 'No terminal surface appeared.' }
    [StaleModesNative]::VerifyDesktop($desktopName, $hostWindow)
    [StaleModesNative]::VerifyDesktop($desktopName, $surface)
    $result.desktopVerified = $true
    if ($shell -eq 'pwsh') { Wait-Marker (Join-Path $RunRoot 'boot.ready') }
    if ($Scenario -eq 'CtrlC') { Assert-ShellDesktop }
    Wait-Prompt
    Assert-Enter (Join-Path $RunRoot 'initial-enter')
    Wait-Prompt
    $checks.Add('initial Enter executes shell command')
    if ($Scenario -eq 'CtrlC') {
        # The fixture queries its actual console server to identify the backend.
        # DLL presence alone also survives a bundled-to-inbox fallback.
        $marker = Join-Path $RunRoot 'focused-ctrl'
        Invoke-Fixture 'interrupt' $marker
        Wait-Marker ($marker + '.ready')
        Assert-FixtureContext $marker
        Assert-RuntimeAllowed
        [StaleModesNative]::VerifyDesktop($desktopName, $surface)
        [StaleModesNative]::Key($surface, 67, 3, $true)
        Wait-Marker ($marker + '.interrupted')
        $result.fixture.interruptObserved = $true
        $checks.Add("$ParentCtrlC parent / $ConPty / ${shell}: Console.CancelKeyPress observed Ctrl+C")
        Wait-Prompt
        Assert-Enter (Join-Path $RunRoot 'after-ctrl-enter')
        Wait-Prompt
        $checks.Add('shell survives native interrupt and executes the next command')
    }
    $modeFlags = if ($Scenario -in @('All', 'Modes')) { @('31', '1-modifyOtherKeys') } else { @() }
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
    if ($shell -eq 'cmd' -and $Scenario -in @('All', 'Paste')) {
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
            if (-not $app.HasExited -and $hostWindow -ne [IntPtr]::Zero) { [HiddenDesktopNative]::Send($hostWindow, 0x10, 0, 0) }
            if (-not $app.WaitForExit(10000)) { Stop-Owned $app $runExe $appStart }
        }
        catch { $result.status = 'FAIL'; $result.error = "Cleanup: $($_.Exception.Message); earlier: $($result.error)" }
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunRoot 'result.json')
}
if ($result.status -ne 'PASS') { exit 1 }

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
