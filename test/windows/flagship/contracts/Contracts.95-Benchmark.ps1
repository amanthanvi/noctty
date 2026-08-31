# Benchmark suite contracts (#121).
#
# Deliberately narrow. The behavior of the benchmark code is covered by Zig
# unit tests; what cannot be asserted there is that CI actually runs the
# regression gates, that no interactive threshold can silently certify a
# product budget, and that competitor results are never published without a
# proven endpoint. Those three properties are what this fragment guards.

$benchmarkThresholds = Join-Path $repoRoot 'test\windows\bench-thresholds.json'
$benchmarkSchema = Join-Path $repoRoot 'test\windows\bench-evidence.schema.json'
$benchmarkHarness = Join-Path $repoRoot 'test\windows\bench-windows.ps1'
$benchmarkHarnessText = Get-Content -LiteralPath $benchmarkHarness -Raw

# ConvertFrom-Json throws on malformed input, which the caller records as a
# contract failure for this fragment.
$null = Get-Content -LiteralPath $benchmarkSchema -Raw | ConvertFrom-Json -Depth 100

# Every shipped threshold must be provisional and inactive. An active
# threshold would let a median silently certify a PRODUCT.md budget that was
# never reviewed, which is exactly what the methodology doc forbids.
$thresholds = @(Get-Content -LiteralPath $benchmarkThresholds -Raw | ConvertFrom-Json -Depth 100)
if ($thresholds.Count -eq 0) {
    throw 'Benchmark thresholds file is empty.'
}
foreach ($threshold in $thresholds) {
    $name = $threshold.metric
    if ($threshold.active -isnot [bool] -or $threshold.provisional -isnot [bool]) {
        throw "Benchmark threshold '$name' must use real JSON booleans for active/provisional."
    }
    if ($threshold.active -and $threshold.provisional) {
        throw "Benchmark threshold '$name' is both active and provisional."
    }
    if ($threshold.active) {
        throw "Benchmark threshold '$name' is active; no interactive budget has been reviewed yet."
    }
    if (-not $threshold.provisional) {
        throw "Benchmark threshold '$name' must be provisional."
    }
}

Invoke-ContractTable -Contracts @(
    @{
        File = "$testWorkflow :: windows headless benchmark gates"
        Content = {
            (Get-YamlJobText -Content $testWorkflowText -Name 'windows' -Source $testWorkflow)
        }
        Pattern = '(?ms)- name: Headless benchmark regression gates.*?--workload=ascii.*?--min-mb-s=50.*?--workload=utf8.*?--min-mb-s=35.*?--workload=osc.*?--min-mb-s=3.*?--workload=scroll.*?--min-mb-s=50.*?bench:palette-match.*?--budget-us=1000'
        Kind = 'Text'
        Description = 'CI runs every headless throughput floor and the palette budget'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = "(?s)'not-supported'"
        Kind = 'Text'
        Description = 'competitor metrics can report not-supported rather than publishing an unproven endpoint'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)\$Gate.*?adapter'
        Kind = 'Text'
        Description = 'gating refuses adapter-required results instead of passing them through'
    }
)
