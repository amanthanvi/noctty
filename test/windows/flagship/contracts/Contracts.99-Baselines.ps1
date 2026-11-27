& (Join-Path $root 'Test-WindowsX64Baseline.ps1')

$reviewedArtifactDigests = @{
    # Reviewed in full for issue #133 named layouts, re-reviewed for issue
    # #131 scrollback-content restore, and again for the issue #123 paste-path
    # audit, which adds load-time pane-text rejection without changing the
    # on-disk schema, and for PKG-44, which skips unknown fields within the
    # schema version and reports a newer schema_version as NewerSchema instead
    # of rejecting it, and for FULLSCREEN-SESSION-01, which adds fullscreen
    # with an optional fullscreen_maximized return flag within schema v1,
    # and for the Zig 0.17.1 parse pass (1B.4), which rewrites one test's
    # removed `**` as a typed @splat and leaves the schema unchanged, and
    # for the Zig 0.17.1 compile pass (1B.5), which wraps the parser's fuzz
    # test in 0.17's Smith interface (the same bytes outside fuzz mode) and
    # leaves the parser and the schema unchanged.
    # PR branch commits are intentionally squashed and
    # deleted, so pin this digest independently of the manifest's durable base
    # commit rather than disabling verification when an intermediate source
    # commit becomes unreachable.
    'src/apprt/win32_session_state.zig' =
        '2599d4fe5a5b7c892dc4806bfeedf406612a45a0ad78a54a452916765d17f33a'

    # Reviewed in full after the Noctty rebrand and for PKG-35's packaged DLL
    # load/allocator smoke, retaining the staged portable CLI siblings, and
    # again when that smoke became the ghostty-vt.dll placeholder check
    # (load fails with ERROR_DLL_INIT_FAILED, no exports, its FileDescription),
    # and again when v1.4.100 dropped that check with the placeholder.
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
