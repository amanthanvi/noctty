[CmdletBinding()]
param([switch]$Rebuild, [switch]$ResetState, [int]$TimeoutSeconds = 30)
$ErrorActionPreference = 'Stop'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
$launcher = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_PALETTE_THEME_BOOTSTRAPPED) {
    $args = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $args += '-Rebuild' }; if ($ResetState) { $args += '-ResetState' }
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
    Send-StatefulText $edit.Hwnd $Query
    return $edit.Hwnd
}

$originalHc = [WinghosttyStatefulNative+HIGHCONTRAST]::new(); $originalHc.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($originalHc)
if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x42, $originalHc.cbSize, [ref]$originalHc, 0)) { throw 'SPI_GETHIGHCONTRAST failed.' }
$hcChanged = $false
$runs = [Collections.Generic.List[object]]::new()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $run = Start-StatefulApp $layout $exe $repoRoot 'palette-theme-normal'; $runs.Add($run)
    $hostHwnd = Wait-StatefulHost $run $deadline
    $surface = Get-StatefulSurface $hostHwnd; if ($null -eq $surface) { throw 'No terminal surface HWND.' }
    $originalPixel = Get-StatefulPixel $surface.Hwnd
    $edit = Open-ThemeQuery $hostHwnd '0x96f' $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme preview pixel change' -Process $run.Process -Condition { (Get-StatefulPixel $surface.Hwnd) -ne $originalPixel }
    if ((Get-Content $configPath -Raw) -notmatch 'theme\s*=\s*Dracula') { throw 'Preview mutated config before commit.' }
    Send-StatefulKey $edit 0x1B
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme preview rollback' -Process $run.Process -Condition { (Get-StatefulPixel $surface.Hwnd) -eq $originalPixel }
    $edit = Open-ThemeQuery $hostHwnd '0x96f' $deadline $run.Process
    Invoke-StatefulCommand $hostHwnd 2003
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'theme config persistence' -Process $run.Process -Condition { (Get-Content $configPath -Raw) -match 'theme\s*=\s*0x96f' }
    Close-StatefulHost $hostHwnd $run $deadline

    $enabled = $originalHc; $enabled.dwFlags = $enabled.dwFlags -bor 1
    if (-not [WinghosttyStatefulNative]::SystemParametersInfo(0x43, $enabled.cbSize, [ref]$enabled, 2)) { throw 'SPI_SETHIGHCONTRAST enable failed.' }
    $hcChanged = $true
    $hcRun = Start-StatefulApp $layout $exe $repoRoot 'palette-theme-high-contrast'; $runs.Add($hcRun)
    $hcHost = Wait-StatefulHost $hcRun $deadline
    $hcSurface = Get-StatefulSurface $hcHost; $hcPixel = Get-StatefulPixel $hcSurface.Hwnd
    $hcEdit = Open-ThemeQuery $hcHost 'Dracula' $deadline $hcRun.Process
    Start-Sleep -Milliseconds 500
    if ((Get-StatefulPixel $hcSurface.Hwnd) -ne $hcPixel) { throw 'Theme preview changed terminal colors while High Contrast was active.' }
    if ((Get-Content $configPath -Raw) -notmatch 'theme\s*=\s*0x96f') { throw 'High Contrast preview mutated persisted theme.' }
    Send-StatefulKey $hcEdit 0x1B
    Close-StatefulHost $hcHost $hcRun $deadline
}
finally {
    if ($hcChanged) { [void][WinghosttyStatefulNative]::SystemParametersInfo(0x43, $originalHc.cbSize, [ref]$originalHc, 2) }
    foreach ($run in $runs) { if (-not $run.Process.HasExited) { Stop-InteractiveWin11Process -Process $run.Process } }
}
Write-Host "interactive-win11 palette-theme validation: PASS (config=$configPath)"
