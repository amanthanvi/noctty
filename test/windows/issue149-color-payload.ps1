[CmdletBinding()]
param([Parameter(Mandatory)] [string]$MarkerDirectory)

$ErrorActionPreference = 'Stop'
[IO.Directory]::CreateDirectory($MarkerDirectory) | Out-Null

$surfaceId = if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_SURFACE_ID)) {
    'unknown-surface'
}
else {
    $env:GHOSTTY_SURFACE_ID
}
$markerPath = Join-Path $MarkerDirectory "$surfaceId.ready"
[IO.File]::WriteAllText($markerPath, $surfaceId, [Text.UTF8Encoding]::new($false))

$esc = [char]27
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Write("$esc[2J$esc[H$esc[?25l$esc[?7l")

# Rows 5-7 use reverse video with default colors, so their cell backgrounds
# are the configured foreground. Rows 12-14 use palette index 1 as their cell
# background. Autowrap is disabled so every row becomes one stable color band
# regardless of the current column count.
foreach ($row in 5..7) {
    [Console]::Write("$esc[$row;1H$esc[0;7m" + (' ' * 512))
}
foreach ($row in 12..14) {
    [Console]::Write("$esc[$row;1H$esc[0;41m" + (' ' * 512))
}
[Console]::Write("$esc[0m$esc[H")

while ($true) {
    Start-Sleep -Seconds 1
}
