[CmdletBinding()]
param([switch]$Rebuild, [switch]$ResetState, [int]$TimeoutSeconds = 30)
$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
$launcher = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_SESSION_RESTORE_BOOTSTRAPPED) {
    $args = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $args += '-Rebuild' }; if ($ResetState) { $args += '-ResetState' }
    $code = 0
    Invoke-InteractiveWin11Bootstrap -RepoRoot $repoRoot -LauncherPath $launcher -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_SESSION_RESTORE_BOOTSTRAPPED' -ArgumentList $args -ExitCode ([ref]$code)
    exit $code
}
. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')
$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'session-restore' -ResetState:$ResetState
$layout = $harness.Layout
$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
if ((Get-InteractiveWin11LaunchAction -ExePath $exe -Rebuild:$Rebuild -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot)) -eq 'build') { Invoke-InteractiveWin11Build -RepoRoot $repoRoot }
Assert-InteractiveWin11ExeExists -ExePath $exe
$stateDir = Join-Path $layout.LocalAppData 'winghostty'; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$configPath = Join-Path $stateDir 'config.ghostty'
$config = "window-save-state = always`r`nconfirm-close-surface = false`r`n"
[IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
$statePath = Join-Path $stateDir 'session-state.json'
$runs = [Collections.Generic.List[object]]::new()
$instanceClass = "winghostty-interactive-$($layout.SandboxId)"
function Get-SessionAutomationSnapshot([string]$Name, [DateTime]$Deadline) {
    $cli = Join-Path (Split-Path -Parent $exe) 'winghostty.com'
    if (-not (Test-Path -LiteralPath $cli)) { throw "Missing automation CLI shim: $cli" }
    $lastError = ''
    foreach ($attempt in 1..3) {
        $out = Join-Path $layout.Logs "$Name-$attempt.json"
        $err = Join-Path $layout.Logs "$Name-$attempt.stderr.log"
        $query = Start-Process -FilePath $cli -ArgumentList @('+list-windows', "--class=$instanceClass") -WorkingDirectory $repoRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        $queryHandle = $query.Handle
        $remainingMs = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $query.WaitForExit($remainingMs)) {
            Stop-InteractiveWin11Process -Process $query
            $lastError = "automation query process did not exit before the story deadline"
            continue
        }
        $query.Refresh()
        $queryExitCode = Get-InteractiveWin11ProcessExitCode -Process $query -ProcessHandle $queryHandle
        if ($queryExitCode -ne 0) {
            $lastError = if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) { "exit ${queryExitCode}: $(Get-Content $err -Raw)" } else { "exit $queryExitCode" }
            Start-Sleep -Milliseconds 250
            continue
        }
        if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { return Get-Content $out -Raw | ConvertFrom-Json }
        $lastError = if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) { Get-Content $err -Raw } else { 'empty stdout' }
        Start-Sleep -Milliseconds 250
    }
    throw "Session automation query failed after three attempts: $lastError"
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $first = Start-StatefulApp $layout $exe $repoRoot 'session-save' @('--single-instance=true'); $runs.Add($first)
    $hostHwnd = Wait-StatefulHost $first $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'initial session-save tab' -Process $first.Process -Condition { (Get-StatefulTabCount $hostHwnd) -eq 1 }
    $null = Invoke-InteractiveWin11Message -Hwnd $hostHwnd -Message 0 -Deadline $deadline -Description 'initial session-save host readiness barrier' -Process $first.Process
    foreach ($targetTabCount in 2..3) {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        Invoke-StatefulPostedCommand $hostHwnd 1904 $deadline $first.Process
        Wait-InteractiveWin11Until -Deadline $deadline -Description "live tab count $targetTabCount" -Process $first.Process -Condition {
            (Get-StatefulTabCount $hostHwnd) -eq $targetTabCount
        }
        $null = Invoke-InteractiveWin11Message -Hwnd $hostHwnd -Message 0 -Deadline $deadline -Description "live tab $targetTabCount readiness barrier" -Process $first.Process
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-StatefulButton $hostHwnd 1001 $deadline $first.Process
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Close-StatefulHost $hostHwnd $first $deadline
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'session-state file' -Condition { Test-Path $statePath }
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($saved.windows[0].tabs.Count -ne 3 -or $saved.windows[0].selected_tab -ne 1) { throw "Saved session mismatch: $($saved | ConvertTo-Json -Depth 8 -Compress)" }
    $savedRaw = Get-Content $statePath -Raw

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $explicit = Start-StatefulApp $layout $exe $repoRoot 'session-explicit-command' @('-e', 'cmd.exe', '/k'); $runs.Add($explicit)
    $explicitHost = Wait-StatefulHost $explicit $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'fresh explicit-command tab' -Process $explicit.Process -Condition { (Get-StatefulTabCount $explicitHost) -eq 1 }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-StatefulPostedCommand $explicitHost 1904 $deadline $explicit.Process
    Invoke-StatefulPostedCommand $explicitHost 1904 $deadline $explicit.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'asynchronous burst-created tabs' -Process $explicit.Process -Condition { (Get-StatefulTabCount $explicitHost) -eq 3 }
    $null = Invoke-InteractiveWin11Message -Hwnd $explicitHost -Message 0 -Deadline $deadline -Description 'asynchronous tab burst readiness barrier' -Process $explicit.Process
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Close-StatefulHost $explicitHost $explicit $deadline
    if ((Get-Content $statePath -Raw) -ne $savedRaw) { throw 'Explicit -e launch read or replaced the saved workspace.' }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $second = Start-StatefulApp $layout $exe $repoRoot 'session-restore' @('--single-instance=true'); $runs.Add($second)
    $restoredHost = Wait-StatefulHost $second $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'restored tabs' -Process $second.Process -Condition { (Get-StatefulTabCount $restoredHost) -eq 3 }
    $snapshot = Get-SessionAutomationSnapshot 'session-restore-automation' $deadline
    if ($snapshot.windows.Count -ne 1 -or $snapshot.windows[0].tabs.Count -ne 3) { throw "Restored automation shape mismatch: $($snapshot | ConvertTo-Json -Depth 8 -Compress)" }
    $activeTabs = @($snapshot.windows[0].tabs | Where-Object active)
    if ($activeTabs.Count -ne 1 -or $snapshot.windows[0].tabs[1].tab_id -ne $snapshot.windows[0].active_tab_id -or -not $snapshot.windows[0].tabs[1].active) {
        throw "Restored selected tab mismatch: $($snapshot | ConvertTo-Json -Depth 8 -Compress)"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Close-StatefulHost $restoredHost $second $deadline

    [IO.File]::WriteAllText($statePath, '{not valid json', [Text.UTF8Encoding]::new($false))
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $third = Start-StatefulApp $layout $exe $repoRoot 'session-corrupt'; $runs.Add($third)
    $freshHost = Wait-StatefulHost $third $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'corrupt state quarantine' -Process $third.Process -Condition {
        -not (Test-Path $statePath) -and @(Get-ChildItem $stateDir -Filter 'session-state.json.corrupt*' -ErrorAction SilentlyContinue).Count -gt 0
    }
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'fresh tab after corrupt state' -Process $third.Process -Condition {
        (Get-StatefulTabCount $freshHost) -eq 1
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Close-StatefulHost $freshHost $third $deadline
}
finally {
    foreach ($run in $runs) { if (-not $run.Process.HasExited) { Stop-InteractiveWin11Process -Process $run.Process } }
}
foreach ($run in $runs) {
    if (Select-String -LiteralPath $run.Stderr -SimpleMatch 'shell/native invariant failed' -Quiet) {
        throw "Shell/native invariant failure reported by $($run.Stderr)."
    }
}
Write-Host "interactive-win11 session-restore validation: PASS (state=$statePath)"
