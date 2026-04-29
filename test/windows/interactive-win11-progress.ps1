param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_PROGRESS_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_PROGRESS_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WinghosttyWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

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
    [string] $BottomStrip

    InteractiveWin11ProgressCapture(
        [InteractiveWin11ProgressCaptureKind] $Kind,
        [string] $Marker,
        [string] $Screenshot,
        [string] $BottomStrip
    ) {
        if ([string]::IsNullOrWhiteSpace($Marker)) { throw 'Marker is required.' }
        if ([string]::IsNullOrWhiteSpace($Screenshot)) { throw 'Screenshot is required.' }
        if ([string]::IsNullOrWhiteSpace($BottomStrip)) { throw 'BottomStrip is required.' }

        $this.Kind = $Kind
        $this.Marker = $Marker
        $this.Screenshot = $Screenshot
        $this.BottomStrip = $BottomStrip
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

    [void] [WinghosttyWin32]::ShowWindow($Hwnd, 9)
    [void] [WinghosttyWin32]::SetForegroundWindow($Hwnd)
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'progress' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

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

function Capture-WindowImage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path
    )

    $rect = New-Object WinghosttyWin32+RECT
    if (-not [WinghosttyWin32]::GetWindowRect($Hwnd, [ref] $rect)) {
        throw "GetWindowRect failed for hwnd=$Hwnd"
    }

    $width = [Math]::Max(1, $rect.Right - $rect.Left)
    $height = [Math]::Max(1, $rect.Bottom - $rect.Top)
    $bmp = New-Object System.Drawing.Bitmap $width, $height
    try {
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
        }
        finally {
            $gfx.Dispose()
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bmp.Dispose()
    }
}

function Capture-PrimaryScreenBottomStrip {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $Height = 220
    )

    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $captureHeight = [Math]::Min($Height, $bounds.Height)
    $top = $bounds.Bottom - $captureHeight
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $captureHeight
    try {
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gfx.CopyFromScreen($bounds.Left, $top, 0, 0, $bmp.Size)
        }
        finally {
            $gfx.Dispose()
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bmp.Dispose()
    }
}

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

$screenshots = [ordered]@{
    set = Join-Path $layout.Logs 'interactive-win11-progress-window-set.png'
    pause = Join-Path $layout.Logs 'interactive-win11-progress-window-pause.png'
    error = Join-Path $layout.Logs 'interactive-win11-progress-window-error.png'
    busy = Join-Path $layout.Logs 'interactive-win11-progress-window-busy.png'
    remove = Join-Path $layout.Logs 'interactive-win11-progress-window-remove.png'
}
$bottomStrips = [ordered]@{
    set = Join-Path $layout.Logs 'interactive-win11-progress-bottom-strip-set.png'
    pause = Join-Path $layout.Logs 'interactive-win11-progress-bottom-strip-pause.png'
    error = Join-Path $layout.Logs 'interactive-win11-progress-bottom-strip-error.png'
    busy = Join-Path $layout.Logs 'interactive-win11-progress-bottom-strip-busy.png'
    remove = Join-Path $layout.Logs 'interactive-win11-progress-bottom-strip-remove.png'
}
Remove-Item -LiteralPath $screenshots.Values, $bottomStrips.Values -ErrorAction SilentlyContinue

[InteractiveWin11ProgressCapture[]] $states = @(
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Set, $markerSet, $screenshots.set, $bottomStrips.set)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Pause, $markerPause, $screenshots.pause, $bottomStrips.pause)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Error, $markerError, $screenshots.error, $bottomStrips.error)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Busy, $markerBusy, $screenshots.busy, $bottomStrips.busy)
    [InteractiveWin11ProgressCapture]::new([InteractiveWin11ProgressCaptureKind]::Remove, $markerRemove, $screenshots.remove, $bottomStrips.remove)
)

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$runtimeFailurePattern = 'taskbar progress init failed|taskbar progress sync failed|panic: reached unreachable code'

$launchArgs = @(
    '--single-instance=false'
    "--class=winghostty-progress-$($layout.SandboxId)"
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
                -Succeeded ([WinghosttyWin32]::MoveWindow($process.MainWindowHandle, 80, 80, 1000, 720, $true)) `
                -Operation "MoveWindow(hwnd=$($process.MainWindowHandle))"
            Show-ProgressHarnessWindow -Hwnd $process.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 100
    }

    if ($process.MainWindowHandle -eq 0) {
        throw 'winghostty main window handle was not ready before timeout.'
    }

    foreach ($state in $states) {
        $stateName = $state.Name()
        $stateDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(4, $TimeoutSeconds))
        while ([DateTime]::UtcNow -lt $stateDeadline) {
            if (Test-Path -LiteralPath $state.Marker) {
                Show-ProgressHarnessWindow -Hwnd $process.MainWindowHandle
                Start-Sleep -Milliseconds 500
                Capture-WindowImage -Hwnd $process.MainWindowHandle -Path $state.Screenshot
                Capture-PrimaryScreenBottomStrip -Path $state.BottomStrip
                break
            }

            $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
            if ($stderr -match $runtimeFailurePattern) {
                throw "unexpected runtime failure reported in stderr while waiting for state '$stateName'"
            }

            if ($process.HasExited) {
                throw "winghostty exited before state '$stateName' was captured (exit code $($process.ExitCode))"
            }

            Start-Sleep -Milliseconds 100
        }

        if (-not (Test-Path -LiteralPath $state.Screenshot)) {
            throw "failed to capture screenshot for state '$stateName'"
        }
        if (-not (Test-Path -LiteralPath $state.BottomStrip)) {
            throw "failed to capture bottom strip for state '$stateName'"
        }
    }

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "unexpected runtime failure reported in stderr:`n$stderr"
    }

    $setHash = Get-FileSha256 -Path $screenshots.set
    $pauseHash = Get-FileSha256 -Path $screenshots.pause
    $errorHash = Get-FileSha256 -Path $screenshots.error
    $removeHash = Get-FileSha256 -Path $screenshots.remove
    $visualSetVsRemoveDistinct = $setHash -ne $removeHash
    $visualPauseVsErrorDistinct = $pauseHash -ne $errorHash

    $bottomStripSetHash = Get-FileSha256 -Path $bottomStrips.set
    $bottomStripPauseHash = Get-FileSha256 -Path $bottomStrips.pause
    $bottomStripErrorHash = Get-FileSha256 -Path $bottomStrips.error
    $bottomStripRemoveHash = Get-FileSha256 -Path $bottomStrips.remove
    $bottomStripSetVsRemoveDistinct = $bottomStripSetHash -ne $bottomStripRemoveHash
    $bottomStripPauseVsErrorDistinct = $bottomStripPauseHash -ne $bottomStripErrorHash
}
finally {
    Stop-InteractiveWin11Process -Process $process
}

Write-Host "interactive-win11 progress validation: PASS (stderr=$stderrPath, set-vs-remove-distinct=$visualSetVsRemoveDistinct, pause-vs-error-distinct=$visualPauseVsErrorDistinct, bottom-strip-set-vs-remove-distinct=$bottomStripSetVsRemoveDistinct, bottom-strip-pause-vs-error-distinct=$bottomStripPauseVsErrorDistinct, set=$($screenshots.set), remove=$($screenshots.remove), bottom-strip-set=$($bottomStrips.set), bottom-strip-remove=$($bottomStrips.remove))"
