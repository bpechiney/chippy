//! Interactive terminal loop. Each tick redraws the framebuffer in place via
//! cursor-home + the half-block renderer, advances the emulator one frame,
//! then sleeps to ~60 Hz. SIGINT terminates the program through the default
//! handler — no signal-handler installation is needed for v1, since the loop
//! has no resources that require explicit teardown beyond the writer the
//! caller already owns.

const std = @import("std");
const Io = std.Io;
const core = @import("chippy_core");
const render = @import("render.zig");

const FRAME_NS: i96 = 16_666_667;

pub fn run(io: Io, m: *core.Machine, writer: *Io.Writer) !void {
    while (true) {
        try writer.writeAll("\x1b[H");
        try render.render(&m.framebuffer, writer);
        try writer.flush();
        m.runFrame();
        try io.sleep(.fromNanoseconds(FRAME_NS), .awake);
    }
}
