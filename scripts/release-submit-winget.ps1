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

if (-not $env:WINGET_CREATE_GITHUB_TOKEN) {
    Write-Host 'Skipping WinGet submit: WINGET_CREATE_GITHUB_TOKEN is not configured.'
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
function Test-WinGetVersionSubmitted {
    # Titles are mutable. Discover merged submissions through path-scoped
    # commits and associated PRs, and enumerate open PR file connections.
    $segments = $PackageIdentifier.Split('.')
    $prefix = 'manifests/{0}/{1}/{2}/' -f $segments[0].Substring(0, 1).ToLowerInvariant(), ($segments -join '/'), $Version
    function Read-WinGetJson {
        param([string[]] $Arguments)
        $json = & gh @Arguments
        if ($LASTEXITCODE -ne 0) { throw 'WinGet GitHub read failed.' }
        $data = $json | ConvertFrom-Json -NoEnumerate
        if ($null -eq $data -or ($data -isnot [array] -and $data.errors)) { throw 'WinGet GitHub response is incomplete.' }
        return $data
    }
    function Test-WinGetPrFiles {
        param([int] $Number)
        $pr = Read-WinGetJson @('api', "repos/microsoft/winget-pkgs/pulls/$Number")
        if ($null -eq $pr.changed_files -or $pr.changed_files -lt 0) { throw 'Missing PR file count.' }
        $seen = 0
        for ($page = 1; ; $page++) {
            $files = @(Read-WinGetJson @('api', "repos/microsoft/winget-pkgs/pulls/$Number/files?per_page=100&page=$page"))
            $seen += $files.Count
            foreach ($file in $files) {
                if (-not $file.filename -or -not $file.status) { throw 'Incomplete PR files.' }
                if ($file.status -cne 'removed' -and $file.filename.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            if ($files.Count -lt 100) {
                if ($seen -ne $pr.changed_files) { throw 'PR files were truncated.' }
                return $false
            }
        }
    }
    $savedToken = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $env:WINGET_CREATE_GITHUB_TOKEN
        for ($page = 1; ; $page++) {
            $commits = @(Read-WinGetJson @('api', '--method', 'GET', 'repos/microsoft/winget-pkgs/commits', '-f', "path=$prefix", '-f', 'per_page=100', '-f', "page=$page"))
            foreach ($commit in $commits) {
                if ($commit.sha -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Incomplete commit list.' }
                for ($prPage = 1; ; $prPage++) {
                    $prs = @(Read-WinGetJson @('api', "repos/microsoft/winget-pkgs/commits/$($commit.sha)/pulls?per_page=100&page=$prPage"))
                    foreach ($pr in $prs) {
                        if (-not $pr.number -or -not $pr.state) { throw 'Incomplete associated PR list.' }
                        if ($pr.merged_at -and (Test-WinGetPrFiles -Number $pr.number)) { return $true }
                    }
                    if ($prs.Count -lt 100) { break }
                }
            }
            if ($commits.Count -lt 100) { break }
        }
        $cursor = $null
        do {
            $query = 'query($cursor:String) { repository(owner:"microsoft",name:"winget-pkgs") { pullRequests(states:OPEN,first:100,after:$cursor) { nodes { number files(first:100) { nodes { path changeType } pageInfo { hasNextPage endCursor } } } pageInfo { hasNextPage endCursor } } } }'
            $arguments = @('api', 'graphql', '-f', "query=$query")
            if ($cursor) { $arguments += @('-f', "cursor=$cursor") }
            $connection = (Read-WinGetJson $arguments).data.repository.pullRequests
            if ($null -eq $connection.nodes -or $null -eq $connection.pageInfo.hasNextPage) { throw 'Incomplete open PR list.' }
            foreach ($pr in $connection.nodes) {
                if (-not $pr.number -or $null -eq $pr.files.nodes -or $null -eq $pr.files.pageInfo.hasNextPage) { throw 'Incomplete open PR files.' }
                foreach ($file in $pr.files.nodes) {
                    if (-not $file.path -or -not $file.changeType) { throw 'Incomplete open PR file.' }
                    if ($file.changeType -cne 'DELETED' -and $file.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
                }
                # REST pagination covers the uncommon PR with >100 files.
                if ($pr.files.pageInfo.hasNextPage -and (Test-WinGetPrFiles -Number $pr.number)) { return $true }
            }
            $next = $connection.pageInfo.endCursor
            if ($connection.pageInfo.hasNextPage -and (-not $next -or $next -ceq $cursor)) { throw 'Open PR pagination stalled.' }
            $cursor = $next
        } while ($connection.pageInfo.hasNextPage)
        return $false
    }
    catch { throw 'Could not determine whether this WinGet version already has an open or merged PR; refusing a duplicate submission.' }
    finally { $env:GH_TOKEN = $savedToken }
}
if (Test-WinGetVersionSubmitted) {
    Write-Host "WinGet already has an open or merged PR for $PackageIdentifier $Version; nothing to submit."
    $global:LASTEXITCODE = 0
    return
}
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
        '--no-open'
    )
    foreach ($argument in $arguments) {
        [void] $startInfo.ArgumentList.Add([string] $argument)
    }
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
                $process.Kill($true)
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
    if (-not [string]::IsNullOrEmpty($env:WINGET_CREATE_GITHUB_TOKEN)) {
        $output = $output.Replace($env:WINGET_CREATE_GITHUB_TOKEN, '[REDACTED]')
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
