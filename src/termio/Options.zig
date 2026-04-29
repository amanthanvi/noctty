//! The options that are used to configure a terminal IO implementation.

const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const Config = @import("../config/Config.zig");
const RendererState = @import("../renderer/State.zig");
const RendererThread = @import("../renderer/Thread.zig");
const renderer_size = @import("../renderer/size.zig");
const backendpkg = @import("backend.zig");
const mailboxpkg = @import("mailbox.zig");
const termiopkg = @import("Termio.zig");

/// All size metrics for the terminal.
size: renderer_size.Size,

/// The full app configuration. This is only available during initialization.
/// The memory it points to is NOT stable after the init call so any values
/// in here must be copied.
full_config: *const Config,

/// The derived configuration for this termio implementation.
config: termiopkg.DerivedConfig,

/// The backend for termio that implements where reads/writes are sourced.
backend: backendpkg.Backend,

/// The mailbox for the terminal. This is how messages are delivered.
/// If you're using termio.Thread this MUST be "mailbox".
mailbox: mailboxpkg.Mailbox,

/// The render state. The IO implementation can modify anything here. The
/// surface thread will setup the initial "terminal" pointer but the IO impl
/// is free to change that if that is useful (i.e. doing some sort of dual
/// terminal implementation.)
renderer_state: *RendererState,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for renderer messages.
renderer_mailbox: *RendererThread.Mailbox,

/// The mailbox for sending the surface messages.
surface_mailbox: apprt.surface.Mailbox,
