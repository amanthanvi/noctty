#requires -Version 7.3
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'release-publish-chocolatey.ps1'
try {


# Runs scripts/release-publish-chocolatey.ps1 in child processes against a fake
# `choco` (first on PATH, logs every call) and a loopback stand-in for the
# community feed, so the dry run, the skip rule, the resubmission switch and
# the 403 and 409 handling are exercised without a package or a real API key.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$publisher = Join-Path $repoRoot 'scripts\release-publish-chocolatey.ps1'
$version = '9.8.7'
$fakeKey = 'test-key-not-a-secret'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('release-publish-chocolatey-' + [guid]::NewGuid().ToString('N'))
$binDirectory = Join-Path $root 'bin'
$stateDirectory = Join-Path $root 'feed'
$runnerTemp = Join-Path $root 'runner-temp'
$artifactRoot = Join-Path $root 'artifacts'
$callLog = Join-Path $root 'choco-calls.txt'
$packageDirectory = Join-Path $artifactRoot "koreterm-$version-windows-x64\package-managers\chocolatey"
$listener = $null
$feedJob = $null

try {
    foreach ($directory in @($binDirectory, $stateDirectory, $runnerTemp, $packageDirectory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $nuspecPath = Join-Path $packageDirectory 'koreterm.nuspec'
    Set-Content -LiteralPath $nuspecPath -Value '<package />'
    $metadata = [ordered]@{
        chocolatey = [ordered]@{
            packageName      = 'koreterm'
            nuspecPath       = $nuspecPath
            packageDirectory = $packageDirectory
        }
    }
    Set-Content -LiteralPath (Join-Path $artifactRoot "koreterm-$version-windows-x64\package-managers\metadata.json") -Value ($metadata | ConvertTo-Json -Depth 4)

    # The fake choco: `pack` writes a package where --output-directory says,
    # `push` behaves as FAKE_CHOCO_PUSH says.
    Set-Content -LiteralPath (Join-Path $binDirectory 'choco.ps1') -Value @'
Add-Content -LiteralPath $env:FAKE_CHOCO_LOG -Value ((@($args) -join ' ') + ' | key-in-env=' + [bool]$env:CHOCO_API_KEY)
switch ($args[0]) {
    'pack' {
        $output = $args[[array]::IndexOf($args, '--output-directory') + 1]
        Set-Content -LiteralPath (Join-Path $output 'koreterm.9.8.7.nupkg') -Value 'fake package'
        exit 0
    }
    'push' {
        switch ($env:FAKE_CHOCO_PUSH) {
            'ok' { exit 0 }
            'refused403' { Write-Output 'The remote server returned an error: (403) Forbidden.'; exit 1 }
            'conflict-then-listed' {
                New-Item -ItemType File -Path (Join-Path $env:FAKE_FEED_STATE 'listed-9.8.7') -Force | Out-Null
                Write-Output 'The remote server returned an error: (409) Conflict.'
                exit 1
            }
        }
    }
}
exit 2
'@

    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $tcp.Stop()
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $feedJob = Start-ThreadJob -ArgumentList $listener, $stateDirectory -ScriptBlock {
        param($listener, $stateDirectory)
        while ($listener.IsListening) {
            try { $context = $listener.GetContext() } catch { break }
            $requested = [regex]::Match($context.Request.RawUrl, "Version='([0-9.]+)'")
            $listed = $requested.Success -and (Test-Path -LiteralPath (Join-Path $stateDirectory ('listed-' + $requested.Groups[1].Value)))
            $context.Response.StatusCode = if ($listed) { 200 } else { 404 }
            $context.Response.Close()
        }
    }
    $querySource = "http://127.0.0.1:$port/api/v2/"
    $listedMarker = Join-Path $stateDirectory "listed-$version"

    function Invoke-Publisher {
        param(
            [string[]] $Switches = @(),
            [bool] $Listed = $false,
            [string] $PushMode = 'ok',
            [bool] $WithKey = $false
        )

        Remove-Item -LiteralPath $callLog, $listedMarker -Force -ErrorAction Ignore
        Remove-Item -LiteralPath (Join-Path $runnerTemp "koreterm-chocolatey-$version") -Recurse -Force -ErrorAction Ignore
        if ($Listed) { New-Item -ItemType File -Path $listedMarker | Out-Null }
        $saved = @{ PATH = $env:PATH; CHOCO_API_KEY = $env:CHOCO_API_KEY }
        try {
            $env:PATH = $binDirectory + [System.IO.Path]::PathSeparator + $env:PATH
            $env:FAKE_CHOCO_LOG = $callLog
            $env:FAKE_FEED_STATE = $stateDirectory
            $env:FAKE_CHOCO_PUSH = $PushMode
            if ($WithKey) { $env:CHOCO_API_KEY = $fakeKey } else { Remove-Item Env:CHOCO_API_KEY -ErrorAction Ignore }
            $output = (& pwsh -NoProfile -File $publisher `
                    -Version $version `
                    -ArtifactRoot $artifactRoot `
                    -RunnerTemp $runnerTemp `
                    -PushSource 'https://push.invalid/' `
                    -QuerySource $querySource @Switches 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $env:PATH = $saved.PATH
            if ($null -eq $saved.CHOCO_API_KEY) { Remove-Item Env:CHOCO_API_KEY -ErrorAction Ignore } else { $env:CHOCO_API_KEY = $saved.CHOCO_API_KEY }
            Remove-Item Env:FAKE_CHOCO_LOG, Env:FAKE_FEED_STATE, Env:FAKE_CHOCO_PUSH -ErrorAction Ignore
        }
        $calls = if (Test-Path -LiteralPath $callLog) { @(Get-Content -LiteralPath $callLog) } else { @() }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $output
            Packs    = @($calls | Where-Object { $_ -like 'pack *' })
            Pushes   = @($calls | Where-Object { $_ -like 'push *' })
        }
    }

    function Assert-Case {
        param([string] $Name, [bool] $Condition, [pscustomobject] $Result)
        if (-not $Condition) {
            throw "release-publish-chocolatey.ps1: $Name`n--- exit $($Result.ExitCode), packs $($Result.Packs.Count), pushes $($Result.Pushes.Count)`n$($Result.Output)"
        }
    }

    # A dry run packs, needs no key and never pushes.
    $result = Invoke-Publisher -Switches '-PackOnly'
    Assert-Case 'a dry run packs once and pushes nothing, without a key' ($result.ExitCode -eq 0 -and $result.Packs.Count -eq 1 -and $result.Pushes.Count -eq 0 -and $result.Output -match '-PackOnly stops here') $result
    # Even a key in the environment is not used by a dry run.
    $result = Invoke-Publisher -Switches '-PackOnly' -WithKey $true
    Assert-Case 'a dry run with a key still pushes nothing' ($result.ExitCode -eq 0 -and $result.Pushes.Count -eq 0 -and $result.Output -notmatch [regex]::Escape($fakeKey)) $result
    # A listed version is reported by the dry run, which still packs.
    $result = Invoke-Publisher -Switches '-PackOnly' -Listed $true
    Assert-Case 'a dry run reports a listed version and still packs' ($result.ExitCode -eq 0 -and $result.Packs.Count -eq 1 -and $result.Pushes.Count -eq 0 -and $result.Output -match 'nothing to push') $result

    # Without a key a real run skips before it touches choco.
    $result = Invoke-Publisher
    Assert-Case 'a real run without a key skips' ($result.ExitCode -eq 0 -and $result.Packs.Count -eq 0 -and $result.Output -match 'CHOCO_API_KEY is not configured') $result

    # A real run packs without the key in the packing process's environment,
    # then pushes with it, and never prints it.
    $result = Invoke-Publisher -WithKey $true
    Assert-Case 'a real run packs without the key, then pushes with it' ($result.ExitCode -eq 0 -and $result.Packs.Count -eq 1 -and $result.Pushes.Count -eq 1 -and
        $result.Packs[0] -match 'key-in-env=False' -and $result.Pushes[0] -match 'key-in-env=True' -and
        $result.Pushes[0] -match '--source https://push\.invalid/' -and $result.Pushes[0] -match ('--api-key ' + [regex]::Escape($fakeKey)) -and
        $result.Output -notmatch [regex]::Escape($fakeKey)) $result

    # The rerun-safe rule: a listed version is skipped before choco is called.
    $result = Invoke-Publisher -WithKey $true -Listed $true
    Assert-Case 'a listed version is skipped' ($result.ExitCode -eq 0 -and $result.Packs.Count -eq 0 -and $result.Pushes.Count -eq 0 -and $result.Output -match 'nothing to push') $result

    # -Resubmit pushes a listed version (one still in moderation).
    $result = Invoke-Publisher -Switches '-Resubmit' -WithKey $true -Listed $true
    Assert-Case '-Resubmit pushes a listed version' ($result.ExitCode -eq 0 -and $result.Packs.Count -eq 1 -and $result.Pushes.Count -eq 1 -and $result.Output -match 'Resubmit pushes it again') $result

    # A refused push fails the run with the 403 explanation.
    $result = Invoke-Publisher -WithKey $true -PushMode 'refused403'
    Assert-Case 'a 403 fails the run and explains it' ($result.ExitCode -ne 0 -and $result.Output -match 'refused with 403') $result

    # A failed push counts as complete only when the feed then holds the version.
    $result = Invoke-Publisher -WithKey $true -PushMode 'conflict-then-listed'
    Assert-Case 'a 409 is complete once the feed holds the version' ($result.ExitCode -eq 0 -and $result.Output -match 'treating the push as complete') $result

    # ...and never when the run is a resubmission, because a listed version
    # proves nothing about the bytes the feed holds.
    $result = Invoke-Publisher -Switches '-Resubmit' -WithKey $true -Listed $true -PushMode 'refused403'
    Assert-Case 'a failed resubmission is a failure' ($result.ExitCode -ne 0 -and $result.Output -notmatch 'treating the push as complete') $result

    Write-Host 'release-publish-chocolatey.ps1 behaviour: PASS (10 cases)'
    # The last case ends on a failing child; GitHub's pwsh wrapper exits with
    # the last native exit code.
    $global:LASTEXITCODE = 0
}
finally {
    if ($null -ne $listener) { $listener.Close() }
    if ($null -ne $feedJob) { Remove-Job -Job $feedJob -Force -ErrorAction Ignore }
    if ((Test-Path -LiteralPath $root) -and
        [System.IO.Path]::GetFullPath($root).StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $root) -like 'release-publish-chocolatey-*') {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Ignore
    }
}

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
