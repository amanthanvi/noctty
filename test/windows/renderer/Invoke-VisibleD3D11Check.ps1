[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Binary,
    [string]$OutputDirectory = (Join-Path $env:TEMP ('noctty-visible-d3d11-' + [guid]::NewGuid().ToString('N'))),
    [switch]$PrepareOnly
)
# Maintainer-only, interactive five-minute check. Agents use -PrepareOnly.
# This intentionally shows one isolated terminal when the maintainer runs it.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Native.ps1')
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot))
. (Join-Path $repoRoot 'scripts/common.ps1')
. (Join-Path $repoRoot 'scripts/windows-architecture.ps1')
. (Join-Path $repoRoot 'scripts/conpty-redist.ps1')
$Binary = [IO.Path]::GetFullPath($Binary)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh output directory; existing evidence is preserved.' }
$realProfile = Join-Path $env:LOCALAPPDATA 'noctty\startup-attempts.json'
function ProfileReceipt {
    if (Test-Path -LiteralPath $realProfile) { return @{exists=$true;hash=(Get-FileHash -LiteralPath $realProfile).Hash;mtime=(Get-Item -LiteralPath $realProfile).LastWriteTimeUtc.ToString('o')} }
    return @{exists=$false}
}
$before = ProfileReceipt
function AssertProfile {
    $after = ProfileReceipt
    if ($after.exists -ne $before.exists -or $after.hash -ne $before.hash -or $after.mtime -ne $before.mtime) { throw 'Real startup-attempts.json changed; stop launches and report it.' }
}
$bin = Join-Path $OutputDirectory 'bin'
[void](New-Item -ItemType Directory -Path $bin)
Copy-Item -LiteralPath $Binary -Destination (Join-Path $bin 'noctty.exe')
Set-Content -LiteralPath (Join-Path $bin 'noctty.portable') -Value 'maintainer visible renderer check'
if ((Get-FileHash -LiteralPath $Binary).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bin 'noctty.exe')).Hash) { throw 'Copied executable differs.' }
$share = Join-Path (Split-Path (Split-Path $Binary)) 'share'
if (Test-Path -LiteralPath $share) { Copy-Item -LiteralPath $share -Destination $OutputDirectory -Recurse }
$architecture = if ([RendererNative]::PeMachine($Binary) -eq 0xaa64) { 'arm64' } else { 'x64' }
if (!(Install-ConPtyRedist -PinPath (Join-Path $repoRoot 'dist/windows/conpty-redist.json') -Architecture $architecture -Destination $bin -CacheRoot (Join-Path $OutputDirectory 'conpty-cache') -RequireConPty)) { throw 'Pinned ConPTY is required for Kitty protocol coverage.' }
$configPath = Join-Path $bin 'config.ghostty'
$config = @('renderer=d3d11','auto-update=off','single-instance=false','window-save-state=never','confirm-close-surface=false','shell-integration=none','window-vsync=false','window-width=96','window-height=28','background-opacity=1','clipboard-paste-protection=true','keybind=ctrl+shift+p=toggle_command_palette','keybind=ctrl+shift+s=toggle_quick_select','keybind=ctrl+shift+r=reload_config','windows-job-object-kill-on-close=true')
Set-Content -LiteralPath $configPath -Value ($config -join "`n") -Encoding utf8
$environment = @{LOCALAPPDATA=(Join-Path $OutputDirectory 'LocalAppData');APPDATA=(Join-Path $OutputDirectory 'AppData')}
[void](New-Item -ItemType Directory -Path $environment.LOCALAPPDATA,$environment.APPDATA)
$readme = @'
Run from a normal PowerShell terminal on your own desktop. Use a ReleaseFast
production build with custom shaders. This script stages a checksum-verified
portable copy, redirects app data, and changes only its own config. Close other
applications with private content before opting into screenshots.

Seven prompts record pass/fail/skip in result.json. Keep the test window visible.
The fixture uses PowerShell -NoProfile. Paste confirmation: paste the supplied
harmless two-line text, inspect the preview/Allow/Cancel buttons, then Cancel.
Quick-select: Ctrl+Shift+S, inspect labels over the text, then Escape.
Opacity: after config reload, inspect the desktop behind the terminal, then
restore opaque mode. Kitty: run the supplied literal escape-sequence command,
observe the OpenGL fallback notice and new text reaching the visible pane.
Do not accept a GPU readback alone as successful visible presentation.

Evidence includes only your ratings unless you explicitly answer y to a cropped
window screenshot. Screenshots capture the displayed window rectangle; unrelated
windows overlapping it can appear. The script never takes the foreground,
changes your clipboard, or terminates an unrelated process. If you interrupted
it, close its one test window yourself; the printed PID identifies that launch.
'@
Set-Content -LiteralPath (Join-Path $OutputDirectory 'README.txt') -Value $readme
if ($PrepareOnly) { AssertProfile; Write-Output "Prepared safely without launching: $OutputDirectory"; return }
if ([RendererNative]::DesktopName().StartsWith('renderer-test-')) { throw 'This check requires the maintainer visible desktop; use PrepareOnly for agent validation.' }
if (-not ('VisibleD3D11Capture' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing.Common,System.Drawing.Primitives,System.Private.Windows.Core,System.Private.Windows.GdiPlus -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
public static class VisibleD3D11Capture {
 public static void Save(int x,int y,int w,int h,string path) {
  using(var image=new Bitmap(w,h))using(var graphics=Graphics.FromImage(image)) {
   graphics.CopyFromScreen(x,y,0,0,new Size(w,h));image.Save(path,ImageFormat.Png);
  }
 }
}
'@
}
$result = [ordered]@{binarySHA256=(Get-FileHash -LiteralPath $Binary).Hash;profileBefore=$before;steps=@();status='incomplete'}
$proc = $null
function Step([string]$Name,[string]$Instruction) {
    Write-Host "`n$Instruction"
    $answer = Read-Host 'Result [p=pass, f=fail, s=skip]'
    if ($answer -notin @('p','f','s')) { $answer='s' }
    $entry = @{step=$Name;result=@{p='pass';f='fail';s='skip'}[$answer]}
    if ((Read-Host 'Save a cropped visible screenshot? [y/N]') -eq 'y') {
        $rect = New-Object RendererNative+RECT
        [void][RendererNative]::GetWindowRect($hostWindow,[ref]$rect)
        try { [VisibleD3D11Capture]::Save($rect.l,$rect.t,$rect.r-$rect.l,$rect.b-$rect.t,(Join-Path $OutputDirectory ($Name+'.png')));$entry.screenshot=$Name+'.png' }
        catch { $entry.captureError='Screen capture unavailable; rating retained.';Write-Warning $entry.captureError }
    }
    $result.steps += $entry
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json')
}
try {
    AssertProfile
    $shell = (Get-Command pwsh).Source
    $proc = Start-Process -FilePath (Join-Path $bin 'noctty.exe') -ArgumentList @('--single-instance=false','-e',('"'+$shell+'"'),'-NoProfile') -WorkingDirectory $bin -Environment $environment -PassThru
    $identity = $proc.StartTime
    Write-Host "Visible test PID=$($proc.Id), portable run=$OutputDirectory"
    $deadline=[DateTime]::UtcNow.AddSeconds(40);$hostWindow=[IntPtr]::Zero
    while ($hostWindow -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) { $proc.Refresh();if($proc.HasExited){throw 'Test app exited.'};$hostWindow=[RendererNative]::Host($proc.Id);Start-Sleep -Milliseconds 100 }
    if ($hostWindow -eq [IntPtr]::Zero) { throw 'Test host did not appear.' }
    Step 'initial' 'Confirm the banner says D3D11 hardware or WARP. In the test pane run: 1..100 | ForEach-Object { "VISIBLE ROW $_ https://example.com" }. Check new text is visible.'
    Step 'palette' 'Press Ctrl+Shift+P. Check the palette list is fully visible over terminal text. Close it with Escape.'
    Step 'paste-confirm' "Paste these two lines into the test pane, inspect the full confirmation preview and Allow/Cancel buttons, then CANCEL:`nWrite-Output 'SAFE FIRST LINE'`nWrite-Output 'SAFE SECOND LINE'"
    Step 'scrollbar' 'Move the mouse to the right terminal edge. Check the overlay scrollbar is visible above text and moves when scrolling.'
    Step 'quick-select' 'Press Ctrl+Shift+S. Check quick-select labels are visible above terminal text and transparent areas still show text. Exit with Escape.'
    Add-Content -LiteralPath $configPath -Value 'background-opacity=0.8'
    Step 'opacity' 'Press Ctrl+Shift+R. Check the desktop shows through the terminal at opacity 0.8, with legible text and chrome.'
    Add-Content -LiteralPath $configPath -Value 'background-opacity=1'
    $kitty = '$e=[char]27; [Console]::Write("$e`_Ga=T,f=24,s=1,v=1,c=1,r=1;/wAA$e\"); Write-Output "AFTER KITTY: VISIBLE OPENGL TEXT"'
    Step 'kitty-fallback' ("Press Ctrl+Shift+R to restore opaque mode. Run this ONE line in the test pane:`n"+$kitty+"`nCheck an OpenGL fallback notice appears, the red Kitty pixel/text presents visibly, and typing another command still works. A black pane fails.")
    $result.status = if (@($result.steps | Where-Object result -eq 'fail').Count) {'fail'} elseif (@($result.steps | Where-Object result -eq 'skip').Count) {'incomplete'} else {'pass'}
} finally {
    if ($proc) {
        $proc.Refresh()
        if (!$proc.HasExited) { [void][RendererNative]::PostMessageW($hostWindow,0x0010,[IntPtr]::Zero,[IntPtr]::Zero);[void]$proc.WaitForExit(5000) }
        if (!$proc.HasExited) { Write-Warning "Close only the test window PID=$($proc.Id) yourself; no forced termination was attempted." }
    }
    AssertProfile
    $result.profileAfter=ProfileReceipt
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json')
}
Write-Output "Visible check $($result.status): $(Join-Path $OutputDirectory 'result.json')"
