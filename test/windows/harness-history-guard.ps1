#requires -Version 7.0
<#
.SYNOPSIS
Scratch-only acceptance controls for the metadata history guard.
.DESCRIPTION
Runs genuine PSReadLine input under ConPTY on a private desktop, once with
SaveIncrementally (expected guard failure), once with SaveNothing (expected
pass), for each installed Windows PowerShell / pwsh host. Retains all artifacts
under .sandbox/history-guard-<guid>. Never reads or hashes real history.
#>
[CmdletBinding()]
param([switch] $Worker, [string] $RunDirectory, [string] $Desktop, [string] $OwnedJobName)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $repo 'scripts/windows-harness-history.ps1')
. (Join-Path $PSScriptRoot 'interactive-win11-hidden-desktop-lib.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'history-guard-native.cs')

function Save-Receipt([string] $Name, $Value) {
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $RunDirectory $Name) -Encoding UTF8
}
function Assert-ExpectedFailure($Guard, [string] $Case) {
    $message = $null
    try { Assert-WindowsHarnessHistoryGuard -Guard $Guard }
    catch { $message = $_.Exception.Message }
    if (-not $message -or -not $message.Contains($Guard.Harness)) { throw "$Case did not fail with its harness name." }
    return $message
}
function Get-ProtectedStatePaths {
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    return @(
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'koreterm/startup-attempts.json'),
        (Join-Path $roaming 'Microsoft/Windows/Recent/CustomDestinations/c2214d6ebc43ff3f.customDestinations-ms')
    )
}

if ($Worker) {
    # The parent creates this run and passes a private desktop explicitly.
    $RunDirectory = [IO.Path]::GetFullPath($RunDirectory)
    if (-not $RunDirectory.StartsWith((Join-Path $repo '.sandbox/history-guard-'), [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $RunDirectory -PathType Container)) { throw 'Owned run directory required.' }
    try {
        $batchBefore = Get-Content -LiteralPath (Join-Path $RunDirectory 'before.json') -Raw | ConvertFrom-Json
        $workerRealGuard = Start-WindowsHarnessHistoryGuard -Harness 'harness-history-guard'
        $workerRealGuard.Before = @($batchBefore.history)
        $workerStateGuard = Start-WindowsHarnessHistoryGuard -Harness 'harness-history-guard/state' -Paths (Get-ProtectedStatePaths)
        $workerStateGuard.Before = @($batchBefore.startupAndJumpList)
        if (($workerRealGuard.Paths -join "`0") -ine ($batchBefore.historyPaths -join "`0") -or
            ($workerStateGuard.Paths -join "`0") -ine ($batchBefore.statePaths -join "`0")) { throw 'Known-folder guard paths differ between controller and worker.' }
        function Assert-BatchUntouched {
            Assert-WindowsHarnessHistoryGuard -Guard $workerRealGuard
            Assert-WindowsHarnessHistoryGuard -Guard $workerStateGuard
            if ([HistoryGuardNative]::GetClipboardSequenceNumber() -ne $batchBefore.clipboardSequence) { throw 'Clipboard sequence changed; stop launches and report.' }
        }
        Assert-BatchUntouched
        $results = @()
        foreach ($mutation in @('absent', 'creation', 'deletion', 'mtime-only')) {
            $path = Join-Path $RunDirectory "$mutation.txt"
            if ($mutation -in @('deletion', 'mtime-only')) { [IO.File]::WriteAllText($path, 'scratch') }
            $guard = Start-WindowsHarnessHistoryGuard -Harness "harness-history-guard/$mutation" -Paths @($path)
            switch ($mutation) {
                'creation' { [IO.File]::WriteAllText($path, 'scratch') }
                # Preserve the original bytes as an artifact while removing the
                # guarded pathname; nothing is deleted from the evidence tree.
                'deletion' { Move-Item -LiteralPath $path -Destination "$path.preserved" }
                'mtime-only' { [IO.File]::SetLastWriteTimeUtc($path, [IO.File]::GetLastWriteTimeUtc($path).AddSeconds(10)) }
            }
            if ($mutation -eq 'absent') { Assert-WindowsHarnessHistoryGuard -Guard $guard; $message = 'pass' }
            else { $message = Assert-ExpectedFailure $guard $mutation }
            $results += [pscustomobject]@{ case = $mutation; before = $guard.Before; after = (Get-WindowsHarnessHistoryMetadata $path); result = $message }
        }
        Save-Receipt 'mutations.json' $results
        $hosts = @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
        $driverHost = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([IO.Path]::GetFileName($driverHost) -ine 'pwsh.exe' -or $PSVersionTable.PSVersion.Major -ne 7) { throw 'Controller must be PowerShell 7.' }
        $hosts += $driverHost
        foreach ($shell in $hosts) {
            if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) { throw 'Required Windows PowerShell missing.' }
            $hostName = [IO.Path]::GetFileNameWithoutExtension($shell)
            foreach ($style in @('SaveIncrementally', 'SaveNothing')) {
                Assert-BatchUntouched
                $caseName = "$hostName-$style"
                $caseDir = Join-Path $RunDirectory $caseName
                [void][IO.Directory]::CreateDirectory($caseDir)
                $historyPath = Join-Path $caseDir 'scratch-history.txt'
                # Seed both identically; SaveNothing must leave this file intact.
                [IO.File]::WriteAllText($historyPath, "# scratch seed`n")
                $guard = Start-WindowsHarnessHistoryGuard -Harness "harness-history-guard/$caseName" -Paths @($historyPath)
                $childPid = [HistoryGuardNative]::Run($shell, $Desktop, $caseDir, $historyPath, $style, (Join-Path $caseDir 'executed.txt'), $OwnedJobName)
                Assert-BatchUntouched
                $after = Get-WindowsHarnessHistoryMetadata $historyPath
                if ($style -eq 'SaveIncrementally') {
                    if ((Get-Item -LiteralPath $historyPath).Length -le 15) { throw "$caseName did not grow scratch history." }
                    $result = Assert-ExpectedFailure $guard $caseName
                }
                else { Assert-WindowsHarnessHistoryGuard -Guard $guard; $result = 'pass' }
                Save-Receipt "$caseName.json" ([pscustomobject]@{ case = $caseName; pid = $childPid; before = $guard.Before; after = $after; result = $result; interactiveReceipt = (Test-Path -LiteralPath (Join-Path $caseDir 'executed.txt')); explicitDesktop = $Desktop; verifiedOwnedJob = $OwnedJobName })
            }
        }
        Save-Receipt 'worker-result.json' @{ passed = $true; hosts = $hosts.Count; interactiveCases = $hosts.Count * 2 }
        exit 0
    }
    catch {
        # Only fixture-authored errors, no child transcript/environment dumps.
        Save-Receipt 'worker-result.json' @{ passed = $false; error = $_.Exception.Message }
        exit 1
    }
}

$RunDirectory = Join-Path $repo ('.sandbox/history-guard-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($RunDirectory)
$Desktop = 'WinSta0\history-guard-' + [guid]::NewGuid().ToString('N')
$OwnedJobName = 'Local\history-guard-' + [guid]::NewGuid().ToString('N')
$realGuard = Start-WindowsHarnessHistoryGuard -Harness 'harness-history-guard'
$protectedPaths = Get-ProtectedStatePaths
$stateGuard = Start-WindowsHarnessHistoryGuard -Harness 'harness-history-guard/state' -Paths $protectedPaths
$before = @{ utc = [DateTime]::UtcNow.ToString('o'); clipboardSequence = [HistoryGuardNative]::GetClipboardSequenceNumber(); history = $realGuard.Before; startupAndJumpList = $stateGuard.Before; historyPaths = $realGuard.Paths; statePaths = $stateGuard.Paths }
Save-Receipt 'before.json' $before
$desktopHandle = [IntPtr]::Zero; $job = [IntPtr]::Zero
$failures = [Collections.Generic.List[string]]::new(); $exitCode = -1; $cleanupPids = @(); $jobEmpty = $false
try {
    $desktopHandle = [HiddenDesktopNative]::CreateDesktopW(($Desktop -split '\\')[1], [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
    if ($desktopHandle -eq [IntPtr]::Zero) { throw 'Private desktop creation failed.' }
    $job = [HistoryGuardNative]::CreateOwnedJob($OwnedJobName)
    if ($job -eq [IntPtr]::Zero) { throw 'Owned job creation failed.' }
    $driver = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileName($driver) -ine 'pwsh.exe' -or $PSVersionTable.PSVersion.Major -ne 7) { throw 'Controller must be PowerShell 7.' }
    $quote = { param($text) "'" + $text.Replace("'", "''") + "'" }
    $driverModule = Join-Path (Split-Path $driver) 'Modules/PSReadLine/PSReadLine.psd1'
    $script = '$ErrorActionPreference=''Stop''; Import-Module ' + (& $quote $driverModule) + ' -Global; Set-PSReadLineOption -HistorySaveStyle SaveNothing -HistorySavePath ' + (& $quote (Join-Path $RunDirectory 'driver-history.txt')) + '; & ' + (& $quote $PSCommandPath) + ' -Worker -RunDirectory ' + (& $quote $RunDirectory) + ' -Desktop ' + (& $quote $Desktop) + ' -OwnedJobName ' + (& $quote $OwnedJobName)
    $command = '"' + $driver + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $driverEnvironment = @{}
    foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP')) {
        $directory = Join-Path $RunDirectory $name
        [void][IO.Directory]::CreateDirectory($directory)
        $driverEnvironment[$name] = $directory
    }
    $driverEnvironment['PSModuleAnalysisCachePath'] = Join-Path $RunDirectory 'module-analysis-cache'
    $driverEnvironment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
    $driverEnvironment['POWERSHELL_UPDATECHECK'] = 'Off'
    $exitCode = Start-Hidden -Application $driver -Command $command -Directory $repo -Desktop $Desktop -OwnerJob $job -LogPath (Join-Path $RunDirectory 'driver.log') -EnvironmentOverrides $driverEnvironment
    $workerResultPath = Join-Path $RunDirectory 'worker-result.json'
    if (-not (Test-Path -LiteralPath $workerResultPath -PathType Leaf)) { throw "Acceptance driver produced no completion receipt (exit $exitCode)." }
    $workerResult = Get-Content -LiteralPath $workerResultPath -Raw | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $workerResult.passed) { throw "Acceptance driver failed (exit $exitCode): $($workerResult.error)" }
    if ($workerResult.hosts -ne 2 -or $workerResult.interactiveCases -ne 4) { throw 'Acceptance driver did not complete both hosts and all four interactive cases.' }
}
catch { $failures.Add($_.Exception.Message) }
finally {
    try {
        if ($job -ne [IntPtr]::Zero) {
            $cleanupPids = @([HiddenDesktopNative]::ReapOwnedJob($job))
            if ($cleanupPids.Count) { $failures.Add('Acceptance driver left processes requiring owned-job termination.') }
            $jobEmpty = [HiddenDesktopNative]::JobPids($job).Count -eq 0
            if (-not $jobEmpty) { throw 'Owned job still has processes.' }
        }
    }
    catch { $failures.Add('Owned-job cleanup failed: ' + $_.Exception.Message) }
    finally {
        if ($job -ne [IntPtr]::Zero) { [void][HiddenDesktopNative]::CloseHandle($job) }
        if ($desktopHandle -ne [IntPtr]::Zero) { [void][HiddenDesktopNative]::CloseDesktop($desktopHandle) }
    }
    $after = @{ utc = [DateTime]::UtcNow.ToString('o'); clipboardSequence = [HistoryGuardNative]::GetClipboardSequenceNumber(); history = @(); startupAndJumpList = @(); cleanupPids = $cleanupPids; jobEmpty = $jobEmpty }
    foreach ($section in @(@{ name = 'history'; paths = $realGuard.Paths }, @{ name = 'startupAndJumpList'; paths = $stateGuard.Paths })) {
        foreach ($path in $section.paths) {
            try { $after[$section.name] += Get-WindowsHarnessHistoryMetadata $path }
            catch { $after[$section.name] += 'unavailable'; $failures.Add("Metadata receipt failed for $($section.name): $($_.Exception.Message)") }
        }
    }
    Save-Receipt 'after.json' $after
    foreach ($guard in @($realGuard, $stateGuard)) {
        try { Assert-WindowsHarnessHistoryGuard -Guard $guard }
        catch { $failures.Add($_.Exception.Message) }
    }
    if ($before.clipboardSequence -ne $after.clipboardSequence) { $failures.Add("Clipboard sequence changed ($($before.clipboardSequence) -> $($after.clipboardSequence)); stop launches and report. Attribution is unknown.") }
}
Save-Receipt 'result.json' @{ passed = ($failures.Count -eq 0); errors = @($failures.ToArray()); driverExitCode = $exitCode; artifacts = $RunDirectory }
Write-Host "Artifacts: $RunDirectory"
Write-Host "Clipboard sequence: $($before.clipboardSequence) -> $($after.clipboardSequence)"
if ($failures.Count) { throw ($failures -join ' ') }
Write-Host 'PASS: scratch mutation controls and hidden-desktop PSReadLine history controls.'
