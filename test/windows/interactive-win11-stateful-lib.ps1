. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\interactive-win11-window-lib.ps1')

# Settling delay after promoting a stateful host window.
$script:STATEFUL_HOST_SETTLE_MS = 200

if (-not ('System.Drawing.Bitmap' -as [type])) {
    Add-Type -AssemblyName System.Drawing
}

function Send-StatefulMessage(
    [IntPtr] $Hwnd,
    [uint32] $Message,
    [UIntPtr] $WParam,
    [IntPtr] $LParam,
    [DateTime] $Deadline,
    [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
    [string] $Description
) {
    return Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message $Message -WParam $WParam -LParam $LParam -Deadline $Deadline -Process $Process -Description $Description
}

function Get-StatefulClassName([IntPtr] $Hwnd) {
    $value = [Text.StringBuilder]::new(128)
    [void][InteractiveWin11WindowNative]::GetClassNameW($Hwnd, $value, $value.Capacity)
    return $value.ToString()
}

function Find-StatefulHost([int] $ProcessId) {
    $script:StatefulPid = [uint32]$ProcessId
    $script:StatefulHost = [IntPtr]::Zero
    $callback = [InteractiveWin11WindowNative+EnumWindowsProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        $windowProcessId = [uint32]0
        [void][InteractiveWin11MessageNativeV2]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
        if ($windowProcessId -eq $script:StatefulPid -and (Get-StatefulClassName $hwnd) -eq 'noctty.win32.host') {
            $script:StatefulHost = $hwnd
            return $false
        }
        return $true
    }
    [void][InteractiveWin11WindowNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:StatefulHost
}

function Get-StatefulChildren([IntPtr] $Parent) {
    $script:StatefulChildren = [Collections.Generic.List[object]]::new()
    $callback = [InteractiveWin11WindowNative+EnumWindowsProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        if ([InteractiveWin11WindowNative]::IsWindowVisible($hwnd)) {
            $script:StatefulChildren.Add([pscustomobject]@{
                Hwnd = $hwnd
                Id = [InteractiveWin11WindowNative]::GetDlgCtrlID($hwnd)
                Class = Get-StatefulClassName $hwnd
            })
        }
        return $true
    }
    [void][InteractiveWin11WindowNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return @($script:StatefulChildren)
}

function Get-StatefulTabCount([IntPtr] $HostHwnd) {
    return @(Get-StatefulChildren $HostHwnd | Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 }).Count
}

function Get-StatefulSurface([IntPtr] $HostHwnd) {
    return Get-StatefulChildren $HostHwnd | Where-Object Class -eq 'noctty.win32' | Select-Object -First 1
}

function Get-StatefulWindowRect([IntPtr] $Hwnd) {
    $rect = [InteractiveWin11WindowNative+RECT]::new()
    if (-not [InteractiveWin11WindowNative]::GetWindowRect($Hwnd, [ref]$rect)) { return $null }
    return $rect
}

function Set-StatefulEditText([IntPtr] $HostHwnd, [IntPtr] $Hwnd, [string] $Text, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    $textPointer = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($Text)
    try {
        $result = Send-StatefulMessage $Hwnd 0x000C ([UIntPtr]::Zero) $textPointer $Deadline $Process 'WM_SETTEXT'
        if ($result -eq [UIntPtr]::Zero) { throw "WM_SETTEXT failed for hwnd=$Hwnd" }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($textPointer)
    }
    $enChange = 0x0300
    $controlId = [InteractiveWin11WindowNative]::GetDlgCtrlID($Hwnd)
    $command = [uint64]([uint32]$controlId -bor ([uint32]$enChange -shl 16))
    [void](Send-StatefulMessage $HostHwnd 0x0111 ([UIntPtr]$command) $Hwnd $Deadline $Process "WM_COMMAND EN_CHANGE id=$controlId")
}

function Show-StatefulHost([IntPtr] $HostHwnd) {
    [void][InteractiveWin11WindowNative]::ShowWindow($HostHwnd, 9)
    [void][InteractiveWin11WindowNative]::SetWindowPos($HostHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0043)
    [void][InteractiveWin11WindowNative]::SetForegroundWindow($HostHwnd)
    Start-Sleep -Milliseconds $script:STATEFUL_HOST_SETTLE_MS
}

function Get-StatefulPixelSamplePoints($Rect) {
    $width = $Rect.Right - $Rect.Left
    $height = $Rect.Bottom - $Rect.Top
    foreach ($column in 1..4) {
        foreach ($row in 1..4) {
            [Drawing.Point]::new($Rect.Left + [int](($width * $column) / 5), $Rect.Top + [int](($height * $row) / 5))
        }
    }
}

function Get-StatefulPixel([IntPtr] $Hwnd) {
    # Names the window a screen-pixel wait reads, so Wait-InteractiveWin11Until
    # can record what was on screen there if the wait times out.
    $script:InteractiveWin11PixelWindow = $Hwnd
    $rect = [InteractiveWin11WindowNative+RECT]::new()
    if (-not [InteractiveWin11WindowNative]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw "GetWindowRect failed for hwnd=$Hwnd"
    }
    $bitmap = [Drawing.Bitmap]::new(1, 1)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $counts = @{}
        $bestColor = 0
        $bestCount = 0
        foreach ($point in Get-StatefulPixelSamplePoints $rect) {
            $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, [Drawing.Size]::new(1, 1))
            $color = $bitmap.GetPixel(0, 0).ToArgb()
            $count = 1 + [int]($counts[$color])
            $counts[$color] = $count
            if ($count -gt $bestCount) { $bestColor = $color; $bestCount = $count }
        }
        return $bestColor
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not ('StatefulPixelDiagnosticNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class StatefulPixelDiagnosticNative {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr hwnd, int index);
    [DllImport("user32.dll")] private static extern bool GetLayeredWindowAttributes(IntPtr hwnd, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out uint value, int size);
    // DWMWA_CLOAKED: 0 when shown; -1 when DWM could not say.
    public static long Cloaked(IntPtr hwnd) {
        uint value;
        return DwmGetWindowAttribute(hwnd, 14, out value, 4) == 0 ? (long)value : -1L;
    }
    // The client area in screen coordinates, or false.
    public static bool ClientScreenRect(IntPtr hwnd, out RECT rect) {
        if (!GetClientRect(hwnd, out rect)) return false;
        POINT origin = new POINT();
        if (!ClientToScreen(hwnd, ref origin)) return false;
        rect.Left += origin.X; rect.Right += origin.X;
        rect.Top += origin.Y; rect.Bottom += origin.Y;
        return true;
    }
    // Whether the window hides what is under it: not layered, or layered with
    // full alpha and no color key. A layered window whose attributes cannot be
    // read (UpdateLayeredWindow) counts as see-through.
    public static bool Opaque(IntPtr hwnd) {
        if ((GetWindowLongW(hwnd, -20) & 0x00080000) == 0) return true;
        uint key, flags;
        byte alpha;
        if (!GetLayeredWindowAttributes(hwnd, out key, out alpha, out flags)) return false;
        return (flags & 1) == 0 && ((flags & 2) == 0 || alpha == 255);
    }
    public static uint Dpi(IntPtr hwnd) {
        uint dpi = GetDpiForWindow(hwnd);
        return dpi == 0 ? 96u : dpi;
    }
    public static long InputAgeMilliseconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) return -1;
        return unchecked((uint)Environment.TickCount - info.dwTime);
    }
}
'@
}

# Pixel diagnostics go to the harness's logs, which the interactive job uploads.
$script:StatefulDiagnosticDirectory = $null

function Get-StatefulWindowFacts([IntPtr] $Hwnd, [hashtable] $ProcessNames = @{}) {
    # Handle, class and process only: never a window title or its contents.
    # ProcessNames caches names by process id within one read of the screen.
    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    $processId = [uint32]0
    [void][InteractiveWin11WindowNative]::GetWindowThreadProcessId($Hwnd, [ref]$processId)
    if (-not $ProcessNames.ContainsKey($processId)) {
        $ProcessNames[$processId] = try { (Get-Process -Id $processId -ErrorAction Stop).ProcessName } catch { $null }
    }
    $processName = $ProcessNames[$processId]
    return [pscustomobject][ordered]@{
        Handle = '0x{0:X}' -f $Hwnd.ToInt64()
        Class = Get-StatefulClassName $Hwnd
        ProcessId = $processId
        ProcessName = $processName
    }
}

function ConvertTo-StatefulRectData($Rect) {
    if ($null -eq $Rect) { return $null }
    return [pscustomobject][ordered]@{ Left = [int]$Rect.Left; Top = [int]$Rect.Top; Right = [int]$Rect.Right; Bottom = [int]$Rect.Bottom }
}

# What the screenshot decision needs, read from the screen at one moment: the
# sampled rect, noctty's top-level window (its state, its client area inset by
# the Windows 11 corner radius, whether it is see-through), the top-level
# window under each sample point and the visible windows above it that overlap
# the rect, of any process. -WithColors also reads the 16 sample colors.
function Get-StatefulScreenFacts([IntPtr] $Hwnd, [switch] $WithColors) {
    $root = [StatefulPixelDiagnosticNative]::GetAncestor($Hwnd, 2)
    $names = @{}
    $rootFacts = Get-StatefulWindowFacts $root $names
    $rect = ConvertTo-StatefulRectData (Get-StatefulWindowRect $Hwnd)
    $bounds = $null
    if ($root -ne [IntPtr]::Zero) {
        $client = [StatefulPixelDiagnosticNative+RECT]::new()
        if ([StatefulPixelDiagnosticNative]::ClientScreenRect($root, [ref]$client)) {
            # Rounded corners show a few pixels of what is under the window.
            $inset = [int][Math]::Ceiling(8 * [StatefulPixelDiagnosticNative]::Dpi($root) / 96.0)
            $bounds = [pscustomobject][ordered]@{ Left = $client.Left + $inset; Top = $client.Top + $inset; Right = $client.Right - $inset; Bottom = $client.Bottom - $inset }
        }
    }
    $samples = [Collections.Generic.List[object]]::new()
    $windowsAbove = [Collections.Generic.List[object]]::new()
    if ($null -ne $rect) {
        $bitmap = $null
        $graphics = $null
        if ($WithColors) {
            $bitmap = [Drawing.Bitmap]::new(1, 1)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
        }
        try {
            foreach ($point in Get-StatefulPixelSamplePoints $rect) {
                $rgb = $null
                if ($WithColors) {
                    try {
                        $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, [Drawing.Size]::new(1, 1))
                        $rgb = '{0:x6}' -f ($bitmap.GetPixel(0, 0).ToArgb() -band 0xFFFFFF)
                    }
                    catch { $rgb = "capture failed: $($_.Exception.Message)" }
                }
                $nativePoint = [StatefulPixelDiagnosticNative+POINT]::new()
                $nativePoint.X = $point.X
                $nativePoint.Y = $point.Y
                $under = [StatefulPixelDiagnosticNative]::WindowFromPoint($nativePoint)
                $samples.Add([pscustomobject][ordered]@{
                    X = $point.X; Y = $point.Y; Rgb = $rgb
                    Window = Get-StatefulWindowFacts $under $names
                    Root = Get-StatefulWindowFacts ([StatefulPixelDiagnosticNative]::GetAncestor($under, 2)) $names
                })
            }
        }
        finally {
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $bitmap) { $bitmap.Dispose() }
        }
        # GW_HWNDPREV walks up the z-order from noctty's top-level window: every
        # visible window above it that overlaps the rect, of any process, with
        # its DWM cloak state (the decision says which of them hide noctty).
        $above = if ($root -eq [IntPtr]::Zero) { [IntPtr]::Zero } else { [StatefulPixelDiagnosticNative]::GetWindow($root, 3) }
        for ($guard = 0; $above -ne [IntPtr]::Zero -and $guard -lt 4096; $guard++) {
            $aboveRect = Get-StatefulWindowRect $above
            if ([InteractiveWin11WindowNative]::IsWindowVisible($above) -and $null -ne $aboveRect -and
                $aboveRect.Left -lt $rect.Right -and $aboveRect.Right -gt $rect.Left -and
                $aboveRect.Top -lt $rect.Bottom -and $aboveRect.Bottom -gt $rect.Top) {
                $windowsAbove.Add((Get-StatefulWindowFacts $above $names | Add-Member -PassThru -NotePropertyName Cloaked -NotePropertyValue ([StatefulPixelDiagnosticNative]::Cloaked($above))))
            }
            $above = [StatefulPixelDiagnosticNative]::GetWindow($above, 3)
        }
    }
    $haveRoot = $root -ne [IntPtr]::Zero
    return [pscustomobject][ordered]@{
        Rect = $rect
        Root = $rootFacts
        WindowVisible = [InteractiveWin11WindowNative]::IsWindowVisible($Hwnd)
        RootVisible = $haveRoot -and [InteractiveWin11WindowNative]::IsWindowVisible($root)
        RootMinimized = $haveRoot -and [StatefulPixelDiagnosticNative]::IsIconic($root)
        RootCloaked = if ($haveRoot) { [StatefulPixelDiagnosticNative]::Cloaked($root) } else { -1 }
        RootOpaque = $haveRoot -and [StatefulPixelDiagnosticNative]::Opaque($root)
        RootHung = $haveRoot -and [StatefulPixelDiagnosticNative]::IsHungAppWindow($root)
        CaptureBounds = $bounds
        Samples = @($samples)
        WindowsAbove = @($windowsAbove)
    }
}

# Whether a screenshot of the sampled rect would show only noctty, from facts
# alone (Get-StatefulScreenFacts), so the contracts can table-test it. It is
# taken only while noctty's top-level window is shown, uncloaked (DWM must say
# so), not minimized and opaque, every sample point lies on a window of
# noctty's process, and no window of another process above noctty overlaps the
# rect unless DWM says it is cloaked; the capture is clipped to noctty's inset
# client area (CaptureRect, set whenever both rects are known). Occluders lists
# those other-process windows in every case.
function Get-StatefulScreenshotDecision($Facts) {
    $root = $Facts.Root
    $occluders = @($Facts.WindowsAbove | Where-Object { $_.Cloaked -le 0 -and ($null -eq $root -or $_.ProcessId -ne $root.ProcessId) })
    $foreign = if ($null -eq $root) { 0 } else { @($Facts.Samples | Where-Object { $null -eq $_.Root -or $_.Root.ProcessId -ne $root.ProcessId }).Count }
    $bounds = $Facts.CaptureBounds
    $capture = $null
    if ($null -ne $Facts.Rect -and $null -ne $bounds) {
        $capture = [pscustomobject][ordered]@{
            Left = [Math]::Max($Facts.Rect.Left, $bounds.Left); Top = [Math]::Max($Facts.Rect.Top, $bounds.Top)
            Right = [Math]::Min($Facts.Rect.Right, $bounds.Right); Bottom = [Math]::Min($Facts.Rect.Bottom, $bounds.Bottom)
        }
        if ($capture.Right -le $capture.Left -or $capture.Bottom -le $capture.Top) { $capture = $null }
    }
    $note = if ($null -eq $Facts.Rect) { 'not taken: the window rect could not be read' }
    elseif ($null -eq $root) { "withheld: noctty's top-level window could not be found" }
    elseif (-not $Facts.RootVisible -or -not $Facts.WindowVisible) { "withheld: noctty's window is hidden" }
    elseif ($Facts.RootMinimized) { "withheld: noctty's window is minimized" }
    elseif ($Facts.RootCloaked -lt 0) { "withheld: DWM could not say whether noctty's window is cloaked" }
    elseif ($Facts.RootCloaked -ne 0) { "withheld: noctty's window is cloaked ($($Facts.RootCloaked))" }
    elseif (-not $Facts.RootOpaque) { "withheld: noctty's window is see-through (layered)" }
    elseif ($foreign -ne 0) { "withheld: $foreign sample point(s) lie on windows of other processes" }
    elseif ($occluders.Count -ne 0) { "withheld: $($occluders.Count) window(s) of other processes overlap the sampled rect" }
    elseif ($null -eq $bounds) { "withheld: noctty's client area could not be read" }
    elseif ($null -eq $capture) { "withheld: the sampled rect lies outside noctty's client area" }
    else { $null }
    return [pscustomobject]@{ Capture = $null -eq $note; CaptureRect = $capture; Note = $note; Occluders = $occluders }
}

# Every screenshot a harness saves goes through here, because the interactive
# job uploads the sandbox logs to the artifacts of a public repository
# (EVIDENCE-SCREENSHOT-PRIVACY-01). It reads the screen over the decision's
# CaptureRect (the window's rect clipped to noctty's inset client area) and
# saves that to $Path only while Get-StatefulScreenshotDecision allows it, both
# before the read and right after it. Without -PassThru the screen is read only
# when it may be saved; with it the screen is read anyway and the bitmap is
# returned for an in-memory check (the caller disposes it and never saves it).
# Area is the screen rect the bitmap shows, WindowRect the window's rect.
function Save-StatefulScreenCapture([IntPtr] $Hwnd, [string] $Path, [switch] $PassThru, $Facts = $null) {
    if ($null -eq $Facts) { $Facts = Get-StatefulScreenFacts $Hwnd }
    $decision = Get-StatefulScreenshotDecision $Facts
    $area = $decision.CaptureRect
    $result = [pscustomobject][ordered]@{ Path = $null; Note = $decision.Note; Bitmap = $null; Area = $area; WindowRect = $Facts.Rect }
    if ($null -eq $area -or -not ($decision.Capture -or $PassThru)) { return $result }
    $bitmap = [Drawing.Bitmap]::new($area.Right - $area.Left, $area.Bottom - $area.Top)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.CopyFromScreen($area.Left, $area.Top, 0, 0, $bitmap.Size) }
        finally { $graphics.Dispose() }
        if ($decision.Capture) {
            $recheck = Get-StatefulScreenshotDecision (Get-StatefulScreenFacts $Hwnd)
            $again = $recheck.CaptureRect
            if ($recheck.Capture -and $again.Left -eq $area.Left -and $again.Top -eq $area.Top -and
                $again.Right -eq $area.Right -and $again.Bottom -eq $area.Bottom) {
                $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
                $result.Path = $Path
            }
            else {
                $why = if ($recheck.Capture) { 'the window moved' } else { $recheck.Note }
                $result.Note = "discarded: the screen changed during the capture ($why)"
            }
        }
        if ($PassThru) { $result.Bitmap = $bitmap; $bitmap = $null }
    }
    finally { if ($null -ne $bitmap) { $bitmap.Dispose() } }
    return $result
}

# Records what was on screen where a screen-pixel assertion looked: the window
# under each sample point and its color, the foreground window, whether
# noctty's window was hung, cloaked, minimized, hidden or see-through, which
# other processes' windows lay above it, and a screenshot of the sampled rect
# when Get-StatefulScreenshotDecision says it shows only noctty, before the
# capture and right after it (Save-StatefulScreenCapture). The 16 colors are
# recorded either way.
function Save-StatefulPixelDiagnostic([IntPtr] $Hwnd, [string] $Description, [string] $Directory = $script:StatefulDiagnosticDirectory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = [IO.Path]::GetTempPath() }
    [void][IO.Directory]::CreateDirectory($Directory)
    $slug = ($Description.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 48) { $slug = $slug.Substring(0, 48).TrimEnd('-') }
    $base = Join-Path $Directory ('pixel-diagnostic-{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'), $slug)
    $facts = Get-StatefulScreenFacts $Hwnd -WithColors
    $decision = Get-StatefulScreenshotDecision $facts
    try {
        $shot = Save-StatefulScreenCapture -Hwnd $Hwnd -Path "$base.png" -Facts $facts
        $screenshot = $shot.Path
        $screenshotNote = $shot.Note
    }
    catch { $screenshot = $null; $screenshotNote = "capture failed: $($_.Exception.Message)" }
    $foreground = Get-StatefulWindowFacts ([InteractiveWin11WindowNative]::GetForegroundWindow())
    $report = [ordered]@{
        Description = $Description
        TimeUtc = [DateTime]::UtcNow.ToString('o')
        Window = Get-StatefulWindowFacts $Hwnd
        Rect = $facts.Rect
        Root = $facts.Root
        RootHung = $facts.RootHung
        RootCloaked = $facts.RootCloaked
        RootMinimized = $facts.RootMinimized
        RootVisible = $facts.RootVisible
        WindowVisible = $facts.WindowVisible
        RootOpaque = $facts.RootOpaque
        Foreground = $foreground
        InputAgeMilliseconds = [StatefulPixelDiagnosticNative]::InputAgeMilliseconds()
        Samples = $facts.Samples
        WindowsAbove = $facts.WindowsAbove
        OtherProcessWindowsAbove = $decision.Occluders
        CaptureRect = $decision.CaptureRect
        Screenshot = $screenshot
        ScreenshotNote = $screenshotNote
    }
    [IO.File]::WriteAllText("$base.json", ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    $underCounts = @($facts.Samples | ForEach-Object {
            if ($null -eq $_.Root) { '<none>' } else { "$($_.Root.ProcessName)/$($_.Root.Class)" }
        } | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" })
    $foregroundText = if ($null -eq $foreground) { '<none>' } else { "$($foreground.ProcessName)/$($foreground.Class)" }
    $screenshotText = if ($null -ne $screenshot) { $screenshot } else { $screenshotNote }
    return ("pixel diagnostic: foreground={0}; under the samples: {1}; hung={2}; cloaked={3}; other-process windows above={4}; screenshot={5}; report={6}.json" -f `
            $foregroundText, ($underCounts -join ', '), $report.RootHung, $report.RootCloaked, @($decision.Occluders).Count, $screenshotText, $base)
}

function Start-StatefulApp($Layout, [string] $Exe, [string] $RepoRoot, [string] $Name, [string[]] $ExtraArguments = @(), [switch] $UseConfiguredCommand) {
    $stdout = Join-Path $Layout.Logs "$Name-stdout.log"
    $stderr = Join-Path $Layout.Logs "$Name-stderr.log"
    $script:StatefulDiagnosticDirectory = $Layout.Logs
    $arguments = @((Get-InteractiveWin11LaunchArguments -Layout $Layout -UseConfiguredCommand:$UseConfiguredCommand)) + @($ExtraArguments)
    $process = Start-Process -FilePath $Exe -ArgumentList $arguments `
        -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    return [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = $stderr }
}

function Wait-StatefulHost($Run, [DateTime] $Deadline) {
    $script:StatefulWaitProcess = $Run.Process
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'noctty host window' -Process $Run.Process -Condition {
        [IntPtr]::Zero -ne (Find-StatefulHost $script:StatefulWaitProcess.Id)
    }
    return Find-StatefulHost $Run.Process.Id
}

function Invoke-StatefulButton([IntPtr] $HostHwnd, [int] $ControlId, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    $button = Get-StatefulChildren $HostHwnd | Where-Object Id -eq $ControlId | Select-Object -First 1
    if ($null -eq $button) { throw "No visible button with control ID $ControlId." }
    [void](Send-StatefulMessage $button.Hwnd 0x00F5 ([UIntPtr]::Zero) ([IntPtr]::Zero) $Deadline $Process "BM_CLICK id=$ControlId")
}

function Invoke-StatefulPostedCommand(
    [IntPtr] $Hwnd,
    [int] $Id,
    [DateTime] $Deadline,
    [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
) {
    Invoke-InteractiveWin11PostMessage `
        -Hwnd $Hwnd `
        -Message 0x0111 `
        -WParam ([UIntPtr]::new([uint64]$Id)) `
        -Deadline $Deadline `
        -Description "WM_COMMAND id=$Id" `
        -Process $Process
}

function Invoke-StatefulPaletteFirstRow([IntPtr] $HostHwnd, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    $list = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2006 | Select-Object -First 1
    if ($null -eq $list) { throw 'No visible command-palette list.' }
    $coordinates = [IntPtr](4 -bor (4 -shl 16))
    [void](Send-StatefulMessage $list.Hwnd 0x0201 ([UIntPtr]::Zero) $coordinates $Deadline $Process 'WM_LBUTTONDOWN command-palette first row')
}

function Wait-StatefulSurface([IntPtr] $HostHwnd, $Run, [DateTime] $Deadline) {
    $script:StatefulSurfaceHost = $HostHwnd
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'terminal surface window' -Process $Run.Process -Condition {
        $surface = Get-StatefulSurface $script:StatefulSurfaceHost
        if ($null -eq $surface) { return $false }
        $rect = Get-StatefulWindowRect $surface.Hwnd
        return $null -ne $rect -and ($rect.Right - $rect.Left) -gt 100 -and ($rect.Bottom - $rect.Top) -gt 100
    }
    return Get-StatefulSurface $HostHwnd
}

function Close-StatefulHost([IntPtr] $HostHwnd, $Run, [DateTime] $Deadline) {
    $processHandle = $Run.Process.Handle
    $toleratedCloseError = [ref]0
    $closeSkipDetail = $null
    try {
        [void](Invoke-InteractiveWin11Message `
            -Hwnd $HostHwnd `
            -Message 0x0010 `
            -Deadline $Deadline `
            -Description 'WM_CLOSE to noctty' `
            -Flags $script:InteractiveWin11SmtoBlock `
            -ToleratedErrors @($script:InteractiveWin11ErrorInvalidWindowHandle) `
            -ObservedToleratedError $toleratedCloseError `
            -Process $Run.Process)
        if ($toleratedCloseError.Value -ne 0) {
            $closeSkipDetail = "WM_CLOSE was skipped after tolerated Win32 error $($toleratedCloseError.Value) for hwnd=$HostHwnd"
        }
    }
    catch {
        $sendError = $_
        $Run.Process.Refresh()
        if (-not $Run.Process.HasExited) {
            throw $sendError
        }
        Write-Warning "WM_CLOSE send raced noctty exit: $sendError"
    }
    try {
        Wait-InteractiveWin11Until -Deadline $Deadline -Description 'noctty graceful exit' -Condition { $Run.Process.Refresh(); $Run.Process.HasExited }
    }
    catch {
        if ($null -ne $closeSkipDetail) { throw "$($_.Exception.Message) ($closeSkipDetail)" }
        throw
    }
    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $Run.Process -ProcessHandle $processHandle
    if ($exitCode -ne 0) {
        $suffix = if ($null -ne $closeSkipDetail) { " ($closeSkipDetail)" } else { '' }
        throw "noctty exited with code $exitCode during graceful-close validation$suffix"
    }
}
