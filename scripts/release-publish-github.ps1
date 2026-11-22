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
            'amanthanvi/noctty'
        }
    ),

    [string] $ArtifactRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9a-f]{40}\z')]
    [string] $CandidateSha
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

# The writer finalizes SHA256SUMS.txt before hashing; never modify payload here.
. (Join-Path $PSScriptRoot 'release-publication-state.ps1')
$primary = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
$manifestPath = Join-Path $primary 'release-manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifestDigest = Get-FileSha256Lower $manifestPath
$assets = @(Get-ReleasePayloadPaths -ArtifactRoot $ArtifactRoot -Version $Version) + $manifestPath
$notesPrefix = @"
Compatibility line: Ghostty $VersionLine
Base upstream release: $UpstreamBaseVersion
Versioning: major.minor follow the Ghostty upstream line; patch is the noctty release number on that line.
"@

$existing = Get-ReleaseByTag -Repository $Repository -Tag $Tag -AllowMissing
if ($existing) {
    Assert-ReleasePublicationState -Release $existing -Repository $Repository -Tag $Tag
    throw "Release $Tag already exists. Use mode promote with its recorded manifest; a build must never replace published assets."
}
# GitHub ignores --target for an existing tag. Peel it before any mutation.
Assert-RemoteReleaseTag -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -AllowMissing
# Create an explicit draft, upload each immutable asset with bounded retries,
# verify the complete set, then publish. Cancellation leaves a named manual
# recovery path, never automatic deletion or replacement of unknown bytes.
$createMarker = "<!-- noctty-release-create:$([guid]::NewGuid().ToString('N')) -->"
$extra = @(if ($Prerelease -eq 'true') { '--prerelease' })
& gh release create $Tag --repo $Repository --target $CandidateSha --draft --title $Title --generate-notes --notes "$notesPrefix`n`n$createMarker`n" @extra
$createExit = $LASTEXITCODE
$created = Get-CreatedReleaseDraft -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -Prerelease ($Prerelease -eq 'true') -CreateMarker $createMarker
if ($createExit -ne 0) { Write-Host 'Release create response was lost; authenticated the draft by ID and create attempt marker.' }
$releaseId = [string]$created.id
foreach ($asset in $assets) {
    $name = [IO.Path]::GetFileName($asset)
    $hash = Get-FileSha256Lower $asset
    $size = (Get-Item -LiteralPath $asset).Length
    $uploaded = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & gh release upload $Tag --repo $Repository $asset
        $uploadExit = $LASTEXITCODE
        # Also reconcile a lost success response; never retry with replacement.
        $state = Invoke-ReleaseGhJson @('api', "repos/$Repository/releases/$releaseId")
        $remote = @($state.assets | Where-Object { $_.name -ceq $name })
        if ($remote.Count -eq 1) {
            if ($remote[0].digest -cne "sha256:$hash" -or $remote[0].size -ne $size) {
                throw "AssetDigestMismatch: existing upload $name differs; refusing replacement."
            }
            $uploaded = $true
            break
        }
        if ($uploadExit -eq 0) { throw "UploadStateUnknown: successful upload $name is missing from GitHub." }
        if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
    }
    if (-not $uploaded) {
        throw "IncompleteRelease: upload $name failed after 3 attempts. $(Get-IncompleteReleaseRecovery -Repository $Repository -Tag $Tag)"
    }
}
$assertInputs = @{
    Path = $manifestPath; ExpectedSha256 = $manifestDigest; ArtifactRoot = $ArtifactRoot
    DownloadDirectory = $primary; Tag = $Tag; CandidateSha = $CandidateSha
    TestRunId = [string]$manifest.testRunId; ReleaseRunId = [string]$manifest.releaseRunId
}
$state = Invoke-ReleaseGhJson @('api', "repos/$Repository/releases/$releaseId")
[void](Assert-ReleaseManifest @assertInputs -Release $state)
# A draft may still be tagless; reject a conflicting ref if one exists.
Assert-RemoteReleaseTag -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -AllowMissing
$publishFlags = if ($Prerelease -eq 'true') { @('--prerelease', '--latest=false') } else { @('--prerelease=false', '--latest') }
& gh release edit $Tag --repo $Repository --draft=false @publishFlags
$editExit = $LASTEXITCODE
[void](Confirm-ReleasePublication -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -ReleaseId $releaseId -Prerelease ($Prerelease -eq 'true') -ManifestInputs $assertInputs)
if ($editExit -ne 0) { Write-Host 'Publish response was lost; authenticated persisted publication state.' }
Write-Host 'Build publication: PASS (publication flags, tag, all uploaded bytes and GitHub digests match).'
