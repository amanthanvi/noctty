[CmdletBinding()]
param(
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$exePath = Join-Path $repoRoot 'zig-out\bin\conpty-host.exe'
$sandboxParent = Join-Path $repoRoot '.sandbox'
$sandboxName = "conpty-host-spike-$([Guid]::NewGuid().ToString('N'))"
$sandbox = Join-Path $sandboxParent $sandboxName
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$startedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$hostProcess = $null
$shellProcess = $null
$shellPid = $null
$stage = 'preflight'
$failure = $null
$failureKind = 'harness'
$cleanupFailure = $null
$result = $null
$ringCapacity = 1024 * 1024

function Get-SharedText {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally {
        $stream.Dispose()
    }
}

function Wait-TextPattern {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Description,
        [System.Diagnostics.Process] $Process,
        [string] $StderrPath
    )

    while ([DateTime]::UtcNow -lt $deadline) {
        $text = Get-SharedText -Path $Path
        $match = [regex]::Match($text, $Pattern)
        if ($match.Success) { return $match }
        if ($Process) {
            $Process.Refresh()
            if ($Process.HasExited) {
                $stderr = if ($StderrPath) { Get-SharedText -Path $StderrPath } else { '' }
                throw "$Description process exited early (pid=$($Process.Id), exit=$($Process.ExitCode), stderr=$stderr)"
            }
        }
        Start-Sleep -Milliseconds 50
    }
    throw "timed out waiting for $Description in $Path"
}

function Stop-ExactProcess {
    param([System.Diagnostics.Process] $Process)

    if (-not $Process) { return }
    $Process.Refresh()
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        if (-not $Process.WaitForExit(5000)) {
            throw "exact-PID process did not exit after forced stop: pid=$($Process.Id)"
        }
    }
}

function Start-AttachClient {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $PipeName,
        [Parameter(Mandatory)][string] $InputPath,
        [string] $Resize,
        [switch] $StayOnEof
    )

    $stdoutPath = Join-Path $sandbox "$Name.stdout.log"
    $stderrPath = Join-Path $sandbox "$Name.stderr.log"
    $arguments = @('attach', '--pipe', $PipeName)
    if ($Resize) { $arguments += @('--resize', $Resize) }
    if ($StayOnEof) { $arguments += '--stay-on-eof' }

    $process = Start-Process `
        -FilePath $exePath `
        -ArgumentList $arguments `
        -WorkingDirectory $repoRoot `
        -RedirectStandardInput $InputPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    $startedProcesses.Add($process)
    return [pscustomobject]@{
        Process = $process
        Stdout = $stdoutPath
        Stderr = $stderrPath
    }
}

try {
    if ($env:OS -ne 'Windows_NT') {
        $failureKind = 'environmental'
        throw 'Windows is required; this is an environmental failure, not an architectural verdict.'
    }
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        $failureKind = 'environmental'
        throw "missing spike executable: $exePath (run zig build -Demit-conpty-host=true first)"
    }
    if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $failureKind = 'environmental'
        throw 'pwsh.exe is unavailable; this is an environmental failure, not an architectural verdict.'
    }

    [void](New-Item -ItemType Directory -Path $sandboxParent -Force)
    [void](New-Item -ItemType Directory -Path $sandbox)
    $emptyInput = Join-Path $sandbox 'empty.input'
    [System.IO.File]::WriteAllBytes($emptyInput, [byte[]]::new(0))

    $pipeName = "spike-$([Guid]::NewGuid().ToString('N'))"
    $hostStdout = Join-Path $sandbox 'host.stdout.log'
    $hostStderr = Join-Path $sandbox 'host.stderr.log'

    $stage = 'start-host'
    $failureKind = 'feasibility'
    $hostProcess = Start-Process `
        -FilePath $exePath `
        -ArgumentList @('serve', '--pipe', $pipeName) `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $hostStdout `
        -RedirectStandardError $hostStderr `
        -PassThru
    $startedProcesses.Add($hostProcess)

    $ready = Wait-TextPattern `
        -Path $hostStdout `
        -Pattern 'CONPTY_HOST_READY .*shell_pid=(\d+) ring_capacity=(\d+) security=current-user' `
        -Description 'host readiness' `
        -Process $hostProcess `
        -StderrPath $hostStderr
    $hostReportedShellPid = [int]$ready.Groups[1].Value
    if ([int]$ready.Groups[2].Value -ne $ringCapacity) {
        throw "host used unexpected ring capacity: $($ready.Groups[2].Value)"
    }

    $stage = 'initial-attach'
    $stateToken = "STATE_$([Guid]::NewGuid().ToString('N'))"
    $tuiProbeId = [Guid]::NewGuid().ToString('N')
    $tuiContentToken = "TUI_CONTENT_$tuiProbeId"
    $tuiInitialRedrawToken = "TUI_REDRAW_80x24_$tuiProbeId"
    $tuiResizedRedrawToken = "TUI_REDRAW_100x31_$tuiProbeId"
    $escape = [char]27
    $boxTop = '+----------------------------------------------------------+'
    # ConPTY consumes the application's VT and emits a normalized redraw. Match
    # the cursor-home redraw plus the unique content/size tokens, not the exact
    # application byte sequence that conhost intentionally normalizes.
    $cursorHomeBox = [regex]::Escape("$escape[H$boxTop")
    $initialTuiPattern = '(?s)' + [regex]::Escape("$escape[?1049h") +
        '.{0,256}' + $cursorHomeBox + '.{0,2048}' +
        [regex]::Escape($tuiContentToken) + '.{0,2048}' + [regex]::Escape($tuiInitialRedrawToken)
    $resizedTuiPattern = '(?s)' + [regex]::Escape("$escape[2J") +
        '.{0,256}' + $cursorHomeBox + '.{0,2048}' +
        [regex]::Escape($tuiContentToken) + '.{0,2048}' + [regex]::Escape($tuiResizedRedrawToken)
    $initialInput = Join-Path $sandbox 'initial.input'
    $initialCommand = @"
`$global:ConptySpikeState='$stateToken'; `$escape=[char]27; `$lastWidth=0; `$lastHeight=0; `$resizeSeen=`$false; Write-Output ('SHELL_PID={0}' -f `$PID); Write-Output ('STATE_SET={0}' -f `$global:ConptySpikeState); try { [Console]::Write("`$escape[?1049h"); for (`$iteration=0; `$iteration -lt 400; `$iteration++) { `$size=`$Host.UI.RawUI.WindowSize; if (`$size.Width -ne `$lastWidth -or `$size.Height -ne `$lastHeight) { `$redrawToken='TUI_REDRAW_{0}x{1}_$tuiProbeId' -f `$size.Width,`$size.Height; [Console]::Write(("`$escape[2J`$escape[1;1H$boxTop`$escape[2;1H| $tuiContentToken |`$escape[3;1H$boxTop`$escape[4;1H{0}" -f `$redrawToken)); `$lastWidth=`$size.Width; `$lastHeight=`$size.Height; if (`$size.Width -eq 100 -and `$size.Height -eq 31) { `$resizeSeen=`$true; break } }; Start-Sleep -Milliseconds 50 } } finally { [Console]::Write("`$escape[?1049l") }; if (-not `$resizeSeen) { throw 'synthetic TUI did not observe 100x31' }; Write-Output 'LONG_RUNNING_DONE'
"@.Trim() + "`r"
    [System.IO.File]::WriteAllText($initialInput, $initialCommand, [System.Text.UTF8Encoding]::new($false))

    $client1 = Start-AttachClient `
        -Name 'client1' `
        -PipeName $pipeName `
        -InputPath $initialInput `
        -StayOnEof
    $shellMatch = Wait-TextPattern `
        -Path $client1.Stdout `
        -Pattern 'SHELL_PID=(\d+)' `
        -Description 'initial shell PID' `
        -Process $client1.Process `
        -StderrPath $client1.Stderr
    $shellPid = [int]$shellMatch.Groups[1].Value
    $shellProcess = Get-Process -Id $shellPid -ErrorAction Stop
    if ($shellProcess.HasExited) { throw "shell exited before the initial assertion: pid=$shellPid" }
    [void](Wait-TextPattern `
        -Path $client1.Stdout `
        -Pattern "STATE_SET=$([regex]::Escape($stateToken))" `
        -Description 'initial shell state' `
        -Process $client1.Process `
        -StderrPath $client1.Stderr)
    [void](Wait-TextPattern `
        -Path $client1.Stdout `
        -Pattern $initialTuiPattern `
        -Description 'initial cursor-addressed alt-screen box' `
        -Process $client1.Process `
        -StderrPath $client1.Stderr)
    if ($shellPid -ne $hostReportedShellPid) {
        throw "shell PID disagreement: shell=$shellPid host=$hostReportedShellPid"
    }

    $stage = 'hard-kill-first-client'
    $firstClientPid = $client1.Process.Id
    Stop-Process -Id $firstClientPid -Force
    if (-not $client1.Process.WaitForExit(5000)) {
        throw "hard-killed client did not exit: pid=$firstClientPid"
    }
    $shellProcess.Refresh()
    if ($shellProcess.HasExited) { throw "shell exited after client hard kill: pid=$shellPid" }

    $stage = 'reattach-resize'
    $client2 = Start-AttachClient `
        -Name 'client2' `
        -PipeName $pipeName `
        -InputPath $emptyInput `
        -Resize '100x31' `
        -StayOnEof
    [void](Wait-TextPattern `
        -Path $client2.Stdout `
        -Pattern $resizedTuiPattern `
        -Description 'reattached cursor-addressed alt-screen redraw after resize' `
        -Process $client2.Process `
        -StderrPath $client2.Stderr)
    [void](Wait-TextPattern `
        -Path $client2.Stdout `
        -Pattern ([regex]::Escape("$escape[?1049l")) `
        -Description 'alt-screen exit after resized redraw' `
        -Process $client2.Process `
        -StderrPath $client2.Stderr)
    [void](Wait-TextPattern `
        -Path $client2.Stdout `
        -Pattern 'LONG_RUNNING_DONE' `
        -Description 'long-running shell command completion after reattach' `
        -Process $client2.Process `
        -StderrPath $client2.Stderr)
    Stop-ExactProcess -Process $client2.Process

    $stage = 'state-and-overflow-command'
    $oldestToken = "OLDEST_$([Guid]::NewGuid().ToString('N'))"
    $newestToken = "NEWEST_$([Guid]::NewGuid().ToString('N'))"
    $overflowInput = Join-Path $sandbox 'overflow.input'
    $overflowDonePath = Join-Path $sandbox 'overflow.done'
    $overflowDoneLiteral = $overflowDonePath.Replace("'", "''")
    $overflowCommand = @"
Write-Output ('REATTACH_PID={0}' -f `$PID); Write-Output ('REATTACH_STATE={0}' -f `$global:ConptySpikeState); Write-Output '$oldestToken'; Start-Sleep -Seconds 2; `$payload='X' * 180; for (`$i=0; `$i -lt 12000; `$i++) { Write-Output ('BUFFER_{0:D5}_{1}' -f `$i,`$payload) }; Write-Output '$newestToken'; Write-Output 'OVERFLOW_DONE'; [System.IO.File]::WriteAllText('$overflowDoneLiteral','done')
"@.Trim() + "`r"
    [System.IO.File]::WriteAllText($overflowInput, $overflowCommand, [System.Text.UTF8Encoding]::new($false))

    $client3 = Start-AttachClient `
        -Name 'client3' `
        -PipeName $pipeName `
        -InputPath $overflowInput `
        -StayOnEof
    $reattachPid = Wait-TextPattern `
        -Path $client3.Stdout `
        -Pattern 'REATTACH_PID=(\d+)' `
        -Description 'reattached shell PID' `
        -Process $client3.Process `
        -StderrPath $client3.Stderr
    $reattachState = Wait-TextPattern `
        -Path $client3.Stdout `
        -Pattern "REATTACH_STATE=$([regex]::Escape($stateToken))" `
        -Description 'reattached shell state' `
        -Process $client3.Process `
        -StderrPath $client3.Stderr
    if ([int]$reattachPid.Groups[1].Value -ne $shellPid) {
        throw "reattached shell PID changed: before=$shellPid after=$($reattachPid.Groups[1].Value)"
    }
    [void](Wait-TextPattern `
        -Path $client3.Stdout `
        -Pattern ([regex]::Escape($oldestToken)) `
        -Description 'oldest overflow marker before detach' `
        -Process $client3.Process `
        -StderrPath $client3.Stderr)

    $hostProcess.Refresh()
    $privateBaseline = [long]$hostProcess.PrivateMemorySize64
    $maxPrivate = $privateBaseline
    Stop-ExactProcess -Process $client3.Process

    $stage = 'detached-ring-overflow'
    $lastRingTotal = 0L
    $lastRingRetained = 0L
    $stableTotal = -1L
    $stableSince = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $hostProcess.Refresh()
        if ($hostProcess.HasExited) { throw "host exited during detached output (exit=$($hostProcess.ExitCode))" }
        $maxPrivate = [Math]::Max($maxPrivate, [long]$hostProcess.PrivateMemorySize64)

        $statsText = Get-SharedText -Path $hostStderr
        $statsMatches = [regex]::Matches($statsText, 'RING_STATS total=(\d+) retained=(\d+) capacity=(\d+)')
        foreach ($stats in $statsMatches) {
            $total = [long]$stats.Groups[1].Value
            $retained = [long]$stats.Groups[2].Value
            $capacity = [long]$stats.Groups[3].Value
            if ($retained -gt $capacity -or $capacity -ne $ringCapacity) {
                throw "ring exceeded its bound: total=$total retained=$retained capacity=$capacity"
            }
            if ($total -gt $lastRingTotal) {
                $lastRingTotal = $total
                $lastRingRetained = $retained
            }
        }
        if ($lastRingTotal -ge ($ringCapacity + ($ringCapacity / 2)) -and
            (Test-Path -LiteralPath $overflowDonePath -PathType Leaf)) {
            if ($lastRingTotal -ne $stableTotal) {
                $stableTotal = $lastRingTotal
                $stableSince = [DateTime]::UtcNow
            }
            elseif ($stableSince -and ([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge 750) {
                break
            }
        }
        Start-Sleep -Milliseconds 25
    }
    if ($lastRingTotal -lt ($ringCapacity + ($ringCapacity / 2))) {
        throw "detached output did not overflow the ring: total=$lastRingTotal capacity=$ringCapacity"
    }
    if (-not (Test-Path -LiteralPath $overflowDonePath -PathType Leaf)) {
        throw 'detached overflow command did not reach its completion sentinel'
    }
    if (-not $stableSince -or ([DateTime]::UtcNow - $stableSince).TotalMilliseconds -lt 750) {
        throw 'detached ConPTY drain did not reach a stable output-total barrier before reattach'
    }
    $privateGrowth = [Math]::Max(0L, $maxPrivate - $privateBaseline)
    if ($privateGrowth -gt $ringCapacity) {
        throw "host private-memory growth exceeded ring cap while detached: growth=$privateGrowth cap=$ringCapacity"
    }

    $stage = 'bounded-ring-replay'
    $client4 = Start-AttachClient `
        -Name 'client4' `
        -PipeName $pipeName `
        -InputPath $emptyInput `
        -StayOnEof
    [void](Wait-TextPattern `
        -Path $client4.Stdout `
        -Pattern ([regex]::Escape($newestToken)) `
        -Description 'newest overflow marker on replay' `
        -Process $client4.Process `
        -StderrPath $client4.Stderr)
    [void](Wait-TextPattern `
        -Path $client4.Stdout `
        -Pattern 'OVERFLOW_DONE' `
        -Description 'overflow completion on replay' `
        -Process $client4.Process `
        -StderrPath $client4.Stderr)
    $replayBytes = 0L
    while ([DateTime]::UtcNow -lt $deadline) {
        $replayBytes = (Get-Item -LiteralPath $client4.Stdout).Length
        if ($replayBytes -ge $ringCapacity) { break }
        Start-Sleep -Milliseconds 25
    }
    if ($replayBytes -lt $ringCapacity) {
        throw "full retained ring was not replayed: bytes=$replayBytes capacity=$ringCapacity"
    }
    $replayText = Get-SharedText -Path $client4.Stdout
    if ($replayText.Contains($oldestToken)) {
        throw 'oldest overflow marker survived despite more than one ring capacity of newer output'
    }
    Stop-ExactProcess -Process $client4.Process

    $stage = 'detach-frame'
    $client5 = Start-AttachClient `
        -Name 'client5' `
        -PipeName $pipeName `
        -InputPath $emptyInput
    if (-not $client5.Process.WaitForExit(10000)) {
        throw "detach-on-EOF client did not exit: pid=$($client5.Process.Id)"
    }
    if ($client5.Process.ExitCode -ne 0) {
        throw "detach-on-EOF client failed: exit=$($client5.Process.ExitCode) stderr=$(Get-SharedText -Path $client5.Stderr)"
    }
    $shellProcess.Refresh()
    if ($shellProcess.HasExited) { throw "shell exited after detach frame: pid=$shellPid" }

    $result = [ordered]@{
        result = 'PASS'
        verdict = 'GREEN'
        host_pid = $hostProcess.Id
        killed_client_pid = $firstClientPid
        shell_pid = $shellPid
        same_shell_pid = $true
        shell_state_intact = $true
        alt_screen_entered = $true
        alt_screen_redraw = 'cursor-addressed-preexisting-content@100x31'
        alt_screen_exited = $true
        detached_drain = $true
        detached_output_completed = $true
        ring_capacity_bytes = $ringCapacity
        ring_retained_bytes = $lastRingRetained
        ring_total_bytes = $lastRingTotal
        replay_bytes = $replayBytes
        oldest_replay_absent = $true
        newest_replay_present = $true
        observed_host_private_baseline_bytes = $privateBaseline
        observed_host_private_max_detached_bytes = $maxPrivate
        observed_host_private_growth_bytes = $privateGrowth
        observed_private_growth_within_ring_cap = $true
        pipe_security = 'current-user-DACL+first-instance+reject-remote'
        detach_frame = $true
        ceiling = 'same-logon-session-only;never-logoff-or-reboot'
    }
}
catch {
    $failure = $_
}
finally {
    for ($index = $startedProcesses.Count - 1; $index -ge 0; $index--) {
        $process = $startedProcesses[$index]
        try {
            Stop-ExactProcess -Process $process
        }
        catch {
            $message = "exact-PID cleanup failed for pid=$($process.Id): $($_.Exception.Message)"
            $cleanupFailure = if ($cleanupFailure) { "$cleanupFailure; $message" } else { $message }
        }
        $process.Dispose()
    }

    if ($shellProcess) {
        try {
            Stop-ExactProcess -Process $shellProcess
        }
        catch {
            $message = "exact shell-PID cleanup failed for pid=$shellPid`: $($_.Exception.Message)"
            $cleanupFailure = if ($cleanupFailure) { "$cleanupFailure; $message" } else { $message }
        }
        $shellProcess.Dispose()
    }

    if (-not $failure -and (Test-Path -LiteralPath $sandbox)) {
        $resolvedParent = [System.IO.Path]::GetFullPath($sandboxParent).TrimEnd('\') + '\'
        $resolvedSandbox = [System.IO.Path]::GetFullPath($sandbox)
        if (-not $resolvedSandbox.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([System.IO.Path]::GetFileName($resolvedSandbox)).StartsWith('conpty-host-spike-', [StringComparison]::Ordinal)) {
            $cleanupFailure = "refusing to remove unexpected sandbox path: $resolvedSandbox"
        }
        else {
            for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $resolvedSandbox); $attempt++) {
                try {
                    [System.IO.Directory]::Delete($resolvedSandbox, $true)
                }
                catch {
                    if ($attempt -eq 19) {
                        $cleanupFailure = "sandbox cleanup failed: $($_.Exception.Message)"
                    }
                    else {
                        Start-Sleep -Milliseconds 100
                    }
                }
            }
        }
    }
}

if (-not $failure -and $cleanupFailure) {
    $stage = 'cleanup'
    $failureKind = 'cleanup'
    $failure = [System.Management.Automation.RuntimeException]::new($cleanupFailure)
}

if ($failure) {
    $failureResult = [ordered]@{
        result = 'FAIL'
        verdict = if ($failureKind -eq 'feasibility') { 'RED' } else { 'INCONCLUSIVE' }
        failure_kind = $failureKind
        stage = $stage
        error = $failure.Exception.Message
        shell_pid = $shellPid
        cleanup_error = $cleanupFailure
    }
    Write-Output "CONPTY_HOST_SPIKE_RESULT $($failureResult | ConvertTo-Json -Compress)"
    exit 1
}

Write-Output "CONPTY_HOST_SPIKE_RESULT $($result | ConvertTo-Json -Compress)"
exit 0
