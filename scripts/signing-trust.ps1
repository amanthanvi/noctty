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

function Initialize-WinghosttyAuthenticodeVerifier {
    if ('WinghosttyAuthenticodeVerifier' -as [type]) {
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

public static class WinghosttyAuthenticodeVerifier
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
        out IntPtr ppvContext);

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
        IntPtr context = IntPtr.Zero;
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
                    out context))
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
    Initialize-WinghosttyAuthenticodeVerifier
    return [WinghosttyAuthenticodeVerifier]::VerifyEmbeddedSignatureAndFileHash(
        [System.IO.Path]::GetFullPath($Path)
    )
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
