//! "apprt" is the "application runtime" package. This abstracts the
//! application runtime and lifecycle management such as creating windows,
//! getting user input (mouse/keyboard), etc.
//!
//! This fork keeps a native Win32 runtime for the application and a minimal
//! non-app/runtime split for library and wasm-specific artifacts.
//!
//! The goal is still to share as much of the core logic as possible while
//! keeping the user-facing application runtime Windows-native.
const build_config = @import("build_config.zig");

const structs = @import("apprt/structs.zig");

pub const action = @import("apprt/action.zig");
pub const ipc = @import("apprt/ipc.zig");
pub const none = @import("apprt/none.zig");
pub const win32 = @import("apprt/win32.zig");
/// Pure workspace state/reducer used by the incremental Win32 shell migration.
pub const win32_shell = @import("apprt/win32_shell.zig");
pub const win32_job_object = @import("apprt/win32_job_object.zig");
pub const win32_session_state = @import("apprt/win32_session_state.zig");
pub const win32_session_persistence = @import("apprt/win32_session_persistence.zig");
pub const win32_recovery = @import("apprt/win32_recovery.zig");
pub const win32_settings_transaction = @import("apprt/win32_settings_transaction.zig");
pub const win32_universal_palette = @import("apprt/win32_universal_palette.zig");
pub const win32_tab_drop_zones = @import("apprt/win32_tab_drop_zones.zig");
pub const win32_compositor = @import("apprt/win32_compositor.zig");
pub const browser = @import("apprt/browser.zig");
pub const embedded = none;
pub const surface = @import("apprt/surface.zig");

pub const Action = action.Action;
pub const Runtime = @import("apprt/runtime.zig").Runtime;
pub const Target = action.Target;

pub const ContentScale = structs.ContentScale;
pub const Clipboard = structs.Clipboard;
pub const ClipboardContent = structs.ClipboardContent;
pub const ClipboardRequest = structs.ClipboardRequest;
pub const ClipboardRequestType = structs.ClipboardRequestType;
pub const ColorScheme = structs.ColorScheme;
pub const CursorPos = structs.CursorPos;
pub const IMEPos = structs.IMEPos;
pub const Selection = structs.Selection;
pub const SurfaceSize = structs.SurfaceSize;

/// The implementation to use for the app runtime. This is comptime chosen
/// so that every build has exactly one application runtime implementation.
/// Note: it is very rare to use Runtime directly; most usage will use
/// Window or something.
pub const runtime = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) {
        .none => none,
        .win32 => win32,
    },
    .lib => embedded,
    .wasm_module => browser,
};

pub const App = runtime.App;
pub const Surface = runtime.Surface;

test {
    _ = Runtime;
    _ = runtime;
    _ = action;
    _ = structs;
    _ = win32_job_object;
    _ = win32_session_state;
    _ = win32_session_persistence;
    _ = win32_recovery;
    _ = win32_settings_transaction;
    _ = win32_universal_palette;
    _ = win32_tab_drop_zones;
    _ = win32_compositor;
    _ = win32_shell;
    _ = @import("apprt/win32_named_layout.zig");
    _ = @import("apprt/win32_power.zig");
    _ = @import("apprt/win32_elevation.zig");
    _ = @import("apprt/win32_hints.zig");
    _ = @import("apprt/win32_copy_mode.zig");
    _ = @import("apprt/win32_ssh_hosts.zig");
    _ = @import("apprt/win32_terminal_handoff.zig");
    _ = @import("apprt/win32_jump_list.zig");
    _ = @import("apprt/win32_explorer_verb.zig");
}
