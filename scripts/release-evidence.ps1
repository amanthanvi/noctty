function Invoke-ReleaseGhJson {
    param([string[]] $Arguments)
    $json = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Release GitHub read failed; publication state is unknown.' }
    $json | ConvertFrom-Json
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
            ($run.conclusion -cne 'success' -and -not ($spec.Workflow -ceq 'release.yml' -and $run.conclusion -ceq 'failure')) -or
            $run.path -cne ".github/workflows/$($spec.Workflow)") {
            throw "RunIdentityMismatch: run $($spec.Id) must be completed and successful on the candidate in $($spec.Workflow)."
        }
        if ($spec.Workflow -ceq 'release.yml' -and $run.conclusion -ceq 'failure') {
            $releaseJobs = Invoke-ReleaseGhJson @('api', "repos/$Repository/actions/runs/$ReleaseRunId/jobs?per_page=100")
            $build = @($releaseJobs.jobs | Where-Object { $_.name -ceq 'Windows Release' })
            $published = @($build.steps | Where-Object { $_.name -ceq 'Publish GitHub Release' -and $_.conclusion -ceq 'success' })
            if ($releaseJobs.total_count -gt @($releaseJobs.jobs).Count -or $build.Count -ne 1 -or $published.Count -ne 1) {
                throw 'ReleasePublishNotSuccessful: original Release run did not successfully complete Publish GitHub Release; published-release resume is refused.'
            }
            $resumeFrom = 0
            foreach ($stepName in @('Verify published release copy and assets', 'Publish Scoop manifest', 'Submit WinGet manifest update', 'Publish Chocolatey package')) {
                $step = @($build[0].steps | Where-Object { $_.name -ceq $stepName })
                if ($step.Count -ne 1 -or $step[0].conclusion -cne 'success') { break }
                $resumeFrom++
            }
            Write-Host "PublishedReleaseResume: original Release $ReleaseRunId published successfully; resume step index $resumeFrom (verify, Scoop, WinGet, Chocolatey)."
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
