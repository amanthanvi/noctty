param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [string] $CliAction = '+help',
    [string] $CommandText = '',
    [string] $ExePathOverride = '',
    [switch] $RunBooFirst,
    [int] $SeedTabs = 1,
    [int] $TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

if ($SeedTabs -le 0) {
    throw 'SeedTabs must be greater than 0.'
}

if ([string]::IsNullOrWhiteSpace($CliAction)) {
    throw 'CliAction must not be empty.'
}

$typedCommandText = if ([string]::IsNullOrWhiteSpace($CommandText)) {
    "winghostty $CliAction"
}
else {
    $CommandText
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_SHELL_COMMAND_LIVE_BOOTSTRAPPED) {
    $forwardedArgs = @('-CliAction', $CliAction, '-SeedTabs', $SeedTabs.ToString(), '-TimeoutSeconds', $TimeoutSeconds.ToString())
    if (-not [string]::IsNullOrWhiteSpace($CommandText)) {
        $forwardedArgs += @('-CommandText', $CommandText)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExePathOverride)) {
        $forwardedArgs += @('-ExePathOverride', $ExePathOverride)
    }
    if ($RunBooFirst) { $forwardedArgs += '-RunBooFirst' }
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_SHELL_COMMAND_LIVE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win11ShellCommandLiveNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern int GetDlgCtrlID(IntPtr hwndCtl);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern short VkKeyScanW(char ch);
}
'@
Add-Type -AssemblyName System.Drawing

$MAPVK_VK_TO_VSC = 0
$SMTO_ABORTIFHUNG = 0x0002
$SW_RESTORE = 9
$SWP_NOMOVE = 0x0002
$SWP_NOSIZE = 0x0001
$SWP_SHOWWINDOW = 0x0040
$VISIBLE_TAB_MIN_ID = 1000
$VISIBLE_TAB_MAX_ID_EXCLUSIVE = 1900
$HOST_COMMAND_NEW_TAB_ID = 1904
$SEND_TIMEOUT_MS = 1000
$BOO_AUTO_EXIT_MS = 1000
$KEY_STROKE_DELAY_MS = 15
$CAPTURE_PROMOTION_DELAY_MS = 150
$CAPTURE_SETTLE_MS = 300
$POST_COMMAND_CAPTURE_SETTLE_MS = 1500
$IMAGE_DELTA_SAMPLE_STEP = 4
$IMAGE_DELTA_CHANNEL_THRESHOLD = 24
$MIN_CHANGED_PIXELS = 500
$VK_CONTROL = 0x11
$VK_MENU = 0x12
$VK_RETURN = 0x0D
$VK_SHIFT = 0x10
$WM_CHAR = 0x0102
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$HWND_TOPMOST = [IntPtr] (-1)
$HWND_NOTOPMOST = [IntPtr] (-2)

function New-WParam {
    param(
        [Parameter(Mandatory)] [int] $Low,
        [int] $High = 0
    )

    return [UIntPtr]([uint64](((($High -band 0xffff) -shl 16) -bor ($Low -band 0xffff)) -band 0xffffffff))
}

function Get-WindowClassName {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $builder = [System.Text.StringBuilder]::new(256)
    [void] [Win11ShellCommandLiveNative]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Find-HostWindow {
    param(
        [Parameter(Mandatory)] [int] $ProcessId
    )

    $script:Win11ShellCommandLiveProcessId = [uint32] $ProcessId
    $script:Win11ShellCommandLiveHost = [IntPtr]::Zero
    $callback = [Win11ShellCommandLiveNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        $windowProcessId = [uint32] 0
        [void] [Win11ShellCommandLiveNative]::GetWindowThreadProcessId($hwnd, [ref] $windowProcessId)
        if ($windowProcessId -ne $script:Win11ShellCommandLiveProcessId) {
            return $true
        }

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32.host') {
            $script:Win11ShellCommandLiveHost = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11ShellCommandLiveNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:Win11ShellCommandLiveHost
}

function Find-SurfaceWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:Win11ShellCommandLiveSurface = [IntPtr]::Zero
    $callback = [Win11ShellCommandLiveNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32') {
            $script:Win11ShellCommandLiveSurface = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11ShellCommandLiveNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:Win11ShellCommandLiveSurface
}

function Get-VisibleChildControls {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $controls = [System.Collections.Generic.List[object]]::new()
    $callback = [Win11ShellCommandLiveNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ([Win11ShellCommandLiveNative]::IsWindowVisible($hwnd)) {
            $controls.Add([pscustomobject]@{
                Hwnd = $hwnd
                Id = [Win11ShellCommandLiveNative]::GetDlgCtrlID($hwnd)
            }) | Out-Null
        }

        return $true
    }

    [void] [Win11ShellCommandLiveNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $controls.ToArray()
}

function Get-VisibleTabButtons {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return Get-VisibleChildControls -Parent $Parent |
        Where-Object { $_.Id -ge $VISIBLE_TAB_MIN_ID -and $_.Id -lt $VISIBLE_TAB_MAX_ID_EXCLUSIVE } |
        Sort-Object Id
}

function Get-VisibleTabCount {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleTabButtons -Parent $Parent).Count
}

function Invoke-HostCommand {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $CommandId
    )

    $sendResult = [UIntPtr]::Zero
    [void] [Win11ShellCommandLiveNative]::SendMessageTimeoutW(
        $HostHwnd,
        0x0111,
        (New-WParam -Low $CommandId),
        [IntPtr]::Zero,
        [uint32] $SMTO_ABORTIFHUNG,
        [uint32] $SEND_TIMEOUT_MS,
        [ref] $sendResult
    )
}

function Activate-TabIndex {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $TabIndex
    )

    $tab = Get-VisibleTabButtons -Parent $HostHwnd | Select-Object -Index $TabIndex
    if ($null -eq $tab) {
        throw "tab index $TabIndex was not visible"
    }

    $sendResult = [UIntPtr]::Zero
    [void] [Win11ShellCommandLiveNative]::SendMessageTimeoutW(
        $tab.Hwnd,
        0x0201,
        [UIntPtr]::Zero,
        [IntPtr]::Zero,
        [uint32] $SMTO_ABORTIFHUNG,
        [uint32] $SEND_TIMEOUT_MS,
        [ref] $sendResult
    )
    $sendResult = [UIntPtr]::Zero
    [void] [Win11ShellCommandLiveNative]::SendMessageTimeoutW(
        $tab.Hwnd,
        0x0202,
        [UIntPtr]::Zero,
        [IntPtr]::Zero,
        [uint32] $SMTO_ABORTIFHUNG,
        [uint32] $SEND_TIMEOUT_MS,
        [ref] $sendResult
    )
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

function Send-KeyMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [UInt16] $VirtualKey,
        [UInt16] $CharCode = 0,
        [switch] $KeyUp
    )

    $scanCode = [Win11ShellCommandLiveNative]::MapVirtualKeyW([uint32] $VirtualKey, [uint32] $MAPVK_VK_TO_VSC)
    if ($scanCode -eq 0) {
        throw "MapVirtualKeyW returned 0 for VK=$VirtualKey"
    }

    $message = if ($KeyUp) { $WM_KEYUP } else { $WM_KEYDOWN }
    $sendResult = [UIntPtr]::Zero
    $sendStatus = [Win11ShellCommandLiveNative]::SendMessageTimeoutW(
        $Hwnd,
        [uint32] $message,
        [UIntPtr]([uint64] $VirtualKey),
        (New-KeyLParam -ScanCode ([uint16] $scanCode) -KeyUp:$KeyUp),
        [uint32] $SMTO_ABORTIFHUNG,
        [uint32] $SEND_TIMEOUT_MS,
        [ref] $sendResult
    )
    if ($sendStatus -eq [IntPtr]::Zero) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SendMessageTimeoutW failed for message=$message hwnd=$Hwnd vk=$VirtualKey error=$lastError"
    }

    if (-not $KeyUp -and $CharCode -ne 0) {
        $sendResult = [UIntPtr]::Zero
        $sendStatus = [Win11ShellCommandLiveNative]::SendMessageTimeoutW(
            $Hwnd,
            [uint32] $WM_CHAR,
            [UIntPtr]([uint64] $CharCode),
            (New-KeyLParam -ScanCode ([uint16] $scanCode)),
            [uint32] $SMTO_ABORTIFHUNG,
            [uint32] $SEND_TIMEOUT_MS,
            [ref] $sendResult
        )
        if ($sendStatus -eq [IntPtr]::Zero) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "SendMessageTimeoutW failed for WM_CHAR hwnd=$Hwnd char=$CharCode error=$lastError"
        }
    }
}

function Send-ModifiedChar {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [char] $Character
    )

    $vkScan = [Win11ShellCommandLiveNative]::VkKeyScanW($Character)
    if ($vkScan -eq -1) {
        throw "VkKeyScanW failed for character '$Character'"
    }

    $virtualKey = [uint16] ($vkScan -band 0xff)
    $modifierMask = (($vkScan -shr 8) -band 0xff)
    $modifiers = @()
    if ($modifierMask -band 0x02) { $modifiers += [uint16] $VK_CONTROL }
    if ($modifierMask -band 0x04) { $modifiers += [uint16] $VK_MENU }
    if ($modifierMask -band 0x01) { $modifiers += [uint16] $VK_SHIFT }

    foreach ($modifier in $modifiers) {
        Send-KeyMessage -Hwnd $Hwnd -VirtualKey $modifier
    }

    try {
        Send-KeyMessage -Hwnd $Hwnd -VirtualKey $virtualKey -CharCode ([uint16] [int] $Character)
        Send-KeyMessage -Hwnd $Hwnd -VirtualKey $virtualKey -KeyUp
    }
    finally {
        for ($i = $modifiers.Count - 1; $i -ge 0; $i -= 1) {
            $modifier = $modifiers[$i]
            Send-KeyMessage -Hwnd $Hwnd -VirtualKey $modifier -KeyUp
        }
    }
}

function Send-Line {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Text
    )

    foreach ($character in $Text.ToCharArray()) {
        Send-ModifiedChar -Hwnd $Hwnd -Character $character
        Start-Sleep -Milliseconds $KEY_STROKE_DELAY_MS
    }

    Send-KeyMessage -Hwnd $Hwnd -VirtualKey ([uint16] $VK_RETURN) -CharCode 13
    Send-KeyMessage -Hwnd $Hwnd -VirtualKey ([uint16] $VK_RETURN) -KeyUp
}

function Save-WindowCapture {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path
    )

    $rect = [Win11ShellCommandLiveNative+RECT]::new()
    if (-not [Win11ShellCommandLiveNative]::GetWindowRect($Hwnd, [ref] $rect)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetWindowRect failed for hwnd=$Hwnd (error=$lastError)"
    }

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        throw "Invalid capture rect width=$width height=$height for hwnd=$Hwnd"
    }

    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        }
        finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Promote-WindowForCapture {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    [void] [Win11ShellCommandLiveNative]::ShowWindow($Hwnd, $SW_RESTORE)
    [void] [Win11ShellCommandLiveNative]::SetWindowPos(
        $Hwnd,
        $HWND_TOPMOST,
        0,
        0,
        0,
        0,
        [uint32] ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)
    )
    [void] [Win11ShellCommandLiveNative]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds $CAPTURE_PROMOTION_DELAY_MS
}

function Measure-ImageDelta {
    param(
        [Parameter(Mandatory)] [string] $BeforePath,
        [Parameter(Mandatory)] [string] $AfterPath
    )

    $before = [System.Drawing.Bitmap]::new($BeforePath)
    $after = [System.Drawing.Bitmap]::new($AfterPath)
    try {
        if ($before.Width -ne $after.Width -or $before.Height -ne $after.Height) {
            throw "capture size mismatch before=$($before.Width)x$($before.Height) after=$($after.Width)x$($after.Height)"
        }

        $changedPixels = 0
        $sampledPixels = 0
        for ($y = 0; $y -lt $before.Height; $y += $IMAGE_DELTA_SAMPLE_STEP) {
            for ($x = 0; $x -lt $before.Width; $x += $IMAGE_DELTA_SAMPLE_STEP) {
                $beforePixel = $before.GetPixel($x, $y)
                $afterPixel = $after.GetPixel($x, $y)
                $sampledPixels += 1

                $delta = [Math]::Abs($beforePixel.R - $afterPixel.R) +
                    [Math]::Abs($beforePixel.G - $afterPixel.G) +
                    [Math]::Abs($beforePixel.B - $afterPixel.B)
                if ($delta -ge $IMAGE_DELTA_CHANNEL_THRESHOLD) {
                    $changedPixels += 1
                }
            }
        }

        return [pscustomobject]@{
            ChangedPixels = $changedPixels
            SampledPixels = $sampledPixels
        }
    }
    finally {
        $before.Dispose()
        $after.Dispose()
    }
}

$useRepoResources = [string]::IsNullOrWhiteSpace($ExePathOverride)
$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'shell-command-live' -ResetState:$ResetState -IncludeResourcesDir:$useRepoResources
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = if ([string]::IsNullOrWhiteSpace($ExePathOverride)) {
    Get-InteractiveWin11ExePath -RepoRoot $repoRoot
}
else {
    Get-InteractiveWin11NormalizedPath -Path $ExePathOverride
}
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = if ([string]::IsNullOrWhiteSpace($ExePathOverride)) {
    Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
}
else {
    'reuse'
}
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-shell-command-live-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-shell-command-live-stderr.log'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-shell-command-live.cmd'
$readyPath = Join-Path $layout.Temp 'interactive-win11-shell-command-live-ready.txt'
$controlPath = Join-Path $layout.Temp 'interactive-win11-shell-command-live-control.txt'
$resolvedPath = Join-Path $layout.Temp 'interactive-win11-shell-command-live-resolved.txt'
$postPath = Join-Path $layout.Temp 'interactive-win11-shell-command-live-post.txt'
$beforeCapturePath = Join-Path $layout.Temp 'interactive-win11-shell-command-live-before.png'
$afterCapturePath = Join-Path $layout.Temp 'interactive-win11-shell-command-live-after.png'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

if (-not [string]::IsNullOrWhiteSpace($ExePathOverride)) {
    $packagedResourcesDir = Join-Path (Split-Path -Parent $exePath) 'share\ghostty'
    if (Test-Path -LiteralPath $packagedResourcesDir -PathType Container) {
        [System.Environment]::SetEnvironmentVariable(
            'GHOSTTY_RESOURCES_DIR',
            (Get-InteractiveWin11NormalizedPath -Path $packagedResourcesDir),
            'Process'
        )
    }
}

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $payloadPath, $readyPath, $controlPath, $resolvedPath, $postPath, $beforeCapturePath, $afterCapturePath -ErrorAction SilentlyContinue

@(
    '@echo off'
    "cd /d `"$($layout.Temp)`""
    if ($RunBooFirst) { "set WINGHOSTTY_BOO_AUTO_EXIT_MS=$BOO_AUTO_EXIT_MS" }
    if ($RunBooFirst) { 'winghostty +boo' }
    if ($RunBooFirst) { 'set WINGHOSTTY_BOO_AUTO_EXIT_MS=' }
    'echo READY>interactive-win11-shell-command-live-ready.txt'
) | Set-Content -LiteralPath $payloadPath -Encoding ASCII

$launchArgs = @(
    (Get-InteractiveWin11LaunchArguments -Layout $layout)
    '--config-default-files=false'
    '-e'
    'cmd.exe'
    '/d'
    '/q'
    '/k'
    $payloadPath
)

$process = Start-Process -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$hostHwnd = [IntPtr]::Zero
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    Wait-Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        (Find-HostWindow -ProcessId $process.Id) -ne [IntPtr]::Zero
    }

    $hostHwnd = Find-HostWindow -ProcessId $process.Id
    Promote-WindowForCapture -Hwnd $hostHwnd

    Wait-Until -Deadline $deadline -Description 'surface child window' -Process $process -Condition {
        (Find-SurfaceWindow -Parent $hostHwnd) -ne [IntPtr]::Zero
    }

    while ((Get-VisibleTabCount -Parent $hostHwnd) -lt $SeedTabs) {
        $targetTabCount = (Get-VisibleTabCount -Parent $hostHwnd) + 1
        Invoke-HostCommand -HostHwnd $hostHwnd -CommandId $HOST_COMMAND_NEW_TAB_ID
        Wait-Until -Deadline $deadline -Description "seed tabs ($targetTabCount/$SeedTabs)" -Process $process -Condition {
            (Get-VisibleTabCount -Parent $hostHwnd) -ge $targetTabCount
        }
    }

    Activate-TabIndex -HostHwnd $hostHwnd -TabIndex 0

    Wait-Until -Deadline $deadline -Description 'shell ready file' -Process $process -Condition {
        Test-Path -LiteralPath $readyPath
    }

    $surfaceHwnd = Find-SurfaceWindow -Parent $hostHwnd
    Start-Sleep -Milliseconds $CAPTURE_SETTLE_MS
    Promote-WindowForCapture -Hwnd $hostHwnd
    Save-WindowCapture -Hwnd $surfaceHwnd -Path $beforeCapturePath

    Send-Line -Hwnd $surfaceHwnd -Text 'echo READY>interactive-win11-shell-command-live-control.txt'
    Wait-Until -Deadline $deadline -Description 'control output file' -Process $process -Condition {
        Test-Path -LiteralPath $controlPath
    }
    Start-Sleep -Milliseconds $CAPTURE_SETTLE_MS

    Send-Line -Hwnd $surfaceHwnd -Text 'where winghostty>interactive-win11-shell-command-live-resolved.txt'
    Wait-Until -Deadline $deadline -Description 'command resolution file' -Process $process -Condition {
        Test-Path -LiteralPath $resolvedPath
    }
    Start-Sleep -Milliseconds $CAPTURE_SETTLE_MS

    $resolved = @(Get-Content -LiteralPath $resolvedPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $expectedCommandDir = Split-Path -Parent $exePath
    $resolvedFirstDir = if ($resolved.Count -gt 0) { Split-Path -Parent $resolved[0] } else { '' }
    $resolvedFirstName = if ($resolved.Count -gt 0) { [System.IO.Path]::GetFileName($resolved[0]) } else { '' }
    if ($resolved.Count -lt 1) {
        throw "live shell command resolution produced no output ($resolvedPath)"
    }
    if (
        (-not $resolvedFirstDir.Equals($expectedCommandDir, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ($resolvedFirstName -notin @('winghostty.com', 'winghostty.exe'))
    ) {
        throw "live shell resolved unexpected first winghostty command: $($resolved[0]) (expected same install dir as $exePath)"
    }

    Send-Line -Hwnd $surfaceHwnd -Text ("{0} & echo POST>interactive-win11-shell-command-live-post.txt" -f $typedCommandText)
    Start-Sleep -Milliseconds $POST_COMMAND_CAPTURE_SETTLE_MS
    Promote-WindowForCapture -Hwnd $hostHwnd
    Save-WindowCapture -Hwnd $surfaceHwnd -Path $afterCapturePath
    $imageDelta = Measure-ImageDelta -BeforePath $beforeCapturePath -AfterPath $afterCapturePath
    if ($imageDelta.ChangedPixels -lt $MIN_CHANGED_PIXELS) {
        throw "live shell command '$typedCommandText' produced too little visible change (changed=$($imageDelta.ChangedPixels), sampled=$($imageDelta.SampledPixels))"
    }

    Wait-Until -Deadline $deadline -Description 'post-help output file' -Process $process -Condition {
        Test-Path -LiteralPath $postPath
    }

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match 'error starting IO thread:|panic: reached unreachable code') {
        throw 'winghostty live shell command run reported a runtime failure'
    }

    Write-Host ("interactive-win11 shell command live validation: PASS (command={0}, action={1}, run_boo_first={2}, seed_tabs={3}, changed={4}, sampled={5}, stdout={6}, stderr={7}, ready={8}, control={9}, resolved={10}, post={11}, before={12}, after={13})" -f $typedCommandText, $CliAction, $RunBooFirst, $SeedTabs, $imageDelta.ChangedPixels, $imageDelta.SampledPixels, $stdoutPath, $stderrPath, $readyPath, $controlPath, $resolvedPath, $postPath, $beforeCapturePath, $afterCapturePath)
}
finally {
    if ($hostHwnd -ne [IntPtr]::Zero) {
        [void] [Win11ShellCommandLiveNative]::SetWindowPos(
            $hostHwnd,
            $HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            [uint32] ($SWP_NOMOVE -bor $SWP_NOSIZE)
        )
    }

    Stop-InteractiveWin11Process -Process $process
}
