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

const Machine = @import("chippy_core").Machine;
const harness = @import("golden_harness.zig");

const ROM_PATH = "tests/test_roms/quirks.ch8";
const GOLDEN_PATH = "tests/test_goldens/quirks_after_1000_frames.bin";
const FRAME_COUNT: u32 = 1000;
const PLATFORM_SELECT_ADDR: u12 = 0x1FF;
const PLATFORM_CHIP8_VIP: u8 = 1;

fn selectChip8Vip(m: *Machine) void {
    m.pokeRam(PLATFORM_SELECT_ADDR, PLATFORM_CHIP8_VIP);
}

test "5-quirks: framebuffer after 1000 frames matches golden (all six VIP quirks pass)" {
    try harness.runAndCompare(.{
        .rom_path = ROM_PATH,
        .golden_path = GOLDEN_PATH,
        .run = .{ .frames = FRAME_COUNT },
        .pre_run = selectChip8Vip,
    });
}
