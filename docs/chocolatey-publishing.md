# Publish noctty on Chocolatey

Every stable release builds a Chocolatey package, `noctty`, and the last step of
the `Release` workflow pushes it to the community repository. The community
maintainer `virtualex` created the package: they submitted `noctty` 1.3.131 on
2026-10-16 from their package auto-updater, so their account owned the id, and
Chocolatey refused this repository's pushes with `403` (the 1.3.132 push from
the Chocolatey Publish workflow on 2026-10-17 and the 1.3.133 release's push on
2026-10-18).

On 2026-10-20, as agreed in
[virtualex-itv/chocolatey-packages#35](https://github.com/virtualex-itv/chocolatey-packages/issues/35),
`virtualex` added `amanthanvi` as a maintainer of the package, stayed on as a
co-maintainer, and rejected 1.3.131
([its page](https://community.chocolatey.org/packages/noctty/1.3.131)). On
2026-10-21 the Chocolatey Publish workflow pushed 1.3.134 (dry run
[39578632348](https://github.com/amanthanvi/noctty/actions/runs/39578632348),
push [39578893616](https://github.com/amanthanvi/noctty/actions/runs/39578893616):
`noctty.1.3.134.nupkg was pushed successfully`). Read at 10:21 UTC that day,
the feed's
[entry for it](https://community.chocolatey.org/api/v2/Packages(Id='noctty',Version='1.3.134'))
had `PackageStatus` `Submitted`, `PackageSubmittedStatus` `Pending`,
`IsApproved` `false`, `PackageValidationResultStatus` `Passing` (since 10:16
UTC) and `PackageTestResultStatus` `Pending`.

Chocolatey approved 1.3.134 on 2026-10-23, about two days after the push. Read
at 16:28 UTC on 2026-10-24, the same feed entry had `PackageStatus` `Approved`,
`IsApproved` `true`, `PackageReviewer` `Windos` (reviewed and approved at
07:44 UTC on 2026-10-23), `PackageValidationResultStatus` `Passing` and
`PackageTestResultStatus` `Passing`, and `choco search noctty --exact` listed
`noctty|1.3.134`. So `choco install noctty` works. Chocolatey's own install
test passed; this repository did not run an install, which would run Setup on
the machine that checked.

## Turning the release push off and on

The release push runs again. The repository variable `CHOCOLATEY_PUBLISH` was
deleted on 2026-10-23, after 1.3.134 was approved, so each release's
**Publish Chocolatey package** step pushes the new version once the GitHub
Release and the Scoop update are published and the WinGet manifest update is
submitted. It had been `off` while
chocolatey.org could not accept a push: it refuses every new version while a
version is in moderation and none is approved, and that refusal ended the
release run red.

If chocolatey.org cannot accept the push again, turn it off with a repository
variable, so that a release does not end red for a refusal nothing in this
repository can fix:

```powershell
gh variable set CHOCOLATEY_PUBLISH --body off --repo amanthanvi/noctty
```

The `Release` workflow then skips its **Publish Chocolatey package** step (the
run lists it as skipped) and keeps the `CHOCO_API_KEY` secret. Only `off` skips
it (GitHub compares the text without regard to case); with the variable unset,
or set to anything else, the step runs. The Chocolatey Publish workflow below
does not read the variable: it runs only when someone starts it, and it is the
way to try a push while the release step is off. To turn the push back on,
delete the variable:

```powershell
gh variable delete CHOCOLATEY_PUBLISH --repo amanthanvi/noctty
```

Chocolatey accepts a push only when this repository's account owns (or
co-maintains) the id; `amanthanvi` has maintained it since 2026-10-20. It also
refuses every new version while the package has a version in moderation and
none approved, which was the case from the push of 1.3.134 on 2026-10-21 until
its approval. (A corrected package that a moderator asks for keeps the version
in moderation; see below.) The package has an approved version now.

The `Release` workflow never pushes the releases it skipped. Push the latest
one with the Chocolatey Publish workflow if it is not listed; do not rerun its
`Release` run. Versions 1.3.132 and 1.3.133 were refused (see above) and are
not on Chocolatey.

## What the package is

The package downloads the signed Inno Setup installer for the machine's
architecture (x64 or arm64) from the GitHub release, checks it against the
release's SHA-256, and runs it silently. The install script asks the CPU for the
architecture (`Win32_Processor.Architecture` 12 is ARM64), because Chocolatey
runs as an emulated x64 process on ARM64 Windows and the process reports x64
there; a package without an ARM64 installer keeps the x64 one. Chocolatey's own
uninstaller removes it through the installer's entry in Apps. The package
contains no binaries, so it needs no `VERIFICATION.txt`. The id is `noctty`, the
title `Noctty`, the license is the repository's MIT `LICENSE` at the release
tag, and the icon is the website's `https://noctty.com/assets/favicon.svg`,
because the validator rejects an icon served from GitHub. The package has its
own description for its Chocolatey page, which names the packaged architectures
("on x64 or ARM64").

The CPU question and the description came with
[#526](https://github.com/amanthanvi/noctty/pull/526) and
[#525](https://github.com/amanthanvi/noctty/pull/525), both merged on
2026-10-23 after 1.3.134 was built, so they ship with the first release built
after them. The 1.3.134 package asks the process only: #526's author measured
it installing the x64 build on a Windows 11 ARM64 machine, where it runs under
emulation. An upgrade over such an install is expected to switch to the ARM64
build; that was not tested.

## The account and the key

The maintainer's community account exists, and its API key has been the
`release` environment secret `CHOCO_API_KEY` since 2026-10-17. To replace the
key, copy a new one from the account page
(<https://community.chocolatey.org/account>) and paste it at the prompt rather
than on the command line:

```powershell
gh secret set CHOCO_API_KEY --repo amanthanvi/noctty --env release
```

## Publishing a version that is already released

Run the **Chocolatey Publish** workflow
([`chocolatey-publish.yml`](../.github/workflows/chocolatey-publish.yml)) from
`main`. Run it once without `push` first; that dry run does everything except
the push:

```powershell
gh workflow run chocolatey-publish.yml --repo amanthanvi/noctty --ref main -f version=1.3.133
gh workflow run chocolatey-publish.yml --repo amanthanvi/noctty --ref main -f version=1.3.133 -f push=true
```

Do not rerun that version's `Release` run instead. A rerun rebuilds the
installers and replaces the assets on the release page with new bytes whose
hashes no longer match the Scoop and WinGet manifests already published for
it. It would also run the workflow and scripts as they were at that release:
1.3.132's, for instance, push a package naming a GitHub-hosted icon that the
validator rejects.

## What the Chocolatey Publish workflow does

It runs in the `release` environment on a GitHub-hosted `windows-latest`
runner, where Chocolatey is preinstalled
([Windows Server 2025 image](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md):
Chocolatey 2.7.4 in image 20261013.288.2), and builds nothing:

1. It refuses to run unless the repository is `amanthanvi/noctty`, the
   version is plain three-part semver such as `1.3.132`, and the workflow
   commit is the head of `main`.
2. `scripts/release-stage-published.ps1` downloads the published release and
   verifies it with `scripts/verify-published-release.ps1`, the check the
   `Release` workflow ends with: GitHub's digest for every asset, the
   `SHA256SUMS` files, the build provenance attestation of every asset except
   the icon, and the Authenticode signer. A draft or prerelease fails there.
   It then requires both installers' attestations to name the commit the
   release tag points at now, so an installer re-uploaded from another commit
   is refused while the tag still points where it did.
3. It builds the package from those installers with
   `scripts/package-package-managers.ps1`, whose `packageSourceUrl` names the
   workflow's commit.
4. Without `push`, `scripts/release-publish-chocolatey.ps1 -PackOnly` packs it
   with `choco pack` and prints the file's size and SHA-256. It reads no API
   key and never contacts the push source.
5. With `push`, the same script runs for real. Only this step can read
   `CHOCO_API_KEY`, and it fails with a clear message if the secret is
   missing. The script takes the key out of its environment while
   `choco pack` runs, so only `choco push` receives it. The 403 and 409
   handling and the rule below are the `Release` workflow's, because it is the
   same script.

What this cannot tell is a rebuild of the same commit re-uploaded under the
same tag (the rerun the section above warns against), or a tag moved to another
commit together with that commit's rebuilt assets (the release page was not
immutable and no tag ruleset existed on 2026-10-17): their attestations are as
good as the original's. Nothing in the repository holds the original hashes
except the Scoop and WinGet manifests, so before the first push of a version,
compare the
`Installer <arch> SHA-256` lines the build step prints with `InstallerSha256`
in the WinGet manifest of that version (`microsoft/winget-pkgs`,
`manifests/a/AmanThanvi/noctty/<version>`), which was published from the
original build. For 1.3.132 the release's installers and that manifest were
identical on 2026-10-17 for both x64 (`b59f99a3...`) and arm64
(`f7c465e1...`).

The script skips a version the feed already lists. The feed's exact-version
lookup also lists a version that is still in moderation (measured on
2026-10-17: versions with the status `Submitted` and `Ready` answer `200`
there, while `FindPackagesById` leaves them out), so a corrected package for
such a version needs `-f resubmit=true` as well. Without it the run reports
`Chocolatey already has noctty <version>; nothing to push.`

The check that the run starts from `main` guards against a mistake, not
against a person with write access: it is part of the workflow file, and on
2026-10-17 the `release` environment had no deployment-branch rule and no
required reviewers, so a copy of the workflow edited on any branch could
still read the environment's secrets (`CHOCO_API_KEY` and the signing
certificate alike). The fix is in the environment's settings, which this
repository's code cannot change: limit deployment branches and tags to `main`
and the `v*` tags (with a tag ruleset, otherwise a writer can create a
matching tag on any commit), or require a reviewer for the environment.

## What happens after a push

Every version on the community repository is reviewed before it is listed. An
automatic validator and an install test start about 30 minutes after the push,
then a human moderator reviews it. The wait varies: 1.3.134, the first push from
this repository that Chocolatey accepted, was approved about two days later
(09:42 UTC on 2026-10-21 to 07:44 UTC on 2026-10-23), while another project
recorded 28 and 54 days for its first two approvals in 2026. How long later
versions take has not been measured, so a release can reach Chocolatey after
GitHub, WinGet and Scoop. Follow the state at
`https://community.chocolatey.org/packages/noctty/<version>` under
**Package Status**; `Submitted` means it is still queued.

If a moderator asks for changes, the status turns to **Waiting for
Maintainer** and the email says what to change. The fix goes into
`scripts/package-package-managers.ps1` through a pull request, and Chocolatey
wants the corrected package under the same version. Once the fix is on `main`,
run the **Chocolatey Publish** workflow again for that version, with
`resubmit` so that the listed version is not skipped:

```powershell
gh workflow run chocolatey-publish.yml --repo amanthanvi/noctty --ref main -f version=<version> -f push=true -f resubmit=true
```

Do not rerun the release instead: it would rebuild its installers.
Chocolatey's [moderation page](https://docs.chocolatey.org/en-us/community-repository/moderation/)
says to "resubmit the exact same version" with the required changes; this
repository has not done that yet, so the `resubmit` path is untested against
the live feed.

The package script checks every downloaded installer against the release's
`SHA256SUMS` before it writes the checksums into the package, so the
resubmitted package installs exactly the bytes on the release page. Its
`packageSourceUrl` names the commit of the generator that built it, so a
moderator can reproduce the corrected package; every other link still points
at the original release.

### Without the workflow

The workflow is these two scripts, so the same steps run from a checkout of
`main` with `gh` and `choco` installed and the fix merged; use this when
Actions is unavailable:

```powershell
$version = "<version>"   # the version the moderator asked about
$ErrorActionPreference = "Stop"
function Assert-Exit([string] $What) { if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" } }
git switch main; Assert-Exit "git switch"
git pull --ff-only; Assert-Exit "git pull"
$generator = (git rev-parse HEAD).Trim(); Assert-Exit "git rev-parse"
$env:WINDOWS_CODESIGN_TRUST_SELF_SIGNED = "true"   # the release is signed with a self-signed certificate
./scripts/release-stage-published.ps1 -Version $version -PackageSourceRef $generator
./scripts/release-publish-chocolatey.ps1 -Version $version -PackOnly   # dry run: packs, pushes nothing
$key = Read-Host -Prompt "Chocolatey API key" -AsSecureString
$env:CHOCO_API_KEY = [Net.NetworkCredential]::new("", $key).Password
try { ./scripts/release-publish-chocolatey.ps1 -Version $version -Resubmit }   # drop -Resubmit for a version the feed does not list yet
finally { Remove-Item Env:CHOCO_API_KEY }
```

While a version is in moderation and none is approved, Chocolatey refuses every
new version with `403`: one of the causes it documents is "Package has a
version in moderation and no approved versions"
([common errors](https://docs.chocolatey.org/en-us/community-repository/maintainers/common-errors/)).
That was the state of `noctty` from 2026-10-21 to 2026-10-23. A release in such
a window still publishes to GitHub and Scoop and submits the WinGet manifest
update. The Chocolatey step runs last so that it cannot hold back WinGet; it
fails, the run turns red, and its message names the possible causes of a `403`,
unless `CHOCOLATEY_PUBLISH` is `off` and the step is skipped. Such a version
never reaches Chocolatey from the release, and the next release pushes again
once Chocolatey accepts pushes.

A `403` can also mean an invalid or revoked API key, or that another account
owns the id. A `409 Conflict` is treated as success only when the feed then
holds the version, because Chocolatey also answers `409` for a package that
fails its basic validation.
