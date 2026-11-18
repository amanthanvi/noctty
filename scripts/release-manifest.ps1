# Shared definition: payload = every asset except release-manifest.json;
# permitted = exactly that payload plus the manifest. The summary digest is
# the manifest's trust anchor, never a field inside the manifest itself.
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

function Get-ReleasePayloadPaths {
    param([string] $ArtifactRoot, [string] $Version)
    foreach ($architecture in (Get-WindowsPackageArchitectures)) {
        $directory = Join-Path $ArtifactRoot "noctty-$Version-windows-$architecture"
        foreach ($kind in @('setup', 'portable', 'manifest', 'symbols', 'checksums')) {
            Join-Path $directory (New-WindowsPackageArtifactName -Version $Version -Architecture $architecture -Kind $kind)
        }
    }
    $primary = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
    Join-Path $primary 'SHA256SUMS.txt'
    Join-Path $primary 'noctty-icon.svg'
}

function Get-ReleaseFileRecord {
    param([string] $Path, [string] $Name)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    [ordered]@{ name = $Name; size = $file.Length; sha256 = Get-FileSha256Lower $Path }
}

function Get-PackageManagerFileRecords {
    param([string] $PrimaryDirectory)
    $root = Join-Path $PrimaryDirectory 'package-managers'
    foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName)) {
        Get-ReleaseFileRecord -Path $file.FullName -Name ([IO.Path]::GetRelativePath($PrimaryDirectory, $file.FullName).Replace('\', '/'))
    }
}

function Write-ReleaseManifest {
    param(
        [string] $Tag, [string] $Version, [string] $CandidateSha,
        [string] $TestRunId, [string] $EvidenceRunId, [string] $ReleaseRunId,
        [string] $ArtifactRoot, [string] $CandidateDirectory
    )
    $generatorBlob = & git -C $CandidateDirectory rev-parse "${CandidateSha}:scripts/package-package-managers.ps1"
    if ($LASTEXITCODE -ne 0 -or $generatorBlob -notmatch '\A[0-9a-f]{40}\z') { throw 'Cannot read the candidate package-manager generator blob.' }
    $diskBlob = & git -C $CandidateDirectory hash-object scripts/package-package-managers.ps1
    if ($LASTEXITCODE -ne 0 -or $diskBlob -cne $generatorBlob) { throw 'Candidate generator has uncommitted changes.' }
    $primary = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
    $manifest = [ordered]@{
        schemaVersion = 1
        tag = $Tag
        version = $Version
        candidateSha = $CandidateSha
        testRunId = $TestRunId
        evidenceRunId = $EvidenceRunId
        releaseRunId = $ReleaseRunId
        payload = @(Get-ReleasePayloadPaths -ArtifactRoot $ArtifactRoot -Version $Version | ForEach-Object {
            Get-ReleaseFileRecord -Path $_ -Name ([IO.Path]::GetFileName($_))
        })
        packageManagers = [ordered]@{
            generatorBlob = $generatorBlob.Trim()
            files = @(Get-PackageManagerFileRecords -PrimaryDirectory $primary)
        }
    }
    $path = Join-Path $primary 'release-manifest.json'
    [IO.File]::WriteAllText($path, (($manifest | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $digest = Get-FileSha256Lower $path
    Write-Host "release-manifest.json SHA-256: $digest"
    if ($env:GITHUB_STEP_SUMMARY) {
        "release-manifest.json SHA-256: ``$digest``" | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
    if ($env:GITHUB_OUTPUT) { "manifest_sha256=$digest" | Out-File -LiteralPath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
    return $path
}

function Assert-ReleaseManifest {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedSha256,
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string] $DownloadDirectory,
        [string] $Tag, [string] $CandidateSha, [string] $TestRunId,
        [string] $EvidenceRunId, [string] $ReleaseRunId,
        [switch] $Historical
    )
    if ($ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or (Get-FileSha256Lower $Path) -cne $ExpectedSha256) {
        throw 'ManifestDigestMismatch: release-manifest.json differs from the run-summary digest.'
    }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.tag -cne $Tag -or
        $manifest.version -cne $Tag.Substring(1) -or $manifest.candidateSha -cne $CandidateSha -or
        $CandidateSha -cnotmatch '\A[0-9a-f]{40}\z') { throw 'ManifestIdentityMismatch: tag, version or candidate differs.' }
    foreach ($run in @('Test', 'Evidence', 'Release')) {
        $name = $run.ToLowerInvariant() + 'RunId'
        $expected = Get-Variable -Name ($run + 'RunId') -ValueOnly
        # Test/interactive inputs may be fresh same-SHA evidence after expiry.
        # The manifest retains the original accepted runs; release identity is
        # immutable. Assert-ReleaseEvidence authenticates every supplied run.
        if ([string]$manifest.$name -cnotmatch '\A[0-9]+\z' -or $expected -cnotmatch '\A[0-9]+\z' -or
            ($run -ceq 'Release' -and [string]$manifest.$name -cne $expected)) {
            throw "ManifestIdentityMismatch: $name differs."
        }
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.payload)) {
        $name = [string]$entry.name
        if ($name -ceq 'release-manifest.json' -or $name -cnotmatch '\A[0-9A-Za-z][0-9A-Za-z._-]*\z' -or -not $names.Add($name)) {
            throw 'ManifestPayloadInvalid: payload lists itself, duplicates a name or contains an invalid asset name.'
        }
        if ($entry.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $entry.size -isnot [long] -and $entry.size -isnot [int]) {
            throw 'ManifestPayloadInvalid: invalid size or SHA-256.'
        }
        $asset = @($Release.assets | Where-Object { $_.name -ceq $name })
        $file = Join-Path $DownloadDirectory $name
        if ($asset.Count -ne 1 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "AssetSetMismatch: missing payload $name." }
        $hash = Get-FileSha256Lower $file
        if ((Get-Item -LiteralPath $file).Length -ne $entry.size -or $asset[0].size -ne $entry.size -or
            $hash -cne $entry.sha256 -or [string]$asset[0].digest -cne "sha256:$hash") {
            throw "AssetDigestMismatch: $name differs from its manifest or GitHub digest."
        }
    }
    if ($names.Count -eq 0) { throw 'ManifestPayloadInvalid: payload is empty.' }
    if (-not $Historical) {
        [void]$names.Add('release-manifest.json')
        $asset = @($Release.assets | Where-Object { $_.name -ceq 'release-manifest.json' })
        if ($asset.Count -ne 1 -or $asset[0].digest -cne "sha256:$ExpectedSha256" -or
            $asset[0].size -ne (Get-Item -LiteralPath $Path).Length) { throw 'ManifestDigestMismatch: GitHub manifest record differs.' }
    }
    if (@($Release.assets).Count -ne $names.Count -or
        @($Release.assets | Where-Object { -not $names.Contains([string]$_.name) }).Count -ne 0) {
        throw 'AssetSetMismatch: permitted assets are exactly the payload plus release-manifest.json.'
    }
    return $manifest
}

function Assert-PackageManagerFiles {
    param($Manifest, [string] $PrimaryDirectory)
    $actual = @(Get-PackageManagerFileRecords -PrimaryDirectory $PrimaryDirectory)
    $expected = @($Manifest.packageManagers.files)
    if ($expected.Count -eq 0 -or $expected.Count -ne $actual.Count -or
        @($expected | Where-Object { $_.name -ceq 'package-managers/metadata.json' }).Count -ne 1) {
        throw 'PackageManagerMismatch: generated file set differs.'
    }
    foreach ($file in $actual) {
        $record = @($expected | Where-Object { $_.name -ceq $file.name })
        if ($record.Count -ne 1 -or $record[0].sha256 -cne $file.sha256 -or $record[0].size -ne $file.size) {
            throw "PackageManagerMismatch: $($file.name) differs from the prerelease."
        }
    }
}
