[CmdletBinding()]
param(
    [string]$Binary = (Join-Path $PSScriptRoot '..\..\..\zig-out\bin\noctty.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'artifacts'),
    [string]$ExpectedProfileHash = '',
    [string]$ExpectedProfileMtime = '',
    [switch]$RequireHardware,
    [switch]$WarpOnly,
    [switch]$Driver,
    [string]$RealProfile = '',
    [string]$DesktopName = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native.ps1')
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot))
. (Join-Path $repoRoot 'scripts/common.ps1')
. (Join-Path $repoRoot 'scripts/windows-architecture.ps1')
. (Join-Path $repoRoot 'scripts/conpty-redist.ps1')
function Assert-PeMachine([string]$PathToCheck, [string]$ExpectedArchitecture) {
    if ([RendererNative]::PeMachine($PathToCheck) -ne (Get-WindowsPackageArchitecture -Architecture $ExpectedArchitecture).PeMachine) { throw 'Pinned ConPTY PE machine does not match the test architecture.' }
}
$Binary = [IO.Path]::GetFullPath($Binary)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (!$RealProfile) { $RealProfile = Join-Path $env:LOCALAPPDATA 'noctty\startup-attempts.json' }
function Get-ProfileReceipt {
    if (!(Test-Path -LiteralPath $RealProfile)) { return @{ exists = $false } }
    return @{ exists = $true; sha256 = (Get-FileHash -LiteralPath $RealProfile -Algorithm SHA256).Hash.ToLowerInvariant(); mtime = (Get-Item -LiteralPath $RealProfile).LastWriteTimeUtc.ToString('o') }
}
function Assert-Profile($Before) {
    $after = Get-ProfileReceipt
    if ($Before.exists -ne $after.exists -or $Before.sha256 -ne $after.sha256 -or $Before.mtime -ne $after.mtime) { throw 'Real startup-attempts.json changed; stop launches.' }
    if ($ExpectedProfileHash -and $after.sha256 -ne $ExpectedProfileHash) { throw 'Real profile differs from adopted SHA256 baseline; stop launches.' }
    if ($ExpectedProfileMtime -and $after.mtime -ne $ExpectedProfileMtime) { throw 'Real profile differs from adopted mtime baseline; stop launches.' }
    return $after
}
$before = Get-ProfileReceipt
[void](Assert-Profile $before)
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
if (!$Driver) {
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'result.json')) { throw 'Evidence already exists; use a new output directory.' }
    $DesktopName = 'renderer-test-' + [guid]::NewGuid().ToString('N')
    $desktop = [RendererNative]::CreateDesktopW($DesktopName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed; no app launched.' }
    $pi = New-Object RendererNative+PI
    try {
        $si = New-Object RendererNative+SI
        $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][RendererNative+SI])
        $si.desktop = 'WinSta0\' + $DesktopName; $si.flags = 1; $si.show = 0
        $exe = (Get-Command pwsh).Source
        # Paths are literal Windows paths; reject quotes before constructing CreateProcess argv.
        foreach ($value in @($PSCommandPath, $Binary, $OutputDirectory, $RealProfile)) { if ($value.Contains('"')) { throw 'A path contains an invalid quote.' } }
        $command = '"' + $exe + '" -NoProfile -NonInteractive -File "' + $PSCommandPath + '" -Driver -Binary "' + $Binary + '" -OutputDirectory "' + $OutputDirectory + '" -RealProfile "' + $RealProfile + '" -DesktopName ' + $DesktopName
        if ($ExpectedProfileHash) { $command += ' -ExpectedProfileHash ' + $ExpectedProfileHash }
        if ($ExpectedProfileMtime) { $command += ' -ExpectedProfileMtime ' + $ExpectedProfileMtime }
        if ($RequireHardware) { $command += ' -RequireHardware' }
        if ($WarpOnly) { $command += ' -WarpOnly' }
        if (![RendererNative]::CreateProcessW($exe, [Text.StringBuilder]::new($command), [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x08004000, [IntPtr]::Zero, $PSScriptRoot, [ref]$si, [ref]$pi)) { throw 'Hidden driver CreateProcess failed.' }
        Write-Output "Hidden renderer driver PID=$($pi.pid) desktop=$DesktopName"
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while ([RendererNative]::WaitForSingleObject($pi.process, 1000) -eq 258) {
            if ($wait.Elapsed.TotalMinutes -gt 10) { throw 'Hidden renderer driver timed out; inspect exact driver PID.' }
        }
        $code = 0; [void][RendererNative]::GetExitCodeProcess($pi.process, [ref]$code)
        $receipt = Get-Content -LiteralPath (Join-Path $OutputDirectory 'result.json') -Raw | ConvertFrom-Json
        $receipt | ConvertTo-Json -Depth 12
        if ($code -ne 0 -or $receipt.status -ne 'pass') { throw 'Renderer parity driver failed; see result.json.' }
    } finally {
        if ($pi.thread -ne [IntPtr]::Zero) { [void][RendererNative]::CloseHandle($pi.thread) }
        if ($pi.process -ne [IntPtr]::Zero) { [void][RendererNative]::CloseHandle($pi.process) }
        [void][RendererNative]::CloseDesktop($desktop)
        [void](Assert-Profile $before)
    }
    return
}
if ([RendererNative]::DesktopName() -ne $DesktopName -or !$DesktopName.StartsWith('renderer-test-')) { throw 'Driver is not on its verified hidden desktop.' }
[void][RendererNative]::SetThreadDpiAwarenessContext([IntPtr]-4)
$result = [ordered]@{ status = 'error'; hiddenDesktop = $DesktopName; profileBefore = $before; binarySHA256 = (Get-FileHash -LiteralPath $Binary).Hash; runs = @(); comparisons = @() }
function Invoke-Case([string]$Label, [string]$Backend, [hashtable]$ExtraEnvironment = @{}, [string[]]$ExtraConfig = @(), [switch]$Lifecycle, [switch]$MultiPane, [switch]$Streaming, [int]$FailureAction = 0, [switch]$ReloadUnsupported) {
    [void](Assert-Profile $before)
    $run = Join-Path $OutputDirectory $Label
    $bin = Join-Path $run 'bin'
    [void](New-Item -ItemType Directory -Path $bin)
    Copy-Item -LiteralPath $Binary -Destination (Join-Path $bin 'noctty.exe')
    if ((Get-FileHash -LiteralPath (Join-Path $bin 'noctty.exe')).Hash -ne $result.binarySHA256) { throw 'Source binary changed during this batch.' }
    $share = Join-Path (Split-Path (Split-Path $Binary)) 'share'
    if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination $run -Recurse }
    Set-Content -LiteralPath (Join-Path $bin 'noctty.portable') -Value 'isolated renderer verification'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Fixture.ps1') -Destination $bin
    $architecture = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
    if (!(Install-ConPtyRedist -PinPath (Join-Path $repoRoot 'dist/windows/conpty-redist.json') -Architecture $architecture -Destination $bin -CacheRoot (Join-Path $OutputDirectory 'conpty-cache') -RequireConPty)) { throw 'Pinned bundled ConPTY is required for protocol coverage.' }
    $config = @('auto-update=off', 'window-save-state=never', 'confirm-close-surface=false', 'window-width=96', 'window-height=28', 'font-size=14', 'font-family=JetBrains Mono', 'cursor-style=block', 'cursor-style-blink=false', 'background=#101010', 'foreground=#eeeeee', 'minimum-contrast=4.5', 'window-vsync=false', 'shell-integration=none', 'single-instance=false', 'windows-job-object-kill-on-close=true', ('renderer=' + $Backend))
    $config += 'command=direct:"' + (Get-Command pwsh).Source + '" -NoProfile -File "' + (Join-Path $bin 'Fixture.ps1') + '"'
    if ($Streaming) { $config[-1] += ' -Stream' }
    $config += $ExtraConfig
    Set-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value ($config -join "`n") -Encoding utf8
    $environment = @{ LOCALAPPDATA = (Join-Path $run 'LocalAppData'); APPDATA = (Join-Path $run 'AppData'); NOCTTY_RENDERER_CAPTURE_PATH = (Join-Path $run 'frame.bmp'); NOCTTY_RENDERER_STATUS_PATH = (Join-Path $run 'renderer.json'); NOCTTY_RENDERER_READY_PATH = (Join-Path $run 'ready.txt'); NOCTTY_RENDERER_HIDE_NOTICES = '1' }
    foreach ($key in $ExtraEnvironment.Keys) { $environment[$key] = $ExtraEnvironment[$key] }
    [void](New-Item -ItemType Directory -Path $environment.LOCALAPPDATA, $environment.APPDATA)
    if (!(Test-Path -LiteralPath (Join-Path $bin 'noctty.portable'))) { throw 'Portable marker missing; app launch blocked.' }
    $proc = $null
    $case = [ordered]@{ label = $Label; requested = $Backend; portable = $true; appDataRedirected = $true }
    try {
        $proc = Start-Process -FilePath (Join-Path $bin 'noctty.exe') -ArgumentList '--single-instance=false' -WorkingDirectory $bin -WindowStyle Hidden -Environment $environment -PassThru -RedirectStandardError (Join-Path $run 'stderr.txt')
        $identity = $proc.StartTime
        $case.pid = $proc.Id; $case.startTime = $identity
        $clock = [Diagnostics.Stopwatch]::StartNew(); $hostWindow = [IntPtr]::Zero; $surfaceWindow = [IntPtr]::Zero
        while ($clock.Elapsed.TotalSeconds -lt 40) {
            $proc.Refresh(); if ($proc.HasExited) { throw "App exited before fixture: $($proc.ExitCode)" }
            $hostWindow = [RendererNative]::Host($proc.Id)
            if ($hostWindow -ne [IntPtr]::Zero) {
                if (![RendererNative]::IsWindowVisible($hostWindow)) { [void][RendererNative]::ShowWindow($hostWindow, 4) }
                $surfaceWindow = [RendererNative]::Surface($hostWindow)
            }
            if ($surfaceWindow -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH)) { break }
            Start-Sleep -Milliseconds 25
        }
        if ($surfaceWindow -eq [IntPtr]::Zero -or !(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH)) { throw 'Fixture did not become ready.' }
        Start-Sleep -Milliseconds 500
        $capture = {
            param($Name, [switch]$NoReplay)
            if (!$NoReplay -and ![RendererNative]::Replay($surfaceWindow)) { throw 'Retained-frame redraw request failed.' }
            # Each capture must produce fresh GPU pixels and status. A failed
            # capture must never reuse an earlier frame's successful evidence.
            foreach ($path in @($environment.NOCTTY_RENDERER_CAPTURE_PATH, $environment.NOCTTY_RENDERER_STATUS_PATH)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
            if (![RendererNative]::Capture($surfaceWindow, (Join-Path $run 'gdi.png'))) { throw 'Synchronous in-app GPU readback was rejected.' }
            if (!(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_CAPTURE_PATH) -or !(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_STATUS_PATH)) { throw 'Fresh in-app GPU readback/status missing; GDI is not a substitute.' }
            $image = Join-Path $run ($Name + '.png')
            [RendererNative]::Readback($environment.NOCTTY_RENDERER_CAPTURE_PATH, $image)
            $status = Get-Content -LiteralPath $environment.NOCTTY_RENDERER_STATUS_PATH -Raw | ConvertFrom-Json
            $pixels = [RendererNative]::PixelStats($image) | ConvertFrom-Json
            if ($pixels.colors -lt 50 -or $pixels.nonblack -lt 1000) { throw 'Readback does not contain a meaningful fixture.' }
            return @{ path = $image; status = $status; pixels = $pixels }
        }
        $case.initial = & $capture 'initial'
        if ($Streaming) {
            Start-Sleep -Milliseconds 2200
            $case.streamStart = & $capture 'stream-start'
            Start-Sleep -Milliseconds 800
            $case.streamEnd = & $capture 'stream-end'
            $case.streamDiff = [RendererNative]::Diff($case.streamStart.path, $case.streamEnd.path, (Join-Path $run 'stream-diff.png')) | ConvertFrom-Json
            if ($case.streamEnd.status.frames - $case.streamStart.status.frames -lt 2 -or $case.streamDiff.different -lt 10) { throw 'Streaming output did not advance paced renderer frames and pixels.' }
        }
        if ($FailureAction) {
            $reply = [IntPtr]::Zero
            if ([RendererNative]::SendMessageTimeoutW($surfaceWindow, $FailureAction, [IntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$reply) -eq [IntPtr]::Zero -or $reply -eq [IntPtr]::Zero) { throw 'Recovery failure injection was rejected.' }
            Start-Sleep -Milliseconds 200
            $case.afterFailure = & $capture 'after-failure'
        }
        if ($Lifecycle) {
            if ($case.initial.status.backend -ne 'd3d11') { throw 'D3D11 was not selected for lifecycle verification.' }
            if (![RendererNative]::LoseDevice($surfaceWindow)) { throw 'Device-loss action failed.' }
            Start-Sleep -Milliseconds 200
            $case.recreated = & $capture 'recreated'
            if ($case.recreated.status.recoveries -lt 1 -or $case.recreated.status.generation -le $case.initial.status.generation) { throw 'Device generation did not advance.' }
            $case.recreationDiff = [RendererNative]::Diff($case.initial.path, $case.recreated.path, (Join-Path $run 'recreation-diff.png')) | ConvertFrom-Json
            if ($case.recreationDiff.different -ne 0) { throw 'Device recreation changed pixels.' }
            $rect = New-Object RendererNative+RECT; [void][RendererNative]::GetWindowRect($hostWindow, [ref]$rect)
            # Shrink rather than grow: Windows clamps a window that would exceed
            # the desktop, and CI runners' displays can be smaller than the
            # fixture window, so a growing resize left the width unchanged there.
            [void][RendererNative]::Resize($hostWindow, $rect.r - $rect.l - 100, $rect.b - $rect.t - 60)
            Start-Sleep -Milliseconds 250
            $case.resized = & $capture 'resized'
            if ($case.resized.pixels.width -eq $case.initial.pixels.width -or $case.resized.pixels.height -eq $case.initial.pixels.height) { throw 'Resize did not change physical render-target dimensions.' }
            if ($case.resized.status.resize_buffers -le $case.recreated.status.resize_buffers -or
                $case.resized.status.swapchain_width -ne $case.resized.pixels.width -or
                $case.resized.status.swapchain_height -ne $case.resized.pixels.height) { throw 'Resize did not reach DXGI ResizeBuffers with the target dimensions.' }
            [void][RendererNative]::Resize($hostWindow, $rect.r - $rect.l, $rect.b - $rect.t)
            Start-Sleep -Milliseconds 250
            $case.restored = & $capture 'restored'
            $case.resizeDiff = [RendererNative]::Diff($case.initial.path, $case.restored.path, (Join-Path $run 'resize-diff.png')) | ConvertFrom-Json
            if ($case.resizeDiff.different -ne 0) { throw 'Resize return changed pixels.' }
            $case.idleStart = & $capture 'idle-start' -NoReplay
            Start-Sleep -Milliseconds 1100
            $case.idleEnd = & $capture 'idle-end' -NoReplay
            if ($case.idleStart.status.occluded -gt 0) {
                $probes = $case.idleEnd.status.present_tests - $case.idleStart.status.present_tests
                if ($probes -lt 1 -or $probes -gt 8) { throw 'Idle occlusion retry was absent or unpaced.' }
            }
            [void][RendererNative]::ShowWindow($hostWindow, 6)
            Start-Sleep -Milliseconds 400
            $case.hiddenStart = & $capture 'minimized-start' -NoReplay
            Start-Sleep -Milliseconds 700
            $case.hiddenEnd = & $capture 'minimized-end' -NoReplay
            if ($case.hiddenEnd.status.present_tests - $case.hiddenStart.status.present_tests -gt 1) { throw 'Minimized surface kept polling presentation.' }
            [void][RendererNative]::ShowWindow($hostWindow, 4)
            Start-Sleep -Milliseconds 400
            $case.unminimized = & $capture 'unminimized'
            $dpi = [RendererNative]::GetDpiForWindow($hostWindow)
            if (![RendererNative]::Scale($surfaceWindow, 192)) { throw 'DPI scale notification rejected.' }
            Start-Sleep -Milliseconds 400
            $case.scaled = & $capture 'scaled-192dpi'
            if ($dpi -ne 192 -and $case.scaled.pixels.width -eq $case.initial.pixels.width -and $case.scaled.pixels.height -eq $case.initial.pixels.height) { throw 'DPI scale did not change the render target.' }
            if (![RendererNative]::Scale($surfaceWindow, $dpi)) { throw 'DPI scale restore rejected.' }
            Start-Sleep -Milliseconds 400
            # Font-scale notifications preserve the grid and can round the host
            # by a few physical pixels. Restore geometry before exact parity.
            [void][RendererNative]::Resize($hostWindow, $rect.r - $rect.l, $rect.b - $rect.t)
            Start-Sleep -Milliseconds 300
            $case.scaleRestored = & $capture 'scale-restored'
            $case.scaleDiff = [RendererNative]::Diff($case.initial.path, $case.scaleRestored.path, (Join-Path $run 'scale-diff.png')) | ConvertFrom-Json
            if ($case.scaleDiff.different -ne 0) { throw 'DPI scale round trip changed pixels.' }
        }
        if ($ReloadUnsupported) {
            $reloadShader = Join-Path $run 'reload.glsl'
            Set-Content -LiteralPath $reloadShader -Value 'void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }'
            $reloadImage = Join-Path $run 'reload.png'
            $image = [Drawing.Bitmap]::new(2, 2)
            try { $image.SetPixel(0, 0, [Drawing.Color]::Red); $image.Save($reloadImage, [Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
            Add-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value @(('custom-shader=' + $reloadShader), 'custom-shader-animation=false', ('background-image=' + $reloadImage))
            if (![RendererNative]::Action($surfaceWindow, 7)) { throw 'Config reload action rejected.' }
            Start-Sleep -Milliseconds 800
            $case.reloaded = & $capture 'unsupported-reload'
            if ($case.reloaded.status.backend -ne 'd3d11' -or !$case.reloaded.status.fallback_blocked) { throw 'Failed GL reload fallback did not retain D3D11.' }
            # A retained healthy device must produce more frames, not just retain
            # old readback pixels after the fallback attempt.
            Start-Sleep -Milliseconds 600
            $case.afterReload = & $capture 'after-unsupported-reload'
            if ($case.afterReload.status.frames -le $case.reloaded.status.frames) { throw 'D3D11 stopped rendering after rejected GL fallback.' }
        }
        if ($MultiPane) {
            if (![RendererNative]::Action($surfaceWindow, 2)) { throw 'Split action rejected.' }
            Start-Sleep -Milliseconds 1500
            $panes = [RendererNative]::Surfaces($hostWindow, $true)
            if ($panes.Count -ne 2) { throw 'Expected two visible split panes.' }
            $case.panes = @()
            foreach ($pane in $panes) {
                $surfaceWindow = $pane
                $frame = & $capture ('split-' + $case.panes.Count)
                if ($frame.status.backend -ne 'd3d11') { throw 'Split pane did not use D3D11.' }
                $case.panes += $frame
            }
            if (![RendererNative]::Action($surfaceWindow, 1)) { throw 'New tab action rejected.' }
            Start-Sleep -Milliseconds 1500
            if ([RendererNative]::Surfaces($hostWindow, $false).Count -ne 3 -or [RendererNative]::Surfaces($hostWindow, $true).Count -ne 1) { throw 'Tab visibility disagrees with expected pane count.' }
            $surfaceWindow = [RendererNative]::Surface($hostWindow)
            $case.newTab = & $capture 'new-tab'
            if (![RendererNative]::Action($surfaceWindow, 4)) { throw 'Previous tab action rejected.' }
            Start-Sleep -Milliseconds 300
            if ([RendererNative]::Surfaces($hostWindow, $true).Count -ne 2) { throw 'Split panes did not return on tab switch.' }
            $surfaceWindow = [RendererNative]::Surface($hostWindow)
            $case.returnedTab = & $capture 'returned-tab'
            if (![RendererNative]::Action($surfaceWindow, 6)) { throw 'Close split action rejected.' }
            Start-Sleep -Milliseconds 300
            if ([RendererNative]::Surfaces($hostWindow, $false).Count -ne 2) { throw 'Closed split resources remain attached.' }
            $surfaceWindow = [RendererNative]::Surface($hostWindow)
            $reloadShader = Join-Path $run 'reload.glsl'
            Set-Content -LiteralPath $reloadShader -Value 'void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }'
            Add-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value ('custom-shader=' + $reloadShader)
            Add-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value 'custom-shader-animation=false'
            if (![RendererNative]::Action($surfaceWindow, 7)) { throw 'Config reload action rejected.' }
            Start-Sleep -Milliseconds 1000
            $case.reloaded = & $capture 'reloaded-shader'
            if ($case.reloaded.status.backend -ne 'opengl') { throw 'Reloaded custom shader did not switch to OpenGL.' }
        }
        $caseSuccessful = $true
        return $case
    } catch {
        $case.failure = $_.Exception.Message
        $result.incompleteCase = $case
        throw
    } finally {
        if ($proc) {
            $proc.Refresh()
            if (!$proc.HasExited) {
                $live = Get-Process -Id $proc.Id -ErrorAction Ignore
                if ($live -and $live.StartTime -eq $identity -and $live.Path -eq (Join-Path $bin 'noctty.exe')) {
                    if ($hostWindow -ne [IntPtr]::Zero) { [void][RendererNative]::PostMessageW($hostWindow, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
                    $case.teardown = 'graceful'
                    if (!$proc.WaitForExit(5000)) { $proc.Refresh(); $live = Get-Process -Id $proc.Id -ErrorAction Ignore; if ($live -and $live.StartTime -eq $identity -and $live.Path -eq (Join-Path $bin 'noctty.exe')) { Stop-Process -Id $proc.Id; $proc.WaitForExit(); $case.teardown = 'forced' } }
                } else { throw 'App PID identity changed; cleanup refused.' }
            }
            $proc.Dispose()
        }
        [void](Assert-Profile $before)
        if ($caseSuccessful -and $case.teardown -ne 'graceful') { throw 'Successful renderer case did not close gracefully.' }
    }
}
try {
    # These cases need no GL driver and run on x64 and native ARM64 CI too.
    $blockedKitty = Invoke-Case 'kitty-without-gl' 'd3d11-warp' @{NOCTTY_RENDERER_FAIL_OPENGL='1';NOCTTY_RENDERER_TEST_KITTY='1'} @('power-saver-rendering=on') -Streaming
    $result.runs += $blockedKitty
    if ($blockedKitty.initial.status.backend -ne 'd3d11' -or !$blockedKitty.initial.status.fallback_blocked) { throw 'Failed GL image fallback did not retain healthy D3D11.' }
    $blockedReload = Invoke-Case 'reload-without-gl' 'd3d11-warp' @{NOCTTY_RENDERER_FAIL_OPENGL='1'} @('power-saver-rendering=on') -Streaming -ReloadUnsupported
    $result.runs += $blockedReload
    if ($WarpOnly) {
        $warp = Invoke-Case 'warp' 'd3d11-warp' -Lifecycle
        $result.runs += $warp
        if (!$warp.initial.status.warp) { throw 'Forced WARP selected hardware.' }
        $result.status = 'pass'
        return
    }
    $gl = Invoke-Case 'opengl' 'opengl'; $result.runs += $gl
    $hardware = Invoke-Case 'hardware' 'd3d11' -Lifecycle; $result.runs += $hardware
    if ($RequireHardware -and $hardware.initial.status.warp) { throw 'Hardware required, but adapter selection used WARP.' }
    $warp = Invoke-Case 'warp' 'd3d11-warp' -Lifecycle; $result.runs += $warp
    if (!$warp.initial.status.warp) { throw 'Forced WARP selected hardware.' }
    foreach ($candidate in @($hardware, $warp)) {
        $diff = [RendererNative]::Diff($gl.initial.path, $candidate.initial.path, (Join-Path $OutputDirectory ($candidate.label + '-diff.png'))) | ConvertFrom-Json
        $result.comparisons += @{ label = $candidate.label; diff = $diff }
        if (!$candidate.initial.status.warp -and $diff.different -ne 0) { throw 'Hardware differs from OpenGL.' }
        if ($candidate.initial.status.warp -and ($diff.maxChannelDelta -gt 4 -or $diff.different -gt $diff.pixels * 0.01 -or $diff.over2 -gt $diff.pixels * 0.001)) { throw 'WARP exceeds documented edge quantization tolerance.' }
    }
    $noHardware = Invoke-Case 'no-hardware' 'd3d11' @{ NOCTTY_RENDERER_FAIL_HARDWARE = '1' }; $result.runs += $noHardware
    if ($noHardware.initial.status.backend -ne 'd3d11' -or !$noHardware.initial.status.warp) { throw 'Hardware failure did not select WARP.' }
    $noDevice = Invoke-Case 'no-device' 'd3d11' @{ NOCTTY_RENDERER_FAIL_DEVICE = '1' }; $result.runs += $noDevice
    if ($noDevice.initial.status.backend -ne 'opengl') { throw 'Unavailable D3D11 did not select OpenGL.' }
    $noLibrary = Invoke-Case 'no-library' 'd3d11' @{ NOCTTY_RENDERER_FAIL_LIBRARY = '1' }; $result.runs += $noLibrary
    if ($noLibrary.initial.status.backend -ne 'opengl') { throw 'Unavailable D3D11 runtime did not select OpenGL.' }
    $resource = Invoke-Case 'resource-failure' 'd3d11' @{ NOCTTY_RENDERER_FAIL_RESOURCE = '1' }; $result.runs += $resource
    if ($resource.initial.status.backend -ne 'd3d11' -or !$resource.initial.status.warp) { throw 'Hardware startup resource failure did not select WARP.' }
    $present = Invoke-Case 'present-failure' 'd3d11' -FailureAction 0x8054; $result.runs += $present
    if ($present.afterFailure.status.backend -ne 'd3d11' -or !$present.afterFailure.status.warp) { throw 'Ordinary hardware presentation failure did not select WARP.' }
    $lostHardware = Invoke-Case 'lost-hardware' 'd3d11' -FailureAction 0x8052; $result.runs += $lostHardware
    if ($lostHardware.afterFailure.status.backend -ne 'd3d11' -or !$lostHardware.afterFailure.status.warp) { throw 'Hardware recovery failure did not select WARP.' }
    $lostAll = Invoke-Case 'lost-all' 'd3d11' -FailureAction 0x8053; $result.runs += $lostAll
    if ($lostAll.afterFailure.status.backend -ne 'opengl') { throw 'Device recovery failure did not select OpenGL.' }
    $multiPane = Invoke-Case 'multi-pane-power-saver' 'd3d11' @{} @('power-saver-rendering=on', 'unfocused-render-fps=10') -MultiPane; $result.runs += $multiPane
    $stream = Invoke-Case 'stream-power-saver' 'd3d11' @{} @('power-saver-rendering=on', 'unfocused-render-fps=10') -Streaming; $result.runs += $stream
    $shaderPath = Join-Path $OutputDirectory 'passthrough.glsl'
    Set-Content -LiteralPath $shaderPath -Value 'void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = texture(iChannel0, fragCoord / iResolution.xy); }'
    $shader = Invoke-Case 'shader-fallback' 'd3d11' @{} @('custom-shader=' + $shaderPath, 'custom-shader-animation=false'); $result.runs += $shader
    if ($shader.initial.status.backend -ne 'opengl') { throw 'Custom shader did not select OpenGL.' }
    $backgroundPath = Join-Path $OutputDirectory 'background.png'
    $background = [Drawing.Bitmap]::new(2, 2)
    try { $background.SetPixel(0, 0, [Drawing.Color]::Red); $background.Save($backgroundPath, [Drawing.Imaging.ImageFormat]::Png) } finally { $background.Dispose() }
    $image = Invoke-Case 'background-image-fallback' 'd3d11' @{} @('background-image=' + $backgroundPath); $result.runs += $image
    if ($image.initial.status.backend -ne 'opengl') { throw 'Background image did not select OpenGL.' }
    $kitty = Invoke-Case 'kitty-fallback' 'd3d11' @{ NOCTTY_RENDERER_TEST_KITTY = '1' }; $result.runs += $kitty
    if ($kitty.initial.status.backend -ne 'opengl') { throw 'Kitty images did not trigger OpenGL fallback.' }
    $result.status = 'pass'
} catch { $result.failure = $_.Exception.Message }
finally {
    $result.profileAfter = Assert-Profile $before
    $result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json') -Encoding utf8
}
if ($result.status -ne 'pass') { exit 1 }
