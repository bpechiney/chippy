//! Interactive terminal loop. Each tick redraws the framebuffer in place via
//! cursor-home + the half-block renderer, writes a 4-char BEEP indicator
//! beneath it, advances the emulator one frame, then sleeps to ~60 Hz.
//! SIGINT terminates the program through the default handler — no
//! signal-handler installation is needed for v1, since the loop has no
//! resources that require explicit teardown beyond the writer the caller
//! already owns.
//!
//! The BEEP indicator is fixed-width (4 cells) so a state flip from on to
//! off overwrites cleanly on the next frame's cursor-home redraw — variable
//! widths would leak stale chars onto the indicator row.

const std = @import("std");
const Io = std.Io;
const core = @import("chippy_core");
const render = @import("render.zig");

const FRAME_NS: i96 = 16_666_667;

pub fn run(io: Io, m: *core.Machine, writer: *Io.Writer) !void {
    while (true) {
        try writer.writeAll("\x1b[H");
        try render.render(&m.framebuffer, writer);
        try writeBeepIndicator(m.isBeeping(), writer);
        try writer.flush();
        m.runFrame();
        try io.sleep(.fromNanoseconds(FRAME_NS), .awake);
    }
}

pub fn writeBeepIndicator(beeping: bool, writer: anytype) !void {
    try writer.writeAll(if (beeping) "BEEP" else "    ");
}

test "writeBeepIndicator: 'BEEP' is emitted when the beeper is on" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeBeepIndicator(true, &aw.writer);
    try std.testing.expectEqualStrings("BEEP", aw.written());
}

test "writeBeepIndicator: four spaces are emitted when the beeper is off" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeBeepIndicator(false, &aw.writer);
    try std.testing.expectEqualStrings("    ", aw.written());
}
