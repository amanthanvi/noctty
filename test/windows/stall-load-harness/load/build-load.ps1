# MEASUREMENT ONLY: compile CpuLoad.cs with Windows PowerShell 5.1 Add-Type (.NET Framework exe).
param([string]$Root = (Join-Path $env:TEMP 'w14\pacing-stall2'))
$ErrorActionPreference = 'Stop'
$cs = Join-Path $Root 'load\CpuLoad.cs'
$hash = (Get-FileHash -LiteralPath $cs -Algorithm SHA256).Hash.Substring(0, 12)
$exe = Join-Path $Root "bin\CpuLoad-$hash.exe"
if (-not (Test-Path -LiteralPath $exe)) { Add-Type -TypeDefinition (Get-Content -LiteralPath $cs -Raw) -OutputAssembly $exe -OutputType ConsoleApplication }
$exe
