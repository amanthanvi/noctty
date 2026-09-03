# Code signing certificate decision

Noctty releases are signed with a self-signed certificate
(`CN=winghostty Local Dev Signing`, valid to 2029-04-30). That gives a valid
cryptographic signature and, through the SPKI pin described in
[ADR 0005](0005-pin-updater-publisher-public-keys.md), a real trust anchor for
the in-app updater. It gives no Windows publisher identity. Closing that gap
needs a certificate the repository cannot produce, so this record picks which
one to get. Every fact below was checked on 2026-09-03; each is cited.

## The thing none of the options buy

No option removes the SmartScreen warning on day one. Microsoft states that
Azure Artifact Signing "does **not** provide instant SmartScreen trust" and
that reputation "can take several weeks and hundreds of clean installs from a
wide audience", and that "EV certificates no longer bypass SmartScreen ... this
behavior no longer exists", a change its comparison table dates to 2024
(<https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation>,
<https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options>,
both checked 2026-09-03). Microsoft's own table rates SmartScreen behaviour
identically for Azure Artifact Signing and a purchased OV certificate. So this
decision is about publisher identity, cost, and what it does to the release
pipeline — not about making the warning go away faster.

## The options

**Azure Artifact Signing** was renamed from Azure Trusted Signing (and before
that Azure Code Signing) during 2026; the docs are at `/azure/artifact-signing/`,
the client package is `Microsoft.ArtifactSigning.Client`, and the action is
`azure/artifact-signing-action`. An individual developer is eligible, but only
with an Azure billing account whose Account Type is "Individual", only in the
US and Canada, and only on a paid subscription — "Artifact Signing doesn't
support free, trial, or sponsored Azure subscriptions"
(<https://learn.microsoft.com/en-us/azure/artifact-signing/faq>, checked
2026-09-03). Identity validation runs through Microsoft Entra Verified ID with
a third-party verifier and takes 1 to 20 business days, cannot be expedited,
allows three document-upload attempts, and must be renewed on a 60-day window
before it expires
(<https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart>,
<https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-renew-identity-validation>,
checked 2026-09-03). The often-quoted "three years of verifiable history" rule
was an organization-path rule from the 2025 preview and does not appear in the
current docs; it never applied to the individual path, and no Microsoft
statement formally rescinding it was found. The Basic SKU is **$9.99 per month**
for 5,000 signatures per month, $0.005 per signature over that, not pro-rated
and billed from account creation
(<https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/artifact-signing/how-to-change-sku.md>,
corroborated by the code-signing-options page; the rendered pricing page shows
`$-` placeholders, checked 2026-09-03). The certificate subject is the
subscriber's validated legal name plus city, state, and country; custom CN or O
values are not possible and EV is never issued. Signing is `signtool` with the
Artifact Signing dlib rather than a key file:

```
signtool sign /v /debug /fd SHA256 /tr "http://timestamp.acs.microsoft.com" /td SHA256 ^
  /dlib "<dlib bin>\x64\Azure.CodeSigning.Dlib.dll" /dmdf "<path>\metadata.json" <file>
```

verbatim from
<https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations>
(checked 2026-09-03), where `metadata.json` names the regional `Endpoint`, the
`CodeSigningAccountName`, and the `CertificateProfileName`. There is an official
`azure/artifact-signing-action` (v2) that runs on Windows runners only and
authenticates through OIDC workload identity federation via `azure/login`, so no
long-lived secret is stored (<https://github.com/azure/artifact-signing-action>,
checked 2026-09-03). Timestamping is not optional: certificates "are renewed
daily and are valid for only 72 hours".

**SignPath Foundation** costs nothing and is the obvious first thought for an
OSS project, and it is the one this decision rejects most firmly. Three of its
published rules are fatal here, all quoted from
<https://signpath.org/terms.html> (checked 2026-09-03). First, "the code signing
certificate is issued to SignPath Foundation ... SignPath Foundation is the
publisher of the OSS project" — Windows would show a publisher that is not the
maintainer, which is most of what this exercise is trying to obtain. Second,
"every release needs manual approval for signing", so a tag-triggered release
can never complete unattended; the maintainer must click Approve in SignPath's
web UI mid-workflow. Third, signing a modified upstream is allowed only if "the
upstream project publishes signed builds" and the project performs "code reviews
for all changes of the upstream code base" — a solo-maintainer fork does not do
upstream code review, and whether upstream Ghostty publishes signed builds in
the sense SignPath means is not confirmed. On top of that, acceptance is openly
discretionary ("we require a certain verifiable reputation", "there is no
independent arbitration mechanism"), and the certificate's issuing CA, its type,
its term, and whether its key survives renewal are all unstated by SignPath;
Microsoft describes it as OV-level. The public "Code signing policy" page it
requires is worth having regardless, so this branch wrote one anyway:
[docs/code-signing-policy.md](../code-signing-policy.md).

**A purchased OV certificate** is the only option that leaves the current
pinning design untouched, and it is the most expensive and the most awkward to
automate. Since 2023-06-01, CA/Browser Forum Code Signing Baseline Requirements
ballots CSC-13 and CSC-17 require private keys to live in FIPS 140-2 Level 2 or
Common Criteria EAL4+ hardware
(<https://cabforum.org/2022/04/06/ballot-csc-13-update-to-subscriber-key-protection-requirements/>,
<https://cabforum.org/2022/09/27/ballot-csc-17-subscriber-private-key-extension/>,
<https://cabforum.org/working-groups/code-signing/requirements/>, with DigiCert
and SSL.com confirming in their own documentation, checked 2026-09-03). A new
OV certificate therefore cannot be exported as a PFX at all, which retires
`WINDOWS_CODESIGN_PFX_BASE64` as a mechanism no matter which vendor is chosen. The cheapest CI-viable path found is SSL.com OV at $129/year
plus eSigner Tier 1 at $180/year ($309 year one, 240 signatures) with a
first-party GitHub Action; DigiCert OV with KeyLocker is $996/year; Sectigo's
own list price is $715/year. Certum's Open Source certificate is cheapest at
EUR 49-69 but has no official unattended-signing path and names the publisher
"Open Source Developer". Every cloud-signing path except Azure Key Vault stores
a long-lived credential — and for eSigner a TOTP seed — in GitHub Actions
secrets, which is strictly weaker than OIDC.

| Option                        | Year-1 cost | Unattended release | Publisher shown         | Leaf SPKI pin survives |
| ----------------------------- | ----------- | ------------------ | ----------------------- | ---------------------- |
| Azure Artifact Signing, Basic | ~$120       | yes, via OIDC      | maintainer's legal name | no — rotates daily     |
| SignPath Foundation           | $0          | no, manual approve | "SignPath Foundation"   | unconfirmed            |
| SSL.com OV + eSigner Tier 1   | $309        | yes, secret + TOTP | maintainer's legal name | unconfirmed            |
| DigiCert OV + KeyLocker       | $996        | yes, API           | maintainer's legal name | unconfirmed            |

## Decision

Take **Azure Artifact Signing on the Basic SKU**. It is the only option that
puts the maintainer's own validated identity on the signature, keeps the release
workflow unattended, and does so without storing a long-lived signing credential
anywhere — the GitHub OIDC federation the release workflow already has
`id-token: write` for is enough. $120/year is the lowest recurring cost of any
option that satisfies all three.

The price is that it invalidates the pinning design in ADR 0005. Microsoft is
explicit: because certificates are renewed daily, "pinning trust or validation
to an end-entity certificate that uses certificate attributes (for example, the
public key) or a certificate's thumbprint ... isn't durable", and subject DN
values can change too
(<https://learn.microsoft.com/en-us/azure/artifact-signing/concept-certificate-management>,
checked 2026-09-03). Microsoft's prescribed replacement, given for anti-malware
vendors facing the same problem in its FAQ, is to pin the issuing PCA
certificate's TBS hash **and** require the subscriber's unique custom EKU, which
carries the prefix `1.3.6.1.4.1.311.97.` followed by octets unique to the
identity-validation resource. Microsoft never writes the sentence "a new key
pair is generated per renewal"; it states the operational conclusion instead.
Treat the leaf public key as rotating.

## What this implies in the repository

Nothing here is implemented on this branch. It is the work the decision commits
to, read out of the code as it stands.

`src/update/github_releases.zig` — `verifyPinnedPublisherIdentityFromState`
hashes the SPKI of `signer.pasCertChain[0].pCert`, the leaf, and compares it
against `pinned_publisher_spki_sha256`. Under Artifact Signing that comparison
fails within three days of every release. It must become a conjunction: the
issuing PCA, identified from further up the same `pasCertChain`, must match a
pinned hash, **and** the leaf must carry the subscriber's
`1.3.6.1.4.1.311.97.<octets>` EKU, which means parsing extension `2.5.29.37` on
the leaf. Both must be allowlists rather than single values, for the same reason
ADR 0005 made the key pin an allowlist: the PCA will roll over, and the FAQ says
re-creating an identity validation can change the EKU. `certificateSpkiSha256`
and the DER reader beside it already do most of the parsing work.

`scripts/signing-trust.ps1` — `Get-UpdaterPublisherSpkiPins` and
`Assert-ReleaseSignature` mirror the updater's rule and change with it.
`Assert-CodeSigningCertificatePolicy` cannot survive in its current form at all:
it loads a PFX, requires a private key, and demands at least 180 days of
remaining validity, none of which a 72-hour certificate obtained through a dlib
can satisfy. `Import-CodeSigningCertificate` loses its only caller in the
release path.

`scripts/release-preflight.ps1` — the signing gate must move from "inspect the
key before signing" to "inspect the signature after signing", because there is
no key to inspect. `Assert-ReleaseSignature` already performs exactly that check
on produced artifacts and is where the guarantee should live.
`Assert-TimestampUrlConfigured` stays and gets stricter: timestamping becomes
unconditional at `http://timestamp.acs.microsoft.com`, and
`WINDOWS_CODESIGN_TRUST_SELF_SIGNED` — along with the whole self-signed branch
it guards — is deleted. `WINDOWS_CODESIGN_MIN_VALIDITY_DAYS` becomes meaningless.

`scripts/package-windows.ps1` — `Get-SigningConfig` requires a PFX and password
and constructs an `X509Certificate2`; `Invoke-SignFile` passes `/f <pfx>` and
`/p <password>`. Both must gain an Artifact Signing mode that passes `/dlib` and
`/dmdf` and no key material, with `/tr` and `/td SHA256` unconditional rather
than conditional on `TimestampUrl`. The runner also needs SignTool 10.0.2261.755
or newer (the 20348 SDK is documented as unsupported with the dlib), the .NET 8
runtime, and the client tools. Two further points are load-bearing and
**unverified**: the portable payload manifest is signed at line 595 with
`Set-AuthenticodeSignature`, which needs a certificate object holding a private
key that will not exist, so `.ps1` signing must move to `signtool` and be proven
to work against the PowerShell subject-interface package before this backend is
committed to; and `Assert-ValidSignature`'s self-signed branch compares a
thumbprint that now changes daily, so it must compare against the new pin rule
instead.

`release` environment — delete `WINDOWS_CODESIGN_PFX_BASE64`,
`WINDOWS_CODESIGN_PFX_PASSWORD`, and `WINDOWS_CODESIGN_TRUST_SELF_SIGNED`. Add
the Artifact Signing endpoint, signing account name, and certificate profile
name; these are configuration, not secrets, so they belong in environment
variables. Add `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_SUBSCRIPTION_ID`
as variables and configure a federated credential on the Entra application
scoped to this repository's `release` environment — no client secret.
`.github/workflows/release.yml` already declares `id-token: write`. The service
principal needs the Artifact Signing Certificate Profile Signer role.
`WINDOWS_CODESIGN_TIMESTAMP_URL` stays, repointed and mandatory.

The migration itself follows
[the rotation runbook](../signing-rotation-runbook.md): the overlap release
must ship the new pin rule while still signed by the current self-signed key,
because an install that only knows today's leaf-SPKI pin will reject anything
signed by Artifact Signing.

## Owner prerequisite

One thing must happen outside the repository before any of the above is worth
writing: complete Azure Artifact Signing **individual** identity validation on a
paid Azure subscription whose billing account Account Type is "Individual", in
the US or Canada. It takes 1 to 20 business days, cannot be expedited, and
allows three document-upload attempts. Nothing in this repository can substitute
for it, and no code should be written against this decision until it succeeds —
if eligibility fails, the fallback is a purchased OV certificate, which is the
one option that leaves the existing pin design intact.
