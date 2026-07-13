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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "winghostty-signing-trust-$([Guid]::NewGuid().ToString('N'))"
[System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.KeySize = 2048
$certificate = $null
try {
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=winghostty signing policy test',
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
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
}
finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    $rsa.Dispose()
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'signing trust policy tests: PASS' -ForegroundColor Green
