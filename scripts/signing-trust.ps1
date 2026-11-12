function Get-UpdaterPublisherSpkiPins {
    param(
        [Parameter(Mandatory)]
        [string] $SourcePath
    )

    $source = [System.IO.File]::ReadAllText($SourcePath)
    $allowlist = [regex]::Match(
        $source,
        '(?s)const\s+pinned_publisher_spki_sha256\s*=\s*\[_\]\[Sha256\.digest_length\]u8\s*\{(?<body>.*?)\r?\n\};'
    )
    if (-not $allowlist.Success) {
        throw "Could not locate pinned_publisher_spki_sha256 in $SourcePath."
    }

    $pins = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in [regex]::Matches($allowlist.Groups['body'].Value, '(?s)\.\s*\{(?<bytes>.*?)\}')) {
        $hexBytes = @([regex]::Matches($entry.Groups['bytes'].Value, '0x(?<byte>[0-9a-fA-F]{2})'))
        if ($hexBytes.Count -ne 32) {
            throw "Updater publisher pin entry must contain exactly 32 bytes; found $($hexBytes.Count)."
        }
        $pins.Add((($hexBytes | ForEach-Object { $_.Groups['byte'].Value }) -join '').ToLowerInvariant())
    }
    if ($pins.Count -eq 0) {
        throw 'Updater publisher pin allowlist must not be empty.'
    }
    return @($pins)
}

function Get-CertificateSpkiSha256 {
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
    if ($null -eq $key) {
        $key = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($Certificate)
    }
    if ($null -eq $key) {
        throw "Unsupported signing public-key algorithm: $($Certificate.PublicKey.Oid.Value)"
    }

    try {
        $spki = $key.ExportSubjectPublicKeyInfo()
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([Convert]::ToHexString($sha256.ComputeHash($spki))).ToLowerInvariant()
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $key.Dispose()
    }
}

function Initialize-KoretermAuthenticodeVerifier {
    if ('KoretermAuthenticodeVerifier' -as [type]) {
        return
    }

    try {
        Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
    }
    catch {
        # Windows PowerShell 5.1 exposes SignedCms from System.Security.
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    $pkcsAssembly = [System.Security.Cryptography.Pkcs.SignedCms].Assembly.Location

    Add-Type -ReferencedAssemblies $pkcsAssembly -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography.Pkcs;

public static class KoretermAuthenticodeVerifier
{
    private const uint CertQueryObjectFile = 1;
    private const uint CertQueryContentFlagPkcs7SignedEmbed = 0x00000400;
    private const uint CertQueryFormatFlagBinary = 0x00000002;
    private const uint CmsgEncodedMessage = 29;
    private const uint WtdUiNone = 2;
    private const uint WtdChoiceFile = 1;
    private const uint WtdRevocationCheckNone = 0x00000010;
    private const uint WtdHashOnlyFlag = 0x00000200;
    private const uint WtdCacheOnlyUrlRetrieval = 0x00001000;
    private const uint WtdDisableMd2Md4 = 0x00002000;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WintrustFileInfo
    {
        internal uint cbStruct;
        [MarshalAs(UnmanagedType.LPWStr)] internal string pcwszFilePath;
        internal IntPtr hFile;
        internal IntPtr pgKnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WintrustData
    {
        internal uint cbStruct;
        internal IntPtr pPolicyCallbackData;
        internal IntPtr pSIPClientData;
        internal uint dwUIChoice;
        internal uint fdwRevocationChecks;
        internal uint dwUnionChoice;
        internal IntPtr pFile;
        internal uint dwStateAction;
        internal IntPtr hWVTStateData;
        internal IntPtr pwszURLReference;
        internal uint dwProvFlags;
        internal uint dwUIContext;
        internal IntPtr pSignatureSettings;
    }

    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptQueryObject(
        uint dwObjectType,
        [MarshalAs(UnmanagedType.LPWStr)] string pvObject,
        uint dwExpectedContentTypeFlags,
        uint dwExpectedFormatTypeFlags,
        uint dwFlags,
        out uint pdwMsgAndCertEncodingType,
        out uint pdwContentType,
        out uint pdwFormatType,
        out IntPtr phCertStore,
        out IntPtr phMsg,
        IntPtr ppvContext);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgGetParam(
        IntPtr hCryptMsg,
        uint dwParamType,
        uint dwIndex,
        IntPtr pvData,
        ref uint pcbData);

    [DllImport("crypt32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptMsgClose(IntPtr hCryptMsg);

    [DllImport("crypt32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CertCloseStore(IntPtr hCertStore, uint dwFlags);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern int WinVerifyTrust(
        IntPtr hwnd,
        [In] ref Guid pgActionID,
        ref WintrustData pWVTData);

    public static bool VerifyEmbeddedSignatureAndFileHash(string path)
    {
        IntPtr certificateStore = IntPtr.Zero;
        IntPtr message = IntPtr.Zero;
        try
        {
            uint encoding;
            uint contentType;
            uint formatType;
            if (!CryptQueryObject(
                    CertQueryObjectFile,
                    path,
                    CertQueryContentFlagPkcs7SignedEmbed,
                    CertQueryFormatFlagBinary,
                    0,
                    out encoding,
                    out contentType,
                    out formatType,
                    out certificateStore,
                    out message,
                    IntPtr.Zero))
            {
                return false;
            }

            uint encodedSize = 0;
            if (!CryptMsgGetParam(message, CmsgEncodedMessage, 0, IntPtr.Zero, ref encodedSize) ||
                encodedSize == 0)
            {
                return false;
            }

            IntPtr encoded = Marshal.AllocCoTaskMem((int)encodedSize);
            try
            {
                if (!CryptMsgGetParam(message, CmsgEncodedMessage, 0, encoded, ref encodedSize))
                {
                    return false;
                }
                byte[] bytes = new byte[encodedSize];
                Marshal.Copy(encoded, bytes, 0, (int)encodedSize);
                SignedCms signedCms = new SignedCms();
                signedCms.Decode(bytes);
                // Verify the PKCS#7 signer without imposing machine trust roots.
                signedCms.CheckSignature(true);
            }
            finally
            {
                Marshal.FreeCoTaskMem(encoded);
            }

            WintrustFileInfo fileInfo = new WintrustFileInfo
            {
                cbStruct = (uint)Marshal.SizeOf(typeof(WintrustFileInfo)),
                pcwszFilePath = path,
                hFile = IntPtr.Zero,
                pgKnownSubject = IntPtr.Zero,
            };
            IntPtr fileInfoPointer = Marshal.AllocCoTaskMem(Marshal.SizeOf(typeof(WintrustFileInfo)));
            bool fileInfoMarshalled = false;
            try
            {
                Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);
                fileInfoMarshalled = true;
                WintrustData trustData = new WintrustData
                {
                    cbStruct = (uint)Marshal.SizeOf(typeof(WintrustData)),
                    dwUIChoice = WtdUiNone,
                    fdwRevocationChecks = 0,
                    dwUnionChoice = WtdChoiceFile,
                    pFile = fileInfoPointer,
                    dwProvFlags = WtdRevocationCheckNone |
                        WtdHashOnlyFlag |
                        WtdCacheOnlyUrlRetrieval |
                        WtdDisableMd2Md4,
                };
                Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
                return WinVerifyTrust(new IntPtr(-1), ref action, ref trustData) == 0;
            }
            finally
            {
                if (fileInfoMarshalled)
                {
                    Marshal.DestroyStructure(fileInfoPointer, typeof(WintrustFileInfo));
                }
                Marshal.FreeCoTaskMem(fileInfoPointer);
            }
        }
        catch
        {
            return false;
        }
        finally
        {
            if (message != IntPtr.Zero) CryptMsgClose(message);
            if (certificateStore != IntPtr.Zero) CertCloseStore(certificateStore, 0);
        }
    }
}
'@
}

function Test-SelfSignedTrustStatus {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Signature] $Signature,
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) {
        return $true
    }
    if ($Signature.Status -eq [System.Management.Automation.SignatureStatus]::NotTrusted) {
        return $true
    }
    if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::UnknownError -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    Initialize-KoretermAuthenticodeVerifier
    return [KoretermAuthenticodeVerifier]::VerifyEmbeddedSignatureAndFileHash(
        [System.IO.Path]::GetFullPath($Path)
    )
}

function Assert-ReleaseSignature {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string[]] $AllowedPins,

        [Parameter(Mandatory)]
        [bool] $TrustSelfSigned
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $certificate = $signature.SignerCertificate
    if ($null -eq $certificate) {
        throw "$Label has no Authenticode signer certificate: $Path"
    }

    $statusAccepted = $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid
    if (-not $statusAccepted -and $TrustSelfSigned -and
        $certificate.Subject -eq $certificate.Issuer -and
        (Test-SelfSignedTrustStatus -Signature $signature -Path $Path)) {
        $statusAccepted = $true
    }
    if (-not $statusAccepted) {
        throw "$Label Authenticode signature is not valid: $($signature.Status) $($signature.StatusMessage)"
    }

    $pin = Get-CertificateSpkiSha256 -Certificate $certificate
    if ($AllowedPins -notcontains $pin) {
        throw "$Label signer SPKI SHA-256 is not allowed: $pin"
    }

    return [pscustomobject]@{
        Label = $Label
        Thumbprint = $certificate.Thumbprint
        SpkiSha256 = $pin
        Status = [string]$signature.Status
    }
}

function Get-ChecksumEntries {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $entries = [ordered]@{}
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, '^(?<hash>[0-9a-fA-F]{64}) \*(?<name>[^\\/]+)$')
        if (-not $match.Success) {
            throw "Malformed checksum line in $Path`: $line"
        }
        $name = $match.Groups['name'].Value
        if ($entries.Contains($name)) {
            throw "Duplicate checksum entry '$name' in $Path."
        }
        $entries[$name] = $match.Groups['hash'].Value.ToLowerInvariant()
    }
    return $entries
}

function Import-CodeSigningCertificate {
    param(
        [string] $PfxBase64,
        [string] $PfxPath,
        [Parameter(Mandatory)]
        [string] $Password
    )

    if (-not [string]::IsNullOrWhiteSpace($PfxBase64) -and -not [string]::IsNullOrWhiteSpace($PfxPath)) {
        throw 'Set only one PFX source.'
    }
    $bytes = if (-not [string]::IsNullOrWhiteSpace($PfxBase64)) {
        try { [Convert]::FromBase64String($PfxBase64) }
        catch { throw "WINDOWS_CODESIGN_PFX_BASE64 is not valid base64: $($_.Exception.Message)" }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PfxPath)) {
        [System.IO.File]::ReadAllBytes($PfxPath)
    }
    else {
        throw 'A PFX source is required.'
    }

    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    try {
        $loaderType = [type]::GetType(
            'System.Security.Cryptography.X509Certificates.X509CertificateLoader, System.Security.Cryptography'
        )
        if ($null -eq $loaderType) {
            throw 'X509CertificateLoader is required; run release preflight with PowerShell 7.5 / .NET 9 or newer.'
        }
        return [System.Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12(
            $bytes,
            $Password,
            $flags,
            [System.Security.Cryptography.X509Certificates.Pkcs12LoaderLimits]::Defaults
        )
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Assert-CodeSigningCertificatePolicy {
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory)]
        [string] $UpdaterSourcePath,
        [ValidateRange(1, 3650)]
        [int] $MinimumValidityDays = 180,
        [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow
    )

    if (-not $Certificate.HasPrivateKey) {
        throw 'Code-signing PFX does not contain a private key.'
    }
    $notBefore = [DateTimeOffset]::new($Certificate.NotBefore.ToUniversalTime())
    $notAfter = [DateTimeOffset]::new($Certificate.NotAfter.ToUniversalTime())
    if ($Now -lt $notBefore -or $Now -ge $notAfter) {
        throw "Code-signing certificate is not currently valid ($notBefore .. $notAfter)."
    }
    $remainingDays = [Math]::Floor(($notAfter - $Now).TotalDays)
    if ($remainingDays -lt $MinimumValidityDays) {
        throw "Code-signing certificate has only $remainingDays validity days remaining; at least $MinimumValidityDays are required."
    }

    $actualPin = Get-CertificateSpkiSha256 -Certificate $Certificate
    $allowedPins = @(Get-UpdaterPublisherSpkiPins -SourcePath $UpdaterSourcePath)
    if ($actualPin -notin $allowedPins) {
        throw "Signing certificate SPKI SHA-256 $actualPin is absent from the updater publisher-pin allowlist. Ship an overlap pin before rotating the signing certificate."
    }

    return [pscustomobject]@{
        Subject = $Certificate.Subject
        Thumbprint = $Certificate.Thumbprint.ToLowerInvariant()
        SpkiSha256 = $actualPin
        NotAfter = $notAfter
        RemainingValidityDays = [int]$remainingDays
        SelfSigned = $Certificate.Subject -eq $Certificate.Issuer
    }
}

# Azure Artifact Signing (ADR 0006) is dormant: it is selected only when the
# release environment defines all of these variables, and otherwise signing
# stays on the PFX path untouched. A partial set, or one next to a PFX or the
# self-signed switch, is a configuration error rather than a fallback, so a
# half-finished migration can never quietly sign with the old key.
$script:ArtifactSigningVariableNames = @(
    'ARTIFACT_SIGNING_ENDPOINT',
    'ARTIFACT_SIGNING_ACCOUNT_NAME',
    'ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME',
    'ARTIFACT_SIGNING_TENANT_ID',
    'ARTIFACT_SIGNING_CLIENT_ID'
)

function Get-ArtifactSigningConfiguration {
    $values = [ordered]@{}
    foreach ($name in $script:ArtifactSigningVariableNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values[$name] = $value.Trim()
        }
    }
    if ($values.Count -eq 0) {
        return $null
    }

    $missing = @($script:ArtifactSigningVariableNames | Where-Object { -not $values.Contains($_) })
    if ($missing.Count -ne 0) {
        throw "Azure Artifact Signing is partly configured; also set: $($missing -join ', ')."
    }
    foreach ($name in @('WINDOWS_CODESIGN_PFX_BASE64', 'WINDOWS_CODESIGN_PFX_PATH', 'WINDOWS_CODESIGN_PFX_PASSWORD', 'WINDOWS_CODESIGN_TRUST_SELF_SIGNED')) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Azure Artifact Signing is configured, so $name must be removed from the release environment."
        }
    }
    # The dlib sends a bearer token to this host; accept only the regional
    # Artifact Signing endpoints Microsoft documents.
    if ($values['ARTIFACT_SIGNING_ENDPOINT'] -notmatch '\Ahttps://[a-z0-9]+\.codesigning\.azure\.net/?\z') {
        throw "ARTIFACT_SIGNING_ENDPOINT must be a regional endpoint such as https://eus.codesigning.azure.net, got '$($values['ARTIFACT_SIGNING_ENDPOINT'])'."
    }
    foreach ($name in @('ARTIFACT_SIGNING_TENANT_ID', 'ARTIFACT_SIGNING_CLIENT_ID')) {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse($values[$name], [ref]$guid)) {
            throw "$name must be a GUID."
        }
    }

    return [pscustomobject]@{
        Endpoint = $values['ARTIFACT_SIGNING_ENDPOINT']
        AccountName = $values['ARTIFACT_SIGNING_ACCOUNT_NAME']
        CertificateProfileName = $values['ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME']
        TenantId = $values['ARTIFACT_SIGNING_TENANT_ID']
        ClientId = $values['ARTIFACT_SIGNING_CLIENT_ID']
    }
}

# Artifact Signing issues a new leaf certificate every day, so the updater's
# leaf-SPKI pin rejects every installer it signs. ADR 0006 replaces that pin
# with the issuing PCA plus the subscriber's 1.3.6.1.4.1.311.97.* EKU, and the
# change that teaches the updater (and Assert-ReleaseSignature) that rule
# declares pinned_publisher_artifact_signing_ekus. Until a release carrying it
# has shipped, signing with Artifact Signing would strand every install.
function Assert-UpdaterAcceptsArtifactSigning {
    param(
        [Parameter(Mandatory)]
        [string] $UpdaterSourcePath
    )

    $source = [System.IO.File]::ReadAllText($UpdaterSourcePath)
    if ($source -notmatch '\bpinned_publisher_artifact_signing_ekus\b') {
        throw "The updater does not accept Azure Artifact Signing yet: $UpdaterSourcePath pins only the leaf key and declares no pinned_publisher_artifact_signing_ekus, so every installed copy would reject this release. Ship the ADR 0006 pin rule in a release signed by the current key first (docs/artifact-signing-runbook.md, step 8)."
    }
}
