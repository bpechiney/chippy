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

    /// Vanilla COSMAC VIP semantics (M3 introduces a `Quirks`-gated alternative):
    /// the *starting* coordinate is reduced modulo screen dimensions, but pixels
    /// that would extend past the right or bottom edge are **clipped, not wrapped**.
    /// That asymmetry is load-bearing for the IBM logo ROM and gets misremembered
    /// often, so we name it explicitly here. Same spirit as `Bus.read16`'s "wrap
    /// quietly on PC overflow" comment: ROM-derived coordinates must never panic
    /// the host (CLAUDE.md rule 12).
    pub fn xorSprite(self: *Framebuffer, x: usize, y: usize, sprite: []const u8) bool {
        const start_x = x % WIDTH;
        const start_y = y % HEIGHT;
        var collision = false;
        for (sprite, 0..) |row_bits, row| {
            const py = start_y + row;
            if (py >= HEIGHT) break;
            for (0..8) |col| {
                const bit: u1 = @intCast((row_bits >> @intCast(7 - col)) & 1);
                if (bit == 0) continue;
                const px = start_x + col;
                if (px >= WIDTH) continue;
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

    const collided = fb.xorSprite(0, 0, &sprite);

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

    _ = fb.xorSprite(0, 0, &sprite);
    const collided = fb.xorSprite(0, 0, &sprite);

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

    const collided = fb.xorSprite(0, 0, &sprite);

    try std.testing.expectEqual(false, collided);
    try std.testing.expectEqual(@as(u1, 1), fb.get(0, 0));
}

test "xorSprite: a 2-byte sprite lights two adjacent rows independently" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{ 0b1100_0000, 0b0000_0011 };

    const collided = fb.xorSprite(0, 0, &sprite);

    try std.testing.expectEqual(false, collided);
    const row0 = [_]u1{ 1, 1, 0, 0, 0, 0, 0, 0 };
    const row1 = [_]u1{ 0, 0, 0, 0, 0, 0, 1, 1 };
    for (row0, 0..) |bit, col| try std.testing.expectEqual(bit, fb.get(col, 0));
    for (row1, 0..) |bit, col| try std.testing.expectEqual(bit, fb.get(col, 1));
}

test "xorSprite: a sprite at x=60 clips at the right edge — only the leftmost 4 columns are written" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{0xFF};

    const collided = fb.xorSprite(60, 0, &sprite);

    try std.testing.expectEqual(false, collided);
    for (60..WIDTH) |col| try std.testing.expectEqual(@as(u1, 1), fb.get(col, 0));
    // Pixels that would have wrapped onto row 1 must remain clear.
    for (0..WIDTH) |col| try std.testing.expectEqual(@as(u1, 0), fb.get(col, 1));
}

test "xorSprite: a height-4 sprite at y=30 clips at the bottom edge — only the top 2 rows are written" {
    var fb: Framebuffer = .{};
    const sprite = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

    const collided = fb.xorSprite(0, 30, &sprite);

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

    const collided = fb.xorSprite(65, 33, &sprite);

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
