$releaseArtifactVerifier = Join-Path $repoRoot 'scripts\release-verify-artifacts.ps1'
$releaseArtifactVerifierText = Get-Content -LiteralPath $releaseArtifactVerifier -Raw
$releaseArtifactVerifierSha256 =
    '67719f4ee9604d389eca6958f54088b0cc0923151d2c0be19aa372bf08fc80c0'
$canonicalReleaseArtifactVerifier = ConvertTo-CanonicalText `
    -Text $releaseArtifactVerifierText
if ((Get-CanonicalTextSha256 -Text $canonicalReleaseArtifactVerifier) -cne
    $releaseArtifactVerifierSha256) {
    throw "Protected release script changed: $releaseArtifactVerifier"
}
$releaseArtifactVerifierCriticalStatement =
    '    $checksumEntries = Get-ChecksumEntries -Path $checksums'
if (@([regex]::Matches(
    $canonicalReleaseArtifactVerifier,
    [regex]::Escape($releaseArtifactVerifierCriticalStatement)
)).Count -ne 1) {
    throw "Protected release-script mutation target is not unique: $releaseArtifactVerifier"
}
$releaseArtifactVerifierIndent = [regex]::Match(
    $releaseArtifactVerifierCriticalStatement,
    '^\s*'
).Value
$releaseArtifactVerifierStatement =
    $releaseArtifactVerifierCriticalStatement.Substring(
        $releaseArtifactVerifierIndent.Length
    )
$releaseArtifactVerifierSideEffect =
    "${releaseArtifactVerifierIndent}Set-Content -LiteralPath " +
    "([IO.Path]::Combine([IO.Path]::GetTempPath(), " +
    "'noctty-release-pin-mutant')) -Value 'mutated'"
$releaseArtifactVerifierMutants = [ordered] @{
    'injected early return' = $canonicalReleaseArtifactVerifier.Replace(
        $releaseArtifactVerifierCriticalStatement,
        (@(
            "${releaseArtifactVerifierIndent}return",
            $releaseArtifactVerifierCriticalStatement
        ) -join "`n")
    )
    'dead-code wrapping' = $canonicalReleaseArtifactVerifier.Replace(
        $releaseArtifactVerifierCriticalStatement,
        (@(
            "${releaseArtifactVerifierIndent}if (`$false) {",
            "${releaseArtifactVerifierIndent}    $releaseArtifactVerifierStatement",
            "${releaseArtifactVerifierIndent}}"
        ) -join "`n")
    )
    'added side effect' = $canonicalReleaseArtifactVerifier.Replace(
        $releaseArtifactVerifierCriticalStatement,
        (@(
            $releaseArtifactVerifierSideEffect,
            $releaseArtifactVerifierCriticalStatement
        ) -join "`n")
    )
}
foreach ($mutation in $releaseArtifactVerifierMutants.GetEnumerator()) {
    $mutationTokens = $null
    $mutationErrors = $null
    [void] [Management.Automation.Language.Parser]::ParseInput(
        $mutation.Value,
        [ref] $mutationTokens,
        [ref] $mutationErrors
    )
    if ($mutationErrors.Count -ne 0) {
        throw "Protected release-script mutation does not parse: $releaseArtifactVerifier :: $($mutation.Key)"
    }
    if ((Get-CanonicalTextSha256 -Text $mutation.Value) -ceq
        $releaseArtifactVerifierSha256) {
        throw "Protected release script accepted full-file mutation: $releaseArtifactVerifier :: $($mutation.Key)"
    }
}

function Get-ContractPowerShellAst {
    param(
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Context
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Content,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) {
        throw "Signing contract source does not parse: $Context ($($errors[0].Message))"
    }
    return $ast
}

function Get-TopLevelContractFunctions {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.ScriptBlockAst] $Ast,
        [Parameter(Mandatory)] [string] $Name
    )

    return @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            ($node.Name -replace '^(?i)(?:global|script|local|private):', '') -ceq $Name -and
            [object]::ReferenceEquals($node.Parent, $Ast.EndBlock)
    }, $true))
}

$signingTrustAst = Get-ContractPowerShellAst `
    -Content $signingTrustText `
    -Context $signingTrust
$trustStatusDefinitions = @(
    Get-TopLevelContractFunctions -Ast $signingTrustAst -Name 'Test-SelfSignedTrustStatus'
)
$releaseSignatureDefinitions = @(
    Get-TopLevelContractFunctions -Ast $signingTrustAst -Name 'Assert-ReleaseSignature'
)
$checksumDefinitions = @(
    Get-TopLevelContractFunctions -Ast $signingTrustAst -Name 'Get-ChecksumEntries'
)
if ($trustStatusDefinitions.Count -ne 1 -or
    $releaseSignatureDefinitions.Count -ne 1 -or
    $checksumDefinitions.Count -ne 1) {
    throw 'scripts/signing-trust.ps1 must own one top-level trust classifier, release-signature assertion, and checksum parser.'
}

$trustStatusBodyText = $trustStatusDefinitions[0].Body.Extent.Text
if ($trustStatusBodyText -match '\bStatusMessage\b' -or
    $trustStatusBodyText -notmatch
        'SignatureStatus\]::UnknownError' -or
    $trustStatusBodyText -notmatch
        'VerifyEmbeddedSignatureAndFileHash' -or
    $trustStatusDefinitions[0].Extent.Text -notmatch
        '(?s)\[string\]\s+\$Path\b') {
    throw 'Self-signed trust must classify UnknownError by cryptographic file verification through a typed Path, never localized StatusMessage text.'
}

$releaseSignatureBody = $releaseSignatureDefinitions[0].Body
$releaseSignatureAuthenticodeCalls = @($releaseSignatureBody.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Get-AuthenticodeSignature'
}, $true))
$releaseSignatureTrustCalls = @($releaseSignatureBody.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Test-SelfSignedTrustStatus'
}, $true))
if ($releaseSignatureAuthenticodeCalls.Count -ne 1 -or
    $releaseSignatureTrustCalls.Count -ne 1) {
    throw 'The shared release-signature assertion must own one Authenticode read and one trust-policy decision.'
}
$releaseSignatureText = $releaseSignatureDefinitions[0].Extent.Text
if ($releaseSignatureText -notmatch '\bGet-CertificateSpkiSha256\b' -or
    $releaseSignatureText -notmatch
        '\$AllowedPins\s+-notcontains\s+\$pin' -or
    $releaseSignatureText -notmatch '\bThumbprint\s*=' -or
    $releaseSignatureText -notmatch '\bSpkiSha256\s*=') {
    throw 'Release signature acceptance must bind the signer SPKI to AllowedPins and return Thumbprint plus SpkiSha256 evidence.'
}

# Trust path binding, cryptographic verification, updater pins, and signer
# evidence are observed by the real signed/tampered-PE policy test below. Local
# parameter names and implementation ordering add no contract coverage.
$checksumProbeRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'noctty-checksum-contract-' + [Guid]::NewGuid().ToString('N')
)
$checksumValidPath = Join-Path $checksumProbeRoot 'valid.txt'
$checksumDuplicatePath = Join-Path $checksumProbeRoot 'duplicate.txt'
$checksumMalformedPath = Join-Path $checksumProbeRoot 'malformed.txt'
$checksumCalls = 0
try {
    [IO.Directory]::CreateDirectory($checksumProbeRoot) | Out-Null
    . ([scriptblock]::Create($checksumDefinitions[0].Extent.Text))
    $hashA = 'A' * 64
    $hashB = 'b' * 64
    [IO.File]::WriteAllLines($checksumValidPath, @(
        "$hashA *setup.exe",
        "$hashB *portable.zip"
    ))
    $checksumCalls++
    $entries = Get-ChecksumEntries -Path $checksumValidPath
    if ($entries.Count -ne 2 -or
        $entries['setup.exe'] -cne $hashA.ToLowerInvariant() -or
        $entries['portable.zip'] -cne $hashB) {
        throw 'Executed checksum parser must return unique lowercase-normalized entries.'
    }

    [IO.File]::WriteAllLines($checksumDuplicatePath, @(
        "$hashA *setup.exe",
        "$hashB *setup.exe"
    ))
    $checksumCalls++
    $duplicateRejected = $false
    try { Get-ChecksumEntries -Path $checksumDuplicatePath | Out-Null }
    catch { $duplicateRejected = $true }

    [IO.File]::WriteAllText($checksumMalformedPath, 'not-a-checksum *setup.exe')
    $checksumCalls++
    $malformedRejected = $false
    try { Get-ChecksumEntries -Path $checksumMalformedPath | Out-Null }
    catch { $malformedRejected = $true }
    if ($checksumCalls -ne 3 -or -not $duplicateRejected -or -not $malformedRejected) {
        throw 'Executed checksum parser must reject duplicate names and malformed digests.'
    }
}
finally {
    Remove-Item -LiteralPath Function:\Get-ChecksumEntries -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($checksumProbeRoot)) {
        [IO.Directory]::Delete($checksumProbeRoot, $true)
    }
}

$signingTrustConsumers = @(
    [pscustomobject]@{
        Context = $publishedReleaseVerifier
        Content = $publishedReleaseVerifierText
        ExpectedReleaseSignatureCalls = 3
        ExpectedChecksumCalls = 1
    },
    [pscustomobject]@{
        Context = $releaseArtifactVerifier
        Content = $releaseArtifactVerifierText
        ExpectedReleaseSignatureCalls = 3
        ExpectedChecksumCalls = 1
    }
)
foreach ($consumer in $signingTrustConsumers) {
    $ast = Get-ContractPowerShellAst `
        -Content $consumer.Content `
        -Context $consumer.Context
    foreach ($ownedName in @(
        'Test-SelfSignedTrustStatus',
        'Assert-ReleaseSignature',
        'Get-ChecksumEntries'
    )) {
        if (@(Get-TopLevelContractFunctions -Ast $ast -Name $ownedName).Count -ne 0) {
            throw "Shared signing logic was redefined by $($consumer.Context): $ownedName"
        }
    }
    $imports = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
            $node.Extent.Text.Trim() -match
                '^\.\s+\(\s*Join-Path\s+\$PSScriptRoot\s+[''"]signing-trust\.ps1[''"]\s*\)$'
    }, $true))
    $signatureCalls = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Assert-ReleaseSignature'
    }, $true))
    $checksumCalls = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Get-ChecksumEntries'
    }, $true))
    $directTrustCalls = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Test-SelfSignedTrustStatus'
    }, $true))
    if ($imports.Count -ne 1 -or
        $signatureCalls.Count -ne $consumer.ExpectedReleaseSignatureCalls -or
        $checksumCalls.Count -ne $consumer.ExpectedChecksumCalls -or
        $directTrustCalls.Count -ne 0) {
        throw "Release verification must consume the one shared signing/checksum implementation: $($consumer.Context)"
    }
}

Invoke-ContractTable -Contracts @(
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)^\. \(Join-Path \$PSScriptRoot "signing-trust\.ps1"\).*?function Assert-ValidSignature.*?Get-AuthenticodeSignature -LiteralPath \$PathToCheck.*?SignerCertificate\.Thumbprint -ne \$SigningConfig\.CertificateThumbprint.*?Test-SelfSignedTrustStatus -Signature \$signature -Path \$PathToCheck'
        Kind = 'Text'
        Description = 'packaging imports shared self-signed classification while retaining the active signing-certificate thumbprint gate'
    }
    @{
        File = $releaseArtifactVerifier
        Content = { $releaseArtifactVerifierText }
        Pattern = '(?ms)Get-WindowsPackageArchitectures.*?-Kind setup.*?-Kind portable.*?-Kind manifest.*?-Kind checksums.*?Get-ChecksumEntries.*?\$expectedChecksumNames = @\(.*?GetFileName\(\$setup\).*?GetFileName\(\$portable\).*?\$checksumEntries\.Count -ne \$expectedChecksumNames\.Count.*?\$checksumEntries\.Contains\(\$_\).*?Get-FileSha256Lower.*?Assert-ReleaseSignature.*?Setup \$architecture.*?Assert-ReleaseSignature.*?Portable manifest \$architecture.*?Expand-Archive.*?Assert-PortableManifestMatchesPayload.*?noctty/noctty\.com.*?noctty/noctty\.exe.*?noctty/ghostty-vt\.dll.*?noctty/noctty-terminal-handoff-proxy\.dll.*?Assert-ReleaseSignature'
        Kind = 'Text'
        Description = 'local release verification checks both architecture checksum sets and all installer and portable PE signatures'
    }
)

$signingBehaviorOutputs = @(
    & pwsh -NoProfile -File $signingTrustTest 2>&1
)
$signingBehaviorExitCode = $LASTEXITCODE
$signingBehaviorPassOutputs = @(
    $signingBehaviorOutputs |
        Where-Object { [string]$_ -eq 'signing trust policy tests: PASS' }
)
if ($signingBehaviorExitCode -ne 0 -or
    $signingBehaviorPassOutputs.Count -ne 1) {
    throw "Signing policy behavior failed (exit $signingBehaviorExitCode): $($signingBehaviorOutputs -join [Environment]::NewLine)"
}
$requiredSigningPolicyTestPins = @(
    'Set-AuthenticodeSignature',
    'Direct Authenticode verifier accepted a PE with a modified signed body.',
    'Direct Authenticode verifier accepted a PE with a modified PKCS#7 signature.'
)
foreach ($requiredPin in $requiredSigningPolicyTestPins) {
    if (-not $signingTrustTestText.Contains(
            $requiredPin,
            [StringComparison]::Ordinal
        )) {
        throw "Signing policy test lost required real-signing/tamper coverage: $requiredPin"
    }
}
# The former initializer offset protected nothing observable: earlier trust
# verification initializes the same type. The self-contained signing test is the
# contract and must reach one PASS sentinel.

# Deleted verifier/test implementation and error-string pins: the executed policy
# test accepts an intact signed PE and rejects both body and PKCS#7 mutations.
# The exact published asset/checksum/signature set below is retained because it
# is release-evidence topology, not incidental implementation cardinality.
foreach ($contract in @(
    @{ Pattern = '\$firstPortableManifestVersion = \[version\]''1\.3\.124'''; Description = 'published verifier starts the signed-manifest contract at v1.3.124' },
    @{ Pattern = '\$expectedAssetCount = if \(\$requiresPortableManifests\) \{ 10 \} else \{ 8 \}'; Description = 'published verifier preserves the historical asset set and requires ten assets from v1.3.124' },
    @{ Pattern = '(?s)\$missing = .*?\$unexpected = .*?\$missing\.Count -gt 0 -or \$unexpected\.Count -gt 0.*?asset set mismatch'; Description = 'published verifier rejects missing and unexpected assets' },
    @{ Pattern = '(?s)Get-FileSha256Lower.*?\$digest = .*?\$digest -notmatch.*?\$actualHash -ne \$digest\.Substring\(7\)\.ToLowerInvariant\(\).*?digest mismatch'; Description = 'published verifier compares downloaded bytes with GitHub SHA-256 digests' },
    @{ Pattern = 'SequenceEqual'; Description = 'published verifier preserves byte-identical legacy x64 checksum alias' },
    @{ Pattern = '(?s)\$checksums\.Count -ne \$expectedChecksumNames\.Count.*?\$checksums\.Contains\(\$_\).*?\$checksums\[\$name\] -ne \$actualHash'; Description = 'published verifier enforces exact checksum names, count, and hashes' },
    @{ Pattern = '(?s)\$signatureEvidence\.Add\(\(Assert-ReleaseSignature.*?Setup \$architecture.*?Portable manifest \$architecture.*?Assert-PortableManifestMatchesPayload.*?foreach \(\$relativePath.*?\$signatureEvidence\.Add\(\(Assert-ReleaseSignature.*?\$expectedSignatureCount = if \(\$requiresPortableManifests\) \{ 12 \} else \{ 10 \}'; Description = 'published verifier validates two manifests plus every current portable PE while preserving pre-manifest releases' },
    @{ Pattern = '(?s)gh attestation verify.*?--repo \$Repository.*?--signer-workflow.*?release\.yml.*?\$verifyAttestations.*?asset\.name -ne ''noctty-icon\.svg''.*?\$attestationEvidenceCount \+= 1'; Description = 'published verifier binds nine non-icon attestations to the canonical release workflow' },
    @{ Pattern = '(?s)\$thumbprints\.Count -ne 1 -or \$pins\.Count -ne 1.*?one consistent certificate'; Description = 'published verifier requires one consistent signer after shared updater-pin verification' },
    @{ Pattern = "(?s)noctty/noctty\.com'.*?noctty/noctty\.exe'.*?noctty/ghostty-vt\.dll'.*?noctty/noctty-terminal-handoff-proxy\.dll'"; Description = 'published verifier checks every packaged runtime PE for both architectures' },
    @{ Pattern = '(?s)finally \{.*?\$createdTempDirectory.*?\$DownloadDirectory\.StartsWith\(\$tempRoot.*?for \(\$attempt = 1; \$attempt -le 3; \$attempt\+\+\).*?Remove-Item .*?-ErrorAction Stop.*?Write-Warning'; Description = 'published verifier guards, retries, and reports temporary cleanup' }
)) {
    Invoke-ContractTable -Contracts @(
        @{
            File = $publishedReleaseVerifier
            Content = { $publishedReleaseVerifierText }
            Pattern = $contract.Pattern
            Kind = 'Text'
            Description = $contract.Description
        }
    )
}
