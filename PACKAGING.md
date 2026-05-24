# Packaging winghostty for Distribution

This repository publishes Windows user artifacts directly from GitHub Releases.
The public packaging targets are:

- `winghostty-<version>-windows-x64-setup.exe`
- `winghostty-<version>-windows-x64-portable.zip`
- `winghostty-<version>-windows-arm64-setup.exe`
- `winghostty-<version>-windows-arm64-portable.zip`
- `SHA256SUMS-windows-x64.txt`
- `SHA256SUMS-windows-arm64.txt`
- `SHA256SUMS.txt` legacy alias for existing x64 auto-update clients

Primary distribution URL:

```text
https://github.com/amanthanvi/winghostty/releases
```

## Release Inputs

winghostty releases use plain semver tags such as `v1.3.100`.

Release versioning standard:

- `major.minor` track the Ghostty upstream compatibility line
- `patch` is the winghostty release number on that line
- fork releases should start at patch `100` for a new upstream line

The exact upstream base release is stored in
`dist/windows/release-metadata.json`. For example, a release tagged
`v1.3.105` can still declare `upstreamBaseVersion = 1.3.2`.

The release workflow builds the Windows executable, stages runtime files, then
produces:

1. An Inno Setup installer
2. A portable ZIP
3. SHA256 checksums for published assets
4. A release icon asset
5. Generated package-manager metadata

Local unsigned packaging is still allowed for smoke validation, but the GitHub
Release workflow requires signing and fails closed when signing is absent. The
release installer and Windows PE files inside the portable ZIP are
Authenticode-signed; the ZIP container itself is checksummed, not
Authenticode-signed. SmartScreen and publisher trust should still be treated as
incomplete until winghostty moves from internal/self-signed signing to a
publicly trusted certificate.

## Local Packaging

Build the app first:

```powershell
zig build -Demit-exe=true
```

If Zig cannot hydrate its dependency cache automatically in your environment,
seed the Windows build dependency cache first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
zig build -Demit-exe=true
```

Then stage release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1 -Version 1.3.100
```

On Windows ARM64 hosts, the packaging script defaults to ARM64. Pass
`-Architecture x64` or `-Architecture arm64` explicitly when you need a
specific target.

If Inno Setup is available on the machine, the packaging script can also build
the installer. If it is not installed, the portable artifact and checksums are
still produced so packaging can be validated locally.

To exercise the local signing path, export these environment variables first:

```powershell
$env:WINDOWS_CODESIGN_PFX_PATH = "C:\secure\winghostty-signing.pfx"
$env:WINDOWS_CODESIGN_PFX_PASSWORD = "<pfx-password>"
$env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED = "true" # only for internal/self-signed PFXs
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1 `
  -Version 1.3.100 `
  -RequireInstaller `
  -RequireSigning
```

To generate the package-manager metadata from staged release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-package-managers.ps1 `
  -Version 1.3.100 `
  -Architectures @("x64", "arm64") `
  -UpstreamBaseVersion 1.3.2 `
  -FirstForkPatch 100
```

This emits:

- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/scoop/`
- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/metadata.json`

## Release Automation

The release workflow publishes to the official Windows package-manager tracks
after the GitHub Release is live. The preflight fails closed unless signing is
configured and both remote package-manager manifests already exist.

Release metadata comes from the committed `dist/windows/release-metadata.json`
file, so the release tag, generated package-manager metadata, and GitHub release
notes all agree on the current upstream base.

Automated releases should use a dedicated GitHub Actions environment named
`release`. The workflow now resolves signing secrets from that environment
or the repo default secret scope and runs `scripts/release-preflight.ps1`
before build/test/package work starts.

### Authenticode Signing

Required for the GitHub `Release` workflow:

- Secret: `WINDOWS_CODESIGN_PFX_BASE64`
- Secret: `WINDOWS_CODESIGN_PFX_PASSWORD`

Optional:

- Environment or repo variable: `WINDOWS_CODESIGN_TIMESTAMP_URL`
  Default: `http://timestamp.digicert.com`
- Environment or repo variable: `WINDOWS_CODESIGN_TRUST_SELF_SIGNED`
  Default: unset / false

Recommended setup:

1. Export a password-protected `.pfx` that contains the private key and full
   certificate chain for the Windows code-signing identity.
2. Base64-encode that file locally.
3. Store the base64 and password in the `release` environment, not plain repo
   scope, so release signing stays isolated from unrelated workflows.

Example `gh` commands:

```powershell
$repo = "amanthanvi/winghostty"
$pfxPath = "C:\secure\winghostty-signing.pfx"
$pfxBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfxPath))

$pfxBase64 | gh secret set WINDOWS_CODESIGN_PFX_BASE64 --repo $repo --env release
gh secret set WINDOWS_CODESIGN_PFX_PASSWORD --repo $repo --env release --body "<pfx-password>"
gh variable set WINDOWS_CODESIGN_TIMESTAMP_URL --repo $repo --env release --body "http://timestamp.digicert.com"
gh variable set WINDOWS_CODESIGN_TRUST_SELF_SIGNED --repo $repo --env release --body "true"
```

If you prefer a different RFC 3161/Authenticode timestamp service, set
`WINDOWS_CODESIGN_TIMESTAMP_URL` explicitly. The packaging script will default
to DigiCert when the variable is absent.

When `WINDOWS_CODESIGN_TRUST_SELF_SIGNED=true`, signature validation accepts
the expected self-signed signer thumbprint plus the narrow untrusted-root
statuses reported by `Get-AuthenticodeSignature`. This keeps
internal/self-signed release probes green on the current runner. It does not
create public publisher trust on other machines.

### Release Runbook

Recommended order:

1. Update `dist/windows/release-metadata.json` if the upstream compatibility
   line or `firstForkPatch` changed.
2. Configure or rotate the `release` environment signing secrets.
3. Run the **Release Readiness** workflow with the target plain semver
   version, for example `1.3.107`.
4. After readiness passes, either:
   - push tag `v<version>`, or
   - manually dispatch the **Release** workflow with `version=<version>`.
5. Confirm the workflow published:
   - installer
   - portable ZIP
   - `SHA256SUMS.txt`
   - GitHub Release notes/assets
6. Confirm follow-on publishes:
   - Scoop manifest update
   - WinGet submission

If a tag already exists and the workflow failed before publish, configure the
missing signing secrets and then rerun the failed `Release` workflow or
manually dispatch **Release** with the same version. The workflow is idempotent
for release creation/upload because it uses `gh release create` on first
publish and `gh release upload --clobber` on reruns.

### WinGet

- Secret: `WINGETCREATE_TOKEN`
- Repo variable: `WINGET_PACKAGE_IDENTIFIER`
- Current automation path: `wingetcreate update ... --submit`

The official WinGet package is bootstrapped as `AmanThanvi.winghostty`.
Release preflight verifies that
`microsoft/winget-pkgs/manifests/a/AmanThanvi/winghostty` exists before the
release workflow can claim package-manager readiness. Keep CI on the truthful
`update` path; do not switch to `wingetcreate new` for automated releases.

### Scoop

- Secret: `SCOOP_BUCKET_TOKEN`
- Repo variable: `SCOOP_BUCKET_REPO`
- Optional repo variables: `SCOOP_BUCKET_BRANCH`, `SCOOP_BUCKET_MANIFEST_PATH`

The workflow updates a manifest in a configured Scoop bucket repository. It
does not attempt to auto-open PRs against `ScoopInstaller/Extras`; that path is
review-driven and should stay explicit.

The official Scoop track is the fork-owned bucket:

```powershell
scoop bucket add winghostty https://github.com/amanthanvi/scoop-winghostty
scoop install winghostty/winghostty
```

Release preflight verifies that the configured manifest exists, defaulting to
`bucket/winghostty.json` when `SCOOP_BUCKET_MANIFEST_PATH` is unset.

## Zig Version

This repo is pinned to Zig `0.15.2` in CI. Packaging should use the same Zig
version unless the repo is intentionally updated to a newer one.

## Library Consumers

`libghostty-vt` remains intentionally retained and keeps its existing public
name. The app binary and Windows packaging are rebranded to `winghostty`, but
the library surface is not being renamed as part of this packaging cleanup.
