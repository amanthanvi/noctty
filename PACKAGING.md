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
`noctty-command.pdb` (for `noctty.com`), `ghostty-vt.pdb` (for the portable
ZIP's `ghostty-vt.dll` placeholder, until v1.4.100; see
[Library consumers](#library-consumers)) and
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
(`zig build -Demit-exe=true -Doptimize=ReleaseFast -Dstrip=false ...`),
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
4. After readiness passes and the **Test** run of that commit's push to
   `main` has succeeded, either:
   - push tag `v<version>`, or
   - manually dispatch the **Release** workflow with `version=<version>` and
     `prerelease=false`.
5. Confirm the workflow published artifacts for both x64 and ARM64:
   - installer
   - portable ZIP
   - `noctty-<version>-windows-x64-portable.manifest.ps1`
   - `noctty-<version>-windows-arm64-portable.manifest.ps1`
   - `noctty-<version>-windows-<arch>-symbols.zip`
   - `SHA256SUMS-windows-<arch>.txt`
   - legacy x64 `SHA256SUMS.txt`
   - GitHub Release notes/assets
6. Confirm build provenance for the eleven non-icon assets.
7. Confirm follow-on publishes:
   - Scoop manifest update
   - WinGet submission
   - Chocolatey package push (the step is skipped while the repository
     variable `CHOCOLATEY_PUBLISH` is `off`)

A release does not require a manual Windows 10 pass. The
[Windows 10 manual checklist](docs/windows10-release-checklist.md) is an
optional pass for a change that needs Windows 10 evidence, not a release step.
The scheduled **Windows 10 branches** workflow is a non-required check.

A release does not require an interactive or visible-desktop run either (the
maintainer's decision, 2026-11-22). The **Release** workflow gates on a
completed, successful **Test** run of the exact release SHA, which the push to
`main` gives, and promotion reads no interactive evidence; multi-agent council
review takes the place of a visible run. The interactive composite stays an
optional dispatch, started only on the maintainer's explicit go: register the
self-hosted interactive runner ephemerally, then dispatch **Test** with
`run_interactive_win11=true`. It uses the visible desktop for about 20 to 25
minutes (60 at most) and reads screen pixels, so a window or notification banner
over the windows it tests can fail the run. Before dispatching, turn on Do Not
Disturb, close any open shell flyout, and minimize every other window, your own
noctty windows included. Then leave the machine alone until the job finishes.

Build mode creates a draft targeting the accepted candidate, uploads each asset
with at most three attempts, checks every uploaded digest against
`release-manifest.json`, then publishes. The manifest digest is recorded by
**Write release manifest and record digest**, before **Publish GitHub Release**.
Uploads are immutable; build mode refuses an existing release and never uses
`--clobber`. A lost create or promote response is reconciled by reads, never by
repeating the mutation. Publication flags, the created tag and latest state
have three-read bounded backoff checks; unresolved state stops and is preserved. Keep the original Release run ID and its summary digest.

For a soaked prerelease, land the stable-copy update to README and the site on
`main` first, then dispatch **Release** from `main` with `mode=promote`:

```powershell
gh workflow run release.yml --repo amanthanvi/noctty --ref main -f mode=promote -f tag=<tag> -f candidate_sha=<peeled-sha> -f test_run_id=<test-run> -f release_run_id=<original-build-run> -f manifest_sha256=<summary-sha256>
```

Promotion runs main's scripts, checks out the candidate for its pinned data and
generator, authenticates evidence and every asset, regenerates identical
package-manager files, checks the stable copy, flips the release, verifies it,
then publishes Scoop, WinGet and Chocolatey in order. Before the flip, each
channel must have its repository/package ID, token and bootstrap configured,
or be explicitly disabled by `SCOOP_PUBLISH=off`, `WINGET_PUBLISH=off` or
`CHOCOLATEY_PUBLISH=off`. Missing configuration fails with
`PackageManagerNotReady`; disabling a channel is a deliberate operator choice.

**PublishedReleaseResume** uses the same promote inputs for a stable or
prerelease build whose original Release run failed or was cancelled later.
It reads every run attempt and its jobs. Some attempt must show
**Publish GitHub Release** succeeded; the tag must still resolve to the
candidate, and the summary digest, manifest and every asset must match. The
original run ID stays fixed. **Do not re-run the original Release workflow**
after it created a draft or published a release. Use the guarded draft recovery
below for a draft; dispatch promote for a complete published release. If
a rerun already happened, resume still authenticates the earlier publishing
attempt. Take `manifest_sha256` from that attempt's summary, not a later rerun's
newly generated digest. A stable recovery starts at the first incomplete
step (verify, Scoop, WinGet, Chocolatey) in the **original publishing attempt**,
not a later promotion attempt. Verification needs a successful step; each channel
also needs its durable `publication outcome: published` or `already-present`
step. `skipped-unconfigured` never counts as complete. Older runs without
outcome markers conservatively resume at the first unproven publisher and rely
on its idempotence. Later promotion progress is not used to advance this index.
A prerelease recovery verifies after its flip. Each publisher is idempotent:
Scoop compares the desired bytes, WinGet checks open/merged PR manifest paths,
and Chocolatey checks the exact version. Unknown state stops the run.
`ReleasePublishNotSuccessful` refuses a failed run without a successful publish
step. Inspect that run and publication state before choosing recovery.

`DraftRelease` (including a partial or cancelled upload) cannot be promoted.
Discovery reads all release-list pages and the selected release ID because
GitHub's tag endpoint hides drafts. `AmbiguousReleaseTag` refuses duplicate
pending tags for inspection. If the selected ID returns HTTP 200 with a
non-object JSON value such as `[]`, the read is retried within a three-read
limit. Exhausting that limit gives `ReleaseLookupIncomplete`. A JSON object
with a missing or mismatched ID or tag, such as `{}`, immediately gives
`ReleaseIdentityMismatch`. After a create request, release discovery allows
up to three reads for a list miss or an ID read returning 404. The build
continues only if the returned draft carries this attempt's marker in its
notes and passes the candidate checks. `ReleaseDraftOwnershipUnconfirmed`
means the build could not prove it created the draft. Preserve it and inspect
the original run and draft ID before deciding who should recover it.

For manual draft recovery, first list **every** release with this tag,
including drafts, with a push-authorized token (listing is read-only):

```powershell
gh api --method GET --paginate 'repos/amanthanvi/noctty/releases?per_page=100' --jq '.[] | select(.tag_name == "<tag>") | {id, tag_name, draft, prerelease}'
```

Stop unless there is **exactly one** match and it is the inspected incomplete
draft. A published release plus a draft, or two drafts, requires investigation;
never delete either on a first-match lookup. Immediately before deletion, repeat
the full list and read `gh api repos/amanthanvi/noctty/releases/<draft-id>`;
verify the same ID/tag and `draft: true`. Only then may an operator delete that
specific draft by ID:

```powershell
gh api --method DELETE repos/amanthanvi/noctty/releases/<draft-id>
```

Never use `--cleanup-tag` in this recovery: another published release may share
the tag, and GitHub may never have created a tag for a tagless draft. Check the
remote ref separately (`gh api repos/amanthanvi/noctty/git/ref/tags/<tag>`; a 404
means no ref). Preserve an existing tag; if it points to a different candidate,
stop for independently audited tag recovery rather than deleting it here. With
an absent tag or one peeled to the newly accepted candidate, dispatch a fresh
build from main:

```powershell
gh workflow run release.yml --repo amanthanvi/noctty --ref main -f mode=build -f version=<version> -f prerelease=true
```

This is manual draft recovery only, never automatic deletion or promotion.
It creates a new run/manifest and requires a successful Test run of the new
commit and a new soak.
Every published release and its tag must be preserved.

`LegacyReleaseWithoutManifest` identifies any published release from
before promotion manifests, including the 22 pre-rename winghostty releases and v1.3.136 through v1.3.138. Preserve the
release and tag; use the verified manual Chocolatey workflow or an audited
channel-specific recovery. `IncompletePublishedRelease` also requires
preservation and inspection, not deletion or a rebuild. `ReleaseMissing` means
no release or draft was visible. Never delete a published historical release
in response to a promotion refusal.

The candidate generator runs in a separate, hidden `pwsh` process, with
an environment allowlist containing only Windows runtime/temp locations.
Arbitrary runner variables and parent scope variables are inaccessible; the
orchestration process retains its credentials
for channel preflight. Local metadata generation also works under an outer
`-WhatIf`; external mutations still honor `-WhatIf`. All
three `*_PUBLISH=off` switches compare case-insensitively in build, promote,
preflight and direct publisher scripts.

Test evidence (the portable smoke artifact) is retained for 90 days.
`EvidenceExpired` identifies the run, artifact and expiry time. Dispatch a
fresh Test run on the candidate tag, then pass its run ID as `test_run_id` to
promote, retaining the original Release run ID and manifest digest. No
interactive run is needed:

```powershell
gh workflow run test.yml --repo amanthanvi/noctty --ref <tag>
```

That dispatch also runs the `windows-2025` skip budget, so a budget that drifted
since the candidate fails it; the path then is a new prerelease.

For read-only verification of historical v1.3.124, pass `-AllowPrerelease`
explicitly: it is still marked as a prerelease on GitHub. Its portable archives
predate the bundled ConPTY pair (v1.3.125), so its candidate data need no
`conpty-redist.json`. Modern releases still require both pinned Microsoft
binaries. The default verifier continues to require a stable release.

Local promotion rehearsals use the system temp directory by default. Fixture A
(`scripts/release-promote.ps1 -Fixture historical`) or Fixture B
(`test/windows/release-promote.ps1`) can use an existing scratch parent via
`-WorkDirectory` or `NOCTTY_RELEASE_FIXTURE_ROOT`. GitHub Actions defaults
to `RUNNER_TEMP`. Each fixture creates a child of the selected directory and
removes it on success. Fixture A removes its child on failure too. Fixture B
removes bulk data on failure and prints the location of the text evidence it
kept. An explicit `-AssetDirectory` stays caller-owned. Default downloads
live inside Fixture B's bulk tree and are removed with it.

### WinGet

Duplicate discovery checks the default branch's exact version directory and
searches **open** winget-pkgs PRs for `amanthanvi.noctty` in **title or body**,
without a version qualifier or an author restriction. The complete candidate
set must contain at most **100** PRs. Each candidate's state and changed-file
paths are checked under `manifests/a/AmanThanvi/noctty/<version>/`.
Reads have a 250-request budget, search-rate pacing and three attempts for
5xx or connection loss. `WinGetQueryFailed` stops after a failed lookup;
`WinGetCandidateSetIncomplete` stops for a broad, incomplete or truncated result.
Neither condition permits submission.

A miss is reported as **absent within the stated limit**, never confirmed
repository-wide absence. The search omits PRs from any account whose title
**and** body both omit the identifier, including our own publisher's PRs.
WinGetCreate includes the identifier when it opens a PR, but later edits can
remove it. Retitling a PR or omitting the version is covered as long as either
field retains the identifier. No all-open-PR enumeration is used: that caused
measured 502s on winget-pkgs.

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
the GitHub Release and the Scoop update are published and the WinGet manifest
update is submitted; the release does not wait for WinGet to accept it.
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

noctty does not ship `libghostty-vt` as a library for other programs.
`noctty.exe` does not load `ghostty-vt.dll` (its import table has no such
entry). The copy releases up to 1.3.136 put beside it is libghostty-vt
version 0.1.0 with the pre-1.0 C ABI, under the same name as upstream's
libghostty-vt 1.0 DLL, which has a stable C ABI. To use the library:

- take upstream's official libghostty-vt, with its Windows x64 DLL, from
  [lib.ghostty.org](https://lib.ghostty.org); or
- build it from this tree: `zig build -Demit-lib-vt`, or the CMake wrapper
  (`CMakeLists.txt`, `dist/cmake/`). CI still builds and tests it (the
  `windows-lib-vt` job). Packaging no longer builds it.

Setup no longer installs `ghostty-vt.dll`, and it deletes the copy an
earlier Setup installed (`[InstallDelete]` in `dist/windows/noctty.iss`).
Neither package carries `share/pkgconfig/libghostty-vt.pc` any more, and
Setup deletes that file too. (The updater replaces a portable copy's `share`
folder as a whole.)

From 1.3.137, the portable ZIP's `ghostty-vt.dll` is a placeholder that
noctty builds (`src/ghostty_vt_stub/`), not libghostty-vt, and the symbols
ZIP's `ghostty-vt.pdb` is the placeholder's. The placeholder exports and
imports nothing, and its `DllMain` refuses to initialise, so `LoadLibrary`
fails with `ERROR_DLL_INIT_FAILED` instead of handing a program an old ABI.
Its version resource describes it as "noctty placeholder for the retired
ghostty-vt.dll; not libghostty-vt". There is one per architecture, and it is
signed in the same packaging step as noctty's other binaries.

It is there for the portable updater of noctty 1.3.125 to 1.3.136, which
refuses a portable update whose payload lacks any file it manages,
`ghostty-vt.dll` included. It checks that in the running copy when it stages
the update, and again in the swap, which runs from a copy of the same old
executable. Of each noctty-built DLL in the payload it asks only that the
file is listed in the signed payload manifest with its hash, is built for the
right machine and carries noctty's publisher signature; it never loads it.
The updater from 1.3.137 on accepts a payload without the file. When it
applies one, it moves the copy aside with the other files it replaces, so a
rollback puts it back and a confirmed update deletes it (`retired_entries` in
`src/update/portable_apply.zig`).

**Manual update at v1.4.100.** v1.4.100 drops the placeholder from the
portable and symbols ZIPs. A portable copy on 1.3.125 to 1.3.136 that has
not installed a release from 1.3.137 on by then cannot stage that update: its
update notice offers the release page, and the copy has to be updated by
hand from there. A portable copy that has installed 1.3.137 or later keeps
updating in-app. Releases up to 1.3.124 never updated a portable copy
in-app, so those copies already update by hand. Setup installs are not
affected.
