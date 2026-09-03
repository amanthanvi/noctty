# Code signing policy

This page states who signs Noctty releases, where the signing key lives, what
is signed, how you can check it, and what happens if the key is compromised.
It describes the project as it is today. Where a decision has been made but not
yet carried out, it says so.

## Who may sign

Aman Thanvi (GitHub `amanthanvi`), the sole maintainer, is the only person who
may sign a Noctty release. No other person, organisation, or automated system
is authorised to sign anything under the Noctty name.

Signing only happens inside the `Release` GitHub Actions workflow
(`.github/workflows/release.yml`) on a GitHub-hosted `windows-latest` runner,
triggered by a `v*` tag push or a manual dispatch by the maintainer. That job
runs in the repository's `release` environment, which is where the signing
secrets live; no other workflow in the repository can read them. There is no
local signing path for published artifacts: a build signed on a workstation is
not a Noctty release.

## Where the key lives

Today the release identity is a **self-signed** certificate,
`CN=winghostty Local Dev Signing` (the subject predates the project's rename
and is kept because the trust anchor is the key, not the name), valid until
2029-04-30. Its private key exists as a password-protected PFX held by the
maintainer offline and as two GitHub Actions secrets in the `release`
environment, `WINDOWS_CODESIGN_PFX_BASE64` and
`WINDOWS_CODESIGN_PFX_PASSWORD`. It is not in the repository, not in any
container image, and not on any always-on machine.

Because the certificate is self-signed, Windows shows no publisher identity
and SmartScreen warns on first run. That warning does not fade over time.
Noctty compensates with a key pin rather than pretending otherwise: the SPKI
SHA-256 of the signing key is compiled into the application
(`pinned_publisher_spki_sha256` in `src/update/github_releases.zig`), and both
the in-app updater and the release verifier refuse an artifact signed by any
other key.

| Field               | Value                                                              |
| ------------------- | ------------------------------------------------------------------ |
| Certificate subject | `CN=winghostty Local Dev Signing`                                  |
| SPKI SHA-256        | `671ec822c41f39b1d79c31d27169b37486333c008c7a038261b4fae53818ce2a` |

**Planned, not yet done.** The project intends to move to a certificate from a
publicly trusted certificate authority; the options and the recommendation are
in [ADR 0006](adr/0006-code-signing-certificate-decision.md). Under that
arrangement the private key would be non-exportable and held in a
FIPS-validated hardware or cloud key store operated by the issuing service,
not in a PFX, and the GitHub Actions secrets would be signing-service
credentials rather than a key. Until that migration ships, everything above
describes the live state. The migration itself follows
[the rotation runbook](signing-rotation-runbook.md).

## What is signed

For each release and each architecture (`x64`, `arm64`):

- the installer, `noctty-<version>-windows-<arch>-setup.exe`
- every `.exe`, `.com`, and `.dll` inside the portable tree
- the portable payload manifest,
  `noctty-<version>-windows-<arch>-portable.manifest.ps1`

The portable ZIP container itself is not Authenticode-signed — a ZIP cannot
carry an Authenticode signature — and is covered instead by its published
SHA-256 and by GitHub build-provenance attestation. Nothing else published
under the Noctty name is signed with this key: not source archives, not the
website, not package-manager manifests.

Signatures use SHA-256 (`signtool /fd SHA256`). RFC 3161 timestamping
(`/tr <url> /td SHA256`) is requested whenever a timestamp URL is in effect and
is mandatory for any non-self-signed certificate; release preflight fails
closed if one is missing. The current self-signed releases are deliberately not
timestamped, because the pin, not certificate validity, is what makes them
acceptable.

## How to verify a signature

[docs/verify-release.md](verify-release.md) has the full procedure: checksum,
GitHub build provenance, and the repository verifier that checks every asset's
signature against the compiled pin. The short version is
`scripts/verify-published-release.ps1 -Version <version>`, run from a tag
checkout of this repository.

Verifying by eye is not enough while the certificate is self-signed: Windows
will report the signature as untrusted, and `Get-AuthenticodeSignature` may
report `UnknownError`. Compare the signer's SPKI SHA-256 against the value
above, or let the verifier do it.

## Reporting a problem

Report a suspected key compromise, a signed artifact you cannot account for, or
any other signing problem through the process in
[SECURITY.md](../SECURITY.md). Do not open a public issue for a suspected
compromise.

## Revocation

There is nothing to revoke today: a self-signed certificate has no issuer to
revoke it, and no CRL or OCSP responder that Windows would consult. The
project's revocation mechanism is the pin. If the current key were
compromised, the response would be to withdraw the affected releases from the
release page, publish a security advisory naming the affected versions, and
ship a release that simultaneously adds the replacement key's pin and removes
the compromised one. That deliberately strands anyone still on a compromised
build: they must reinstall by hand, which is the intended outcome, because
in-place update from a compromised build cannot be trusted.

Once the certificate is CA-issued, revocation through the CA is added to that
list and becomes the step that protects users who never update, but it does
not replace any of it: a revoked certificate does not remove installers from
the release page, and revocation does not invalidate a signature that carries a
valid RFC 3161 timestamp from before the revocation date unless the CA
back-dates it. Pin removal remains the mechanism that stops the in-app updater.

## Changes to this policy

This page is version-controlled in the Noctty repository. Every change to it
goes through a pull request against `main` and is visible in that file's git
history.
