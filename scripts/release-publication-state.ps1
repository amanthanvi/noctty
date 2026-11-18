# Read-only guard used before candidate checkout, and by both entry points.
. (Join-Path $PSScriptRoot 'release-manifest.ps1')
. (Join-Path $PSScriptRoot 'release-evidence.ps1')
function Get-ReleaseByTag {
    param([string] $Repository, [string] $Tag, [switch] $AllowMissing)
    # REST tags returns published releases only. List releases includes drafts
    # with push access; unlike gh's first-match draft lookup, inspect every page
    # to refuse duplicate pending tags before any mutation.
    # https://docs.github.com/en/rest/releases/releases#list-releases
    # cli/cli v2.100.0 pkg/cmd/release/shared/fetch.go: FetchRelease/fetchDraftRelease
    $matches = @()
    for ($page = 1; $page -le 1000; $page++) {
        $releases = @(Invoke-ReleaseGhJson @('api', "repos/$Repository/releases?per_page=100&page=$page"))
        $matches += @($releases | Where-Object { [string]::Equals($_.tag_name, $Tag, [StringComparison]::Ordinal) })
        if ($releases.Count -lt 100) { break }
    }
    if ($page -gt 1000) { throw 'ReleaseLookupIncomplete: release listing exceeded the read limit.' }
    if ($matches.Count -gt 1) { throw 'AmbiguousReleaseTag: multiple releases/drafts have this tag; inspect their IDs without deleting a published release.' }
    if ($matches.Count -eq 0) {
        if ($AllowMissing) { return $null }
        throw 'ReleaseMissing: no visible release or draft; inspect the original run before starting a new accepted build.'
    }
    $id = [string]$matches[0].id
    if ($id -cnotmatch '\A[0-9]+\z') { throw 'ReleaseLookupIncomplete: release ID is missing.' }
    $release = Invoke-ReleaseGhJson @('api', "repos/$Repository/releases/$id")
    if ([string]$release.id -cne $id -or -not [string]::Equals($release.tag_name, $Tag, [StringComparison]::Ordinal)) { throw 'ReleaseIdentityMismatch: release changed during discovery.' }
    return $release
}
function Get-IncompleteReleaseRecovery {
    param([string] $Repository, [string] $Tag)
    "Manual recovery (only after confirming this is an incomplete draft; preserve every published release): gh release delete $Tag --repo $Repository --cleanup-tag --yes ; then gh workflow run release.yml --repo $Repository --ref main -f mode=build -f version=$($Tag.Substring(1)) -f prerelease=true . This rebuild is a new candidate and requires renewed evidence and soak."
}
function Assert-ReleasePublicationState {
    param($Release, [string] $Repository, [string] $Tag)
    $recovery = Get-IncompleteReleaseRecovery -Repository $Repository -Tag $Tag
    if ($Release.draft) { throw "DraftRelease: leftover draft $Tag cannot be promoted. $recovery" }
    if ($Release.tag_name -cne $Tag) { throw 'ReleaseIdentityMismatch: release tag differs.' }
    $expected = @(Get-ReleasePayloadPaths -ArtifactRoot '.' -Version $Tag.Substring(1) | ForEach-Object { [IO.Path]::GetFileName($_) })
    $actual = @($Release.assets | ForEach-Object { $_.name })
    if ('release-manifest.json' -cnotin $actual -and @($expected | Where-Object { $_ -cnotin $actual }).Count -eq 0) {
        throw 'LegacyReleaseWithoutManifest: this published release has no promotion manifest. Preserve its release and tag. Use the verified manual Chocolatey workflow or an audited channel-specific recovery; do not rebuild or delete the published release.'
    }
    $expected += 'release-manifest.json'
    if (@($expected | Where-Object { $_ -cnotin $actual }).Count) {
        throw "IncompletePublishedRelease: missing manifest or payload assets for $Tag. Preserve the published release and tag; inspect the original run and use audited channel-specific recovery. Automatic promotion is unavailable."
    }
}
