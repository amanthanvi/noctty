[CmdletBinding()]
param(
    [string]$Binary = (Join-Path $PSScriptRoot '..\..\..\zig-out\bin\noctty.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'artifacts'),
    [string]$ExpectedProfileHash = '',
    [string]$ExpectedProfileMtime = '',
    [switch]$RequireHardware,
    [switch]$WarpOnly,
    [switch]$OpenGLStartupOnly,
    [switch]$SplitDimOnly,
    [switch]$PreeditCaretOnly,
    [switch]$Driver,
    [string]$RealProfile = '',
    [string]$DesktopName = ''
)

. (Join-Path $PSScriptRoot '..\..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'Invoke-RendererParity.ps1'
try {

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
        if ($OpenGLStartupOnly) { $command += ' -OpenGLStartupOnly' }
        if ($SplitDimOnly) { $command += ' -SplitDimOnly' }
        if ($PreeditCaretOnly) { $command += ' -PreeditCaretOnly' }
        if (![RendererNative]::CreateProcessW($exe, [Text.StringBuilder]::new($command), [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x08004000, [IntPtr]::Zero, $PSScriptRoot, [ref]$si, [ref]$pi)) { throw 'Hidden driver CreateProcess failed.' }
        Write-Output "Hidden renderer driver PID=$($pi.pid) desktop=$DesktopName"
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while ([RendererNative]::WaitForSingleObject($pi.process, 1000) -eq 258) {
            if ($wait.Elapsed.TotalMinutes -gt 10) { throw 'Hidden renderer driver timed out; inspect exact driver PID.' }
        }
        $code = 0; [void][RendererNative]::GetExitCodeProcess($pi.process, [ref]$code)
        $receiptPath = Join-Path $OutputDirectory 'result.json'
        if (!(Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Renderer parity driver exited with code $code before writing result.json." }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
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
function Invoke-Case([string]$Label, [string]$Backend, [hashtable]$ExtraEnvironment = @{}, [string[]]$ExtraConfig = @(), [switch]$Lifecycle, [switch]$MultiPane, [switch]$Streaming, [int]$FailureAction = 0, [switch]$ReloadUnsupported, [switch]$ReloadImages, [switch]$RetryHardware, [switch]$OpenGLStartupFallback, [switch]$SplitDim, [switch]$HoldSync, [switch]$NoShaderReload, [string]$SplitFill = '', [double]$SplitOpacity = 0.7, [switch]$PreeditCaret, [switch]$HideCursor) {
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
    if ($HoldSync) { $config[-1] += ' -HoldSync' }
    if ($HideCursor) { $config[-1] += ' -HideCursor' }
    if ($PreeditCaret) {
        $config[-1] += ' -Tick'
        # The caret is drawn in the cursor colour; no fixture text has it.
        $config += 'cursor-color=#13f7a9'
    }
    if ($SplitDim) {
        $config[-1] += ' -HideCursor'
        $config += 'unfocused-split-opacity=' + $SplitOpacity.ToString([Globalization.CultureInfo]::InvariantCulture)
        if ($SplitFill) { $config += 'unfocused-split-fill=#' + $SplitFill }
    }
    $config += $ExtraConfig
    $config += 'class=noctty-test-renderer-' + [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value ($config -join "`n") -Encoding utf8
    $environment = @{ LOCALAPPDATA = (Join-Path $run 'LocalAppData'); APPDATA = (Join-Path $run 'AppData'); NOCTTY_RENDERER_CAPTURE_PATH = (Join-Path $run 'frame.bmp'); NOCTTY_RENDERER_STATUS_PATH = (Join-Path $run 'renderer.json'); NOCTTY_RENDERER_READY_PATH = (Join-Path $run 'ready.txt'); NOCTTY_RENDERER_HIDE_NOTICES = '1' }
    foreach ($key in $ExtraEnvironment.Keys) { $environment[$key] = $ExtraEnvironment[$key] }
    # The fallback case reads its banner through UIA. An info banner's
    # countdown starts when it is set, so on a slow cold launch it could be
    # gone before the first read; this test-tools switch keeps it up.
    if ($OpenGLStartupFallback) { [void]$environment.Remove('NOCTTY_RENDERER_HIDE_NOTICES'); $environment.NOCTTY_RENDERER_KEEP_NOTICES = '1' }
    [void](New-Item -ItemType Directory -Path $environment.LOCALAPPDATA, $environment.APPDATA)
    if (!(Test-Path -LiteralPath (Join-Path $bin 'noctty.portable'))) { throw 'Portable marker missing; app launch blocked.' }
    $proc = $null
    $nativeProcess = New-Object RendererNative+PI
    if ($OpenGLStartupFallback) {
        Add-Type -AssemblyName UIAutomationClient
        # A process's first UIA call may be slow on a cold runner. Make it
        # before the launch, on this desktop's root, which needs nothing from
        # the app, so it neither falls in the banner wait nor blocks the poll
        # that sees the banner shown.
        $warmup = [Diagnostics.Stopwatch]::StartNew(); $warmupError = $null
        try { [void][Windows.Automation.AutomationElement]::RootElement.Current.Name }
        catch { $warmupError = $_.Exception.GetType().Name + ': ' + $_.Exception.Message }
        $warmupMs = $warmup.ElapsedMilliseconds
    }
    $case = [ordered]@{ label = $Label; requested = $Backend; portable = $true; appDataRedirected = $true }
    try {
        $nativeProcess = [RendererNative]::Launch((Join-Path $bin 'noctty.exe'), $bin, $DesktopName, $environment, (Join-Path $run 'stderr.txt'))
        try { $proc = Get-Process -Id $nativeProcess.pid } catch {
            $exitCode=0; [void][RendererNative]::GetExitCodeProcess($nativeProcess.process,[ref]$exitCode)
            throw "App exited before fixture: $exitCode"
        }
        $identity = $proc.StartTime
        $case.pid = $proc.Id; $case.startTime = $identity
        $clock = [Diagnostics.Stopwatch]::StartNew(); $hostWindow = [IntPtr]::Zero; $surfaceWindow = [IntPtr]::Zero
        # What the banner reads said, kept on a pass and for a timeout: a slow
        # WM_NULL points at a busy UI thread, a different name at another
        # banner.
        if ($OpenGLStartupFallback) { $case.bannerWait = [ordered]@{ warmupMs = $warmupMs; warmupError = $warmupError; shownMs = $null; reads = 0; longestPingMs = 0; longestReadMs = 0; lastName = $null; lastReadMs = $null; foundReadStartMs = $null; foundMs = $null; waitMs = $null } }
        while ($clock.Elapsed.TotalSeconds -lt 40) {
            if ([RendererNative]::WaitForSingleObject($nativeProcess.process,0) -eq 0) {
                $exitCode=0; [void][RendererNative]::GetExitCodeProcess($nativeProcess.process,[ref]$exitCode)
                throw "App exited before fixture: $exitCode"
            }
            $hostWindow = [RendererNative]::Host($proc.Id)
            if ($hostWindow -ne [IntPtr]::Zero) {
                if ([RendererNative]::WindowDesktop($hostWindow) -ne $DesktopName) { throw 'App window is not on the private desktop.' }
                if (![RendererNative]::IsWindowVisible($hostWindow)) { [void][RendererNative]::ShowWindow($hostWindow, 4) }
                $surfaceWindow = [RendererNative]::Surface($hostWindow)
                if ($OpenGLStartupFallback -and !$case.fallbackBanner) {
                    $bannerWait = $case.bannerWait
                    # The banner child exists, hidden, long before a banner
                    # is set. Read it only once it is shown, which is when an
                    # info countdown starts.
                    $banner=[RendererNative]::ChildOfId($hostWindow,1913)
                    if ($banner -ne [IntPtr]::Zero -and [RendererNative]::IsWindowVisible($banner)) {
                        if ($null -eq $bannerWait.shownMs) { $bannerWait.shownMs = $clock.ElapsedMilliseconds }
                        # WM_NULL comes back once the app's UI thread pumps
                        # messages, so a slow one means that thread (or the
                        # whole machine) was busy. The read starts after it.
                        $pingStart = $clock.ElapsedMilliseconds; $reply = [IntPtr]::Zero
                        [void][RendererNative]::SendMessageTimeoutW($hostWindow, 0, [IntPtr]::Zero, [IntPtr]::Zero, 0, 10000, [ref]$reply)
                        $readStart = $clock.ElapsedMilliseconds
                        $bannerWait.longestPingMs = [Math]::Max($bannerWait.longestPingMs, $readStart - $pingStart)
                        # A read that throws is recorded; the next poll
                        # reads again.
                        try { $name=[Windows.Automation.AutomationElement]::FromHandle($banner).Current.Name }
                        catch { $name = '<' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message + '>' }
                        $bannerWait.reads++; $bannerWait.lastName = $name; $bannerWait.lastReadMs = $clock.ElapsedMilliseconds
                        $bannerWait.longestReadMs = [Math]::Max($bannerWait.longestReadMs, $bannerWait.lastReadMs - $readStart)
                        # The banner was shown by shownMs, and the app read
                        # the name no earlier than the read's start, so
                        # foundReadStartMs - shownMs is a lower bound on how
                        # long the banner had to stay up. foundMs - shownMs
                        # is not one: the read's own time can be the client's.
                        if ($name -match 'OpenGL could not start.*Custom shaders and images are not available.*renderer') { $case.fallbackBanner=$name; $bannerWait.foundReadStartMs = $readStart; $bannerWait.foundMs = $bannerWait.lastReadMs }
                    }
                }
            }
            if ($surfaceWindow -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH) -and (!$OpenGLStartupFallback -or $case.fallbackBanner)) { break }
            Start-Sleep -Milliseconds 25
        }
        if ($OpenGLStartupFallback) { $case.bannerWait.waitMs = $clock.ElapsedMilliseconds }
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
        if ($OpenGLStartupFallback) {
            if ($case.initial.status.backend -ne 'd3d11' -or !$case.initial.status.opengl_unavailable -or $case.initial.status.opengl_context) { throw 'Unavailable OpenGL did not fall back, cache its failure, and release WGL.' }
            if ($case.fallbackBanner -notmatch 'OpenGL could not start.*Custom shaders and images are not available.*renderer') {
                $bannerWait = $case.bannerWait
                $shown = if ($null -eq $bannerWait.shownMs) { 'never shown' } else { "shown at $($bannerWait.shownMs) ms" }
                throw "OpenGL startup fallback banner is incomplete: after $($bannerWait.waitMs) ms the banner was $shown, and after $($bannerWait.reads) reads (longest WM_NULL wait $($bannerWait.longestPingMs) ms, longest read $($bannerWait.longestReadMs) ms) the last UIA name, read at $($bannerWait.lastReadMs) ms, was '$($bannerWait.lastName)'."
            }
            Remove-Item -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH
            if (![RendererNative]::Action($surfaceWindow,1)) { throw 'New tab action rejected.' }
            $tabClock=[Diagnostics.Stopwatch]::StartNew()
            while (!(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH) -and $tabClock.Elapsed.TotalSeconds -lt 40) { Start-Sleep -Milliseconds 25 }
            if (!(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH)) { throw 'Second-tab fixture did not become ready.' }
            Start-Sleep -Milliseconds 500
            if ([RendererNative]::Surfaces($hostWindow,$false).Count -ne 2) { throw 'Cached fallback did not open a second surface.' }
            $surfaceWindow = [RendererNative]::Surface($hostWindow)
            $case.cachedSurface = & $capture 'cached-surface'
            if ($case.cachedSurface.status.backend -ne 'd3d11' -or !$case.cachedSurface.status.opengl_unavailable -or $case.cachedSurface.status.opengl_context) { throw 'Cached surface did not start on D3D11 without a WGL context.' }
            # Final renderer state also matches a repeated failed GL attempt.
            # Count the per-attempt warning to prove the new tab skipped GL.
            $case.openglStartupAttempts = @(Select-String -LiteralPath (Join-Path $run 'stderr.txt') -Pattern 'OpenGL startup failed err=' -SimpleMatch).Count
            if ($case.openglStartupAttempts -ne 1) { throw "Expected one OpenGL startup attempt across both surfaces; observed $($case.openglStartupAttempts)." }
            $case.ledger = Get-Content -LiteralPath (Join-Path $bin 'startup-attempts.json') -Raw | ConvertFrom-Json
            if ($case.ledger.attempts[0].phase -ne 'ready' -or $case.ledger.attempts[0].opengl_unavailable_at_unix_ms) { throw 'Successful fallback was not an ordinary ready launch.' }
        }
        if ($RetryHardware) {
            if ($case.initial.status.backend -ne 'd3d11' -or !$case.initial.status.warp) { throw 'Hardware startup failure did not select WARP.' }
            if (![RendererNative]::LoseDevice($surfaceWindow)) { throw 'Device loss inside retry window rejected.' }
            Start-Sleep -Milliseconds 200
            $case.withinRetryWindow = & $capture 'within-retry-window'
            if ($case.withinRetryWindow.status.hardware_attempts -ne $case.initial.status.hardware_attempts) { throw 'Startup WARP retried hardware before its retry window.' }
            # Clear injected failures and expire only this test device's budget.
            if (![RendererNative]::RetryHardware($surfaceWindow)) { throw 'Hardware retry action rejected.' }
            Start-Sleep -Milliseconds 200
            $case.hardwareRetried = & $capture 'hardware-retried'
            if ($case.hardwareRetried.status.hardware_attempts -le $case.withinRetryWindow.status.hardware_attempts) { throw 'Startup WARP lost the hardware recovery preference.' }
            if ($RequireHardware -and $case.hardwareRetried.status.warp) { throw 'Available hardware was not selected after the retry window.' }
        }
        if ($Streaming) {
            Start-Sleep -Milliseconds 2200
            $case.streamStart = & $capture 'stream-start'
            Start-Sleep -Milliseconds 800
            $case.streamEnd = & $capture 'stream-end'
            $case.streamDiff = [RendererNative]::Diff($case.streamStart.path, $case.streamEnd.path, (Join-Path $run 'stream-diff.png')) | ConvertFrom-Json
            if ($case.streamEnd.status.frames - $case.streamStart.status.frames -lt 2 -or $case.streamDiff.different -lt 10) { throw 'Streaming output did not advance paced renderer frames and pixels.' }
        }
        if ($ReloadImages) {
            if ($case.streamEnd.status.image_count -gt 2) { throw 'Deleted Kitty image copies accumulate in the renderer.' }
            if (![RendererNative]::Action($surfaceWindow, 7)) { throw 'Kitty-only config reload action rejected.' }
            Start-Sleep -Milliseconds 600
            $case.imagesRetried = & $capture 'kitty-only-reload'
            if ($case.imagesRetried.status.fallback_attempts -le $case.streamEnd.status.fallback_attempts) { throw 'Reload did not retry the retained Kitty images.' }
            if ($case.imagesRetried.status.backend -ne 'd3d11' -or !$case.imagesRetried.status.fallback_blocked) { throw 'Rejected Kitty-only reload stopped using healthy D3D11.' }
            if ($case.imagesRetried.status.image_count -gt 2) { throw 'Deleted Kitty images accumulate after reload.' }
            $reply = [IntPtr]::Zero
            if ([RendererNative]::SendMessageTimeoutW($surfaceWindow, 0x8053, [IntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$reply) -eq [IntPtr]::Zero -or $reply -eq [IntPtr]::Zero) { throw 'Unavailable-device image cleanup injection rejected.' }
            $case.unavailableImages = @()
            foreach ($sample in 1..2) {
                Start-Sleep -Milliseconds 600
                Remove-Item -LiteralPath $environment.NOCTTY_RENDERER_STATUS_PATH -ErrorAction SilentlyContinue
                if ([RendererNative]::Capture($surfaceWindow, (Join-Path $run ('unavailable-' + $sample + '.png')))) { throw 'An unavailable device unexpectedly supplied GPU readback.' }
                $status = Get-Content -LiteralPath $environment.NOCTTY_RENDERER_STATUS_PATH -Raw | ConvertFrom-Json
                if (!$status.unavailable -or $status.image_count -gt 2) { throw 'Unavailable-device image cleanup retained deleted copies.' }
                $case.unavailableImages += $status
            }
            if ($case.unavailableImages[1].max_image_id -le $case.unavailableImages[0].max_image_id) { throw 'Kitty churn did not advance while the device was unavailable.' }
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
            if ($Backend -eq 'd3d11-warp' -and $case.recreated.status.hardware_attempts -ne 0) { throw 'Explicit WARP attempted hardware recovery.' }
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
            # A DPI round trip is exact only while the grid survives it. Scaling
            # up a host that cannot grow to fit its work area (a 1024x768 hosted
            # runner) shrinks the grid, so lines wrap and rows move into history,
            # and a Windows pty does not pull them back when the grid grows again
            # (PKG-14 turned resize_pull_scrollback off). Scaling down only grows
            # the grid, so it runs first and everywhere; scaling up runs only
            # where the scaled host fits the work area.
            $hostWidth = $rect.r - $rect.l
            $hostHeight = $rect.b - $rect.t
            $work = [RendererNative]::WorkArea($hostWindow)
            $scaleDown = [int][Math]::Floor($dpi * 3 / 4)
            $scaleUpFits = [Math]::Ceiling($hostWidth * 192 / $dpi) -le ($work.r - $work.l) -and [Math]::Ceiling($hostHeight * 192 / $dpi) -le ($work.b - $work.t)
            $scaleSteps = @(@{ dpi = $scaleDown; frame = 'scaledDown'; label = "scaled-down-${scaleDown}dpi"; restored = 'scale-down-restored'; keys = 'scaleDown' })
            if ($dpi -lt 192 -and $scaleUpFits) {
                $scaleSteps += @{ dpi = 192; frame = 'scaled'; label = 'scaled-192dpi'; restored = 'scale-restored'; keys = 'scale' }
            } else {
                $case.scaleUpSkipped = "a ${hostWidth}x${hostHeight} host at $dpi DPI would not fit the $($work.r - $work.l)x$($work.b - $work.t) work area at 192 DPI"
            }
            foreach ($step in $scaleSteps) {
                if (![RendererNative]::Scale($surfaceWindow, $step.dpi)) { throw 'DPI scale notification rejected.' }
                Start-Sleep -Milliseconds 400
                $scaled = & $capture $step.label
                $case[$step.frame] = $scaled
                if ($scaled.pixels.width -eq $case.initial.pixels.width -and $scaled.pixels.height -eq $case.initial.pixels.height -and (Get-FileHash -LiteralPath $scaled.path).Hash -eq (Get-FileHash -LiteralPath $case.initial.path).Hash) { throw 'DPI scale did not change the rendered frame.' }
                if (![RendererNative]::Scale($surfaceWindow, $dpi)) { throw 'DPI scale restore rejected.' }
                Start-Sleep -Milliseconds 400
                # Font-scale notifications can round the host by a few physical
                # pixels. Restore geometry before exact parity.
                [void][RendererNative]::Resize($hostWindow, $hostWidth, $hostHeight)
                Start-Sleep -Milliseconds 300
                $restored = & $capture $step.restored
                $case[$step.keys + 'Restored'] = $restored
                $diff = [RendererNative]::Diff($case.initial.path, $restored.path, (Join-Path $run ($step.restored + '-diff.png'))) | ConvertFrom-Json
                $case[$step.keys + 'Diff'] = $diff
                if ($diff.different -ne 0) { throw "DPI scale round trip through $($step.dpi) DPI changed pixels." }
            }
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
        if ($SplitDim) {
            # Both panes run the fixture; the split's new pane, on the right,
            # takes focus. The dim is the fill blended at 1 - opacity in sRGB
            # space, so each dimmed capture must equal its undimmed capture
            # blended that way, every pixel within two levels. The fixture
            # hides the cursor here: its shape follows keyboard focus.
            $fillHex = if ($SplitFill) { $SplitFill } else { '101010' } # the fixture's background
            $fill = @(0, 2, 4 | ForEach-Object { [Convert]::ToInt32($fillHex.Substring($_, 2), 16) })
            $alpha = [int][Math]::Round((1 - $SplitOpacity) * 255, [MidpointRounding]::AwayFromZero)
            $case.splitAlpha = $alpha
            $blend = {
                param($Dimmed, $Undimmed, $What, [int]$Alpha = $alpha)
                $check = [RendererNative]::BlendCheck($Dimmed.path, $Undimmed.path, $fill[0], $fill[1], $fill[2], $Alpha, 2) | ConvertFrom-Json
                if ($Alpha -gt 0 -and $check.changed -lt 1000) { throw "${What}: the dim changed only $($check.changed) pixels." }
                if ($check.mismatches -gt 0) { throw "${What}: $($check.mismatches) pixels in a $($check.bboxWidth)x$($check.bboxHeight) box are not the fill blended in sRGB space." }
                return $check
            }
            # The dim state reaches the renderer through its mailbox; poll
            # until a capture reports the expected state.
            $paneCapture = {
                param($Pane, $Name, [bool]$Dimmed, [switch]$NoReplay)
                $surfaceWindow = $Pane
                $clock = [Diagnostics.Stopwatch]::StartNew()
                while ($true) {
                    $frame = & $capture $Name -NoReplay:$NoReplay
                    if ([bool]$frame.status.split_dimmed -eq $Dimmed) { return $frame }
                    if ($clock.Elapsed.TotalSeconds -gt 5) { throw "$Name reports split_dimmed=$($frame.status.split_dimmed), expected $Dimmed." }
                    Start-Sleep -Milliseconds 100
                }
            }
            Remove-Item -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH
            if (![RendererNative]::Action($surfaceWindow, 2)) { throw 'Split action rejected.' }
            $splitClock = [Diagnostics.Stopwatch]::StartNew()
            while (!(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH) -and $splitClock.Elapsed.TotalSeconds -lt 40) { Start-Sleep -Milliseconds 25 }
            if (!(Test-Path -LiteralPath $environment.NOCTTY_RENDERER_READY_PATH)) { throw 'Split fixture did not become ready.' }
            # A held fixture starts its hold 1.5 s after it is ready.
            Start-Sleep -Milliseconds $(if ($HoldSync) { 2500 } else { 800 })
            $panes = @([RendererNative]::Surfaces($hostWindow, $true) | Sort-Object { [RendererNative]::Left($_) })
            if ($panes.Count -ne 2) { throw 'Expected two visible split panes.' }
            $left = $panes[0]; $right = $panes[1]
            if ($HoldSync) {
                # Under a synchronized-output hold only what the renderer
                # presents itself reaches a capture without a redraw: the dim
                # of the pane focus leaves must be presented for it. Run on
                # OpenGL: an occluded D3D11 pane (any hidden desktop) presents
                # through its paced retry whatever the hold.
                $case.heldFocused = & $paneCapture $right 'held-right-focused' $false -NoReplay
                if (![RendererNative]::Action($right, 8)) { throw 'goto_split rejected.' }
                $heldClock = [Diagnostics.Stopwatch]::StartNew()
                while ($true) {
                    Start-Sleep -Milliseconds 250
                    $case.heldUnfocused = & $paneCapture $right 'held-right-unfocused' $true -NoReplay
                    try { $case.heldBlend = & $blend $case.heldUnfocused $case.heldFocused 'Held right pane'; break }
                    catch { if ($heldClock.Elapsed.TotalSeconds -gt 5) { throw "The dim was not presented under a synchronized-output hold: $($_.Exception.Message)" } }
                }
                $case.heldWaitMs = $heldClock.ElapsedMilliseconds
            } else {
                $case.splitLeft = & $paneCapture $left 'split-left-dimmed' $true
                $case.splitRight = & $paneCapture $right 'split-right-focused' $false
                if (![RendererNative]::Action($right, 8)) { throw 'goto_split rejected.' }
                $case.gotoLeft = & $paneCapture $left 'goto-left-focused' $false
                $case.gotoRight = & $paneCapture $right 'goto-right-dimmed' $true
                $case.leftBlend = & $blend $case.splitLeft $case.gotoLeft 'Left pane'
                $case.rightBlend = & $blend $case.gotoRight $case.splitRight 'Right pane'
                # A zoomed pane shows alone, undimmed; leaving the zoom dims the
                # other pane again.
                if (![RendererNative]::Action($left, 9)) { throw 'Zoom rejected.' }
                Start-Sleep -Milliseconds 400
                if ([RendererNative]::Surfaces($hostWindow, $true).Count -ne 1) { throw 'Zoom left more than one pane visible.' }
                $case.zoomedLeft = & $paneCapture $left 'zoomed-left' $false
                if (![RendererNative]::Action($left, 9)) { throw 'Unzoom rejected.' }
                Start-Sleep -Milliseconds 400
                $case.unzoomedRight = & $paneCapture $right 'unzoomed-right' $true
                $case.unzoomedBlend = & $blend $case.unzoomedRight $case.splitRight 'Right pane after the zoom'
                if ($case.initial.status.backend -eq 'd3d11') {
                    if (![RendererNative]::LoseDevice($right)) { throw 'Device-loss action failed.' }
                    Start-Sleep -Milliseconds 200
                    $case.recreatedRight = & $paneCapture $right 'recreated-right' $true
                    $case.recreatedDiff = [RendererNative]::Diff($case.unzoomedRight.path, $case.recreatedRight.path, (Join-Path $run 'recreated-right-diff.png')) | ConvertFrom-Json
                    if ($case.recreatedDiff.different -ne 0) { throw 'Device recreation changed the dimmed pane.' }
                }
                if (!$NoShaderReload) {
                    # The dim lands after a custom shader; a D3D11 pane moves to
                    # OpenGL for it and keeps its dim.
                    $shaderPath = Join-Path $run 'split-dim.glsl'
                    Set-Content -LiteralPath $shaderPath -Value 'void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }'
                    Add-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value @(('custom-shader=' + $shaderPath), 'custom-shader-animation=false')
                    if (![RendererNative]::Action($left, 7)) { throw 'Config reload action rejected.' }
                    Start-Sleep -Milliseconds 1000
                    $case.shaderRight = & $paneCapture $right 'shader-right-dimmed' $true
                    if ($case.shaderRight.status.backend -ne 'opengl') { throw 'A custom shader did not move the pane to OpenGL.' }
                    $case.shaderBlend = & $blend $case.shaderRight $case.splitRight 'Right pane under a custom shader'
                }
                # Opacity 1 turns the dim off: the unfocused pane matches its
                # undimmed frame.
                Add-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value 'unfocused-split-opacity=1'
                if (![RendererNative]::Action($left, 7)) { throw 'Config reload action rejected.' }
                Start-Sleep -Milliseconds 1000
                $surfaceWindow = $right
                $case.opaqueRight = & $capture 'opaque-right'
                $case.opaqueBlend = & $blend $case.opaqueRight $case.splitRight 'Right pane at opacity 1' -Alpha 0
                # One pane left: nothing to dim.
                Add-Content -LiteralPath (Join-Path $bin 'config.ghostty') -Value ('unfocused-split-opacity=' + $SplitOpacity.ToString([Globalization.CultureInfo]::InvariantCulture))
                if (![RendererNative]::Action($left, 7)) { throw 'Config reload action rejected.' }
                Start-Sleep -Milliseconds 800
                if (![RendererNative]::Action($left, 6)) { throw 'Close split action rejected.' }
                Start-Sleep -Milliseconds 600
                if ([RendererNative]::Surfaces($hostWindow, $true).Count -ne 1) { throw 'Closing a split left more than one pane.' }
                $case.alone = & $paneCapture $right 'alone-right' $false
            }
        }
        if ($PreeditCaret) {
            # An IME composition goes in through the test-tools hook (0x8059),
            # past only the IMM read: fixture 1 is "zhongguo", 2 three CJK
            # characters, 3 208 letters, wider than the grid. Its caret is
            # the only thing in the cursor colour; the visible terminal
            # cursor, a block in that colour, gives the cell geometry.
            $tolerance = if ($case.initial.status.warp) { 4 } else { 0 }
            $box = { param($Frame) [RendererNative]::ColorBox($Frame.path, 0x13, 0xf7, 0xa9, $tolerance) | ConvertFrom-Json }
            $compose = {
                param([int]$Fixture, [int]$Cursor, [string]$Name)
                if (![RendererNative]::Preedit($surfaceWindow, $Fixture, $Cursor)) { throw "IME composition hook rejected fixture $Fixture, cursor $Cursor." }
                Start-Sleep -Milliseconds 300
                $frame = & $capture $Name
                $frame.caret = & $box $frame
                return $frame
            }
            $p = [ordered]@{ cursorCell = (& $box $case.initial) }
            $case.preedit = $p
            if ($HideCursor) {
                if ($p.cursorCell.count -ne 0) { throw 'The fixture did not hide its cursor.' }
            } elseif ($p.cursorCell.count -lt 20) { throw 'No terminal cursor in the cursor colour to measure the cell by.' }
            $p.caret5 = & $compose 1 5 'preedit-caret-5'
            $bar = $p.caret5.caret
            if ($bar.count -lt 4) { throw "No composition caret drawn at cursor 5 (count $($bar.count))." }
            if ($HideCursor) { $caseSuccessful = $true; return $case }
            $cell = $p.cursorCell
            $cw = $cell.x1 - $cell.x0 + 1
            $p.cellWidth = $cw
            # A bar, not a block: it straddles the left edge of the sixth
            # preedit cell and spans the cell's height.
            $edge = $cell.x0 + 5 * $cw
            if ($bar.x1 - $bar.x0 + 1 -gt [Math]::Max(1, [int]($cw / 2)) -or $bar.x0 -gt $edge -or $bar.x1 + 1 -lt $edge) { throw "Caret at cursor 5 is not a bar on the cell edge at x=${edge}: $($bar | ConvertTo-Json -Compress)." }
            if ([Math]::Abs($bar.y0 - $cell.y0) -gt 1 -or [Math]::Abs($bar.y1 - $cell.y1) -gt 1) { throw "Caret height differs from the cell: $($bar | ConvertTo-Json -Compress)." }
            $expectBar = {
                param($Frame, [int]$Cells, [string]$What)
                $c = $Frame.caret
                if ($c.count -ne $bar.count -or $c.x0 -ne $bar.x0 + $Cells * $cw -or $c.x1 -ne $bar.x1 + $Cells * $cw -or $c.y0 -ne $bar.y0 -or $c.y1 -ne $bar.y1) { throw "${What}: expected the cursor-5 bar moved $Cells cells, found $($c | ConvertTo-Json -Compress)." }
            }
            $p.caret4 = & $compose 1 4 'preedit-caret-4'; & $expectBar $p.caret4 -1 'Cursor 4'
            $p.caret0 = & $compose 1 0 'preedit-caret-0'; & $expectBar $p.caret0 -5 'Cursor 0'
            $p.caret8 = & $compose 1 8 'preedit-caret-end'; & $expectBar $p.caret8 3 'Cursor 8 (the end)'
            $p.noCaret = & $compose 1 -1 'preedit-no-caret'
            if ($p.noCaret.caret.count -ne 0) { throw 'A composition without a caret drew one.' }
            $p.wide = & $compose 2 1 'preedit-wide-caret-1'; & $expectBar $p.wide -3 'Wide caret 1'
            $p.longHead = & $compose 3 2 'preedit-long-caret-head'; & $expectBar $p.longHead -5 'Caret in the cut head'
            $p.longEnd = & $compose 3 208 'preedit-long-caret-end'
            $cells = ($p.longEnd.caret.x0 - $p.caret0.caret.x0) / $cw
            # The last column: its cell ends inside the right padding (at
            # least the left padding, cell.x0) and another cell would not.
            $right = $cell.x0 + ($cells + 1) * $cw
            $limit = $p.longEnd.caret.width - $cell.x0
            if ($p.longEnd.caret.count -ne $bar.count -or $cells -ne [Math]::Floor($cells) -or $right -gt $limit -or $right + $cw -le $limit) { throw "Caret at the end of an overlong composition is not on the last column: $($p.longEnd.caret | ConvertTo-Json -Compress)." }
            $p.longEndColumn = $cells
            # The conversion target clause (GCS_COMPATTR). Fixtures 4-7 are
            # six wide characters in three two-character clauses: no
            # attributes (4), the target on the second clause, preedit
            # cells 4-7 (5), on the third, cells 8-11 (6), and attributes
            # one short (7). With no caret, a target only changes the
            # underline: every pixel that differs from fixture 4 lies in the
            # target's cells, across their full width, below the middle of
            # the row.
            $ch = $cell.y1 - $cell.y0 + 1
            $diffBox = { param($A, $B) [RendererNative]::DiffBox($A.path, $B.path, 0) | ConvertFrom-Json }
            $expectUnderline = {
                param($Box, [int]$FirstCell, [int]$LastCell, [string]$What)
                if ($Box.count -lt $cw -or $Box.x0 -ne $cell.x0 + $FirstCell * $cw -or $Box.x1 -ne $cell.x0 + ($LastCell + 1) * $cw - 1 -or $Box.y0 -lt $cell.y0 + [int]($ch / 2) -or $Box.y1 -gt $cell.y1) { throw "${What}: expected an underline change across preedit cells $FirstCell-$LastCell, found $($Box | ConvertTo-Json -Compress)." }
            }
            $p.kana = & $compose 4 -1 'preedit-target-none'
            if ($p.kana.caret.count -ne 0) { throw 'A composition without a caret drew one.' }
            $p.target = & $compose 5 -1 'preedit-target-second-clause'
            $p.targetNext = & $compose 6 -1 'preedit-target-third-clause'
            $p.targetMalformed = & $compose 7 -1 'preedit-target-malformed'
            $p.targetBox = & $diffBox $p.kana $p.target; & $expectUnderline $p.targetBox 4 7 'Target on the second clause'
            $p.targetNextBox = & $diffBox $p.kana $p.targetNext; & $expectUnderline $p.targetNextBox 8 11 'Target on the third clause'
            # Moving the target moves only the underline.
            $p.targetMoveBox = & $diffBox $p.target $p.targetNext; & $expectUnderline $p.targetMoveBox 4 11 'Target moved to the next clause'
            if ($p.targetMoveBox.y0 -ne [Math]::Min($p.targetBox.y0, $p.targetNextBox.y0) -or $p.targetMoveBox.y1 -ne [Math]::Max($p.targetBox.y1, $p.targetNextBox.y1)) { throw "Moving the target changed more than the underline: $($p.targetMoveBox | ConvertTo-Json -Compress)." }
            $p.targetMalformedBox = & $diffBox $p.kana $p.targetMalformed
            if ($p.targetMalformedBox.count -ne 0) { throw "Attributes one short of the string changed the composition: $($p.targetMalformedBox | ConvertTo-Json -Compress)." }
            # The boxes say where the underline changed, not into what. Count
            # the underline in each frame: the rows on which every pixel of a
            # clause's four cells is lit. A clause is two glyphs, and no
            # stroke crosses the gap between them, so only an underline
            # lights a whole row. Each clause has one band, the target two.
            $bands = {
                param($Frame, [int]$Clause)
                $x0 = $cell.x0 + 4 * $Clause * $cw
                $lit = [RendererNative]::LitBands($Frame.path, $x0, $x0 + 4 * $cw - 1, $cell.y0, $cell.y1, 0x10, 0x10, 0x10, 48) | ConvertFrom-Json
                return (@($lit.bands) | ForEach-Object { '{0}-{1}' -f $_.y0, $_.y1 }) -join ','
            }
            $p.underlines = [ordered]@{}
            foreach ($name in @('kana', 'target', 'targetNext')) { $p.underlines[$name] = @(0, 1, 2 | ForEach-Object { & $bands $p[$name] $_ }) }
            $single = $p.underlines.kana[0]
            if ($single -eq '' -or $single.Contains(',') -or $p.underlines.kana[1] -ne $single -or $p.underlines.kana[2] -ne $single) { throw "Without attributes each clause should have the same single underline: $($p.underlines.kana -join ' | ')." }
            foreach ($t in @(@('target', 1), @('targetNext', 2))) {
                $u = $p.underlines[$t[0]]
                for ($k = 0; $k -lt 3; $k++) {
                    if ($k -ne $t[1]) {
                        if ($u[$k] -ne $single) { throw "$($t[0]): clause $k should keep the single underline $single, found '$($u[$k])'." }
                        continue
                    }
                    $double = @($u[$k].Split(',') | Where-Object { $_ -ne '' })
                    if ($double.Count -ne 2) { throw "$($t[0]): the target clause should have two underline bands, found '$($u[$k])'." }
                    foreach ($band in $double) { if ([int]$band.Split('-')[0] -lt $cell.y0 + [int]($ch / 2)) { throw "$($t[0]): an underline band above the middle of the row: '$($u[$k])'." } }
                }
            }
            # A caret before the target's first character keeps both: the
            # bar on the left edge of preedit cell 4, the double underline
            # under cells 4-7 except where the bar covers it.
            $p.kanaCaret = & $compose 4 2 'preedit-target-none-caret'; & $expectBar $p.kanaCaret -1 'Caret before the third character'
            $p.targetCaret = & $compose 5 2 'preedit-target-caret'; & $expectBar $p.targetCaret -1 'Caret with the target clause'
            $p.targetCaretBox = & $diffBox $p.kanaCaret $p.targetCaret
            $edge4 = $cell.x0 + 4 * $cw
            if ($p.targetCaretBox.count -lt $cw -or $p.targetCaretBox.x0 -lt $edge4 -or $p.targetCaretBox.x0 -gt [Math]::Max($edge4, $p.targetCaret.caret.x1 + 1) -or $p.targetCaretBox.x1 -ne $cell.x0 + 8 * $cw - 1 -or $p.targetCaretBox.y0 -ne $p.targetBox.y0 -or $p.targetCaretBox.y1 -ne $p.targetBox.y1) { throw "The target's underline changed with a caret in front of it: $($p.targetCaretBox | ConvertTo-Json -Compress)." }
            # Blink ticks with no output rebuild frames in which no row is
            # dirty, so the preedit's cells are kept from an earlier frame
            # and only a caret set on every rebuild is still drawn. The
            # fixture turns blinking on and then writes nothing; the
            # renderer counts the rebuilds that drew the caret with the
            # preedit row clean, and the captures ask for no redraw.
            $p.beforeTicks = & $compose 1 5 'preedit-before-ticks'; & $expectBar $p.beforeTicks 0 'Cursor 5 again'
            Set-Content -LiteralPath ($environment.NOCTTY_RENDERER_READY_PATH + '.blink') -Value 'blink'
            Start-Sleep -Milliseconds 500
            $p.blinkStart = & $capture 'preedit-blink-start' -NoReplay
            $p.blinkStart.caret = & $box $p.blinkStart
            & $expectBar $p.blinkStart 0 'After blinking was turned on'
            Start-Sleep -Milliseconds 2500
            $p.blinkEnd = & $capture 'preedit-blink-end' -NoReplay
            $p.blinkEnd.caret = & $box $p.blinkEnd
            $p.cleanRebuilds = $p.blinkEnd.status.preedit_caret_clean_rebuilds - $p.blinkStart.status.preedit_caret_clean_rebuilds
            if ($null -eq $p.blinkEnd.status.preedit_caret_clean_rebuilds -or $p.cleanRebuilds -lt 2) { throw "No blink frames rebuilt with the preedit row clean ($($p.cleanRebuilds) in 2.5 s)." }
            & $expectBar $p.blinkEnd 0 'After blink frames with no output'
            # Output on another row: the cursor moves to it and back.
            Set-Content -LiteralPath ($environment.NOCTTY_RENDERER_READY_PATH + '.tick') -Value 'tick'
            Start-Sleep -Milliseconds 1500
            $p.afterTicks = & $capture 'preedit-after-ticks' -NoReplay
            $p.afterTicks.caret = & $box $p.afterTicks
            $p.tickDiff = [RendererNative]::Diff($p.beforeTicks.path, $p.afterTicks.path, (Join-Path $run 'preedit-ticks-diff.png')) | ConvertFrom-Json
            if ($p.tickDiff.different -lt 10) { throw 'The fixture output on another row never reached a frame.' }
            & $expectBar $p.afterTicks 0 'After output on another row'
            $p.cleared = & $compose 0 0 'preedit-cleared'
            $c = $p.cleared.caret
            if ($c.count -ne $cell.count -or $c.x0 -ne $cell.x0 -or $c.y0 -ne $cell.y0) { throw "Clearing the composition did not bring the terminal cursor back: $($c | ConvertTo-Json -Compress)." }
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
        if ($nativeProcess.thread -ne [IntPtr]::Zero) { [void][RendererNative]::CloseHandle($nativeProcess.thread) }
        if ($nativeProcess.process -ne [IntPtr]::Zero) { [void][RendererNative]::CloseHandle($nativeProcess.process) }
        [void](Assert-Profile $before)
        if ($caseSuccessful -and $case.teardown -ne 'graceful') { throw 'Successful renderer case did not close gracefully.' }
    }
}
# The split-dim cases, shared by -SplitDimOnly and the full run. Like
# Invoke-Case, they add to the script's $result in place.
function Invoke-SplitDimCases {
    $splitGL = Invoke-Case 'split-dim-opengl' 'opengl' -SplitDim -SplitFill 'ffffff'; $result.runs += $splitGL
    $splitHardware = Invoke-Case 'split-dim-hardware' 'd3d11' -SplitDim -SplitFill 'ffffff'; $result.runs += $splitHardware
    $splitWarp = Invoke-Case 'split-dim-warp' 'd3d11-warp' -SplitDim -SplitFill 'ffffff' -NoShaderReload; $result.runs += $splitWarp
    $result.runs += Invoke-Case 'split-dim-default-fill' 'd3d11' -SplitDim -NoShaderReload
    # OpenGL only: D3D11 on a hidden desktop is always occluded, and its
    # paced present retry would carry the dim through a hold anyway.
    $result.runs += Invoke-Case 'split-dim-held-opengl' 'opengl' -SplitDim -HoldSync
    # Same dim on every backend: hardware exactly, WARP within its edge tolerance.
    foreach ($candidate in @($splitHardware, $splitWarp)) {
        $diff = [RendererNative]::Diff($splitGL.splitLeft.path, $candidate.splitLeft.path, (Join-Path $OutputDirectory ($candidate.label + '-dimmed-diff.png'))) | ConvertFrom-Json
        $result.comparisons += @{ label = $candidate.label + '-dimmed'; diff = $diff }
        if (!$candidate.initial.status.warp -and $diff.different -ne 0) { throw 'Hardware dims differently from OpenGL.' }
        if ($candidate.initial.status.warp -and ($diff.maxChannelDelta -gt 4 -or $diff.different -gt $diff.pixels * 0.01 -or $diff.over2 -gt $diff.pixels * 0.001)) { throw 'WARP dim exceeds documented edge quantization tolerance.' }
    }
}
# The IME composition caret and target clause on every backend: hardware
# matches OpenGL exactly, WARP within its edge tolerance; a hidden terminal
# cursor keeps the caret.
function Invoke-PreeditCaretCases {
    $preeditGL = Invoke-Case 'preedit-caret-opengl' 'opengl' -PreeditCaret; $result.runs += $preeditGL
    $preeditHardware = Invoke-Case 'preedit-caret-hardware' 'd3d11' -PreeditCaret; $result.runs += $preeditHardware
    $preeditWarp = Invoke-Case 'preedit-caret-warp' 'd3d11-warp' -PreeditCaret; $result.runs += $preeditWarp
    $hidden = Invoke-Case 'preedit-caret-hidden-cursor' 'opengl' -PreeditCaret -HideCursor; $result.runs += $hidden
    $a = $hidden.preedit.caret5.caret; $b = $preeditGL.preedit.caret5.caret
    if ($a.count -ne $b.count -or $a.x0 -ne $b.x0 -or $a.y0 -ne $b.y0) { throw 'The caret moved or vanished with the terminal cursor hidden.' }
    foreach ($candidate in @($preeditHardware, $preeditWarp)) {
        foreach ($frame in @('caret5', 'longEnd', 'target', 'targetCaret')) {
            $diff = [RendererNative]::Diff($preeditGL.preedit[$frame].path, $candidate.preedit[$frame].path, (Join-Path $OutputDirectory ($candidate.label + '-' + $frame + '-diff.png'))) | ConvertFrom-Json
            $result.comparisons += @{ label = $candidate.label + '-' + $frame; diff = $diff }
            if (!$candidate.initial.status.warp -and $diff.different -ne 0) { throw 'Hardware draws the composition differently from OpenGL.' }
            if ($candidate.initial.status.warp -and ($diff.maxChannelDelta -gt 4 -or $diff.different -gt $diff.pixels * 0.01 -or $diff.over2 -gt $diff.pixels * 0.001)) { throw 'WARP composition exceeds documented edge quantization tolerance.' }
        }
    }
}
try {
    # The split-dim cases include OpenGL runs, so they need an OpenGL 4.3 driver.
    if ($SplitDimOnly) { Invoke-SplitDimCases; $result.status = 'pass'; return }
    if ($PreeditCaretOnly) { Invoke-PreeditCaretCases; $result.status = 'pass'; return }
    # These cases need no GL driver and run on x64 and native ARM64 CI too.
    $startupFallback = Invoke-Case 'opengl-startup-fallback' 'opengl' @{NOCTTY_RENDERER_FAIL_OPENGL_VERSION='1'} -OpenGLStartupFallback
    $result.runs += $startupFallback
    if ($OpenGLStartupOnly) { $result.status = 'pass'; return }
    $blockedKitty = Invoke-Case 'kitty-without-gl' 'd3d11-warp' @{NOCTTY_RENDERER_FAIL_OPENGL='1';NOCTTY_RENDERER_TEST_KITTY='1';NOCTTY_RENDERER_TEST_IMAGE_CHURN='1'} @('power-saver-rendering=on') -Streaming -ReloadImages
    $result.runs += $blockedKitty
    if ($blockedKitty.initial.status.backend -ne 'd3d11' -or !$blockedKitty.initial.status.fallback_blocked) { throw 'Failed GL image fallback did not retain healthy D3D11.' }
    $blockedReload = Invoke-Case 'reload-without-gl' 'd3d11-warp' @{NOCTTY_RENDERER_FAIL_OPENGL='1'} @('power-saver-rendering=on') -Streaming -ReloadUnsupported
    $result.runs += $blockedReload
    $noHardware = Invoke-Case 'no-hardware' 'd3d11' @{ NOCTTY_RENDERER_FAIL_HARDWARE = '1' } -RetryHardware; $result.runs += $noHardware
    if ($WarpOnly) {
        $warp = Invoke-Case 'warp' 'd3d11-warp' -Lifecycle
        $result.runs += $warp
        if (!$warp.initial.status.warp) { throw 'Forced WARP selected hardware.' }
        $splitWarp = Invoke-Case 'split-dim-warp' 'd3d11-warp' -SplitDim -SplitFill 'ffffff' -NoShaderReload; $result.runs += $splitWarp
        $result.runs += Invoke-Case 'preedit-caret-warp' 'd3d11-warp' -PreeditCaret
        $result.status = 'pass'
        return
    }
    $gl = Invoke-Case 'opengl' 'opengl'; $result.runs += $gl
    $hardware = Invoke-Case 'hardware' 'd3d11' @{ NOCTTY_RENDERER_TEST_PRESENT_STATUS = '1' } -Lifecycle; $result.runs += $hardware
    if ($hardware.initial.status.last_present_status -ne 0x087A0007 -or $hardware.initial.status.composition_commits -lt 1 -or $hardware.initial.status.presents -lt 1) { throw 'Successful nonzero Present status did not commit and complete startup.' }
    if ($RequireHardware -and $hardware.initial.status.warp) { throw 'Hardware required, but adapter selection used WARP.' }
    $warp = Invoke-Case 'warp' 'd3d11-warp' -Lifecycle; $result.runs += $warp
    if (!$warp.initial.status.warp) { throw 'Forced WARP selected hardware.' }
    foreach ($candidate in @($hardware, $warp)) {
        $diff = [RendererNative]::Diff($gl.initial.path, $candidate.initial.path, (Join-Path $OutputDirectory ($candidate.label + '-diff.png'))) | ConvertFrom-Json
        $result.comparisons += @{ label = $candidate.label; diff = $diff }
        if (!$candidate.initial.status.warp -and $diff.different -ne 0) { throw 'Hardware differs from OpenGL.' }
        if ($candidate.initial.status.warp -and ($diff.maxChannelDelta -gt 4 -or $diff.different -gt $diff.pixels * 0.01 -or $diff.over2 -gt $diff.pixels * 0.001)) { throw 'WARP exceeds documented edge quantization tolerance.' }
    }
    Invoke-SplitDimCases
    Invoke-PreeditCaretCases
    $noDevice = Invoke-Case 'no-device' 'd3d11' @{ NOCTTY_RENDERER_FAIL_DEVICE = '1' }; $result.runs += $noDevice
    if ($noDevice.initial.status.backend -ne 'opengl') { throw 'Unavailable D3D11 did not select OpenGL.' }
    $noLibrary = Invoke-Case 'no-library' 'd3d11' @{ NOCTTY_RENDERER_FAIL_LIBRARY = '1' }; $result.runs += $noLibrary
    if ($noLibrary.initial.status.backend -ne 'opengl') { throw 'Unavailable D3D11 runtime did not select OpenGL.' }
    $resource = Invoke-Case 'resource-failure' 'd3d11' @{ NOCTTY_RENDERER_FAIL_RESOURCE = '1' } -RetryHardware; $result.runs += $resource
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

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
