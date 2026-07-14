[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_ACCESSIBILITY_BOOTSTRAPPED) {
    $forwarded = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwarded += '-Rebuild' }
    if ($ResetState) { $forwarded += '-ResetState' }
    $code = 0
    Invoke-InteractiveWin11Bootstrap -RepoRoot $repoRoot -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_ACCESSIBILITY_BOOTSTRAPPED' `
        -ArgumentList $forwarded -ExitCode ([ref]$code)
    exit $code
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('WinghosttyAccessibilityNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinghosttyAccessibilityNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT {
        public int x; public int y;
    }
    [StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRAST {
        public uint cbSize; public uint dwFlags; public IntPtr lpszDefaultScheme;
    }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool ScreenToClient(IntPtr hwnd, ref POINT point);
}
'@
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'accessibility' -ResetState:$ResetState
$layout = $harness.Layout
$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
if ((Get-InteractiveWin11LaunchAction -ExePath $exe -Rebuild:$Rebuild -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot)) -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}
Assert-InteractiveWin11ExeExists -ExePath $exe
$stdout = Join-Path $layout.Logs 'interactive-win11-accessibility-stdout.log'
$stderr = Join-Path $layout.Logs 'interactive-win11-accessibility-stderr.log'
$artifact = Join-Path $layout.Logs 'uia-tree.json'
$process = Start-Process -FilePath $exe -ArgumentList @(Get-InteractiveWin11LaunchArguments -Layout $layout) `
    -WorkingDirectory $repoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw "winghostty exited before UIA query (exit $($process.ExitCode))." }
    } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'winghostty did not expose a main HWND.' }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    if ($null -eq $root) { throw 'UI Automation returned no root element.' }
    [void][WinghosttyAccessibilityNative]::SetForegroundWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 150
    $elements = @($root) + @($root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    ) | ForEach-Object { $_ })
    $nodes = @($elements | Select-Object -First 512 | ForEach-Object {
        [ordered]@{
            name = $_.Current.Name
            control_type = $_.Current.ControlType.ProgrammaticName
            automation_id = $_.Current.AutomationId
            process_id = $_.Current.ProcessId
            enabled = $_.Current.IsEnabled
            keyboard_focusable = $_.Current.IsKeyboardFocusable
            has_keyboard_focus = $_.Current.HasKeyboardFocus
        }
    })
    if ($root.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
        throw "UIA root control type is $($root.Current.ControlType.ProgrammaticName), expected Window."
    }
    $documents = @($elements | Where-Object {
        $_.Current.ProcessId -eq $process.Id -and
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document
    })
    if ($documents.Count -eq 0) {
        throw 'UIA tree contains no terminal Document element.'
    }
    $document = $documents[0]
    $textPattern = $null
    if (-not $document.TryGetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern,
        [ref] $textPattern
    )) {
        throw 'Terminal Document does not expose the UIA Text pattern.'
    }
    $documentFocusError = $null
    try { $document.SetFocus() } catch { $documentFocusError = $_.Exception.Message }
    $focusDeadline = [DateTime]::UtcNow.AddSeconds(3)
    $clickedDocument = $false
    do {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $process.Id) { break }
        [void][WinghosttyAccessibilityNative]::SetForegroundWindow($process.MainWindowHandle)
        if (-not $clickedDocument) {
            $bounds = $document.Current.BoundingRectangle
            if ($bounds.Width -gt 0 -and $bounds.Height -gt 0) {
                $noMoveNoSizeShow = [uint32](0x0001 -bor 0x0002 -bor 0x0040)
                [void][WinghosttyAccessibilityNative]::SetWindowPos(
                    $process.MainWindowHandle,
                    [IntPtr](-1),
                    0,
                    0,
                    0,
                    0,
                    $noMoveNoSizeShow
                )
                $x = [int][Math]::Round($bounds.Left + ($bounds.Width / 2))
                $y = [int][Math]::Round($bounds.Top + ($bounds.Height / 2))
                $point = [WinghosttyAccessibilityNative+POINT]::new()
                $point.x = $x
                $point.y = $y
                $targetHwnd = [WinghosttyAccessibilityNative]::WindowFromPoint($point)
                [uint32] $targetProcessId = 0
                $targetThreadId = [WinghosttyAccessibilityNative]::GetWindowThreadProcessId(
                    $targetHwnd,
                    [ref] $targetProcessId
                )
                if ($targetHwnd -eq [IntPtr]::Zero -or $targetThreadId -eq 0 -or $targetProcessId -ne [uint32]$process.Id) {
                    throw "Refusing accessibility click outside winghostty (hwnd=$targetHwnd, owner=$targetProcessId, expected=$($process.Id))."
                }
                $clientPoint = $point
                if (-not [WinghosttyAccessibilityNative]::ScreenToClient($targetHwnd, [ref] $clientPoint)) {
                    throw "ScreenToClient failed for accessibility click hwnd=${targetHwnd}: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
                }
                [int32] $clickCoordinates = ($clientPoint.x -band 0xffff) -bor (($clientPoint.y -band 0xffff) -shl 16)
                [void](Invoke-InteractiveWin11Message `
                    -Hwnd $targetHwnd `
                    -Message 0x0201 `
                    -WParam ([UIntPtr]::new([uint64]1)) `
                    -LParam ([IntPtr]$clickCoordinates) `
                    -Deadline $focusDeadline `
                    -Process $process `
                    -Description 'accessibility document mouse-down')
                [void](Invoke-InteractiveWin11Message `
                    -Hwnd $targetHwnd `
                    -Message 0x0202 `
                    -WParam ([UIntPtr]::Zero) `
                    -LParam ([IntPtr]$clickCoordinates) `
                    -Deadline $focusDeadline `
                    -Process $process `
                    -Description 'accessibility document mouse-up')
                [void][WinghosttyAccessibilityNative]::SetWindowPos(
                    $process.MainWindowHandle,
                    [IntPtr](-2),
                    0,
                    0,
                    0,
                    0,
                    $noMoveNoSizeShow
                )
                $clickedDocument = $true
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $focusDeadline)
    if ($null -eq $focused -or $focused.Current.ProcessId -ne $process.Id) {
        $focusedSummary = if ($null -eq $focused) {
            '<none>'
        } else {
            "pid=$($focused.Current.ProcessId) name='$($focused.Current.Name)'"
        }
        throw "UIA focus did not resolve to an element owned by winghostty (focused=$focusedSummary, document_set_focus_error='$documentFocusError', clicked_document=$clickedDocument)."
    }
    $paletteDeadline = [DateTime]::UtcNow.AddSeconds(5)
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $process.MainWindowHandle `
        -Message 0x0111 `
        -WParam ([UIntPtr]::new([uint64]1901)) `
        -LParam ([IntPtr]::Zero) `
        -Deadline $paletteDeadline `
        -Process $process `
        -Description 'open accessibility command palette')
    $palette = $null
    do {
        Start-Sleep -Milliseconds 100
        $palette = @($root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::List
            )
        ) | Where-Object { $_.Current.ProcessId -eq $process.Id }) | Select-Object -First 1
    } while ($null -eq $palette -and [DateTime]::UtcNow -lt $paletteDeadline)
    if ($null -eq $palette) { throw 'UIA tree contains no command palette List element.' }
    $paletteBounds = $palette.Current.BoundingRectangle
    if ($paletteBounds.Width -le 0 -or $paletteBounds.Height -le 0) { throw 'Command palette List has empty UIA bounds.' }
    $paletteItems = @($palette.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem
        )
    ) | ForEach-Object { $_ })
    if ($paletteItems.Count -eq 0) { throw 'Command palette List exposes no ListItem children.' }
    $selectedItems = @($paletteItems | Where-Object {
        $pattern = $null
        $_.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern) -and $pattern.Current.IsSelected
    })
    if ($selectedItems.Count -ne 1) { throw "Command palette exposes $($selectedItems.Count) selected rows; expected one." }
    $selectedBounds = $selectedItems[0].Current.BoundingRectangle
    if ($selectedBounds.Width -le 0 -or $selectedBounds.Height -le 0 -or $selectedItems[0].Current.IsOffscreen) {
        throw 'Selected command palette row is not visible with positive UIA bounds.'
    }
    if ($selectedBounds.Left -lt $paletteBounds.Left -or $selectedBounds.Top -lt $paletteBounds.Top -or
        $selectedBounds.Right -gt $paletteBounds.Right -or $selectedBounds.Bottom -gt $paletteBounds.Bottom) {
        throw 'Selected command palette row bounds escape the List bounds.'
    }
    [void](Invoke-InteractiveWin11Message `
        -Hwnd $process.MainWindowHandle `
        -Message 0x0111 `
        -WParam ([UIntPtr]::new([uint64]2004)) `
        -LParam ([IntPtr]::Zero) `
        -Deadline ([DateTime]::UtcNow.AddSeconds(5)) `
        -Process $process `
        -Description 'dismiss accessibility command palette')
    $hc = [WinghosttyAccessibilityNative+HIGHCONTRAST]::new()
    $hc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($hc)
    if (-not [WinghosttyAccessibilityNative]::SystemParametersInfo(0x42, $hc.cbSize, [ref]$hc, 0)) {
        throw "SPI_GETHIGHCONTRAST failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    [ordered]@{
        schema_version = 1
        process_id = $process.Id
        high_contrast = [bool]($hc.dwFlags -band 1)
        focused = $focused.Current.Name
        palette = [ordered]@{
            name = $palette.Current.Name
            item_count = $paletteItems.Count
            selected_name = $selectedItems[0].Current.Name
            bounds = [ordered]@{ left = $paletteBounds.Left; top = $paletteBounds.Top; width = $paletteBounds.Width; height = $paletteBounds.Height }
            selected_bounds = [ordered]@{ left = $selectedBounds.Left; top = $selectedBounds.Top; width = $selectedBounds.Width; height = $selectedBounds.Height }
        }
        nodes = $nodes
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $artifact -Encoding utf8
}
finally {
    Stop-InteractiveWin11Process -Process $process -Contained
}

Write-Host "interactive Win11 accessibility: PASS ($artifact)"
