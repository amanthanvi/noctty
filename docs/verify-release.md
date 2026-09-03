# Verify a release

Every release publishes, for `<arch>` = `x64` and `arm64`:

- `noctty-<version>-windows-<arch>-setup.exe`, the installer
- `noctty-<version>-windows-<arch>-portable.zip`, the portable build
- `noctty-<version>-windows-<arch>-portable.manifest.ps1`, signed hashes of
  every file inside the portable ZIP
- `SHA256SUMS-windows-<arch>.txt`, checksums for the assets above

The installer, the manifest, and the binaries inside the ZIP are
Authenticode-signed. The ZIP container is not; it is covered by its checksum
and by GitHub build provenance.

Three checks answer three different questions. None replaces another.

## 1. Did the bytes arrive intact?

Download the installer or the portable ZIP and the checksum file from the
same release page, then hash the file you downloaded:

```powershell
Get-FileHash .\noctty-<version>-windows-<arch>-setup.exe -Algorithm SHA256
Get-FileHash .\noctty-<version>-windows-<arch>-portable.zip -Algorithm SHA256
```

Compare the result with the matching line in `SHA256SUMS-windows-<arch>.txt`.
On any mismatch, stop: delete the file and download it again.

A checksum proves the file matches the release page. It does not prove who
published it, because whoever could replace the binary could replace the
checksum file next to it.

## 2. Was it built by this repository's release workflow?

For v1.3.124 and later, GitHub attaches build provenance to every release
asset except the static icon. Bind the check to this repository and its
release workflow:

```powershell
gh attestation verify .\noctty-<version>-windows-<arch>-portable.zip `
  --repo amanthanvi/noctty `
  --signer-workflow amanthanvi/noctty/.github/workflows/release.yml
```

## 3. Was it signed by the pinned publisher key?

The repository verifier runs every check above for a whole release: it
downloads each asset, compares GitHub digests and checksum entries, verifies
the provenance attestations, validates the signed portable manifest and its
payload hashes, and requires that every embedded Authenticode signature come
from one signer whose public key matches the pin compiled into the updater.

It accepts v1.3.124 and later. Run it in PowerShell 7:

```powershell
$version = "<1.3.124-or-later>"
git clone --branch "v$version" --depth 1 https://github.com/amanthanvi/noctty.git
Set-Location .\noctty
$env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED = "true"
pwsh .\scripts\verify-published-release.ps1 -Version $version
```

The environment variable is what lets the script accept today's self-signed
certificate. Without it, the script fails closed.

## What the signature does and does not prove

Releases are signed with a self-signed certificate. There is no code-signing
certificate from a public certificate authority, so Windows has no publisher
identity to show and SmartScreen will warn on first run. That warning does not
fade with time.

| Field               | Value                                                              |
| ------------------- | ------------------------------------------------------------------ |
| Certificate subject | `CN=winghostty Local Dev Signing`                                  |
| SPKI SHA-256        | `671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a` |

The subject name predates the Noctty rename and proves nothing by itself. The
pinned public key is the constraint that matters: the in-app updater and the
verifier both refuse an installer signed by any other key. Its rotation rules
are in [ADR 0005](adr/0005-pin-updater-publisher-public-keys.md), and the
operator steps that carry a rotation out are in
[the rotation runbook](signing-rotation-runbook.md).

Who may sign, where the key is held, what is signed, and what would happen if
the key were compromised are in
[the code signing policy](code-signing-policy.md).

PowerShell may report an otherwise valid signature as `UnknownError` because
Windows does not trust the self-signed root. The verifier accepts that case
only when the signature is cryptographically valid and the signer matches the
pin.

## Legacy release v1.3.123

v1.3.123 was the last release under the `winghostty-*` asset layout, and the
verifier above does not accept it. Check its checksum with step 1, then verify
the embedded signatures manually. The block below accepts the installer, the
portable ZIP, or both; for the ZIP it requires exactly the three expected PE
files and rejects any other. It stops before doing anything on Windows
PowerShell 5.1, so run it in PowerShell 7 (`pwsh`).

```powershell
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "Run this block in PowerShell 7 (pwsh)." }
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("noctty-release-verification-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($workRoot) | Out-Null
try {
  $setup = ".\winghostty-1.3.123-windows-<arch>-setup.exe"
  $portable = ".\winghostty-1.3.123-windows-<arch>-portable.zip"
  $targets = [Collections.Generic.List[string]]::new()
  if (Test-Path -LiteralPath $setup) { $targets.Add((Resolve-Path -LiteralPath $setup).Path) }
  if (Test-Path -LiteralPath $portable) {
    $portableRoot = Join-Path $workRoot "portable"
    Expand-Archive -LiteralPath $portable -DestinationPath $portableRoot
    $expectedPortablePe = @("winghostty\winghostty.com", "winghostty\winghostty.exe", "winghostty\ghostty-vt.dll")
    $portablePe = @(
      Get-ChildItem -LiteralPath $portableRoot -File -Recurse -Force | Where-Object {
        $stream = [IO.File]::OpenRead($_.FullName)
        try { $stream.Length -ge 2 -and $stream.ReadByte() -eq 0x4D -and $stream.ReadByte() -eq 0x5A }
        finally { $stream.Dispose() }
      } | ForEach-Object { [IO.Path]::GetRelativePath($portableRoot, $_.FullName) }
    )
    $missingPe = @($expectedPortablePe | Where-Object { $_ -notin $portablePe })
    $unexpectedPe = @($portablePe | Where-Object { $_ -notin $expectedPortablePe })
    if ($missingPe.Count -gt 0 -or $unexpectedPe.Count -gt 0) {
      throw "Portable PE inventory mismatch. Missing: $($missingPe -join ', '); unexpected: $($unexpectedPe -join ', ')."
    }
    foreach ($relativePath in $expectedPortablePe) {
      $targets.Add((Resolve-Path -LiteralPath (Join-Path $portableRoot $relativePath)).Path)
    }
  }
  if ($targets.Count -eq 0) { throw "Download an installer or portable ZIP first." }
  $verifierRoot = Join-Path $workRoot "repository"
  git clone --no-checkout https://github.com/amanthanvi/noctty.git $verifierRoot
  git -C $verifierRoot checkout --detach 5220df49e39c96182cf13150c53c4fd71fbc5b10
  . (Join-Path $verifierRoot "scripts\signing-trust.ps1")
  $expectedSpki = "671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a"
  foreach ($target in $targets) {
    Assert-ReleaseSignature `
      -Path $target `
      -Label (Split-Path $target -Leaf) `
      -AllowedPins @($expectedSpki) `
      -TrustSelfSigned $true | Format-List
  }
} finally {
  if ([IO.Directory]::Exists($workRoot)) { [IO.Directory]::Delete($workRoot, $true) }
}
```

The commit it checks out is pinned so the helper it dot-sources cannot change
underneath you.
