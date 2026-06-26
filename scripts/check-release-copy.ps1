[CmdletBinding()]
param(
    [switch]$CheckRemoteLatest
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
. (Join-Path $PSScriptRoot "windows-architecture.ps1")

$copyPaths = @(
    "README.md",
    "PACKAGING.md",
    "docs/getting-started.md",
    "docs/status.md",
    "docs/windows.md",
    "docs/windows-capability-matrix.md",
    "site/README.md",
    "site/components/terminal.jsx",
    "site/components/hero/version-chip-color.jsx",
    "site/components/why/why-fork.jsx",
    "site/bundle.js"
)

$failures = New-Object System.Collections.Generic.List[string]
$textCache = @{}

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message) | Out-Null
}

function Get-RepoPath {
    param([string]$RelativePath)
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
}

function Get-Text {
    param([string]$RelativePath)

    if ($script:textCache.ContainsKey($RelativePath)) {
        return $script:textCache[$RelativePath]
    }

    $path = Get-RepoPath -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure "Missing checked copy file: $RelativePath"
        $script:textCache[$RelativePath] = $null
        return $null
    }

    $text = Get-Content -LiteralPath $path -Raw
    $script:textCache[$RelativePath] = $text
    return $text
}

function Test-ContainsOrdinalIgnoreCase {
    param(
        [string]$Text,
        [string]$Needle
    )

    return $Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Require-Contains {
    param(
        [string]$RelativePath,
        [string]$Needle,
        [string]$Reason
    )

    $text = Get-Text -RelativePath $RelativePath
    if ($null -eq $text) {
        return
    }

    if (-not (Test-ContainsOrdinalIgnoreCase -Text $text -Needle $Needle)) {
        Add-Failure "${RelativePath}: missing required text `"$Needle`" - $Reason"
    }
}

function Require-Regex {
    param(
        [string]$RelativePath,
        [string]$Pattern,
        [string]$Reason
    )

    $text = Get-Text -RelativePath $RelativePath
    if ($null -eq $text) {
        return
    }

    if (-not [regex]::IsMatch($text, $Pattern)) {
        Add-Failure "${RelativePath}: missing required pattern /$Pattern/ - $Reason"
    }
}

function Forbid-CopyText {
    param(
        [string]$Needle,
        [string]$Reason
    )

    foreach ($relativePath in $copyPaths) {
        $text = Get-Text -RelativePath $relativePath
        if ($null -eq $text) {
            continue
        }

        if (Test-ContainsOrdinalIgnoreCase -Text $text -Needle $Needle) {
            Add-Failure "${relativePath}: forbidden text `"$Needle`" - $Reason"
        }
    }
}

$readme = Get-Text -RelativePath "README.md"
$latestVersion = $null
if ($null -eq $readme) {
    # Get-Text already recorded the missing-file failure.
} elseif ($readme -match 'winghostty\s+([0-9]+\.[0-9]+\.[0-9]+)\]\(https://github\.com/amanthanvi/winghostty/releases/tag/v\1\)') {
    $latestVersion = $Matches[1]
} else {
    Add-Failure "README.md: could not find a self-consistent latest stable release link."
}

$forbiddenRules = @(
    @{ Text = "1.3.111"; Reason = "README/docs/site release copy should not point at the stale May 12 release." },
    @{ Text = "1.3.113"; Reason = "README/docs/site release copy should not point at the stale May 24 release." },
    @{ Text = "ARM64 builds are added by the next release"; Reason = "Current releases already publish ARM64 assets." },
    @{ Text = "winghostty publishes two Windows artifacts"; Reason = "Current releases publish installer, portable, and checksum assets for both x64 and ARM64." },
    @{ Text = "Releases are currently unsigned"; Reason = "Public releases require signed installers and signed Windows binaries." },
    @{ Text = "Current releases are unsigned"; Reason = "Public releases require signed installers and signed Windows binaries." },
    @{ Text = "Unsigned releases are expected"; Reason = "Public releases require signed installers and signed Windows binaries." },
    @{ Text = "code signing lands"; Reason = "Release signing is already part of the public release track." }
)

foreach ($rule in $forbiddenRules) {
    Forbid-CopyText -Needle $rule.Text -Reason $rule.Reason
}

$architectures = Get-WindowsPackageArchitectures
$placeholderVersion = "<version>"

foreach ($arch in $architectures) {
    foreach ($kind in @("setup", "portable", "checksums")) {
        $placeholderName = New-WindowsPackageArtifactName -Version $placeholderVersion -Architecture $arch -Kind $kind
        Require-Contains -RelativePath "PACKAGING.md" -Needle $placeholderName -Reason "Packaging docs must match scripts/windows-architecture.ps1 artifact naming."
    }
}

Require-Contains -RelativePath "PACKAGING.md" -Needle "legacy alias for existing x64 auto-update clients" -Reason "Packaging docs must preserve the x64 compatibility checksum alias."
Require-Contains -RelativePath "PACKAGING.md" -Needle "Release workflow requires signing" -Reason "Packaging docs must distinguish local unsigned smoke packaging from public signed releases."

foreach ($docsPath in @("docs/getting-started.md", "docs/windows.md")) {
    Require-Contains -RelativePath $docsPath -Needle "winghostty-<version>-windows-<arch>-setup.exe" -Reason "Install docs should describe both x64 and ARM64 setup artifacts."
    Require-Contains -RelativePath $docsPath -Needle "winghostty-<version>-windows-<arch>-portable.zip" -Reason "Install docs should describe both x64 and ARM64 portable artifacts."
    Require-Contains -RelativePath $docsPath -Needle "SHA256SUMS-windows-<arch>.txt" -Reason "Checksum guidance should use architecture-specific checksum files."
    Require-Regex -RelativePath $docsPath -Pattern "(?i)\bx64\b" -Reason "Install docs should name the supported release architectures."
    Require-Regex -RelativePath $docsPath -Pattern "(?i)\barm64\b" -Reason "Install docs should name the supported release architectures."
}

Require-Contains -RelativePath "docs/status.md" -Needle "x64 and ARM64" -Reason "Status docs should match the supported public release architectures."
Require-Contains -RelativePath "docs/status.md" -Needle "checksum metadata" -Reason "Updater docs should mention checksum-gated release metadata."

foreach ($sitePath in @("site/components/terminal.jsx", "site/bundle.js")) {
    Require-Contains -RelativePath $sitePath -Needle 'PROCESSOR_ARCHITEW6432' -Reason "The public site terminal copy should detect the native OS architecture from WOW64 shells."
    Require-Contains -RelativePath $sitePath -Needle 'windows-$arch-setup.exe' -Reason "The public site terminal copy should not hard-code x64 download URLs."
    Require-Contains -RelativePath $sitePath -Needle 'windows-$arch-portable.zip' -Reason "The public site terminal copy should not hard-code x64 download URLs."
    Require-Contains -RelativePath $sitePath -Needle "x64 and ARM64" -Reason "The public site should describe both public release architectures."
}

if ($latestVersion) {
    foreach ($arch in $architectures) {
        foreach ($kind in @("setup", "portable", "checksums")) {
            $artifactName = New-WindowsPackageArtifactName -Version $latestVersion -Architecture $arch -Kind $kind
            Require-Contains -RelativePath "README.md" -Needle $artifactName -Reason "README latest-release table should list every current public artifact."
        }
    }

    $legacyName = New-WindowsPackageArtifactName -Version $latestVersion -Architecture "x64" -Kind "legacy-checksums"
    Require-Contains -RelativePath "README.md" -Needle $legacyName -Reason "README should document the legacy x64 checksum alias."

    $escapedVersion = [regex]::Escape($latestVersion)
    Require-Regex -RelativePath "site/components/hero/version-chip-color.jsx" -Pattern "DEFAULT_WG_VERSION\s*=\s*'$escapedVersion'" -Reason "Site source default release version should match README."
    Require-Regex -RelativePath "site/components/terminal.jsx" -Pattern "WG_VERSION\s*=\s*window\.WG_VERSION\s*\|\|\s*'$escapedVersion'" -Reason "Site terminal default release version should match README."
    Require-Regex -RelativePath "site/bundle.js" -Pattern "(?<![\d.])$escapedVersion(?![\d.])" -Reason "Generated site bundle should contain the current README release version."
}

if ($CheckRemoteLatest) {
    if (-not $latestVersion) {
        Add-Failure "Cannot check remote latest release because README latest version could not be parsed."
    } elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Add-Failure "Cannot check remote latest release because gh is not installed."
    } else {
        $ghOutput = & gh release view --repo amanthanvi/winghostty --json tagName,publishedAt,assets
        if ($LASTEXITCODE -ne 0) {
            Add-Failure "gh release view failed: $ghOutput"
        } else {
            try {
                $release = $ghOutput | ConvertFrom-Json
            } catch {
                Add-Failure "Failed to parse gh release JSON: $($_.Exception.Message)"
                $release = $null
            }

            if ($release) {
                $publishedDate = $null
                try {
                    $publishedDate = [DateTimeOffset]::Parse([string]$release.publishedAt).UtcDateTime.ToString(
                        "yyyy-MM-dd",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } catch {
                    Add-Failure "Could not parse GitHub latest-release publishedAt date: $($release.publishedAt)"
                }

                $expectedTag = "v$latestVersion"
                if ($release.tagName -ne $expectedTag) {
                    Add-Failure "README latest release is $expectedTag, but GitHub latest release is $($release.tagName)."
                }

                if ($publishedDate) {
                    Require-Contains -RelativePath "README.md" -Needle "published $publishedDate" -Reason "README latest-release date should match GitHub."
                }

                $assetNames = @($release.assets | ForEach-Object { [string]$_.name })
                foreach ($arch in $architectures) {
                    foreach ($kind in @("setup", "portable", "checksums")) {
                        $artifactName = New-WindowsPackageArtifactName -Version $latestVersion -Architecture $arch -Kind $kind
                        if ($assetNames -notcontains $artifactName) {
                            Add-Failure "GitHub latest release $expectedTag is missing expected asset $artifactName."
                        }
                    }
                }

                $legacyName = New-WindowsPackageArtifactName -Version $latestVersion -Architecture "x64" -Kind "legacy-checksums"
                if ($assetNames -notcontains $legacyName) {
                    Add-Failure "GitHub latest release $expectedTag is missing expected asset $legacyName."
                }
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Release copy checks failed:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Release copy checks passed." -ForegroundColor Green
