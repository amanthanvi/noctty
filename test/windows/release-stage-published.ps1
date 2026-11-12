#requires -Version 7.3
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'release-stage-published.ps1'
try {


# Runs a copy of scripts/release-stage-published.ps1 next to stand-ins for the
# scripts and tools it calls (the release verifier, the package generator and
# `gh`), to show what the real one guarantees: nothing is staged or packaged
# unless the release verifies, the installers' attestations are tied to the
# release tag's commit, and the verified files are the ones the generator gets.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$version = '9.8.7'
$tagCommit = '0123456789abcdef0123456789abcdef01234567'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('release-stage-published-' + [guid]::NewGuid().ToString('N'))
$scriptsDirectory = Join-Path $root 'scripts'
$binDirectory = Join-Path $root 'bin'
$downloadDirectory = Join-Path $root 'download'
$scratchTemp = Join-Path $root 'temp'
$ghLog = Join-Path $root 'gh-calls.txt'
$packageLog = Join-Path $root 'package-calls.txt'
$stager = Join-Path $scriptsDirectory 'release-stage-published.ps1'

try {
    foreach ($directory in @($scriptsDirectory, $binDirectory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    foreach ($name in @('common.ps1', 'windows-architecture.ps1', 'release-stage-published.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot "scripts\$name") -Destination (Join-Path $scriptsDirectory $name)
    }
    . (Join-Path $scriptsDirectory 'windows-architecture.ps1')

    # Stand-in verifier: fails, or "downloads" the release.
    Set-Content -LiteralPath (Join-Path $scriptsDirectory 'verify-published-release.ps1') -Value @'
param([string] $Version, [string] $DownloadDirectory)
if ($env:FAKE_VERIFY -eq 'fail') { throw 'release verification failed' }
New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
if ($env:FAKE_VERIFY -eq 'fail-after-download') {
    Set-Content -LiteralPath (Join-Path $DownloadDirectory 'partial') -Value 'x'
    throw 'release verification failed after the download'
}
foreach ($arch in 'x64', 'arm64') {
    foreach ($kind in 'setup.exe', 'portable.zip') {
        Set-Content -LiteralPath (Join-Path $DownloadDirectory "koreterm-$Version-windows-$arch-$kind") -Value "$arch $kind"
    }
    Set-Content -LiteralPath (Join-Path $DownloadDirectory "SHA256SUMS-windows-$arch.txt") -Value "sums $arch"
}
Set-Content -LiteralPath (Join-Path $DownloadDirectory 'koreterm-icon.svg') -Value '<svg />'
'@
    # Stand-in generator: records how it was called.
    Set-Content -LiteralPath (Join-Path $scriptsDirectory 'package-package-managers.ps1') -Value @'
param([string] $Version, [string[]] $Architectures, [string] $PackageSourceRef)
Add-Content -LiteralPath $env:FAKE_PACKAGE_LOG -Value "$Version|$($Architectures -join ',')|$PackageSourceRef"
'@
    # Stand-in gh: resolves the tag commit and verifies (or refuses) attestations.
    Set-Content -LiteralPath (Join-Path $binDirectory 'gh.ps1') -Value @'
Add-Content -LiteralPath $env:FAKE_GH_LOG -Value (@($args) -join ' ')
if ($args[0] -eq 'api') { Write-Output $env:FAKE_TAG_COMMIT; exit 0 }
if ($args[0] -eq 'attestation') { exit $(if ($env:FAKE_ATTEST -eq 'fail') { 1 } else { 0 }) }
exit 2
'@

    function Invoke-Stager {
        param([string] $Verify = 'ok', [string] $Attest = 'ok', [string] $SourceRef = '', [switch] $ChooseDownloadDirectory)

        Remove-Item -LiteralPath $ghLog, $packageLog, $downloadDirectory, $scratchTemp, (Join-Path $root 'dist') -Recurse -Force -ErrorAction Ignore
        New-Item -ItemType Directory -Path $scratchTemp -Force | Out-Null
        $savedEnvironment = @{ PATH = $env:PATH; TEMP = $env:TEMP; TMP = $env:TMP }
        try {
            $env:PATH = $binDirectory + [System.IO.Path]::PathSeparator + $env:PATH
            # Where the stager's own temporary folder, if it picks one, would go.
            $env:TEMP = $scratchTemp
            $env:TMP = $scratchTemp
            $env:FAKE_VERIFY = $Verify
            $env:FAKE_ATTEST = $Attest
            $env:FAKE_GH_LOG = $ghLog
            $env:FAKE_PACKAGE_LOG = $packageLog
            $env:FAKE_TAG_COMMIT = $tagCommit
            $arguments = @('-NoProfile', '-File', $stager, '-Version', $version)
            if (-not $ChooseDownloadDirectory) { $arguments += @('-DownloadDirectory', $downloadDirectory) }
            if ($SourceRef) { $arguments += @('-PackageSourceRef', $SourceRef) }
            $output = (& pwsh @arguments 2>&1 | Out-String)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $env:PATH = $savedEnvironment.PATH
            $env:TEMP = $savedEnvironment.TEMP
            $env:TMP = $savedEnvironment.TMP
            Remove-Item Env:FAKE_VERIFY, Env:FAKE_ATTEST, Env:FAKE_GH_LOG, Env:FAKE_PACKAGE_LOG, Env:FAKE_TAG_COMMIT -ErrorAction Ignore
        }
        return [pscustomobject]@{
            ExitCode   = $exitCode
            Output     = $output
            GhCalls    = @(if (Test-Path -LiteralPath $ghLog) { Get-Content -LiteralPath $ghLog })
            Packages   = @(if (Test-Path -LiteralPath $packageLog) { Get-Content -LiteralPath $packageLog })
            Staged     = Test-Path -LiteralPath (Join-Path $root 'dist')
            Downloaded = Test-Path -LiteralPath $downloadDirectory
            Leftovers  = @(Get-ChildItem -LiteralPath $scratchTemp -Directory -Filter 'koreterm-chocolatey-release-*')
        }
    }

    function Assert-Case {
        param([string] $Name, [bool] $Condition, [pscustomobject] $Result)
        if (-not $Condition) {
            throw "release-stage-published.ps1: $Name`n--- exit $($Result.ExitCode), staged $($Result.Staged), gh calls $($Result.GhCalls.Count), packages $($Result.Packages.Count)`n$($Result.Output)"
        }
    }

    # A release that does not verify is neither staged nor packaged.
    $result = Invoke-Stager -Verify 'fail'
    Assert-Case 'a failed release verification stops everything' ($result.ExitCode -ne 0 -and -not $result.Staged -and $result.GhCalls.Count -eq 0 -and $result.Packages.Count -eq 0) $result

    # An installer not built from the tag's commit is neither staged nor packaged.
    $result = Invoke-Stager -Attest 'fail'
    Assert-Case 'an installer built from another commit stops everything' ($result.ExitCode -ne 0 -and -not $result.Staged -and $result.Packages.Count -eq 0) $result

    # Both installers are checked against the tag commit, then the verified files are staged.
    $result = Invoke-Stager -SourceRef 'abcdef0'
    $attestations = @($result.GhCalls | Where-Object { $_ -like 'attestation verify *' })
    Assert-Case 'both installers are verified against the tag commit' ($result.ExitCode -eq 0 -and $attestations.Count -eq 2 -and
        @($attestations | Where-Object { $_ -match ('--source-digest ' + $tagCommit + '$') -and $_ -match '--signer-workflow richardsonvix/noctty_terminal/\.github/workflows/release\.yml' }).Count -eq 2 -and
        ($attestations -join "`n") -match 'windows-x64-setup\.exe' -and ($attestations -join "`n") -match 'windows-arm64-setup\.exe') $result
    $stagedFiles = foreach ($architecture in @('x64', 'arm64')) {
        foreach ($kind in @('setup', 'portable', 'checksums')) {
            Join-Path $root ("dist\artifacts\koreterm-$version-windows-$architecture\" + (New-WindowsPackageArtifactName -Version $version -Architecture $architecture -Kind $kind))
        }
    }
    $stagedFiles += Join-Path $root "dist\artifacts\koreterm-$version-windows-x64\koreterm-icon.svg"
    Assert-Case 'the verified files are staged where the generator reads them' (@($stagedFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) $result
    Assert-Case 'the generator runs once for both architectures at the given source ref' ($result.Packages.Count -eq 1 -and $result.Packages[0] -ceq "$version|x64,arm64|abcdef0") $result
    Assert-Case 'each installer hash is printed for comparison' ($result.Output -match 'Installer x64 SHA-256: [0-9a-f]{64}' -and $result.Output -match 'Installer arm64 SHA-256: [0-9a-f]{64}') $result

    # Without a source ref the generator is not given one.
    $result = Invoke-Stager
    Assert-Case 'no source ref is passed unless one is given' ($result.ExitCode -eq 0 -and $result.Packages.Count -eq 1 -and $result.Packages[0] -ceq "$version|x64,arm64|") $result

    # A folder the caller supplies is the caller's to clean up.
    $result = Invoke-Stager
    Assert-Case 'a download folder supplied by the caller is kept' ($result.ExitCode -eq 0 -and $result.Downloaded -and $result.Leftovers.Count -eq 0) $result

    # A folder the script picked is removed after a success and after a failure.
    $result = Invoke-Stager -ChooseDownloadDirectory
    Assert-Case 'a temporary download folder is removed after a success' ($result.ExitCode -eq 0 -and $result.Staged -and $result.Packages.Count -eq 1 -and $result.Leftovers.Count -eq 0) $result
    $result = Invoke-Stager -ChooseDownloadDirectory -Verify 'fail-after-download'
    Assert-Case 'a temporary download folder is removed after a failure' ($result.ExitCode -ne 0 -and -not $result.Staged -and $result.Leftovers.Count -eq 0) $result

    Write-Host 'release-stage-published.ps1 behaviour: PASS (10 cases)'
    # GitHub's pwsh wrapper exits with the last native exit code.
    $global:LASTEXITCODE = 0
}
finally {
    if ((Test-Path -LiteralPath $root) -and
        [System.IO.Path]::GetFullPath($root).StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $root) -like 'release-stage-published-*') {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Ignore
    }
}

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
