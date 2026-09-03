[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$ResetState,
    [ValidatePattern('^[0-9A-Fa-f]{6}$')] [string]$ExpectedThemeBackground = '132738',
    [ValidateRange(96, 480)] [int]$MinimumDpi = 96,
    [ValidateRange(10, 300)] [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$launcher = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
if (-not $env:NOCTTY_INTERACTIVE_WIN11_ISSUE149_COLORS_BOOTSTRAPPED) {
    $args = @(
        '-TimeoutSeconds', $TimeoutSeconds.ToString(),
        '-ExpectedThemeBackground', $ExpectedThemeBackground,
        '-MinimumDpi', $MinimumDpi.ToString()
    )
    if ($Rebuild) { $args += '-Rebuild' }
    if ($ResetState) { $args += '-ResetState' }
    $code = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcher `
        -EnvironmentVariable 'NOCTTY_INTERACTIVE_WIN11_ISSUE149_COLORS_BOOTSTRAPPED' `
        -ArgumentList $args `
        -ExitCode ([ref]$code)
    exit $code
}

. (Join-Path $PSScriptRoot 'interactive-win11-stateful-lib.ps1')
Add-Type -AssemblyName System.Drawing
if (-not ('NocttyIssue149Framebuffer' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public static class NocttyIssue149Framebuffer {
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }

    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("gdi32.dll", SetLastError=true)]
    private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll", SetLastError=true)]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);
    [DllImport("gdi32.dll", SetLastError=true)]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr value);
    [DllImport("gdi32.dll", SetLastError=true)]
    private static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll", SetLastError=true)]
    private static extern bool DeleteDC(IntPtr hdc);

    public static Bitmap CaptureClient(IntPtr hwnd) {
        RECT rect;
        if (!GetClientRect(hwnd, out rect)) throw new Win32Exception();
        int width = rect.right - rect.left;
        int height = rect.bottom - rect.top;
        if (width <= 0 || height <= 0) throw new InvalidOperationException("Surface client area is empty.");

        IntPtr source = GetDC(hwnd);
        if (source == IntPtr.Zero) throw new Win32Exception();
        IntPtr target = IntPtr.Zero;
        IntPtr bitmap = IntPtr.Zero;
        IntPtr previous = IntPtr.Zero;
        try {
            target = CreateCompatibleDC(source);
            if (target == IntPtr.Zero) throw new Win32Exception();
            bitmap = CreateCompatibleBitmap(source, width, height);
            if (bitmap == IntPtr.Zero) throw new Win32Exception();
            previous = SelectObject(target, bitmap);
            if (previous == IntPtr.Zero || previous == new IntPtr(-1)) throw new Win32Exception();

            // PW_CLIENTONLY | PW_RENDERFULLCONTENT reads the window-owned
            // presented client framebuffer without desktop/screen capture.
            if (!PrintWindow(hwnd, target, 0x00000003)) throw new Win32Exception();
            using (Image image = Image.FromHbitmap(bitmap)) {
                return new Bitmap(image);
            }
        }
        finally {
            if (target != IntPtr.Zero && previous != IntPtr.Zero) SelectObject(target, previous);
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
            if (target != IntPtr.Zero) DeleteDC(target);
            ReleaseDC(hwnd, source);
        }
    }

    public static Task<Bitmap> CaptureClientAsync(IntPtr hwnd) {
        return Task.Run(() => CaptureClient(hwnd));
    }
}
'@
}

function Convert-Issue149Rgb([string]$Hex) {
    return [Convert]::ToInt32($Hex, 16)
}

function Write-Issue149Config(
    [string]$Path,
    [string]$PayloadPath,
    [string]$MarkerDirectory,
    [ValidateSet('default', 'theme', 'explicit')] [string]$Case
) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("command = direct:pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PayloadPath -MarkerDirectory $MarkerDirectory")
    $lines.Add('shell-integration = none')
    $lines.Add('window-save-state = never')
    $lines.Add('confirm-close-surface = false')
    $lines.Add('font-size = 12')
    $lines.Add('window-width = 90')
    $lines.Add('window-height = 24')
    $lines.Add('background-opacity = 1')
    if ($Case -ne 'default') { $lines.Add('theme = Cobalt2') }
    if ($Case -eq 'explicit') {
        # These follow the theme on purpose: explicit values must win.
        $lines.Add('background = #102030')
        $lines.Add('foreground = #405060')
        $lines.Add('palette = 1=#708090')
    }
    [IO.File]::WriteAllText(
        $Path,
        (($lines -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-Issue149VisibleSurfaces([IntPtr]$HostHwnd) {
    return @(Get-StatefulChildren $HostHwnd | Where-Object Class -eq 'noctty.win32')
}

function Assert-Issue149PublicConfig(
    [string]$CliPath,
    [string]$Phase,
    [string]$Background,
    [string]$Foreground,
    [string]$Palette1,
    [string]$RepoRoot
) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $CliPath
    $start.Arguments = '+show-config --changes-only=false --no-pager'
    $start.WorkingDirectory = $RepoRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "$Phase +show-config failed to start." }
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "$Phase +show-config timed out."
        }
        if ($process.ExitCode -ne 0) {
            throw "$Phase +show-config exited $($process.ExitCode): $($stderr.Result)"
        }
        $text = $stdout.Result
    }
    finally {
        $process.Dispose()
    }

    foreach ($entry in ([ordered]@{
            background = "background = #$Background"
            foreground = "foreground = #$Foreground"
            palette1 = "palette = 1=#$Palette1"
        }).GetEnumerator()) {
        if ($text -notmatch "(?m)^$([regex]::Escape($entry.Value))`r?$") {
            throw "$Phase public config did not contain $($entry.Key) '$($entry.Value)'."
        }
    }
    Write-Host "$Phase public config: background=$Background foreground=$Foreground palette1=$Palette1"
}

function Invoke-Issue149PaletteAction(
    [IntPtr]$HostHwnd,
    [string]$Action,
    [DateTime]$Deadline,
    [Parameter(Mandatory)] [Diagnostics.Process]$Process
) {
    Invoke-StatefulPostedCommand $HostHwnd 1901 $Deadline $Process
    $script:Issue149Host = $HostHwnd
    Wait-InteractiveWin11Until -Deadline $Deadline -Description "palette edit for $Action" -Process $Process -Condition {
        @(Get-StatefulChildren $script:Issue149Host | Where-Object Id -eq 2002).Count -eq 1
    }
    $edit = Get-StatefulChildren $HostHwnd | Where-Object Id -eq 2002 | Select-Object -First 1
    Set-StatefulEditText $HostHwnd $edit.Hwnd $Action $Deadline $Process
    Wait-InteractiveWin11Until -Deadline $Deadline -Description "palette result for $Action" -Process $Process -Condition {
        @(Get-StatefulChildren $script:Issue149Host | Where-Object Id -eq 2006).Count -eq 1
    }
    Invoke-StatefulPaletteFirstRow $HostHwnd $Deadline $Process
    Wait-InteractiveWin11Until -Deadline $Deadline -Description "palette dismissal for $Action" -Process $Process -Condition {
        @(Get-StatefulChildren $script:Issue149Host | Where-Object { $_.Id -ge 2001 -and $_.Id -le 2006 }).Count -eq 0
    }
}

function Assert-Issue149FrameColors(
    [IntPtr]$SurfaceHwnd,
    [string]$Name,
    [string]$Background,
    [string]$Foreground,
    [string]$Palette1,
    [string]$EvidenceDirectory
) {
    $capture = [NocttyIssue149Framebuffer]::CaptureClientAsync($SurfaceHwnd)
    if (-not $capture.Wait(10000)) { throw "$Name client-frame readback timed out." }
    $bitmap = $capture.GetAwaiter().GetResult()
    try {
        $evidencePath = Join-Path $EvidenceDirectory "$Name.png"
        $bitmap.Save($evidencePath, [Drawing.Imaging.ImageFormat]::Png)
        $expected = [ordered]@{
            background = Convert-Issue149Rgb $Background
            foreground = Convert-Issue149Rgb $Foreground
            palette1 = Convert-Issue149Rgb $Palette1
        }
        $counts = [ordered]@{ background = 0; foreground = 0; palette1 = 0 }
        $sampleCount = 0
        for ($y = 2; $y -lt ($bitmap.Height - 2); $y += 2) {
            for ($x = 2; $x -lt ($bitmap.Width - 2); $x += 2) {
                $sampleCount++
                $rgb = $bitmap.GetPixel($x, $y).ToArgb() -band 0xFFFFFF
                foreach ($key in $expected.Keys) {
                    if ($rgb -eq $expected[$key]) { $counts[$key]++ }
                }
            }
        }
        $minimum = [Math]::Max(16, [int]($sampleCount * 0.01))
        foreach ($key in $expected.Keys) {
            if ($counts[$key] -lt $minimum) {
                throw ('{0} framebuffer did not contain configured {1} #{2}: count={3}, minimum={4}, samples={5}' -f `
                    $Name, $key, $expected[$key].ToString('x6'), $counts[$key], $minimum, $sampleCount)
            }
        }
        $dpi = [NocttyIssue149Framebuffer]::GetDpiForWindow($SurfaceHwnd)
        if ($dpi -lt $MinimumDpi) { throw "$Name rendered at $dpi DPI; required at least $MinimumDpi DPI." }
        Write-Host ('{0}: dpi={1} client={2}x{3} samples={4} background={5} foreground={6} palette1={7}' -f `
            $Name, $dpi, $bitmap.Width, $bitmap.Height, $sampleCount,
            $counts.background, $counts.foreground, $counts.palette1)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Assert-Issue149VisibleSurfaceColors(
    [IntPtr]$HostHwnd,
    [string]$Phase,
    [string]$Background,
    [string]$Foreground,
    [string]$Palette1,
    [string]$EvidenceDirectory
) {
    $surfaces = @(Get-Issue149VisibleSurfaces $HostHwnd)
    if ($surfaces.Count -eq 0) { throw "$Phase has no visible terminal surface." }
    for ($index = 0; $index -lt $surfaces.Count; $index++) {
        Assert-Issue149FrameColors `
            -SurfaceHwnd $surfaces[$index].Hwnd `
            -Name "$Phase-surface-$index" `
            -Background $Background `
            -Foreground $Foreground `
            -Palette1 $Palette1 `
            -EvidenceDirectory $EvidenceDirectory
    }
}

$harness = Initialize-InteractiveWin11Sandbox `
    -RepoRoot $repoRoot `
    -SandboxName 'issue149-colors' `
    -ResetState:$ResetState `
    -IncludeResourcesDir
$layout = $harness.Layout
$exe = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$cli = Join-Path (Split-Path -Parent $exe) 'noctty.com'
if ((Get-InteractiveWin11LaunchAction `
        -ExePath $exe `
        -Rebuild:$Rebuild `
        -BuildInputs (Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot)) -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}
Assert-InteractiveWin11ExeExists -ExePath $exe
if (-not [IO.File]::Exists($cli)) { throw "Missing noctty.com at $cli" }

$configDirectory = Join-Path $layout.LocalAppData 'noctty'
$markerDirectory = Join-Path $layout.SandboxRoot 'issue149-markers'
$evidenceDirectory = Join-Path $layout.Logs 'issue149-framebuffers'
[IO.Directory]::CreateDirectory($configDirectory) | Out-Null
[IO.Directory]::CreateDirectory($markerDirectory) | Out-Null
[IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null
$configPath = Join-Path $configDirectory 'config.ghostty'
$payloadPath = Join-Path $PSScriptRoot 'issue149-color-payload.ps1'
Write-Issue149Config $configPath $payloadPath $markerDirectory 'default'
Assert-Issue149PublicConfig $cli 'default' '282c34' 'ffffff' 'cc6666' $repoRoot

$run = $null
$primaryError = $null
try {
    $run = Start-StatefulApp $layout $exe $repoRoot 'issue149-colors'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $hostHwnd = Wait-StatefulHost $run $deadline
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'initial issue149 payload marker' -Process $run.Process -Condition {
        @(Get-ChildItem -LiteralPath $markerDirectory -Filter '*.ready' -File -ErrorAction SilentlyContinue).Count -eq 1
    }
    $surface = Wait-StatefulSurface $hostHwnd $run $deadline
    $null = Invoke-InteractiveWin11Message -Hwnd $surface.Hwnd -Message 0 -Deadline $deadline -Description 'initial issue149 presentation barrier' -Process $run.Process
    Assert-Issue149VisibleSurfaceColors $hostHwnd 'default' '282c34' 'ffffff' 'cc6666' $evidenceDirectory

    Write-Issue149Config $configPath $payloadPath $markerDirectory 'theme'
    Assert-Issue149PublicConfig $cli 'theme' '132738' 'ffffff' 'ff0000' $repoRoot
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-Issue149PaletteAction $hostHwnd 'reload_config' $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'Cobalt2 framebuffer reload' -Process $run.Process -Condition {
        try {
            Assert-Issue149VisibleSurfaceColors $hostHwnd 'theme-probe' $ExpectedThemeBackground 'ffffff' 'ff0000' $evidenceDirectory
            return $true
        }
        catch { return $false }
    }
    Assert-Issue149VisibleSurfaceColors $hostHwnd 'theme' $ExpectedThemeBackground 'ffffff' 'ff0000' $evidenceDirectory

    Write-Issue149Config $configPath $payloadPath $markerDirectory 'explicit'
    Assert-Issue149PublicConfig $cli 'explicit' '102030' '405060' '708090' $repoRoot
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-Issue149PaletteAction $hostHwnd 'reload_config' $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'explicit color framebuffer reload' -Process $run.Process -Condition {
        try {
            Assert-Issue149VisibleSurfaceColors $hostHwnd 'explicit-probe' '102030' '405060' '708090' $evidenceDirectory
            return $true
        }
        catch { return $false }
    }
    Assert-Issue149VisibleSurfaceColors $hostHwnd 'explicit' '102030' '405060' '708090' $evidenceDirectory

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-StatefulPostedCommand $hostHwnd 1904 $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'second tab payload marker' -Process $run.Process -Condition {
        (Get-StatefulTabCount $hostHwnd) -eq 2 -and
        @(Get-ChildItem -LiteralPath $markerDirectory -Filter '*.ready' -File -ErrorAction SilentlyContinue).Count -eq 2
    }
    Assert-Issue149VisibleSurfaceColors $hostHwnd 'new-tab' '102030' '405060' '708090' $evidenceDirectory

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Invoke-Issue149PaletteAction $hostHwnd 'new_split:right' $deadline $run.Process
    Wait-InteractiveWin11Until -Deadline $deadline -Description 'split payload markers and surfaces' -Process $run.Process -Condition {
        @(Get-Issue149VisibleSurfaces $hostHwnd).Count -eq 2 -and
        @(Get-ChildItem -LiteralPath $markerDirectory -Filter '*.ready' -File -ErrorAction SilentlyContinue).Count -eq 3
    }
    Assert-Issue149VisibleSurfaceColors $hostHwnd 'new-split' '102030' '405060' '708090' $evidenceDirectory

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    Close-StatefulHost $hostHwnd $run $deadline
}
catch {
    $primaryError = $_
}
finally {
    if ($null -ne $run) {
        $run.Process.Refresh()
        if (-not $run.Process.HasExited) {
            try { Stop-InteractiveWin11Process -Process $run.Process -Contained }
            catch {
                if ($null -eq $primaryError) { $primaryError = $_ }
                else { Write-Warning "Exact-PID cleanup also failed: $($_.Exception.Message)" }
            }
        }
    }
}

if ($null -ne $primaryError) { throw $primaryError }
Write-Host 'PASS: issue #149 default/theme/explicit colors reached the presented WGL framebuffer across reload, new tab, and new split.'
