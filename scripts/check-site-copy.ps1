param()

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")
$siteRoot = Join-Path (Get-RepoRoot) "site"

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
    @{ Pattern = "winget install AmanThanvi.noctty"; Reason = "Do not advertise the pending WinGet package before bootstrap merges." },
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
    @{ Pattern = "Built on libghostty by Mitchell Hashimoto"; Reason = "Prefer the repo-accurate Ghostty terminal-core wording." },
    # Cross-terminal speed claims, site-wide coarse net. site/tests/trust.test.mjs
    # is the authoritative and stricter guard for site/why-noctty.html and the two
    # migration guides: it also bans hardcoded rates, durations, throughput,
    # percentage deltas, multipliers, and comparisons keyed to a named competitor
    # while allowing configuration-size facts. Keep these two lists directionally
    # consistent; when they disagree, the test wins.
    @{ Pattern = "(?i)\bfast(?:er|est)\b"; Regex = $true; Reason = "No cross-terminal performance result is published; see docs/windows-benchmark-methodology.md." },
    @{ Pattern = "(?i)\bslow(?:er|est)\b"; Regex = $true; Reason = "No cross-terminal performance result is published; see docs/windows-benchmark-methodology.md." },
    @{ Pattern = "(?i)\b(?:snappier|snappiest|quicker|quickest)\b"; Regex = $true; Reason = "No cross-terminal performance result is published; see docs/windows-benchmark-methodology.md." },
    @{ Pattern = "(?i)\boutperform"; Regex = $true; Reason = "No cross-terminal performance result is published; see docs/windows-benchmark-methodology.md." },
    @{ Pattern = "(?i)\b(?:than|versus|vs\.?|compared to|compared with)\s+(?:windows terminal|conhost|alacritty|wezterm|mintty|conemu|cmder|putty|iterm)\b"; Regex = $true; Reason = "No terminal has been measured at the same causal endpoint on the same machine; no comparison may be published." },
    @{ Pattern = "(?i)\b(?:twice|thrice|double|triple|\d+(?:\.\d+)?x)\s+the\s+(?:throughput|speed|performance|frame\s?rate)\b"; Regex = $true; Reason = "No cross-terminal performance result is published; see docs/windows-benchmark-methodology.md." },
    @{ Pattern = "(?i)blazing"; Regex = $true; Reason = "Performance copy must cite a measured figure, not an adjective." },
    @{ Pattern = "noctty.dev"; Reason = "The project domain is noctty.com; noctty.dev is not owned by this project." }
)

$requiredRules = @(
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "https://github.com/amanthanvi/noctty/releases/latest"; Reason = "Primary download CTA should point to latest release." },
    @{ Path = Join-Path $siteRoot "terminal.js"; Pattern = "%LOCALAPPDATA%\\noctty\\config.ghostty"; Reason = "Landing page should mention the real Windows config path." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "https://github.com/amanthanvi/noctty"; Reason = "Landing page should keep a repo link." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "WinGet: bootstrap pending"; Reason = "Hero copy should state the pending WinGet migration honestly." },
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "Formerly winghostty"; CaseSensitive = $true; Reason = "Footer should keep the rename note so former winghostty users recognize the project." },
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
    @{ Path = Join-Path $siteRoot "index.html"; Pattern = "why-noctty.html"; Reason = "The landing page should expose the identity and trust page." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "Get-FileHash"; Reason = "The trust page should include an executable checksum check." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a"; Reason = "The trust page should publish the current updater publisher-key pin." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "Assert-ReleaseSignature"; Reason = "The manual legacy-release path should validate the embedded Authenticode signature and signer pin with the repository helper." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = '$PSVersionTable.PSVersion.Major -lt 7'; Reason = "The manual signature verifier should fail before side effects when it is pasted into Windows PowerShell 5.1." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "checkout --detach 5220df49e39c96182cf13150c53c4fd71fbc5b10"; Reason = "The manual v1.3.123 path should use a content-pinned verifier implementation that defines the signature helper." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = 'noctty-release-verification-" + [Guid]::NewGuid()'; Reason = "The manual portable verifier should extract into a fresh workspace rather than reuse stale files." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "winghostty\winghostty.com"; Reason = "The manual legacy-release path should verify the console shim extracted from the portable ZIP." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "winghostty\winghostty.exe"; Reason = "The manual legacy-release path should verify the application binary extracted from the portable ZIP." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "winghostty\ghostty-vt.dll"; Reason = "The manual legacy-release path should verify the library extracted from the portable ZIP." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = '-AllowedPins @($expectedSpki)'; Reason = "The manual legacy-release path should fail closed when the signer does not match the publisher-key pin." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "docs/migrate-from-windows-terminal.md"; Reason = "The trust page should link the Windows Terminal migration guide." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "docs/migrate-from-git-bash.md"; Reason = "The trust page should link the Git Bash and mintty migration guide." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "self-signed certificate"; Reason = "The trust page must state the current signing limitation plainly." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "verifies GitHub build-provenance attestations"; Reason = "The trust page must describe the v1.3.124 provenance gate." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "v1.3.123 uses the legacy"; Reason = "The trust page must state that the promoted stable release predates the current verifier contract." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "verifier accepts v1.3.124 and later"; Reason = "The trust page should keep routing verifier-compatible releases correctly after the latest-version copy updates." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "No screen reader has been run"; Reason = "The trust page must keep the accessibility limit unhedged." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "NVDA pass against a pre-release Debug build found mixed results"; Reason = "The trust page must reflect the measured pre-release NVDA evidence without presenting it as release validation." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "Narrator and JAWS remain unmeasured"; Reason = "The trust page must distinguish the unmeasured readers from the measured NVDA pass." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "miss a budget stated in PRODUCT.md"; Reason = "The trust page must keep the missed performance budgets visible." }
    @{ Path = Join-Path $siteRoot "why-noctty.html"; Pattern = "No comparison against another terminal is published"; Reason = "The trust page must keep the no-competitor-numbers statement." }
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

    $match = Select-String -Path $rule.Path -Pattern $rule.Pattern -SimpleMatch -CaseSensitive:([bool]$rule.CaseSensitive)
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
