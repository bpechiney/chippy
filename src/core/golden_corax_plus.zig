//! Golden-snapshot harness for Timendus's corax+ opcode self-test (ADR 0004).
//!
//! Keystone gate for M2: corax+ exercises subroutines, conditional skips, the
//! ALU, indexed jump, address-register arithmetic, BCD, bulk register memory
//! load/store, font lookup, and shifts — every opcode this milestone added.
//! CI on the matrix (ubuntu-latest, macos-latest) runs the same bytes a
//! developer does — that cross-runner determinism is the whole point.

const harness = @import("golden_harness.zig");

const ROM_PATH = "tests/test_roms/corax_plus.ch8";
const GOLDEN_PATH = "tests/test_goldens/corax_plus_after_1000_cycles.bin";
const CYCLE_COUNT: u32 = 1000;

test "corax+: framebuffer after 1000 cycles matches golden" {
    try harness.runAndCompare(.{
        .rom_path = ROM_PATH,
        .golden_path = GOLDEN_PATH,
        .run = .{ .cycles = CYCLE_COUNT },
    });
}
