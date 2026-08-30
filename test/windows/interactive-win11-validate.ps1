param(
    [switch] $Rebuild,
    [switch] $ResetState
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$suiteLogDir = Join-Path $env:TEMP ("noctty-interactive-win11-suite-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $suiteLogDir | Out-Null
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

class InteractiveWin11HarnessRun {
    [string] $Script
    [System.Diagnostics.Process] $Process
    [string] $Stdout
    [string] $Stderr
    [int] $TimeoutSeconds

    InteractiveWin11HarnessRun(
        [string] $Script,
        [System.Diagnostics.Process] $Process,
        [string] $Stdout,
        [string] $Stderr,
        [int] $TimeoutSeconds
    ) {
        if ([string]::IsNullOrWhiteSpace($Script)) { throw 'Script is required.' }
        if ($null -eq $Process) { throw 'Process is required.' }
        if ([string]::IsNullOrWhiteSpace($Stdout)) { throw 'Stdout is required.' }
        if ([string]::IsNullOrWhiteSpace($Stderr)) { throw 'Stderr is required.' }
        if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }

        $this.Script = $Script
        $this.Process = $Process
        $this.Stdout = $Stdout
        $this.Stderr = $Stderr
        $this.TimeoutSeconds = $TimeoutSeconds
    }
}

function Invoke-SuiteBuild {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

function Invoke-SuiteBuildIfNeeded {
    $exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
    $buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
    $launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

    if ($launchAction -eq 'build') {
        Invoke-SuiteBuild
    }
}

function Get-HarnessArguments {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [int] $TimeoutSeconds = 0,
        [switch] $IncludeResetState,
        [string[]] $AdditionalArguments = @()
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $argumentList = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $scriptPath
    )
    if ($TimeoutSeconds -gt 0) {
        $argumentList += @(
            '-TimeoutSeconds'
            $TimeoutSeconds.ToString()
        )
    }
    if ($ResetState -and $IncludeResetState) { $argumentList += '-ResetState' }
    if ($AdditionalArguments.Count -ne 0) { $argumentList += $AdditionalArguments }

    return $argumentList
}

function Invoke-Harness {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [int] $TimeoutSeconds = 0,
        [switch] $PassResetState
    )

    $argumentList = Get-HarnessArguments -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds -IncludeResetState:$PassResetState

    & powershell.exe @argumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$ScriptName failed with exit code $LASTEXITCODE"
    }
}

function Invoke-HarnessWithPassSentinel {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [string[]] $AdditionalArguments = @(),
        [string] $ScenarioSlug = '',
        # Outer kill deadline for the whole harness process. Defaults to one
        # scenario plus slack, which is right for the single-scenario harnesses.
        # A harness that runs several scenarios sequentially applies
        # -TimeoutSeconds to each of them, so its total budget has to be stated
        # explicitly or the runner kills a run in which no scenario was late.
        [int] $WaitTimeoutSeconds = 0
    )

    $run = Start-Harness -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds -AdditionalArguments $AdditionalArguments -ScenarioSlug $ScenarioSlug
    $waitBudgetSeconds = if ($WaitTimeoutSeconds -gt 0) { $WaitTimeoutSeconds } else { $TimeoutSeconds + 5 }
    $waitMilliseconds = [int][Math]::Ceiling($waitBudgetSeconds * 1000)
    # Single-scenario harnesses report the per-scenario deadline, which is the
    # only number that means anything for them. Multi-scenario runs report the
    # whole budget so the message is not mistaken for a scenario timeout.
    $timeoutDetail = if ($WaitTimeoutSeconds -gt 0) {
        "${waitBudgetSeconds}s total budget (per-scenario deadline ${TimeoutSeconds}s)"
    }
    else {
        "${TimeoutSeconds}s"
    }
    if (-not $run.Process.WaitForExit($waitMilliseconds)) {
        Stop-InteractiveWin11Process -Process $run.Process -RequireLiveRoot
        throw @"
$($run.Script) timed out after ${timeoutDetail}
stdout ($($run.Stdout)):
$(Get-HarnessLog -Path $run.Stdout)

stderr ($($run.Stderr)):
$(Get-HarnessLog -Path $run.Stderr)
"@
    }

    $stdout = Get-HarnessLog -Path $run.Stdout
    $stderr = Get-HarnessLog -Path $run.Stderr
    $summary = Get-HarnessSummary -Path $run.Stdout
    $exitCode = $run.Process.ExitCode

    if (($null -ne $exitCode) -and ($exitCode -ne 0)) {
        throw @"
$($run.Script) exited with code $exitCode
stdout:
$stdout

stderr:
$stderr
"@
    }

    if ($summary -notlike '*PASS*') {
        throw @"
$($run.Script) did not report PASS
stdout:
$stdout

stderr:
$stderr
"@
    }

    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        Write-Host $summary
    }
}

function Start-Harness {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [int] $TimeoutSeconds,
        [string[]] $AdditionalArguments = @(),
        [string] $ScenarioSlug = ''
    )

    $runName = if ([string]::IsNullOrWhiteSpace($ScenarioSlug)) {
        $ScriptName
    }
    else {
        "{0}-{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($ScriptName), $ScenarioSlug
    }
    $stdoutPath = Join-Path $suiteLogDir ("{0}.stdout.log" -f $runName)
    $stderrPath = Join-Path $suiteLogDir ("{0}.stderr.log" -f $runName)
    $argumentList = Get-HarnessArguments -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds -IncludeResetState -AdditionalArguments $AdditionalArguments

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $argumentList `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    return [InteractiveWin11HarnessRun]::new($runName, $process, $stdoutPath, $stderrPath, $TimeoutSeconds)
}

function Get-HarnessLog {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return Get-Content -LiteralPath $Path -Raw
}

function Get-HarnessSummary {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0) {
        return ''
    }

    return $lines[-1]
}

Invoke-Harness -ScriptName 'interactive-win11.ps1'
Invoke-SuiteBuildIfNeeded
Invoke-Harness -ScriptName 'vt-probe-win32-conformance.ps1' -TimeoutSeconds 10 -PassResetState
Invoke-Harness -ScriptName 'interactive-win11-smoke.ps1' -TimeoutSeconds 10 -PassResetState
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-configured-size.ps1' -TimeoutSeconds 15
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-shell-command.ps1' -TimeoutSeconds 20
# Three configured scenarios run sequentially in one process, each with its
# own 30s deadline, so the outer budget covers all three plus startup.
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-shell-command-live.ps1' -TimeoutSeconds 30 -WaitTimeoutSeconds 115 -AdditionalArguments @('-ConfiguredScenariosOnly') -ScenarioSlug 'configured'
if ($env:NOCTTY_INTERACTIVE_RUN_FOREGROUND_HARNESS -eq '1') {
    Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-shell-command-live.ps1' -TimeoutSeconds 25
}
else {
    Write-Host 'interactive-win11 shell command live validation: SKIP (set NOCTTY_INTERACTIVE_RUN_FOREGROUND_HARNESS=1 to require the foreground-sensitive harness in the composite suite)'
}
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -ScenarioSlug 'classic-a'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-bmp') -ScenarioSlug 'bmp'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-supplementary') -ScenarioSlug 'supplementary'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 25 -AdditionalArguments @('-Key', 'unicode-burst') -ScenarioSlug 'burst'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-cr') -ScenarioSlug 'control-cr'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-lf') -ScenarioSlug 'control-lf'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-tab') -ScenarioSlug 'control-tab'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-backspace') -ScenarioSlug 'control-backspace'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20 -AdditionalArguments @('-Key', 'unicode-escape') -ScenarioSlug 'control-escape'
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-ime-candidate.ps1' -TimeoutSeconds 20
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-new-tab.ps1' -TimeoutSeconds 20
Invoke-HarnessWithPassSentinel -ScriptName 'cli-automation.ps1' -TimeoutSeconds 35
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-resize.ps1' -TimeoutSeconds 15
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-undo.ps1' -TimeoutSeconds 35

[InteractiveWin11HarnessRun[]] $parallelRuns = @(
    Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12
    Start-Harness -ScriptName 'interactive-win11-progress.ps1' -TimeoutSeconds 20
)

$maxTimeoutSeconds = ($parallelRuns | ForEach-Object { $_.TimeoutSeconds } | Measure-Object -Maximum).Maximum
$overallTimeoutSeconds = $maxTimeoutSeconds + 20
$parallelDeadline = (Get-Date).AddSeconds($overallTimeoutSeconds)

foreach ($run in $parallelRuns) {
    $remainingMilliseconds = [int][Math]::Ceiling(($parallelDeadline - (Get-Date)).TotalMilliseconds)
    if ($remainingMilliseconds -le 0) { $remainingMilliseconds = 1 }
    if (-not $run.Process.WaitForExit($remainingMilliseconds)) {
        foreach ($other in $parallelRuns) {
            if (-not $other.Process.HasExited) {
                Stop-InteractiveWin11Process -Process $other.Process -RequireLiveRoot
            }
        }
        throw @"
$($run.Script) timed out before suite deadline (${overallTimeoutSeconds}s overall; nominal harness timeout $($run.TimeoutSeconds)s)
stdout ($($run.Stdout)):
$(Get-HarnessLog -Path $run.Stdout)

stderr ($($run.Stderr)):
$(Get-HarnessLog -Path $run.Stderr)
"@
    }
}

foreach ($run in $parallelRuns) {
    $stdout = Get-HarnessLog -Path $run.Stdout
    $stderr = Get-HarnessLog -Path $run.Stderr
    $summary = Get-HarnessSummary -Path $run.Stdout
    $exitCode = $run.Process.ExitCode

    if (($null -ne $exitCode) -and ($exitCode -ne 0)) {
        throw @"
$($run.Script) exited with code $exitCode
stdout:
$stdout

stderr:
$stderr
"@
    }

    if ($summary -notlike '*PASS*') {
        throw @"
$($run.Script) did not report PASS
stdout:
$stdout

stderr:
$stderr
"@
    }

    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        Write-Host $summary
    }
}

Write-Host "interactive-win11 validate suite: PASS ($suiteLogDir)"
