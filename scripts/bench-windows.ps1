#requires -Version 5.1
<#
.SYNOPSIS
  Cold-start + working-set harness for winghostty on Windows (C01).

.DESCRIPTION
  Starts winghostty.exe, waits for the first top-level host HWND, records
  elapsed ms and working set, then closes the process. Writes JSON under
  .sandbox\win11\bench\. Does not fail on PRODUCT.md budget miss until a
  same-machine baseline exists.
#>
[CmdletBinding()]
param(
    [string]$Exe = "",
    [int]$Runs = 3,
    [int]$TimeoutMs = 15000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Exe) {
    $Exe = Join-Path $repoRoot "zig-out\bin\winghostty.exe"
}
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "bench-windows: exe not found: $Exe (build first with scripts/dev-windows.cmd zig build)"
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BenchWin32 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

function Test-HostHwnd {
    param([int]$ProcessId)
    $found = $false
    $cb = [BenchWin32+EnumProc] {
        param([IntPtr]$hwnd, [IntPtr]$lParam)
        $procId = 0
        [void][BenchWin32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
        if ($procId -ne $ProcessId) { return $true }
        if (-not [BenchWin32]::IsWindowVisible($hwnd)) { return $true }
        $sb = New-Object System.Text.StringBuilder 256
        [void][BenchWin32]::GetClassNameW($hwnd, $sb, $sb.Capacity)
        if ($sb.ToString() -eq "winghostty.win32.host") {
            $script:found = $true
            return $false
        }
        return $true
    }
    [void][BenchWin32]::EnumWindows($cb, [IntPtr]::Zero)
    return $found
}

$outDir = Join-Path $repoRoot ".sandbox\win11\bench"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$samples = @()

for ($i = 1; $i -le $Runs; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Exe -ArgumentList @("--class=bench-windows") -PassThru
    $ready = $false
    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-HostHwnd -ProcessId $p.Id) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 20
    }
    $sw.Stop()
    $ws = 0
    try {
        $p.Refresh()
        $ws = $p.WorkingSet64
    } catch {}
    $samples += [pscustomobject]@{
        run = $i
        cold_start_ms = [int]$sw.Elapsed.TotalMilliseconds
        working_set_bytes = $ws
        hwnd_ready = $ready
    }
    try {
        if (-not $p.HasExited) { $p.Kill() }
        $p.WaitForExit(5000) | Out-Null
    } catch {}
    Start-Sleep -Milliseconds 300
}

$json = $samples | ConvertTo-Json -Depth 4
$path = Join-Path $outDir ("cold-start-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
Set-Content -LiteralPath $path -Value $json -Encoding utf8
Write-Host "BENCH_OK path=$path runs=$Runs"
$samples | Format-Table -AutoSize
