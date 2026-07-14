param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_CONFIGURED_SIZE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_CONFIGURED_SIZE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'configured-size' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

if (-not ('InteractiveWin11ConfiguredSizeNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class InteractiveWin11ConfiguredSizeNative {
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
}
"@
}

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-configured-size-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-configured-size-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-configured-size.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-configured-size-payload.ps1'
$resultPath = Join-Path $layout.Temp 'interactive-win11-configured-size-result.json'
$configuredWidth = 140
$configuredHeight = 45

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
window-width = $configuredWidth
window-height = $configuredHeight
confirm-close-surface = false
font-size = 16
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

@"
param(
    [Parameter(Mandatory)] [string] `$ResultPath
)

`$result = [pscustomobject]@{
    width = [Console]::WindowWidth
    height = [Console]::WindowHeight
}
`$result | ConvertTo-Json -Compress | Set-Content -LiteralPath `$ResultPath -Encoding ASCII
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $resultPath -ErrorAction SilentlyContinue

$launchArgs = @(
    Get-InteractiveWin11ContainmentArguments
    '--single-instance=false'
    "--class=winghostty-configured-size-$($layout.SandboxId)"
    "--config-file=$configPath"
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
    '-ResultPath'
    $resultPath
)

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$successPattern = 'started subcommand path='
$runtimeFailurePattern = 'paint redraw failed|InvalidValue|surface closed|panic: reached unreachable code|error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$started = $false
$result = $null
$resultObservedAt = $null

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        [string] $stderr = Get-InteractiveWin11TextFile -Path $stderrPath

        if ($stderr -match $runtimeFailurePattern) {
            throw "unexpected runtime failure reported before size capture:`n$stderr"
        }

        if ($stderr.Contains($successPattern)) {
            $started = $true
        }

        if (Test-Path -LiteralPath $resultPath) {
            $raw = Get-Content -LiteralPath $resultPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $result = $raw | ConvertFrom-Json
                $resultObservedAt = [DateTime]::UtcNow
            }
        }

        if ($null -ne $result) {
            if ($started -or ([DateTime]::UtcNow - $resultObservedAt).TotalMilliseconds -ge 1000) {
                break
            }
        }

        if ($process.HasExited) {
            if ($null -ne $result) {
                break
            }
            throw "winghostty exited before configured-size validation completed (exit code $($process.ExitCode))"
        }

        Start-Sleep -Milliseconds 100
    }

    if ($null -eq $result) {
        if (-not $started) {
            throw "timed out after $TimeoutSeconds seconds waiting for shell startup"
        }
        throw "timed out after $TimeoutSeconds seconds waiting for console size result at $resultPath"
    }

    $width = [int] $result.width
    $height = [int] $result.height

    $process.Refresh()
    $dpi = 96
    if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
        $windowDpi = [InteractiveWin11ConfiguredSizeNative]::GetDpiForWindow($process.MainWindowHandle)
        if ($windowDpi -gt 0) {
            $dpi = [int] $windowDpi
        }
    }
    $minWidth = $configuredWidth - 20
    $minHeight = $configuredHeight - 10

    if ($width -lt $minWidth -or $height -lt $minHeight) {
        throw "configured initial PTY size is too small: ${width}x${height}; expected at least ${minWidth}x${minHeight} for dpi=$dpi"
    }

    [string] $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "unexpected runtime failure reported after size capture:`n$stderr"
    }
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}

Write-Host "interactive-win11 configured-size validation: PASS (pty=${width}x${height}, dpi=$dpi, result=$resultPath, stderr=$stderrPath)"
