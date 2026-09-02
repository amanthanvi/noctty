param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [switch] $PolicySelfTest,
    [int] $TimeoutSeconds = 12
)

$ErrorActionPreference = 'Stop'
# Poll cadence while waiting for command-finish evidence.
$script:COMMAND_FINISH_POLL_MS = 250

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

function Get-CommandFinishValidationDecision {
    param(
        [Parameter(Mandatory)] [bool] $SettingAvailable,
        [Parameter(Mandatory)] [bool] $NotificationsEnabled,
        [Parameter(Mandatory)] [bool] $NotifierDisabledFallback,
        [Parameter(Mandatory)] [int] $UnexpectedToastFailureCount,
        [Parameter(Mandatory)] [int] $ExitCode,
        [Parameter(Mandatory)] [long] $RuntimeMs,
        [Parameter(Mandatory)] [long] $MinimumRuntimeMs,
        [Parameter(Mandatory)] [string] $SettingText
    )

    if ($RuntimeMs -lt $MinimumRuntimeMs) {
        return [pscustomobject]@{ Valid = $false; Reason = "noctty exited too early for command-finish validation (exit code $ExitCode, runtime $($RuntimeMs)ms)" }
    }
    if ($ExitCode -ne 0) {
        return [pscustomobject]@{ Valid = $false; Reason = "noctty exited with code $ExitCode during command-finish validation" }
    }
    if ($UnexpectedToastFailureCount -gt 0) {
        return [pscustomobject]@{ Valid = $false; Reason = "unexpected WinRT toast failure while notifier setting is $SettingText" }
    }
    if ($NotificationsEnabled -or $NotifierDisabledFallback -or -not $SettingAvailable) {
        return [pscustomobject]@{ Valid = $true; Reason = $null }
    }
    return [pscustomobject]@{ Valid = $false; Reason = "expected explicit NotifierDisabled fallback while notifier setting is $SettingText" }
}

if ($PolicySelfTest) {
    $cases = @(
        @{ Label = 'unavailable clean'; Expected = $true; Args = @{ SettingAvailable = $false; NotificationsEnabled = $false; NotifierDisabledFallback = $false; UnexpectedToastFailureCount = 0; ExitCode = 0; RuntimeMs = 5000; MinimumRuntimeMs = 5000; SettingText = 'Unavailable' } },
        @{ Label = 'disabled fallback'; Expected = $true; Args = @{ SettingAvailable = $true; NotificationsEnabled = $false; NotifierDisabledFallback = $true; UnexpectedToastFailureCount = 0; ExitCode = 0; RuntimeMs = 5000; MinimumRuntimeMs = 5000; SettingText = 'DisabledForApplication' } },
        @{ Label = 'enabled clean'; Expected = $true; Args = @{ SettingAvailable = $true; NotificationsEnabled = $true; NotifierDisabledFallback = $false; UnexpectedToastFailureCount = 0; ExitCode = 0; RuntimeMs = 5000; MinimumRuntimeMs = 5000; SettingText = 'Enabled' } },
        @{ Label = 'mixed failures'; Expected = $false; Args = @{ SettingAvailable = $true; NotificationsEnabled = $false; NotifierDisabledFallback = $true; UnexpectedToastFailureCount = 1; ExitCode = 0; RuntimeMs = 5000; MinimumRuntimeMs = 5000; SettingText = 'DisabledForApplication' } },
        @{ Label = 'nonzero exit'; Expected = $false; Args = @{ SettingAvailable = $false; NotificationsEnabled = $false; NotifierDisabledFallback = $false; UnexpectedToastFailureCount = 0; ExitCode = 1; RuntimeMs = 5000; MinimumRuntimeMs = 5000; SettingText = 'Unavailable' } },
        @{ Label = 'disabled no fallback'; Expected = $false; Args = @{ SettingAvailable = $true; NotificationsEnabled = $false; NotifierDisabledFallback = $false; UnexpectedToastFailureCount = 0; ExitCode = 0; RuntimeMs = 5000; MinimumRuntimeMs = 5000; SettingText = 'DisabledForApplication' } },
        @{ Label = 'short runtime'; Expected = $false; Args = @{ SettingAvailable = $false; NotificationsEnabled = $false; NotifierDisabledFallback = $false; UnexpectedToastFailureCount = 0; ExitCode = 0; RuntimeMs = 4999; MinimumRuntimeMs = 5000; SettingText = 'Unavailable' } }
    )
    foreach ($case in $cases) {
        $caseArgs = $case.Args
        $decision = Get-CommandFinishValidationDecision @caseArgs
        if ($decision.Valid -ne $case.Expected) {
            throw "Command-finish policy case failed: $($case.Label)"
        }
    }
    Write-Host 'command-finish validation policy tests: PASS'
    return
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
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_COMMAND_FINISH_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'command-finish' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-command-finish-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-command-finish-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-command-finish.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-command-finish-payload.ps1'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
desktop-notifications = true
notify-on-command-finish = always
notify-on-command-finish-action = notify
notify-on-command-finish-after = 0s
progress-style = true
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

@"
`$stdout = [Console]::OpenStandardOutput()

function Send-Bytes([byte[]]`$bytes) {
    `$stdout.Write(`$bytes, 0, `$bytes.Length)
    `$stdout.Flush()
}

Send-Bytes ([byte[]](0x1b,0x5d,0x31,0x33,0x33,0x3b,0x43,0x07))
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x31,0x3b,0x35,0x30,0x07))
Start-Sleep -Seconds 2
Send-Bytes ([byte[]](0x1b,0x5d,0x31,0x33,0x33,0x3b,0x44,0x3b,0x31,0x37,0x07))
Start-Sleep -Seconds 4
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$aumid = 'io.github.amanthanvi.noctty'
$toastMgr = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$notifier = $toastMgr::CreateToastNotifier($aumid)
$setting = $notifier.Setting
$settingAvailable = $null -ne $setting
$settingValue = if ($settingAvailable) { [int] $setting } else { -1 }
$settingText = if ($settingAvailable) { $setting.ToString() } else { 'Unavailable' }
$notificationsEnabled = $settingText -eq 'Enabled'

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$launchArgs = @(
    Get-InteractiveWin11ContainmentArguments
    '--single-instance=false'
    "--class=noctty-command-finish-$($layout.SandboxId)"
    "--config-file=$configPath"
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
$processHandle = $process.Handle

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$validated = $false
$failureReason = $null
$launchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$minimumRuntimeMs = 5000

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds $script:COMMAND_FINISH_POLL_MS

        $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
        $toastFailureLines = @($stderr -split '\r?\n' | Where-Object { $_ -match 'winrt toast show failed' })
        $notifierDisabledFallback = @($toastFailureLines | Where-Object { $_ -match 'NotifierDisabled; falling back to banner' }).Count -gt 0
        $unexpectedToastFailureCount = @($toastFailureLines | Where-Object { $_ -notmatch 'NotifierDisabled; falling back to banner' }).Count
        $toastFailure = $toastFailureLines.Count -gt 0

        if ($stderr -match 'taskbar progress init failed|taskbar progress sync failed|panic: reached unreachable code') {
            $failureReason = 'unexpected runtime failure reported in stderr'
            break
        }

        if ($notificationsEnabled -and $toastFailure) {
            $failureReason = "unexpected WinRT toast failure while notifier setting is Enabled ($settingText)"
            break
        }
        if ($unexpectedToastFailureCount -gt 0) {
            $failureReason = "unexpected WinRT toast failure while notifier setting is $settingText"
            break
        }

        if ($process.HasExited) {
            $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle

            $decision = Get-CommandFinishValidationDecision `
                -SettingAvailable $settingAvailable `
                -NotificationsEnabled $notificationsEnabled `
                -NotifierDisabledFallback $notifierDisabledFallback `
                -UnexpectedToastFailureCount $unexpectedToastFailureCount `
                -ExitCode $exitCode `
                -RuntimeMs $launchStopwatch.ElapsedMilliseconds `
                -MinimumRuntimeMs $minimumRuntimeMs `
                -SettingText $settingText
            $validated = $decision.Valid
            $failureReason = $decision.Reason

            break
        }
    }
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}

if (-not $validated) {
    if (-not $failureReason) {
        $failureReason = "timed out after $TimeoutSeconds seconds waiting for command-finished validation"
    }

    $stderrTail = Get-InteractiveWin11TextFileTail -Path $stderrPath -LineCount 80

    throw @"
interactive Win11 command-finish validation failed: $failureReason
toast setting: $settingText ($settingValue)
stderr log: $stderrPath
stdout log: $stdoutPath

Recent stderr:
$stderrTail
"@
}

Write-Host "interactive-win11 command-finish validation: PASS (setting=$settingText, stderr=$stderrPath)"
