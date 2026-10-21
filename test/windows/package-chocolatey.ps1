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
# Release version used only for the multi-architecture installer-choice check below.
$dualVersion = '0.0.2'

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
        'packageSourceUrl',
        'title',
        'authors',
        'owners',
        'projectUrl',
        'projectSourceUrl',
        'docsUrl',
        'bugTrackerUrl',
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

    # Chocolatey package-validator rules a first submission must pass:
    # CPMR0076 (an icon from GitHub is a Requirement failure), CPMR0050 (title
    # equal to the id), CPMR0041 (project source URL equal to the project URL).
    $iconUri = [Uri] $metadataNode.SelectSingleNode('n:iconUrl', $namespaceManager).InnerText
    if ($iconUri.Host -match '(?i)(^|\.)(github\.com|githubusercontent\.com|rawgit\.com)$') {
        throw "Generated nuspec iconUrl must not be served from GitHub: $iconUri"
    }
    if ($iconUri.AbsoluteUri -ceq 'https://noctty.com/assets/favicon.svg' -and
        -not (Test-Path -LiteralPath (Join-Path $repoRoot 'site/assets/favicon.svg') -PathType Leaf)) {
        throw 'Generated nuspec iconUrl names site/assets/favicon.svg, which the site no longer ships.'
    }
    $releaseSourceUrl = "https://github.com/amanthanvi/noctty/blob/v$Version/scripts/package-package-managers.ps1"
    if ($metadataNode.SelectSingleNode('n:packageSourceUrl', $namespaceManager).InnerText -cne $releaseSourceUrl) {
        throw "Generated nuspec packageSourceUrl must name the release tag's generator: $releaseSourceUrl"
    }
    if ($metadataNode.SelectSingleNode('n:title', $namespaceManager).InnerText -ceq 'noctty') {
        throw 'Generated nuspec title must not equal the package id.'
    }
    if ($metadataNode.SelectSingleNode('n:projectSourceUrl', $namespaceManager).InnerText -ceq
        $metadataNode.SelectSingleNode('n:projectUrl', $namespaceManager).InnerText) {
        throw 'Generated nuspec projectSourceUrl must differ from projectUrl.'
    }
    $licenseCopyright = (Get-Content -LiteralPath (Join-Path $repoRoot 'LICENSE') | Where-Object { $_ -like 'Copyright*' } | Select-Object -First 1)
    if ($metadataNode.SelectSingleNode('n:copyright', $namespaceManager).InnerText -cne $licenseCopyright) {
        throw "Generated nuspec copyright must match the LICENSE: $licenseCopyright"
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

    # The installer is chosen at install time from the CPU. Chocolatey runs as an emulated x64
    # process on ARM64 Windows, so OSArchitecture alone says x64 there: run the generated script
    # against a stubbed CPU query and check which installer it picks.
    # More than one architecture reads each one's artifacts from the default dist/artifacts layout.
    $dualArtifactDirs = @{}
    foreach ($dualArchitecture in @('x64', 'arm64')) {
        $dualArtifactDirs[$dualArchitecture] = Join-Path $repoRoot "dist\artifacts\noctty-$dualVersion-windows-$dualArchitecture"
        New-Item -ItemType Directory -Path $dualArtifactDirs[$dualArchitecture] -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $dualArtifactDirs['x64'] 'noctty-icon.svg') -Value '<svg xmlns="http://www.w3.org/2000/svg" />' -NoNewline
    $dualInstallers = @{}
    foreach ($dualArchitecture in @('x64', 'arm64')) {
        $dualSetupName = New-WindowsPackageArtifactName -Version $dualVersion -Architecture $dualArchitecture -Kind setup
        $dualPortableName = New-WindowsPackageArtifactName -Version $dualVersion -Architecture $dualArchitecture -Kind portable
        $dualSetupPath = Join-Path $dualArtifactDirs[$dualArchitecture] $dualSetupName
        $dualPortablePath = Join-Path $dualArtifactDirs[$dualArchitecture] $dualPortableName
        Set-Content -LiteralPath $dualSetupPath -Value "fake signed setup for $dualArchitecture" -NoNewline
        Set-Content -LiteralPath $dualPortablePath -Value "fake portable archive for $dualArchitecture" -NoNewline
        $dualSetupSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $dualSetupPath).Hash.ToLowerInvariant()
        $dualPortableSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $dualPortablePath).Hash.ToLowerInvariant()
        Set-Content -LiteralPath (Join-Path $dualArtifactDirs[$dualArchitecture] (New-WindowsPackageArtifactName -Version $dualVersion -Architecture $dualArchitecture -Kind checksums)) -Value @(
            "$dualSetupSha256 *$dualSetupName"
            "$dualPortableSha256 *$dualPortableName"
        )
        $dualInstallers[$dualArchitecture] = @{
            Url = "https://github.com/amanthanvi/noctty/releases/download/v$dualVersion/$dualSetupName"
            Checksum = $dualSetupSha256
        }
    }
    $dualOutputRelative = Join-Path $scratchRelative 'dual-output'
    & $packageScript `
        -Version $dualVersion `
        -Architectures @('x64', 'arm64') `
        -OutputRoot $dualOutputRelative | Out-Null
    $dualInstallScript = Get-Content -LiteralPath (Join-Path $repoRoot (Join-Path $dualOutputRelative 'chocolatey\tools\chocolateyInstall.ps1')) -Raw

    function Get-GeneratedInstallerChoice {
        param([string] $InstallScript, [AllowNull()] $CpuArchitecture)

        $script:chosenInstaller = $null
        function Get-CimInstance {
            [CmdletBinding()]
            param([Parameter(Position = 0)] [string] $ClassName)
            if ("$CpuArchitecture" -eq 'throw') { throw 'CPU query unavailable' }
            if ($null -ne $CpuArchitecture) { [pscustomobject] @{ Architecture = $CpuArchitecture } }
        }
        function Install-ChocolateyPackage {
            [CmdletBinding()]
            param($packageName, $fileType, $url, $checksum, $checksumType, $silentArgs, $validExitCodes)
            $script:chosenInstaller = @{ Url = $url; Checksum = $checksum }
        }
        & ([scriptblock]::Create($InstallScript))
        return $script:chosenInstaller
    }

    $osInstaller = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $installerCases = @(
        @{ Name = 'CPU reports ARM64 (12) while the process reports x64'; Cpu = 12; Expected = 'arm64' },
        @{ Name = 'CPU reports x64 (9)'; Cpu = 9; Expected = $osInstaller },
        @{ Name = 'CPU query returns nothing'; Cpu = $null; Expected = $osInstaller },
        @{ Name = 'CPU query raises an error'; Cpu = 'throw'; Expected = $osInstaller }
    )
    foreach ($case in $installerCases) {
        $choice = Get-GeneratedInstallerChoice -InstallScript $dualInstallScript -CpuArchitecture $case.Cpu
        $want = $dualInstallers[$case.Expected]
        if ($null -eq $choice -or $choice.Url -cne $want.Url -or $choice.Checksum -cne $want.Checksum) {
            throw "Generated install script chose the wrong installer when the $($case.Name): expected $($case.Expected), got $($choice.Url)."
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

    # A moderation fix repacks a published version with a newer generator, and
    # the package must then name that generator's commit, not the release tag.
    $resubmitOutputRelative = Join-Path $scratchRelative 'resubmit'
    & $packageScript `
        -Version $Version `
        -Architectures @($Architecture) `
        -ArtifactRoot $artifactRelative `
        -OutputRoot $resubmitOutputRelative `
        -PackageSourceRef '0123456789abcdef0123456789abcdef01234567' | Out-Null
    $resubmitNuspec = [System.Xml.XmlDocument]::new()
    $resubmitNuspec.Load((Join-Path $repoRoot (Join-Path $resubmitOutputRelative 'chocolatey\noctty.nuspec')))
    $resubmitNamespaces = [System.Xml.XmlNamespaceManager]::new($resubmitNuspec.NameTable)
    $resubmitNamespaces.AddNamespace('n', $nuspecNamespace)
    $resubmitSourceUrl = $resubmitNuspec.SelectSingleNode('/n:package/n:metadata/n:packageSourceUrl', $resubmitNamespaces).InnerText
    if ($resubmitSourceUrl -cne 'https://github.com/amanthanvi/noctty/blob/0123456789abcdef0123456789abcdef01234567/scripts/package-package-managers.ps1') {
        throw "A repacked nuspec must name the generator commit it was built with, got: $resubmitSourceUrl"
    }
    if ($resubmitNuspec.SelectSingleNode('/n:package/n:metadata/n:releaseNotes', $resubmitNamespaces).InnerText -cne
        "https://github.com/amanthanvi/noctty/releases/tag/v$Version") {
        throw 'A repacked nuspec must keep pointing at the original release.'
    }

    # The scripts behind the manual Chocolatey Publish workflow (the publish
    # script is also the Release step's), against fake tools and a loopback feed.
    & (Join-Path $PSScriptRoot 'release-stage-published.ps1')
    & (Join-Path $PSScriptRoot 'release-publish-chocolatey.ps1')

    Write-Host "Chocolatey package validation: PASS (version=$Version, architecture=$Architecture)"
    $global:LASTEXITCODE = 0
}
finally {
    if (Test-Path -LiteralPath $packRoot) {
        Remove-Item -LiteralPath $packRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
    foreach ($dualCleanupArchitecture in @('x64', 'arm64')) {
        $dualCleanupDir = Join-Path $repoRoot "dist/artifacts/noctty-$dualVersion-windows-$dualCleanupArchitecture"
        if (Test-Path -LiteralPath $dualCleanupDir) {
            Remove-Item -LiteralPath $dualCleanupDir -Recurse -Force
        }
    }
}
