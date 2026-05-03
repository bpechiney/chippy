//! Golden-snapshot harness for Timendus's IBM-logo ROM (ADR 0004).
//!
//! CI on the matrix (ubuntu-latest, macos-latest) runs the same bytes a
//! developer does — that cross-runner determinism is the whole point.

const harness = @import("golden_harness.zig");

const ROM_PATH = "tests/test_roms/ibm_logo.ch8";
const GOLDEN_PATH = "tests/test_goldens/ibm_logo_after_100_cycles.bin";
// Bumped 30→100 for M3.3 vBlank-wait stall budget; see ADR 0012. Captured
// bytes unchanged (vanilla JP-self loop is framebuffer-stable beyond N≈14).
const CYCLE_COUNT: u32 = 100;

test "IBM logo: framebuffer after 100 cycles matches golden" {
    try harness.runAndCompare(.{
        .rom_path = ROM_PATH,
        .golden_path = GOLDEN_PATH,
        .run = .{ .cycles = CYCLE_COUNT },
    });
}
