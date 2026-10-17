#requires -Version 7.0
<#
Hosted-only positive control for the outer Default-desktop window oracle. A dedicated
helper in an owned outer job creates an inner job and a tiny window helper on Default.
The parent must find that exact helper PID through both the outer job list and oracle.
No noctty, foreground, input or clipboard operations. Never run this live locally.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Run,
    [ValidateSet('Parent', 'Nested', 'Window', 'PrivateDriver')] [string] $Mode = 'Parent',
    [string] $DesktopName
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hidden-win11-lib.ps1')
Assert-HiddenRunner
$controlScript = $PSCommandPath

function Start-DesktopControlHelper([IntPtr] $Job, [string] $Run, [string] $HelperMode) {
    Assert-HiddenRunner
    if ($HelperMode -cnotin @('Nested', 'Window')) { throw 'Invalid desktop control helper mode.' }
    $pwsh = (Get-Command pwsh.exe).Source
    $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -Mode {3}' -f $pwsh, $controlScript, $Run, $HelperMode
    # Launch supplies CREATE_NO_WINDOW, suspended assignment, then resume; no breakaway.
    return [HiddenWin]::Launch($pwsh, $line, $Run, 'WinSta0\Default', $Job, (Join-Path $Run "$HelperMode-stderr.log"))
}

function Invoke-DesktopControlNested([string] $Run) {
    Assert-HiddenRunner
    if ([HiddenWin]::CurrentDesktopName() -cne 'Default') { throw 'Control helper must be on Default.' }
    $inner = [IntPtr]::Zero; $window = $null; $cleaned = $false; $count = 0
    try {
        $inner = [HiddenWin]::CreateOwnedJob()
        $window = Start-DesktopControlHelper -Job $inner -Run $Run -HelperMode 'Window'
        if (@([HiddenWin]::JobProcessIds($inner)) -notcontains $window.pid) { throw 'Window helper missing from inner job.' }
        @{ WindowPid = $window.pid; InnerMember = $true } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $Run 'window-helper.json')
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath (Join-Path $Run 'stop-control'))) {
            if ([HiddenWin]::WaitForSingleObject($window.process, 50) -ne 258) { throw 'Window helper exited before observation.' }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Nested control exceeded twenty seconds.' }
        }
    } finally {
        try {
            if ($inner -ne [IntPtr]::Zero) { $count = [HiddenWin]::StopOwnedJob($inner); $cleaned = $true }
        } finally {
            if ($window) { [void][HiddenWin]::CloseHandle($window.thread); [void][HiddenWin]::CloseHandle($window.process) }
            @{ InnerJobCleanedUp = $cleaned; OwnedProcessCount = $count } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $Run 'nested-cleanup.json')
        }
    }
}

function Invoke-DesktopControlParent([string] $Run) {
    Assert-HiddenRunner
    if ([HiddenWin]::CurrentDesktopName() -cne 'Default') { throw 'Control parent must observe Default.' }
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $outer = [IntPtr]::Zero; $nested = $null; $seen = $false; $windowExited = $false; $innerCleaned = $false; $outerCleaned = $false; $count = 0; $windowPid = 0
    try {
        $outer = [HiddenWin]::CreateOwnedJob()
        $nested = Start-DesktopControlHelper -Job $outer -Run $Run -HelperMode 'Nested'
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        do {
            if ([HiddenWin]::WaitForSingleObject($nested.process, 50) -ne 258) { throw 'Nested helper exited before observation.' }
            $ready = Join-Path $Run 'window-helper.json'
            if (Test-Path -LiteralPath $ready) {
                # A concurrent write may not be complete yet. Do not hide native oracle errors.
                $helper = $null
                try { $helper = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json -ErrorAction Stop } catch { }
                if ($helper -and $helper.InnerMember -and [int]$helper.WindowPid -gt 0) {
                    $windowPid = [int]$helper.WindowPid
                    $outerIds = @([HiddenWin]::JobProcessIds($outer))
                    $windows = @([HiddenWin]::DefaultJobWindows($outer))
                    $seen = $outerIds -contains $windowPid -and @($windows | Where-Object ProcessId -eq $windowPid).Count -gt 0
                }
            }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Default desktop control did not detect the nested window helper.' }
        } until ($seen)
        Set-Content -LiteralPath (Join-Path $Run 'stop-control') -Value ''
        if ([HiddenWin]::WaitForSingleObject($nested.process, 10000) -ne 0) { throw 'Nested cleanup exceeded ten seconds.' }
        [uint32]$exitCode = 0
        if (-not [HiddenWin]::GetExitCodeProcess($nested.process, [ref]$exitCode) -or $exitCode -ne 0) { throw 'Nested control failed.' }
        # Independently confirm inner cleanup before outer cleanup could mask a leak.
        $cleanupDeadline = [datetime]::UtcNow.AddSeconds(2)
        while (@([HiddenWin]::JobProcessIds($outer)) -contains $windowPid) {
            if ([datetime]::UtcNow -ge $cleanupDeadline) { throw 'Window helper remained in outer job after nested cleanup.' }
            Start-Sleep -Milliseconds 50
        }
        $windowExited = $true
        $cleanup = Get-Content -LiteralPath (Join-Path $Run 'nested-cleanup.json') -Raw | ConvertFrom-Json
        $innerCleaned = $cleanup.InnerJobCleanedUp -eq $true -and $cleanup.OwnedProcessCount -ge 1
        if (-not $innerCleaned) { throw 'Nested owned job cleanup was not confirmed.' }
    } finally {
        try {
            if ($outer -ne [IntPtr]::Zero) { $count = [HiddenWin]::StopOwnedJob($outer); $outerCleaned = $true }
        } finally {
            if ($nested) { [void][HiddenWin]::CloseHandle($nested.thread); [void][HiddenWin]::CloseHandle($nested.process) }
            @{ Passed = ($seen -and $innerCleaned -and $outerCleaned); WindowPid = $windowPid; OuterJobContainsNestedWindow = $seen
                DefaultOracleDetectedWindow = $seen; WindowHelperExitedBeforeOuterCleanup = $windowExited; InnerJobCleanedUp = $innerCleaned; OuterJobCleanedUp = $outerCleaned; OwnedProcessCount = $count } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Run 'desktop-control-results.json')
        }
    }
    Write-Host 'Default desktop nested-job window control: PASS'
}

function Invoke-DesktopControlWindow {
    Assert-HiddenRunner
    if ([HiddenWin]::CurrentDesktopName() -cne 'Default') { throw 'Window helper must be on Default.' }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HiddenDesktopControlWindow {
    [StructLayout(LayoutKind.Sequential)] struct Message {
        public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam;
        public uint time; public int x, y; public uint privateData;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool PeekMessageW(out Message m, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref Message m);
    public static void Run() {
        // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, hidden WS_POPUP; built-in class.
        var hwnd = CreateWindowExW(0x08000080, "STATIC", "", 0x80000000, 0, 0, 16, 16, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new Exception("Control window creation failed");
        try {
            var deadline = DateTime.UtcNow.AddSeconds(20);
            while (DateTime.UtcNow < deadline) {
                Message m;
                for (int i = 0; i < 32 && PeekMessageW(out m, IntPtr.Zero, 0, 0, 1); i++) DispatchMessageW(ref m);
                System.Threading.Thread.Sleep(10);
            }
        } finally { DestroyWindow(hwnd); }
    }
}
'@
    Assert-HiddenRunner
    [HiddenDesktopControlWindow]::Run()
}

function Invoke-PrivateDesktopControlDriver([string] $Run, [string] $DesktopName) {
    Assert-HiddenRunner
    if ($DesktopName -cnotmatch '^noctty-hw-[0-9a-f]{32}$') { throw 'Invalid private control desktop.' }
    # Connect this thread, then retain a hidden sentinel on its assigned desktop.
    $actual = [HiddenWin]::CurrentDesktopName()
    if ($actual -cne $DesktopName) { throw 'Private control driver is on the wrong desktop.' }
    $sentinel = [HiddenWin]::CreateDriverSentinel()
    $driverFailure = $null
    try {
    @{ ProcessId = $PID; Desktop = $actual; Connected = $true; WindowStation = [HiddenWin]::CurrentWindowStationName()
        SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $Run 'private-driver-ready.json')
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath (Join-Path $Run 'stop-private-control'))) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'Private control driver exceeded twenty seconds.' }
        Start-Sleep -Milliseconds 50
    }
    } catch { $driverFailure = $_; throw } finally { Close-HiddenDriverSentinel -Sentinel $sentinel -Run $Run -PrimaryFailure $driverFailure }
}

function Invoke-PrivateDesktopControlParent([string] $Run) {
    Assert-HiddenRunner
    if ([HiddenWin]::CurrentDesktopName() -cne 'Default') { throw 'Private control parent must observe Default.' }
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    [void](New-Item -ItemType Directory -Path $Run)
    $desktopName = 'noctty-hw-' + [guid]::NewGuid().ToString('N')
    $desktop = [IntPtr]::Zero; $job = [IntPtr]::Zero; $driver = $null
    $readyObserved = $false; $observed = $false; $passed = $false; $cleaned = $false; $count = 0
    try {
        $desktop = [HiddenWin]::CreateInheritedDesktop($desktopName)
        $job = [HiddenWin]::CreateOwnedJob()
        $pwsh = (Get-Command pwsh.exe).Source
        $line = '"{0}" -NoProfile -NonInteractive -File "{1}" -Run "{2}" -Mode PrivateDriver -DesktopName {3}' -f $pwsh, $controlScript, $Run, $desktopName
        $driver = [HiddenWin]::Launch($pwsh, $line, $Run, "WinSta0\$desktopName", $job, (Join-Path $Run 'private-driver-stderr.log'))
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        do {
            if ([HiddenWin]::WaitForSingleObject($driver.process, 100) -ne 258) { throw 'Private control driver exited before observation.' }
            Assert-HiddenDefaultDesktop -Job $job -ReceiptPath (Join-Path $Run 'private-default-windows.jsonl')
            $ready = $null
            $readyPath = Join-Path $Run 'private-driver-ready.json'
            if (Test-Path -LiteralPath $readyPath) {
                try { $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { }
            }
            $readyObserved = $ready -and $ready.Connected -eq $true -and $ready.ProcessId -eq $driver.pid -and $ready.Desktop -ceq $desktopName
            if ([datetime]::UtcNow -ge $deadline) { throw 'Private control driver did not report its desktop within fifteen seconds.' }
        } until ($readyObserved)
        if ($ready.WindowStation -cne [HiddenWin]::CurrentWindowStationName() -or
            $ready.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or
            @([HiddenWin]::JobProcessIds($job)) -notcontains $driver.pid) { throw 'Private control driver identity mismatch.' }
        Assert-HiddenDesktop -Job $job -DesktopName $desktopName -DriverPid $driver.pid -ReceiptPath (Join-Path $Run 'private-ready-desktops.jsonl') -RequiredWindowPid $driver.pid
        $observed = $true
        Set-Content -LiteralPath (Join-Path $Run 'stop-private-control') -Value ''
        if ([HiddenWin]::WaitForSingleObject($driver.process, 5000) -ne 0) { throw 'Private control driver stop exceeded five seconds.' }
        [uint32]$exitCode = 0
        if (-not [HiddenWin]::GetExitCodeProcess($driver.process, [ref]$exitCode) -or $exitCode -ne 0) { throw 'Private control driver failed.' }
        $passed = $true
    } finally {
        try {
            if ($job -ne [IntPtr]::Zero) { $count = [HiddenWin]::StopOwnedJob($job); $cleaned = $true }
        } finally {
            if ($driver) { [void][HiddenWin]::CloseHandle($driver.thread); [void][HiddenWin]::CloseHandle($driver.process) }
            if ($desktop -ne [IntPtr]::Zero) { [void][HiddenWin]::CloseDesktop($desktop) }
            @{ Passed = ($passed -and $cleaned)
                ExpectedDesktop = $desktopName; DriverPid = $(if ($driver) { $driver.pid } else { 0 }); MainThreadId = $(if ($driver) { $driver.tid } else { 0 })
                DriverConnected = $readyObserved; ReadyObservationPassed = $observed; DriverWindowObserved = $observed
                OwnedJobCleanedUp = $cleaned; OwnedProcessCount = $count } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $Run 'private-desktop-control-results.json')
        }
    }
    Write-Host 'Private desktop self-receipt and window-enumeration control: PASS'
}

switch ($Mode) {
    'Parent' { Invoke-DesktopControlParent -Run $Run; Invoke-PrivateDesktopControlParent -Run (Join-Path $Run 'private-desktop') }
    'Nested' { Invoke-DesktopControlNested -Run $Run }
    'Window' { Invoke-DesktopControlWindow }
    'PrivateDriver' { Invoke-PrivateDesktopControlDriver -Run $Run -DesktopName $DesktopName }
}
