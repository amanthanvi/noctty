param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 20
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'interactive-win11-shaders.ps1'
try {


$ErrorActionPreference = 'Stop'
# Settling delay before shader-output validation.
$script:SHADER_SETTLE_MS = 750

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
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_SHADERS_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

if ($Rebuild) {
    if (Test-InteractiveWin11MeasureMode) {
        # The measurement generation always carries custom shader support.
        Invoke-InteractiveWin11Build -RepoRoot $repoRoot
    }
    else {
        Push-Location $repoRoot
        try {
            zig build -Demit-exe=true -Dcustom-shaders=true
            if ($LASTEXITCODE -ne 0) {
                throw "shader-enabled build failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            Pop-Location
        }
    }
}

$harness = Initialize-InteractiveWin11Sandbox `
    -RepoRoot $repoRoot `
    -SandboxName 'shaders' `
    -ResetState:$ResetState `
    -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$commandPath = Join-Path (Split-Path -Parent $exePath) 'noctty.com'
$shaderPath = Join-Path $PSScriptRoot 'fixtures\solid-magenta-shader.glsl'
$configPath = Join-Path $layout.Temp 'interactive-win11-shaders.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-shaders-payload.ps1'
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-shaders-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-shaders-stderr.log'
$screenshotPath = Join-Path $layout.Logs 'interactive-win11-shaders-surface.png'

Assert-InteractiveWin11ExeExists -ExePath $exePath
foreach ($path in @($commandPath, $shaderPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing shader validation input: $path"
    }
}

$versionText = & $commandPath +version | Out-String
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'custom shaders: enabled') {
    throw 'The current executable does not include custom shader support. Re-run with -Rebuild.'
}

@"
background = #101010
background-opacity = 1
confirm-close-surface = false
font-size = 16
window-height = 24
window-width = 80
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

@"
Write-Output 'shader validation ready'
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $screenshotPath -ErrorAction SilentlyContinue

$launchArgs = @(
    Get-InteractiveWin11ContainmentArguments
    '--single-instance=false'
    "--class=noctty-shaders-$($layout.SandboxId)"
    "--config-file=$configPath"
    "--custom-shader=$shaderPath"
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
)

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$runtimeFailurePattern = 'error loading custom shaders|error initializing postprocess shaders|shader compilation|panic:|error starting IO thread:'
$surface = $null
$color = $null

try {
    Wait-InteractiveWin11Until `
        -Deadline $deadline `
        -Description 'shader validation host window' `
        -Process $process `
        -Condition {
            $process.Refresh()
            $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
            if ($stderr -match $runtimeFailurePattern) {
                throw "custom shader runtime failure:`n$stderr"
            }

            $hostHwnd = Find-StatefulHost $process.Id
            if ($hostHwnd -eq [IntPtr]::Zero) {
                return $false
            }

            $script:shaderSurface = Get-StatefulSurface $hostHwnd
            return $null -ne $script:shaderSurface
        }

    $surface = $script:shaderSurface
    $hostHwnd = Find-StatefulHost $process.Id
    Show-StatefulHost $hostHwnd
    Start-Sleep -Milliseconds $script:SHADER_SETTLE_MS

    if ($null -eq (Get-StatefulWindowRect $surface.Hwnd)) {
        throw 'Failed to read the shader surface bounds.'
    }

    # Evidence only, and saved only where it shows noctty alone.
    Show-StatefulHost $hostHwnd
    $shot = Save-StatefulScreenCapture -Hwnd $surface.Hwnd -Path $screenshotPath
    $screenshotText = if ($null -ne $shot.Path) { $shot.Path } else { "not saved ($($shot.Note))" }

    Show-StatefulHost $hostHwnd
    $argb = Get-StatefulPixel $surface.Hwnd
    $color = [Drawing.Color]::FromArgb($argb)
    $isMagenta = $color.R -ge 220 -and $color.G -le 40 -and $color.B -ge 220
    if (-not $isMagenta) {
        $diagnostic = try { Save-StatefulPixelDiagnostic -Hwnd $surface.Hwnd -Description 'custom shader magenta surface' -Directory $layout.Logs }
        catch { "pixel diagnostic failed: $($_.Exception.Message)" }
        throw "Custom shader produced no magenta surface (sample RGB=$($color.R),$($color.G),$($color.B); screenshot=$screenshotText); $diagnostic."
    }

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "custom shader runtime failure after capture:`n$stderr"
    }
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}

Write-Host "interactive Win11 shader validation: PASS (RGB=$($color.R),$($color.G),$($color.B), screenshot=$screenshotText)"

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
