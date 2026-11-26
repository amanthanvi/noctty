const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        _ = target;
        _ = wasm_target;
        return .opengl;
    }
};
