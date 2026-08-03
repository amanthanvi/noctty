param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [ValidateSet(
        'a',
        'space',
        'unicode-bmp',
        'unicode-supplementary',
        'unicode-burst',
        'unicode-cr',
        'unicode-lf',
        'unicode-tab',
        'unicode-backspace',
        'unicode-escape'
    )] [string] $Key = 'a',
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

function Get-KeyInputScenarioSlug {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            'a',
            'space',
            'unicode-bmp',
            'unicode-supplementary',
            'unicode-burst',
            'unicode-cr',
            'unicode-lf',
            'unicode-tab',
            'unicode-backspace',
            'unicode-escape'
        )]
        [string] $Key,
        [switch] $PostBoo
    )

    $slug = switch ($Key) {
        'a' { 'classic-a' }
        'space' { 'classic-space' }
        'unicode-bmp' { 'bmp' }
        'unicode-supplementary' { 'supplementary' }
        'unicode-burst' { 'burst' }
        'unicode-cr' { 'control-cr' }
        'unicode-lf' { 'control-lf' }
        'unicode-tab' { 'control-tab' }
        'unicode-backspace' { 'control-backspace' }
        'unicode-escape' { 'control-escape' }
    }
    if ($PostBoo) {
        return "$slug-post-boo"
    }
    return $slug
}

$scenarioSlug = Get-KeyInputScenarioSlug -Key $Key -PostBoo:$RunBooFirst

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_KEY_INPUT_BOOTSTRAPPED) {
    $forwardedArgs = @('-Key', $Key, '-TimeoutSeconds', $TimeoutSeconds.ToString())
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

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)]
        public KEYBDINPUT ki;
        [FieldOffset(0)]
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION U;
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

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint cInputs, INPUT[] pInputs, int cbSize);

    public static bool ForceForeground(IntPtr hWnd) {
        uint ignored;
        uint targetThread = GetWindowThreadProcessId(hWnd, out ignored);
        IntPtr foreground = GetForegroundWindow();
        uint foregroundThread = foreground == IntPtr.Zero ? 0 : GetWindowThreadProcessId(foreground, out ignored);
        uint currentThread = GetCurrentThreadId();
        bool attachedForeground = foregroundThread != 0 && foregroundThread != currentThread && AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedTarget = targetThread != 0 && targetThread != currentThread && AttachThreadInput(currentThread, targetThread, true);
        try {
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            return GetForegroundWindow() == hWnd;
        }
        finally {
            if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }

    public static uint SendUnicodeInput(ushort[] codeUnits) {
        const uint INPUT_KEYBOARD = 1;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_UNICODE = 0x0004;
        INPUT[] inputs = new INPUT[codeUnits.Length * 2];
        for (int i = 0; i < codeUnits.Length; i++) {
            KEYBDINPUT down = new KEYBDINPUT {
                wVk = 0,
                wScan = codeUnits[i],
                dwFlags = KEYEVENTF_UNICODE,
                time = 0,
                dwExtraInfo = UIntPtr.Zero
            };
            KEYBDINPUT up = down;
            up.dwFlags |= KEYEVENTF_KEYUP;
            inputs[i * 2] = new INPUT {
                type = INPUT_KEYBOARD,
                U = new INPUTUNION { ki = down }
            };
            inputs[(i * 2) + 1] = new INPUT {
                type = INPUT_KEYBOARD,
                U = new INPUTUNION { ki = up }
            };
        }

        uint inserted = SendInput(
            (uint)inputs.Length,
            inputs,
            Marshal.SizeOf(typeof(INPUT))
        );
        if (inserted != (uint)inputs.Length) {
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(),
                String.Format("SendInput inserted {0} of {1} Unicode keyboard events", inserted, inputs.Length)
            );
        }
        return inserted;
    }

}
'@

$MAPVK_VK_TO_VSC = 0
$SW_RESTORE = 9
$VK_A = 0x41
$VK_ESCAPE = 0x1B
$VK_SPACE = 0x20
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_CHAR = 0x0102
$UNICODE_SENTINEL = [uint16]0xE000

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

function Send-VirtualKeyMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [UInt16] $VirtualKey,
        [UInt16] $CharCode = 0,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $scanCode = [Win11KeyInputNative]::MapVirtualKeyW([uint32] $VirtualKey, [uint32] $MAPVK_VK_TO_VSC)
    if ($scanCode -eq 0) {
        throw "MapVirtualKeyW returned 0 for VK=$VirtualKey"
    }

    [void](Invoke-InteractiveWin11Message `
        -Hwnd $Hwnd `
        -Message $WM_KEYDOWN `
        -WParam ([UIntPtr]([uint64] $VirtualKey)) `
        -LParam (New-KeyLParam -ScanCode ([uint16] $scanCode)) `
        -Deadline $Deadline `
        -Process $Process `
        -Description "WM_KEYDOWN vk=$VirtualKey")
    if ($CharCode -ne 0) {
        [void](Invoke-InteractiveWin11Message `
            -Hwnd $Hwnd `
            -Message $WM_CHAR `
            -WParam ([UIntPtr]([uint64] $CharCode)) `
            -LParam (New-KeyLParam -ScanCode ([uint16] $scanCode)) `
            -Deadline $Deadline `
            -Process $Process `
            -Description "WM_CHAR char=$CharCode")
    }
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $Hwnd `
        -Message $WM_KEYUP `
        -WParam ([UIntPtr]([uint64] $VirtualKey)) `
        -LParam (New-KeyLParam -ScanCode ([uint16] $scanCode) -KeyUp) `
        -Deadline $Deadline `
        -Process $Process `
        -Description "WM_KEYUP vk=$VirtualKey")
}

function Send-UnicodeInput {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [UInt16[]] $CodeUnits,
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    Start-Sleep -Milliseconds 100
    if (
        [Win11KeyInputNative]::GetForegroundWindow() -ne $Hwnd -and
        -not [Win11KeyInputNative]::ForceForeground($Hwnd)
    ) {
        throw "Failed to foreground terminal before Unicode input"
    }

    [uint16[]] $terminated = @($CodeUnits + $UNICODE_SENTINEL)
    $inserted = [Win11KeyInputNative]::SendUnicodeInput($terminated)
    $expectedEvents = [uint32]($terminated.Length * 2)
    if ($inserted -ne $expectedEvents) {
        throw "SendInput inserted $inserted of $expectedEvents Unicode keyboard events"
    }
}

$artifactPrefix = "interactive-win11-key-input-$scenarioSlug"
$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName "key-input-$scenarioSlug" -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs "$artifactPrefix-stdout.log"
$stderrPath = Join-Path $layout.Logs "$artifactPrefix-stderr.log"
$resultPath = Join-Path $layout.Temp "$artifactPrefix-result.json"
$deliveryTracePath = Join-Path $layout.Temp "$artifactPrefix-delivery.json"
$inputReadyPath = Join-Path $layout.Temp "$artifactPrefix-read-ready.txt"
$preReadKeyReadyPath = Join-Path $layout.Temp "$artifactPrefix-boo-ready.txt"
$preReadKeyStatePath = Join-Path $layout.Temp "$artifactPrefix-boo-state.json"
$preReadKeyTracePath = Join-Path $layout.Temp "$artifactPrefix-boo-trace.txt"
$payloadPath = Join-Path $layout.Temp "$artifactPrefix-payload.ps1"

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath
Remove-Item -LiteralPath $stdoutPath, $stderrPath, $resultPath, $deliveryTracePath, $inputReadyPath -ErrorAction SilentlyContinue

[uint16[]] $unicodeInputUnits = @()
switch ($Key) {
    'unicode-bmp' {
        $unicodeInputUnits = [uint16[]] @(0x03A9)
    }
    'unicode-supplementary' {
        $unicodeInputUnits = [uint16[]] @(0xD83D, 0xDE42)
    }
    'unicode-burst' {
        # Native coverage proves exact sequential delivery. The Zig
        # 256-authorization test owns deferred backlog capacity proof.
        $burstText = 'abcdefghijklmnopqrstuvwxyz012345' * 8
        if ($burstText.Length -ne 256) {
            throw "Unicode burst fixture must contain exactly 256 UTF-16 units; got $($burstText.Length)"
        }
        $unicodeInputUnits = [uint16[]] @(
            $burstText.ToCharArray() | ForEach-Object { [uint16][char] $_ }
        )
    }
    'unicode-cr' {
        $unicodeInputUnits = [uint16[]] @(0x000D)
    }
    'unicode-lf' {
        $unicodeInputUnits = [uint16[]] @(0x000A)
    }
    'unicode-tab' {
        $unicodeInputUnits = [uint16[]] @(0x0009)
    }
    'unicode-backspace' {
        $unicodeInputUnits = [uint16[]] @(0x0008)
    }
    'unicode-escape' {
        $unicodeInputUnits = [uint16[]] @(0x001B)
    }
}
$useUnicodeInput = $unicodeInputUnits.Length -ne 0
$useSequentialRead = $unicodeInputUnits.Length -ne 0
[uint16[]] $expectedReadUnits = @($unicodeInputUnits)
if ($Key -eq 'unicode-backspace') {
    # Terminal Backspace is encoded as DEL by the default terminal protocol.
    $expectedReadUnits = [uint16[]] @(0x007F)
}

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

$payloadBody = if ($useSequentialRead) {
    @'
'ready' | Set-Content -LiteralPath '__INPUT_READY_PATH__' -Encoding ASCII
$receivedUnits = New-Object 'System.Collections.Generic.List[int]'
while ($true) {
    $key = [Console]::ReadKey($true)
    $unit = [int][char]$key.KeyChar
    if ($unit -eq __UNICODE_SENTINEL__) {
        break
    }
    [void] $receivedUnits.Add($unit)
}
[ordered]@{
    utf16Units = @($receivedUnits.ToArray())
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '__RESULT_PATH__' -Encoding ASCII
'@
}
else {
    @'
'ready' | Set-Content -LiteralPath '__INPUT_READY_PATH__' -Encoding ASCII
$key = [Console]::ReadKey($true)
[ordered]@{
    keyCharCode = [int][char]$key.KeyChar
    keyChar = [string]$key.KeyChar
    key = $key.Key.ToString()
    modifiers = $key.Modifiers.ToString()
} | ConvertTo-Json -Compress | Set-Content -LiteralPath '__RESULT_PATH__' -Encoding ASCII
'@
}
$payloadBody = $payloadBody.
    Replace('__INPUT_READY_PATH__', $inputReadyPath.Replace("'", "''")).
    Replace('__RESULT_PATH__', $resultPath.Replace("'", "''")).
    Replace('__UNICODE_SENTINEL__', ([int] $UNICODE_SENTINEL).ToString())
@"
$commandPrelude
$payloadBody
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

$expectedKeyCharCode = $null
$expectedKeyName = $null
$virtualKey = $null
$charCode = $null
if (-not $useSequentialRead) {
    $expectedKeyCharCode, $expectedKeyName, $virtualKey, $charCode = switch ($Key) {
        'a' { 97, 'A', $VK_A, 97 }
        'space' { 32, 'Spacebar', $VK_SPACE, 32 }
    }
}

$process = Start-Process -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru
$keyInputProcessHandle = $process.Handle

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        (Find-HostWindow -ProcessId $process.Id) -ne [IntPtr]::Zero
    }

    $hostHwnd = Find-HostWindow -ProcessId $process.Id
    [void] [Win11KeyInputNative]::ShowWindow($hostHwnd, $SW_RESTORE)
    [void] [Win11KeyInputNative]::ForceForeground($hostHwnd)

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'surface child window' -Process $process -Condition {
        (Find-SurfaceWindow -Parent $hostHwnd) -ne [IntPtr]::Zero
    }

    $surfaceHwnd = Find-SurfaceWindow -Parent $hostHwnd
    $deliveryMode = if ($useUnicodeInput) {
        'sendinput-unicode'
    }
    else {
        'message'
    }
    Start-Sleep -Milliseconds 300

    if ($RunBooFirst) {
        try {
            Wait-InteractiveWin11Until -Deadline $deadline -Description 'post-boo readiness file' -Process $process -Condition {
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
        $expectedCommandDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $exePath))
        $actualCommandDir = [System.IO.Path]::GetFullPath((Split-Path -Parent ([string] $preReadKeyState.commandSource)))
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actualCommandDir, $expectedCommandDir)) {
            throw "winghostty +boo resolved from unexpected location '$($preReadKeyState.commandSource)' (expected dir '$expectedCommandDir', got '$actualCommandDir')"
        }

        Start-Sleep -Milliseconds 300
    }

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'child input readiness' -Process $process -Condition {
        Test-Path -LiteralPath $inputReadyPath
    }

    $inputSentAtUtc = [DateTime]::UtcNow
    $inputStopwatch = [Diagnostics.Stopwatch]::StartNew()
    if ($useSequentialRead) {
        [void] [Win11KeyInputNative]::ForceForeground($hostHwnd)
        Wait-InteractiveWin11Until -Deadline $deadline -Description 'focused terminal surface' -Process $process -Condition {
            if ([Win11KeyInputNative]::GetForegroundWindow() -ne $hostHwnd) {
                [void] [Win11KeyInputNative]::ForceForeground($hostHwnd)
                return $false
            }
            $info = Get-GuiThreadInfo -Hwnd $hostHwnd
            $focused = $null -ne $info -and
                $info.FocusHwnd -ne [IntPtr]::Zero -and
                (Get-WindowClassName -Hwnd $info.FocusHwnd) -eq 'winghostty.win32'
            if (-not $focused) {
                [void] [Win11KeyInputNative]::ForceForeground($hostHwnd)
            }
            return $focused
        }
        Send-UnicodeInput -CodeUnits $unicodeInputUnits -Hwnd $hostHwnd
    }
    else {
        Send-VirtualKeyMessage -Hwnd $surfaceHwnd -VirtualKey $virtualKey -CharCode ([uint16] $charCode) -Deadline $deadline -Process $process
    }

    $resultRef = [ref]$null
    $lastResultReadError = [ref]'result file has not appeared'
    $lastResultContent = [ref]'<missing>'
    $keyInputProcess = $process
    try {
        Wait-InteractiveWin11Until -Deadline $deadline -Description 'key input result file' -Condition {
            if (Test-Path -LiteralPath $resultPath) {
                try {
                    $content = Get-Content -LiteralPath $resultPath -Raw
                    $contentText = if ($null -eq $content) { '' } else { [string]$content }
                    $contentText = $contentText -replace '\s+', ' '
                    $lastResultContent.Value = if ($contentText.Length -gt 240) { $contentText.Substring(0, 240) + '...' } elseif ($contentText.Length -eq 0) { '<empty>' } else { $contentText }
                    $parsed = $content | ConvertFrom-Json
                    if ($null -ne $parsed) {
                        $resultRef.Value = $parsed
                        return $true
                    }
                    $lastResultReadError.Value = 'JSON parsed to null'
                }
                catch {
                    $lastResultReadError.Value = $_.Exception.Message
                }
            }
            $keyInputProcess.Refresh()
            if ($keyInputProcess.HasExited) {
                $exitCode = Get-InteractiveWin11ProcessExitCode -Process $keyInputProcess -ProcessHandle $keyInputProcessHandle
                throw "winghostty exited while waiting for key input result file (exit code $exitCode)"
            }
            return $false
        }
    }
    catch {
        throw "$($_.Exception.Message) (last result read error='$($lastResultReadError.Value)', content='$($lastResultContent.Value)')"
    }

    $result = $resultRef.Value
    $inputStopwatch.Stop()
    $inputObservedAtUtc = [DateTime]::UtcNow
    if ($useSequentialRead) {
        [int[]] $actualUnits = @($result.utf16Units | ForEach-Object { [int] $_ })
        $mismatchIndex = -1
        $comparedLength = [Math]::Min($expectedReadUnits.Length, $actualUnits.Length)
        for ($i = 0; $i -lt $comparedLength; $i++) {
            if ($actualUnits[$i] -ne $expectedReadUnits[$i]) {
                $mismatchIndex = $i
                break
            }
        }
        if ($mismatchIndex -lt 0 -and $actualUnits.Length -ne $expectedReadUnits.Length) {
            $mismatchIndex = $comparedLength
        }
        if ($mismatchIndex -ge 0) {
            $expectedAtMismatch = if ($mismatchIndex -lt $expectedReadUnits.Length) {
                [int] $expectedReadUnits[$mismatchIndex]
            } else {
                '<end>'
            }
            $actualAtMismatch = if ($mismatchIndex -lt $actualUnits.Length) {
                $actualUnits[$mismatchIndex]
            } else {
                '<end>'
            }
            throw "unexpected Unicode input result (mode=$deliveryMode key=$Key expected-units=$($expectedReadUnits.Length) actual-units=$($actualUnits.Length) mismatch-index=$mismatchIndex expected=$expectedAtMismatch actual=$actualAtMismatch)"
        }
    }
    elseif ($result.keyCharCode -ne $expectedKeyCharCode -or $result.key -ne $expectedKeyName) {
        throw "unexpected key input result (mode=$deliveryMode): $($result | ConvertTo-Json -Compress)"
    }

    [ordered]@{
        scenario = $scenarioSlug
        deliveryMode = $deliveryMode
        sentAtUtc = $inputSentAtUtc.ToString('o')
        observedAtUtc = $inputObservedAtUtc.ToString('o')
        elapsedMs = [int] $inputStopwatch.ElapsedMilliseconds
        injectedUtf16Units = if ($useSequentialRead) { @($unicodeInputUnits) } else { $null }
        expectedReadUtf16Units = if ($useSequentialRead) { @($expectedReadUnits) } else { @([int] $expectedKeyCharCode) }
        utf16Units = if ($useSequentialRead) { @($actualUnits) } else { @([int] $result.keyCharCode) }
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $deliveryTracePath -Encoding ASCII

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
    Write-Host ("interactive-win11 key-input validation: PASS (scenario={0}, input-scenario={1}, key={2}, mode={3}, input-elapsed-ms={4}, focus-class={5}, stdout={6}, stderr={7}, result={8}, delivery-trace={9}{10})" -f $scenario, $scenarioSlug, $Key, $deliveryMode, $inputStopwatch.ElapsedMilliseconds, $focusClass, $stdoutPath, $stderrPath, $resultPath, $deliveryTracePath, $extra)
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}
