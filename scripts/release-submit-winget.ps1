[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $PackageIdentifier = $env:WINGET_PACKAGE_IDENTIFIER,

    [string] $ArtifactRoot,

    [string] $TempDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $env:WINGETCREATE_TOKEN) {
    Write-Host 'Skipping WinGet submit: WINGETCREATE_TOKEN is not configured.'
    return
}
if ([string]::IsNullOrWhiteSpace($PackageIdentifier)) {
    Write-Host 'Skipping WinGet submit: WINGET_PACKAGE_IDENTIFIER is not configured. Initial WinGet bootstrap is still manual.'
    return
}
if (-not $PSCmdlet.ShouldProcess($PackageIdentifier, "submit noctty $Version WinGet manifest")) {
    return
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path $repoRoot 'dist/artifacts'
}
if ([string]::IsNullOrWhiteSpace($TempDirectory)) {
    $TempDirectory = [System.IO.Path]::GetTempPath()
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
$TempDirectory = [System.IO.Path]::GetFullPath($TempDirectory)

$artifactDirectoryX64 = Join-Path $ArtifactRoot "noctty-$Version-windows-x64"
$metadataPath = Join-Path $artifactDirectoryX64 'package-managers/metadata.json'
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$packageIdSegments = $PackageIdentifier.Split('.')
$manifestPath = 'manifests/{0}/{1}' -f `
    $packageIdSegments[0].Substring(0, 1).ToLowerInvariant(), `
    ($packageIdSegments -join '/')
$manifestApiUrl = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$manifestPath"

try {
    Invoke-WebRequest `
        -Uri $manifestApiUrl `
        -Headers @{ 'User-Agent' = 'noctty-release-workflow' } `
        -ErrorAction Stop | Out-Null
}
catch {
    $statusCode = if ($_.Exception.Response) {
        [int]$_.Exception.Response.StatusCode
    } else {
        $null
    }

    if ($statusCode -eq 404) {
        Write-Host "Skipping WinGet submit: $PackageIdentifier is not bootstrapped in microsoft/winget-pkgs ($manifestPath)."
        return
    }
    throw
}

$vcLibsPath = Join-Path $TempDirectory 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
$bundlePath = Join-Path $TempDirectory 'wingetcreate.msixbundle'
Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop
function Install-AppxPackageIfNeeded {
    param(
        [string] $Path,
        [string] $Label
    )

    try {
        Add-AppxPackage -Path $Path -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        # Hosted runners may already contain a newer package. HRESULT
        # 0x80073D06 is success for this prerequisite path.
        if ($message -match '0x80073D06' -or
            $message -match 'higher version of this package is already installed') {
            Write-Host "$Label already satisfied on this runner; skipping package install."
            return
        }
        throw
    }
}

Invoke-WebRequest `
    -Uri 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' `
    -OutFile $vcLibsPath `
    -ErrorAction Stop
Install-AppxPackageIfNeeded `
    -Path $vcLibsPath `
    -Label 'Microsoft.VCLibs.x64.14.00.Desktop'
Invoke-WebRequest `
    -Uri 'https://aka.ms/wingetcreate/latest/msixbundle' `
    -OutFile $bundlePath `
    -ErrorAction Stop
Install-AppxPackageIfNeeded -Path $bundlePath -Label 'wingetcreate bundle'

# wingetcreate update documents URL architecture overrides as "<url>|<arch>".
$installerUrlArgs = @(
    $metadata.winget.installerUrlArgs |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
        ForEach-Object { [string] $_ }
)
$installerArchitectures = @(
    $installerUrlArgs | ForEach-Object {
        if ($_ -cnotmatch '\|(?<architecture>x64|arm64)$') {
            throw "WinGet installer URL must end with an explicit |x64 or |arm64 architecture: $_"
        }
        $Matches.architecture
    }
)
$expectedInstallerArchitectures = @('arm64', 'x64')
if ($installerUrlArgs.Count -ne 2 -or
    (($installerArchitectures | Sort-Object -Unique) -join ',') -ne
        ($expectedInstallerArchitectures -join ',')) {
    throw 'WinGet publishing requires exactly one x64 and one arm64 installer URL.'
}

function Invoke-WinGetCreateUpdate {
    param([string[]] $InstallerUrlArgs)

    $output = & wingetcreate update $PackageIdentifier `
        --version $Version `
        --urls $InstallerUrlArgs `
        --release-notes-url $metadata.release.releaseUrl `
        --submit `
        --no-open `
        --token $env:WINGETCREATE_TOKEN 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }

    return @{
        ExitCode = $exitCode
        Output = (@($output) -join "`n")
    }
}

$result = Invoke-WinGetCreateUpdate -InstallerUrlArgs $installerUrlArgs
if ($result.ExitCode -ne 0) {
    throw "wingetcreate update failed with exit code $($result.ExitCode)"
}
