if (-not ('WinghosttyStatefulNative' -as [type])) {
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinghosttyStatefulNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRAST {
        public uint cbSize; public uint dwFlags; public IntPtr lpszDefaultScheme;
    }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int capacity);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
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
        $pid = [uint32]0
        [void][WinghosttyStatefulNative]::GetWindowThreadProcessId($hwnd, [ref]$pid)
        if ($pid -eq $script:StatefulPid -and (Get-StatefulClassName $hwnd) -eq 'winghostty.win32.host') {
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

function Get-StatefulTabCount([IntPtr] $Host) {
    return @(Get-StatefulChildren $Host | Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 }).Count
}

function Get-StatefulSurface([IntPtr] $Host) {
    return Get-StatefulChildren $Host | Where-Object Class -eq 'winghostty.win32' | Select-Object -First 1
}

function Invoke-StatefulCommand([IntPtr] $Host, [int] $CommandId) {
    [void][WinghosttyStatefulNative]::SendMessageW($Host, 0x0111, [UIntPtr]([uint64]$CommandId), [IntPtr]::Zero)
}

function Send-StatefulText([IntPtr] $Hwnd, [string] $Text) {
    foreach ($character in $Text.ToCharArray()) {
        [void][WinghosttyStatefulNative]::SendMessageW($Hwnd, 0x0102, [UIntPtr]([uint64][int][char]$character), [IntPtr]::Zero)
    }
}

function Send-StatefulKey([IntPtr] $Hwnd, [int] $VirtualKey) {
    [void][WinghosttyStatefulNative]::SendMessageW($Hwnd, 0x0100, [UIntPtr]([uint64]$VirtualKey), [IntPtr]::Zero)
    [void][WinghosttyStatefulNative]::SendMessageW($Hwnd, 0x0101, [UIntPtr]([uint64]$VirtualKey), [IntPtr]::Zero)
}

function Get-StatefulPixel([IntPtr] $Hwnd) {
    $dc = [WinghosttyStatefulNative]::GetDC($Hwnd)
    if ($dc -eq [IntPtr]::Zero) { throw "GetDC failed for hwnd=$Hwnd" }
    try { return [uint32][WinghosttyStatefulNative]::GetPixel($dc, 4, 4) }
    finally { [void][WinghosttyStatefulNative]::ReleaseDC($Hwnd, $dc) }
}

function Start-StatefulApp($Layout, [string] $Exe, [string] $RepoRoot, [string] $Name) {
    $stdout = Join-Path $Layout.Logs "$Name-stdout.log"
    $stderr = Join-Path $Layout.Logs "$Name-stderr.log"
    $process = Start-Process -FilePath $Exe -ArgumentList @(Get-InteractiveWin11LaunchArguments -Layout $Layout) `
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

function Close-StatefulHost([IntPtr] $Host, $Run, [DateTime] $Deadline) {
    [void][WinghosttyStatefulNative]::SendMessageW($Host, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'winghostty graceful exit' -Condition { $Run.Process.Refresh(); $Run.Process.HasExited }
}
