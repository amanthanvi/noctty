# Win32 Auto-Update Install/Staging Design

Date: 2026-05-03
Status: Draft
Scope: Win32 updater v2 for true download, staging, verification, and apply on Windows before implementation work starts

## Problem

winghostty already has a Windows update check path, but it stops at
"new version available" and opens the GitHub release page. The repo accepts
`auto-update = download`, yet current user-facing docs and code explicitly say
that `download` behaves the same as `check`.

That is a reasonable v1 contract, but it leaves four gaps:

- No trusted artifact download path from GitHub Releases into local staging.
- No install-mode detection, so the app cannot distinguish installer-managed
  installs from portable ZIP extractions.
- No out-of-process apply path, which means the running app cannot safely
  replace itself or hand off to the installer with predictable restart/UAC
  behavior.
- No release-pipeline contract for detached checksum signatures even though the
  current release parser already looks for them.

This spec defines a Win32 updater v2 that keeps `check` conservative, makes
`download` real, and does so with an explicit trust model.

## Current Anchors

The design intentionally extends current repo behavior instead of replacing it:

- `src/config/Config.zig`
  - Documents the current contract:
    - `auto-update = check` is notify-only.
    - `auto-update = download` currently behaves the same as `check`.
    - `auto-update-channel = stable` is the only supported automatic channel.
- `src/update/github_releases.zig`
  - Owns update throttling, persisted dismissal state, release discovery, and
    GitHub API parsing.
  - Parses a Windows install candidate:
    `setup.exe` + `SHA256SUMS.txt`.
  - Cached throttled state only preserves `last_seen_version`, so asset-scoped
    metadata is dropped between runs.
- `src/apprt/win32.zig`
  - Owns the Win32 app-thread updater flow:
    `maybeScheduleAutomaticUpdateCheck`,
    `scheduleUpdateCheck`,
    `handleUpdateCheckCompletion`,
    `setUpdateNotice`,
    `openUpdateNotice`,
    `dismissUpdateNotice`,
    and the `.check_for_updates` action.
  - Current completion handling only surfaces version text + release URL. It
    does not carry forward installer/checksum asset metadata into the UI/apply
    path.
- `scripts/package-windows.ps1`
  - Builds both the portable ZIP and the Inno Setup installer.
  - Can Authenticode-sign staged `.exe`/`.dll` artifacts and the final
    installer when secrets are present.
  - Writes `SHA256SUMS.txt`.
- `dist/windows/winghostty.iss`
  - Defines the current installer identity, default install root, shortcut
    AUMID wiring, and post-install launch behavior.
- `.github/workflows/release.yml`
  - Publishes:
    - `winghostty-<version>-windows-x64-setup.exe`
    - `winghostty-<version>-windows-x64-portable.zip`
    - `SHA256SUMS.txt`
    - `winghostty-icon.svg`
- `docs/getting-started.md`, `docs/status.md`, and
  `docs/windows-capability-matrix.md`
  - All currently describe the updater as notify-only and describe
    `download` as a no-op alias for `check`.

## Goals

- Keep `auto-update = check` conservative and compatible with the current UX.
- Make `auto-update = download` perform a real background download and staging
  flow on Win32.
- Select the correct release asset for the current install mode:
  installer-managed install uses the installer asset; portable install uses the
  portable ZIP.
- Verify release artifacts before staging and again before apply.
- Apply updates out of process so the running app never overwrites itself.
- Preserve the current stable-channel-first behavior while leaving a clear path
  for future prerelease support.
- Fail closed when release assets are unsigned, incomplete, mismatched, or
  staged in an unsafe location.

## Non-Goals

- Session restore, tab restore, or relaunching the exact previous command tree.
- Binary-delta patching. v2 uses full installer/ZIP artifacts.
- Cross-platform updater work. This spec is Win32-specific.
- Silent background replacement with no user-visible prompt.
- Auto-apply for unsigned release artifacts.
- Full `tip` channel auto-install in the first implementation tranche.

## Design Principles

- `check` remains a discovery-only mode.
- `download` is only active when the release asset set passes the trust
  contract and the current install mode is known.
- Installer and portable flows never cross. We do not convert a portable user
  into an installer user or vice versa.
- Every apply path is out of process.
- Verification is not a one-time event. Re-check staged artifacts immediately
  before apply.
- Unknown or ambiguous runtime state degrades to the current release-page flow,
  not best-effort mutation.

## Channel Model

### `stable`

- Discovery source stays GitHub Releases.
- Automatic checks continue to use the current stable path first:
  `releases/latest`.
- `auto-update = check` remains fully supported.
- `auto-update = download` becomes supported once the release asset trust
  contract in this spec is in place.

### `tip`

- `tip` remains check-only/manual in the first implementation tranche.
- The current banner behavior from `src/apprt/win32.zig` stays:
  when the user explicitly triggers `.check_for_updates` on `tip`, we open the
  GitHub Releases page and explain that prerelease auto-updates are not
  supported yet.
- A later tranche may add prerelease discovery by scanning
  `GET /repos/.../releases` and selecting the newest prerelease with the same
  signed asset contract as stable. This spec leaves room for that shape but
  does not make it part of phase 1 apply work.

## Release Asset Contract

For a release to be eligible for `auto-update = download`, it must publish:

- `winghostty-<version>-windows-x64-setup.exe`
- `winghostty-<version>-windows-x64-portable.zip`
- `SHA256SUMS.txt`

The current filename conventions in `scripts/package-windows.ps1` and
`src/update/github_releases.zig` stay authoritative.

`SHA256SUMS.txt` must contain exact `sha256 *filename` lines for at least:

- `winghostty-<version>-windows-x64-setup.exe`
- `winghostty-<version>-windows-x64-portable.zip`

### Authenticode requirements

The installer trust model is `SHA256SUMS.txt` for release-asset integrity plus
Windows Authenticode for publisher and signing-chain trust.

- Installer mode requires a valid Authenticode signature on the staged
  `setup.exe`.
- Portable mode should verify:
  - ZIP hash against the checksum manifest.
  - Basic extracted-tree shape after unzip.
  - Valid Authenticode signatures on shipped PE files where present
    (`winghostty.exe`, `ghostty-vt.dll`, and any future dedicated update
    helper).

Production auto-apply must reject invalid Authenticode results. Test/self-signed
allowances are harness-only behavior, not production behavior.

### Version constraints

- Reject versions `<= current_version` for automatic staging/apply.
- Reject releases whose filename version, tag version, and parsed semantic
  version disagree.
- If the checksum manifest omits the expected asset, treat that release
  as ineligible for `download`.

## Install Mode Detection

Add a Win32-only mode classification:

- `installed`
- `portable`
- `unknown`

Detection order:

1. Classify as `installed` when the current executable directory is consistent
   with an Inno install, using one or more of:
   - `unins*.exe` / `unins*.dat` beside the current app.
   - uninstall-registry metadata whose install root matches the current
     executable directory.
2. Classify as `portable` when the current executable directory is a writable,
   self-contained packaged tree with:
   - `winghostty.exe`
   - `ghostty-vt.dll`
   - bundled `share/ghostty/...` resources consistent with the current
     `resourcesDir()` sentinel lookup in `src/os/resourcesdir.zig`
   - no matching installer/uninstall marker
3. Otherwise classify as `unknown`.

Mode consequences:

- `installed` -> use the installer asset.
- `portable` -> use the portable ZIP asset.
- `unknown` -> allow `check`, but degrade `download` to notify-only with a
  clear "Open Releases" action and a log line explaining why auto-apply is not
  safe.

This keeps install-mode detection repo-grounded without inventing new
user-visible config.

## Persisted State And Staging Layout

Retain the current `update-state.json` concept from
`src/update/github_releases.zig`, but extend it to a v2 schema.

Suggested layout:

```text
%LOCALAPPDATA%\winghostty\
  update-state.json
  updates\
    1.3.110\
      SHA256SUMS.txt
      asset\
        winghostty-1.3.110-windows-x64-setup.exe
        winghostty-1.3.110-windows-x64-portable.zip
      extracted\          # portable mode only
      rollback\           # portable mode only
      logs\
        download.log
        apply.log
```

Suggested state shape:

```json
{
  "schema": 2,
  "last_checked_at": 0,
  "last_seen_version": null,
  "dismissed_version": null,
  "install_mode": "installed",
  "staged": {
    "version": "1.3.110",
    "channel": "stable",
    "asset_kind": "installer",
    "asset_name": "winghostty-1.3.110-windows-x64-setup.exe",
    "asset_sha256": "<hex>",
    "release_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.110",
    "stage_dir": "C:\\Users\\...\\updates\\1.3.110",
    "status": "ready",
    "downloaded_at": 0,
    "apply_requested_at": 0,
    "last_error": null
  },
  "blocked_version": null,
  "last_applied_version": null
}
```

State rules:

- Preserve `last_checked_at`, `last_seen_version`, and `dismissed_version`
  semantics from v1.
- `blocked_version` is for trust failures such as signature/hash mismatch. A
  blocked version must not be auto-retried until a newer version appears or a
  manual retry explicitly clears it.
- Network failures and user-canceled UAC prompts do not block the version.
- Keep at most:
  - the currently staged version
  - one rollback backup for portable mode
  - recent logs
- Successful startup on the new version clears obsolete stage directories.

## Discovery And Candidate Selection

Extend `src/update/github_releases.zig` from "release with optional
windows installer metadata" to "release with asset metadata usable by the
Win32 updater."

Required additions:

- Carry both installer and portable asset metadata in the parsed release model.
- Preserve enough staged/cached metadata to avoid losing asset selection
  context on throttled runs.
- Keep `release_url` for manual fallbacks and release notes.
- Keep current semver normalization (`v1.2.3` -> `1.2.3`) and long-tag support.

Selection rules:

- Stable channel:
  - prefer the newest semver-greater candidate from `releases/latest`
  - require checksum file + install-mode-matching asset
- Tip channel, future:
  - newest prerelease semver-greater candidate with the same trust contract

Candidate rejection reasons must be explicit in logs:

- missing asset
- missing checksum line
- unsupported channel
- version not newer
- install mode unknown

## Verification Pipeline

For `auto-update = download`, verification happens in this order:

1. Resolve release candidate from GitHub API.
2. Download `SHA256SUMS.txt`.
3. Parse the checksum line for the selected asset.
4. Download the selected asset to `*.partial` inside the stage dir.
5. Stream SHA-256 while downloading.
6. Compare the final hash to the checksum line.
7. Rename `*.partial` -> final asset name only after hash match.
8. Perform mode-specific verification:
    - installer mode:
      - verify Authenticode on the staged `setup.exe`
    - portable mode:
      - unzip into `extracted\`
      - verify expected packaged tree shape
      - verify Authenticode on extracted PE files where present
9. Mark the stage `ready`.

Re-verify immediately before apply:

- Re-hash the staged asset against the saved checksum.
- Re-run Authenticode verification before execute/swap.

This avoids a stale "verified once, trusted forever" assumption.

## Apply Strategy

### Shared rule: out-of-process helper

The running `winghostty.exe` must never directly execute a flow that requires
its own files to be replaced. Add a dedicated update helper in a later code
tranche:

- launched from the staged update area or another non-overwritten location
- receives:
  - parent PID
  - install mode
  - current install root
  - stage dir
  - target version
  - whether relaunch was requested
- waits for the parent app to exit
- re-verifies staged assets
- applies the update
- relaunches the app on success when requested

Using a dedicated helper is simpler and safer than trying to reuse the main app
binary while that same binary is being replaced.

### Installer-managed apply flow

When `install_mode = installed` and a verified installer is staged:

1. App surfaces "Update ready" UI.
2. User chooses `Restart and install`.
3. App writes `apply_requested_at` into `update-state.json`.
4. App spawns the update helper and exits cleanly.
5. Helper waits for all `winghostty.exe` processes from the same install root
   to exit.
6. Helper launches the staged installer elevated with `ShellExecuteExW` and the
   `runas` verb.
7. Helper passes fixed silent-update arguments, including:
   - no interactive wizard
   - no machine reboot
   - explicit `/DIR=<current install root>` so custom install locations are
     preserved
   - log path inside the stage dir
8. Installer exits:
   - success -> helper relaunches installed `winghostty.exe`
   - UAC canceled -> helper preserves the staged payload and records a
     non-blocking failure
   - nonzero exit -> helper records failure and leaves the old install in place

Notes:

- Session restore is not guaranteed.
- The current app must not try to keep windows alive while apply is in
  progress.
- If the installer requires script-level changes for silent close behavior,
  those changes belong in `dist/windows/winghostty.iss`.

### Portable apply flow

When `install_mode = portable` and a verified ZIP is staged:

1. App surfaces "Update ready" UI.
2. User chooses `Restart and update`.
3. App spawns the update helper and exits.
4. Helper waits for the current app process to exit.
5. Helper verifies the current executable directory is writable and still
   matches the detected portable layout.
6. Helper extracts the ZIP into the stage dir if not already extracted.
7. Helper copies the current packaged tree into `rollback\`.
8. Helper atomically replaces known packaged files/directories in place:
   - `winghostty.exe`
   - `winghostty.com`
   - `ghostty-vt.dll`
   - bundled `share\`
   - packaged docs/icons/templates that ship beside the exe
9. Helper relaunches the new `winghostty.exe`.

Portable failure rules:

- If replacement fails before completion, restore from `rollback\`.
- If relaunch/version confirmation fails, surface a failure banner on the next
  startup and keep rollback artifacts for inspection.
- If the portable directory is not writable or is on an unsupported location,
  degrade to the release-page flow instead of mutating it.

## UAC And Restart Behavior

- `check` mode never triggers UAC.
- `download` mode only triggers UAC when the user explicitly asks to apply an
  installer-managed update.
- UAC cancel is a normal recoverable outcome:
  - keep the staged payload
  - record a non-blocking failure reason
  - allow retry later
- Portable apply must never request elevation. If admin rights are needed to
  mutate the directory, that directory is not a supported portable auto-update
  target.

Relaunch behavior:

- On success, relaunch the normal GUI app entrypoint.
- Do not attempt to preserve arbitrary CLI actions in v2.
- If version verification after relaunch shows the old version, treat the apply
  as failed and surface that state to the user.

## UI Notifications And User Actions

Reuse current Win32 surfaces first:

- top-of-host update notice/banner in `src/apprt/win32.zig`
- app-level info banner fallback
- optional WinRT toast for "update ready" and "update failed while app not
  focused", reusing the existing toast activation plumbing

Notice states:

- `available-check`
  - message: update available
  - actions: `Open release page`, `Dismiss`
- `downloading`
  - message: downloading update
  - actions: optional `Open release notes`
- `ready-installer`
  - message: downloaded and ready to install
  - actions: `Restart and install`, `Later`, `Release notes`
- `ready-portable`
  - message: downloaded and ready to update
  - actions: `Restart and update`, `Later`, `Release notes`
- `failed`
  - message: update failed
  - actions: `Retry`, `Open release page`, `Dismiss`

Dismissal semantics:

- Existing "dismiss this version" behavior remains for `check`.
- `Later` on a staged update hides the notice for the current session but keeps
  the staged payload.
- Trust failures do not silently disappear. They log clearly and surface a
  recoverable failure state on manual checks.

Manual action behavior:

- `.check_for_updates`
  - stable + `check` -> current notify-only behavior
  - stable + `download` -> may immediately start background download if the
    candidate passes trust checks
  - tip -> current "open releases" fallback until a future prerelease tranche

## Failure States And Rollback

### Fail before apply

Examples:

- network error
- missing asset
- bad checksum signature
- hash mismatch
- invalid Authenticode
- install mode unknown

Behavior:

- do not mutate the current install
- delete incomplete partial files
- keep logs
- block the version only for trust failures, not for transient transport errors

### Fail during installer apply

Behavior:

- rely on the installer's own transactional behavior for partial update cleanup
- do not claim success until the relaunched app reports the new version
- keep the staged metadata/logs for diagnostics

### Fail during portable apply

Behavior:

- restore from `rollback\`
- relaunch the old version if restoration succeeded
- leave rollback artifacts and apply logs if restoration failed

### Post-startup confirmation

On app startup:

- if `update-state.json` says an apply was requested
- and the running version is now the staged target version
  - clear staged state
  - delete obsolete stage/rollback dirs
- else
  - mark the apply as failed
  - surface a clear banner

## CI And Release Packaging Requirements

### `scripts/package-windows.ps1`

Required future changes:

- sign every production PE that will be auto-applied or executed
- continue writing `SHA256SUMS.txt`

### `dist/windows/winghostty.iss`

Required review points for silent updater compatibility:

- keep stable `AppId` / install identity
- preserve shortcut/AUMID behavior already relied on by the Win32 runtime
- make silent upgrade assumptions explicit if Inno defaults are not enough
  (close-running-app behavior, restart suppression, log-friendly execution)

### `.github/workflows/release.yml`

Required future changes:

- fail the release if any required asset is missing
- keep publishing both installer and portable assets

### `scripts/package-package-managers.ps1`

Required future changes:

- keep installer and portable hashes aligned with the checksum manifest

### `scripts/release-preflight.ps1`

Required future changes:

- validate that release signing is configured when `download` mode is intended
  to be trustworthy in production

## Security And Threat Model

### Threats addressed

- GitHub API or release-page tampering in transit
  - mitigated by TLS plus Authenticode verification on the installer
- Corrupt or replaced downloaded artifact
  - mitigated by checksum validation and re-hash before apply
- Unsigned or differently signed installer
  - mitigated by Authenticode verification before execute
- Stale or replayed older release
  - mitigated by semver-greater checks and blocked-version handling
- Post-download tampering inside the stage directory
  - mitigated by re-verification immediately before apply

### Threats explicitly not solved

- Full compromise of the local user account
- Malicious code already running with the same user rights
- Offline theft of the Authenticode signing private key
- Session continuity or user-shell command replay after restart

### Operational trust assumptions

- The Authenticode certificate used for production releases is stable and
  valid.
- Release workflow environment protections are enforced before public release.

## Test And Harness Plan

### Zig unit tests

Extend targeted tests under `src/update/github_releases.zig` and related future
Win32 updater modules for:

- stable candidate selection
- future prerelease candidate filtering
- missing/malformed checksum lines
- blocked-version behavior
- state schema migration from v1 -> v2
- install-mode classification with synthetic paths
- portable rollback plan generation

### Verification fixtures

Add test fixtures for:

- valid `SHA256SUMS.txt`
- hash mismatch
- missing asset line
- invalid Authenticode signature

### Packaging script validation

Add narrow script-level checks that validate:

- `scripts/package-windows.ps1` emits `SHA256SUMS.txt`
- missing signing inputs fail closed

### Interactive/manual Win11 harness

Reuse the existing `scripts/interactive-win11.*` sandbox style for manual
update validation. The eventual harness should exercise:

- installer-mode stage -> apply -> relaunch
- UAC cancel
- portable-mode stage -> swap -> relaunch
- portable rollback after forced copy failure
- preservation of `%LOCALAPPDATA%\winghostty\config.ghostty`

### Release workflow gate

Before publishing a release, CI should verify:

- setup exe present
- portable ZIP present
- `SHA256SUMS.txt` present
- Authenticode valid where required
- hashes in the checksum file match the uploaded assets exactly

## Staged Implementation Milestones

### Milestone 1: Data-model and state groundwork

- Extend `src/update/github_releases.zig` to retain asset metadata needed by
  Win32.
- Extend `update-state.json` to a v2 schema.
- Keep user-visible behavior notify-only.

### Milestone 2: Trust pipeline and release packaging

- Keep `scripts/package-windows.ps1` emitting `SHA256SUMS.txt`.
- Verify runtime checksum and Authenticode checks.
- Keep apply disabled; stage only in test/dev harnesses.

### Milestone 3: Installer-mode download and ready-to-apply UX

- Add install-mode detection.
- Add staging layout and verified background download for installer mode.
- Surface `Restart and install` UI once the stage is ready.

### Milestone 4: Installer apply helper, UAC, and relaunch

- Add the dedicated update helper.
- Implement out-of-process silent installer handoff.
- Confirm version after relaunch.

### Milestone 5: Portable-mode swap and rollback

- Add portable writable-layout detection.
- Implement extracted-tree swap and rollback.
- Add manual harness coverage for rollback failure cases.

### Milestone 6: Tip-channel and polish

- Consider prerelease candidate selection for `tip`.
- Add toast actions and polish around ready/failed states.
- Update user-facing docs once production behavior changes.

## Likely Implementation Areas

These are the files most likely to move first once coding starts:

- `src/update/github_releases.zig`
- `src/apprt/win32.zig`
- `scripts/package-windows.ps1`
- `dist/windows/winghostty.iss`
- `.github/workflows/release.yml`
- `scripts/release-preflight.ps1`
- `scripts/package-package-managers.ps1`

Expected new code will probably live under `src/update/` plus a dedicated
out-of-process helper target, but the exact file split should be decided during
implementation once the state/verification pieces are extracted cleanly.
