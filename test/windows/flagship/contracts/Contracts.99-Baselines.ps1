& (Join-Path $root 'Test-WindowsX64Baseline.ps1')

$reviewedArtifactDigests = @{
    # Reviewed in full for issue #133 named layouts, re-reviewed for issue
    # #131 scrollback-content restore, and again for the issue #123 paste-path
    # audit, which adds load-time pane-text rejection without changing the
    # on-disk schema, and for PKG-44, which skips unknown fields within the
    # schema version and reports a newer schema_version as NewerSchema instead
    # of rejecting it. PR branch commits are intentionally squashed and
    # deleted, so pin this digest independently of the manifest's durable base
    # commit rather than disabling verification when an intermediate source
    # commit becomes unreachable.
    'src/apprt/win32_session_state.zig' =
        '58ca692b407a1c107da2c819d5975a7aaf23395a176f779896e88fdf36a2256f'

    # Reviewed in full after the Noctty rebrand and for PKG-35's packaged DLL
    # load/allocator smoke, retaining the staged portable CLI siblings.
    # This combined artifact intentionally differs from origin/main; its exact
    # SHA remains fail-closed tamper evidence, taken over the LF-canonical
    # bytes that .gitattributes now guarantees on every checkout.
    'test/windows/package-portable-cli.ps1' =
        'e835bc487ce36413b95dd1eaea79b96b98a125547e3fc1297dce298d55448ff4'
}
foreach ($baselinePath in Get-ChildItem -LiteralPath (Join-Path $root 'baselines') -Filter '*.json') {
    Assert-JsonDocument `
        -Path $baselinePath.FullName `
        -SchemaPath (Join-Path $root 'baseline-manifest.schema.json')
    $baseline = Get-Content -LiteralPath $baselinePath.FullName -Raw | ConvertFrom-Json
    & git -C $repoRoot cat-file -e "$($baseline.git_commit)^{commit}" 2>$null
    $baselineCommitAvailable = $LASTEXITCODE -eq 0
    if (-not $baselineCommitAvailable) {
        Write-Warning "Skipping frozen baseline git diff because commit is unavailable in this checkout: $($baseline.git_commit)"
    }
    foreach ($artifact in $baseline.artifacts) {
        $artifactPath = Join-Path $repoRoot $artifact.path
        $reviewedDigest = $reviewedArtifactDigests[[string]$artifact.path]
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Frozen baseline artifact is missing: $($artifact.path)"
        }
        if ($baselineCommitAvailable -and [string]::IsNullOrWhiteSpace($reviewedDigest)) {
            & git -C $repoRoot diff --quiet $baseline.git_commit -- $artifact.path
            if ($LASTEXITCODE -ne 0) {
                throw "Frozen baseline artifact drifted from $($baseline.git_commit): $($artifact.path)"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($reviewedDigest) -and
            $artifact.sha256 -cne $reviewedDigest) {
            throw "Reviewed baseline manifest digest drifted: $($artifact.path)"
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = if ([string]::IsNullOrWhiteSpace($reviewedDigest)) {
            [string]$artifact.sha256
        } else {
            $reviewedDigest
        }
        if ($actualHash -cne $expectedHash) {
            throw "Frozen baseline hash mismatch: $($artifact.path)"
        }
    }
}
