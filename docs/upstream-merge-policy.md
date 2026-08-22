# Upstream merge policy

## Posture

noctty is a hard fork of Ghostty. It adopts upstream work through deliberate,
scheduled merge windows while retaining a Windows-only application runtime and
fork-owned product behavior. This follows the roadmap's
[published non-goal 9](../plans/2026-competitive-roadmap.md#published-non-goals)
and its
[C33 ruling](../plans/2026-competitive-roadmap.md#c33--upstream-merge-cadence--published-merge-policy--sm-recurring--141).

This policy is not a daily-rebase soft-fork process. Sync work does not rebase
or force-push fork branches, and fork work is not upstreamed to
`ghostty-org/ghostty`. The `upstream` remote is read-only; never push to it.

## Cadence

A normal merge window opens after each tagged upstream Ghostty release. An
out-of-band window may open for an applicable upstream security fix, with a
target of opening within seven calendar days after the fix is identified. That
target is planning guidance for a single-maintainer project, not an SLA.

Each window produces a dated drift report under `plans/`. A window may produce
several sync PRs, but each subsystem appears in at most one of them, so review,
validation, and rollback remain bounded.

## Merge scope

The following paths are eligible for upstream merges. Eligibility does not make
a change automatic; the conflict and validation rules below still apply.

- Terminal and VT core: `src/terminal/**`, `src/simd/**`
- Renderer: `src/renderer/**`, `src/renderer.zig`
- Font: `src/font/**`
- Config: `src/config/**`, `src/config.zig`
- Input and keybindings: `src/input/**`, `src/input.zig`
- Shell integration: `src/shell-integration/**`
- Termio and PTY: `src/termio/**`, `src/termio.zig`, `src/pty.zig`, `src/pty.c`
- CLI: `src/cli/**`, `src/cli.zig`
- `libghostty-vt`: `src/lib_vt.zig`, `src/terminal/c/**`,
  `include/ghostty/**`

The following upstream paths are never merged into the fork:

- GTK runtime: `src/apprt/gtk*`, `src/apprt/gtk/**`
- macOS application and packaging: `macos/**`, `dist/macos/**`
- Linux application packaging: `dist/linux/**`, `flatpak/**`, `snap/**`
- Nix application packaging: `nix/package.nix`, `nix/tests.nix`, `nix/vm/**`
- Upstream CI workflows: `.github/workflows/**`
- Upstream community and governance files: `.github/VOUCHED.td`,
  `CODEOWNERS`, `CONTRIBUTING.md`

## Fork-owned files

The fork wins by default when a conflict crosses Windows platform behavior or
a fork-owned feature. The current high-risk seams are:

- `src/apprt/**`
- `src/config/Config.zig`
- `src/Surface.zig`
- `src/renderer/Thread.zig`
- `src/renderer/generic.zig`
- `src/termio/Termio.zig`
- `src/termio/Exec.zig`
- `src/termio/stream_handler.zig`
- `src/termio/shell_integration.zig`
- `src/terminal/search/sliding_window.zig`
- `src/terminal/search/Thread.zig`
- `src/terminal/PageList.zig`
- `src/terminal/Terminal.zig`
- `src/Command.zig`
- `src/font/discovery.zig`

Upstream wins on VT and protocol correctness and on memory-safety fixes, but
those changes must be adapted around fork-owned Windows behavior rather than
overwriting it. If neither rule resolves a conflict cleanly, add the change to
the window's deferred list with a written reason; do not force it through.

## Recording the base

At the end of a completed merge window, update
`dist/windows/release-metadata.json` so `upstreamBaseVersion` identifies the
upstream version line represented by the new base. Keep `firstForkPatch` at
`100`. Record the exact merge-base SHA and date in the window's dated drift
report.

Public tags remain plain semantic versions. `major.minor` tracks the upstream
Ghostty line, while `patch` is fork-owned beginning at `100`: `1.3.100`,
`1.3.101`, and so on. The exact upstream base does not appear in the public
tag. The current base is `ba398dfff` from 2026-04-05: post-`v1.3.1` upstream
main, represented as `1.3.2-dev`, not a released upstream tag.

## Validation gates

Every merge window must run:

```powershell
zig fmt --check src
zig build -Demit-exe=true
zig build test -Demit-test-exe=true
pwsh -NoProfile -File scripts/check-source-format.ps1
```

When scripts or validation harnesses change, also run:

```powershell
pwsh -NoProfile -File test/windows/flagship/Test-VerificationContracts.ps1
```

Renderer or input picks also require the interactive Windows 11 composite
validator, plus the harnesses covering the affected surface (for example
`interactive-win11-ime-candidate.ps1` for preedit changes and
`interactive-win11-key-input.ps1` for key-encoding changes):

```powershell
pwsh -NoProfile -File test/windows/interactive-win11-validate.ps1 -ResetState
```

A pick in those areas is not certified until the relevant interactive result is
recorded in the window's drift report.

The full suite has a known pre-existing failure named
`Command: custom env vars`. Record that result as the baseline and reject any
new failure or change in its failure mode.

## Deferral

A pick that conflicts structurally is deferred to the next merge window with a
written reason in the dated drift report. It is never forced into the current
window.

## How to check drift

`scripts/upstream-drift.ps1` reads local refs only. Refresh the read-only
upstream tracking ref explicitly when network and Git metadata permissions
allow it, then run the report:

```powershell
git fetch upstream
pwsh -NoProfile -File scripts/upstream-drift.ps1
```

Use `-Remote` and `-Branch` only when checking another local tracking-ref pair.
The equivalent raw Git inputs are:

```powershell
$base = git merge-base HEAD upstream/main
git show -s --format='%H%x09%cs' $base
git rev-list --left-right --count HEAD...upstream/main
git diff --name-only "$base..HEAD"
git diff --name-only "$base..upstream/main"
git diff --diff-filter=D --name-only "$base..HEAD"
git show HEAD:dist/windows/release-metadata.json
```

The live overlap is the intersection of the two `--name-only` lists after
removing paths in the fork-deletion list.
