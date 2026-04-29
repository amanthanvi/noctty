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

if (-not ('CliShellCommandNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CliShellCommandNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
}
"@
}

function Get-CliShellExitCode {
    param(
        [System.Diagnostics.Process] $Process,
        [IntPtr] $ProcessHandle
    )

    $Process.Refresh()
    if ($null -ne $Process.ExitCode) {
        return [int] $Process.ExitCode
    }

    [uint32] $nativeExitCode = 0
    if (-not [CliShellCommandNative]::GetExitCodeProcess($ProcessHandle, [ref] $nativeExitCode)) {
        throw "Unable to read exit code for pid=$($Process.Id): $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

    return [int] $nativeExitCode
}

function Format-CmdArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + $Argument.Replace('"', '""') + '"'
}

function Format-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Argument
    )

    return "'" + $Argument.Replace("'", "''") + "'"
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$binDir = if ($BinDir) { $BinDir } else { Join-Path $repoRoot 'zig-out\bin' }
$guiExe = Join-Path $binDir 'winghostty.exe'
$commandExe = Join-Path $binDir 'winghostty.com'

if (-not (Test-Path $guiExe)) {
    throw "Missing built executable: $guiExe. Run `zig build -Demit-exe=true` first."
}
if (-not (Test-Path $commandExe)) {
    throw "Missing shell launcher: $commandExe. Run `zig build -Demit-exe=true` first."
}

$envPath = "$binDir;$env:PATH"
$argsDisplay = [string]::Join(' ', $Arguments)

switch ($Shell) {
    'cmd' {
        $resolved = & cmd /d /c "set ""PATH=$envPath""&& where winghostty"
        if ($LASTEXITCODE -ne 0) {
            throw "cmd could not resolve winghostty from PATH."
        }
        if (-not ($resolved | Select-Object -First 1 | ForEach-Object { $_.ToLowerInvariant().EndsWith('winghostty.com') })) {
            throw "cmd resolved winghostty to the wrong artifact: $($resolved | Select-Object -First 1)"
        }

        $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + ".cmd")
        try {
            $cmdArgs = [string]::Join(' ', ($Arguments | ForEach-Object { Format-CmdArgument $_ }))
            $cmdCommand = if ([string]::IsNullOrEmpty($cmdArgs)) { 'winghostty' } else { "winghostty $cmdArgs" }
            @(
                '@echo off'
                "set `"PATH=$envPath`""
                $cmdCommand
            ) | Set-Content -LiteralPath $payloadPath -Encoding ASCII

            $output = & cmd /d /c $payloadPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            Remove-Item -LiteralPath $payloadPath -ErrorAction SilentlyContinue
        }
    }

    'powershell' {
        $oldPath = $env:PATH
        $env:PATH = $envPath
        try {
            $resolved = & powershell.exe -NoProfile -Command "(Get-Command winghostty).Source"
            if ($LASTEXITCODE -ne 0) {
                throw "PowerShell could not resolve winghostty from PATH."
            }
            if (-not $resolved.ToLowerInvariant().EndsWith('winghostty.com')) {
                throw "PowerShell resolved winghostty to the wrong artifact: $resolved"
            }

            $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stdout.txt")
            $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + "-stderr.txt")
            $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("winghostty-cli-shell-" + [System.Guid]::NewGuid().ToString("N") + ".ps1")
            try {
                $argLiterals = [string]::Join(', ', ($Arguments | ForEach-Object { Format-PowerShellLiteral $_ }))
                @(
                    '$argsList = @(' + $argLiterals + ')'
                    '$output = & winghostty @argsList | Out-String'
                    '$exitCode = $LASTEXITCODE'
                    '[Console]::Out.Write($output)'
                    'exit $exitCode'
                ) | Set-Content -LiteralPath $payloadPath -Encoding UTF8

                $process = Start-Process `
                    -FilePath powershell.exe `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $payloadPath) `
                    -RedirectStandardOutput $stdoutPath `
                    -RedirectStandardError $stderrPath `
                    -WindowStyle Hidden `
                    -PassThru
                $processHandle = $process.Handle
                $process.WaitForExit()

                $exitCode = Get-CliShellExitCode -Process $process -ProcessHandle $processHandle
                $output = if (Test-Path -LiteralPath $stdoutPath) {
                    Get-Content -LiteralPath $stdoutPath -Raw
                } else {
                    ''
                }
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

$outputText = ($output | Out-String)
if (-not $outputText.Contains($ExpectedText)) {
    throw "$Shell shell launcher output did not contain expected text '$ExpectedText'."
}

Write-Host "shell launcher validation: PASS (shell=$Shell, args=$argsDisplay)"
