# Contributing to winghostty

Thanks for working on `winghostty`.

This repository is a public Windows-first project. Issues and pull requests
are welcome, but contributions need to be tight, technically defensible, and
validated against the Windows runtime shipped here.

For usage questions, design discussion, or anything that isn't a
reproducible bug, use
[Discussions](https://github.com/amanthanvi/winghostty/discussions). GitHub
Issues on this repo are reserved for reproducible bugs so triage stays
signal-heavy.

## Contribution Rules

1. Understand the change end to end before calling it done.
2. Prefer Windows-native behavior when it conflicts with upstream
   cross-platform behavior.
3. Keep the scope tight and minimal — one logical change per PR, with
   validation results in the description. Call out risks or follow-up work
   if a change is intentionally partial.
4. Preserve `libghostty-vt`; it remains a supported deliverable in this
   repo.
5. Keep docs, packaging, and user-visible strings aligned with the shipped
   `winghostty` product identity.

## Before You Open A PR

- Read [HACKING.md](HACKING.md) for build, test, validation, and runtime
  commands, and use the narrowest command that covers your change.
- For UI or interaction changes, read [PRODUCT.md](PRODUCT.md) and
  [DESIGN.md](DESIGN.md) first — they define the product direction and the
  visual/interaction contract your change will be reviewed against.
- Read any applicable `AGENTS.md` files before editing.
- If you use AI assistance, you are responsible for understanding and
  reviewing the final change. See [AI_POLICY.md](AI_POLICY.md).
- If the change touches input, rendering, window chrome, process startup,
  packaging, or update behavior, do the manual Windows checks in
  [HACKING.md](HACKING.md#manual-validation) as well.

## Scope Guard

This fork does not preserve upstream macOS or GTK app surfaces. Do not
reintroduce:

- macOS application packaging or Xcode workflows
- GTK, Wayland, or X11 app-runtime logic
- Linux desktop packaging such as Flatpak or Snap
