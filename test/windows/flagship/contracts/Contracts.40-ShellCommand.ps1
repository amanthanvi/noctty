$expectedCliShellHarnessText = @'
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cmd', 'powershell')]
    [string] $Shell,

    [Parameter(Mandatory = $true)]
    [string[]] $Arguments,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedText,

    [int] $ExpectedExitCode = 0,

    [string] $BinDir
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

function Format-CmdArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.Length -eq 0) {
        return '""'
    }

    $escaped = $Argument.Replace('%', '%%').Replace('"', '""')
    if ($escaped -match '[\s"&|<>()^!]') {
        return '"' + $escaped + '"'
    }

    return $escaped
}

function Format-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Argument
    )

    return "'" + $Argument.Replace("'", "''") + "'"
}

$binDir = [System.IO.Path]::GetFullPath($(if ($BinDir) { $BinDir } else { Join-Path $repoRoot 'zig-out\bin' }))
$guiExe = Join-Path $binDir 'noctty.exe'
$commandExe = Join-Path $binDir 'noctty.com'
$cmdExe = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
$powershellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

foreach ($requiredExecutable in @($guiExe, $commandExe, $cmdExe, $powershellExe)) {
    if (-not (Test-Path -LiteralPath $requiredExecutable -PathType Leaf)) {
        throw "Missing required executable: $requiredExecutable. Run `zig build -Demit-exe=true` if the noctty binaries are absent."
    }
}

$envPath = "$binDir;$env:PATH"
$argsDisplay = [string]::Join(' ', $Arguments)
$shellLauncherTimeoutSeconds = 30

switch ($Shell) {
    'cmd' {
        $resolved = & $cmdExe /d /c "set ""PATH=$envPath""&& where noctty"
        if ($LASTEXITCODE -ne 0) {
            throw "cmd could not resolve noctty from PATH."
        }
        $resolvedPath = [System.IO.Path]::GetFullPath(($resolved | Select-Object -First 1))
        if (-not [string]::Equals($resolvedPath, $commandExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "cmd resolved noctty to the wrong artifact: $resolvedPath"
        }

        $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stdout.txt")
        $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stderr.txt")
        $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + ".cmd")
        try {
            $cmdArgs = [string]::Join(' ', ($Arguments | ForEach-Object { Format-CmdArgument $_ }))
            $cmdCommand = if ([string]::IsNullOrEmpty($cmdArgs)) { 'noctty' } else { "noctty $cmdArgs" }
            @(
                '@echo off'
                "set `"PATH=$envPath`""
                $cmdCommand
            ) | Set-Content -LiteralPath $payloadPath -Encoding ASCII

            $process = Start-Process `
                -FilePath $cmdExe `
                -ArgumentList "/d /c `"$payloadPath`"" `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -WindowStyle Hidden `
                -PassThru
            $processHandle = $process.Handle
            if (-not $process.WaitForExit($shellLauncherTimeoutSeconds * 1000)) {
                Stop-InteractiveWin11Process -Process $process -RequireLiveRoot
                throw "Timed out waiting $shellLauncherTimeoutSeconds seconds for shell launcher process to exit."
            }

            $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
            $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
                Get-Content -LiteralPath $stdoutPath -Raw
            } else {
                ''
            }
            $stderrText = if (Test-Path -LiteralPath $stderrPath) {
                Get-Content -LiteralPath $stderrPath -Raw
            } else {
                ''
            }
            $output = $stdoutText + $stderrText
        }
        finally {
            Remove-Item -LiteralPath $stdoutPath, $stderrPath, $payloadPath -ErrorAction SilentlyContinue
        }
    }

    'powershell' {
        $oldPath = $env:PATH
        $env:PATH = $envPath
        try {
            $resolved = & $powershellExe -NoProfile -Command "(Get-Command noctty).Source"
            if ($LASTEXITCODE -ne 0) {
                throw "PowerShell could not resolve noctty from PATH."
            }
            $resolvedPath = [System.IO.Path]::GetFullPath($resolved)
            if (-not [string]::Equals($resolvedPath, $commandExe, [StringComparison]::OrdinalIgnoreCase)) {
                throw "PowerShell resolved noctty to the wrong artifact: $resolvedPath"
            }

            $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stdout.txt")
            $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stderr.txt")
            $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + ".ps1")
            try {
                $env:PATH = $envPath
                $argLiterals = [string]::Join(', ', ($Arguments | ForEach-Object { Format-PowerShellLiteral $_ }))
                @(
                    '$argsList = @(' + $argLiterals + ')'
                    '$output = & noctty @argsList | Out-String'
                    '$exitCode = $LASTEXITCODE'
                    '[Console]::Out.Write($output)'
                    'exit $exitCode'
                ) | Set-Content -LiteralPath $payloadPath -Encoding UTF8

                $process = Start-Process `
                    -FilePath $powershellExe `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $payloadPath) `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError $stderrPath `
                    -WindowStyle Hidden `
                    -PassThru
                $processHandle = $process.Handle
                if (-not $process.WaitForExit($shellLauncherTimeoutSeconds * 1000)) {
                    Stop-InteractiveWin11Process -Process $process -RequireLiveRoot
                    throw "Timed out waiting $shellLauncherTimeoutSeconds seconds for shell launcher process to exit."
                }

                $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
                $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
                    Get-Content -LiteralPath $stdoutPath -Raw
                } else {
                    ''
                }
                $stderrText = if (Test-Path -LiteralPath $stderrPath) {
                    Get-Content -LiteralPath $stderrPath -Raw
                } else {
                    ''
                }
                $output = $stdoutText + $stderrText
            }
            finally {
                Remove-Item -LiteralPath $stdoutPath, $stderrPath, $payloadPath -ErrorAction SilentlyContinue
            }
        }
        finally {
            $env:PATH = $oldPath
        }
    }
}

if ($exitCode -ne $ExpectedExitCode) {
    throw "$Shell shell launcher should exit with code $ExpectedExitCode, got $exitCode."
}

$outputText = if ($output -is [string]) { $output } else { ($output | Out-String) }
if (-not $outputText.Contains($ExpectedText)) {
    throw "$Shell shell launcher output did not contain expected text '$ExpectedText'."
}

Write-Host "shell launcher validation: PASS (shell=$Shell, args=$argsDisplay)"
'@
if ((($cliShellHarnessText -replace "\r\n?", "`n") -replace '\n+\z', '') -cne
    (($expectedCliShellHarnessText -replace "\r\n?", "`n") -replace '\n+\z', '')) {
    throw 'CLI shell harness must match its complete reviewed source snapshot.'
}
$cliShellTokens = $null
$cliShellErrors = $null
$cliShellAst = [System.Management.Automation.Language.Parser]::ParseInput(
    $cliShellHarnessText,
    [ref]$cliShellTokens,
    [ref]$cliShellErrors
)
if ($cliShellErrors.Count -ne 0) { throw 'CLI shell harness must parse without errors.' }
Assert-CommandResolutionContract -Ast $cliShellAst -Tokens $cliShellTokens -Context $cliShellHarness -ExpectedDotSources @(
    ". (Join-Path `$repoRoot 'scripts\interactive-win11-lib.ps1')"
) -ExpectedAmpersandCommands @(
    '& $cmdExe /d /c "set ""PATH=$envPath""&& where noctty"'
    '& $powershellExe -NoProfile -Command "(Get-Command noctty).Source"'
)

$commandFinishHarness = Join-Path $repoRoot 'test\windows\interactive-win11-command-finish.ps1'
$commandFinishHarnessText = Get-Content -LiteralPath $commandFinishHarness -Raw
Invoke-ContractTable -Contracts @(
    @{
        File = $commandFinishHarness
        Content = { $commandFinishHarnessText }
        Pattern = '(?ms)\$setting = \$notifier\.Setting.*?\$settingAvailable = \$null -ne \$setting.*?Unavailable.*?\$toastFailure -and -not \$notifierDisabledFallback.*?-not \$settingAvailable -and -not \$toastFailure'
        Kind = 'Text'
        Description = 'command-finish validation handles unavailable WinRT settings while rejecting unexpected toast failures'
    }
)
