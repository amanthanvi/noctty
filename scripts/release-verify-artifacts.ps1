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
    $checksums = Join-Path $artifactDirectory (
        New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture $architecture `
            -Kind checksums
    )
    foreach ($path in @($setup, $portable, $checksums)) {
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

    $extractDirectory = Join-Path $ExtractionRoot "noctty-release-verify-$architecture"
    if (Test-Path -LiteralPath $extractDirectory) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }
    Expand-Archive -LiteralPath $portable -DestinationPath $extractDirectory
    foreach ($relativePath in @(
        'noctty/noctty.com',
        'noctty/noctty.exe',
        'noctty/ghostty-vt.dll',
        'noctty/noctty-terminal-handoff-proxy.dll'
    )) {
        [void](Assert-ReleaseSignature `
            -Path (Join-Path $extractDirectory $relativePath) `
            -Label "$relativePath $architecture" `
            -AllowedPins $allowedPins `
            -TrustSelfSigned $TrustSelfSigned)
    }
}

Write-Host "Release artifact signature and checksum verification: PASS ($Version)" -ForegroundColor Green
