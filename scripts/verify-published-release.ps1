[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$DownloadDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$repoRoot = Get-RepoRoot
$repository = if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    'amanthanvi/winghostty'
} else {
    $env:GITHUB_REPOSITORY
}
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')
. (Join-Path $PSScriptRoot 'signing-trust.ps1')

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required to verify a published release.'
}
if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
    throw 'Get-AuthenticodeSignature is required to verify published Windows binaries.'
}

$tag = "v$Version"
$releaseJson = & gh release view $tag --repo $repository --json tagName,isDraft,isPrerelease,assets
if ($LASTEXITCODE -ne 0) { throw "Could not load published release $tag from $repository." }
$release = $releaseJson | ConvertFrom-Json
if ($release.tagName -ne $tag -or $release.isDraft -or $release.isPrerelease) {
    throw "Published release $tag must exist as a stable, non-draft release."
}

$expectedNames = [System.Collections.Generic.List[string]]::new()
foreach ($architecture in (Get-WindowsPackageArchitectures)) {
    $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind setup))
    $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind portable))
    $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind checksums))
}
$expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture x64 -Kind legacy-checksums))
$expectedNames.Add('winghostty-icon.svg')
if ($expectedNames.Count -ne 8) {
    throw "Published release contract must require exactly eight assets; generated $($expectedNames.Count)."
}

$assets = @($release.assets)
$actualNames = @($assets | ForEach-Object { [string]$_.name })
if (($actualNames | Sort-Object -Unique).Count -ne $actualNames.Count) {
    throw "Release $tag contains duplicate asset names."
}
$missing = @($expectedNames | Where-Object { $_ -notin $actualNames })
$unexpected = @($actualNames | Where-Object { $_ -notin $expectedNames })
if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
    throw "Release $tag asset set mismatch. Missing: $($missing -join ', '); unexpected: $($unexpected -join ', ')."
}

$createdTempDirectory = [string]::IsNullOrWhiteSpace($DownloadDirectory)
if ($createdTempDirectory) {
    $DownloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "winghostty-published-$Version-$([Guid]::NewGuid().ToString('N'))"
}
$DownloadDirectory = [System.IO.Path]::GetFullPath($DownloadDirectory)
if (Test-Path -LiteralPath $DownloadDirectory) {
    if (@(Get-ChildItem -LiteralPath $DownloadDirectory -Force).Count -ne 0) {
        throw "Published-release verification directory must be empty: $DownloadDirectory"
    }
} else {
    [System.IO.Directory]::CreateDirectory($DownloadDirectory) | Out-Null
}

try {
    & gh release download $tag --repo $repository --dir $DownloadDirectory
    if ($LASTEXITCODE -ne 0) { throw "Could not download published release $tag from $repository." }

    $allowedPins = @(Get-UpdaterPublisherSpkiPins -SourcePath (Join-Path $repoRoot 'src/update/github_releases.zig'))
    if ($allowedPins.Count -eq 0) { throw 'Updater publisher-pin allowlist is empty.' }
    $trustSelfSigned = ([string]$env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED).Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on')

    foreach ($asset in $assets) {
        $path = Join-Path $DownloadDirectory ([string]$asset.name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Downloaded release asset is missing: $path"
        }
        $actualHash = Get-FileSha256Lower -Path $path
        $digest = [string]$asset.digest
        if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
            throw "GitHub did not publish a SHA-256 digest for asset $($asset.name)."
        }
        if ($actualHash -ne $digest.Substring(7).ToLowerInvariant()) {
            throw "GitHub digest mismatch for asset $($asset.name)."
        }
    }

    $legacyPath = Join-Path $DownloadDirectory (New-WindowsPackageArtifactName -Version $Version -Architecture x64 -Kind legacy-checksums)
    $x64ChecksumsPath = Join-Path $DownloadDirectory (New-WindowsPackageArtifactName -Version $Version -Architecture x64 -Kind checksums)
    if (-not [System.Linq.Enumerable]::SequenceEqual(
        [byte[]][System.IO.File]::ReadAllBytes($legacyPath),
        [byte[]][System.IO.File]::ReadAllBytes($x64ChecksumsPath)
    )) {
        throw 'Legacy SHA256SUMS.txt is not byte-for-byte identical to the x64 checksum file.'
    }

    $signatureEvidence = [System.Collections.Generic.List[object]]::new()
    foreach ($architecture in (Get-WindowsPackageArchitectures)) {
        $setupName = New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind setup
        $portableName = New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind portable
        $checksumsName = New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind checksums
        $checksums = Get-ChecksumEntries -Path (Join-Path $DownloadDirectory $checksumsName)
        $expectedChecksumNames = @($setupName, $portableName)
        if ($checksums.Count -ne $expectedChecksumNames.Count -or
            @($expectedChecksumNames | Where-Object { -not $checksums.Contains($_) }).Count -gt 0) {
            throw "$checksumsName must contain exactly the setup and portable assets for $architecture."
        }
        foreach ($name in $expectedChecksumNames) {
            $actualHash = Get-FileSha256Lower -Path (Join-Path $DownloadDirectory $name)
            if ($checksums[$name] -ne $actualHash) {
                throw "$checksumsName does not match downloaded asset $name."
            }
        }

        $signatureEvidence.Add((Assert-ReleaseSignature `
            -Path (Join-Path $DownloadDirectory $setupName) `
            -Label "Setup $architecture" `
            -AllowedPins $allowedPins `
            -TrustSelfSigned $trustSelfSigned))

        $extractDirectory = Join-Path $DownloadDirectory "extract-$architecture"
        Expand-Archive -LiteralPath (Join-Path $DownloadDirectory $portableName) -DestinationPath $extractDirectory
        foreach ($relativePath in @('winghostty/winghostty.com', 'winghostty/winghostty.exe', 'winghostty/ghostty-vt.dll')) {
            $binaryPath = Join-Path $extractDirectory $relativePath
            if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
                throw "$portableName is missing signed binary $relativePath."
            }
            $signatureEvidence.Add((Assert-ReleaseSignature `
                -Path $binaryPath `
                -Label "$relativePath $architecture" `
                -AllowedPins $allowedPins `
                -TrustSelfSigned $trustSelfSigned))
        }
    }

    if ($signatureEvidence.Count -ne 8) {
        throw "Published release must contain exactly eight verified PE signatures; found $($signatureEvidence.Count)."
    }

    $thumbprints = @($signatureEvidence | ForEach-Object { $_.Thumbprint } | Sort-Object -Unique)
    $pins = @($signatureEvidence | ForEach-Object { $_.SpkiSha256 } | Sort-Object -Unique)
    if ($thumbprints.Count -ne 1 -or $pins.Count -ne 1) {
        throw "Published release binaries are not signed by one consistent certificate (thumbprints=$($thumbprints -join ', '); pins=$($pins -join ', '))."
    }

    Write-Host "Published release verification: PASS ($tag, $($assets.Count) assets, $($signatureEvidence.Count) signed PE files, SPKI $($pins[0]))" -ForegroundColor Green
}
finally {
    if ($createdTempDirectory -and (Test-Path -LiteralPath $DownloadDirectory)) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($DownloadDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    Remove-Item -LiteralPath $DownloadDirectory -Recurse -Force -ErrorAction Stop
                    break
                }
                catch {
                    if ($attempt -eq 3) {
                        Write-Warning "Could not remove temporary published-release verification directory '$DownloadDirectory': $($_.Exception.Message)"
                    } else {
                        Start-Sleep -Milliseconds 200
                    }
                }
            }
        }
    }
}
