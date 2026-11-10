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

# Source builds stage the same pinned pair (zig build -> src/build/ConptyRedist.zig
# -> scripts/stage-conpty-redist.ps1 -> Install-ConPtyRedist).
$conptyBuildStep = Join-Path $repoRoot 'src\build\ConptyRedist.zig'
$conptyStageScript = Join-Path $repoRoot 'scripts\stage-conpty-redist.ps1'
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'build.zig') `
    -Pattern '(?ms)if \(config\.target\.result\.os\.tag == \.windows\) \{[^}]*?if \(config\.bundled_conpty\) \{[^}]*?ConptyRedist\.install\(b, config\.target\);' `
    -Description 'every Windows source build installs the pinned bundled ConPTY beside the exe'
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'src\build\Config.zig') `
    -Pattern '(?ms)config\.bundled_conpty = b\.option\(\s*bool,\s*"bundled-conpty",.*?\) orelse true;' `
    -Description 'source builds stage the bundled ConPTY unless the builder opts out'
Assert-WorkflowContract `
    -Path $conptyBuildStep `
    -Pattern '(?ms)const stage_script = "scripts/stage-conpty-redist\.ps1";.*?if \(installedMatches\(arena, bin, &staged\)\) return;.*?env\.remove\("PSModulePath"\);.*?\.env_map = &env,.*?b\.pathFromRoot\(stage_script\).*?0 => \{\s*if \(installedMatches\(arena, bin, &staged\)\) return;\s*return step\.fail\(.*?exit_not_downloaded => \{.*?break :reason "the package could not be fetched";.*?return step\.fail\(.*?bin\.deleteFile\(file\.name\)' `
    -Description 'source builds restage only through the release helper with a clean PSModulePath, re-verify its result, tolerate only a failed download, and remove an unpinned pair before falling back'
Assert-WorkflowContract `
    -Path $conptyStageScript `
    -Pattern '(?ms)\$ErrorActionPreference = "Stop".*?\. \(Join-Path \$PSScriptRoot "conpty-redist\.ps1"\).*?Mutex\]::new\(\$false, "Local\\noctty-stage-conpty-redist"\).*?WaitOne\(\[TimeSpan\]::FromMinutes\(2\)\).*?if \(-not \$owned\) \{.*?exit 3\s*\}.*?Install-ConPtyRedist\s*`\s*-PinPath \(Join-Path \$PSScriptRoot "\.\.\\dist\\windows\\conpty-redist\.json"\).*?ReleaseMutex\(\).*?if \(-not \$staged\) \{\s*exit 3\s*\}' `
    -Description 'source-build staging serializes on a named mutex, runs the release helper against the shared pin, and reports only a failed download as exit 3'
Assert-WorkflowContractAbsent `
    -Path $conptyStageScript `
    -Pattern 'Invoke-SignFile|signtool|Set-AuthenticodeSignature' `
    -Description 'source-build staging never signs the Microsoft binaries'
Assert-WorkflowContract `
    -Path $testWorkflow `
    -Pattern '(?ms)- name: Build executable.*?- name: Verify source build stages the pinned ConPTY\s+shell: pwsh\s+run: \./test/windows/source-build-conpty\.ps1 -Architecture x64\s.*?- name: Build ARM64 executable.*?- name: Verify ARM64 source build stages the pinned ConPTY\s+shell: pwsh\s+run: \./test/windows/source-build-conpty\.ps1 -Architecture arm64\s' `
    -Description 'CI checks that x64 and ARM64 source builds stage the pinned ConPTY pair'
Assert-WorkflowContract `
    -Path (Join-Path $repoRoot 'test\windows\source-build-conpty.ps1') `
    -Pattern '(?ms)Assert-ConPtySha256 -Path \$path -Expected \$file\.Sha256.*?Assert-PeMachine -PathToCheck \$path -ExpectedArchitecture \$Architecture.*?ConPTY\\s\*: bundled \\\(' `
    -Description 'the source-build ConPTY check uses the release hash and PE checks and requires noctty to select the pair'
Assert-WorkflowContract `
    -Path $conptyRuntime `
    -Pattern '(?ms)fn signalFallbackBanner\(\) void \{\s*fallback_banner_pending\.store\(true, \.release\);\s*\}' `
    -Description 'a ConPTY fallback warns in every build mode, not only ReleaseFast'
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
# noctty/ghostty-vt.dll in that list is the placeholder, not libghostty-vt
# (src/build/GhosttyVtStub.zig). It is signed in the same staging loop as the
# other runtime PEs, then checked to be the placeholder; the old portable
# updaters require a pinned-publisher signature on every payload DLL.
# Read through PowerShell's parser, not as text: a line comment, a block
# comment or a here-string around a required call leaves no command there, so
# it fails the contract as a deleted call does, and so does a signing filter
# without ".dll"; the controls below prove each. A control that disables a
# required call disables its whole line, and a control whose text no longer
# parses proves nothing, so every control must still parse and must fail the
# contract. (Deliberately dead code, such as `if ($false)`, is for review to
# catch.)
function Get-PlaceholderStagingProblems {
    param([Parameter(Mandatory)] [string] $ScriptText)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$parseErrors)
    $problems = [System.Collections.Generic.List[string]]::new()
    if (@($parseErrors).Count -gt 0) {
        $problems.Add("the packager does not parse: $($parseErrors[0].Message)")
        return , $problems
    }
    $isCommand = { param($node) $node -is [System.Management.Automation.Language.CommandAst] }

    $listsStub = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$runtimeFiles'
    }, $true) | Where-Object {
        @($_.Right.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -eq 'ghostty-vt-stub\ghostty-vt.dll'
        }, $true)).Count -gt 0
    })
    if ($listsStub.Count -eq 0) { $problems.Add('$runtimeFiles does not list ghostty-vt-stub\ghostty-vt.dll') }

    $stagingLoop = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'runtimeFile'
    }, $true) | Where-Object {
        $loopCommands = @($_.Body.FindAll($isCommand, $true))
        @($loopCommands | Where-Object { $_.GetCommandName() -eq 'Invoke-SignFile' -and $_.Extent.Text -match '-PathToSign \$destinationPath' }).Count -gt 0 -and
        @($loopCommands | Where-Object { $_.GetCommandName() -eq 'Assert-ValidSignature' -and $_.Extent.Text -match '-PathToCheck \$destinationPath' }).Count -gt 0
    }) | Select-Object -First 1
    if ($null -eq $stagingLoop) {
        $problems.Add('no runtime staging loop signs (Invoke-SignFile) and verifies (Assert-ValidSignature) each staged file')
        return , $problems
    }
    # The loop signs by extension; an `if` around the signing call must
    # still take a .dll, or the placeholder ships unsigned.
    $signCall = @($stagingLoop.Body.FindAll($isCommand, $true) | Where-Object { $_.GetCommandName() -eq 'Invoke-SignFile' }) | Select-Object -First 1
    for ($node = $signCall.Parent; $null -ne $node -and $node -ne $stagingLoop; $node = $node.Parent) {
        if ($node -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
        foreach ($clause in $node.Clauses) {
            if ($signCall.Extent.StartOffset -lt $clause.Item2.Extent.StartOffset -or $signCall.Extent.EndOffset -gt $clause.Item2.Extent.EndOffset) { continue }
            $takesDll = @($clause.Item1.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq '.dll'
            }, $true)).Count -gt 0
            if (-not $takesDll) { $problems.Add('the staging loop signs only behind a condition that does not take ".dll"') }
        }
    }

    $commands = @($ast.FindAll($isCommand, $true))
    $zipPhase = $commands | Where-Object { $_.GetCommandName() -eq 'Write-Host' -and $_.Extent.Text -match 'Packaging phase: create portable zip' } | Select-Object -First 1
    if ($null -eq $zipPhase) {
        $problems.Add('the portable zip phase is missing')
        return , $problems
    }
    $stubCheck = $commands | Where-Object {
        $_.GetCommandName() -eq 'Assert-GhosttyVtStub' -and
        $_.Extent.Text -match 'Join-Path \$portableRoot "ghostty-vt\.dll"' -and
        $_.Extent.StartOffset -gt $stagingLoop.Extent.EndOffset -and
        $_.Extent.StartOffset -lt $zipPhase.Extent.StartOffset
    } | Select-Object -First 1
    if ($null -eq $stubCheck) { $problems.Add('the staged ghostty-vt.dll is not checked to be the placeholder (Assert-GhosttyVtStub) before the portable zip is made') }
    return , $problems
}

$windowsPackagerText = Get-Content -LiteralPath $windowsPackager -Raw
$stagingProblems = Get-PlaceholderStagingProblems -ScriptText $windowsPackagerText
if ($stagingProblems.Count -gt 0) {
    throw "Workflow contract missing: the ghostty-vt.dll placeholder is staged, signed and verified with the other runtime PEs, and checked to be the placeholder before the portable zip is made: $($stagingProblems -join '; ') ($windowsPackager)"
}
$runtimeLoopStart = $windowsPackagerText.IndexOf('foreach ($runtimeFile in $runtimeFiles) {')
if ($runtimeLoopStart -lt 0) { throw "Contract control: the runtime staging loop is missing ($windowsPackager)" }
function Assert-PlaceholderControlFails {
    param([Parameter(Mandatory)] [string] $ScriptText, [Parameter(Mandatory)] [string] $What)

    # Checked with the parser itself, not by the wording of the contract's
    # own parse-error problem, so rewording that message can't turn this off.
    $controlTokens = $null
    $controlParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$controlTokens, [ref]$controlParseErrors)
    if (@($controlParseErrors).Count -gt 0) {
        throw "Contract control is invalid: with $What the packager no longer parses, so the contract would fail for that reason alone ($($controlParseErrors[0].Message))"
    }
    $controlProblems = Get-PlaceholderStagingProblems -ScriptText $ScriptText
    if ($controlProblems.Count -eq 0) {
        throw "Contract control failed: the placeholder staging contract still passes with $What"
    }
}

foreach ($requiredCall in @(
    '"ghostty-vt-stub\ghostty-vt.dll",',
    'Invoke-SignFile -SigningConfig $signingConfig -PathToSign $destinationPath',
    'Assert-ValidSignature -PathToCheck $destinationPath -SigningConfig $signingConfig',
    'Assert-GhosttyVtStub -Path (Join-Path $portableRoot "ghostty-vt.dll")'
)) {
    $searchFrom = if ($requiredCall.StartsWith('"')) { 0 } else { $runtimeLoopStart }
    $callIndex = $windowsPackagerText.IndexOf($requiredCall, $searchFrom)
    if ($callIndex -lt 0) { throw "Contract control: '$requiredCall' is missing from $windowsPackager" }
    if ($windowsPackagerText.IndexOf($requiredCall, $callIndex + $requiredCall.Length) -ge 0) { throw "Contract control: '$requiredCall' occurs more than once in $windowsPackager; anchor each control on a line that occurs once" }
    # A control must disable the whole line: an anchor that stops short leaves
    # the rest of the line behind the comment or here-string.
    $lineStart = if ($callIndex -eq 0) { 0 } else { $windowsPackagerText.LastIndexOf("`n", $callIndex - 1) + 1 }
    $lineEnd = $windowsPackagerText.IndexOf("`n", $callIndex)
    if ($lineEnd -lt 0) { $lineEnd = $windowsPackagerText.Length }
    $anchorLine = $windowsPackagerText.Substring($lineStart, $lineEnd - $lineStart).Trim()
    if ($anchorLine -ne $requiredCall) { throw "Contract control: '$requiredCall' is not a whole line in $windowsPackager (the line is '$anchorLine')" }
    $before = $windowsPackagerText.Substring(0, $callIndex)
    $after = $windowsPackagerText.Substring($callIndex + $requiredCall.Length)
    foreach ($disabled in @(
        @{ How = 'line-commented'; Text = $before + '# ' + $requiredCall + $after },
        @{ How = 'block-commented'; Text = $before + '<# ' + $requiredCall + ' #>' + $after },
        @{ How = 'block-commented over lines'; Text = $before + "<#`n" + $requiredCall + "`n#>" + $after },
        @{ How = 'inside a here-string'; Text = $before + "@'`n" + $requiredCall + "`n'@" + $after },
        @{ How = 'deleted'; Text = $before + $after }
    )) {
        Assert-PlaceholderControlFails -ScriptText $disabled.Text -What "'$requiredCall' $($disabled.How)"
    }
}
$signFilter = '@(".com", ".exe", ".dll") -contains'
if ($windowsPackagerText.IndexOf($signFilter, $runtimeLoopStart) -lt 0) { throw "Contract control: the staging loop's signing filter '$signFilter' is missing from $windowsPackager" }
Assert-PlaceholderControlFails -ScriptText $windowsPackagerText.Replace($signFilter, '@(".com", ".exe") -contains') -What '".dll" dropped from the signing filter'
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
# The single foreach over $expectedPortablePePaths is part of the contract:
# it is what stops an expected PE from leaving the block unverified.
Assert-WorkflowContract `
    -Path $publishedReleaseVerifierScript `
    -Pattern '(?ms)dist/windows/conpty-redist\.json.*?conptyDll.*?openConsoleExe.*?foreach \(\$relativePath in \$expectedPortablePePaths\).*?Get-FileHash -Algorithm SHA256.*?pinned ConPTY SHA-256.*?X509NameType\]::SimpleName.*?Microsoft Corporation' `
    -Description 'published-release verification rechecks the bundled ConPTY pair against its pinned hashes and Microsoft signer'
