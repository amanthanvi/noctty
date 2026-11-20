function Resolve-ArtifactMetadataPath {
    param(
        [Parameter(Mandatory)] [string] $ArtifactDirectory,
        [Parameter(Mandatory)] [string] $Path,
        [int] $SchemaVersion = 2
    )
    if ($SchemaVersion -ge 2 -and [IO.Path]::IsPathRooted($Path)) {
        throw 'Package-manager metadata must use artifact-relative paths.'
    }
    # Pre-repair local metadata remains readable by the moderation helpers.
    [IO.Path]::GetFullPath($Path, [IO.Path]::GetFullPath($ArtifactDirectory))
}
