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
