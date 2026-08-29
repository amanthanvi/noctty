[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $ArtifactRoot,

    [string] $ExtractionRoot = $env:RUNNER_TEMP,

    [bool] $TrustSelfSigned = (
        ([string] $env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED).
            Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on')
    ),

    [switch] $ValidateParameters
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')
. (Join-Path $PSScriptRoot 'signing-trust.ps1')
. (Join-Path $PSScriptRoot 'portable-manifest-verification.ps1')

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
if ([string]::IsNullOrWhiteSpace($ExtractionRoot)) {
    $ExtractionRoot = [System.IO.Path]::GetTempPath()
}
$ExtractionRoot = [System.IO.Path]::GetFullPath($ExtractionRoot)

if ($ValidateParameters) {
    Write-Host "Release artifact verification parameters: PASS ($Version)" -ForegroundColor Green
    return
}

if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
    throw 'Get-AuthenticodeSignature is required to verify release artifacts.'
}

$allowedPins = @(
    Get-UpdaterPublisherSpkiPins `
        -SourcePath (Join-Path $repoRoot 'src/update/github_releases.zig')
)
if ($allowedPins.Count -eq 0) {
    throw 'Updater publisher-pin allowlist is empty.'
}

$conptyPin = Get-Content `
    -LiteralPath (Join-Path $repoRoot 'dist/windows/conpty-redist.json') `
    -Raw | ConvertFrom-Json

foreach ($architecture in (Get-WindowsPackageArchitectures)) {
    $artifactDirectory = Join-Path $ArtifactRoot "noctty-$Version-windows-$architecture"
    $setup = Join-Path $artifactDirectory (
        New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture $architecture `
            -Kind setup
    )
    $portable = Join-Path $artifactDirectory (
        New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture $architecture `
            -Kind portable
    )
    $manifest = Join-Path $artifactDirectory (
        New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture $architecture `
            -Kind manifest
    )
    $checksums = Join-Path $artifactDirectory (
        New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture $architecture `
            -Kind checksums
    )
    foreach ($path in @($setup, $portable, $manifest, $checksums)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing required release asset: $path"
        }
    }

    $checksumEntries = Get-ChecksumEntries -Path $checksums
    $expectedChecksumNames = @(
        [System.IO.Path]::GetFileName($setup),
        [System.IO.Path]::GetFileName($portable)
    )
    if ($checksumEntries.Count -ne $expectedChecksumNames.Count -or
        @($expectedChecksumNames | Where-Object {
            -not $checksumEntries.Contains($_)
        }).Count -gt 0) {
        throw "$([System.IO.Path]::GetFileName($checksums)) must contain exactly the setup and portable assets for $architecture."
    }
    foreach ($path in @($setup, $portable)) {
        $name = [System.IO.Path]::GetFileName($path)
        $hash = Get-FileSha256Lower -Path $path
        if (-not $checksumEntries.Contains($name) -or
            $checksumEntries[$name] -cne $hash) {
            throw "$([System.IO.Path]::GetFileName($checksums)) does not contain the expected hash line for $name."
        }
    }

    [void](Assert-ReleaseSignature `
        -Path $setup `
        -Label "Setup $architecture" `
        -AllowedPins $allowedPins `
        -TrustSelfSigned $TrustSelfSigned)
    [void](Assert-ReleaseSignature `
        -Path $manifest `
        -Label "Portable manifest $architecture" `
        -AllowedPins $allowedPins `
        -TrustSelfSigned $TrustSelfSigned)

    $extractDirectory = Join-Path $ExtractionRoot "noctty-release-verify-$architecture"
    if (Test-Path -LiteralPath $extractDirectory) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }
    Expand-Archive -LiteralPath $portable -DestinationPath $extractDirectory
    Assert-PortableManifestMatchesPayload `
        -ManifestPath $manifest `
        -PayloadRoot (Join-Path $extractDirectory 'noctty') `
        -Label "Portable manifest $architecture"
    foreach ($relativePath in (Get-WindowsSignedRuntimePayloads)) {
        [void](Assert-ReleaseSignature `
            -Path (Join-Path $extractDirectory $relativePath) `
            -Label "$relativePath $architecture" `
            -AllowedPins $allowedPins `
            -TrustSelfSigned $TrustSelfSigned)
    }

    # The bundled ConPTY pair is Microsoft's, not ours: it is never re-signed,
    # so it is verified against the pinned hashes and Microsoft's own signature
    # instead of the updater publisher pins.
    $conptyArchitecture = $conptyPin.architectures.PSObject.Properties[$architecture].Value
    foreach ($payload in @(
        @{ RelativePath = 'noctty/conpty.dll'; Pin = $conptyArchitecture.conptyDll },
        @{ RelativePath = 'noctty/OpenConsole.exe'; Pin = $conptyArchitecture.openConsoleExe }
    )) {
        $payloadPath = Join-Path $extractDirectory $payload.RelativePath
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $payloadPath).Hash.ToLowerInvariant()
        if ($actualHash -cne ([string] $payload.Pin.sha256).ToLowerInvariant()) {
            throw "$($payload.RelativePath) $architecture does not match the pinned ConPTY SHA-256."
        }

        $conptySignature = Get-AuthenticodeSignature -LiteralPath $payloadPath
        if ($conptySignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "$($payload.RelativePath) $architecture has no valid Authenticode signature: $($conptySignature.Status)"
        }
        $conptySigner = $conptySignature.SignerCertificate.GetNameInfo(
            [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )
        if ($conptySigner -cne 'Microsoft Corporation') {
            throw "$($payload.RelativePath) $architecture is not signed by Microsoft Corporation: $conptySigner"
        }
    }
}

Write-Host "Release artifact signature and checksum verification: PASS ($Version)" -ForegroundColor Green
