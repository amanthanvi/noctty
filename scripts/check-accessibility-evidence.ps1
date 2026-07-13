[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$evidencePath = Join-Path $repoRoot "docs/accessibility-evidence/v$Version.json"
$schemaPath = Join-Path $repoRoot 'test/windows/accessibility-evidence.schema.json'
if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    throw "Missing manual accessibility evidence for v${Version}: $evidencePath"
}

$json = Get-Content -LiteralPath $evidencePath -Raw
$testJson = Get-Command Test-Json -ErrorAction SilentlyContinue
if ($null -eq $testJson -or -not $testJson.Parameters.ContainsKey('SchemaFile')) {
    throw 'Test-Json -SchemaFile is required to validate accessibility release evidence; run this check with PowerShell 7.1 or newer.'
}
if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) {
    throw "Accessibility evidence failed schema validation: $evidencePath"
}
$evidence = $json | ConvertFrom-Json
if ($evidence.release_version -ne $Version) {
    throw "Accessibility evidence version '$($evidence.release_version)' does not match '$Version'."
}
$testedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse(
        [string]$evidence.tested_at,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$testedAt)) {
    throw "Accessibility evidence tested_at is not a valid ISO 8601 timestamp: '$($evidence.tested_at)'."
}

$requiredScenarios = @('navigate-tabs', 'navigate-panes', 'read-terminal', 'command-palette', 'settings-edit', 'dismiss-transient-ui')
$actualScenarios = @($evidence.scenarios | Sort-Object -Unique)
if ((($requiredScenarios | Sort-Object) -join "`n") -ne ($actualScenarios -join "`n")) {
    throw 'Accessibility evidence does not cover every required interaction scenario.'
}

$expectedMatrix = foreach ($reader in @('Narrator', 'NVDA')) {
    foreach ($scale in @(100, 200, 300)) {
        foreach ($contrast in @($false, $true)) {
            "$reader|$scale|$contrast"
        }
    }
}
$actualMatrix = @($evidence.matrix | ForEach-Object { "$($_.screen_reader)|$($_.scale_percent)|$($_.high_contrast)" })
if ((($expectedMatrix | Sort-Object) -join "`n") -ne (($actualMatrix | Sort-Object -Unique) -join "`n")) {
    throw 'Accessibility evidence must contain each Narrator/NVDA, 100/200/300%, high-contrast off/on combination exactly once.'
}

& git -C $repoRoot cat-file -e "$($evidence.tested_commit)^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) { throw "Accessibility tested commit is unavailable: $($evidence.tested_commit)" }
& git -C $repoRoot merge-base --is-ancestor $evidence.tested_commit HEAD
if ($LASTEXITCODE -ne 0) { throw "Accessibility tested commit is not an ancestor of HEAD: $($evidence.tested_commit)" }

$changedAfterTest = @(& git -C $repoRoot diff --name-only $evidence.tested_commit HEAD)
$invalidatedBy = @($changedAfterTest | Where-Object {
    $_ -notlike 'docs/accessibility-evidence/*'
})
if ($invalidatedBy.Count -gt 0) {
    throw "Accessibility evidence was invalidated by post-test changes: $($invalidatedBy -join ', ')"
}

$runId = [regex]::Match($evidence.workflow_run_url, '/actions/runs/(?<id>[0-9]+)$').Groups['id'].Value
if ([string]::IsNullOrWhiteSpace($runId) -or -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'Accessibility evidence requires a valid GitHub Actions run URL and the gh CLI.'
}
$repo = & gh api 'repos/amanthanvi/winghostty' | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not load repository metadata for accessibility evidence validation.' }
$defaultBranch = $repo.default_branch
$run = & gh api "repos/amanthanvi/winghostty/actions/runs/$runId" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Could not load accessibility workflow run $runId." }
if ($run.name -ne 'Test' -or $run.status -ne 'completed' -or $run.conclusion -ne 'success' -or
    $run.head_sha -ne $evidence.tested_commit -or $run.head_branch -ne $defaultBranch -or
    $run.event -notin @('push', 'workflow_dispatch', 'schedule')) {
    throw "Accessibility workflow run $runId is not a successful Test run for $($evidence.tested_commit) on default branch '$defaultBranch'."
}
$jobs = & gh api "repos/amanthanvi/winghostty/actions/runs/$runId/jobs?per_page=100" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Could not load accessibility workflow jobs for run $runId." }
$interactiveJob = @($jobs.jobs | Where-Object { $_.name -eq 'Windows 11 Interactive Composite' -and $_.conclusion -eq 'success' })
if ($interactiveJob.Count -ne 1) { throw "Workflow run $runId lacks one successful Windows 11 Interactive Composite job." }
$artifacts = & gh api "repos/amanthanvi/winghostty/actions/runs/$runId/artifacts?per_page=100" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Could not load accessibility workflow artifacts for run $runId." }
$evidenceArtifact = @($artifacts.artifacts | Where-Object {
    $_.name -eq "flagship-interactive-win11-$runId" -and -not $_.expired
})
if ($evidenceArtifact.Count -ne 1) { throw "Workflow run $runId lacks one unexpired interactive evidence artifact." }

$downloadRoot = Join-Path ([System.IO.Path]::GetTempPath()) "winghostty-accessibility-evidence-$([Guid]::NewGuid().ToString('N'))"
try {
    & gh run download $runId `
        --repo amanthanvi/winghostty `
        --name "flagship-interactive-win11-$runId" `
        --dir $downloadRoot
    if ($LASTEXITCODE -ne 0) { throw "Could not download interactive evidence artifact for run $runId." }
    $resultPaths = @(Get-ChildItem -LiteralPath $downloadRoot -Filter result.json -Recurse | Where-Object {
        try { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).scenario_id -eq 'windows.interactive-win11.composite' }
        catch { $false }
    })
    if ($resultPaths.Count -ne 1) { throw "Interactive artifact for run $runId lacks one composite result.json." }
    $result = Get-Content -LiteralPath $resultPaths[0].FullName -Raw | ConvertFrom-Json
    if ($result.status -ne 'pass' -or $result.implementation_commit -ne $evidence.tested_commit -or
        -not $result.environment.interactive_desktop -or [string]::IsNullOrWhiteSpace([string]$result.environment.runner_name)) {
        throw "Interactive artifact result does not prove a passing exact-SHA desktop run for $($evidence.tested_commit)."
    }
    $uiaTrees = @(Get-ChildItem -LiteralPath $downloadRoot -Filter uia-tree.json -Recurse)
    if ($uiaTrees.Count -lt 1) { throw "Interactive artifact for run $runId lacks automated UIA evidence." }
    $provenancePaths = @(Get-ChildItem -LiteralPath $downloadRoot -Filter winghostty-runner-provenance.json -Recurse)
    if ($provenancePaths.Count -ne 1) { throw "Interactive artifact for run $runId lacks exactly one runner provenance file." }
    try {
        $provenance = Get-Content -LiteralPath $provenancePaths[0].FullName -Raw | ConvertFrom-Json
    }
    catch {
        throw "Interactive runner provenance for run $runId is malformed: $($_.Exception.Message)"
    }
    if ($provenance.schema_version -ne 'winghostty.interactive-runner-provenance.v1') {
        throw "Interactive runner provenance for run $runId has unsupported schema '$($provenance.schema_version)'."
    }
    $minimumRunnerVersion = [version]'2.327.1'
    [version]$provenanceRunnerVersion = $null
    if (-not [version]::TryParse([string]$provenance.runner_version, [ref]$provenanceRunnerVersion)) {
        throw "Interactive runner provenance for run $runId lacks a valid runner version."
    }
    if ($provenance.runner_os -ne 'Windows' -or
        $provenance.runner_arch -ne 'X64' -or
        $provenanceRunnerVersion -lt $minimumRunnerVersion -or
        $provenance.runner_environment -ne 'self-hosted' -or
        $provenance.input_desktop -ne 'Default' -or
        [string]::IsNullOrWhiteSpace([string]$provenance.runner_name) -or
        $provenance.runner_name -ne $result.environment.runner_name -or
        $provenance.runner_name -ne $interactiveJob[0].runner_name -or
        [string]$provenance.user -match '(?i)(^|\\)SYSTEM$' -or
        [int]$provenance.windows_build -lt 22000 -or
        [int]$provenance.process_session_id -le 0 -or
        [int]$provenance.process_session_id -ne [int]$provenance.active_console_session_id -or
        $provenance.repository -ne 'amanthanvi/winghostty' -or
        $provenance.workflow -ne 'Test' -or
        [string]$provenance.run_id -ne [string]$runId -or
        [int]$provenance.run_attempt -lt 1 -or
        [int]$provenance.run_attempt -ne [int]$run.run_attempt -or
        [int]$provenance.run_attempt -ne [int]$result.workflow_run_attempt -or
        $provenance.commit -ne $evidence.tested_commit) {
        throw "Interactive runner provenance does not satisfy the release contract for run $runId."
    }
}
finally {
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedDownload = [System.IO.Path]::GetFullPath($downloadRoot)
    if ($resolvedDownload.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedDownload)) {
        Remove-Item -LiteralPath $resolvedDownload -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$global:LASTEXITCODE = 0
Write-Host "Accessibility evidence: PASS (v$Version, $($evidence.tested_commit), $($evidence.workflow_run_url))" -ForegroundColor Green
