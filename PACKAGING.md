# Packaging noctty for distribution

This repository publishes Windows user artifacts directly from GitHub
Releases. The public packaging targets are:

- `noctty-<version>-windows-x64-setup.exe`
- `noctty-<version>-windows-x64-portable.zip`
- `noctty-<version>-windows-x64-portable.manifest.ps1`
- `noctty-<version>-windows-x64-symbols.zip`
- `noctty-<version>-windows-arm64-setup.exe`
- `noctty-<version>-windows-arm64-portable.zip`
- `noctty-<version>-windows-arm64-portable.manifest.ps1`
- `noctty-<version>-windows-arm64-symbols.zip`
- `SHA256SUMS-windows-x64.txt`
- `SHA256SUMS-windows-arm64.txt`
- `SHA256SUMS.txt` legacy alias for existing x64 auto-update clients

Primary distribution URL:

```text
https://github.com/amanthanvi/noctty/releases
```

## Release inputs

noctty releases use plain semver tags such as `v1.3.100`:

- `major.minor` track the Ghostty upstream compatibility line
- `patch` is the noctty release number on that line
- fork releases start at patch `100` for a new upstream line

The exact upstream base release is stored in
`dist/windows/release-metadata.json`. For example, a release tagged
`v1.3.105` can still declare `upstreamBaseVersion = 1.3.2`.

The bundled ConPTY redistributable is independently pinned in
`dist/windows/conpty-redist.json`. The current pin is
`Microsoft.Windows.Console.ConPTY` `1.24.260710001` under the MIT license.
That file records the exact NuGet URL, package SHA256, and the x64/ARM64
archive entry paths and SHA256 values for `conpty.dll` and `OpenConsole.exe`.
The release verification contract in
`test/windows/flagship/Test-VerificationContracts.ps1` independently pins the
same values, so a pin refresh must update both files. The in-app portable
updater embeds `dist/windows/conpty-redist.json` itself
(`src/update/conpty_redist.zig`), so it needs no separate pin refresh.
`zig build` stages the same pair into `zig-out\bin` with the same
`Install-ConPtyRedist`, through `scripts/stage-conpty-redist.ps1`
(`src/build/ConptyRedist.zig`), and keeps the verified package in the Zig
global cache under `noctty-conpty`, so it needs no pin refresh either.

The release workflow builds the Windows executable, stages runtime files,
then produces:

1. An Inno Setup installer
2. A portable ZIP
3. An Authenticode-signed manifest covering every portable payload file
4. A symbols ZIP: the PDBs of the shipped binaries, from the same build
5. SHA256 checksums for published assets
6. A release icon asset
7. Generated package-manager metadata

The symbols ZIP holds one `symbols` folder with `noctty.pdb`,
`noctty-command.pdb` (for `noctty.com`), `ghostty-vt.pdb` and
`noctty-terminal-handoff-proxy.pdb`. Release builds therefore pass
`-Dstrip=false` (`scripts/build-package-windows.ps1` does). Left alone,
that would have grown `noctty.exe` by 2.1 MB and `noctty.com` by 1.4 MB, so
three things keep the shipped binaries the size of a stripped release: frame
pointers are still omitted and unwind tables kept (`src/build/Config.zig`);
`build.zig` adds `-OPT:REF` to lld's `_LINK_` environment variable, because
lld-link defaults to `/OPT:NOREF` when it writes a PDB and Zig has no COFF
switch for it (this is the 2 MB of dead code); and release builds panic with
the message and a trap instead of Zig's default handler (`panic` in
`src/process_shared.zig`), which would drag std.debug's whole symbolizer into
any image that keeps debug info (about 114 KB). The PDBs then describe the
binary users run, and the images are within about 2 KB of a stripped build.
They are not byte-identical: LLVM generates a few dozen instructions
differently when it keeps debug info (99 more in a 3.1 million instruction
`noctty.exe`).
The `noctty.com` measurements above describe the former full console runtime.
It is now a native forwarder (38,400 bytes in the measured x64 ReleaseFast
build) that starts its sibling `noctty.exe`; it does not link the application's
runtime dependencies or `process_shared.zig` panic handler. Its entrypoint uses
`std.debug.no_panic`. The installed filename and `noctty-command.pdb` name stay
the same, and CI caps the forwarder at 128 KiB to catch an accidental runtime link.
The PDBs stay out of the portable ZIP and the installer (the packager stages
an explicit file list). `scripts/symbols-verification.ps1` reads each shipped
PE's CodeView record and the PDB's info stream and requires the same GUID and
age; the packager, `scripts/release-verify-artifacts.ps1` (against the ZIP
that will be published) and `scripts/verify-published-release.ps1` (against the
downloaded release) all run it, and the symbols ZIP is listed in
`SHA256SUMS-windows-<arch>.txt` and attested like the other assets. Release
`SHA256SUMS.txt` is a copy of the x64 file, so it lists the x64 symbols ZIP
too; the in-app updater looks a file up by name and ignores the extra line.
Scoop and WinGet read only the setup and portable entries.

Pass `-RequireSymbols` to make a build without symbols fatal; the Release
workflow always does. Without it, packaging a stripped build warns and omits
the symbols ZIP.

Local unsigned packaging is allowed for smoke validation, but the GitHub
Release workflow requires signing and fails closed when signing is absent.
The release installer, portable payload manifest, and noctty-built Windows PE
files inside the portable ZIP are Authenticode-signed; the pinned Microsoft
`conpty.dll` and `OpenConsole.exe` remain byte-for-byte vendor artifacts and
are not re-signed. Because they cannot satisfy the updater's publisher pin,
the release verifier and the in-app portable updater both check them against
their `dist/windows/conpty-redist.json` SHA-256 and Microsoft's own signature
instead. The ZIP container itself is checksummed and bound to the
canonical release workflow by a GitHub build provenance attestation. Every
published asset except the static icon is attested.

Before publication, the Release workflow updates Microsoft Defender
signatures and scans both setup artifacts plus the twelve PE files extracted from
the portable ZIPs, with remediation disabled. A missing or inactive scanner,
update or scan error, or detection fails the release. This is a current-engine
regression gate for the published Windows executable bytes; it does not replace
a publicly trusted signing identity or reproduce every enterprise security
policy.

## Local packaging

Build the app first:

```powershell
zig build -Demit-exe=true
```

x64 packaging also requires LLVM's `llvm-objdump` on `PATH` or in the
standard LLVM installation directory. The packaging gate disassembles every
noctty-built runtime PE and rejects AMD-only SSE4a instructions so published x64 builds
retain the documented baseline CPU compatibility. Executable PE sections are
treated as code; intentional constants must remain in non-executable sections.

If Zig cannot hydrate its dependency cache automatically in your
environment, seed the Windows build dependency cache first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
zig build -Demit-exe=true
```

Then stage release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1 -Version 1.3.100
```

The packager builds with `-Dstrip=false`. To package an existing build with
`-SkipBuild`, build it the same way
(`zig build -Demit-exe=true -Demit-lib-vt=true -Doptimize=ReleaseFast -Dstrip=false ...`),
or the symbols ZIP is skipped with a warning (`-RequireSymbols` makes that
fatal).

The packaging script caches the verified NuGet package outside the source tree
under `%LOCALAPPDATA%\noctty\cache\conpty\<version>`. A valid cached package is
re-hashed on every use and supports offline packaging. If no valid cache exists
and the download fails, local packaging warns clearly, omits the bundled pair,
and continues; the resulting package uses the in-box conhost and may silently
strip Kitty graphics APC and Sixel DCS passthrough on some Windows builds.
Pass `-RequireConPty` to make that download failure fatal. The GitHub Release
workflow always passes this switch for both x64 and ARM64.

To refresh the pin:

1. Select an exact `Microsoft.Windows.Console.ConPTY` version; never use a
   floating or `latest` URL.
2. Download that version's `.nupkg` and compute its SHA256.
3. Open the package as a ZIP, select the matching x64 and ARM64
   `conpty.dll`/`OpenConsole.exe` entries, and compute all four SHA256 values.
4. Update `dist/windows/conpty-redist.json` and the matching value pins in
   `test/windows/flagship/Test-VerificationContracts.ps1`, preserving the
   package ID, license, project URL, exact entry paths, and lowercase SHA256
   encoding.
5. Package both architectures with `-RequireConPty`; the packager re-verifies
   the archive, each extracted file, and both PE machine types before staging.

Microsoft's MIT text is committed as `dist/windows/LICENSE-conpty.txt` and is
staged beside noctty's `LICENSE` in every portable and installer package.

In a native Windows ARM64 PowerShell process, the packaging script defaults
to ARM64. An x64/emulated shell defaults to x64, even on ARM64 hardware.
Pass `-Architecture x64` or `-Architecture arm64` explicitly when you need a
specific target.

If Inno Setup is available on the machine, the packaging script can also
build the installer. If it is not installed, the portable artifact and
checksums are still produced so packaging can be validated locally.

To exercise the local signing path, export these environment variables
first:

```powershell
$env:WINDOWS_CODESIGN_PFX_PATH = "C:\secure\noctty-signing.pfx"
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

- `dist/artifacts/noctty-<version>-windows-x64/package-managers/scoop/`
- `dist/artifacts/noctty-<version>-windows-x64/package-managers/metadata.json`

## Release automation

The release workflow publishes to the official Windows package-manager
tracks after the GitHub Release is live. The preflight fails closed unless
signing is configured and both remote package-manager manifests already
exist. Release metadata comes from the committed
`dist/windows/release-metadata.json` file, so the release tag, generated
package-manager metadata, and GitHub release notes all agree on the current
upstream base.

Automated releases should use a dedicated GitHub Actions environment named
`release`. The workflow resolves signing secrets from that environment or
the repo default secret scope and runs `scripts/release-preflight.ps1`
before build/test/package work starts.

### Authenticode signing

Required for the GitHub `Release` workflow:

- Secret: `WINDOWS_CODESIGN_PFX_BASE64`
- Secret: `WINDOWS_CODESIGN_PFX_PASSWORD`

Optional:

- Environment or repo variable: `WINDOWS_CODESIGN_TIMESTAMP_URL`
  Default: `http://timestamp.digicert.com` (RFC 3161). Optional only while
  `WINDOWS_CODESIGN_TRUST_SELF_SIGNED` is `true`; preflight otherwise
  requires an explicit http(s) URL.
- Environment or repo variable: `WINDOWS_CODESIGN_TRUST_SELF_SIGNED`
  Default: unset / false
- Environment or repo variable: `WINDOWS_CODESIGN_MIN_VALIDITY_DAYS`
  Default: 180, which is also the minimum. Preflight rejects a value that is
  not an integer of at least 180, and rejects a signing certificate with
  fewer than this many days of validity left. Set it only to raise the floor.

Recommended setup:

1. Export a password-protected `.pfx` that contains the private key and full
   certificate chain for the Windows code-signing identity.
2. Base64-encode that file locally.
3. Store the base64 and password in the `release` environment, not plain
   repo scope, so release signing stays isolated from unrelated workflows.

Example `gh` commands:

```powershell
$repo = "amanthanvi/noctty"
$pfxPath = "C:\secure\noctty-signing.pfx"
$pfxBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfxPath))

$pfxBase64 | gh secret set WINDOWS_CODESIGN_PFX_BASE64 --repo $repo --env release
gh secret set WINDOWS_CODESIGN_PFX_PASSWORD --repo $repo --env release --body "<pfx-password>"
gh variable set WINDOWS_CODESIGN_TIMESTAMP_URL --repo $repo --env release --body "http://timestamp.digicert.com"
gh variable set WINDOWS_CODESIGN_TRUST_SELF_SIGNED --repo $repo --env release --body "true"
```

If you prefer a different RFC 3161/Authenticode timestamp service, set
`WINDOWS_CODESIGN_TIMESTAMP_URL` explicitly. The packaging script defaults
to DigiCert when the variable is absent.

> **Security note:** set `WINDOWS_CODESIGN_TRUST_SELF_SIGNED` in the
> `release` environment only while the release identity is intentionally
> self-signed, and remove it as soon as a publicly trusted certificate is
> in use. With the variable unset, signature validation fails closed on
> untrusted roots instead of accepting them.

When `WINDOWS_CODESIGN_TRUST_SELF_SIGNED=true`, signature validation accepts
the expected self-signed signer thumbprint plus the narrow untrusted-root
statuses reported by `Get-AuthenticodeSignature`. This keeps
internal/self-signed release probes green on the current runner, but it
does not create public publisher trust on other machines. Until noctty
moves from internal/self-signed signing to a publicly trusted certificate,
treat SmartScreen and publisher trust as incomplete.

### Release runbook

Recommended order:

1. Update `dist/windows/release-metadata.json` if the upstream compatibility
   line or `firstForkPatch` changed.
2. Configure or rotate the `release` environment signing secrets.
3. Run the **Release Readiness** workflow with the target plain semver
   version, for example `1.3.107`.
4. Produce interactive evidence for the release SHA: register the
   self-hosted interactive runner ephemerally, then dispatch the **Test**
   workflow with `run_interactive_win11=true`. The interactive job runs
   only on this opted-in dispatch, and the **Release** workflow refuses
   to publish without its hash-bound evidence at the exact release SHA.
5. Run the Windows 10 22H2 checklist,
   [docs/windows10-release-checklist.md](docs/windows10-release-checklist.md),
   against a candidate built from the intended source SHA on a Windows 10
   machine. Use [Local packaging](#local-packaging) with `-RequireConPty` and
   Inno Setup available for the installed rows. Local builds are unsigned unless
   signing is configured; record that limit. **Release Readiness** produces no
   artifacts. Record the source SHA and candidate hashes. Stable publication
   rebuilds the assets, so this pass binds to the source SHA; record the shipped
   hashes separately and repeat affected checks if the source changes. No
   hosted image or interactive job covers Windows 10; the checklist is a manual
   release step, not a CI gate. Put its results table in the release notes'
   validation section. The scheduled **Windows 10 branches** workflow is a
   separate, non-required check that runs the unit suite on Windows Server 2022
   (build 20348); read its latest run too.
6. After readiness passes, either:
   - push tag `v<version>`, or
   - manually dispatch the **Release** workflow with `version=<version>` and
     `prerelease=false`.
7. Confirm the workflow published artifacts for both x64 and ARM64:
   - installer
   - portable ZIP
   - `noctty-<version>-windows-x64-portable.manifest.ps1`
   - `noctty-<version>-windows-arm64-portable.manifest.ps1`
   - `noctty-<version>-windows-<arch>-symbols.zip`
   - `SHA256SUMS-windows-<arch>.txt`
   - legacy x64 `SHA256SUMS.txt`
   - GitHub Release notes/assets
8. Confirm build provenance for the eleven non-icon assets.
9. Confirm follow-on publishes:
   - Scoop manifest update
   - WinGet submission
   - Chocolatey package push (the step is skipped while the repository
     variable `CHOCOLATEY_PUBLISH` is `off`)

If a tag already exists and the workflow failed before publish, configure
the missing signing secrets and then rerun the failed `Release` workflow or
manually dispatch **Release** with the same version. The workflow is
idempotent for release creation/upload because it uses `gh release create`
on first publish and `gh release upload --clobber` on reruns.

### WinGet

- Secret: `WINGETCREATE_TOKEN`
- Repo variable: `WINGET_PACKAGE_IDENTIFIER`
- Current automation path: `wingetcreate update ... --submit`

The WinGet package identifier is `AmanThanvi.noctty` and the package is
published (`microsoft/winget-pkgs/manifests/a/AmanThanvi/noctty`, first version
1.3.131). The repository variable `WINGET_PACKAGE_IDENTIFIER` is set to it, and
stable preflight verifies that the manifest folder exists and that the latest
public manifest covers x64 and arm64. Users install with
`winget install --id AmanThanvi.noctty -e`. The old
`AmanThanvi.winghostty` identifier is retired. Keep CI on the truthful
`update` path; do not switch to `wingetcreate new` for automated releases.

### Scoop

- Secret: `SCOOP_BUCKET_TOKEN`
- Repo variable: `SCOOP_BUCKET_REPO`
- Optional repo variables: `SCOOP_BUCKET_BRANCH`, `SCOOP_BUCKET_MANIFEST_PATH`

The workflow updates a manifest in a configured Scoop bucket repository. It
does not attempt to auto-open PRs against `ScoopInstaller/Extras`; that path
is review-driven and should stay explicit.

The official Scoop track is the fork-owned bucket:

```powershell
scoop bucket add noctty https://github.com/amanthanvi/scoop-noctty
scoop install noctty/noctty
```

Release preflight verifies that the configured manifest exists, defaulting
to `bucket/noctty.json` when `SCOOP_BUCKET_MANIFEST_PATH` is unset.

### Chocolatey

- Secret: `CHOCO_API_KEY` (in the `release` environment)
- Optional repo variable: `CHOCOLATEY_PUBLISH` (`off` skips the push; it is
  unset, so the push runs)
- Package id: `noctty`

The package is published: users install with `choco install noctty`
(chocolatey.org approved 1.3.134 on 2026-10-23, and the `CHOCOLATEY_PUBLISH`
variable was deleted that day). The release workflow always generates the
Chocolatey package metadata, and its Chocolatey step runs after Scoop and
WinGet, so a refusal there cannot hold them back. It skips `choco pack` and
`choco push` cleanly when `CHOCO_API_KEY` is absent, and the step does not run
while `CHOCOLATEY_PUBLISH` is `off`. The package carries both installers, and
its install script picks one by asking the CPU, because Chocolatey runs as an
emulated x64 process on ARM64 Windows. chocolatey.org reviews each version
before listing it, so a release can reach Chocolatey after the other channels,
and it refuses the push with `403` while another account owns the id, or while
a version is in moderation and none is approved; the step then fails after
everything else has published.
[docs/chocolatey-publishing.md](docs/chocolatey-publishing.md) has the id's
state, how to turn the push off and back on, and the steps for resubmitting a
version during moderation; do not rerun a published Release for that. To push a
version that is already released, dispatch the **Chocolatey Publish**
workflow (`.github/workflows/chocolatey-publish.yml`, `version` input; `push`
off is a dry run that verifies the release and packs); it verifies the
published assets and then runs `scripts/release-publish-chocolatey.ps1`, the
script the Release step uses. To publish a generated package by hand:

```powershell
choco pack .\noctty.nuspec --output-directory .\out
choco push .\out\noctty.<version>.nupkg --source https://push.chocolatey.org/ --api-key $env:CHOCO_API_KEY
```

The chocolatey.org account and its API key (stored on 2026-10-17) are the
maintainer's, outside this repository. `virtualex`, who created the package,
stays a co-maintainer of the id.

## Zig version

This repo is pinned to Zig `0.15.2` in CI, and packaging should use the same
Zig version unless the repo is intentionally updated to a newer one. The
full toolchain rules live in [HACKING.md](HACKING.md#toolchain).

## Library consumers

`libghostty-vt` remains intentionally retained and keeps its existing public
name. The app binary and Windows packaging are rebranded to `noctty`,
but the library surface is not being renamed as part of this packaging
cleanup.
