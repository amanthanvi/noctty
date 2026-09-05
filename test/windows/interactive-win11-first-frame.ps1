[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 30
)

# Regression harness for #224: the window must present terminal content before
# it is given any input.
#
# The whole point of the bug is that a keystroke hides it, so this harness
# never sends one and never touches the mouse, the foreground or the window
# placement. The oracle is the render trace, which the app writes to disk by
# itself on its FIRST successful SwapBuffers (RenderTrace.noteSwapBuffers /
# shouldWriteSnapshotAfterSwap). No file means no frame ever reached the
# screen, which is exactly the reported symptom.
#
# The only thing sent to the app before the assertions pass is
# WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT. That is a sent message: the app services
# it from inside GetMessageW without returning to the loop body, so it does not
# run tickCoreApp and cannot drain the app mailbox the way a real input message
# would. It carries no terminal input.

$ErrorActionPreference = 'Stop'
# Poll cadence while waiting for the first-frame trace to land.
$script:FIRST_FRAME_POLL_MS = 100
# WM_APP + 8; asks the surface to serialize a fresh render-trace snapshot.
$script:FIRST_FRAME_TRACE_SNAPSHOT_MESSAGE = [uint32] (0x8000 + 8)
# A first-show wake is a one-shot per surface and there are two of them
# (host_shown and paint_without_content). More than that means the handshake
# became a steady-state repaint source and the #134 idle budget is at risk.
$script:FIRST_FRAME_MAX_FIRST_SHOW_WAKEUPS = 2

if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be greater than 0.' }

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')

$forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
if ($Rebuild) { $forwardedArgs += '-Rebuild' }
if ($ResetState) { $forwardedArgs += '-ResetState' }
Invoke-InteractiveWin11HarnessMain `
    -RepoRoot $repoRoot `
    -LauncherPath $launcherPath `
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_FIRST_FRAME_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')

if (-not ('NocttyFirstFrameNative' -as [type])) {
    Add-Type -Namespace '' -Name 'NocttyFirstFrameNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeoutW(
    System.IntPtr hWnd,
    uint Msg,
    System.UIntPtr wParam,
    System.IntPtr lParam,
    uint fuFlags,
    uint uTimeout,
    ref System.UIntPtr lpdwResult);
'@
}

function Get-FirstFrameTrace {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [uint64] $AfterSequence = 0
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $snapshot = $raw | ConvertFrom-Json
    }
    catch { return $null }
    if ([uint64] $snapshot.snapshot_sequence -le $AfterSequence) { return $null }
    return $snapshot
}

function Request-FirstFrameTrace {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [uint64] $AfterSequence,
        [Parameter(Mandatory)] [DateTime] $Deadline
    )

    [UIntPtr] $messageResult = [UIntPtr]::Zero
    $sent = [NocttyFirstFrameNative]::SendMessageTimeoutW(
        $Hwnd, $script:FIRST_FRAME_TRACE_SNAPSHOT_MESSAGE,
        [UIntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref] $messageResult)
    if ($sent -eq [IntPtr]::Zero) {
        throw "failed to request a render-trace snapshot (win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    while ([DateTime]::UtcNow -lt $Deadline) {
        $snapshot = Get-FirstFrameTrace -Path $Path -AfterSequence $AfterSequence
        if ($null -ne $snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 1
    }
    throw "Timed out waiting for a fresh render-trace snapshot at $Path"
}

# UIA text read, bounded by a job so a hung provider cannot wedge the run.
# Reported, not asserted: the trace assertions are the gate, and whether the
# terminal UIA provider is instantiated depends on which clients are attached.
function Get-FirstFrameTerminalText {
    param(
        [Parameter(Mandatory)] [IntPtr] $HostHwnd,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $ProbeTimeoutSeconds = 5
    )

    $probe = Start-Job -ScriptBlock {
        param([long] $HwndValue, [int] $TargetProcessId)

        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr] $HwndValue)
        if ($null -eq $root) { return '' }

        $documents = @($root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text
                )
            ) | Where-Object {
                $_.Current.ProcessId -eq $TargetProcessId -and
                $_.Current.LocalizedControlType -eq 'terminal'
            })
        if ($documents.Count -eq 0) { return '' }

        $textPattern = $null
        if (-not $documents[0].TryGetCurrentPattern(
                [System.Windows.Automation.TextPattern]::Pattern,
                [ref] $textPattern)) {
            return ''
        }
        return [string] $textPattern.DocumentRange.GetText(-1)
    } -ArgumentList $HostHwnd.ToInt64(), $Process.Id

    try {
        if ($null -eq (Wait-Job -Job $probe -Timeout $ProbeTimeoutSeconds)) { return '' }
        return [string] (Receive-Job -Job $probe -ErrorAction Stop)
    }
    catch { return '' }
    finally {
        Stop-Job -Job $probe -ErrorAction SilentlyContinue
        Remove-Job -Job $probe -Force -ErrorAction SilentlyContinue
    }
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'first-frame' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
if ((Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs) -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}
Assert-InteractiveWin11ExeExists -ExePath $exePath

# The reporter runs a default config plus `auto-update = off`; keep that shape
# so nothing here depends on a setting the bug report did not have.
$stateDir = Join-Path $layout.LocalAppData 'noctty'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $stateDir 'config.ghostty'),
    "auto-update = off`r`nconfirm-close-surface = false`r`n",
    [Text.UTF8Encoding]::new($false))

$tracePath = Join-Path $layout.Temp 'first-frame-render-trace.json'
Remove-Item -LiteralPath $tracePath -ErrorAction SilentlyContinue
$env:NOCTTY_RENDER_TRACE_FILE = $tracePath
$env:NOCTTY_RENDER_TRACE_LIVE = '1'

$script:firstFrameTraceCapture = $null
$run = $null
$firstFrameTrace = $null
$outputTrace = $null
$terminalText = ''
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $run = Start-StatefulApp $layout $exePath $repoRoot 'first-frame'
    $hostHwnd = Wait-StatefulHost $run $deadline
    $surface = Wait-StatefulSurface $hostHwnd $run $deadline

    # Nothing is sent to the app here: only the filesystem is polled.
    Wait-InteractiveWin11Until `
        -Deadline $deadline `
        -Description 'a presented frame before any input' `
        -Process $run.Process `
        -PollMilliseconds $script:FIRST_FRAME_POLL_MS `
        -Condition {
        $candidate = Get-FirstFrameTrace -Path $tracePath
        if ($null -eq $candidate) { return $false }
        if ([uint64] $candidate.swap_buffers_count -lt 1) { return $false }
        $script:firstFrameTraceCapture = $candidate
        return $true
    }
    $firstFrameTrace = $script:firstFrameTraceCapture

    if ([uint64] $firstFrameTrace.paint_draw_count -lt 1) {
        throw "a swap happened without a WM_PAINT that drew renderer content (paint_draw_count=$($firstFrameTrace.paint_draw_count))"
    }

    # A frame reached the screen. Now prove it carried shell output rather than
    # an empty clear: last_swap_process_output_bytes is the PTY byte count
    # committed to the terminal as of the most recent swap.
    $sequence = [uint64] $firstFrameTrace.snapshot_sequence
    while ([DateTime]::UtcNow -lt $deadline) {
        $outputTrace = Request-FirstFrameTrace -Hwnd $surface.Hwnd -Path $tracePath `
            -AfterSequence $sequence -Deadline $deadline
        $sequence = [uint64] $outputTrace.snapshot_sequence
        if ([uint64] $outputTrace.last_swap_process_output_bytes -gt 0) { break }
        Start-Sleep -Milliseconds $script:FIRST_FRAME_POLL_MS
    }
    if ($null -eq $outputTrace -or [uint64] $outputTrace.last_swap_process_output_bytes -lt 1) {
        throw 'no presented frame carried shell output before any input was sent'
    }

    # The post-show handshake is a bounded one-shot, not a repaint source.
    if ([uint64] $outputTrace.first_show_wakeup_count -gt $script:FIRST_FRAME_MAX_FIRST_SHOW_WAKEUPS) {
        throw "first-show wakes are not bounded (first_show_wakeup_count=$($outputTrace.first_show_wakeup_count))"
    }

    $terminalText = Get-FirstFrameTerminalText -HostHwnd $hostHwnd -Process $run.Process

    Close-StatefulHost $hostHwnd $run $deadline
}
finally {
    if ($null -ne $run -and -not $run.Process.HasExited) {
        Stop-InteractiveWin11Process -Process $run.Process -Contained
    }
    Remove-Item Env:\NOCTTY_RENDER_TRACE_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\NOCTTY_RENDER_TRACE_LIVE -ErrorAction SilentlyContinue
}

if (Select-String -LiteralPath $run.Stderr -SimpleMatch 'shell/native invariant failed' -Quiet) {
    throw "Shell/native invariant failure reported by $($run.Stderr)."
}

$uia = if ([string]::IsNullOrWhiteSpace($terminalText)) { 'unavailable' } else { "$($terminalText.Trim().Length) chars" }
Write-Host ("interactive-win11 first-frame validation: PASS " +
    "(swaps={0}, paints={1}, first_swap_ms={2}, presented_output_bytes={3}, first_show_wakes={4}, uia={5})" -f `
        $outputTrace.swap_buffers_count,
    $outputTrace.paint_draw_count,
    $firstFrameTrace.process_start_to_first_swap_ms,
    $outputTrace.last_swap_process_output_bytes,
    $outputTrace.first_show_wakeup_count,
    $uia)
