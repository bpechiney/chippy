//! Golden-snapshot harness for Timendus's 6-keypad.ch8 (ADR 0004).
//!
//! Second M4 keystone gate: 6-keypad.ch8 verifies all three keypad opcodes
//! (EX9E, EXA1, FX0A) end-to-end with scripted input across four reference
//! checkpoints. Each subtest jumps directly off `RAM[0x1FF]` (1=keypad-down,
//! 2=keypad-up, 3=keypad-getkey, 0=menu) so a separate `Machine` runs each
//! subtest from boot — the EX9E and EXA1 subtests are dead-end infinite
//! loops with no menu return path, so the four checkpoints can't share one
//! Machine via menu navigation.
//!
//! Why `.bin` regression contract instead of runtime PNG decode: matches
//! the M4.2 precedent (5-quirks.ch8 golden) — a runtime PNG decoder would
//! cost ~300 LOC of test-only, non-carry-forward code; cross-runner
//! determinism via the captured `.bin` carries the regression load forward,
//! and the vendored PNGs anchor correctness as the eyeball-gate at PR
//! review time.

const std = @import("std");
const Machine = @import("machine.zig").Machine;
const harness = @import("golden_harness.zig");
const scripted = @import("scripted_input.zig");
const bus_mod = @import("bus.zig");

const ROM_PATH = "tests/test_roms/keypad.ch8";

const MENU_GOLDEN = "tests/test_goldens/keypad_menu_after_2000_cycles.bin";
const MENU_CYCLES: u64 = 2000;

const DOWN_GOLDEN = "tests/test_goldens/keypad_down_after_2000_cycles.bin";
const DOWN_CYCLES: u64 = 2000;

const UP_GOLDEN = "tests/test_goldens/keypad_up_after_5000_cycles.bin";
const UP_CYCLES: u64 = 5000;

const GETKEY_GOLDEN = "tests/test_goldens/keypad_getkey_after_5000_cycles.bin";
const GETKEY_CYCLES: u64 = 5000;
// Press@cycle 350 lands ~50 cycles after FX0A starts stalling and ~20 cycles
// after the ROM's `delay := 3` timer reaches 0 (3 frames * 11 cycles/frame =
// 33 cycles after the timer is set, plus FX0A's pre-stall setup) — needed so
// the post-FX0A `if v1 != 0` (delay) check passes (NOT-HALTING test). Release
// 50 cycles after press lets phase 1 of FX0A claim the held key, then phase 2
// consume on the release. See pre-flight trace in the PR description.
const FX0A_PRESS_CYCLE: u64 = 350;
const FX0A_RELEASE_CYCLE: u64 = 400;

const PLATFORM_SELECT_ADDR: u12 = 0x1FF;

const SubtestSpec = struct {
    poke: u8,
    events: []const scripted.KeyEvent,
    checkpoint_cycle: u64,
    label: []const u8,
    golden_path: []const u8,
};

fn runSubtest(spec: SubtestSpec) !void {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;

    const rom = try cwd.readFileAlloc(io, ROM_PATH, std.testing.allocator, .limited(bus_mod.ROM_MAX_BYTES));
    defer std.testing.allocator.free(rom);

    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(rom);
    m.pokeRam(PLATFORM_SELECT_ADDR, spec.poke);

    if (harness.updateGoldensRequested()) {
        const captured = try scripted.captureAt(&m, spec.events, spec.checkpoint_cycle);
        try cwd.writeFile(io, .{ .sub_path = spec.golden_path, .data = &captured });
        return;
    }

    const golden = try cwd.readFileAlloc(io, spec.golden_path, std.testing.allocator, .limited(harness.PACKED_BYTES + 1));
    defer std.testing.allocator.free(golden);

    try scripted.runScripted(&m, spec.events, &.{
        .{ .cycle = spec.checkpoint_cycle, .expected_packed = golden, .label = spec.label },
    });
}

test "6-keypad: menu checkpoint matches reference (cursor-visible blink phase, EX9E + EXA1 menu polling)" {
    try runSubtest(.{
        .poke = 0,
        .events = &.{},
        .checkpoint_cycle = MENU_CYCLES,
        .label = "menu",
        .golden_path = MENU_GOLDEN,
    });
}

test "6-keypad: EX9E (keypad-down) checkpoint matches reference with keys 1+6 held" {
    try runSubtest(.{
        .poke = 1,
        .events = &.{
            .{ .cycle = 0, .key = 0x1, .down = true },
            .{ .cycle = 0, .key = 0x6, .down = true },
        },
        .checkpoint_cycle = DOWN_CYCLES,
        .label = "down",
        .golden_path = DOWN_GOLDEN,
    });
}

test "6-keypad: EXA1 (keypad-up) checkpoint matches reference with keys 1+6 held" {
    try runSubtest(.{
        .poke = 2,
        .events = &.{
            .{ .cycle = 0, .key = 0x1, .down = true },
            .{ .cycle = 0, .key = 0x6, .down = true },
        },
        .checkpoint_cycle = UP_CYCLES,
        .label = "up",
        .golden_path = UP_GOLDEN,
    });
}

test "6-keypad: FX0A (keypad-getkey) ALL-GOOD checkpoint matches reference after press+release" {
    try runSubtest(.{
        .poke = 3,
        .events = &.{
            .{ .cycle = FX0A_PRESS_CYCLE, .key = 0x1, .down = true },
            .{ .cycle = FX0A_RELEASE_CYCLE, .key = 0x1, .down = false },
        },
        .checkpoint_cycle = GETKEY_CYCLES,
        .label = "getkey",
        .golden_path = GETKEY_GOLDEN,
    });
}
