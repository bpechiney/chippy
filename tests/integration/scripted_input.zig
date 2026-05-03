//! Test-only scripted-keypad-with-framebuffer-checkpoints helper for the
//! `6-keypad.ch8` golden (ADR 0013). Lives in the integration-test module
//! and reaches `Machine`, `Framebuffer`, and `assemble` only via
//! `chippy_core`'s public API — never `src/core/` internals.
//!
//! The helper is justified only because `6-keypad.ch8` is a real second
//! caller for "drive a `Machine` through a multi-event keypad timeline with
//! framebuffer assertions at scripted checkpoints" (rule 9). EX9E/EXA1 unit
//! tests use raw `setKey` (single-step skip-or-not); FX0A unit tests in M4.3
//! use raw `setKey` + `step` interleaving (single-transition sequence). Only
//! `6-keypad.ch8`'s four-checkpoint timeline justifies a shared scheduler,
//! and even then the helper itself ships under test (the unit tests below
//! cover the scheduler's contract before the 6-keypad ROM uses it).

const std = @import("std");
const chippy = @import("chippy_core");
const Machine = chippy.Machine;
const Framebuffer = chippy.Framebuffer;
const harness = @import("golden_harness.zig");

const PACKED_BYTES = harness.PACKED_BYTES;

pub const KeyEvent = struct {
    cycle: u64,
    key: u4,
    down: bool,
};

pub const Checkpoint = struct {
    cycle: u64,
    expected_packed: []const u8,
    label: []const u8,
};

/// Drives `m` from its current `timing.cycles` forward, applying each
/// `events` entry via `Machine.setKey` at its scripted cycle and asserting
/// the packed framebuffer matches `expected_packed` at each `checkpoints`
/// entry. Both slices must be pre-sorted ascending by `cycle`. `cycle`
/// values are absolute (interpreted against `m.timing.cycles`), so the
/// caller hands a fresh `Machine` (`timing.cycles == 0`) for the absolute
/// cycle counts to mean "from boot."
///
/// Cycle accounting mirrors `runFrame`: each `step` call advances
/// `timing.cycles` by 1 regardless of `StepResult` (per ADR 0012 + ADR
/// 0013's "cycles ≠ instructions" contract — `.waiting_for_vblank` and
/// `.waiting_for_key` returns still consume a cycle), and timers tick
/// every `cycles_per_frame` cycles at frame boundaries. `.halted` returns
/// fail the whole helper (no test ROM under this helper should halt; that
/// would be a chippy bug, not ROM input).
///
/// Failure messages identify which checkpoint diverged (label + cycle),
/// so a regression localizes to the subtest that matters.
pub fn runScripted(
    m: *Machine,
    events: []const KeyEvent,
    checkpoints: []const Checkpoint,
) !void {
    const max_target = maxCycle(m, events, checkpoints);

    var event_idx: usize = 0;
    var checkpoint_idx: usize = 0;
    while (true) {
        while (event_idx < events.len and events[event_idx].cycle == m.timing.cycles) : (event_idx += 1) {
            m.setKey(events[event_idx].key, events[event_idx].down);
        }
        while (checkpoint_idx < checkpoints.len and checkpoints[checkpoint_idx].cycle == m.timing.cycles) : (checkpoint_idx += 1) {
            const cp = checkpoints[checkpoint_idx];
            const actual = harness.packFramebuffer(&m.framebuffer);
            std.testing.expectEqualSlices(u8, cp.expected_packed, &actual) catch |err| {
                std.debug.print(
                    "scripted_input: checkpoint '{s}' (cycle {}) framebuffer mismatch\n",
                    .{ cp.label, cp.cycle },
                );
                return err;
            };
        }
        if (m.timing.cycles >= max_target) break;
        try driveTo(m, nextHaltCycle(m.timing.cycles, events, event_idx, checkpoints, checkpoint_idx, max_target));
    }
}

/// Re-baseline path for `golden_keypad.zig`: drives `m` through `events`
/// up to `target_cycle`, applying each event at its scripted cycle, and
/// returns the packed framebuffer captured at `target_cycle`. Shares
/// `driveTo`'s step + frame-tick contract with `runScripted` so the two
/// produce byte-identical results at the same cycle.
pub fn captureAt(
    m: *Machine,
    events: []const KeyEvent,
    target_cycle: u64,
) ![harness.PACKED_BYTES]u8 {
    const max_target = maxCycle(m, events, &.{
        .{ .cycle = target_cycle, .expected_packed = &.{}, .label = "" },
    });

    var event_idx: usize = 0;
    while (true) {
        while (event_idx < events.len and events[event_idx].cycle == m.timing.cycles) : (event_idx += 1) {
            m.setKey(events[event_idx].key, events[event_idx].down);
        }
        if (m.timing.cycles >= max_target) break;
        try driveTo(m, nextHaltCycle(m.timing.cycles, events, event_idx, &.{}, 0, max_target));
    }
    return harness.packFramebuffer(&m.framebuffer);
}

fn maxCycle(m: *const Machine, events: []const KeyEvent, checkpoints: []const Checkpoint) u64 {
    // events/checkpoints are pre-sorted ascending; the last entry is the max.
    var max_target = m.timing.cycles;
    if (events.len > 0 and events[events.len - 1].cycle > max_target) max_target = events[events.len - 1].cycle;
    if (checkpoints.len > 0 and checkpoints[checkpoints.len - 1].cycle > max_target) max_target = checkpoints[checkpoints.len - 1].cycle;
    return max_target;
}

fn nextHaltCycle(
    current: u64,
    events: []const KeyEvent,
    event_idx: usize,
    checkpoints: []const Checkpoint,
    checkpoint_idx: usize,
    max_target: u64,
) u64 {
    var next = max_target;
    if (event_idx < events.len and events[event_idx].cycle > current and events[event_idx].cycle < next) {
        next = events[event_idx].cycle;
    }
    if (checkpoint_idx < checkpoints.len and checkpoints[checkpoint_idx].cycle > current and checkpoints[checkpoint_idx].cycle < next) {
        next = checkpoints[checkpoint_idx].cycle;
    }
    return next;
}

// `Machine.runCycles(1)` already increments `timing.cycles` for `.ran`,
// `.waiting_for_vblank`, and `.waiting_for_key` per ADR 0012/0013, and
// returns 0 on `.halted`. The frame-aligned `tickTimers` mirrors what
// `Machine.runFrame` would do for a whole frame, but inserts the tick at
// each `cycles_per_frame` boundary so events landing mid-frame still see
// the correct delay-timer state.
fn driveTo(m: *Machine, target_cycle: u64) !void {
    const cycles_per_frame: u64 = m.options.cycles_per_second / 60;
    while (m.timing.cycles < target_cycle) {
        if (m.runCycles(1) == 0) return error.UnexpectedHalt;
        if (m.timing.cycles % cycles_per_frame == 0) m.tickTimers();
    }
}

const assemble = chippy.assemble;

test "runScripted: zero-event/zero-checkpoint timeline returns immediately on a fresh machine" {
    var m = Machine.init(.{});
    defer m.deinit();
    try runScripted(&m, &.{}, &.{});
    try std.testing.expectEqual(@as(u64, 0), m.timing.cycles);
}

test "runScripted: a single checkpoint advances timing.cycles to the checkpoint's cycle" {
    var m = Machine.init(.{});
    defer m.deinit();
    try m.loadRom(&assemble(.{0x1200})); // JP 0x200 — tight self-loop, no halt.

    const empty: [PACKED_BYTES]u8 = [_]u8{0} ** PACKED_BYTES;
    try runScripted(&m, &.{}, &.{
        .{ .cycle = 100, .expected_packed = &empty, .label = "end" },
    });
    try std.testing.expectEqual(@as(u64, 100), m.timing.cycles);
}

// Test ROM that draws font glyph "0" at (5, 7) only when key 0xE is currently
// down at the SKP fetch. Used to prove a cycle-0 `KeyEvent` reaches the first
// `step` (key-down branch fires) and that an event scheduled after the fetch
// does not retroactively rewrite the past (key-up branch fires).
const KEY_GATED_DRAW_ROM = assemble(.{
    0x600E, 0xA050, 0x6105, 0x6207, 0xE09E, 0x120E, 0xD125, 0x120E,
});

fn font0DrawnAt5_7() [PACKED_BYTES]u8 {
    var fb: Framebuffer = .{};
    _ = fb.xorSprite(5, 7, &.{ 0xF0, 0x90, 0x90, 0x90, 0xF0 }, false);
    return harness.packFramebuffer(&fb);
}

test "runScripted: a cycle-0 KeyEvent is applied before the first step" {
    var m = Machine.init(.{ .quirks = .{ .vblank_wait_on_draw = false } });
    defer m.deinit();
    try m.loadRom(&KEY_GATED_DRAW_ROM);

    const expected = font0DrawnAt5_7();
    try runScripted(
        &m,
        &.{.{ .cycle = 0, .key = 0xE, .down = true }},
        &.{.{ .cycle = 50, .expected_packed = &expected, .label = "drawn" }},
    );
}

test "runScripted: with no events, a key-gated ROM leaves the framebuffer empty at the checkpoint" {
    var m = Machine.init(.{ .quirks = .{ .vblank_wait_on_draw = false } });
    defer m.deinit();
    try m.loadRom(&KEY_GATED_DRAW_ROM);

    const empty: [PACKED_BYTES]u8 = [_]u8{0} ** PACKED_BYTES;
    try runScripted(
        &m,
        &.{},
        &.{.{ .cycle = 50, .expected_packed = &empty, .label = "skipped" }},
    );
}

test "runScripted: a KeyEvent that arrives *after* the SKP fetch does not retroactively draw" {
    var m = Machine.init(.{ .quirks = .{ .vblank_wait_on_draw = false } });
    defer m.deinit();
    try m.loadRom(&KEY_GATED_DRAW_ROM);

    const empty: [PACKED_BYTES]u8 = [_]u8{0} ** PACKED_BYTES;
    try runScripted(
        &m,
        &.{.{ .cycle = 5, .key = 0xE, .down = true }},
        &.{.{ .cycle = 50, .expected_packed = &empty, .label = "missed" }},
    );
}
