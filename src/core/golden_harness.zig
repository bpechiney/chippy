//! Shared runner for the framebuffer-snapshot golden tests: load a ROM,
//! step the machine, then either compare the packed framebuffer against
//! the on-disk golden or rewrite it when `UPDATE_GOLDENS=1` is set.
//!
//! Files load via runtime relative paths (`cwd.readFileAlloc` with CWD =
//! repo root) instead of `@embedFile` because Zig restricts `@embedFile`
//! to paths inside the module's package directory, and `tests/test_roms/`
//! (ADR 0004) sits outside `chippy_core`'s root at `src/core/`.

const std = @import("std");
const Machine = @import("machine.zig").Machine;
const Framebuffer = @import("display.zig").Framebuffer;
const display = @import("display.zig");
const bus_mod = @import("bus.zig");

const PACKED_BYTES: usize = display.PIXELS / 8;

pub const RunMode = union(enum) {
    cycles: u32,
    frames: u32,
};

pub const RunOptions = struct {
    rom_path: []const u8,
    golden_path: []const u8,
    run: RunMode,
    pre_run: ?*const fn (*Machine) void = null,
};

pub fn runAndCompare(opts: RunOptions) !void {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;

    const rom = try cwd.readFileAlloc(io, opts.rom_path, std.testing.allocator, .limited(bus_mod.ROM_MAX_BYTES));
    defer std.testing.allocator.free(rom);

    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(rom);

    if (opts.pre_run) |hook| hook(&m);

    switch (opts.run) {
        .cycles => |n| _ = m.runCycles(n),
        .frames => |n| {
            var i: u32 = 0;
            while (i < n) : (i += 1) m.runFrame();
        },
    }

    const actual = packFramebuffer(&m.framebuffer);

    if (updateGoldensRequested()) {
        try cwd.writeFile(io, .{ .sub_path = opts.golden_path, .data = &actual });
        return;
    }

    const golden = try cwd.readFileAlloc(io, opts.golden_path, std.testing.allocator, .limited(PACKED_BYTES + 1));
    defer std.testing.allocator.free(golden);

    try std.testing.expectEqualSlices(u8, golden, &actual);
}

// Row-major, MSB = leftmost so a hex dump of the snapshot reads like the screen.
fn packFramebuffer(fb: *const Framebuffer) [PACKED_BYTES]u8 {
    var out: [PACKED_BYTES]u8 = [_]u8{0} ** PACKED_BYTES;
    for (0..display.HEIGHT) |row| {
        for (0..display.WIDTH / 8) |byte_col| {
            var b: u8 = 0;
            for (0..8) |bit| {
                const px = fb.get(byte_col * 8 + bit, row);
                b |= @as(u8, px) << @intCast(7 - bit);
            }
            out[row * (display.WIDTH / 8) + byte_col] = b;
        }
    }
    return out;
}

fn updateGoldensRequested() bool {
    const v = std.testing.environ.getPosix("UPDATE_GOLDENS") orelse return false;
    return std.mem.eql(u8, v, "1");
}
