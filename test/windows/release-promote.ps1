# Fixture B. Runs the production writer, generator and promotion predicates
# with recorded GitHub responses. No GitHub mutation can escape the gh shim.
# The final copy/published-verifier collaborators are recording stand-ins;
# their actual contracts remain covered separately by Contracts.80/.82.
[CmdletBinding()]
param([string] $AssetDirectory, [string] $WorkDirectory)
$ErrorActionPreference = 'Stop'
$previousFixtureContext = $global:NocttyReleaseFixtureB
$global:NocttyReleaseFixtureB = [pscustomobject]@{ RealGit=$null; Candidate=$null; Inputs=$null; Calls=$null; Case=$null; ReleaseRun=$null; TestRun=$null; Release=$null; Jobs=$null; ManifestText=$null }
$sourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$recordPath = Join-Path $PSScriptRoot 'fixtures/release-promotion-1.3.136.json'
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
if (-not $WorkDirectory) { $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) ('release-promote-' + [guid]::NewGuid().ToString('N')) }
if (Test-Path -LiteralPath $WorkDirectory) { throw 'Fixture work directory must be fresh.' }
[void][IO.Directory]::CreateDirectory($WorkDirectory)
if (-not $AssetDirectory) {
    $AssetDirectory = Join-Path $WorkDirectory 'published-assets'
    [void][IO.Directory]::CreateDirectory($AssetDirectory)
    foreach ($asset in $record.release.assets) {
        Invoke-WebRequest -Uri "https://github.com/amanthanvi/noctty/releases/download/v1.3.136/$($asset.name)" -OutFile (Join-Path $AssetDirectory $asset.name)
    }
}
. (Join-Path $sourceRoot 'scripts/release-manifest.ps1')
foreach ($asset in $record.release.assets) {
    $path = Join-Path $AssetDirectory $asset.name
    if ((Get-Item -LiteralPath $path).Length -ne $asset.size -or "sha256:$(Get-FileSha256Lower $path)" -cne $asset.digest) {
        throw "Fixture must use v1.3.136's real, digest-verified asset: $($asset.name)."
    }
}

$primary = Join-Path $WorkDirectory 'checkout-a'
$candidate = Join-Path $WorkDirectory 'candidate'
$other = Join-Path $WorkDirectory 'checkout-b'
[void][IO.Directory]::CreateDirectory((Join-Path $primary 'scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $primary 'dist/windows'))
foreach ($name in @('common.ps1', 'windows-architecture.ps1', 'release-manifest.ps1', 'release-evidence.ps1', 'release-promote.ps1', 'package-package-managers.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts/$name") -Destination (Join-Path $primary "scripts/$name")
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'dist/windows/release-metadata.json') -Destination (Join-Path $primary 'dist/windows/release-metadata.json')
[IO.File]::WriteAllText((Join-Path $primary 'scripts/check-release-copy.ps1'), @'
param([string] $ExpectedVersion, [switch] $CheckRemoteLatest)
Test-PromoteFixtureCopy -Version $ExpectedVersion -Remote ([bool]$CheckRemoteLatest)
$global:LASTEXITCODE = 0
'@)
[IO.File]::WriteAllText((Join-Path $primary 'scripts/verify-published-release.ps1'), @'
param([string] $Version, [string] $CandidateDirectory, [string] $ManifestSha256)
Test-PromoteFixtureVerification -CandidateDirectory $CandidateDirectory -ManifestSha256 $ManifestSha256
$global:LASTEXITCODE = 0
'@)
$global:NocttyReleaseFixtureB.RealGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
function Invoke-FixtureGit {
    & $global:NocttyReleaseFixtureB.RealGit @args
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git setup failed.' }
}
Invoke-FixtureGit init --quiet --initial-branch=main $primary
Invoke-FixtureGit -C $primary add .
Invoke-FixtureGit -C $primary -c user.name=release-fixture -c user.email=release-fixture@example.invalid commit --quiet -m candidate
$sha = (Invoke-FixtureGit -C $primary rev-parse HEAD).Trim()
Invoke-FixtureGit -C $primary tag v1.3.136
[IO.File]::WriteAllText((Join-Path $primary 'orchestration.txt'), 'main moved during soak')
Invoke-FixtureGit -C $primary add orchestration.txt
Invoke-FixtureGit -C $primary -c user.name=release-fixture -c user.email=release-fixture@example.invalid commit --quiet -m orchestration
Invoke-FixtureGit -C $primary update-ref refs/remotes/origin/main HEAD
Invoke-FixtureGit clone --shared --quiet $primary $candidate
Invoke-FixtureGit -C $candidate checkout --detach --quiet v1.3.136
Invoke-FixtureGit clone --shared --quiet $primary $other
function Initialize-FixtureArtifacts {
    param([string] $Root)
    foreach ($architecture in @('x64', 'arm64')) {
        $destination = Join-Path $Root "dist/artifacts/noctty-1.3.136-windows-$architecture"
        [void][IO.Directory]::CreateDirectory($destination)
        foreach ($asset in $record.release.assets) {
            if ($asset.name -like "*-windows-$architecture-*" -or $asset.name -ceq "SHA256SUMS-windows-$architecture.txt" -or
                ($architecture -eq 'x64' -and $asset.name -in @('SHA256SUMS.txt', 'noctty-icon.svg'))) {
                Copy-Item -LiteralPath (Join-Path $AssetDirectory $asset.name) -Destination $destination
            }
        }
    }
    & (Join-Path $Root 'scripts/package-package-managers.ps1') -Version 1.3.136 -Architectures @('x64', 'arm64') -UpstreamBaseVersion 1.3.2 -FirstForkPatch 100 | Out-Null
}
Initialize-FixtureArtifacts $primary
Initialize-FixtureArtifacts $other
$primaryArtifact = Join-Path $primary 'dist/artifacts/noctty-1.3.136-windows-x64'
$otherArtifact = Join-Path $other 'dist/artifacts/noctty-1.3.136-windows-x64'
$filesA = @(Get-PackageManagerFileRecords $primaryArtifact)
$filesB = @(Get-PackageManagerFileRecords $otherArtifact)
if (($filesA | ConvertTo-Json -Depth 4 -Compress) -cne ($filesB | ConvertTo-Json -Depth 4 -Compress)) { throw 'Generator depends on checkout root.' }
[IO.File]::WriteAllText((Join-Path $WorkDirectory 'determinism.json'), ($filesA | ConvertTo-Json -Depth 4) + "`n")
$manifestPath = Write-ReleaseManifest -Tag v1.3.136 -Version 1.3.136 -CandidateSha $sha -TestRunId 42344250161 -EvidenceRunId 42344250161 -ReleaseRunId 42346135091 -ArtifactRoot (Join-Path $primary 'dist/artifacts') -CandidateDirectory $candidate
$manifestBytes = [IO.File]::ReadAllText($manifestPath)
# Main's generator changes during the soak. Its replacement cannot regenerate
# anything: a passing promotion therefore proves it ran the candidate copy.
[IO.File]::WriteAllText((Join-Path $primary 'scripts/package-package-managers.ps1'), "throw 'The orchestration generator must never run during promotion.'`n")
Invoke-FixtureGit -C $primary add scripts/package-package-managers.ps1
Invoke-FixtureGit -C $primary -c user.name=release-fixture -c user.email=release-fixture@example.invalid commit --quiet -m changed-main-generator
Invoke-FixtureGit -C $primary update-ref refs/remotes/origin/main HEAD
$global:NocttyReleaseFixtureB.Candidate = $candidate
$global:NocttyReleaseFixtureB.Inputs = @{
    Tag = 'v1.3.136'; CandidateSha = $sha; TestRunId = '42344250161'; EvidenceRunId = '42344250161'; ReleaseRunId = '42346135091'
    CandidateDirectory = $candidate
}
$global:NocttyReleaseFixtureB.Calls = [Collections.Generic.List[string]]::new()
$global:NocttyReleaseFixtureB.Case = ''
function Test-PromoteFixtureCopy {
    param([string] $Version, [bool] $Remote)
    $global:NocttyReleaseFixtureB.Calls.Add("copy:$Version`:$Remote")
    if ($global:NocttyReleaseFixtureB.Case -eq 'copy') { throw 'StableCopyMismatch' }
}
function Test-PromoteFixtureVerification {
    param([string] $CandidateDirectory, [string] $ManifestSha256)
    if ($CandidateDirectory -cne $global:NocttyReleaseFixtureB.Candidate -or $ManifestSha256 -cne $global:NocttyReleaseFixtureB.Inputs.ManifestSha256) { throw 'Wrong verifier candidate inputs.' }
    $global:NocttyReleaseFixtureB.Calls.Add('verify')
    if ($global:NocttyReleaseFixtureB.Case -eq 'verification') { throw 'PublishedVerificationFailed' }
}
function git {
    if ($global:NocttyReleaseFixtureB.Case -eq 'ancestry' -and $args -contains 'merge-base') { $global:LASTEXITCODE = 1; return }
    & $global:NocttyReleaseFixtureB.RealGit @args
}
function gh {
    $global:LASTEXITCODE = 0
    $operation = @($args)
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'view' -and $global:NocttyReleaseFixtureB.Case -like 'build*') {
        $global:LASTEXITCODE = if ($global:NocttyReleaseFixtureB.Case -eq 'build') { 1 } else { 0 }
        return
    }
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'create' -and $global:NocttyReleaseFixtureB.Case -eq 'build') {
        $target = $operation[[array]::IndexOf($operation, '--target') + 1]
        $assets = @($operation | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue })
        if ($target -cne $global:NocttyReleaseFixtureB.Inputs.CandidateSha -or $assets.Count -ne 13 -or
            @($assets | Where-Object { [IO.Path]::GetFileName($_) -ceq 'release-manifest.json' }).Count -ne 1) { throw 'Build publisher omitted the candidate target or manifest asset.' }
        $global:NocttyReleaseFixtureB.Calls.Add('create')
        return
    }
    if ($operation[0] -ceq 'api') {
        $endpoint = $operation[1]
        if ($endpoint -like '*/git/ref/tags/*') {
            $remoteSha = if ($global:NocttyReleaseFixtureB.Case -eq 'remote-tag') { 'f' * 40 } else { $global:NocttyReleaseFixtureB.Inputs.CandidateSha }
            return (@{ object = @{ type = 'commit'; sha = $remoteSha } } | ConvertTo-Json -Depth 5)
        }
        if ($endpoint -like '*/releases/tags/*') { return ($global:NocttyReleaseFixtureB.Release | ConvertTo-Json -Depth 8) }
        if ($endpoint -match '/actions/runs/([0-9]+)(/artifacts|/jobs)?(?:\?|$)') {
            $runId = $Matches[1]; $kind = $Matches[2]
            if ($kind -ceq '/artifacts') {
                $expired = $global:NocttyReleaseFixtureB.Case -eq 'expired' -and $runId -ceq '42344250161'
                $expiration = if ($expired) { '2026-11-21T06:07:57Z' } else { '2099-01-01T00:00:00Z' }
                return (@{ total_count = 2; artifacts = @(
                    @{ name = "flagship-portable-x64-$runId"; expired = $expired; expires_at = $expiration },
                    @{ name = "flagship-interactive-win11-$runId"; expired = ($expired -or $global:NocttyReleaseFixtureB.Case -eq 'expired-interactive'); expires_at = $expiration }
                ) } | ConvertTo-Json -Depth 5)
            }
            if ($kind -ceq '/jobs') { return ($global:NocttyReleaseFixtureB.Jobs | ConvertTo-Json -Depth 5) }
            $run = if ($runId -ceq '42346135091') { $global:NocttyReleaseFixtureB.ReleaseRun } else { $global:NocttyReleaseFixtureB.TestRun }
            $run.id = [long]$runId
            return ($run | ConvertTo-Json -Depth 5)
        }
    }
    if ($operation[0] -ceq 'run' -and $operation[1] -ceq 'download') {
        $destination = $operation[[array]::IndexOf($operation, '--dir') + 1]
        [IO.File]::WriteAllText((Join-Path $destination 'bound.txt'), 'candidate-bound evidence')
        $hash = Get-FileSha256Lower (Join-Path $destination 'bound.txt')
        $evidence = @{
            scenario_id = 'windows.interactive-win11.composite'; status = 'pass'
            implementation_commit = $global:NocttyReleaseFixtureB.Inputs.CandidateSha; workflow_run_id = $operation[2]
            artifacts = @(@{ path = 'bound.txt'; sha256 = $hash })
        }
        if ($global:NocttyReleaseFixtureB.Case -eq 'evidence-hash') { $evidence.artifacts[0].sha256 = '0' * 64 }
        if ($global:NocttyReleaseFixtureB.Case -eq 'evidence-sha') { $evidence.implementation_commit = '0' * 40 }
        [IO.File]::WriteAllText((Join-Path $destination 'result.json'), ($evidence | ConvertTo-Json -Depth 5))
        return
    }
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'download') {
        $destination = $operation[[array]::IndexOf($operation, '--dir') + 1]
        foreach ($asset in $record.release.assets) { Copy-Item -LiteralPath (Join-Path $AssetDirectory $asset.name) -Destination $destination }
        [IO.File]::WriteAllText((Join-Path $destination 'release-manifest.json'), $global:NocttyReleaseFixtureB.ManifestText, [Text.UTF8Encoding]::new($false))
        if ($global:NocttyReleaseFixtureB.Case -eq 'asset') { [IO.File]::AppendAllText((Join-Path $destination 'noctty-icon.svg'), 'changed') }
        return
    }
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'edit') {
        if (($operation -join ' ') -cne 'release edit v1.3.136 --repo amanthanvi/noctty --prerelease=false --latest') { throw 'Wrong promote mutation.' }
        $global:NocttyReleaseFixtureB.Calls.Add('edit')
        $global:NocttyReleaseFixtureB.Release.prerelease = $false
        return
    }
    throw 'Fixture refused an unrecorded GitHub operation; no real gh fallback exists.'
}

$cases = [ordered]@{
    prerelease = $null; resume = $null
    tag = 'TagIdentityMismatch'; 'remote-tag' = 'TagIdentityMismatch'; ancestry = 'CandidateNotAncestor'
    asset = 'AssetDigestMismatch'; 'github-digest' = 'AssetDigestMismatch'; digest = 'ManifestDigestMismatch'; self = 'ManifestPayloadInvalid'
    extra = 'AssetSetMismatch'; missing = 'AssetSetMismatch'; metadata = 'PackageManagerMismatch'
    generator = 'package-manager generator differs from the prerelease'; 'generator-missing' = 'package-manager generator differs from the prerelease'
    identity = 'ManifestIdentityMismatch'; expired = 'EvidenceExpired'; recovery = $null; 'expired-interactive' = 'EvidenceExpired'; run = 'RunIdentityMismatch'
    job = 'EvidenceJobInvalid'; 'evidence-hash' = 'EvidenceHashMismatch'; 'evidence-sha' = 'EvidenceInvalid'
    copy = 'StableCopyMismatch'; verification = 'PublishedVerificationFailed'
}
$results = [Collections.Generic.List[object]]::new()
try {
    foreach ($case in $cases.Keys) {
        $global:NocttyReleaseFixtureB.Case = $case
        $global:NocttyReleaseFixtureB.Calls.Clear()
        $global:NocttyReleaseFixtureB.Release = ($record.release | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.Release.prerelease = $case -notin @('resume', 'identity')
        $global:NocttyReleaseFixtureB.TestRun = ($record.testRun | ConvertTo-Json | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.ReleaseRun = ($record.releaseRun | ConvertTo-Json | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.TestRun.head_sha = $sha
        $global:NocttyReleaseFixtureB.ReleaseRun.head_sha = $sha
        $global:NocttyReleaseFixtureB.Jobs = ($record.jobs | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.ManifestText = $manifestBytes
        $manifest = $manifestBytes | ConvertFrom-Json
        if ($case -eq 'self') { $manifest.payload += [pscustomobject]@{ name = 'release-manifest.json'; size = 0; sha256 = '0' * 64 } }
        if ($case -eq 'metadata') { $manifest.packageManagers.files[0].sha256 = '0' * 64 }
        if ($case -eq 'generator') { $manifest.packageManagers.generatorBlob = '0' * 40 }
        if ($case -eq 'identity') { $manifest.candidateSha = '0' * 40 }
        $global:NocttyReleaseFixtureB.ManifestText = ($manifest | ConvertTo-Json -Depth 8) + "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($global:NocttyReleaseFixtureB.ManifestText)
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $global:NocttyReleaseFixtureB.Release.assets += [pscustomobject]@{ name = 'release-manifest.json'; size = $bytes.Length; digest = "sha256:$digest" }
        if ($case -eq 'github-digest') { $global:NocttyReleaseFixtureB.Release.assets[0].digest = 'sha256:' + ('0' * 64) }
        if ($case -eq 'extra') { $global:NocttyReleaseFixtureB.Release.assets += [pscustomobject]@{ name = 'extra.txt'; size = 1; digest = 'sha256:' + ('0' * 64) } }
        if ($case -eq 'missing') { $global:NocttyReleaseFixtureB.Release.assets = @($global:NocttyReleaseFixtureB.Release.assets | Where-Object { $_.name -cne 'noctty-icon.svg' }) }
        if ($case -eq 'run') { $global:NocttyReleaseFixtureB.ReleaseRun.conclusion = 'failure' }
        if ($case -eq 'job') { $global:NocttyReleaseFixtureB.Jobs.jobs = @() }
        $global:NocttyReleaseFixtureB.Inputs.ManifestSha256 = if ($case -eq 'digest') { '0' * 64 } else { $digest }
        $global:NocttyReleaseFixtureB.Inputs.CandidateSha = if ($case -eq 'tag') { '0' * 40 } else { $sha }
        $global:NocttyReleaseFixtureB.Inputs.TestRunId = if ($case -eq 'recovery') { '99999999999' } else { '42344250161' }
        $global:NocttyReleaseFixtureB.Inputs.EvidenceRunId = $global:NocttyReleaseFixtureB.Inputs.TestRunId
        if ($case -eq 'generator-missing') { Rename-Item -LiteralPath (Join-Path $candidate 'scripts/package-package-managers.ps1') -NewName 'generator.saved' }
        $invokeInputs = $global:NocttyReleaseFixtureB.Inputs
        $errorMessage = $null
        try {
            & (Join-Path $primary 'scripts/release-promote.ps1') @invokeInputs -WorkDirectory (Join-Path $WorkDirectory "case-$case") *> (Join-Path $WorkDirectory "case-$case.log")
        } catch { $errorMessage = $_.Exception.Message }
        finally {
            if ($case -eq 'generator-missing') { Rename-Item -LiteralPath (Join-Path $candidate 'scripts/generator.saved') -NewName 'package-package-managers.ps1' }
        }
        if ($cases[$case]) {
            if (-not $errorMessage -or $errorMessage -notmatch [regex]::Escape($cases[$case])) { throw "Fixture $case failed for the wrong reason: $errorMessage" }
            if ($case -ne 'verification' -and $global:NocttyReleaseFixtureB.Calls.Contains('edit')) { throw "Fixture $case mutated before validation completed." }
            if ($case -eq 'expired' -and ($errorMessage -notmatch '42344250161.*flagship-portable-x64-42344250161.*2026-11-21T06:07:57' -or
                $errorMessage -notmatch 'gh workflow run test.yml --repo amanthanvi/noctty --ref v1.3.136 -f run_interactive_win11=true')) { throw 'Expiry omitted its identity or recovery command.' }
        } else {
            if ($errorMessage) { throw "Fixture $case unexpectedly failed: $errorMessage" }
            $edits = @($global:NocttyReleaseFixtureB.Calls | Where-Object { $_ -ceq 'edit' }).Count
            if ($edits -ne $(if ($case -eq 'resume') { 0 } else { 1 }) -or -not $global:NocttyReleaseFixtureB.Calls.Contains('verify') -or
                -not $global:NocttyReleaseFixtureB.Calls.Contains('copy:1.3.136:False') -or -not $global:NocttyReleaseFixtureB.Calls.Contains('copy:1.3.136:True')) { throw "Fixture $case skipped a required orchestration step." }
        }
        $results.Add([ordered]@{ case = $case; result = 'pass'; expectedError = $cases[$case]; calls = @($global:NocttyReleaseFixtureB.Calls) })
        Write-Host "Fixture B $case`: PASS"
    }
    foreach ($case in @('build', 'build-existing')) {
        $global:NocttyReleaseFixtureB.Case = $case
        $global:NocttyReleaseFixtureB.Calls.Clear()
        $message = $null
        try {
            & (Join-Path $sourceRoot 'scripts/release-publish-github.ps1') -Tag v1.3.136 -Version 1.3.136 -Title 'noctty 1.3.136' -VersionLine 1.3 -UpstreamBaseVersion 1.3.2 -Prerelease true -CandidateSha $sha -ArtifactRoot (Join-Path $primary 'dist/artifacts') *> (Join-Path $WorkDirectory "case-$case.log")
        } catch { $message = $_.Exception.Message }
        if ($case -eq 'build') {
            if ($message -or @($global:NocttyReleaseFixtureB.Calls).Count -ne 1 -or -not $global:NocttyReleaseFixtureB.Calls.Contains('create')) { throw "Build publisher fixture failed: $message" }
        } elseif (-not $message -or $message -notmatch 'already exists' -or $global:NocttyReleaseFixtureB.Calls.Count -ne 0) { throw 'Build publisher must refuse an existing release.' }
        $results.Add([ordered]@{ case = $case; result = 'pass'; calls = @($global:NocttyReleaseFixtureB.Calls) })
        Write-Host "Fixture B $case`: PASS"
    }
} finally {
    Remove-Item Function:\gh,Function:\git
    $global:NocttyReleaseFixtureB = $previousFixtureContext
    $global:LASTEXITCODE = 0
}
[IO.File]::WriteAllText((Join-Path $WorkDirectory 'results.json'), ($results | ConvertTo-Json -Depth 6) + "`n")
Write-Host "Release promotion fixture B: PASS ($($results.Count) cases, $($filesA.Count) files identical across two checkout roots, 12 real assets)."
