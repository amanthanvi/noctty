[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'artifacts\portable-x64'),
    [string] $Version = '0.0.1',
    [switch] $SkipPackage
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$outputPath = [System.IO.Path]::GetFullPath($OutputDirectory)
$transcriptPath = Join-Path $outputPath 'transcript.log'
$resultPath = Join-Path $outputPath 'result.json'
$started = [DateTimeOffset]::UtcNow
$status = 'error'
$failure = $null
$commit = $null

try {
    $dirty = @(& git -C $repoRoot status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to establish verification provenance.' }
    if ($dirty.Count -ne 0) { throw 'Refusing provenance-bearing verification for a dirty worktree.' }
    $commit = (& git -C $repoRoot rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $repoRoot 'test\windows\package-portable-cli.ps1'),
        '-Version', $Version,
        '-Architecture', 'x64'
    )
    if ($SkipPackage) { $arguments += '-SkipPackage' }

    & powershell.exe @arguments *> $transcriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Portable package CLI smoke exited with code $LASTEXITCODE."
    }
    $status = 'pass'
}
catch {
    $failure = [ordered]@{ message = $_.Exception.Message; type = $_.Exception.GetType().FullName }
}
finally {
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
    $finished = [DateTimeOffset]::UtcNow
    $logHash = if ($commit -and (Test-Path -LiteralPath $transcriptPath)) {
        (Get-FileHash -LiteralPath $transcriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { $null }

    $packageRelativePath = "dist/artifacts/winghostty-$Version-windows-x64/winghostty/winghostty.exe"
    $packagePath = Join-Path $repoRoot $packageRelativePath
    $packageHash = if ($commit -and (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { $null }
    if ($status -eq 'pass' -and -not $packageHash) {
        $status = 'error'
        $failure = [ordered]@{
            message = "Packaged executable evidence is missing: $packageRelativePath"
            type = 'PackageEvidenceMissing'
        }
    }
    $artifacts = @(
        [ordered]@{ kind = 'log'; path = 'transcript.log'; sha256 = $logHash }
        [ordered]@{ kind = 'package'; path = $packageRelativePath.Replace('\', '/'); sha256 = $packageHash }
    )

    $result = [ordered]@{
        schema_version = 'winghostty.verification.result.v1'
        scenario_id = 'windows.portable-cli.x64'
        status = $status
        started_at = $started.ToString('o')
        finished_at = $finished.ToString('o')
        duration_ms = [Math]::Max(0, [long]($finished - $started).TotalMilliseconds)
        baseline_commit = $null
        implementation_commit = $commit
        environment = [ordered]@{
            os = [System.Environment]::OSVersion.VersionString
            architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            ci = [bool]$env:CI
        }
        measurements = [ordered]@{}
        assertions = @(
            [ordered]@{
                id = 'package-layout'
                status = $(if ($status -eq 'pass' -and $packageHash) { 'pass' } else { 'fail' })
                message = $(if (-not $packageHash) { 'Packaged executable evidence is missing.' } else { $null })
            }
            [ordered]@{
                id = 'cli-contract'
                status = $(if ($status -eq 'pass') { 'pass' } else { 'fail' })
                message = $(if ($failure) { $failure.message } else { $null })
            }
        )
        artifacts = $artifacts
        failure = $failure
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
    $resultJson = Get-Content -LiteralPath $resultPath -Raw
    if (-not ($resultJson | Test-Json -SchemaFile (Join-Path $PSScriptRoot 'result.schema.json'))) {
        throw 'Portable smoke emitted an invalid result contract.'
    }
    $scenario = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scenarios\portable-x64.json') -Raw | ConvertFrom-Json
    $declaredAssertions = @($scenario.assertions | ForEach-Object id | Sort-Object)
    $emittedAssertions = @($result.assertions | ForEach-Object id | Sort-Object)
    if (($declaredAssertions -join "`n") -ne ($emittedAssertions -join "`n")) {
        throw 'Portable result assertion set differs from the scenario contract.'
    }
    $declaredArtifacts = @($scenario.artifacts | Where-Object kind -ne 'result' | ForEach-Object { "$($_.kind)|$($_.path)" } | Sort-Object)
    $emittedArtifacts = @($result.artifacts | ForEach-Object { "$($_.kind)|$($_.path)" } | Sort-Object)
    if (($declaredArtifacts -join "`n") -ne ($emittedArtifacts -join "`n")) {
        throw 'Portable result artifact set differs from the scenario contract.'
    }
}

if ($status -ne 'pass') {
    if ($commit) {
        Get-Content -LiteralPath $transcriptPath -ErrorAction SilentlyContinue | Write-Host
    }
    throw $failure.message
}

Get-Content -LiteralPath $transcriptPath | Write-Host
Write-Host "flagship portable smoke: PASS (artifacts=$outputPath)"
