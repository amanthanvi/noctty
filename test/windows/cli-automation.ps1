[CmdletBinding()]
param([switch]$Rebuild, [switch]$ResetState, [int]$TimeoutSeconds = 35)

$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }

$launcher = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
$forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
if ($Rebuild) { $forwardedArgs += '-Rebuild' }
if ($ResetState) { $forwardedArgs += '-ResetState' }
Invoke-InteractiveWin11HarnessMain -RepoRoot $repoRoot -LauncherPath $launcher `
    -EnvironmentVariable 'NOCTTY_CLI_AUTOMATION_BOOTSTRAPPED' -ArgumentList $forwardedArgs

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'cli-automation' `
    -ResetState:$ResetState -IncludeResourcesDir
$layout = $harness.Layout
$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
if ((Get-InteractiveWin11LaunchAction -ExePath $exe -Rebuild:$Rebuild `
        -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot)) -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}
Assert-InteractiveWin11ExeExists -ExePath $exe
$cli = Join-Path (Split-Path -Parent $exe) 'noctty.com'
if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "Missing automation CLI shim: $cli" }

$stateDir = Join-Path $layout.LocalAppData 'noctty'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $stateDir 'config.ghostty'),
    "confirm-close-surface = false`r`nwindow-save-state = never`r`n",
    [Text.UTF8Encoding]::new($false)
)

$instanceClass = "noctty-automation-$($layout.SandboxId)"
$serverStdout = Join-Path $layout.Logs 'server.stdout.log'
$serverStderr = Join-Path $layout.Logs 'server.stderr.log'
$server = $null
$script:automationInvocation = 0

function Invoke-AutomationCli {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $script:automationInvocation++
    $stderr = Join-Path $layout.Logs ("cli-{0}.stderr.log" -f $script:automationInvocation)
    $output = @(& $cli @Arguments 2> $stderr)
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output -join [Environment]::NewLine
        Stderr = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
    }
}

function Assert-AutomationExit {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [psobject] $Result,
        [Parameter(Mandatory)] [int] $Expected
    )

    if ($Result.ExitCode -ne $Expected) {
        throw "$Description returned $($Result.ExitCode), expected $Expected. stderr: $($Result.Stderr)"
    }
}

function Convert-AutomationSnapshot {
    param([Parameter(Mandatory)] [psobject] $Result)

    Assert-AutomationExit -Description '+list-windows' -Result $Result -Expected 0
    try { return $Result.Output | ConvertFrom-Json }
    catch { throw "Automation JSON did not parse: $($_.Exception.Message); payload: $($Result.Output)" }
}

function Assert-AutomationV3Shape {
    param([Parameter(Mandatory)] [psobject] $State, [Parameter(Mandatory)] [int] $ServerPid)

    if ($State.schema -cne 'noctty.windows.v3' -or $State.api_version -ne 3 -or
        $State.instance.pid -ne $ServerPid -or $State.instance.class -cne $instanceClass -or
        [string]::IsNullOrWhiteSpace($State.instance.version)) {
        throw "Automation instance/schema mismatch: $($State | ConvertTo-Json -Depth 8 -Compress)"
    }
    $window = @($State.windows)[0]
    $pane = @($window.tabs)[0].panes[0]
    if ($null -eq $window -or $null -eq $pane -or
        'title' -cnotin @($window.PSObject.Properties.Name) -or
        'title' -cnotin @($pane.PSObject.Properties.Name) -or
        'working_directory' -cnotin @($pane.PSObject.Properties.Name)) {
        throw "Automation v3 window/pane shape mismatch: $($State | ConvertTo-Json -Depth 8 -Compress)"
    }
}

function Wait-AutomationState {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [scriptblock] $Condition
    )

    $last = $null
    do {
        $result = Invoke-AutomationCli @('+list-windows', "--class=$instanceClass", '--format=json', '--timeout=1000')
        if ($result.ExitCode -eq 0) {
            $last = Convert-AutomationSnapshot $result
            if (& $Condition $last) { return $last }
        }
        else { $last = $result }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "Timed out waiting for $Description. Last state: $($last | ConvertTo-Json -Depth 8 -Compress)"
}

try {
    $server = Start-Process -FilePath $exe -ArgumentList @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=true'
        "--class=$instanceClass"
    ) -WorkingDirectory $repoRoot -RedirectStandardOutput $serverStdout `
        -RedirectStandardError $serverStderr -PassThru
    $serverPid = $server.Id
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    $state = Wait-AutomationState -Description 'initial v3 snapshot' -Deadline $deadline -Condition {
        param($candidate) @($candidate.windows).Count -eq 1
    }
    Assert-AutomationV3Shape -State $state -ServerPid $serverPid
    $firstWindow = @($state.windows)[0]
    $firstWindowId = [uint32]$firstWindow.window_id

    $result = Invoke-AutomationCli @('+new-window', "--class=$instanceClass", '--timeout=10000')
    Assert-AutomationExit -Description '+new-window' -Result $result -Expected 0
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $state = Wait-AutomationState -Description 'second window' -Deadline $deadline -Condition {
        param($candidate) @($candidate.windows).Count -eq 2
    }

    $beforeTabCount = @($state.windows | Where-Object window_id -eq $firstWindowId)[0].tab_count
    $result = Invoke-AutomationCli @(
        '+new-tab', "--class=$instanceClass", "--window-id=$firstWindowId",
        "--working-directory=$($layout.Temp)", '--timeout=10000'
    )
    Assert-AutomationExit -Description '+new-tab' -Result $result -Expected 0
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $state = Wait-AutomationState -Description 'new tab' -Deadline $deadline -Condition {
        param($candidate)
        @($candidate.windows | Where-Object window_id -eq $firstWindowId)[0].tab_count -eq ($beforeTabCount + 1)
    }
    $targetWindow = @($state.windows | Where-Object window_id -eq $firstWindowId)[0]
    $targetTab = @($targetWindow.tabs | Where-Object active)[0]
    $originalSurfaceId = [uint64]$targetTab.focused_surface_id
    $beforePaneCount = $targetTab.pane_count

    $result = Invoke-AutomationCli @(
        '+new-split', "--class=$instanceClass", "--surface-id=$originalSurfaceId", '--direction=down',
        "--working-directory=$($layout.Temp)", '--timeout=10000'
    )
    Assert-AutomationExit -Description '+new-split' -Result $result -Expected 0
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $state = Wait-AutomationState -Description 'new split' -Deadline $deadline -Condition {
        param($candidate)
        $window = @($candidate.windows | Where-Object window_id -eq $firstWindowId)[0]
        @($window.tabs | Where-Object active)[0].pane_count -eq ($beforePaneCount + 1)
    }

    $result = Invoke-AutomationCli @(
        '+focus', "--class=$instanceClass", "--surface-id=$originalSurfaceId", '--timeout=10000'
    )
    Assert-AutomationExit -Description '+focus' -Result $result -Expected 0
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $state = Wait-AutomationState -Description 'exact focused surface' -Deadline $deadline -Condition {
        param($candidate)
        $pane = @($candidate.windows.tabs.panes | Where-Object surface_id -eq $originalSurfaceId)[0]
        $null -ne $pane -and $pane.focused -and $pane.active
    }

    $result = Invoke-AutomationCli @(
        '+perform-action', "--class=$instanceClass", "--surface-id=$originalSurfaceId",
        '--timeout=10000', 'scroll_to_bottom'
    )
    Assert-AutomationExit -Description '+perform-action' -Result $result -Expected 0

    $result = Invoke-AutomationCli @(
        '+send-text', "--class=$instanceClass", "--surface-id=$originalSurfaceId",
        '--timeout=10000', "blocked`nline"
    )
    Assert-AutomationExit -Description '+send-text newline refusal' -Result $result -Expected 4
    $result = Invoke-AutomationCli @(
        '+send-text', "--class=$instanceClass", "--surface-id=$originalSurfaceId",
        '--timeout=10000', 'echo $HOME & whoami'
    )
    Assert-AutomationExit -Description '+send-text printable text' -Result $result -Expected 0

    $unusedClass = "noctty-unused-$([Guid]::NewGuid().ToString('N'))"
    $result = Invoke-AutomationCli @('+list-windows', "--class=$unusedClass", '--timeout=0')
    Assert-AutomationExit -Description '+list-windows unused class' -Result $result -Expected 2
}
finally {
    if ($null -ne $server) { Stop-InteractiveWin11Process -Process $server -Contained }
}

Write-Host "cli automation validation: PASS (server pid=$serverPid class=$instanceClass)"
