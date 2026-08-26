# Upstream merge cadence (C33)

This fork is a hard fork of Ghostty. We do not upstream Windows work.
We do absorb upstream `main` on a published cadence so the 1.4 wave
(scriptability, tmux-control GUI, graphical preferences) does not land
as one conflict bomb.

## Policy

- Remote: `upstream` = `https://github.com/ghostty-org/ghostty.git`.
  Never push it.
- Cadence: merge `upstream/main` into this fork's default branch at
  least once per upstream weekly snapshot, and immediately after each
  Ghostty minor tag.
- Method: merge commits, not rebase of published history. Do not
  force-push default-branch SHAs.
- Conflict owners: `src/apprt/win32.zig` and `src/config/Config.zig`
  stay fork-owned. Prefer taking upstream VT/renderer/font fixes and
  re-applying Win32 call sites.
- 1.4 gate: C25 verb design waits until upstream scriptability shape
  is visible in a merged snapshot.

## Drift record

Record the last absorbed upstream SHA in
[dist/windows/release-metadata.json](../dist/windows/release-metadata.json)
(`upstreamBase` / equivalent). Release notes should name that SHA.

## Sync tooling

Updater and docs default to `api.github.com`. Re-point with
`WINGHOSTTY_UPDATE_API_BASE` if the GitHub API origin changes (C31).
Keep `origin` pinned at `amanthanvi/winghostty`.
