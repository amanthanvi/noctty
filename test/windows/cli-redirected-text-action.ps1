param(
    [Parameter(Mandatory = $true)]
    [string] $Action,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedText,

    [int] $TimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$exePath = Join-Path $repoRoot 'zig-out\bin\winghostty.exe'
$scratchDir = Join-Path $repoRoot 'zig-out\cli-redirected'
$actionSlug = $Action.TrimStart('+')
$stdoutPath = Join-Path $scratchDir "$actionSlug.stdout.txt"
$stderrPath = Join-Path $scratchDir "$actionSlug.stderr.txt"

if (-not (Test-Path $exePath)) {
    throw "Missing built executable: $exePath. Run `zig build -Demit-exe=true` first."
}

New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

if (-not ('RedirectedCliTextActionNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class RedirectedCliTextActionNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@
}

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $Action `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

$nativeProcessHandle = [RedirectedCliTextActionNative]::OpenProcess(0x1000, $false, [uint32] $process.Id)
if ($nativeProcessHandle -eq [IntPtr]::Zero) {
    throw "Unable to open redirected CLI action process handle: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

try {
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        throw "Redirected CLI action did not exit within ${TimeoutSeconds}s. A dialog or hung child likely blocked completion."
    }

    [uint32] $nativeExitCode = 0
    if (-not [RedirectedCliTextActionNative]::GetExitCodeProcess($nativeProcessHandle, [ref] $nativeExitCode)) {
        throw "Unable to read exit code for redirected CLI action: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

    $exitCode = [int] $nativeExitCode
    if ($exitCode -ne 0) {
        throw "Redirected CLI action should exit with code 0, got $exitCode."
    }

    $stdoutText = if (Test-Path $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath } else { '' }
    $stderrText = if (Test-Path $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { '' }

    if (-not $stdoutText.Contains($ExpectedText)) {
        throw "Redirected CLI action stdout did not contain expected text '$ExpectedText'."
    }

    if ($stderrText.Length -ne 0) {
        throw "Redirected CLI action stderr should be empty, got: $stderrText"
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }

    if ($nativeProcessHandle -ne [IntPtr]::Zero) {
        [void] [RedirectedCliTextActionNative]::CloseHandle($nativeProcessHandle)
    }
}

Write-Host "redirected CLI action validation: PASS (action=$Action, expected=$ExpectedText)"
