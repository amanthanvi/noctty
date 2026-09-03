& (Join-Path $root 'Test-WindowsX64Baseline.ps1')

$reviewedArtifactDigests = @{
    # Reviewed in full for issue #133 named layouts and re-reviewed for issue
    # #131 scrollback-content restore. PR branch commits are intentionally
    # squashed and deleted, so pin this digest independently of the manifest's
    # durable base commit rather than disabling verification when an
    # intermediate source commit becomes unreachable.
    'src/apprt/win32_session_state.zig' =
        '591abc7a724cfc076f97a4a27d5368bbdcd5d6915942a711cc5de2c12959a0d5'

    # Reviewed in full after the Noctty rebrand while retaining the cleanup's
    # redirected-text CLI sibling pinned to the staged portable executable.
    # This combined artifact intentionally differs from origin/main; its exact
    # SHA remains fail-closed tamper evidence, taken over the LF-canonical
    # bytes that .gitattributes now guarantees on every checkout.
    'test/windows/package-portable-cli.ps1' =
        'edc0919e5e2951aba80f461be21cf8ba19911810454af00e6508c6c6af0b6f2b'
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
