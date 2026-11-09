# Contributing to noctty

Thanks for working on noctty.

This repository is a public, Windows-only project. Issues and pull
requests are welcome, but contributions need to be small in scope, well
reasoned, and validated against the Windows runtime shipped here.

Upstream-derived changes must follow the [upstream merge policy](docs/upstream-merge-policy.md).

For usage questions, design discussion, or anything that isn't a
reproducible bug, use
[Discussions](https://github.com/amanthanvi/noctty/discussions).
GitHub Issues on this repo are reserved for reproducible bugs so real
bugs don't get buried.

## Contribution rules

1. Understand the change end to end before calling it done.
2. Prefer Windows-native behavior when it conflicts with upstream
   cross-platform behavior.
3. Keep the scope tight: one logical change per PR, with validation
   results in the description. Call out risks or follow-up work if a
   change is intentionally partial.
4. Preserve `libghostty-vt`: it stays buildable and tested from this repo
   (`zig build -Demit-lib-vt`), but no package ships it. From 1.3.137 the
   portable ZIP's `ghostty-vt.dll` is a placeholder that exports nothing and
   fails to load, kept for older portable updaters until v1.4.100, when
   portable copies on 1.3.125 to 1.3.136 that never took 1.3.137 or later
   have to update by hand ([PACKAGING.md](PACKAGING.md#library-consumers)).
5. Keep docs, packaging, and user-visible strings aligned with the
   shipped `noctty` product identity.

## Before you open a PR

- Read [HACKING.md](HACKING.md) for build, test, validation, and runtime
  commands, and use the narrowest command that covers your change.
- For UI or interaction changes, read [PRODUCT.md](PRODUCT.md) and
  [DESIGN.md](DESIGN.md) first. They define the product direction and
  the visual/interaction contract your change will be reviewed against.
- Read any applicable `AGENTS.md` files before editing.
- If you use AI assistance, you are responsible for understanding and
  reviewing the final change. See [AI_POLICY.md](AI_POLICY.md).
- If the change touches input, rendering, window chrome, or process
  startup, do the manual Windows checks in
  [HACKING.md](HACKING.md#manual-validation) as well.
- If it touches packaging or update behavior, follow the release runbook
  in [PACKAGING.md](PACKAGING.md#release-runbook) instead; the manual
  checks above don't cover that path.

## Scope guard

This fork does not preserve upstream macOS or GTK app surfaces. Do not
reintroduce:

- macOS application packaging or Xcode workflows
- GTK, Wayland, or X11 app-runtime logic
- Linux desktop packaging such as Flatpak or Snap
