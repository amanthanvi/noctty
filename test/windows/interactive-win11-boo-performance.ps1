param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 25
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_BOO_PERF_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_BOO_PERF_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

if (-not ('InteractiveWin11BooPerfNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class InteractiveWin11BooPerfNative {
    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'boo-performance' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

$exeDir = Split-Path -Parent $exePath
$payloadPath = Join-Path $layout.Temp 'interactive-win11-boo-performance.cmd'
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-boo-performance-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-boo-performance-stderr.log'
$renderTracePath = Join-Path $layout.Temp 'interactive-win11-boo-performance-render.json'
$termioTracePath = Join-Path $layout.Temp 'interactive-win11-boo-performance-termio.json'
$booTracePath = Join-Path $layout.Temp 'interactive-win11-boo-performance-boo.json'

@(
    '@echo off'
    "set `"PATH=$exeDir;%PATH%`""
    'winghostty +boo'
) | Set-Content -LiteralPath $payloadPath -Encoding ASCII

$traceEnv = [ordered]@{
    WINGHOSTTY_RENDER_TRACE_FILE = $renderTracePath
    WINGHOSTTY_TERMIO_TRACE_FILE = $termioTracePath
    WINGHOSTTY_BOO_STATE_FILE = $booTracePath
    WINGHOSTTY_BOO_AUTO_EXIT_MS = '5000'
}

$savedEnv = [ordered]@{}
foreach ($entry in $traceEnv.GetEnumerator()) {
    $savedEnv[[string] $entry.Key] = [System.Environment]::GetEnvironmentVariable([string] $entry.Key, 'Process')
    [System.Environment]::SetEnvironmentVariable([string] $entry.Key, [string] $entry.Value, 'Process')
}

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $renderTracePath, $termioTracePath, $booTracePath -ErrorAction SilentlyContinue

$process = $null
$processHandle = [IntPtr]::Zero
try {
    $process = Start-Process `
        -FilePath $exePath `
        -ArgumentList @(
            '--single-instance=false'
            "--class=winghostty-boo-performance-$($layout.SandboxId)"
            '-e'
            'cmd.exe'
            '/d'
            '/c'
            $payloadPath
        ) `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    $processHandle = $process.Handle
    Show-InteractiveWin11ProcessMainWindow `
        -Process $process `
        -NativeTypeName 'InteractiveWin11BooPerfNative' `
        -SetForeground

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "winghostty +boo timed out after $TimeoutSeconds seconds"
    }

    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
    if ($exitCode -ne 0) {
        throw @"
winghostty +boo exited with code $exitCode
stdout:
$(Get-InteractiveWin11TextFileTail -Path $stdoutPath)

stderr:
$(Get-InteractiveWin11TextFileTail -Path $stderrPath)
"@
    }

    $renderTrace = Get-InteractiveWin11RequiredJsonFile -Path $renderTracePath
    $termioTrace = Get-InteractiveWin11RequiredJsonFile -Path $termioTracePath
    $booTrace = Get-InteractiveWin11RequiredJsonFile -Path $booTracePath

    if ($booTrace.rendered_byte_count -lt 200000) {
        throw "Expected +boo to emit substantial frame output (expected >= 200000, got $($booTrace.rendered_byte_count))"
    }
    if ($renderTrace.paint_draw_count -lt 250) {
        throw "Expected visible paint cadence to stay well above the prior stalled path (expected >= 250, got $($renderTrace.paint_draw_count))"
    }
    $requiredRenderTraceFields = @(
        'max_paint_gap_ms',
        'max_paint_gap_ended_at_ms',
        'max_sustained_paint_gap_ms',
        'max_sustained_paint_gap_ended_at_ms',
        'max_paint_draw_duration_ms',
        'max_paint_draw_duration_at_ms',
        'first_paint_at_ms'
    )
    foreach ($field in $requiredRenderTraceFields) {
        if ($null -eq $renderTrace.PSObject.Properties[$field]) {
            throw "Render trace is missing required field '$field'"
        }
    }

    $startupWindowMs = 1000
    $startupDrawLeadMs = 250
    $startupPaintGapLimitMs = 750
    $startupPaintStartMs = $renderTrace.max_paint_gap_ended_at_ms - $renderTrace.max_paint_gap_ms
    $startupPaintGap =
        $renderTrace.max_paint_gap_ended_at_ms -le $startupWindowMs -and
        $renderTrace.max_paint_gap_ms -eq $renderTrace.max_paint_draw_duration_ms -and
        $renderTrace.max_paint_gap_ended_at_ms -eq $renderTrace.max_paint_draw_duration_at_ms -and
        $startupPaintStartMs -ge $renderTrace.first_paint_at_ms -and
        $startupPaintStartMs - $renderTrace.first_paint_at_ms -le $startupDrawLeadMs
    if ($renderTrace.max_paint_gap_ms -gt 300 -and -not $startupPaintGap) {
        throw "Expected visible paint gaps to stay below the prior choppy path (expected <= 300, got $($renderTrace.max_paint_gap_ms))"
    }
    if ($startupPaintGap -and $renderTrace.max_paint_gap_ms -gt $startupPaintGapLimitMs) {
        throw "Startup paint initialization gap exceeded the hard ceiling (expected <= $startupPaintGapLimitMs, got $($renderTrace.max_paint_gap_ms))"
    }
    if ($renderTrace.max_paint_gap_ms -gt 300 -and $startupPaintGap) {
        Write-Warning "Ignoring startup paint initialization gap ($($renderTrace.max_paint_gap_ms) ms at $($renderTrace.max_paint_gap_ended_at_ms) ms); enforcing sustained paint gap <= 300 ms after $startupWindowMs ms."
    }
    if ($renderTrace.max_sustained_paint_gap_ms -gt 300) {
        throw "Expected sustained visible paint gaps after startup to stay below the prior choppy path (expected <= 300, got $($renderTrace.max_sustained_paint_gap_ms) at $($renderTrace.max_sustained_paint_gap_ended_at_ms) ms)"
    }
    if ($termioTrace.process_output_count -lt 140) {
        throw "Expected steady PTY output batches for +boo (expected >= 140, got $($termioTrace.process_output_count))"
    }
    if ($booTrace.frame_change_count -lt 140) {
        throw "Expected +boo child animation to advance near full rate (expected >= 140, got $($booTrace.frame_change_count))"
    }

    Write-Host "interactive-win11 boo performance validation: PASS (updates=$($renderTrace.renderer_update_frame_count), paints=$($renderTrace.paint_draw_count), frames=$($booTrace.frame_change_count), bytes=$($booTrace.rendered_byte_count))"
}
finally {
    foreach ($entry in $savedEnv.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable(
            [string] $entry.Key,
            $entry.Value,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    if ($null -ne $process) {
        Stop-InteractiveWin11Process -Process $process
    }
}
