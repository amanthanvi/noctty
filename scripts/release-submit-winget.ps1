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
. (Join-Path $PSScriptRoot 'release-publisher-outcome.ps1')
if ([string]::Equals($env:WINGET_PUBLISH, 'off', [StringComparison]::OrdinalIgnoreCase)) { Write-Host 'WinGet explicitly disabled.'; Set-ReleasePublisherOutcome skipped-disabled; return }

if (-not $env:WINGET_CREATE_GITHUB_TOKEN) {
    Write-Host 'Skipping WinGet submit: WINGET_CREATE_GITHUB_TOKEN is not configured.'
    Set-ReleasePublisherOutcome skipped-unconfigured
    return
}
if ([string]::IsNullOrWhiteSpace($PackageIdentifier)) {
    Write-Host 'Skipping WinGet submit: WINGET_PACKAGE_IDENTIFIER is not configured. Initial WinGet bootstrap is still manual.'
    Set-ReleasePublisherOutcome skipped-unconfigured
    return
}
if (-not $PSCmdlet.ShouldProcess($PackageIdentifier, "submit noctty $Version WinGet manifest")) {
    Set-ReleasePublisherOutcome what-if
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
    # At most 100 open PRs matching the identifier in title OR body, without
    # a version qualifier. Confirm identity by manifest paths, not PR text.
    # A PR from any account is outside this search if both fields omit the
    # identifier. wingetcreate includes it at submission; later edits may not.
    $segments = $PackageIdentifier.Split('.')
    $prefix = 'manifests/{0}/{1}/{2}/' -f $segments[0].Substring(0, 1).ToLowerInvariant(), ($segments -join '/'), $Version
    $requestBudget = [pscustomobject]@{ Remaining = 250 }
    function Read-WinGetJson {
        param([string[]] $Arguments, [switch] $AllowNotFound, [switch] $Search)
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if (--$requestBudget.Remaining -lt 0) { throw 'WinGet read budget exceeded.' }
            # Search permits 30 authenticated reads/minute. Keep reads serial;
            # other REST calls are paced too, with at most three 5xx attempts.
            Start-Sleep -Milliseconds $(if ($Search) { 2100 } else { 250 })
            $lines = @(& gh api --method GET @Arguments --include 2>$null)
            $exitCode = $LASTEXITCODE
            $status = [regex]::Match(($lines -join "`n"), '(?m)^HTTP/\S+\s+([0-9]{3})\b')
            if (-not $status.Success) {
                if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)); continue }
                throw 'WinGet HTTP status unavailable after 3 attempts.'
            }
            $code = [int]$status.Groups[1].Value
            if ($code -ge 500 -and $code -le 599 -and $attempt -lt 3) {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                continue
            }
            if ($code -eq 404 -and $AllowNotFound) { return $null }
            if ($exitCode -ne 0 -or $code -ne 200) { throw "WinGet read refused (HTTP $code)." }
            $blank = [array]::IndexOf($lines, '')
            if ($blank -lt 0 -or $blank -ge $lines.Count - 1) { throw 'Incomplete WinGet HTTP response.' }
            $data = ($lines[($blank + 1)..($lines.Count - 1)] -join "`n") | ConvertFrom-Json -NoEnumerate
            if ($null -eq $data) { throw 'WinGet JSON is missing.' }
            return $data
        }
    }
    function Test-WinGetPrFiles {
        param([int] $Number)
        $pr = Read-WinGetJson @("repos/microsoft/winget-pkgs/pulls/$Number")
        if ($pr.state -cne 'open' -and -not $pr.merged_at) { return $false }
        if ($null -eq $pr.changed_files -or $pr.changed_files -lt 0) { throw 'Missing PR file count.' }
        $seen = 0
        for ($page = 1; $page -le 30; $page++) {
            $files = @(Read-WinGetJson @("repos/microsoft/winget-pkgs/pulls/$Number/files?per_page=100&page=$page"))
            $seen += $files.Count
            foreach ($file in $files) {
                if (-not $file.filename -or -not $file.status) { throw 'Incomplete PR file record.' }
                if ($file.status -cne 'removed' -and $file.filename.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            if ($files.Count -lt 100) {
                if ($seen -ne $pr.changed_files) { throw 'PR files were truncated.' }
                return $false
            }
        }
        throw 'PR files exceeded GitHub REST file limit.'
    }
    $savedToken = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $env:WINGET_CREATE_GITHUB_TOKEN
        $repo = Read-WinGetJson @('repos/microsoft/winget-pkgs')
        if (-not $repo.default_branch) { throw 'WinGet default branch is unknown.' }
        $directory = Read-WinGetJson @("repos/microsoft/winget-pkgs/contents/$($prefix.TrimEnd('/'))", '-f', "ref=$($repo.default_branch)") -AllowNotFound
        if ($null -ne $directory) {
            if (@($directory | Where-Object { $_.type -ceq 'file' -and $_.name -ceq "$PackageIdentifier.yaml" -and $_.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
                throw 'Existing WinGet version directory is incomplete.'
            }
            return $true
        }
        $identifier = $PackageIdentifier.ToLowerInvariant()
        $query = "repo:microsoft/winget-pkgs is:pr is:open in:title,body `"$identifier`""
        $search = Read-WinGetJson @('search/issues', '-f', "q=$query", '-f', 'per_page=100') -Search
        if ($null -eq $search.total_count -or $null -eq $search.items -or $search.incomplete_results -or
            $search.total_count -ne @($search.items).Count -or $search.total_count -gt 100) {
            throw 'WinGetCandidateSetIncomplete: identifier query must be complete and contain at most 100 open PRs.'
        }
        $numbers = [Collections.Generic.HashSet[int]]::new()
        foreach ($item in $search.items) {
            if (-not $item.number) { throw 'WinGet search candidate has no PR number.' }
            [void]$numbers.Add([int]$item.number)
        }
        foreach ($number in $numbers) { if (Test-WinGetPrFiles -Number $number) { return $true } }
        Write-Host "WinGet $PackageIdentifier $Version`: absent within the stated limit (open PR title/body identifier query and default-branch manifest check; PRs from any account omitting the identifier in both fields are excluded)."
        return $false
    }
    catch {
        if ($_.Exception.Message.StartsWith('WinGetCandidateSetIncomplete:', [StringComparison]::Ordinal)) { throw }
        throw 'WinGetQueryFailed: could not complete the bounded submission lookup after its retry policy; refusing submission.'
    }
    finally { $env:GH_TOKEN = $savedToken }
}
if (Test-WinGetVersionSubmitted) {
    Write-Host "WinGet already has an open or merged PR for $PackageIdentifier $Version; nothing to submit."
    Set-ReleasePublisherOutcome already-present
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
    Set-ReleasePublisherOutcome skipped-unconfigured
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
Set-ReleasePublisherOutcome published
