# Packaging winghostty for Distribution

This repository publishes Windows user artifacts directly from GitHub Releases.
The public packaging targets are:

- `winghostty-<version>-windows-x64-setup.exe`
- `winghostty-<version>-windows-x64-portable.zip`
- `SHA256SUMS.txt`

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
5. Generated Scoop package-manager metadata

Local unsigned packaging is still allowed for smoke validation, but the GitHub
Release workflow currently requires signing and fails closed when signing is
absent. SmartScreen and publisher trust should still be treated as incomplete
until winghostty moves from internal/self-signed signing to a publicly trusted
certificate.

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

If Inno Setup is available on the machine, the packaging script can also build
the installer. If it is not installed, the portable artifact and checksums are
still produced so packaging can be validated locally.

To generate the package-manager metadata from staged release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-package-managers.ps1 `
  -Version 1.3.100 `
  -UpstreamBaseVersion 1.3.2 `
  -FirstForkPatch 100
```

This emits:

- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/scoop/`
- `dist/artifacts/winghostty-<version>-windows-x64/package-managers/metadata.json`

## Release Automation

The release workflow can optionally publish to Windows package managers after
the GitHub Release is live. Each path is explicit and configuration-gated.

Release metadata comes from the committed `dist/windows/release-metadata.json`
file, so the release tag, generated package-manager metadata, and GitHub release
notes all agree on the current upstream base.

### Authenticode Signing

The release workflow currently reads these inputs:

- Secrets: `WINDOWS_CODESIGN_PFX_BASE64`, `WINDOWS_CODESIGN_PFX_PASSWORD`
- Optional secret: `WINDOWS_CODESIGN_TIMESTAMP_URL`
- Optional repo/environment variable: `WINDOWS_CODESIGN_TRUST_SELF_SIGNED`

For local-only or internal releases, a self-signed PFX is supported. When
`WINDOWS_CODESIGN_TRUST_SELF_SIGNED=true`, the packaging script imports the
signing certificate's public half into `Cert:\CurrentUser\Root` and
`Cert:\CurrentUser\TrustedPublisher` before signature validation. This keeps
`Get-AuthenticodeSignature` green on the current machine/runner without
weakening the release gate.

This does not make the resulting installer or binaries publicly trusted. On
machines that do not trust that self-signed certificate, Windows will still
show an unknown publisher / SmartScreen-style trust warning.

### WinGet

- Secret: `WINGETCREATE_TOKEN`
- Repo variable: `WINGET_PACKAGE_IDENTIFIER`
- Current automation path: `wingetcreate update ... --submit`

As of `wingetcreate v1.12.8.0`, the `new` command still prompts for required
fields such as `PackageIdentifier` and fails in a non-interactive shell when
they are missing. Keep CI on the truthful `update` path after the package
already exists in `microsoft/winget-pkgs`.

For the first bootstrap, run `wingetcreate token -s` once locally, then submit
the current installer interactively with:

```powershell
wingetcreate new --out "$env:TEMP\wingetcreate-bootstrap" --no-open `
  https://github.com/amanthanvi/winghostty/releases/download/v<version>/winghostty-<version>-windows-x64-setup.exe
```

### Scoop

- Secret: `SCOOP_BUCKET_TOKEN`
- Repo variable: `SCOOP_BUCKET_REPO`
- Optional repo variables: `SCOOP_BUCKET_BRANCH`, `SCOOP_BUCKET_MANIFEST_PATH`

The workflow updates a manifest in a configured Scoop bucket repository. It
does not attempt to auto-open PRs against `ScoopInstaller/Extras`; that path is
review-driven and should stay explicit.

## Zig Version

This repo is pinned to Zig `0.15.2` in CI. Packaging should use the same Zig
version unless the repo is intentionally updated to a newer one.

## Library Consumers

`libghostty-vt` remains intentionally retained and keeps its existing public
name. The app binary and Windows packaging are rebranded to `winghostty`, but
the library surface is not being renamed as part of this packaging cleanup.
