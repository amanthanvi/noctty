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
                # After a malformed success from an object endpoint, a later
                # 404 does not establish absence.
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
        throw 'ReleaseLookupIncomplete: the GitHub endpoint did not return a JSON object after 3 reads.'
    }
    throw 'Release GitHub read failed after 3 attempts; publication state is unknown.'
}

function Assert-ReleaseEvidence {
    param(
        [string] $Repository, [string] $Tag, [string] $CandidateSha,
        [string] $TestRunId, [string] $ReleaseRunId,
        [string] $WorkDirectory
    )
    $resumeFrom = 0
    # The hosted Test run of the candidate (its portable smoke artifact) and the Release run. No release requires an
    # interactive run (the maintainer's decision, 2026-11-22), so none is read here.
    foreach ($spec in @(
        @{ Id = $TestRunId; Workflow = 'test.yml'; Artifact = "flagship-portable-x64-$TestRunId" },
        @{ Id = $ReleaseRunId; Workflow = 'release.yml'; Artifact = $null }
    )) {
        $run = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$($spec.Id)")
        if ([string]$run.id -cne $spec.Id -or $run.head_sha -cne $CandidateSha -or
            $run.status -cne 'completed' -or
            ($run.conclusion -cne 'success' -and -not ($spec.Workflow -ceq 'release.yml' -and $run.conclusion -in @('failure','cancelled'))) -or
            $run.path -cne ".github/workflows/$($spec.Workflow)") {
            throw "RunIdentityMismatch: run $($spec.Id) must be completed and successful on the candidate in $($spec.Workflow)."
        }
        # The Test run must be a full-matrix run: a pull_request run's path filter can skip lanes.
        if ($spec.Workflow -ceq 'test.yml' -and [string]$run.event -cnotin @('push', 'schedule', 'workflow_dispatch')) {
            throw "RunIdentityMismatch: Test run $($spec.Id) is a '$($run.event)' run; promotion needs a push, schedule or workflow_dispatch run."
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
            # A missing or expired portable smoke artifact keeps promotion blocked until a fresh Test run's validates.
            $recovery = "gh workflow run test.yml --repo $Repository --ref $Tag, then retry promotion with the new Test run ID, the original Release run ID $ReleaseRunId and the original manifest digest"
            $artifact = @($records.artifacts | Where-Object { $_.name -ceq $spec.Artifact })
            if ($artifact.Count -ne 1) { throw "EvidenceMissing: run $($spec.Id), artifact $($spec.Artifact). Recovery: $recovery" }
            if ($artifact[0].expired -or [datetimeoffset]$artifact[0].expires_at -le [datetimeoffset]::UtcNow) {
                $expiresAt = ([datetimeoffset]$artifact[0].expires_at).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
                throw "EvidenceExpired: run $($spec.Id), artifact $($spec.Artifact), expires_at $expiresAt. Recovery: $recovery"
            }
        }
    }
    Write-Host "Evidence: PASS (Test $TestRunId, Release $ReleaseRunId)."
    # Successful original builds and ordinary promote retries start at verification.
    if ($null -eq $resumeFrom) { $resumeFrom = 0 }
    return [int]$resumeFrom
}
