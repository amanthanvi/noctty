#requires -Version 7.0
<#
Hidden-desktop captures of the tab strip.

  pwsh -NoProfile -File tabline-run.ps1 -Side main=<bin dir> -Scenario triggers,notice -Run <new dir>

Each side is a bin directory with noctty.exe (a measure-AUMID build); its sibling 'share' is copied too.
Each case is a portable copy (noctty.portable), LOCALAPPDATA/APPDATA point into the run folder, and every
process is started on a desktop created for this run with an explicit lpDesktop. The real startup state,
PSReadLine history (size/mtime/hash only) and the clipboard sequence number are checked before and after.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $Side,
    [Parameter(Mandatory)] [string] $Run,
    [string[]] $Scenario,
    [switch] $Driver,
    [string] $Desktop,
    [ValidateRange(30,3600)] [int] $DriverTimeoutSeconds = 900,
    [string] $ExpectedStartupHash = 'E769C95025A42369B0FD5C339F42BE6FA56C0F21702F8586CEF4CF19A0A2070B'
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Native.cs'))

function Startup-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'noctty\startup-attempts.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    $i = Get-Item -LiteralPath $path
    return @{ Exists=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; Modified=$i.LastWriteTimeUtc.ToString('o'); Length=$i.Length }
}
function History-Fingerprint {
    $path = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (-not (Test-Path -LiteralPath $path)) { return @{ Exists=$false } }
    $i = Get-Item -LiteralPath $path
    return @{ Exists=$true; Length=$i.Length; Modified=$i.LastWriteTimeUtc.ToString('o') }
}
function Parse-Sides([string[]]$Specs) {
    $out = [ordered]@{}
    foreach ($s in ($Specs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) {
        $i = $s.IndexOf('=')
        if ($i -lt 1) { throw "Side must be name=binDir: $s" }
        $name = $s.Substring(0, $i); $dir = $s.Substring($i + 1)
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'noctty.exe'))) { throw "Side $name has no noctty.exe in $dir" }
        $out[$name] = (Resolve-Path -LiteralPath $dir).Path
    }
    return $out
}

if (-not $Driver) {
    $sides = Parse-Sides $Side
    $Run = [IO.Path]::GetFullPath($Run)
    if (Test-Path -LiteralPath $Run) { throw 'Run directory must be new.' }
    $before = Startup-Fingerprint; $histBefore = History-Fingerprint; $clipBefore = [Tl]::GetClipboardSequenceNumber()
    if ($ExpectedStartupHash -and $before.Hash -ne $ExpectedStartupHash) { throw "Real startup state differs from the baseline ($($before.Hash)); no launches performed." }
    [void](New-Item -ItemType Directory -Path $Run)
    foreach ($name in @('localappdata','appdata')) { [void](New-Item -ItemType Directory -Path (Join-Path $Run $name)) }
    $desktopName = 'noctty-tabline-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $desk = [Tl]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
    if ($desk -eq [IntPtr]::Zero) { throw 'CreateDesktop failed.' }
    $oldLocal=$env:LOCALAPPDATA; $oldRoaming=$env:APPDATA
    $pi=$null; $job=[IntPtr]::Zero; [uint32]$code=1
    $startedAt = [DateTime]::UtcNow.ToString('o')
    try {
        $job=[Tl]::CreateOwnedJob()
        $env:LOCALAPPDATA=Join-Path $Run 'localappdata'; $env:APPDATA=Join-Path $Run 'appdata'
        $pwsh=(Get-Command pwsh.exe).Source
        $sideArgs = '-Side "' + (($sides.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ',') + '"'
        $scenArgs = if ($Scenario) { '-Scenario "' + ($Scenario -join ',') + '"' } else { '' }
        $line='"{0}" -NoProfile -NonInteractive -File "{1}" {2} -Run "{3}" {4} -Desktop "{5}" -Driver' -f $pwsh,$PSCommandPath,$sideArgs,$Run,$scenArgs,$desktopName
        # CREATE_NO_WINDOW | BELOW_NORMAL_PRIORITY_CLASS, on the new desktop.
        $pi=[Tl]::Launch($pwsh,$line,$Run,"WinSta0\$desktopName",$job,0x08004000)
        Write-Host "Hidden driver PID=$($pi.pid) desktop=$desktopName evidence=$Run"
        $deadline=[datetime]::UtcNow.AddSeconds($DriverTimeoutSeconds)
        while ([Tl]::WaitForSingleObject($pi.process,1000) -eq 258) {
            if([datetime]::UtcNow -ge $deadline) { throw "Hidden driver exceeded $DriverTimeoutSeconds seconds; owned job will be closed." }
        }
        [void][Tl]::GetExitCodeProcess($pi.process,[ref]$code)
    } finally {
        $env:LOCALAPPDATA=$oldLocal; $env:APPDATA=$oldRoaming
        $cleanupError=$null; $ownedProcessCount=0
        if($job -ne [IntPtr]::Zero) { try { $ownedProcessCount=[Tl]::StopOwnedJob($job) } catch { $cleanupError=$_ } }
        if($pi) { [void][Tl]::CloseHandle($pi.thread); [void][Tl]::CloseHandle($pi.process) }
        [void][Tl]::CloseDesktop($desk)
        $after=Startup-Fingerprint; $histAfter = History-Fingerprint; $clipAfter = [Tl]::GetClipboardSequenceNumber()
        $unchanged=$before.Exists -eq $after.Exists -and $before.Hash -eq $after.Hash -and $before.Modified -eq $after.Modified
        $histUnchanged=$histBefore.Exists -eq $histAfter.Exists -and $histBefore.Length -eq $histAfter.Length -and $histBefore.Modified -eq $histAfter.Modified
        $guard = [ordered]@{ Started=$startedAt; Ended=[DateTime]::UtcNow.ToString('o'); StartupBefore=$before; StartupAfter=$after; StartupUnchanged=$unchanged;
            HistoryBefore=$histBefore; HistoryAfter=$histAfter; HistoryUnchanged=$histUnchanged; ClipboardBefore=$clipBefore; ClipboardAfter=$clipAfter;
            OwnedJobCleanedUp=($null -eq $cleanupError); OwnedProcessCount=$ownedProcessCount; DriverExit=$code }
        $guard | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Run 'guard.json')
        Write-Host ("guard: startup unchanged={0} history unchanged={1} clipboard {2}->{3} owned processes={4}" -f $unchanged, $histUnchanged, $clipBefore, $clipAfter, $ownedProcessCount)
        if (-not $unchanged) { throw 'Real startup state changed; stop launches.' }
        if($cleanupError) { throw $cleanupError }
    }
    if (Test-Path -LiteralPath (Join-Path $Run 'results.txt')) { Get-Content -LiteralPath (Join-Path $Run 'results.txt') | Write-Host }
    if($code -ne 0) { throw "Hidden driver failed with exit $code." }
    exit
}

# ---- driver: runs only on the new desktop ----
[void][Tl]::SetThreadDpiAwarenessContext([IntPtr](-4))
$sides = Parse-Sides $Side
$out = [Collections.Generic.List[string]]::new()
function Say([string]$s) { $out.Add($s); $out | Set-Content -LiteralPath (Join-Path $Run 'results.txt') }
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)

function Copy-Portable([string] $Source, [string] $Destination) {
    [void](New-Item -ItemType Directory -Path $Destination)
    Get-ChildItem -LiteralPath $Source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $share = Join-Path (Split-Path -Parent $Source) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination (Join-Path (Split-Path -Parent $Destination) 'share') -Recurse }
    Set-Content -LiteralPath (Join-Path $Destination 'noctty.portable') -Value '' -NoNewline
}
function Start-Case([string]$Name, [string]$Bin, [string[]]$Extra) {
    $case = Join-Path $Run $Name
    [void](New-Item -ItemType Directory -Path $case)
    $dir = Join-Path $case 'bin'
    Copy-Portable $Bin $dir
    $config = Join-Path $dir 'tabline.ghostty'
    @('command = cmd.exe /d /k','shell-integration = none','single-instance = false',"class = noctty-test-tabline-$runId",
      'window-save-state = never','confirm-close-surface = false','cursor-style-blink = false','keybind = f8=close_tab',
      'window-width = 120','window-height = 34') + $Extra | Set-Content -LiteralPath $config
    $exe = Join-Path $dir 'noctty.exe'
    $pi = [Tl]::Launch($exe, ('"{0}" --config-file="{1}"' -f $exe, $config), $dir, "WinSta0\$Desktop", [IntPtr]::Zero, 0)
    $deadline = [Environment]::TickCount64 + 30000
    $h = [IntPtr]::Zero; $s = [IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 200
        $hosts = @([Tl]::Hosts($pi.pid)); if ($hosts.Count) { $h = $hosts[0]; $s = [Tl]::Surface($h) }
        if ([Tl]::WaitForSingleObject($pi.process, 0) -eq 0) { throw "noctty exited early ($Name)" }
    } while ($s -eq [IntPtr]::Zero -and [Environment]::TickCount64 -lt $deadline)
    $c = @{ Pi=$pi; Host=$h; Surface=$s; Dir=$case; Name=$Name; Launched=[DateTime]::UtcNow }
    if ($s -eq [IntPtr]::Zero) { Stop-Case $c; throw "no terminal surface ($Name)" }
    $d = [Tl]::DesktopOf($h)
    if ($d -ne $Desktop) { Stop-Case $c; throw "host is on desktop '$d', not '$Desktop' ($Name)" }
    Say ("  pid={0} desktop={1} monitors={2}" -f $pi.pid, $d, [Tl]::Monitors())
    Start-Sleep -Seconds 2
    return $c
}
function Stop-Case($c) {
    foreach ($h in [Tl]::Hosts($c.Pi.pid)) { [void][Tl]::PostMessageW($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
    if ([Tl]::WaitForSingleObject($c.Pi.process, 8000) -ne 0) {
        # Exact process: the handle CreateProcess returned for it.
        [void][Tl]::WaitForSingleObject($c.Pi.process, 0)
        Say "  WARNING: noctty did not exit on WM_CLOSE; the owned job ends it"
    }
    [void][Tl]::CloseHandle($c.Pi.thread); [void][Tl]::CloseHandle($c.Pi.process)
}
function Shoot($c, [string]$Label) {
    $h = $c.Host
    $wr = [Tl+Rect]::new(); [void][Tl]::GetWindowRect($h, [ref]$wr)
    $cr = [Tl+Rect]::new(); [void][Tl]::GetClientRect($h, [ref]$cr)
    $o = [Tl+Pt]::new(); [void][Tl]::ClientToScreen($h, [ref]$o)
    $s = [Tl]::Surface($h)
    $sr = [Tl+Rect]::new(); [void][Tl]::GetWindowRect($s, [ref]$sr)
    $shot = [Tl]::Capture($h, 2)
    [Tl]::SaveBmp($shot, (Join-Path $c.Dir "$Label-pw2.bmp"))
    $blt = [Tl]::Blt($h)
    [Tl]::SaveBmp($blt, (Join-Path $c.Dir "$Label-blt.bmp"))
    Say ("  [{0}] dpi={1} zoomed={2} window=({3},{4})-({5},{6}) clientOffset=({7},{8}) client={9}x{10} surface=({11},{12})-({13},{14}) panes={15} pw={16} blt={17}" -f $Label,
        [Tl]::GetDpiForWindow($h), [Tl]::IsZoomed($h), $wr.Left, $wr.Top, $wr.Right, $wr.Bottom, ($o.X-$wr.Left), ($o.Y-$wr.Top), $cr.Right, $cr.Bottom,
        ($sr.Left-$o.X), ($sr.Top-$o.Y), ($sr.Right-$o.X), ($sr.Bottom-$o.Y), [Tl]::SurfaceCount($h), $shot.Ok, $blt.Ok)
    Say ("      children: {0}" -f [Tl]::Children($h))
    $b = [Tl]::Child($h, 1913)
    if ($b -ne [IntPtr]::Zero) {
        try { $e = [System.Windows.Automation.AutomationElement]::FromHandle($b); Say ("      banner 1913 UIA name: '{0}'" -f $e.Current.Name) } catch { Say ("      banner 1913 UIA error {0}" -f $_.Exception.GetType().Name) }
    }
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
function Command($c, [int]$Id) { [void][Tl]::PostMessageW($c.Host, 0x111, [IntPtr]$Id, [IntPtr]::Zero) }
function SysCommand($c, [int]$Sc) { [void][Tl]::PostMessageW($c.Host, 0x112, [IntPtr]$Sc, [IntPtr]::Zero) }

$scenarios = [ordered]@{
    'notice'   = @('window-theme = dark','auto-update = check')
    'triggers' = @('window-theme = dark','auto-update = off')
    'light'    = @('window-theme = light','auto-update = off')
    'three'    = @('window-theme = dark','auto-update = off')
    'dark'     = @('window-theme = dark','auto-update = off')
    'lightterm' = @('window-theme = light','auto-update = off','background = #ffffff','foreground = #1b1b1b')
}
$selected = if ($Scenario) { @($Scenario | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) } else { @('triggers') }
Say ("driver desktop={0} clipboard={1}" -f $Desktop, [Tl]::GetClipboardSequenceNumber())
try {
    foreach ($name in $sides.Keys) {
        foreach ($scen in $selected) {
            Say ("== {0} / {1}" -f $name, $scen)
            $c = $null
            try {
                $c = Start-Case "$name-$scen" $sides[$name] $scenarios[$scen]
                [void][Tl]::SetWindowPos($c.Host, [IntPtr]::Zero, 120, 120, 1280, 800, 0x14)
                Start-Sleep -Milliseconds 1200
                switch ($scen) {
                    'notice' {
                        $deadline = [Environment]::TickCount64 + 45000; $seen = $false
                        do {
                            Start-Sleep -Seconds 1
                            # 1914 is the notice's Open Release / Install button on main; 1.3.131 has no such child.
                            $b = [Tl]::Child($c.Host, 1914)
                            if ($b -ne [IntPtr]::Zero -and [Tl]::IsWindowVisible($b)) { $seen = 'notice-button-1914'; Start-Sleep -Seconds 2; break }
                            $state = Get-ChildItem -LiteralPath $Run -Recurse -Filter 'update-state.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $c.Launched }
                            if ($state) { $seen = 'state-file ' + ($state[0].FullName.Substring($Run.Length)); Start-Sleep -Seconds 3; break }
                        } while ([Environment]::TickCount64 -lt $deadline)
                        Say ("  update check finished: {0}" -f $seen)
                        $state = Get-ChildItem -LiteralPath $Run -Recurse -Filter 'update-state.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $c.Launched }
                        foreach ($f in $state) { Say ("  state {0}: {1}" -f $f.FullName.Substring($Run.Length), ((Get-Content -Raw -LiteralPath $f.FullName) -replace '\s+', ' ')) }
                        Shoot $c 'notice'
                        Start-Sleep -Seconds 8
                        Shoot $c 'notice-late'
                        # Resize and come back, so a later full repaint of the band is captured too.
                        [void][Tl]::SetWindowPos($c.Host, [IntPtr]::Zero, 0, 0, 1100, 700, 0x16); Start-Sleep -Milliseconds 1000; Shoot $c 'notice-resized'
                    }
                    'triggers' {
                        Shoot $c 'launch'
                        [void][Tl]::SetWindowPos($c.Host, [IntPtr]::Zero, 0, 0, 1100, 700, 0x16); Start-Sleep -Milliseconds 1000; Shoot $c 'resized'
                        [void][Tl]::SetWindowPos($c.Host, [IntPtr]::Zero, 0, 0, 1280, 800, 0x16); Start-Sleep -Milliseconds 1000; Shoot $c 'resized-back'
                        SysCommand $c 0xF030; Start-Sleep -Milliseconds 1500; Shoot $c 'maximized'
                        SysCommand $c 0xF120; Start-Sleep -Milliseconds 1500; Shoot $c 'restored'
                        Command $c 1904; Start-Sleep -Milliseconds 2000; Shoot $c 'two-tabs'
                        [Tl]::Key([Tl]::Surface($c.Host), 0x77); Start-Sleep -Milliseconds 1500; Shoot $c 'tab-closed'
                        $plus = [Tl]::Child($c.Host, 1904)
                        [Tl]::Move($plus, 8, 8); [void][Tl]::PostMessageW($plus, 0x2A1, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 600; Shoot $c 'hover-plus'
                        [void][Tl]::PostMessageW($plus, 0x2A3, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 600; Shoot $c 'left-plus'
                        $chev = [Tl]::Child($c.Host, 1911)
                        [void][Tl]::PostMessageW($chev, 0xF5, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 1200
                        $menus = @([Tl]::Menus()); Say ("  menus open: {0}" -f $menus.Count)
                        Shoot $c 'menu-open'
                        foreach ($m in $menus) { [Tl]::Key($m, 0x1B) }
                        Start-Sleep -Milliseconds 1000
                        Say ("  menus after Escape: {0}" -f @([Tl]::Menus()).Count)
                        Shoot $c 'menu-closed'
                        $here = [Tl]::GetDpiForWindow($c.Host)
                        $other = $null
                        foreach ($m in ([Tl]::Monitors() -split ';' | Where-Object { $_ })) {
                            if ($m -match '^\((-?\d+),(-?\d+)\)-\((-?\d+),(-?\d+)\)@(\d+)$' -and [int]$Matches[5] -ne $here) { $other = @([int]$Matches[1], [int]$Matches[2]); break }
                        }
                        if ($other) {
                            $wr = [Tl+Rect]::new(); [void][Tl]::GetWindowRect($c.Host, [ref]$wr)
                            [void][Tl]::SetWindowPos($c.Host, [IntPtr]::Zero, $other[0] + 60, $other[1] + 60, 0, 0, 0x15); Start-Sleep -Milliseconds 2000; Shoot $c 'dpi-moved'
                            [void][Tl]::SetWindowPos($c.Host, [IntPtr]::Zero, $wr.Left, $wr.Top, 0, 0, 0x15); Start-Sleep -Milliseconds 2000; Shoot $c 'dpi-back'
                        } else { Say '  no monitor with another DPI' }
                    }
                    { $_ -in @('light','dark','lightterm') } { Shoot $c 'launch'; Command $c 1904; Start-Sleep -Milliseconds 2000; Command $c 1904; Start-Sleep -Milliseconds 2000; Shoot $c 'three-tabs' }
                    'three' { Command $c 1904; Start-Sleep -Milliseconds 2000; Command $c 1904; Start-Sleep -Milliseconds 2000; Shoot $c 'three-tabs' }
                }
            } catch { Say ("  ERROR: {0}" -f $_) } finally { if ($c) { Stop-Case $c } }
        }
    }
} finally {
    Say ("driver end clipboard={0}" -f [Tl]::GetClipboardSequenceNumber())
}
