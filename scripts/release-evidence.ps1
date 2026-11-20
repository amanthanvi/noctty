function Invoke-ReleaseGhJson {
    param([string[]] $Arguments, [switch] $AllowNotFound, [switch] $RequireReleaseObject)
    $invalidReleaseResponse = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $lines = @(& gh @Arguments --include 2>$null)
        $readExit = $LASTEXITCODE
        $status = [regex]::Match(($lines -join "`n"), '(?m)^HTTP/\S+\s+([0-9]{3})\b')
        if ($status.Success) {
            $code = [int]$status.Groups[1].Value
            if ($code -eq 404 -and $AllowNotFound) {
                if (-not $invalidReleaseResponse) { $global:LASTEXITCODE = 0; return $null }
                # Once a selected ID sent a malformed success, keep trying to
                # read its object. A later 404 does not establish absence.
            } elseif ($readExit -eq 0 -and $code -eq 200) {
                $blank = [array]::IndexOf($lines, '')
                if ($blank -lt 0) { throw 'Release GitHub read refused (HTTP 200); publication state is unknown.' }
                $data = ($lines[($blank + 1)..($lines.Count - 1)] -join "`n") | ConvertFrom-Json -NoEnumerate
                if ($RequireReleaseObject -and $data -isnot [System.Management.Automation.PSCustomObject]) {
                    # The [pscustomobject] accelerator also matches the PSObject
                    # wrapper on a JSON array. Returning [] would emit nothing.
                    $invalidReleaseResponse = $true
                } else {
                    if ($null -eq $data) { throw 'Release GitHub JSON is missing; publication state is unknown.' }
                    return $data
                }
            } elseif ($code -lt 500 -or $code -gt 599) {
                throw "Release GitHub read refused (HTTP $code); publication state is unknown."
            }
        }
        # A connection failure may have no HTTP response. Retry it too.
        if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
    }
    if ($invalidReleaseResponse) {
        throw 'ReleaseLookupIncomplete: the selected release ID did not return an object after 3 reads.'
    }
    throw 'Release GitHub read failed after 3 attempts; publication state is unknown.'
}

function Assert-ReleaseEvidence {
    param(
        [string] $Repository, [string] $Tag, [string] $CandidateSha,
        [string] $TestRunId, [string] $EvidenceRunId, [string] $ReleaseRunId,
        [string] $WorkDirectory
    )
    $resumeFrom = 0
    foreach ($spec in @(
        @{ Id = $TestRunId; Workflow = 'test.yml'; Artifact = "flagship-portable-x64-$TestRunId" },
        @{ Id = $EvidenceRunId; Workflow = 'test.yml'; Artifact = "flagship-interactive-win11-$EvidenceRunId" },
        @{ Id = $ReleaseRunId; Workflow = 'release.yml'; Artifact = $null }
    )) {
        $run = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$($spec.Id)")
        if ([string]$run.id -cne $spec.Id -or $run.head_sha -cne $CandidateSha -or
            $run.status -cne 'completed' -or
            ($run.conclusion -cne 'success' -and -not ($spec.Workflow -ceq 'release.yml' -and $run.conclusion -in @('failure','cancelled'))) -or
            $run.path -cne ".github/workflows/$($spec.Workflow)") {
            throw "RunIdentityMismatch: run $($spec.Id) must be completed and successful on the candidate in $($spec.Workflow)."
        }
        if ($spec.Workflow -ceq 'release.yml') {
            $attemptCount = $run.run_attempt
            if ($attemptCount -isnot [long] -and $attemptCount -isnot [int]) { throw 'ReleaseAttemptsIncomplete: run_attempt is missing.' }
            if ($attemptCount -lt 1) { throw 'ReleaseAttemptsIncomplete: invalid attempt count.' }
            $publishingAttempt = $null
            for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
                $attemptRun = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$ReleaseRunId/attempts/$attempt")
                if ([string]$attemptRun.id -cne $ReleaseRunId -or $attemptRun.run_attempt -ne $attempt -or
                    $attemptRun.head_sha -cne $CandidateSha -or $attemptRun.path -cne '.github/workflows/release.yml' -or
                    $attemptRun.status -cne 'completed') { throw 'ReleaseAttemptsIncomplete: attempt identity/status differs.' }
                $jobs = @()
                for ($page = 1; ; $page++) {
                    $records = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$ReleaseRunId/attempts/$attempt/jobs?per_page=100&page=$page")
                    if ($null -eq $records.total_count -or $null -eq $records.jobs) { throw 'ReleaseAttemptsIncomplete: jobs record is incomplete.' }
                    $jobs += @($records.jobs)
                    if (@($records.jobs).Count -lt 100) { break }
                }
                if ($jobs.Count -ne $records.total_count) { throw 'ReleaseAttemptsIncomplete: jobs were truncated.' }
                $build = @($jobs | Where-Object { $_.name -ceq 'Windows Release' })
                $published = @($build.steps | Where-Object { $_.name -ceq 'Publish GitHub Release' -and $_.conclusion -ceq 'success' })
                if ($build.Count -eq 1 -and $published.Count -eq 1 -and $null -eq $publishingAttempt) {
                    $publishingAttempt = $attempt
                    $resumeFrom = 0
                    foreach ($stepName in @('Verify published release copy and assets', 'Publish Scoop manifest', 'Submit WinGet manifest update', 'Publish Chocolatey package')) {
                        $step = @($build[0].steps | Where-Object { $_.name -ceq $stepName })
                        if ($step.Count -ne 1 -or $step[0].conclusion -cne 'success') { break }
                        if ($resumeFrom -gt 0) {
                            $channel = @('Scoop','WinGet','Chocolatey')[$resumeFrom - 1]
                            $outcome = @($build[0].steps | Where-Object {
                                ([string]::Equals($_.name, "$channel publication outcome: published", [StringComparison]::Ordinal) -or
                                 [string]::Equals($_.name, "$channel publication outcome: already-present", [StringComparison]::Ordinal)) -and $_.conclusion -ceq 'success'
                            })
                            if ($outcome.Count -ne 1) { break }
                        }
                        $resumeFrom++
                    }
                }
            }
            if ($null -eq $publishingAttempt) { throw 'ReleasePublishNotSuccessful: no attempt of the original Release run successfully published. Inspect the release and original attempts; preserve any published release.' }
            Write-Host "PublishedReleaseResume: original Release $ReleaseRunId, publishing attempt $publishingAttempt of $attemptCount; resume step index $resumeFrom (verify, Scoop, WinGet, Chocolatey). Use that attempt's manifest summary digest."
        }
        # Read the records before any download, including on a stable retry.
        $records = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$($spec.Id)/artifacts?per_page=100")
        if ($records.total_count -gt @($records.artifacts).Count) { throw 'Incomplete evidence artifact records.' }
        if ($spec.Artifact) {
            $artifact = @($records.artifacts | Where-Object { $_.name -ceq $spec.Artifact })
            if ($artifact.Count -ne 1) { throw "EvidenceMissing: run $($spec.Id), artifact $($spec.Artifact)." }
            if ($artifact[0].expired -or [datetimeoffset]$artifact[0].expires_at -le [datetimeoffset]::UtcNow) {
                $recovery = "gh workflow run test.yml --repo $Repository --ref $Tag -f run_interactive_win11=true"
                $expiresAt = ([datetimeoffset]$artifact[0].expires_at).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
                throw "EvidenceExpired: run $($spec.Id), artifact $($spec.Artifact), expires_at $expiresAt. Recovery: $recovery"
            }
        }
    }
    $jobs = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$EvidenceRunId/jobs?per_page=100")
    if ($jobs.total_count -gt @($jobs.jobs).Count -or @($jobs.jobs | Where-Object {
        $_.name -ceq 'Windows 11 Interactive Composite' -and $_.status -ceq 'completed' -and $_.conclusion -ceq 'success'
    }).Count -ne 1) { throw 'EvidenceJobInvalid: named interactive job is not successful.' }
    $root = Join-Path $WorkDirectory "evidence-$EvidenceRunId"
    [void][IO.Directory]::CreateDirectory($root)
    & gh run download $EvidenceRunId --repo $Repository --name "flagship-interactive-win11-$EvidenceRunId" --dir $root
    if ($LASTEXITCODE -ne 0) { throw 'EvidenceDownloadFailed: fresh artifact could not be downloaded.' }
    $results = @(Get-ChildItem -LiteralPath $root -Filter result.json -File -Recurse | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).scenario_id -ceq 'windows.interactive-win11.composite'
    })
    if ($results.Count -ne 1) { throw 'EvidenceInvalid: expected exactly one composite result.' }
    $result = Get-Content -LiteralPath $results[0].FullName -Raw | ConvertFrom-Json
    if ($result.status -cne 'pass' -or $result.implementation_commit -cne $CandidateSha -or
        [string]$result.workflow_run_id -cne $EvidenceRunId -or @($result.artifacts).Count -eq 0) {
        throw 'EvidenceInvalid: composite result is not a candidate-bound pass.'
    }
    $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($artifact in @($result.artifacts)) {
        if (-not $artifact.path -or $artifact.sha256 -cnotmatch '\A[0-9a-f]{64}\z') { throw 'EvidenceHashMismatch: incomplete artifact record.' }
        $path = [IO.Path]::GetFullPath((Join-Path $results[0].DirectoryName ([string]$artifact.path)))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileSha256Lower $path) -cne $artifact.sha256) { throw 'EvidenceHashMismatch: interactive artifact is not hash-bound.' }
    }
    Write-Host "Evidence: PASS (Test $TestRunId, interactive $EvidenceRunId, Release $ReleaseRunId)."
    # Successful original builds and ordinary promote retries start at verification.
    if ($null -eq $resumeFrom) { $resumeFrom = 0 }
    return [int]$resumeFrom
}
