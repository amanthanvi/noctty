#requires -Version 7.0
<#
MEASUREMENT ONLY (pacing-stall2): a copy of notrun\scratch\runner.ps1 with
three changes, nothing else in the measurements changed:
  1. Quiet gate: before each run, wait until whole-machine CPU busy (GetSystemTimes,
     1 s samples) is under -QuietBelowPct (25) for -QuietSeconds (10) consecutive
     seconds. Every wait is logged to quiet.log (each sample; top 3 processes by
     CPU, name and PID only, whenever a sample is over the bar). A run is never
     started without the gate; past -Deadline the batch stops instead.
  2. Build sentinel: during waits and around each run, any process whose image is
     a build tool (zig, cl, link, lld-link, clang, rustc, cargo, msbuild, cmake,
     ninja) that was not there before is logged by name, PID, parent PID and
     start time (no command lines).
  3. watchdog.ps1 runs beside each probe (started before the gate, stopped after
     the probe), logging into <measurement>\<side>-p<k>.wd\.
Runs go to pacing-stall2\runs\<Name> (probe.ps1 copy here refuses anything else).
#>
[CmdletBinding()]
param(
    [string[]] $Measurement = @('lat02'),
    [int] $Pairs = 20,
    [string] $A = (Join-Path $env:TEMP 'w14\notrun\builds\main-cur-rf-lt\bin'),
    [string] $ALabel = 'main-cur',
    [string] $B = (Join-Path $env:TEMP 'w14\notrun\builds\pacing-cur-rf-lt\bin'),
    [string] $BLabel = 'pacing-cur',
    [Parameter(Mandatory)] [string] $Name,
    [string] $OutRoot = (Join-Path $env:TEMP 'w14\pacing-stall2\runs'),
    [switch] $Alternate,
    [int] $QuietBelowPct = 25,
    [int] $QuietSeconds = 10,
    [datetime] $Deadline = (Get-Date).AddHours(3),
    [ValidateSet('BelowNormal','Normal','AboveNormal')] [string] $Priority = 'BelowNormal',
    [switch] $NoWatchdog
)
$ErrorActionPreference = 'Stop'
$Measurement = @($Measurement | ForEach-Object { $_.Split(',') })
foreach ($m in $Measurement) { if ($m -notin @('held','expose','expose-saver','saver60','lat02')) { throw "unknown measurement '$m'" } }
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$probe = Join-Path $here 'probe.ps1'
$metrics = Join-Path $here 'analyze\metrics.py'
$report = Join-Path $here 'analyze\report.py'
$watchdog = Join-Path $root 'watchdog.ps1'
$python = (Get-Command python.exe).Source
$pwshExe = (Get-Command pwsh.exe).Source
$dll = Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Filter 'StallWatch-*.dll' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Add-Type -Path $dll.FullName

function Assert-TraceBuild([string]$Bin) {
    $exe = Join-Path $Bin 'noctty.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "no noctty.exe in $Bin" }
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
    if (-not $text.Contains('NOCTTY_LATENCY_TRACE_FILE') -or -not $text.Contains('NOCTTY_LAT_VSYNC_HZ')) { throw "$Bin is not a trace-patched build" }
}
Assert-TraceBuild $A
Assert-TraceBuild $B

$spec = @{
    'held'         = @{ Tool='held'; A1=200; A2=10; VsyncHz=60; InvalidateMs=0;  Extra=@() }
    'expose'       = @{ Tool='held'; A1=200; A2=10; VsyncHz=0;  InvalidateMs=50; Extra=@() }
    'expose-saver' = @{ Tool='held'; A1=200; A2=10; VsyncHz=0;  InvalidateMs=50; Extra=@('--power-saver-rendering=on') }
    'saver60'      = @{ Tool='anim'; A1=60;  A2=10; VsyncHz=60; InvalidateMs=0;  Extra=@('--power-saver-rendering=on') }
    'lat02'        = @{ Tool='echo'; DelayMs=0; Mode='ssh'; Pattern='steady'; Count=240; Style='plain'; VsyncHz=60; Extra=@() }
}

$batch = Join-Path $OutRoot $Name
if (Test-Path -LiteralPath $batch) { throw "batch dir exists: $batch" }
[void](New-Item -ItemType Directory -Force -Path $batch)
$order = if ($Alternate) { 'ABBA' } else { 'ABAB' }
[ordered]@{ Sides=@{ A=$ALabel; B=$BLabel }; Bins=@{ A=$A; B=$B }; Measurements=$Measurement; Pairs=$Pairs; Order=$order;
    Validation=$false; Priority=$Priority; QuietBelowPct=$QuietBelowPct; QuietSeconds=$QuietSeconds; Watchdog=(-not $NoWatchdog);
    Started=(Get-Date).ToString('o'); RunnerPid=$PID } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $batch 'batch.json')
$logFile = Join-Path $batch 'runner.log'
$quietLog = Join-Path $batch 'quiet.log'
function Say([string]$m) { $line = "{0:HH:mm:ss} {1}" -f (Get-Date), $m; Add-Content -LiteralPath $logFile -Value $line; Write-Host $line }
function QSay([string]$m) { Add-Content -LiteralPath $quietLog -Value ("{0} {1:HH:mm:ss.fff} {2}" -f [Diagnostics.Stopwatch]::GetTimestamp(), (Get-Date), $m) }

$buildNames = @('zig.exe','cl.exe','link.exe','lld-link.exe','clang.exe','clang++.exe','clang-cl.exe','rustc.exe','cargo.exe','msbuild.exe','MSBuild.exe','cmake.exe','ninja.exe')
$buildSeen = @{}
function Check-Builds([object]$snap, [string]$where) {
    foreach ($p in $snap.P.Values) {
        if ($buildNames -notcontains $p.Name) { continue }
        $key = '{0}-{1}' -f $p.Pid, $p.Create
        if ($buildSeen.ContainsKey($key)) { continue }
        $buildSeen[$key] = $true
        $parent = $snap.P[$p.Ppid]
        $msg = 'BUILD PROCESS {0} pid={1} ppid={2} parent={3} created={4:o} seen_at={5}' -f $p.Name, $p.Pid, $p.Ppid, $(if ($parent) { $parent.Name } else { '?' }), [datetime]::FromFileTime($p.Create), $where
        Say $msg; QSay $msg
    }
}
$snap0 = [W14Stall.Snap]::Take(0)
foreach ($p in $snap0.P.Values) { if ($buildNames -contains $p.Name) { $buildSeen['{0}-{1}' -f $p.Pid, $p.Create] = $true; QSay ('build tool already running at batch start: {0} pid={1}' -f $p.Name, $p.Pid) } }

function SysTimes { $i = 0L; $k = 0L; $u = 0L; [void][W14Stall.N]::GetSystemTimes([ref]$i, [ref]$k, [ref]$u); return @($i, $k, $u) }
function Wait-Quiet([string]$label) {
    $t0 = Get-Date; $ok = 0; $n = 0; $max = 0.0
    QSay "wait start for $label (need $QuietSeconds consecutive 1 s samples under $QuietBelowPct%)"
    $prevSnap = [W14Stall.Snap]::Take(0); $prevT = SysTimes
    while ($true) {
        if ((Get-Date) -ge $Deadline) { QSay "DEADLINE reached while waiting for $label"; return $null }
        Start-Sleep -Milliseconds 1000
        $t = SysTimes; $idle = $t[0] - $prevT[0]; $tot = ($t[1] - $prevT[1]) + ($t[2] - $prevT[2]); $prevT = $t
        $busy = if ($tot -le 0) { 0 } else { 100.0 * (1 - $idle / $tot) }
        $snap = [W14Stall.Snap]::Take(0); $tc = 0.0
        $top = [W14Stall.Snap]::Top($prevSnap, $snap, 3, [ref]$tc, 0); $prevSnap = $snap
        Check-Builds $snap "wait:$label"
        $n++
        if ($busy -lt $QuietBelowPct) { $ok++; QSay ('sample busy={0:n0}% ok={1} | {2}' -f $busy, $ok, $top) }
        else { if ($busy -gt $max) { $max = $busy }; $ok = 0; QSay ('sample busy={0:n0}% OVER | {1}' -f $busy, $top) }
        if ($ok -ge $QuietSeconds) { $s = ((Get-Date) - $t0).TotalSeconds; QSay ('wait end for {0}: {1:n0} s, {2} samples, max over-bar {3:n0}%' -f $label, $s, $n, $max); return ('quiet after {0:n0} s' -f $s) }
    }
}

Say ("batch {0}: A={1} ({2}) B={3} ({4}) pairs={5} order={6} gate=<{7}% for {8} s deadline={9:HH:mm} watchdog={10}" -f $Name,$ALabel,$A,$BLabel,$B,$Pairs,$order,$QuietBelowPct,$QuietSeconds,$Deadline,(-not $NoWatchdog))
$stop = $false
foreach ($m in $Measurement) {
    if ($stop) { break }
    $s = $spec[$m]
    $mdir = Join-Path $batch $m
    [void](New-Item -ItemType Directory -Force -Path $mdir)
    for ($p = 1; $p -le $Pairs -and -not $stop; $p++) {
        $sides = @('A','B'); if ($Alternate -and ($p % 2 -eq 0)) { $sides = @('B','A') }
        foreach ($side in $sides) {
            $bin = if ($side -eq 'A') { $A } else { $B }
            $run = Join-Path $mdir "$side-p$p"
            $probeArgs = @('-NoProfile','-NonInteractive','-File',$probe,'-Bin',$bin,'-Run',$run,'-Tool',$s.Tool,'-VsyncHz',$s.VsyncHz)
            if ($s.Tool -eq 'echo') {
                $probeArgs += @('-DelayMs',$s.DelayMs,'-Mode',$s.Mode,'-Pattern',$s.Pattern,'-Count',$s.Count,'-Style',$s.Style,'-Seed',($p * 100))
            } else {
                $probeArgs += @('-A1',$s.A1,'-A2',$s.A2,'-InvalidateMs',$s.InvalidateMs)
            }
            if ($s.Extra.Count -gt 0) { $probeArgs += @('-Extra',$s.Extra[0]) }
            $probeArgs += @('-Priority',$Priority)
            $wd = $null; $wdDir = Join-Path $mdir "$side-p$p.wd"; $wdStop = Join-Path $wdDir 'stop'
            if (-not $NoWatchdog) {
                [void](New-Item -ItemType Directory -Force -Path $wdDir)
                $wdArgs = @('-NoProfile','-NonInteractive','-File',$watchdog,'-RunDir',$run,'-BuildBin',$bin,'-WrapperPid',$PID,'-OutDir',$wdDir,'-StopFile',$wdStop)
                $wd = Start-Process -FilePath $pwshExe -ArgumentList $wdArgs -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $wdDir 'wd.out') -RedirectStandardError (Join-Path $wdDir 'wd.err')
            }
            $gate = Wait-Quiet "$m $side-p$p"
            if (-not $gate) {
                Say "DEADLINE: stopping before $m $side-p$p (gate never met)"
                if ($wd) { Set-Content -LiteralPath $wdStop -Value 'stop'; [void]$wd.WaitForExit(30000) }
                $stop = $true; break
            }
            Check-Builds ([W14Stall.Snap]::Take(0)) "before:$m $side-p$p"
            $t0 = Get-Date
            & $pwshExe @probeArgs 2>&1 | Out-File -LiteralPath (Join-Path $mdir "$side-p$p.probe.txt")
            $rc = $LASTEXITCODE
            Check-Builds ([W14Stall.Snap]::Take(0)) "after:$m $side-p$p"
            $wdSummary = ''
            if ($wd) {
                Set-Content -LiteralPath $wdStop -Value 'stop'
                if (-not $wd.WaitForExit(240000)) { Say "watchdog pid=$($wd.Id) still running 240 s after the probe (left alone)" }
                $wl = Join-Path $wdDir 'watchdog.log'
                if (Test-Path -LiteralPath $wl) {
                    $sum = Select-String -LiteralPath $wl -Pattern ' SUMMARY ' | Select-Object -Last 1
                    $wdSummary = if ($sum) { ($sum.Line -split ' SUMMARY ', 2)[1] } else { 'no SUMMARY (see watchdog.log)' }
                    if (Select-String -LiteralPath $wl -Pattern ' TRIGGER ' -Quiet) { $wdSummary += ' STACKS-TAKEN' }
                }
            }
            $probeOut = Get-Content -LiteralPath (Join-Path $mdir "$side-p$p.probe.txt") -Raw -ErrorAction SilentlyContinue
            if ($rc -ne 0) {
                Say ("FAILED {0} {1}-p{2} rc={3} ({4:n0} s) wd: {5}" -f $m,$side,$p,$rc,((Get-Date)-$t0).TotalSeconds,$wdSummary)
                if ($probeOut -match 'stop launches') { Say 'real user state guard tripped: stopping the batch'; throw "guard tripped in $run" }
                continue
            }
            $line = & $python -I $metrics $run --json (Join-Path $run 'metrics.json')
            Say ("{0} {1}-p{2} [{3}] ({4:n0} s, gate: {5}) {6} | wd: {7}" -f $m,$side,$p,$(if($side -eq 'A'){$ALabel}else{$BLabel}),((Get-Date)-$t0).TotalSeconds,$gate,($line -join ' '),$wdSummary)
        }
    }
}
& $python -I $report $batch | Out-Null
Say "report: $(Join-Path $batch 'report.txt')"
