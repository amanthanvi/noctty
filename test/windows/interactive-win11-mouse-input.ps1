#requires -Version 7.0
[CmdletBinding()]
param([string] $ExePath, [string] $RunRoot, [switch] $Worker,
      [ValidateSet('context-menu','ignore','copy')] [string] $RightClickAction = 'context-menu',
      [switch] $ObserveBaseline)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-mouse-input.ps1'
try {

# No clipboard access, SendInput, cursor movement, or foreground changes.
# All messages target a portable instance on a newly created hidden desktop.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $ExePath) { $ExePath = Join-Path $repoRoot 'zig-out\bin\koreterm.exe' }
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot ('.zig-cache\pkg26\mouse-' + [guid]::NewGuid().ToString('N')) }
. (Join-Path $PSScriptRoot 'interactive-win11-hidden-desktop-lib.ps1')

if (-not ('MouseInputNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class MouseInputNative {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd,ref Point point);
    [DllImport("user32.dll",SetLastError=true)] public static extern bool PostMessageW(IntPtr hwnd,uint msg,UIntPtr wparam,IntPtr lparam);
    public static long Position(int x,int y) { return (long)((uint)(ushort)x | ((uint)(ushort)y<<16)); }
}
'@
}

if (-not $Worker) {
    $ExePath = (Resolve-Path -LiteralPath $ExePath).Path
    if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be fresh.' }
    $realStartup = Join-Path $env:LOCALAPPDATA 'koreterm\startup-attempts.json'
    $before = Get-Fingerprint $realStartup
    [void](New-Item -ItemType Directory -Path $RunRoot)
    $RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
    Copy-Item -LiteralPath $ExePath -Destination (Join-Path $RunRoot 'koreterm.exe')
    $bin = Split-Path -Parent $ExePath
    foreach ($name in @('conpty.dll', 'OpenConsole.exe', 'koreterm.ico')) {
        $source = Join-Path $bin $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $RunRoot }
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $bin) 'share') -Destination (Join-Path $RunRoot 'share') -Recurse
    [IO.File]::WriteAllText((Join-Path $RunRoot 'koreterm.portable'), '')
    $fixtureSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
class MouseRecorder {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle,uint mode);
    static int Main(string[] a) {
        uint mode;
        if(!GetConsoleMode(GetStdHandle(-10),out mode) || !SetConsoleMode(GetStdHandle(-10),(mode|512)&~(2u|4u))) return 11;
        if(GetConsoleMode(GetStdHandle(-11),out mode)) SetConsoleMode(GetStdHandle(-11),mode|4);
        File.WriteAllText(a[0]+".ready","yes");
        while(!File.Exists(a[0]+".enable")) Thread.Sleep(20);
        Console.Write("\x1b[?1003h\x1b[?1006h"); Console.Out.Flush();
        File.WriteAllText(a[0]+".enabled","yes");
        using(var input=Console.OpenStandardInput()) using(var log=new FileStream(a[0]+".bytes",FileMode.Create,FileAccess.Write,FileShare.ReadWrite)) {
            var bytes=new byte[256]; int count;
            while((count=input.Read(bytes,0,bytes.Length))>0) { log.Write(bytes,0,count); log.Flush(); }
        }
        return 0;
    }
}
'@
    $sourcePath = Join-Path $RunRoot 'mouse-recorder.cs'
    [IO.File]::WriteAllText($sourcePath, $fixtureSource)
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe "/out:$RunRoot\mouse-recorder.exe" $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Recorder compilation failed.' }
    $leaf = 'pkg26-' + [guid]::NewGuid().ToString('N')
    $desktop = [HiddenDesktopNative]::CreateDesktopW($leaf, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktopW failed.' }
    [IO.File]::WriteAllText((Join-Path $RunRoot 'desktop.txt'), "WinSta0\$leaf")
    $job = [HiddenDesktopNative]::CreateJobObjectW([IntPtr]::Zero, [NullString]::Value)
    if ($job -eq [IntPtr]::Zero) { throw 'CreateJobObject failed.' }
    try {
        $pwsh = (Get-Command pwsh.exe).Source
        $command = '"{0}" -NoProfile -NonInteractive -File "{1}" -Worker -RunRoot "{2}" -RightClickAction {3}' -f $pwsh, $PSCommandPath, $RunRoot, $RightClickAction
        if ($ObserveBaseline) { $command += ' -ObserveBaseline' }
        $driver = Start-Hidden $pwsh $command $RunRoot "WinSta0\$leaf" $job
        if (-not $driver.WaitForExit(90000)) { Stop-Owned $driver $pwsh $driver.StartTime; throw 'Mouse driver timed out.' }
        $result = Get-Content -Raw -LiteralPath (Join-Path $RunRoot 'result.json') | ConvertFrom-Json
        $result | ConvertTo-Json -Depth 5 | Write-Output
        if ($result.status -ne 'PASS') { throw 'Mouse assertions failed.' }
    }
    finally {
        try {
            $stopped = @([HiddenDesktopNative]::ReapOwnedJob($job))
            [pscustomobject]@{ stoppedPids = $stopped; remainingPids = @([HiddenDesktopNative]::JobPids($job)) } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunRoot 'cleanup.json')
        }
        finally {
            [void][HiddenDesktopNative]::CloseHandle($job)
            [void][HiddenDesktopNative]::CloseDesktop($desktop)
            if ((Get-Fingerprint $realStartup) -ne $before) { throw 'Real startup ledger changed.' }
            [pscustomobject]@{ sourceSha256 = (Get-FileHash -LiteralPath $ExePath).Hash; startup = $before; startupUnchanged = $true } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunRoot 'provenance.json')
        }
    }
    Write-Host 'mouse input: PASS; real startup ledger unchanged'
    return
}

$env:LOCALAPPDATA = Join-Path $RunRoot 'local'
$env:APPDATA = Join-Path $RunRoot 'roaming'
$env:GHOSTTY_RESOURCES_DIR = Join-Path $RunRoot 'share\ghostty'
$marker = Join-Path $RunRoot 'reports'
$exe = Join-Path $RunRoot 'koreterm.exe'
$app = $null
$result = [ordered]@{ status = 'FAIL'; action = $RightClickAction; error = $null; observations = @() }
function Wait-File([string] $Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($app.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw "Marker timeout: $([IO.Path]::GetFileName($Path))" }
        Start-Sleep -Milliseconds 30
    }
}
function Get-ReportOffset {
    if (-not (Test-Path -LiteralPath ($marker + '.bytes'))) { return 0L }
    return (Get-Item -LiteralPath ($marker + '.bytes')).Length
}
function Read-Reports([long] $Offset) {
    if (-not (Test-Path -LiteralPath ($marker + '.bytes'))) { return '' }
    $stream = [IO.File]::Open($marker + '.bytes', 'Open', 'Read', 'ReadWrite')
    try {
        [void]$stream.Seek($Offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream)
        return $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }
}
function Wait-Report([long] $Offset, [string] $Pattern, [string] $EventName) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $report = [regex]::Matches((Read-Reports $Offset), $Pattern) | Select-Object -Last 1
        if ($report) { return $report }
        if ($app.HasExited) { throw "App exited while waiting for $EventName." }
        Start-Sleep -Milliseconds 30
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "No new $EventName report before deadline."
}
function Right-Click([int] $Mods) {
    [HiddenDesktopNative]::Send($surface, 0x204, ($Mods -bor 2), [MouseInputNative]::Position(80,80))
    [void][MouseInputNative]::PostMessageW($surface, 0x205, [UIntPtr]$Mods, [IntPtr][MouseInputNative]::Position(80,80))
    Start-Sleep -Milliseconds 300
    $menu = [HiddenDesktopNative]::TopWindow($app.Id, '#32768')
    if ($menu -ne [IntPtr]::Zero) {
        [void][MouseInputNative]::PostMessageW($hostWindow, 0x1F, [UIntPtr]::Zero, [IntPtr]::Zero)
        [void][MouseInputNative]::PostMessageW($menu, 0x100, [UIntPtr]27, [IntPtr]::Zero)
    }
    Start-Sleep -Milliseconds 200
    return ($menu -ne [IntPtr]::Zero)
}
try {
    $config = Join-Path $RunRoot 'config.ghostty'
    $text = "auto-update = off`nconfirm-close-surface = false`nwindow-save-state = never`nsingle-instance = false`ncopy-on-select = false`nright-click-action = $RightClickAction`n"
    $text += 'command = direct:"' + (Join-Path $RunRoot 'mouse-recorder.exe') + '" "' + $marker + '"' + "`n"
    [IO.File]::WriteAllText($config, $text, [Text.UTF8Encoding]::new($false))
    $app = Start-Hidden $exe ('"' + $exe + '" --config-file="' + $config + '"') $RunRoot ([IO.File]::ReadAllText((Join-Path $RunRoot 'desktop.txt')))
    $appStart = $app.StartTime
    Wait-File ($marker + '.ready')
    $hostWindow = [HiddenDesktopNative]::Host($app.Id)
    $surface = [HiddenDesktopNative]::Surface($hostWindow)
    if ($surface -eq [IntPtr]::Zero) { throw 'Hidden terminal surface missing.' }
    $menuShown = Right-Click 0
    $result.observations += "menu shown before reporting: $menuShown"
    if (-not $ObserveBaseline -and $menuShown -ne ($RightClickAction -eq 'context-menu')) { throw 'right-click-action menu policy failed.' }
    [IO.File]::WriteAllText($marker + '.enable', 'yes')
    Wait-File ($marker + '.enabled')
    Start-Sleep -Milliseconds 250
    $offset = Get-ReportOffset
    [HiddenDesktopNative]::Send($surface, 0x200, 0, [MouseInputNative]::Position(100,100))
    $motionPattern = '\x1b\[<(\d+);(\d+);(\d+)M'
    $firstMotion = Wait-Report $offset $motionPattern 'motion after menu'
    $result.observations += ('motion after menu: ' + $firstMotion.Value.Replace([string][char]27, '<ESC>'))
    # SGR folds Shift/Alt/Ctrl into the button field; the interactive user's
    # modifier state may change independently of our posted hidden messages.
    if (-not $ObserveBaseline -and ([int]$firstMotion.Groups[1].Value -band (-bnot 28)) -ne 35) { throw 'Phantom right drag.' }
    $menuShown = Right-Click 0
    if (-not $ObserveBaseline -and $menuShown) { throw 'Mouse-reporting right click opened a menu.' }
    $menuShown = Right-Click 4
    if (-not $ObserveBaseline -and $menuShown -ne ($RightClickAction -eq 'context-menu')) { throw 'Shift override menu policy failed.' }
    $offset = Get-ReportOffset
    [HiddenDesktopNative]::Send($surface, 0x200, 0, [MouseInputNative]::Position(180,140))
    $lastMotion = Wait-Report $offset $motionPattern 'motion after Shift release'
    if (-not $ObserveBaseline -and ([int]$lastMotion.Groups[1].Value -band (-bnot 28)) -ne 35) { throw 'Shift right release left a pressed button.' }
    if ($lastMotion.Groups[2].Value -eq $firstMotion.Groups[2].Value -and $lastMotion.Groups[3].Value -eq $firstMotion.Groups[3].Value) { throw 'Motion reported the previous position.' }
    foreach ($message in @(0x20A, 0x20E)) {
        # Calibrate the expected cell on this DPI/font, then leave a different
        # cached position so a wheel handler that ignores lParam still fails.
        $x = if ($message -eq 0x20A) { 300 } else { 340 }
        $y = if ($message -eq 0x20A) { 200 } else { 240 }
        $offset = Get-ReportOffset
        [HiddenDesktopNative]::Send($surface, 0x200, 0, [MouseInputNative]::Position($x,$y))
        $expected = Wait-Report $offset $motionPattern 'wheel position calibration'
        $offset = Get-ReportOffset
        [HiddenDesktopNative]::Send($surface, 0x200, 0, [MouseInputNative]::Position(180,140))
        $lastMotion = Wait-Report $offset $motionPattern 'motion before wheel'
        if ($expected.Groups[2].Value -eq $lastMotion.Groups[2].Value -and $expected.Groups[3].Value -eq $lastMotion.Groups[3].Value) { throw 'Wheel calibration did not change the cell.' }
        $point = [MouseInputNative+Point]::new(); $point.x = $x; $point.y = $y
        if (-not [MouseInputNative]::ClientToScreen($surface, [ref]$point)) { throw 'ClientToScreen failed.' }
        $offset = Get-ReportOffset
        [HiddenDesktopNative]::Send($surface, $message, (120 -shl 16), [MouseInputNative]::Position($point.x,$point.y))
        $button = if ($message -eq 0x20A) { 64 } else { 66 }
        $wheel = Wait-Report $offset $motionPattern "wheel $message"
        if (([int]$wheel.Groups[1].Value -band (-bnot 28)) -ne $button) { throw "Wheel $message reported the wrong button." }
        $result.observations += "wheel $message button $button at cell $($wheel.Groups[2].Value),$($wheel.Groups[3].Value)"
        if (-not $ObserveBaseline -and ($wheel.Groups[2].Value -ne $expected.Groups[2].Value -or $wheel.Groups[3].Value -ne $expected.Groups[3].Value)) { throw 'Wheel reported an unexpected position.' }
    }
    $result.status = 'PASS'
}
catch { $result.error = $_.Exception.Message }
finally {
    if ($app -and -not $app.HasExited) {
        [void][MouseInputNative]::PostMessageW([HiddenDesktopNative]::Host($app.Id), 0x10, [UIntPtr]::Zero, [IntPtr]::Zero)
        if (-not $app.WaitForExit(10000)) { Stop-Owned $app $exe $appStart }
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RunRoot 'result.json')
}
if ($result.status -ne 'PASS') { exit 1 }

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
