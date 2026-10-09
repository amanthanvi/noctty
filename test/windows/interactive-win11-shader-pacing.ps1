[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 30
)

# Regression harness for #297: with an animated custom shader and power-saver
# pacing active (Battery Saver or Energy Saver on battery, forced here with
# `power-saver-rendering = on`), typed input must reach the screen.
#
# Saver pacing allows one present per interval. Before the fix the shader's
# animation tick could take that slot with a draw-only frame every interval,
# so the deferred frame update that carries terminal output never ran: the
# shader kept animating over a frozen terminal. Whether the animation tick
# takes the lead is timing-dependent, so a single round can miss the bug;
# several rounds, each starting from idle, make a miss unlikely.
#
# The oracle is the render trace. `last_swap_process_output_bytes` is the PTY
# byte count reflected by the most recently presented frame, so it grows only
# when a frame built from new terminal output reaches the screen. Typing is
# key messages sent to the terminal surface; nothing takes the foreground.

$ErrorActionPreference = 'Stop'
$script:SHADER_PACING_POLL_MS = 100
# Saver pacing presents every 34 ms nominally (about 47 ms in practice, as it
# is measured with GetTickCount64); this only separates "late" from "never" on
# a slow machine.
$script:SHADER_PACING_PRESENT_LIMIT_MS = 2000
$script:SHADER_PACING_ROUNDS = 3
# Idle long enough between rounds for the content path's follow-up window to
# close, so each round starts with the animation tick alone.
$script:SHADER_PACING_ROUND_GAP_MS = 500
# The prompt has arrived once the presented byte count holds this long.
$script:SHADER_PACING_SETTLE_MS = 500
# WM_APP + 8; asks the surface to serialize a fresh render-trace snapshot.
$script:SHADER_PACING_TRACE_SNAPSHOT_MESSAGE = [uint32] (0x8000 + 8)
$script:SHADER_PACING_WM_KEYDOWN = [uint32] 0x0100
$script:SHADER_PACING_WM_KEYUP = [uint32] 0x0101
$script:SHADER_PACING_WM_CHAR = [uint32] 0x0102
# The animation must keep presenting at saver cadence (about 21 fps measured)
# rather than being switched off to make room for content frames. The upper
# bound proves saver pacing is in effect: unpaced, the animation presents at
# 60 fps or more, and main passes this harness for the wrong reason.
$script:SHADER_PACING_ANIMATION_WINDOW_MS = 1000
$script:SHADER_PACING_MIN_ANIMATION_SWAPS = 10
$script:SHADER_PACING_MAX_ANIMATION_SWAPS = 40

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
    -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_SHADER_PACING_BOOTSTRAPPED' `
    -ArgumentList $forwardedArgs

if ($Rebuild) {
    Push-Location $repoRoot
    try {
        zig build -Demit-exe=true -Dcustom-shaders=true
        if ($LASTEXITCODE -ne 0) { throw "shader-enabled build failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'shader-pacing' -ResetState:$ResetState
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')

if (-not ('NocttyShaderPacingNative' -as [type])) {
    Add-Type -Namespace '' -Name 'NocttyShaderPacingNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeoutW(
    System.IntPtr hWnd,
    uint Msg,
    System.UIntPtr wParam,
    System.IntPtr lParam,
    uint fuFlags,
    uint uTimeout,
    ref System.UIntPtr lpdwResult);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint MapVirtualKeyW(uint uCode, uint uMapType);
'@
}

# The surface accepts a WM_CHAR only after the WM_KEYDOWN that announced it,
# as TranslateMessage would produce, so each key is the full down/char/up.
function Send-ShaderPacingKey {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [char] $Char,
        [Parameter(Mandatory)] [DateTime] $Deadline,
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process
    )

    $vk = [uint32] [char]::ToUpperInvariant($Char)
    $scanCode = [NocttyShaderPacingNative]::MapVirtualKeyW($vk, 0)
    if ($scanCode -eq 0) { throw "MapVirtualKeyW returned 0 for VK=$vk" }
    $down = [IntPtr] (1 -bor ([int32] $scanCode -shl 16))
    $up = [IntPtr] ($down.ToInt32() -bor (-1073741824))
    foreach ($message in @(
            @($script:SHADER_PACING_WM_KEYDOWN, $vk, $down),
            @($script:SHADER_PACING_WM_CHAR, [uint32] $Char, $down),
            @($script:SHADER_PACING_WM_KEYUP, $vk, $up))) {
        [void](Invoke-InteractiveWin11Message `
                -Hwnd $Hwnd `
                -Message $message[0] `
                -WParam ([UIntPtr] [uint64] $message[1]) `
                -LParam $message[2] `
                -Deadline $Deadline `
                -Process $Process `
                -Description "key message 0x$('{0:X}' -f $message[0]) for $([int] $Char)")
    }
}

function Get-ShaderPacingTrace {
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

function Request-ShaderPacingTrace {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [uint64] $AfterSequence,
        [Parameter(Mandatory)] [DateTime] $Deadline
    )

    [UIntPtr] $messageResult = [UIntPtr]::Zero
    $sent = [NocttyShaderPacingNative]::SendMessageTimeoutW(
        $Hwnd, $script:SHADER_PACING_TRACE_SNAPSHOT_MESSAGE,
        [UIntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref] $messageResult)
    if ($sent -eq [IntPtr]::Zero) {
        throw "failed to request a render-trace snapshot (win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    while ([DateTime]::UtcNow -lt $Deadline) {
        $snapshot = Get-ShaderPacingTrace -Path $Path -AfterSequence $AfterSequence
        if ($null -ne $snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 1
    }
    throw "Timed out waiting for a fresh render-trace snapshot at $Path"
}

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
Assert-InteractiveWin11ExeExists -ExePath $exePath
$commandPath = Join-Path (Split-Path -Parent $exePath) 'noctty.com'
$versionText = & $commandPath +version | Out-String
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'custom shaders: enabled') {
    throw 'The current executable does not include custom shader support. Re-run with -Rebuild.'
}

# Any custom shader turns the animation draw timer on; the content of the
# shader does not matter to the pacing under test.
$shaderPath = Join-Path $PSScriptRoot 'fixtures\solid-magenta-shader.glsl'
$configPath = Join-Path $layout.Temp 'interactive-win11-shader-pacing.conf'
[IO.File]::WriteAllText(
    $configPath,
    "auto-update = off`r`nconfirm-close-surface = false`r`ncustom-shader-animation = true`r`npower-saver-rendering = on`r`n",
    [Text.UTF8Encoding]::new($false))

$tracePath = Join-Path $layout.Temp 'shader-pacing-render-trace.json'
Remove-Item -LiteralPath $tracePath -ErrorAction SilentlyContinue
$env:NOCTTY_RENDER_TRACE_FILE = $tracePath
$env:NOCTTY_RENDER_TRACE_LIVE = '1'

$run = $null
$before = $null
$typed = $null
$after = $null
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $run = Start-StatefulApp $layout $exePath $repoRoot 'shader-pacing' @(
        "--config-file=$configPath"
        "--custom-shader=$shaderPath"
        '-e'
        'cmd.exe'
    )
    $hostHwnd = Wait-StatefulHost $run $deadline
    $surface = Wait-StatefulSurface $hostHwnd $run $deadline

    Wait-InteractiveWin11Until `
        -Deadline $deadline `
        -Description 'a first presented frame' `
        -Process $run.Process `
        -PollMilliseconds $script:SHADER_PACING_POLL_MS `
        -Condition {
        $candidate = Get-ShaderPacingTrace -Path $tracePath
        return $null -ne $candidate -and [uint64] $candidate.swap_buffers_count -ge 1
    }

    # Wait for the shell prompt: the presented byte count has to hold still.
    $before = Request-ShaderPacingTrace -Hwnd $surface.Hwnd -Path $tracePath -AfterSequence 0 -Deadline $deadline
    $sequence = [uint64] $before.snapshot_sequence
    $stableSince = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $stableSince).TotalMilliseconds -lt $script:SHADER_PACING_SETTLE_MS) {
        Start-Sleep -Milliseconds $script:SHADER_PACING_POLL_MS
        $next = Request-ShaderPacingTrace -Hwnd $surface.Hwnd -Path $tracePath -AfterSequence $sequence -Deadline $deadline
        $sequence = [uint64] $next.snapshot_sequence
        if ([uint64] $next.last_swap_process_output_bytes -ne [uint64] $before.last_swap_process_output_bytes) {
            $stableSince = [DateTime]::UtcNow
        }
        $before = $next
    }

    # Each round has two steps, each needing its own fresh frame: the typed
    # echo, then the command's output. Letters, digits, space and Enter: each
    # character's virtual key is its upper-case ASCII code.
    $presentedMs = @()
    $typed = $before
    for ($round = 1; $round -le $script:SHADER_PACING_ROUNDS; $round++) {
        if ($round -gt 1) { Start-Sleep -Milliseconds $script:SHADER_PACING_ROUND_GAP_MS }
        foreach ($keys in @('echo 297', [string] [char] 13)) {
            $baseline = [uint64] $typed.last_swap_process_output_bytes
            foreach ($ch in $keys.ToCharArray()) {
                Send-ShaderPacingKey -Hwnd $surface.Hwnd -Char $ch -Deadline $deadline -Process $run.Process
            }
            $sent = [DateTime]::UtcNow
            $limit = $sent.AddMilliseconds($script:SHADER_PACING_PRESENT_LIMIT_MS)
            do {
                Start-Sleep -Milliseconds $script:SHADER_PACING_POLL_MS
                $typed = Request-ShaderPacingTrace -Hwnd $surface.Hwnd -Path $tracePath -AfterSequence $sequence -Deadline $deadline
                $sequence = [uint64] $typed.snapshot_sequence
            } while ([uint64] $typed.last_swap_process_output_bytes -le $baseline -and [DateTime]::UtcNow -lt $limit)
            if ([uint64] $typed.last_swap_process_output_bytes -le $baseline) {
                throw ("round ${round}: typed input did not reach a presented frame within $($script:SHADER_PACING_PRESENT_LIMIT_MS) ms: " +
                    "presented_output_bytes stayed at $baseline while swaps went $($before.swap_buffers_count) -> " +
                    "$($typed.swap_buffers_count) and frame updates went $($before.renderer_update_frame_count) -> " +
                    "$($typed.renderer_update_frame_count)")
            }
            $presentedMs += [int] ([DateTime]::UtcNow - $sent).TotalMilliseconds
        }
    }

    Start-Sleep -Milliseconds $script:SHADER_PACING_ANIMATION_WINDOW_MS
    $after = Request-ShaderPacingTrace -Hwnd $surface.Hwnd -Path $tracePath -AfterSequence $sequence -Deadline $deadline
    $animationSwaps = [uint64] $after.swap_buffers_count - [uint64] $typed.swap_buffers_count
    if ($animationSwaps -lt $script:SHADER_PACING_MIN_ANIMATION_SWAPS) {
        throw "the shader animation stopped presenting: $animationSwaps swaps in $($script:SHADER_PACING_ANIMATION_WINDOW_MS) ms"
    }
    if ($animationSwaps -gt $script:SHADER_PACING_MAX_ANIMATION_SWAPS) {
        throw "saver pacing is not in effect: $animationSwaps swaps in $($script:SHADER_PACING_ANIMATION_WINDOW_MS) ms"
    }

    Close-StatefulHost $hostHwnd $run $deadline
}
finally {
    if ($null -ne $run -and -not $run.Process.HasExited) {
        Stop-InteractiveWin11Process -Process $run.Process -Contained
    }
    Remove-Item Env:\NOCTTY_RENDER_TRACE_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\NOCTTY_RENDER_TRACE_LIVE -ErrorAction SilentlyContinue
}

Write-Host ("interactive-win11 shader-pacing validation: PASS " +
    "(presented_output_bytes={0}->{1}, frame_updates={2}->{3}, presented_within_ms={5}, animation_swaps_per_s={4})" -f `
        $before.last_swap_process_output_bytes,
    $typed.last_swap_process_output_bytes,
    $before.renderer_update_frame_count,
    $typed.renderer_update_frame_count,
    $animationSwaps,
    ($presentedMs -join '/'))
