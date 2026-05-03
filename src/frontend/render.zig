//! Pure framebuffer-to-ANSI renderer. No allocation, no globals, no terminal-
//! control codes other than color and reset, so the same framebuffer always
//! produces the same byte stream — a property the M1.5 golden-snapshot
//! discipline (ADR 0004) extends to terminal output once a snapshot lands.

const std = @import("std");
const core = @import("chippy_core");
const Framebuffer = core.Framebuffer;

const CELL_BOTH_OFF = "\x1b[30m\x1b[40m▀";
const CELL_TOP_ON = "\x1b[37m\x1b[40m▀";
const CELL_BOTTOM_ON = "\x1b[30m\x1b[47m▀";
const CELL_BOTH_ON = "\x1b[37m\x1b[47m▀";
const EOL = "\x1b[0m\n";

// HEIGHT/2 terminal lines because each U+2580 cell stacks two pixel rows.
const WIDTH: usize = 64;
const HEIGHT: usize = 32;

pub fn render(fb: *const Framebuffer, writer: anytype) !void {
    var row: usize = 0;
    while (row < HEIGHT) : (row += 2) {
        for (0..WIDTH) |col| {
            const top = fb.get(col, row);
            const bottom = fb.get(col, row + 1);
            const cell = if (top == 1 and bottom == 1)
                CELL_BOTH_ON
            else if (top == 1)
                CELL_TOP_ON
            else if (bottom == 1)
                CELL_BOTTOM_ON
            else
                CELL_BOTH_OFF;
            try writer.writeAll(cell);
        }
        try writer.writeAll(EOL);
    }
}

test "render: a clear framebuffer produces 16 lines of 64 both-off cells" {
    var fb: Framebuffer = .{};

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&fb, &aw.writer);

    const line = CELL_BOTH_OFF ** 64 ++ EOL;
    const expected = line ** 16;
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "render: a single pixel at (0,0) renders the first cell as top-on, bottom-off" {
    var fb: Framebuffer = .{};
    fb.set(0, 0, 1);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&fb, &aw.writer);

    const first_line = CELL_TOP_ON ++ CELL_BOTH_OFF ** 63 ++ EOL;
    const remaining = (CELL_BOTH_OFF ** 64 ++ EOL) ** 15;
    try std.testing.expectEqualStrings(first_line ++ remaining, aw.written());
}

test "render: a single pixel at (0,1) renders the first cell as top-off, bottom-on" {
    var fb: Framebuffer = .{};
    fb.set(0, 1, 1);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&fb, &aw.writer);

    const first_line = CELL_BOTTOM_ON ++ CELL_BOTH_OFF ** 63 ++ EOL;
    const remaining = (CELL_BOTH_OFF ** 64 ++ EOL) ** 15;
    try std.testing.expectEqualStrings(first_line ++ remaining, aw.written());
}

test "render: a fully-on framebuffer produces 16 lines of 64 both-on cells" {
    var fb: Framebuffer = .{};
    @memset(&fb.pixels, 1);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&fb, &aw.writer);

    const line = CELL_BOTH_ON ** 64 ++ EOL;
    const expected = line ** 16;
    try std.testing.expectEqualStrings(expected, aw.written());
}
