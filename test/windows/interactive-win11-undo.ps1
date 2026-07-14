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
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

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

    Wait-InteractiveWin11Until @PSBoundParameters
}

function Invoke-HostCommand {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $CommandId,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    [void] (Invoke-InteractiveWin11Message -Hwnd $HostHwnd -Message 0x0111 -WParam (New-WParam -Low $CommandId) -Deadline $Deadline -Description "WM_COMMAND $CommandId" -Process $Process)
}

function Invoke-CommandPaletteAction {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [Win11UndoPaletteAction] $Action,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId 1901 -Deadline $Deadline -Process $Process
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
        [void] (Invoke-InteractiveWin11Message -Hwnd $edit.Hwnd -Message 0x0102 -WParam ([UIntPtr]([uint64]([int][char]$ch))) -Deadline $Deadline -Description "palette WM_CHAR '$ch'" -Process $Process)
    }

    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId 2003 -Deadline $Deadline -Process $Process
}

function Invoke-CloseSecondTab {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
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
    [void] (Invoke-InteractiveWin11Message -Hwnd $tab.Hwnd -Message 0x0201 -LParam $lParam -Deadline $Deadline -Description 'second tab mouse down' -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $tab.Hwnd -Message 0x0202 -LParam $lParam -Deadline $Deadline -Description 'second tab mouse up' -Process $Process)
}

function Invoke-DragFirstTabIntoActiveSurface {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $sourceTab = Get-VisibleTabButtons -Parent $HostHwnd |
        Where-Object { $_.Id -eq 1000 } |
        Select-Object -First 1
    $targetSurface = Get-VisibleChildControls -Parent $HostHwnd |
        Where-Object { (Get-WindowClassName -Hwnd $_.Hwnd) -eq 'winghostty.win32' } |
        Select-Object -First 1
    if ($null -eq $sourceTab -or $null -eq $targetSurface) {
        throw 'drag source tab or active target surface was not visible'
    }

    $tabClient = [Win11UndoNative+RECT]::new()
    $tabScreen = [Win11UndoNative+RECT]::new()
    $surfaceScreen = [Win11UndoNative+RECT]::new()
    if (-not [Win11UndoNative]::GetClientRect($sourceTab.Hwnd, [ref] $tabClient) -or
        -not [Win11UndoNative]::GetWindowRect($sourceTab.Hwnd, [ref] $tabScreen) -or
        -not [Win11UndoNative]::GetWindowRect($targetSurface.Hwnd, [ref] $surfaceScreen)) {
        throw 'failed to read drag geometry'
    }

    $downX = [Math]::Max(4, [int] (($tabClient.Right - $tabClient.Left) / 2))
    $downY = [Math]::Max(4, [int] (($tabClient.Bottom - $tabClient.Top) / 2))
    $targetScreenX = [Math]::Max($surfaceScreen.Left, $surfaceScreen.Right - 20)
    $targetScreenY = [int] (($surfaceScreen.Top + $surfaceScreen.Bottom) / 2)
    $moveX = $targetScreenX - $tabScreen.Left
    $moveY = $targetScreenY - $tabScreen.Top

    [void] (Invoke-InteractiveWin11Message -Hwnd $sourceTab.Hwnd -Message 0x0201 -LParam (New-LParam -X $downX -Y $downY) -Deadline $Deadline -Description 'tab drag mouse down' -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $sourceTab.Hwnd -Message 0x0200 -WParam (New-WParam -Low 1) -LParam (New-LParam -X $moveX -Y $moveY) -Deadline $Deadline -Description 'tab drag mouse move' -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $sourceTab.Hwnd -Message 0x0202 -LParam (New-LParam -X $moveX -Y $moveY) -Deadline $Deadline -Description 'tab drag mouse up' -Process $Process)
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

    Invoke-HostCommand -HostHwnd $hostHwnd -CommandId 1904 -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'second tab button' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 2
    }
    Wait-Until -Deadline $deadline -Description 'second shell startup' -Process $process -Condition {
        (Get-LogPatternCount -Path $stderrPath -Pattern $successPattern) -ge 3
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 2 'tab count after new_tab'

    Invoke-DragFirstTabIntoActiveSurface -HostHwnd $hostHwnd -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'tab drag split transfer' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 1 -and
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 2
    }
    Assert-Equal (Get-VisibleTabCount -Parent $hostHwnd) 1 'tab count after drag split transfer'
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 2 'pane count after drag split transfer'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Undo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'undo tab drag split transfer' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 2
    }
    Assert-Equal (Get-VisibleSurfaceCount -Parent $hostHwnd) 1 'visible pane count after drag transfer undo'

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Redo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'redo tab drag split transfer' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 1 -and
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 2
    }

    Invoke-CommandPaletteAction -HostHwnd $hostHwnd -Action ([Win11UndoPaletteAction]::Undo) -Deadline $deadline -Process $process
    Wait-Until -Deadline $deadline -Description 'restore two tabs after drag transfer checks' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -eq 2 -and
        (Get-VisibleSurfaceCount -Parent $hostHwnd) -eq 1
    }

    Invoke-CloseSecondTab -HostHwnd $hostHwnd -Deadline $deadline -Process $process
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
        Stop-InteractiveWin11Process -Process $process -Contained
    }
}

Write-Host "interactive-win11 undo test: PASS ($stderrPath)"
