param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
# Tight poll cadence for maximize-state drift observation.
$script:NEW_TAB_STATE_POLL_MS = 10

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath
. (Join-Path $repoRoot 'scripts\interactive-win11-window-lib.ps1')

$forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
if ($Rebuild) { $forwardedArgs += '-Rebuild' }
if ($ResetState) { $forwardedArgs += '-ResetState' }
Invoke-InteractiveWin11HarnessMain `
    -RepoRoot $repoRoot `
    -LauncherPath $launcherPath `
    -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_NEW_TAB_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

Add-Type -TypeDefinition @'
using System;

public sealed class Win11NewTabChildControl {
    public Win11NewTabChildControl(IntPtr hwnd, int id) {
        Hwnd = hwnd;
        Id = id;
    }

    public IntPtr Hwnd { get; private set; }
    public int Id { get; private set; }
}
'@

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
    [void] [InteractiveWin11WindowNative]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Get-WindowRectObject {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $rect = [InteractiveWin11WindowNative+RECT]::new()
    if (-not [InteractiveWin11WindowNative]::GetWindowRect($Hwnd, [ref] $rect)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetWindowRect failed for hwnd=$Hwnd (Win32 error $lastError)"
    }

    return [pscustomobject]@{
        Left = $rect.Left
        Top = $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
    }
}

function Get-WindowPlacementObject {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $placement = [InteractiveWin11WindowNative+WINDOWPLACEMENT]::new()
    $placement.length = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type] [InteractiveWin11WindowNative+WINDOWPLACEMENT])
    if (-not [InteractiveWin11WindowNative]::GetWindowPlacement($Hwnd, [ref] $placement)) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetWindowPlacement failed for hwnd=$Hwnd (Win32 error $lastError)"
    }

    return [pscustomobject]@{
        ShowCmd = [int] $placement.showCmd
        NormalPosition = [pscustomobject]@{
            Left = $placement.rcNormalPosition.Left
            Top = $placement.rcNormalPosition.Top
            Right = $placement.rcNormalPosition.Right
            Bottom = $placement.rcNormalPosition.Bottom
        }
    }
}

function Test-RectEquals {
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right
    )

    return $Left.Left -eq $Right.Left -and
        $Left.Top -eq $Right.Top -and
        $Left.Right -eq $Right.Right -and
        $Left.Bottom -eq $Right.Bottom
}

function Find-HostWindow {
    param(
        [Parameter(Mandatory)] [int] $ProcessId
    )

    $script:Win11NewTabTargetProcessId = [uint32] $ProcessId
    $script:Win11NewTabFoundHost = [IntPtr]::Zero
    $callback = [InteractiveWin11WindowNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        $windowProcessId = [uint32] 0
        [void] [InteractiveWin11WindowNative]::GetWindowThreadProcessId($hwnd, [ref] $windowProcessId)
        if ($windowProcessId -ne $script:Win11NewTabTargetProcessId) {
            return $true
        }

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32.host') {
            $script:Win11NewTabFoundHost = $hwnd
            return $false
        }

        return $true
    }

    [void] [InteractiveWin11WindowNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:Win11NewTabFoundHost
}

function Get-VisibleChildControls {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:Win11NewTabChildControls = [System.Collections.Generic.List[Win11NewTabChildControl]]::new()
    $callback = [InteractiveWin11WindowNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ([InteractiveWin11WindowNative]::IsWindowVisible($hwnd)) {
            $control = [Win11NewTabChildControl]::new(
                $hwnd,
                [InteractiveWin11WindowNative]::GetDlgCtrlID($hwnd)
            )
            [void] $script:Win11NewTabChildControls.Add($control)
        }

        return $true
    }

    [void] [InteractiveWin11WindowNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:Win11NewTabChildControls.ToArray()
}

function Get-VisibleTabCount {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    return @(Get-VisibleChildControls -Parent $Parent |
        Where-Object { $_.Id -ge 1000 -and $_.Id -lt 1900 }).Count
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
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId 1901 -Deadline $Deadline -Process $Process
    $script:Win11NewTabPaletteHostHwnd = $HostHwnd
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'command palette edit control' -Process $Process -Condition {
        @(Get-VisibleChildControls -Parent $script:Win11NewTabPaletteHostHwnd |
            Where-Object { $_.Id -eq 2002 }).Count -gt 0
    }

    $edit = Get-VisibleChildControls -Parent $script:Win11NewTabPaletteHostHwnd |
        Where-Object { $_.Id -eq 2002 } |
        Select-Object -First 1

    foreach ($ch in $Action.ToCharArray()) {
        [void] (Invoke-InteractiveWin11Message -Hwnd $edit.Hwnd -Message 0x0102 -WParam ([UIntPtr]([uint64]([int][char]$ch))) -Deadline $Deadline -Description "palette WM_CHAR '$ch'" -Process $Process)
    }

    [void] (Invoke-InteractiveWin11Message -Hwnd $edit.Hwnd -Message 0x0102 -WParam ([UIntPtr]([uint64]0x0D)) -Deadline $Deadline -Description 'palette WM_CHAR Enter' -Process $Process)
}

function Invoke-NewTabScenario {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $OpenAction,
        [Parameter(Mandatory)] $Layout,
        [Parameter(Mandatory)] [string] $ExePath,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [int] $SeedTabs = 1
    )

    $stdoutPath = Join-Path $Layout.Logs ("interactive-win11-new-tab-{0}-stdout.log" -f $Name)
    $stderrPath = Join-Path $Layout.Logs ("interactive-win11-new-tab-{0}-stderr.log" -f $Name)
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

    $launchArgs = @(
        Get-InteractiveWin11ContainmentArguments
        '--single-instance=false'
        "--class=winghostty-new-tab-$Name-$($Layout.SandboxId)"
    )

    $process = Start-Process `
        -FilePath $ExePath `
        -ArgumentList $launchArgs `
        -WorkingDirectory $RepoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $script:Win11NewTabProcess = $process
        Wait-InteractiveWin11Until -Deadline $deadline -Description "host window ($Name)" -Process $process -Condition {
            [IntPtr]::Zero -ne (Find-HostWindow -ProcessId $script:Win11NewTabProcess.Id)
        }

        $hostHwnd = Find-HostWindow -ProcessId $process.Id
        if ($hostHwnd -eq [IntPtr]::Zero) {
            throw "failed to find host window for $Name"
        }

        while ((Get-VisibleTabCount -Parent $hostHwnd) -lt $SeedTabs) {
            $targetTabCount = (Get-VisibleTabCount -Parent $hostHwnd) + 1
            Invoke-HostCommand -HostHwnd $hostHwnd -CommandId 1904 -Deadline $deadline -Process $process
            Wait-InteractiveWin11Until -Deadline $deadline -Description "seed tabs ($Name)" -Process $process -Condition {
                (Get-VisibleTabCount -Parent $hostHwnd) -ge $targetTabCount
            }
        }

        $normalRectBeforeMaximize = Get-WindowRectObject -Hwnd $hostHwnd
        $normalPlacementBeforeMaximize = Get-WindowPlacementObject -Hwnd $hostHwnd
        [void] [InteractiveWin11WindowNative]::ShowWindow($hostHwnd, 3)
        Wait-InteractiveWin11Until -Deadline $deadline -Description "maximized host ($Name)" -Process $process -Condition {
            [InteractiveWin11WindowNative]::IsZoomed($hostHwnd)
        }

        $maximizedPlacementBeforeNewTab = Get-WindowPlacementObject -Hwnd $hostHwnd
        if (-not (Test-RectEquals -Left $normalPlacementBeforeMaximize.NormalPosition -Right $maximizedPlacementBeforeNewTab.NormalPosition)) {
            throw "$Name maximize setup changed restore target before opening a tab. before=$($normalPlacementBeforeMaximize.NormalPosition | ConvertTo-Json -Compress) after=$($maximizedPlacementBeforeNewTab.NormalPosition | ConvertTo-Json -Compress)"
        }

        $beforeRect = Get-WindowRectObject -Hwnd $hostHwnd
        & $OpenAction $hostHwnd $deadline $process

        Wait-InteractiveWin11Until -Deadline $deadline -Description "next tab ($Name)" -Process $process -Condition {
            (Get-VisibleTabCount -Parent $hostHwnd) -ge ($SeedTabs + 1)
        }

        $samples = [System.Collections.Generic.List[object]]::new()
        $sampleDeadline = [DateTime]::UtcNow.AddMilliseconds(1200)
        while ([DateTime]::UtcNow -lt $sampleDeadline) {
            $sampleRect = Get-WindowRectObject -Hwnd $hostHwnd
            $samplePlacement = Get-WindowPlacementObject -Hwnd $hostHwnd
            $samples.Add([pscustomobject]@{
                Ticks = [DateTime]::UtcNow.Ticks
                Zoomed = [bool][InteractiveWin11WindowNative]::IsZoomed($hostHwnd)
                ShowCmd = $samplePlacement.ShowCmd
                Rect = $sampleRect
                Normal = $samplePlacement.NormalPosition
            }) | Out-Null
            Start-Sleep -Milliseconds $script:NEW_TAB_STATE_POLL_MS
        }

        $afterRect = $samples[$samples.Count - 1].Rect
        $placementAfterRect = [pscustomobject]@{
            ShowCmd = $samples[$samples.Count - 1].ShowCmd
            NormalPosition = $samples[$samples.Count - 1].Normal
        }
        $samplesJson = $samples | ConvertTo-Json -Compress -Depth 6
        if (-not $samples[-1].Zoomed) {
            throw "$Name new-tab path dropped maximized state. before=$($beforeRect | ConvertTo-Json -Compress) after=$($afterRect | ConvertTo-Json -Compress) placement=$($placementAfterRect | ConvertTo-Json -Compress) samples=$samplesJson"
        }
        $changedSample = $samples | Where-Object { -not $_.Zoomed -or -not (Test-RectEquals -Left $beforeRect -Right $_.Rect) } | Select-Object -First 1
        if ($null -ne $changedSample) {
            throw "$Name new-tab path transiently changed maximized state or rect. before=$($beforeRect | ConvertTo-Json -Compress) changed=$($changedSample | ConvertTo-Json -Compress) samples=$samplesJson"
        }

        $maximizedPlacementAfterNewTab = $placementAfterRect
        $restoreTargetChangedWhileMaximized = -not (Test-RectEquals -Left $normalPlacementBeforeMaximize.NormalPosition -Right $maximizedPlacementAfterNewTab.NormalPosition)
        if ($restoreTargetChangedWhileMaximized) {
            throw "$Name new-tab path changed WINDOWPLACEMENT restore target while maximized. before=$($normalPlacementBeforeMaximize.NormalPosition | ConvertTo-Json -Compress) after=$($maximizedPlacementAfterNewTab.NormalPosition | ConvertTo-Json -Compress)"
        }

        [void] (Invoke-InteractiveWin11Message -Hwnd $hostHwnd -Message 0x0112 -WParam (New-WParam -Low 0xF120) -Deadline $deadline -Description 'SC_RESTORE' -Process $process)
        Wait-InteractiveWin11Until -Deadline $deadline -Description "restored host ($Name)" -Process $process -Condition {
            -not [InteractiveWin11WindowNative]::IsZoomed($hostHwnd)
        }

        $restoredRect = Get-WindowRectObject -Hwnd $hostHwnd
        if (-not (Test-RectEquals -Left $normalRectBeforeMaximize -Right $restoredRect)) {
            throw "$Name new-tab path changed restored window rect. before=$($normalRectBeforeMaximize | ConvertTo-Json -Compress) after=$($restoredRect | ConvertTo-Json -Compress) placement=$($maximizedPlacementAfterNewTab | ConvertTo-Json -Compress) restoreTargetChangedWhileMaximized=$restoreTargetChangedWhileMaximized"
        }

        return [pscustomobject]@{
            Name = $Name
            Stdout = $stdoutPath
            Stderr = $stderrPath
        }
    }
    finally {
        Stop-InteractiveWin11Process -Process $process -Contained
    }
}

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

function Invoke-NewTabScenarioRun {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $OpenAction
    )

    $scenarioHarness = Initialize-InteractiveWin11Sandbox `
        -RepoRoot $repoRoot `
        -SandboxName ("new-tab-" + $Name) `
        -ResetState:$ResetState
    $scenarioLayout = $scenarioHarness.Layout
    $scenarioRepoRoot = $scenarioHarness.RepoRoot
    $scenarioConfigDir = Join-Path $scenarioLayout.LocalAppData 'winghostty'
    $scenarioConfigPath = Join-Path $scenarioConfigDir 'config.ghostty'
    New-Item -ItemType Directory -Force -Path $scenarioConfigDir | Out-Null
    [System.IO.File]::WriteAllText(
        $scenarioConfigPath,
        '',
        [System.Text.UTF8Encoding]::new($false)
    )

    return Invoke-NewTabScenario `
        -Name $Name `
        -SeedTabs 3 `
        -OpenAction $OpenAction `
        -Layout $scenarioLayout `
        -ExePath $exePath `
        -RepoRoot $scenarioRepoRoot
}

$titlebarRun = Invoke-NewTabScenarioRun -Name 'titlebar' -OpenAction {
    param($HostHwnd, $Deadline, $Process)
    Invoke-HostCommand -HostHwnd $HostHwnd -CommandId 1904 -Deadline $Deadline -Process $Process
}

$commandRun = Invoke-NewTabScenarioRun -Name 'command-palette' -OpenAction {
    param($HostHwnd, $Deadline, $Process)
    Invoke-CommandPaletteAction -HostHwnd $HostHwnd -Action 'new_tab' -Deadline $Deadline -Process $Process
}

Write-Host (
    "interactive-win11 new-tab validation: PASS " +
    "(titlebar_stdout=$($titlebarRun.Stdout), titlebar_stderr=$($titlebarRun.Stderr), " +
    "command_stdout=$($commandRun.Stdout), command_stderr=$($commandRun.Stderr))"
)
