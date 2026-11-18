# Invoked by Contracts.80; the full workflow digest protects the envelope,
# and these parseable controls prove the two roles and mode split are required.
function Test-ReleasePromotionWorkflow {
    param([string] $Text)
    foreach ($line in @(
        "    if: github.event_name == 'push' || inputs.mode != 'promote'",
        "    if: github.event_name == 'workflow_dispatch' && inputs.mode == 'promote'",
        '          ref: main', '          ref: ${{ inputs.tag }}', '          path: candidate',
        '          RELEASE_CANDIDATE_SHA: ${{ github.sha }}',
        '          RELEASE_TEST_RUN_ID: ${{ steps.evidence.outputs.test_run_id }}',
        '          RELEASE_EVIDENCE_RUN_ID: ${{ steps.evidence.outputs.evidence_run_id }}',
        '          RELEASE_RUN_ID: ${{ github.run_id }}',
        '          RELEASE_MANIFEST_SHA256: ${{ steps.publish.outputs.manifest_sha256 }}',
        "        if: vars.CHOCOLATEY_PUBLISH != 'off'"
    )) {
        if (@([regex]::Matches($Text, '(?m)^' + [regex]::Escape($line) + '\r?$')).Count -ne 1) { return $false }
    }
    $main = Get-YamlStepBlock -Content $Text -Name 'Checkout orchestration main' -Source 'promote workflow'
    $candidate = Get-YamlStepBlock -Content $Text -Name 'Checkout candidate data' -Source 'promote workflow'
    foreach ($step in @($main, $candidate)) {
        if ($step -notmatch '(?m)^          fetch-depth: 0\r?$' -or $step -notmatch '(?m)^          persist-credentials: false\r?$') { return $false }
    }
    if ($main -match '(?m)^          path:' -or $candidate -notmatch '(?m)^          path: candidate\r?$') { return $false }
    $promotion = Get-YamlStepBlock -Content $Text -Name 'Verify and promote recorded candidate' -Source 'promote workflow'
    if ($promotion -notmatch '-CandidateDirectory \(Join-Path \$PWD ''candidate''\)' -or $promotion -notmatch '-ManifestSha256 \$env:PROMOTE_MANIFEST_SHA256') { return $false }
    $scoop = $Text.IndexOf('      - name: Publish promoted Scoop manifest', [StringComparison]::Ordinal)
    $winget = $Text.IndexOf('      - name: Submit promoted WinGet manifest update', [StringComparison]::Ordinal)
    $choco = $Text.IndexOf('      - name: Publish promoted Chocolatey package', [StringComparison]::Ordinal)
    if ($scoop -lt 0 -or $winget -le $scoop -or $choco -le $winget) { return $false }
    foreach ($name in @('Publish promoted Scoop manifest', 'Submit promoted WinGet manifest update', 'Publish promoted Chocolatey package')) {
        $step = Get-YamlStepBlock -Content $Text -Name $name -Source 'promote workflow'
        if ($step -notmatch '-ArtifactRoot \$env:RELEASE_ARTIFACT_ROOT' -or $step -match 'continue-on-error') { return $false }
    }
    return $true
}
if (-not (Test-ReleasePromotionWorkflow $releaseWorkflowText)) { throw 'Release promote mode must keep main orchestration, candidate data and ordered publishers.' }
foreach ($target in @(
    "    if: github.event_name == 'push' || inputs.mode != 'promote'",
    "    if: github.event_name == 'workflow_dispatch' && inputs.mode == 'promote'",
    '          ref: main', '          ref: ${{ inputs.tag }}', '          path: candidate',
    '          RELEASE_CANDIDATE_SHA: ${{ github.sha }}',
    '          RELEASE_TEST_RUN_ID: ${{ steps.evidence.outputs.test_run_id }}',
    '          RELEASE_EVIDENCE_RUN_ID: ${{ steps.evidence.outputs.evidence_run_id }}',
    '          RELEASE_RUN_ID: ${{ github.run_id }}',
    '          RELEASE_MANIFEST_SHA256: ${{ steps.publish.outputs.manifest_sha256 }}',
    "        if: vars.CHOCOLATEY_PUBLISH != 'off'"
)) {
    if (Test-ReleasePromotionWorkflow ($releaseWorkflowText.Replace($target, '# removed by contract control'))) { throw 'Promotion workflow accepted a missing requirement.' }
}
$testWorkflowText = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/test.yml') -Raw
foreach ($name in @('Upload portable smoke evidence', 'Upload interactive evidence')) {
    $step = Get-YamlStepBlock -Content $testWorkflowText -Name $name -Source 'Test workflow'
    if ($step -notmatch '(?m)^          retention-days: 90\r?$') { throw 'Promotion evidence must be retained for 90 days.' }
}
$promoteText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-promote.ps1') -Raw
if ($promoteText -match '(?m)^\s*& gh release (upload|create)\b|--clobber' -or
    $promoteText -notmatch '(?m)^\s*& gh release edit \$Tag --repo \$Repository --prerelease=false --latest\r?$' -or
    $promoteText -notmatch 'verify-published-release.ps1.*?-CandidateDirectory \$CandidateDirectory -ManifestSha256 \$ManifestSha256') {
    throw 'Promotion must edit without uploading and verify with candidate data and the summary digest.'
}
$publisherResumeOutput = @(& (Join-Path $repoRoot 'test/windows/release-publisher-resume.ps1') 6>&1)
if ($LASTEXITCODE -ne 0 -or @($publisherResumeOutput | Where-Object {
    [string]$_ -ceq 'Publisher resume: PASS (9 WinGet cases and unchanged Scoop with relative metadata).'
}).Count -ne 1) { throw 'Publisher resume controls did not all complete.' }
$publisherResumeOutput | ForEach-Object { Write-Host $_ }
