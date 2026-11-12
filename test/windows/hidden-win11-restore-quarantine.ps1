#requires -Version 7.0
<#
Portable, hidden-desktop regression for the startup recovery ledger and a saved
session that keeps ending the process while it is restored (PKG-45). Run with
-Bin <Debug build bin directory> -Run <new evidence directory> -Label fixed for
a build with the fix, or -Label main for one without (the label picks which
behaviour the checks expect). The build must
be a Debug build: its KORETERM_DEBUG_CRASH_SESSION_RESTORE hook ends the process
with ExitProcess(3) after restore begins. Release builds have no such hook.

Every file the app reads or writes is one this script creates beside a portable
copy (`koreterm.portable`), with LOCALAPPDATA and APPDATA redirected into the run
directory: the real %LOCALAPPDATA%\koreterm is never written or deleted, and only
the hash and time of its startup state file are read, before and after. Every
process starts on a private desktop named explicitly in STARTUPINFO, inside a
job this script owns. Nothing is typed and nothing can copy; the clipboard
sequence number is logged before and after and a change fails the run. Launch a
build patched with a measurement AUMID only. -MeasureJumpListName names that
AUMID's jump-list file (`<hash>.customDestinations-ms`); the script deletes that
one file, and only when it did not exist before the run and was written during
it. Any other file that appears there is reported, never deleted.

Per build, five launches with the hook set: three that die restoring, the
safe-mode launch the ledger then selects, and one more; then a sixth without
it, which restores whatever session is left. Results hold exit codes,
the ledger's attempts, the session files' hashes, the safe-mode notice text and
assertions. Exits 1 when a check fails, so it can be run against a build that
still loops.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [Parameter(Mandatory)] [ValidateSet('main','fixed')] [string] $Label,
    [switch] $Driver,
    [string] $Desktop,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 600,
    [ValidatePattern('^[0-9a-f]{16}\.customDestinations-ms$')] [string] $MeasureJumpListName,
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
public static class Rq {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int p);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref Startup si,out ProcessInfo pi);
    [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    static string Class(IntPtr h) { var s=new StringBuilder(128); GetClassNameW(h,s,128); return s.ToString(); }
    public static IntPtr[] Windows(int pid,string cls) {
        var list=new List<IntPtr>(); EnumWindows((h,p)=> { int id; GetWindowThreadProcessId(h,out id);
            if(id==pid && Class(h)==cls) list.Add(h); return true;
        },IntPtr.Zero); return list.ToArray();
    }
    // A MessageBox keeps its text in the static control with ID 0xFFFF.
    public static string MessageText(IntPtr box) {
        var item=GetDlgItem(box,0xFFFF); if(item==IntPtr.Zero) return null;
        var s=new StringBuilder(2048); GetWindowTextW(item,s,2048); return s.ToString();
    }
    public static string Title(IntPtr h) { var s=new StringBuilder(256); GetWindowTextW(h,s,256); return s.ToString(); }
    // Children are created suspended, assigned to the job when one is given,
    // and always placed on the named desktop.
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        uint flags=0x00000004|(job!=IntPtr.Zero?0x08000000u:0u)|0x00000400u; // SUSPENDED, NO_WINDOW for the driver, UNICODE_ENVIRONMENT
        if(!CreateProcessW(app,new StringBuilder(command),IntPtr.Zero,IntPtr.Zero,false,flags,IntPtr.Zero,cwd,ref si,out pi))
            throw new Exception("CreateProcess failed: "+Marshal.GetLastWin32Error());
        if((job!=IntPtr.Zero && !AssignProcessToJobObject(job,pi.process))||ResumeThread(pi.thread)==0xFFFFFFFF) {
            TerminateProcess(pi.process,1); CloseHandle(pi.thread); CloseHandle(pi.process);
            throw new Exception("Assign/resume failed");
        }
        return pi;
    }
}
'@

if (-not $Driver) {
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    $source = (Resolve-Path -LiteralPath $Bin).Path
    if (-not (Test-Path -LiteralPath (Join-Path $source 'koreterm.exe'))) { throw "No koreterm.exe in $source." }
    $before = Startup-Fingerprint
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-restore-quarantine.ps1'
    $clipboardBefore = [HiddenLocal]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    $jumpBefore = @(Jump-List-Files | ForEach-Object { $_.Path })
    $batchStart = [DateTimeOffset]::UtcNow
    Write-Host "Clipboard sequence before: $clipboardBefore"
    [void](New-Item -ItemType Directory -Path $Run)
    $copy = Join-Path $Run 'case\bin'
    Copy-Portable $source $copy
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'koreterm-rq-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero; $code=1
    try {
        $job=[HiddenLocal]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -Label {4} -Desktop "{5}" -Driver' -f $pwsh,$PSCommandPath,$copy,$Run,$Label,"WinSta0\$desktopName"
        $pi=[Rq]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job)
        Write-Host "Hidden driver PID=$($pi.pid); evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([HiddenLocal]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned process job will be closed." }
        }
        [uint32]$exit=0; [void][HiddenLocal]::GetExitCodeProcess($pi.process,[ref]$exit); $code=$exit
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[HiddenLocal]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Rq]::CloseHandle($pi.thread); [void][Rq]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
        $batchEnd = [DateTimeOffset]::UtcNow
        # Only the measurement AUMID's file, and only if this batch created it:
        # absent before and written during it. Not its creation time: NTFS
        # tunnelling gives a file recreated under a name deleted less than 15 s
        # earlier the old file's creation time.
        $removed = @(); $otherNew = @()
        foreach ($f in Jump-List-Files) {
            if ($jumpBefore -contains $f.Path -or $f.Written -lt $batchStart -or $f.Written -gt $batchEnd) { continue }
            if ($MeasureJumpListName -and (Split-Path -Leaf $f.Path) -eq $MeasureJumpListName) {
                Remove-Item -LiteralPath $f.Path; $removed += $MeasureJumpListName
            } else { $otherNew += (Split-Path -Leaf $f.Path) }
        }
        $after=Startup-Fingerprint
        $clipboardAfter=[HiddenLocal]::GetClipboardSequenceNumber()
        Write-Host "Clipboard sequence after: $clipboardAfter"
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $historyFailure=$null
        try { Assert-WindowsHarnessHistoryGuard -Guard $historyGuard } catch { $historyFailure=$_ }
        @{ Before=$before; After=$after; Unchanged=$unchanged; HistoryUnchanged=($null -eq $historyFailure); OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount; ClipboardSequenceBefore=$clipboardBefore; ClipboardSequenceAfter=$clipboardAfter; JumpListFilesRemoved=$removed; OtherNewJumpListFiles=$otherNew; BatchStartUtc=$batchStart.ToString('o'); BatchEndUtc=$batchEnd.ToString('o') } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'startup-state.json')
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if ($clipboardBefore -ne $clipboardAfter) { throw "Clipboard sequence number changed ($clipboardBefore -> $clipboardAfter); stop launches and report it." }
        if ($historyFailure) { throw $historyFailure }
        if($cleanupError) { throw $cleanupError }
    }
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect sanitized results in $Run." }
    Write-Host 'Hidden restore quarantine: PASS'
    exit
}

# Driver: runs only on the private desktop, inside the owned job.
$script:checks=[Collections.Generic.List[object]]::new()
$script:launches=[Collections.Generic.List[object]]::new()
function Check([string]$Build,[string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Build=$Build; Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
function Ledger([string]$Dir) {
    $path = Join-Path $Dir 'startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    # The app may hold or be replacing the file; read again a moment later.
    for ($try = 0; $try -lt 20; $try++) {
        try { return @((Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).attempts) }
        catch { Start-Sleep -Milliseconds 50 }
    }
    throw "Ledger stayed unreadable: $path"
}
function Launch-Once([string]$Build,[string]$Dir,[int]$Index) {
    $exe = Join-Path $Dir 'koreterm.exe'
    $class = "koreterm-test-pkg45-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $line = '"{0}" --config-file="{1}" --single-instance=false --class={2}' -f $exe,(Join-Path $Dir 'quarantine.ghostty'),$class
    $pi = [Rq]::Launch($exe,$line,$Dir,$Desktop,[IntPtr]::Zero)
    $record = @{ Build=$Build; Launch=$Index; Pid=$pi.pid; ExitCode=$null; HostWindow=$false; Notice=$null }
    try {
        $deadline=[datetime]::UtcNow.AddSeconds(25)
        while ([datetime]::UtcNow -lt $deadline) {
            if ([HiddenLocal]::WaitForSingleObject($pi.process,100) -eq 0) { break }
            $hosts = @([Rq]::Windows($pi.pid,'koreterm.win32.host'))
            $attempts = @(Ledger $Dir)
            $ready = $attempts.Count -gt 0 -and $null -ne $attempts[-1].ready_at_unix_ms
            if ($hosts.Count -gt 0 -and $ready) {
                $record.HostWindow = $true
                # The safe-mode notice is released only after the ready marker.
                $noticeDeadline=[datetime]::UtcNow.AddSeconds(4)
                do {
                    foreach ($box in [Rq]::Windows($pi.pid,'#32770')) {
                        if ([Rq]::Title($box) -eq 'koreterm safe mode') { $record.Notice = [Rq]::MessageText($box) }
                    }
                    if ($record.Notice) { break }
                    Start-Sleep -Milliseconds 100
                } while ([datetime]::UtcNow -lt $noticeDeadline)
                break
            }
        }
        if ([HiddenLocal]::WaitForSingleObject($pi.process,0) -ne 0) {
            foreach ($h in [Rq]::Windows($pi.pid,'koreterm.win32.host')) { [void][Rq]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
            if ([HiddenLocal]::WaitForSingleObject($pi.process,8000) -ne 0) {
                # Our own handle from CreateProcess: the exact process we started.
                [void][Rq]::TerminateProcess($pi.process,1); [void][HiddenLocal]::WaitForSingleObject($pi.process,5000)
                $record.Terminated = $true
            }
        } else {
            [uint32]$exit=0; [void][HiddenLocal]::GetExitCodeProcess($pi.process,[ref]$exit); $record.ExitCode = $exit
        }
    } finally { [void][Rq]::CloseHandle($pi.thread); [void][Rq]::CloseHandle($pi.process) }
    $attempts = @(Ledger $Dir)
    $record.Attempts = @($attempts | ForEach-Object { @{ started=$_.started_at_unix_ms; ready=$_.ready_at_unix_ms; phase=$_.phase; restore=$_.session_restore_at_unix_ms; version=$_.version } })
    $record.SessionHash = Hash-Of (Join-Path $Dir 'session-state.json')
    $record.SetAside = @(Get-ChildItem -LiteralPath $Dir -Filter 'session-state.json.restore-failed*' -File | ForEach-Object { @{ Name=$_.Name; Hash=(Hash-Of $_.FullName) } })
    $script:launches.Add($record)
    return $record
}

try {
    foreach ($label in @($Label)) {
        $dir = $Bin
        # A sample session written by this script: one window, one tab, one pane.
        $session = @{ schema_version=1; windows=@(@{ selected_tab=0; tabs=@(@{ selected_leaf=0; layout=@{ root=0; nodes=@(@{ pane=@{ cwd=$dir } }) } }) }) } | ConvertTo-Json -Depth 12 -Compress
        Set-Content -LiteralPath (Join-Path $dir 'session-state.json') -Value $session -NoNewline -Encoding utf8NoBOM
        $sessionHash = Hash-Of (Join-Path $dir 'session-state.json')
        @('command = cmd.exe /d /k','shell-integration = none','window-save-state = always','confirm-close-surface = false') | Set-Content -LiteralPath (Join-Path $dir 'quarantine.ghostty')
        $env:KORETERM_DEBUG_CRASH_SESSION_RESTORE = '1'
        $runs = @()
        for ($i = 1; $i -le 5; $i++) { $runs += (Launch-Once $label $dir $i) }
        Remove-Item Env:\KORETERM_DEBUG_CRASH_SESSION_RESTORE
        $runs += (Launch-Once $label $dir 6)
        Check $label 'launch 6, without the fault, restores and reaches ready' ($runs[5].HostWindow -and $runs[5].ExitCode -ne 3) 'window' @{ Exit=$runs[5].ExitCode; Window=$runs[5].HostWindow }

        for ($i = 0; $i -lt 3; $i++) {
            Check $label "launch $($i+1) ends during restore (exit 3, no window ready)" ($runs[$i].ExitCode -eq 3 -and -not $runs[$i].HostWindow) 3 @{ Exit=$runs[$i].ExitCode; Window=$runs[$i].HostWindow }
        }
        Check $label 'launch 4 is a safe-mode launch with its notice' ($runs[3].HostWindow -and $null -ne $runs[3].Notice -and $runs[3].Notice.StartsWith('Safe mode')) 'window and notice' @{ Window=$runs[3].HostWindow; Notice=$runs[3].Notice }
        if ($label -eq 'fixed') {
            $last3 = @($runs[2].Attempts | Select-Object -Last 3)
            Check $label 'the three failed attempts are flagged as restoring and carry a version' (@($last3 | Where-Object { $null -ne $_.restore -and $_.version }).Count -eq 3) 3 $last3
            Check $label 'safe-mode launch moved the session aside unchanged' ($null -eq $runs[3].SessionHash -and $runs[3].SetAside.Count -eq 1 -and $runs[3].SetAside[0].Hash -eq $sessionHash) $sessionHash @{ Session=$runs[3].SessionHash; SetAside=$runs[3].SetAside }
            Check $label 'safe-mode notice names the moved session' ($null -ne $runs[3].Notice -and $runs[3].Notice.Contains('.restore-failed')) '.restore-failed' $runs[3].Notice
            Check $label 'launch 5 starts normally with a fresh window' ($runs[4].HostWindow -and $runs[4].ExitCode -ne 3) 'window' @{ Exit=$runs[4].ExitCode; Window=$runs[4].HostWindow }
            $sixth = @($runs[5].Attempts)[-1]
            Check $label 'launch 6 recorded its restore and its version' ($null -ne $sixth.restore -and $sixth.version -and $null -ne $sixth.ready) 'restore, version, ready' $sixth
        } else {
            Check $label 'safe-mode launch leaves the session in place' ($runs[3].SessionHash -eq $sessionHash -and $runs[3].SetAside.Count -eq 0) $sessionHash @{ Session=$runs[3].SessionHash; SetAside=$runs[3].SetAside }
            Check $label 'launch 5 restores the same session and ends again' ($runs[4].ExitCode -eq 3 -and -not $runs[4].HostWindow) 3 @{ Exit=$runs[4].ExitCode; Window=$runs[4].HostWindow }
        }
    }
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    @{ Checks=$script:checks; Launches=$script:launches; Limit='The restore failure is a Debug-only ExitProcess(3) after restore begins, not a real crash; one window, one pane; no input.' } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'quarantine-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count -or $script:checks.Count -eq 0){exit 1}
