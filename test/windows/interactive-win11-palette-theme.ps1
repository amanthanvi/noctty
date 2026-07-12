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
    Invoke-StatefulCommand $HostHwnd 1901
    $script:PaletteThemeHost = $HostHwnd
    Wait-InteractiveWin11Until -Deadline $Deadline -Description 'palette query edit' -Process $Process -Condition {
        @(Get-StatefulChildren $script:PaletteThemeHost | Where-Object Id -eq 2002).Count -gt 0
    }
    $edit = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2002 | Select-Object -First 1
    Set-StatefulEditText $HostHwnd $edit.Hwnd $Query
    return $edit.Hwnd
}

$originalHc = [WinghosttyStatefulNative+HIGHCONTRAST]::new(); $originalHc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($originalHc)
if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x42, $originalHc.cbSize, [ref]$originalHc, 0)) { throw 'SPI_GETHIGHCONTRAST failed.' }
$hcChanged = $false
$hcMutex = $null
$runs = [Collections.Generic.List[object]]::new()
$draculaRgb = [Convert]::ToInt32('282a36', 16)
$themeRgb = [Convert]::ToInt32('262427', 16)
try {
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
    Invoke-StatefulCommand $hostHwnd 2004
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'Dracula preview rollback' -Process $run.Process -Condition { ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF) -eq $draculaRgb }
    $edit = Open-ThemeQuery $hostHwnd '0x96f' $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description '0x96f commit preview' -Process $run.Process -Condition { ((Get-StatefulPixel $surface.Hwnd) -band 0xFFFFFF) -eq $themeRgb }
    $script:PaletteThemeHost = $hostHwnd
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme palette result list' -Process $run.Process -Condition {
        @(Get-StatefulChildren $script:PaletteThemeHost | Where-Object Id -eq 2006).Count -gt 0
    }
    Invoke-StatefulPaletteFirstRow $hostHwnd
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme config persistence' -Process $run.Process -Condition { (Get-Content $configPath -Raw) -match 'theme\s*=\s*0x96f' }
    Close-StatefulHost $hostHwnd $run $deadline

    if ($ExerciseHighContrast) {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        if (($originalHc.dwFlags -band 1) -eq 0) {
            $hcMutex = [Threading.Mutex]::new($false, 'Global\WinghosttyHighContrastHarness')
            if (-not $hcMutex.WaitOne([TimeSpan]::FromSeconds(10))) { throw 'Timed out waiting for the High Contrast harness mutex.' }
            $enabled = $originalHc; $enabled.dwFlags = $enabled.dwFlags -bor 1
            if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x43, $enabled.cbSize, [ref]$enabled, 2)) { throw 'SPI_SETHIGHCONTRAST enable failed.' }
            $hcChanged = $true
        }
        $hcRun = Start-StatefulApp $layout $exe $repoRoot 'palette-theme-high-contrast'; $runs.Add($hcRun)
        $hcHost = Wait-StatefulHost $hcRun $deadline
        $hcSurface = Wait-StatefulSurface $hcHost $hcRun $deadline; Show-StatefulHost $hcHost; $hcPixel = Get-StatefulPixel $hcSurface.Hwnd
        $hcEdit = Open-ThemeQuery $hcHost 'Dracula' $deadline $hcRun.Process
        Start-Sleep -Milliseconds 500
        if ((Get-StatefulPixel $hcSurface.Hwnd) -ne $hcPixel) { throw 'Theme preview changed terminal colors while High Contrast was active.' }
        if ((Get-Content $configPath -Raw) -notmatch 'theme\s*=\s*0x96f') { throw 'High Contrast preview mutated persisted theme.' }
        Invoke-StatefulCommand $hcHost 2004
        Close-StatefulHost $hcHost $hcRun $deadline
    }
}
finally {
    if ($hcChanged -and -not [WinghosttyStatefulNative]::SystemParametersInfo(0x43, $originalHc.cbSize, [ref]$originalHc, 2)) { Write-Error 'Failed to restore the original High Contrast setting.' }
    if ($null -ne $hcMutex) { try { $hcMutex.ReleaseMutex() } catch { }; $hcMutex.Dispose() }
    foreach ($run in $runs) { if (-not $run.Process.HasExited) { Stop-InteractiveWin11Process -Process $run.Process } }
}
Write-Host "interactive-win11 palette-theme validation: PASS (config=$configPath)"
