# Shared definition: payload = every asset except release-manifest.json;
# permitted = exactly that payload plus the manifest. The summary digest is
# the manifest's trust anchor, never a field inside the manifest itself.
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

function Get-ReleasePayloadPaths {
    param([string] $ArtifactRoot, [string] $Version)
    foreach ($architecture in (Get-WindowsPackageArchitectures)) {
        $directory = Join-Path $ArtifactRoot "noctty-$Version-windows-$architecture"
        $kinds = @('setup', 'portable')
        if ([version]$Version -ge [version]'1.3.124') { $kinds += 'manifest' }
        if ([version]$Version -ge [version]'1.3.133') { $kinds += 'symbols' }
        $kinds += 'checksums'
        foreach ($kind in $kinds) {
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
        [string] $TestRunId, [string] $ReleaseRunId,
        [string] $ArtifactRoot, [string] $CandidateDirectory
    )
    $generatorBlob = & git -C $CandidateDirectory rev-parse "${CandidateSha}:scripts/package-package-managers.ps1"
    if ($LASTEXITCODE -ne 0 -or $generatorBlob -notmatch '\A[0-9a-f]{40}\z') { throw 'Cannot read the candidate package-manager generator blob.' }
    $diskBlob = & git -C $CandidateDirectory hash-object scripts/package-package-managers.ps1
    if ($LASTEXITCODE -ne 0 -or $diskBlob -cne $generatorBlob) { throw 'Candidate generator has uncommitted changes.' }
    $primary = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
    # Finalize the legacy alias before hashing it. Publication never rewrites it.
    Copy-Item -LiteralPath (Join-Path $primary 'SHA256SUMS-windows-x64.txt') -Destination (Join-Path $primary 'SHA256SUMS.txt') -Force
    $manifest = [ordered]@{
        schemaVersion = 1
        tag = $Tag
        version = $Version
        candidateSha = $CandidateSha
        testRunId = $TestRunId
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
        [string] $ExpectedSha256,
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string] $DownloadDirectory,
        [string] $Tag, [string] $CandidateSha, [string] $TestRunId,
        [string] $ReleaseRunId,
        [string] $ArtifactRoot,
        [switch] $Historical
    )
    $manifestDigest = Get-FileSha256Lower $Path
    if ($ExpectedSha256 -and ($ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $manifestDigest -cne $ExpectedSha256)) {
        throw 'ManifestDigestMismatch: release-manifest.json differs from the run-summary digest.'
    }
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.tag -cne $Tag -or
        $manifest.version -cne $Tag.Substring(1) -or $manifest.candidateSha -cne $CandidateSha -or
        $CandidateSha -cnotmatch '\A[0-9a-f]{40}\z') { throw 'ManifestIdentityMismatch: tag, version or candidate differs.' }
    # A manifest written before 2026-11-22 also records an interactive evidence run; nothing requires one now, so
    # that field is not read.
    foreach ($run in @('Test', 'Release')) {
        $name = $run.ToLowerInvariant() + 'RunId'
        $expected = Get-Variable -Name ($run + 'RunId') -ValueOnly
        # The Test input may be fresh same-SHA evidence after expiry.
        # The manifest retains the original accepted runs; release identity is
        # immutable. Assert-ReleaseEvidence authenticates every supplied run.
        if ([string]$manifest.$name -cnotmatch '\A[0-9]+\z' -or $expected -cnotmatch '\A[0-9]+\z' -or
            ($run -ceq 'Release' -and [string]$manifest.$name -cne $expected)) {
            throw "ManifestIdentityMismatch: $name differs."
        }
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $payloadPaths = @(Get-ReleasePayloadPaths -ArtifactRoot $(if ($ArtifactRoot) { $ArtifactRoot } else { '.' }) -Version $manifest.version)
    $expectedNames = @($payloadPaths | ForEach-Object { [IO.Path]::GetFileName($_) })
    foreach ($entry in @($manifest.payload)) {
        $name = [string]$entry.name
        if ($name -ceq 'release-manifest.json' -or $name -cnotmatch '\A[0-9A-Za-z][0-9A-Za-z._-]*\z' -or -not $names.Add($name)) {
            throw 'ManifestPayloadInvalid: payload lists itself, duplicates a name or contains an invalid asset name.'
        }
        if ($entry.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or ($entry.size -isnot [long] -and $entry.size -isnot [int])) {
            throw 'ManifestPayloadInvalid: invalid size or SHA-256.'
        }
        if ($name -cnotin $expectedNames) { throw 'AssetSetMismatch: unexpected manifest payload.' }
        $asset = @($Release.assets | Where-Object { $_.name -ceq $name })
        $file = Join-Path $DownloadDirectory $name
        if ($ArtifactRoot) { $file = @($payloadPaths | Where-Object { [IO.Path]::GetFileName($_) -ceq $name })[0] }
        if ($asset.Count -ne 1 -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "AssetSetMismatch: missing payload $name." }
        $hash = Get-FileSha256Lower $file
        if ((Get-Item -LiteralPath $file).Length -ne $entry.size -or $asset[0].size -ne $entry.size -or
            $hash -cne $entry.sha256 -or [string]$asset[0].digest -cne "sha256:$hash") {
            throw "AssetDigestMismatch: $name differs from its manifest or GitHub digest."
        }
    }
    if ($names.Count -eq 0) { throw 'ManifestPayloadInvalid: payload is empty.' }
    if ($names.Count -ne $expectedNames.Count -or @($expectedNames | Where-Object { -not $names.Contains($_) }).Count) {
        throw 'AssetSetMismatch: manifest payload differs from the shared release payload definition.'
    }
    if (-not $Historical) {
        [void]$names.Add('release-manifest.json')
        $asset = @($Release.assets | Where-Object { $_.name -ceq 'release-manifest.json' })
        if ($asset.Count -ne 1 -or $asset[0].digest -cne "sha256:$manifestDigest" -or
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
