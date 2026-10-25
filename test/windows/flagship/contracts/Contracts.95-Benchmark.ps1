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
$win32Constants = Join-Path $repoRoot 'src\apprt\win32\consts.zig'
$win32ConstantsText = Get-Content -LiteralPath $win32Constants -Raw
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

# Each gate command is pinned as a whole line, followed by the exit-code check
# that lets its failure fail the step. Matching argument by argument let a
# trailing `--min-mb-s=0` (the tool takes the last value, so it disables the
# gate), a changed `--bytes` or a commented-out line through. The floors are for
# the fastest run (docs/windows-benchmark-methodology.md, BENCH-VT-FLOOR-01).
$benchmarkGateCommands = @(
    'zig build bench:vt-throughput -- --workload=ascii --bytes=4194304 --seed=121 --runs=60 --rows=45 --cols=140 --min-mb-s=50'
    'zig build bench:vt-throughput -- --workload=utf8 --bytes=4194304 --seed=121 --runs=60 --rows=45 --cols=140 --min-mb-s=35'
    'zig build bench:vt-throughput -- --workload=osc --bytes=4194304 --seed=121 --runs=20 --rows=45 --cols=140 --min-mb-s=3'
    'zig build bench:vt-throughput -- --workload=scroll --bytes=4194304 --seed=121 --runs=60 --rows=45 --cols=140 --min-mb-s=50'
    'zig build bench:palette-match -- --entries=5000 --keystrokes=5000 --budget-us=2500'
)
$benchmarkGateLinePatterns = foreach ($command in $benchmarkGateCommands) {
    '^[ \t]*' + [regex]::Escape($command) + '[ \t]*\r?\n[ \t]*if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}[ \t]*\r?$'
}
$benchmarkGateStepPattern = '(?ms)' + ($benchmarkGateLinePatterns -join '.*?')
# Exactly four throughput invocations in the job: an extra one could re-run a
# workload with a floor of 0. Comments (a line that starts with `#`, or a `<# ... #>`
# block, as in the job's pwsh steps) are not invocations, so a note in the job that
# names the step does not count; every other line that names it does.
$benchmarkGateCountPattern = '(?s)\A(?:(?!bench:vt-throughput).)*(?:bench:vt-throughput(?:(?!bench:vt-throughput).)*){4}\z'
# One left-to-right pass, so a `<#` inside a line comment opens no block and a `#` line
# inside a block closes nothing early.
$benchmarkGateCommentPattern = '<#.*?#>|^[ \t]*#[^\r\n]*'
function Get-BenchmarkGateCountText([string] $JobText) {
    [regex]::Replace($JobText, $benchmarkGateCommentPattern, '', [System.Text.RegularExpressions.RegexOptions]'Singleline, Multiline')
}
# The runner's CPU is logged to read a failure against; looking it up must never
# be able to fail the step before any benchmark runs.
$benchmarkGateCpuLine = "try { Write-Host ('runner cpu: ' + (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()) } catch { Write-Host 'runner cpu: unknown' }"
$benchmarkGateCpuPattern = '(?m)^[ \t]*' + [regex]::Escape($benchmarkGateCpuLine) + '[ \t]*\r?$'
$benchmarkGateStepName = 'Headless benchmark regression gates'

function Test-BenchmarkGateJob([string] $JobText) {
    $step = Get-YamlStepBlock -Content $JobText -Name $benchmarkGateStepName -Source $testWorkflow
    [regex]::IsMatch($step, $benchmarkGateStepPattern) -and
    [regex]::IsMatch($step, $benchmarkGateCpuPattern) -and
    [regex]::IsMatch((Get-BenchmarkGateCountText $JobText), $benchmarkGateCountPattern)
}

Invoke-ContractTable -Contracts @(
    @{
        File = "$testWorkflow :: bench headless benchmark gates"
        Content = {
            (Get-YamlStepBlock -Content (Get-YamlJobText -Content $testWorkflowText -Name 'bench' -Source $testWorkflow) -Name $benchmarkGateStepName -Source $testWorkflow)
        }
        Pattern = $benchmarkGateStepPattern
        Kind = 'Text'
        Description = 'CI runs every headless throughput floor on the fastest of 60 runs (20 for OSC) and the palette budget, each command exactly'
    }
    @{
        File = "$testWorkflow :: bench headless benchmark gates"
        Content = {
            (Get-YamlStepBlock -Content (Get-YamlJobText -Content $testWorkflowText -Name 'bench' -Source $testWorkflow) -Name $benchmarkGateStepName -Source $testWorkflow)
        }
        Pattern = $benchmarkGateCpuPattern
        Kind = 'Text'
        Description = 'the gate step logs the runner CPU best effort, so the lookup cannot fail the step'
    }
    @{
        File = "$testWorkflow :: bench headless benchmark gates"
        Content = {
            Get-BenchmarkGateCountText (Get-YamlJobText -Content $testWorkflowText -Name 'bench' -Source $testWorkflow)
        }
        Pattern = $benchmarkGateCountPattern
        Kind = 'Text'
        Description = 'the bench job invokes the throughput gate exactly four times, comment lines aside'
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
        File = $benchmarkHarness
        Content = { $benchmarkHarnessText }
        Pattern = '(?s)pendingAltScreenSequence\s*=\s*null.*?remainingPayload.*?bytes\.LongLength > remainingPayload.*?pendingAltScreenSequence\s*=\s*bytes.*?pendingAltScreenOffset.*?Array\.Copy\(pendingAltScreenSequence, pendingAltScreenOffset.*?pendingAltScreenOffset == pendingAltScreenSequence\.Length'
        Kind = 'Text'
        Description = 'alternate-screen payload generation carries complete CSI sequences across stream buffers'
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
        File = "$win32Constants + $benchmarkHarness :: render-trace message IDs"
        Content = { $win32ConstantsText + "`n" + $benchmarkHarnessText }
        Pattern = '(?s)WM_WINHOSTTY_TERMINAL_HANDOFF\s*=\s*WM_APP \+ 7.*?WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT\s*=\s*WM_APP \+ 8.*?WM_WINHOSTTY_RENDER_TRACE_TARGET\s*=\s*WM_APP \+ 9.*?WmWinhosttyRenderTraceSnapshot\s*=\s*\[uint32\] \(0x8000 \+ 8\).*?WmWinhosttyRenderTraceTarget\s*=\s*\[uint32\] \(0x8000 \+ 9\).*?\$message\s*=\s*\$script:WmWinhosttyRenderTraceSnapshot.*?\$message\s*=\s*\$script:WmWinhosttyRenderTraceTarget'
        Kind = 'Text'
        Description = 'Zig handlers and the PowerShell live-trace client use the same collision-free message IDs'
    }
    @{
        File = $memoryTrace
        Content = { $memoryTraceText }
        Pattern = '(?s)pub fn noteOnce.*?return self\.note\(stage, surface_token, surface_id\).*?pub fn noteIoReaderSpawned.*?if \(self\.noteOnce.*?io_reader_ready\.store\(true, \.release\).*?claimFirstSwapObservation.*?io_reader_ready\.load\(\.acquire\).*?first_swap_recorded\.cmpxchgStrong'
        Kind = 'Text'
        Description = 'the startup swap boundary cannot precede successfully serialized IO reader startup evidence'
    }
    @{
        File = "$rendererGeneric + src\renderer\Thread.zig :: renderer frame activity"
        Content = { $rendererGenericText + "`n" + (Get-Content -LiteralPath (Join-Path $repoRoot 'src\renderer\Thread.zig') -Raw) }
        Pattern = '(?s)output_progress\s*=\s*null.*?\.output_progress\s*=\s*output_progress.*?noteRendererUpdateFrame\(update\.output_progress, cursor_blinking\)'
        Kind = 'Text'
        Description = 'completed frame updates remain observable even when output provenance is intentionally unavailable'
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

# Negative controls for the gate commands above. They mutate only the workflow
# text already read and never run anything. Every mutant must be rejected: the
# trailing floor of 0, the changed bytes, the commented-out line and the
# unchecked exit code each left the older argument-by-argument pattern passing.
# Positive controls follow them: comments that name the step are accepted.
$benchmarkGateJob = Get-YamlJobText -Content $testWorkflowText -Name 'bench' -Source $testWorkflow
if (Test-BenchmarkGateJob $benchmarkGateJob) {
    $gateCmd = $benchmarkGateCommands
    $benchmarkGateMutants = [System.Collections.Generic.List[object]]::new()
    foreach ($case in @(
        @{ Index = 0; To = "$($gateCmd[0]) --min-mb-s=0" }
        @{ Index = 3; To = "$($gateCmd[3]) --runs=1" }
        @{ Index = 0; To = $gateCmd[0].Replace('--bytes=4194304', '--bytes=4096') }
        @{ Index = 1; To = $gateCmd[1].Replace('--seed=121', '--seed=7') }
        @{ Index = 2; To = $gateCmd[2].Replace('--rows=45', '--rows=4') }
        @{ Index = 1; To = $gateCmd[1].Replace('--cols=140', '--cols=14') }
        @{ Index = 0; To = "# $($gateCmd[0])" }
        @{ Index = 3; To = "# $($gateCmd[3])" }
        @{ Index = 0; To = $gateCmd[0].Replace('--min-mb-s=50', '--min-mb-s=40') }
        @{ Index = 3; To = $gateCmd[3].Replace('--min-mb-s=50', '--min-mb-s=5') }
        @{ Index = 1; To = $gateCmd[1].Replace('--min-mb-s=35', '--min-mb-s=3.5') }
        @{ Index = 2; To = $gateCmd[2].Replace('--min-mb-s=3', '--min-mb-s=3e-9') }
        @{ Index = 0; To = $gateCmd[0].Replace('--runs=60', '--runs=5') }
        @{ Index = 0; To = $gateCmd[0].Replace('--runs=60', '--runs=600') }
        @{ Index = 2; To = $gateCmd[2].Replace('--runs=20', '--runs=2') }
        @{ Index = 4; To = $gateCmd[4].Replace('--budget-us=2500', '--budget-us=250000') }
    )) {
        $benchmarkGateMutants.Add(@{ Name = $case.To; Text = $benchmarkGateJob.Replace($gateCmd[$case.Index], $case.To) })
    }
    # A fifth throughput invocation after the real four, with its floor disabled.
    $benchmarkGateMutants.Add(@{ Name = 'a fifth invocation'; Text = $benchmarkGateJob.TrimEnd() + "`n          $($gateCmd[0]) --min-mb-s=0`n" })
    # The same, behind a `#` that is not the first character of its line (after a
    # space, so a filter that cuts at any `#` preceded by whitespace fails too): only a
    # line that starts with `#` is a comment.
    $benchmarkGateMutants.Add(@{ Name = 'a fifth invocation behind a mid-line #'; Text = $benchmarkGateJob.TrimEnd() + "`n          Write-Host ' #'; $($gateCmd[0]) --min-mb-s=0`n" })
    # Block comments only hide what they enclose: an invocation after a closed one, one
    # behind a `#>` with no opener, and one between two blocks (a greedy `<#.*#>` would
    # swallow it) all still run.
    $benchmarkGateMutants.Add(@{ Name = 'a fifth invocation after a closed block comment'; Text = $benchmarkGateJob.TrimEnd() + "`n          <# note #> $($gateCmd[0]) --min-mb-s=0`n" })
    $benchmarkGateMutants.Add(@{ Name = 'a fifth invocation behind a lone #>'; Text = $benchmarkGateJob.TrimEnd() + "`n          Write-Host '#>'; $($gateCmd[0]) --min-mb-s=0`n" })
    $benchmarkGateMutants.Add(@{ Name = 'a fifth invocation between two block comments'; Text = $benchmarkGateJob.TrimEnd() + "`n          <# a #>`n          $($gateCmd[0]) --min-mb-s=0`n          <# b #>`n" })
    # A CPU lookup that can fail the step.
    $benchmarkGateMutants.Add(@{ Name = 'a CPU lookup without try/catch'; Text = $benchmarkGateJob.Replace($benchmarkGateCpuLine, "Write-Host ('runner cpu: ' + (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim())") })
    # A command whose exit code is no longer checked.
    foreach ($command in $gateCmd) {
        $unchecked = '(' + [regex]::Escape($command) + ')[ \t]*\r?\n[ \t]*if \(\$LASTEXITCODE -ne 0\) \{ exit \$LASTEXITCODE \}'
        $benchmarkGateMutants.Add(@{ Name = "no exit-code check after '$command'"; Text = [regex]::Replace($benchmarkGateJob, $unchecked, '$1') })
    }
    foreach ($mutant in $benchmarkGateMutants) {
        if ($mutant.Text -ceq $benchmarkGateJob) { throw "Benchmark gate mutation '$($mutant.Name)' changed nothing." }
        if (Test-BenchmarkGateJob $mutant.Text) { throw "Benchmark gate contract accepted '$($mutant.Name)'." }
    }
    # Positive controls: a comment that names the step is not an invocation. The
    # unfiltered count rejects each of these texts, so they exercise the comment filter.
    # The last one opens a `<#` inside a line comment and closes a block at the end of
    # the job: a filter that strips block comments before line comments would pair
    # them and swallow the four real invocations between.
    $benchmarkGateCommentedJobs = @(
        $benchmarkGateJob.Replace($gateCmd[0], "# the floors below run bench:vt-throughput four times`n          $($gateCmd[0])")
        $benchmarkGateJob.Replace($gateCmd[0], "<# the floors below run bench:vt-throughput four times #>`n          $($gateCmd[0])")
        $benchmarkGateJob.Replace($gateCmd[0], "<#`n          the floors below run`n          bench:vt-throughput four times`n          #>`n          $($gateCmd[0])")
        $benchmarkGateJob.Replace($gateCmd[0], "# a note that mentions <# and never closes it`n          $($gateCmd[0])").TrimEnd() + "`n          <# bench:vt-throughput is pinned #>`n"
    )
    foreach ($benchmarkGateCommented in $benchmarkGateCommentedJobs) {
        if ($benchmarkGateCommented -ceq $benchmarkGateJob) { throw 'The benchmark gate comment control changed nothing.' }
        if ([regex]::IsMatch($benchmarkGateCommented, $benchmarkGateCountPattern)) { throw 'The benchmark gate comment control does not reach the invocation count.' }
        if (-not (Test-BenchmarkGateJob $benchmarkGateCommented)) { throw 'Benchmark gate contract rejected a comment that names the step.' }
    }
}
