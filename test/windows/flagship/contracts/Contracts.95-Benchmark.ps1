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
$termioThread = Join-Path $repoRoot 'src\termio\Thread.zig'
$termioThreadText = Get-Content -LiteralPath $termioThread -Raw
$win32Runtime = Join-Path $repoRoot 'src\apprt\win32.zig'
$win32RuntimeText = Get-Content -LiteralPath $win32Runtime -Raw
$memoryTrace = Join-Path $repoRoot 'src\apprt\win32\bench_trace.zig'
$memoryTraceText = Get-Content -LiteralPath $memoryTrace -Raw
$rendererGeneric = Join-Path $repoRoot 'src\renderer\generic.zig'
$rendererGenericText = Get-Content -LiteralPath $rendererGeneric -Raw
$benchmarkSchemaText = Get-Content -LiteralPath $benchmarkSchema -Raw

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
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)Start-BenchTarget.*?-EndMarker \$nonce.*?Set-BenchRenderTraceTarget -Hwnd \$surfaceHwnd -OutputBytes 0.*?SendUnicodeText.*?first_target_swap_benchmark_end_marker_generation.*?first_target_swap_qpc_ticks'
        Kind = 'Text'
        Description = 'key-response latency consumes the first swap containing its visible nonce marker'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)\$endMarker\s*=\s*"NB.*?\$childScriptArguments \+= @\(''-EndMarker'', \$endMarker\).*?first_target_swap_benchmark_end_marker_generation'
        Kind = 'Text'
        Description = 'every interactive throughput workload uses a committed visible-marker endpoint'
    }
    @{
        File = $benchmarkSchema
        Content = { $benchmarkSchemaText }
        Pattern = '(?s)"metric": \{ "enum": \["throughput_mb_s", "scroll_mb_s"\] \}.*?"terminal_visible_marker_observer_included": \{\s*"const": true'
        Kind = 'Text'
        Description = 'stream and scroll evidence accepts the visible-marker observer used by every workload'
    }
    @{
        File = $termioThread
        Content = { $termioThreadText }
        Pattern = '(?s)noteBenchmarkIoThreadStarted\(\);.*?try io\.threadEnter'
        Kind = 'Text'
        Description = 'IO worker publishes its startup before backend reader-thread creation'
    }
    @{
        File = $win32Runtime
        Content = { $win32RuntimeText }
        Pattern = '(?s)WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT.*?render_trace\.requestSnapshot\(\).*?WM_WINHOSTTY_RENDER_TRACE_TARGET.*?render_trace\.setTargetOutputBytes'
        Kind = 'Text'
        Description = 'surface window procedure handles live render-trace control messages'
    }
    @{
        File = $memoryTrace
        Content = { $memoryTraceText }
        Pattern = '(?s)noteIoReaderSpawned.*?noteOnce.*?io_reader_ready\.store\(true, \.release\).*?claimFirstSwapObservation.*?io_reader_ready\.load\(\.acquire\).*?first_swap_recorded\.cmpxchgStrong'
        Kind = 'Text'
        Description = 'the startup swap boundary cannot precede serialized IO reader startup evidence'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)\$previousStageSequence\s*=\s*\[uint64\] 0.*?\$stageSequence -le \$previousStageSequence.*?out of lifecycle order'
        Kind = 'Text'
        Description = 'memory evidence rejects lifecycle stages whose trace sequence contradicts the declared order'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)git -C \$repoRoot status --porcelain=v1 --untracked-files=all.*?source worktree is dirty.*?git -C \$repoRoot rev-parse HEAD'
        Kind = 'Text'
        Description = 'evidence refuses to attribute dirty-source builds to a clean commit SHA'
    }
    @{
        File = $rendererGeneric
        Content = { $rendererGenericText }
        Pattern = '(?s)rebuildCells\(.*?catch \|err\|.*?output_progress\s*=\s*null.*?\.output_progress\s*=\s*output_progress'
        Kind = 'Text'
        Description = 'a frozen GPU-cell fallback cannot publish output progress that was not drawn'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)\$streamWorkloadComplete\s*=\s*\$false.*?if \(\$streamWorkloadComplete -and \$frameTimeSamples\.Count -gt 0\)'
        Kind = 'Text'
        Description = 'frame-time evidence fails closed unless every stream run completes'
    }
    @{
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)\$measurementField\s*=\s*if \(\$record\.metric -eq ''frame_time_p95_ms''\) \{ ''p95'' \} else \{ ''median'' \}.*?\$measured\s*=\s*\[double\] \$record\.\$measurementField'
        Kind = 'Text'
        Description = 'the frame-time p95 threshold compares the p95 statistic rather than the median'
    }
)
