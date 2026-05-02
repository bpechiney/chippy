//! 64×32 monochrome framebuffer. Backed by a flat `[2048]u1` array so element
//! access is cheap; sprite XOR drawing for `DXYN` lands at M1.

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
};
