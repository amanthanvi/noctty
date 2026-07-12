if (-not ('WinghosttyStatefulNative' -as [type])) {
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinghosttyStatefulNative {
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
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
}
'@
}

function Get-StatefulClassName([IntPtr] $Hwnd) {
    $value = [Text.StringBuilder]::new(128)
    [void][WinghosttyStatefulNative]::GetClassNameW($Hwnd, $value, $value.Capacity)
    return $value.ToString()
}

function Find-StatefulHost([int] $ProcessId) {
    $script:StatefulPid = [uint32]$ProcessId
    $script:StatefulHost = [IntPtr]::Zero
    $callback = [WinghosttyStatefulNative+EnumProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        $windowProcessId = [uint32]0
        [void][WinghosttyStatefulNative]::GetWindowThreadProcessId($hwnd, [ref]$windowProcessId)
        if ($windowProcessId -eq $script:StatefulPid -and (Get-StatefulClassName $hwnd) -eq 'winghostty.win32.host') {
            $script:StatefulHost = $hwnd
            return $false
        }
        return $true
    }
    [void][WinghosttyStatefulNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:StatefulHost
}

function Get-StatefulChildren([IntPtr] $Parent) {
    $script:StatefulChildren = [Collections.Generic.List[object]]::new()
    $callback = [WinghosttyStatefulNative+EnumProc] {
        param([IntPtr]$hwnd, [IntPtr]$data)
        if ([WinghosttyStatefulNative]::IsWindowVisible($hwnd)) {
            $script:StatefulChildren.Add([pscustomobject]@{
                Hwnd = $hwnd
                Id = [WinghosttyStatefulNative]::GetDlgCtrlID($hwnd)
                Class = Get-StatefulClassName $hwnd
            })
        }
        return $true
    }
    [void][WinghosttyStatefulNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return @($script:StatefulChildren)
}

function Get-StatefulTabCount([IntPtr] $HostHwnd) {
    return @(Get-StatefulChildren $HostHwnd | Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 }).Count
}

function Get-StatefulSurface([IntPtr] $HostHwnd) {
    return Get-StatefulChildren $HostHwnd | Where-Object Class -eq 'winghostty.win32' | Select-Object -First 1
}

function Get-StatefulWindowRect([IntPtr] $Hwnd) {
    $rect = [WinghosttyStatefulNative+RECT]::new()
    if (-not [WinghosttyStatefulNative]::GetWindowRect($Hwnd, [ref]$rect)) { return $null }
    return $rect
}

function Invoke-StatefulCommand([IntPtr] $HostHwnd, [int] $CommandId) {
    [void][WinghosttyStatefulNative]::SendMessageW($HostHwnd, 0x0111, [UIntPtr]([uint64]$CommandId), [IntPtr]::Zero)
}

function Set-StatefulEditText([IntPtr] $HostHwnd, [IntPtr] $Hwnd, [string] $Text) {
    $textPointer = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($Text)
    try {
        $result = [WinghosttyStatefulNative]::SendMessageW($Hwnd, 0x000C, [UIntPtr]::Zero, $textPointer)
        if ($result -eq [IntPtr]::Zero) { throw "WM_SETTEXT failed for hwnd=$Hwnd" }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($textPointer)
    }
    $enChange = 0x0300
    $controlId = [WinghosttyStatefulNative]::GetDlgCtrlID($Hwnd)
    $command = [uint64]([uint32]$controlId -bor ([uint32]$enChange -shl 16))
    [void][WinghosttyStatefulNative]::SendMessageW($HostHwnd, 0x0111, [UIntPtr]$command, $Hwnd)
}

function Show-StatefulHost([IntPtr] $HostHwnd) {
    [void][WinghosttyStatefulNative]::ShowWindow($HostHwnd, 9)
    [void][WinghosttyStatefulNative]::SetWindowPos($HostHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0043)
    [void][WinghosttyStatefulNative]::SetForegroundWindow($HostHwnd)
    Start-Sleep -Milliseconds 200
}

function Get-StatefulPixel([IntPtr] $Hwnd) {
    $rect = [WinghosttyStatefulNative+RECT]::new()
    if (-not [WinghosttyStatefulNative]::GetWindowRect($Hwnd, [ref]$rect)) {
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
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'winghostty host window' -Process $Run.Process -Condition {
        [IntPtr]::Zero -ne (Find-StatefulHost $script:StatefulWaitProcess.Id)
    }
    return Find-StatefulHost $Run.Process.Id
}

function Invoke-StatefulButton([IntPtr] $HostHwnd, [int] $ControlId) {
    $button = Get-StatefulChildren $HostHwnd | Where-Object Id -eq $ControlId | Select-Object -First 1
    if ($null -eq $button) { throw "No visible button with control ID $ControlId." }
    [void][WinghosttyStatefulNative]::SendMessageW($button.Hwnd, 0x00F5, [UIntPtr]::Zero, [IntPtr]::Zero)
}

function Invoke-StatefulPaletteFirstRow([IntPtr] $HostHwnd) {
    $list = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2006 | Select-Object -First 1
    if ($null -eq $list) { throw 'No visible command-palette list.' }
    $coordinates = [IntPtr](4 -bor (4 -shl 16))
    [void][WinghosttyStatefulNative]::SendMessageW($list.Hwnd, 0x0201, [UIntPtr]::Zero, $coordinates)
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
    [void][WinghosttyStatefulNative]::SendMessageW($HostHwnd, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'winghostty graceful exit' -Condition { $Run.Process.Refresh(); $Run.Process.HasExited }
}
