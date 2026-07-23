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

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_RESIZE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_RESIZE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WinghosttyResizeWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetDlgCtrlID(IntPtr hwndCtl);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowExW(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

}
'@

$wmEnterSizeMove = 0x0231
$wmExitSizeMove = 0x0232
$wmCommand = 0x0111
$wmChar = 0x0102
$vkReturn = 0x0D
$showWindowRestore = 9
$hostCommandPaletteCommandId = 1901
$hostNewTabCommandId = 1904
$paletteEditControlId = 2002
$tabControlIdMin = 1000
$tabControlIdMaxExclusive = 1900
$surfaceWindowClassName = 'winghostty.win32'

function Assert-Win32CallSucceeded {
    param(
        [Parameter(Mandatory)] [bool] $Succeeded,
        [Parameter(Mandatory)] [string] $Operation
    )

    if (-not $Succeeded) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "$Operation failed with Win32 error $lastError"
    }
}

function Get-WindowRectObject {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $rect = New-Object WinghosttyResizeWin32+RECT
    if (-not [WinghosttyResizeWin32]::GetWindowRect($Hwnd, [ref] $rect)) {
        throw "GetWindowRect failed for hwnd=$Hwnd"
    }

    return [pscustomobject]@{
        Left = $rect.Left
        Top = $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
        Width = [Math]::Max(0, $rect.Right - $rect.Left)
        Height = [Math]::Max(0, $rect.Bottom - $rect.Top)
    }
}

function Get-WindowClassName {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $builder = [System.Text.StringBuilder]::new(256)
    [void] [WinghosttyResizeWin32]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Get-VisibleChildWindows {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $children = [System.Collections.Generic.List[object]]::new()
    $callback = [WinghosttyResizeWin32+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ([WinghosttyResizeWin32]::IsWindowVisible($hwnd)) {
            [void] $children.Add([pscustomobject]@{
                Hwnd = $hwnd
                Id = [WinghosttyResizeWin32]::GetDlgCtrlID($hwnd)
                ClassName = Get-WindowClassName -Hwnd $hwnd
            })
        }

        return $true
    }

    [void] [WinghosttyResizeWin32]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $children.ToArray()
}

function Get-VisibleTabCount {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleChildWindows -Parent $Parent |
        Where-Object { $_.Id -ge $tabControlIdMin -and $_.Id -lt $tabControlIdMaxExclusive }).Count
}

function Get-VisibleSurfaceWindows {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleChildWindows -Parent $Parent |
        Where-Object { $_.ClassName -eq $surfaceWindowClassName })
}

function Get-VisibleSurfaceRects {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleSurfaceWindows -Parent $Parent |
        ForEach-Object {
            $rect = Get-WindowRectObject -Hwnd $_.Hwnd
            [pscustomobject]@{
                Hwnd = $_.Hwnd
                Left = $rect.Left
                Top = $rect.Top
                Right = $rect.Right
                Bottom = $rect.Bottom
                Width = $rect.Width
                Height = $rect.Height
            }
        })
}

function Get-VisibleChildById {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent,
        [Parameter(Mandatory)] [int] $Id
    )

    return Get-VisibleChildWindows -Parent $Parent |
        Where-Object { $_.Id -eq $Id } |
        Select-Object -First 1
}

function New-WParam {
    param(
        [Parameter(Mandatory)] [int] $Low,
        [int] $High = 0
    )

    return [UIntPtr]([uint64](((($High -band 0xffff) -shl 16) -bor ($Low -band 0xffff)) -band 0xffffffff))
}

function Invoke-HostCommand {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $CommandId,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    [void] (Invoke-InteractiveWin11Message -Hwnd $HostHwnd -Message $wmCommand -WParam (New-WParam -Low $CommandId) -Deadline $Deadline -Description "WM_COMMAND $CommandId" -Process $Process)
}

function Invoke-CommandPaletteAction {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId $hostCommandPaletteCommandId -Deadline $Deadline -Process $Process
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'command palette edit control' -Process $Process -Condition {
        $null -ne (Get-VisibleChildById -Parent $HostHwnd -Id $paletteEditControlId)
    }

    $edit = Get-VisibleChildById -Parent $HostHwnd -Id $paletteEditControlId
    foreach ($ch in $Action.ToCharArray()) {
        [void] (Invoke-InteractiveWin11Message -Hwnd $edit.Hwnd -Message $wmChar -WParam ([UIntPtr]([uint64]([int][char]$ch))) -Deadline $Deadline -Description "palette WM_CHAR '$ch'" -Process $Process)
    }

    [void] (Invoke-InteractiveWin11Message -Hwnd $edit.Hwnd -Message $wmChar -WParam ([UIntPtr]([uint64]$vkReturn)) -Deadline $Deadline -Description 'palette WM_CHAR Enter' -Process $Process)
}

function Show-ResizeHarnessWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    [void] [WinghosttyResizeWin32]::ShowWindow($Hwnd, $showWindowRestore)
    $noMoveNoSizeShow = [uint32](0x0001 -bor 0x0002 -bor 0x0040)
    [void] [WinghosttyResizeWin32]::SetWindowPos(
        $Hwnd,
        [IntPtr](-1),
        0,
        0,
        0,
        0,
        $noMoveNoSizeShow
    )
    [void] [WinghosttyResizeWin32]::SetForegroundWindow($Hwnd)
}

function Capture-WindowImage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path
    )

    $rect = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $rect = Get-WindowRectObject -Hwnd $Hwnd
        $width = [Math]::Max(1, $rect.Width)
        $height = [Math]::Max(1, $rect.Height)
        $bmp = New-Object System.Drawing.Bitmap $width, $height
        $captured = $false
        try {
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                try {
                    $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
                    $captured = $true
                }
                catch {
                    $lastError = $_.Exception.Message
                }
            }
            finally {
                $gfx.Dispose()
            }
            if ($captured) {
                $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
                return
            }
        }
        finally {
            $bmp.Dispose()
        }
        Show-ResizeHarnessWindow -Hwnd $Hwnd
        Start-Sleep -Milliseconds 150
    }

    throw "CopyFromScreen failed after 3 attempts for hwnd=$Hwnd rect=$($rect | ConvertTo-Json -Compress): $lastError"
}

function Assert-VisibleSurfaceUnionFillsHostContent {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $ExpectedSurfaceCount,
        [Parameter(Mandatory)] [string] $Label
    )

    $hostRect = Get-WindowRectObject -Hwnd $HostHwnd
    $surfaceRects = @(Get-VisibleSurfaceRects -Parent $HostHwnd)
    if ($surfaceRects.Count -ne $ExpectedSurfaceCount) {
        throw "$Label expected $ExpectedSurfaceCount visible surfaces, found $($surfaceRects.Count): $($surfaceRects | ConvertTo-Json -Compress)"
    }

    $left = ($surfaceRects | Measure-Object -Property Left -Minimum).Minimum
    $top = ($surfaceRects | Measure-Object -Property Top -Minimum).Minimum
    $right = ($surfaceRects | Measure-Object -Property Right -Maximum).Maximum
    $bottom = ($surfaceRects | Measure-Object -Property Bottom -Maximum).Maximum
    $unionWidth = [Math]::Max(0, $right - $left)
    $unionHeight = [Math]::Max(0, $bottom - $top)

    $totalSurfaceArea = ($surfaceRects | ForEach-Object { $_.Width * $_.Height } | Measure-Object -Sum).Sum
    $unionArea = $unionWidth * $unionHeight

    $maxHorizontalInset = 64   # borders/scrollbar allowance around hosted child surfaces
    $maxVerticalChrome = 128   # integrated titlebar + tab bar allowance above surfaces
    $minUnionWidth = [Math]::Max(1, $hostRect.Width - $maxHorizontalInset)
    $minUnionHeight = [Math]::Max(1, $hostRect.Height - $maxVerticalChrome)
    if ($unionWidth -lt $minUnionWidth -or $unionHeight -lt $minUnionHeight) {
        throw @"
$Label visible surface union does not fill host content after resize.
host=$($hostRect | ConvertTo-Json -Compress)
surface_union={"left":$left,"top":$top,"right":$right,"bottom":$bottom,"width":$unionWidth,"height":$unionHeight}
surfaces=$($surfaceRects | ConvertTo-Json -Compress)
minimum={"width":$minUnionWidth,"height":$minUnionHeight}
"@
    }

    $maxOuterSlop = 8
    if ($left -lt ($hostRect.Left - $maxOuterSlop) -or
        $top -lt ($hostRect.Top - $maxOuterSlop) -or
        $right -gt ($hostRect.Right + $maxOuterSlop) -or
        $bottom -gt ($hostRect.Bottom + $maxOuterSlop)) {
        throw @"
$Label visible surface union extends outside host after resize.
host=$($hostRect | ConvertTo-Json -Compress)
surface_union={"left":$left,"top":$top,"right":$right,"bottom":$bottom,"width":$unionWidth,"height":$unionHeight}
surfaces=$($surfaceRects | ConvertTo-Json -Compress)
max_outer_slop=$maxOuterSlop
"@
    }

    $maxGapArea = [Math]::Max(1, [int]($unionArea * 0.03))
    $gapArea = $unionArea - $totalSurfaceArea
    if ($gapArea -gt $maxGapArea) {
        throw @"
$Label visible surface union contains interior gaps after resize.
host=$($hostRect | ConvertTo-Json -Compress)
surface_union={"left":$left,"top":$top,"right":$right,"bottom":$bottom,"width":$unionWidth,"height":$unionHeight,"area":$unionArea}
surface_area=$totalSurfaceArea
gap_area=$gapArea
max_gap_area=$maxGapArea
surfaces=$($surfaceRects | ConvertTo-Json -Compress)
"@
    }

    return [pscustomobject]@{
        HostWidth = $hostRect.Width
        HostHeight = $hostRect.Height
        SurfaceUnionWidth = $unionWidth
        SurfaceUnionHeight = $unionHeight
        SurfaceArea = $totalSurfaceArea
        SurfaceGapArea = $gapArea
        SurfaceCount = $surfaceRects.Count
    }
}

function Measure-ExpansionBandRatios {
    param(
        [Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap,
        [Parameter(Mandatory)] [System.Drawing.Rectangle] $Region,
        [int] $Step = 3
    )

    $samples = 0
    $nearBlack = 0
    $neutralGray = 0
    $maxX = $Region.X + $Region.Width
    $maxY = $Region.Y + $Region.Height
    for ($y = $Region.Y; $y -lt $maxY; $y += $Step) {
        for ($x = $Region.X; $x -lt $maxX; $x += $Step) {
            $color = $Bitmap.GetPixel($x, $y)
            $samples++
            if ($color.R -le 14 -and $color.G -le 14 -and $color.B -le 14) {
                $nearBlack++
            }
            $maxChannel = [Math]::Max($color.R, [Math]::Max($color.G, $color.B))
            $minChannel = [Math]::Min($color.R, [Math]::Min($color.G, $color.B))
            $avgChannel = [int] (($color.R + $color.G + $color.B) / 3)
            if (($maxChannel - $minChannel) -le 10 -and $avgChannel -ge 80 -and $avgChannel -le 250) {
                $neutralGray++
            }
        }
    }

    if ($samples -eq 0) {
        throw "empty screenshot sample region: $Region"
    }

    return [pscustomobject]@{
        NearBlack = [double] $nearBlack / [double] $samples
        NeutralGray = [double] $neutralGray / [double] $samples
    }
}

function Assert-ResizeImageHasNoUnpaintedExpansionBands {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        if ($bmp.Width -lt 900 -or $bmp.Height -lt 560) {
            throw "resize screenshot is too small for reliable analysis: $($bmp.Width)x$($bmp.Height)"
        }

        $rightBand = [System.Drawing.Rectangle]::new(
            [Math]::Max(0, $bmp.Width - 260),
            [Math]::Min([Math]::Max(96, [int] ($bmp.Height * 0.18)), $bmp.Height - 220),
            200,
            [Math]::Max(120, $bmp.Height - [Math]::Min([Math]::Max(96, [int] ($bmp.Height * 0.18)), $bmp.Height - 220) - 96)
        )
        $bottomBand = [System.Drawing.Rectangle]::new(
            100,
            [Math]::Max(120, $bmp.Height - 220),
            [Math]::Max(200, $bmp.Width - 200),
            150
        )

        $rightRatios = Measure-ExpansionBandRatios -Bitmap $bmp -Region $rightBand
        $bottomRatios = Measure-ExpansionBandRatios -Bitmap $bmp -Region $bottomBand
        $blackThreshold = 0.25
        $grayThreshold = 0.15

        if ($rightRatios.NearBlack -gt $blackThreshold -or $bottomRatios.NearBlack -gt $blackThreshold) {
            throw ("settled resize expansion area is unexpectedly near-black: right={0:P1} bottom={1:P1} screenshot={2}" -f $rightRatios.NearBlack, $bottomRatios.NearBlack, $Path)
        }
        if ($rightRatios.NeutralGray -gt $grayThreshold -or $bottomRatios.NeutralGray -gt $grayThreshold) {
            throw ("settled resize expansion area has unpainted neutral-gray boxes: right={0:P1} bottom={1:P1} screenshot={2}" -f $rightRatios.NeutralGray, $bottomRatios.NeutralGray, $Path)
        }

        return [pscustomobject]@{
            RightBlackRatio = $rightRatios.NearBlack
            BottomBlackRatio = $bottomRatios.NearBlack
            RightGrayRatio = $rightRatios.NeutralGray
            BottomGrayRatio = $bottomRatios.NeutralGray
        }
    }
    finally {
        $bmp.Dispose()
    }
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'resize' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-resize-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-resize-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-resize.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-resize-payload.ps1'
$screenshotPath = Join-Path $layout.Logs 'interactive-win11-resize-grown.png'
$surfaceScreenshotPath = Join-Path $layout.Logs 'interactive-win11-resize-grown-surface.png'
$liveScreenshotPath = Join-Path $layout.Logs 'interactive-win11-resize-live-grown.png'
$instanceClass = "winghostty-resize-$($layout.SandboxId)"

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
background = #F3E9CB
foreground = #111111
background-opacity = 1
confirm-close-surface = false
font-size = 16
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

@"
Write-Output 'resize validation ready'
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $screenshotPath, $surfaceScreenshotPath, $liveScreenshotPath -ErrorAction SilentlyContinue

$launchArgs = @(
    Get-InteractiveWin11ContainmentArguments
    '--single-instance=false'
    "--class=$instanceClass"
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

$successPattern = 'started subcommand path='
$runtimeFailurePattern = 'paint redraw failed|InvalidValue|surface closed|panic: reached unreachable code|error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$enteredSizeMove = $false

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
        if ($stderr -match $runtimeFailurePattern) {
            throw "unexpected runtime failure reported before resize:`n$stderr"
        }

        if ($process.MainWindowHandle -ne 0 -and $stderr.Contains($successPattern)) {
            break
        }

        if ($process.HasExited) {
            throw "winghostty exited before resize validation could start (exit code $($process.ExitCode))"
        }

        Start-Sleep -Milliseconds 100
    }

    if ($process.MainWindowHandle -eq 0) {
        throw 'winghostty main window handle was not ready before timeout.'
    }

    $workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $workingArea.Left + 40
    $y = $workingArea.Top + 40
    $initialWidth = [Math]::Min(720, [Math]::Max(640, $workingArea.Width - 80))
    $initialHeight = [Math]::Min(460, [Math]::Max(420, $workingArea.Height - 100))
    $grownWidth = [Math]::Min(1280, [Math]::Max(960, $workingArea.Width - 80))
    $grownHeight = [Math]::Min(820, [Math]::Max(620, $workingArea.Height - 100))

    Show-ResizeHarnessWindow -Hwnd $process.MainWindowHandle
    Assert-Win32CallSucceeded `
        -Succeeded ([WinghosttyResizeWin32]::MoveWindow($process.MainWindowHandle, $x, $y, $initialWidth, $initialHeight, $true)) `
        -Operation "initial MoveWindow(hwnd=$($process.MainWindowHandle))"
    Start-Sleep -Milliseconds 600

    $scenarioDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-HostCommand -HostHwnd $process.MainWindowHandle -CommandId $hostNewTabCommandId -Deadline $scenarioDeadline -Process $process
    Wait-InteractiveWin11Until -Deadline $scenarioDeadline -Description 'second tab for resize repro' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $process.MainWindowHandle) -ge 2
    }
    Invoke-CommandPaletteAction -HostHwnd $process.MainWindowHandle -Action 'new_split:right' -Deadline $scenarioDeadline -Process $process
    Wait-InteractiveWin11Until -Deadline $scenarioDeadline -Description 'split pane for resize repro' -Process $process -Condition {
        @(Get-VisibleSurfaceWindows -Parent $process.MainWindowHandle).Count -eq 2
    }
    $initialUnion = Assert-VisibleSurfaceUnionFillsHostContent -HostHwnd $process.MainWindowHandle -ExpectedSurfaceCount 2 -Label 'initial split layout'

    [void] (Invoke-InteractiveWin11Message -Hwnd $process.MainWindowHandle -Message $wmEnterSizeMove -Deadline $scenarioDeadline -Description 'WM_ENTERSIZEMOVE' -Flags $script:InteractiveWin11SmtoBlock -Process $process)
    $enteredSizeMove = $true
    Assert-Win32CallSucceeded `
        -Succeeded ([WinghosttyResizeWin32]::MoveWindow($process.MainWindowHandle, $x, $y, $grownWidth, $grownHeight, $true)) `
        -Operation "grown MoveWindow(hwnd=$($process.MainWindowHandle))"
    Show-ResizeHarnessWindow -Hwnd $process.MainWindowHandle
    [void] [WinghosttyResizeWin32]::UpdateWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 150
    Capture-WindowImage -Hwnd $process.MainWindowHandle -Path $liveScreenshotPath
    $liveRatios = Assert-ResizeImageHasNoUnpaintedExpansionBands -Path $liveScreenshotPath
    [void] [WinghosttyResizeWin32]::UpdateWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 700

    [void] (Invoke-InteractiveWin11Message -Hwnd $process.MainWindowHandle -Message $wmExitSizeMove -Deadline $scenarioDeadline -Description 'WM_EXITSIZEMOVE' -Flags $script:InteractiveWin11SmtoBlock -Process $process)
    $enteredSizeMove = $false
    [void] [WinghosttyResizeWin32]::UpdateWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 700

    $surfaceHwnd = [WinghosttyResizeWin32]::FindWindowExW($process.MainWindowHandle, [IntPtr]::Zero, $surfaceWindowClassName, $null)
    if ($surfaceHwnd -eq [IntPtr]::Zero) {
        throw 'failed to locate winghostty surface child HWND after resize'
    }
    $hostRect = Get-WindowRectObject -Hwnd $process.MainWindowHandle
    $surfaceRect = Get-WindowRectObject -Hwnd $surfaceHwnd
    Capture-WindowImage -Hwnd $process.MainWindowHandle -Path $screenshotPath
    Capture-WindowImage -Hwnd $surfaceHwnd -Path $surfaceScreenshotPath

    $grownUnion = Assert-VisibleSurfaceUnionFillsHostContent -HostHwnd $process.MainWindowHandle -ExpectedSurfaceCount 2 -Label 'grown split layout'
    $ratios = Assert-ResizeImageHasNoUnpaintedExpansionBands -Path $screenshotPath

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "unexpected runtime failure reported after resize:`n$stderr"
    }
}
finally {
    if ($enteredSizeMove -and $process.MainWindowHandle -ne 0) {
        try {
            [void] (Invoke-InteractiveWin11Message -Hwnd $process.MainWindowHandle -Message $wmExitSizeMove -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'cleanup WM_EXITSIZEMOVE' -Flags $script:InteractiveWin11SmtoBlock -Process $process)
        }
        catch {
            Write-Warning "cleanup WM_EXITSIZEMOVE failed: $($_.Exception.Message)"
        }
    }
    Stop-InteractiveWin11Process -Process $process -Contained
}

Write-Host ("interactive-win11 resize validation: PASS (stderr={0}, screenshot={1}, live-screenshot={2}, surface-screenshot={3}, host={4}x{5}, surface={6}x{7}, split-union-before={8}x{9}, split-union-after={10}x{11}, live-right-near-black={12:P1}, live-bottom-near-black={13:P1}, live-right-neutral-gray={14:P1}, live-bottom-neutral-gray={15:P1}, right-near-black={16:P1}, bottom-near-black={17:P1}, right-neutral-gray={18:P1}, bottom-neutral-gray={19:P1})" -f $stderrPath, $screenshotPath, $liveScreenshotPath, $surfaceScreenshotPath, $hostRect.Width, $hostRect.Height, $surfaceRect.Width, $surfaceRect.Height, $initialUnion.SurfaceUnionWidth, $initialUnion.SurfaceUnionHeight, $grownUnion.SurfaceUnionWidth, $grownUnion.SurfaceUnionHeight, $liveRatios.RightBlackRatio, $liveRatios.BottomBlackRatio, $liveRatios.RightGrayRatio, $liveRatios.BottomGrayRatio, $ratios.RightBlackRatio, $ratios.BottomBlackRatio, $ratios.RightGrayRatio, $ratios.BottomGrayRatio)
