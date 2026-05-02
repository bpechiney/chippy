//! Tier 1 debug affordance: per-cycle trace logging. M0 declares the type;
//! actual emission lands at M2 once disassembly produces line content. The
//! function-pointer + ctx shape lets the frontend own the file/buffer
//! without core gaining file-IO knowledge.

pub const TraceSink = struct {
    write: *const fn (ctx: *anyopaque, line: []const u8) void,
    ctx: *anyopaque,
};
