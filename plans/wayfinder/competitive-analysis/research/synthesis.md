# Synthesis: ranked gap list

Cross-reference of the twelve research reports in this directory against
winghostty ground truth (PRODUCT.md, docs/status.md,
docs/windows-capability-matrix.md, **and the code** — see the ground-truth
note below). Input to the batch decision session
([D01](../tickets/D01-decision-session.md)). Recommendations here are
provisional; the decision session rules.

Report shorthand: `[wintty]` = [wintty.md](wintty.md), `[wt]` =
[windows-terminal.md](windows-terminal.md), `[wez]` = [wezterm.md](wezterm.md),
`[warp]` = [warp.md](warp.md), `[ala]` = [alacritty.md](alacritty.md),
`[tabby]` = [tabby.md](tabby.md), `[conemu]` = [conemu.md](conemu.md),
`[rio]` = [rio.md](rio.md), `[up]` = [upstream-ghostty.md](upstream-ghostty.md),
`[lt]` = [long-tail.md](long-tail.md), `[wave]` = [wave-terminal.md](wave-terminal.md),
`[forks]` = [ghostty-windows-forks.md](ghostty-windows-forks.md).

**Ground-truth note (verified 2026-08-17 against the working tree).**
docs/status.md undersells the code. Grep/file verification: quick terminal
with `RegisterHotKey` global hotkey (`src/apprt/win32_quick_terminal.zig`),
WinRT toast notifications (`src/apprt/win32_toast_winrt.zig`,
`win32_toast_activation.zig`), taskbar progress
(`src/apprt/win32_taskbar_progress.zig`), and a docked scrollback search bar
(`src/apprt/win32_search_bar.zig`, wired in `win32.zig`) **all exist** and are
absent from status.md and the capability matrix. Consequently the
quake-mode/toast/taskbar "adopt" recommendations in `[wt]` §10.1–2, `[warp]`
§10.1, `[tabby]` §10.3, `[conemu]` §10.2, `[lt]`, and `[forks]` are **stale
against code** and are deduped here into C04 (docs accuracy), not listed as
build candidates. Verified genuinely absent: jump lists (no
`ICustomDestinationList`), default-terminal registration (no
`ITerminalHandoff`), Explorer context menu, bundled newer `conpty.dll`
(`src/pty.zig:430` calls in-box `kernel32.CreatePseudoConsole`), UTF-8
`chcp`/`OutputEncoding` preamble, cmd.exe shell integration, sixel/iTerm2
image decoding, broadcast input, SSH profile ingestion, named layouts, any
performance benchmark harness (`src/bench/` holds one palette microbench).

---

## 1. Executive summary

The Windows terminal field has no healthy occupant of winghostty's exact
position. The incumbent (Windows Terminal) is slowing and carries chronic
cold-start/latency/settings debt; the strongest power-user rival (WezTerm)
treats Windows as a port and hasn't shipped stable since Feb 2024; the
category-definers (Warp, Wave) are drifting into cloud/AI workspaces their
own users push back against; the minimal-fast pole (Alacritty) refuses the
benchmark user's workflow needs and is tier-2 on Windows; and the
Ghostty-on-Windows fork swarm is decaying, unsigned, and unverifiable. The
real strategic threats are not products but **facts**: upstream's trademark
statement naming winghostty (2026-07-12), and upstream's slow convergence on
Windows via libghostty and tiered contributions (12–24 month window).
Top-5 highest-leverage moves: (1) **publish reproducible Windows performance
benchmarks** — every competitor either can't or won't, and PRODUCT.md's core
claim is currently unfalsifiable (C01); (2) **fix status.md and market what
already exists** — quick terminal, toasts, taskbar progress, search are built
and invisible (C04); (3) **own the ConPTY layer** — bundle a newer
OpenConsole so the Kitty-graphics claim survives the user's OS (C05);
(4) **take the OS entry points nobody else has** — default-terminal
registration, jump lists, Explorer menu (C11–C13); (5) **deepen the session
promise** — scrollback-content restore now, durable-process feasibility spike
next (C15/C16). The naming/upstream questions (F1/F2) gate all marketing
spend and should be ruled first.

---

## 2. Ranked candidate list

IDs are global rank order (leverage = benchmark-user impact × competitive
differentiation ÷ cost). Grouped by theme; themes ordered by aggregate
leverage. Cost: S ≲ days, M ≲ weeks, L ≈ month+, XL ≈ quarter+.

### Theme A — Performance credibility

**C01. Published, reproducible Windows benchmark suite + CI perf gates.**

- _What:_ Adopt a vtebench-style harness plus Windows-specific metrics
  (cold-start-to-first-frame, camera/photodiode key-to-pixel latency, ConPTY
  round-trip, scroll throughput, frame-time p95, idle/peak memory), publish
  numbers vs Windows Terminal / Alacritty / Tabby / Wave on the same machine,
  and gate regressions in CI.
- _Evidence:_ `[ala]` §10.1 (vtebench, perf-as-artifact culture); `[wintty]`
  §2/§10.9 (rival's full metric plan exists but is unexecuted — publishing
  first converts it into winghostty marketing); `[wt]` §2/§10 (no published
  startup numbers; ~2x conhost latency per
  [chadaustin.me](https://chadaustin.me/2024/02/windows-terminal-latency/) —
  a vacuum to occupy); `[rio]` §10.6 (unverifiable self-reported MiB/s);
  `[warp]` §10 blind-spot 6; `[tabby]` §10.1 and `[wave]` §10.2 (Electron
  memory numbers users cite when leaving); `[forks]` §2 ("winghostty could
  own this axis simply by measuring").
- _Why:_ PRODUCT.md's purpose sentence ("fastest, most fluid") is the
  product's entire thesis and currently has zero evidence behind it; the
  benchmark user chooses on exactly these numbers.
- _Cost:_ M.
- _Recommendation:_ **Adopt.** Highest leverage item on the list: nobody in
  the field publishes credible Windows numbers, the claim is already made,
  and the harnesses are mostly off-the-shelf.

**C02. Power/battery awareness as a performance axis.**

- _What:_ Power-saver detection with adaptive rendering, unfocused-render
  throttling / target-fps knobs, occlusion-aware repaint, measured idle
  wattage as a published number.
- _Evidence:_ `[up]` §2/§9/§10.2 (upstream's "GPU or nothing" battery-drain
  complaint stream — a durable upstream blind spot to exploit); `[wintty]`
  §3/§10.8 (power-saver adaptive behavior shipped; idle-power bench planned);
  `[rio]` §10.3 (`target-fps`, `disable-unfocused-render`, low-power adapter
  preference); `[lt]` (laptops are the dominant dev hardware).
- _Why:_ The benchmark user works on a laptop; "fastest" that drains the
  battery loses the daily-driver decision, and upstream structurally
  deprioritizes this.
- _Cost:_ M.
- _Recommendation:_ **Adopt.** Cheap differentiation against upstream and
  every Electron rival; folds naturally into C01's scoreboard.

**C03. GPU floor and degraded-mode policy.**

- _What:_ Document the OpenGL 4.3+ requirement and what happens below it
  (RDP, VMs, old iGPUs, partially-robust drivers); fail gracefully with a
  visible message; decide later whether a lower-floor fallback renderer is
  worth building.
- _Evidence:_ `[ala]` §10.4/blind-spot 2 (GLES 2.0 floor, robustness crash
  hardening); `[warp]` §2 (GPU driver roulette crashes + documented backend
  switch); `[wez]` §2 (RDP auto-selects software rendering); `[wt]` §2 (D2D
  fallback for weak GPUs).
- _Why:_ Corporate/VM/RDP machines are normal Windows dev environments; a
  terminal that won't start there fails PRODUCT.md's "always leave a path
  back to a working terminal."
- _Cost:_ S (document + graceful fail) / L (real fallback path).
- _Recommendation:_ **Adopt** the S slice (documented floor + graceful
  failure); explicitly defer any fallback renderer until C01 data shows need.

### Theme B — Ground truth & docs

**C04. status.md accuracy + advertise the invisible features.**

- _What:_ Update status.md and the capability matrix to cover what the code
  ships — quick terminal with global hotkey, toast notifications, taskbar
  progress (OSC 9;4), docked scrollback search — then market them; audit for
  further omissions (status bar, link preview, paste protection modules exist
  in `src/apprt/`).
- _Evidence:_ Code verification above; `[wintty]` §10 ground-truth caveat
  (first report to notice); six other reports independently mis-list quake
  mode as a winghostty gap (`[wt]` `[warp]` `[tabby]` `[conemu]` `[lt]`
  `[forks]`) — i.e., the docs actively misinform competitive analysis, and
  will misinform users identically. `[ala]` §10.3's "no search UI at all"
  claim is likewise wrong against `win32_search_bar.zig`.
- _Why:_ Features the benchmark user can't discover don't exist for
  adoption purposes; docs are the product's only marketing surface today.
- _Cost:_ S.
- _Recommendation:_ **Adopt.** Do first — it re-baselines every other
  decision in this list and is nearly free.

### Theme C — Terminal capability

**C05. Own the ConPTY layer: bundle newer OpenConsole + degraded-mode
logging + a public mangling catalog.**

- _What:_ Ship a newer OpenConsole as `conpty.dll` beside the exe, prefer it
  over the in-box conhost, log a loud degraded-mode warning on fallback
  ("Kitty graphics and Sixel will not work"), and publish a
  ConPTY-mangling/mitigation catalog + measured esctest baseline in the
  spirit of docs/windows-vt-conformance.md.
- _Evidence:_ `[wintty]` §3/§10.1/§10.5 (in-box conhost silently strips
  Kitty APC/Sixel DCS; the bundled-dll + logged-fallback pattern; the
  esctest/latency-probe measurement culture —
  [conpty-reference.md](https://github.com/deblasis/wintty/blob/windows/windows/docs/vt-compliance/conpty-reference.md));
  `[rio]` §3/§10.1 (manual `conpty.dll` sideload as the user-hostile
  version); `[warp]` §3 (forked ConPTY to fix DCS filtering/OSC reordering);
  `[wt]` §3 (passthrough #1173 never shipped — the ecosystem ceiling);
  `[forks]` (ghostinthewsl embeds newer ConPTY too). winghostty verified:
  in-box `CreatePseudoConsole` only (`src/pty.zig:430`).
- _Why:_ winghostty's flagship capability claim (Kitty graphics, deep VT) is
  currently at the mercy of whatever conhost version the user's OS carries;
  this is the single biggest silent-failure risk in the product's core
  promise.
- _Cost:_ M.
- _Recommendation:_ **Adopt.** Directly protects the "deep terminal
  capability" differentiator; proven pattern with two working references.

**C06. UTF-8 console preamble with CJK-code-page guard.**

- _What:_ `chcp 65001` for cmd, `chcp` + `[Console]::OutputEncoding` for
  PowerShell 5.1/7, behind a `utf8-console = auto|always|never` config with a
  guard refusing auto-forcing on legacy CJK ANSI code pages.
- _Evidence:_ `[wintty]` §3/§10.2 (complete tested design to copy);
  grep-verified absent in winghostty.
- _Why:_ Nerd-Font/oh-my-posh mojibake in cmd/PowerShell is a first-session
  failure for exactly the PowerShell-first benchmark user.
- _Cost:_ S.
- _Recommendation:_ **Adopt.**

**C07. cmd.exe shell integration via `PROMPT` + optional Clink lua.**

- _What:_ Emit OSC 133;A/B and OSC 9;9 (cwd) from the `PROMPT` env var;
  auto-load a Clink script for 133;C/D + exit codes when Clink is present.
- _Evidence:_ `[wintty]` §4/§10.3 (unique among forks; degrades gracefully);
  status.md explicitly leaves cmd a "plain fallback"; `[warp]` §3 doesn't
  support cmd at all (differentiation).
- _Why:_ Closes the last unsupported-shell gap cheaply; cwd-correct session
  restore and prompt-jump then work in cmd too.
- _Cost:_ S.
- _Recommendation:_ **Adopt.**

**C08. Ghostty 1.3-surface Win32 wiring audit.**

- _What:_ One-time audit that 1.3 core features present in the fork's
  1.3.2-dev baseline actually behave on Win32: `scrollbar` (native overlay
  equivalent?), Kitty keyboard protocol on the Win32 input path,
  notify-on-command-finish trio → the existing toast pipeline, `key-remap`,
  clipboard-codepoint-map; document results in the capability matrix.
- _Evidence:_ `[up]` §7/§10.6 ("config presence was verified locally, apprt
  wiring was not"); `[wt]` §10.6 (Kitty keyboard now table stakes — WT 1.25
  shipped it).
- _Why:_ Inherited-on-paper features that silently no-op on Windows are
  precisely the "generic parity fork" failure PRODUCT.md's anti-references
  name.
- _Cost:_ S.
- _Recommendation:_ **Adopt.**

**C09. Sixel + iTerm2 inline image protocols.**

- _What:_ Add sixel (and iTerm2 OSC 1337 display, whose parsing 1.3 already
  carries) alongside the shipped Kitty graphics.
- _Evidence:_ `[rio]` §4 (ships all three); `[wt]` §4 (sixel shipped 1.22/23;
  Kitty graphics still open — winghostty's current edge is Kitty, not
  sixel); `[wez]` §4 (sixel "preliminary"); `[tabby]`/`[wave]` (none — not a
  competitive floor); `[lt]` (WSL legacy tooling uses sixel).
- _Why:_ Some WSL-side tools are sixel-only; but Kitty covers modern TUIs
  and C05 must land first for _any_ protocol to survive ConPTY.
- _Cost:_ M.
- _Recommendation:_ **Defer** until after C05; revisit if user demand
  materializes.

**C10. WSL transport upgrades: keepalive now, VSOCK PTY bypass later.**

- _What:_ (a) WSL VM keepalive so WSL profiles stop timing out (S);
  (b) longer-term: a Hyper-V-socket bridge allocating real Linux PTYs for
  WSL sessions, bypassing ConPTY stripping entirely (L).
- _Evidence:_ `[forks]` §3/§10 (ghostinthewsl's VSOCK bridge — "the
  strongest technical challenge to winghostty's WSL story"; keepalive called
  "a cheap adopt"); `[conemu]` §3 (wslbridge precedent); `[wave]` §10.4
  (WSL-as-remote-connection is the failure mode to avoid).
- _Why:_ WSL is half the benchmark user's definition; a real-PTY path makes
  every VT capability work unconditionally in WSL.
- _Cost:_ S (keepalive) + L (bypass).
- _Recommendation:_ **Defer** the bypass (C05 reduces its urgency); adopt
  the keepalive slice opportunistically.

### Theme D — Native Windows integration (OS entry points)

**C11. Default-terminal registration (`ITerminalHandoff`).**

- _What:_ Register winghostty as a selectable Windows 11 "default terminal
  application" so console apps launched from Explorer/IDEs open in it.
- _Evidence:_ Open, unfulfilled requests against every rival: `[ala]`
  [#6036](https://github.com/alacritty/alacritty/issues/6036), `[wez]`
  #7534, `[warp]` #6261, `[tabby]` #4882; `[conemu]` §3 (burned a decade
  faking it via injection — the stickiest feature it had); `[wt]` §3 (only
  WT has it); `[wintty]` §3 (roadmap-only, rated high-complexity). Verified
  absent in winghostty.
- _Why:_ This is how a terminal becomes _the_ terminal — it captures the
  consoles the user didn't explicitly launch; first-mover among all
  non-Microsoft terminals.
- _Cost:_ M (COM registration + handoff stability work).
- _Recommendation:_ **Adopt.**

**C12. Taskbar jump lists (`ICustomDestinationList`).**

- _What:_ Recent directories + pinned profiles (and named layouts once C17
  exists) in the taskbar right-click jump list.
- _Evidence:_ `[wintty]` §3/§10.4 (shipped); `[conemu]` §3/§10.4 (tasks in
  jump lists, decade-proven); `[wt]` §3. Verified absent (no
  `ICustomDestinationList` usage).
- _Why:_ Taskbar re-entry into a cwd/profile is core native-feel for a
  keyboard-first user who pins the terminal.
- _Cost:_ S.
- _Recommendation:_ **Adopt.**

**C13. Explorer "Open winghostty here" context menu.**

- _What:_ Classic registry + Win11 `IExplorerCommand` context-menu entry for
  directories/background.
- _Evidence:_ `[ala]` §3 (shipped 0.12 even in a minimal terminal);
  `[conemu]`/`[lt]` (ConEmu/Fluent/Cmder all had it); `[tabby]` §3 (users
  struggle with the registry hack). Verified absent.
- _Why:_ Cheapest possible OS entry point; expected by every Windows dev.
- _Cost:_ S.
- _Recommendation:_ **Adopt.**

**C14. Elevation as a designed surface.**

- _What:_ Document the elevation model (what running winghostty elevated
  means, what restore does with elevated sessions); add a "run elevated"
  profile flag / palette action that opens an elevated window with clear
  visual marking. Mixed-elevation tabs in one window are explicitly out.
- _Evidence:_ `[conemu]` §3/§10.1 (`-new_console:a` elevated tabs — the
  unmatched decade-old affordance); `[wt]` §3/§10.8 (deliberate
  separate-window model, documented; users still complain); `[wave]` §3
  (open "admin console" ask); winghostty docs silent beyond updater UAC.
- _Why:_ The benchmark user runs elevated shells weekly; an undesigned
  surface here violates "be native where behavior matters."
- _Cost:_ M (posture + elevated-window action); mixed-elevation would be XL.
- _Recommendation:_ **Adopt** the documented model + elevated-window action;
  defer anything resembling mixed-integrity tabs.

### Theme E — Workflow features

**C15. Scrollback-content restore.**

- _What:_ Optionally persist and restore the last N lines of each pane's
  scrollback with `window-save-state`, clearly marked as a snapshot.
- _Evidence:_ `[wt]` §5/§10.3 (buffer snapshots shipped 1.21; rollout bugs
  show the reliability bar); `[warp]` §5/§10.3 (restored blocks via SQLite —
  a top retention feature); `[lt]` §a.1 (users now expect more than layout).
  status.md: contents explicitly not restored.
- _Why:_ existing restore preserves layout and pane metadata but no scrollback content, so a restored pane starts blank; even flawed text restore beats none, and winghostty's transactional session machinery can do it exactly.
- _Cost:_ M.
- _Recommendation:_ **Adopt.**

**C16. Durable local sessions (processes survive UI restart).**

- _What:_ A local mux/daemon concept (or ConPTY-handle survival) so shells
  and TUIs keep running across window close/crash/update and reattach with
  scrollback.
- _Evidence:_ `[wez]` §5/§10.1 (mux domains — the crown jewel; "would
  leapfrog every Windows-native competitor"); `[wave]` §5/§10.1 (durable
  SSH sessions shipped, users immediately asked for local —
  [#3248](https://github.com/wavetermdev/waveterm/issues/3248)); `[lt]` §a.1
  (Contour daemon+attach; ranked the #1 blind spot); `[wt]` §9.5 (text-only
  restore is a chronic complaint).
- _Why:_ The strongest possible fulfillment of PRODUCT.md's restart promise;
  no Windows-native terminal has it.
- _Cost:_ XL (process lifetime, ConPTY ownership, reattach protocol).
- _Recommendation:_ **Defer, with a funded feasibility spike.** Impact is
  top-3 but cost and technical risk (ConPTY handle lifetime) are unproven;
  C15 buys most of the felt value now. Candidate for its own grilling
  ticket.

**C17. Named layouts ("tasks"): profile + split layout + hotkey in one
object.**

- _What:_ A named workspace definition (commands, cwds, split tree) that
  materializes on one keystroke / palette entry / CLI flag / jump-list
  click.
- _Evidence:_ `[conemu]` §5/§10.3 (Tasks — the signature system); `[warp]`
  §5/§10.2 (Tab Configs/launch configurations); `[wez]` §5 (workspaces);
  `[forks]` (hollow workspaces). winghostty restores only the _last_
  implicit layout.
- _Why:_ Turns session restore from "what I had" into "what I want":
  project switching for the tabs-and-splits benchmark user.
- _Cost:_ M (session-persistence machinery already exists to build on).
- _Recommendation:_ **Adopt.**

**C18. Quick-select / hints + modal copy mode.**

- _What:_ Regex-driven keyboard capture of visible text (URLs, paths,
  hashes, IPs → open/copy/paste/pipe) plus a modal keyboard
  selection/scrollback-navigation mode.
- _Evidence:_ `[ala]` §4/§10.2–3 (hints + vi mode — the polished
  reference); `[wez]` §5/§10.3 (quick select + copy mode); `[rio]` §4/§10.4
  (hints); `[forks]` (hollow quick-select); `[lt]` §a.4 (Contour modal
  input). Only URL hover-hints exist in winghostty today.
- _Why:_ Pure keyboard-first territory — PRODUCT.md's second principle with
  no current implementation; high daily-use frequency.
- _Cost:_ M.
- _Recommendation:_ **Adopt.**

**C19. Prompt-mark navigation verbs, surfaced.**

- _What:_ Jump-to-previous/next-command, copy-last-command-output,
  re-run-last-command as palette actions/keybinds built on the OSC 133
  marks winghostty already emits (incl. PowerShell).
- _Evidence:_ `[warp]` §10.4 ("80% of blocks' daily value with 0% of the
  ConPTY-fork cost"); `[rio]` §10.5 (ScrollToPrev/NextPrompt); `[lt]` §a.3
  (Extraterm framing — block value without AI); `[wt]` §4 (marks
  de-experimentalized; "finishing marks" still unfinished — a lead to take);
  `[ala]` §10.5 (advantage must be _felt_, not just implemented).
- _Why:_ Converts already-shipped shell integration into visible daily
  value; answers the Warp/blocks trend without architecture cost.
- _Cost:_ S.
- _Recommendation:_ **Adopt.**

**C20. SSH host ingestion into profiles/palette (lean).**

- _What:_ Parse `%USERPROFILE%\.ssh\config`, surface hosts as launchable
  profiles/palette entries (running the system `ssh`); no bundled SSH
  client, no vault.
- _Evidence:_ `[tabby]` §5/§10.1 (connection manager is the #1 adoption
  driver behind 74k stars; "even a lean version captures most value");
  `[wez]` §5/§10.5 (auto-populated SSH domains); `[wt]` §3 (1.24 SSH
  auto-detection); `[lt]` (Termius/MobaXterm define the SSH slice).
- _Why:_ The benchmark user's week includes remote hosts; winghostty
  already wraps ssh for terminfo (`shell-integration` notes) — discovery is
  the missing piece.
- _Cost:_ M.
- _Recommendation:_ **Adopt** the lean slice; anything deeper waits on F8.

**C21. Snippets / saved-commands library.**

- _What:_ A persistent, local, user-curated command library in the palette
  (beyond the existing recent-commands provider).
- _Evidence:_ `[wt]` §5 (snippets pane + scratchpad); `[warp]` §5/blind-spot
  2 (Drive workflows — team version); `[tabby]` (login scripts).
- _Why:_ "Remembering commands" is a real daily workflow, but recents cover
  much of it and the palette provider model makes this easy later.
- _Cost:_ M.
- _Recommendation:_ **Defer.**

**C22. Broadcast input to multiple panes.**

- _What:_ Toggle typing into all panes of a tab with clear visual marking.
- _Evidence:_ `[wt]` §5 (shipped 1.19); absent everywhere else surveyed;
  no report ranks it high.
- _Cost:_ S/M. _Recommendation:_ **Defer** — low frequency for the
  benchmark user; revisit on demand signal.

**C23. Vertical/side-docked tabs + tab overview.**

- _What:_ Optional vertical tab strip for wide monitors; tab overview.
- _Evidence:_ `[wintty]` §5 (marketed differentiator); `[wave]` §5
  (vertical tabs v0.14.4).
- _Cost:_ M. _Recommendation:_ **Defer** — chrome work with modest
  differentiation; conflicts with "chrome justifies every pixel" until
  demand shows.

**C24. Secrets via Windows Credential Manager / Windows Hello.**

- _What:_ OS-native secret storage exposed to shells/SSH on demand.
- _Evidence:_ `[tabby]` §5/§10.2 (vault is a stated switching reason);
  `[wave]` §10.5; `[lt]` §a.5 (Hello/FIDO2/smart-card expectations).
- _Cost:_ M/L. _Recommendation:_ **Defer** — real demand but downstream of
  the F8 remote-scope ruling; do not build before C20 proves the SSH slice.

### Theme F — Configuration & extensibility

**C25. Documented automation surface (CLI verb set over the running app).**

- _What:_ Grow `+list-windows` / allowlisted `+perform-action` into a
  stable, documented, PowerShell-friendly verb set (open/split/launch
  profile/query state/run named layout), aligned with upstream 1.4's
  scriptability contract when it lands; explicitly not an embedded
  language or plugin runtime.
- _Evidence:_ `[wez]` §7/§10.2 (Lua+plugins let users self-serve features —
  the biggest capability gap named); `[wt]` §7/§10.6 (a decade-old product
  still has no extensibility — vacuum); `[conemu]` §7 (GuiMacro precedent);
  `[wave]` §10.3 (`wsh` verb-set value, minus the remote-injection
  mistake); `[ala]` §10.3 (unix-only IPC — winghostty already ahead on
  Windows); `[up]` §10.4 (align with upstream's eventual contract);
  `[forks]` (hollow's LuaJIT shows where a rival differentiates).
- _Why:_ Lets keyboard-first users and their scripts drive the terminal;
  multiplies a solo maintainer by letting users build their own missing
  features.
- _Cost:_ L.
- _Recommendation:_ **Adopt** (staged; verb design after upstream 1.4's
  scriptability shape is visible, per C33).

**C26. Config/settings portability stance (file-based, no service).**

- _What:_ Documented answer for multi-machine users: config in a syncable
  location, portable-mode config discovery, conflict-aware merge (the
  revision-aware settings merge already exists).
- _Evidence:_ `[tabby]` §7/§10.3 (tabby-web sync collapse — demand AND the
  maintenance trap); `[warp]` blind-spot 5; `[lt]` (Termius sync
  expectations); `[wez]` §3 (thumb-drive mode).
- _Cost:_ S/M. _Recommendation:_ **Defer** decision; never ship a sync
  service (see rejects R7).

### Theme G — Distribution & trust

**C27. Identity, trust, and verification page + migration guide.**

- _What:_ A "why winghostty / how we differ from the fork swarm / how to
  verify our binaries (signing, checksums, reproducibility) / what we will
  never do" page, plus a "migrate from Windows Terminal" (and Git
  Bash/mintty) guide; keep release cadence visible.
- _Evidence:_ `[forks]` §9/§10 (fork confusion documented in upstream's own
  thread; "trust is the moat the swarm cannot cross"); `[wintty]` §10.1
  (winghostty is today the only installable Ghostty-on-Windows with
  releases — exploit loudly); `[warp]` §8/§10.5 (migration guide as
  deliberate adoption lever); `[lt]` (Git Bash users "never chose a
  terminal; they are winnable"); `[wez]`/`[conemu]`/`[wave]` (cadence
  visibility as retention — stale-stable and stalls bleed users).
- _Why:_ Every distribution advantage winghostty already has is currently
  unmarketed; conversion is blocked on discoverability and trust, not
  capability. Note: contingent on F1 (naming) ruling first.
- _Cost:_ S.
- _Recommendation:_ **Adopt**, sequenced after F1.

**C28. SmartScreen/signing reputation hardening.**

- _What:_ Pursue SignPath Foundation or EV-grade reputation so first-run
  SmartScreen warnings disappear; sign or attest the portable ZIP container.
- _Evidence:_ `[ala]` §3/§10.5 (unsigned since 2021; SignPath proposal
  [#8725](https://github.com/alacritty/alacritty/issues/8725)); `[rio]` §3
  ("click Run anyway" docs); `[conemu]` §9 (AV reputation death spiral);
  status.md's own caveat (SmartScreen can still warn).
- _Why:_ The last trust gap in an otherwise best-in-field distribution
  story; SmartScreen warnings kill first installs.
- _Cost:_ S/M.
- _Recommendation:_ **Adopt.**

**C29. Portable mode + portable-ZIP updater apply.**

- _What:_ Config/state discovery beside the exe ("thumb-drive mode") and
  implement the already-planned portable ZIP update apply/rollback.
- _Evidence:_ `[wez]` §3/blind-spot 4 (thumb-drive mode); `[tabby]` §3
  (portable `data` dir — "popular with locked-down-corporate users");
  `[lt]` (MobaXterm's portable single-exe owns a niche); status.md
  "what's next" already lists ZIP apply.
- _Why:_ Locked-down corporate machines are a genuine Windows persona the
  benchmark user often is.
- _Cost:_ M.
- _Recommendation:_ **Adopt.**

**C30. Additional package channels: Chocolatey (+ consider MSYS2).**

- _Evidence:_ `[wave]` §10.7 (winget+choco enterprise parity); `[rio]`
  §10.6 (choco+MSYS2 reach).
- _Why:_ Enterprise fleets script Chocolatey; near-zero maintenance cost.
- _Cost:_ S. _Recommendation:_ **Adopt.**

**C31. GitHub-coupling contingency.**

- _What:_ Abstract the updater endpoint (currently hardcoded
  `api.github.com`), monitor upstream's mirror freshness, be ready to
  re-point sync tooling when upstream's GitHub exodus completes.
- _Evidence:_ `[up]` §1/§10.5 (upstream leaving GitHub, destination
  unnamed; the fork's updater depends on infrastructure upstream just
  judged unreliable).
- _Cost:_ S. _Recommendation:_ **Adopt** (mitigation planning now, work as
  needed).

### Theme H — Reliability & quality engineering

**C32. Fork-surface fuzzing/QA + Win32 paste-path security audit.**

- _What:_ AFL++-style fuzzing and corpus replay for fork-only surfaces
  (Win32 clipboard/drag-drop paste paths, ConPTY I/O, session-state JSON,
  IPC); first step: one-time audit that CVE-2026-26982's paste-sanitization
  fix covers the fork's Win32 clipboard/drag-drop code.
- _Evidence:_ `[up]` §6/§10.1 (upstream's AFL++/Tripwire/corpus culture;
  the CVE fix surface is upstream's, not the fork's Win32 paths); `[rio]`
  §6 (hint-URL command-execution vuln on Windows); `[tabby]` §6 (recurring
  injection vuln classes).
- _Why:_ "Reliability as a feature" is a PRODUCT.md principle; the fork's
  own code has none of the core's QA coverage.
- _Cost:_ M (audit is S).
- _Recommendation:_ **Adopt** (audit immediately; fuzzing incrementally).

**C33. Upstream merge cadence ahead of 1.4 + documented merge policy.**

- _What:_ Merge upstream main incrementally now (kitty key-release, UTF-8/VT
  fixes, renderer work) rather than absorbing the Sept 2026 1.4 wave
  (scriptability, tmux-control GUI, graphical preferences) as one conflict
  bomb; publish the fork's drift/merge policy in docs.
- _Evidence:_ `[up]` §10.2 (the 1.4 wave collides with the fork's own
  settings window and palette); `[forks]` §10 (shiweis's visible "merged N
  upstream commits" policy as trust signal; frozen snapshots decay);
  `[wintty]` §1 (the soft-fork alternative's costs — validating deliberate
  syncs, not daily rebases).
- _Why:_ The hard fork's moat is priced in merge labor; deferring it
  compounds, and 1.4's tmux-control GUI is a marquee benchmark-user feature
  to build on (WSL users who live in tmux).
- _Cost:_ S/M recurring.
- _Recommendation:_ **Adopt.**

### Theme I — Adoption extras

**C34. Finish and market accessibility (UIA/Narrator/NVDA matrix).**

- _Evidence:_ `[forks]` §10 ("accessibility ignored across the field" —
  winterm-ghostty admits screen readers can't read its panes; winghostty's
  partial UIA is unique — "worth finishing and stating"); status.md already
  lists it as next.
- _Why:_ Differentiator no competitor in the niche attempts; aligns with
  PRODUCT.md's WCAG commitment.
- _Cost:_ M. _Recommendation:_ **Adopt** (continue; add the release
  matrix).

**C35. D3D11 renderer option.**

- _What:_ A Direct3D 11 terminal-rendering backend alongside OpenGL/WGL.
- _Evidence:_ `[forks]` §2/§10 (family majority + upstream's stated
  Direct3D preference for official Windows work — future-proofing against
  upstream alignment); `[wintty]` §2 (DX12 path); OpenGL driver pain on
  Intel iGPUs.
- _Cost:_ XL. _Recommendation:_ **Defer** — revisit when C01 data or the
  planned ARB migration (status.md) surfaces OpenGL-specific pain, or if
  F2's upstream posture makes alignment valuable.

**C36. Localization stance.**

- _Evidence:_ `[wt]` blind-spot 6 (community translations); `[up]`
  blind-spot 4 (six new languages in 1.3.0; winghostty UI is
  English-only).
- _Cost:_ decision S, execution M. _Recommendation:_ **Defer** — write the
  stance down when F-items are settled; IME support already covers input.

**C37. Serial/COM-port workflows.**

- _Evidence:_ `[tabby]` §5/blind-spot 2 (owns the embedded niche); `[wez]`
  §5 (serial support).
- _Cost:_ M/L. _Recommendation:_ **Defer** — real niche, off the benchmark
  user's core loop; an explicit non-goal statement (C27) may be the right
  answer instead.

---

## 3. Frame challenges (PRODUCT.md amendments)

These challenge the positioning itself; each needs an explicit ruling, not a
roadmap slot.

**F1. Naming/trademark risk is live, specific, and aimed at winghostty.**
Ghostty collaborator pluiedev, 2026-07-12, replying to a question about
winghostty by name: unaffiliated projects "must not use 'Ghostty' as a part
of their branding … they need to find a different name"
([discussion #12371](https://github.com/ghostty-org/ghostty/discussions/12371);
`[forks]` §1/§10 — the field is already complying, cf. WolftacDigital →
"Spectre"; `[wintty]` §1 corroborates the policing). Options: (a) proactive
rename on winghostty's own schedule, (b) seek explicit permission
(strengthened by an upstreaming posture, see F2), (c) wait — which invites a
forced rename at the worst possible moment, after marketing spend (C27).
_Amendment sketch:_ add an "Identity & naming" section to PRODUCT.md; treat
the name as a product decision with a deadline; keep "keeps Ghostty's
terminal core intact" as factual description, not branding. **Rule first —
gates C27 and all adoption spend.**

**F2. Upstream-relations posture: what is winghostty when upstream ships
Windows?** Upstream has Windows CI (Dec 2025), an April 2026 tier plan
(Direct3D, Win10/11, minimal C++), mattn at Tier 2, wintty's 17 merged PRs,
and mitchellh's bet that libghostty consumers dwarf the GUI by mid-2027;
official Windows exploration earliest Nov/Dec 2026, "still not planned"
(`[forks]` §1/§10, `[up]` §1/§10.1). winghostty has a 12–24 month window as
the definitive Ghostty-on-Windows — and no stated posture for the day that
ends. Sub-questions: libghostty tracking (consume it? restructure toward it?
ignore it — and accept rising merge cost, C33); upstreaming-as-strategy
(AGENTS.md currently forbids it, yet wintty converted PRs into goodwill and
standing that a naming conversation would benefit from — `[forks]` §10);
embeddability of winghostty's own `libghostty-vt` as a product surface
(`[wintty]` blind-spot 1, `[rio]` blind-spot 4). _Amendment sketch:_ add an
"Upstream & lineage" section: winghostty positions as its own product whose
durable value is the session/native-polish/trust layer upstream's tiers
won't do first; define a libghostty checkpoint (reassess when it tags a
release); explicitly revisit the no-upstreaming rule.

**F3. AI/agent stance is absent.** The category's center of gravity (Warp's
ADE, WT Terminal Chat, Wave's AI-first roadmap, yaw) demands a written
position even if it is "no cloud AI ever; best-in-class local host for CLI
agents" (`[warp]` blind-spot 1, `[wt]` blind-spot 1, `[wave]` blind-spot 5).
The strongest version is affirmative: agent TUIs (Claude Code etc.) are now
a primary Windows dev workload, and Warp/Wave demonstrably leak memory and
jank while hosting them — "runs your agents flawlessly, locally" doubles as
the privacy differentiator. _Amendment sketch:_ one paragraph under Product
purpose naming the stance + a success criterion (agent TUIs run at full
throughput with zero interception), feeding C01's benchmark set.

**F4. "Fastest, most fluid" needs a measurable contract.** PRODUCT.md
asserts speed with no metric, budget, or harness anywhere (`[ala]`
blind-spot 1, `[wintty]` blind-spot 4, `[warp]` blind-spot 6). _Amendment
sketch:_ add explicit budgets (cold start to first frame, key-to-pixel
latency, memory/pane, idle power) that C01 then enforces; without this
amendment C01 has no target to gate against.

**F5. No category for OS entry points — "how users enter the terminal."**
PRODUCT.md's frame stops at the window edge; default-terminal handoff, jump
lists, Explorer menus, tray/summon, and inbox-default politics (why someone
replaces a preinstalled default) have no home (`[wt]` blind-spots 5/7,
`[conemu]` blind-spot 5, `[wintty]` blind-spot 5). _Amendment sketch:_ add a
"launch topology" principle covering the C11–C14 family and the
replace-the-default argument C27 must make.

**F6. The session promise is being outgrown.** "Session layout to survive
restarts" was differentiating; the emerging bar is contents (WT snapshots,
Warp blocks) and processes (WezTerm mux, Wave durable sessions, Contour
daemon) (`[lt]` §a.1, `[wave]` blind-spot 1, `[wez]` blind-spot 1).
_Amendment sketch:_ restate the promise in tiers — layout (shipped), content
(C15), process durability (C16, explicit aspiration or explicit non-goal) —
so the roadmap has a ruled ceiling.

**F7. Sustainability/bus factor is a product risk with no category.**
Wave's cadence collapsed within weeks of one founder going quiet at 22k
stars; ConEmu, Hyper, the fork swarm's vanished root, and Tabby's dead sync
service show the pattern; wintty monetizes via sponsorware; upstream became
a nonprofit (`[wave]` §6/blind-spot 6, `[conemu]` §10.4, `[lt]`, `[wintty]`
blind-spot 2, `[up]` blind-spot 2). winghostty is one maintainer promising
"reliability as a feature." _Amendment sketch:_ a sustainability statement
(funding for signing certs/infra, succession/continuity note, what happens
to releases if the maintainer disappears) — also a trust asset for C27.

**F8. Remote development scope.** PRODUCT.md's user is "PowerShell and WSL,"
but Tabby's 74k stars, WezTerm's domains, and Termius/MobaXterm show the
same person operates SSH fleets weekly (`[tabby]` blind-spot 1, `[wez]`
blind-spot 1, `[lt]`). _Amendment sketch:_ either extend the benchmark user
("…and the remote hosts they reach over SSH") — which legitimizes C20 and
future C24 — or write remote work out explicitly as a non-goal; the current
silence just defers the fight.

**F9. Publish a user-facing non-goals contract.** Alacritty's README refusal
list successfully manages a two-person team's scope pressure (`[ala]`
blind-spot 5). PRODUCT.md's anti-references are internal; the rejects below
(§4), once ratified, should be published (in C27's page) so scope pressure
is deflected in public.

---

## 4. Explicit rejects

Things the evidence says NOT to do — listed for fast ratification.

- **R1. Cloud coupling: accounts, telemetry, hosted services.** Warp's
  login/telemetry history is its dominant trust complaint years later
  (`[warp]` §9); Wave's opt-out telemetry and BYOK-gated-on-telemetry
  stumbles (`[wave]` §7); Tabby's dead sync service burns trust (`[tabby]`
  §7). winghostty's local-only posture is a marketed asset — never regress.
- **R2. AI-first pivot / bundled chatbot.** Warp's fundamentals lagged its
  AI runway; Wave's AI roadmap crowded out keybindings and a command
  palette while reviewers judged the AI "generic" (`[warp]` §10.5, `[wave]`
  §9/§10.7, `[lt]` yaw). Host agents; don't become one (F3).
- **R3. Feature breadth before performance/reliability.** wintty shipped
  backdrops and palettes while scrolling still rebuilds the full frame
  (`[wintty]` §10.8); WT's flagship features crashed for months post-ship
  (`[wt]` §10.4); Rio's ship-then-stabilize cadence reads as churn (`[rio]`
  §10.3). PRODUCT.md's anti-reference, observed in the wild three times.
- **R4. Re-platforming onto Electron or fashionable Windows UI frameworks.**
  Tabby/Wave/Hyper show the permanent Electron floor; Fluent died on UWP;
  wintty's own maintainer spiked a no-.NET escape hatch citing CLR/GC costs
  (`[tabby]` §2, `[wave]` §2, `[lt]`, `[wintty]` #82). Raw Win32 + Zig is
  validated from inside the rival camp.
- **R5. Workspace/widget drift (embedded browsers, DB clients, file
  managers).** Wave's own users beg it to be more terminal; the drift wins
  stars, not the benchmark user (`[wave]` §9/strategic verdict, `[lt]`).
  Bounded exception worth a separate discussion someday: keyboard-first file
  _preview_ via already-shipped Kitty graphics (`[wave]` §10.4) — but not
  now.
- **R6. Forced/silent auto-update.** Warp's top ops complaint
  (`[warp]` §6). winghostty's user-initiated, checksum+Authenticode staged
  updates are exactly what those users beg for.
- **R7. A plugin runtime / npm-style plugin economy (and any hosted sync
  service).** Tabby's plugin surface multiplied memory, security vulns, and
  abandonment risk; Hyper's ownerless ecosystem hollowed out (`[tabby]`
  §7/§10.3–4, `[lt]`). C25's documented CLI/IPC automation is the bounded
  alternative.
- **R8. DLL injection / hook-based OS integration.** ConEmu's decade of AV
  quarantines, injector conflicts, and crashes; everything it hooked for is
  now achievable via ConPTY + documented APIs (`[conemu]` §10.1).
- **R9. Converting to a daily-rebase soft fork.** wintty's force-pushed
  branches, rewritten SHAs, and contributor-hostile churn show the cost;
  the hard fork's apprt could never survive as a rebase patch-set
  (`[wintty]` §10.4, `[up]` §10 framing). Deliberate scheduled merges (C33)
  are the middle path.
- **R10. Intercepting the shell's line editor or wrapping output in a
  proprietary protocol.** Warp's input-editor/DCS takeover breaks fzf,
  Starship, PSReadLine, tmux muscle memory (`[warp]` §4/§10.4). Keep the
  shell's editor sacred; "your prompt tools just work" is a positioning
  line.
- **R11. Chrome-only differentiation.** Fluent Terminal died the day the
  platform vendor shipped a competent default; depth (VT correctness,
  fluidity, sessions, trust) is the only defensible ground (`[lt]`).

---

## Tally

Candidates: 37 total — **adopt 26** (C01–C08, C11–C15, C17–C20, C25,
C27–C34), **defer 11** (C09, C10, C16, C21–C24, C26, C35–C37), reject 0
(rejections are ratified via §4's eleven items). Frame challenges: 9
(F1–F9), of which F1 and F2 should be ruled before adoption-marketing
candidates (C27) are executed.
