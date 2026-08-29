const std = @import("std");

pub const Options = struct {
    iterations: usize = 2_048,
    max_input_len: usize = 2_048,
    random_seed: u64,
    corpus: []const []const u8,
};

/// Deterministic mutation campaign for toolchains whose continuous fuzzer can
/// assert while shrinking a failing input to zero bytes. Inputs are always
/// non-empty, iteration and allocation counts are fixed, and every even case
/// mutates a valid or interesting corpus entry rather than starting from noise.
pub fn run(
    context: anytype,
    comptime callback: anytype,
    comptime options: Options,
) !void {
    comptime {
        std.debug.assert(options.iterations > 0);
        std.debug.assert(options.max_input_len > 0);
    }

    var prng = std.Random.DefaultPrng.init(options.random_seed);
    const random = prng.random();
    var input: [options.max_input_len]u8 = undefined;

    for (0..options.iterations) |i| {
        var len = 1 + random.uintLessThan(usize, options.max_input_len);
        random.bytes(input[0..len]);

        if (options.corpus.len > 0 and i % 2 == 0) {
            const seed = options.corpus[(i / 2) % options.corpus.len];
            len = @max(1, @min(seed.len, options.max_input_len));
            if (seed.len > 0) @memcpy(input[0..len], seed[0..len]);

            const mutation_count = 1 + random.uintLessThan(usize, @min(len, 8));
            for (0..mutation_count) |_| {
                input[random.uintLessThan(usize, len)] = random.int(u8);
            }
        }

        try callback(context, input[0..len]);
    }
}
