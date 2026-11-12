$releaseArtifactVerifier = Join-Path $repoRoot 'scripts\release-verify-artifacts.ps1'
$releaseArtifactVerifierText = Get-Content -LiteralPath $releaseArtifactVerifier -Raw
$releaseArtifactVerifierSha256 =
    '22804247b157590260c275218dccd738705cecb0a3ed913a30d561910f9fe7e5'
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
    "'koreterm-release-pin-mutant')) -Value 'mutated'"
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
    'koreterm-checksum-contract-' + [Guid]::NewGuid().ToString('N')
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
        Pattern = '(?ms)^\. \(Join-Path \$PSScriptRoot "signing-trust\.ps1"\).*?Certificate = \$signingCert.*?function Assert-ValidSignature.*?Get-AuthenticodeSignature -LiteralPath \$PathToCheck.*?SignerCertificate\.Thumbprint -ne \$SigningConfig\.CertificateThumbprint.*?Test-SelfSignedTrustStatus -Signature \$signature -Path \$PathToCheck'
        Kind = 'Text'
        Description = 'packaging imports shared self-signed classification while retaining the active signing-certificate thumbprint gate'
    }
    @{
        File = $releaseArtifactVerifier
        Content = { $releaseArtifactVerifierText }
        Pattern = '(?ms)Get-WindowsPackageArchitectures.*?-Kind setup.*?-Kind portable.*?-Kind manifest.*?-Kind checksums.*?Get-ChecksumEntries.*?\$expectedChecksumNames = @\(.*?GetFileName\(\$setup\).*?GetFileName\(\$portable\).*?\$checksumEntries\.Count -ne \$expectedChecksumNames\.Count.*?\$checksumEntries\.Contains\(\$_\).*?Get-FileSha256Lower.*?Assert-ReleaseSignature.*?Setup \$architecture.*?Assert-ReleaseSignature.*?Portable manifest \$architecture.*?Expand-Archive.*?Assert-PortableManifestMatchesPayload.*?Get-WindowsSignedRuntimePayloads.*?Assert-ReleaseSignature'
        Kind = 'Text'
        Description = 'local release verification checks both architecture checksum sets and all installer and portable PE signatures'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = 'Get-ChildItem -LiteralPath \$PayloadRoot -Recurse -File -Force'
        Kind = 'Text'
        Description = 'portable manifest generation includes hidden and system payload files'
    }
)

# Authenticode timestamping: every signtool invocation must request an RFC 3161
# timestamp (/tr + /td SHA256); the legacy Authenticode /t countersignature is
# forbidden because it cannot carry a SHA-256 digest policy.
$signToolInvocationPattern = '(?ms)function Invoke-SignFile.*?"/fd", "SHA256".*?"/tr", \$SigningConfig\.TimestampUrl, "/td", "SHA256".*?& \$SigningConfig\.SignToolPath @signArgs'
Invoke-ContractTable -Contracts @(
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = $signToolInvocationPattern
        Kind = 'Text'
        Description = 'packaging signs with SHA-256 file digests and RFC 3161 SHA-256 timestamps (/tr, /td SHA256)'
    }
    @{
        File = $releasePreflight
        Content = { Get-Content -LiteralPath $releasePreflight -Raw }
        Pattern = '(?ms)function Assert-TimestampUrlConfigured.*?if \(\$TrustSelfSigned\) \{.*?return .*?\}.*?Test-EnvPresent -Name "WINDOWS_CODESIGN_TIMESTAMP_URL".*?throw "WINDOWS_CODESIGN_TIMESTAMP_URL must be set.*?\[Uri\]::TryCreate\(.*?\[UriKind\]::Absolute.*?Scheme -notin @\(''http'', ''https''\).*?throw "WINDOWS_CODESIGN_TIMESTAMP_URL must be an absolute http\(s\) URL.*?if \(\$RequireSigning\) \{\s*\$timestampStatus = Assert-TimestampUrlConfigured -TrustSelfSigned \$trustSelfSigned'
        Kind = 'Text'
        Description = 'release preflight requires an absolute http(s) RFC 3161 timestamp URL whenever signing is not self-signed'
    }
)
$signToolInvocationText = [regex]::Match(
    $windowsPackagerText,
    '(?ms)function Invoke-SignFile.*?& \$SigningConfig\.SignToolPath @signArgs'
).Value
if ([string]::IsNullOrEmpty($signToolInvocationText) -or
    $signToolInvocationText -match '"/t",' -or
    $signToolInvocationText -match '(?m)^\s*/t\s') {
    throw 'Packaging must never pass the legacy Authenticode /t timestamp switch to signtool.'
}

# The preflight timestamp gate is executed, not just pattern-matched: with the
# signing environment cleared it must fail closed on the timestamp URL before it
# reaches the PFX checks, and the self-signed mode must bypass that gate.
function Invoke-PreflightTimestampProbe {
    param(
        [Parameter(Mandatory)] [hashtable] $Environment
    )

    $signingVariables = @(
        'WINDOWS_CODESIGN_TRUST_SELF_SIGNED',
        'WINDOWS_CODESIGN_TIMESTAMP_URL',
        'WINDOWS_CODESIGN_PFX_BASE64',
        'WINDOWS_CODESIGN_PFX_PATH',
        'WINDOWS_CODESIGN_PFX_PASSWORD',
        'WINDOWS_CODESIGN_MIN_VALIDITY_DAYS',
        'ARTIFACT_SIGNING_ENDPOINT',
        'ARTIFACT_SIGNING_ACCOUNT_NAME',
        'ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME',
        'ARTIFACT_SIGNING_TENANT_ID',
        'ARTIFACT_SIGNING_CLIENT_ID'
    )
    $saved = @{}
    foreach ($name in $signingVariables) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    try {
        $output = @(& pwsh -NoProfile -File $releasePreflight -Version 1.3.100 -RequireSigning 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        }
    }
    finally {
        foreach ($name in $signingVariables) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

$preflightTimestampProbes = [ordered] @{
    'CA-issued mode without a timestamp URL' = [pscustomobject]@{
        Environment = @{}
        ExpectedExitCode = 1
        MustMatch = 'WINDOWS_CODESIGN_TIMESTAMP_URL must be set'
        MustNotMatch = 'Required code-signing certificate was not configured'
    }
    'CA-issued mode with a non-http timestamp URL' = [pscustomobject]@{
        Environment = @{ WINDOWS_CODESIGN_TIMESTAMP_URL = 'ftp://timestamp.invalid' }
        ExpectedExitCode = 1
        MustMatch = 'must be an absolute http\(s\) URL'
        MustNotMatch = 'Required code-signing certificate was not configured'
    }
    'CA-issued mode with an http timestamp URL' = [pscustomobject]@{
        Environment = @{ WINDOWS_CODESIGN_TIMESTAMP_URL = 'http://timestamp.invalid/rfc3161' }
        ExpectedExitCode = 1
        MustMatch = 'Required code-signing certificate was not configured'
        MustNotMatch = 'WINDOWS_CODESIGN_TIMESTAMP_URL must'
    }
    'self-signed mode without a timestamp URL' = [pscustomobject]@{
        Environment = @{ WINDOWS_CODESIGN_TRUST_SELF_SIGNED = 'true' }
        ExpectedExitCode = 1
        MustMatch = 'Required code-signing certificate was not configured'
        MustNotMatch = 'WINDOWS_CODESIGN_TIMESTAMP_URL must'
    }
    # Azure Artifact Signing (ADR 0006) stays dormant: a partial configuration,
    # one next to the PFX, or a complete one before the updater accepts its
    # rotating leaf certificates all stop preflight, and none of them falls
    # back to the PFX checks above.
    'Artifact Signing partly configured' = [pscustomobject]@{
        Environment = @{
            WINDOWS_CODESIGN_TIMESTAMP_URL = 'http://timestamp.acs.microsoft.com'
            ARTIFACT_SIGNING_ACCOUNT_NAME = 'koretermprobe'
        }
        ExpectedExitCode = 1
        MustMatch = 'Azure Artifact Signing is partly configured'
        MustNotMatch = 'Required code-signing certificate was not configured'
    }
    'Artifact Signing next to the PFX' = [pscustomobject]@{
        Environment = @{
            WINDOWS_CODESIGN_TIMESTAMP_URL = 'http://timestamp.acs.microsoft.com'
            WINDOWS_CODESIGN_PFX_BASE64 = 'cHJvYmU='
            ARTIFACT_SIGNING_ENDPOINT = 'https://eus.codesigning.azure.net'
            ARTIFACT_SIGNING_ACCOUNT_NAME = 'koretermprobe'
            ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME = 'koretermprobeprofile'
            ARTIFACT_SIGNING_TENANT_ID = '00000000-0000-0000-0000-000000000001'
            ARTIFACT_SIGNING_CLIENT_ID = '00000000-0000-0000-0000-000000000002'
        }
        ExpectedExitCode = 1
        MustMatch = 'so WINDOWS_CODESIGN_PFX_BASE64 must be removed'
        MustNotMatch = 'Signer SPKI SHA-256'
    }
    'Artifact Signing with a foreign endpoint' = [pscustomobject]@{
        Environment = @{
            WINDOWS_CODESIGN_TIMESTAMP_URL = 'http://timestamp.acs.microsoft.com'
            ARTIFACT_SIGNING_ENDPOINT = 'https://eus.codesigning.azure.net.example'
            ARTIFACT_SIGNING_ACCOUNT_NAME = 'koretermprobe'
            ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME = 'koretermprobeprofile'
            ARTIFACT_SIGNING_TENANT_ID = '00000000-0000-0000-0000-000000000001'
            ARTIFACT_SIGNING_CLIENT_ID = '00000000-0000-0000-0000-000000000002'
        }
        ExpectedExitCode = 1
        MustMatch = 'ARTIFACT_SIGNING_ENDPOINT must be a regional endpoint'
        MustNotMatch = 'Required code-signing certificate was not configured'
    }
    'Artifact Signing before the updater accepts it' = [pscustomobject]@{
        Environment = @{
            WINDOWS_CODESIGN_TIMESTAMP_URL = 'http://timestamp.acs.microsoft.com'
            ARTIFACT_SIGNING_ENDPOINT = 'https://eus.codesigning.azure.net'
            ARTIFACT_SIGNING_ACCOUNT_NAME = 'koretermprobe'
            ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME = 'koretermprobeprofile'
            ARTIFACT_SIGNING_TENANT_ID = '00000000-0000-0000-0000-000000000001'
            ARTIFACT_SIGNING_CLIENT_ID = '00000000-0000-0000-0000-000000000002'
        }
        ExpectedExitCode = 1
        MustMatch = 'The updater does not accept Azure Artifact Signing yet'
        MustNotMatch = 'Required code-signing certificate was not configured|Release preflight passed'
    }
}
foreach ($probe in $preflightTimestampProbes.GetEnumerator()) {
    $result = Invoke-PreflightTimestampProbe -Environment $probe.Value.Environment
    if ($result.ExitCode -ne $probe.Value.ExpectedExitCode -or
        $result.Text -notmatch $probe.Value.MustMatch -or
        $result.Text -match $probe.Value.MustNotMatch) {
        throw "Release preflight timestamp gate misbehaved for $($probe.Key) (exit $($result.ExitCode)): $($result.Text)"
    }
}

# The Artifact Signing path is configuration only: both workflows that enter
# the release environment read its five values from environment variables,
# never from secrets, and it signs through the job's own OIDC identity.
$artifactSigningWorkflowContracts = foreach ($workflowPath in @(
        $releaseWorkflow,
        (Join-Path $repoRoot '.github\workflows\release-readiness.yml')
    )) {
    foreach ($name in @(
            'ARTIFACT_SIGNING_ENDPOINT',
            'ARTIFACT_SIGNING_ACCOUNT_NAME',
            'ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME',
            'ARTIFACT_SIGNING_TENANT_ID',
            'ARTIFACT_SIGNING_CLIENT_ID'
        )) {
        @{
            File = $workflowPath
            Pattern = "(?m)^      ${name}: \`$\{\{ vars\.${name} \}\}\s*$"
            Kind = 'Workflow'
            Description = "the release job reads $name from the release environment's variables"
        }
    }
}
Invoke-ContractTable -Contracts @($artifactSigningWorkflowContracts)
foreach ($workflowPath in @($releaseWorkflow, (Join-Path $repoRoot '.github\workflows\release-readiness.yml'))) {
    if ((Get-Content -LiteralPath $workflowPath -Raw) -match 'secrets\.(?:ARTIFACT_SIGNING|AZURE)_') {
        throw "Artifact Signing must not read a secret: $workflowPath"
    }
}
Invoke-ContractTable -Contracts @(
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)function Get-SigningConfig \{\s*\$artifactSigning = Get-ArtifactSigningConfiguration\s*if \(\$artifactSigning\) \{\s*return Get-ArtifactSigningConfig -Configuration \$artifactSigning\s*\}\s*\$hasPath = '
        Kind = 'Text'
        Description = 'packaging takes the Artifact Signing path only when it is configured and otherwise reaches the PFX path unchanged'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)function Invoke-SignFile.*?if \(\$SigningConfig\.DlibPath\) \{\s*\$signArgs \+= @\("/dlib", \$SigningConfig\.DlibPath, "/dmdf", \$SigningConfig\.MetadataPath\)\s*\} else \{\s*\$signArgs \+= @\("/f", \$SigningConfig\.PfxPath, "/p", \$SigningConfig\.PfxPassword\)\s*\}'
        Kind = 'Text'
        Description = 'signtool gets the Artifact Signing dlib or the PFX, never both'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)\$artifactSigningClientVersion = "1\.0\.146"\s*\$artifactSigningClientSha512 = "/G0hG/VDIS6psW23b5t1V/ORIgn0PVAOtGj9w\+hkPmAuI4pempfwlW50E2GtHscnz9\+5Qz3hbC4mcb7ej2Yn1A=="'
        Kind = 'Text'
        Description = 'the Artifact Signing client is pinned by version and nuget.org SHA-512'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)SHA512\]::HashData.*?if \(\$packageSha512 -cne \$artifactSigningClientSha512\) \{\s*throw .*?ExtractToDirectory'
        Kind = 'Text'
        Description = 'the Artifact Signing client is hash-checked before it is extracted'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)ExcludeCredentials = @\(\s*"EnvironmentCredential",\s*"ManagedIdentityCredential",\s*"SharedTokenCacheCredential",\s*"VisualStudioCredential",\s*"VisualStudioCodeCredential",\s*"AzureCliCredential",\s*"AzurePowerShellCredential",\s*"AzureDeveloperCliCredential",\s*"InteractiveBrowserCredential"\s*\)'
        Kind = 'Text'
        Description = 'only the workload-identity credential can sign for the release job'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)audience = \[System\.Uri\]::EscapeDataString\("api://AzureADTokenExchange"\).*?try \{\s*\[System\.IO\.File\]::WriteAllText\(\$SigningConfig\.FederatedTokenPath.*?& \$SigningConfig\.SignToolPath @signArgs\s*\}\s*finally \{.*?Remove-Item -LiteralPath \$SigningConfig\.FederatedTokenPath'
        Kind = 'Text'
        Description = 'each Artifact Signing call gets a fresh OIDC token that is deleted after signtool returns'
    }
    @{
        File = $windowsPackager
        Content = { $windowsPackagerText }
        Pattern = '(?ms)function Assert-ValidSignature.*?SignatureStatus\]::Valid\) \{\s*throw .*?\}\s*if \(\$SigningConfig -and \$SigningConfig\.DlibPath -and \$null -eq \$signature\.TimeStamperCertificate\) \{\s*throw '
        Kind = 'Text'
        Description = 'an Artifact Signing signature without an RFC 3161 timestamp fails packaging'
    }
)

$portableManifestVerifier = Join-Path $repoRoot 'scripts\portable-manifest-verification.ps1'
$portableManifestVerifierText = Get-Content -LiteralPath $portableManifestVerifier -Raw
Invoke-ContractTable -Contracts @(
    @{
        File = $portableManifestVerifier
        Content = { $portableManifestVerifierText }
        Pattern = 'Get-ChildItem -LiteralPath \$PayloadRoot -Recurse -File -Force'
        Kind = 'Text'
        Description = 'portable manifest verification includes hidden and system payload files'
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
    @{ Pattern = '(?s)\$firstPortableManifestVersion = \[version\]''1\.3\.124''.*?\$requiresPortableManifests = \(\$releaseVersion -ge \$firstPortableManifestVersion\)'; Description = 'published verifier executes the signed-manifest boundary at v1.3.124' },
    @{ Pattern = '\$expectedAssetCount = if \(\$requiresPortableManifests\) \{ 10 \} else \{ 8 \}\s*if \(\$requiresSymbols\) \{ \$expectedAssetCount \+= 2 \}'; Description = 'published verifier preserves the historical asset set, requires ten assets from v1.3.124 and twelve from the first symbols release' },
    @{ Pattern = '(?s)\$firstSymbolsVersion = \[version\]''1\.3\.133''.*?\$requiresSymbols = \(\$releaseVersion -ge \$firstSymbolsVersion\)'; Description = 'published verifier starts requiring the symbols zips at v1.3.133' },
    @{ Pattern = '(?s)\$requiresSymbols\) \{\s*\$expectedNames\.Add\(\(New-WindowsPackageArtifactName[^\n]*-Kind symbols\)\)\s*\}'; Description = 'published verifier adds the per-architecture symbols zip to the exact asset set' },
    @{ Pattern = '(?s)\$requiresSymbols\) \{\s*\[void\]\(Assert-SymbolsArchiveMatchesPortable.*?-SymbolsZip.*?-PayloadRoot \(Join-Path \$extractDirectory ''koreterm''\)'; Description = 'published verifier matches every downloaded PDB to the downloaded portable binaries by GUID and age' },
    @{ Pattern = '(?s)\$missing = .*?\$unexpected = .*?\$missing\.Count -gt 0 -or \$unexpected\.Count -gt 0.*?asset set mismatch'; Description = 'published verifier rejects missing and unexpected assets' },
    @{ Pattern = '(?s)Get-FileSha256Lower.*?\$digest = .*?\$digest -notmatch.*?\$actualHash -ne \$digest\.Substring\(7\)\.ToLowerInvariant\(\).*?digest mismatch'; Description = 'published verifier compares downloaded bytes with GitHub SHA-256 digests' },
    @{ Pattern = 'SequenceEqual'; Description = 'published verifier preserves byte-identical legacy x64 checksum alias' },
    @{ Pattern = '(?s)\$checksums\.Count -ne \$expectedChecksumNames\.Count.*?\$checksums\.Contains\(\$_\).*?\$checksums\[\$name\] -ne \$actualHash'; Description = 'published verifier enforces exact checksum names, count, and hashes' },
    @{ Pattern = '(?s)\$signatureEvidence\.Add\(\(Assert-ReleaseSignature.*?Setup \$architecture.*?Portable manifest \$architecture.*?Assert-PortableManifestMatchesPayload.*?foreach \(\$relativePath.*?\$signatureEvidence\.Add\(\(Assert-ReleaseSignature.*?\$signedAssetsPerArchitecture = if \(\$requiresPortableManifests\) \{ 2 \} else \{ 1 \}.*?\$expectedSignatureCount =.*?@\(Get-WindowsPackageArchitectures\)\.Count \*.*?\(\$signedAssetsPerArchitecture \+ @\(Get-WindowsSignedRuntimePayloads\)\.Count\).*?\$signatureEvidence\.Count -ne \$expectedSignatureCount'; Description = 'published verifier validates two manifests plus a derived count of every signed portable PE while preserving pre-manifest releases' },
    @{ Pattern = '(?s)gh attestation verify \$Path.*?--repo \$Repository.*?--signer-workflow.*?release\.yml'; Description = 'published verifier binds provenance to the canonical release workflow' },
    @{ Pattern = '(?s)\$expectedAttestationNames = @\(\$expectedNames \| Where-Object \{ \$_ -ne ''koreterm-icon\.svg'' \}\).*?foreach \(\$asset in \$assets\).*?\$expectedAttestationNames -contains \[string\]\$asset\.name.*?\$expectedAttestationNames\.Count -ne \$expectedAttestationCount.*?\$attestationEvidenceCount -ne \$expectedAttestationNames\.Count'; Description = 'published verifier binds the exact non-icon asset names (nine, eleven with symbols) to attestation evidence' },
    @{ Pattern = '\$expectedAttestationCount = \$expectedAssetCount - 1'; Description = 'published verifier attests every asset but the static icon' },
    @{ Pattern = '(?s)\$thumbprints\.Count -ne 1 -or \$pins\.Count -ne 1.*?one consistent certificate'; Description = 'published verifier requires one consistent signer after shared updater-pin verification' },
    @{ Pattern = "Get-WindowsSignedRuntimePayloads"; Description = 'published verifier checks every packaged runtime PE for both architectures' },
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
