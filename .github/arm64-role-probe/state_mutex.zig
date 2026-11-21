// The M-a wrapper, version-agnostic: public acquiring methods are `inline` and make a `never_tail` call into a
// `noinline` implementation that records @returnAddress(), so the recorded address is inside the function that
// called the public method, whatever the build mode does with tail calls. The demand acquire goes the same way
// through State.lockDemand (inline). `lockOld` is round 12's mechanism (a noinline method called directly), kept for
// the tail-position comparison.
pub const Kind = enum(u8) { lock, demand, try_lock, old, lock_uncancelable };

pub var hook: *const fn (addr: usize, kind: Kind) void = undefined;

pub const StateMutex = struct {
    held: bool = false,

    pub inline fn lock(self: *StateMutex) void {
        @call(.never_tail, lockImpl, .{ self, Kind.lock });
    }

    // r14 (Opus L5): the 0.17 spelling, the same M-a shape as lock
    pub inline fn lockUncancelable(self: *StateMutex) void {
        @call(.never_tail, lockImpl, .{ self, Kind.lock_uncancelable });
    }

    pub inline fn tryLock(self: *StateMutex) bool {
        return @call(.never_tail, tryLockImpl, .{self});
    }

    pub inline fn demand(self: *StateMutex) void {
        @call(.never_tail, lockImpl, .{ self, Kind.demand });
    }

    noinline fn lockImpl(self: *StateMutex, kind: Kind) void {
        hook(@returnAddress(), kind);
        self.held = true;
    }

    noinline fn tryLockImpl(self: *StateMutex) bool {
        hook(@returnAddress(), .try_lock);
        self.held = true;
        return true;
    }

    pub noinline fn lockOld(self: *StateMutex) void {
        hook(@returnAddress(), .old);
        self.held = true;
    }
};

pub const State = struct {
    mutex: *StateMutex,

    pub inline fn lockDemand(self: *State) void {
        self.mutex.demand();
    }
};
