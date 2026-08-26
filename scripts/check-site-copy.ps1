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
    @{ Pattern = "(?i)\bscoop install noctty\b(?!/)"; Regex = $true; Reason = "Official Scoop installs should use the bucket-qualified command: scoop install noctty/noctty." },
    @{ Pattern = "winget install noctty"; Reason = "Official WinGet installs should use the package id: winget install AmanThanvi.noctty." },
    @{ Pattern = "D3D11"; Reason = "The shipping Windows renderer is OpenGL 4.3 via WGL." },
    @{ Pattern = "DirectX 11"; Reason = "The shipping Windows renderer is OpenGL 4.3 via WGL." },
    @{ Pattern = "%APPDATA%\noctty\config"; Reason = "Windows docs use %LOCALAPPDATA%\\noctty\\config.ghostty." },
    @{ Pattern = "%APPDATA%/noctty/config"; Reason = "Windows docs use %LOCALAPPDATA%\\noctty\\config.ghostty." },
    @{ Pattern = "replaces binaries silently"; Reason = "Updater apply must stay user-initiated." },
    @{ Pattern = "downloads updates automatically"; Reason = "Avoid implying automatic install/apply." },
    @{ Pattern = "silent auto-update"; Reason = "Updater apply must stay user-initiated." },
    @{ Pattern = "releases are unsigned"; Reason = "Release copy should reflect the signed-release track." },
    @{ Pattern = "currently unsigned"; Reason = "Release copy should reflect the signed-release track." },
    @{ Pattern = "allowDowngrade"; Reason = "The latest-release fetch must never downgrade the compiled site version." },
    @{ Pattern = "full parity"; Reason = "Avoid overclaiming protocol or platform parity." },
    @{ Pattern = "The Ghostty you know and love"; Reason = "Avoid broad compatibility claims that exceed the documented shared core." },
    @{ Pattern = "Close where it matters"; Reason = "Avoid vague compatibility claims; name the shared and fork-specific layers." },
    @{ Pattern = "shared Ghostty terminal core · auto-detected: PowerShell, cmd, Git Bash'"; Reason = "Current profile-picker messaging should include opt-in WSL." },
    @{ Pattern = "src/terminal, src/font, src/renderer, src/input, src/config, and libghostty-vt are shared"; Reason = "The shared upstream surface is broader today and includes termio/crash/shell-integration/inspector." },
    @{ Pattern = "Built on libghostty by Mitchell Hashimoto"; Reason = "Prefer the repo-accurate Ghostty terminal-core wording." }
)

$requiredRules = @(
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "https://github.com/amanthanvi/noctty/releases/latest"; Reason = "Primary download CTA should point to latest release." },
    @{ Path = Join-Path $siteRoot "terminal.js"; Pattern = "%LOCALAPPDATA%\\noctty\\config.ghostty"; Reason = "Landing page should mention the real Windows config path." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "https://github.com/amanthanvi/noctty"; Reason = "Landing page should keep a repo link." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "winget install AmanThanvi.noctty"; Reason = "Hero copy should surface the official WinGet install command." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "formerly WingHostty"; Reason = "Hero should keep the rename note so former WingHostty users recognize the project." },
    @{ Path = Join-Path $siteRoot "install.js"; Pattern = "scoop install noctty/noctty"; Reason = "Copied install text should include the official Scoop install command." },
    @{ Path = Join-Path $siteRoot "install.js"; Pattern = "https://github.com/amanthanvi/scoop-noctty"; Reason = "Copied Scoop install text should include the official bucket source." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "Session restoration"; Reason = "Landing page should describe current session restoration." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "Native settings"; Reason = "Landing page should describe the current native settings window." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "Universal palette"; Reason = "Landing page should describe the current universal palette." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "partial, not complete"; Reason = "Landing page must keep Windows accessibility status explicitly partial." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = '<link rel="canonical" href="https://noctty.com/"'; Reason = "Landing page should publish its canonical URL." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "<noscript>"; Reason = "Landing page should retain a useful no-JavaScript fallback." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "https://github.com/amanthanvi/noctty/discussions"; Reason = "Footer should link to project Discussions." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "bug_report.yml"; Reason = "Footer should link directly to the bug report form." }
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
