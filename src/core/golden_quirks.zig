//! Golden-snapshot harness for Timendus's 5-quirks.ch8 (ADR 0004).
//!
//! Keystone gate for M4: 5-quirks.ch8 verifies all six VIP quirk gates
//! (vF reset on logical, FX55/FX65 I increment, vBlank wait on draw,
//! display clipping, shift source, BNNN jump base) by running each test
//! sequence and rendering a pass/fail indicator on a results grid. The
//! ROM's first act is to read `RAM[0x1FF]` to pick a platform preset; we
//! `pokeRam(0x1FF, 1)` to bypass the interactive menu and select CHIP-8
//! /COSMAC VIP. The wait-loop at `\$204` (`SKNP V0 / JP self` per Timendus's
//! "wait for key 0 release" idiom) self-clears in 16 iterations with the
//! default-empty keypad — see issue #79's pre-flight trace.
//!
//! Why `runFrame` (not `runCycles`): this ROM uses the delay timer for
//! splash pacing, and FX0A to wait for input before restarting the test
//! cycle. `runCycles` advances the CPU but **does not tick DT/ST** (that
//! happens only in `runFrame.tick()`); without DT ticking, the splash
//! never auto-advances. Without FX0A blocking, the post-test wait-for-key
//! falls through and the ROM endlessly restarts. The combination of
//! `runFrame` (DT ticks) + working FX0A (post-test stall) produces a
//! deterministic frozen post-results state.
//!
//! `N = 1000` frames chosen empirically per the M2.11 procedure: the
//! framebuffer reaches the all-six-quirks stable state by frame ~500
//! (post-test FX0A blocks at PC=0x766, freezing the screen). N=1000
//! is a 2× safety margin, matching the corax+ test's cycle count for
//! pattern consistency. Test runtime is sub-millisecond.
//!
//! See the file-level doc in `golden_ibm_logo.zig` for the runtime-read /
//! `@embedFile` package-path constraint that motivates the relative-path
//! load pattern shared with that test.

const std = @import("std");
const Machine = @import("machine.zig").Machine;
const Framebuffer = @import("display.zig").Framebuffer;
const display = @import("display.zig");
const bus_mod = @import("bus.zig");

const ROM_PATH = "tests/test_roms/quirks.ch8";
const GOLDEN_PATH = "tests/test_goldens/quirks_after_1000_frames.bin";
const FRAME_COUNT: u32 = 1000;
const PLATFORM_SELECT_ADDR: u12 = 0x1FF;
const PLATFORM_CHIP8_VIP: u8 = 1;
const PACKED_BYTES: usize = display.PIXELS / 8;

/// Row-major, MSB = leftmost pixel — the standard CHIP-8 sprite-pack layout,
/// chosen so a hex dump of the snapshot reads visually like the screen.
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

test "5-quirks: framebuffer after 1000 frames matches golden (all six VIP quirks pass)" {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;

    const rom = try cwd.readFileAlloc(io, ROM_PATH, std.testing.allocator, .limited(bus_mod.ROM_MAX_BYTES));
    defer std.testing.allocator.free(rom);

    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(rom);
    m.pokeRam(PLATFORM_SELECT_ADDR, PLATFORM_CHIP8_VIP);
    var i: u32 = 0;
    while (i < FRAME_COUNT) : (i += 1) m.runFrame();

    const actual = packFramebuffer(&m.framebuffer);

    if (updateGoldensRequested()) {
        try cwd.writeFile(io, .{ .sub_path = GOLDEN_PATH, .data = &actual });
        return;
    }

    const golden = try cwd.readFileAlloc(io, GOLDEN_PATH, std.testing.allocator, .limited(PACKED_BYTES + 1));
    defer std.testing.allocator.free(golden);

    try std.testing.expectEqualSlices(u8, golden, &actual);
}
