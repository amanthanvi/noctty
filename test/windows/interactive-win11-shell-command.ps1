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

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_SHELL_COMMAND_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_SHELL_COMMAND_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

function Get-RequiredTextFile {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing expected output file: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $Expected,
        [Parameter(Mandatory)] [string] $Label
    )

    if ($Text.IndexOf($Expected, [System.StringComparison]::Ordinal) -lt 0) {
        throw "$Label missing expected text: $Expected"
    }
}

function Get-EscapedPowerShellLiteralPath {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    return $Path.Replace("'", "''")
}

function Invoke-AppShellRun {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string[]] $ShellArgs,
        [Parameter(Mandatory)] [string] $StdoutPath,
        [Parameter(Mandatory)] [string] $StderrPath
    )

    Remove-Item -LiteralPath $StdoutPath, $StderrPath -ErrorAction SilentlyContinue

    $launchArgs = @(
        '--single-instance=false'
        "--class=winghostty-shell-command-$Name-$($layout.SandboxId)"
        '-e'
    ) + $ShellArgs

    $process = Start-Process `
        -FilePath $exePath `
        -ArgumentList $launchArgs `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -PassThru
    $processHandle = $process.Handle

    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            throw "winghostty $Name run timed out after $TimeoutSeconds seconds"
        }

        $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
        if ($exitCode -ne 0) {
            throw "winghostty $Name run exited with code $exitCode"
        }

        $stderr = Get-InteractiveWin11TextFile -Path $StderrPath
        if ($stderr -match 'error starting IO thread:|panic: reached unreachable code') {
            throw "winghostty $Name run reported a runtime failure"
        }

        return $stderr
    }
    finally {
        Stop-InteractiveWin11Process -Process $process
    }
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'shell-command' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

$exeDir = Split-Path -Parent $exePath
$expectedCommandPath = Join-Path $exeDir 'winghostty.com'

$cmdResolvedPath = Join-Path $layout.Temp 'cmd-resolved.txt'
$cmdHelpPath = Join-Path $layout.Temp 'cmd-help.txt'
$cmdVersionPath = Join-Path $layout.Temp 'cmd-version.txt'
$cmdBooHelpPath = Join-Path $layout.Temp 'cmd-boo-help.txt'
$cmdKeybindsPath = Join-Path $layout.Temp 'cmd-list-keybinds.txt'
$cmdColorsPath = Join-Path $layout.Temp 'cmd-list-colors.txt'
$cmdThemesPath = Join-Path $layout.Temp 'cmd-list-themes.txt'
$cmdPayloadPath = Join-Path $layout.Temp 'interactive-win11-shell-command.cmd'
$cmdStdoutPath = Join-Path $layout.Logs 'interactive-win11-shell-command-cmd-stdout.log'
$cmdStderrPath = Join-Path $layout.Logs 'interactive-win11-shell-command-cmd-stderr.log'

Remove-Item -LiteralPath $cmdResolvedPath, $cmdHelpPath, $cmdVersionPath, $cmdBooHelpPath, $cmdKeybindsPath, $cmdColorsPath, $cmdThemesPath, $cmdPayloadPath, $cmdStdoutPath, $cmdStderrPath -ErrorAction SilentlyContinue

@(
    '@echo off'
    "where winghostty > `"$cmdResolvedPath`" || exit /b 1"
    "winghostty +help > `"$cmdHelpPath`" || exit /b 1"
    "winghostty +version > `"$cmdVersionPath`" || exit /b 1"
    "winghostty +boo --help > `"$cmdBooHelpPath`" || exit /b 1"
    "winghostty +list-keybinds > `"$cmdKeybindsPath`" || exit /b 1"
    "winghostty +list-colors > `"$cmdColorsPath`" || exit /b 1"
    "winghostty +list-themes > `"$cmdThemesPath`" || exit /b 1"
) | Set-Content -LiteralPath $cmdPayloadPath -Encoding ASCII

$null = Invoke-AppShellRun `
    -Name 'cmd' `
    -ShellArgs @('cmd.exe', '/d', '/c', $cmdPayloadPath) `
    -StdoutPath $cmdStdoutPath `
    -StderrPath $cmdStderrPath

$cmdResolved = @(Get-Content -LiteralPath $cmdResolvedPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($cmdResolved.Count -lt 1) {
    throw "cmd run produced no command resolution output ($cmdResolvedPath)"
}
if (-not $cmdResolved[0].Equals($expectedCommandPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "cmd resolved unexpected first winghostty command: $($cmdResolved[0])"
}
Assert-Contains -Text (Get-RequiredTextFile -Path $cmdHelpPath) -Expected 'Usage: winghostty [+action] [options]' -Label 'cmd +help'
Assert-Contains -Text (Get-RequiredTextFile -Path $cmdVersionPath) -Expected 'Build Config' -Label 'cmd +version'
Assert-Contains -Text (Get-RequiredTextFile -Path $cmdBooHelpPath) -Expected 'The `boo` command is used to display the project animation in the terminal.' -Label 'cmd +boo --help'
Assert-Contains -Text (Get-RequiredTextFile -Path $cmdKeybindsPath) -Expected 'keybind = ctrl+shift+,=reload_config' -Label 'cmd +list-keybinds'
Assert-Contains -Text (Get-RequiredTextFile -Path $cmdColorsPath) -Expected 'alice blue = #f0f8ff' -Label 'cmd +list-colors'
Assert-Contains -Text (Get-RequiredTextFile -Path $cmdThemesPath) -Expected '0x96f (resources)' -Label 'cmd +list-themes'

$psResolvedPath = Join-Path $layout.Temp 'powershell-resolved.txt'
$psHelpPath = Join-Path $layout.Temp 'powershell-help.txt'
$psVersionPath = Join-Path $layout.Temp 'powershell-version.txt'
$psBooHelpPath = Join-Path $layout.Temp 'powershell-boo-help.txt'
$psKeybindsPath = Join-Path $layout.Temp 'powershell-list-keybinds.txt'
$psColorsPath = Join-Path $layout.Temp 'powershell-list-colors.txt'
$psThemesPath = Join-Path $layout.Temp 'powershell-list-themes.txt'
$psPayloadPath = Join-Path $layout.Temp 'interactive-win11-shell-command.ps1'
$psStdoutPath = Join-Path $layout.Logs 'interactive-win11-shell-command-powershell-stdout.log'
$psStderrPath = Join-Path $layout.Logs 'interactive-win11-shell-command-powershell-stderr.log'
$psResolvedLiteral = Get-EscapedPowerShellLiteralPath -Path $psResolvedPath
$psHelpLiteral = Get-EscapedPowerShellLiteralPath -Path $psHelpPath
$psVersionLiteral = Get-EscapedPowerShellLiteralPath -Path $psVersionPath
$psBooHelpLiteral = Get-EscapedPowerShellLiteralPath -Path $psBooHelpPath
$psKeybindsLiteral = Get-EscapedPowerShellLiteralPath -Path $psKeybindsPath
$psColorsLiteral = Get-EscapedPowerShellLiteralPath -Path $psColorsPath
$psThemesLiteral = Get-EscapedPowerShellLiteralPath -Path $psThemesPath

Remove-Item -LiteralPath $psResolvedPath, $psHelpPath, $psVersionPath, $psBooHelpPath, $psKeybindsPath, $psColorsPath, $psThemesPath, $psPayloadPath, $psStdoutPath, $psStderrPath -ErrorAction SilentlyContinue

@(
    '$resolved = (Get-Command winghostty).Source'
    "Set-Content -LiteralPath '$psResolvedLiteral' -Value `$resolved -Encoding ASCII"
    '$help = winghostty +help | Out-String'
    'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
    "Set-Content -LiteralPath '$psHelpLiteral' -Value `$help -Encoding UTF8"
    '$version = winghostty +version | Out-String'
    'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
    "Set-Content -LiteralPath '$psVersionLiteral' -Value `$version -Encoding UTF8"
    '$booHelp = winghostty +boo --help | Out-String'
    'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
    "Set-Content -LiteralPath '$psBooHelpLiteral' -Value `$booHelp -Encoding UTF8"
    '$keybinds = winghostty +list-keybinds | Out-String'
    'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
    "Set-Content -LiteralPath '$psKeybindsLiteral' -Value `$keybinds -Encoding UTF8"
    '$colors = winghostty +list-colors | Out-String'
    'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
    "Set-Content -LiteralPath '$psColorsLiteral' -Value `$colors -Encoding UTF8"
    '$themes = winghostty +list-themes | Out-String'
    'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
    "Set-Content -LiteralPath '$psThemesLiteral' -Value `$themes -Encoding UTF8"
) | Set-Content -LiteralPath $psPayloadPath -Encoding UTF8

$null = Invoke-AppShellRun `
    -Name 'powershell' `
    -ShellArgs @('powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psPayloadPath) `
    -StdoutPath $psStdoutPath `
    -StderrPath $psStderrPath

$psResolved = (Get-RequiredTextFile -Path $psResolvedPath).Trim()
if (-not $psResolved.Equals($expectedCommandPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PowerShell resolved unexpected winghostty command: $psResolved"
}
Assert-Contains -Text (Get-RequiredTextFile -Path $psHelpPath) -Expected 'Usage: winghostty [+action] [options]' -Label 'PowerShell +help'
Assert-Contains -Text (Get-RequiredTextFile -Path $psVersionPath) -Expected 'Build Config' -Label 'PowerShell +version'
Assert-Contains -Text (Get-RequiredTextFile -Path $psBooHelpPath) -Expected 'The `boo` command is used to display the project animation in the terminal.' -Label 'PowerShell +boo --help'
Assert-Contains -Text (Get-RequiredTextFile -Path $psKeybindsPath) -Expected 'keybind = ctrl+shift+,=reload_config' -Label 'PowerShell +list-keybinds'
Assert-Contains -Text (Get-RequiredTextFile -Path $psColorsPath) -Expected 'alice blue = #f0f8ff' -Label 'PowerShell +list-colors'
Assert-Contains -Text (Get-RequiredTextFile -Path $psThemesPath) -Expected '0x96f (resources)' -Label 'PowerShell +list-themes'

Write-Host "interactive-win11 shell command validation: PASS (cmd=$cmdStdoutPath, powershell=$psStdoutPath)"
