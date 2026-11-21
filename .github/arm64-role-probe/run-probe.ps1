# TEMPORARY (PLAN.md §2.7 RQ16, step 1A.2(d), lead decision 12 of 1A.2): probe-r14 run once on the hosted
# windows-11-arm runner. A PowerShell port of zig017\probe-r14\run_probe.sh: build probe14_015.zig with Zig 0.15.2
# and probe14_017.zig with Zig 0.17.1, Debug and ReleaseSafe, each with its own global and local cache; run each
# build twice in record mode (once normally, once crashing after it acquires, each with its own dump file); then a
# separate process symbolises each dump. Nothing of noctty is built. Removed with its workflow in the next commit.
param(
    [Parameter(Mandatory)][string] $Zig015,
    [Parameter(Mandatory)][string] $Zig017,
    [Parameter(Mandatory)][string] $Out
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$here = $PSScriptRoot
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Invoke-Logged([System.Collections.Generic.List[string]] $Lines, [string] $Exe, [string[]] $Arguments) {
    $ErrorActionPreference = 'Continue'
    $text = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    foreach ($t in $text) { $Lines.Add($t) }
    return $code
}

$failed = $false
foreach ($v in '0.15.2', '0.17.1') {
    $zig = if ($v -eq '0.15.2') { $Zig015 } else { $Zig017 }
    $src = if ($v -eq '0.15.2') { 'probe14_015.zig' } else { 'probe14_017.zig' }
    foreach ($m in 'Debug', 'ReleaseSafe') {
        $dir = Join-Path $Out "out-$v-$m"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("# zig $v, -O $m, source $src, PROCESSOR_ARCHITECTURE $env:PROCESSOR_ARCHITECTURE; caches under out-$v-$m")
        $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $dir 'global'
        $env:ZIG_LOCAL_CACHE_DIR = Join-Path $dir 'local'
        $exe = Join-Path $dir 'probe.exe'
        Push-Location $dir
        try {
            $code = Invoke-Logged $lines $zig @('build-exe', (Join-Path $here $src), '-O', $m, "-femit-bin=$exe")
            $lines.Add("# build exit: $code")
            if ($code -ne 0) { $failed = $true; continue }
            Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in '.exe', '.pdb' } |
                ForEach-Object { $lines.Add("# artefact: $($_.Name)") }
            foreach ($run in 'normal', 'crash') {
                $dump = Join-Path $dir "dump-$run.txt"
                Remove-Item -LiteralPath $dump -Force -ErrorAction SilentlyContinue
                $env:PROBE_DUMP = $dump
                if ($run -eq 'crash') { $env:PROBE_CRASH = '1' } else { Remove-Item Env:PROBE_CRASH -ErrorAction SilentlyContinue }
                $rec = [System.Collections.Generic.List[string]]::new()
                $code = Invoke-Logged $rec $exe @()
                Remove-Item Env:PROBE_CRASH -ErrorAction SilentlyContinue
                [System.IO.File]::WriteAllLines((Join-Path $dir "record-$run.out"), $rec)
                $pairs = if (Test-Path -LiteralPath $dump) { @(Get-Content -LiteralPath $dump | Where-Object { $_ -and -not $_.StartsWith('#') }).Count } else { 0 }
                $lines.Add("# record ($run) exit: $code; $pairs pairs in its dump")
                if ($run -eq 'crash') {
                    $hit = $rec | Select-String -SimpleMatch 'probe: crash after acquiring' | Select-Object -First 1
                    if ($hit) { $lines.Add('# record (crash) panicked: probe: crash after acquiring') }
                }
                $lines.Add("# symbolised by a separate process from dump-$run.txt:")
                $env:PROBE_MODE = 'symbolise'
                $code = Invoke-Logged $lines $exe @()
                Remove-Item Env:PROBE_MODE -ErrorAction SilentlyContinue
                $lines.Add("# symbolise exit: $code")
                if ($code -ne 0) { $failed = $true }
            }
        }
        finally {
            Pop-Location
            Remove-Item Env:PROBE_DUMP, Env:PROBE_MODE, Env:PROBE_CRASH -ErrorAction SilentlyContinue
            $log = Join-Path $Out "probe-$v-$m.txt"
            [System.IO.File]::WriteAllLines($log, $lines)
            Write-Host "===== probe-$v-$m.txt"
            $lines | ForEach-Object { Write-Host $_ }
        }
    }
}
if ($failed) { exit 1 }
