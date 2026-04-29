param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [ValidateSet('a', 'space')] [string] $Key = 'a',
    [ValidateSet('surface', 'host')] [string] $Route = 'surface',
    [switch] $RunBooFirst,
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

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_KEY_INPUT_BOOTSTRAPPED) {
    $forwardedArgs = @('-Key', $Key, '-Route', $Route, '-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($RunBooFirst) { $forwardedArgs += '-RunBooFirst' }
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_KEY_INPUT_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win11KeyInputNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)]
        public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint uCode, uint uMapType);
}
'@
Add-Type -AssemblyName Microsoft.VisualBasic

$INPUT_KEYBOARD = 1
$KEYEVENTF_KEYUP = 0x0002
$MAPVK_VK_TO_VSC = 0
$SW_RESTORE = 9
$VK_A = 0x41
$VK_ESCAPE = 0x1B
$VK_SPACE = 0x20
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_CHAR = 0x0102

function Get-WindowClassName {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $builder = [System.Text.StringBuilder]::new(256)
    [void] [Win11KeyInputNative]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Find-HostWindow {
    param(
        [Parameter(Mandatory)] [int] $ProcessId
    )

    $script:Win11KeyInputTargetProcessId = [uint32] $ProcessId
    $script:Win11KeyInputFoundHost = [IntPtr]::Zero
    $callback = [Win11KeyInputNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        $windowProcessId = [uint32] 0
        [void] [Win11KeyInputNative]::GetWindowThreadProcessId($hwnd, [ref] $windowProcessId)
        if ($windowProcessId -ne $script:Win11KeyInputTargetProcessId) {
            return $true
        }

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32.host') {
            $script:Win11KeyInputFoundHost = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11KeyInputNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:Win11KeyInputFoundHost
}

function Find-SurfaceWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:Win11KeyInputFoundSurface = [IntPtr]::Zero
    $callback = [Win11KeyInputNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32') {
            $script:Win11KeyInputFoundSurface = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11KeyInputNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:Win11KeyInputFoundSurface
}

function Wait-Until {
    param(
        [Parameter(Mandatory)] [scriptblock] $Condition,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [System.Diagnostics.Process] $Process
    )

    while ([DateTime]::UtcNow -lt $Deadline) {
        if ($null -ne $Process -and $Process.HasExited) {
            throw "winghostty exited while waiting for ${Description} (exit code $($Process.ExitCode))"
        }

        if (& $Condition) {
            return
        }

        Start-Sleep -Milliseconds 100
    }

    throw "Timed out waiting for $Description"
}

function Get-GuiThreadInfo {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $processId = [uint32] 0
    $threadId = [Win11KeyInputNative]::GetWindowThreadProcessId($Hwnd, [ref] $processId)
    if ($threadId -eq 0) {
        return $null
    }

    $info = [Win11KeyInputNative+GUITHREADINFO]::new()
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type] [Win11KeyInputNative+GUITHREADINFO])
    if (-not [Win11KeyInputNative]::GetGUIThreadInfo($threadId, [ref] $info)) {
        return $null
    }

    return [pscustomobject]@{
        ThreadId = $threadId
        ProcessId = $processId
        ActiveHwnd = $info.hwndActive
        FocusHwnd = $info.hwndFocus
    }
}

function New-KeyLParam {
    param(
        [Parameter(Mandatory)] [UInt16] $ScanCode,
        [switch] $KeyUp
    )

    [int32] $bits = 1 -bor (($ScanCode -band 0xffff) -shl 16)
    if ($KeyUp) {
        $bits = $bits -bor (-1073741824)
    }

    return [IntPtr] $bits
}

function Send-VirtualKey {
    param(
        [Parameter(Mandatory)] [UInt16] $VirtualKey
    )

    $scanCode = [Win11KeyInputNative]::MapVirtualKeyW([uint32] $VirtualKey, [uint32] $MAPVK_VK_TO_VSC)
    if ($scanCode -eq 0) {
        throw "MapVirtualKeyW returned 0 for VK=$VirtualKey"
    }

    $inputs = [Win11KeyInputNative+INPUT[]]::new(2)

    $inputs[0].type = $INPUT_KEYBOARD
    $inputs[0].U.ki.wVk = $VirtualKey
    $inputs[0].U.ki.wScan = [uint16] $scanCode
    $inputs[0].U.ki.dwFlags = 0

    $inputs[1].type = $INPUT_KEYBOARD
    $inputs[1].U.ki.wVk = $VirtualKey
    $inputs[1].U.ki.wScan = [uint16] $scanCode
    $inputs[1].U.ki.dwFlags = $KEYEVENTF_KEYUP

    $sent = [Win11KeyInputNative]::SendInput(
        [uint32] $inputs.Length,
        $inputs,
        [Runtime.InteropServices.Marshal]::SizeOf([type] [Win11KeyInputNative+INPUT])
    )
    if ($sent -ne $inputs.Length) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SendInput sent $sent/$($inputs.Length) events (Win32 error $lastError)"
    }
}

function Send-VirtualKeyMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [UInt16] $VirtualKey,
        [UInt16] $CharCode = 0
    )

    $scanCode = [Win11KeyInputNative]::MapVirtualKeyW([uint32] $VirtualKey, [uint32] $MAPVK_VK_TO_VSC)
    if ($scanCode -eq 0) {
        throw "MapVirtualKeyW returned 0 for VK=$VirtualKey"
    }

    [void] [Win11KeyInputNative]::SendMessageW(
        $Hwnd,
        $WM_KEYDOWN,
        [UIntPtr]([uint64] $VirtualKey),
        (New-KeyLParam -ScanCode ([uint16] $scanCode))
    )
    if ($CharCode -ne 0) {
        [void] [Win11KeyInputNative]::SendMessageW(
            $Hwnd,
            $WM_CHAR,
            [UIntPtr]([uint64] $CharCode),
            (New-KeyLParam -ScanCode ([uint16] $scanCode))
        )
    }
    [void] [Win11KeyInputNative]::SendMessageW(
        $Hwnd,
        $WM_KEYUP,
        [UIntPtr]([uint64] $VirtualKey),
        (New-KeyLParam -ScanCode ([uint16] $scanCode) -KeyUp)
    )
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'key-input' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-key-input-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-key-input-stderr.log'
$resultPath = Join-Path $layout.Temp 'interactive-win11-key-input-result.json'
$preReadKeyReadyPath = Join-Path $layout.Temp 'interactive-win11-key-input-ready.txt'
$preReadKeyStatePath = Join-Path $layout.Temp 'interactive-win11-key-input-state.json'
$preReadKeyTracePath = Join-Path $layout.Temp 'interactive-win11-key-input-boo-trace.txt'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-key-input-payload.ps1'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath
Remove-Item -LiteralPath $stdoutPath, $stderrPath, $resultPath -ErrorAction SilentlyContinue

$commandPrelude = ''
if ($RunBooFirst) {
    Remove-Item -LiteralPath $preReadKeyReadyPath, $preReadKeyStatePath, $preReadKeyTracePath -ErrorAction SilentlyContinue
    $commandPrelude = @'
$winghosttyCommand = Get-Command winghostty -ErrorAction Stop
[ordered]@{
    phase = 'before-boo'
    commandSource = $winghosttyCommand.Source
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII
$booStart = Get-Date
try {
    $env:WINGHOSTTY_BOO_AUTO_EXIT_MS = '1000'
    $env:WINGHOSTTY_BOO_STATE_FILE = '__TRACE_PATH__'
    & winghostty +boo
    $booExitCode = $LASTEXITCODE
}
finally {
    Remove-Item Env:WINGHOSTTY_BOO_AUTO_EXIT_MS -ErrorAction SilentlyContinue
    Remove-Item Env:WINGHOSTTY_BOO_STATE_FILE -ErrorAction SilentlyContinue
}
[ordered]@{
    phase = 'after-boo'
    commandSource = $winghosttyCommand.Source
    exitCode = $booExitCode
    elapsedMs = [int]((Get-Date) - $booStart).TotalMilliseconds
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII
'ready' | Set-Content -LiteralPath '__READY_PATH__' -Encoding ASCII
'@
    $preReadKeyStatePathLiteral = $preReadKeyStatePath.Replace("'", "''")
    $preReadKeyTracePathLiteral = $preReadKeyTracePath.Replace("'", "''")
    $preReadKeyReadyPathLiteral = $preReadKeyReadyPath.Replace("'", "''")
    $commandPrelude = $commandPrelude.
        Replace('__STATE_PATH__', $preReadKeyStatePathLiteral).
        Replace('__TRACE_PATH__', $preReadKeyTracePathLiteral).
        Replace('__READY_PATH__', $preReadKeyReadyPathLiteral)
}

$resultPathLiteral = $resultPath.Replace("'", "''")
@"
$commandPrelude
`$key = [Console]::ReadKey(`$true)
[ordered]@{
    keyCharCode = [int][char]`$key.KeyChar
    keyChar = [string]`$key.KeyChar
    key = `$key.Key.ToString()
    modifiers = `$key.Modifiers.ToString()
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '$resultPathLiteral' -Encoding ASCII
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

$launchArgs = @(
    (Get-InteractiveWin11LaunchArguments -Layout $layout)
    '--config-default-files=false'
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
)

$expectedKeyCharCode, $expectedKeyName, $virtualKey, $charCode = switch ($Key) {
    'a' { 97, 'A', $VK_A, 97 }
    'space' { 32, 'Spacebar', $VK_SPACE, 32 }
}

$process = Start-Process -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        (Find-HostWindow -ProcessId $process.Id) -ne [IntPtr]::Zero
    }

    $hostHwnd = Find-HostWindow -ProcessId $process.Id
    [void] [Win11KeyInputNative]::ShowWindow($hostHwnd, $SW_RESTORE)
    [void] [Win11KeyInputNative]::SetForegroundWindow($hostHwnd)

    Wait-Until -Deadline $deadline -Description 'surface child window' -Process $process -Condition {
        (Find-SurfaceWindow -Parent $hostHwnd) -ne [IntPtr]::Zero
    }

    $surfaceHwnd = Find-SurfaceWindow -Parent $hostHwnd
    $messageTargetHwnd = if ($Route -eq 'host') { $hostHwnd } else { $surfaceHwnd }
    $deliveryMode = 'message'
    Start-Sleep -Milliseconds 300

    if ($RunBooFirst) {
        try {
            Wait-Until -Deadline $deadline -Description 'post-boo readiness file' -Process $process -Condition {
                Test-Path -LiteralPath $preReadKeyReadyPath
            }
        }
        catch {
            $stateSummary = if (Test-Path -LiteralPath $preReadKeyStatePath) {
                Get-Content -LiteralPath $preReadKeyStatePath -Raw
            } else {
                '<missing>'
            }
            $traceSummary = if (Test-Path -LiteralPath $preReadKeyTracePath) {
                Get-Content -LiteralPath $preReadKeyTracePath -Raw
            } else {
                '<missing>'
            }
            throw "$($_.Exception.Message) (state=$stateSummary trace=$traceSummary)"
        }

        $preReadKeyState = Get-Content -LiteralPath $preReadKeyStatePath -Raw | ConvertFrom-Json
        if ($preReadKeyState.exitCode -ne 0) {
            throw "winghostty +boo exited with code $($preReadKeyState.exitCode) from $($preReadKeyState.commandSource)"
        }

        Start-Sleep -Milliseconds 300
    }

    $sendInputError = $null
    try {
        [Microsoft.VisualBasic.Interaction]::AppActivate($process.Id) | Out-Null
        Start-Sleep -Milliseconds 300
        Send-VirtualKey -VirtualKey $virtualKey

        $sendInputDeadline = [DateTime]::UtcNow.AddSeconds(2)
        while ([DateTime]::UtcNow -lt $sendInputDeadline) {
            if (Test-Path -LiteralPath $resultPath) {
                $deliveryMode = 'sendinput'
                break
            }

            if ($process.HasExited) {
                break
            }

            Start-Sleep -Milliseconds 100
        }
    }
    catch {
        $sendInputError = $_.Exception.Message
    }

    if (-not (Test-Path -LiteralPath $resultPath)) {
        Send-VirtualKeyMessage -Hwnd $messageTargetHwnd -VirtualKey $virtualKey -CharCode ([uint16] $charCode)
    }

    Wait-Until -Deadline $deadline -Description 'key input result file' -Process $process -Condition {
        Test-Path -LiteralPath $resultPath
    }

    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($result.keyCharCode -ne $expectedKeyCharCode -or $result.key -ne $expectedKeyName) {
        $sendInputContext = if ($sendInputError) { ", sendinput-error=$sendInputError" } else { '' }
        throw "unexpected key input result (mode=$deliveryMode): $($result | ConvertTo-Json -Compress)$sendInputContext"
    }

    $guiThreadInfo = Get-GuiThreadInfo -Hwnd $hostHwnd
    $focusClass = if ($null -ne $guiThreadInfo -and $guiThreadInfo.FocusHwnd -ne [IntPtr]::Zero) {
        Get-WindowClassName -Hwnd $guiThreadInfo.FocusHwnd
    }
    else {
        '<unavailable>'
    }

    $scenario = if ($RunBooFirst) { 'post-boo' } else { 'direct' }
    $extra = if ($RunBooFirst) {
        ", pre-readkey-state=$preReadKeyStatePath, pre-readkey-ready=$preReadKeyReadyPath"
    }
    else {
        ''
    }
    Write-Host ("interactive-win11 key-input validation: PASS (scenario={0}, key={1}, route={2}, mode={3}, focus-class={4}, stdout={5}, stderr={6}, result={7}{8})" -f $scenario, $Key, $Route, $deliveryMode, $focusClass, $stdoutPath, $stderrPath, $resultPath, $extra)
}
finally {
    Stop-InteractiveWin11Process -Process $process
}
