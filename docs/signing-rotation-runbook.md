# Rotate the release signing key

The in-app updater refuses any installer whose Authenticode signer public key
is not in the allowlist compiled into `src/update/github_releases.zig`
(`pinned_publisher_spki_sha256`). Changing the signing key therefore changes
what already-installed copies will accept, so the new key has to reach users
_before_ it starts signing releases. That is the overlap procedure in
[ADR 0005](adr/0005-pin-updater-publisher-public-keys.md), written out here as
steps. Every step is an owner action in the `release` environment or an
ordinary pull request; none of it is automated.

Run every command in PowerShell 7.5 or newer. `Import-CodeSigningCertificate`
requires `X509CertificateLoader` (.NET 9) and refuses to run without it. Never
paste a PFX, a PFX password, or a signing account credential into a file, a
log, or a commit.

## Scope

This is the procedure for the signing backend the repository has today: a
PFX loaded from `WINDOWS_CODESIGN_PFX_BASE64`, a leaf-SPKI pin, and the
`signtool /f /p` path in `scripts/package-windows.ps1`. It carries a rotation
to any replacement key that is also delivered as a PFX — which, since
2023-06-01, means a self-signed key or an existing certificate, not a newly
issued OV one.

It is **not**, on its own, the migration to
[ADR 0006](adr/0006-code-signing-certificate-decision.md)'s recommendation.
Azure Artifact Signing has no PFX to load, no stable leaf public key to pin,
and no `/f` argument. Steps 1, 2, and the `release`-secret commands in step 5
do not apply to it. Migrating there needs three repository changes to land
first — the `/dlib` + `/dmdf` signing mode, OIDC credentials in place of the
PFX secrets, and the pin rule rewritten to require the issuing PCA plus the
subscriber's custom EKU — and then steps 3, 4, 6, and 7 carry the rollout, with
"the new pin" meaning that PCA-plus-EKU rule rather than an SPKI hash. ADR 0006
lists those changes; none of them exist yet.

## 0. Before you start

You need the new certificate, and you need the old one to keep working. Do not
revoke or delete the old certificate, and do not let it expire, until step 7.
The old key signs the overlap release; without it, existing installs can never
be updated in place and every user has to reinstall by hand.

## 1. Get the new certificate and its public key

Obtain the certificate per
[ADR 0006](adr/0006-code-signing-certificate-decision.md). Then export the
**public** certificate only (`.cer`). You never need the private key on your
workstation to compute the pin, and with a hardware token or a cloud signing
service you cannot export it at all.

## 2. Compute the new SPKI SHA-256

From a public certificate file:

```powershell
. .\scripts\signing-trust.ps1
$certificate = [System.Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadCertificateFromFile('C:\secure\noctty-next.cer')
try { $pin = Get-CertificateSpkiSha256 -Certificate $certificate; $pin } finally { $certificate.Dispose() }
```

From a PFX, if that is all you have (prompted, never echoed):

```powershell
. .\scripts\signing-trust.ps1
$secure = Read-Host -Prompt 'PFX password' -AsSecureString
$certificate = Import-CodeSigningCertificate `
  -PfxPath 'C:\secure\noctty-next.pfx' `
  -Password ([System.Net.NetworkCredential]::new('', $secure).Password)
try { $pin = Get-CertificateSpkiSha256 -Certificate $certificate; $pin } finally { $certificate.Dispose() }
```

The result is 64 lowercase hex characters. It hashes a public key, so it is
safe to publish; the pin already in `docs/verify-release.md` is the same kind
of value.

**Verify.** The string is 64 hex characters and differs from the current pin.
If it matches, you loaded the old certificate.

## 3. Add the new pin as the second element

Render the pin as Zig bytes in the layout `zig fmt` keeps:

```powershell
0..3 | ForEach-Object {
    $row = $_
    $bytes = 0..7 | ForEach-Object { '0x' + $pin.Substring((($row * 8) + $_) * 2, 2) + ',' }
    '        ' + ($bytes -join ' ')
}
```

Paste the four lines as a **second** `.{ ... }` entry in
`pinned_publisher_spki_sha256`, after the current one, with a comment naming
the certificate subject and its validity window, as the existing entry does.
Keep the current entry: this step adds, it does not replace.

**Verify.**

```powershell
. .\scripts\signing-trust.ps1
Get-UpdaterPublisherSpkiPins -SourcePath .\src\update\github_releases.zig
pwsh -NoProfile -File scripts\check-zig-format.ps1
zig build test -Dtest-filter="publisher"
```

The first command must print exactly two pins, old first. It throws if an
entry is not 32 bytes or the array is empty.

**Skip this step** and sign a release with the new key anyway, and the
updater's `verifyPinnedPublisherIdentityFromState` returns
`UntrustedUpdatePublisher` on every existing install: the download is rejected
and no staged install runs. Preflight catches it earlier —
`Assert-CodeSigningCertificatePolicy` in `scripts/signing-trust.ps1` throws
"Signing certificate SPKI SHA-256 ... is absent from the updater publisher-pin
allowlist" before packaging starts.

## 4. Ship the overlap release, still signed by the old key

Release the two-pin build with the `release` environment unchanged: old PFX,
old password, `WINDOWS_CODESIGN_TRUST_SELF_SIGNED` exactly as it is now. This
release exists only to distribute the new pin.

**Verify.**

```powershell
pwsh -NoProfile -File scripts\release-preflight.ps1 -Version <version> -RequireSigning
pwsh -NoProfile -File scripts\verify-published-release.ps1 -Version <version>
```

Preflight prints `Signer SPKI SHA-256`; it must be the **old** pin. The
published-release verifier reads the allowlist out of
`src/update/github_releases.zig`, so it accepts a release signed by either
pinned key — read the printed SPKI rather than trusting the exit code alone.

**Skip this step** and go straight to the new key, and users on the previous
release have only the old pin compiled in. They can never accept the new
installer and must reinstall by hand. Nothing in the application can recover
from it.

Give this release time to reach installs before step 5. The updater checks at
most once every 24 hours (`throttle_seconds` in
`src/update/github_releases.zig`), and users who turned the check off never see
it at all.

## 5. Switch the `release` environment to the new key

Set the new secrets and clear the self-signed escape hatch. These commands are
the PFX-backed form, and only that form. A hardware-token or
cloud-signing backend has no PFX to encode; under Azure Artifact Signing these
two secrets are deleted rather than replaced, and the endpoint, account name,
certificate profile name, and OIDC federation described in ADR 0006 are set
instead.

```powershell
$repo = "amanthanvi/noctty"
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\secure\noctty-next.pfx")) |
  gh secret set WINDOWS_CODESIGN_PFX_BASE64 --repo $repo --env release
gh secret set WINDOWS_CODESIGN_PFX_PASSWORD --repo $repo --env release
gh variable delete WINDOWS_CODESIGN_TRUST_SELF_SIGNED --repo $repo --env release
gh variable set WINDOWS_CODESIGN_TIMESTAMP_URL --repo $repo --env release --body "http://timestamp.digicert.com"
```

**Verify.** Rerun preflight. `Signer SPKI SHA-256` must now be the new pin,
`Signer identity` must read `CA-issued; updater-pin constrained`, and
`Timestamp URL` must print the URL instead of
`disabled (WINDOWS_CODESIGN_TRUST_SELF_SIGNED is set)`.

**Leave `WINDOWS_CODESIGN_TRUST_SELF_SIGNED` set** and
`scripts/package-windows.ps1` forces `TimestampUrl` to `$null`, so nothing is
timestamped; it then throws "WINDOWS_CODESIGN_TRUST_SELF_SIGNED=true is only
supported for a self-signed PFX" as soon as the certificate's subject and
issuer differ. An untimestamped CA-issued signature stops verifying the day the
certificate expires.

**Clear it but leave no timestamp URL** and `Assert-TimestampUrlConfigured` in
`scripts/release-preflight.ps1` throws before the PFX is loaded at all.

## 6. Release again, signed by the new key

Nothing in the repository changes for this release. It is the first one users
accept through the _second_ pin.

**Verify.** Run `scripts\verify-published-release.ps1 -Version <version>` with
`WINDOWS_CODESIGN_TRUST_SELF_SIGNED` absent from the environment. Once the
certificate is CA-issued the verifier no longer needs that variable, and
`docs/verify-release.md` should stop telling readers to set it.

## 7. Retire the old pin

In a later release, delete the old `.{ ... }` entry so the allowlist holds only
the new key.

**Verify.** `Get-UpdaterPublisherSpkiPins` prints one pin and `zig build test
-Dtest-filter="publisher"` passes. Never delete both: an empty array makes
`verifyPinnedPublisherIdentityFromState` return
`UpdatePublisherPinUnavailable`, which disables verified download and apply
entirely.

**Retire the old pin too early** and anyone who never installed the overlap
release from step 4 is stranded on their current version, because the only
release the updater offers them is signed by a key they do not trust. Wait
until step 4's release has been the recommended download long enough that you
accept stranding whoever is left.

## What rotation does not cover

Revocation. If the private key is compromised, revoking the certificate
invalidates untimestamped signatures made with it, and the pin does not help:
the installers on the release page are still signed by the compromised key and
still match the pin. Handling that means withdrawing the affected releases and
running steps 1-7 with the compromised pin removed in the same release that
adds the replacement, which strands anyone on a compromised build on purpose.
[The signing policy](code-signing-policy.md) states that as policy.
