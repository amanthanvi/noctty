param(
    [switch] $Rebuild,
    [switch] $ResetState
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$suiteLogDir = Join-Path $env:TEMP ("winghostty-interactive-win11-suite-{0}" -f $PID)
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
        [switch] $IncludeResetState
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
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $run = Start-Harness -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds
    $waitMilliseconds = [int][Math]::Ceiling(($TimeoutSeconds + 5) * 1000)
    if (-not $run.Process.WaitForExit($waitMilliseconds)) {
        Stop-InteractiveWin11Process -Process $run.Process
        throw @"
$ScriptName timed out after ${TimeoutSeconds}s
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
$ScriptName exited with code $exitCode
stdout:
$stdout

stderr:
$stderr
"@
    }

    if ($summary -notlike '*PASS*') {
        throw @"
$ScriptName did not report PASS
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
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $stdoutPath = Join-Path $suiteLogDir ("{0}.stdout.log" -f $ScriptName)
    $stderrPath = Join-Path $suiteLogDir ("{0}.stderr.log" -f $ScriptName)
    $argumentList = Get-HarnessArguments -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds -IncludeResetState

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $argumentList `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    return [InteractiveWin11HarnessRun]::new($ScriptName, $process, $stdoutPath, $stderrPath, $TimeoutSeconds)
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
Invoke-Harness -ScriptName 'interactive-win11-smoke.ps1' -TimeoutSeconds 10 -PassResetState
Invoke-Harness -ScriptName 'interactive-win11-boo-performance.ps1' -TimeoutSeconds 25
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-boo-multitab.ps1' -TimeoutSeconds 25
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-shell-command.ps1' -TimeoutSeconds 20
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-shell-command-live.ps1' -TimeoutSeconds 25
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-key-input.ps1' -TimeoutSeconds 20
Invoke-HarnessWithPassSentinel -ScriptName 'interactive-win11-new-tab.ps1' -TimeoutSeconds 20
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
                Stop-InteractiveWin11Process -Process $other.Process
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
