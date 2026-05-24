param()

$ErrorActionPreference = "Stop"

$siteRoot = Join-Path $PSScriptRoot "..\\site"
$siteRoot = [System.IO.Path]::GetFullPath($siteRoot)

if (-not (Test-Path $siteRoot)) {
    throw "Site root not found: $siteRoot"
}

$textFiles = Get-ChildItem -Path $siteRoot -Recurse -File | Where-Object {
    $_.Extension -in @(".html", ".css", ".js", ".jsx", ".md", ".txt", ".svg") -or
    $_.Name -in @("_redirects")
}

$forbiddenRules = @(
    @{ Pattern = "(?i)\bscoop install winghostty\b(?!/)"; Regex = $true; Reason = "Official Scoop installs should use the bucket-qualified command: scoop install winghostty/winghostty." },
    @{ Pattern = "winget install winghostty"; Reason = "No official WinGet package exists yet." },
    @{ Pattern = "D3D11"; Reason = "The shipping Windows renderer is OpenGL 4.3 via WGL." },
    @{ Pattern = "DirectX 11"; Reason = "The shipping Windows renderer is OpenGL 4.3 via WGL." },
    @{ Pattern = "%APPDATA%\winghostty\config"; Reason = "Windows docs use %LOCALAPPDATA%\\winghostty\\config.ghostty." },
    @{ Pattern = "%APPDATA%/winghostty/config"; Reason = "Windows docs use %LOCALAPPDATA%\\winghostty\\config.ghostty." },
    @{ Pattern = "replaces binaries silently"; Reason = "Updater apply must stay user-initiated." },
    @{ Pattern = "downloads updates automatically"; Reason = "Avoid implying automatic install/apply." },
    @{ Pattern = "silent auto-update"; Reason = "Updater apply must stay user-initiated." },
    @{ Pattern = "full parity"; Reason = "Avoid overclaiming protocol or platform parity." },
    @{ Pattern = "shared Ghostty terminal core · auto-detected: PowerShell, cmd, Git Bash'"; Reason = "Current profile-picker messaging should include opt-in WSL." },
    @{ Pattern = "src/terminal, src/font, src/renderer, src/input, src/config, and libghostty-vt are shared"; Reason = "The shared upstream surface is broader today and includes termio/crash/shell-integration/inspector." },
    @{ Pattern = "Built on libghostty by Mitchell Hashimoto"; Reason = "Prefer the repo-accurate Ghostty terminal-core wording." }
)

$requiredRules = @(
    @{ Path = Join-Path $siteRoot "bundle.js"; Pattern = "https://github.com/amanthanvi/winghostty/releases/latest"; Reason = "Primary download CTA should point to latest release." },
    @{ Path = Join-Path $siteRoot "bundle.js"; Pattern = "%LOCALAPPDATA%\\winghostty\\config.ghostty"; Reason = "Landing page should mention the real Windows config path." },
    @{ Path = Join-Path $siteRoot "bundle.js"; Pattern = "https://github.com/amanthanvi/winghostty"; Reason = "Landing page should keep a repo link." },
    @{ Path = Join-Path $siteRoot "bundle.js"; Pattern = "scoop install winghostty/winghostty"; Reason = "Hero copy should surface the official Scoop install command." },
    @{ Path = Join-Path $siteRoot "bundle.js"; Pattern = "https://github.com/amanthanvi/scoop-winghostty"; Reason = "Copied Scoop install text should include the official bucket source." }
)

$failures = New-Object System.Collections.Generic.List[string]

foreach ($rule in $forbiddenRules) {
    $matches = if ($rule.Regex) {
        Select-String -Path $textFiles.FullName -Pattern $rule.Pattern
    } else {
        Select-String -Path $textFiles.FullName -Pattern $rule.Pattern -SimpleMatch
    }
    foreach ($match in $matches) {
        $failures.Add(('{0}:{1}: forbidden pattern "{2}" - {3}' -f $match.Path, $match.LineNumber, $rule.Pattern, $rule.Reason))
    }
}

foreach ($rule in $requiredRules) {
    if (-not (Test-Path $rule.Path)) {
        $failures.Add(('missing required file "{0}"' -f $rule.Path))
        continue
    }

    $match = Select-String -Path $rule.Path -Pattern $rule.Pattern -SimpleMatch
    if (-not $match) {
        $failures.Add(('{0}: missing required pattern "{1}" - {2}' -f $rule.Path, $rule.Pattern, $rule.Reason))
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Site copy checks failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Site copy checks passed." -ForegroundColor Green
