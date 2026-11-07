Assert-DeferredZigFixtureExecution `
    -WorkflowText $testWorkflowText `
    -Source $testWorkflow

$win32ModuleImports = @(
    'const c = @import("win32/consts.zig");'
    'const sys = @import("win32/sys.zig");'
    'const render_trace = @import("win32/render_trace.zig");'
    'const gl_startup = @import("win32/gl_startup.zig");'
    'const win32_input = @import("win32/input.zig");'
    'const chrome_layout = @import("win32/chrome_layout.zig");'
    'const gdi = @import("win32/gdi.zig");'
)
foreach ($win32ModuleImport in $win32ModuleImports) {
    if (-not $win32RuntimeText.Contains($win32ModuleImport)) {
        throw "Win32 runtime is missing decomposition module import: $win32ModuleImport"
    }
}

$win32TestModuleRoots = @(
    '_ = @import("win32/render_trace.zig");'
    '_ = @import("win32/gl_startup.zig");'
    '_ = @import("win32/input.zig");'
    '_ = @import("win32/chrome_layout.zig");'
    '_ = @import("win32/gdi.zig");'
    '_ = @import("win32/docked_search.zig");'
    '_ = @import("win32/window_start.zig");'
    '_ = @import("win32/confirm_text.zig");'
    '_ = @import("win32/tab_label.zig");'
    '_ = @import("win32/profile_pick.zig");'
    '_ = @import("win32/overlay_view.zig");'
)
foreach ($win32TestModuleRoot in $win32TestModuleRoots) {
    if (-not [regex]::IsMatch(
            $win32RuntimeText,
            '(?m)^[ \t]*' + [regex]::Escape($win32TestModuleRoot))) {
        throw "Win32 runtime test graph is missing explicit module root: $win32TestModuleRoot"
    }
}

# Zig does not fail when a test vanishes (a deleted or renamed declaration, or a
# module that dropped out of the test graph just stops running), so the tests
# moved out of win32.zig keep a floor per module instead of a pin on 148 names,
# which made every rename or consolidation edit the list. Each floor is the
# number of pinned names that module held; most modules declare more tests
# than their floor, so consolidating those is free, and emptying a module, or
# removing its explicit root import above, fails. Lower a floor only for a
# deliberate consolidation. facade_budget.zig did not move out of win32.zig:
# its floor is the facade guard's three tests (the budget, the leaves, and the
# leaf check's spellings of an owner's path), and its root line is pinned
# below.
# docked_search.zig holds the per-pane search tests that came from
# win32_search_bar.zig and labels.zig, rewritten against its interface; its
# floor is every one of them. labels.zig went from 113 to 104 when its
# docked-search rules moved there and its search chrome (button words,
# colours, focus stops) to search_controls.zig, to 103 when the search
# overlay's count label went with the search arguments no caller passed, and
# to 101 when its window opacity helpers became `TopLevel.alpha` in
# window_start.zig and the unused resizeSplitFallbackDelta went with the dead
# Surface.resizeSplitFallback (window state on the Window), to 87 when its
# confirm prompt words (the program clipboard, background close and link
# prompts) and its 11 preview pane tests moved to confirm_text.zig, to 65
# when its tab label, tooltip and UIA name tests moved to tab_label.zig (14),
# its cell-width compaction tests to text.zig (4), the window caption's title
# tests to host.zig (2) and text.zig (1) and the base title's to
# terminal_window.zig (1), to 59 when its profile picking tests (by key,
# typed text, where the picker starts, quick slots and pins) moved to
# profile_pick.zig (6), and to 29 when its overlay text, mode and focus ring
# tests moved to overlay_view.zig (24), the title prompt's refill test to
# host.zig (1), and commandPaletteBannerText, which no overlay lane reached
# once overlay_view replaced buildOverlayHintText, went with its 5 tests.
# labels.zig is gone (facade S7): 28 of its last 29 tests went with what they
# test, 15 to host.zig, 7 to win32.zig, 3 to app.zig, 2 to chrome_scene.zig
# and 1 to terminal_window.zig, and its taskbar mapping test was deleted,
# since win32_taskbar_progress.zig's overflow test asserts the same mapping.
# input.zig's floor is 25 since tabFocusStep, which came from labels.zig in
# the same move, has its own test there (the S7 review moved its asserts out
# of host.zig's chrome button test).
# window_start.zig is the pure half of window state, which received its
# consolidated tests: the `plan`, `place`, `returnOn`, `forRestore` and
# `savedFullscreen` tables (from window_state.zig's start and placement tests
# and session.zig's lookup-failure test), `restoredRectOnScreen` (from
# win32.zig) and `TopLevel.alpha` (from labels.zig); its floor was all 10,
# went to 12 when the two `composedFullscreenRect` tables (#598: the free
# edge a fullscreen OpenGL window grows past, and the null that keeps the
# exact monitor rect) joined them, and is 13, all of them, since #678's
# `TopLevel.shows` table (what each renderer shows of a window's opacity).
# confirm_text.zig says what each confirm prompt says: its floor is the 14
# tests from labels.zig, the close-scope table from win32.zig and the
# out-of-memory test of a background tab's close prompt, 16.
# tab_label.zig says what a tab's label, tooltip and UIA name are: its floor
# is the 14 tests from labels.zig, the 2 tab-label tests from win32_bell.zig
# and its Key equality and status-badge tests, 18.
# profile_pick.zig says which profile a key, typed text, the picker's start
# and a quick slot pick, and where a pick opens: its floor is the 6 tests from
# labels.zig and the 3 open-target tests from win32.zig, 9.
# overlay_view.zig says what the host overlay says and shows in each mode: its
# floor is the 24 tests from labels.zig, rewritten against `compose`, `shape`,
# `nextFocus` and `bannerLine` with the three mode tables as one `shape` table
# (22), less the three confirm tests (payload size, three titles, banner
# precedence) that the confirm hint and title tests cover once both lanes
# come from one `compose` (19), and its test of the profile overlay's
# detecting state, 20.
$movedWin32TestFloors = [ordered]@{
    'input.zig' = 25
    'gl_startup.zig' = 4
    'render_trace.zig' = 3
    'chrome_layout.zig' = 2
    'gdi.zig' = 2
    'facade_budget.zig' = 3
    'docked_search.zig' = 32
    'window_start.zig' = 13
    'confirm_text.zig' = 16
    'tab_label.zig' = 18
    'profile_pick.zig' = 9
    'overlay_view.zig' = 20
}
foreach ($movedWin32TestModule in $movedWin32TestFloors.Keys) {
    $movedWin32TestModulePath = @($win32RuntimeModuleFiles | Where-Object {
        (Split-Path -Leaf $_) -ceq $movedWin32TestModule
    })
    if ($movedWin32TestModulePath.Count -ne 1) {
        throw "Moved Win32 test module is missing: $movedWin32TestModule"
    }
    $movedWin32TestCount = [regex]::Matches(
        (Get-Content -LiteralPath $movedWin32TestModulePath[0] -Raw),
        '(?m)^test "[^"\r\n]+" \{$'
    ).Count
    $movedWin32TestFloor = $movedWin32TestFloors[$movedWin32TestModule]
    if ($movedWin32TestCount -lt $movedWin32TestFloor) {
        throw "$movedWin32TestModule declares $movedWin32TestCount named Zig tests; the floor is $movedWin32TestFloor."
    }
}

# The modules cut out of win32.zig by R03 to R06a (#584 to #590) hold most of
# the runtime's tests, and the block above does not fit them twice over. The
# facade reaches them from its root `test {}` block by binding name
# (`_ = app_module;`), not as `_ = @import("win32/<m>.zig");`, and many of their
# tests sit inside containers (`App`, `Host`, `Surface`, `HostControls`,
# `HostScene`), which the top-level-only count above does not see. So each
# module needs its import binding at the start of a line, its root line inside
# the root `test {}` block (a comment, or `_ = x;` in another function, does not
# count), and a floor over the named tests at any indent. A floor started as
# the number of named tests the module declared when it was cut out (app.zig
# 59, host.zig 43, terminal_window.zig 23, session.zig 33,
# quick_terminal_host.zig 10, window_state.zig 41, surface_presentation.zig 15,
# search_controls.zig 4, overlay_session.zig 2, palette_controller.zig 7 and
# chrome_scene.zig 1), the numbers the #584 to #590 reviews measured as the
# tests a module filter runs above the no-match control; the rest says why a
# floor moved since. Registry adds 7 tests in R06b (#592); its floor is 6
# since its toast lookup test became notifications.zig's click tests
# (notifications PR 3). child_window.zig holds the 3 tests that moved out of
# win32.zig with the child-control plumbing, and text.zig the 11 it declared
# once the owned-string helpers (from win32.zig and labels.zig) and
# utf8BoundedPrefix moved in, 16 since labels.zig's cell-width compaction
# tests followed `compactHostLabel` there and the window title sync's test
# became its `ownedStringEquals` test (tab labels). For the same move,
# host.zig's floor went to 46 and terminal_window.zig's to 24: the window
# caption's title tests came from labels.zig with `buildHostAwareBaseTitle`
# and `resolveWindowBaseTitle`, and host.zig gained the NameChanged test of a
# narrow tab's split. host.zig's went to 48 when the title prompt's refill
# test came from labels.zig with `overlayTextNeedsRefill` (overlay view): its
# 48 named tests then, so deleting that one failed the floor (it was one under
# the count before), and to 63, its named tests then, when labels.zig's last
# tests came with what they test (facade S7): the chrome button keys, focus
# stops, the strip's action names and context-menu focus, the profile
# overlay's badges, insets and menu labels, the overview and wheel steps, the
# palette toggle lookup and the inspector panel's visibility (15). For the
# same move app.zig's went to 62 (`tabClosedMessage`'s 3), terminal_window.zig's
# to 25 (`inspectorBannerStateChanged`) and chrome_scene.zig's to 3 (the
# inspector panel's title and hint). host.zig's is 59, its named tests, since
# the S7 review folded four one-line helpers into their single callers and
# deleted their tests: the wheel step's direction, the target badge's inset
# (the label inset test covers it), the context menu's focus rule and the
# inspector panel's visibility (win32_chrome_state.zig's `inspectorVisible`
# test covers its overlay half). chrome_scene.zig's is 6, its named tests,
# since #678 added the three `AlphaPaint` tests (what a translucent window's
# chrome paint leaves see-through).
# session.zig's floor is 27: its five restore-by-key tests became rows of
# pane_launch.zig's `prepare` table (pane launch step 4b), and its
# fullscreen-placement lookup-failure test became window_start.zig's pure
# `savedFullscreen` test (window state, step 6).
# notifications.zig's 23 are the toast lifecycle's, the click's and the cold
# toast wait's tests at its interface, which replaced App's, Host's,
# Surface's and Registry's, and the two cold-wait tests that moved from
# win32.zig. window_state.zig's floor went to 25 when six of its start tests
# (the kept forwarded keys, maximize/fullscreen per kind, the decoration,
# startup-style, initial-decoration and effective-style helpers) became rows
# of the pure `plan` tests in window_start.zig, which window_state.zig
# imports (window state, step 3), and its eight new-window placement tests,
# the fullscreen-restore rect test and the two initial-opacity tests became
# the pure `place` tables there and first-show assertions (step 4), went to
# 26 when `scaleInitialClientSize`'s test moved in from win32.zig (step 7),
# and is 30 since #608 added its two composed-fullscreen window tests and the
# two table tests of their gate (`composesFullscreen`, `PaneRenderer.of`).
# Lower one only for a deliberate consolidation.
# test_support.zig declares no tests, so it has no floor.
$extractedWin32TestModules = [ordered]@{
    'registry.zig' = @{ Binding = 'registry_module'; Floor = 6 }
    'app.zig' = @{ Binding = 'app_module'; Floor = 62 }
    'host.zig' = @{ Binding = 'host_module'; Floor = 59 }
    'terminal_window.zig' = @{ Binding = 'terminal_window_module'; Floor = 25 }
    'session.zig' = @{ Binding = 'session_module'; Floor = 27 }
    'quick_terminal_host.zig' = @{ Binding = 'quick_terminal_host'; Floor = 10 }
    'window_state.zig' = @{ Binding = 'window_state'; Floor = 30 }
    'surface_presentation.zig' = @{ Binding = 'surface_presentation'; Floor = 15 }
    'search_controls.zig' = @{ Binding = 'search_controls'; Floor = 4 }
    'overlay_session.zig' = @{ Binding = 'overlay_session'; Floor = 2 }
    'palette_controller.zig' = @{ Binding = 'palette_controller'; Floor = 7 }
    'chrome_scene.zig' = @{ Binding = 'chrome_scene'; Floor = 6 }
    'child_window.zig' = @{ Binding = 'child_window'; Floor = 3 }
    'text.zig' = @{ Binding = 'paint_text'; Floor = 16 }
    'notifications.zig' = @{ Binding = 'notifications'; Floor = 23 }
}
$win32RootTestBlock = [regex]::Match(
    $win32RuntimeText,
    '(?ms)^test \{\r?\n(?<body>.*?)^\}'
)
if (-not $win32RootTestBlock.Success) {
    throw 'Win32 runtime has no root test block.'
}
foreach ($extractedWin32Module in $extractedWin32TestModules.Keys) {
    $extractedWin32Binding = $extractedWin32TestModules[$extractedWin32Module].Binding
    $extractedWin32Floor = $extractedWin32TestModules[$extractedWin32Module].Floor
    $extractedWin32ImportPattern = '(?m)^const ' + [regex]::Escape($extractedWin32Binding) +
        ' = @import\("win32/' + [regex]::Escape($extractedWin32Module) + '"\);[ \t]*\r?$'
    if (-not [regex]::IsMatch($win32RuntimeText, $extractedWin32ImportPattern)) {
        throw "Win32 runtime is missing decomposition module import: const $extractedWin32Binding = @import(win32/$extractedWin32Module)"
    }
    $extractedWin32RootPattern = '(?m)^[ \t]+_ = ' + [regex]::Escape($extractedWin32Binding) +
        ';[ \t]*\r?$'
    if (-not [regex]::IsMatch($win32RootTestBlock.Groups['body'].Value, $extractedWin32RootPattern)) {
        throw "Win32 runtime root test block is missing: _ = $extractedWin32Binding;"
    }
    $extractedWin32Path = @($win32RuntimeModuleFiles | Where-Object {
        (Split-Path -Leaf $_) -ceq $extractedWin32Module
    })
    if ($extractedWin32Path.Count -ne 1) {
        throw "Extracted Win32 test module is missing: $extractedWin32Module"
    }
    $extractedWin32Count = [regex]::Matches(
        (Get-Content -LiteralPath $extractedWin32Path[0] -Raw),
        '(?m)^[ \t]*test "[^"\r\n]+" \{\r?$'
    ).Count
    if ($extractedWin32Count -lt $extractedWin32Floor) {
        throw "$extractedWin32Module declares $extractedWin32Count named Zig tests; the floor is $extractedWin32Floor."
    }
}

# win32.zig itself keeps the tests that combine owners, those of its native
# window procedures and those of the helpers it still defines. It had no floor
# while the facade series moved tests out of it, so the 7 tests labels.zig
# handed it in facade S7 lost theirs when labels.zig's row went. With the
# series done (S8) its floor is its named tests at any indent, 391: a change
# that moves tests out to the module they test lowers it and says why here.
# 390: "issue149 Windows setting change filters terminal color sync" went with
# the helper it tested, `settingChangeIsImmersiveColorSet`, which lost its
# last caller when every system theme message came to run the light/dark
# change (#685); what the handler still uses, `settingChangeAffectsTheme`,
# has its own test in win32/app.zig.
$win32RuntimeTestFloor = 390
$win32RuntimeTestCount = [regex]::Matches(
    $win32RuntimeText,
    '(?m)^[ \t]*test "[^"\r\n]+" \{\r?$'
).Count
if ($win32RuntimeTestCount -lt $win32RuntimeTestFloor) {
    throw "win32.zig declares $win32RuntimeTestCount named Zig tests; the floor is $win32RuntimeTestFloor."
}

# The facade budget guard (src/apprt/win32/facade_budget.zig) caps win32.zig's
# dependency bags, aliases and pub surface. It runs only from the root
# `test {}` block, and a test that drops out of the graph fails nothing, so its
# root line (here) and its three tests (the floors above) are pinned. Comptime
# cannot list files, so the rest of the rule is checked here: the src/apprt
# files that reach win32.zig are exactly these, the guard and the 15 importers
# it started with (a new one imports the module that owns the name instead; one
# that stopped comes off the list), and only win32.zig declares a `*_runtime`
# bag. A file reaches win32.zig by importing it, or through src/apprt.zig,
# which re-exports it as `apprt.win32` and `apprt.runtime`.
if (-not [regex]::IsMatch(
        $win32RootTestBlock.Groups['body'].Value,
        '(?m)^[ \t]+_ = @import\("win32/facade_budget\.zig"\);[ \t]*\r?$')) {
    throw 'Win32 runtime root test block is missing: _ = @import("win32/facade_budget.zig");'
}
$facadeImporterAllowlist = @(
    'win32/app.zig'
    'win32/chrome_scene.zig'
    'win32/clipboard_write.zig'
    'win32/facade_budget.zig'
    'win32/host.zig'
    'win32/ipc_server.zig'
    'win32/overlay_session.zig'
    'win32/palette_controller.zig'
    'win32/quick_terminal_host.zig'
    'win32/registry.zig'
    'win32/search_controls.zig'
    'win32/session.zig'
    'win32/surface_presentation.zig'
    'win32/terminal_window.zig'
    'win32/window_state.zig'
    'win32_settings.zig'
)
$facadeApprtRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'src\apprt'))
$facadePath = [IO.Path]::GetFullPath($win32Runtime)
$facadeReexportPath = [IO.Path]::GetFullPath((Join-Path $repoRoot 'src\apprt.zig'))
$facadeImporters = [Collections.Generic.List[string]]::new()
$facadeBagFiles = [Collections.Generic.List[string]]::new()
foreach ($facadeSourceFile in @(Get-ChildItem -LiteralPath $facadeApprtRoot -Filter '*.zig' -File -Recurse)) {
    if ($facadeSourceFile.FullName -eq $facadePath) { continue }
    $facadeSourceText = Get-Content -LiteralPath $facadeSourceFile.FullName -Raw
    $facadeSourceName = [IO.Path]::GetRelativePath($facadeApprtRoot, $facadeSourceFile.FullName).Replace('\', '/')
    foreach ($facadeImport in [regex]::Matches(
            $facadeSourceText,
            '(?:\bconst[ \t]+(?<binding>\w+)(?:[ \t]*:[^=\r\n]*)?[ \t]*=[ \t]*)?@import\("(?<path>[^"\r\n]+)"\)(?<member>\.(?:win32|runtime)\b)?')) {
        $facadeImportPath = [IO.Path]::GetFullPath(
            (Join-Path $facadeSourceFile.DirectoryName $facadeImport.Groups['path'].Value))
        $facadeReached = $facadeImportPath -eq $facadePath
        if (-not $facadeReached -and $facadeImportPath -eq $facadeReexportPath) {
            $facadeReached = $facadeImport.Groups['member'].Success -or (
                $facadeImport.Groups['binding'].Success -and [regex]::IsMatch(
                    $facadeSourceText,
                    '(?<![\w.])' + [regex]::Escape($facadeImport.Groups['binding'].Value) + '\.(?:win32|runtime)\b'))
        }
        if ($facadeReached) {
            $facadeImporters.Add($facadeSourceName)
            break
        }
    }
    if ([regex]::IsMatch(
            $facadeSourceText,
            '(?m)^[ \t]*(?:pub[ \t]+)?const[ \t]+\w+_runtime(?:[ \t]*:[^=\r\n]*)?[ \t]*=[ \t]*(?:if[ \t]*\(.*?\)[ \t]*)?\.\{')) {
        $facadeBagFiles.Add($facadeSourceName)
    }
}
$facadeNewImporters = @($facadeImporters | Where-Object { $_ -cnotin $facadeImporterAllowlist })
if ($facadeNewImporters.Count -ne 0) {
    throw "These files reach win32.zig (an import of it, or apprt.win32 or apprt.runtime) and are not on its importer list: $($facadeNewImporters -join ', '). Import each name from the module that owns it, not from the facade."
}
$facadeFormerImporters = @($facadeImporterAllowlist | Where-Object { $_ -cnotin $facadeImporters })
if ($facadeFormerImporters.Count -ne 0) {
    throw "These files no longer import win32.zig: $($facadeFormerImporters -join ', '). Take them off the importer list in Contracts.20-Zig.ps1."
}
if ($facadeBagFiles.Count -ne 0) {
    throw "Only win32.zig may declare a *_runtime dependency bag; found one in $($facadeBagFiles -join ', '). Import each name from the module that owns it."
}

$nativeKeyFilters = @('VK_PACKET', 'deferred char')
foreach ($nativeKeyFilter in $nativeKeyFilters) {
    # Zig accepts a zero-match test filter. A narrow declaration check is
    # appropriate here only to prove that the semantic runner below is nonempty.
    $nativeKeyDeclarations = [regex]::Matches(
        $win32RuntimeAllText,
        '(?m)^test "win32 ' + [regex]::Escape($nativeKeyFilter) +
            '[^"\r\n]*" \{$'
    )
    if ($nativeKeyDeclarations.Count -lt 1) {
        throw "$nativeKeyFilter semantic fixture has no matching Zig test declaration."
    }
    Register-ZigFixture -Filter $nativeKeyFilter
}

if ($termioRuntimeText.Contains('self.surface_mailbox.pushTerminalOutput(buf)') -or
    -not $termioRuntimeText.Contains('self.terminal_stream.handler.semantic_output.begin(') -or
    -not $termioRuntimeText.Contains('self.terminal_stream.handler.semantic_output.finish()') -or
    -not $termioRuntimeText.Contains('self.terminal_output_transport.captureEpoch()') -or
    -not $termioRuntimeText.Contains('self.terminal_output_transport.pushSemanticCapture(') -or
    -not $termioRuntimeText.Contains('decision.semantic_output.slice()')) {
    throw 'Termio must publish parser-derived semantic batches instead of forwarding raw PTY bytes.'
}
if ($terminalAccessibilityText.Contains('OutputSanitizer') -or
    $terminalAccessibilityText.Contains('sanitizeAnnouncementByte') -or
    $surfaceRuntimeText.Contains('terminal output transport drains inactive split controls without speech')) {
    throw 'Win32 accessibility cannot retain a second terminal parser or its fake transport parser fixture.'
}
$semanticOutputInterestPolicyMatches = [regex]::Matches(
    $terminalAccessibilityText,
    '(?ms)^fn semanticOutputInterestPolicy\(\r?\n\s+attached: bool,\r?\n\s+provider_ready: bool,\r?\n\s+focused: bool,\r?\n\) bool \{\r?\n(?<body>.*?)^\}'
)
if ($semanticOutputInterestPolicyMatches.Count -ne 1 -or
    -not $semanticOutputInterestPolicyMatches[0].Groups['body'].Value.Contains(
        'return attached and provider_ready and focused;'
    ) -or
    -not $terminalAccessibilityText.Contains('.emit_events = clients_listening,') -or
    -not $terminalAccessibilityText.Contains('win32_uia.events.clientsAreListening(),')) {
    throw 'Semantic output interest must require attachment, provider readiness, and focus while event emission remains listener-gated.'
}

$semanticPolicyTestMatch = [regex]::Match(
    $terminalAccessibilityText,
    '(?ms)^test "terminal accessibility refresh and query policies" \{\r?\n(?<body>.*?)^\}'
)
$semanticPolicyAssertions = @(
    'try std.testing.expect(semanticOutputInterestPolicy(true, true, true));',
    'try std.testing.expect(!semanticOutputInterestPolicy(true, true, false));',
    'try std.testing.expect(!semanticOutputInterestPolicy(true, false, true));',
    'try std.testing.expect(!semanticOutputInterestPolicy(false, true, true));',
    'try std.testing.expect(!query_only.emit_events);',
    'try std.testing.expect(subscribed.emit_events);'
)
if (-not $semanticPolicyTestMatch.Success) {
    throw 'Semantic output interest policy has no exact Zig test declaration.'
}
foreach ($assertion in $semanticPolicyAssertions) {
    if (-not $semanticPolicyTestMatch.Groups['body'].Value.Contains($assertion)) {
        throw "Semantic output interest policy test is missing assertion: $assertion"
    }
}
if (-not $terminalSemanticOutputText.Contains('pub const transport_chunk_bytes = 1_000;') -or
    -not $terminalSemanticOutputText.Contains('pub const transport_max_chunks = 8;') -or
    -not $terminalSemanticOutputText.Contains('pub const capacity = transport_chunk_bytes * transport_max_chunks;') -or
    -not $terminalOutputCaptureText.Contains('pub const capacity = semantic_output.capacity;') -or
    -not $surfaceRuntimeText.Contains('pub const capacity = semantic_output.capacity;') -or
    $terminalOutputCaptureText.Contains('recordRepeat') -or
    $terminalStreamHandlerText.Contains('recordRepeat')) {
    throw 'Semantic capture and transport must share one 8000-byte capacity and no duplicate REP interface.'
}

$realParserSemanticFragments = @(
    'stream.nextSlice("\x1b[3b");',
    '\x1b[31mright',
    '\x1b]8;;https://secret.example',
    '\x1bPqDCS-SECRET',
    '\x1b[1$}\r\n\thidden\x1b[0$}visible',
    '\x1b(0`\x1b(B',
    'before\x1bcafter',
    'stream.nextSlice("\xcc\x81");'
)
foreach ($realParserFragment in $realParserSemanticFragments) {
    if (-not $terminalStreamHandlerText.Contains($realParserFragment)) {
        throw "Real-parser semantic fixture is missing executable coverage fragment: $realParserFragment"
    }
}

Register-ZigTestsDiscoveredAndRun `
    -Sources @{
        $terminalOutputCapture = $terminalOutputCaptureText
        $terminalStreamHandler = $terminalStreamHandlerText
    } `
    -ExpectedNames @(
        'semantic output capture uninterested fast path',
        'semantic output capture preserves utf8 and control order',
        'semantic output finished batch owns bytes across capture reuse',
        'semantic output full reset discards prior bytes and omission',
        'semantic output capture retains codepoint-aligned prefix before omission',
        'semantic output capture explicit partial error omission retains prefix',
        'semantic output capture follows real stream handler parser'
    ) `
    -Filter 'semantic output'

Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $surfaceRuntime = $surfaceRuntimeText } `
    -ExpectedNames @(
        'terminal output transport saturation is nonblocking and ordered',
        'terminal output transport keeps utf8 chunks before batch omission marker',
        'terminal output transport reentrant callbacks preserve epochs and contention marker',
        'terminal output transport rejects stale interest epoch without poisoning new epoch',
        'terminal output transport orders silent reset before post reset data'
    ) `
    -Filter 'terminal output transport'

Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $terminalAccessibility = $terminalAccessibilityText } `
    -ExpectedNames @(
        'terminal accessibility refresh and query policies'
    ) `
    -Filter 'terminal accessibility refresh and query policies'

Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $terminalAccessibility = $terminalAccessibilityText } `
    -ExpectedNames @(
        'terminal output announcement normalization allocation failure becomes ordered omission'
    ) `
    -Filter 'normalization allocation failure becomes ordered omission'

Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $win32UiaWidgets = $win32UiaWidgetsText } `
    -ExpectedNames @(
        'settings provider behavior invoke dispatch is asynchronous and source preserving',
        'settings provider behavior selection dispatch is synchronous and postcondition checked',
        'settings provider behavior selection dispatch is bounded for a hung owner thread',
        'settings provider behavior keyboard focus includes descendants',
        'settings provider behavior focus properties are provider routed and thread correct'
    ) `
    -Filter 'settings provider behavior'
Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $win32UiaWidgets = $win32UiaWidgetsText } `
    -ExpectedNames @(
        'TerminalProvider GetSelection reports the caret range and real selections'
    ) `
    -Filter 'GetSelection reports the caret range and real selections'
Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $win32UiaWidgets = $win32UiaWidgetsText } `
    -ExpectedNames @(
        'TerminalTextRangeProvider reports unsupported mutation and scrolling honestly'
    ) `
    -Filter 'unsupported mutation and scrolling honestly'

if (-not $win32ThemeText.Contains('const DWMSBT_NONE: u32 = 1;')) {
    throw 'Win32 theme policy must use the documented DWMSBT_NONE value 1.'
}
Register-ZigTestsDiscoveredAndRun `
    -Sources @{ $win32Theme = $win32ThemeText } `
    -ExpectedNames @(
        'settings window policy explicitly disables system backdrop',
        'DWM system backdrop constants match Win32 ABI'
    ) `
    -Filter 'system backdrop'

# The registered fixtures run as one batch at the end of Test-VerificationContracts.ps1,
# and CI skips that run, so the judge that attributes each filter is exercised on
# synthetic runner output here: a zero-match filter, a missing or duplicated expected
# test, a skipped fixture, any failed test (named, unnamed or on its own line after an
# assertion message), a crash and an unfiltered build must each be reported.
function New-ZigRunnerOutput {
    param([Parameter(Mandatory)] [string[]] $Lines)

    $index = 0
    (@($Lines | ForEach-Object { $index++; "$index/$($Lines.Count) $_" }) -join "`n") + "`n"
}

$judgeFixtures = @(
    [pscustomobject]@{
        Filter = 'semantic output capture'
        ExpectedNames = @('semantic output capture uninterested fast path')
    }
    [pscustomobject]@{ Filter = 'VK_PACKET'; ExpectedNames = @() }
)
$judgeCapture = 'termio.semantic_output_capture.test.semantic output capture uninterested fast path'
$judgeBase = @(
    'main.test_0...OK'
    "$judgeCapture...OK"
    'termio.semantic_output_capture.test.semantic output capture preserves utf8...OK'
    'apprt.win32.input.test.win32 VK_PACKET key down authorizes one unit...OK'
)
$judgeWithoutPacket = @($judgeBase | Where-Object { $_ -notmatch 'VK_PACKET' })
$judgeCases = @(
    @{ Name = 'a complete run'; Lines = $judgeBase; Exit = 0; Expect = $null }
    @{
        Name = 'a run with logs between the header and OK'
        Lines = @($judgeBase | ForEach-Object {
            $_ -replace '\.\.\.OK$', "...[terminal] (warn): noise`nOK"
        })
        Exit = 0; Expect = $null
    }
    @{
        Name = 'a log line that looks like a header or an outcome'
        Lines = @($judgeBase | ForEach-Object {
            $_ -replace '\.\.\.OK$', "...3/5 items done`n1/4 chunks...`nFAIL is a word`nOK"
        })
        Exit = 0; Expect = $null
    }
    @{
        Name = 'a skip that follows a line starting with OK'
        Lines = @($judgeBase | ForEach-Object {
            $_ -replace '(uninterested fast path)\.\.\.OK$', "`$1...`nOK`nSKIP"
        })
        Exit = 0; Expect = 'ended as SKIP'
    }
    @{
        Name = 'a zero-match filter'
        Lines = $judgeWithoutPacket + 'main.test_1...OK'
        Exit = 0; Expect = "filter 'VK_PACKET' matched no test"
    }
    @{
        Name = 'a missing expected name'
        Lines = @($judgeBase | Where-Object { $_ -notmatch 'uninterested' }) +
            'termio.semantic_output_capture.test.semantic output capture other...OK'
        Exit = 0; Expect = 'found 0'
    }
    @{
        Name = 'a duplicated expected name'
        Lines = $judgeBase + "$judgeCapture...OK"
        Exit = 0; Expect = 'found 2'
    }
    @{
        Name = 'a skipped expected name'
        Lines = @($judgeBase | ForEach-Object { $_ -replace '(uninterested fast path)\.\.\.OK$', '$1...SKIP' })
        Exit = 0; Expect = 'ended as SKIP'
    }
    @{
        Name = 'a fixture whose tests all skip'
        Lines = $judgeWithoutPacket +
            'apprt.win32.input.test.win32 VK_PACKET key down authorizes one unit...SKIP'
        Exit = 0; Expect = "filter 'VK_PACKET' matched 1 tests but none passed"
    }
    @{
        Name = 'a failed fixture test'
        Lines = $judgeWithoutPacket +
            'apprt.win32.input.test.win32 VK_PACKET key up authorizes no units...FAIL (error.TestUnexpectedResult)'
        Exit = 1; Expect = "fixture 'VK_PACKET' failed"
    }
    @{
        Name = 'a failure reported on its own line after an assertion message'
        Lines = $judgeWithoutPacket +
            "apprt.win32.input.test.win32 VK_PACKET key up authorizes no units...expected 5, found 4`nFAIL (TestExpectedEqual)"
        Exit = 1; Expect = 'expected 5, found 4'
    }
    @{
        Name = 'a failed unnamed test no filter claims'
        Lines = $judgeBase + 'main.test_1...FAIL (error.TestUnexpectedResult)'
        Exit = 1; Expect = 'main.test_1'
    }
    @{
        Name = 'a crash in the middle of a test'
        Lines = $judgeBase + 'apprt.win32.input.test.win32 VK_PACKET crashes...'
        Exit = 3; Expect = 'did not finish test apprt.win32.input.test.win32 VK_PACKET crashes'
    }
    @{
        Name = 'a nonzero exit with no failed test'
        Lines = $judgeBase; Exit = 3; Expect = 'without reporting a failed test'
    }
    @{
        Name = 'an unfiltered executable'
        Lines = $judgeBase + 'apprt.win32.tab_label.test.win32 unrelated label...OK'
        Exit = 0; Expect = 'matches none of the fixture filters'
    }
)
foreach ($judgeCase in $judgeCases) {
    $judgeProblems = @(Get-ZigFixtureProblems `
        -Fixtures $judgeFixtures `
        -Output (New-ZigRunnerOutput -Lines $judgeCase.Lines) `
        -ExitCode $judgeCase.Exit)
    $judged = $judgeProblems -join ' | '
    if ($null -eq $judgeCase.Expect) {
        if ($judgeProblems.Count -ne 0) {
            throw "Zig fixture judge rejected $($judgeCase.Name): $judged"
        }
    }
    elseif (-not $judged.Contains($judgeCase.Expect, [StringComparison]::Ordinal)) {
        throw "Zig fixture judge missed $($judgeCase.Name); expected '$($judgeCase.Expect)', got: $judged"
    }
}
if (@(Get-ZigFixtureProblems -Fixtures $judgeFixtures -Output '' -ExitCode 0).Count -eq 0) {
    throw 'Zig fixture judge accepted a run that listed no tests.'
}
