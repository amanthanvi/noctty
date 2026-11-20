# Read-only guard used before candidate checkout, and by both entry points.
. (Join-Path $PSScriptRoot 'release-manifest.ps1')
. (Join-Path $PSScriptRoot 'release-evidence.ps1')
function Get-ReleaseByTag {
    param([string] $Repository, [string] $Tag, [switch] $AllowMissing, [switch] $AllowIdNotFound)
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
    $release = Invoke-ReleaseGhJson -Arguments @('api', "repos/$Repository/releases/$id") -AllowNotFound:$AllowIdNotFound -RequireReleaseObject
    if ($null -eq $release) { return $null }
    if ([string]$release.id -cne $id -or -not [string]::Equals($release.tag_name, $Tag, [StringComparison]::Ordinal)) { throw 'ReleaseIdentityMismatch: release changed during discovery.' }
    return $release
}
function Get-IncompleteReleaseRecovery {
    param([string] $Repository, [string] $Tag)
    "Manual recovery: first list EVERY release with tag $Tag, including drafts, and stop unless the sole match is this incomplete draft. Read its ID again immediately before deleting ONLY that draft by ID (gh api --method DELETE repos/$Repository/releases/<draft-id>). Never use --cleanup-tag. A tagless draft needs no tag deletion. Preserve any existing tag until an independently audited tag recovery; see PACKAGING.md. Then use gh workflow run release.yml --repo $Repository --ref main -f mode=build -f version=$($Tag.Substring(1)) -f prerelease=true with renewed evidence and soak."
}
function Assert-ReleasePublicationState {
    param($Release, [string] $Repository, [string] $Tag)
    $recovery = Get-IncompleteReleaseRecovery -Repository $Repository -Tag $Tag
    if ($Release.draft) { throw "DraftRelease: leftover draft $Tag cannot be promoted. $recovery" }
    if ($Release.tag_name -cne $Tag) { throw 'ReleaseIdentityMismatch: release tag differs.' }
    $expected = @(Get-ReleasePayloadPaths -ArtifactRoot '.' -Version $Tag.Substring(1) | ForEach-Object { [IO.Path]::GetFileName($_) })
    $actual = @($Release.assets | ForEach-Object { $_.name })
    if ('release-manifest.json' -cnotin $actual) {
        throw 'LegacyReleaseWithoutManifest: this published release has no promotion manifest. Preserve its release and tag. Use the verified manual Chocolatey workflow or an audited channel-specific recovery; do not rebuild or delete the published release.'
    }
    $expected += 'release-manifest.json'
    if (@($expected | Where-Object { $_ -cnotin $actual }).Count) {
        throw "IncompletePublishedRelease: missing manifest or payload assets for $Tag. Preserve the published release and tag; inspect the original run and use audited channel-specific recovery. Automatic promotion is unavailable."
    }
}

function Assert-RemoteReleaseTag {
    param([string] $Repository, [string] $Tag, [string] $CandidateSha, [switch] $AllowMissing, [switch] $WaitForExistence)
    $attempts = if ($WaitForExistence) { 3 } else { 1 }
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $ref = Invoke-ReleaseGhJson -Arguments @('api', "repos/$Repository/git/ref/tags/$Tag") -AllowNotFound:($AllowMissing -or $WaitForExistence) -RequireReleaseObject
        if ($null -ne $ref) { break }
        if ($AllowMissing) { return }
        if ($attempt -lt $attempts) { Start-Sleep -Seconds $attempt }
    }
    if ($null -eq $ref) { throw 'ReleaseTagUnconfirmed: published tag is still missing after 3 reads; preserve release and inspect it.' }
    $object = $ref.object
    for ($depth = 0; $object.type -ceq 'tag' -and $depth -lt 8; $depth++) {
        $object = (Invoke-ReleaseGhJson @('api', "repos/$Repository/git/tags/$($object.sha)")).object
    }
    if ($object.type -cne 'commit' -or -not [string]::Equals($object.sha, $CandidateSha, [StringComparison]::Ordinal)) {
        throw 'TagIdentityMismatch: remote tag differs from candidate input.'
    }
}
function Get-CreatedReleaseDraft {
    param(
        [string] $Repository, [string] $Tag, [string] $CandidateSha, [bool] $Prerelease,
        [Parameter(Mandatory)] [string] $CreateMarker
    )
    # Create is issued once. A failed response may have created the draft;
    # discover it by list/ID and authenticate it before uploading any bytes.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        # A list hit can precede visibility by ID. Only post-create discovery
        # treats that 404 as transient; preflight still refuses the unknown state.
        $draft = Get-ReleaseByTag -Repository $Repository -Tag $Tag -AllowMissing -AllowIdNotFound
        if ($null -ne $draft) {
            $markerLines = @(([string]$draft.body -split '\r?\n') | Where-Object {
                [string]::Equals($_, $CreateMarker, [StringComparison]::Ordinal)
            })
            if ($markerLines.Count -ne 1) {
                throw 'ReleaseDraftOwnershipUnconfirmed: the draft does not carry this create attempt marker. Preserve it and inspect its ID before retrying.'
            }
            if (-not $draft.draft -or $draft.prerelease -ne $Prerelease -or
                @($draft.assets).Count -ne 0) { throw "ReleaseIdentityMismatch: created draft flags/assets differ (draft=$($draft.draft), prerelease=$($draft.prerelease), expected=$Prerelease, assets=$(@($draft.assets).Count)); preserve it for inspection." }
            if (-not [string]::Equals($draft.target_commitish, $CandidateSha, [StringComparison]::Ordinal)) {
                # GitHub ignores target_commitish when the tag already exists.
                # In that case only its peeled ref authenticates the candidate.
                try { Assert-RemoteReleaseTag -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha }
                catch { throw 'ReleaseIdentityMismatch: created draft target cannot be authenticated; preserve it for inspection.' }
            }
            return $draft
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
    }
    throw 'ReleaseCreateUnconfirmed: draft unavailable after 3 discovery reads; inspect the run before retrying. Never delete a published release.'
}
function Confirm-ReleasePublication {
    param([string] $Repository, [string] $Tag, [string] $CandidateSha, [string] $ReleaseId, [bool] $Prerelease, [hashtable] $ManifestInputs)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $state = Invoke-ReleaseGhJson -Arguments @('api', "repos/$Repository/releases/$ReleaseId") -AllowNotFound
        if ($null -ne $state -and -not $state.draft -and $state.prerelease -eq $Prerelease) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
    }
    if ($null -eq $state -or $state.draft -or $state.prerelease -ne $Prerelease) {
        throw 'ReleasePublishUnconfirmed: publication flags did not converge after 3 reads; preserve the release and inspect its ID.'
    }
    if (-not [string]::Equals([string]$state.id, $ReleaseId, [StringComparison]::Ordinal)) { throw 'ReleaseIdentityMismatch: publication ID differs.' }
    Assert-ReleasePublicationState -Release $state -Repository $Repository -Tag $Tag
    [void](Assert-ReleaseManifest @ManifestInputs -Release $state)
    Assert-RemoteReleaseTag -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -WaitForExistence
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $latest = Invoke-ReleaseGhJson -Arguments @('api', "repos/$Repository/releases/latest") -AllowNotFound -RequireReleaseObject
        $isLatest = [string]::Equals([string]$latest.id, $ReleaseId, [StringComparison]::Ordinal)
        if ($isLatest -ne $Prerelease) { return $state }
        if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
    }
    throw 'ReleaseLatestUnconfirmed: latest state did not converge after 3 reads; preserve the release and inspect it.'
}
