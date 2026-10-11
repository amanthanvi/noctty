[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$startupPath = Join-Path $env:LOCALAPPDATA 'noctty\startup-attempts.json'
$before = if (Test-Path -LiteralPath $startupPath) {
    [pscustomobject]@{
        Hash = (Get-FileHash -LiteralPath $startupPath -Algorithm SHA256).Hash
        Modified = (Get-Item -LiteralPath $startupPath).LastWriteTimeUtc
    }
}
$oldProbe = [Environment]::GetEnvironmentVariable('NOCTTY_RUN_LINK_PATHEXT_PROBE', 'Process')
$oldReceipt = [Environment]::GetEnvironmentVariable('NOCTTY_LINK_PATHEXT_PROBE_RECEIPT', 'Process')
$probeDirectory = Join-Path $repoRoot ('.sandbox\link-probe-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $probeDirectory)
$receiptPath = Join-Path $probeDirectory 'completed.txt'
Push-Location $repoRoot
try {
    # The callable production gate and real ShellExecute control run in a Zig
    # test on a hidden desktop. Only owned temp-folder marker commands execute.
    # No noctty.exe is launched and no real profile is used.
    $env:NOCTTY_RUN_LINK_PATHEXT_PROBE = '1'
    $env:NOCTTY_LINK_PATHEXT_PROBE_RECEIPT = $receiptPath
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList @(
        '/d', '/c',
        'scripts\dev-windows.cmd zig build test -Demit-test-exe=true -Dtest-filter="link opener PATHEXT live probe" --summary all'
    ) -NoNewWindow -PassThru
    $process.PriorityClass = 'BelowNormal'
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "PATHEXT probe failed: exit $($process.ExitCode)" }
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf) -or
        [IO.File]::ReadAllText($receiptPath) -cne "NOCTTY_LINK_PATHEXT_PROBE_COMPLETE`n") {
        throw 'PATHEXT probe did not produce its completion receipt; the live test may not have run.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable('NOCTTY_RUN_LINK_PATHEXT_PROBE', $oldProbe, 'Process')
    [Environment]::SetEnvironmentVariable('NOCTTY_LINK_PATHEXT_PROBE_RECEIPT', $oldReceipt, 'Process')
    Pop-Location
    if ($null -ne $before) {
        $afterHash = (Get-FileHash -LiteralPath $startupPath -Algorithm SHA256).Hash
        $afterModified = (Get-Item -LiteralPath $startupPath).LastWriteTimeUtc
        if ($afterHash -ne $before.Hash -or $afterModified -ne $before.Modified) {
            throw 'Real startup-attempts.json changed during the probe.'
        }
    }
    elseif (Test-Path -LiteralPath $startupPath) {
        throw 'Real startup-attempts.json was created during the probe.'
    }
}
Write-Host 'PATHEXT and leading-dot controls executed only owned marker commands; the production gate refused the missing targets and leading-dot handlers before shell dispatch.'
Write-Host "Completion receipt: $receiptPath"
