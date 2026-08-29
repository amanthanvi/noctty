Assert-DeferredZigFixtureExecution `
    -WorkflowText $testWorkflowText `
    -Source $testWorkflow

$win32ModuleImports = @(
    'const c = @import("win32/consts.zig");'
    'const sys = @import("win32/sys.zig");'
    'const render_trace = @import("win32/render_trace.zig");'
    'const gl_startup = @import("win32/gl_startup.zig");'
    'const labels = @import("win32/labels.zig");'
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
    '_ = @import("win32/labels.zig");'
    '_ = @import("win32/input.zig");'
    '_ = @import("win32/chrome_layout.zig");'
    '_ = @import("win32/gdi.zig");'
)
foreach ($win32TestModuleRoot in $win32TestModuleRoots) {
    if (-not $win32RuntimeText.Contains($win32TestModuleRoot)) {
        throw "Win32 runtime test graph is missing explicit module root: $win32TestModuleRoot"
    }
}

$movedWin32TestNames = @(
    'win32 render trace classifies gaps by start time'
    'win32 render trace classifies visible paint gaps'
    'win32 render trace init rejects and frees a second process owner'
    'win32-opengl-startup-failure-message-explains-error-126'
    'win32-opengl-startup-failure-message-explains-version-floor'
    'win32-opengl-startup-failure-recording-is-startup-scoped'
    'win32-opengl-startup-failure-preserves-win32-loader-cause'
    'win32 profileIndexByKey finds launch profile key'
    'win32 buildWindowTitle appends active status segments'
    'win32 buildWindowTitle uses default title when base is null'
    'win32 resolveWindowBaseTitle prefers tab then surface override'
    'win32 effectiveBackgroundOpacity respects opaque override'
    'win32 resizeSplitFallbackDelta maps directions to window deltas'
    'win32 nextInspectorVisible follows requested mode'
    'win32 tab inspector toggle hides any active pane inspector'
    'win32 primarySurfaceIndex prefers active tab of first host'
    'win32 buildHostAwareBaseTitle prefixes host tab position'
    'win32 buildTabButtonLabel marks active tab and pane count'
    'win32 buildTabButtonLabel omits pane count for single pane tabs'
    'win32 buildTabButtonLabel compacts long titles'
    'win32 buildTabButtonLabel drops pane count when tabs are narrow'
    'win32 hostTabLabelMaxLen shrinks with narrow tab widths'
    'win32 visibleTabRange windows tabs around the active tab'
    'win32 buildTabOverviewBannerText lists active tabs and pane counts'
    'win32 buildSearchButtonLabel reflects active search state'
    'win32 buildProfilesButtonLabel reflects selected cached profile'
    'win32 profilesButtonKeyAction maps focused launcher keys'
    'win32 profileShortcutIndexFromKey supports top row and numpad digits'
    'win32 quickSlotShortcutProfileIndex maps visible launcher slots'
    'win32 quickSlotPinOrdinalFromKey maps visible pin slots'
    'win32 clearQuickSlotPinsRequested detects clear shortcut'
    'win32 quickSlotFocusKeyAction maps painted quick slot focus keys'
    'win32 progress status and taskbar mapping clamp percent to shell range'
    'win32 launchTargetButtonLabel reflects selected launcher slot'
    'win32 launchTargetButtonLabel reflects Windows-style target wording'
    'win32 preferredProfileIndex respects host key then app key then hint'
    'win32 resolveProfileSelection supports index and prefix matching'
    'win32 buildProfileOverlayLabel and hint reflect selected profile'
    'win32 buildProfileDetailText reflects selected launcher state'
    'win32 buildProfileDetailText appends shell integration guidance when present'
    'win32 buildProfileCommandPreviewText compacts shell command preview'
    'win32 buildProfileOrderSummaryText compacts launcher order'
    'win32 buildProfileQuickPickText reflects ordered launcher profiles'
    'win32 buildProfileStatusBadgeText reflects selected profile kind'
    'win32 profileStatusBadgeTextLen matches built text'
    'win32 buildProfileQuickSlotChipText reflects ordered quick slot badge'
    'win32 profileQuickSlotChipTextLen matches built text'
    'win32 launcherChipRightInset reserves badge and target space'
    'win32 targetButtonLabelRightInset reserves target badge space'
    'win32 buttonLabelRightInset reserves slot and target badge space'
    'win32 shouldPaintQuickSlotTargetMarker follows active chip state'
    'win32 profileOpenTargetMarkerColor reflects launcher target'
    'win32 profileOpenTargetBadgeGlyph reflects launcher target'
    'win32 pinnedSlotBadgeDigit reflects visible quick slot ordinals'
    'win32 quickSlotProfileIndex skips the selected profile and preserves order'
    'win32 findLauncherQuickSlotOrdinal finds runtime-pinned slots'
    'win32 buildProfileChromeBadgeText adds profile glyph treatment'
    'win32 profileKindDetail exposes shell integration posture'
    'win32 buildSearchOverlayLabel reflects match counts'
    'win32 buildSearchBarResultsText reflects docked search states'
    'win32 showSearchBarResults only shows status chip for non-empty queries'
    'win32 searchBarNeedsRelayoutForQueryChange only trips on empty-state transitions'
    'win32 searchBarShouldInvalidateCoreSearchOnEdit invalidates active query edits'
    'win32 shouldAcceptCoreSearchUpdates rejects pending docked search state'
    'win32 profileChromeNeedsFullTextInvalidation only trips for status-only profile chrome'
    'win32 chromeTextNeedsFullInvalidation only trips when status bar is visible'
    'win32 searchBarResultsVisual marks no-match state with error colors'
    'win32 searchBarButtonShowsLabel keeps docked search buttons icon-only'
    'win32 buildTabOverviewOverlayLabel reflects current host tab'
    'win32 buildOverlayPaintLabelText reflects live overlay mode'
    'win32 buildOverlayFeedbackText prefers inline banner state'
    'win32 nextTabOverviewSelection wraps and clamps'
    'win32 tabDirectionFromWheelDelta maps wheel direction to tab navigation'
    'win32 searchDirectionFromWheelDelta maps wheel direction to search navigation'
    'win32 searchBarSearchedState helpers preserve pending searches on null callbacks'
    'win32 searchBarDisplayStateChanged only trips on visible results changes'
    'win32 scrollStatusTextChanged only trips on indicator visibility or percent deltas'
    'win32 commandPaletteDirectionFromWheelDelta maps wheel direction to completion direction'
    'win32 profileDirectionFromWheelDelta maps wheel direction to profile navigation'
    'win32 tabButtonKeyAction maps focused-tab keys'
    'win32 moveTabAmountToEdge computes direct host reorder delta'
    'win32 searchButtonKeyAction maps focused search button keys'
    'win32 docked search key actions preserve semantic next and previous navigation'
    'win32 docked search arrow buttons follow visible up and down navigation'
    'win32 docked search Enter and Shift+Enter follow the arrow-key contract'
    'win32 docked search Up and Down keys follow the visible button contract'
    'win32 docked search selection preserves newest-first visible numbering'
    'win32 docked search preview advances visible numbering with navigation'
    'win32 docked search sequential visible order increments while moving older and up'
    'win32 tabsButtonKeyAction maps focused tabs button keys'
    'win32 commandButtonKeyAction maps focused command button keys'
    'win32 command palette toggle binding is recognized inside action chains'
    'win32 buildInspectorBannerText reflects host inspector context'
    'win32 buildHostBannerText prefixes info and error banners'
    'win32 overlayPaintCacheDirty ignores repaint-only dirtiness'
    'win32 profileChromeVisible only trips for profile overlay or visible status bar'
    'win32 inspector chrome visibility only trips for banner or visible status bar'
    'win32 inspector visibility changes require host relayout'
    'win32 inspector panel visibility is tab scoped'
    'win32 command palette hides duplicate accept button'
    'win32 transient overlay focus ring includes every visible control'
    'win32 inspectorBannerStateChanged only trips on actual banner deltas'
    'win32 windowTitleSyncChanged only trips on actual title deltas'
    'win32 buildInspectorPanelTitleText reflects host inspector context'
    'win32 buildInspectorPanelHintText reflects live inspector scope'
    'win32 buildInspectorDetailText reflects pane and zoom context'
    'win32 buildSearchDetailText reflects live search context'
    'win32 buildOverlayAcceptLabel reflects overlay action state'
    'win32 buildOverlayHintText reflects live overlay guidance'
    'win32 overlayCancelLabel reflects overlay mode'
    'win32 buildCommandButtonLabel reflects live palette state'
    'win32 buildInspectorButtonLabel reflects inspector and pane state'
    'win32 buildCommandPaletteOverlayLabel reflects palette state'
    'win32 command palette rich feedback never calls a theme an action miss'
    'win32 commandPaletteCompletionCandidate resolves and cycles defaults'
    'win32 commandPaletteBannerText shows ready banner for valid action'
    'win32 commandPaletteBannerText suggests matching actions'
    'win32 commandPaletteBannerText resolves unique prefix'
    'win32 commandPaletteBannerText uses fullscreen description'
    'win32 commandPaletteBannerText suggests tab overview action'
    'win32 keyFromVirtualKey maps core keys'
    'win32 shouldDeferTextToCharMessage only defers plain text keys'
    'win32 deferred char authorization respects key handling effect'
    'win32 VK_PACKET key down authorizes one unit without direct text or modifiers'
    'win32 VK_PACKET key up authorizes no units or text'
    'win32 authorized char commit preserves packet control characters'
    'win32 deferred char authorization preserves pending units across non-text events'
    'win32 deferred char dead key and composition consume exact units'
    'win32 deferred char authorization blocks unsolicited and IME text'
    'win32 deferred char two surrogate keydowns consume two code units'
    'win32 deferred char supplementary expectation authorizes both units'
    'win32 deferred char commits 256 delayed BMP authorizations'
    'win32 deferred char malformed surrogate clears authorization state'
    'win32 deferred char authorization saturates only at usize maximum'
    'win32 hotkeySpecForTrigger maps physical key triggers'
    'win32 hotkeySpecForTrigger maps unicode triggers with implicit shift'
    'win32 hotkeySpecForTrigger rejects unsupported catch-all triggers'
    'win32 hotkeySpecEql detects duplicate resolved triggers'
    'win32 hotkeyRegistrationFailureReason names conflicts'
    'win32 XButton wParam decoding maps forward and back buttons'
    'win32 normalizeWheelDelta maps discrete wheel steps to pixel deltas'
    'win32 normalizeWheelDelta maps horizontal wheel steps to pixel deltas'
    'win32 normalizeWheelDelta scales high-resolution input proportionally'
    'win32 normalizeWheelDelta honors page scroll settings'
    'win32 normalizeWheelDelta ignores page scroll settings for high-resolution input'
    'win32 normalizeWheelDelta ignores disabled notch settings for high-resolution input'
    'win32 overlay edit child rect preserves frame border'
    'win32 overlay edit frame offsets scale with DPI'
    'win32 rectIntersects only trips on positive overlap'
    'win32 GDI text length accepts empty sentinel slices'
)
foreach ($movedWin32TestName in $movedWin32TestNames) {
    $declarationCount = [regex]::Matches(
        $win32RuntimeAllText,
        '(?m)^test "' + [regex]::Escape($movedWin32TestName) + '" \{$'
    ).Count
    if ($declarationCount -ne 1) {
        throw "Moved Win32 Zig test must have exactly one declaration: $movedWin32TestName"
    }
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
    Invoke-ZigFixture `
        -RepoRoot $repoRoot `
        -Filter $nativeKeyFilter
}

if ($termioRuntimeText.Contains('self.surface_mailbox.pushTerminalOutput(buf)') -or
    -not $termioRuntimeText.Contains('self.terminal_stream.handler.semantic_output.begin(') -or
    -not $termioRuntimeText.Contains('self.terminal_stream.handler.semantic_output.finish()') -or
    -not $termioRuntimeText.Contains('self.terminal_output_transport.captureEpoch()') -or
    -not $termioRuntimeText.Contains('self.terminal_output_transport.pushSemanticBatchForEpoch(') -or
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
foreach ($fragment in $realParserSemanticFragments) {
    if (-not $terminalStreamHandlerText.Contains($fragment)) {
        throw "Real-parser semantic fixture is missing executable coverage fragment: $fragment"
    }
}

Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
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
    -Filter 'semantic output capture'

Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $surfaceRuntime = $surfaceRuntimeText } `
    -ExpectedNames @(
        'terminal output transport saturation is nonblocking and ordered',
        'terminal output transport keeps utf8 chunks before batch omission marker',
        'terminal output transport reentrant callbacks preserve epochs and contention marker',
        'terminal output transport rejects stale interest epoch without poisoning new epoch',
        'terminal output transport orders silent reset before post reset data'
    ) `
    -Filter 'terminal output transport'

Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $terminalAccessibility = $terminalAccessibilityText } `
    -ExpectedNames @(
        'terminal accessibility refresh and query policies'
    ) `
    -Filter 'terminal accessibility refresh and query policies'

Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $terminalAccessibility = $terminalAccessibilityText } `
    -ExpectedNames @(
        'terminal output announcement normalization allocation failure becomes ordered omission'
    ) `
    -Filter 'normalization allocation failure becomes ordered omission'

Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $win32UiaWidgets = $win32UiaWidgetsText } `
    -ExpectedNames @(
        'settings provider behavior invoke dispatch is asynchronous and source preserving',
        'settings provider behavior selection dispatch is synchronous and postcondition checked',
        'settings provider behavior selection dispatch is bounded for a hung owner thread',
        'settings provider behavior keyboard focus includes descendants',
        'settings provider behavior focus properties are provider routed and thread correct'
    ) `
    -Filter 'settings provider behavior'
Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $win32UiaWidgets = $win32UiaWidgetsText } `
    -ExpectedNames @(
        'TerminalProvider GetSelection reports the caret range and real selections'
    ) `
    -Filter 'GetSelection reports the caret range and real selections'
Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $win32UiaWidgets = $win32UiaWidgetsText } `
    -ExpectedNames @(
        'TerminalTextRangeProvider reports unsupported mutation and scrolling honestly'
    ) `
    -Filter 'unsupported mutation and scrolling honestly'

if (-not $win32ThemeText.Contains('const DWMSBT_NONE: u32 = 1;')) {
    throw 'Win32 theme policy must use the documented DWMSBT_NONE value 1.'
}
Assert-ZigTestsDiscoveredAndRun `
    -RepoRoot $repoRoot `
    -Sources @{ $win32Theme = $win32ThemeText } `
    -ExpectedNames @(
        'settings window policy explicitly disables system backdrop',
        'DWM system backdrop constants match Win32 ABI'
    ) `
    -Filter 'system backdrop'
