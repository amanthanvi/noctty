[CmdletBinding()]
param(
    # \A and \z rather than ^ and $, and [0-9] rather than \d, for the reasons
    # in package-package-managers.ps1.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string] $Version,

    # The commit of package-package-managers.ps1 the package names as its
    # source (see that script's -PackageSourceRef).
    [ValidatePattern('\A[0-9A-Za-z][0-9A-Za-z._/-]*\z')]
    [string] $PackageSourceRef,

    # An empty or missing directory for the verified download.
    [string] $DownloadDirectory
)

# Rebuilds the package-manager metadata and the Chocolatey package for a
# release that is already published, from the installers on its release page
# and without building anything: the Release workflow cannot be rerun for that
# because it replaces the published assets (docs/chocolatey-publishing.md).
# The release is verified first by the same script the Release workflow ends
# with, so the installers a package names have the checksums, build provenance
# and signer the release promises. Afterwards
# scripts/release-publish-chocolatey.ps1 packs and pushes.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

$repoRoot = Get-RepoRoot
$createdDownloadDirectory = [string]::IsNullOrWhiteSpace($DownloadDirectory)
if ($createdDownloadDirectory) {
    $DownloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "koreterm-chocolatey-release-$Version-$([guid]::NewGuid().ToString('N'))"
}
$DownloadDirectory = [System.IO.Path]::GetFullPath($DownloadDirectory)

try {
    # Throws on any failure: a missing or draft or prerelease release, an unexpected
    # asset set, a digest, checksum, provenance or Authenticode mismatch.
    & (Join-Path $PSScriptRoot 'verify-published-release.ps1') -Version $Version -DownloadDirectory $DownloadDirectory

    $architectures = @(Get-WindowsPackageArchitectures)

    # verify-published-release.ps1 ties each attestation to this repository's
    # release workflow, not to a commit. Tie the installers the package will name
    # to the commit the release tag points at as well: a release rebuilt later from
    # another commit and re-uploaded under the same tag passes the checks above and
    # fails this one. (A rebuild of the same commit, or of a commit the tag was
    # moved to, still passes both; the WinGet manifest's InstallerSha256 values are
    # the independent record to compare.)
    $repository = if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) { 'richardsonvix/noctty_terminal' } else { $env:GITHUB_REPOSITORY }
    $tagCommit = ((& gh api "repos/$repository/commits/v$Version" --jq .sha) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $tagCommit -cnotmatch '\A[0-9a-f]{40}\z') {
        throw "Could not resolve the commit of tag v$Version in $repository."
    }
    foreach ($architecture in $architectures) {
        $setupPath = Join-Path $DownloadDirectory (New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind setup)
        & gh attestation verify $setupPath `
            --repo $repository `
            --signer-workflow "$repository/.github/workflows/release.yml" `
            --source-digest $tagCommit
        if ($LASTEXITCODE -ne 0) {
            throw "The $architecture installer was not built from the commit of tag v${Version}: $setupPath"
        }
    }

    # The layout package-package-managers.ps1 and release-publish-chocolatey.ps1
    # read: one directory per architecture, the icon beside the x64 files.
    $artifactRoot = Join-Path $repoRoot 'dist/artifacts'
    foreach ($architecture in $architectures) {
        $architectureDirectory = Join-Path $artifactRoot "koreterm-$Version-windows-$architecture"
        New-Item -ItemType Directory -Path $architectureDirectory -Force | Out-Null
        foreach ($kind in @('setup', 'portable', 'checksums')) {
            $name = New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind $kind
            Copy-Item -LiteralPath (Join-Path $DownloadDirectory $name) -Destination (Join-Path $architectureDirectory $name) -Force
            if ($kind -eq 'setup') {
                # Printed so the hashes can be compared with the ones WinGet holds.
                Write-Host "Installer $architecture SHA-256: $(Get-FileSha256Lower -Path (Join-Path $architectureDirectory $name))"
            }
        }
    }
    Copy-Item `
        -LiteralPath (Join-Path $DownloadDirectory 'koreterm-icon.svg') `
        -Destination (Join-Path $artifactRoot "koreterm-$Version-windows-x64/koreterm-icon.svg") `
        -Force

    $packageArguments = @{
        Version       = $Version
        Architectures = $architectures
    }
    if ($PackageSourceRef) {
        $packageArguments.PackageSourceRef = $PackageSourceRef
    }
    & (Join-Path $PSScriptRoot 'package-package-managers.ps1') @packageArguments
}
finally {
    # A folder the caller supplied is the caller's; one chosen here is removed,
    # but only if it is still the temporary folder this script named.
    if ($createdDownloadDirectory -and (Test-Path -LiteralPath $DownloadDirectory)) {
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ($DownloadDirectory.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $DownloadDirectory) -like 'koreterm-chocolatey-release-*') {
            Remove-Item -LiteralPath $DownloadDirectory -Recurse -Force -ErrorAction Continue
        }
    }
}
