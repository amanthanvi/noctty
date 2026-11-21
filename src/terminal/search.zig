//! Search functionality for the terminal.

pub const options = @import("terminal_options");

pub const Query = @import("search/query_options.zig").Query;
pub const QueryOptions = @import("search/query_options.zig").QueryOptions;
pub const QuerySearch = @import("search/query_search.zig").QuerySearch;
/// The type of `QuerySearch.Term.mutex` and the search thread's
/// `Options.mutex`, the renderer-state mutex. With the thread-role layer off,
/// as in every lib-vt build, it has `std.Thread.Mutex`'s size and methods.
pub const StateMutex = @import("../sync/state_mutex.zig").StateMutex;

pub const Active = @import("search/active.zig").ActiveSearch;
pub const PageList = @import("search/pagelist.zig").PageListSearch;
pub const Screen = @import("search/screen.zig").ScreenSearch;
pub const Terminal = @import("search/terminal.zig").TerminalSearch;
pub const Viewport = @import("search/viewport.zig").ViewportSearch;

// The search thread is not available in libghostty due to the xev dep
// for now.
pub const Thread = switch (options.artifact) {
    .ghostty => @import("search/Thread.zig"),
    .lib => void,
};

test {
    @import("std").testing.refAllDecls(@This());

    // Non-public APIs
    _ = @import("search/pattern.zig");
    _ = @import("search/query_options.zig");
    _ = @import("search/sliding_window.zig");
}
