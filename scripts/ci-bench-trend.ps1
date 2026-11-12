#requires -Version 5.1
<#
.SYNOPSIS
Nightly, report-only benchmark trend for test.yml.

.DESCRIPTION
Runs the headless VT throughput workloads and the palette benchmark that the
`bench` gate runs, without their floors, writes the medians to
<OutputDirectory>\bench-trend.json and the job summary, and compares them with
the previous nightly's artifact when one can be fetched. It never fails the
job on a slow number: the gate owns catastrophic regressions
(docs/windows-benchmark-methodology.md), this shows drift.

Hosted windows-2025 runners are bimodal (about 2x between fast and slow
machines), so one night's change means little; read the trend over weeks.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [string] $Repository,
    [int] $Runs = 9,
    # Dot-source for the baseline lookup only.
    [switch] $LibraryOnly
)

# The artifact of the newest earlier nightly. Only scheduled runs of test.yml
# count (they run on the default branch), so a manual run on a work branch never
# becomes the baseline. The lookup goes through runs rather than the repository's
# artifact list, which pages at 100 and would lose the baseline once enough other
# artifacts exist, and asks for 100 runs, more than the 90 days an artifact
# lives, so a run of nights without a trend artifact does not hide an older one. $Api takes an API path and returns the
# parsed JSON.
function Get-PreviousTrendArtifact {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $CurrentRunId,
        [scriptblock] $Api = { param($Path) gh api $Path | ConvertFrom-Json }
    )

    $listing = & $Api "repos/$Repository/actions/workflows/test.yml/runs?event=schedule&status=completed&per_page=100"
    foreach ($run in @($listing.workflow_runs)) {
        if ([string] $run.id -eq $CurrentRunId) { continue }
        $artifacts = & $Api "repos/$Repository/actions/runs/$($run.id)/artifacts?per_page=100"
        $name = "bench-trend-$($run.id)"
        $match = @($artifacts.artifacts | Where-Object { $_.name -ceq $name -and -not $_.expired }) | Select-Object -First 1
        if ($match) { return [pscustomobject]@{ RunId = [string] $run.id; Name = $name } }
    }
    return $null
}

if ($LibraryOnly) { return }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'Pass -OutputDirectory.' }
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$metrics = [ordered]@{}
foreach ($workload in 'ascii', 'utf8', 'osc', 'scroll') {
    $json = Join-Path $OutputDirectory "vt-$workload.json"
    zig build bench:vt-throughput -- "--workload=$workload" --bytes=4194304 --seed=121 "--runs=$Runs" --rows=45 --cols=140 "--json=$json"
    if ($LASTEXITCODE -ne 0) { throw "bench:vt-throughput $workload failed with exit code $LASTEXITCODE." }
    $result = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
    $metrics["vt-$workload median"] = [ordered]@{ value = [math]::Round($result.median_mb_s, 2); unit = 'MB/s'; higher_is_better = $true }
    $metrics["vt-$workload p95"] = [ordered]@{ value = [math]::Round($result.p95_mb_s, 2); unit = 'MB/s'; higher_is_better = $true }
}

# A budget nothing reaches: this run reports, the gate enforces 2500 us.
$palette = @(zig build bench:palette-match -- --entries=5000 --keystrokes=5000 --budget-us=100000000)
if ($LASTEXITCODE -ne 0) { throw "bench:palette-match failed with exit code $LASTEXITCODE." }
$palette | ForEach-Object { Write-Host $_ }
foreach ($percentile in 'p50', 'p99') {
    $line = $palette | Where-Object { $_ -match "^\s*$percentile\s*=\s*(\d+) us" } | Select-Object -First 1
    if ($line -match '=\s*(\d+) us') {
        $metrics["palette $percentile"] = [ordered]@{ value = [int] $Matches[1]; unit = 'us'; higher_is_better = $false }
    }
}
if (-not $metrics.Contains('palette p99')) { throw 'The palette benchmark printed no p99 line.' }

$report = [ordered]@{
    schema_version = 'koreterm.bench-trend.v1'
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    commit = $env:GITHUB_SHA
    run_id = $env:GITHUB_RUN_ID
    runner_image = $env:ImageVersion
    vt_runs_per_workload = $Runs
    palette_keystrokes = 5000
    metrics = $metrics
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'bench-trend.json') -Encoding utf8

# The previous nightly's artifact, newest first. Any failure here only drops the
# comparison column.
$previous = $null
$previousNote = ''
if ($Repository -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    try {
        $candidate = Get-PreviousTrendArtifact -Repository $Repository -CurrentRunId $env:GITHUB_RUN_ID
        if ($candidate) {
            $previousDirectory = Join-Path $OutputDirectory 'previous'
            gh run download $candidate.RunId --repo $Repository --name $candidate.Name --dir $previousDirectory
            if ($LASTEXITCODE -ne 0) { throw "gh run download exited with $LASTEXITCODE." }
            $previous = Get-Content -LiteralPath (Join-Path $previousDirectory 'bench-trend.json') -Raw | ConvertFrom-Json
            $previousNote = "Compared with $($candidate.Name) ($($previous.generated_at))."
            Remove-Item -LiteralPath $previousDirectory -Recurse -Force
        }
        else {
            $previousNote = 'No earlier nightly bench-trend artifact to compare with.'
        }
    }
    catch {
        $previousNote = "The previous artifact could not be read: $($_.Exception.Message)"
    }
}

$rows = foreach ($name in $metrics.Keys) {
    $now = $metrics[$name]
    $before = if ($previous) { $previous.metrics.PSObject.Properties[$name] } else { $null }
    $change = ''
    $beforeText = ''
    if ($before -and $before.Value.value -gt 0) {
        $beforeText = "$($before.Value.value) $($now.unit)"
        $delta = ($now.value - $before.Value.value) / $before.Value.value * 100
        $change = '{0:+0.0;-0.0}%' -f $delta
    }
    "| $name | $($now.value) $($now.unit) | $beforeText | $change |"
}
$summary = @(
    '### Benchmark trend (report only)'
    ''
    'Hosted runners are bimodal, about 2x between fast and slow machines; read the trend over weeks, not one night.'
    $previousNote
    ''
    '| Metric | Now | Previous | Change |'
    '| --- | ---: | ---: | ---: |'
) + $rows
$summary | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8 }
# A baseline lookup that failed was reported in the summary; do not let its exit
# code fail the step (Actions ends a pwsh step with `exit $LASTEXITCODE`).
$global:LASTEXITCODE = 0
