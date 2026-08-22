[CmdletBinding()]
param(
    [string] $Version = '0.0.1',
    [string] $Architecture = $null,
    [switch] $ShowGeneratedFiles
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts\windows-architecture.ps1')
$Architecture = (Get-WindowsPackageArchitecture -Architecture $(if ($Architecture) { $Architecture } else { Get-DefaultWindowsPackageArchitecture })).Name
$packageScript = Join-Path $repoRoot 'scripts\package-package-managers.ps1'
$scratchName = 'package-chocolatey-{0}' -f [guid]::NewGuid().ToString('N')
$scratchRelative = Join-Path 'dist' $scratchName
$scratchRoot = Join-Path $repoRoot $scratchRelative
$artifactRelative = Join-Path $scratchRelative 'artifacts'
$artifactRoot = Join-Path $repoRoot $artifactRelative
$outputRelative = Join-Path $scratchRelative 'output'
$outputRoot = Join-Path $repoRoot $outputRelative
$packRoot = Join-Path ([System.IO.Path]::GetTempPath()) $scratchName

try {
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

    $setupName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind setup
    $portableName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind portable
    $checksumsName = New-WindowsPackageArtifactName -Version $Version -Architecture $Architecture -Kind checksums
    $setupPath = Join-Path $artifactRoot $setupName
    $portablePath = Join-Path $artifactRoot $portableName
    $checksumsPath = Join-Path $artifactRoot $checksumsName
    $iconPath = Join-Path $artifactRoot 'noctty-icon.svg'

    Set-Content -LiteralPath $setupPath -Value "fake signed setup for $Architecture" -NoNewline
    Set-Content -LiteralPath $portablePath -Value "fake portable archive for $Architecture" -NoNewline
    Set-Content -LiteralPath $iconPath -Value '<svg xmlns="http://www.w3.org/2000/svg" />' -NoNewline
    $setupSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
    $portableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $portablePath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumsPath -Value @(
        "$setupSha256 *$setupName"
        "$portableSha256 *$portableName"
    )

    & $packageScript `
        -Version $Version `
        -Architectures @($Architecture) `
        -ArtifactRoot $artifactRelative `
        -OutputRoot $outputRelative

    $nuspecPath = Join-Path $outputRoot 'chocolatey\noctty.nuspec'
    $installScriptPath = Join-Path $outputRoot 'chocolatey\tools\chocolateyInstall.ps1'
    $metadataPath = Join-Path $outputRoot 'metadata.json'
    foreach ($path in @($nuspecPath, $installScriptPath, $metadataPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing generated Chocolatey path: $path"
        }
    }

    $nuspec = [System.Xml.XmlDocument]::new()
    $nuspec.Load($nuspecPath)
    $nuspecNamespace = 'http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd'
    if ($nuspec.DocumentElement.LocalName -cne 'package' -or $nuspec.DocumentElement.NamespaceURI -cne $nuspecNamespace) {
        throw 'Generated nuspec does not use the expected NuGet package schema shape.'
    }

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($nuspec.NameTable)
    $namespaceManager.AddNamespace('n', $nuspecNamespace)
    $metadataNode = $nuspec.SelectSingleNode('/n:package/n:metadata', $namespaceManager)
    if ($null -eq $metadataNode) {
        throw 'Generated nuspec is missing its metadata element.'
    }

    $requiredMetadata = @(
        'id',
        'version',
        'title',
        'authors',
        'owners',
        'projectUrl',
        'licenseUrl',
        'iconUrl',
        'requireLicenseAcceptance',
        'summary',
        'description',
        'releaseNotes',
        'copyright',
        'tags'
    )
    foreach ($elementName in $requiredMetadata) {
        $element = $metadataNode.SelectSingleNode("n:$elementName", $namespaceManager)
        if ($null -eq $element -or [string]::IsNullOrWhiteSpace($element.InnerText)) {
            throw "Generated nuspec is missing required metadata: $elementName"
        }
    }

    if ($metadataNode.SelectSingleNode('n:id', $namespaceManager).InnerText -cne 'noctty') {
        throw 'Generated nuspec package id is not noctty.'
    }
    if ($metadataNode.SelectSingleNode('n:version', $namespaceManager).InnerText -cne $Version) {
        throw "Generated nuspec version does not match requested version $Version."
    }
    if ($metadataNode.SelectSingleNode('n:requireLicenseAcceptance', $namespaceManager).InnerText -cne 'false') {
        throw 'Generated nuspec must not require license acceptance.'
    }

    $installScript = Get-Content -LiteralPath $installScriptPath -Raw
    $expectedSetupUrl = "https://github.com/amanthanvi/noctty/releases/download/v$Version/$setupName"
    foreach ($expectedText in @(
        $setupSha256,
        $expectedSetupUrl,
        "checksumType = 'sha256'",
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS',
        'Install-ChocolateyPackage @packageArgs'
    )) {
        if (-not $installScript.Contains($expectedText, [StringComparison]::Ordinal)) {
            throw "Generated install script is missing expected content: $expectedText"
        }
    }
    foreach ($expectedArchitecture in @('x64', 'arm64')) {
        if (-not $installScript.Contains($expectedArchitecture, [StringComparison]::Ordinal)) {
            throw "Generated install script is missing architecture selection for $expectedArchitecture."
        }
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.chocolatey.packageName -cne 'noctty' -or
        $metadata.chocolatey.nuspecPath -cne $nuspecPath -or
        $metadata.chocolatey.packageDirectory -cne (Split-Path -Parent $nuspecPath)) {
        throw 'metadata.json has an invalid Chocolatey block.'
    }

    $uninstallScriptPath = Join-Path $outputRoot 'chocolatey\tools\chocolateyUninstall.ps1'
    if (Test-Path -LiteralPath $uninstallScriptPath) {
        throw 'The Inno package should rely on Chocolatey auto-uninstall, not ship an uninstall script.'
    }

    if ($ShowGeneratedFiles) {
        Write-Host '--- generated noctty.nuspec ---'
        Get-Content -LiteralPath $nuspecPath
        Write-Host '--- generated chocolateyInstall.ps1 ---'
        Get-Content -LiteralPath $installScriptPath
    }

    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($null -eq $choco) {
        Write-Host 'Skipping choco pack: choco is not on PATH.'
    }
    else {
        New-Item -ItemType Directory -Path $packRoot -Force | Out-Null
        & $choco.Source pack $nuspecPath "--output-directory=$packRoot" --limit-output
        if ($LASTEXITCODE -ne 0) {
            throw "choco pack failed with exit code $LASTEXITCODE."
        }

        $packages = @(Get-ChildItem -LiteralPath $packRoot -Filter '*.nupkg' -File)
        if ($packages.Count -ne 1) {
            throw "Expected one .nupkg from choco pack; found $($packages.Count)."
        }
        Write-Host "choco pack produced: $($packages[0].FullName)"
    }

    Write-Host "Chocolatey package validation: PASS (version=$Version, architecture=$Architecture)"
}
finally {
    if (Test-Path -LiteralPath $packRoot) {
        Remove-Item -LiteralPath $packRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}
