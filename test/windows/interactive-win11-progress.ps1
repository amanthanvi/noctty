param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 20
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-progress.ps1'
try {


$ErrorActionPreference = 'Stop'
# Poll cadence while waiting for progress-window evidence.
$script:PROGRESS_POLL_MS = 100
# Settling delay before the taskbar progress capture.
$script:PROGRESS_CAPTURE_SETTLE_MS = 500

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

$forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
if ($Rebuild) { $forwardedArgs += '-Rebuild' }
if ($ResetState) { $forwardedArgs += '-ResetState' }
Invoke-InteractiveWin11HarnessMain `
    -RepoRoot $repoRoot `
    -LauncherPath $launcherPath `
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_PROGRESS_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class NocttyWin32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

}
'@

enum InteractiveWin11ProgressCaptureKind {
    Set
    Pause
    Error
    Busy
    Remove
}

class InteractiveWin11ProgressCapture {
    [InteractiveWin11ProgressCaptureKind] $Kind
    [string] $Marker
    [string] $Screenshot
    # The saved screenshot, or empty when the privacy gate withheld it.
    [string] $Saved
    [string] $Note

    InteractiveWin11ProgressCapture(
        [InteractiveWin11ProgressCaptureKind] $Kind,
        [string] $Marker,
        [string] $Screenshot
    ) {
        if ([string]::IsNullOrWhiteSpace($Marker)) { throw 'Marker is required.' }
        if ([string]::IsNullOrWhiteSpace($Screenshot)) { throw 'Screenshot is required.' }

        $this.Kind = $Kind
        $this.Marker = $Marker
        $this.Screenshot = $Screenshot
    }

    [string] Name() {
        return $this.Kind.ToString().ToLowerInvariant()
    }
}

function Assert-Win32CallSucceeded {
    param(
        [Parameter(Mandatory)] [bool] $Succeeded,
        [Parameter(Mandatory)] [string] $Operation
    )

    if (-not $Succeeded) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "$Operation failed with Win32 error $lastError"
    }
}

function Show-ProgressHarnessWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    [void] [NocttyWin32]::ShowWindow($Hwnd, 9)
    [void] [NocttyWin32]::SetForegroundWindow($Hwnd)
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'progress' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-progress-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-progress-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-progress.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-progress-payload.ps1'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
progress-style = true
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

$markerSet = Join-Path $layout.Temp 'progress-state-set.marker'
$markerPause = Join-Path $layout.Temp 'progress-state-pause.marker'
$markerError = Join-Path $layout.Temp 'progress-state-error.marker'
$markerBusy = Join-Path $layout.Temp 'progress-state-busy.marker'
$markerRemove = Join-Path $layout.Temp 'progress-state-remove.marker'
Remove-Item -LiteralPath $markerSet, $markerPause, $markerError, $markerBusy, $markerRemove -ErrorAction SilentlyContinue

@"
`$stdout = [Console]::OpenStandardOutput()

function Send-Bytes([byte[]]`$bytes) {
    `$stdout.Write(`$bytes, 0, `$bytes.Length)
    `$stdout.Flush()
}

function Mark-State([string]`$path) {
    Set-Content -LiteralPath `$path -Value 'ok' -Encoding ASCII
}

Mark-State '$markerSet'
# ESC ] 9 ; 4 ; 1 ; 50 BEL: set progress to 50%.
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x31,0x3b,0x35,0x30,0x07))
Start-Sleep -Seconds 2

Mark-State '$markerPause'
# ESC ] 9 ; 4 ; 4 ; 50 BEL: pause progress at 50%.
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x34,0x3b,0x35,0x30,0x07))
Start-Sleep -Seconds 2

Mark-State '$markerError'
# ESC ] 9 ; 4 ; 2 ; 50 BEL: mark progress as error at 50%.
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x32,0x3b,0x35,0x30,0x07))
Start-Sleep -Seconds 2

Mark-State '$markerBusy'
# ESC ] 9 ; 4 ; 3 BEL: switch progress to indeterminate.
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x33,0x07))
Start-Sleep -Seconds 2

Mark-State '$markerRemove'
# ESC ] 9 ; 4 ; 0 ; BEL: clear progress.
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x30,0x3b,0x07))
Start-Sleep -Seconds 3
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha256.Dispose()
    }
}

# Whether two saved screenshots differ, or 'unknown' when either was withheld.
function Compare-ProgressScreenshots {
    param(
        [Parameter(Mandatory)] [InteractiveWin11ProgressCapture] $First,
        [Parameter(Mandatory)] [InteractiveWin11ProgressCapture] $Second
    )

    if ([string]::IsNullOrEmpty($First.Saved) -or [string]::IsNullOrEmpty($Second.Saved)) { return 'unknown' }
    return (Get-FileSha256 -Path $First.Saved) -ne (Get-FileSha256 -Path $Second.Saved)
}

$screenshots = [ordered]@{
    set = Join-Path $layout.Logs 'interactive-win11-progress-window-set.png'
    pause = Join-Path $layout.Logs 'interactive-win11-progress-window-pause.png'
    error = Join-Path $layout.Logs 'interactive-win11-progress-window-error.png'
    busy = Join-Path $layout.Logs 'interactive-win11-progress-window-busy.png'
    remove = Join-Path $layout.Logs 'interactive-win11-progress-window-remove.png'
}
Remove-Item -LiteralPath $screenshots.Values -ErrorAction SilentlyContinue
# Earlier versions also saved bottom-of-screen strips here.
Remove-Item -Path (Join-Path $layout.Logs 'interactive-win11-progress-bottom-strip-*.png') -ErrorAction SilentlyContinue

[InteractiveWin11ProgressCapture[]] $states = @(
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Set, $markerSet, $screenshots.set)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Pause, $markerPause, $screenshots.pause)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Error, $markerError, $screenshots.error)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Busy, $markerBusy, $screenshots.busy)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Remove, $markerRemove, $screenshots.remove)
)

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$runtimeFailurePattern = 'taskbar progress init failed|taskbar progress sync failed|panic: reached unreachable code'

$launchArgs = @(
    Get-InteractiveWin11ContainmentArguments
    '--single-instance=false'
    "--class=noctty-progress-$($layout.SandboxId)"
    "--config-file=$configPath"
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
)

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne 0) {
            Assert-Win32CallSucceeded `
                -Succeeded ([NocttyWin32]::MoveWindow($process.MainWindowHandle, 80, 80, 1000, 720, $true)) `
                -Operation "MoveWindow(hwnd=$($process.MainWindowHandle))"
            Show-ProgressHarnessWindow -Hwnd $process.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds $script:PROGRESS_POLL_MS
    }

    if ($process.MainWindowHandle -eq 0) {
        throw 'noctty main window handle was not ready before timeout.'
    }

    foreach ($state in $states) {
        $stateName = $state.Name()
        $stateDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(4, $TimeoutSeconds))
        $stateReached = $false
        while ([DateTime]::UtcNow -lt $stateDeadline) {
            if (Test-Path -LiteralPath $state.Marker) {
                Show-ProgressHarnessWindow -Hwnd $process.MainWindowHandle
                Start-Sleep -Milliseconds $script:PROGRESS_CAPTURE_SETTLE_MS
                # Diagnostic only, and saved only where it shows noctty alone.
                $shot = Save-StatefulScreenCapture -Hwnd $process.MainWindowHandle -Path $state.Screenshot
                $state.Saved = $shot.Path
                $state.Note = $shot.Note
                if ($null -eq $shot.Path) {
                    Write-Host "interactive-win11 progress: screenshot for state '$stateName' not saved ($($shot.Note))"
                }
                $stateReached = $true
                break
            }

            $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
            if ($stderr -match $runtimeFailurePattern) {
                throw "unexpected runtime failure reported in stderr while waiting for state '$stateName'"
            }

            if ($process.HasExited) {
                throw "noctty exited before state '$stateName' was captured (exit code $($process.ExitCode))"
            }

            Start-Sleep -Milliseconds $script:PROGRESS_POLL_MS
        }

        if (-not $stateReached) {
            throw "progress state '$stateName' was not reached before timeout"
        }
    }

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "unexpected runtime failure reported in stderr:`n$stderr"
    }

    $visualSetVsRemoveDistinct = Compare-ProgressScreenshots -First $states[0] -Second $states[4]
    $visualPauseVsErrorDistinct = Compare-ProgressScreenshots -First $states[1] -Second $states[2]
    $savedScreenshots = @($states | Where-Object { -not [string]::IsNullOrEmpty($_.Saved) }).Count
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}

Write-Host "interactive-win11 progress validation: PASS (stderr=$stderrPath, set-vs-remove-distinct=$visualSetVsRemoveDistinct, pause-vs-error-distinct=$visualPauseVsErrorDistinct, screenshots-saved=$savedScreenshots/$($states.Count), set=$($screenshots.set), remove=$($screenshots.remove))"

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
