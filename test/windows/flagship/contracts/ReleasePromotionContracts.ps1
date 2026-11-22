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
        '          RELEASE_RUN_ID: ${{ github.run_id }}',
        '          RELEASE_MANIFEST_SHA256: ${{ steps.manifest.outputs.manifest_sha256 }}',
        "        if: steps.promote.outputs.publish_chocolatey == 'true' && vars.CHOCOLATEY_PUBLISH != 'off'"
    )) {
        if (@([regex]::Matches($Text, '(?m)^' + [regex]::Escape($line) + '\r?$')).Count -ne 1) { return $false }
    }
    $job = Get-YamlJobText -Content $Text -Name 'windows-promote' -Source 'promote workflow'
    if ($job -notmatch '(?m)^      attestations: read\r?$') { return $false }
    $manifest = Get-YamlStepBlock -Content $Text -Name 'Write release manifest and record digest' -Source 'build workflow'
    $publish = Get-YamlStepBlock -Content $Text -Name 'Publish GitHub Release' -Source 'build workflow'
    if ($manifest -notmatch 'release-write-manifest.ps1' -or $publish -match 'release-write-manifest.ps1' -or
        $Text.IndexOf('      - name: Write release manifest and record digest') -ge $Text.IndexOf('      - name: Publish GitHub Release')) { return $false }
    foreach ($channel in @('scoop','winget','chocolatey')) {
        if ($job -notmatch ('steps.promote.outputs.publish_' + $channel + ' == ''true''')) { return $false }
    }
    if ($Text.IndexOf('      - name: Refuse incomplete publication before candidate checkout') -ge $Text.IndexOf('      - name: Checkout candidate data')) { return $false }
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
    '      attestations: read',
    '          RELEASE_RUN_ID: ${{ github.run_id }}',
    '          RELEASE_MANIFEST_SHA256: ${{ steps.manifest.outputs.manifest_sha256 }}',
    "        if: steps.promote.outputs.publish_chocolatey == 'true' && vars.CHOCOLATEY_PUBLISH != 'off'"
)) {
    if (Test-ReleasePromotionWorkflow ($releaseWorkflowText.Replace($target, '# removed by contract control'))) { throw 'Promotion workflow accepted a missing requirement.' }
}
$testWorkflowText = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/test.yml') -Raw
foreach ($name in @('Upload portable smoke evidence')) {
    $step = Get-YamlStepBlock -Content $testWorkflowText -Name $name -Source 'Test workflow'
    if ($step -notmatch '(?m)^          retention-days: 90\r?$') { throw 'Promotion evidence must be retained for 90 days.' }
}
# No release requires an interactive run (the maintainer's decision, 2026-11-22): the Release workflow and promotion
# (release-promote.ps1 and the evidence check it calls) name neither the interactive composite job nor its artifact.
# The control adds the old lookup back to release.yml.
function Get-ReleaseInteractiveRequirements([System.Collections.IDictionary] $Files) {
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $Files.Keys) {
        foreach ($name in @('Windows 11 Interactive Composite', 'flagship-interactive-win11')) {
            if ($Files[$path].IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $found.Add("$path names $name") }
        }
    }
    return , $found.ToArray()
}
$releaseNoInteractiveFiles = [ordered]@{
    '.github/workflows/release.yml' = $releaseWorkflowText
    'scripts/release-promote.ps1' = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-promote.ps1') -Raw
    'scripts/release-evidence.ps1' = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-evidence.ps1') -Raw
}
$releaseInteractiveFound = Get-ReleaseInteractiveRequirements $releaseNoInteractiveFiles
if ($releaseInteractiveFound.Count -ne 0) { throw "A release must require no interactive run: $($releaseInteractiveFound -join '; ')." }
$releaseInteractiveControl = [ordered]@{}
foreach ($path in $releaseNoInteractiveFiles.Keys) { $releaseInteractiveControl[$path] = $releaseNoInteractiveFiles[$path] }
$releaseInteractiveControl['.github/workflows/release.yml'] += "`n            `$interactive = @(`$jobs.jobs | Where-Object { `$_.name -eq 'Windows 11 Interactive Composite' -and `$_.conclusion -eq 'success' })`n"
if ((Get-ReleaseInteractiveRequirements $releaseInteractiveControl).Count -eq 0) { throw 'The no-interactive release check accepted the interactive lookup added back to release.yml.' }
$promoteText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-promote.ps1') -Raw
if ($promoteText -match '(?m)^\s*& gh release (upload|create)\b|--clobber' -or
    $promoteText -notmatch '(?m)^\s*& gh release edit \$Tag --repo \$Repository --prerelease=false --latest\r?$' -or
    $promoteText -notmatch 'verify-published-release.ps1.*?-CandidateDirectory \$CandidateDirectory -ManifestSha256 \$ManifestSha256') {
    throw 'Promotion must edit without uploading and verify with candidate data and the summary digest.'
}
$publisherResumeOutput = @(& (Join-Path $repoRoot 'test/windows/release-publisher-resume.ps1') 6>&1)
if ($LASTEXITCODE -ne 0 -or @($publisherResumeOutput | Where-Object {
    [string]$_ -ceq 'Publisher resume: PASS (25 WinGet cases and unchanged Scoop with relative metadata).'
}).Count -ne 1) { throw 'Publisher resume controls did not all complete.' }
$publisherResumeOutput | ForEach-Object { Write-Host $_ }

$manifestText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-manifest.ps1') -Raw
$publisherText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-publish-github.ps1') -Raw
$verifierText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/verify-published-release.ps1') -Raw
foreach ($text in @($publisherText,$verifierText)) {
    if ($text -notmatch 'Get-ReleasePayloadPaths' -or $text -notmatch 'Assert-ReleaseManifest') { throw 'Writer, publisher and verifier must use one payload definition and assertion.' }
}
if ($publisherText -match 'Copy-Item' -or $manifestText.IndexOf('Copy-Item') -ge $manifestText.IndexOf('payload = @(')) { throw 'Checksum alias must be finalized before manifest hashing.' }
. (Join-Path $repoRoot 'scripts/release-manifest.ps1')
foreach ($spec in @(@{Version='1.3.123';Count=8;Symbols=0}, @{Version='1.3.124';Count=10;Symbols=0}, @{Version='1.3.133';Count=12;Symbols=2}, @{Version='1.4.100';Count=12;Symbols=2})) {
    $paths = @(Get-ReleasePayloadPaths -ArtifactRoot '.' -Version $spec.Version)
    if ($paths.Count -ne $spec.Count -or @($paths | Where-Object { $_ -like '*-symbols.zip' }).Count -ne $spec.Symbols) { throw 'Shared release payload lost its historical manifest/symbols boundaries.' }
}
$checks = Get-YamlJobText -Content $testWorkflowText -Name checks -Source 'Test workflow'
if ($checks -notmatch 'Cache digest-verified release fixture inputs' -or $checks -notmatch 'NOCTTY_RELEASE_FIXTURE_ASSETS:') { throw 'Checks must cache the verified real fixture assets.' }

$channelOutput = @(& (Join-Path $repoRoot 'test/windows/release-channel-switches.ps1') 6>&1)
if (@($channelOutput | Where-Object { [string]$_ -ceq 'Release channel switches: PASS (4 case variants and enabled-missing twin).' }).Count -ne 1) { throw 'Build/direct channel switch controls did not complete.' }
$channelOutput | ForEach-Object { Write-Host $_ }
$publicationText = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-publication-state.ps1') -Raw
if ($publisherText -match 'releases/tags/' -or $publicationText -match 'releases/tags/' -or $publicationText -notmatch 'releases/\$id') { throw 'Draft lookup must discover and read by release ID.' }
$generatorRunner = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/release-run-generator.ps1') -Raw
if ($promoteText -match 'generatorCredentials' -or $promoteText -notmatch 'Invoke-ReleaseGenerator' -or
    $generatorRunner -notmatch 'ProcessStartInfo' -or $generatorRunner -notmatch 'CreateNoWindow = \$true' -or
    $generatorRunner -notmatch 'Environment.Clear' -or $generatorRunner -match 'SetEnvironmentVariable') { throw 'Candidate generator must be isolated from parent scope and token environment.' }

$outcomeOutput=@(& (Join-Path $repoRoot 'test/windows/release-publisher-outcomes.ps1') 6>&1)
if (@($outcomeOutput | Where-Object { [string]$_ -ceq 'Publisher outcomes: PASS (3 missing-credential paths).' }).Count -ne 1) { throw 'Publishers must distinguish missing credentials from completion.' }
$outcomeOutput | ForEach-Object { Write-Host $_ }
foreach($channel in @('Scoop','WinGet','Chocolatey')) {
    $slug=$channel.ToLowerInvariant()
    if ($releaseWorkflowText -notmatch ([regex]::Escape("$channel publication outcome:")) -or
        $releaseWorkflowText -notmatch ([regex]::Escape("PUBLICATION_OUTCOME: " + '${{ steps.' + $slug + '.outputs.outcome }}'))) { throw 'The publishing attempt must persist channel outcomes in the jobs API.' }
}

$generatorOutput=@(& (Join-Path $repoRoot 'test/windows/release-generator.ps1') 6>&1)
if (@($generatorOutput | Where-Object { [string]$_ -ceq 'Generator isolation: PASS (allowlist, parent scope, outer WhatIf, typed parameters, bounded redacted failure reason).' }).Count -ne 1) { throw 'Generator allowlist/diagnostics controls did not complete.' }
$generatorOutput | ForEach-Object { Write-Host $_ }
$cleanupOutput = @(& (Join-Path $repoRoot 'test/windows/release-fixture-cleanup.ps1') 6>&1)
if (@($cleanupOutput | Where-Object { [string]$_ -ceq 'Release fixture cleanup: PASS (temp fallback, root override, literal brackets, default assets and failure evidence under outer WhatIf).' }).Count -ne 1) { throw 'Release fixture directory controls did not complete.' }
$cleanupOutput | ForEach-Object { Write-Host $_ }
$buildVerificationOutput=@(& (Join-Path $repoRoot 'test/windows/release-build-verification.ps1') 6>&1)
if (@($buildVerificationOutput | Where-Object { [string]$_ -ceq 'Build verification results: PASS (stale native status, failed copy, failed verifier).' }).Count -ne 1) { throw 'Build verification must consume explicit results.' }
$buildVerificationOutput | ForEach-Object { Write-Host $_ }
