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
    'amanthanvi/noctty'
} else {
    $env:GITHUB_REPOSITORY
}
$firstAttestedVersion = [version]'1.3.124'
$firstPortableManifestVersion = [version]'1.3.124'
$minimumGhAttestationVersion = [version]'2.93.0'
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')
. (Join-Path $PSScriptRoot 'signing-trust.ps1')
. (Join-Path $PSScriptRoot 'portable-manifest-verification.ps1')

function Test-GhAttestationAvailable {
    $versionOutput = @(& gh --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        $versionOutput.Count -eq 0 -or
        [string]$versionOutput[0] -notmatch '^gh version (?<version>\d+\.\d+\.\d+)(?:\s|$)') {
        throw 'Cannot determine the installed GitHub CLI version required for safe attestation verification.'
    }

    $ghVersion = [version]$Matches['version']
    if ($ghVersion -lt $minimumGhAttestationVersion) {
        throw "GitHub CLI $ghVersion is unsafe for attestation verification. Upgrade to $minimumGhAttestationVersion or later."
    }

    & gh attestation verify --help *> $null
    if ($LASTEXITCODE -eq 0) { return $true }

    $message = 'the installed GitHub CLI does not provide the gh attestation verify subcommand'
    if ($env:GITHUB_ACTIONS -eq 'true') {
        throw "Cannot verify build provenance attestations: $message. Upgrade gh on the runner."
    }
    Write-Warning "Skipping build provenance attestation verification: $message. Upgrade gh to verify provenance."
    return $false
}

function Assert-PublishedAttestation {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Label,
        [Parameter(Mandatory)] [string]$Repository
    )

    & gh attestation verify $Path `
        --repo $Repository `
        --signer-workflow "$Repository/.github/workflows/release.yml"
    if ($LASTEXITCODE -ne 0) {
        throw "$Label build provenance attestation is missing or invalid: $Path"
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required to verify a published release.'
}
if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
    throw 'Get-AuthenticodeSignature is required to verify published Windows binaries.'
}

function Get-PortablePeRelativePaths {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $rootPath -File -Recurse -Force)) {
        $stream = [System.IO.File]::Open(
            $file.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            if ($stream.Length -ge 2 -and $stream.ReadByte() -eq 0x4D -and $stream.ReadByte() -eq 0x5A) {
                $paths.Add(
                    [System.IO.Path]::GetRelativePath($rootPath, $file.FullName).Replace('\', '/')
                )
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    return @($paths)
}

$tag = "v$Version"
$releaseJson = & gh release view $tag --repo $repository --json tagName,isDraft,isPrerelease,assets
if ($LASTEXITCODE -ne 0) { throw "Could not load published release $tag from $repository." }
$release = $releaseJson | ConvertFrom-Json
if ($release.tagName -ne $tag -or $release.isDraft -or $release.isPrerelease) {
    throw "Published release $tag must exist as a stable, non-draft release."
}
$releaseVersion = [version]$Version
$requiresAttestation = ($releaseVersion -ge $firstAttestedVersion)
$requiresPortableManifests = ($releaseVersion -ge $firstPortableManifestVersion)
$verifyAttestations = if ($requiresAttestation) {
    Test-GhAttestationAvailable
} else {
    Write-Host "Skipping build provenance attestation verification: $tag predates the v$firstAttestedVersion attestation requirement."
    $false
}

$expectedNames = [System.Collections.Generic.List[string]]::new()
foreach ($architecture in (Get-WindowsPackageArchitectures)) {
    $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind setup))
    $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind portable))
    if ($requiresPortableManifests) {
        $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind manifest))
    }
    $expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind checksums))
}
$expectedNames.Add((New-WindowsPackageArtifactName -Version $Version -Architecture x64 -Kind legacy-checksums))
$expectedNames.Add('noctty-icon.svg')
$expectedAttestationNames = @($expectedNames | Where-Object { $_ -ne 'noctty-icon.svg' })
$expectedAssetCount = if ($requiresPortableManifests) { 10 } else { 8 }
if ($expectedNames.Count -ne $expectedAssetCount) {
    throw "Published release contract must require exactly $expectedAssetCount assets; generated $($expectedNames.Count)."
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
    $DownloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "noctty-published-$Version-$([Guid]::NewGuid().ToString('N'))"
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
    $conptyPin = Get-Content `
        -LiteralPath (Join-Path $repoRoot 'dist/windows/conpty-redist.json') `
        -Raw | ConvertFrom-Json

    $attestationEvidenceCount = 0
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
        if ($verifyAttestations -and $expectedAttestationNames -contains [string]$asset.name) {
            Assert-PublishedAttestation `
                -Path $path `
                -Label ([string]$asset.name) `
                -Repository $repository
            $attestationEvidenceCount += 1
        }
    }
    if ($verifyAttestations -and
        ($expectedAttestationNames.Count -ne 9 -or
         $attestationEvidenceCount -ne $expectedAttestationNames.Count)) {
        throw "Published release must contain exactly nine verified build provenance attestations; found $attestationEvidenceCount."
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
        $manifestName = New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind manifest
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
        if ($requiresPortableManifests) {
            $signatureEvidence.Add((Assert-ReleaseSignature `
                -Path (Join-Path $DownloadDirectory $manifestName) `
                -Label "Portable manifest $architecture" `
                -AllowedPins $allowedPins `
                -TrustSelfSigned $trustSelfSigned))
        }

        $extractDirectory = Join-Path $DownloadDirectory "extract-$architecture"
        Expand-Archive -LiteralPath (Join-Path $DownloadDirectory $portableName) -DestinationPath $extractDirectory
        if ($requiresPortableManifests) {
            Assert-PortableManifestMatchesPayload `
                -ManifestPath (Join-Path $DownloadDirectory $manifestName) `
                -PayloadRoot (Join-Path $extractDirectory 'noctty') `
                -Label "Portable manifest $architecture"
        }
        # Microsoft's bundled ConPTY pair is intentionally outside
        # Get-WindowsSignedRuntimePayloads: it is never re-signed by us, so it
        # can never satisfy the updater publisher pins. It still has to survive
        # publication, so it is checked below the way the pre-publish verifier
        # checks it, against the pinned hash and Microsoft's own signer.
        $conptyArchitecture = $conptyPin.architectures.PSObject.Properties[$architecture].Value
        $conptyPortablePayloads = @(
            [pscustomobject]@{
                RelativePath = 'noctty/conpty.dll'
                Pin          = $conptyArchitecture.conptyDll
            },
            [pscustomobject]@{
                RelativePath = 'noctty/OpenConsole.exe'
                Pin          = $conptyArchitecture.openConsoleExe
            }
        )
        $signedPortablePePaths = @(Get-WindowsSignedRuntimePayloads)
        $expectedPortablePePaths = $signedPortablePePaths + @($conptyPortablePayloads.RelativePath)
        $portablePePaths = @(Get-PortablePeRelativePaths -Root $extractDirectory)
        $missingPortablePe = @($expectedPortablePePaths | Where-Object { $_ -notin $portablePePaths })
        $unexpectedPortablePe = @($portablePePaths | Where-Object { $_ -notin $expectedPortablePePaths })
        if ($missingPortablePe.Count -gt 0 -or $unexpectedPortablePe.Count -gt 0) {
            throw "$portableName PE inventory mismatch. Missing: $($missingPortablePe -join ', '); unexpected: $($unexpectedPortablePe -join ', ')."
        }
        # One loop over the whole expected inventory, so no expected PE can
        # leave this block without an Authenticode verdict.
        foreach ($relativePath in $expectedPortablePePaths) {
            $binaryPath = Join-Path $extractDirectory $relativePath
            if ($relativePath -in $signedPortablePePaths) {
                $signatureEvidence.Add((Assert-ReleaseSignature `
                    -Path $binaryPath `
                    -Label "$relativePath $architecture" `
                    -AllowedPins $allowedPins `
                    -TrustSelfSigned $trustSelfSigned))
                continue
            }

            $conptyPayloadPin = @(
                $conptyPortablePayloads | Where-Object { $_.RelativePath -eq $relativePath }
            )[0].Pin
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $binaryPath).Hash.ToLowerInvariant()
            if ($actualHash -cne ([string] $conptyPayloadPin.sha256).ToLowerInvariant()) {
                throw "$relativePath $architecture does not match the pinned ConPTY SHA-256."
            }

            $conptySignature = Get-AuthenticodeSignature -LiteralPath $binaryPath
            if ($conptySignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                throw "$relativePath $architecture has no valid Authenticode signature: $($conptySignature.Status)"
            }
            $conptySigner = $conptySignature.SignerCertificate.GetNameInfo(
                [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
                $false
            )
            if ($conptySigner -cne 'Microsoft Corporation') {
                throw "$relativePath $architecture is not signed by Microsoft Corporation: $conptySigner"
            }
        }
    }

    # Per architecture: one setup, one portable manifest (from 1.3.124), and
    # every signed runtime payload. Derived so that shipping a new signed
    # binary cannot silently shrink the evidence set.
    $signedAssetsPerArchitecture = if ($requiresPortableManifests) { 2 } else { 1 }
    $expectedSignatureCount =
        @(Get-WindowsPackageArchitectures).Count *
        ($signedAssetsPerArchitecture + @(Get-WindowsSignedRuntimePayloads).Count)
    if ($signatureEvidence.Count -ne $expectedSignatureCount) {
        throw "Published release must contain exactly $expectedSignatureCount verified Authenticode signatures; found $($signatureEvidence.Count)."
    }

    $thumbprints = @($signatureEvidence | ForEach-Object { $_.Thumbprint } | Sort-Object -Unique)
    $pins = @($signatureEvidence | ForEach-Object { $_.SpkiSha256 } | Sort-Object -Unique)
    if ($thumbprints.Count -ne 1 -or $pins.Count -ne 1) {
        throw "Published release files are not signed by one consistent certificate (thumbprints=$($thumbprints -join ', '); pins=$($pins -join ', '))."
    }

    $attestationSummary = if ($verifyAttestations) {
        "$attestationEvidenceCount provenance attestations"
    } elseif ($requiresAttestation) {
        'provenance skipped because gh attestation verify is unavailable'
    } else {
        "provenance not required before v$firstAttestedVersion"
    }
    Write-Host "Published release verification: PASS ($tag, $($assets.Count) assets, $attestationSummary, $($signatureEvidence.Count) signed files, SPKI $($pins[0]))" -ForegroundColor Green
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
