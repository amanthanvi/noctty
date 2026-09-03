[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'signing-trust.ps1')

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)] [scriptblock] $Script,
        [Parameter(Mandatory)] [string] $Pattern
    )
    try {
        & $Script
    }
    catch {
        if ($_.Exception.Message -notlike $Pattern) {
            throw "Expected error like '$Pattern', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected error like '$Pattern', but the command succeeded."
}

function Set-TestFileByte {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [long] $Offset
    )

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        if ($Offset -lt 0 -or $Offset -ge $stream.Length) {
            throw "Test mutation offset $Offset is outside $Path."
        }
        $stream.Position = $Offset
        $value = $stream.ReadByte()
        $stream.Position = $Offset
        $stream.WriteByte($value -bxor 1)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-PeCertificateTableOffset {
    param([Parameter(Mandatory)] [string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        $optionalHeaderOffset = $peOffset + 24
        $stream.Position = $optionalHeaderOffset
        $magic = $reader.ReadUInt16()
        $dataDirectoryOffset = switch ($magic) {
            0x10b { $optionalHeaderOffset + 96 }
            0x20b { $optionalHeaderOffset + 112 }
            default { throw "Unsupported PE optional-header magic 0x$($magic.ToString('x'))." }
        }
        # IMAGE_DIRECTORY_ENTRY_SECURITY is directory index 4. Its address is
        # a file offset rather than an RVA.
        $stream.Position = $dataDirectoryOffset + (4 * 8)
        $certificateTableOffset = $reader.ReadUInt32()
        if ($certificateTableOffset -eq 0) {
            throw "Signed test PE has no certificate table: $Path"
        }
        return [long]$certificateTableOffset
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "noctty-signing-trust-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$certificate = $null
try {
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=noctty signing policy test',
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $codeSigningOids = [System.Security.Cryptography.OidCollection]::new()
    [void]$codeSigningOids.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
            $codeSigningOids,
            $false
        )
    )
    $created = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(365))
    try {
        $pfxBytes = $created.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'test-password')
    }
    finally {
        $created.Dispose()
    }
    $certificate = Import-CodeSigningCertificate -PfxBase64 ([Convert]::ToBase64String($pfxBytes)) -Password 'test-password'
    $pin = Get-CertificateSpkiSha256 -Certificate $certificate
    $pinBytes = for ($offset = 0; $offset -lt $pin.Length; $offset += 2) { "0x$($pin.Substring($offset, 2))" }
    $updaterSource = Join-Path $tempRoot 'github_releases.zig'
    @"
const pinned_publisher_spki_sha256 = [_][Sha256.digest_length]u8{
    .{
        $($pinBytes -join ', '),
    },
};
"@ | Set-Content -LiteralPath $updaterSource -Encoding utf8NoBOM

    $policy = Assert-CodeSigningCertificatePolicy `
        -Certificate $certificate `
        -UpdaterSourcePath $updaterSource `
        -MinimumValidityDays 180
    if ($policy.SpkiSha256 -ne $pin -or -not $policy.SelfSigned) {
        throw 'Matching signer policy returned inconsistent metadata.'
    }

    $mismatchSource = Join-Path $tempRoot 'mismatch.zig'
    (Get-Content -LiteralPath $updaterSource -Raw).Replace($pinBytes[0], $(if ($pinBytes[0] -eq '0x00') { '0x01' } else { '0x00' })) |
        Set-Content -LiteralPath $mismatchSource -Encoding utf8NoBOM
    Assert-ThrowsLike -Pattern '*absent from the updater publisher-pin allowlist*' -Script {
        Assert-CodeSigningCertificatePolicy -Certificate $certificate -UpdaterSourcePath $mismatchSource -MinimumValidityDays 180
    }
    Assert-ThrowsLike -Pattern '*validity days remaining*' -Script {
        Assert-CodeSigningCertificatePolicy -Certificate $certificate -UpdaterSourcePath $updaterSource -MinimumValidityDays 366
    }

    # ADR-0005 overlap: a rotation release compiles the retiring key and the
    # incoming key at the same time, so the parser must return both, in order.
    $rotationPin = 'b3' * 32
    $rotationPinBytes = for ($offset = 0; $offset -lt $rotationPin.Length; $offset += 2) { "0x$($rotationPin.Substring($offset, 2))" }
    $rotationSource = Join-Path $tempRoot 'rotation.zig'
    @"
const pinned_publisher_spki_sha256 = [_][Sha256.digest_length]u8{
    // Retiring key.
    .{
        $($pinBytes -join ', '),
    },
    // Incoming key.
    .{
        $($rotationPinBytes -join ', '),
    },
};
"@ | Set-Content -LiteralPath $rotationSource -Encoding utf8NoBOM

    $rotationPins = @(Get-UpdaterPublisherSpkiPins -SourcePath $rotationSource)
    if ($rotationPins.Count -ne 2) {
        throw "Expected a two-element overlap allowlist, got $($rotationPins.Count) pin(s)."
    }
    if ($rotationPins[0] -ne $pin -or $rotationPins[1] -ne $rotationPin) {
        throw "Two-element pin allowlist parsed incorrectly: $($rotationPins -join ', ')."
    }
    $rotationPolicy = Assert-CodeSigningCertificatePolicy `
        -Certificate $certificate `
        -UpdaterSourcePath $rotationSource `
        -MinimumValidityDays 180
    if ($rotationPolicy.SpkiSha256 -ne $pin) {
        throw 'Overlap allowlist rejected the still-configured signing key.'
    }

    $shortEntrySource = Join-Path $tempRoot 'short-entry.zig'
    @"
const pinned_publisher_spki_sha256 = [_][Sha256.digest_length]u8{
    .{
        $(($rotationPinBytes | Select-Object -First 31) -join ', '),
    },
};
"@ | Set-Content -LiteralPath $shortEntrySource -Encoding utf8NoBOM
    Assert-ThrowsLike -Pattern '*exactly 32 bytes*' -Script {
        Get-UpdaterPublisherSpkiPins -SourcePath $shortEntrySource
    }

    $emptyAllowlistSource = Join-Path $tempRoot 'empty-allowlist.zig'
    @"
const pinned_publisher_spki_sha256 = [_][Sha256.digest_length]u8{
};
"@ | Set-Content -LiteralPath $emptyAllowlistSource -Encoding utf8NoBOM
    Assert-ThrowsLike -Pattern '*must not be empty*' -Script {
        Get-UpdaterPublisherSpkiPins -SourcePath $emptyAllowlistSource
    }

    $signedPath = Join-Path $tempRoot 'signed-host.exe'
    Copy-Item -LiteralPath (Get-Process -Id $PID).Path -Destination $signedPath
    $signedResult = Set-AuthenticodeSignature `
        -LiteralPath $signedPath `
        -Certificate $certificate `
        -HashAlgorithm SHA256 `
        -IncludeChain NotRoot
    $signature = Get-AuthenticodeSignature -LiteralPath $signedPath
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint -or
        -not (Test-SelfSignedTrustStatus -Signature $signature -Path $signedPath)) {
        throw "Cryptographic self-signed verification rejected an intact signed PE: $($signedResult.Status) $($signedResult.StatusMessage)"
    }
    Initialize-NocttyAuthenticodeVerifier
    if (-not [NocttyAuthenticodeVerifier]::VerifyEmbeddedSignatureAndFileHash($signedPath)) {
        throw 'Direct Authenticode verifier rejected an intact signed PE.'
    }

    $bodyTamperedPath = Join-Path $tempRoot 'body-tampered-host.exe'
    Copy-Item -LiteralPath $signedPath -Destination $bodyTamperedPath
    Set-TestFileByte -Path $bodyTamperedPath -Offset 4096
    $bodyTamperedSignature = Get-AuthenticodeSignature -LiteralPath $bodyTamperedPath
    if (Test-SelfSignedTrustStatus -Signature $bodyTamperedSignature -Path $bodyTamperedPath) {
        throw 'Self-signed verification accepted a PE with a modified signed body.'
    }
    if ([NocttyAuthenticodeVerifier]::VerifyEmbeddedSignatureAndFileHash($bodyTamperedPath)) {
        throw 'Direct Authenticode verifier accepted a PE with a modified signed body.'
    }

    $signatureTamperedPath = Join-Path $tempRoot 'signature-tampered-host.exe'
    Copy-Item -LiteralPath $signedPath -Destination $signatureTamperedPath
    $certificateTableOffset = Get-PeCertificateTableOffset -Path $signatureTamperedPath
    Set-TestFileByte -Path $signatureTamperedPath -Offset ($certificateTableOffset + 16)
    $signatureTamperedSignature = Get-AuthenticodeSignature -LiteralPath $signatureTamperedPath
    if (Test-SelfSignedTrustStatus -Signature $signatureTamperedSignature -Path $signatureTamperedPath) {
        throw 'Self-signed verification accepted a PE with a modified PKCS#7 signature.'
    }
    if ([NocttyAuthenticodeVerifier]::VerifyEmbeddedSignatureAndFileHash($signatureTamperedPath)) {
        throw 'Direct Authenticode verifier accepted a PE with a modified PKCS#7 signature.'
    }
}
finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    $rsa.Dispose()
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'signing trust policy tests: PASS' -ForegroundColor Green
