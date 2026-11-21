#requires -Version 7.0
<#
.SYNOPSIS
The hidden-desktop GUI suite's error publisher (design §4.5): it gives a job that failed without a complete result an
`error` result, so the uploaded artifact still records the failure.

.DESCRIPTION
  pwsh -NoProfile -File test/windows/gui-hidden-publish-error.ps1 -Kind <kind> -Out <directory>

It stands alone (Sol on #740: a parse error in the runner defeated both the runner's own publisher and its -PublishError
fallback, which lived in the same file). It dot-sources nothing, runs no other script, compiles nothing, and reads only
-Out and the flagship result schema (test/windows/flagship/result.schema.json). The workflow runs it when the suite job
failed (`if: failure()`); the runner runs it when its own initialization fails.

A result already in -Out stands only when it is complete: result.json parses, matches the result schema and names this
scenario, and result.json.sha256, which the runner writes after result.json, holds result.json's SHA-256. Then nothing
is written and the exit code is 0. Otherwise (no result; a truncated, foreign or schema-invalid one; a missing or stale
hash; Sol on #740: a seeded `{` stood as final) any result.json is kept as result.incomplete.json (numbered when that
name is taken), and this writes receipts/publish-error.json, then an `error` result of fixed values that lists only
that receipt, then its hash, and exits 2. A -Kind outside its shape, or an -Out that is not a directory, exits 2 with
nothing written. Only allowlisted values are written: the kind, booleans, the run's id and attempt, and hashes.
#>
[CmdletBinding()]
param(
    [string] $Kind,
    [string] $Out
)
$ErrorActionPreference = 'Stop'

function Get-PublishSha256([string] $Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# Whether -Out holds a complete result (the description's checks). Anything that cannot be read is incomplete.
function Test-PublishCompleteResult([string] $OutPath) {
    $resultPath = Join-Path $OutPath 'result.json'
    $hashPath = Join-Path $OutPath 'result.json.sha256'
    try {
        if (-not [IO.File]::Exists($resultPath) -or -not [IO.File]::Exists($hashPath)) { return $false }
        $recorded = [IO.File]::ReadAllText($hashPath).Trim()
        if ($recorded -cnotmatch '\A[0-9a-f]{64}\z') { return $false }
        if (-not [string]::Equals($recorded, (Get-PublishSha256 $resultPath), [StringComparison]::Ordinal)) { return $false }
        $text = [IO.File]::ReadAllText($resultPath)
        $schema = Join-Path $PSScriptRoot 'flagship\result.schema.json'
        if (-not (Test-Json -Json $text -SchemaFile $schema -ErrorAction SilentlyContinue)) { return $false }
        $parsed = $text | ConvertFrom-Json
        return $parsed.scenario_id -ceq 'windows.gui-hidden.suite'
    }
    catch { return $false }
}

if ($Kind -cnotmatch '\A[a-z][a-z0-9-]{0,39}\z' -or -not $Out) {
    Write-Host 'gui-hidden: usage: -Kind <lowercase letters, digits and hyphens> -Out <directory>'
    exit 2
}
$Out = [IO.Path]::GetFullPath($Out)
if ([IO.File]::Exists($Out)) { Write-Host 'gui-hidden: the output path is not a directory.'; exit 2 }
if ([IO.Directory]::Exists($Out) -and (Test-PublishCompleteResult $Out)) {
    Write-Host 'gui-hidden: a complete result already stands; nothing to publish'
    exit 0
}

[void][IO.Directory]::CreateDirectory((Join-Path $Out 'receipts'))
$resultPath = Join-Path $Out 'result.json'
$replaced = $false
if ([IO.File]::Exists($resultPath)) {
    # Kept, never deleted: an incomplete result is evidence of how the run ended.
    # A name a file or a directory holds is taken (CodeRabbit on #740).
    $kept = Join-Path $Out 'result.incomplete.json'
    for ($n = 2; [IO.File]::Exists($kept) -or [IO.Directory]::Exists($kept); $n++) { $kept = Join-Path $Out "result.incomplete-$n.json" }
    [IO.File]::Move($resultPath, $kept)
    $replaced = $true
}
# The invariant culture's Gregorian calendar, whatever this machine's (CodeRabbit on #740: th-TH writes a Buddhist year).
$now = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
$hostedRun = $env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted'
$published = [ordered]@{
    hosted = $hostedRun; publishedError = $Kind; replacedIncomplete = $replaced
    guards = [ordered]@{ state = 'not-run'; history = 'not-run'; startup = 'not-run' }; stateGuardsHeld = $false; exit = 2
}
$publishedRecord = Join-Path $Out 'receipts\publish-error.json'
[IO.File]::WriteAllText($publishedRecord, ($published | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$publishedResult = [ordered]@{
    schema_version = 'noctty.verification.result.v1'
    scenario_id = 'windows.gui-hidden.suite'
    status = 'error'
    started_at = $now; finished_at = $now; duration_ms = 0
    baseline_commit = $null; implementation_commit = $null
    workflow_run_id = $(if ($env:GITHUB_RUN_ID -match '\A[0-9]+\z') { $env:GITHUB_RUN_ID } else { $null })
    workflow_run_attempt = $(if ($env:GITHUB_RUN_ATTEMPT -match '\A[0-9]+\z') { [int]$env:GITHUB_RUN_ATTEMPT } else { $null })
    environment = [ordered]@{ os = 'Windows'; architecture = 'x86_64'; hosted = $hostedRun; desktop = 'private' }
    measurements = [ordered]@{ 'suite.publishedError' = $Kind; 'suite.replacedIncomplete' = $replaced }
    assertions = @(foreach ($id in @('leaves-pass', 'launch-policy', 'real-input-absent', 'state-guards')) { [ordered]@{ id = $id; status = 'fail'; message = $null } })
    artifacts = @([ordered]@{ kind = 'other'; path = 'receipts/publish-error.json'; sha256 = (Get-PublishSha256 $publishedRecord) })
    failure = [ordered]@{ message = "exit 2 ($Kind)"; type = 'error' }
}
# The result goes in whole (a temporary file moved into place), then its hash, last.
$partial = "$resultPath.partial"
[IO.File]::WriteAllText($partial, ($publishedResult | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
[IO.File]::Move($partial, $resultPath, $true)
[IO.File]::WriteAllText("$resultPath.sha256", (Get-PublishSha256 $resultPath) + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "gui-hidden: published an error result ($Kind)"
exit 2
