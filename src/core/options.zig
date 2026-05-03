//! Configuration passed to `Machine.init`. Keeps the constructor free of
//! positional arguments so adding knobs later is non-breaking.

const Quirks = @import("quirks.zig").Quirks;
const TraceSink = @import("trace.zig").TraceSink;

pub const Options = struct {
    quirks: Quirks = Quirks.vanilla,
    rng_seed: u64 = 0,
    cycles_per_second: u32 = 700,
    trace: ?TraceSink = null,
    sprite_log: ?TraceSink = null,
};
