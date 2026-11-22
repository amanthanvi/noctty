param(
    [ValidateRange(5, 90)] [int] $TimeoutSeconds = 30,
    [switch] $NoKey
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

if (-not $env:NOCTTY_GUI_HIDDEN_DESKTOP -or -not $env:NOCTTY_THREAD_ROLE_DUMP) {
    throw 'The role-pairs leaf requires the hidden runner and its dump directory.'
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'role-pairs'
$layout = $harness.Layout
$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$launchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout) + @('--confirm-close-surface=false')

# cmd expands $E to ESC and $G to >. Its prompt changes the host title through the PTY,
# so seeing the private marker proves shell output reached noctty before the key is posted.
$promptTitle = 'noctty-role-prompt-' + $layout.SandboxId
$env:PROMPT = '$E]2;' + $promptTitle + '$E\$G'
$process = Start-InteractiveWin11HostedProcess -FilePath $exePath -ArgumentList $launchArgs -WorkingDirectory $repoRoot `
    -RedirectStandardError (Join-Path $layout.Logs 'role-pairs-stderr.log')
$processHandle = $process.Handle
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'role-pairs cmd prompt' -Process $process -Condition {
        $hosts = @([InteractiveWin11HostedLaunch]::HostWindows($process.Id))
        $hosts.Count -eq 1 -and [InteractiveWin11HostedLaunch]::HostTitleContains($hosts[0], $process.Id, $promptTitle) -and
            @([InteractiveWin11HostedLaunch]::SurfaceWindows($hosts[0], $process.Id)).Count -eq 1
    }

    $hosts = @([InteractiveWin11HostedLaunch]::HostWindows($process.Id))
    if ($hosts.Count -ne 1) { throw 'The role-pairs host disappeared or is ambiguous.' }
    $surfaces = @([InteractiveWin11HostedLaunch]::SurfaceWindows($hosts[0], $process.Id))
    if ($surfaces.Count -ne 1) { throw 'The role-pairs terminal surface disappeared or is ambiguous.' }

    if (-not $NoKey) {
        Invoke-InteractiveWin11PostLetter -Hwnd $surfaces[0] -VirtualKey 0x41 -Deadline $deadline -Process $process
    }
    Start-Sleep -Seconds 2

    $closeDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-InteractiveWin11PostMessage -Hwnd $hosts[0] -Message 0x0010 -Deadline $closeDeadline -Description 'role-pairs WM_CLOSE' -Process $process
    Wait-InteractiveWin11Until -Deadline $closeDeadline -Description 'role-pairs graceful exit' -Condition { $process.HasExited }
    $code = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
    if ($code -ne 0) { throw "The role-pairs copy exited with code $code." }
}
finally {
    # The runner owns the job, including cleanup on a timeout.
    $process.Dispose()
}
