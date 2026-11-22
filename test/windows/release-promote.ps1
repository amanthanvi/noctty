# Fixture B. Runs the production writer, generator and promotion predicates
# with recorded GitHub responses. No GitHub mutation can escape the gh shim.
# The final copy/published-verifier collaborators are recording stand-ins;
# their actual contracts remain covered separately by Contracts.80/.82.
[CmdletBinding()]
param([string] $AssetDirectory, [string] $WorkDirectory, [string[]] $CaseFilter)
$ErrorActionPreference = 'Stop'
$previousFixtureContext = $global:NocttyReleaseFixtureB
$sourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $sourceRoot 'scripts/release-fixture-directory.ps1')
$recordPath = Join-Path $PSScriptRoot 'fixtures/release-promotion-1.3.136.json'
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
$savedEnvironment = @{}
foreach ($name in @('SCOOP_PUBLISH','WINGET_PUBLISH','CHOCOLATEY_PUBLISH','SCOOP_BUCKET_REPO','SCOOP_BUCKET_TOKEN','WINGET_PACKAGE_IDENTIFIER','WINGET_CREATE_GITHUB_TOKEN','PROMOTE_CHOCOLATEY_KEY_PRESENT','SCOOP_BUCKET_MANIFEST_PATH','SCOOP_BUCKET_BRANCH','GITHUB_OUTPUT','GH_TOKEN','GITHUB_TOKEN','WINGETCREATE_TOKEN','CHOCO_API_KEY','NOCTTY_FIXTURE_UNLISTED_SECRET')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$resultDirectory = New-ReleaseFixtureDirectory -ParentDirectory $WorkDirectory
$bulk = [IO.Path]::Combine($resultDirectory, 'bulk')
$results = [Collections.Generic.List[object]]::new()
$activeCase = $null
$passed = $false
try {
$global:NocttyReleaseFixtureB = [pscustomobject]@{ RealGit=$null; Candidate=$null; Inputs=$null; Calls=$null; Case=$null; ReleaseRun=$null; TestRun=$null; Release=$null; Jobs=$null; ManifestText=$null; BuildCreated=$false; ReadFailures=0; Reads=@{}; HttpStatus=0 }
$WorkDirectory = $bulk
[void][IO.Directory]::CreateDirectory($WorkDirectory)
if (-not $AssetDirectory) { $AssetDirectory = [IO.Path]::Combine($bulk, 'assets') }
[void][IO.Directory]::CreateDirectory($AssetDirectory)
foreach ($asset in $record.release.assets) {
    $path = Join-Path $AssetDirectory $asset.name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Invoke-WebRequest -Uri "https://github.com/amanthanvi/noctty/releases/download/v1.3.136/$($asset.name)" -OutFile $path -MaximumRetryCount 2
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
foreach ($name in @('common.ps1', 'windows-architecture.ps1', 'release-manifest.ps1', 'release-evidence.ps1', 'release-promote.ps1', 'release-publication-state.ps1', 'release-package-manager-preflight.ps1', 'release-run-generator.ps1', 'package-package-managers.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot "scripts/$name") -Destination (Join-Path $primary "scripts/$name")
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'dist/windows/release-metadata.json') -Destination (Join-Path $primary 'dist/windows/release-metadata.json')
[IO.File]::WriteAllText((Join-Path $primary 'scripts/check-release-copy.ps1'), @'
param([string] $ExpectedVersion, [switch] $CheckRemoteLatest)
Test-PromoteFixtureCopy -Version $ExpectedVersion -Remote ([bool]$CheckRemoteLatest)
$global:LASTEXITCODE = 0
'@)
[IO.File]::WriteAllText((Join-Path $primary 'scripts/verify-published-release.ps1'), @'
param([string] $Version, [string] $CandidateDirectory, [string] $ManifestSha256, [switch] $PassThru)
Test-PromoteFixtureVerification -CandidateDirectory $CandidateDirectory -ManifestSha256 $ManifestSha256
$global:LASTEXITCODE = 73 # Deliberately stale: caller must use the explicit result.
if ($PassThru) { [pscustomobject]@{Verified=($global:NocttyReleaseFixtureB.Case -ne 'verification-result')} }
'@)
$generatorPath = Join-Path $primary 'scripts/package-package-managers.ps1'
$generatorSource = [IO.File]::ReadAllText($generatorPath)
$guard = "if ([Environment]::GetEnvironmentVariable('NOCTTY_FIXTURE_UNLISTED_SECRET')) { throw 'GeneratorUnlistedEnvironmentLeak' }; if ((Get-Variable generatorCredentials -ErrorAction Ignore) -or (Get-Variable generatorScopeSentinel -ErrorAction Ignore)) { throw 'GeneratorScopeLeak' }; foreach (`$credential in @('GH_TOKEN','GITHUB_TOKEN','SCOOP_BUCKET_TOKEN','WINGET_CREATE_GITHUB_TOKEN','WINGETCREATE_TOKEN','CHOCO_API_KEY')) { if ([Environment]::GetEnvironmentVariable(`$credential)) { throw 'GeneratorCredentialLeak' } }"
$generatorSource = $generatorSource.Replace('$ErrorActionPreference = "Stop"', "`$ErrorActionPreference = 'Stop'`n$guard")
if ($generatorSource.IndexOf('GeneratorCredentialLeak') -gt $generatorSource.IndexOf('function ')) { throw 'Credential assertion was not inserted at generator entry.' }
[IO.File]::WriteAllText($generatorPath, $generatorSource, [Text.UTF8Encoding]::new($false))
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
    $saved = @{}
    foreach ($name in @('GH_TOKEN','GITHUB_TOKEN','SCOOP_BUCKET_TOKEN','WINGET_CREATE_GITHUB_TOKEN','WINGETCREATE_TOKEN','CHOCO_API_KEY')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name,$null) }
    try {
    & (Join-Path $Root 'scripts/package-package-managers.ps1') -Version 1.3.136 -Architectures @('x64', 'arm64') -UpstreamBaseVersion 1.3.2 -FirstForkPatch 100 | Out-Null
    } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }

}
Initialize-FixtureArtifacts $primary
Initialize-FixtureArtifacts $other
$primaryArtifact = Join-Path $primary 'dist/artifacts/noctty-1.3.136-windows-x64'
$otherArtifact = Join-Path $other 'dist/artifacts/noctty-1.3.136-windows-x64'
$filesA = @(Get-PackageManagerFileRecords $primaryArtifact)
$filesB = @(Get-PackageManagerFileRecords $otherArtifact)
if (($filesA | ConvertTo-Json -Depth 4 -Compress) -cne ($filesB | ConvertTo-Json -Depth 4 -Compress)) { throw 'Generator depends on checkout root.' }
[IO.File]::WriteAllText((Join-Path $resultDirectory 'determinism.json'), ($filesA | ConvertTo-Json -Depth 4) + "`n")
# The writer must repair a stale alias before hashing; the publisher cannot.
[IO.File]::WriteAllText((Join-Path $primaryArtifact 'SHA256SUMS.txt'), 'stale alias')
$manifestPath = Write-ReleaseManifest -Tag v1.3.136 -Version 1.3.136 -CandidateSha $sha -TestRunId 42344250161 -ReleaseRunId 42346135091 -ArtifactRoot (Join-Path $primary 'dist/artifacts') -CandidateDirectory $candidate
$manifestBytes = [IO.File]::ReadAllText($manifestPath)
# Main's generator changes during the soak. Its replacement cannot regenerate
# anything: a passing promotion therefore proves it ran the candidate copy.
[IO.File]::WriteAllText((Join-Path $primary 'scripts/package-package-managers.ps1'), "throw 'The orchestration generator must never run during promotion.'`n")
Invoke-FixtureGit -C $primary add scripts/package-package-managers.ps1
Invoke-FixtureGit -C $primary -c user.name=release-fixture -c user.email=release-fixture@example.invalid commit --quiet -m changed-main-generator
Invoke-FixtureGit -C $primary update-ref refs/remotes/origin/main HEAD
$global:NocttyReleaseFixtureB.Candidate = $candidate
$global:NocttyReleaseFixtureB.Inputs = @{
    Tag = 'v1.3.136'; CandidateSha = $sha; TestRunId = '42344250161'; ReleaseRunId = '42346135091'
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
function Get-FixtureReadCount {
    param([string] $Key)
    $reads=$global:NocttyReleaseFixtureB.Reads
    if (-not $reads.ContainsKey($Key)) { $reads[$Key]=0 }
    $reads[$Key]++
    $global:NocttyReleaseFixtureB.Calls.Add("poll:$Key`:$($reads[$Key])")
    return $reads[$Key]
}
function Invoke-FixtureGh {
    $global:LASTEXITCODE = 0
    $operation = @($args)
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'create' -and $global:NocttyReleaseFixtureB.Case -like 'build*') {
        if (@($operation | Where-Object { $_ -is [char] }).Count -or (($operation -contains '--prerelease') -ne ($global:NocttyReleaseFixtureB.Case -notlike 'build-stable*'))) { throw 'Create prerelease flag was not passed as a complete argument.' }
        $target = $operation[[array]::IndexOf($operation, '--target') + 1]
        if ($target -cne $global:NocttyReleaseFixtureB.Inputs.CandidateSha -or $operation -notcontains '--draft') { throw 'Build omitted candidate or draft.' }
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-create-refused') { $global:NocttyReleaseFixtureB.Calls.Add('create'); $global:LASTEXITCODE=1; return }
        $global:NocttyReleaseFixtureB.Release | Add-Member -NotePropertyName target_commitish -NotePropertyValue $target -Force
        $notes = $operation[[array]::IndexOf($operation, '--notes') + 1]
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-create-other-writer') {
            # Same candidate, flags, title, notes prefix and zero assets.
            # The failed call did not create this different attempt's draft.
            $notes = $notes -creplace '(?m)^<!-- noctty-release-create:[0-9a-f]{32} -->$', '<!-- noctty-release-create:0123456789abcdef0123456789abcdef -->'
        }
        $global:NocttyReleaseFixtureB.Release | Add-Member -NotePropertyName body -NotePropertyValue "$notes`n## Changes`nGenerated release notes" -Force
        $global:NocttyReleaseFixtureB.Release.prerelease = $operation -contains '--prerelease'
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-create-existing-tag-target') { $global:NocttyReleaseFixtureB.Release.target_commitish='main' }
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-create-identity') { $global:NocttyReleaseFixtureB.Release.target_commitish='0'*40 }
        $global:NocttyReleaseFixtureB.BuildCreated = $true
        $global:NocttyReleaseFixtureB.Release.assets = @()
        $global:NocttyReleaseFixtureB.Release.draft = $true
        $global:NocttyReleaseFixtureB.Calls.Add('create')
        if ($global:NocttyReleaseFixtureB.Case -in @('build-create-lost','build-create-delay','build-create-other-writer','build-create-id-lag','build-create-id-exhausted')) { $global:LASTEXITCODE=1 }
        return
    }
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'upload' -and $global:NocttyReleaseFixtureB.Case -like 'build*') {
        $path = $operation[-1]
        $name = [IO.Path]::GetFileName($path)
        $call = "upload:$name"
        $count = @($global:NocttyReleaseFixtureB.Calls | Where-Object { $_ -ceq $call }).Count
        $global:NocttyReleaseFixtureB.Calls.Add($call)
        if (@($global:NocttyReleaseFixtureB.Release.assets | Where-Object name -ceq $name).Count) { $global:LASTEXITCODE=1;return }
        if ($name -ceq 'noctty-icon.svg' -and ($global:NocttyReleaseFixtureB.Case -eq 'build-exhausted' -or ($global:NocttyReleaseFixtureB.Case -eq 'build-retry' -and $count -lt 2))) { $global:LASTEXITCODE = 1; return }
        $global:NocttyReleaseFixtureB.Release.assets += [pscustomobject]@{ name=$name; size=(Get-Item -LiteralPath $path).Length; digest="sha256:$(Get-FileSha256Lower $path)"; state='uploaded' }
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-lost-response') { $global:LASTEXITCODE = 1 }
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-upload-starter' -and $name -ceq 'noctty-icon.svg') { $global:NocttyReleaseFixtureB.Release.assets[-1].digest=$null; $global:NocttyReleaseFixtureB.Release.assets[-1].state='starter' }
        if ($global:NocttyReleaseFixtureB.Case -eq 'build-drift' -and $name -ceq 'noctty-icon.svg') { $global:NocttyReleaseFixtureB.Release.assets[-1].digest = 'sha256:' + ('0' * 64) }
        return
    }
    if ($operation[0] -ceq 'api') {
        $endpoint = $operation[1]
        if ($operation -contains '--method') {
            if ($operation[[array]::IndexOf($operation,'--method')+1] -cne 'GET') { throw 'Fixture refused an unrecorded API mutation.' }
            $readPath=$operation[[array]::IndexOf($operation,'--method')+2]
            if ($readPath -notin @('repos/fixture/bucket/contents/bucket/noctty.json','repos/microsoft/winget-pkgs/contents/manifests/a/AmanThanvi/noctty')) { throw 'Preflight queried an unrecorded bootstrap path.' }

            if ($global:NocttyReleaseFixtureB.Case -eq 'preflight-bootstrap') { $global:LASTEXITCODE = 1 }
            return '{}'
        }
        if ($endpoint -like '*/git/tags/*') {
            $global:NocttyReleaseFixtureB.Calls.Add('peel')
            $remoteSha=if($global:NocttyReleaseFixtureB.Case -like '*annotated-mismatch'){'f'*40}else{$global:NocttyReleaseFixtureB.Inputs.CandidateSha}
            return (@{object=@{type='commit';sha=$remoteSha}}|ConvertTo-Json -Depth 5)
        }
        if ($endpoint -like '*/git/ref/tags/*') {
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-tag-empty') {
                [void](Get-FixtureReadCount tag)
                return '[]'
            }
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-create-identity' -and $global:NocttyReleaseFixtureB.BuildCreated) { $global:LASTEXITCODE=1;return '{}' }
            if ($global:NocttyReleaseFixtureB.Calls.Contains('publish') -and $global:NocttyReleaseFixtureB.Case -in @('build-tag-lag','build-tag-exhausted','build-tag-503')) {
                $count=Get-FixtureReadCount tag
                if ($global:NocttyReleaseFixtureB.Case -eq 'build-tag-exhausted' -or $count -le 2) {
                    if ($global:NocttyReleaseFixtureB.Case -eq 'build-tag-503') { $global:NocttyReleaseFixtureB.HttpStatus=503 }
                    $global:LASTEXITCODE=1;return '{}'
                }
            }
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-absent-tag' -and -not $global:NocttyReleaseFixtureB.Calls.Contains('publish')) { $global:LASTEXITCODE=1; return }
            if ($global:NocttyReleaseFixtureB.Case -like '*annotated*') { return (@{object=@{type='tag';sha='a'*40}}|ConvertTo-Json -Depth 5) }
            $remoteSha = if ($global:NocttyReleaseFixtureB.Case -in @('remote-tag','build-tag-mismatch')) { 'f' * 40 } else { $global:NocttyReleaseFixtureB.Inputs.CandidateSha }
            return (@{ object = @{ type = 'commit'; sha = $remoteSha } } | ConvertTo-Json -Depth 5)
        }
        if ($endpoint -match '/releases\?per_page=100&page=([0-9]+)$') {
            $page=[int]$Matches[1];$case=$global:NocttyReleaseFixtureB.Case
            if ($case -eq 'build-create-refused' -and $global:NocttyReleaseFixtureB.Calls.Contains('create')) { [void](Get-FixtureReadCount create) }
            if ($case -eq 'build-create-delay' -and $global:NocttyReleaseFixtureB.BuildCreated -and (Get-FixtureReadCount create) -le 2) { return '[]' }
            if ($case -eq 'release-missing' -or ($case -like 'build*' -and $case -notin @('build-existing','build-draft','build-preflight-id-404','build-preflight-id-empty','build-preflight-id-empty-lag') -and -not $global:NocttyReleaseFixtureB.BuildCreated)) { return '[]' }
            if ($case -eq 'discovery-page2' -and $page -eq 1) { return (ConvertTo-Json -Depth 5 -InputObject @(1..100 | ForEach-Object { @{id=$_;tag_name="v0.0.$_";draft=$false;assets=@()} })) }
            if (($case -eq 'discovery-page2' -and $page -ne 2) -or ($case -ne 'discovery-page2' -and $page -ne 1)) { return '[]' }
            $items=@($global:NocttyReleaseFixtureB.Release)
            if ($case -in @('duplicate-draft','shared-tag')) { $items += [pscustomobject]@{id=137;tag_name='v1.3.136';draft=$true;assets=@()} }
            return (ConvertTo-Json -Depth 8 -InputObject $items)
        }
        if ($endpoint -like '*/releases/tags/*') {
            # REST docs + cli v2.100.0 FetchRelease: drafts are never found by tag.
            $global:NocttyReleaseFixtureB.Calls.Add('tag-release-read')
            if ($global:NocttyReleaseFixtureB.Release.draft) { $global:LASTEXITCODE=1; return '{"message":"Not Found","status":"404"}' }
            return ($global:NocttyReleaseFixtureB.Release | ConvertTo-Json -Depth 8)
        }
        if ($endpoint -match '/releases/latest$') {
            $case=$global:NocttyReleaseFixtureB.Case
            if ($case -eq 'build-latest-empty') {
                [void](Get-FixtureReadCount latest)
                return '[]'
            }
            if ($case -in @('build-stable-latest-lag','build-stable-latest-exhausted','build-stable-latest-404','build-stable-latest-503','promote-latest-lag','promote-latest-exhausted')) {
                $count=Get-FixtureReadCount latest
                if ($case -like '*exhausted' -or $count -le 2) {
                    if ($case -like '*404' -or $case -like '*503') { $global:LASTEXITCODE=1; $global:NocttyReleaseFixtureB.HttpStatus=$(if($case -like '*503'){503}else{404});return '{}' }
                    return '{"id":135}'
                }
            }
            return (@{id=$(if($global:NocttyReleaseFixtureB.Release.prerelease){135}else{136})}|ConvertTo-Json)
        }
        if ($endpoint -match '/releases/([0-9]+)$') {
            if ($global:NocttyReleaseFixtureB.Calls.Contains('publish') -and $global:NocttyReleaseFixtureB.Case -in @('build-read-retry','build-read-exhausted')) {
                $global:NocttyReleaseFixtureB.ReadFailures++
                if ($global:NocttyReleaseFixtureB.ReadFailures -le $(if($global:NocttyReleaseFixtureB.Case -eq 'build-read-exhausted'){3}else{2})) { $global:LASTEXITCODE=1; return 'retry' }
            }

            if ([string]$global:NocttyReleaseFixtureB.Release.id -cne $Matches[1]) { $global:LASTEXITCODE=1; return '{}' }
            $global:NocttyReleaseFixtureB.Calls.Add('id-release-read')
            $case = $global:NocttyReleaseFixtureB.Case
            $calls = $global:NocttyReleaseFixtureB.Calls
            if ($case -in @('build-preflight-id-empty','build-preflight-id-empty-lag') -and -not $calls.Contains('create')) {
                $count = Get-FixtureReadCount empty-id
                if ($case -eq 'build-preflight-id-empty' -or $count -le 2) { return '[]' }
            }
            if ($case -eq 'build-preflight-id-404' -or
                ($case -in @('build-create-id-lag','build-create-id-exhausted') -and
                 -not @($calls | Where-Object { $_ -like 'upload:*' }).Count)) {
                $count = Get-FixtureReadCount create-id
                if ($case -ne 'build-create-id-lag' -or $count -le 2) {
                    $global:NocttyReleaseFixtureB.HttpStatus=404
                    $global:LASTEXITCODE=1
                    return '{"message":"Not Found","status":"404"}'
                }
            }
            if (($global:NocttyReleaseFixtureB.Calls.Contains('edit') -and $global:NocttyReleaseFixtureB.Case -in @('promote-flip-lag','promote-refused')) -or
                ($global:NocttyReleaseFixtureB.Calls.Contains('publish') -and $global:NocttyReleaseFixtureB.Case -eq 'build-publish-lag')) {
                if ((Get-FixtureReadCount flags) -le 2) {
                    $stale=$global:NocttyReleaseFixtureB.Release | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                    $stale.draft=$global:NocttyReleaseFixtureB.Case -like 'build*';$stale.prerelease=$true
                    return ($stale|ConvertTo-Json -Depth 8)
                }
            }
            return ($global:NocttyReleaseFixtureB.Release | ConvertTo-Json -Depth 8)
        }
        if ($endpoint -match '/actions/runs/([0-9]+)(?:/attempts/([0-9]+))?(/artifacts|/jobs)?(?:\?|$)') {
            $runId=$Matches[1]; $attempt=if($Matches[2]){[int]$Matches[2]}else{0}; $kind=$Matches[3]
            if ($kind -ceq '/artifacts') {
                if ($runId -ceq '42346135091') { return '{"total_count":0,"artifacts":[]}' }
                $expired = $global:NocttyReleaseFixtureB.Case -eq 'expired' -and $runId -ceq '42344250161'
                $expiration = if ($expired) { '2026-11-21T06:07:57Z' } else { '2099-01-01T00:00:00Z' }
                return (@{ total_count = 2; artifacts = @(
                    @{ name = "flagship-portable-x64-$runId"; expired = $expired; expires_at = $expiration },
                    @{ name = "flagship-interactive-win11-$runId"; expired = $expired; expires_at = $expiration }
                ) } | ConvertTo-Json -Depth 5)
            }
            if ($runId -ceq '42346135091') {
                $case=$global:NocttyReleaseFixtureB.Case
                $run=$global:NocttyReleaseFixtureB.ReleaseRun | ConvertTo-Json | ConvertFrom-Json
                $run.id=[long]$runId
                if ($attempt) {
                    $global:NocttyReleaseFixtureB.Calls.Add("attempt:$attempt$kind")
                    $run.run_attempt=$attempt
                    if ($attempt -eq 1 -and $case -eq 'rerun') { $run.conclusion='failure' }
                    if ($case -eq 'attempt-sha') { $run.head_sha='0'*40 }
                }
                if ($kind -ceq '/jobs') {
                    # Unqualified jobs is latest-only; attempts retain publication.
                    if (-not $attempt) { $attempt=$global:NocttyReleaseFixtureB.ReleaseRun.run_attempt }
                    $names=@('Publish GitHub Release','Verify published release copy and assets','Publish Scoop manifest','Submit WinGet manifest update','Publish Chocolatey package')
                    $incomplete=switch($case){'failed-scoop'{2} 'failed-winget'{3} 'failed-chocolatey'{4} 'rerun'{2} 'cancelled-after'{2} default{1}}
                    $steps=@(for($i=0;$i -lt $names.Count;$i++) {
                        $conclusion=if($run.conclusion -eq 'success') { if($i -eq 0){'success'}else{'skipped'} }
                            elseif($case -in @('run','cancelled-no-publish','rerun-no-publish') -or ($case -eq 'rerun' -and $attempt -eq 2)) { if($i -eq 0){$run.conclusion}else{'skipped'} }
                            elseif($i -lt $incomplete){'success'}elseif($i -eq $incomplete){$run.conclusion}else{'skipped'}
                        @{name=$names[$i];conclusion=$conclusion}
                    })
                    foreach ($channel in @('Scoop','WinGet','Chocolatey')) {
                        if ($case -ne 'outcome-legacy') {
                            $outcome=if($case -eq 'outcome-skipped' -and $channel -eq 'Chocolatey'){'skipped-unconfigured'}elseif($case -eq 'outcome-present'){'already-present'}else{'published'}
                            $steps += @{name="$channel publication outcome: $outcome";conclusion='success'}
                        }
                    }
                    if ($case -like 'outcome-*') { foreach($step in $steps){$step.conclusion='success'} }
                    return (@{total_count=1;jobs=@(@{name='Windows Release';status='completed';conclusion=$run.conclusion;run_attempt=$attempt;steps=$steps})}|ConvertTo-Json -Depth 6)
                }
                return ($run|ConvertTo-Json -Depth 5)
            }
            if ($kind -ceq '/jobs') { return ($global:NocttyReleaseFixtureB.Jobs | ConvertTo-Json -Depth 5) }
            $run = if ($runId -ceq '42346135091') { $global:NocttyReleaseFixtureB.ReleaseRun } else { $global:NocttyReleaseFixtureB.TestRun }
            $run.id = [long]$runId
            return ($run | ConvertTo-Json -Depth 5)
        }
    }
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'download') {
        $destination = $operation[[array]::IndexOf($operation, '--dir') + 1]
        foreach ($asset in $record.release.assets) { Copy-Item -LiteralPath (Join-Path $AssetDirectory $asset.name) -Destination $destination }
        [IO.File]::WriteAllText((Join-Path $destination 'release-manifest.json'), $global:NocttyReleaseFixtureB.ManifestText, [Text.UTF8Encoding]::new($false))
        if ($global:NocttyReleaseFixtureB.Case -in @('asset','failed-asset')) { [IO.File]::AppendAllText((Join-Path $destination 'noctty-icon.svg'), 'changed') }
        return
    }
    if ($operation[0] -ceq 'release' -and $operation[1] -ceq 'edit') {
        if ($global:NocttyReleaseFixtureB.Case -like 'build*') {
            if ($operation -notcontains '--draft=false' -or @($global:NocttyReleaseFixtureB.Release.assets).Count -ne 13) { throw 'Build published before all assets verified.' }
            $expectedFlags = if ($global:NocttyReleaseFixtureB.Case -like 'build-stable*') { @('--prerelease=false','--latest') } else { @('--prerelease','--latest=false') }
            if (@($expectedFlags | Where-Object { $_ -cnotin $operation }).Count) { throw 'Build published the wrong stable/prerelease flags.' }
            $global:NocttyReleaseFixtureB.Calls.Add('publish')
            $global:NocttyReleaseFixtureB.Release.draft = $false
            $global:NocttyReleaseFixtureB.Release.prerelease = $operation -contains '--prerelease'
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-publish-flags') { $global:NocttyReleaseFixtureB.Release.prerelease=$false }
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-edit-lost') { $global:LASTEXITCODE=1 }
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-after-publish-drift') { $global:NocttyReleaseFixtureB.Release.assets[0].digest='sha256:'+('0'*64) }
            if ($global:NocttyReleaseFixtureB.Case -eq 'build-edit-refused') { $global:NocttyReleaseFixtureB.Release.draft=$true; $global:LASTEXITCODE=1 }
            return
        }
        if (($operation -join ' ') -cne 'release edit v1.3.136 --repo amanthanvi/noctty --prerelease=false --latest') { throw 'Wrong promote mutation.' }
        $global:NocttyReleaseFixtureB.Calls.Add('edit')
        $global:NocttyReleaseFixtureB.Release | Add-Member -NotePropertyName id -NotePropertyValue 136 -Force
        if ($global:NocttyReleaseFixtureB.Case -eq 'promote-confirmation-drift') { $global:NocttyReleaseFixtureB.Release.assets[0].digest='sha256:'+('0'*64) }
        $global:NocttyReleaseFixtureB.Release.prerelease = $global:NocttyReleaseFixtureB.Case -eq 'promote-refused'
        if ($global:NocttyReleaseFixtureB.Case -in @('promote-lost','promote-refused')) { $global:LASTEXITCODE=1 }
        return
    }
    throw 'Fixture refused an unrecorded GitHub operation; no real gh fallback exists.'
}

function gh {
    $global:NocttyReleaseFixtureB.HttpStatus=0
    $lines = @(Invoke-FixtureGh @args)
    $code = $LASTEXITCODE
    if ($args[0] -ceq 'api' -and $args -contains '--include' -and $args -notcontains '--method') {
        if ($lines.Count -eq 1 -and $lines[0] -ceq 'retry') { $global:LASTEXITCODE=1; return } # connection loss, no HTTP status
        "HTTP/2.0 $(if($global:NocttyReleaseFixtureB.HttpStatus){$global:NocttyReleaseFixtureB.HttpStatus}elseif($code -eq 0){200}else{404})"
        ''
    }
    $lines
    $global:LASTEXITCODE=$code
}

$cases = [ordered]@{
    prerelease = $null; resume = $null
    'promote-lost'=$null; 'promote-flip-lag'=$null; 'promote-latest-lag'=$null
    'promote-confirmation-drift'='AssetDigestMismatch'; 'promote-refused'='ReleasePublishUnconfirmed'; 'promote-latest-exhausted'='ReleaseLatestUnconfirmed'
    'annotated'=$null; 'annotated-mismatch'='TagIdentityMismatch'
    'verification-stale-exit'=$null; 'verification-result'='Published release verification failed'
    'outcome-skipped'=$null; 'outcome-present'=$null; 'outcome-legacy'=$null
    'legacy-pre-rename'='LegacyReleaseWithoutManifest'; 'shared-tag'='AmbiguousReleaseTag'; 'tagless-draft'='DraftRelease'
    'failed-verify' = $null; 'failed-scoop' = $null; 'failed-winget' = $null; 'failed-chocolatey' = $null; 'failed-prerelease' = $null
    'failed-digest' = 'ManifestDigestMismatch'; 'failed-asset' = 'AssetDigestMismatch'
    draft = 'DraftRelease'; 'manifest-missing' = 'LegacyReleaseWithoutManifest'
    'duplicate-draft' = 'AmbiguousReleaseTag'; 'release-missing' = 'ReleaseMissing'; 'discovery-page2' = $null
    rerun = $null; 'rerun-no-publish' = 'ReleasePublishNotSuccessful'; 'cancelled-after' = $null; 'cancelled-prerelease' = $null; 'cancelled-no-publish' = 'ReleasePublishNotSuccessful'; 'cancelled-before' = 'DraftRelease'; 'attempt-sha' = 'ReleaseAttemptsIncomplete'
    'generator-secrets' = $null; 'switches-Off' = $null
    'preflight-missing-scoop' = 'PackageManagerNotReady'; 'preflight-missing-winget' = 'PackageManagerNotReady'; 'preflight-missing-chocolatey' = 'PackageManagerNotReady'; 'preflight-bootstrap' = 'PackageManagerNotReady'; 'preflight-configured' = $null
    tag = 'TagIdentityMismatch'; 'remote-tag' = 'TagIdentityMismatch'; ancestry = 'CandidateNotAncestor'
    asset = 'AssetDigestMismatch'; 'github-digest' = 'AssetDigestMismatch'; digest = 'ManifestDigestMismatch'; self = 'ManifestPayloadInvalid'
    extra = 'AssetSetMismatch'; missing = 'IncompletePublishedRelease'; metadata = 'PackageManagerMismatch'
    generator = 'package-manager generator differs from the prerelease'; 'generator-missing' = 'package-manager generator differs from the prerelease'
    identity = 'ManifestIdentityMismatch'; expired = 'EvidenceExpired'; recovery = $null; run = 'ReleasePublishNotSuccessful'
    # A successful pull_request Test run at the candidate is no promotion evidence: its path filter can skip lanes.
    'pull-request-test-run' = 'RunIdentityMismatch'
    copy = 'StableCopyMismatch'; verification = 'PublishedVerificationFailed'
}
try {
    foreach ($case in $cases.Keys) {
        if ($CaseFilter -and $case -cnotin $CaseFilter) { continue }
        $env:SCOOP_PUBLISH = 'off'; $env:WINGET_PUBLISH = 'off'; $env:CHOCOLATEY_PUBLISH = 'off'
        $env:SCOOP_BUCKET_MANIFEST_PATH='';$env:SCOOP_BUCKET_BRANCH=''
        $env:SCOOP_BUCKET_REPO = 'fixture/bucket'; $env:SCOOP_BUCKET_TOKEN = 'fixture'
        $env:WINGET_PACKAGE_IDENTIFIER = 'AmanThanvi.noctty'; $env:WINGET_CREATE_GITHUB_TOKEN = 'fixture'
        $env:PROMOTE_CHOCOLATEY_KEY_PRESENT = 'true'
        if ($case -eq 'switches-Off') { $env:SCOOP_PUBLISH='Off';$env:WINGET_PUBLISH='OFF';$env:CHOCOLATEY_PUBLISH='oFf';$env:SCOOP_BUCKET_TOKEN='';$env:WINGET_CREATE_GITHUB_TOKEN='';$env:PROMOTE_CHOCOLATEY_KEY_PRESENT='false' }
        if ($case -eq 'generator-secrets') { $env:NOCTTY_FIXTURE_UNLISTED_SECRET='not-in-child-fixture';$env:GH_TOKEN='fixture';$env:GITHUB_TOKEN='fixture';$env:WINGETCREATE_TOKEN='fixture';$env:CHOCO_API_KEY='fixture' }

        if ($case -like 'outcome-*' -or $case -like 'preflight*' -or $case -like 'failed-*' -or $case -in @('rerun','cancelled-after','cancelled-prerelease')) { $env:SCOOP_PUBLISH = ''; $env:WINGET_PUBLISH = ''; $env:CHOCOLATEY_PUBLISH = '' }
        if ($case -eq 'preflight-missing-scoop') { $env:SCOOP_BUCKET_TOKEN = '' }
        if ($case -eq 'preflight-missing-winget') { $env:WINGET_CREATE_GITHUB_TOKEN = '' }
        if ($case -eq 'preflight-missing-chocolatey') { $env:PROMOTE_CHOCOLATEY_KEY_PRESENT = 'false' }
        $env:GITHUB_OUTPUT = Join-Path $resultDirectory "case-$case.outputs"
        if ($CaseFilter -and $case -cnotin $CaseFilter) { continue }
        $activeCase = $case
        $global:NocttyReleaseFixtureB.Case = $case
        $global:NocttyReleaseFixtureB.Calls.Clear()
        $global:NocttyReleaseFixtureB.Reads=@{}
        $global:NocttyReleaseFixtureB.Release = ($record.release | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.Release | Add-Member -NotePropertyName id -NotePropertyValue 136 -Force
        $global:NocttyReleaseFixtureB.Release.prerelease = $case -notlike 'outcome-*' -and $case -notin @('resume', 'identity', 'failed-verify', 'failed-scoop', 'failed-winget', 'failed-chocolatey', 'failed-digest', 'failed-asset', 'rerun', 'cancelled-after', 'cancelled-no-publish', 'rerun-no-publish')
        $global:NocttyReleaseFixtureB.TestRun = ($record.testRun | ConvertTo-Json | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.ReleaseRun = ($record.releaseRun | ConvertTo-Json | ConvertFrom-Json)
        $global:NocttyReleaseFixtureB.TestRun.head_sha = $sha
        if ($case -eq 'pull-request-test-run') { $global:NocttyReleaseFixtureB.TestRun.event = 'pull_request' }
        $global:NocttyReleaseFixtureB.ReleaseRun.head_sha = $sha
        $global:NocttyReleaseFixtureB.ReleaseRun | Add-Member -NotePropertyName run_attempt -NotePropertyValue $(if($case -in @('rerun','rerun-no-publish')){2}else{1}) -Force
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
        if ($case -in @('draft','duplicate-draft','cancelled-before','tagless-draft')) { $global:NocttyReleaseFixtureB.Release.draft = $true; $global:NocttyReleaseFixtureB.Release.assets=@($global:NocttyReleaseFixtureB.Release.assets[0]) }
        if ($case -eq 'legacy-pre-rename') { $global:NocttyReleaseFixtureB.Release.assets=@([pscustomobject]@{name='winghostty-old.zip'}) }
        if ($case -eq 'manifest-missing') { $global:NocttyReleaseFixtureB.Release.assets = @($global:NocttyReleaseFixtureB.Release.assets | Where-Object { $_.name -cne 'release-manifest.json' }) }
        if ($case -eq 'run' -or $case -like 'failed-*' -or $case -in @('rerun','rerun-no-publish','attempt-sha')) { $global:NocttyReleaseFixtureB.ReleaseRun.conclusion = 'failure' }
        if ($case -like 'cancelled-*') { $global:NocttyReleaseFixtureB.ReleaseRun.conclusion = 'cancelled' }
        $global:NocttyReleaseFixtureB.Inputs.ManifestSha256 = if ($case -in @('digest','failed-digest')) { '0' * 64 } else { $digest }
        $global:NocttyReleaseFixtureB.Inputs.CandidateSha = if ($case -eq 'tag') { '0' * 40 } else { $sha }
        $global:NocttyReleaseFixtureB.Inputs.TestRunId = if ($case -eq 'recovery') { '99999999999' } else { '42344250161' }
        if ($case -eq 'generator-missing') { Rename-Item -LiteralPath (Join-Path $candidate 'scripts/package-package-managers.ps1') -NewName 'generator.saved' }
        $invokeInputs = $global:NocttyReleaseFixtureB.Inputs
        $generatorScopeSentinel = 'parent-only-fixture-value'
        $errorMessage = $null
        try {
            & (Join-Path $primary 'scripts/release-promote.ps1') @invokeInputs -WorkDirectory (Join-Path $WorkDirectory "case-$case") *>&1 |
                Out-File -LiteralPath (Join-Path $resultDirectory "case-$case.log")
        } catch { $errorMessage = $_.Exception.Message }
        finally {
            if ($case -eq 'generator-missing') { Rename-Item -LiteralPath (Join-Path $candidate 'scripts/generator.saved') -NewName 'package-package-managers.ps1' }
        }
        if ($cases[$case]) {
            if (-not $errorMessage -or $errorMessage -notmatch [regex]::Escape($cases[$case])) { throw "Fixture $case failed for the wrong reason: $errorMessage" }
            if ($case -notin @('verification','verification-result','promote-confirmation-drift','promote-refused','promote-latest-exhausted') -and $global:NocttyReleaseFixtureB.Calls.Contains('edit')) { throw "Fixture $case mutated before validation completed." }
            if ($case -eq 'promote-refused' -and $global:NocttyReleaseFixtureB.Reads.flags -ne 3) { throw 'Failed promote reconciliation was not bounded to three observations.' }
            if ($case -in @('draft','cancelled-before','tagless-draft') -and ($errorMessage -notmatch 'sole match' -or $errorMessage -notmatch 'tagless draft' -or $errorMessage -notmatch 'gh api --method DELETE' -or $errorMessage -match 'gh release delete')) { throw 'Manual recovery did not guard shared/tagless drafts.' }
            if ($case -in @('manifest-missing','missing') -and $errorMessage -match 'gh release delete') { throw 'Published refusal gave destructive advice.' }
            if ($case -eq 'expired' -and ($errorMessage -notmatch '42344250161.*flagship-portable-x64-42344250161.*2026-11-21T06:07:57' -or
                $errorMessage -notmatch 'Recovery: gh workflow run test\.yml --repo amanthanvi/noctty --ref v1\.3\.136, then retry promotion with the new Test run ID, the original Release run ID 42346135091 and the original manifest digest\z')) { throw 'Expiry omitted its identity or recovery command.' }
        } else {
            if ($errorMessage) { throw "Fixture $case unexpectedly failed: $errorMessage" }
            $edits = @($global:NocttyReleaseFixtureB.Calls | Where-Object { $_ -ceq 'edit' }).Count
            $skipVerify = $case -like 'outcome-*' -or $case -in @('failed-scoop','failed-winget','failed-chocolatey','rerun','cancelled-after')
            $stable = $case -like 'outcome-*' -or $case -in @('resume','failed-verify','failed-scoop','failed-winget','failed-chocolatey','rerun','cancelled-after')
            if ($edits -ne $(if ($stable) { 0 } else { 1 }) -or
                $global:NocttyReleaseFixtureB.Calls.Contains('verify') -eq $skipVerify -or
                -not $global:NocttyReleaseFixtureB.Calls.Contains('copy:1.3.136:False') -or
                $global:NocttyReleaseFixtureB.Calls.Contains('copy:1.3.136:True') -eq $skipVerify) { throw "Fixture $case skipped a required orchestration step." }
            if ($case -like 'outcome-*') {
                $outputs=Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw
                $scoop=($case -eq 'outcome-legacy').ToString().ToLowerInvariant()
                $choco=($case -ne 'outcome-present').ToString().ToLowerInvariant()
                if ($outputs -notmatch "publish_scoop=$scoop" -or $outputs -notmatch "publish_chocolatey=$choco") { throw 'Publisher outcome was not authenticated for resume.' }
            }
            if ($case -eq 'annotated' -and -not $global:NocttyReleaseFixtureB.Calls.Contains('peel')) { throw 'Annotated tag was not peeled.' }
            if ($case -eq 'rerun' -and (-not $global:NocttyReleaseFixtureB.Calls.Contains('attempt:1/jobs') -or -not $global:NocttyReleaseFixtureB.Calls.Contains('attempt:2/jobs'))) { throw 'Resume skipped an attempt.' }
            if ($case -eq 'generator-secrets' -and $env:SCOOP_BUCKET_TOKEN -cne 'fixture') { throw 'Generator failed to restore credentials.' }
            if ($case -like 'failed-*' -or $case -in @('rerun','cancelled-after','cancelled-prerelease')) {
                $outputs = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw
                $wantScoop = $case -notin @('failed-winget','failed-chocolatey')
                $wantWinGet = $case -ne 'failed-chocolatey'
                if ($outputs -notmatch ("publish_scoop=" + $wantScoop.ToString().ToLowerInvariant()) -or $outputs -notmatch ("publish_winget=" + $wantWinGet.ToString().ToLowerInvariant()) -or $outputs -notmatch 'publish_chocolatey=true') { throw 'Resume did not start at the first incomplete channel.' }
                $log = Get-Content -LiteralPath (Join-Path $resultDirectory "case-$case.log") -Raw
                if ($log -notmatch 'PublishedReleaseResume') { throw 'Recovery path was not named.' }
            }
        }
        $results.Add([ordered]@{ case = $case; result = 'pass'; expectedError = $cases[$case]; calls = @($global:NocttyReleaseFixtureB.Calls) })
        Write-Host "Fixture B $case`: PASS"
    }
    if ($null -eq $global:NocttyReleaseFixtureB.Release) {
        $global:NocttyReleaseFixtureB.Release=$record.release | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $global:NocttyReleaseFixtureB.Release | Add-Member -NotePropertyName id -NotePropertyValue 136 -Force
    }
    foreach ($case in @('build', 'build-stable', 'build-retry', 'build-lost-response', 'build-exhausted', 'build-drift', 'build-existing', 'build-draft', 'build-upload-starter','build-absent-tag','build-tag-mismatch','build-annotated','build-annotated-mismatch','build-edit-lost','build-edit-refused','build-read-retry','build-read-exhausted','build-publish-flags','build-create-lost','build-create-delay','build-create-refused','build-create-identity','build-create-other-writer','build-create-id-lag','build-create-id-exhausted','build-preflight-id-404','build-preflight-id-empty','build-preflight-id-empty-lag','build-tag-lag','build-tag-exhausted','build-tag-503','build-tag-empty','build-latest-empty','build-stable-latest-lag','build-stable-latest-exhausted','build-stable-latest-404','build-stable-latest-503','build-publish-lag','build-after-publish-drift','build-create-existing-tag-target')) {
        if ($CaseFilter -and $case -cnotin $CaseFilter) { continue }
        $activeCase = $case
        $global:NocttyReleaseFixtureB.Case = $case
        $global:NocttyReleaseFixtureB.Calls.Clear()
        $global:NocttyReleaseFixtureB.Reads=@{}
        $global:NocttyReleaseFixtureB.Release.draft = $case -eq 'build-draft'
        $global:NocttyReleaseFixtureB.BuildCreated = $false
        $global:NocttyReleaseFixtureB.ReadFailures = 0
        $global:NocttyReleaseFixtureB.Release.assets = @($record.release.assets) + [pscustomobject]@{name='release-manifest.json';size=1;digest='sha256:' + ('0'*64)}
        $message = $null
        try {
            & (Join-Path $sourceRoot 'scripts/release-publish-github.ps1') -Tag v1.3.136 -Version 1.3.136 -Title 'noctty 1.3.136' -VersionLine 1.3 -UpstreamBaseVersion 1.3.2 -Prerelease $(if ($case -like 'build-stable*') { 'false' } else { 'true' }) -CandidateSha $sha -ArtifactRoot (Join-Path $primary 'dist/artifacts') *>&1 |
                Out-File -LiteralPath (Join-Path $resultDirectory "case-$case.log")
        } catch { $message = $_.Exception.Message }
        if ($case -in @('build-exhausted','build-drift','build-upload-starter')) {
            $expected = if ($case -eq 'build-exhausted') { 'IncompleteRelease' } else { 'AssetDigestMismatch' }
            if ($message -notmatch $expected -or $global:NocttyReleaseFixtureB.Calls.Contains('publish')) { throw "Build failure control $case failed: $message" }
            if ($case -eq 'build-exhausted' -and @($global:NocttyReleaseFixtureB.Calls | Where-Object { $_ -ceq 'upload:noctty-icon.svg' }).Count -ne 3) { throw 'Upload retry was not bounded at three.' }
        } elseif ($case -eq 'build-after-publish-drift') {
            if ($message -notmatch 'AssetDigestMismatch' -or -not $global:NocttyReleaseFixtureB.Calls.Contains('publish')) { throw 'Published asset drift was accepted.' }
        } elseif ($case -in @('build-create-refused','build-create-identity')) {
            $expected=if($case -eq 'build-create-refused'){'ReleaseCreateUnconfirmed'}else{'ReleaseIdentityMismatch'}
            if ($case -eq 'build-create-refused' -and $global:NocttyReleaseFixtureB.Reads.create -ne 3) { throw 'Create discovery was not bounded to three observations.' }
            if ($message -notmatch $expected -or $global:NocttyReleaseFixtureB.Calls.Contains('publish') -or @($global:NocttyReleaseFixtureB.Calls|Where-Object {$_ -eq 'create'}).Count -ne 1) { throw "Create reconciliation failed: $message" }
        } elseif ($case -in @('build-preflight-id-empty','build-preflight-id-empty-lag')) {
            $expected = if ($case -eq 'build-preflight-id-empty') { 'ReleaseLookupIncomplete' } else { 'already exists' }
            $calls = $global:NocttyReleaseFixtureB.Calls
            if ($message -notmatch $expected -or $global:NocttyReleaseFixtureB.Reads['empty-id'] -ne 3 -or
                @($calls | Where-Object { $_ -eq 'create' -or $_ -like 'upload:*' -or $_ -eq 'publish' }).Count) {
                throw "Preflight empty-ID control failed for ${case}: $message"
            }
        } elseif ($case -in @('build-create-other-writer','build-create-id-exhausted','build-preflight-id-404')) {
            $expected = switch ($case) {
                'build-create-other-writer' { 'ReleaseDraftOwnershipUnconfirmed' }
                'build-create-id-exhausted' { 'ReleaseCreateUnconfirmed' }
                'build-preflight-id-404' { 'HTTP 404' }
            }
            $calls = $global:NocttyReleaseFixtureB.Calls
            $expectedReads = if ($case -eq 'build-create-id-exhausted') { 3 } else { 1 }
            if ($message -notmatch $expected -or @($calls | Where-Object { $_ -like 'upload:*' -or $_ -eq 'publish' }).Count -or
                @($calls | Where-Object { $_ -eq 'id-release-read' }).Count -ne $expectedReads -or
                @($calls | Where-Object { $_ -eq 'create' }).Count -ne [int]($case -ne 'build-preflight-id-404')) {
                throw "Create discovery refusal failed for ${case}: $message"
            }
        } elseif ($case -in @('build-tag-empty','build-latest-empty')) {
            $key = if ($case -eq 'build-tag-empty') { 'tag' } else { 'latest' }
            $calls = $global:NocttyReleaseFixtureB.Calls
            if ($message -notmatch '^ReleaseLookupIncomplete:' -or $global:NocttyReleaseFixtureB.Reads[$key] -ne 3) {
                throw "Empty $key response did not refuse after three reads: $message"
            }
            if ($key -eq 'tag' -and @($calls | Where-Object { $_ -in @('create','publish') -or $_ -like 'upload:*' }).Count) {
                throw 'Build mutated after an empty tag-ref response.'
            }
            if ($key -eq 'latest' -and (@($calls | Where-Object { $_ -eq 'publish' }).Count -ne 1 -or
                $global:NocttyReleaseFixtureB.Release.draft -or -not $global:NocttyReleaseFixtureB.Release.prerelease)) {
                throw 'An empty latest response did not preserve the published prerelease.'
            }
        } elseif ($case -in @('build-tag-exhausted','build-stable-latest-exhausted')) {
            $expected=if($case -eq 'build-tag-exhausted'){'ReleaseTagUnconfirmed'}else{'ReleaseLatestUnconfirmed'}
            $key=if($case -eq 'build-tag-exhausted'){'tag'}else{'latest'}
            if ($message -notmatch $expected -or $global:NocttyReleaseFixtureB.Reads[$key] -ne 3) { throw "Post-publication retry bound failed: $message" }
        } elseif ($case -in @('build-tag-mismatch' ,'build-annotated-mismatch')) {
            if ($message -notmatch 'TagIdentityMismatch' -or $global:NocttyReleaseFixtureB.Calls.Contains('create')) { throw 'Build mutated a mismatched remote tag.' }
        } elseif ($case -in @('build-edit-refused','build-publish-flags','build-read-exhausted')) {
            if ($message -notmatch 'ReleasePublishUnconfirmed|after 3 attempts' -or -not $global:NocttyReleaseFixtureB.Calls.Contains('publish')) { throw "Publish reconciliation control failed: $message" }
        } elseif ($case -eq 'build-draft') {
            if ($message -notmatch 'DraftRelease' -or $global:NocttyReleaseFixtureB.Calls.Contains('create')) { throw 'Existing draft did not reach its named refusal.' }
        } elseif ($case -eq 'build-existing') {
            if ($message -notmatch 'already exists' -or $global:NocttyReleaseFixtureB.Calls.Contains('create')) { throw 'Build publisher must refuse an existing release.' }
        } else {
            if ($message -or -not $global:NocttyReleaseFixtureB.Calls.Contains('publish') -or @($global:NocttyReleaseFixtureB.Release.assets).Count -ne 13) { throw "Build publisher fixture failed: $message" }
            if ($case -eq 'build-create-id-lag' -and $global:NocttyReleaseFixtureB.Reads['create-id'] -ne 3) { throw 'Draft ID discovery did not recover on the third observation.' }
            if ($case -eq 'build-retry' -and @($global:NocttyReleaseFixtureB.Calls | Where-Object { $_ -ceq 'upload:noctty-icon.svg' }).Count -ne 3) { throw 'Transient upload was not retried.' }
        }
        if (@($global:NocttyReleaseFixtureB.Calls | Where-Object { $_ -eq 'create' }).Count -gt 1) { throw 'Create must not be reissued during read reconciliation.' }
        if ($global:NocttyReleaseFixtureB.Calls.Contains('tag-release-read')) { throw 'Build used the published-only tag endpoint.' }
        $results.Add([ordered]@{ case = $case; result = 'pass'; calls = @($global:NocttyReleaseFixtureB.Calls) })
        Write-Host "Fixture B $case`: PASS"
    }
} finally {
    Remove-Item Function:\gh,Function:\Invoke-FixtureGh,Function:\Get-FixtureReadCount,Function:\git
    $global:NocttyReleaseFixtureB = $previousFixtureContext
    $global:LASTEXITCODE = 0
}
Write-Host "Release promotion fixture B: PASS ($($results.Count) cases, $($filesA.Count) files identical across two checkout roots, 12 real assets)."
$passed = $true

} catch {
    $results.Add([ordered]@{ case = $activeCase; result = 'fail'; message = $_.Exception.Message })
    [IO.File]::WriteAllText([IO.Path]::Combine($resultDirectory, 'results.json'), (ConvertTo-Json -InputObject $results.ToArray() -Depth 6) + "`n")
    Write-Warning "Fixture B retained text evidence at: $resultDirectory"
    throw
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    $global:NocttyReleaseFixtureB = $previousFixtureContext
    if ($passed) {
        Remove-ReleaseFixtureDirectory -RunDirectory $resultDirectory
    } elseif (Test-Path -LiteralPath $bulk) {
        $bulkItem = Get-Item -LiteralPath $bulk -Force
        if ($bulkItem -isnot [IO.DirectoryInfo] -or
            ($bulkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not [string]::Equals($bulkItem.Parent.FullName, $resultDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Fixture B cleanup refused a bulk path outside its run directory.'
        }
        Remove-Item -LiteralPath $bulk -Recurse -Force -WhatIf:$false
    }
}
