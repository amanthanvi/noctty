param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_UNDO_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_UNDO_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win11UndoNative {
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

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
}

public sealed class Win11UndoChildControl {
    public Win11UndoChildControl(IntPtr hwnd, int id) {
        Hwnd = hwnd;
        Id = id;
    }

    public IntPtr Hwnd { get; private set; }
    public int Id { get; private set; }
}
'@

enum Win11UndoPaletteAction {
    Undo = 0
    Redo = 1
    NewSplitDown = 2
    CloseTabThis = 3
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function New-WParam {
    param(
        [Parameter(Mandatory)] [int] $Low,
        [int] $High = 0
    )

    return [UIntPtr]([uint64](((($High -band 0xffff) -shl 16) -bor ($Low -band 0xffff)) -band 0xffffffff))
}

function New-LParam {
    param(
        [Parameter(Mandatory)] [int] $X,
        [Parameter(Mandatory)] [int] $Y
    )

    return [IntPtr](((($Y -band 0xffff) -shl 16) -bor ($X -band 0xffff)) -band 0xffffffff)
}

function Get-WindowClassName {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $builder = [System.Text.StringBuilder]::new(256)
    [void] [Win11UndoNative]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Find-HostWindow {
    param(
        [Parameter(Mandatory)] [int] $ProcessId
    )

    $script:Win11UndoTargetProcessId = [uint32] $ProcessId
    $script:Win11UndoFoundHost = [IntPtr]::Zero
    $callback = [Win11UndoNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        $windowProcessId = [uint32] 0
        [void] [Win11UndoNative]::GetWindowThreadProcessId($hwnd, [ref] $windowProcessId)
        if ($windowProcessId -ne $script:Win11UndoTargetProcessId) {
            return $true
        }

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32.host') {
            $script:Win11UndoFoundHost = $hwnd
            return $false
        }

        return $true
    }

    [void] [Win11UndoNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:Win11UndoFoundHost
}

function Get-VisibleChildControls {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:Win11UndoChildControls = [System.Collections.Generic.List[Win11UndoChildControl]]::new()
    $callback = [Win11UndoNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ([Win11UndoNative]::IsWindowVisible($hwnd)) {
            $control = [Win11UndoChildControl]::new(
                $hwnd,
                [Win11UndoNative]::GetDlgCtrlID($hwnd)
            )
            [void] $script:Win11UndoChildControls.Add($control)
        }

        return $true
    }

    [void] [Win11UndoNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:Win11UndoChildControls.ToArray()
}

function Get-VisibleChildById {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent,
        [Parameter(Mandatory)] [int] $Id
    )

    return Get-VisibleChildControls -Parent $Parent |
        Where-Object { $_.Id -eq $Id } |
        Select-Object -First 1
}

function Get-VisibleTabButtons {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return Get-VisibleChildControls -Parent $Parent |
        Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 } |
        Sort-Object Id
}

function Get-VisibleTabCount {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleTabButtons -Parent $Parent).Count
}

function Get-VisibleSurfaceCount {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleChildControls -Parent $Parent |
        Where-Object { (Get-WindowClassName -Hwnd $_.Hwnd) -eq 'winghostty.win32' }).Count
}

function Get-LogPatternCount {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Pattern
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $content = Get-InteractiveWin11TextFile -Path $Path
    if ($null -eq $content) {
        return 0
    }

    return [regex]::Matches($content, [regex]::Escape($Pattern)).Count
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

function Invoke-HostCommand {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $CommandId
    )

    [void] [Win11UndoNative]::SendMessageW($HostHwnd, 0x0111, (New-WParam -Low $CommandId), [IntPtr]::Zero)
}

function Invoke-CommandPaletteAction {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [Win11UndoPaletteAction] $Action,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [System.Diagnostics.Process] $Process
    )

    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId 1901
    $script:Win11UndoPaletteHostHwnd = $HostHwnd
    Wait-Until -Deadline $Deadline -Description 'command palette edit control' -Process $Process -Condition {
        $null -ne (Get-VisibleChildById -Parent $script:Win11UndoPaletteHostHwnd -Id 2002)
    }

    $edit = Get-VisibleChildById -Parent $script:Win11UndoPaletteHostHwnd -Id 2002
    $actionText = switch ($Action) {
        ([Win11UndoPaletteAction]::Undo) { 'undo' }
        ([Win11UndoPaletteAction]::Redo) { 'redo' }
        ([Win11UndoPaletteAction]::NewSplitDown) { 'new_split:down' }
        ([Win11UndoPaletteAction]::CloseTabThis) { 'close_tab:this' }
    }
    foreach ($ch in $actionText.ToCharArray()) {
        [void] [Win11UndoNative]::SendMessageW(
            $edit.Hwnd,
            0x0102,
            ([UIntPtr]([uint64]([int][char]$ch))),
            [IntPtr]::Zero
        )
    }

    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId 2003
}

function Invoke-CloseSecondTab {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd
    )

    $tab = Get-VisibleTabButtons -Parent $HostHwnd |
        Where-Object { $_.Id -eq 1001 } |
        Select-Object -First 1
    if ($null -eq $tab) {
        throw 'second tab button was not visible'
    }

    $rect = [Win11UndoNative+RECT]::new()
    if (-not [Win11UndoNative]::GetClientRect($tab.Hwnd, [ref] $rect)) {
        throw 'failed to read second tab button client rect'
    }

    $x = [Math]::Max(0, $rect.Right - 4)
    $y = [Math]::Max(0, [int] (($rect.Bottom - $rect.Top) / 2))
    $lParam = New-LParam -X $x -Y $y
    [void] [Win11UndoNative]::SendMessageW($tab.Hwnd, 0x0201, [UIntPtr]::Zero, $lParam)
    [void] [Win11UndoNative]::SendMessageW($tab.Hwnd, 0x0202, [UIntPtr]::Zero, $lParam)
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'undo' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout
$configDir = Join-Path $layout.LocalAppData 'winghostty'
$configPath = Join-Path $configDir 'config.ghostty'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
[System.IO.File]::WriteAllText(
    $configPath,
    '',
    [System.Text.UTF8Encoding]::new($false)
)

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$launchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout)
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-undo-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-undo-stderr.log'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$successPattern = 'started subcommand path='
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$hostHwnd = [IntPtr]::Zero

try {
    Wait-Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        if ($process.HasExited) {
            throw "winghostty exited before host creation (exit code $($process.ExitCode))"
        }

        $script:Win11UndoHostHwnd = Find-HostWindow -ProcessId $process.Id
        return $script:Win11UndoHostHwnd -ne [IntPtr]::Zero
    }
    $hostHwnd = $script:Win11UndoHostHwnd

    Wait-Until -Deadline $deadline -Description 'initial shell startup' -Process $process -Condition {
        (Get-LogPatternCount -Path $stderrPath -Pattern $successPattern) -ge 1
    }

    Wait-Until -Deadline $deadline -Description 'initial tab button' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 1
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 1 'initial tab count'

    Wait-Until -Deadline $deadline -Description 'initial surface child' -Process $process -Condition {
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 1
    }
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 1 'initial visible surface count'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::NewSplitDown) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'split surface creation' -Process $process -Condition {
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 2
    }
    Wait-Until -Deadline $deadline -Description 'split shell startup' -Process $process -Condition {
        (Get-LogPatternCount -Path $stderrPath -Pattern $successPattern) -ge 2
    }
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 2 'visible surface count after new_split:down'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Undo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'undo removed split surface' -Process $process -Condition {
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 1
    }
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 1 'visible surface count after split undo'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Redo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'redo restored split surface' -Process $process -Condition {
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 2
    }
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 2 'visible surface count after split redo'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Undo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'second undo removed split surface' -Process $process -Condition {
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 1
    }
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 1 'visible surface count after second split undo'

    Invoke-HostCommand -HostHwnd $hostHwnd -CommandId 1904
    Wait-Until -Deadline $deadline -Description 'second tab button' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 2
    }
    Wait-Until -Deadline $deadline -Description 'second shell startup' -Process $process -Condition {
        (Get-LogPatternCount -Path $stderrPath -Pattern $successPattern) -ge 3
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 2 'tab count after new_tab'

    Invoke-CloseSecondTab -HostHwnd $hostHwnd
    Wait-Until -Deadline $deadline -Description 'second tab close' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 1
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 1 'tab count after close_tab:this'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Undo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'undo restored closed tab' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 2
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 2 'tab count after undo'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Redo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'redo closed restored tab' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 1
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 1 'tab count after redo'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::CloseTabThis) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'last tab close' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 0
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 0 'tab count after last close_tab:this'

    Start-Sleep -Milliseconds 500
    if ($process.HasExited) {
        throw 'winghostty exited after last-tab close'
    }
}
catch {
    $stderrTail = Get-InteractiveWin11TextFileTail -Path $stderrPath -LineCount 60

    throw @"
interactive Win11 undo test failed: $($_.Exception.Message)
stderr log: $stderrPath
stdout log: $stdoutPath

Recent stderr:
$stderrTail
"@
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        Stop-InteractiveWin11Process -Process $process
    }
}

Write-Host "interactive-win11 undo test: PASS ($stderrPath)"
