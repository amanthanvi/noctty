#requires -Version 7.0
# MEASUREMENT ONLY (pacing-stall2): one lat02 probe run with the watchdog
# beside it and forced stacks at -ForceStacksAtMs (not a stall), to prove the
# watchdog finds and pings noctty on the private desktop and to fill the
# symbol cache for noctty's system modules. Not a measurement result.
param([Parameter(Mandatory)][string]$Bin, [Parameter(Mandatory)][string]$Run, [int]$ForceStacksAtMs = 8000, [string]$SymPath)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot; $root = Split-Path -Parent $here
$pwshExe = (Get-Command pwsh.exe).Source
$wdDir = "$Run.wd"; $wdStop = Join-Path $wdDir 'stop'
[void](New-Item -ItemType Directory -Force -Path $wdDir)
$wdArgs = @('-NoProfile','-NonInteractive','-File',(Join-Path $root 'watchdog.ps1'),'-RunDir',$Run,'-BuildBin',$Bin,'-WrapperPid',$PID,'-OutDir',$wdDir,'-StopFile',$wdStop,'-ForceStacksAtMs',$ForceStacksAtMs)
if ($SymPath) { $wdArgs += @('-SymPath',$SymPath) }
$wd = Start-Process -FilePath $pwshExe -ArgumentList $wdArgs -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $wdDir 'wd.out') -RedirectStandardError (Join-Path $wdDir 'wd.err')
$probeArgs = @('-NoProfile','-NonInteractive','-File',(Join-Path $here 'probe.ps1'),'-Bin',$Bin,'-Run',$Run,'-Tool','echo','-VsyncHz',60,'-DelayMs',0,'-Mode','ssh','-Pattern','steady','-Count',240,'-Style','plain','-Seed',100,'-Priority','BelowNormal')
& $pwshExe @probeArgs 2>&1 | Out-File -LiteralPath "$Run.probe.txt"
"probe rc=$LASTEXITCODE"
Set-Content -LiteralPath $wdStop -Value 'stop'
if (-not $wd.WaitForExit(300000)) { "watchdog still running" } else { "watchdog exit=$($wd.ExitCode)" }
