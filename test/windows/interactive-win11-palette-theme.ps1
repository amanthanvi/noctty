[CmdletBinding()]
param([switch]$Rebuild, [switch]$ResetState, [switch]$ExerciseHighContrast, [int]$TimeoutSeconds = 30)
$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
$launcher = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_PALETTE_THEME_BOOTSTRAPPED) {
    $args = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $args += '-Rebuild' }; if ($ResetState) { $args += '-ResetState' }
    if ($ExerciseHighContrast) { $args += '-ExerciseHighContrast' }
    $code = 0
    Invoke-InteractiveWin11Bootstrap -RepoRoot $repoRoot -LauncherPath $launcher -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_PALETTE_THEME_BOOTSTRAPPED' -ArgumentList $args -ExitCode ([ref]$code)
    exit $code
}
. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')
$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'palette-theme' -ResetState:$ResetState -IncludeResourcesDir
$layout = $harness.Layout
$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
if ((Get-InteractiveWin11LaunchAction -ExePath $exe -Rebuild:$Rebuild -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot)) -eq 'build') { Invoke-InteractiveWin11Build -RepoRoot $repoRoot }
Assert-InteractiveWin11ExeExists -ExePath $exe
$configDir = Join-Path $layout.LocalAppData 'winghostty'; New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$configPath = Join-Path $configDir 'config.ghostty'
[IO.File]::WriteAllText($configPath, "theme = Dracula`r`nwindow-save-state = never`r`n", [Text.UTF8Encoding]::new($false))

function Open-ThemeQuery([IntPtr]$HostHwnd, [string]$Query, [DateTime]$Deadline, $Process) {
    Invoke-StatefulCommand $HostHwnd 1901 $Deadline $Process
    $script:PaletteThemeHost = $HostHwnd
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'palette query edit' -Process $Process -Condition {
        @(Get-StatefulChildren $script:PaletteThemeHost | Where-Object Id -eq 2002).Count -gt 0
    }
    $edit = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2002 | Select-Object -First 1
    Set-StatefulEditText $HostHwnd $edit.Hwnd $Query $Deadline $Process
    return $edit.Hwnd
}

$originalHc = $null
$hcChanged = $false
$hcMutex = $null
$hcMutexAcquired = $false
$hcRecoveryPath = $null
$primaryError = $null
$runs = [Collections.Generic.List[object]]::new()
$draculaRgb = [Convert]::ToInt32('282a36', 16)
$themeRgb = [Convert]::ToInt32('262427', 16)
try {
    if ($ExerciseHighContrast) {
        $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $hcMutex = [Threading.Mutex]::new($false, "Global\WinghosttyHighContrastHarness-$currentUserSid")
        $hostLocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($hostLocalAppData)) { throw 'Unable to resolve the host LocalAppData directory for High Contrast recovery.' }
        $hcRecoveryPath = Join-Path $hostLocalAppData 'winghostty\harness-state\high-contrast-restore-off.marker'
        try {
            $hcMutexAcquired = $hcMutex.WaitOne([TimeSpan]::FromSeconds(10))
        }
        catch [Threading.AbandonedMutexException] {
            $hcMutexAcquired = $true
            Write-Warning 'Recovered ownership of an abandoned High Contrast harness mutex.'
        }
        if (-not $hcMutexAcquired) { throw 'Timed out waiting for the High Contrast harness mutex.' }
        if (Test-Path -LiteralPath $hcRecoveryPath) {
            $recoveryHc = [WinghosttyStatefulNative+HIGHCONTRAST]::new(); $recoveryHc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($recoveryHc)
            if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x42, $recoveryHc.cbSize, [ref]$recoveryHc, 0)) { throw 'SPI_GETHIGHCONTRAST recovery failed.' }
            $recoveryHc.dwFlags = $recoveryHc.dwFlags -band (-bnot 1)
            if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x43, $recoveryHc.cbSize, [ref]$recoveryHc, 2)) { throw 'SPI_SETHIGHCONTRAST recovery failed.' }
            Remove-Item -LiteralPath $hcRecoveryPath -Force
            Write-Warning 'Restored High Contrast state left behind by an interrupted harness run.'
        }
        $originalHc = [WinghosttyStatefulNative+HIGHCONTRAST]::new(); $originalHc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($originalHc)
        if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x42, $originalHc.cbSize, [ref]$originalHc, 0)) { throw 'SPI_GETHIGHCONTRAST failed.' }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $run = Start-StatefulApp $layout $exe $repoRoot 'palette-theme-normal'; $runs.Add($run)
    $hostHwnd = Wait-StatefulHost $run $deadline
    $surface = Wait-StatefulSurface $hostHwnd $run $deadline
    Show-StatefulHost $hostHwnd
    Write-Host ('theme initial framebuffer rgb={0:x6}' -f ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF))
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'Dracula background render' -Process $run.Process -Condition { ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF) -eq $draculaRgb }
    $edit = Open-ThemeQuery $hostHwnd '0x96f' $deadline $run.Process
    Start-Sleep -Milliseconds 750
    Write-Host ('theme preview framebuffer rgb={0:x6}' -f ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF))
    Wait-InteractiveWin11Until -Deadline $deadline -Description '0x96f preview render' -Process $run.Process -Condition { ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF) -eq $themeRgb }
    if ((Get-Content $configPath -Raw) -notmatch 'theme\s*=\s*Dracula') { throw 'Preview mutated config before commit.' }
    Invoke-StatefulCommand $hostHwnd 2004 $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'Dracula preview rollback' -Process $run.Process -Condition { ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF) -eq $draculaRgb }
    $edit = Open-ThemeQuery $hostHwnd '0x96f' $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description '0x96f commit preview' -Process $run.Process -Condition { ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF) -eq $themeRgb }
    $script:PaletteThemeHost = $hostHwnd
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme palette result list' -Process $run.Process -Condition {
        @(Get-StatefulChildren $script:PaletteThemeHost | Where-Object Id -eq 2006).Count -gt 0
    }
    Invoke-StatefulPaletteFirstRow $hostHwnd $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme config persistence' -Process $run.Process -Condition { (Get-Content $configPath -Raw) -match 'theme\s*=\s*0x96f' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Close-StatefulHost $hostHwnd $run $deadline

    if ($ExerciseHighContrast) {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        if (($originalHc.dwFlags -band 1) -eq 0) {
            $enabled = $originalHc; $enabled.dwFlags = $enabled.dwFlags -bor 1
            [IO.Directory]::CreateDirectory((Split-Path -Parent $hcRecoveryPath)) | Out-Null
            [IO.File]::WriteAllText($hcRecoveryPath, 'restore-high-contrast-off', [Text.UTF8Encoding]::new($false))
            $hcChanged = $true
            if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x43, $enabled.cbSize, [ref]$enabled, 2)) { throw 'SPI_SETHIGHCONTRAST enable failed.' }
        }
        $hcRun = Start-StatefulApp $layout $exe $repoRoot 'palette-theme-high-contrast'; $runs.Add($hcRun)
        $hcHost = Wait-StatefulHost $hcRun $deadline
        $hcSurface = Wait-StatefulSurface $hcHost $hcRun $deadline; Show-StatefulHost $hcHost; $hcPixel = Get-StatefulPixel $hcSurface.Hwnd
        $hcEdit = Open-ThemeQuery $hcHost 'Dracula' $deadline $hcRun.Process
        Start-Sleep -Milliseconds 500
        if ((Get-StatefulPixel $hcSurface.Hwnd) -ne $hcPixel) { throw 'Theme preview changed terminal colors while High Contrast was active.' }
        if ((Get-Content $configPath -Raw) -notmatch 'theme\s*=\s*0x96f') { throw 'High Contrast preview mutated persisted theme.' }
        Invoke-StatefulCommand $hcHost 2004 $deadline $hcRun.Process
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        Close-StatefulHost $hcHost $hcRun $deadline
    }
}
catch {
    $primaryError = $_
}
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $hcRestored = $false
    if ($hcChanged) {
        try {
            if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x43, $originalHc.cbSize, [ref]$originalHc, 2)) {
                [void]$cleanupErrors.Add('Failed to restore the original High Contrast setting.')
            }
            else {
                $hcRestored = $true
            }
        }
        catch {
            [void]$cleanupErrors.Add("High Contrast restoration threw: $($_.Exception.Message)")
        }
    }
    if ($hcRestored) {
        try { Remove-Item -LiteralPath $hcRecoveryPath -Force -ErrorAction Stop } catch { [void]$cleanupErrors.Add("High Contrast recovery marker cleanup failed: $($_.Exception.Message)") }
    }
    if ($null -ne $hcMutex) {
        if ($hcMutexAcquired) {
            try { $hcMutex.ReleaseMutex() } catch { [void]$cleanupErrors.Add("High Contrast mutex release failed: $($_.Exception.Message)") }
        }
        try { $hcMutex.Dispose() } catch { [void]$cleanupErrors.Add("High Contrast mutex disposal failed: $($_.Exception.Message)") }
    }
    foreach ($run in $runs) {
        try {
            if (-not $run.Process.HasExited) { Stop-InteractiveWin11Process -Process $run.Process }
        }
        catch {
            [void]$cleanupErrors.Add("winghostty process cleanup failed: $($_.Exception.Message)")
        }
    }
    if ($cleanupErrors.Count -gt 0) {
        $cleanupMessage = "Palette/theme cleanup failed: $($cleanupErrors -join '; ')"
        if ($null -ne $primaryError) {
            $primaryError.Exception.Data['WinghosttyCleanupErrors'] = $cleanupMessage
            Write-Error $cleanupMessage -ErrorAction Continue
        }
        else {
            throw $cleanupMessage
        }
    }
}
if ($null -ne $primaryError) { throw $primaryError }
Write-Host "interactive-win11 palette-theme validation: PASS (config=$configPath)"
