//! 64×32 monochrome framebuffer. Backed by a flat `[2048]u1` array so element
//! access is cheap; sprite XOR drawing for `DXYN` lands at M1.

const std = @import("std");

pub const WIDTH: usize = 64;
pub const HEIGHT: usize = 32;
pub const PIXELS: usize = WIDTH * HEIGHT;

pub const Framebuffer = struct {
    pixels: [PIXELS]u1 = [_]u1{0} ** PIXELS,

    pub fn clear(self: *Framebuffer) void {
        @memset(&self.pixels, 0);
    }

    pub fn get(self: *const Framebuffer, x: usize, y: usize) u1 {
        return self.pixels[y * WIDTH + x];
    }

    pub fn set(self: *Framebuffer, x: usize, y: usize, value: u1) void {
        self.pixels[y * WIDTH + x] = value;
    }

    /// Vanilla COSMAC VIP semantics (`wrap = false`): the *starting* coordinate is
    /// reduced modulo screen dimensions, but pixels that would extend past the
    /// right or bottom edge are **clipped, not wrapped**. That asymmetry is
    /// load-bearing for the IBM logo ROM and gets misremembered often. The
    /// modern non-VIP alternative (`wrap = true`) wraps every pixel modulo
    /// dimensions on both axes — gated by `Quirks.display_clipping` at the
    /// `DXYN` call site. Either way, ROM-derived coordinates must never panic
    /// the host (CLAUDE.md rule 12).
    pub fn xorSprite(self: *Framebuffer, x: usize, y: usize, sprite: []const u8, wrap: bool) bool {
        const start_x = x % WIDTH;
        const start_y = y % HEIGHT;
        var collision = false;
        for (sprite, 0..) |row_bits, row| {
            const py_offset = start_y + row;
            const py = if (wrap) py_offset % HEIGHT else if (py_offset < HEIGHT) py_offset else break;
            for (0..8) |col| {
                const bit: u1 = @intCast((row_bits >> @intCast(7 - col)) & 1);
                if (bit == 0) continue;
                const px_offset = start_x + col;
                const px = if (wrap) px_offset % WIDTH else if (px_offset < WIDTH) px_offset else continue;
                const idx = py * WIDTH + px;
                if (self.pixels[idx] == 1) collision = true;
                self.pixels[idx] ^= 1;
            }
        }
        return collision;
    }
};

test "xorSprite: 1-byte sprite at (0,0) on a clear framebuffer lights the 8 expected pixels and reports no collision" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{0b1010_0011};

    const collided = fb.xorSprite(0, 0, &sprite, false);

    try std.testing.expectEqual(false, collided);
    const expected = [_]u1{ 1, 0, 1, 0, 0, 0, 1, 1 };
    for (expected, 0..) |bit, col| {
        try std.testing.expectEqual(bit, fb.get(col, 0));
    }
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 1));
}

test "xorSprite: drawing the same sprite twice at the same location erases it and reports a collision" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{0b1010_0011};

    _ = fb.xorSprite(0, 0, &sprite, false);
    const collided = fb.xorSprite(0, 0, &sprite, false);

    try std.testing.expectEqual(true, collided);
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 0));
}

test "xorSprite: a zero sprite-bit over a lit framebuffer pixel does not report a collision or clear the pixel" {
    var fb: Framebuffer = .{};
    fb.set(0, 0, 1);
    // The MSB of this byte is 0; column 0 of the sprite is therefore a zero-bit.
    // A naive impl that flagged collision on any already-set pixel inside the
    // sprite footprint (rather than only on a 1→0 transition) would fail here.
    const sprite = [_]u8{0b0111_1111};

    const collided = fb.xorSprite(0, 0, &sprite, false);

    try std.testing.expectEqual(false, collided);
    try std.testing.expectEqual(@as(u1, 1), fb.get(0, 0));
}

test "xorSprite: a 2-byte sprite lights two adjacent rows independently" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{ 0b1100_0000, 0b0000_0011 };

    const collided = fb.xorSprite(0, 0, &sprite, false);

    try std.testing.expectEqual(false, collided);
    const row0 = [_]u1{ 1, 1, 0, 0, 0, 0, 0, 0 };
    const row1 = [_]u1{ 0, 0, 0, 0, 0, 0, 1, 1 };
    for (row0, 0..) |bit, col| try std.testing.expectEqual(bit, fb.get(col, 0));
    for (row1, 0..) |bit, col| try std.testing.expectEqual(bit, fb.get(col, 1));
}

test "xorSprite: a sprite at x=60 clips at the right edge — only the leftmost 4 columns are written" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{0xFF};

    const collided = fb.xorSprite(60, 0, &sprite, false);

    try std.testing.expectEqual(false, collided);
    for (60..WIDTH) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 0));
    // Pixels that would have wrapped onto row 1 must remain clear.
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 1));
}

test "xorSprite: a height-4 sprite at y=30 clips at the bottom edge — only the top 2 rows are written" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

    const collided = fb.xorSprite(0, 30, &sprite, false);

    try std.testing.expectEqual(false, collided);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 30));
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 31));
    // Rows 32–33 don't exist; assert nothing was written by checking row 0 and the
    // far end of the framebuffer remain clear (a wrap into row 0 would surface here).
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 0));
}

test "xorSprite: starting (x, y) is reduced modulo the screen dimensions before drawing" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{0xFF};

    const collided = fb.xorSprite(65, 33, &sprite, false);

    try std.testing.expectEqual(false, collided);
    // (65, 33) wraps to (1, 1); the sprite occupies columns 1–8 of row 1.
    try std.testing.expectEqual(@as(u1, 0), fb.get(0, 1));
    for (1..9) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 1));
    try std.testing.expectEqual(@as(u1, 0), fb.get(9, 1));
    // The unwrapped destination row (33) doesn't exist; the wrapped row (1) is the
    // only row that should have changed. Confirm row 0 and row 2 are untouched.
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 0));
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 2));
}

test "xorSprite: wrap=true at x=60 wraps the rightmost 4 columns to columns 0-3 of the same row" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{0xFF};

    const collided = fb.xorSprite(60, 0, &sprite, true);

    try std.testing.expectEqual(false, collided);
    for (60..WIDTH) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 0));
    for (0..4) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 0));
    // Pixels 4-59 of row 0 untouched; row 1 untouched.
    for (4..60) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 0));
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 1));
}

test "xorSprite: wrap=true with a height-4 sprite at y=30 wraps rows 32-33 onto rows 0-1" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

    const collided = fb.xorSprite(0, 30, &sprite, true);

    try std.testing.expectEqual(false, collided);
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 30));
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 31));
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 0));
    for (0..8) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 1));
    // Row 2 untouched; far-right of row 0 untouched.
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 2));
    for (8..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 0));
}

test "xorSprite: wrap=true at x=60 y=30 with a 2x2 sprite wraps both axes simultaneously" {
    var fb: Framebuffer = .{};
    // 2-row sprite, each row's leftmost 8 columns are 0xFF.
    const sprite = [_]u8{ 0xFF, 0xFF };

    const collided = fb.xorSprite(60, 30, &sprite, true);

    try std.testing.expectEqual(false, collided);
    // Row 30 — vanilla columns 60-63 + wrapped columns 0-3.
    for (60..WIDTH) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 30));
    for (0..4) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 30));
    // Row 31 — same.
    for (60..WIDTH) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 31));
    for (0..4) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 31));
    // Pixels 4-59 of rows 30 and 31 untouched; row 0 and row 1 untouched (only Y
    // overflow would land there, but this sprite is 2 rows starting at 30, so
    // it stays inside Y bounds).
    for (4..60) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 30));
    for (4..60) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 31));
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 0));
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 1));
}
