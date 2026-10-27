# Settings' All settings page notes what Windows does with the keys it accepts
# without honouring (`windows_notes` in win32_settings_reference.zig), and the
# capability matrix lists them under "Settings accepted without effect": the
# two lists name the same keys.
$settingsReferenceSource = Join-Path $repoRoot 'src\apprt\win32_settings_reference.zig'
$capabilityMatrixPath = Join-Path $repoRoot 'docs\windows-capability-matrix.md'

$settingsReferenceText = Get-Content -LiteralPath $settingsReferenceSource -Raw
$windowsNotesBlock = [regex]::Match($settingsReferenceText, '(?ms)^pub const windows_notes = \[_\]WindowsNote\{\r?\n(.*?)^\};')
if (-not $windowsNotesBlock.Success) {
    throw 'win32_settings_reference.zig no longer declares windows_notes as this contract reads it.'
}
$windowsNoteKeys = @([regex]::Matches($windowsNotesBlock.Groups[1].Value, '\.key = "([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

$capabilityMatrixText = Get-Content -LiteralPath $capabilityMatrixPath -Raw
$inertSection = [regex]::Match($capabilityMatrixText, '(?ms)^### Settings accepted without effect\r?\n(.*?)(?=^### )')
if (-not $inertSection.Success) {
    throw 'docs/windows-capability-matrix.md has no "Settings accepted without effect" section.'
}
# Each bullet's keys, written in backticks, `bell-features = border` included.
$inertBullets = [regex]::Matches($inertSection.Groups[1].Value, '(?ms)^- (.*?)(?=^- |^\s*$)')
$matrixKeys = @($inertBullets | ForEach-Object {
    [regex]::Matches($_.Groups[1].Value, '`(_?[a-z][a-z0-9-]*)(?: = [^`]*)?`') |
        ForEach-Object { $_.Groups[1].Value }
} | Sort-Object -Unique)

if ($windowsNoteKeys.Count -lt 2 -or $matrixKeys.Count -lt 2) {
    throw "The Windows notes ($($windowsNoteKeys.Count)) or the matrix's inert keys ($($matrixKeys.Count)) were not found."
}
$onlyInCode = @($windowsNoteKeys | Where-Object { $_ -cnotin $matrixKeys })
$onlyInMatrix = @($matrixKeys | Where-Object { $_ -cnotin $windowsNoteKeys })
if ($onlyInCode.Count -ne 0 -or $onlyInMatrix.Count -ne 0) {
    throw ("The All settings page's Windows notes and the capability matrix's inert keys differ. " +
        "Only in windows_notes: $($onlyInCode -join ', '). Only in the matrix: $($onlyInMatrix -join ', ').")
}
