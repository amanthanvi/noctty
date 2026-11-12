# Move release signing to Azure Artifact Signing

[ADR 0006](adr/0006-code-signing-certificate-decision.md) chose Azure Artifact
Signing so that Windows shows the maintainer's verified name instead of an
untrusted self-signed publisher. The release workflow already contains the
signing path, but it is dormant: it does nothing until the `release`
environment defines the variables in step 9, and until then every release is
signed exactly as before, with the self-signed PFX.

The steps are in the order they must happen. Steps 1 to 7 and 9 to 11 are
yours, in the Azure portal and with `gh`. Step 8 is a pull request. Nothing
here creates or stores a secret: the release job signs as its own GitHub OIDC
identity, and every value you put in GitHub is an ordinary variable.

What it costs: the Basic plan is $9.99 a month for 5,000 signatures. A release
signs about 20 files, so the plan covers far more releases than this project
makes. Billing starts when the signing account is created (step 3) and is not
pro-rated. Identity validation takes from minutes to several business days.

What it does not do: it does not remove the SmartScreen warning on day one.
Reputation builds per signing identity over weeks of clean installs, and EV
certificates no longer skip that
([Microsoft](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)).

## 1. Prepare the Azure subscription and billing account

Microsoft's requirements for an individual, as of 2026-10-16
([quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)):

- you live in the United States or Canada;
- the subscription is paid (pay-as-you-go); free, trial and sponsored
  subscriptions are refused
  ([FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq));
- the billing account behind it has Account Type **Individual**, and its legal
  name and sold-to address match the government photo ID you will show in
  step 4. The city, state and country from that address appear in the
  certificate; the street address and email do not.

Check and correct the billing account under **Cost Management + Billing**
before you start: the validation form copies it and cannot be edited.

## 2. Register the resource provider

Azure portal, **Subscriptions**, your subscription, **Resource providers**:
register **Microsoft.CodeSigning**.

## 3. Create the signing account

Search for **Artifact Signing Accounts**, then **Create**:

- a new resource group, for example `koreterm-signing`;
- an account name, 3 to 24 letters and digits, globally unique, for example
  `koretermsigning`;
- a region; note its endpoint, for example East US is
  `https://eus.codesigning.azure.net` (the full table is in the quickstart);
- pricing tier **Basic**.

## 4. Validate your identity

On the new account, **Access control (IAM)**, give yourself the **Artifact
Signing Identity Verifier** role. Then **Identity validations**, choose
**Individual**, **New identity**, **Public**, select the billing account, check
the certificate subject preview, and **Create**.

When the status turns to **Action Required**, open the request, follow the
link, and complete the Verified ID flow on your phone: the verifier scans your
photo ID, then you add the credential to Microsoft Authenticator and share it
with Artifact Signing. The status turns to **Completed** a few minutes after
that. If it asks for more documents, you get three upload attempts.

## 5. Create the certificate profile

On the account, **Certificate profiles**, **Create**, **Public Trust**. Give it
a name (5 to 100 letters and digits, for example `koreterm`) and select your
completed identity validation.

Keep this profile. Its custom EKU (`1.3.6.1.4.1.311.97.` followed by numbers
unique to the profile) is what installed copies of koreterm will trust, and
deleting and recreating the profile gives a new EKU that they will not.

## 6. Let the release job sign

Microsoft Entra ID, **App registrations**, **New registration**: name it
`koreterm-release-signing`, single tenant, no redirect URI. From its overview,
note the **Application (client) ID** and the **Directory (tenant) ID**.

In the app, **Certificates & secrets**, **Federated credentials**, **Add
credential**:

- scenario **GitHub Actions deploying Azure resources**;
- organization `amanthanvi`, repository `koreterm`;
- entity type **Environment**, environment name `release`;
- name `koreterm-release`.

The subject must read `repo:amanthanvi/koreterm:environment:release` and the
audience `api://AzureADTokenExchange`. Do not create a client secret: the
federated credential is the only way in, and only a job running in the
`release` environment of this repository can use it.

On the certificate profile from step 5, **Access control (IAM)**, **Add role
assignment**, role **Artifact Signing Certificate Profile Signer**, member the
`koreterm-release-signing` app.

## 7. Read the profile's EKU

Installed copies of koreterm have to learn the EKU before any release is signed
with it (step 8), so read it once from a signature. On your own machine, give
yourself the **Artifact Signing Certificate Profile Signer** role on the
profile as well, then in PowerShell 7:

This needs the Azure CLI (`az`), the Windows SDK's `signtool.exe`
(10.0.22621.755 or newer) and the .NET 8 runtime or newer. It uses the same
pinned client as the release job:

```powershell
az login
$work = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "koreterm-eku-$(Get-Random)")
$package = Join-Path $work "client.nupkg"
Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.artifactsigning.client/1.0.146/microsoft.artifactsigning.client.1.0.146.nupkg" -OutFile $package
if ([Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($package))) -cne "/G0hG/VDIS6psW23b5t1V/ORIgn0PVAOtGj9w+hkPmAuI4pempfwlW50E2GtHscnz9+5Qz3hbC4mcb7ej2Yn1A==") { throw "client hash mismatch" }
[IO.Compression.ZipFile]::ExtractToDirectory($package, (Join-Path $work "client"))
@{
    Endpoint = "https://eus.codesigning.azure.net"
    CodeSigningAccountName = "koretermsigning"
    CertificateProfileName = "koreterm"
} | ConvertTo-Json | Set-Content (Join-Path $work "metadata.json")
Set-Content (Join-Path $work "probe.ps1") "'koreterm EKU probe'"
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\signtool.exe" | Sort-Object FullName -Descending | Select-Object -First 1
& $signtool.FullName sign /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 /dlib (Join-Path $work "client\bin\x64\Azure.CodeSigning.Dlib.dll") /dmdf (Join-Path $work "metadata.json") (Join-Path $work "probe.ps1")
(Get-AuthenticodeSignature (Join-Path $work "probe.ps1")).SignerCertificate.EnhancedKeyUsageList
```

Use your own endpoint, account and profile names. The list shows the code
signing EKU (`1.3.6.1.5.5.7.3.3`), `1.3.6.1.4.1.311.97.1.0`, and one longer
`1.3.6.1.4.1.311.97.` value: that longer one is the profile's EKU. Remove the
signer role from yourself afterwards; the release job does not need it. The
EKU is not a secret.

## 8. Ship the trust rule in a release signed by the current key

This is a pull request, not configuration. The in-app updater and
`Assert-ReleaseSignature` trust only the pinned leaf key today, and an
Artifact Signing leaf changes every day, so they have to learn ADR 0006's rule:
the issuing PCA plus the profile EKU from step 7, declared in
`src/update/github_releases.zig` as `pinned_publisher_artifact_signing_ekus`.
Release preflight refuses Artifact Signing until that declaration exists.

The same change has to cover every other check that assumes one leaf
certificate:

- `Assert-ReleaseSignature` in `scripts/signing-trust.ps1`, which
  `scripts/release-verify-artifacts.ps1` runs before publishing and
  `scripts/verify-published-release.ps1` runs after;
- `scripts/verify-published-release.ps1` itself, which requires every file of
  a release to share one thumbprint and one public key. A release whose
  signing crosses Artifact Signing's daily renewal carries two leaves from the
  same profile, and that check would fail after the release is already on
  GitHub, before Scoop and WinGet. For Artifact Signing it has to require one
  PCA and one profile EKU instead, and keep the one-leaf rule for PFX
  releases;
- the contracts in `test/windows/flagship/contracts` that pin those checks,
  with a case for two leaves from one profile (accepted) and one for a
  different profile (rejected).

Release that change with the `release` environment untouched, so the self-signed
key signs it and every installed copy accepts it. Give it time to reach
installs before step 9: the updater checks at most once a day, and copies that
never update in place have to reinstall by hand. This is the overlap step of
[the rotation runbook](signing-rotation-runbook.md).

## 9. Switch the `release` environment

```powershell
$repo = "amanthanvi/koreterm"
gh variable set ARTIFACT_SIGNING_ENDPOINT --repo $repo --env release --body "https://eus.codesigning.azure.net"
gh variable set ARTIFACT_SIGNING_ACCOUNT_NAME --repo $repo --env release --body "koretermsigning"
gh variable set ARTIFACT_SIGNING_CERTIFICATE_PROFILE_NAME --repo $repo --env release --body "koreterm"
gh variable set ARTIFACT_SIGNING_TENANT_ID --repo $repo --env release --body "<directory (tenant) ID from step 6>"
gh variable set ARTIFACT_SIGNING_CLIENT_ID --repo $repo --env release --body "<application (client) ID from step 6>"
gh variable set WINDOWS_CODESIGN_TIMESTAMP_URL --repo $repo --env release --body "http://timestamp.acs.microsoft.com"
gh variable delete WINDOWS_CODESIGN_TRUST_SELF_SIGNED --repo $repo --env release
gh secret delete WINDOWS_CODESIGN_PFX_BASE64 --repo $repo --env release
gh secret delete WINDOWS_CODESIGN_PFX_PASSWORD --repo $repo --env release
```

Keep the PFX itself, offline, until the old pin is retired (step 7 of the
rotation runbook): it is how you would roll back.

Preflight fails closed on any half state. With only some of the five variables
set it names the missing ones; with a PFX secret or the self-signed switch
still present it names the one to delete; with an endpoint that is not a
regional `*.codesigning.azure.net` address it refuses it; and without step 8
it says the updater does not accept Artifact Signing yet.

## 10. Check before releasing

Run **Release readiness** (Actions, `release-readiness.yml`, **Run workflow**)
for the next version. Its preflight must print:

```
Signing source:          Azure Artifact Signing (GitHub OIDC)
Signing account:         koretermsigning / koreterm
Timestamp URL:           http://timestamp.acs.microsoft.com
```

## 11. Release

Tag as usual. Each packaging step downloads Microsoft.ArtifactSigning.Client
1.0.146 from nuget.org and refuses it unless its SHA-512 matches the pinned
value. It signs every file through `signtool /dlib` with a fresh OIDC token per
file, deletes the token after each call, and fails if a signature is not valid
or carries no RFC 3161 timestamp.

Afterwards, `scripts\verify-published-release.ps1 -Version <version>` and the
Windows file properties (**Digital Signatures**) should both show your name as
the signer.

## Rolling back

Set `WINDOWS_CODESIGN_PFX_BASE64`, `WINDOWS_CODESIGN_PFX_PASSWORD` and
`WINDOWS_CODESIGN_TRUST_SELF_SIGNED` again as they were, delete the five
`ARTIFACT_SIGNING_*` variables, and release. That works for as long as the
self-signed pin is still in the updater's allowlist.
