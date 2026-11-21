param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 10
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-smoke.ps1'
try {


$ErrorActionPreference = 'Stop'
# Poll cadence while waiting for smoke-test output.
$script:SMOKE_POLL_MS = 100
# Retry delay after transient smoke-test startup failures.
$script:SMOKE_RETRY_MS = 250

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
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_SMOKE_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'smoke' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

# WM_CLOSE follows startup closely, possibly before the shell's first prompt,
# and a window whose terminal is not at a prompt asks before closing.
$launchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout) + @('--confirm-close-surface=false')
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-smoke-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-smoke-stderr.log'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

# Hosted mode starts the copy through the hosted launcher (scripts/interactive-win11-lib.ps1), never Start-Process.
$process = if ($env:NOCTTY_GUI_HIDDEN_DESKTOP) {
    Start-InteractiveWin11HostedProcess -FilePath $exePath -ArgumentList $launchArgs -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
}
else {
    Start-Process `
        -FilePath $exePath `
        -ArgumentList $launchArgs `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
}

$successPattern = 'started subcommand path='
$failurePattern = 'error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$smokePassed = $false
$closePassed = $false
$closeDelivered = $false
$failureReason = $null

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds $script:SMOKE_RETRY_MS

        $stderr = Get-InteractiveWin11TextFile -Path $stderrPath

        if ($stderr.Contains($successPattern)) {
            $smokePassed = $true
            break
        }

        if ($stderr.Contains($failurePattern)) {
            $failureReason = 'terminal startup failure detected in stderr log'
            break
        }

        if ($process.HasExited) {
            $failureReason = "noctty exited before shell startup was observed (exit code $($process.ExitCode))"
            break
        }
    }

    if ($smokePassed -and $env:NOCTTY_GUI_HIDDEN_DESKTOP) {
        # Hosted mode: on a private desktop MainWindowHandle can be the system's input-indicator overlay, which a
        # WM_CLOSE does not close, so the close goes to the one host window found by class. No host, more than one,
        # or a send that fails fails the leaf, whatever the process does afterwards: a clean exit without a delivered
        # WM_CLOSE is not a close handshake (Sol on #740).
        $closeDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $TimeoutSeconds))
        $hostWindows = @()
        while ([DateTime]::UtcNow -lt $closeDeadline) {
            $process.Refresh()
            if ($process.HasExited) { break }
            $hostWindows = @([InteractiveWin11HostedLaunch]::HostWindows($process.Id))
            if ($hostWindows.Count -eq 1) { break }
            Start-Sleep -Milliseconds $script:SMOKE_POLL_MS
        }
        if ($process.HasExited) {
            $failureReason = "noctty exited before its host window took WM_CLOSE (exit code $($process.ExitCode))"
        }
        elseif ($hostWindows.Count -ne 1) {
            $failureReason = "noctty showed $($hostWindows.Count) host windows, not one, for WM_CLOSE"
        }
        else {
            $processHandle = $process.Handle
            try {
                [void](Invoke-InteractiveWin11Message `
                    -Hwnd $hostWindows[0] `
                    -Message 0x0010 `
                    -Deadline $closeDeadline `
                    -Description 'WM_CLOSE smoke validation' `
                    -Flags $script:InteractiveWin11SmtoBlock `
                    -Process $process)
                $closeDelivered = $true
            }
            catch {
                $failureReason = "WM_CLOSE was not delivered to the host window: $($_.Exception.Message)"
            }
            if ($closeDelivered) {
                $closeProcess = $process
                try {
                    Wait-InteractiveWin11Until -Deadline $closeDeadline -Description 'noctty smoke graceful exit' -Condition {
                        $closeProcess.Refresh()
                        $closeProcess.HasExited
                    }
                    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
                    if ($exitCode -ne 0) { $failureReason = "noctty exited after WM_CLOSE with exit code $exitCode" }
                    else { $closePassed = $true }
                }
                catch {
                    $failureReason = "noctty graceful-close validation failed: $($_.Exception.Message)"
                }
            }
        }
    }
    elseif ($smokePassed) {
        $closeTimeoutSeconds = [Math]::Max(5, $TimeoutSeconds)
        $closeDeadline = [DateTime]::UtcNow.AddSeconds($closeTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $closeDeadline) {
            $process.Refresh()
            if ($process.HasExited) {
                $failureReason = "noctty exited before exposing a main window handle for WM_CLOSE validation (exit code $($process.ExitCode))"
                break
            }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                break
            }
            Start-Sleep -Milliseconds $script:SMOKE_POLL_MS
        }

        if (-not $failureReason -and $process.MainWindowHandle -eq [IntPtr]::Zero) {
            $failureReason = 'noctty never exposed a main window handle for WM_CLOSE validation'
        }
        elseif (-not $failureReason) {
            $processHandle = $process.Handle
            try {
                try {
                    [void](Invoke-InteractiveWin11Message `
                        -Hwnd $process.MainWindowHandle `
                        -Message 0x0010 `
                        -Deadline $closeDeadline `
                        -Description 'WM_CLOSE smoke validation' `
                        -Flags $script:InteractiveWin11SmtoBlock `
                        -Process $process)
                }
                catch {
                    $sendError = $_
                    $process.Refresh()
                    if (-not $process.HasExited) {
                        throw $sendError
                    }
                }
                $closeProcess = $process
                Wait-InteractiveWin11Until -Deadline $closeDeadline -Description 'noctty smoke graceful exit' -Condition {
                    $closeProcess.Refresh()
                    $closeProcess.HasExited
                }
                $process.Refresh()
                $exitCode = $process.ExitCode

                # In the dev-windows bootstrap shell, GUI child ExitCode can stay null after WaitForExit.
                if ($null -eq $exitCode) {
                    try {
                        $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
                    }
                    catch {
                        $failureReason = "noctty exited after WM_CLOSE but exit code could not be read: $($_.Exception.Message)"
                    }
                }

                if (-not $failureReason -and $exitCode -ne 0) {
                    $failureReason = "noctty exited after WM_CLOSE with exit code $exitCode"
                }
                elseif (-not $failureReason) {
                    $closePassed = $true
                }
            }
            catch {
                $failureReason = "noctty graceful-close validation failed: $($_.Exception.Message)"
            }
        }
    }
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}

if (-not $smokePassed -or -not $closePassed) {
    if (-not $failureReason) {
        $failureReason = "timed out after $TimeoutSeconds seconds waiting for initial shell startup"
    }

    $stderrTail = Get-InteractiveWin11TextFileTail -Path $stderrPath -LineCount 40

    throw @"
interactive Win11 smoke test failed: $failureReason
stderr log: $stderrPath
stdout log: $stdoutPath

Recent stderr:
$stderrTail
"@
}

Write-Host "interactive-win11 smoke test: PASS ($stderrPath)"

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
