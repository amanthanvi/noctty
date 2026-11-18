# Read-only guard used before candidate checkout, and by both entry points.
. (Join-Path $PSScriptRoot 'release-manifest.ps1')
. (Join-Path $PSScriptRoot 'release-evidence.ps1')
function Get-IncompleteReleaseRecovery {
    param([string] $Repository, [string] $Tag)
    "Manual recovery (after inspecting the incomplete release): gh release delete $Tag --repo $Repository --cleanup-tag --yes ; then gh workflow run release.yml --repo $Repository --ref main -f mode=build -f version=$($Tag.Substring(1)) -f prerelease=true . This rebuild is a new candidate and requires renewed evidence and soak."
}
function Assert-ReleasePublicationState {
    param($Release, [string] $Repository, [string] $Tag)
    $recovery = Get-IncompleteReleaseRecovery -Repository $Repository -Tag $Tag
    if ($Release.draft) { throw "DraftRelease: leftover draft $Tag cannot be promoted. $recovery" }
    if ($Release.tag_name -cne $Tag) { throw 'ReleaseIdentityMismatch: release tag differs.' }
    $expected = @(Get-ReleasePayloadPaths -ArtifactRoot '.' -Version $Tag.Substring(1) | ForEach-Object { [IO.Path]::GetFileName($_) }) + 'release-manifest.json'
    $actual = @($Release.assets | ForEach-Object { $_.name })
    if (@($expected | Where-Object { $_ -cnotin $actual }).Count) {
        throw "IncompleteRelease: missing manifest or payload assets for $Tag. $recovery"
    }
}
