param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [string] $CliAction = '+help',
    [string] $CommandText = '',
    [string] $ExePathOverride = '',
    [int] $SeedTabs = 1,
    [int] $TimeoutSeconds = 20,
    [switch] $ConfiguredScenariosOnly
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
    "noctty $CliAction"
}
else {
    $CommandText
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath
. (Join-Path $repoRoot 'scripts\interactive-win11-window-lib.ps1')

$forwardedArgs = @('-CliAction', $CliAction, '-SeedTabs', $SeedTabs.ToString(), '-TimeoutSeconds', $TimeoutSeconds.ToString())
if (-not [string]::IsNullOrWhiteSpace($CommandText)) {
    $forwardedArgs += @('-CommandText', $CommandText)
}
if (-not [string]::IsNullOrWhiteSpace($ExePathOverride)) {
    $forwardedArgs += @('-ExePathOverride', $ExePathOverride)
}
if ($Rebuild) { $forwardedArgs += '-Rebuild' }
if ($ResetState) { $forwardedArgs += '-ResetState' }
if ($ConfiguredScenariosOnly) { $forwardedArgs += '-ConfiguredScenariosOnly' }
Invoke-InteractiveWin11HarnessMain `
    -RepoRoot $repoRoot `
    -LauncherPath $launcherPath `
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_SHELL_COMMAND_LIVE_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

if (-not ('Win11ShellCommandLiveNative' -as [type])) {
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
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

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

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern short VkKeyScanW(char ch);

}
'@
}

if (-not ('System.Drawing.Bitmap' -as [type])) {
    Add-Type -AssemblyName System.Drawing
}

if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}

$MAPVK_VK_TO_VSC = 0
$SW_RESTORE = 9
$SWP_NOMOVE = 0x0002
$SWP_NOSIZE = 0x0001
$SWP_SHOWWINDOW = 0x0040
$VISIBLE_TAB_MIN_ID = 1000
$VISIBLE_TAB_MAX_ID_EXCLUSIVE = 1900
$HOST_COMMAND_NEW_TAB_ID = 1904
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

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'noctty.win32.host') {
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

        if ((Get-WindowClassName -Hwnd $hwnd) -ne 'noctty.win32') {
            return $true
        }

        if (-not [Win11ShellCommandLiveNative]::IsWindowVisible($hwnd)) {
            return $true
        }

        $rect = [Win11ShellCommandLiveNative+RECT]::new()
        if (-not [Win11ShellCommandLiveNative]::GetWindowRect($hwnd, [ref] $rect)) {
            return $true
        }

        if (($rect.Right -le $rect.Left) -or ($rect.Bottom -le $rect.Top)) {
            return $true
        }

        $script:Win11ShellCommandLiveSurface = $hwnd
        return $false
    }

    [void] [Win11ShellCommandLiveNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:Win11ShellCommandLiveSurface
}

function Assert-ForegroundWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $foreground = [Win11ShellCommandLiveNative]::GetForegroundWindow()
    if (($foreground -eq $Hwnd) -or [Win11ShellCommandLiveNative]::IsChild($Hwnd, $foreground)) {
        return $true
    }

    return $false
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
        [Parameter(Mandatory)] [int] $CommandId,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    Invoke-SendMessageTimeoutOrThrow `
        -Hwnd $HostHwnd `
        -Message 0x0111 `
        -WParam (New-WParam -Low $CommandId) `
        -LParam ([IntPtr]::Zero) `
        -Deadline $Deadline `
        -Process $Process `
        -Description "host command $CommandId"
}

function Invoke-SendMessageTimeoutOrThrow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint32] $Message,
        [Parameter(Mandatory)] [UIntPtr] $WParam,
        [Parameter(Mandatory)] [IntPtr] $LParam,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [string] $Description
    )

    [void](Invoke-InteractiveWin11Message `
        -Hwnd $Hwnd `
        -Message $Message `
        -WParam $WParam `
        -LParam $LParam `
        -Deadline $Deadline `
        -Process $Process `
        -Description $Description)
}

function Invoke-TabIndexActivation {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $TabIndex,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $tab = Get-VisibleTabButtons -Parent $HostHwnd | Select-Object -Index $TabIndex
    if ($null -eq $tab) {
        throw "tab index $TabIndex was not visible"
    }

    Invoke-SendMessageTimeoutOrThrow `
        -Hwnd $tab.Hwnd `
        -Message 0x0201 `
        -WParam ([UIntPtr]::Zero) `
        -LParam ([IntPtr]::Zero) `
        -Deadline $Deadline `
        -Process $Process `
        -Description "activate tab index $TabIndex mouse down"
    Invoke-SendMessageTimeoutOrThrow `
        -Hwnd $tab.Hwnd `
        -Message 0x0202 `
        -WParam ([UIntPtr]::Zero) `
        -LParam ([IntPtr]::Zero) `
        -Deadline $Deadline `
        -Process $Process `
        -Description "activate tab index $TabIndex mouse up"
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
        [switch] $KeyUp,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $scanCode = [Win11ShellCommandLiveNative]::MapVirtualKeyW([uint32] $VirtualKey, [uint32] $MAPVK_VK_TO_VSC)
    if ($scanCode -eq 0) {
        throw "MapVirtualKeyW returned 0 for VK=$VirtualKey"
    }

    $message = if ($KeyUp) { $WM_KEYUP } else { $WM_KEYDOWN }
    Invoke-SendMessageTimeoutOrThrow `
        -Hwnd $Hwnd `
        -Message ([uint32] $message) `
        -WParam ([UIntPtr]([uint64] $VirtualKey)) `
        -LParam (New-KeyLParam -ScanCode ([uint16] $scanCode) -KeyUp:$KeyUp) `
        -Deadline $Deadline `
        -Process $Process `
        -Description "message=$message vk=$VirtualKey"

    if (-not $KeyUp -and $CharCode -ne 0) {
        Invoke-SendMessageTimeoutOrThrow `
            -Hwnd $Hwnd `
            -Message ([uint32] $WM_CHAR) `
            -WParam ([UIntPtr]([uint64] $CharCode)) `
            -LParam (New-KeyLParam -ScanCode ([uint16] $scanCode)) `
            -Deadline $Deadline `
            -Process $Process `
            -Description "WM_CHAR char=$CharCode"
    }
}

function Send-ModifiedChar {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [char] $Character,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
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
        Send-KeyMessage -Hwnd $Hwnd -VirtualKey $modifier -Deadline $Deadline -Process $Process
    }

    try {
        Send-KeyMessage -Hwnd $Hwnd -VirtualKey $virtualKey -CharCode ([uint16] [int] $Character) -Deadline $Deadline -Process $Process
        Send-KeyMessage -Hwnd $Hwnd -VirtualKey $virtualKey -KeyUp -Deadline $Deadline -Process $Process
    }
    finally {
        for ($i = $modifiers.Count - 1; $i -ge 0; $i -= 1) {
            $modifier = $modifiers[$i]
            Send-KeyMessage -Hwnd $Hwnd -VirtualKey $modifier -KeyUp -Deadline $Deadline -Process $Process
        }
    }
}

function Send-Line {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    foreach ($character in $Text.ToCharArray()) {
        Send-ModifiedChar -Hwnd $Hwnd -Character $character -Deadline $Deadline -Process $Process
        Start-Sleep -Milliseconds $KEY_STROKE_DELAY_MS
    }

    Send-KeyMessage -Hwnd $Hwnd -VirtualKey ([uint16] $VK_RETURN) -CharCode 13 -Deadline $Deadline -Process $Process
    Send-KeyMessage -Hwnd $Hwnd -VirtualKey ([uint16] $VK_RETURN) -KeyUp -Deadline $Deadline -Process $Process
}

function Save-WindowCapture {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Offscreen
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
            if ($Offscreen) {
                $hdc = $graphics.GetHdc()
                try {
                    if (-not [Win11ShellCommandLiveNative]::PrintWindow($Hwnd, $hdc, 2)) {
                        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "PrintWindow failed for hwnd=$Hwnd (error=$lastError)"
                    }
                }
                finally {
                    $graphics.ReleaseHdc($hdc)
                }
            }
            else {
                $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
            }
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
    [void] [InteractiveWin11WindowNative]::ForceForeground($Hwnd, $true, $false)

    $captureDeadline = (Get-Date).AddMilliseconds($CAPTURE_PROMOTION_DELAY_MS * 4)
    while ((Get-Date) -lt $captureDeadline) {
        if (Assert-ForegroundWindow -Hwnd $Hwnd) {
            Start-Sleep -Milliseconds $CAPTURE_PROMOTION_DELAY_MS
            return
        }

        Start-Sleep -Milliseconds $CAPTURE_PROMOTION_DELAY_MS
        [void] [InteractiveWin11WindowNative]::ForceForeground($Hwnd, $true, $false)
    }

    throw "Failed to foreground capture target hwnd=$Hwnd before screenshot sampling"
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

function Get-BoundedTerminalTextSnapshot {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $TimeoutSeconds = 5
    )

    $probe = Start-Job -ScriptBlock {
        param([long] $HwndValue, [int] $TargetProcessId)

        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $HwndValue)
        if ($null -eq $root) { return $null }

        $documents = @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text
            )
        ) | Where-Object {
            $_.Current.ProcessId -eq $TargetProcessId -and
            $_.Current.LocalizedControlType -eq 'terminal'
        })
        if ($documents.Count -eq 0) { return $null }

        $textPattern = $null
        if (-not $documents[0].TryGetCurrentPattern(
            [System.Windows.Automation.TextPattern]::Pattern,
            [ref] $textPattern
        )) {
            return $null
        }

        return $textPattern.DocumentRange.GetText(-1)
    } -ArgumentList $HostHwnd.ToInt64(), $Process.Id

    try {
        if ($null -eq (Wait-Job -Job $probe -Timeout $TimeoutSeconds)) {
            return $null
        }
        return [string] (Receive-Job -Job $probe -ErrorAction Stop)
    }
    catch {
        return $null
    }
    finally {
        Stop-Job -Job $probe -ErrorAction SilentlyContinue
        Remove-Job -Job $probe -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ConfiguredShellCommandScenario {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [string[]] $ExpectedText,
        [string[]] $RejectedText = @(),
        [Parameter(Mandatory)] [string] $CapturePath,
        [Parameter(Mandatory)] [string] $StdoutPath,
        [Parameter(Mandatory)] [string] $StderrPath
    )

    Remove-Item -LiteralPath $CapturePath, $StdoutPath, $StderrPath -ErrorAction SilentlyContinue
    $scenarioArgs = @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=noctty-shell-config-$Name-$($layout.SandboxId)"
        '--config-default-files=false'
        "--config-file=$ConfigPath"
    )
    $scenarioProcess = Start-Process -FilePath $exePath `
        -ArgumentList $scenarioArgs `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $StdoutPath `
        -RedirectStandardError $StderrPath `
        -PassThru
    Write-Host "$Name configured shell scenario launched pid=$($scenarioProcess.Id)"

    $scenarioHostHwnd = [IntPtr]::Zero
    try {
        $scenarioDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        Wait-InteractiveWin11Until -Deadline $scenarioDeadline -Description "$Name host window" -Process $scenarioProcess -Condition {
            (Find-HostWindow -ProcessId $scenarioProcess.Id) -ne [IntPtr]::Zero
        }
        $scenarioHostHwnd = Find-HostWindow -ProcessId $scenarioProcess.Id

        Wait-InteractiveWin11Until -Deadline $scenarioDeadline -Description "$Name terminal output" -Process $scenarioProcess -Condition {
            $script:Win11ShellCommandScenarioText = Get-BoundedTerminalTextSnapshot -HostHwnd $scenarioHostHwnd -Process $scenarioProcess
            if ($null -eq $script:Win11ShellCommandScenarioText) { return $false }
            foreach ($expected in $ExpectedText) {
                if (-not $script:Win11ShellCommandScenarioText.Contains($expected)) { return $false }
            }
            foreach ($rejected in $RejectedText) {
                if ($script:Win11ShellCommandScenarioText.Contains($rejected)) { return $false }
            }
            return $true
        }

        Save-WindowCapture -Hwnd $scenarioHostHwnd -Path $CapturePath -Offscreen

        $scenarioStderr = Get-InteractiveWin11TextFile -Path $StderrPath
        if ($scenarioStderr -match 'panic: reached unreachable code') {
            throw "$Name reported a runtime panic"
        }

        return [pscustomobject]@{
            Name = $Name
            ProcessId = $scenarioProcess.Id
            Text = $script:Win11ShellCommandScenarioText
            Capture = $CapturePath
            Stdout = $StdoutPath
            Stderr = $StderrPath
        }
    }
    finally {
        if ($scenarioHostHwnd -ne [IntPtr]::Zero) {
            [void] [Win11ShellCommandLiveNative]::SetWindowPos(
                $scenarioHostHwnd,
                $HWND_NOTOPMOST,
                0,
                0,
                0,
                0,
                [uint32] ($SWP_NOMOVE -bor $SWP_NOSIZE)
            )
        }
        Stop-InteractiveWin11Process -Process $scenarioProcess -Contained
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
$quotedConfigPath = Join-Path $layout.Temp 'interactive-win11-shell-command-quoted.conf'
$quotedCapturePath = Join-Path $layout.Temp 'interactive-win11-shell-command-quoted.png'
$quotedStdoutPath = Join-Path $layout.Logs 'interactive-win11-shell-command-quoted-stdout.log'
$quotedStderrPath = Join-Path $layout.Logs 'interactive-win11-shell-command-quoted-stderr.log'
$abnormalConfigPath = Join-Path $layout.Temp 'interactive-win11-shell-command-abnormal.conf'
$abnormalCapturePath = Join-Path $layout.Temp 'interactive-win11-shell-command-abnormal.png'
$abnormalStdoutPath = Join-Path $layout.Logs 'interactive-win11-shell-command-abnormal-stdout.log'
$abnormalStderrPath = Join-Path $layout.Logs 'interactive-win11-shell-command-abnormal-stderr.log'
$failedStartConfigPath = Join-Path $layout.Temp 'interactive-win11-shell-command-failed-start.conf'
$failedStartCapturePath = Join-Path $layout.Temp 'interactive-win11-shell-command-failed-start.png'
$failedStartStdoutPath = Join-Path $layout.Logs 'interactive-win11-shell-command-failed-start-stdout.log'
$failedStartStderrPath = Join-Path $layout.Logs 'interactive-win11-shell-command-failed-start-stderr.log'
$missingExecutablePath = "C:\noctty-issue151-missing-$([Guid]::NewGuid().ToString('N')).exe"
if (Test-Path -LiteralPath $missingExecutablePath) {
    throw "Failed-start validation path unexpectedly exists: $missingExecutablePath"
}

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

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $payloadPath, $readyPath, $controlPath, $resolvedPath, $postPath, $beforeCapturePath, $afterCapturePath, $quotedConfigPath, $quotedCapturePath, $quotedStdoutPath, $quotedStderrPath, $abnormalConfigPath, $abnormalCapturePath, $abnormalStdoutPath, $abnormalStderrPath, $failedStartConfigPath, $failedStartCapturePath, $failedStartStdoutPath, $failedStartStderrPath -ErrorAction SilentlyContinue

@(
    '@echo off'
    "cd /d `"$($layout.Temp)`""
    'echo READY>interactive-win11-shell-command-live-ready.txt'
) | Set-Content -LiteralPath $payloadPath -Encoding ASCII

@(
    'command = cmd.exe /d /c "echo CONFIG_QUOTED_^A && echo CONFIG_QUOTED_^B"'
    'wait-after-command = true'
    'abnormal-command-exit-runtime = 5000'
) | Set-Content -LiteralPath $quotedConfigPath -Encoding ASCII

@(
    'command = cmd.exe /d /c "exit /b 37"'
    'wait-after-command = true'
    'abnormal-command-exit-runtime = 5000'
) | Set-Content -LiteralPath $abnormalConfigPath -Encoding ASCII

@(
    "command = direct:`"$missingExecutablePath`""
    'wait-after-command = true'
) | Set-Content -LiteralPath $failedStartConfigPath -Encoding ASCII

if ($ConfiguredScenariosOnly) {
    $quotedResult = Invoke-ConfiguredShellCommandScenario `
        -Name 'quoted' `
        -ConfigPath $quotedConfigPath `
        -ExpectedText @('CONFIG_QUOTED_A', 'CONFIG_QUOTED_B') `
        -RejectedText @('Ghostty failed to launch the requested command:') `
        -CapturePath $quotedCapturePath `
        -StdoutPath $quotedStdoutPath `
        -StderrPath $quotedStderrPath

    $abnormalResult = Invoke-ConfiguredShellCommandScenario `
        -Name 'abnormal' `
        -ConfigPath $abnormalConfigPath `
        -ExpectedText @(
            'Ghostty failed to launch the requested command:',
            'cmd.exe /d /c "exit /b 37"',
            'Exit Code: 37',
            'Press any key to close the window.'
        ) `
        -CapturePath $abnormalCapturePath `
        -StdoutPath $abnormalStdoutPath `
        -StderrPath $abnormalStderrPath

    $failedStartResult = Invoke-ConfiguredShellCommandScenario `
        -Name 'failed-start' `
        -ConfigPath $failedStartConfigPath `
        -ExpectedText @(
            'error starting IO thread: error.ProcessNotStarted (cause: error.FileNotFound)',
            'noctty failed to launch the requested command:',
            $missingExecutablePath,
            'No child process was created, so there is no exit code.',
            'common causes include a',
            'missing, inaccessible, or invalid executable.',
            'This terminal is non-functional. Please close it and try again.'
        ) `
        -CapturePath $failedStartCapturePath `
        -StdoutPath $failedStartStdoutPath `
        -StderrPath $failedStartStderrPath

    Write-Host (
        'interactive-win11 configured shell command validation: PASS ' +
        "(quoted_pid=$($quotedResult.ProcessId), abnormal_pid=$($abnormalResult.ProcessId), " +
        "failed_start_pid=$($failedStartResult.ProcessId), offscreen_captures=true)"
    )
    return
}

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
Write-Host "interactive-win11 shell command live launched pid=$($process.Id)"

$hostHwnd = [IntPtr]::Zero
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        (Find-HostWindow -ProcessId $process.Id) -ne [IntPtr]::Zero
    }

    $hostHwnd = Find-HostWindow -ProcessId $process.Id
    Promote-WindowForCapture -Hwnd $hostHwnd

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'surface child window' -Process $process -Condition {
        (Find-SurfaceWindow -Parent $hostHwnd) -ne [IntPtr]::Zero
    }

    while ((Get-VisibleTabCount -Parent $hostHwnd) -lt $SeedTabs) {
        $targetTabCount = (Get-VisibleTabCount -Parent $hostHwnd) + 1
        Invoke-HostCommand -HostHwnd $hostHwnd -CommandId $HOST_COMMAND_NEW_TAB_ID -Deadline $deadline -Process $process
        Wait-InteractiveWin11Until -Deadline $deadline -Description "seed tabs ($targetTabCount/$SeedTabs)" -Process $process -Condition {
            (Get-VisibleTabCount -Parent $hostHwnd) -ge $targetTabCount
        }
    }

    Invoke-TabIndexActivation -HostHwnd $hostHwnd -TabIndex 0 -Deadline $deadline -Process $process

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'shell ready file' -Process $process -Condition {
        Test-Path -LiteralPath $readyPath
    }

    $surfaceHwnd = Find-SurfaceWindow -Parent $hostHwnd
    Start-Sleep -Milliseconds $CAPTURE_SETTLE_MS
    Promote-WindowForCapture -Hwnd $hostHwnd
    Save-WindowCapture -Hwnd $surfaceHwnd -Path $beforeCapturePath

    Send-Line -Hwnd $surfaceHwnd -Text 'echo READY>interactive-win11-shell-command-live-control.txt' -Deadline $deadline -Process $process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'control output file' -Process $process -Condition {
        Test-Path -LiteralPath $controlPath
    }
    Start-Sleep -Milliseconds $CAPTURE_SETTLE_MS

    Send-Line -Hwnd $surfaceHwnd -Text 'where noctty>interactive-win11-shell-command-live-resolved.txt' -Deadline $deadline -Process $process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'command resolution file' -Process $process -Condition {
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
        ($resolvedFirstName -notin @('noctty.com', 'noctty.exe'))
    ) {
        throw "live shell resolved unexpected first noctty command: $($resolved[0]) (expected same install dir as $exePath)"
    }

    Send-Line -Hwnd $surfaceHwnd -Text ("{0} & echo POST>interactive-win11-shell-command-live-post.txt" -f $typedCommandText) -Deadline $deadline -Process $process
    Start-Sleep -Milliseconds $POST_COMMAND_CAPTURE_SETTLE_MS
    Promote-WindowForCapture -Hwnd $hostHwnd
    Save-WindowCapture -Hwnd $surfaceHwnd -Path $afterCapturePath
    $imageDelta = Measure-ImageDelta -BeforePath $beforeCapturePath -AfterPath $afterCapturePath
    if ($imageDelta.ChangedPixels -lt $MIN_CHANGED_PIXELS) {
        throw "live shell command '$typedCommandText' produced too little visible change (changed=$($imageDelta.ChangedPixels), sampled=$($imageDelta.SampledPixels))"
    }

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'post output file' -Process $process -Condition {
        Test-Path -LiteralPath $postPath
    }

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match 'error starting IO thread:|panic: reached unreachable code') {
        throw 'noctty live shell command run reported a runtime failure'
    }

    Write-Host ("interactive-win11 shell command live validation: PASS (pid={0}, command={1}, action={2}, seed_tabs={3}, changed={4}, sampled={5}, stdout={6}, stderr={7}, ready={8}, control={9}, resolved={10}, post={11}, before={12}, after={13})" -f $process.Id, $typedCommandText, $CliAction, $SeedTabs, $imageDelta.ChangedPixels, $imageDelta.SampledPixels, $stdoutPath, $stderrPath, $readyPath, $controlPath, $resolvedPath, $postPath, $beforeCapturePath, $afterCapturePath)
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

    Stop-InteractiveWin11Process -Process $process -Contained
}
