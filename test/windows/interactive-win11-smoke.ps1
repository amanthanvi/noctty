param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_SMOKE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_SMOKE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'smoke' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

$launchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout)
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-smoke-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-smoke-stderr.log'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$successPattern = 'started subcommand path='
$failurePattern = 'error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$smokePassed = $false
$closePassed = $false
$failureReason = $null

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250

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
            $failureReason = "winghostty exited before shell startup was observed (exit code $($process.ExitCode))"
            break
        }
    }

    if ($smokePassed) {
        $closeTimeoutSeconds = [Math]::Max(5, $TimeoutSeconds)
        $closeDeadline = [DateTime]::UtcNow.AddSeconds($closeTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $closeDeadline) {
            $process.Refresh()
            if ($process.HasExited) {
                $failureReason = "winghostty exited before exposing a main window handle for WM_CLOSE validation (exit code $($process.ExitCode))"
                break
            }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                break
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $failureReason -and $process.MainWindowHandle -eq [IntPtr]::Zero) {
            $failureReason = 'winghostty never exposed a main window handle for WM_CLOSE validation'
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
                Wait-InteractiveWin11Until -Deadline $closeDeadline -Description 'winghostty smoke graceful exit' -Condition {
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
                        $failureReason = "winghostty exited after WM_CLOSE but exit code could not be read: $($_.Exception.Message)"
                    }
                }

                if (-not $failureReason -and $exitCode -ne 0) {
                    $failureReason = "winghostty exited after WM_CLOSE with exit code $exitCode"
                }
                elseif (-not $failureReason) {
                    $closePassed = $true
                }
            }
            catch {
                $failureReason = "winghostty graceful-close validation failed: $($_.Exception.Message)"
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
