# Windows Terminal Chrome Reference for noctty

## Executive Summary

Windows Terminal's chrome is a custom-frame Win32 window with WM_NCCALCSIZE zeroing the top non-client area and DwmExtendFrameIntoClientArea painting it back under app control. Tabs sit inside the caption bar. Caption buttons are 46x40 DIP, the close button hovers red #C42B1C, min/max hover SubtleFillColorSecondary (~8% white on dark). A drag-bar child HWND overlays the titlebar to intercept WM_NCHITTEST, returning HTMAXBUTTON at the maximize rect for Win11 Snap Layouts. Mica is enabled via DWMSBT_MAINWINDOW through DwmSetWindowAttribute (build 22621+). The command palette is a centered overlay at 60% width, flyout-styled with OverlayCornerRadius and ThemeShadow. All hover transitions are 100-150ms linear color animations. The design is flat, border-less within the tab row, with 1px top border for the DWM accent strip, and cards/expanders with ControlCornerRadius (4px) in settings. To replicate in pure Win32+GDI, paint the titlebar region yourself after WM_NCCALCSIZE, handle NCHITTEST precisely, and use DWM APIs for backdrop.

---

## 1. Tab Strip

**Cite:** `TabRowControl.xaml`, `Tab.cpp`, `TabManagement.cpp`, `App.xaml`, MUX TabView defaults

### Layout
- **TabView mode:** `TabWidthMode="Equal"` (default). Also supports `SizeToContent` and `Compact` via settings.
- **MUX TabView defaults (WinUI 2.8):** min tab width 100 DIP in Equal mode; no explicit max (fills available space equally). In SizeToContent mode, tabs grow to fit label text.
- **Tab row height:** 32 DIP (maximized), 40 DIP (windowed; caption button drives this).
- **Tab border:** `TabViewItemBorderThickness: 1,1,1,0` -- 1px top/left/right, 0 bottom.
- **Tab header padding:** `TabViewHeaderPadding: 0,0,0,0` (WT overrides MUX default to suppress top padding).
- **Corner radius:** Inherits MUX TabViewItem default: 8px top-left/top-right, 0 bottom.
- **Tab row bottom border:** 1px `CardStrokeColorDefaultBrush` drawn in TabStripFooter.

### Hover Close Button
- MUX TabViewItem provides the close button; appears on hover over the tab item.
- Hit rect is the standard MUX close glyph area (~24x24 DIP within the tab).
- No custom alpha animation in WT; relies on MUX default (instant show/hide on PointerOver state).

### Focused Tab Indicator
- MUX TabView's `SelectedTabIndicator` -- a 2-3 DIP bottom border in accent color.
- Slide animation between tabs is MUX's built-in `TabViewItemIndicator` transition (spring-based, ~300ms).
- WT does not override this; uses MUX default entirely.

### Tab-width Clamping
- In Equal mode, all tabs share space equally. When many tabs open, each tab shrinks toward MinTabWidth (100 DIP by MUX default).
- WT does not set a custom min or max; MUX TabView clamps internally.

### Overflow / New Tab Affordance
- MUX TabView provides scroll buttons at left/right edges when tabs overflow.
- `IsAddTabButtonVisible="false"` in WT -- WT uses its own `SplitButton` in `TabStripFooter`.
- New-tab button: `Height="24"`, `Margin="0,4"`, icon U+E710 at FontSize 12.
- SplitButton primary/secondary width: 31 DIP each (`SplitButtonPrimaryButtonSize`/`SecondaryButtonSize`).

---

## 2. Caption Buttons (Integrated Titlebar)

**Cite:** `MinMaxCloseControl.xaml`, `NonClientIslandWindow.cpp`

### Dimensions
- All three buttons: **46 DIP wide x 40 DIP tall** (windowed), **32 DIP tall** (maximized).
- Glyph Viewbox: 10x10 DIP centered within the button.
- Font: `SymbolThemeFontFamily` (Segoe Fluent Icons / Segoe MDL2 Assets).
- Glyphs: Minimize U+E921, Maximize U+E922, Restore U+E923, Close U+E8BB.

### Close Button
- Hover background: **#C42B1C** (`CloseButtonColor`), foreground: White.
- Pressed: same #C42B1C at **0.9 opacity**, foreground White at **0.7 opacity**.
- Rest: transparent background, color fades from transparent (#00C42B1C).

### Min/Max Buttons
- Hover background: `SubtleFillColorSecondary` (WinUI token: dark theme = `#0FFFFFFF` = ~6% white; light theme = `#0F000000` = ~6% black).
- Pressed background: `SubtleFillColorTertiary` (dark = `#0AFFFFFF`; light = `#0A000000`).
- Foreground: `SystemBaseHighColor` (white in dark, black in light).
- Unfocused foreground: `TextFillColorDisabled`.

### Hover Transition
- PointerOver to Normal: background color animates over **150ms**, foreground over **100ms** (linear, no easing curve specified).
- PointerOver to Unfocused: same 150ms/100ms durations.
- No entrance animation; state changes are instant on PointerOver, transitions fire only on exit.

### Focus Rect
- `IsTabStop="False"` on all caption buttons -- no keyboard focus rect. They are operated only via NCHITTEST dispatch from the drag bar.

### HTMAXBUTTON / Snap Layouts
- `_dragBarNcHitTest()` returns **HTMAXBUTTON** when the cursor is within `buttonWidthInPixels` to `buttonWidthInPixels*2` from the right border.
- `buttonWidthInPixels = CaptionButtonWidth() * dpiScale` (CaptionButtonWidth is 46 DIP).
- This is what triggers Win11 22H2+ Snap Layouts flyout. The drag bar HWND covers the entire caption area including buttons to ensure WM_NCHITTEST reaches WT's code before the XAML island.

---

## 3. Titlebar Integration

**Cite:** `NonClientIslandWindow.cpp`, `NonClientIslandWindow.h`, `IslandWindow.cpp`

### WM_NCCALCSIZE Strategy
1. Call `DefWindowProc(WM_NCCALCSIZE)` to get default frame.
2. **Reset top** to `originalTop` (zero the top NC area entirely).
3. When maximized (not fullscreen): add back `_GetResizeHandleHeight()` = `SM_CXPADDEDBORDER + SM_CYSIZEFRAME` (at current DPI).
4. Auto-hide taskbar: inset 2px on the taskbar edge when maximized.

### WM_NCHITTEST Dispatch
- `DefWindowProc` handles left/right/bottom borders.
- If `HTCLIENT`: check if cursor is in top `resizeBorderHeight` px -> return `HTTOP`.
- Otherwise: return `HTCAPTION`.
- Drag bar child HWND handles HTCLOSE/HTMAXBUTTON/HTMINBUTTON by measuring distance from right border in `buttonWidthInPixels` increments.

### WM_NCACTIVATE
- On `WM_NCACTIVATE`: calls `_titlebar.Focused(activated)` to update visual state (focused vs unfocused foreground color on caption buttons).
- Does **not** suppress DWM's paint entirely; instead uses DwmExtendFrameIntoClientArea + WM_PAINT to paint over any DWM artifacts.

### Top Border
- `topBorderVisibleHeight = 1` (constant, DPI-independent). This 1px strip is painted with BLACK_BRUSH (alpha=0) so DWM's accent border shows through.
- When maximized or fullscreen: top border height = 0. When maximized, island is shifted up 1px (`topBorderHeight = -1`) as a Fitt's Law bodge.

### Frame Margins (DwmExtendFrameIntoClientArea)
- Normal: `cyTopHeight = -frame.top` (the full default frame top, computed via AdjustWindowRectExForDpi).
- With Mica or transparent titlebar: `cyTopHeight = 0` (load-bearing for Snap Layouts detection by DWM).
- Borderless/focus mode: `cyTopHeight = 1`.

---

## 4. Acrylic / Mica Backdrop

**Cite:** `IslandWindow.cpp:1847-1857`

### API
- Single call: `DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, DWMSBT_MAINWINDOW, ...)`.
- Disable: `DWMSBT_NONE`.
- WT uses **DWMSBT_MAINWINDOW** (Mica), **not** DWMSBT_TABBEDWINDOW or DWMSBT_TRANSIENTWINDOW.

### Build-Number Gates
- **22621+ (Win11 SV2):** DWMWA_SYSTEMBACKDROP_TYPE is publicly supported and functional.
- **22000-22620 (Win11 RTM / 22H2 pre-release):** WT's code notes a "slightly different API surface" existed but the current codebase only uses the SV2 API. Noctty skips `DWMWA_SYSTEMBACKDROP_TYPE` on these builds.
- **Windows 10:** Noctty skips `DWMWA_SYSTEMBACKDROP_TYPE`; the window uses opaque solid color.

### Fallback
- No Mica: titlebar painted with solid background brush color via GDI `FillRect` + `BeginBufferedPaint` in `_OnPaint()`.
- Background color sampled from XAML titlebar's `Background` (SolidColorBrush.Color or AcrylicBrush.FallbackColor).

### Transient Overlays
- WT does not differentiate DWMSBT_TABBEDWINDOW vs DWMSBT_TRANSIENTWINDOW. All overlays (palette, flyouts) use XAML's own acrylic brush (`FlyoutPresenterBackground`), not DWM backdrop.

---

## 5. Command Palette

**Cite:** `CommandPalette.xaml`, `CommandPalette.cpp`, `HighlightedTextControl.cpp`

### Layout
- Centered at column weights 2:6:2 (20%/60%/20% of window width). Row split 8:2.
- Backdrop: `FlyoutPresenterBackground`, border: `FlyoutBorderThemeBrush`, thickness: `FlyoutBorderThemeThickness`.
- Corner radius: `OverlayCornerRadius` (8px on Win11). Shadow: `ThemeShadow` at Z=32 (`Translation="0,0,32"`).
- Inner padding: `Padding="0,8,0,0"` top, margin 8 on all sides.

### Search Bar
- `TextBox` at top, `Margin="8,0,8,8"`, `Padding="18,8,8,8"`.
- Prefix character overlaid at left (for `>` command mode, `:` line-goto mode, etc.).

### Row Layout (GeneralItemTemplate)
- 4-column grid: 16px icon | Auto label | `*` keychord | 16px scrollbar gutter. `ColumnSpacing="8"`.
- Icon: 16x16 DIP ContentPresenter.
- Keychord badge: 1px border, 2px corner radius, `FlyoutPresenterBackground`, text at FontSize 12.

### Fuzzy Match Highlighting
- `HighlightedTextControl` renders matched character ranges as **Bold** (FontWeight 700) inline Runs. Default style; no color change, no underline.

### Keyboard Navigation
- Arrow up/down: selection in ListView. Enter: execute. Esc: dismiss. Tab: cycle focus.
- `PreviewKeyDown`/`PreviewKeyUp` handlers on the UserControl. `TabNavigation="Cycle"`.

### Entrance/Exit Animation
- No custom entrance/exit animation defined in XAML. Relies on `ContentThemeTransition` (standard WinUI slide+fade, ~250ms).

---

## 6. Settings Page Styling

**Cite:** `SettingContainerStyle.xaml`, `MainPage.xaml` (TerminalSettingsEditor)

### Section/Row Layout
- Each setting row: `NonExpanderGrid` style -- `MinHeight="64"`, `Padding="16,0,8,0"`, `CornerRadius=ControlCornerRadius` (4px).
- `MaxWidth="1000"` on SettingContainer. `Margin="0,4,0,0"` between rows.
- Two columns: `*` for label/description, `Auto` for control.
- Inner stack: `Padding="0,12,0,12"`.

### Typography
- Header: `BodyTextBlockStyle`, `LineHeight="20"`, `FontWeight="SemiBold"`.
- Description: `CaptionTextBlockStyle`, `LineHeight="16"`, `Foreground=TextFillColorSecondary`, font `"Segoe UI, Segoe Fluent Icons, Segoe MDL2 Assets"`.
- Reset button: 20x20 DIP, transparent, icon FontSize 12 in accent color (`SystemAccentColorDark2` light / `SystemAccentColorLight2` dark).

### Search
- `SearchIndex.cpp`/`.h` provides search within settings. No special visual treatment beyond standard TextBox.

---

## 7. Scrollbar

**Cite:** `ScrollBarVisualStateManager.cpp`, `TermControl.xaml` (MUX ScrollViewer defaults)

### Dimensions
- WT uses MUX ScrollViewer defaults: **resting indicator 2px**, **expanded 6px**, **full thumb 8px** on hover/drag.
- These are WinUI 2.x defaults; WT does not override widths.

### Colour Treatment
- Thumb: `ScrollBarThumbFill` / `ScrollBarThumbFillPointerOver` (system tokens).
- Track: transparent at rest, `ScrollBarTrackFillPointerOver` on hover.
- Search match markers: rendered by the terminal renderer, not the scrollbar chrome.

### Auto-hide
- `ScrollBarVisualStateManager` intercepts collapse transitions: when `ScrollState=Always`, it forces `ExpandedWithoutAnimation` instead of `Collapsed`.
- Default mode: MUX ScrollViewer auto-hide after ~2s of inactivity (fade-out via `CollapsedWithAnimation` state, ~300ms opacity transition).

---

## 8. Focus Rings

**Cite:** `App.xaml:79-80`, `CommonResources.xaml:388-389`

### Keyboard-Nav Focus Ring
- `UseSystemFocusVisuals="True"` -- delegates to Windows' built-in focus visual.
- `FocusVisualMargin="-3"` (inset 3 DIP on all sides from control bounds).
- System focus visual: 2px outer ring in `SystemFocusVisualPrimaryBrush` (black), 1px inner in `SystemFocusVisualSecondaryBrush` (white). This is the standard Win11 reveal-focus rect.
- Settings NavigationViewItem uses `FocusVisualMargin="-7,-3,-7,-3"` (wider horizontal inset).

### Mouse-Mode Suppression
- System focus visuals are automatically suppressed when `FocusState` is `Pointer` (mouse click). Only shown for `Keyboard` focus state. This is default WinUI behavior.

---

## 9. Animation Durations and Easing Curves

**Cite:** `MinMaxCloseControl.xaml`, `App.xaml`, MUX TabView internals

| Animation | Duration | Easing |
|---|---|---|
| Caption button hover-out (bg) | **150ms** | Linear (no easing specified) |
| Caption button hover-out (fg) | **100ms** | Linear |
| Caption button hover-in | **0ms** (instant setter) | N/A |
| Tab underline slide | ~**300ms** | MUX spring animation (not overridden) |
| Command palette enter/exit | ~**250ms** | ContentThemeTransition default (cubic decelerate) |
| Scrollbar collapse | ~**300ms** | MUX ScrollViewer default opacity fade |
| Tab add/remove | `AddDeleteThemeTransition` + `ContentThemeTransition` + `ReorderThemeTransition` | System defaults (~200-350ms, decelerate curve) |

### Notes for GDI/Win32 Implementation
- WT's 150ms/100ms caption button transitions are simple linear color interpolations. Replicate with `SetTimer` at 16ms intervals (60 FPS) or a tween engine.
- For spring-based tab indicator slide, approximate with cubic-bezier(0.1, 0.9, 0.2, 1.0) at 300ms.
- WinUI's `ContentThemeTransition` is roughly translateY(28px->0) + opacity(0->1) over 250ms with a decelerate curve ~cubic-bezier(0.1, 0.9, 0.2, 1.0).
- Caption buttons have **no easing curve** -- pure linear interpolation confirmed by the XAML `<ColorAnimation>` lacking an `EasingFunction` child.
