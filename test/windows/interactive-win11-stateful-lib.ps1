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
        if ($windowProcessId -eq $script:StatefulPid -and (Get-StatefulClassName $hwnd) -eq 'winghostty.win32.host') {
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
    return Get-StatefulChildren $HostHwnd | Where-Object Class -eq 'winghostty.win32' | Select-Object -First 1
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

function Get-StatefulPixel([IntPtr] $Hwnd) {
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
            -Description 'WM_CLOSE to winghostty' `
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
        Write-Warning "WM_CLOSE send raced winghostty exit: $sendError"
    }
    try {
        Wait-InteractiveWin11Until -Deadline $Deadline -Description 'winghostty graceful exit' -Condition { $Run.Process.Refresh(); $Run.Process.HasExited }
    }
    catch {
        if ($null -ne $closeSkipDetail) { throw "$($_.Exception.Message) ($closeSkipDetail)" }
        throw
    }
    $exitCode = Get-InteractiveWin11ProcessExitCode -Process $Run.Process -ProcessHandle $processHandle
    if ($exitCode -ne 0) {
        $suffix = if ($null -ne $closeSkipDetail) { " ($closeSkipDetail)" } else { '' }
        throw "winghostty exited with code $exitCode during graceful-close validation$suffix"
    }
}
