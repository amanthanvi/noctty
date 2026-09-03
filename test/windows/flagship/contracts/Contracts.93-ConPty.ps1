# Bundled ConPTY redistributable contracts (issue #129).
$windowsPackageBuilder = Join-Path $repoRoot 'scripts\build-package-windows.ps1'
$conptyRedistHelper = Join-Path $repoRoot 'scripts\conpty-redist.ps1'
$conptyRedistPin = Join-Path $repoRoot 'dist\windows\conpty-redist.json'
$conptyRuntime = Join-Path $repoRoot 'src\pty.zig'
$diagnosticBundle = Join-Path $repoRoot 'src\cli\diagnostic_bundle.zig'
$conptyRedistHelperText = Get-Content -LiteralPath $conptyRedistHelper -Raw

Assert-WorkflowContract `
    -Path $windowsPackager `
    -Pattern '(?ms)\. \(Join-Path \$PSScriptRoot "conpty-redist\.ps1"\).*?foreach \(\$runtimeFile in \$runtimeFiles\).*?Invoke-SignFile.*?Install-ConPtyRedist.*?-PinPath \$conptyPinPath.*?-Architecture \$Architecture.*?-Destination \$portableRoot.*?-CacheRoot \$conptyCacheRoot.*?-RequireConPty:\$RequireConPty.*?if \(\$conptyStaged\) \{.*?Copy-Item.*?LICENSE-conpty\.txt.*?\}' `
    -Description 'Windows packaging stages pinned ConPTY after the noctty-only signing loop and includes its license only with the pair'
Assert-WorkflowContract `
    -Path $windowsPackageBuilder `
    -Pattern '(?ms)\[switch\]\$RequireConPty.*?if \(\$RequireConPty\) \{\s*\$packageArgs\.RequireConPty = \$true\s*\}.*?package-windows\.ps1.*?@packageArgs' `
    -Description 'Windows build-package wrapper forwards required ConPTY mode to the packager'
Assert-WorkflowContractAbsent `
    -Path $conptyRedistHelper `
    -Pattern 'Invoke-SignFile|signtool|Set-AuthenticodeSignature' `
    -Description 'Microsoft ConPTY binaries remain outside noctty signing'
Assert-WorkflowContract `
    -Path $conptyRedistHelper `
    -Pattern '(?ms)Invoke-WebRequest.*?catch \{.*?if \(\$RequireConPty\).*?Write-Warning.*?return \$false.*?Assert-ConPtySha256 -Path \$downloadPath.*?Move-Item.*?Assert-ConPtySha256 -Path \$packagePath' `
    -Description 'ConPTY downloads fail optionally only at the network boundary and every archive is hash-checked'
Assert-WorkflowContract `
    -Path $conptyRedistHelper `
    -Pattern '(?ms)Expand-ConPtyEntry.*?conptyDll\.entryPath.*?Expand-ConPtyEntry.*?openConsoleExe\.entryPath.*?Assert-ConPtySha256.*?conptyDll\.sha256.*?Assert-ConPtySha256.*?openConsoleExe\.sha256.*?Assert-PeMachine.*?temporaryConPty.*?Assert-PeMachine.*?temporaryOpenConsole.*?Copy-Item.*?temporaryConPty.*?Copy-Item.*?temporaryOpenConsole' `
    -Description 'ConPTY staging verifies both pinned files and both PE machines before committing the pair'
Assert-WorkflowContract `
    -Path $conptyRedistHelper `
    -Pattern '(?ms)\$entryStream = \$entry\.Open\(\).*?\$entryStream\.CopyTo\(\$output\).*?\$entryStream\.Dispose\(\)' `
    -Description 'ConPTY ZIP extraction does not shadow the PowerShell input automatic variable'
Assert-WorkflowContract `
    -Path $conptyRuntime `
    -Pattern '(?ms)fn forceInbox\(\) bool.*?NOCTTY_CONPTY.*?return std\.ascii\.eqlIgnoreCase\(value, "inbox"\).*?LoadLibraryExW.*?OpenConsole\.exe.*?openConsoleMatchesArchitecture.*?return error\.OpenConsoleWrongArch' `
    -Description 'ConPTY selection only forces inbox explicitly and rejects a missing or wrong-architecture companion executable'
Assert-WorkflowContract `
    -Path $conptyRuntime `
    -Pattern 'error\.OpenConsoleWrongArch => "bundled OpenConsole\.exe has the wrong architecture"' `
    -Description 'ConPTY fallback names a wrong-architecture OpenConsole companion concretely'
Assert-WorkflowContract `
    -Path $conptyRuntime `
    -Pattern '(?ms)var selected = std\.atomic\.Value\(\*const Functions\)\.init\(&inbox_functions\).*?selected\.cmpxchgStrong\(.*?pty\.control = \.\{ \.pseudo_console = \.\{.*?\.conpty = conpty,' `
    -Description 'ConPTY selection is one atomic pointer and each PTY captures its creating implementation'
Assert-WorkflowContract `
    -Path $conptyRuntime `
    -Pattern '(?ms)\.pseudo_console => \|pc\| \{\s*pc\.conpty\.close\(pc\.handle\);.*?WindowsConPty\.releaseBundledHpcon\(\).*?pc\.conpty\.resize\(\s*pc\.handle,' `
    -Description 'an HPCON is only ever closed or resized by the implementation that created it'
Assert-WorkflowContract `
    -Path $diagnosticBundle `
    -Pattern '(?ms)conpty: \?pty\.ConPtyInfo.*?\.conpty = pty\.conPtyInfo\(\)' `
    -Description 'diagnostic bundles reuse the ConPTY resolver fact without a duplicate manifest type or probe'
Assert-WorkflowContractAbsent `
    -Path $diagnosticBundle `
    -Pattern 'const ConPty = struct|fn conPtyManifest' `
    -Description 'diagnostic bundles do not duplicate the ConPTY info shape'
Assert-WorkflowContract `
    -Path $releaseDefenderScanner `
    -Pattern '(?ms)\$portablePayloads = @\(Get-WindowsSignedRuntimePayloads\) \+ @\(\s*''noctty/conpty\.dll'',\s*''noctty/OpenConsole\.exe''\s*\).*?\$expectedScanCount = \$architectures\.Count \* \(1 \+ \$portablePayloads\.Count\)' `
    -Description 'release Defender scan covers the bundled ConPTY pair in every architecture'
Assert-WorkflowContract `
    -Path $releaseArtifactVerifier `
    -Pattern '(?ms)dist/windows/conpty-redist\.json.*?conptyDll.*?openConsoleExe.*?Get-FileHash -Algorithm SHA256.*?pinned ConPTY SHA-256.*?X509NameType\]::SimpleName.*?Microsoft Corporation' `
    -Description 'release rechecks pinned ConPTY payload hashes and requires a Microsoft Authenticode signer'

$conptyRedistHelperTokens = $null
$conptyRedistHelperErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $conptyRedistHelperText,
    [ref]$conptyRedistHelperTokens,
    [ref]$conptyRedistHelperErrors
)
if ($conptyRedistHelperErrors.Count -ne 0) {
    throw "ConPTY redistributable helper does not parse: $($conptyRedistHelperErrors[0].Message)"
}
$conptyRedistHelperSha256 =
    '365826625d6969feaa0f6a292825a8655057e191407e8ef72d1434805bac68b2'
if ((Get-CanonicalTextSha256 -Text $conptyRedistHelperText) -cne $conptyRedistHelperSha256) {
    throw 'ConPTY redistributable helper changed without a contract review.'
}

$conptyPin = Get-Content -LiteralPath $conptyRedistPin -Raw | ConvertFrom-Json
$conptyPinRootFields = @('schemaVersion', 'packageId', 'version', 'license', 'projectUrl', 'nupkg', 'architectures')
if (@(Compare-Object $conptyPinRootFields @($conptyPin.PSObject.Properties.Name) -SyncWindow 0).Count -ne 0 -or
    $conptyPin.schemaVersion -ne 1 -or
    $conptyPin.packageId -cne 'Microsoft.Windows.Console.ConPTY' -or
    $conptyPin.version -cne '1.24.260710001' -or
    $conptyPin.license -cne 'MIT' -or
    $conptyPin.projectUrl -cne 'https://github.com/microsoft/terminal' -or
    $conptyPin.nupkg.url -cne 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/1.24.260710001/microsoft.windows.console.conpty.1.24.260710001.nupkg' -or
    $conptyPin.nupkg.sha256 -cne '175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e' -or
    @(Compare-Object @('x64', 'arm64') @($conptyPin.architectures.PSObject.Properties.Name) -SyncWindow 0).Count -ne 0) {
    throw 'ConPTY redistributable package identity, version, license, URL, archive hash, or architectures drifted.'
}
$conptyPinEntries = @(
    @{ Architecture = 'x64'; Field = 'conptyDll'; Path = 'runtimes/win-x64/native/conpty.dll'; Sha256 = '39fba2713e2495117b1591ae8c32a3b904bea7aa66069cf7815e2844c76d75d8' },
    @{ Architecture = 'x64'; Field = 'openConsoleExe'; Path = 'build/native/runtimes/x64/OpenConsole.exe'; Sha256 = 'b7fd936c2668b87b9ecf7b3366dc6568afc1c6f981874cba3e955a1c35cf8160' },
    @{ Architecture = 'arm64'; Field = 'conptyDll'; Path = 'runtimes/win-arm64/native/conpty.dll'; Sha256 = 'db3d173640b172bafd42d5b541b638a9aeec1c7d0e40dd636bf02822a32c912c' },
    @{ Architecture = 'arm64'; Field = 'openConsoleExe'; Path = 'build/native/runtimes/arm64/OpenConsole.exe'; Sha256 = 'ed7622fd0d3bedc9ab9f122f5e58edf0def9e7999224f52dd395ba9f54edbe09' }
)
foreach ($expected in $conptyPinEntries) {
    $actual = $conptyPin.architectures.PSObject.Properties[$expected.Architecture].Value.PSObject.Properties[$expected.Field].Value
    if (@(Compare-Object @('entryPath', 'sha256') @($actual.PSObject.Properties.Name) -SyncWindow 0).Count -ne 0 -or
        $actual.entryPath -cne $expected.Path -or
        $actual.sha256 -cne $expected.Sha256 -or
        $actual.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "ConPTY redistributable entry drifted: $($expected.Architecture) $($expected.Field)"
    }
}

foreach ($packageStepSpec in @(
    @{ Name = 'Build and package x64 release artifacts'; Architecture = 'x64' },
    @{ Name = 'Build and package ARM64 release artifacts'; Architecture = 'arm64' }
)) {
    $packageStep = Get-YamlStepBlock -Content $releaseWorkflowText -Name $packageStepSpec.Name -Source $releaseWorkflow
    if (([regex]::Matches($packageStep, '(?m)^\s*-RequireConPty\s*$')).Count -ne 1 -or
        $packageStep -notmatch "(?ms)build-package-windows\.ps1.*?-Architecture $($packageStepSpec.Architecture).*?-RequireInstaller.*?-RequireSigning.*?-RequireConPty") {
        throw "$($packageStepSpec.Name) must require bundled ConPTY exactly once."
    }
}

# --- Shared signed-runtime-payload list (issue #129 / #130) ----------------
# Every PE noctty signs must be re-verified and Defender-scanned at release.
# A single list feeds all three gates so a newly shipped binary cannot be
# covered by one and silently missed by the others.
$releaseCommonScript = Join-Path $repoRoot 'scripts\common.ps1'
$publishedReleaseVerifierScript = Join-Path $repoRoot 'scripts\verify-published-release.ps1'
Assert-WorkflowContract `
    -Path $releaseCommonScript `
    -Pattern "(?ms)function Get-WindowsSignedRuntimePayloads.*?noctty/noctty\.com.*?noctty/noctty\.exe.*?noctty/ghostty-vt\.dll.*?noctty/noctty-terminal-handoff-proxy\.dll" `
    -Description 'the shared signed-runtime payload list covers every PE noctty ships and signs'
foreach ($payloadConsumer in @(
    $releaseArtifactVerifier,
    $publishedReleaseVerifierScript,
    $releaseDefenderScanner
)) {
    Assert-WorkflowContract `
        -Path $payloadConsumer `
        -Pattern 'Get-WindowsSignedRuntimePayloads' `
        -Description "release gate $(Split-Path -Leaf $payloadConsumer) derives its payload set from the shared signed-runtime list"
    Assert-WorkflowContractAbsent `
        -Path $payloadConsumer `
        -Pattern "'noctty/ghostty-vt\.dll'" `
        -Description "release gate $(Split-Path -Leaf $payloadConsumer) does not hardcode a parallel payload list"
}
Assert-WorkflowContract `
    -Path $publishedReleaseVerifierScript `
    -Pattern '(?ms)\$expectedSignatureCount =\s*@\(Get-WindowsPackageArchitectures\)\.Count \*\s*\(\$signedAssetsPerArchitecture \+ @\(Get-WindowsSignedRuntimePayloads\)\.Count\)' `
    -Description 'published-release signature evidence count is derived, not a hardcoded literal'
# The shared payload list cannot cover the Microsoft pair, so the published
# verifier needs its own check or the pinned-hash chain stops at publication.
Assert-WorkflowContract `
    -Path $publishedReleaseVerifierScript `
    -Pattern '(?ms)dist/windows/conpty-redist\.json.*?conptyDll.*?openConsoleExe.*?is missing bundled ConPTY payload.*?Get-FileHash -Algorithm SHA256.*?pinned ConPTY SHA-256.*?X509NameType\]::SimpleName.*?Microsoft Corporation' `
    -Description 'published-release verification rechecks the bundled ConPTY pair against its pinned hashes and Microsoft signer'
