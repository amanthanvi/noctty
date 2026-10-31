#requires -Version 7.0
<#
MEASUREMENT ONLY: interleaved A/B batches of the four renderer scratch
measurements (renderer.md 2026-10-15 PKG-37 and LAT-02), on private desktops
through probe.ps1, then per-side medians/p95 and per-pair differences
(analyze/report.py).

  held          PKG-37 (1): held.exe 200 ms x 10 cycles, emulated 60 Hz      (results-G G-held-v60)
  expose        PKG-37 (1): held.exe 200 x 10, child invalidated every 50 ms  (G-held-expose, real swaps)
  expose-saver  the same under --power-saver-rendering=on                     (G-held-expose-saver)
  saver60       PKG-37 (2): anim.exe 60 fps x 10 s, saver pacing, emulated 60 Hz (G-anim-saver-v60)
  lat02         LAT-02: lat-echo d0 ssh steady, 240 keys, emulated 60 Hz      (results.txt F-v60 d0-ssh-steady)

Both sides must be trace-patched builds (notrun\builds\<name>-rf-lt\bin): the
measurements read the measurement-only latency trace, which a stock build
does not have. Order is A,B per pair (A/B/A/B), or A,B then B,A with
-Alternate. At least 5 pairs unless -Validation (then the report is labelled
a validation run, not results).

usage (the lead's final batch, once the machine is quiet):
  pwsh -NoProfile -File runner.ps1 -Measurement all -Pairs 5
#>
[CmdletBinding()]
param(
    # held, expose, expose-saver, saver60, lat02 or all; comma-separated works through pwsh -File.
    [string[]] $Measurement = @('all'),
    [int] $Pairs = 5,
    [string] $A = (Join-Path $env:TEMP 'w14\notrun\builds\main-rf-lt\bin'),
    [string] $ALabel = 'main',
    [string] $B = (Join-Path $env:TEMP 'w14\notrun\builds\pacing-rf-lt\bin'),
    [string] $BLabel = 'pacing',
    [string] $Name = ('batch-' + (Get-Date -Format 'yyyyMMdd-HHmmss')),
    [string] $OutRoot = (Join-Path $env:TEMP 'w14\notrun\runs'),
    [switch] $Alternate,
    [switch] $Validation,
    # Quiet gate: before each run, wait until whole-machine CPU busy over a 3 s
    # sample is below this (0 disables), for at most QuietMaxWaitSeconds; a run
    # that starts without meeting it is logged LOADED (its load.json has the
    # busy % over the run either way).
    [int] $QuietBelowPct = 30,
    [int] $QuietMaxWaitSeconds = 900,
    # BelowNormal is the original drivers' class; Normal/AboveNormal are for validation on a loaded machine.
    [ValidateSet('BelowNormal','Normal','AboveNormal')] [string] $Priority = 'BelowNormal'
)
$ErrorActionPreference = 'Stop'
$Measurement = @($Measurement | ForEach-Object { $_.Split(',') })
if ($Measurement -contains 'all') { $Measurement = @('held','expose','expose-saver','saver60','lat02') }
foreach ($m in $Measurement) { if ($m -notin @('held','expose','expose-saver','saver60','lat02')) { throw "unknown measurement '$m'" } }
if ($Pairs -lt 5 -and -not $Validation) { throw 'A batch needs at least 5 pairs per measurement (or -Validation).' }
$here = $PSScriptRoot
$probe = Join-Path $here 'probe.ps1'
$metrics = Join-Path $here 'analyze\metrics.py'
$report = Join-Path $here 'analyze\report.py'
$python = (Get-Command python.exe).Source

function Assert-TraceBuild([string]$Bin) {
    $exe = Join-Path $Bin 'noctty.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "no noctty.exe in $Bin" }
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
    if (-not $text.Contains('NOCTTY_LATENCY_TRACE_FILE') -or -not $text.Contains('NOCTTY_LAT_VSYNC_HZ')) {
        throw "$Bin is not a trace-patched build (no NOCTTY_LATENCY_TRACE_FILE / NOCTTY_LAT_VSYNC_HZ); build it with scratch\build-all.sh"
    }
}
Assert-TraceBuild $A
Assert-TraceBuild $B

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class NrLoad {
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
    public static double BusyPct(int ms) {
        long i0,k0,u0,i1,k1,u1; GetSystemTimes(out i0,out k0,out u0); System.Threading.Thread.Sleep(ms); GetSystemTimes(out i1,out k1,out u1);
        double total=(k1-k0)+(u1-u0); return total<=0?0:100.0*(1-(i1-i0)/total);
    }
}
'@
function Wait-Quiet {
    if ($QuietBelowPct -le 0) { return 'gate off' }
    $deadline = (Get-Date).AddSeconds($QuietMaxWaitSeconds); $busy = 100
    while ($true) {
        $busy = [NrLoad]::BusyPct(3000)
        if ($busy -lt $QuietBelowPct) { return ('quiet {0:n0}%' -f $busy) }
        if ((Get-Date) -ge $deadline) { return ('LOADED {0:n0}% after {1} s' -f $busy, $QuietMaxWaitSeconds) }
    }
}

# Parameters per measurement, as the original matrices ran them.
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
    Validation=[bool]$Validation; Priority=$Priority; QuietBelowPct=$QuietBelowPct; Started=(Get-Date).ToString('o') } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $batch 'batch.json')
$logFile = Join-Path $batch 'runner.log'
function Say([string]$m) { $line = "{0:HH:mm:ss} {1}" -f (Get-Date), $m; Add-Content -LiteralPath $logFile -Value $line; Write-Host $line }
Say ("batch {0}: A={1} ({2}) B={3} ({4}) pairs={5} order={6}{7}" -f $Name,$ALabel,$A,$BLabel,$B,$Pairs,$order,$(if($Validation){' VALIDATION'}else{''}))

foreach ($m in $Measurement) {
    $s = $spec[$m]
    $mdir = Join-Path $batch $m
    [void](New-Item -ItemType Directory -Force -Path $mdir)
    for ($p = 1; $p -le $Pairs; $p++) {
        $sides = @('A','B'); if ($Alternate -and ($p % 2 -eq 0)) { $sides = @('B','A') }
        foreach ($side in $sides) {
            $bin = if ($side -eq 'A') { $A } else { $B }
            $run = Join-Path $mdir "$side-p$p"
            $probeArgs = @('-NoProfile','-NonInteractive','-File',$probe,'-Bin',$bin,'-Run',$run,'-Tool',$s.Tool,'-VsyncHz',$s.VsyncHz)
            if ($s.Tool -eq 'echo') {
                # matrix.ps1: seed = rep * 100 + scenario index; both sides of a pair share the key schedule.
                $probeArgs += @('-DelayMs',$s.DelayMs,'-Mode',$s.Mode,'-Pattern',$s.Pattern,'-Count',$s.Count,'-Style',$s.Style,'-Seed',($p * 100))
            } else {
                $probeArgs += @('-A1',$s.A1,'-A2',$s.A2,'-InvalidateMs',$s.InvalidateMs)
            }
            if ($s.Extra.Count -gt 0) { $probeArgs += @('-Extra',$s.Extra[0]) }
            $probeArgs += @('-Priority',$Priority)
            $gate = Wait-Quiet
            $t0 = Get-Date
            & pwsh @probeArgs 2>&1 | Out-File -LiteralPath (Join-Path $mdir "$side-p$p.probe.txt")
            $rc = $LASTEXITCODE
            $probeOut = Get-Content -LiteralPath (Join-Path $mdir "$side-p$p.probe.txt") -Raw -ErrorAction SilentlyContinue
            if ($rc -ne 0) {
                Say ("FAILED {0} {1}-p{2} rc={3} ({4:n0} s)" -f $m,$side,$p,$rc,((Get-Date)-$t0).TotalSeconds)
                if ($probeOut -match 'stop launches') { Say 'real user state guard tripped: stopping the batch'; throw "guard tripped in $run" }
                continue
            }
            $line = & $python -I $metrics $run --json (Join-Path $run 'metrics.json')
            Say ("{0} {1}-p{2} [{3}] ({4:n0} s, gate: {5}) {6}" -f $m,$side,$p,$(if($side -eq 'A'){$ALabel}else{$BLabel}),((Get-Date)-$t0).TotalSeconds,$gate,($line -join ' '))
        }
    }
}
& $python -I $report $batch | Out-Null
Say "report: $(Join-Path $batch 'report.txt')"
Get-Content -LiteralPath (Join-Path $batch 'report.txt') | Write-Host
