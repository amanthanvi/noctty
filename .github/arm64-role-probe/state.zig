// The renderer State's demand forwarder in its own file, as noctty has it (renderer/State.zig is not the wrapper
// module src/sync/state_mutex.zig): an inline forwarder to the wrapper's inline demand acquire (M-a).
const sm = @import("state_mutex.zig");

pub const State = struct {
    mutex: *sm.StateMutex,

    pub inline fn lockDemand(self: *State) void {
        self.mutex.demand();
    }
};
