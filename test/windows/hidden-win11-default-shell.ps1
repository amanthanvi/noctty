#requires -Version 7.0
<#
Portable, hidden-desktop check of the shell a new terminal starts when `command`
is unset (PKG-49): PowerShell 7 if it is on PATH, else Windows PowerShell, else
cmd.exe, and cmd.exe in safe mode. Run with -Bin <directory holding a noctty.exe
and its share folder> and -Run <new evidence directory>.

Cases, each one launch of noctty with no `command` in its config:
  default           a quoted, explicit PowerShell 7 install directory first on
                    PATH: expects pwsh.exe (inherited PATH follows it so user
                    profile dependencies remain available)
  no-pwsh           only Windows system directories on PATH: expects powershell.exe
  restricted-51     the same, with the process execution policy Restricted: the
                    screen must settle with no warning from this app and
                    the injected shell integration must be on the command line (
                    only a policy-blocked user profile.ps1 is expected there)
  safe-mode         --safe-mode: expects cmd.exe whatever else is installed
Per case the results hold the shell's image name, whether the integration
payload was supplied on its command line (a boolean; the command line itself is
never written), the time from launch until its screen stops changing, and the
text of that shell's own screen, read through its console (the screen of a
terminal this script started, never a user's). This is a smoke check: a screen
that settles proves the shell started and went quiet, not that the integration
hook ran. That the injected payload loads, under Restricted included, is
test/windows/powershell-shell-integration.ps1's job; no key is typed here, so no
shell history is written.

PowerShell7Directory defaults to this script's PowerShell 7 installation ($PSHOME).
It must be a direct local installation without redirected ancestors, acceptable
to automatic discovery; an unsuitable fixture fails the default case. The harness
does not predict discovery from inherited PATH. The Windows PowerShell cases use
a minimal PATH, so user profiles that require external tools may fail those cases.

Every file the app reads or writes is one this script creates beside a portable
copy (`noctty.portable`), with LOCALAPPDATA and APPDATA redirected into the run
directory: the real %LOCALAPPDATA%\noctty is never written or deleted, and only
the hash and time of its startup state file are read, before and after. Every
process starts on a private desktop named explicitly in STARTUPINFO, inside a
job this script owns. Nothing is typed and nothing can copy; the clipboard
sequence number is logged before and after and a change fails the run, as does a
change in the size or time of either real PSReadLine history file (metadata only,
scripts/windows-harness-history.ps1). These shells run the product's own command line, which a
history-path override would change, so the guard is their only history control.
Launch a build patched with a measurement AUMID only; -MeasureJumpListName names
that AUMID's jump-list file, which the script deletes only when it did not exist
before the run and was written during it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Bin,
    [Parameter(Mandatory)] [string] $Run,
    [switch] $Driver,
    [string] $Desktop,
    [string] $AttachExe,
    [string] $PowerShell7Directory = $PSHOME,
    [ValidateRange(1,1800)] [int] $DriverTimeoutSeconds = 300,
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
public static class Ds {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Startup {
        public int cb; public string reserved,desktop,title;
        public int x,y,cx,cy,charsX,charsY,fill,flags; public short show,reservedBytes;
        public IntPtr reservedPointer,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] public struct ProcessInfo { public IntPtr process,thread; public int pid,tid; }
    public delegate bool EnumWindow(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindow cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
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
    // Children are created suspended and always placed on the named desktop.
    // noWindow: CREATE_NO_WINDOW, for console helpers.
    public static ProcessInfo Launch(string app,string command,string cwd,string desktop,IntPtr job,bool noWindow) {
        var si=new Startup { cb=Marshal.SizeOf<Startup>(),desktop=desktop,flags=1,show=0 }; ProcessInfo pi;
        uint flags=0x00000004|(noWindow?0x08000000u:0u)|0x00000400u; // SUSPENDED, UNICODE_ENVIRONMENT
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
# Compile a C helper without a window: the compile runs in the build shell with no console of its own.
function Compile-Helper([string] $Source, [string] $Exe, [IntPtr] $Job, [string] $Root, [string] $Desktop) {
    $script = [IO.Path]::ChangeExtension($Exe, '.cmd')
    @('@echo off', ('call "{0}" cl /nologo /W4 /WX /O2 /DUNICODE /D_UNICODE "{1}" /Fe:"{2}" /Fo:"{3}" > "{4}" 2>&1' -f
        (Join-Path $Root 'scripts\dev-windows.cmd'), $Source, $Exe, ($Exe -replace '\.exe$', '.obj'), ($Exe -replace '\.exe$', '.compile.log')),
        'exit /b %errorlevel%') | Set-Content -LiteralPath $script -Encoding ascii
    $pi = [Ds]::Launch($env:ComSpec, ('"{0}" /d /c ""{1}""' -f $env:ComSpec, $script), $Root, $Desktop, $Job, $true)
    [void][HiddenLocal]::WaitForSingleObject($pi.process, 180000)
    [uint32]$code = 1; [void][HiddenLocal]::GetExitCodeProcess($pi.process, [ref]$code)
    [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process)
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $Exe)) { throw "Helper compile failed: $Source" }
}

if (-not $Driver) {
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    $source = (Resolve-Path -LiteralPath $Bin).Path
    if (-not (Test-Path -LiteralPath (Join-Path $source 'noctty.exe'))) { throw "No noctty.exe in $source." }
    $PowerShell7Directory = [IO.Path]::GetFullPath($PowerShell7Directory)
    if (-not (Test-Path -LiteralPath (Join-Path $PowerShell7Directory 'pwsh.exe') -PathType Leaf)) { throw 'PowerShell7Directory must name an installed PowerShell 7 directory.' }
    $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $before = Startup-Fingerprint
    $historyGuard = Start-WindowsHarnessHistoryGuard -Harness 'hidden-win11-default-shell.ps1'
    $clipboardBefore = [HiddenLocal]::GetClipboardSequenceNumber()
    if (($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) -or ($ExpectedStartupModified -and $before.Modified -ne $ExpectedStartupModified)) { throw 'Real startup state differs from supplied baseline; no launches performed.' }
    $jumpBefore = @(Jump-List-Files | ForEach-Object { $_.Path })
    $batchStart = [DateTimeOffset]::UtcNow
    Write-Host "Clipboard sequence before: $clipboardBefore"
    [void](New-Item -ItemType Directory -Path $Run)
    $copy = Join-Path $Run 'case\bin'
    Copy-Portable $source $copy
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $attach = Join-Path $Run 'console-attach-info.exe'
    $desktopName = 'noctty-ds-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenLocal]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero; $code=1
    try {
        $compileJob = [HiddenLocal]::CreateOwnedJob()
        try { Compile-Helper (Join-Path $PSScriptRoot 'console-attach-info.c') $attach $compileJob $root "WinSta0\$desktopName" } finally { [void][HiddenLocal]::StopOwnedJob($compileJob) }
        $job=[HiddenLocal]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=Join-Path $PSHOME 'pwsh.exe'
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" -Bin "{2}" -Run "{3}" -AttachExe "{4}" -Desktop "{5}" -PowerShell7Directory "{6}" -Driver' -f $pwsh,$PSCommandPath,$copy,$Run,$attach,"WinSta0\$desktopName",$PowerShell7Directory
        $pi=[Ds]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job,$true)
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
        if($pi) { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
        [void][HiddenLocal]::CloseDesktop($desktop)
        $batchEnd = [DateTimeOffset]::UtcNow
        # Only the measurement AUMID's file, and only if this batch created it.
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
    if($code -ne 0) { throw "Hidden driver failed with exit $code; inspect results in $Run." }
    Write-Host 'Hidden default shell: PASS'
    exit
}

# Driver: runs only on the private desktop, inside the owned job.
. (Join-Path $PSScriptRoot '..\..\scripts\interactive-win11-lib.ps1')
$script:checks=[Collections.Generic.List[object]]::new()
$script:launches=[Collections.Generic.List[object]]::new()
function Check([string]$Case,[string]$Name,[bool]$Passed,$Expected,$Actual) {
    $script:checks.Add(@{ Case=$Case; Name=$Name; Passed=$Passed; Expected=$Expected; Actual=$Actual })
}
$shellNames = @('pwsh.exe','powershell.exe','cmd.exe')
# Names, image paths and ids only. The command line of a shell is tested for the integration
# payload inside this function and never returned.
# ParentProcessId is a number Windows reuses: a process whose parent exited can name the newer
# process that took its number, so a shell older than the process it claims as its parent is not
# under noctty (its screen would be someone else's), and is skipped. A start time CIM could not read
# proves nothing. The query has a deadline of its own: the caller's 30 s loop cannot interrupt a call.
function Find-Shell([int]$RootPid) {
    $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,CreationDate -OperationTimeoutSec 15 -ErrorAction Stop)
    $started = @{}; foreach ($p in $all) { $started[[int]$p.ProcessId] = $p.CreationDate }
    $ids = [Collections.Generic.HashSet[int]]::new(); [void]$ids.Add($RootPid)
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) {
            if (-not $ids.Contains([int]$p.ParentProcessId)) { continue }
            $parentStart = $started[[int]$p.ParentProcessId]
            if ($null -ne $p.CreationDate -and $null -ne $parentStart -and $p.CreationDate.ToUniversalTime() -lt $parentStart.ToUniversalTime()) { continue }
            if ($ids.Add([int]$p.ProcessId)) { $grew = $true }
        }
    }
    foreach ($p in $all) {
        if ($ids.Contains([int]$p.ProcessId) -and $p.ProcessId -ne $RootPid -and $shellNames -contains $p.Name.ToLowerInvariant()) {
            $integration = ($null -ne $p.CommandLine) -and ($p.CommandLine -match 'integration\.ps1|__ghostty')
            $noAutoRun = ($null -ne $p.CommandLine) -and ($p.CommandLine -match '(?i)\s/d(\s|$)')
            return @{ Pid=[int]$p.ProcessId; Name=$p.Name.ToLowerInvariant(); ImagePath=$p.ExecutablePath; Integration=$integration; NoAutoRun=$noAutoRun }
        }
    }
    return $null
}
function Read-Screen([int]$ShellPid,[string]$OutFile) {
    $pi = [Ds]::Launch($AttachExe,('"{0}" {1} "{2}" dump' -f $AttachExe,$ShellPid,$OutFile),(Split-Path -Parent $AttachExe),$Desktop,[IntPtr]::Zero,$true)
    try {
        [void][HiddenLocal]::WaitForSingleObject($pi.process,10000)
        [uint32]$code=1; [void][HiddenLocal]::GetExitCodeProcess($pi.process,[ref]$code)
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) { return $null }
        return @(Get-Content -LiteralPath $OutFile | Select-Object -Skip 1)
    } finally { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
}
function Launch-Case([string]$Case,[string]$Exe,[string[]]$ExtraArgs,[hashtable]$Env) {
    $dir = Split-Path -Parent $Exe
    @('window-save-state = never','confirm-close-surface = false','auto-update = off') | Set-Content -LiteralPath (Join-Path $dir 'config.ghostty')
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k,$Env[$k]) }
    $class = "noctty-test-pkg49-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $line = '"{0}" --single-instance=false --class={1} {2}' -f $Exe,$class,($ExtraArgs -join ' ')
    $record = @{ Case=$Case; Shell=$null; Integration=$null; PromptMs=$null; PromptLine=$null; Screen=@(); NocttyWarnings=@(); HostNoise=@(); Unexplained=@(); NoAutoRun=$null }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { $pi = [Ds]::Launch($Exe,$line,$dir,$Desktop,[IntPtr]::Zero,$false) }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k,$saved[$k]) } }
    try {
        $record.Pid = $pi.pid
        $shell = $null
        while ($clock.Elapsed.TotalSeconds -lt 30 -and $null -eq $shell) {
            if ([HiddenLocal]::WaitForSingleObject($pi.process,0) -eq 0) { break }
            $shell = Find-Shell $pi.pid
            if ($null -eq $shell) { Start-Sleep -Milliseconds 100 }
        }
        if ($shell) {
            $record.Shell = $shell.Name; $record.ShellPath = $shell.ImagePath; $record.Integration = $shell.Integration; $record.NoAutoRun = $shell.NoAutoRun
            $out = Join-Path $dir "screen-$Case.txt"
            # A prompt is the screen holding the same non-empty rows in two reads 750 ms apart: prompts are
            # themed (a starship prompt is `~ ❯`), so no pattern for them is trusted.
            $last = $null; $lastAt = 0
            while ($clock.Elapsed.TotalSeconds -lt 40) {
                Remove-Item -LiteralPath $out -ErrorAction Ignore
                $rows = Read-Screen $shell.Pid $out
                if ($rows) {
                    $text = @($rows | Where-Object { $_.Trim() })
                    $joined = $text -join "`n"
                    if ($text.Count -gt 0 -and $joined -eq $last -and ($clock.ElapsedMilliseconds - $lastAt) -ge 750) {
                        $record.PromptMs = $lastAt
                        $record.PromptLine = $text[-1]
                        $record.Screen = $text
                        break
                    }
                    if ($joined -ne $last) { $last = $joined; $lastAt = [int]$clock.ElapsedMilliseconds }
                }
                Start-Sleep -Milliseconds 250
            }
            # Only a policy-blocked user profile is expected under Restricted.
            # PSReadLine errors must fail, including inherited PS7 module-path failures.
            $record.NocttyWarnings = @($record.Screen | Where-Object { $_ -match '(?i)noctty|integration (skipped|could not)|could not load' })
            $profileBlocked = ($record.Screen -join "`n") -match '(?i)profile\.ps1.*cannot be loaded'
            $record.HostNoise = @($record.Screen | Where-Object { $Case -eq 'restricted-51' -and $profileBlocked -and $_ -notmatch '(?i)PSReadLine|noctty|integration' -and $_ -match '(?i)profile\.ps1|about_Execution_Policies|SecurityError|UnauthorizedAccess|FullyQualifiedErrorId|^\s*\+ |^At line:|^because running scripts|^about_Execution' })
            # Every row but the last (the prompt) must be a row the host explains; wrapped lines of the profile error count.
            $record.Unexplained = @($record.Screen | Select-Object -SkipLast 1 | Where-Object { $record.HostNoise -notcontains $_ -and $_ -notmatch '^(because|about_|\. :|File )' })
        }
        if ([HiddenLocal]::WaitForSingleObject($pi.process,0) -ne 0) {
            foreach ($h in [Ds]::Windows($pi.pid,'noctty.win32.host')) { [void][Ds]::PostMessageW($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero) }
            if ([HiddenLocal]::WaitForSingleObject($pi.process,8000) -ne 0) {
                # Our own handle from CreateProcess: the exact process we started.
                [void][Ds]::TerminateProcess($pi.process,1); [void][HiddenLocal]::WaitForSingleObject($pi.process,5000)
                $record.Terminated = $true
            }
        }
    } finally { [void][Ds]::CloseHandle($pi.thread); [void][Ds]::CloseHandle($pi.process) }
    $script:launches.Add($record)
    return $record
}

try {
    $exe = Join-Path $Bin 'noctty.exe'
    # An explicit installed PS7 fixture wins before any inherited entry. Quoting
    # it also exercises discovery's quoted PATH handling without a second resolver.
    $withPwsh = '"{0}";{1}' -f $PowerShell7Directory,$env:PATH
    $withoutPwsh = @(
        (Join-Path $env:SystemRoot 'System32'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32\Wbem'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    ) -join ';'
    $windowsPowerShellModules = Get-InteractiveWin11WindowsPowerShellModulePath $env:PSModulePath
    $expectedWindowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $expectedCmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'

    $r = Launch-Case 'default' $exe @() @{ PATH = $withPwsh }
    $expectedPwsh = Join-Path $PowerShell7Directory 'pwsh.exe'
    Check 'default' 'the first tab runs pwsh.exe from the explicit quoted PATH fixture' ($r.Shell -eq 'pwsh.exe' -and $r.ShellPath -eq $expectedPwsh) $expectedPwsh $r.ShellPath
    Check 'default' 'the shell integration payload is on its command line' ($r.Integration -eq $true) $true $r.Integration
    Check 'default' 'the shell starts and its screen settles' ($null -ne $r.PromptMs) 'settled' $r.PromptLine
    Check 'default' 'nothing unexplained above the prompt' ($r.Unexplained.Count -eq 0) 0 $r.Unexplained
    Check 'default' 'no warning from this app on the screen' ($r.NocttyWarnings.Count -eq 0) 0 $r.NocttyWarnings

    $r = Launch-Case 'no-pwsh' $exe @() @{ PATH = $withoutPwsh; PSModulePath = $windowsPowerShellModules }
    Check 'no-pwsh' 'without pwsh.exe on PATH the first tab runs system Windows PowerShell' ($r.Shell -eq 'powershell.exe' -and $r.ShellPath -eq $expectedWindowsPowerShell) $expectedWindowsPowerShell $r.ShellPath
    Check 'no-pwsh' 'nothing unexplained above the prompt' ($r.Unexplained.Count -eq 0) 0 $r.Unexplained
    Check 'no-pwsh' 'the shell starts and its screen settles' ($null -ne $r.PromptMs) 'settled' $r.PromptLine

    $r = Launch-Case 'restricted-51' $exe @() @{ PATH = $withoutPwsh; PSExecutionPolicyPreference = 'Restricted'; PSModulePath = $windowsPowerShellModules }
    Check 'restricted-51' 'system Windows PowerShell 5.1 starts under the Restricted policy' ($r.Shell -eq 'powershell.exe' -and $r.ShellPath -eq $expectedWindowsPowerShell) $expectedWindowsPowerShell $r.ShellPath
    Check 'restricted-51' 'the integration payload is on its command line' ($r.Integration -eq $true) $true $r.Integration
    Check 'restricted-51' 'the shell starts and its screen settles' ($null -ne $r.PromptMs) 'settled' $r.PromptLine
    Check 'restricted-51' 'every row above the prompt is the host or the user profile under Restricted' ($r.Unexplained.Count -eq 0) 0 $r.Unexplained
    Check 'restricted-51' 'no integration warning or PSReadLine load error on the screen' ($r.NocttyWarnings.Count -eq 0 -and -not ($r.Screen -match 'Cannot load PSReadline')) 0 $r.NocttyWarnings

    $r = Launch-Case 'safe-mode' $exe @('--safe-mode') @{ PATH = $withPwsh }
    Check 'safe-mode' 'safe mode starts system cmd.exe although PowerShell is installed' ($r.Shell -eq 'cmd.exe' -and $r.ShellPath -eq $expectedCmd) $expectedCmd $r.ShellPath
    Check 'safe-mode' 'with /D, which skips the AutoRun command' ($r.NoAutoRun -eq $true) $true $r.NoAutoRun
    Check 'safe-mode' 'nothing unexplained above the prompt' ($r.Unexplained.Count -eq 0) 0 $r.Unexplained
    Check 'safe-mode' 'the shell starts and its screen settles' ($null -ne $r.PromptMs) 'settled' $r.PromptLine
} catch {
    $script:checks.Add(@{Name='Harness execution'; Passed=$false; Error=$_.Exception.Message})
} finally {
    @{ PowerShell7FixtureDirectory=$PowerShell7Directory; WindowsPowerShellPath=$withoutPwsh; Checks=$script:checks; Launches=$script:launches; Limit='One window, one tab per launch; no input; the settle time is from launch until the shell screen stops changing for 750 ms, polled every 250 ms; a settled screen is not proof that the integration hook ran. Windows PowerShell cases use a minimal system PATH; profiles requiring external tools may fail.' } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Run 'default-shell-results.json')
}
$failed=@($script:checks|Where-Object {-not $_.Passed})
if($failed.Count -or $script:checks.Count -eq 0){exit 1}
