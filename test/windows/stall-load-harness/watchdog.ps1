#requires -Version 7.0
<#
MEASUREMENT ONLY (pacing-stall2): stall watchdog for one probe.ps1 run (or the
positive control). Core in StallWatch.cs (compiled once into bin\).

Probe mode (-RunDir, -BuildBin, -WrapperPid): waits for the probe's outer.log
("driver pid=<n> desktop=<name>"), finds the noctty.exe whose parent is that
driver (the driver's parent must be a pwsh.exe whose parent is -WrapperPid,
each created no later than its child), checks its image is <RunDir>\app\bin\noctty.exe
and that file's SHA-256 equals <BuildBin>\noctty.exe's (the probe runs a
portable copy of the build dir), then pings its noctty.win32.host window on
the private desktop.

Control mode (-TargetPid, -Desktop, -ExpectImage): the same on any window
whose class starts with -ClassPrefix.

Every 100 ms: SendMessageTimeoutW(WM_NULL, SMTO_ABORTIFHUNG, 250 ms). The first
unanswered streak that reaches -StallMs (1000) runs
  cdb -pv -p <PID> -y <SymPath> -logo <OutDir>\stacks-1-pid<PID>.log -c "~*kn 40; qd"
and a second one 500 ms after the first exits. Logs only names, PIDs, thread
IDs/states and timings: no command lines, no environment, no window text.
#>
param(
    [string] $RunDir,
    [string] $BuildBin,
    [int] $WrapperPid = 0,
    [int] $TargetPid = 0,
    [string] $Desktop,
    [string] $ExpectImage,
    [string] $ClassPrefix = 'noctty.win32.host',
    [Parameter(Mandatory)] [string] $OutDir,
    [string] $StopFile,
    [string] $ReadyFile,
    [string] $SymPath,
    [int] $StallMs = 1000,
    [int] $PeriodMs = 100,
    [int] $SmtoMs = 250,
    [int] $SlowMs = 100,
    [int] $ForceStacksAtMs = -1,
    [int] $WaitSeconds = 1200
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cs = Join-Path $root 'StallWatch.cs'
$hash = (Get-FileHash -LiteralPath $cs -Algorithm SHA256).Hash.Substring(0, 12)
$dll = Join-Path $root "bin\StallWatch-$hash.dll"
if (-not (Test-Path -LiteralPath $dll)) { Add-Type -Path $cs -OutputAssembly $dll -OutputType Library }
Add-Type -Path $dll
[void](New-Item -ItemType Directory -Force -Path $OutDir)
$log = Join-Path $OutDir 'watchdog.log'
function Say([string]$m) { [IO.File]::AppendAllText($log, ("{0} {1:HH:mm:ss.fff} PS {2}`r`n" -f [Diagnostics.Stopwatch]::GetTimestamp(), (Get-Date), $m)) }
(Get-Process -Id $PID).PriorityClass = 'Normal'
$cdb = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path -LiteralPath $cdb)) { throw "no cdb at $cdb" }
$symCache = Join-Path $root 'sym'

function Stopped { return ($StopFile -and (Test-Path -LiteralPath $StopFile)) }

if ($RunDir) {
    $RunDir = [IO.Path]::GetFullPath($RunDir)
    $BuildBin = (Resolve-Path -LiteralPath $BuildBin).Path
    if (-not $SymPath) { $SymPath = "srv*$symCache;$RunDir\app\bin;$BuildBin" }
    Say ("probe mode run={0} build={1} wrapper_pid={2}" -f $RunDir, $BuildBin, $WrapperPid)
    $outer = Join-Path $RunDir 'outer.log'
    $deadline = (Get-Date).AddSeconds($WaitSeconds); $driverPid = 0; $Desktop = $null
    while ((Get-Date) -lt $deadline -and -not (Stopped)) {
        if (Test-Path -LiteralPath $outer) {
            $m = [regex]::Match((Get-Content -LiteralPath $outer -Raw -ErrorAction SilentlyContinue), 'driver pid=(\d+) desktop=(\S+)')
            if ($m.Success) { $driverPid = [int]$m.Groups[1].Value; $Desktop = $m.Groups[2].Value; break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $driverPid) { Say 'no driver line in outer.log (probe never started or stop file); exiting'; exit 2 }
    if (-not $Desktop.StartsWith('noctty-notrun-', [StringComparison]::Ordinal)) { Say "unexpected desktop name $Desktop"; exit 2 }
    $expect = Join-Path $RunDir 'app\bin\noctty.exe'
    $buildHash = (Get-FileHash -LiteralPath (Join-Path $BuildBin 'noctty.exe') -Algorithm SHA256).Hash
    $deadline = (Get-Date).AddSeconds(60); $target = $null
    while ((Get-Date) -lt $deadline -and -not (Stopped)) {
        $snap = [W14Stall.Snap]::Take(0)
        $drv = $snap.P[[uint32]$driverPid]
        if ($drv) {
            $kids = @($snap.P.Values | Where-Object { $_.Name -eq 'noctty.exe' -and $_.Ppid -eq [uint32]$driverPid -and $_.Create -ge $drv.Create })
            if ($kids.Count -eq 1) { $target = $kids[0]; break }
            if ($kids.Count -gt 1) { Say ("{0} noctty.exe children of the driver; refusing to guess" -f $kids.Count); exit 2 }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $target) { Say 'noctty.exe child of the driver not found; exiting'; exit 2 }
    $outerProc = $snap.P[[uint32]$drv.Ppid]
    $chainOk = $outerProc -and $outerProc.Name -eq 'pwsh.exe' -and $drv.Name -eq 'pwsh.exe' -and $outerProc.Create -le $drv.Create -and ($WrapperPid -eq 0 -or $outerProc.Ppid -eq [uint32]$WrapperPid)
    $img = $null; $created = [long]0
    if (-not [W14Stall.N]::Identity($target.Pid, [ref]$img, [ref]$created)) { Say 'target identity unavailable'; exit 2 }
    $imgHash = (Get-FileHash -LiteralPath $img -Algorithm SHA256).Hash
    $drvLog = Join-Path $RunDir 'driver.log'; $logged = $null
    for ($i = 0; $i -lt 50 -and -not $logged; $i++) {
        if (Test-Path -LiteralPath $drvLog) { $mm = [regex]::Match((Get-Content -LiteralPath $drvLog -Raw -ErrorAction SilentlyContinue), 'noctty pid=(\d+)'); if ($mm.Success) { $logged = [int]$mm.Groups[1].Value } }
        if (-not $logged) { Start-Sleep -Milliseconds 100 }
    }
    Say ("tree: wrapper={0} -> probe outer {1}:{2} -> driver {3}:{4} -> target {5}:{6} created={7} chain_ok={8} driver_log_pid={9}" -f $WrapperPid, $drv.Ppid, $(if ($outerProc) { $outerProc.Name } else { '?' }), $driverPid, $drv.Name, $target.Pid, $target.Name, $created, $chainOk, $logged)
    Say ("image={0} expected={1} path_ok={2} sha256_matches_build={3}" -f $img, $expect, [string]::Equals($img, $expect, [StringComparison]::OrdinalIgnoreCase), ($imgHash -eq $buildHash))
    if (-not $chainOk -or -not [string]::Equals($img, $expect, [StringComparison]::OrdinalIgnoreCase) -or $imgHash -ne $buildHash -or ($logged -and $logged -ne [int]$target.Pid)) { Say 'identity check FAILED; not watching'; exit 2 }
    $TargetPid = [int]$target.Pid
} else {
    if (-not $TargetPid -or -not $Desktop -or -not $ExpectImage) { throw 'control mode needs -TargetPid, -Desktop and -ExpectImage' }
    if (-not $SymPath) { $SymPath = "srv*$symCache" }
    $img = $null; $created = [long]0
    if (-not [W14Stall.N]::Identity([uint32]$TargetPid, [ref]$img, [ref]$created)) { Say 'target identity unavailable'; exit 2 }
    Say ("control mode target={0} image={1} expected={2} desktop={3}" -f $TargetPid, $img, $ExpectImage, $Desktop)
    if (-not [string]::Equals($img, $ExpectImage, [StringComparison]::OrdinalIgnoreCase)) { Say 'image mismatch; not watching'; exit 2 }
}
Say ("symbol path: {0}" -f $SymPath)
$w = [W14Stall.Watch]::new()
$w.LogPath = $log; $w.OutDir = $OutDir; $w.Desktop = $Desktop; $w.ClassPrefix = $ClassPrefix
$w.CdbPath = $cdb; $w.SymPath = $SymPath; $w.StopFile = $StopFile; $w.ReadyFile = $ReadyFile
$w.TargetPid = [uint32]$TargetPid; $w.TargetCreate = $created; $w.TargetImage = $img
$w.PeriodMs = $PeriodMs; $w.SmtoMs = $SmtoMs; $w.SlowMs = $SlowMs; $w.StallMs = $StallMs; $w.ForceStacksAtMs = $ForceStacksAtMs
$rc = $w.Run()
exit $rc
