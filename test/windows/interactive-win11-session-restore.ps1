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
$configPath = Join-Path $stateDir 'config.ghostty'; [IO.File]::WriteAllText($configPath, "window-save-state = always`r`n", [Text.UTF8Encoding]::new($false))
$statePath = Join-Path $stateDir 'session-state.json'
$runs = [Collections.Generic.List[object]]::new()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $first = Start-StatefulApp $layout $exe $repoRoot 'session-save'; $runs.Add($first)
    $host = Wait-StatefulHost $first $deadline
    Invoke-StatefulCommand $host 1904; Invoke-StatefulCommand $host 1904
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'three live tabs' -Process $first.Process -Condition { (Get-StatefulTabCount $host) -eq 3 }
    Invoke-StatefulCommand $host 1001
    Close-StatefulHost $host $first $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'session-state file' -Condition { Test-Path $statePath }
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($saved.windows[0].tabs.Count -ne 3 -or $saved.windows[0].selected_tab -ne 1) { throw "Saved session mismatch: $($saved | ConvertTo-Json -Depth 8 -Compress)" }

    $second = Start-StatefulApp $layout $exe $repoRoot 'session-restore'; $runs.Add($second)
    $restoredHost = Wait-StatefulHost $second $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'restored tabs' -Process $second.Process -Condition { (Get-StatefulTabCount $restoredHost) -eq 3 }
    Close-StatefulHost $restoredHost $second $deadline

    [IO.File]::WriteAllText($statePath, '{not valid json', [Text.UTF8Encoding]::new($false))
    $third = Start-StatefulApp $layout $exe $repoRoot 'session-corrupt'; $runs.Add($third)
    $freshHost = Wait-StatefulHost $third $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'corrupt state quarantine' -Process $third.Process -Condition {
        -not (Test-Path $statePath) -and @(Get-ChildItem $stateDir -Filter 'session-state.json.corrupt*' -ErrorAction SilentlyContinue).Count -gt 0
    }
    if ((Get-StatefulTabCount $freshHost) -ne 1) { throw 'Corrupt session restored tabs instead of starting fresh.' }
    Close-StatefulHost $freshHost $third $deadline
}
finally {
    foreach ($run in $runs) { if (-not $run.Process.HasExited) { Stop-InteractiveWin11Process -Process $run.Process } }
}
Write-Host "interactive-win11 session-restore validation: PASS (state=$statePath)"
