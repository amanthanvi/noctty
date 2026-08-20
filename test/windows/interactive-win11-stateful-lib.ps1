if (-not ('NocttyStatefulNative' -as [type])) {
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class NocttyStatefulNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left; public int Top; public int Right; public int Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRAST {
        public uint cbSize; public uint dwFlags; public IntPtr lpszDefaultScheme;
    }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
}
'@
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
    [void][NocttyStatefulNative]::GetClassNameW($Hwnd, $value, $value.Capacity)
    return $value.ToString()
}

function Find-StatefulHost([int] $ProcessId) {
    $script:StatefulPid = [uint32]$ProcessId
    $script:StatefulHost = [IntPtr]::Zero
    $callback = [NocttyStatefulNative+EnumProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        $windowProcessId = [uint32]0
        [void][InteractiveWin11MessageNativeV2]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
        if ($windowProcessId -eq $script:StatefulPid -and (Get-StatefulClassName $hwnd) -eq 'noctty.win32.host') {
            $script:StatefulHost = $hwnd
            return $false
        }
        return $true
    }
    [void][NocttyStatefulNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:StatefulHost
}

function Get-StatefulChildren([IntPtr] $Parent) {
    $script:StatefulChildren = [Collections.Generic.List[object]]::new()
    $callback = [NocttyStatefulNative+EnumProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        if ([NocttyStatefulNative]::IsWindowVisible($hwnd)) {
            $script:StatefulChildren.Add([pscustomobject]@{
                Hwnd = $hwnd
                Id = [NocttyStatefulNative]::GetDlgCtrlID($hwnd)
                Class = Get-StatefulClassName $hwnd
            })
        }
        return $true
    }
    [void][NocttyStatefulNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return @($script:StatefulChildren)
}

function Get-StatefulTabCount([IntPtr] $HostHwnd) {
    return @(Get-StatefulChildren $HostHwnd | Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 }).Count
}

function Get-StatefulSurface([IntPtr] $HostHwnd) {
    return Get-StatefulChildren $HostHwnd | Where-Object Class -eq 'noctty.win32' | Select-Object -First 1
}

function Get-StatefulWindowRect([IntPtr] $Hwnd) {
    $rect = [NocttyStatefulNative+RECT]::new()
    if (-not [NocttyStatefulNative]::GetWindowRect($Hwnd, [ref]$rect)) { return $null }
    return $rect
}

function Invoke-StatefulCommand([IntPtr] $HostHwnd, [int] $CommandId, [DateTime] $Deadline, [Parameter(Mandatory)] [System.Diagnostics.Process] $Process) {
    [void](Send-StatefulMessage $HostHwnd 0x0111 ([UIntPtr]([uint64]$CommandId)) ([IntPtr]::Zero) $Deadline $Process "WM_COMMAND id=$CommandId")
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
    $controlId = [NocttyStatefulNative]::GetDlgCtrlID($Hwnd)
    $command = [uint64]([uint32]$controlId -bor ([uint32]$enChange -shl 16))
    [void](Send-StatefulMessage $HostHwnd 0x0111 ([UIntPtr]$command) $Hwnd $Deadline $Process "WM_COMMAND EN_CHANGE id=$controlId")
}

function Show-StatefulHost([IntPtr] $HostHwnd) {
    [void][NocttyStatefulNative]::ShowWindow($HostHwnd, 9)
    [void][NocttyStatefulNative]::SetWindowPos($HostHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0043)
    [void][NocttyStatefulNative]::SetForegroundWindow($HostHwnd)
    Start-Sleep -Milliseconds 200
}

function Get-StatefulPixel([IntPtr] $Hwnd) {
    $rect = [NocttyStatefulNative+RECT]::new()
    if (-not [NocttyStatefulNative]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw "GetWindowRect failed for hwnd=$Hwnd"
    }
    $bitmap = [Drawing.Bitmap]::new(1, 1)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $counts = @{}
        $bestColor = 0
        $bestCount = 0
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        foreach ($column in 1..4) {
            foreach ($row in 1..4) {
                $sampleX = $rect.Left + [int](($width * $column) / 5)
                $sampleY = $rect.Top + [int](($height * $row) / 5)
                $graphics.CopyFromScreen($sampleX, $sampleY, 0, 0, [Drawing.Size]::new(1, 1))
                $color = $bitmap.GetPixel(0, 0).ToArgb()
                $count = 1 + [int]($counts[$color])
                $counts[$color] = $count
                if ($count -gt $bestCount) { $bestColor = $color; $bestCount = $count }
            }
        }
        return $bestColor
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Start-StatefulApp($Layout, [string] $Exe, [string] $RepoRoot, [string] $Name, [string[]] $ExtraArguments = @()) {
    $stdout = Join-Path $Layout.Logs "$Name-stdout.log"
    $stderr = Join-Path $Layout.Logs "$Name-stderr.log"
    $arguments = @((Get-InteractiveWin11LaunchArguments -Layout $Layout)) + @($ExtraArguments)
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
