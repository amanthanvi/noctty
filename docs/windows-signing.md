# Signing and SmartScreen (C28)

Installers and the PE files inside the portable ZIP are Authenticode
signed. The ZIP container itself is checksummed, not catalog-signed.

## Reputation

Microsoft no longer grants instant SmartScreen reputation for EV
certificates (2024). Reputation accrues per file hash. A new release
hash can warn even when the publisher is signed.

Pursuit path: SignPath Foundation (or equivalent OSS signing) plus
consistent publisher identity across every release so hashes accrue
under one publisher. Self-signed local-dev certs are for developers
only; they will always show as untrusted until imported.

## Verification

```powershell
Get-FileHash -Algorithm SHA256 .\winghostty-*-setup.exe
Get-AuthenticodeSignature .\zig-out\bin\winghostty.exe
```

Match the SHA-256 against `SHA256SUMS-windows-<arch>.txt` on the
GitHub Release. See [trust.md](trust.md).
