# winghostty Product Context

This context defines the product language used to evaluate winghostty's
direction and user experience.

## Language

**Native Windows Developer Terminal**:
A terminal emulator optimized for the fastest, most fluid native terminal workflow for Windows developers.
_Avoid_: Cross-platform Ghostty port, Windows Terminal clone, feature-parity fork

**Canonical Benchmark User**:
A keyboard-first Windows developer who moves between PowerShell and WSL, keeps several tabs and panes open, runs long-lived shells and TUIs, and expects session layouts to survive restarts.
_Avoid_: Generic power user, all developers

**Interaction Fluidity**:
The felt continuity between intent, visible feedback, and completed action during terminal work.
_Avoid_: Animation smoothness, benchmark speed

**Safe Recovery**:
A temporary launch state that restores access to a working terminal without overwriting the user's normal configuration or saved session layout.
_Avoid_: Factory reset, rollback

**Window**:
A top-level operating-system window containing one or more tabs.
_Avoid_: Host, workspace

**Tab**:
A switchable session layout within a window.
_Avoid_: Window, workspace

**Pane**:
A visible terminal region within a tab.
_Avoid_: Split, surface

**Session Layout**:
The restorable arrangement of windows, tabs, and panes plus their user-visible placement metadata.
_Avoid_: Workspace, session process

**Universal Palette**:
The searchable command surface for actions, open terminal locations, profiles, settings, and help.
_Avoid_: Command palette, launcher
