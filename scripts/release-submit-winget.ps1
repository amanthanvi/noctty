[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [string] $PackageIdentifier = $env:WINGET_PACKAGE_IDENTIFIER,

    [string] $ArtifactRoot,

    [string] $TempDirectory = $env:TEMP,

    [ValidateRange(1, 300)]
    [int] $NetworkTimeoutSeconds = 60,

    [ValidateRange(1, 1800)]
    [int] $WinGetCreateTimeoutSeconds = 600,

    [ValidateRange(1, 120)]
    [int] $ProcessTerminationTimeoutSeconds = 30,

    [ValidateRange(1, 120)]
    [int] $StreamDrainTimeoutSeconds = 30
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
        -TimeoutSec $NetworkTimeoutSeconds `
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
    -TimeoutSec $NetworkTimeoutSeconds `
    -ErrorAction Stop
Install-AppxPackageIfNeeded `
    -Path $vcLibsPath `
    -Label 'Microsoft.VCLibs.x64.14.00.Desktop'
Invoke-WebRequest `
    -Uri 'https://aka.ms/wingetcreate/latest/msixbundle' `
    -OutFile $bundlePath `
    -TimeoutSec $NetworkTimeoutSeconds `
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

    $wingetCreateCommand = Get-Command `
        wingetcreate `
        -CommandType Application `
        -ErrorAction Stop |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($wingetCreateCommand.Source)) {
        throw 'Unable to resolve the wingetcreate executable path.'
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $wingetCreateCommand.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $arguments = @(
        'update',
        $PackageIdentifier,
        '--version',
        $Version,
        '--urls'
    )
    $arguments += $InstallerUrlArgs
    $arguments += @(
        '--release-notes-url',
        [string] $metadata.release.releaseUrl,
        '--submit',
        '--no-open',
        '--token'
    )
    foreach ($argument in $arguments) {
        [void] $startInfo.ArgumentList.Add([string] $argument)
    }
    [void] $startInfo.ArgumentList.Add($env:WINGETCREATE_TOKEN)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $standardOutputTask = $null
    $standardErrorTask = $null
    $standardOutput = ''
    $standardError = ''
    $exitCode = $null
    $timedOut = $false
    $terminationError = $null
    try {
        if (-not $process.Start()) {
            throw 'Failed to start wingetcreate.'
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($WinGetCreateTimeoutSeconds * 1000)) {
            $timedOut = $true
            try {
                $process.Kill()
            }
            catch {
                $terminationError = $_.Exception.Message
            }
            try {
                if (-not $process.WaitForExit($ProcessTerminationTimeoutSeconds * 1000)) {
                    $terminationError = 'the recorded process did not exit after termination'
                }
            }
            catch {
                $terminationError = $_.Exception.Message
            }
        }

        $streamTasks = [System.Threading.Tasks.Task[]] @(
            $standardOutputTask,
            $standardErrorTask
        )
        if (-not [System.Threading.Tasks.Task]::WaitAll(
            $streamTasks,
            $StreamDrainTimeoutSeconds * 1000
        )) {
            throw "Timed out draining wingetcreate output after $StreamDrainTimeoutSeconds seconds."
        }
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
        }
    }
    finally {
        $process.Dispose()
    }

    $output = @($standardOutput, $standardError) -join "`n"
    if (-not [string]::IsNullOrEmpty($env:WINGETCREATE_TOKEN)) {
        $output = $output.Replace($env:WINGETCREATE_TOKEN, '[REDACTED]')
    }
    if (-not [string]::IsNullOrWhiteSpace($output)) {
        $output -split '\r?\n' | ForEach-Object { Write-Host $_ }
    }
    if ($timedOut) {
        $detail = if ($terminationError) {
            " Termination detail: $terminationError."
        } else {
            ''
        }
        throw "wingetcreate update timed out after $WinGetCreateTimeoutSeconds seconds.$detail"
    }

    return @{
        ExitCode = $exitCode
        Output = $output
    }
}

$result = Invoke-WinGetCreateUpdate -InstallerUrlArgs $installerUrlArgs
if ($result.ExitCode -ne 0) {
    throw "wingetcreate update failed with exit code $($result.ExitCode)"
}
