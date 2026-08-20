param(
    [string] $Action = '+boo',
    [int] $TimeoutSeconds = 5,
    [string] $ResourcesDir,
    [string[]] $ExtraArgs = @(),
    [string] $ExePath
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$exePath = if ($ExePath) { $ExePath } else { Join-Path $repoRoot 'zig-out\bin\noctty.exe' }
$expectedTitle = 'noctty CLI action failed'
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

if (-not (Test-Path $exePath)) {
    throw "Missing built executable: $exePath. Run `zig build -Demit-exe=true` first."
}

function Find-DetachedCliResourcesDir {
    $artifactsDir = Join-Path $repoRoot 'dist\artifacts'
    if (-not (Test-Path $artifactsDir)) {
        return $null
    }

    return Get-ChildItem $artifactsDir -Directory |
        ForEach-Object { Join-Path $_.FullName 'noctty\share\ghostty' } |
        Where-Object { Test-Path (Join-Path $_ 'themes') } |
        Select-Object -First 1
}

if (-not $ResourcesDir -and $Action -eq '+list-themes') {
    $ResourcesDir = Find-DetachedCliResourcesDir
}

if (-not ('DetachedCliActionNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DetachedCliActionNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetWindowTextLengthW(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder lpString, int nMaxCount);
}
"@
}

function Get-DetachedCliWindowTitle {
    param([IntPtr] $Handle)

    if ($Handle -eq [IntPtr]::Zero) {
        return ''
    }

    $length = [DetachedCliActionNative]::GetWindowTextLengthW($Handle)
    if ($length -le 0) {
        return ''
    }

    $builder = New-Object System.Text.StringBuilder ($length + 1)
    [void] [DetachedCliActionNative]::GetWindowTextW($Handle, $builder, $builder.Capacity)
    return $builder.ToString()
}

$oldResourcesDir = $env:GHOSTTY_RESOURCES_DIR
$hadResourcesDir = $null -ne (Get-Item Env:GHOSTTY_RESOURCES_DIR -ErrorAction SilentlyContinue)

if ($ResourcesDir) {
    $env:GHOSTTY_RESOURCES_DIR = $ResourcesDir
}

try {
    $argumentList = @($Action) + $ExtraArgs
    $process = Start-Process `
        -FilePath $exePath `
        -ArgumentList $argumentList `
        -WindowStyle Hidden `
        -PassThru
}
finally {
    if ($hadResourcesDir) {
        $env:GHOSTTY_RESOURCES_DIR = $oldResourcesDir
    }
    else {
        Remove-Item Env:GHOSTTY_RESOURCES_DIR -ErrorAction SilentlyContinue
    }
}
$processHandle = $process.Handle

$dialogHandle = [IntPtr]::Zero
$observedTitle = ''

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()

        if ($process.HasExited) {
            break
        }

        $dialogHandle = $process.MainWindowHandle
        $observedTitle = Get-DetachedCliWindowTitle -Handle $dialogHandle
        if ($observedTitle -eq $expectedTitle) {
            break
        }
    }

    if ($observedTitle -ne $expectedTitle) {
        if ($process.HasExited) {
            $exitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
            throw "Detached CLI action exited without a visible error dialog (exit code $exitCode)."
        }

        throw "Detached CLI action did not expose the expected error dialog within ${TimeoutSeconds}s (observed title: '$observedTitle')."
    }

    $closeDeadline = [DateTime]::UtcNow.AddSeconds(5)
    try {
        [void](Invoke-InteractiveWin11Message `
            -Hwnd $dialogHandle `
            -Message 0x0010 `
            -Deadline $closeDeadline `
            -Description 'WM_CLOSE detached CLI error dialog' `
            -Flags $script:InteractiveWin11SmtoBlock `
            -Process $process)
    }
    catch {
        $sendError = $_
        $process.Refresh()
        if (-not $process.HasExited) {
            throw $sendError
        }
        Write-Warning "WM_CLOSE send raced detached CLI process exit: $sendError"
    }
    $closeProcess = $process
    Wait-InteractiveWin11Until -Deadline $closeDeadline -Description 'detached CLI action exit' -Condition {
        $closeProcess.Refresh()
        $closeProcess.HasExited
    }

    $finalExitCode = Get-InteractiveWin11ProcessExitCode -Process $process -ProcessHandle $processHandle
    if ($finalExitCode -ne 1) {
        throw "Detached CLI action should exit with code 1 after its error dialog closes, got $finalExitCode."
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}

$argumentSummary = (@($Action) + $ExtraArgs) -join ' '
Write-Host "detached CLI action validation: PASS (args=$argumentSummary, title=$expectedTitle)"
