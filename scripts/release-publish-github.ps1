[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string] $Tag,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [Parameter(Mandatory)]
    [string] $Title,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+$')]
    [string] $VersionLine,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $UpstreamBaseVersion,

    [Parameter(Mandatory)]
    [ValidateSet('true', 'false')]
    [string] $Prerelease,

    [string] $Repository = $(
        if (-not [string]::IsNullOrWhiteSpace($env:GH_REPO)) {
            $env:GH_REPO
        } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
            $env:GITHUB_REPOSITORY
        } else {
            'amanthanvi/winghostty'
        }
    ),

    [string] $ArtifactRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)

if (-not $PSCmdlet.ShouldProcess("$Repository release $Tag", 'publish GitHub release and assets')) {
    return
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required to publish a release.'
}

$architectures = Get-WindowsPackageArchitectures
$artifactDirectories = @{}
foreach ($architecture in $architectures) {
    $artifactDirectories[$architecture] = Join-Path $ArtifactRoot "winghostty-$Version-windows-$architecture"
}
$artifactDirectoryX64 = $artifactDirectories['x64']
$legacyChecksumsPath = Join-Path $artifactDirectoryX64 (
    New-WindowsPackageArtifactName `
        -Version $Version `
        -Architecture x64 `
        -Kind legacy-checksums
)
Copy-Item `
    -LiteralPath (Join-Path $artifactDirectoryX64 (
        New-WindowsPackageArtifactName `
            -Version $Version `
            -Architecture x64 `
            -Kind checksums
    )) `
    -Destination $legacyChecksumsPath `
    -Force

$assets = @()
foreach ($architecture in $architectures) {
    $artifactDirectory = $artifactDirectories[$architecture]
    $assets += @(
        (Join-Path $artifactDirectory (New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind setup)),
        (Join-Path $artifactDirectory (New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind portable)),
        (Join-Path $artifactDirectory (New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind checksums))
    )
}
$assets += @(
    $legacyChecksumsPath,
    (Join-Path $artifactDirectoryX64 'winghostty-icon.svg')
)
$notesPrefix = @"
Compatibility line: Ghostty $VersionLine
Base upstream release: $UpstreamBaseVersion
Versioning: major.minor follow the Ghostty upstream line; patch is the winghostty release number on that line.
"@

& gh release view $Tag --repo $Repository *> $null
if ($LASTEXITCODE -ne 0) {
    $extra = @()
    if ($Prerelease -eq 'true') {
        $extra += '--prerelease'
    }
    & gh release create $Tag --repo $Repository --title $Title --generate-notes --notes $notesPrefix @extra @assets
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create GitHub release $Tag."
    }
} else {
    & gh release edit $Tag --repo $Repository --title $Title
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to edit GitHub release $Tag."
    }
    & gh release upload $Tag --repo $Repository @assets --clobber
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload assets for GitHub release $Tag."
    }
}
