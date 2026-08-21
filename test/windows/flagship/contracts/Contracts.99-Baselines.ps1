& (Join-Path $root 'Test-WindowsX64Baseline.ps1')

$reviewedArtifactDigests = @{
    # Reviewed in full when the redirected-text CLI sibling was pinned to the
    # staged portable executable. This artifact intentionally differs from the
    # older origin/main snapshot; its exact SHA remains fail-closed tamper evidence.
    'test/windows/package-portable-cli.ps1' =
        'f1aad78377e3ce303e9a2bc9a4d77ca947cf5332741d4c881eb215cacca3162e'
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
