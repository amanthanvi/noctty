param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [switch] $OpenShell,
    [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'

if ($Rebuild -and $NoBuild) {
    throw 'Cannot use -Rebuild with -NoBuild together.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$libPath = Join-Path $PSScriptRoot 'interactive-win11-lib.ps1'
. $libPath

if (-not $env:NOCTTY_INTERACTIVE_WIN11_BOOTSTRAPPED) {
    $forwardedArgs = @()
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }
    if ($OpenShell) { $forwardedArgs += '-OpenShell' }
    if ($NoBuild) { $forwardedArgs += '-NoBuild' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'interactive' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout
$sandboxEnv = $harness.Environment

if ($OpenShell) {
    Write-Host "RepoRoot: $($layout.RepoRoot)"
    Write-Host "WorktreeId: $($layout.WorktreeId)"
    Write-Host "SandboxId: $($layout.SandboxId)"
    Write-Host "SandboxRoot: $($layout.SandboxRoot)"
    foreach ($entry in $sandboxEnv.GetEnumerator()) {
        Write-Host "$($entry.Key)=$($entry.Value)"
    }

    Push-Location $repoRoot
    try {
        & cmd.exe /k
    }
    finally {
        Pop-Location
    }

    exit 0
}

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -NoBuild:$NoBuild -BuildInputs $buildInputs
$launchArgs = Get-InteractiveWin11LaunchArguments -Layout $layout

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

Start-Process -FilePath $exePath -ArgumentList $launchArgs -WorkingDirectory $repoRoot | Out-Null
