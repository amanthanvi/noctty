param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $SeedTabs = 4,
    [int] $EscapeAfterMs = 1200,
    [int] $TimeoutSeconds = 25
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

if ($SeedTabs -lt 2) {
    throw 'SeedTabs must be at least 2 for the multi-tab +boo regression.'
}

if ($EscapeAfterMs -le 0) {
    throw 'EscapeAfterMs must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_BOO_MULTITAB_BOOTSTRAPPED) {
    $forwardedArgs = @(
        '-SeedTabs', $SeedTabs.ToString(),
        '-EscapeAfterMs', $EscapeAfterMs.ToString(),
        '-TimeoutSeconds', $TimeoutSeconds.ToString()
    )
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_BOO_MULTITAB_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

if (-not ('InteractiveWin11BooMultiTabNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class InteractiveWin11BooMultiTabNative {
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
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

}

public sealed class InteractiveWin11BooMultiTabChildControl {
    public InteractiveWin11BooMultiTabChildControl(IntPtr hwnd, int id) {
        Hwnd = hwnd;
        Id = id;
    }

    public IntPtr Hwnd { get; private set; }
    public int Id { get; private set; }
}
"@
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

function New-KeyLParam {
    param(
        [Parameter(Mandatory)] [uint16] $ScanCode,
        [switch] $KeyUp
    )

    [int32] $lParam = 1 -bor (($ScanCode -band 0xff) -shl 16)
    if ($KeyUp) {
        $lParam = $lParam -bor (-1073741824)
    }
    return [IntPtr] $lParam
}

function Get-WindowClassName {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $builder = [System.Text.StringBuilder]::new(256)
    [void] [InteractiveWin11BooMultiTabNative]::GetClassNameW($Hwnd, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Find-HostWindow {
    param(
        [Parameter(Mandatory)] [int] $ProcessId
    )

    $script:InteractiveWin11BooMultiTabFoundHost = [IntPtr]::Zero
    $callback = [InteractiveWin11BooMultiTabNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        [uint32] $windowPid = 0
        [void] [InteractiveWin11BooMultiTabNative]::GetWindowThreadProcessId($hwnd, [ref] $windowPid)
        if ($windowPid -ne $ProcessId) {
            return $true
        }

        if ((Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32.host') {
            $script:InteractiveWin11BooMultiTabFoundHost = $hwnd
            return $false
        }

        return $true
    }

    [void] [InteractiveWin11BooMultiTabNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:InteractiveWin11BooMultiTabFoundHost
}

function Find-SurfaceWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:InteractiveWin11BooMultiTabFoundSurface = [IntPtr]::Zero
    $callback = [InteractiveWin11BooMultiTabNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if (
            (Get-WindowClassName -Hwnd $hwnd) -eq 'winghostty.win32' -and
            [InteractiveWin11BooMultiTabNative]::GetParent($hwnd) -eq $Parent -and
            [InteractiveWin11BooMultiTabNative]::IsWindowVisible($hwnd)
        ) {
            $script:InteractiveWin11BooMultiTabFoundSurface = $hwnd
            return $false
        }

        return $true
    }

    [void] [InteractiveWin11BooMultiTabNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:InteractiveWin11BooMultiTabFoundSurface
}

function Test-SurfaceWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [IntPtr] $ExpectedParent
    )

    if (-not [InteractiveWin11BooMultiTabNative]::IsWindow($Hwnd)) {
        return $false
    }

    if ((Get-WindowClassName -Hwnd $Hwnd) -ne 'winghostty.win32') {
        return $false
    }

    if ([InteractiveWin11BooMultiTabNative]::GetParent($Hwnd) -ne $ExpectedParent) {
        return $false
    }

    if (-not [InteractiveWin11BooMultiTabNative]::IsWindowVisible($Hwnd)) {
        return $false
    }

    return $true
}

function Get-VisibleChildControls {
    param(
        [Parameter(Mandatory)] [IntPtr] $Parent
    )

    $script:InteractiveWin11BooMultiTabChildControls = [System.Collections.Generic.List[InteractiveWin11BooMultiTabChildControl]]::new()
    $callback = [InteractiveWin11BooMultiTabNative+EnumWindowsProc] {
        param([IntPtr] $hwnd, [IntPtr] $lParam)

        if ([InteractiveWin11BooMultiTabNative]::IsWindowVisible($hwnd)) {
            $control = [InteractiveWin11BooMultiTabChildControl]::new(
                $hwnd,
                [InteractiveWin11BooMultiTabNative]::GetDlgCtrlID($hwnd)
            )
            [void] $script:InteractiveWin11BooMultiTabChildControls.Add($control)
        }

        return $true
    }

    [void] [InteractiveWin11BooMultiTabNative]::EnumChildWindows($Parent, $callback, [IntPtr]::Zero)
    return $script:InteractiveWin11BooMultiTabChildControls.ToArray()
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

function Invoke-HostCommand {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [int] $CommandId,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    [void] (Invoke-InteractiveWin11Message -Hwnd $HostHwnd -Message 0x0111 -WParam (New-WParam -Low $CommandId) -Deadline $Deadline -Description "WM_COMMAND $CommandId" -Process $Process)
}

function Invoke-TabButtonActivation {
    param(
        [Parameter(Mandatory)] [InteractiveWin11BooMultiTabChildControl] $Tab,
        [Parameter(Mandatory)] [IntPtr] $ExpectedParent,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    if (
        -not [InteractiveWin11BooMultiTabNative]::IsWindow($Tab.Hwnd) -or
        [InteractiveWin11BooMultiTabNative]::GetParent($Tab.Hwnd) -ne $ExpectedParent -or
        [InteractiveWin11BooMultiTabNative]::GetDlgCtrlID($Tab.Hwnd) -ne $Tab.Id
    ) {
        throw "initial tab button handle is stale or was recycled; control=$($Tab.Id)"
    }

    $rect = [InteractiveWin11BooMultiTabNative+RECT]::new()
    if (-not [InteractiveWin11BooMultiTabNative]::GetClientRect($Tab.Hwnd, [ref] $rect)) {
        throw "failed to read tab button client rect for control $($Tab.Id)"
    }

    $x = [Math]::Max(1, [int] (($rect.Right - $rect.Left) / 2))
    $y = [Math]::Max(1, [int] (($rect.Bottom - $rect.Top) / 2))
    $lParam = New-LParam -X $x -Y $y
    [void] (Invoke-InteractiveWin11Message -Hwnd $Tab.Hwnd -Message 0x0201 -LParam $lParam -Deadline $Deadline -Description "tab button mouse down control=$($Tab.Id)" -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $Tab.Hwnd -Message 0x0202 -LParam $lParam -Deadline $Deadline -Description "tab button mouse up control=$($Tab.Id)" -Process $Process)
}

function Send-TextKeyMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint16] $VirtualKey,
        [Parameter(Mandatory)] [uint16] $CharCode,
        [uint16] $ScanCode = 0x1E,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    [void] (Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0100 -WParam ([UIntPtr]([uint64] $VirtualKey)) -LParam (New-KeyLParam -ScanCode $ScanCode) -Deadline $Deadline -Description "WM_KEYDOWN vk=$VirtualKey" -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0102 -WParam ([UIntPtr]([uint64] $CharCode)) -LParam (New-KeyLParam -ScanCode $ScanCode) -Deadline $Deadline -Description "WM_CHAR char=$CharCode" -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0101 -WParam ([UIntPtr]([uint64] $VirtualKey)) -LParam (New-KeyLParam -ScanCode $ScanCode -KeyUp) -Deadline $Deadline -Description "WM_KEYUP vk=$VirtualKey" -Process $Process)
}

function Send-KeyPressMessage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [uint16] $VirtualKey,
        [Parameter(Mandatory)] [uint16] $ScanCode,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    [void] (Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0100 -WParam ([UIntPtr]([uint64] $VirtualKey)) -LParam (New-KeyLParam -ScanCode $ScanCode) -Deadline $Deadline -Description "WM_KEYDOWN vk=$VirtualKey" -Process $Process)
    [void] (Invoke-InteractiveWin11Message -Hwnd $Hwnd -Message 0x0101 -WParam ([UIntPtr]([uint64] $VirtualKey)) -LParam (New-KeyLParam -ScanCode $ScanCode -KeyUp) -Deadline $Deadline -Description "WM_KEYUP vk=$VirtualKey" -Process $Process)
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'boo-multitab' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

$stdoutPath = Join-Path $layout.Logs 'interactive-win11-boo-multitab-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-boo-multitab-stderr.log'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-payload.ps1'
$goPath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-go.txt'
$statePath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-state.json'
$resultPath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-result.json'
$renderTracePath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-render.json'
$termioTracePath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-termio.json'
$booTracePath = Join-Path $layout.Temp 'interactive-win11-boo-multitab-boo.json'
$booAutoExitMs = 12000

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $goPath, $statePath, $resultPath, $renderTracePath, $termioTracePath, $booTracePath -ErrorAction SilentlyContinue

$payload = @'
try {
    [ordered]@{
        phase = 'payload-start'
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII

    while (-not (Test-Path -LiteralPath '__GO_PATH__')) {
        Start-Sleep -Milliseconds 100
    }

    [ordered]@{
        phase = 'after-go'
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII

    $winghosttyCommand = Get-Command winghostty -ErrorAction Stop
    $commandSource = $winghosttyCommand.Source
    [ordered]@{
        phase = 'before-boo'
        commandSource = $commandSource
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII
    $booStart = Get-Date
    & winghostty +boo
    $booExitCode = $LASTEXITCODE

    [ordered]@{
        phase = 'after-boo'
        commandSource = $winghosttyCommand.Source
        exitCode = $booExitCode
        elapsedMs = [int]((Get-Date) - $booStart).TotalMilliseconds
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII

    $key = [Console]::ReadKey($true)
    [ordered]@{
        keyCharCode = [int][char]$key.KeyChar
        keyChar = [string]$key.KeyChar
        key = $key.Key.ToString()
        modifiers = $key.Modifiers.ToString()
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath '__RESULT_PATH__' -Encoding ASCII
}
catch {
    [ordered]@{
        phase = 'payload-error'
        message = $_.Exception.Message
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath '__STATE_PATH__' -Encoding ASCII
    throw
}
'@
$payload = $payload.
    Replace('__STATE_PATH__', $statePath).
    Replace('__GO_PATH__', $goPath).
    Replace('__RESULT_PATH__', $resultPath)
$payload | Set-Content -LiteralPath $payloadPath -Encoding UTF8

$traceEnv = [ordered]@{
    WINGHOSTTY_RENDER_TRACE_FILE = $renderTracePath
    WINGHOSTTY_TERMIO_TRACE_FILE = $termioTracePath
    WINGHOSTTY_BOO_STATE_FILE = $booTracePath
    WINGHOSTTY_BOO_AUTO_EXIT_MS = $booAutoExitMs.ToString()
}

$savedEnv = [ordered]@{}
foreach ($entry in $traceEnv.GetEnumerator()) {
    $savedEnv[[string] $entry.Key] = [System.Environment]::GetEnvironmentVariable([string] $entry.Key, 'Process')
    [System.Environment]::SetEnvironmentVariable([string] $entry.Key, [string] $entry.Value, 'Process')
}

$launchArgs = @(
    (Get-InteractiveWin11LaunchArguments -Layout $layout)
    '--config-default-files=false'
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
)

$process = $null
try {
    $process = Start-Process -FilePath $exePath `
        -ArgumentList $launchArgs `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'host window' -Process $process -Condition {
        (Find-HostWindow -ProcessId $process.Id) -ne [IntPtr]::Zero
    }

    $hostHwnd = Find-HostWindow -ProcessId $process.Id
    Show-InteractiveWin11Window -Hwnd $hostHwnd -NativeType ([InteractiveWin11BooMultiTabNative]) -SetForeground

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'surface child window' -Process $process -Condition {
        (Find-SurfaceWindow -Parent $hostHwnd) -ne [IntPtr]::Zero
    }
    $initialSurfaceHwnd = Find-SurfaceWindow -Parent $hostHwnd
    if ($initialSurfaceHwnd -eq [IntPtr]::Zero) {
        throw 'initial surface disappeared after discovery'
    }
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'initial tab button' -Process $process -Condition {
        (Get-VisibleTabCount -Parent $hostHwnd) -ge 1
    }
    $initialTabButton = Get-VisibleTabButtons -Parent $hostHwnd | Select-Object -First 1
    if ($null -eq $initialTabButton) {
        throw 'initial tab button was not visible before seeding tabs'
    }

    while ((Get-VisibleTabCount -Parent $hostHwnd) -lt $SeedTabs) {
        $targetTabCount = (Get-VisibleTabCount -Parent $hostHwnd) + 1
        Invoke-HostCommand -HostHwnd $hostHwnd -CommandId 1904 -Deadline $deadline -Process $process
        Wait-InteractiveWin11Until -Deadline $deadline -Description "seed tabs ($targetTabCount/$SeedTabs)" -Process $process -Condition {
            (Get-VisibleTabCount -Parent $hostHwnd) -ge $targetTabCount
        }
    }

    Invoke-TabButtonActivation -Tab $initialTabButton -ExpectedParent $hostHwnd -Deadline $deadline -Process $process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'initial surface reactivation' -Process $process -Condition {
        Test-SurfaceWindow -Hwnd $initialSurfaceHwnd -ExpectedParent $hostHwnd
    }
    $surfaceHwnd = $initialSurfaceHwnd
    Start-Sleep -Milliseconds 300

    'go' | Set-Content -LiteralPath $goPath -Encoding ASCII

    Wait-InteractiveWin11Until -Deadline $deadline -Description '+boo trace start file' -Process $process -Condition {
        if (-not (Test-Path -LiteralPath $booTracePath)) {
            return $false
        }
        try {
            $booTraceProbe = Get-Content -LiteralPath $booTracePath -Raw | ConvertFrom-Json
            return $booTraceProbe.phase -eq 'before_app_run'
        }
        catch {
            return $false
        }
    }

    Start-Sleep -Milliseconds $EscapeAfterMs
    Send-KeyPressMessage -Hwnd $surfaceHwnd -VirtualKey 0x1B -ScanCode 0x01 -Deadline $deadline -Process $process

    Wait-InteractiveWin11Until -Deadline $deadline -Description 'post-boo state file' -Process $process -Condition {
        if (-not (Test-Path -LiteralPath $statePath)) {
            return $false
        }
        try {
            $stateProbe = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            return $stateProbe.phase -eq 'after-boo'
        }
        catch {
            return $false
        }
    }

    $state = Get-InteractiveWin11RequiredJsonFile -Path $statePath
    if ($state.exitCode -ne 0) {
        throw @"
winghostty +boo exited with code $($state.exitCode)
stdout:
$(Get-InteractiveWin11TextFileTail -Path $stdoutPath)

stderr:
$(Get-InteractiveWin11TextFileTail -Path $stderrPath)
"@
    }

    if ($state.elapsedMs -ge ($booAutoExitMs - 1000)) {
        throw "Expected +boo to respond to Escape before auto-exit; elapsedMs=$($state.elapsedMs)"
    }

    if (
        -not (Test-SurfaceWindow -Hwnd $initialSurfaceHwnd -ExpectedParent $hostHwnd)
    ) {
        throw 'initial surface disappeared or became hidden after +boo'
    }

    Send-TextKeyMessage -Hwnd $initialSurfaceHwnd -VirtualKey 0x41 -CharCode 97 -Deadline $deadline -Process $process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'post-boo key result file' -Process $process -Condition {
        Test-Path -LiteralPath $resultPath
    }

    $result = Get-InteractiveWin11RequiredJsonFile -Path $resultPath
    if ($result.keyCharCode -ne 97 -or $result.key -ne 'A') {
        throw "unexpected post-boo key input result: $($result | ConvertTo-Json -Compress)"
    }

    Stop-InteractiveWin11Process -Process $process
    $process = $null

    Wait-InteractiveWin11Until -Deadline ([DateTime]::UtcNow.AddSeconds(3)) -Description 'post-exit trace files' -Condition {
        (Test-Path -LiteralPath $renderTracePath) -and
            (Test-Path -LiteralPath $termioTracePath) -and
            (Test-Path -LiteralPath $booTracePath)
    }

    $renderTrace = Get-InteractiveWin11RequiredJsonFile -Path $renderTracePath
    $termioTrace = Get-InteractiveWin11RequiredJsonFile -Path $termioTracePath
    $booTrace = Get-InteractiveWin11RequiredJsonFile -Path $booTracePath

    if ($booTrace.rendered_byte_count -lt 40000) {
        throw "Expected +boo to emit substantial frame output; rendered_byte_count=$($booTrace.rendered_byte_count)"
    }
    if ($renderTrace.paint_draw_count -lt 20) {
        throw "Expected multi-tab +boo to keep visible paint cadence above the stalled path; paint_draw_count=$($renderTrace.paint_draw_count)"
    }
    if ($termioTrace.process_output_count -lt 20) {
        throw "Expected steady PTY output batches for +boo; process_output_count=$($termioTrace.process_output_count)"
    }
    if ($booTrace.frame_change_count -lt 25) {
        throw "Expected +boo child animation to advance near full rate; frame_change_count=$($booTrace.frame_change_count)"
    }

    Write-Host "interactive-win11 boo multitab validation: PASS (tabs=$SeedTabs, source=$($state.commandSource), elapsed=$($state.elapsedMs), updates=$($renderTrace.renderer_update_frame_count), paints=$($renderTrace.paint_draw_count), frames=$($booTrace.frame_change_count), bytes=$($booTrace.rendered_byte_count))"
}
finally {
    foreach ($entry in $savedEnv.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable(
            [string] $entry.Key,
            [string] $entry.Value,
            [System.EnvironmentVariableTarget]::Process
        )
    }

    if ($null -ne $process) {
        Stop-InteractiveWin11Process -Process $process
    }
}
