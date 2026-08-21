& (Join-Path $root 'Test-WindowsX64Baseline.ps1')

$reviewedArtifactDigests = @{
    # Reviewed in full after the Noctty rebrand while retaining the cleanup's
    # redirected-text CLI sibling pinned to the staged portable executable.
    # This combined artifact intentionally differs from origin/main; its exact
    # SHA remains fail-closed tamper evidence.
    'test/windows/package-portable-cli.ps1' =
        '586de5a964938acf85be7729cf043de189fba841292597baa4db5c9dd3a54898'
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
