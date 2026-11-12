#Requires -Version 7.0
<# Regression checks; receipt files use a new private temporary folder only. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'settings-open-readiness.psm1') -Force
$checks = 0
function Check([bool] $Condition, [string] $Description) {
    if (-not $Condition) { throw "Readiness regression: $Description" }
    $script:checks++
}
function State($Attempts) {
    $json = ConvertTo-Json -InputObject @{ schema_version = 1; attempts = @($Attempts) } -Depth 5 -Compress
    Read-StartupAttempt -Json $json
}
function Attempt([uint64] $Started, [string] $Phase = 'init', $ReadyAt = $null) {
    @{ started_at_unix_ms = $Started; phase = $Phase; ready_at_unix_ms = $ReadyAt }
}

$oldReady = Attempt 100 'ready' 150
$state = State @($oldReady)
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 100
Check (-not $result.ready -and $result.stage -eq 'startup-stale') 'old ready marker cannot release a new launch'
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 101
Check (-not $result.ready) 'older marker cannot release a new launch'

$state = State @($oldReady, (Attempt 200 'init'))
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 100
Check (-not $result.ready -and $result.stage -eq 'startup-pending') 'old ready plus new init remains pending'
Check ($result.attempt.started_at_unix_ms -eq 200) 'latest attempt controls readiness'
$state = State @($oldReady, (Attempt 200 'window_created'))
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 100
Check (-not $result.ready) 'window creation alone is not startup ready'

$state = State @($oldReady, (Attempt 200 'ready' 250))
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 100
Check ($result.ready -and $result.stage -eq 'startup-ready') 'distinct ready marker releases the launch'
Check ($result.attempt.ready_at_unix_ms -eq 250) 'ready timestamp is preserved in receipt'
$result = Get-NewReadyAttempt -State (State @((Attempt 200 'ready' 200)))
Check $result.ready 'first launch may become ready without an earlier ledger'

$result = Get-NewReadyAttempt -State (State @((Attempt 200 'ready')))
Check (-not $result.ready) 'ready phase without ready timestamp cannot pass'
$result = Get-NewReadyAttempt -State (State @((Attempt 200 'ready' 199)))
Check (-not $result.ready -and $result.stage -eq 'startup-invalid') 'ready timestamp before start is rejected'
$result = Get-NewReadyAttempt -State (State @((Attempt 200 'ready_persist_failed')))
Check (-not $result.ready) 'ready persistence failure remains pending'

$result = Get-NewReadyAttempt -State (Read-StartupAttempt -Json '{') -PreviousStartedAt 100
Check (-not $result.ready -and $result.stage -eq 'startup-malformed') 'partial JSON remains pending with parse stage'
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 100
Check $result.ready 'subsequent complete atomic ledger can pass after a parse failure'
$result = Get-NewReadyAttempt -State (State @())
Check (-not $result.ready -and $result.stage -eq 'startup-empty') 'empty ledger remains pending'
$missing = Join-Path ([IO.Path]::GetTempPath()) ('koreterm-readiness-absent-' + [guid]::NewGuid().ToString('N'))
$result = Get-NewReadyAttempt -State (Read-StartupAttempt -Path $missing)
Check (-not $result.ready -and $result.stage -eq 'startup-missing') 'missing ledger remains pending'

$state = Read-StartupAttempt -Json '{"schema_version":2,"attempts":[]}'
Check ($state.stage -eq 'invalid') 'unknown schema is rejected'
$state = Read-StartupAttempt -Json '{"schema_version":1,"attempts":{}}'
Check ($state.stage -eq 'invalid') 'object-shaped attempts are rejected'
$state = State @((Attempt 200 'ready' 250), (Attempt 100 'ready' 150))
Check ($state.stage -eq 'invalid') 'out-of-order ledger cannot select an earlier attempt'
$state = State @(@{ started_at_unix_ms = -1; phase = 'ready'; ready_at_unix_ms = 2 })
Check ($state.stage -eq 'invalid') 'negative start timestamp is rejected'
$state = State @((Attempt 200 'unknown' 250))
Check ($state.stage -eq 'invalid') 'unknown lifecycle phase is rejected'

$attempts = @(1..16 | ForEach-Object { Attempt ([uint64]$_ * 100) 'ready' ([uint64]$_ * 100 + 20) })
$state = State $attempts
$result = Get-NewReadyAttempt -State $state -PreviousStartedAt 1500
Check ($result.ready -and $result.attemptCount -eq 16) 'full retained ledger accepts a distinct final ready attempt'
$attempts = @($attempts[1..15]) + @((Attempt 1700 'ready' 1720))
$result = Get-NewReadyAttempt -State (State $attempts) -PreviousStartedAt 1600
Check ($result.ready -and $result.attempt.started_at_unix_ms -eq 1700) 'trimming the oldest attempt does not lose correlation'
$state = State (@($attempts) + @((Attempt 1800 'ready' 1820)))
Check ($state.stage -eq 'invalid') 'oversized ledger is rejected'

$receiptRoot = Join-Path ([IO.Path]::GetTempPath()) ('koreterm-settings-receipt-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($receiptRoot)
$receiptPath = Join-Path $receiptRoot 'receipt.json'
try {
    Write-SettingsOpenReceipt -Path $receiptPath -Value @{ stage = 'first' }
    Check (([IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json).stage -eq 'first') 'first receipt publishes complete JSON'
    $held = [IO.FileStream]::new($receiptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        Write-SettingsOpenReceipt -Path $receiptPath -Value @{ stage = 'second' }
        Check (([IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json).stage -eq 'second') 'replacement succeeds while a reader shares delete'
        $reader = [IO.StreamReader]::new($held)
        try { Check (($reader.ReadToEnd() | ConvertFrom-Json).stage -eq 'first') 'held reader retains a complete previous snapshot' }
        finally { $reader.Dispose() }
    } finally { $held.Dispose() }
    Check (@([IO.Directory]::GetFiles($receiptRoot)).Count -eq 1) 'successful publication consumes temporary siblings'
    $blocked = [IO.FileStream]::new($receiptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { Write-SettingsOpenReceipt -Path $receiptPath -Value @{ failureStage = 'settings-visible'; error = 'stage-timeout' } }
        catch [IO.IOException] { $failed = $true }
        Check $failed 'reader without delete sharing causes an explicit publication failure'
        Check (([IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json).stage -eq 'second') 'failed publication keeps the last complete receipt'
        $retained = @([IO.Directory]::GetFiles($receiptRoot, 'receipt.json.*.tmp'))
        Check ($retained.Count -eq 1) 'failed publication retains one complete temporary sibling'
        $failure = [IO.File]::ReadAllText($retained[0]) | ConvertFrom-Json
        Check ($failure.failureStage -eq 'settings-visible' -and $failure.error -eq 'stage-timeout') 'retained sibling preserves the original timeout boundary and reason'
    } finally { $blocked.Dispose() }
} finally {
    foreach ($temporary in [IO.Directory]::GetFiles($receiptRoot, 'receipt.json.*.tmp')) { [IO.File]::Delete($temporary) }
    [IO.File]::Delete($receiptPath)
    [IO.Directory]::Delete($receiptRoot, $false)
}
"Settings readiness and receipts PASS ($checks checks; app runtime NOT RUN)."
