[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('\Av[0-9]+\.[0-9]+\.[0-9]+\z')] [string] $Tag,
    [ValidatePattern('\A[0-9a-f]{40}\z')] [string] $CandidateSha,
    [ValidatePattern('\A[0-9]+\z')] [string] $TestRunId,
    [ValidatePattern('\A[0-9]+\z')] [string] $ReleaseRunId,
    [ValidatePattern('\A[0-9a-f]{64}\z')] [string] $ManifestSha256,
    [string] $CandidateDirectory,
    [string] $WorkDirectory,
    [ValidateSet('historical')] [string] $Fixture,
    # The only production target. Fixtures shadow gh, never change this repo.
    [ValidateSet('amanthanvi/noctty')] [string] $Repository = 'amanthanvi/noctty'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-manifest.ps1')
. (Join-Path $PSScriptRoot 'release-evidence.ps1')
. (Join-Path $PSScriptRoot 'release-publication-state.ps1')
. (Join-Path $PSScriptRoot 'release-package-manager-preflight.ps1')
. (Join-Path $PSScriptRoot 'release-run-generator.ps1')
$repoRoot = Get-RepoRoot
$fixtureRun = $null
if ($Fixture -eq 'historical') {
    $Tag = 'v1.3.136'
    $CandidateSha = 'e629842e9c4ddef133ab4d4ad27d37e0e9718e09'
    $TestRunId = '42344250161'
    $ReleaseRunId = '42346135091'
    Write-Host 'Historical fixture: all mutations disabled; old absolute-path metadata comparison is skipped.'
}
foreach ($field in @('Tag', 'CandidateSha', 'TestRunId', 'ReleaseRunId')) {
    if (-not (Get-Variable $field -ValueOnly)) { throw "Required promote input missing: $field." }
}
if (-not $Fixture -and -not $ManifestSha256) { throw 'Required promote input missing: ManifestSha256.' }
$release = Get-ReleaseByTag -Repository $Repository -Tag $Tag
if (-not $Fixture) { Assert-ReleasePublicationState -Release $release -Repository $Repository -Tag $Tag }
if ($Fixture) {
    . (Join-Path $PSScriptRoot 'release-fixture-directory.ps1')
    $fixtureRun = New-ReleaseFixtureDirectory -ParentDirectory $WorkDirectory
    $WorkDirectory = $fixtureRun
} else {
    if (-not $WorkDirectory) { $WorkDirectory = Join-Path $repoRoot ('dist/promote-' + [guid]::NewGuid().ToString('N')) }
    $WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
    if ((Test-Path -LiteralPath $WorkDirectory) -and @(Get-ChildItem -LiteralPath $WorkDirectory -Force).Count) {
        throw 'Promote work directory must be fresh and empty.'
    }
    [void][IO.Directory]::CreateDirectory($WorkDirectory)
}
try {
if (-not $CandidateDirectory) {
    if (-not $Fixture) { throw 'CandidateDirectory must name the second checkout.' }
    $CandidateDirectory = Join-Path $WorkDirectory 'candidate'
    & git clone --shared --no-checkout --quiet $repoRoot $CandidateDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Historical candidate checkout failed.' }
    & git -C $CandidateDirectory checkout --detach --quiet $Tag
    if ($LASTEXITCODE -ne 0) { throw 'Historical candidate tag checkout failed.' }
}
$CandidateDirectory = [IO.Path]::GetFullPath($CandidateDirectory)
$primarySha = & git -C $repoRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot read orchestration revision.' }
$mainSha = & git -C $repoRoot rev-parse origin/main
if ($LASTEXITCODE -ne 0 -or (-not $Fixture -and $primarySha -cne $mainSha)) { throw 'Orchestration checkout must be origin/main head.' }
$tagSha = & git -C $CandidateDirectory rev-list -n 1 $Tag
if ($LASTEXITCODE -ne 0 -or $tagSha -cne $CandidateSha) { throw 'TagIdentityMismatch: peeled tag differs from candidate input.' }
$candidateHead = & git -C $CandidateDirectory rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $candidateHead -cne $CandidateSha) { throw 'TagIdentityMismatch: second checkout is not the candidate.' }
& git -C $repoRoot merge-base --is-ancestor $CandidateSha origin/main
if ($LASTEXITCODE -ne 0) { throw 'CandidateNotAncestor: candidate is not an ancestor of origin/main.' }
# API ref resolution independently checks a moved remote tag, including annotated tags.
Assert-RemoteReleaseTag -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha
$resume = -not $release.prerelease
$resumeFrom = Assert-ReleaseEvidence -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -TestRunId $TestRunId -ReleaseRunId $ReleaseRunId -WorkDirectory $WorkDirectory
# After a prerelease flip verification always runs, even if its build verified it.
if (-not $resume) { $resumeFrom = 0 }
$version = $Tag.Substring(1)
$download = Join-Path $WorkDirectory 'download'
[void][IO.Directory]::CreateDirectory($download)
& gh release download $Tag --repo $Repository --dir $download
if ($LASTEXITCODE -ne 0) { throw 'Release assets could not be downloaded.' }
$manifestPath = Join-Path $download 'release-manifest.json'
if ($Fixture) {
    # Only the historical fixture may synthesize a manifest. SHA256SUMS binds
    # the installers/archives; GitHub's digests bind all twelve payload assets.
    foreach ($checksums in Get-ChildItem -LiteralPath $download -Filter 'SHA256SUMS*.txt') {
        foreach ($line in Get-Content -LiteralPath $checksums.FullName) {
            if ($line -cnotmatch '\A([0-9a-f]{64}) \*([0-9A-Za-z._-]+)\z' -or
                (Get-FileSha256Lower (Join-Path $download $Matches[2])) -cne $Matches[1]) { throw 'Historical checksum mismatch.' }
        }
    }
    $historicalManifest = [ordered]@{
        schemaVersion = 1; tag = $Tag; version = $version; candidateSha = $CandidateSha
        testRunId = $TestRunId; releaseRunId = $ReleaseRunId
        payload = @($release.assets | ForEach-Object { Get-ReleaseFileRecord -Path (Join-Path $download $_.name) -Name $_.name })
    }
    [IO.File]::WriteAllText($manifestPath, ($historicalManifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $ManifestSha256 = Get-FileSha256Lower $manifestPath
}
$manifest = Assert-ReleaseManifest -Path $manifestPath -ExpectedSha256 $ManifestSha256 -Release $release -DownloadDirectory $download -Tag $Tag -CandidateSha $CandidateSha -TestRunId $TestRunId -ReleaseRunId $ReleaseRunId -Historical:([bool]$Fixture)
Write-Host "Assets: PASS ($(@($release.assets).Count) assets; manifest $ManifestSha256)."
$artifactRoot = Join-Path $WorkDirectory 'artifacts'
foreach ($architecture in (Get-WindowsPackageArchitectures)) {
    $directory = Join-Path $artifactRoot "noctty-$version-windows-$architecture"
    [void][IO.Directory]::CreateDirectory($directory)
    foreach ($file in Get-ChildItem -LiteralPath $download -File) {
        if ($file.Name -like "*-windows-$architecture-*" -or $file.Name -ceq "SHA256SUMS-windows-$architecture.txt" -or
            ($architecture -eq 'x64' -and $file.Name -in @('SHA256SUMS.txt', 'noctty-icon.svg', 'release-manifest.json'))) {
            Copy-Item -LiteralPath $file.FullName -Destination $directory -WhatIf:$false
        }
    }
}
$primary = Join-Path $artifactRoot "noctty-$version-windows-x64"
if (-not $Fixture) {
    $generator = Join-Path $CandidateDirectory 'scripts/package-package-managers.ps1'
    $recorded = [string]$manifest.packageManagers.generatorBlob
    $found = & git -C $CandidateDirectory rev-parse "${CandidateSha}:scripts/package-package-managers.ps1"
    if ($LASTEXITCODE -ne 0) { $found = '<missing>' }
    $disk = if (Test-Path -LiteralPath $generator -PathType Leaf) { & git -C $CandidateDirectory hash-object scripts/package-package-managers.ps1 } else { '<missing>' }
    if ($recorded -cnotmatch '\A[0-9a-f]{40}\z' -or $found -cne $recorded -or $disk -cne $recorded) {
        throw "package-manager generator differs from the prerelease: $recorded != $found (working file $disk)"
    }
    $metadata = Get-Content -LiteralPath (Join-Path $CandidateDirectory 'dist/windows/release-metadata.json') -Raw | ConvertFrom-Json
    Invoke-ReleaseGenerator -Generator $generator -Parameters @{
        Version=$version; Tag=$Tag; Repo=$Repository; Architectures=@('x64','arm64'); ArtifactBase=$artifactRoot
        UpstreamBaseVersion=$metadata.upstreamBaseVersion; FirstForkPatch=$metadata.firstForkPatch
    }
    Assert-PackageManagerFiles -Manifest $manifest -PrimaryDirectory $primary
    & (Join-Path $PSScriptRoot 'check-release-copy.ps1') -ExpectedVersion $version
    if ($LASTEXITCODE -ne 0) { throw 'Stable release copy check failed.' }
} else {
    Write-Host 'Historical fixture: current-main copy checks do not apply to a superseded release; metadata hashes are unavailable.'
    # Chocolatey reads metadata before ShouldProcess. Generate local metadata
    # with the repaired orchestration writer solely for its WhatIf invocation.
    Invoke-ReleaseGenerator -Generator (Join-Path $PSScriptRoot 'package-package-managers.ps1') -Parameters @{ Version=$version; Architectures=@('x64','arm64'); ArtifactBase=$artifactRoot }
}
if ($resume) {
    Write-Host 'Resume: verified identical already-stable release; skipping release edit.'
}
$channels = if (-not $Fixture) { Assert-PromotionPackageManagers } else { @{ SCOOP=$false; WINGET=$false; CHOCOLATEY=$false } }
if (-not $resume -and -not $Fixture -and $PSCmdlet.ShouldProcess($Tag, 'promote verified release to stable and latest')) {
    Assert-RemoteReleaseTag -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha
    & gh release edit $Tag --repo $Repository --prerelease=false --latest
    $flipExit = $LASTEXITCODE
    $confirmation = @{
        Path=$manifestPath; ExpectedSha256=$ManifestSha256; DownloadDirectory=$download
        Tag=$Tag; CandidateSha=$CandidateSha; TestRunId=$TestRunId; ReleaseRunId=$ReleaseRunId
    }
    [void](Confirm-ReleasePublication -Repository $Repository -Tag $Tag -CandidateSha $CandidateSha -ReleaseId ([string]$release.id) -Prerelease $false -ManifestInputs $confirmation)
    if ($flipExit -ne 0) { Write-Host 'Promote response was lost; authenticated the completed stable flip.' }
} elseif (-not $resume) { Write-Host 'Read-only rehearsal: release edit disabled.' }
if (-not $Fixture -and -not $WhatIfPreference -and $resumeFrom -eq 0) {
    & (Join-Path $PSScriptRoot 'check-release-copy.ps1') -ExpectedVersion $version -CheckRemoteLatest
    if ($LASTEXITCODE -ne 0) { throw 'Remote latest copy check failed.' }
    $verification = & (Join-Path $PSScriptRoot 'verify-published-release.ps1') -Version $version -CandidateDirectory $CandidateDirectory -ManifestSha256 $ManifestSha256 -PassThru
    if ($verification.Verified -ne $true) { throw 'Published release verification failed.' }
}
if ($Fixture) {
    & (Join-Path $PSScriptRoot 'release-publish-scoop.ps1') -Version $version -ArtifactRoot $artifactRoot -RunnerTemp $WorkDirectory -WhatIf
    & (Join-Path $PSScriptRoot 'release-submit-winget.ps1') -Version $version -ArtifactRoot $artifactRoot -TempDirectory $WorkDirectory -WhatIf
    & (Join-Path $PSScriptRoot 'release-publish-chocolatey.ps1') -Version $version -ArtifactRoot $artifactRoot -RunnerTemp $WorkDirectory -WhatIf
}
if ($env:GITHUB_OUTPUT -and -not $Fixture) {
    "version=$version`nartifact_root=$artifactRoot" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "publish_scoop=$($channels.SCOOP -and $resumeFrom -le 1)`npublish_winget=$($channels.WINGET -and $resumeFrom -le 2)`npublish_chocolatey=$($channels.CHOCOLATEY -and $resumeFrom -le 3)".ToLowerInvariant() | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
Write-Host "Release promote: PASS ($Tag, resume=$resume, fixture=$([bool]$Fixture))."
$global:LASTEXITCODE = 0
} finally {
    if ($fixtureRun) { Remove-ReleaseFixtureDirectory -RunDirectory $fixtureRun }
}
