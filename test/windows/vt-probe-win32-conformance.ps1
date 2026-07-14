param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [switch] $Runtime,
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

if (-not $env:WINGHOSTTY_VT_PROBE_WIN32_CONFORMANCE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }
    if ($Runtime) { $forwardedArgs += '-Runtime' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_VT_PROBE_WIN32_CONFORMANCE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'vt-conformance' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'vt-probe-win32-conformance-stdout.log'
$stderrPath = Join-Path $layout.Logs 'vt-probe-win32-conformance-stderr.log'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath
Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList '+vt-probe' `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru
$processHandle = $process.Handle

try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "+vt-probe did not exit within ${TimeoutSeconds}s"
    }

    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
    if ($exitCode -ne 0) {
        throw "+vt-probe exited with code $exitCode"
    }
}
finally {
    Stop-InteractiveWin11Process -Process $process -AllowAlreadyExited
}

$stdout = Get-InteractiveWin11TextFile -Path $stdoutPath
$stderr = Get-InteractiveWin11TextFile -Path $stderrPath
if (-not [string]::IsNullOrWhiteSpace($stderr)) {
    throw "+vt-probe wrote unexpected stderr:`n$stderr"
}

$expectedRuntime = [ordered]@{
    'osc-7-working-directory' = 'parser-only'
    'osc-8-hyperlink' = 'pending'
    'osc-9-desktop-notification' = 'validated'
    'osc-777-desktop-notification' = 'parser-only'
    'osc-9-4-progress' = 'validated'
    'osc-52-clipboard' = 'pending'
    'osc-4-palette' = 'parser-only'
    'osc-10-11-colors' = 'parser-only'
    'osc-21-kitty-color-stack' = 'parser-only'
    'csi-2026-synchronized-output' = 'validated'
    'kitty-graphics' = 'pending'
}

foreach ($entry in $expectedRuntime.GetEnumerator()) {
    $escapedId = [regex]::Escape([string] $entry.Key)
    $escapedRuntime = [regex]::Escape([string] $entry.Value)
    if ($stdout -notmatch "capability=$escapedId .* win32-runtime=$escapedRuntime ") {
        throw "Missing or incorrect Win32 runtime classification for $($entry.Key): expected $($entry.Value).`nOutput:`n$stdout"
    }
}

if ($stdout -notmatch 'capability=osc-133-semantic-prompt .* win32-runtime=validated evidence="test/windows/interactive-win11-command-finish\.ps1"') {
    throw "OSC 133 command-finish evidence is missing from +vt-probe output.`nOutput:`n$stdout"
}

if ($Runtime) {
    $runtimeHarnesses = @(
        @{ Script = 'interactive-win11-command-finish.ps1'; Timeout = 12 },
        @{ Script = 'interactive-win11-progress.ps1'; Timeout = 20 },
        @{ Script = 'interactive-win11-boo-performance.ps1'; Timeout = 25 }
    )

    foreach ($runtimeHarness in $runtimeHarnesses) {
        $scriptPath = Join-Path $PSScriptRoot $runtimeHarness.Script
        $scriptArgs = @(
            '-NoLogo'
            '-NoProfile'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            $scriptPath
            '-TimeoutSeconds'
            ($runtimeHarness.Timeout.ToString())
        )
        if ($ResetState) { $scriptArgs += '-ResetState' }

        & powershell.exe @scriptArgs
        if ($LASTEXITCODE -ne 0) {
            throw "$($runtimeHarness.Script) failed with exit code $LASTEXITCODE"
        }
    }
}

$mode = if ($Runtime) { 'runtime' } else { 'metadata' }
Write-Host "vt-probe Win32 conformance validation: PASS (mode=$mode, stdout=$stdoutPath)"
