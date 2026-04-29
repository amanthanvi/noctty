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
    "set PATH=$exeDir;%PATH%"
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
        throw "Expected +boo to emit substantial frame output; rendered_byte_count=$($booTrace.rendered_byte_count)"
    }
    if ($renderTrace.paint_draw_count -lt 250) {
        throw "Expected visible paint cadence to stay well above the prior stalled path; paint_draw_count=$($renderTrace.paint_draw_count)"
    }
    if ($renderTrace.max_paint_gap_ms -gt 300) {
        throw "Expected visible paint gaps to stay below the prior choppy path; max_paint_gap_ms=$($renderTrace.max_paint_gap_ms)"
    }
    if ($termioTrace.process_output_count -lt 140) {
        throw "Expected steady PTY output batches for +boo; process_output_count=$($termioTrace.process_output_count)"
    }
    if ($booTrace.frame_change_count -lt 140) {
        throw "Expected +boo child animation to advance near full rate; frame_change_count=$($booTrace.frame_change_count)"
    }

    Write-Host "interactive-win11 boo performance validation: PASS (updates=$($renderTrace.renderer_update_frame_count), paints=$($renderTrace.paint_draw_count), frames=$($booTrace.frame_change_count), bytes=$($booTrace.rendered_byte_count))"
}
finally {
    foreach ($entry in $savedEnv.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable(
            [string] $entry.Key,
            [string] $entry.Value,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    if ($null -ne $process) {
        Stop-InteractiveWin11Process -Process $process
    }
}
